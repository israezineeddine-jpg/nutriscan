// Trading API emulation on top of mql_shim.h: one symbol, market orders, SL/TP executed by the harness,
// deal history, CSV files. Enough to run an Expert Advisor bar by bar on real data.
#pragma once
#include "mql_shim.h"
#include <cfloat>
#include <fstream>

const int PERIOD_M1 = 1;
const int OBJPROP_TIME = 19;
const int MQL_OPTIMIZATION = 1, MQL_TESTER = 2;
const int INVALID_HANDLE = -1, FILE_WRITE = 2, FILE_CSV = 8, FILE_ANSI = 32;
enum { SYMBOL_BID = 1, SYMBOL_ASK, SYMBOL_TRADE_TICK_VALUE, SYMBOL_TRADE_TICK_VALUE_LOSS, SYMBOL_TRADE_TICK_SIZE,
       SYMBOL_VOLUME_STEP, SYMBOL_VOLUME_MIN, SYMBOL_VOLUME_MAX, SYMBOL_POINT };
enum { ACCOUNT_BALANCE = 1, ACCOUNT_EQUITY };
enum { POSITION_SYMBOL = 1, POSITION_MAGIC, POSITION_TIME, POSITION_TYPE, POSITION_PRICE_OPEN, POSITION_SL, POSITION_TP,
       POSITION_VOLUME, POSITION_TICKET };
enum { POSITION_TYPE_BUY = 0, POSITION_TYPE_SELL = 1 };
enum { DEAL_MAGIC = 1, DEAL_SYMBOL, DEAL_ENTRY, DEAL_POSITION_ID, DEAL_TYPE, DEAL_TIME, DEAL_VOLUME, DEAL_PRICE, DEAL_SL,
       DEAL_TP, DEAL_PROFIT, DEAL_COMMISSION, DEAL_SWAP, DEAL_COMMENT };
enum { DEAL_ENTRY_IN = 0, DEAL_ENTRY_OUT = 1 };
enum { DEAL_TYPE_BUY = 0, DEAL_TYPE_SELL = 1 };

inline double _Point = 0.01;
inline double g_bid = 0, g_ask = 0, g_balance = 100000.0, g_contract = 100.0;
inline datetime g_tick = 0;                         // time of the current tick

struct SimPos { ulong ticket; int type; double vol, price, sl, tp; datetime time; long magic; std::string comment; };
struct SimDeal { ulong ticket; ulong pos; int type, entry; datetime time; double vol, price, sl, tp, profit; long magic; std::string comment; };
inline std::vector<SimPos> g_pos;
inline std::vector<SimDeal> g_deals;
inline ulong g_nextTicket = 1000;
inline int g_selPos = -1;
inline bool g_optimization = false;

inline datetime TimeCurrent() { return g_tick; }
inline datetime StructToTime(MqlDateTime& d) {
    struct tm g{}; g.tm_year = d.year - 1900; g.tm_mon = d.mon - 1; g.tm_mday = d.day; g.tm_hour = d.hour; g.tm_min = d.min; g.tm_sec = d.sec;
    return (datetime)timegm(&g);
}
template <class T> int ArraySize(const MArr<T>& a) { return (int)a.v.size(); }
inline double NormalizeDouble(double v, int digits) { double p = std::pow(10.0, digits); return std::round(v * p) / p; }
inline double MathFloor(double x) { return std::floor(x); }
inline int PeriodSeconds(int tf) { return tf * 60; }
inline int MQLInfoInteger(int what) { return what == MQL_OPTIMIZATION ? (int)g_optimization : (what == MQL_TESTER ? 1 : 0); }
inline int iBarShift(const mstring& sym, int tf, datetime t, bool exact = false) {
    auto it = g_series.find(keyOf(sym, tf));
    if (it == g_series.end()) return -1;
    const auto& b = it->second;
    int li = lastIdx(b); if (li < 0) return -1;
    int lo = 0, hi = li + 1;                     // last bar with time <= t
    while (lo < hi) { int m = (lo + hi) / 2; if (b[m].time <= t) lo = m + 1; else hi = m; }
    int idx = lo - 1;
    if (idx < 0) return -1;
    if (exact && b[idx].time != t) return -1;
    return li - idx;
}
inline bool ObjectSetInteger(long, const mstring& name, int prop, int modifier, long long v) {
    auto it = g_objs.find(name.s);
    if (it == g_objs.end()) { g_log.push_back("ERR: ObjectSetInteger on missing object " + name.s); g_errors++; return false; }
    it->second.iprops[prop * 100 + modifier] = v; return true;
}
inline double SymbolInfoDouble(const mstring&, int p) {
    switch (p) {
        case SYMBOL_BID: return g_bid; case SYMBOL_ASK: return g_ask;
        case SYMBOL_TRADE_TICK_VALUE: case SYMBOL_TRADE_TICK_VALUE_LOSS: return 0.01 * g_contract;
        case SYMBOL_TRADE_TICK_SIZE: return 0.01; case SYMBOL_VOLUME_STEP: return 0.01; case SYMBOL_VOLUME_MIN: return 0.01;
        case SYMBOL_VOLUME_MAX: return 100.0; case SYMBOL_POINT: return _Point;
    }
    return 0;
}
inline double AccountInfoDouble(int) { return g_balance; }

// ---- positions
inline int PositionsTotal() { return (int)g_pos.size(); }
inline ulong PositionGetTicket(int i) { if (i < 0 || i >= (int)g_pos.size()) return 0; g_selPos = i; return g_pos[i].ticket; }
inline bool PositionSelectByTicket(ulong t) { for (size_t i = 0; i < g_pos.size(); i++) if (g_pos[i].ticket == t) { g_selPos = (int)i; return true; } return false; }
inline long long PositionGetInteger(int p) {
    if (g_selPos < 0 || g_selPos >= (int)g_pos.size()) { g_errors++; g_log.push_back("ERR: PositionGetInteger without selection"); return 0; }
    const SimPos& s = g_pos[g_selPos];
    switch (p) { case POSITION_MAGIC: return s.magic; case POSITION_TIME: return s.time; case POSITION_TYPE: return s.type; case POSITION_TICKET: return (long long)s.ticket; }
    return 0;
}
inline double PositionGetDouble(int p) {
    const SimPos& s = g_pos.at(g_selPos);
    switch (p) { case POSITION_PRICE_OPEN: return s.price; case POSITION_SL: return s.sl; case POSITION_TP: return s.tp; case POSITION_VOLUME: return s.vol; }
    return 0;
}
inline mstring PositionGetString(int p) { return p == POSITION_SYMBOL ? _Symbol : mstring(g_pos.at(g_selPos).comment); }

// ---- broker: open / close
inline void sim_close(size_t i, double price, const std::string& why) {
    SimPos s = g_pos[i];
    double pnl = (s.type == POSITION_TYPE_BUY ? price - s.price : s.price - price) * s.vol * g_contract;
    g_balance += pnl;
    g_deals.push_back(SimDeal{g_nextTicket++, s.ticket, s.type == POSITION_TYPE_BUY ? DEAL_TYPE_SELL : DEAL_TYPE_BUY, DEAL_ENTRY_OUT, g_tick,
                              s.vol, price, s.sl, s.tp, pnl, s.magic, why});
    g_pos.erase(g_pos.begin() + i);
    g_selPos = -1;
}
// called by the harness at every tick, before OnTick: SL / TP at the exact level (same convention as the Python backtest)
inline void sim_check_stops() {
    for (size_t i = 0; i < g_pos.size();) {
        const SimPos& s = g_pos[i];
        if (s.type == POSITION_TYPE_BUY) {
            if (s.sl > 0 && g_bid <= s.sl) { sim_close(i, s.sl, "sl"); continue; }
            if (s.tp > 0 && g_bid >= s.tp) { sim_close(i, s.tp, "tp"); continue; }
        } else {
            if (s.sl > 0 && g_ask >= s.sl) { sim_close(i, s.sl, "sl"); continue; }
            if (s.tp > 0 && g_ask <= s.tp) { sim_close(i, s.tp, "tp"); continue; }
        }
        i++;
    }
}

struct CTrade {
    long magic = 0; unsigned ret = 0;
    void SetExpertMagicNumber(long m) { magic = m; }
    void SetDeviationInPoints(unsigned long) {}
    void SetTypeFillingBySymbol(const mstring&) {}
    unsigned ResultRetcode() { return ret; }
    mstring ResultRetcodeDescription() { return mstring(ret == 10009 ? "done" : "rejected"); }
    bool open(int type, double lots, double sl, double tp, const mstring& cm) {
        double px = type == POSITION_TYPE_BUY ? g_ask : g_bid;
        if (lots <= 0 || (type == POSITION_TYPE_BUY && (sl >= px || tp <= px)) || (type == POSITION_TYPE_SELL && (sl <= px || tp >= px))) {
            ret = 10016; g_log.push_back("ERR: invalid stops"); g_errors++; return false;
        }
        SimPos s{g_nextTicket++, type, lots, px, sl, tp, g_tick, magic, cm.s};
        g_pos.push_back(s);
        g_deals.push_back(SimDeal{g_nextTicket++, s.ticket, type == POSITION_TYPE_BUY ? DEAL_TYPE_BUY : DEAL_TYPE_SELL, DEAL_ENTRY_IN, g_tick,
                                  lots, px, sl, tp, 0.0, magic, cm.s});
        ret = 10009; return true;
    }
    bool Buy(double lots, const mstring&, double, double sl, double tp, const mstring& cm) { return open(POSITION_TYPE_BUY, lots, sl, tp, cm); }
    bool Sell(double lots, const mstring&, double, double sl, double tp, const mstring& cm) { return open(POSITION_TYPE_SELL, lots, sl, tp, cm); }
    bool PositionClose(ulong ticket) {
        for (size_t i = 0; i < g_pos.size(); i++)
            if (g_pos[i].ticket == ticket) { sim_close(i, g_pos[i].type == POSITION_TYPE_BUY ? g_bid : g_ask, "close"); ret = 10009; return true; }
        ret = 10036; return false;
    }
};

// ---- history
inline bool HistorySelect(datetime, datetime) { return true; }
inline int HistoryDealsTotal() { return (int)g_deals.size(); }
inline ulong HistoryDealGetTicket(int i) { return (i >= 0 && i < (int)g_deals.size()) ? g_deals[i].ticket : 0; }
inline const SimDeal* deal_of(ulong t) { for (auto& d : g_deals) if (d.ticket == t) return &d; return nullptr; }
inline long long HistoryDealGetInteger(ulong t, int p) {
    const SimDeal* d = deal_of(t); if (!d) return 0;
    switch (p) { case DEAL_MAGIC: return d->magic; case DEAL_ENTRY: return d->entry; case DEAL_POSITION_ID: return (long long)d->pos;
                 case DEAL_TYPE: return d->type; case DEAL_TIME: return d->time; }
    return 0;
}
inline double HistoryDealGetDouble(ulong t, int p) {
    const SimDeal* d = deal_of(t); if (!d) return 0;
    switch (p) { case DEAL_VOLUME: return d->vol; case DEAL_PRICE: return d->price; case DEAL_SL: return d->sl; case DEAL_TP: return d->tp;
                 case DEAL_PROFIT: return d->profit; }
    return 0;
}
inline mstring HistoryDealGetString(ulong t, int p) { const SimDeal* d = deal_of(t); if (!d) return mstring(""); return p == DEAL_SYMBOL ? _Symbol : mstring(d->comment); }

// ---- files (written in g_fileDir)
inline std::string g_fileDir = ".";
inline std::map<int, FILE*> g_files;
inline int FileOpen(const mstring& name, int, int) { FILE* f = fopen((g_fileDir + "/" + name.s).c_str(), "w"); if (!f) return INVALID_HANDLE; int h = (int)g_files.size() + 1; g_files[h] = f; return h; }
inline std::string fstr(const mstring& s) { return s.s; }
inline std::string fstr(const char* s) { return s; }
template <class... A> void FileWrite(int h, A... a) {
    std::string o; bool first = true;
    ((o += (first ? "" : ","), o += fstr(a), first = false), ...);
    fprintf(g_files.at(h), "%s\n", o.c_str());
}
inline void FileClose(int h) { fclose(g_files.at(h)); g_files.erase(h); }
