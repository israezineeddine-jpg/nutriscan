//+------------------------------------------------------------------+
//| OB_EA.mq5 - Order Block (ICT) M30, port MQL5 de OB_EA.mq4         |
//| Attacher sur un graphique M30 (XAUUSDm).                          |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

input double Lots        = 0.10;   // lot fixe (si RiskPercent = 0)
input double RiskPercent = 0.0;    // % du solde risque par trade (0 = lot fixe)
input double RR          = 1.0;    // ratio R:R (config #1)
input int    Lookback    = 10;     // bougies pour le BOS
input double DispATR     = 2.0;    // impulsion minimale en ATR (config #1)
input int    MaxK        = 3;      // bougies max pour la confirmation
input int    ExpiryBars  = 48;     // validite de l'ordre limite (bougies)
input double SLBufATR    = 0.1;    // marge du SL en ATR
input int    ATRPeriod   = 14;
input int    Slippage    = 30;
input long   Magic       = 202511;

CTrade   trade;
int      atrHandle = INVALID_HANDLE;
datetime lastBar   = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Slippage);
   atrHandle = iATR(_Symbol, _Period, ATRPeriod);
   return(atrHandle == INVALID_HANDLE ? INIT_FAILED : INIT_SUCCEEDED);
}

// export des trades pour comparaison (MQL5\Files ou Tester\...\Files)
void OnDeinit(const int reason)
{
   int h = FileOpen("trades_ea5.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h != INVALID_HANDLE)
   {
      FileWrite(h, "close_time", "side", "price", "volume", "profit", "commission", "swap");
      if(HistorySelect(0, TimeCurrent()))
         for(int i = 0; i < HistoryDealsTotal(); i++)
         {
            ulong tk = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(tk, DEAL_MAGIC) != Magic) continue;
            if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
            if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
            // un deal de sortie SELL ferme un BUY
            int side = (HistoryDealGetInteger(tk, DEAL_TYPE) == DEAL_TYPE_SELL) ? 1 : -1;
            FileWrite(h, TimeToString((datetime)HistoryDealGetInteger(tk, DEAL_TIME), TIME_DATE | TIME_MINUTES), side,
                      HistoryDealGetDouble(tk, DEAL_PRICE), HistoryDealGetDouble(tk, DEAL_VOLUME),
                      HistoryDealGetDouble(tk, DEAL_PROFIT), HistoryDealGetDouble(tk, DEAL_COMMISSION),
                      HistoryDealGetDouble(tk, DEAL_SWAP));
         }
      FileClose(h);
   }
   IndicatorRelease(atrHandle);
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) return true;
   }
   return false;
}

void DeletePendings(bool onlyBroken)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != Magic) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double sl = OrderGetDouble(ORDER_SL);
      bool broken = (ot == ORDER_TYPE_BUY_LIMIT && bid < sl) || (ot == ORDER_TYPE_SELL_LIMIT && ask > sl);
      if(!onlyBroken || broken) trade.OrderDelete(tk);
   }
}

double AtrAt(int shift)
{
   double b[1];
   if(CopyBuffer(atrHandle, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
}

// bougie s = OB, bougie j = s-k = confirmation
bool Confirmed(int s, int side, int k)
{
   int j = s - k;
   double atr = AtrAt(s);
   if(atr <= 0) return false;
   double os = iOpen(_Symbol, _Period, s), cs = iClose(_Symbol, _Period, s), cj = iClose(_Symbol, _Period, j);
   if(side == 1)
   {
      if(!(cs < os)) return false;
      double refHi = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, Lookback, s + 1));
      return cj > refHi && cj - iHigh(_Symbol, _Period, s) > DispATR * atr;
   }
   if(!(cs > os)) return false;
   double refLo = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, Lookback, s + 1));
   return cj < refLo && iLow(_Symbol, _Period, s) - cj > DispATR * atr;
}

double CalcLots(double risk)
{
   double lots = Lots;
   if(RiskPercent > 0 && risk > 0)
   {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      lots = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0 / (risk / ts * tv);
   }
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(lots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)));
}

void Place(int s, int side)
{
   double atr   = AtrAt(s);
   double entry = NormalizeDouble(iOpen(_Symbol, _Period, s), _Digits);
   double sl    = NormalizeDouble(side == 1 ? iLow(_Symbol, _Period, s) - SLBufATR * atr
                                            : iHigh(_Symbol, _Period, s) + SLBufATR * atr, _Digits);
   double risk  = MathAbs(entry - sl);
   double tp    = NormalizeDouble(entry + side * RR * risk, _Digits);
   double lots  = CalcLots(risk);
   datetime exp = iTime(_Symbol, _Period, 0) + ExpiryBars * PeriodSeconds(_Period);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   PrintFormat("SIGNAL side=%d OB=%s entry=%.3f sl=%.3f tp=%.3f risk=%.2f spread=%d pts", side,
               TimeToString(iTime(_Symbol, _Period, s)), entry, sl, tp, risk, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   bool ok;
   if(side == 1)
      ok = (ask <= entry) ? trade.Buy(lots, _Symbol, 0, sl, tp, "OB")
                          : trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "OB");
   else
      ok = (bid >= entry) ? trade.Sell(lots, _Symbol, 0, sl, tp, "OB")
                          : trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "OB");
   if(!ok) Print("Order erreur ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

void OnTick()
{
   if(HasPosition()) { DeletePendings(false); return; }
   DeletePendings(true);                       // OB casse avant remplissage

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBar) return;                   // une evaluation par nouvelle bougie
   lastBar = t0;
   if(Bars(_Symbol, _Period) < Lookback + ATRPeriod + MaxK + 5) return;

   // bougie 1 = derniere cloturee = confirmation ; OB en s = 1+k
   for(int s = MaxK + 1; s >= 2; s--)
   {
      int k = s - 1;
      for(int side = 1; side >= -1; side -= 2)
      {
         if(!Confirmed(s, side, k)) continue;
         bool earlier = false;                 // la 1ere confirmation prime
         for(int kk = 1; kk < k; kk++) if(Confirmed(s, side, kk)) earlier = true;
         if(earlier) continue;
         Place(s, side);
      }
   }
}
