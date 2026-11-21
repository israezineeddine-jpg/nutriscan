//+------------------------------------------------------------------+
//| SilverBullet_XAU.mq5 - ICT Silver Bullet (sweep + FVG)           |
//| (copie de l'EA fourni, tel quel, pour la reference du backtest)  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

input double RiskPercent      = 0.5;   // Risque par trade (% du solde)
input double RR               = 2.0;   // Ratio TP/SL
input int    ServerMinusNY    = 7;     // Heure serveur - heure New York
input int    LiquidityBars    = 20;    // Bougies pour la liquidité précédente
input int    SweepBars        = 10;    // Bougies récentes où chercher le sweep
input double MinFVGPoints     = 50;    // Taille minimale du FVG (points)
input double SLBufferPoints   = 20;    // Marge derrière la mèche du sweep
input bool   UseLondon        = true;  // Fenêtre 3h-4h NY
input bool   UseNYAM          = true;  // Fenêtre 10h-11h NY
input bool   UseNYPM          = true;  // Fenêtre 14h-15h NY
input double MaxDailyLossPct  = 4.0;   // Coupe-circuit journalier (% equity)
input long   Magic            = 20261121;

datetime lastBar = 0;
long     lastBuyWin = -1, lastSellWin = -1;
int      curDay = -1;
double   dayStartBal = 0;
bool     dayStopped = false;

int WindowIndex(datetime t)
{
   MqlDateTime s; TimeToStruct(t, s);
   int h = (s.hour - ServerMinusNY + 24) % 24;
   if(UseLondon && h == 3)  return 1;
   if(UseNYAM   && h == 10) return 2;
   if(UseNYPM   && h == 14) return 3;
   return 0;
}

double CalcLots(double entry, double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double dist      = MathAbs(entry - sl);
   if(dist <= 0 || tickVal <= 0 || tickSize <= 0) return 0;
   double lots = riskMoney / (dist / tickSize * tickVal);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0;
   return MathMin(lots, maxL);
}

bool HasPositionOrOrder()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) return true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(OrderSelect(tk) && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == Magic) return true;
   }
   return false;
}

void DeletePendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(OrderSelect(tk) && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == Magic)
         trade.OrderDelete(tk);
   }
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic)
         trade.PositionClose(tk);
   }
   DeletePendings();
}

int OnInit() { trade.SetExpertMagicNumber(Magic); return INIT_SUCCEEDED; }

void OnTick()
{
   // --- Coupe-circuit journalier
   MqlDateTime s; TimeToStruct(TimeCurrent(), s);
   if(s.day_of_year != curDay)
   {
      curDay = s.day_of_year;
      dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      dayStopped = false;
   }
   if(!dayStopped && AccountInfoDouble(ACCOUNT_EQUITY) <= dayStartBal * (1.0 - MaxDailyLossPct / 100.0))
   {
      CloseAll();
      dayStopped = true;
   }
   if(dayStopped) return;

   // --- Annuler les ordres en attente hors fenêtre
   if(WindowIndex(TimeCurrent()) == 0) DeletePendings();

   // --- Une seule analyse par nouvelle bougie
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == lastBar) return;
   lastBar = bt;

   int idx = WindowIndex(bt);
   if(idx == 0 || HasPositionOrOrder()) return;

   long     wid  = (long)(bt / 86400) * 10 + idx;
   datetime wEnd = bt - (bt % 3600) + 3600;

   double h1 = iHigh(_Symbol, _Period, 1), l1 = iLow(_Symbol, _Period, 1);
   double h3 = iHigh(_Symbol, _Period, 3), l3 = iLow(_Symbol, _Period, 3);
   double minGap = MinFVGPoints * _Point;
   double buf    = SLBufferPoints * _Point;

   // --- ACHAT : sweep de la liquidité vendeuse + FVG haussier
   int    rLowI  = iLowest(_Symbol, _Period, MODE_LOW, SweepBars, 1);
   int    pLowI  = iLowest(_Symbol, _Period, MODE_LOW, LiquidityBars, SweepBars + 1);
   double rLow   = iLow(_Symbol, _Period, rLowI);
   double pLow   = iLow(_Symbol, _Period, pLowI);

   if(wid != lastBuyWin && rLow < pLow && rLowI >= 3 && (l1 - h3) >= minGap)
   {
      double entry = NormalizeDouble(l1, _Digits);
      double sl    = NormalizeDouble(rLow - buf, _Digits);
      double tp    = NormalizeDouble(entry + RR * (entry - sl), _Digits);
      double lots  = CalcLots(entry, sl);
      if(lots > 0 && SymbolInfoDouble(_Symbol, SYMBOL_ASK) > entry)
         if(trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, wEnd, "SB Buy"))
            { lastBuyWin = wid; return; }
   }

   // --- VENTE : sweep de la liquidité acheteuse + FVG baissier
   int    rHighI = iHighest(_Symbol, _Period, MODE_HIGH, SweepBars, 1);
   int    pHighI = iHighest(_Symbol, _Period, MODE_HIGH, LiquidityBars, SweepBars + 1);
   double rHigh  = iHigh(_Symbol, _Period, rHighI);
   double pHigh  = iHigh(_Symbol, _Period, pHighI);

   if(wid != lastSellWin && rHigh > pHigh && rHighI >= 3 && (l3 - h1) >= minGap)
   {
      double entry = NormalizeDouble(h1, _Digits);
      double sl    = NormalizeDouble(rHigh + buf, _Digits);
      double tp    = NormalizeDouble(entry - RR * (sl - entry), _Digits);
      double lots  = CalcLots(entry, sl);
      if(lots > 0 && SymbolInfoDouble(_Symbol, SYMBOL_BID) < entry)
         if(trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, wEnd, "SB Sell"))
            lastSellWin = wid;
   }
}
//+------------------------------------------------------------------+
