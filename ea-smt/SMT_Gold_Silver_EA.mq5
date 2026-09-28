//+------------------------------------------------------------------+
//|                                          SMT_Gold_Silver_EA.mq5  |
//|  MQL5 port of the TradingView indicator "SMT — ENTRY SL TP"      |
//|  Gold (chart symbol, M5) vs Silver SMT divergence, breakout      |
//|  entry, SL beyond the swept swing, TP at a fixed R multiple.     |
//|  Adds prop-firm (FTMO) protections: daily / max loss guards,     |
//|  spread, session and news filters, execution log.                |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Gold/Silver SMT divergence EA (port of 'SMT — ENTRY SL TP')"

#include <Trade\Trade.mqh>

enum ENUM_SMT_ENTRY_MODE
  {
   ENTRY_STOP_ORDER = 0,      // Stop order at the breakout level
   ENTRY_MARKET_ON_CLOSE = 1  // Market order when the breakout candle closes
  };

//================= INPUTS =================

input group "SMT"
input string InpSilverSymbol   = ""; // Silver symbol (empty = auto, e.g. XAUUSDm -> XAGUSDm)
input int    InpLeftBars       = 2;        // Pivot left bars
input int    InpRightBars      = 2;        // Pivot right bars
input int    InpPairTolerance  = 3;        // Pair tolerance — M5 intervals
input int    InpMaxGap         = 200;      // Maximum swing gap
input int    InpHistoryBars    = 3000;     // History bars used to warm up
input double InpBufferPoints   = 10.0;     // SL buffer — points
input double InpPointSize      = 0.0;      // Point size — 0 = symbol point

input group "Entry / exit"
input ENUM_SMT_ENTRY_MODE InpEntryMode = ENTRY_STOP_ORDER; // Entry mode
input double InpRiskReward     = 1.0;      // Take profit in R (indicator = 1.0)

input group "Risk (prop firm)"
input double InpRiskPercent       = 0.5;   // Risk per trade, % of initial balance
input double InpInitialBalance    = 0.0;   // Initial account balance (0 = auto)
input double InpDailyLossStopPct  = 4.0;   // Stop the day at this loss % (FTMO limit = 5)
input double InpMaxLossStopPct    = 9.0;   // Stop the EA at this total loss % (FTMO limit = 10)
input int    InpMaxTradesPerDay   = 3;     // Max trades per day
input int    InpMaxOpenPositions  = 1;     // Max open positions
input bool   InpMinLotFallback    = false; // Use the minimum lot when risk % gives less (max 2x the risk)

input group "Filters"
input double InpMaxSpread          = 0.60;  // Max spread in price (0.60 = 60 cents on gold), 0 = off
input bool   InpUseSessionFilter  = true;  // Block trading during rollover hours
input int    InpNoTradeStartHour  = 23;    // No-trade start hour (server time)
input int    InpNoTradeEndHour    = 1;     // No-trade end hour (server time)
input bool   InpUseNewsFilter     = true;  // Block trading around high-impact news
input int    InpNewsMinutesBefore = 5;     // Minutes before news
input int    InpNewsMinutesAfter  = 5;     // Minutes after news
input string InpNewsCurrencies    = "USD"; // News currencies (comma separated)

input group "Misc"
input ulong  InpMagic             = 20260928; // Magic number
input bool   InpDrawSignals       = true;     // Draw entry / SL / TP on chart
input bool   InpLogToFile         = true;     // Write execution log (MQL5/Files)

//================= STATE =================

struct TradeSetup
  {
   int      direction;     // +1 buy, -1 sell
   datetime firstTime;
   datetime secondTime;
   double   firstPrice;
   double   secondPrice;
   double   entry;
   double   stop;
   double   firstGold;
   double   firstSilver;
   bool     goldSwept;
   bool     silverSwept;
   ulong    ticket;        // pending stop order (0 = none)
   bool     traded;        // order already filled
   bool     lotWarned;     // lot-size problem already logged
  };

TradeSetup g_setups[];

// Pending pivots: 0 = Gold low, 1 = Silver low, 2 = Gold high, 3 = Silver high
bool     g_pendValid[4];
datetime g_pendTime[4];
long     g_pendIndex[4];
double   g_pendPrice[4];

// Previous matched pair: 0 = lows, 1 = highs
bool     g_prevValid[2];
datetime g_prevGT[2];
datetime g_prevST[2];
long     g_prevGI[2];
long     g_prevSI[2];
double   g_prevGP[2];
double   g_prevSP[2];

long     g_barIndex      = 0;     // Pine bar_index equivalent
datetime g_lastProcessed = 0;     // open time of the last processed closed bar
bool     g_ready         = false;
datetime g_waitSince     = 0;

double   g_slBuffer      = 0.0;
double   g_initialBalance = 0.0;
datetime g_dayStart      = 0;
double   g_dayStartBalance = 0.0;
bool     g_dailyHalt     = false;
bool     g_totalHalt     = false;

datetime g_newsTimes[];
datetime g_newsLoaded    = 0;

string   g_silver        = "";    // resolved Silver symbol
int      g_signalCount   = 0;
int      g_setupCount    = 0;
int      g_orderCount    = 0;
string   g_lastBlock     = "";
int      g_objCount      = 0;

CTrade   g_trade;

//================= HELPERS =================

// Global variables keep state across restarts on a live account only:
// in the tester they would leak between runs (e.g. an old deposit).
bool UseGlobalVars()
  {
   return !(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION));
  }

string GvName(const string key)
  {
   return "SMTEA_" + key + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((long)InpMagic);
  }

double RoundToTick(const double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0)
      tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

bool GoldBar(const int shift, double &o, double &h, double &l)
  {
   if(shift < 0 || shift >= Bars(_Symbol, PERIOD_M5))
      return false;
   o = iOpen(_Symbol, PERIOD_M5, shift);
   h = iHigh(_Symbol, PERIOD_M5, shift);
   l = iLow(_Symbol, PERIOD_M5, shift);
   return (o > 0.0 && h > 0.0 && l > 0.0);
  }

// Silver candle with exactly the same open time as the Gold candle at goldShift.
bool SilverAt(const int goldShift, double &h, double &l)
  {
   if(goldShift < 0 || goldShift >= Bars(_Symbol, PERIOD_M5))
      return false;
   datetime t = iTime(_Symbol, PERIOD_M5, goldShift);
   if(t == 0)
      return false;
   int ss = iBarShift(g_silver, PERIOD_M5, t, true);
   if(ss < 0)
      return false;
   h = iHigh(g_silver, PERIOD_M5, ss);
   l = iLow(g_silver, PERIOD_M5, ss);
   return (h > 0.0 && l > 0.0);
  }

void LogLine(const string text)
  {
   Print(text);
   if(!InpLogToFile)
      return;
   int fh = FileOpen("SMT_EA_log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ';');
   if(fh == INVALID_HANDLE)
      return;
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), text);
   FileClose(fh);
  }

void RemoveSetup(const int n)
  {
   int size = ArraySize(g_setups);
   for(int i = n; i < size - 1; i++)
      g_setups[i] = g_setups[i + 1];
   ArrayResize(g_setups, size - 1);
  }

bool OrderIsPending(const ulong ticket)
  {
   return (ticket > 0 && OrderSelect(ticket));
  }

// Removes the pending order of a setup. If the order is gone, it was filled.
void DeleteSetupOrder(TradeSetup &tr)
  {
   if(tr.ticket == 0)
      return;
   if(OrderSelect(tr.ticket))
     {
      if(g_trade.OrderDelete(tr.ticket))
         tr.ticket = 0; // otherwise retry on the next tick
     }
   else
     {
      tr.traded = true;
      tr.ticket = 0;
     }
  }

int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
     }
   return count;
  }

void DeleteAllPendingOrders()
  {
   for(int n = 0; n < ArraySize(g_setups); n++)
      DeleteSetupOrder(g_setups[n]);
   // Orphan orders (e.g. left by a previous run).
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == (long)InpMagic && OrderGetString(ORDER_SYMBOL) == _Symbol)
         g_trade.OrderDelete(ticket);
     }
  }

void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         g_trade.PositionClose(ticket);
     }
  }

int TradesToday()
  {
   if(!HistorySelect(g_dayStart, TimeCurrent() + 60))
      return 0;
   int count = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) == (long)InpMagic &&
         HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
     }
   return count;
  }

bool SymbolExists(const string sym)
  {
   if(sym == "")
      return false;
   double pt = 0.0;
   return (SymbolInfoDouble(sym, SYMBOL_POINT, pt) && pt > 0.0);
  }

// Silver symbol: the input if set, otherwise Gold's name with XAU -> XAG
// (keeps broker prefixes / suffixes such as XAUUSDm -> XAGUSDm).
string ResolveSilverSymbol()
  {
   string candidates[4];
   candidates[0] = InpSilverSymbol;
   string swapped = _Symbol;
   StringReplace(swapped, "XAU", "XAG");
   candidates[1] = swapped;
   string swappedLower = _Symbol;
   StringReplace(swappedLower, "xau", "xag");
   candidates[2] = swappedLower;
   candidates[3] = "XAGUSD";
   for(int i = 0; i < 4; i++)
     {
      if(candidates[i] == _Symbol)
         continue;
      if(SymbolExists(candidates[i]))
         return candidates[i];
     }
   return "";
  }

//================= RISK GUARDS =================

void UpdateDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime day = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(day == g_dayStart)
      return;

   g_dayStart = day;
   g_dailyHalt = false;

   // Keep the start-of-day balance across EA restarts.
   if(UseGlobalVars() && GlobalVariableCheck(GvName("day")) && (datetime)GlobalVariableGet(GvName("day")) == day)
      g_dayStartBalance = GlobalVariableGet(GvName("daybal"));
   else
     {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(UseGlobalVars())
        {
         GlobalVariableSet(GvName("day"), (double)day);
         GlobalVariableSet(GvName("daybal"), g_dayStartBalance);
        }
     }
  }

double DailyLossLimitMoney()
  {
   return g_initialBalance * InpDailyLossStopPct / 100.0;
  }

double RiskMoney()
  {
   return g_initialBalance * InpRiskPercent / 100.0;
  }

void CheckGuards()
  {
   UpdateDay();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(!g_totalHalt && equity <= g_initialBalance * (1.0 - InpMaxLossStopPct / 100.0))
     {
      g_totalHalt = true;
      if(UseGlobalVars())
         GlobalVariableSet(GvName("halt"), 1.0);
      CloseAllPositions();
      DeleteAllPendingOrders();
      LogLine("MAX LOSS GUARD: equity " + DoubleToString(equity, 2) + " — EA stopped permanently");
     }

   if(!g_dailyHalt && g_dayStartBalance - equity >= DailyLossLimitMoney())
     {
      g_dailyHalt = true;
      CloseAllPositions();
      DeleteAllPendingOrders();
      LogLine("DAILY LOSS GUARD: equity " + DoubleToString(equity, 2) + " — trading stopped until tomorrow");
     }
  }

//================= FILTERS =================

bool SessionBlocked()
  {
   if(!InpUseSessionFilter || InpNoTradeStartHour == InpNoTradeEndHour)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpNoTradeStartHour < InpNoTradeEndHour)
      return (dt.hour >= InpNoTradeStartHour && dt.hour < InpNoTradeEndHour);
   return (dt.hour >= InpNoTradeStartHour || dt.hour < InpNoTradeEndHour);
  }

void LoadNews()
  {
   ArrayResize(g_newsTimes, 0);
   string currencies[];
   int count = StringSplit(InpNewsCurrencies, ',', currencies);
   datetime now = TimeTradeServer();
   for(int c = 0; c < count; c++)
     {
      string cur = currencies[c];
      StringTrimLeft(cur);
      StringTrimRight(cur);
      if(cur == "")
         continue;
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, now - 86400, now + 2 * 86400, NULL, cur))
         continue;
      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         int size = ArraySize(g_newsTimes);
         ArrayResize(g_newsTimes, size + 1);
         g_newsTimes[size] = values[i].time;
        }
     }
   g_newsLoaded = TimeCurrent();
  }

bool NewsBlocked()
  {
   if(!InpUseNewsFilter || MQLInfoInteger(MQL_TESTER))
      return false;
   if(TimeCurrent() - g_newsLoaded > 1800)
      LoadNews();
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - InpNewsMinutesBefore * 60 && now <= g_newsTimes[i] + InpNewsMinutesAfter * 60)
         return true;
     }
   return false;
  }

bool SpreadTooWide()
  {
   if(InpMaxSpread <= 0.0)
      return false;
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID) > InpMaxSpread);
  }

// Conditions that must hold for any order to exist (pending or new).
bool TradingWindowOpen()
  {
   return (!g_totalHalt && !g_dailyHalt && !SessionBlocked() && !NewsBlocked());
  }

//================= ORDERS =================

double CalcLots(const int direction, const double entry, const double stop)
  {
   double risk = RiskMoney();
   double loss = 0.0;
   ENUM_ORDER_TYPE type = direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, stop, loss) || loss >= 0.0)
     {
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
         return 0.0;
      loss = -MathAbs(entry - stop) / tickSize * tickValue;
     }
   double lossPerLot = MathAbs(loss);
   if(lossPerLot <= 0.0)
      return 0.0;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lots = MathFloor(risk / lossPerLot / step) * step;
   if(lots < minLot)
     {
      // Stop too wide for the allowed risk: optionally trade the minimum lot
      // if its real risk stays within 2x the target.
      if(InpMinLotFallback && minLot * lossPerLot <= 2.0 * RiskMoney())
         return minLot;
      return 0.0;
     }
   return NormalizeDouble(MathMin(lots, maxLot), 2);
  }

// Explains the lot size computation (for the log).
string LotDetail(const double entry, const double stop)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lossPerLot = tickSize > 0.0 ? MathAbs(entry - stop) / tickSize * tickValue : 0.0;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return StringFormat("balance=%.2f %s, risk=%.2f (%.2f%%), SL distance=%s, loss per 1 lot=%.2f, min lot=%.2f -> risk with min lot=%.2f",
                       AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoString(ACCOUNT_CURRENCY), RiskMoney(), InpRiskPercent,
                       DoubleToString(MathAbs(entry - stop), _Digits), lossPerLot, minLot, minLot * lossPerLot);
  }

// Room left before the daily guard, keeping the new trade's full risk inside it.
bool DailyRoomFor(const double riskMoney)
  {
   double lossSoFar = g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY);
   return (lossSoFar + riskMoney < DailyLossLimitMoney());
  }

// "" when a new trade is allowed, otherwise the reason.
string BlockReason()
  {
   if(g_totalHalt)
      return "max loss guard";
   if(g_dailyHalt)
      return "daily loss guard";
   if(SessionBlocked())
      return "rollover hours";
   if(NewsBlocked())
      return "news window";
   if(SpreadTooWide())
      return "spread too wide";
   if(CountPositions() >= InpMaxOpenPositions)
      return "max open positions";
   if(TradesToday() >= InpMaxTradesPerDay)
      return "max trades per day";
   if(!DailyRoomFor(RiskMoney()))
      return "not enough daily loss room";
   return "";
  }

bool CanOpenNewTrade()
  {
   string reason = BlockReason();
   if(reason != "" && reason != g_lastBlock)
      LogLine("BLOCKED: " + reason);
   if(reason != "")
      g_lastBlock = reason;
   return (reason == "");
  }

void DrawTrade(const TradeSetup &tr, const double entry, const double target)
  {
   if(!InpDrawSignals)
      return;
   datetime t0 = TimeCurrent();
   datetime t1 = t0 + 20 * PeriodSeconds(PERIOD_M5);
   string base = "SMTEA_" + IntegerToString(g_objCount++);
   color c = tr.direction > 0 ? clrLime : clrOrange;

   ObjectCreate(0, base + "_smt", OBJ_TREND, 0, tr.firstTime, tr.firstPrice, tr.secondTime, tr.secondPrice);
   ObjectSetInteger(0, base + "_smt", OBJPROP_COLOR, c);
   ObjectSetInteger(0, base + "_smt", OBJPROP_WIDTH, 2);

   string names[3] = {"_entry", "_sl", "_tp"};
   double prices[3];
   prices[0] = entry;
   prices[1] = tr.stop;
   prices[2] = target;
   color colors[3] = {clrYellow, clrRed, clrAqua};
   for(int i = 0; i < 3; i++)
     {
      ObjectCreate(0, base + names[i], OBJ_TREND, 0, t0, prices[i], t1, prices[i]);
      ObjectSetInteger(0, base + names[i], OBJPROP_COLOR, colors[i]);
      ObjectSetInteger(0, base + names[i], OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, base + names[i], OBJPROP_RAY_RIGHT, false);
     }
  }

bool OpenMarket(TradeSetup &tr)
  {
   if(!CanOpenNewTrade())
      return false;
   double price = tr.direction > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk = tr.direction * (price - tr.stop);
   if(risk <= 0.0)
      return false;
   double tp = RoundToTick(price + tr.direction * InpRiskReward * risk);
   double lots = CalcLots(tr.direction, price, tr.stop);
   if(lots <= 0.0)
     {
      if(!tr.lotWarned)
         LogLine("BLOCKED: lot size below minimum — " + LotDetail(price, tr.stop));
      tr.lotWarned = true;
      g_lastBlock = "lot size below minimum";
      return false;
     }
   bool ok = tr.direction > 0
             ? g_trade.Buy(lots, _Symbol, 0.0, tr.stop, tp, "SMT BUY")
             : g_trade.Sell(lots, _Symbol, 0.0, tr.stop, tp, "SMT SELL");
   LogLine(StringFormat("MARKET %s lots=%.2f req=%s sl=%s tp=%s spread=%d result=%u",
                        tr.direction > 0 ? "BUY" : "SELL", lots, DoubleToString(price, _Digits),
                        DoubleToString(tr.stop, _Digits), DoubleToString(tp, _Digits),
                        (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), g_trade.ResultRetcode()));
   if(ok)
     {
      g_orderCount++;
      DrawTrade(tr, price, tp);
     }
   return ok;
  }

// Places the breakout stop order of a setup when conditions allow it.
void PlaceStopOrder(TradeSetup &tr)
  {
   if(tr.traded || OrderIsPending(tr.ticket))
      return;
   if(!CanOpenNewTrade())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double entry = RoundToTick(tr.entry);
   double stop = RoundToTick(tr.stop);

   // Price already beyond the level (gap): enter at market, like the indicator's gap fill.
   bool beyond = tr.direction > 0 ? ask >= entry : bid <= entry;
   if(beyond)
     {
      if(OpenMarket(tr))
         tr.traded = true;
      return;
     }

   bool tooClose = tr.direction > 0 ? entry - ask < minDist : bid - entry < minDist;
   if(tooClose || MathAbs(entry - stop) < minDist)
      return; // retry on a later tick

   double risk = tr.direction * (entry - stop);
   double tp = RoundToTick(entry + tr.direction * InpRiskReward * risk);
   double lots = CalcLots(tr.direction, entry, stop);
   if(lots <= 0.0)
     {
      if(!tr.lotWarned)
         LogLine("BLOCKED: lot size below minimum — " + LotDetail(entry, stop));
      tr.lotWarned = true;
      g_lastBlock = "lot size below minimum";
      return;
     }

   bool ok = tr.direction > 0
             ? g_trade.BuyStop(lots, entry, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "SMT BUY")
             : g_trade.SellStop(lots, entry, _Symbol, stop, tp, ORDER_TIME_GTC, 0, "SMT SELL");
   LogLine(StringFormat("STOP ORDER %s lots=%.2f entry=%s sl=%s tp=%s result=%u",
                        tr.direction > 0 ? "BUY" : "SELL", lots, DoubleToString(entry, _Digits),
                        DoubleToString(stop, _Digits), DoubleToString(tp, _Digits), g_trade.ResultRetcode()));
   if(ok)
     {
      g_orderCount++;
      tr.ticket = g_trade.ResultOrder();
      DrawTrade(tr, entry, tp);
     }
  }

bool TicketUsedBySetup(const ulong ticket)
  {
   for(int n = 0; n < ArraySize(g_setups); n++)
      if(g_setups[n].ticket == ticket)
         return true;
   return false;
  }

// Called on every tick / timer in stop-order mode.
void ManageStopOrders()
  {
   // Remove pending orders whose setup no longer exists.
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == (long)InpMagic && OrderGetString(ORDER_SYMBOL) == _Symbol &&
         !TicketUsedBySetup(ticket))
         g_trade.OrderDelete(ticket);
     }

   bool windowOpen = TradingWindowOpen();
   bool positionsFull = CountPositions() >= InpMaxOpenPositions;

   for(int n = 0; n < ArraySize(g_setups); n++)
     {
      if(g_setups[n].ticket > 0 && !OrderSelect(g_setups[n].ticket))
        {
         // No longer pending: it was filled (or removed by the server).
         g_setups[n].traded = true;
         g_setups[n].ticket = 0;
         continue;
        }
      if(!windowOpen || positionsFull)
        {
         DeleteSetupOrder(g_setups[n]);
         continue;
        }
      PlaceStopOrder(g_setups[n]);
     }
  }

//================= STATE RESET =================

void ResetState(const bool live)
  {
   if(live)
      DeleteAllPendingOrders();
   ArrayResize(g_setups, 0);
   for(int i = 0; i < 4; i++)
      g_pendValid[i] = false;
   for(int j = 0; j < 2; j++)
      g_prevValid[j] = false;
  }

//================= CORE: ONE CLOSED M5 CANDLE =================

// s = shift of the closed Gold candle being processed (Pine offset k -> shift s + k).
void ProcessBar(const int s, const bool live)
  {
   double o0 = 0.0, h0 = 0.0, l0 = 0.0, sh0 = 0.0, sl0 = 0.0;
   bool goldOk = GoldBar(s, o0, h0, l0);
   bool aligned = goldOk && SilverAt(s, sh0, sl0);

   // ---------- PIVOTS ----------
   int L = InpLeftBars;
   int R = InpRightBars;
   bool enough = g_barIndex >= L + R;

   datetime pivotTime = iTime(_Symbol, PERIOD_M5, s + R);
   long pivotIndex = g_barIndex - R;

   double po = 0.0, gHighP = 0.0, gLowP = 0.0, sHighP = 0.0, sLowP = 0.0;
   bool goldPivotBar = GoldBar(s + R, po, gHighP, gLowP);
   bool silverPivotBar = SilverAt(s + R, sHighP, sLowP);

   bool goldLowPivot = enough && goldPivotBar;
   bool goldHighPivot = enough && goldPivotBar;
   bool silverLowPivot = enough && silverPivotBar;
   bool silverHighPivot = enough && silverPivotBar;

   if(enough)
     {
      for(int k = 0; k <= L + R; k++)
        {
         double ko = 0.0, gh = 0.0, gl = 0.0;
         if(!GoldBar(s + k, ko, gh, gl))
           {
            goldLowPivot = false;
            goldHighPivot = false;
           }
         double xh = 0.0, xl = 0.0;
         bool silverBarValid = SilverAt(s + k, xh, xl);
         if(!silverBarValid)
           {
            silverLowPivot = false;
            silverHighPivot = false;
           }
         if(k != R)
           {
            if(gl <= gLowP)
               goldLowPivot = false;
            if(gh >= gHighP)
               goldHighPivot = false;
            if(silverBarValid)
              {
               if(xl <= sLowP)
                  silverLowPivot = false;
               if(xh >= sHighP)
                  silverHighPivot = false;
              }
           }
        }
     }

   if(!aligned)
     {
      ResetState(live);
      g_barIndex++;
      return;
     }

   // ---------- PROCESS EXISTING SETUPS ----------
   int n = 0;
   while(n < ArraySize(g_setups))
     {
      TradeSetup tr = g_setups[n];

      bool broke = tr.direction > 0 ? h0 > tr.entry : l0 < tr.entry;
      bool newGoldSweep = tr.direction > 0 ? l0 < tr.firstGold : h0 > tr.firstGold;
      bool newSilverSweep = tr.direction > 0 ? sl0 < tr.firstSilver : sh0 > tr.firstSilver;

      tr.goldSwept = tr.goldSwept || newGoldSweep;
      tr.silverSwept = tr.silverSwept || newSilverSweep;

      bool stopped = tr.direction > 0 ? l0 <= tr.stop : h0 >= tr.stop;
      bool invalid = stopped || (tr.goldSwept && tr.silverSwept);

      if(invalid)
        {
         if(live)
            DeleteSetupOrder(tr);
         RemoveSetup(n);
        }
      else if(broke)
        {
         double entryPrice = tr.direction > 0 ? MathMax(o0, tr.entry) : MathMin(o0, tr.entry);
         double risk = tr.direction * (entryPrice - tr.stop);
         if(risk > 0.0)
           {
            g_signalCount++;
            if(live)
              {
               LogLine(StringFormat("SIGNAL %s est.entry=%s sl=%s", tr.direction > 0 ? "BUY" : "SELL",
                                    DoubleToString(entryPrice, _Digits), DoubleToString(tr.stop, _Digits)));
               if(InpEntryMode == ENTRY_MARKET_ON_CLOSE && s == 1)
                  OpenMarket(tr);
              }
           }
         // Stop-order mode: the order was triggered by the breakout; drop any leftover.
         if(live)
            DeleteSetupOrder(tr);
         RemoveSetup(n);
        }
      else
        {
         g_setups[n] = tr;
         n++;
        }
     }

   // ---------- STORE NEW PIVOTS ----------
   if(goldLowPivot)
     {
      g_pendValid[0] = true;
      g_pendTime[0] = pivotTime;
      g_pendIndex[0] = pivotIndex;
      g_pendPrice[0] = gLowP;
     }
   if(silverLowPivot)
     {
      g_pendValid[1] = true;
      g_pendTime[1] = pivotTime;
      g_pendIndex[1] = pivotIndex;
      g_pendPrice[1] = sLowP;
     }
   if(goldHighPivot)
     {
      g_pendValid[2] = true;
      g_pendTime[2] = pivotTime;
      g_pendIndex[2] = pivotIndex;
      g_pendPrice[2] = gHighP;
     }
   if(silverHighPivot)
     {
      g_pendValid[3] = true;
      g_pendTime[3] = pivotTime;
      g_pendIndex[3] = pivotIndex;
      g_pendPrice[3] = sHighP;
     }

   // ---------- MATCH LOWS AND HIGHS ----------
   for(int sideIndex = 0; sideIndex <= 1; sideIndex++)
     {
      int goldSlot = sideIndex * 2;
      int silverSlot = goldSlot + 1;
      int direction = sideIndex == 0 ? 1 : -1;

      if(!g_pendValid[goldSlot] || !g_pendValid[silverSlot])
         continue;

      datetime gt = g_pendTime[goldSlot];
      datetime st = g_pendTime[silverSlot];
      bool closeEnough = MathAbs((long)gt - (long)st) <= (long)InpPairTolerance * PeriodSeconds(PERIOD_M5);

      if(!closeEnough)
        {
         // Discard the older unmatched pivot.
         if(gt < st)
            g_pendValid[goldSlot] = false;
         else
            g_pendValid[silverSlot] = false;
         continue;
        }

      long gi = g_pendIndex[goldSlot];
      long si = g_pendIndex[silverSlot];
      double gp = g_pendPrice[goldSlot];
      double sp = g_pendPrice[silverSlot];

      bool ordered = g_prevValid[sideIndex] && gt > g_prevGT[sideIndex] && st > g_prevST[sideIndex];

      if(ordered)
        {
         datetime oldGT = g_prevGT[sideIndex];
         long oldGI = g_prevGI[sideIndex];
         double oldGP = g_prevGP[sideIndex];
         double oldSP = g_prevSP[sideIndex];

         long gap = gi - oldGI;
         int olderOffset = (int)(g_barIndex - oldGI);
         int newerOffset = (int)(g_barIndex - gi);
         int earliestOffset = (int)(g_barIndex - MathMin(gi, si));

         bool gapValid = gap >= 2 && gap <= InpMaxGap && olderOffset < 5000 && earliestOffset < 5000;
         bool divergence = (gp > oldGP && sp < oldSP) || (gp < oldGP && sp > oldSP);

         if(gapValid && divergence)
           {
            // Extreme strictly between the two Gold pivot candles.
            bool haveEntry = false;
            double entryLevel = 0.0;
            for(int k = newerOffset + 1; k <= olderOffset - 1; k++)
              {
               double bo = 0.0, bh = 0.0, bl = 0.0;
               if(!GoldBar(s + k, bo, bh, bl))
                  continue;
               double value = direction > 0 ? bh : bl;
               if(!haveEntry)
                 {
                  entryLevel = value;
                  haveEntry = true;
                 }
               else
                  entryLevel = direction > 0 ? MathMax(entryLevel, value) : MathMin(entryLevel, value);
              }

            double rawStop = direction > 0 ? MathMin(oldGP, gp) - g_slBuffer : MathMax(oldGP, gp) + g_slBuffer;
            double stopLevel = RoundToTick(rawStop);

            bool gs = direction > 0 ? gp < oldGP : gp > oldGP;
            bool ss = direction > 0 ? sp < oldSP : sp > oldSP;

            bool valid = haveEntry && direction * (entryLevel - stopLevel) > 0.0;

            // Reject breaks / invalidation before confirmation.
            for(int k = 0; k <= earliestOffset && valid; k++)
              {
               double bo = 0.0, bh = 0.0, bl = 0.0, xh = 0.0, xl = 0.0;
               if(!GoldBar(s + k, bo, bh, bl) || !SilverAt(s + k, xh, xl))
                 {
                  valid = false;
                  break;
                 }
               if(direction > 0)
                 {
                  gs = gs || bl < oldGP;
                  ss = ss || xl < oldSP;
                  if(bh > entryLevel || bl < rawStop)
                     valid = false;
                  if(k < newerOffset && bl <= rawStop)
                     valid = false;
                 }
               else
                 {
                  gs = gs || bh > oldGP;
                  ss = ss || xh > oldSP;
                  if(bl < entryLevel || bh > rawStop)
                     valid = false;
                  if(k < newerOffset && bh >= rawStop)
                     valid = false;
                 }
              }

            if(valid && !(gs && ss))
              {
               TradeSetup ns;
               ns.direction = direction;
               ns.firstTime = oldGT;
               ns.secondTime = gt;
               ns.firstPrice = oldGP;
               ns.secondPrice = gp;
               ns.entry = entryLevel;
               ns.stop = stopLevel;
               ns.firstGold = oldGP;
               ns.firstSilver = oldSP;
               ns.goldSwept = gs;
               ns.silverSwept = ss;
               ns.ticket = 0;
               ns.traded = false;
               ns.lotWarned = false;
               int size = ArraySize(g_setups);
               ArrayResize(g_setups, size + 1);
               g_setups[size] = ns;
               g_setupCount++;
               if(live)
                  LogLine(StringFormat("SETUP %s entry=%s sl=%s", direction > 0 ? "BUY" : "SELL",
                                       DoubleToString(entryLevel, _Digits), DoubleToString(stopLevel, _Digits)));
              }
           }
        }

      // Store the latest matched pair.
      g_prevValid[sideIndex] = true;
      g_prevGT[sideIndex] = gt;
      g_prevST[sideIndex] = st;
      g_prevGI[sideIndex] = gi;
      g_prevSI[sideIndex] = si;
      g_prevGP[sideIndex] = gp;
      g_prevSP[sideIndex] = sp;

      // Consume both matched pivots.
      g_pendValid[goldSlot] = false;
      g_pendValid[silverSlot] = false;
     }

   g_barIndex++;
  }

//================= ENGINE =================

bool SilverReady()
  {
   return (bool)SeriesInfoInteger(g_silver, PERIOD_M5, SERIES_SYNCHRONIZED) &&
          Bars(g_silver, PERIOD_M5) > 0;
  }

// Warm up the state on history (no trading), like the indicator's history pass.
bool WarmUp()
  {
   if(!SilverReady())
      return false;
   int available = Bars(_Symbol, PERIOD_M5) - 1;
   int start = MathMin(InpHistoryBars, available - (InpLeftBars + InpRightBars) - 1);
   if(start < 10)
      return false;

   ResetState(false);
   g_barIndex = 0;
   for(int s = start; s >= 1; s--)
      ProcessBar(s, false);
   g_lastProcessed = iTime(_Symbol, PERIOD_M5, 1);
   g_ready = true;
   LogLine(StringFormat("READY: warm-up on %d bars, %d signals in history, %d active setups",
                        start, g_signalCount, ArraySize(g_setups)));
   return true;
  }

void Engine()
  {
   if(!g_ready)
     {
      static datetime warned = 0;
      if(!WarmUp() && TimeCurrent() - warned > 3600)
        {
         warned = TimeCurrent();
         Print("SMT EA: waiting for history — need ", g_silver, " M5 and ", _Symbol,
               " M5 bars (download them in the History Center).");
        }
      return;
     }

   CheckGuards();

   datetime lastClosed = iTime(_Symbol, PERIOD_M5, 1);
   if(lastClosed > g_lastProcessed)
     {
      // Wait until Silver has printed the candle after the one we process (max 60 s).
      datetime silverLast = iTime(g_silver, PERIOD_M5, 0);
      if(silverLast <= lastClosed)
        {
         if(g_waitSince == 0)
            g_waitSince = TimeCurrent();
         if(TimeCurrent() - g_waitSince < 60)
            return;
        }
      g_waitSince = 0;

      int from = iBarShift(_Symbol, PERIOD_M5, g_lastProcessed, true);
      if(from < 0)
        {
         g_ready = false; // history changed: rebuild
         return;
        }
      for(int s = from - 1; s >= 1; s--)
         ProcessBar(s, true);
      g_lastProcessed = lastClosed;
     }

   if(InpEntryMode == ENTRY_STOP_ORDER)
      ManageStopOrders();
  }

//================= EVENTS =================

int OnInit()
  {
   if(_Period != PERIOD_M5)
     {
      Print("SMT EA: INIT FAILED — attach it to a Gold M5 chart.");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_silver = ResolveSilverSymbol();
   if(g_silver == "" || !SymbolSelect(g_silver, true))
     {
      Print("SMT EA: INIT FAILED — silver symbol not found. Set InpSilverSymbol to the exact name (e.g. XAGUSDm).");
      return INIT_PARAMETERS_INCORRECT;
     }
   Print("SMT EA: using silver symbol ", g_silver);
   // The initial balance is printed so a wrong stored value is easy to spot.

   double pointSize = InpPointSize > 0.0 ? InpPointSize : _Point;
   g_slBuffer = InpBufferPoints * pointSize;

   if(InpInitialBalance > 0.0)
      g_initialBalance = InpInitialBalance;
   else if(UseGlobalVars() && GlobalVariableCheck(GvName("init")))
      g_initialBalance = GlobalVariableGet(GvName("init"));
   else
     {
      g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(UseGlobalVars())
         GlobalVariableSet(GvName("init"), g_initialBalance);
     }

   Print(StringFormat("SMT EA: initial balance %.2f -> risk per trade %.2f, daily stop %.2f, max stop %.2f",
                      g_initialBalance, RiskMoney(), DailyLossLimitMoney(), g_initialBalance * InpMaxLossStopPct / 100.0));
   g_totalHalt = UseGlobalVars() && GlobalVariableCheck(GvName("halt")) && GlobalVariableGet(GvName("halt")) > 0.0;
   if(g_totalHalt)
      LogLine("EA is halted (max loss guard hit earlier). Delete global variable " + GvName("halt") + " to reset.");

   // Setups are rebuilt from history, so leftover orders are removed.
   DeleteAllPendingOrders();
   UpdateDay();
   EventSetTimer(1);
   WarmUp();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Print(StringFormat("SMT EA SUMMARY: silver=%s ready=%s setups=%d signals=%d orders=%d last block=%s",
                      g_silver, g_ready ? "yes" : "NO (missing history)", g_setupCount, g_signalCount,
                      g_orderCount, g_lastBlock == "" ? "-" : g_lastBlock));
   EventKillTimer();
   DeleteAllPendingOrders();
  }

void OnTick()
  {
   Engine();
  }

void OnTimer()
  {
   Engine();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !InpLogToFile)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic)
      return;

   double requested = 0.0;
   if(HistoryOrderSelect(trans.order))
      requested = HistoryOrderGetDouble(trans.order, ORDER_PRICE_OPEN);

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   LogLine(StringFormat("DEAL %s price=%s requested=%s volume=%.2f profit=%.2f spread=%d",
                        entry == DEAL_ENTRY_IN ? "IN" : "OUT",
                        DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), _Digits),
                        DoubleToString(requested, _Digits),
                        HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                        HistoryDealGetDouble(trans.deal, DEAL_PROFIT),
                        (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
  }
//+------------------------------------------------------------------+
