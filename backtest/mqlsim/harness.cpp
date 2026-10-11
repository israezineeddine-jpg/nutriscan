#include "mql_shim.h"
#include "ind_gen.cpp"
#include <fstream>
#include <sstream>
#include <iostream>
#include <random>

static long long days_from_civil(int y, unsigned m, unsigned d) {
    y -= m <= 2; const int era = (y >= 0 ? y : y - 399) / 400; const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1; const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (long long)era * 146097 + (long long)doe - 719468;
}
static std::vector<MqlRates> load(const std::string& path) {
    std::vector<MqlRates> v; std::ifstream f(path); std::string line;
    while (std::getline(f, line)) {
        int Y, M, D, h, m; double o, hi, lo, c; long vol;
        if (sscanf(line.c_str(), "%d.%d.%d,%d:%d,%lf,%lf,%lf,%lf,%ld", &Y, &M, &D, &h, &m, &o, &hi, &lo, &c, &vol) < 9) continue;
        MqlRates r{}; r.time = days_from_civil(Y, M, D) * 86400LL + h * 3600 + m * 60; r.open = o; r.high = hi; r.low = lo; r.close = c; r.tick_volume = vol;
        v.push_back(r);
    }
    return v;
}
static void dump_trades(const char* path) {
    FILE* f = fopen(path, "w");
    fprintf(f, "open_epoch,open,dir,entry,sl,tp,exit,res,R,end\n");
    for (int i = 0; i < nt; i++)
        fprintf(f, "%lld,%s,%d,%.5f,%.5f,%.5f,%.5f,%d,%.5f,%s\n", trEnt[i], TimeToString(trEnt[i]).s.c_str(), trDir[i], trPrice[i], trSL[i], trTP[i],
                trExit[i], trRes[i], trR[i], TimeToString(trEnd[i]).s.c_str());
    fclose(f);
}
static void dump_dashboard(const char* path) {
    FILE* f = fopen(path, "w");
    for (auto& kv : g_objs) if (kv.first.rfind("OB30D_l", 0) == 0 && kv.second.sprops.count(OBJPROP_TEXT)) fprintf(f, "%s | %s\n", kv.first.c_str(), kv.second.sprops[OBJPROP_TEXT].c_str());
    fclose(f);
}
static MArr<datetime> dT; static MArr<double> dD; static MArr<long> dL; static MArr<int> dI;
static void reset_state() { lastSig = 0; lastAlert = 0; nt = 0; nz = 0; n5 = 0; nS = 0; g_objs.clear(); }

int main(int argc, char** argv) {
    std::string scen = argc > 1 ? argv[1] : "full";
    std::string dir = argc > 2 ? argv[2] : ".";
    auto g5 = load(dir + "/gold5.csv"), g30 = load(dir + "/gold30.csv"), s5 = load(dir + "/silver5.csv");
    std::string silverName = getenv("SILVER_NAME") ? getenv("SILVER_NAME") : "XAGUSDm";
    g_symbols = {"XAUUSDm", silverName};
    g_series["XAUUSDm|5"] = g5; g_series["XAUUSDm|30"] = g30; g_series[silverName + "|5"] = s5;
    printf("loaded gold5=%zu gold30=%zu silver5=%zu (silver symbol in broker = %s)\n", g5.size(), g30.size(), s5.size(), silverName.c_str());
    try {
        if (scen == "full") {
            g_now = g5.back().time; HistoryBars = 1000000;
            int rc = OnInit(); printf("OnInit rc=%d  silver resolved = %s\n", rc, g_silver.s.c_str());
            OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
            printf("n5=%d nS=%d nz=%d nt=%d errors=%d\n", n5, nS, nz, nt, g_errors);
            dump_trades((dir + "/ind_trades_full.csv").c_str()); dump_dashboard((dir + "/ind_dashboard.txt").c_str());
            int cnt = 0; for (auto& kv : g_objs) if (kv.first.rfind("OB30_", 0) == 0) cnt++;
            printf("chart objects (OB30_*) = %d, dashboard lines = %d\n", cnt, (int)g_objs.size() - cnt);
        } else if (scen == "live") {
            // live replay: at the first tick of selected M5 bars with HistoryBars=4000
            HistoryBars = 4000;
            OnInit();
            std::mt19937 rng(12345);
            std::set<long long> picks;
            // indices of gold M5 bars between silver start+6h and the end
            long long tmin = s5.front().time + 6 * 3600;
            std::vector<int> cand; for (int i = 0; i < (int)g5.size(); i++) if (g5[i].time >= tmin) cand.push_back(i);
            // all entry bars from the file (if provided) + random sample
            std::vector<long long> entries;
            { std::ifstream f(dir + "/entries.txt"); long long t; while (f >> t) entries.push_back(t); }
            int nsamp = argc > 3 ? atoi(argv[3]) : 1500;
            std::vector<long long> steps = entries;
            for (int k = 0; k < nsamp; k++) steps.push_back(g5[cand[rng() % cand.size()]].time);
            std::sort(steps.begin(), steps.end()); steps.erase(std::unique(steps.begin(), steps.end()), steps.end());
            std::set<long long> entrySet(entries.begin(), entries.end());
            int exceptions = 0, liveHits = 0, entryChecked = 0, entryFired = 0, entryDirOk = 0;
            std::vector<std::string> fired;
            for (long long t : steps) {
                g_now = t; reset_state(); g_log.clear();
                try {
                    OnTimer();
                } catch (std::exception& e) { exceptions++; printf("EXCEPTION at %s : %s\n", TimeToString(t).s.c_str(), e.what()); continue; }
                bool fire = false;
                for (auto& l : g_log) if (l.rfind("ALERT:", 0) == 0) fire = true;
                if (fire) { liveHits++; char b[256]; snprintf(b, sizeof b, "%s dir=%d entry=%.3f sl=%.3f tp=%.3f", TimeToString(t).s.c_str(), trDir[nt - 1], trPrice[nt - 1], trSL[nt - 1], trTP[nt - 1]); fired.push_back(b); }
                if (entrySet.count(t)) { entryChecked++; if (fire) entryFired++; }
            }
            printf("steps=%zu exceptions=%d errors=%d liveAlerts=%d | entry bars checked=%d fired=%d\n", steps.size(), exceptions, g_errors, liveHits, entryChecked, entryFired);
            FILE* f = fopen((dir + "/live_fired.txt").c_str(), "w"); for (auto& s : fired) fprintf(f, "%s\n", s.c_str()); fclose(f);
        } else if (scen == "warmup") {
            // history not ready at attach: first 6 CopyRates calls fail and first 2 iTime calls return 0
            g_now = g5.back().time; HistoryBars = 4000; g_failCalls = 6; g_failITime = 2;
            OnInit(); OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
            printf("after attach: nt=%d nS=%d dashboard objs=%d\n", nt, nS, (int)g_objs.size());
            for (int k = 1; k <= 12 && lastSig == 0; k++) { OnTimer(); printf("timer tick %d -> lastSig=%lld nt=%d\n", k, (long long)lastSig, nt); }
            dump_dashboard((dir + "/ind_dashboard_warm.txt").c_str());
            for (auto& l : g_log) printf("%s\n", l.c_str());
        } else if (scen == "partial") {
            // terminal still downloading: CopyRates returns only 900 bars at first, then everything
            g_now = g5.back().time; HistoryBars = 4000; g_copyCap = 900;
            OnInit(); OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
            printf("partial: n5=%d incomplete=%d nt=%d\n", n5, (int)g_incomplete, nt);
            g_copyCap = 0; OnTimer();
            printf("after full download: n5=%d incomplete=%d nt=%d\n", n5, (int)g_incomplete, nt);
            OnTimer(); OnTimer();
            printf("stable: n5=%d incomplete=%d (copy calls so far %d)\n", n5, (int)g_incomplete, g_copyCalls);
        } else if (scen == "early") {
            // steps spread over the WHOLE gold history (also before silver exists), incl. very first bars
            HistoryBars = 4000; OnInit();
            int exceptions = 0, steps = 0;
            std::mt19937 rng(777);
            std::vector<long long> st;
            for (int i = 0; i < 400; i++) st.push_back(g5[i].time);
            for (int i = 0; i < 2500; i++) st.push_back(g5[rng() % g5.size()].time);
            for (long long t : st) {
                g_now = t; reset_state(); g_log.clear(); steps++;
                try { OnTimer(); } catch (std::exception& e) { exceptions++; printf("EXCEPTION at %s : %s\n", TimeToString(t).s.c_str(), e.what()); }
            }
            printf("steps=%d exceptions=%d object errors=%d\n", steps, exceptions, g_errors);
        } else if (scen == "options") {
            struct Opt { const char* name; void (*set)(); };
            std::vector<Opt> opts = {
                {"UseSMT=false", [] { UseSMT = false; }},
                {"ShowAllZones=true", [] { ShowAllZones = true; }},
                {"NeedColor=false", [] { NeedColor = false; }},
                {"ShowOutcome=false+ShowDashboard=false", [] { ShowOutcome = false; ShowDashboard = false; }},
                {"RR=3 SMTWindow=30 NoWeekend=false", [] { RR = 3.0; SMTWindow = 30; NoWeekend = false; }},
                {"AlertOnSignal=false MaxRiskPts=0", [] { AlertOnSignal = false; MaxRiskPts = 0; }},
            };
            for (auto& o : opts) {
                UseSMT = true; ShowAllZones = false; NeedColor = true; ShowOutcome = true; ShowDashboard = true; RR = 2.0; SMTWindow = 24;
                NoWeekend = true; AlertOnSignal = true; MaxRiskPts = 20.0;
                o.set(); g_errors = 0; g_log.clear();
                HistoryBars = 100000; g_now = g5.back().time; reset_state(); OnInit();
                OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
                int cnt = 0; for (auto& kv : g_objs) if (kv.first.rfind("OB30_", 0) == 0) cnt++;
                printf("%-42s -> trades=%d objects=%d dashboardObjs=%d errors=%d\n", o.name, nt, cnt, (int)g_objs.size() - cnt, g_errors);
            }
        } else if (scen == "smallwin") {
            for (int hb : {500, 700, 1500, 100000}) {
                HistoryBars = hb; g_now = g5.back().time; reset_state(); g_log.clear();
                OnInit(); OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
                printf("HistoryBars=%d -> n5=%d nt=%d errors=%d\n", hb, n5, nt, g_errors);
            }
        } else if (scen == "silver_missing") {
            // silver series truncated 9 hours before gold end
            g_now = g5.back().time; HistoryBars = 4000;
            std::vector<MqlRates> cut; for (auto& r : s5) if (r.time <= g_now - 9 * 3600) cut.push_back(r);
            g_series[silverName + "|5"] = cut;
            OnInit(); OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
            printf("nS=%d nt=%d\n", nS, nt);
            for (auto& kv : g_objs) if (kv.second.sprops.count(OBJPROP_TEXT) && kv.first.rfind("OB30D_", 0) == 0) printf("%s | %s\n", kv.first.c_str(), kv.second.sprops[OBJPROP_TEXT].c_str());
        } else if (scen == "no_silver_symbol") {
            g_symbols = {"XAUUSDm"}; g_series.erase(silverName + "|5");
            g_now = g5.back().time; HistoryBars = 4000;
            OnInit(); OnCalculate(0, 0, dT, dD, dD, dD, dD, dL, dL, dI);
            printf("nS=%d nt=%d silver=%s\n", nS, nt, g_silver.s.c_str());
            for (auto& kv : g_objs) if (kv.second.sprops.count(OBJPROP_TEXT) && kv.first.rfind("OB30D_", 0) == 0) printf("%s | %s\n", kv.first.c_str(), kv.second.sprops[OBJPROP_TEXT].c_str());
        }
    } catch (std::exception& e) { printf("FATAL EXCEPTION: %s\n", e.what()); return 2; }
    for (auto& l : g_log) if (l.rfind("ERR", 0) == 0) printf("%s\n", l.c_str());
    return 0;
}
