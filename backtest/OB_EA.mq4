//+------------------------------------------------------------------+
//| OB_EA.mq4 - Order Block (ICT) M30, meme logique que backtest_ob.py|
//| Attacher sur un graphique M30 (XAUUSDm).                          |
//+------------------------------------------------------------------+
#property strict

input double Lots        = 0.10;   // lot fixe (si RiskPercent = 0)
input double RiskPercent = 0.0;    // % du solde risque par trade (0 = lot fixe)
input double RR          = 2.0;    // ratio R:R
input int    Lookback    = 10;     // bougies pour le BOS
input double DispATR     = 1.0;    // impulsion minimale en ATR
input int    MaxK        = 3;      // bougies max pour la confirmation
input int    ExpiryBars  = 48;     // validite de l'ordre limite (bougies)
input double SLBufATR    = 0.1;    // marge du SL en ATR
input int    ATRPeriod   = 14;
input int    Slippage    = 30;
input int    Magic       = 202511;

datetime lastBar = 0;

int OnInit() { return INIT_SUCCEEDED; }

// export des trades pour comparer avec trades_ob.csv (dossier tester\files)
void OnDeinit(const int reason)
{
   int h = FileOpen("trades_ea.csv", FILE_CSV | FILE_WRITE, ',');
   if(h < 0) return;
   FileWrite(h, "open", "close", "side", "open_price", "close_price", "sl", "tp", "profit", "commission", "swap");
   for(int i = 0; i < OrdersHistoryTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != Magic || OrderSymbol() != Symbol() || OrderType() > OP_SELL) continue;
      FileWrite(h, TimeToString(OrderOpenTime(), TIME_DATE | TIME_MINUTES), TimeToString(OrderCloseTime(), TIME_DATE | TIME_MINUTES),
                OrderType() == OP_BUY ? 1 : -1, OrderOpenPrice(), OrderClosePrice(), OrderStopLoss(), OrderTakeProfit(),
                OrderProfit(), OrderCommission(), OrderSwap());
   }
   FileClose(h);
}

bool HasPosition()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderMagicNumber() == Magic &&
         OrderSymbol() == Symbol() && OrderType() <= OP_SELL)
         return true;
   return false;
}

void DeletePendings(bool onlyBroken)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != Magic || OrderSymbol() != Symbol() || OrderType() <= OP_SELL) continue;
      bool broken = (OrderType() == OP_BUYLIMIT  && Bid < OrderStopLoss()) ||
                    (OrderType() == OP_SELLLIMIT && Ask > OrderStopLoss());
      if(!onlyBroken || broken) OrderDelete(OrderTicket());
   }
}

// bougie s = OB, bougie j = s-k = confirmation
bool Confirmed(int s, int side, int k)
{
   int j = s - k;
   double atr = iATR(NULL, 0, ATRPeriod, s);
   if(side == 1)
   {
      if(!(Close[s] < Open[s])) return false;
      double refHi = High[iHighest(NULL, 0, MODE_HIGH, Lookback, s + 1)];
      return Close[j] > refHi && Close[j] - High[s] > DispATR * atr;
   }
   if(!(Close[s] > Open[s])) return false;
   double refLo = Low[iLowest(NULL, 0, MODE_LOW, Lookback, s + 1)];
   return Close[j] < refLo && Low[s] - Close[j] > DispATR * atr;
}

double CalcLots(double risk)
{
   double lots = Lots;
   if(RiskPercent > 0 && risk > 0)
   {
      double tv = MarketInfo(Symbol(), MODE_TICKVALUE), ts = MarketInfo(Symbol(), MODE_TICKSIZE);
      lots = AccountBalance() * RiskPercent / 100.0 / (risk / ts * tv);
   }
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   lots = MathFloor(lots / step) * step;
   return MathMax(MarketInfo(Symbol(), MODE_MINLOT), MathMin(lots, MarketInfo(Symbol(), MODE_MAXLOT)));
}

void Place(int s, int side)
{
   double atr   = iATR(NULL, 0, ATRPeriod, s);
   double entry = NormalizeDouble(Open[s], Digits);
   double sl    = NormalizeDouble(side == 1 ? Low[s] - SLBufATR * atr : High[s] + SLBufATR * atr, Digits);
   double risk  = MathAbs(entry - sl);
   double tp    = NormalizeDouble(entry + side * RR * risk, Digits);
   double lots  = CalcLots(risk);
   datetime exp = Time[0] + ExpiryBars * Period() * 60;
   int type;
   double price = entry;
   if(side == 1) { if(Ask <= entry) { type = OP_BUY;  price = Ask; } else type = OP_BUYLIMIT; }
   else          { if(Bid >= entry) { type = OP_SELL; price = Bid; } else type = OP_SELLLIMIT; }
   if(type <= OP_SELL) exp = 0;
   Print("SIGNAL side=", side, " OB=", TimeToString(Time[s]), " entry=", entry, " sl=", sl, " tp=", tp,
         " risk=", DoubleToString(risk, 2), " spread=", MarketInfo(Symbol(), MODE_SPREAD), " pts");
   if(OrderSend(Symbol(), type, lots, price, Slippage, sl, tp, "OB", Magic, exp) < 0)
      Print("OrderSend erreur ", GetLastError());
}

void OnTick()
{
   if(HasPosition()) { DeletePendings(false); return; }
   DeletePendings(true);                       // OB casse avant remplissage

   if(Time[0] == lastBar) return;              // une evaluation par nouvelle bougie
   lastBar = Time[0];
   if(Bars < Lookback + ATRPeriod + MaxK + 5) return;

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
