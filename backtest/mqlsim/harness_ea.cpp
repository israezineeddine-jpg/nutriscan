// Runs OB_CHoCH_M1.mq5 (converted by mql2cpp_ea.py into ea_gen.cpp) tick by tick on M1 bars.
// Each M1 bar gives 4 ticks: open, adverse extreme for an open position (SL first, as in the Python backtest),
// favourable extreme, close.  bid = data price, ask = bid + spread.
//   ./harness_ea <dir with m1_server.csv, m30_server.csv> <spread> [start_bar]
// start_bar > 0: the EA is attached in the middle of the data (warm start test).
#include "mql_trade_shim.h"
#include "ea_gen.cpp"
#include <iostream>

static std::vector<MqlRates> load(const std::string& path) {
    std::vector<MqlRates> v; FILE* f = fopen(path.c_str(), "r"); if (!f) { printf("missing %s\n", path.c_str()); exit(1); }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        long long t; double o, h, l, c;
        if (sscanf(line, "%lld,%lf,%lf,%lf,%lf", &t, &o, &h, &l, &c) != 5) continue;
        MqlRates r{}; r.time = t; r.open = o; r.high = h; r.low = l; r.close = c; v.push_back(r);
    }
    fclose(f); return v;
}

int main(int argc, char** argv) {
    std::string dir = argc > 1 ? argv[1] : ".";
    double spread = argc > 2 ? atof(argv[2]) : 0.0;
    size_t start = argc > 3 ? (size_t)atol(argv[3]) : 0;
    std::string clock = argc > 4 ? argv[4] : "ny7";
    if (clock == "fixed0") { ServerClock = CLOCK_FIXED; ServerUTCOffset = 0; }
    std::string suf = clock == "fixed0" ? "_utc" : "_server";
    auto m1 = load(dir + "/m1" + suf + ".csv"), m30 = load(dir + "/m30" + suf + ".csv");
    _Symbol = "XAUUSD"; _Digits = 2; _Point = 0.01;
    g_series["XAUUSD|1"] = m1; g_series["XAUUSD|30"] = m30;
    g_fileDir = dir;
    printf("m1=%zu m30=%zu spread=%.2f start_bar=%zu clock=%s\n", m1.size(), m30.size(), spread, start, clock.c_str());
    auto tick = [&](datetime t, double p) {
        g_now = t; g_tick = t; g_bid = p; g_ask = p + spread;
        sim_check_stops();
        OnTick();
    };
    try {
        g_now = g_tick = m1[start].time + 30; g_bid = m1[start].open; g_ask = g_bid + spread;   // attach inside bar 'start'
        int rc = OnInit();
        printf("OnInit rc=%d zones=%d buffer=%d\n", rc, nZones, nb);
        for (size_t i = start; i < m1.size(); i++) {
            const MqlRates& b = m1[i];
            if (i > start) tick(b.time, b.open);
            bool shortPos = !g_pos.empty() && g_pos[0].type == POSITION_TYPE_SELL;
            tick(b.time + 15, shortPos ? b.high : b.low);
            tick(b.time + 30, shortPos ? b.low : b.high);
            tick(b.time + 59, b.close);
        }
        OnDeinit(0);
    } catch (std::exception& e) { printf("EXCEPTION: %s\n", e.what()); return 2; }
    printf("deals=%zu open positions at end=%zu balance=%.2f errors=%d log lines=%zu\n", g_deals.size(), g_pos.size(), g_balance, g_errors, g_log.size());
    int shown = 0;
    for (auto& s : g_log) if (s.rfind("ERR", 0) == 0 && shown++ < 10) printf("%s\n", s.c_str());
    for (size_t i = 0; i < g_log.size() && i < 3; i++) printf("%s\n", g_log[i].c_str());
    printf("%s\n", g_log.empty() ? "" : g_log.back().c_str());
    return 0;
}
