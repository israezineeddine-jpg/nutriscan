// Minimal MQL5 API emulation so an MQL5 indicator source can be compiled as C++ and executed on real data.
#pragma once
#include <string>
#include <vector>
#include <map>
#include <set>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <type_traits>
#include <ctime>

typedef long long datetime;
typedef unsigned int color;
typedef int ENUM_OBJECT;
typedef int ENUM_LINE_STYLE;
typedef int ENUM_TIMEFRAMES;

struct mstring {
    std::string s;
    mstring() {}
    mstring(const char* c) : s(c ? c : "") {}
    mstring(const std::string& c) : s(c) {}
    bool operator==(const mstring& o) const { return s == o.s; }
    bool operator!=(const mstring& o) const { return s != o.s; }
};
typedef mstring string;
inline mstring operator+(const mstring& a, const mstring& b) { return mstring(a.s + b.s); }
inline mstring& operator+=(mstring& a, const mstring& b) { a.s += b.s; return a; }
inline mstring _S(const char* c) { return mstring(c); }

// ---- arrays with bounds checking (MQL5 stops the program on out-of-range access)
template <class T> struct Store { typedef T type; };
template <> struct Store<bool> { typedef unsigned char type; };
template <class T> struct MArr {
    std::vector<typename Store<T>::type> v;
    T& operator[](long long i) {
        if (i < 0 || i >= (long long)v.size())
            throw std::runtime_error("array out of range: idx=" + std::to_string(i) + " size=" + std::to_string(v.size()));
        return reinterpret_cast<T&>(v[i]);
    }
    const T& operator[](long long i) const {
        if (i < 0 || i >= (long long)v.size())
            throw std::runtime_error("array out of range: idx=" + std::to_string(i) + " size=" + std::to_string(v.size()));
        return reinterpret_cast<const T&>(v[i]);
    }
    int size() const { return (int)v.size(); }
};
template <class T> int ArrayResize(MArr<T>& a, int n) {
    size_t old = a.v.size();
    a.v.resize(n);
    // MQL5 does not initialise new elements: poison them so reads of uninitialised data show up
    for (size_t i = old; i < a.v.size(); i++) {
        if constexpr (std::is_floating_point<T>::value) a.v[i] = (T)NAN;
        else if constexpr (std::is_same<T, bool>::value) a.v[i] = 1;
        else if constexpr (std::is_arithmetic<T>::value) a.v[i] = (T)-777777777;
    }
    return n;
}
template <class T> void ArraySetAsSeries(MArr<T>&, bool) {}
template <class T> int ArrayInitialize(MArr<T>& a, T val) { for (auto& x : a.v) x = (typename Store<T>::type)val; return (int)a.v.size(); }

// ---- structs
struct MqlRates { datetime time; double open, high, low, close; long tick_volume; int spread; long real_volume; };
struct MqlDateTime { int year, mon, day, hour, min, sec, day_of_week, day_of_year; };

// ---- constants
const int PERIOD_M5 = 5, PERIOD_M30 = 30;
const int OBJ_TREND = 1, OBJ_ARROW_BUY = 2, OBJ_ARROW_SELL = 3, OBJ_RECTANGLE = 4, OBJ_TEXT = 5, OBJ_LABEL = 6, OBJ_RECTANGLE_LABEL = 7;
const int OBJPROP_COLOR = 1, OBJPROP_STYLE = 2, OBJPROP_WIDTH = 3, OBJPROP_RAY_RIGHT = 4, OBJPROP_SELECTABLE = 5, OBJPROP_FONTSIZE = 6,
          OBJPROP_ANCHOR = 7, OBJPROP_FILL = 8, OBJPROP_CORNER = 9, OBJPROP_XDISTANCE = 10, OBJPROP_YDISTANCE = 11, OBJPROP_XSIZE = 12,
          OBJPROP_YSIZE = 13, OBJPROP_BGCOLOR = 14, OBJPROP_BORDER_TYPE = 15, OBJPROP_BACK = 16, OBJPROP_TEXT = 17, OBJPROP_FONT = 18;
const int CORNER_LEFT_UPPER = 0, ANCHOR_LEFT_UPPER = 0, ANCHOR_LEFT_LOWER = 2, BORDER_FLAT = 0, STYLE_SOLID = 0, STYLE_DOT = 2;
const int TIME_DATE = 1, TIME_MINUTES = 2, TIME_SECONDS = 4;
const int INIT_SUCCEEDED = 0, INIT_PARAMETERS_INCORRECT = 2, INDICATOR_SHORTNAME = 0;
const color clrWhite = 0xFFFFFF, clrAqua = 0xFFFF00, clrYellow = 0x00FFFF, clrTomato = 0x4763FF, clrDimGray = 0x696969,
            clrSilver = 0xC0C0C0, clrLime = 0x00FF00, clrRed = 0x0000FF, clrDodgerBlue = 0xFF901E, clrOrangeRed = 0x0045FF;
inline color RGB(int r, int g, int b) { return (color)(r | (g << 8) | (b << 16)); }

// ---- environment state (set by the harness)
inline mstring _Symbol = "XAUUSDm";
inline int _Digits = 3;
inline int _Period = 30;
inline datetime g_now = 0;                       // open time of the (forming) current M5 bar
inline std::map<std::string, std::vector<MqlRates>> g_series;   // key "SYM|tf"
inline std::vector<std::string> g_symbols;
inline std::vector<std::string> g_log;
inline std::set<std::string> g_logSeen;
inline int g_errors = 0;
inline int g_copyCalls = 0;
inline int g_failCalls = 0;      // first N CopyRates calls fail (history not ready)
inline int g_failITime = 0;      // first N iTime calls return 0
inline int g_copyCap = 0;        // if >0: CopyRates(start_pos) never returns more than this many bars (partial download)

inline std::string keyOf(const mstring& s, int tf) { return s.s + "|" + std::to_string(tf); }

// index of last bar with time <= g_now, or -1
inline int lastIdx(const std::vector<MqlRates>& b) {
    int lo = 0, hi = (int)b.size();
    while (lo < hi) { int m = (lo + hi) / 2; if (b[m].time <= g_now) lo = m + 1; else hi = m; }
    return lo - 1;
}
inline MqlRates visible(const std::vector<MqlRates>& b, int i, int tf) {
    MqlRates r = b[i];
    if (r.time + tf * 60 > g_now) { r.high = r.low = r.close = r.open; }   // forming bar at its first tick
    return r;
}
inline int CopyRates(const mstring& sym, int tf, int start_pos, int count, MArr<MqlRates>& out) {
    g_copyCalls++;
    if (g_failCalls > 0) { g_failCalls--; return -1; }
    auto it = g_series.find(keyOf(sym, tf));
    if (it == g_series.end()) return -1;
    int li = lastIdx(it->second);
    if (li < 0) return -1;
    int hiI = li - start_pos; if (hiI < 0) return -1;
    if (g_copyCap > 0) count = std::min(count, g_copyCap);
    int loI = std::max(0, hiI - count + 1);
    out.v.clear();
    for (int i = loI; i <= hiI; i++) out.v.push_back(visible(it->second, i, tf));
    return (int)out.v.size();
}
inline int CopyRates(const mstring& sym, int tf, datetime start, datetime stop, MArr<MqlRates>& out) {
    g_copyCalls++;
    if (g_failCalls > 0) { g_failCalls--; return -1; }
    auto it = g_series.find(keyOf(sym, tf));
    if (it == g_series.end()) return -1;
    int li = lastIdx(it->second);
    out.v.clear();
    for (int i = 0; i <= li; i++) {
        const MqlRates& r = it->second[i];
        if (r.time >= start && r.time <= stop) out.v.push_back(visible(it->second, i, tf));
    }
    return out.v.empty() ? -1 : (int)out.v.size();
}
inline datetime iTime(const mstring& sym, int tf, int shift) {
    if (g_failITime > 0) { g_failITime--; return 0; }
    auto it = g_series.find(keyOf(sym, tf));
    if (it == g_series.end()) return 0;
    int li = lastIdx(it->second) - shift;
    return li < 0 ? 0 : it->second[li].time;
}

inline int iBars(const mstring& sym, int tf) {
    auto it = g_series.find(keyOf(sym, tf));
    if (it == g_series.end()) return 0;
    return lastIdx(it->second) + 1;
}
// ---- symbols
inline bool SymbolSelect(const mstring& n, bool) { return std::find(g_symbols.begin(), g_symbols.end(), n.s) != g_symbols.end(); }
inline int SymbolsTotal(bool) { return (int)g_symbols.size(); }
inline mstring SymbolName(int i, bool) { return mstring(g_symbols.at(i)); }

// ---- time / strings / math
inline void TimeToStruct(datetime t, MqlDateTime& d) {
    time_t tt = (time_t)t; struct tm g; gmtime_r(&tt, &g);
    d.year = g.tm_year + 1900; d.mon = g.tm_mon + 1; d.day = g.tm_mday; d.hour = g.tm_hour; d.min = g.tm_min; d.sec = g.tm_sec;
    d.day_of_week = g.tm_wday; d.day_of_year = g.tm_yday;
}
inline mstring TimeToString(datetime t, int mode = TIME_DATE | TIME_MINUTES) {
    MqlDateTime d; TimeToStruct(t, d); char b[64];
    std::string s;
    if (mode & TIME_DATE) { snprintf(b, sizeof b, "%04d.%02d.%02d", d.year, d.mon, d.day); s += b; }
    if (mode & TIME_MINUTES) { snprintf(b, sizeof b, "%s%02d:%02d", s.empty() ? "" : " ", d.hour, d.min); s += b; }
    if (mode & TIME_SECONDS) { snprintf(b, sizeof b, ":%02d", d.sec); s += b; }
    return mstring(s);
}
inline mstring DoubleToString(double v, int digits = 8) { char b[64]; snprintf(b, sizeof b, "%.*f", digits, v); return mstring(b); }
inline mstring IntegerToString(long long v) { return mstring(std::to_string(v)); }
inline int StringFind(const mstring& s, const mstring& sub, int start = 0) { size_t p = s.s.find(sub.s, start); return p == std::string::npos ? -1 : (int)p; }
inline bool StringToUpper(mstring& s) { for (auto& c : s.s) c = (char)toupper((unsigned char)c); return true; }
inline int StringLen(const mstring& s) { return (int)s.s.size(); }
template <class A, class B> inline typename std::common_type<A, B>::type MathMax(A a, B b) { return a > b ? a : b; }
template <class A, class B> inline typename std::common_type<A, B>::type MathMin(A a, B b) { return a < b ? a : b; }
inline double MathAbs(double x) { return std::fabs(x); }
inline double MathRound(double x) { return std::round(x); }
inline uint GetTickCount() { static uint t = 100000; t += 3000; return t; }

// ---- logging
inline std::string toStr(const mstring& s) { return s.s; }
inline std::string toStr(const char* s) { return s; }
inline std::string toStr(int v) { return std::to_string(v); }
inline std::string toStr(long long v) { return std::to_string(v); }
inline std::string toStr(unsigned v) { return std::to_string(v); }
inline std::string toStr(double v) { char b[64]; snprintf(b, sizeof b, "%g", v); return b; }
inline std::string toStr(bool v) { return v ? "true" : "false"; }
template <class... A> void Print(A... a) { std::string o; ((o += toStr(a)), ...); g_log.push_back("PRINT: " + o); }
template <class... A> void Alert(A... a) { std::string o; ((o += toStr(a)), ...); g_log.push_back("ALERT: " + o); }
inline int GetLastError() { return 0; }

// ---- chart objects
struct ObjInfo { int type; std::map<int, long long> iprops; std::map<int, std::string> sprops; };
inline std::map<std::string, ObjInfo> g_objs;
inline bool ObjectCreate(long, const mstring& name, int type, int, long long, double, long long = 0, double = 0) {
    if (g_objs.count(name.s)) { g_log.push_back("ERR: ObjectCreate duplicate " + name.s); g_errors++; return false; }
    g_objs[name.s] = ObjInfo{type, {}, {}};
    return true;
}
inline bool ObjectSetInteger(long, const mstring& name, int prop, long long v) {
    auto it = g_objs.find(name.s);
    if (it == g_objs.end()) { g_log.push_back("ERR: ObjectSetInteger on missing object " + name.s); g_errors++; return false; }
    it->second.iprops[prop] = v; return true;
}
inline bool ObjectSetString(long, const mstring& name, int prop, const mstring& v) {
    auto it = g_objs.find(name.s);
    if (it == g_objs.end()) { g_log.push_back("ERR: ObjectSetString on missing object " + name.s); g_errors++; return false; }
    it->second.sprops[prop] = v.s; return true;
}
inline int ObjectsDeleteAll(long, const mstring& prefix, int = -1, int = -1) {
    int n = 0;
    for (auto it = g_objs.begin(); it != g_objs.end();) {
        if (it->first.compare(0, prefix.s.size(), prefix.s) == 0) { it = g_objs.erase(it); n++; } else ++it;
    }
    return n;
}
inline void ChartRedraw(long = 0) {}
inline void EventSetTimer(int) {}
inline void EventKillTimer() {}
inline bool IndicatorSetString(int, const mstring&) { return true; }
