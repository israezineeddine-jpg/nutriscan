//+------------------------------------------------------------------+
//| OB_Indicator.mq5 - Order Block (ICT): Entry / SL / TP sur le      |
//| graphique, memes regles que OB_EA. A mettre sur M30 (XAUUSD).     |
//| Les resultats (WIN/LOSS) sont estimes sur les bougies du graphique|
//| (SL prioritaire si SL et TP touches dans la meme bougie).         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input int    Lookback     = 10;     // bougies pour le BOS
input double DispATR      = 2.0;    // impulsion minimale en ATR
input int    MaxK         = 3;      // bougies max pour la confirmation
input int    ExpiryBars   = 48;     // validite de l'ordre limite (bougies)
input double SLBufATR     = 0.1;    // marge du SL en ATR
input int    ATRPeriod    = 14;
input double RR           = 1.5;    // ratio R:R pour le TP
input int    HistoryBars  = 1500;   // nombre de bougies analysees
input bool   ShowOutcome  = true;   // afficher WIN / LOSS / ...
input bool   AlertOnSignal= true;   // alerte a chaque nouveau signal
input color  BuyColor     = clrDodgerBlue;
input color  SellColor    = clrOrangeRed;

const string P = "OBI_";
datetime lastCalc  = 0;
datetime lastAlert = 0;

int OnInit()
{
   IndicatorSetString(INDICATOR_SHORTNAME, "OB Entry/SL/TP");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { ObjectsDeleteAll(0, P); }

void Line(string name, datetime t1, datetime t2, double price, color clr, ENUM_LINE_STYLE st, int w)
{
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, st);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void Label(string name, datetime t, double price, string txt, color clr)
{
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   if(rates_total < Lookback + ATRPeriod + MaxK + 5) return(0);
   if(time[rates_total - 1] == lastCalc && prev_calculated > 0) return(rates_total);
   lastCalc = time[rates_total - 1];
   ObjectsDeleteAll(0, P);

   // ATR (moyenne simple du True Range, comme le backtest)
   double tr[], atr[];
   ArrayResize(tr, rates_total); ArrayResize(atr, rates_total);
   ArrayInitialize(atr, 0.0);
   tr[0] = high[0] - low[0];
   for(int i = 1; i < rates_total; i++)
      tr[i] = MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i - 1]), MathAbs(low[i] - close[i - 1])));
   for(int i = ATRPeriod; i < rates_total; i++)
   {
      double s = 0;
      for(int q = i - ATRPeriod + 1; q <= i; q++) s += tr[q];
      atr[i] = s / ATRPeriod;
   }

   int per = PeriodSeconds();
   int start = MathMax(Lookback + ATRPeriod, rates_total - HistoryBars);

   for(int i = start; i <= rates_total - 3; i++)
   {
      for(int side = 1; side >= -1; side -= 2)
      {
         if(side == 1 && !(close[i] < open[i])) continue;
         if(side == -1 && !(close[i] > open[i])) continue;

         double refHi = -DBL_MAX, refLo = DBL_MAX;
         for(int q = i - Lookback; q < i; q++) { refHi = MathMax(refHi, high[q]); refLo = MathMin(refLo, low[q]); }

         int j = -1;
         for(int k = 1; k <= MaxK; k++)
         {
            int jj = i + k;
            if(jj > rates_total - 2) break;               // seulement bougies cloturees
            bool ok = (side == 1) ? (close[jj] > refHi && close[jj] - high[i] > DispATR * atr[i])
                                  : (close[jj] < refLo && low[i] - close[jj] > DispATR * atr[i]);
            if(ok) { j = jj; break; }
         }
         if(j < 0) continue;

         double entry = open[i];
         double sl    = (side == 1) ? low[i] - SLBufATR * atr[i] : high[i] + SLBufATR * atr[i];
         double risk  = MathAbs(entry - sl);
         double tp    = entry + side * RR * risk;
         datetime t0  = time[j] + per;
         datetime tE  = t0 + (datetime)(ExpiryBars * per);

         // estimation du resultat sur les bougies du graphique
         string res = "PENDING"; datetime tEnd = tE; bool filled = false;
         int last = MathMin(rates_total - 1, j + ExpiryBars);
         for(int q = j + 1; q <= last; q++)
         {
            if(!filled)
            {
               if((side == 1 && low[q] <= entry) || (side == -1 && high[q] >= entry)) { filled = true; res = "OPEN"; }
               else if((side == 1 && low[q] < sl) || (side == -1 && high[q] > sl)) { res = "CANCELLED"; tEnd = time[q]; break; }
            }
            if(filled)
            {
               bool hSL = (side == 1) ? (low[q] <= sl) : (high[q] >= sl);
               bool hTP = (side == 1) ? (high[q] >= tp) : (low[q] <= tp);
               if(hSL) { res = "LOSS"; tEnd = time[q]; break; }
               if(hTP) { res = "WIN";  tEnd = time[q]; break; }
            }
         }
         if(res == "PENDING" && j + ExpiryBars < rates_total - 1) res = "EXPIRED";

         color c = (side == 1) ? BuyColor : SellColor;
         string id = P + IntegerToString(i) + "_" + IntegerToString(side);

         ObjectCreate(0, id + "_zone", OBJ_RECTANGLE, 0, time[i], high[i], tEnd, low[i]);
         ObjectSetInteger(0, id + "_zone", OBJPROP_COLOR, c);
         ObjectSetInteger(0, id + "_zone", OBJPROP_FILL, false);
         ObjectSetInteger(0, id + "_zone", OBJPROP_SELECTABLE, false);

         Line(id + "_en", t0, tEnd, entry, c, STYLE_SOLID, 2);
         Line(id + "_sl", t0, tEnd, sl, clrRed, STYLE_DOT, 1);
         Line(id + "_tp", t0, tEnd, tp, clrLime, STYLE_DOT, 1);
         string dir = (side == 1) ? "BUY LIMIT " : "SELL LIMIT ";
         Label(id + "_ten", t0, entry, dir + DoubleToString(entry, _Digits), c);
         Label(id + "_tsl", t0, sl, "SL " + DoubleToString(sl, _Digits), clrRed);
         Label(id + "_ttp", t0, tp, "TP " + DoubleToString(tp, _Digits), clrLime);
         if(ShowOutcome)
            Label(id + "_res", tEnd, entry, res, (res == "WIN") ? clrLime : (res == "LOSS") ? clrRed : clrSilver);

         if(AlertOnSignal && j == rates_total - 2 && time[j] != lastAlert)
         {
            lastAlert = time[j];
            Alert(_Symbol, " ", dir, DoubleToString(entry, _Digits), "  SL ", DoubleToString(sl, _Digits),
                  "  TP ", DoubleToString(tp, _Digits));
         }
      }
   }
   ChartRedraw();
   return(rates_total);
}
