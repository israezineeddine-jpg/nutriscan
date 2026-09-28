//+------------------------------------------------------------------+
//|                                          SMT_Gold_Silver_EA.mq4  |
//|  MQL4 port of the TradingView indicator "SMT — ENTRY SL TP"      |
//|  Gold (chart symbol, M5) vs Silver SMT divergence, breakout      |
//|  entry, SL beyond the swept swing, TP at a fixed R multiple.     |
//|  Adds prop-firm (FTMO) protections: daily / max loss guards,     |
//|  spread, session and manual news filters, execution log.         |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Gold/Silver SMT divergence EA (port of 'SMT — ENTRY SL TP')"
#property strict

enum ENUM_SMT_ENTRY_MODE
  {
   ENTRY_STOP_ORDER = 0,      // Stop order at the breakout level
   ENTRY_MARKET_ON_CLOSE = 1  // Market order when the breakout candle closes
  };

//================= INPUTS =================

input string InpSectionSmt     = "===== SMT =====";        // -----
input string InpSilverSymbol   = ""; // Silver symbol (empty = auto, e.g. XAUUSDm -> XAGUSDm)
input int    InpLeftBars       = 2;        // Pivot left bars
input int    InpRightBars      = 2;        // Pivot right bars
input int    InpPairTolerance  = 3;        // Pair tolerance — M5 intervals
input int    InpMaxGap         = 200;      // Maximum swing gap
input int    InpHistoryBars    = 3000;     // History bars used to warm up
input double InpBufferPoints   = 10.0;     // SL buffer — points
input double InpPointSize      = 0.0;      // Point size — 0 = symbol point

input string InpSectionEntry   = "===== Entry / exit ====="; // -----
input ENUM_SMT_ENTRY_MODE InpEntryMode = ENTRY_STOP_ORDER; // Entry mode
input double InpRiskReward     = 1.0;      // Take profit in R (indicator = 1.0)

input string InpSectionRisk    = "===== Risk (prop firm) ====="; // -----
input double InpRiskPercent       = 0.5;   // Risk per trade, % of initial balance
input double InpInitialBalance    = 0.0;   // Initial account balance (0 = auto)
input double InpDailyLossStopPct  = 4.0;   // Stop the day at this loss % (FTMO limit = 5)
input double InpMaxLossStopPct    = 9.0;   // Stop the EA at this total loss % (FTMO limit = 10)
input int    InpMaxTradesPerDay   = 3;     // Max trades per day
input int    InpMaxOpenPositions  = 1;     // Max open positions

input string InpSectionFilters = "===== Filters ====="; // -----
input int    InpMaxSpreadPoints   = 50;    // Max spread (points), 0 = off
input bool   InpUseSessionFilter  = true;  // Block trading during rollover hours
input int    InpNoTradeStartHour  = 23;    // No-trade start hour (server time)
input int    InpNoTradeEndHour    = 1;     // No-trade end hour (server time)
input string InpNewsTimes         = "";    // News times, server time "yyyy.mm.dd hh:mi;..."
input int    InpNewsMinutesBefore = 5;     // Minutes before news
input int    InpNewsMinutesAfter  = 5;     // Minutes after news

input string InpSectionMisc    = "===== Misc ====="; // -----
input int    InpMagic             = 20260928; // Magic number
input int    InpSlippagePoints    = 30;       // Max slippage (points)
input bool   InpDrawSignals       = true;     // Draw entry / SL / TP on chart
input bool   InpLogToFile         = true;     // Write execution log (MQL4/Files)

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
   int      ticket;        // pending stop order (0 = none)
   bool     traded;        // order already filled
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

string   g_silver        = "";    // resolved Silver symbol
int      g_signalCount   = 0;
int      g_objCount      = 0;

//================= HELPERS =================

string GvName(const string key)
  {
   return "SMTEA_" + key + "_" + IntegerToString(AccountNumber()) + "_" + IntegerToString(InpMagic);
  }

double RoundToTick(const double price)
  {
   double tick = MarketInfo(_Symbol, MODE_TICKSIZE);
   if(tick <= 0.0)
      tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

bool GoldBar(const int shift, double &o, double &h, double &l)
  {
   if(shift < 0 || shift >= iBars(_Symbol, PERIOD_M5))
      return false;
   o = iOpen(_Symbol, PERIOD_M5, shift);
   h = iHigh(_Symbol, PERIOD_M5, shift);
   l = iLow(_Symbol, PERIOD_M5, shift);
   return (o > 0.0 && h > 0.0 && l > 0.0);
  }

// Silver candle with exactly the same open time as the Gold candle at goldShift.
bool SilverAt(const int goldShift, double &h, double &l)
  {
   if(goldShift < 0 || goldShift >= iBars(_Symbol, PERIOD_M5))
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

bool IsOurOrder()
  {
   return (OrderMagicNumber() == InpMagic && OrderSymbol() == _Symbol);
  }

bool IsPendingType(const int type)
  {
   return (type == OP_BUYSTOP || type == OP_SELLSTOP || type == OP_BUYLIMIT || type == OP_SELLLIMIT);
  }

// 1 = still pending, 2 = filled (market order), 0 = gone (deleted / closed without fill)
int OrderState(const int ticket)
  {
   if(ticket <= 0 || !OrderSelect(ticket, SELECT_BY_TICKET))
      return 0;
   if(IsPendingType(OrderType()))
      return OrderCloseTime() == 0 ? 1 : 0;
   return 2;
  }

bool OrderIsPending(const int ticket)
  {
   return (OrderState(ticket) == 1);
  }

// Removes the pending order of a setup. If the order became a trade, mark it.
void DeleteSetupOrder(TradeSetup &tr)
  {
   if(tr.ticket == 0)
      return;
   int state = OrderState(tr.ticket);
   if(state == 1)
     {
      if(OrderDelete(tr.ticket))
         tr.ticket = 0; // otherwise retry on the next tick
      return;
     }
   if(state == 2)
      tr.traded = true;
   tr.ticket = 0;
  }

int CountPositions()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(IsOurOrder() && (OrderType() == OP_BUY || OrderType() == OP_SELL))
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
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(IsOurOrder() && IsPendingType(OrderType()))
        {
         if(!OrderDelete(OrderTicket()))
            Print("OrderDelete failed: ", GetLastError());
        }
     }
  }

void CloseAllPositions()
  {
   RefreshRates();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!IsOurOrder())
         continue;
      if(OrderType() == OP_BUY)
        {
         if(!OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippagePoints, clrNONE))
            Print("OrderClose failed: ", GetLastError());
        }
      else if(OrderType() == OP_SELL)
        {
         if(!OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippagePoints, clrNONE))
            Print("OrderClose failed: ", GetLastError());
        }
     }
  }

int TradesToday()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(IsOurOrder() && (OrderType() == OP_BUY || OrderType() == OP_SELL) && OrderOpenTime() >= g_dayStart)
         count++;
     }
   for(int j = OrdersHistoryTotal() - 1; j >= 0; j--)
     {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(IsOurOrder() && (OrderType() == OP_BUY || OrderType() == OP_SELL) && OrderOpenTime() >= g_dayStart)
         count++;
     }
   return count;
  }

bool SymbolExists(const string sym)
  {
   if(sym == "")
      return false;
   ResetLastError();
   double pt = MarketInfo(sym, MODE_POINT);
   return (pt > 0.0 && GetLastError() != ERR_UNKNOWN_SYMBOL);
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
   datetime now = TimeCurrent();
   datetime day = now - (TimeHour(now) * 3600 + TimeMinute(now) * 60 + TimeSeconds(now));
   if(day == g_dayStart)
      return;

   g_dayStart = day;
   g_dailyHalt = false;

   // Keep the start-of-day balance across EA restarts.
   if(GlobalVariableCheck(GvName("day")) && (datetime)GlobalVariableGet(GvName("day")) == day)
      g_dayStartBalance = GlobalVariableGet(GvName("daybal"));
   else
     {
      g_dayStartBalance = AccountBalance();
      GlobalVariableSet(GvName("day"), (double)day);
      GlobalVariableSet(GvName("daybal"), g_dayStartBalance);
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
   double equity = AccountEquity();

   if(!g_totalHalt && equity <= g_initialBalance * (1.0 - InpMaxLossStopPct / 100.0))
     {
      g_totalHalt = true;
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
   int hour = TimeHour(TimeCurrent());
   if(InpNoTradeStartHour < InpNoTradeEndHour)
      return (hour >= InpNoTradeStartHour && hour < InpNoTradeEndHour);
   return (hour >= InpNoTradeStartHour || hour < InpNoTradeEndHour);
  }

// MT4 has no built-in economic calendar: news times are typed in the inputs.
void LoadNews()
  {
   ArrayResize(g_newsTimes, 0);
   string items[];
   int count = StringSplit(InpNewsTimes, ';', items);
   for(int i = 0; i < count; i++)
     {
      string item = StringTrimRight(StringTrimLeft(items[i]));
      if(item == "")
         continue;
      datetime t = StringToTime(item);
      if(t <= 0)
        {
         Print("Invalid news time ignored: ", item);
         continue;
        }
      int size = ArraySize(g_newsTimes);
      ArrayResize(g_newsTimes, size + 1);
      g_newsTimes[size] = t;
     }
  }

bool NewsBlocked()
  {
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - InpNewsMinutesBefore * 60 && now <= g_newsTimes[i] + InpNewsMinutesAfter * 60)
         return true;
     }
   return false;
  }

bool SpreadTooWide()
  {
   if(InpMaxSpreadPoints <= 0)
      return false;
   return (MarketInfo(_Symbol, MODE_SPREAD) > InpMaxSpreadPoints);
  }

// Conditions that must hold for any order to exist (pending or new).
bool TradingWindowOpen()
  {
   return (!g_totalHalt && !g_dailyHalt && !SessionBlocked() && !NewsBlocked());
  }

//================= ORDERS =================

double CalcLots(const double entry, const double stop)
  {
   double tickSize = MarketInfo(_Symbol, MODE_TICKSIZE);
   double tickValue = MarketInfo(_Symbol, MODE_TICKVALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   double lossPerLot = MathAbs(entry - stop) / tickSize * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double step = MarketInfo(_Symbol, MODE_LOTSTEP);
   double minLot = MarketInfo(_Symbol, MODE_MINLOT);
   double maxLot = MarketInfo(_Symbol, MODE_MAXLOT);
   if(step <= 0.0)
      step = 0.01;
   double lots = MathFloor(RiskMoney() / lossPerLot / step) * step;
   if(lots < minLot)
      return 0.0; // stop too wide for the allowed risk
   return NormalizeDouble(MathMin(lots, maxLot), 2);
  }

// Room left before the daily guard, keeping the new trade's full risk inside it.
bool DailyRoomFor(const double riskMoney)
  {
   double lossSoFar = g_dayStartBalance - AccountEquity();
   return (lossSoFar + riskMoney < DailyLossLimitMoney());
  }

bool CanOpenNewTrade()
  {
   if(!TradingWindowOpen() || SpreadTooWide())
      return false;
   if(CountPositions() >= InpMaxOpenPositions)
      return false;
   if(TradesToday() >= InpMaxTradesPerDay)
      return false;
   return DailyRoomFor(RiskMoney());
  }

void DrawTrade(const TradeSetup &tr, const double entry, const double target)
  {
   if(!InpDrawSignals)
      return;
   datetime t0 = TimeCurrent();
   datetime t1 = t0 + 20 * 300;
   string base = "SMTEA_" + IntegerToString(g_objCount++);
   color c = tr.direction > 0 ? clrLime : clrOrange;

   ObjectCreate(0, base + "_smt", OBJ_TREND, 0, tr.firstTime, tr.firstPrice, tr.secondTime, tr.secondPrice);
   ObjectSetInteger(0, base + "_smt", OBJPROP_COLOR, c);
   ObjectSetInteger(0, base + "_smt", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, base + "_smt", OBJPROP_RAY, false);

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
      ObjectSetInteger(0, base + names[i], OBJPROP_RAY, false);
     }
  }

bool OpenMarket(const TradeSetup &tr)
  {
   if(!CanOpenNewTrade())
      return false;
   RefreshRates();
   double price = tr.direction > 0 ? Ask : Bid;
   double risk = tr.direction * (price - tr.stop);
   if(risk <= 0.0)
      return false;
   double stop = RoundToTick(tr.stop);
   double tp = RoundToTick(price + tr.direction * InpRiskReward * risk);
   double lots = CalcLots(price, stop);
   if(lots <= 0.0)
     {
      LogLine("SKIP: stop too wide for risk, entry " + DoubleToString(price, _Digits));
      return false;
     }
   int type = tr.direction > 0 ? OP_BUY : OP_SELL;
   int ticket = OrderSend(_Symbol, type, lots, price, InpSlippagePoints, stop, tp,
                          tr.direction > 0 ? "SMT BUY" : "SMT SELL", InpMagic, 0,
                          tr.direction > 0 ? clrLime : clrOrange);
   int err = ticket < 0 ? GetLastError() : 0;
   double filled = 0.0;
   if(ticket > 0 && OrderSelect(ticket, SELECT_BY_TICKET))
      filled = OrderOpenPrice();
   LogLine(StringFormat("MARKET %s lots=%.2f req=%s filled=%s sl=%s tp=%s spread=%d ticket=%d err=%d",
                        tr.direction > 0 ? "BUY" : "SELL", lots, DoubleToString(price, _Digits),
                        DoubleToString(filled, _Digits), DoubleToString(stop, _Digits),
                        DoubleToString(tp, _Digits), (int)MarketInfo(_Symbol, MODE_SPREAD), ticket, err));
   if(ticket > 0)
      DrawTrade(tr, price, tp);
   return (ticket > 0);
  }

// Places the breakout stop order of a setup when conditions allow it.
void PlaceStopOrder(TradeSetup &tr)
  {
   if(tr.traded || OrderIsPending(tr.ticket))
      return;
   if(!CanOpenNewTrade())
      return;

   RefreshRates();
   double minDist = MarketInfo(_Symbol, MODE_STOPLEVEL) * _Point;
   double entry = RoundToTick(tr.entry);
   double stop = RoundToTick(tr.stop);

   // Price already beyond the level (gap): enter at market, like the indicator's gap fill.
   bool beyond = tr.direction > 0 ? Ask >= entry : Bid <= entry;
   if(beyond)
     {
      if(OpenMarket(tr))
         tr.traded = true;
      return;
     }

   bool tooClose = tr.direction > 0 ? entry - Ask < minDist : Bid - entry < minDist;
   if(tooClose || MathAbs(entry - stop) < minDist)
      return; // retry on a later tick

   double risk = tr.direction * (entry - stop);
   double tp = RoundToTick(entry + tr.direction * InpRiskReward * risk);
   double lots = CalcLots(entry, stop);
   if(lots <= 0.0)
      return;

   int type = tr.direction > 0 ? OP_BUYSTOP : OP_SELLSTOP;
   int ticket = OrderSend(_Symbol, type, lots, entry, InpSlippagePoints, stop, tp,
                          tr.direction > 0 ? "SMT BUY" : "SMT SELL", InpMagic, 0,
                          tr.direction > 0 ? clrLime : clrOrange);
   int err = ticket < 0 ? GetLastError() : 0;
   LogLine(StringFormat("STOP ORDER %s lots=%.2f entry=%s sl=%s tp=%s ticket=%d err=%d",
                        tr.direction > 0 ? "BUY" : "SELL", lots, DoubleToString(entry, _Digits),
                        DoubleToString(stop, _Digits), DoubleToString(tp, _Digits), ticket, err));
   if(ticket > 0)
     {
      tr.ticket = ticket;
      DrawTrade(tr, entry, tp);
     }
  }

bool TicketUsedBySetup(const int ticket)
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
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(IsOurOrder() && IsPendingType(OrderType()) && !TicketUsedBySetup(OrderTicket()))
        {
         if(!OrderDelete(OrderTicket()))
            Print("OrderDelete failed: ", GetLastError());
        }
     }

   bool windowOpen = TradingWindowOpen();
   bool positionsFull = CountPositions() >= InpMaxOpenPositions;

   for(int n = 0; n < ArraySize(g_setups); n++)
     {
      if(g_setups[n].ticket > 0 && !OrderIsPending(g_setups[n].ticket))
        {
         // No longer pending: filled (logged) or removed by the server.
         if(OrderState(g_setups[n].ticket) == 2)
           {
            g_setups[n].traded = true;
            LogLine(StringFormat("FILLED ticket=%d requested=%s filled=%s spread=%d", g_setups[n].ticket,
                                 DoubleToString(RoundToTick(g_setups[n].entry), _Digits),
                                 DoubleToString(OrderOpenPrice(), _Digits), (int)MarketInfo(_Symbol, MODE_SPREAD)));
           }
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
      long timeDiff = (long)gt - (long)st;
      if(timeDiff < 0)
         timeDiff = -timeDiff;
      bool closeEnough = timeDiff <= (long)InpPairTolerance * 300;

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
         int earliestOffset = (int)(g_barIndex - (gi < si ? gi : si));

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
               int size = ArraySize(g_setups);
               ArrayResize(g_setups, size + 1);
               g_setups[size] = ns;
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
   ResetLastError();
   int bars = iBars(g_silver, PERIOD_M5);
   int err = GetLastError();
   return (bars > 100 && err != ERR_HISTORY_WILL_UPDATED);
  }

// Warm up the state on history (no trading), like the indicator's history pass.
bool WarmUp()
  {
   if(!SilverReady())
      return false;
   int available = iBars(_Symbol, PERIOD_M5) - 1;
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
      if(!IsTesting())
        {
         datetime silverLast = iTime(g_silver, PERIOD_M5, 0);
         if(silverLast <= lastClosed)
           {
            if(g_waitSince == 0)
               g_waitSince = TimeCurrent();
            if(TimeCurrent() - g_waitSince < 60)
               return;
           }
         g_waitSince = 0;
        }

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
      Print("SMT EA: INIT FAILED — attach it to a Gold M5 chart (current period: ", _Period, " min).");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_silver = ResolveSilverSymbol();
   if(g_silver == "")
     {
      Print("SMT EA: INIT FAILED — silver symbol not found. Set InpSilverSymbol to the exact name (e.g. XAGUSDm).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!IsTesting())
      SymbolSelect(g_silver, true);
   iBars(g_silver, PERIOD_M5); // triggers the Silver history download
   Print("SMT EA: using silver symbol ", g_silver);

   double pointSize = InpPointSize > 0.0 ? InpPointSize : _Point;
   g_slBuffer = InpBufferPoints * pointSize;

   if(InpInitialBalance > 0.0)
      g_initialBalance = InpInitialBalance;
   else if(GlobalVariableCheck(GvName("init")))
      g_initialBalance = GlobalVariableGet(GvName("init"));
   else
     {
      g_initialBalance = AccountBalance();
      GlobalVariableSet(GvName("init"), g_initialBalance);
     }

   g_totalHalt = GlobalVariableCheck(GvName("halt")) && GlobalVariableGet(GvName("halt")) > 0.0;
   if(g_totalHalt)
      LogLine("EA is halted (max loss guard hit earlier). Delete global variable " + GvName("halt") + " to reset.");

   LoadNews();
   // Setups are rebuilt from history, so leftover orders are removed.
   DeleteAllPendingOrders();
   UpdateDay();
   EventSetTimer(1);
   WarmUp();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
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
//+------------------------------------------------------------------+
