//+------------------------------------------------------------------+
//| OB_Indicator.mq5 - Order Block (ICT) : Entry / SL / TP            |
//| Presets P1..P4 (OB sur M30, entree Limit ou confirmation M5).     |
//|  P1 = M30 Limit      RR 1:2                                       |
//|  P2 = M30 + M5       RR 1:2                                       |
//|  P3 = M30 Limit      RR 1:3  NoGap                                |
//|  P4 = M30 + M5       RR 1:3  NoGap                                |
//| Hypotheses (a verifier): NoGap = on ignore l'OB si une bougie entre |
//| l'OB et la confirmation ouvre avec un gap > GapATR x ATR.          |
//| Graphique: M30 XAUUSD. Le resultat (WIN/LOSS) est simule sur M5.   |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

enum ENUM_PRESET
{
   P1_M30_RR2          = 0,
   P2_M30M5_RR2        = 1,
   P3_M30_RR3_NoGap    = 2,
   P4_M30M5_RR3_NoGap  = 3,
   CUSTOM              = 4
};

input ENUM_PRESET Preset       = P1_M30_RR2;
input double CustomRR          = 2.0;     // (CUSTOM) ratio R:R
input bool   CustomM5Entry     = false;   // (CUSTOM) entree par confirmation M5
input bool   CustomNoGap       = false;   // (CUSTOM) filtre NoGap

input int    Lookback          = 10;      // bougies pour le BOS
input double DispATR           = 2.0;     // impulsion minimale en ATR
input int    MaxK              = 3;       // bougies max pour la confirmation
input int    ExpiryBars        = 48;      // validite de l'ordre (bougies M30)
input double SLBufATR          = 0.1;     // marge du SL en ATR
input int    ATRPeriod         = 14;
input double GapATR            = 0.3;     // seuil du gap pour NoGap (x ATR)
input int    M5Window          = 12;      // bougies M5 max apres le touche (mode M5)
input double MinRiskATR        = 0.3;     // risque minimum (mode M5) en ATR
input int    HistoryBars       = 1000;    // nombre de bougies M30 analysees
input bool   ShowAllRR         = true;    // afficher aussi 1:1, 1:2, 1:3
input bool   ShowOutcome       = true;    // afficher WIN / LOSS / ...
input bool   AlertOnSignal     = true;    // alerte a chaque nouveau signal
input color  BuyColor          = clrDodgerBlue;
input color  SellColor         = clrOrangeRed;

const string P = "OBI_";
datetime lastCalc  = 0;
datetime lastAlert = 0;
double   effRR     = 2.0;
bool     effM5     = false;
bool     effNoGap  = false;

struct SimResult
{
   bool     entered;
   datetime tEntry;
   double   entry;
   double   sl;
   double   tp;
   datetime tEnd;
   string   res;
};

int OnInit()
{
   switch(Preset)
   {
      case P1_M30_RR2:         effRR = 2.0; effM5 = false; effNoGap = false; break;
      case P2_M30M5_RR2:       effRR = 2.0; effM5 = true;  effNoGap = false; break;
      case P3_M30_RR3_NoGap:   effRR = 3.0; effM5 = false; effNoGap = true;  break;
      case P4_M30M5_RR3_NoGap: effRR = 3.0; effM5 = true;  effNoGap = true;  break;
      default:                 effRR = CustomRR; effM5 = CustomM5Entry; effNoGap = CustomNoGap; break;
   }
   IndicatorSetString(INDICATOR_SHORTNAME, "OB Entry/SL/TP " + EnumToString(Preset));
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

// Simulation sur les bougies M5 (meme logique que le backtest)
void Simulate(const MqlRates &r5[], int n5, int side, datetime t0, datetime tE,
              double entry0, double sl0, double atr, SimResult &o)
{
   o.entered = false; o.tEntry = 0; o.entry = entry0; o.sl = sl0; o.tp = 0; o.tEnd = tE; o.res = "PENDING";
   int lo = 0, hi = n5;
   while(lo < hi) { int mid = (lo + hi) / 2; if(r5[mid].time < t0) lo = mid + 1; else hi = mid; }
   int state = 0, arm = -1;                    // 0 = en attente, 1 = arme (M5), 2 = en position
   double sw = 0, risk = 0, sl = sl0, tp = 0, ent = entry0;
   bool ended = false;
   int q;
   for(q = lo; q < n5 && r5[q].time < tE; q++)
   {
      double H = r5[q].high, L = r5[q].low, C = r5[q].close;
      if(state == 0)
      {
         bool touched = (side == 1) ? (L <= entry0) : (H >= entry0);
         bool broken  = (side == 1) ? (L < sl0)     : (H > sl0);
         if(!effM5)
         {
            if(touched)
            {
               state = 2; ent = entry0; sl = sl0; risk = MathAbs(ent - sl); tp = ent + side * effRR * risk;
               o.entered = true; o.tEntry = r5[q].time;
            }
            else if(broken) { o.res = "CANCELLED"; o.tEnd = r5[q].time; ended = true; break; }
         }
         else
         {
            if(broken) { o.res = "CANCELLED"; o.tEnd = r5[q].time; ended = true; break; }
            if(touched) { arm = q; sw = (side == 1) ? L : H; state = 1; }
            continue;
         }
      }
      else if(state == 1)
      {
         sw = (side == 1) ? MathMin(sw, L) : MathMax(sw, H);
         if((side == 1 && sw < sl0) || (side == -1 && sw > sl0)) { o.res = "CANCELLED"; o.tEnd = r5[q].time; ended = true; break; }
         bool trig = (side == 1) ? (C > r5[arm].high) : (C < r5[arm].low);
         if(trig)
         {
            ent = C; sl = sw - side * SLBufATR * atr; risk = MathAbs(ent - sl);
            if(risk < MinRiskATR * atr) { o.res = "SKIPPED"; o.tEnd = r5[q].time; ended = true; break; }
            tp = ent + side * effRR * risk; state = 2;
            o.entered = true; o.tEntry = r5[q].time;
            continue;                           // SL/TP verifies des la bougie suivante
         }
         if(q - arm >= M5Window) { o.res = "EXPIRED"; o.tEnd = r5[q].time; ended = true; break; }
         continue;
      }
      if(state == 2)
      {
         bool hSL = (side == 1) ? (L <= sl) : (H >= sl);
         bool hTP = (side == 1) ? (H >= tp) : (L <= tp);
         if(hSL) { o.res = "LOSS (SL)"; o.tEnd = r5[q].time; ended = true; break; }
         if(hTP) { o.res = "WIN (TP)";  o.tEnd = r5[q].time; ended = true; break; }
      }
   }
   o.entry = ent; o.sl = sl; o.tp = tp;
   if(!ended)
   {
      if(state == 2) { o.res = "OPEN"; if(q > 0 && q <= n5) o.tEnd = r5[MathMin(q, n5) - 1].time; }
      else if(q >= n5) o.res = "PENDING";
      else o.res = "EXPIRED";
   }
}

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   if(rates_total < Lookback + ATRPeriod + MaxK + 5) return(0);
   if(time[rates_total - 1] == lastCalc && prev_calculated > 0) return(rates_total);
   lastCalc = time[rates_total - 1];
   ObjectsDeleteAll(0, P);

   // ATR = moyenne simple du True Range (comme le backtest)
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

   // bougies M5 pour la simulation
   MqlRates r5[];
   ArraySetAsSeries(r5, false);
   int n5 = CopyRates(_Symbol, PERIOD_M5, time[start], time[rates_total - 1] + per, r5);
   if(n5 <= 0) { Print("OB_Indicator: pas de donnees M5 (", GetLastError(), ")"); n5 = 0; }

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
            if(!ok) continue;
            if(effNoGap)
            {
               bool gap = false;
               for(int x = i; x <= jj; x++)
                  if(MathAbs(open[x] - close[x - 1]) > GapATR * atr[i]) { gap = true; break; }
               if(gap) ok = false;
            }
            if(ok) { j = jj; break; }
         }
         if(j < 0) continue;

         double entry0 = open[i];
         double sl0    = (side == 1) ? low[i] - SLBufATR * atr[i] : high[i] + SLBufATR * atr[i];
         datetime t0   = time[j] + per;
         datetime tE   = t0 + (datetime)(ExpiryBars * per);

         SimResult sr;
         if(n5 > 0) Simulate(r5, n5, side, t0, tE, entry0, sl0, atr[i], sr);
         else { sr.entered = false; sr.entry = entry0; sr.sl = sl0; sr.tp = 0; sr.tEnd = tE; sr.res = "NO M5 DATA"; sr.tEntry = 0; }

         color c = (side == 1) ? BuyColor : SellColor;
         string id = P + IntegerToString(i) + "_" + IntegerToString(side);
         datetime tl = sr.entered ? sr.tEntry : t0;
         string dir = (side == 1) ? "BUY" : "SELL";

         ObjectCreate(0, id + "_zone", OBJ_RECTANGLE, 0, time[i], high[i], sr.tEnd, low[i]);
         ObjectSetInteger(0, id + "_zone", OBJPROP_COLOR, c);
         ObjectSetInteger(0, id + "_zone", OBJPROP_FILL, false);
         ObjectSetInteger(0, id + "_zone", OBJPROP_SELECTABLE, false);

         if(sr.entered)
         {
            double risk = MathAbs(sr.entry - sr.sl);
            Line(id + "_en", tl, sr.tEnd, sr.entry, c, STYLE_SOLID, 2);
            Line(id + "_sl", tl, sr.tEnd, sr.sl, clrRed, STYLE_DOT, 1);
            Line(id + "_tp", tl, sr.tEnd, sr.tp, clrLime, STYLE_SOLID, 2);
            Label(id + "_ten", tl, sr.entry, dir + " " + DoubleToString(sr.entry, _Digits), c);
            Label(id + "_tsl", tl, sr.sl, "SL " + DoubleToString(sr.sl, _Digits), clrRed);
            Label(id + "_ttp", tl, sr.tp, "TP 1:" + DoubleToString(effRR, 0) + " " + DoubleToString(sr.tp, _Digits), clrLime);
            if(ShowAllRR)
               for(int r = 1; r <= 3; r++)
               {
                  if(r == (int)MathRound(effRR)) continue;
                  double p = sr.entry + side * r * risk;
                  Line(id + "_rr" + IntegerToString(r), tl, sr.tEnd, p, clrSilver, STYLE_DOT, 1);
                  Label(id + "_trr" + IntegerToString(r), tl, p, "1:" + IntegerToString(r), clrSilver);
               }
         }
         else
         {
            Line(id + "_en", t0, sr.tEnd, entry0, c, STYLE_SOLID, 1);
            Line(id + "_sl", t0, sr.tEnd, sl0, clrRed, STYLE_DOT, 1);
            Label(id + "_ten", t0, entry0, (effM5 ? dir + " zone (confirmation M5) " : dir + " LIMIT ") + DoubleToString(entry0, _Digits), c);
            Label(id + "_tsl", t0, sl0, "SL " + DoubleToString(sl0, _Digits), clrRed);
            if(!effM5)
            {
               double tp0 = entry0 + side * effRR * MathAbs(entry0 - sl0);
               Line(id + "_tp", t0, sr.tEnd, tp0, clrLime, STYLE_DOT, 1);
               Label(id + "_ttp", t0, tp0, "TP 1:" + DoubleToString(effRR, 0) + " " + DoubleToString(tp0, _Digits), clrLime);
            }
         }
         if(ShowOutcome)
            Label(id + "_res", sr.tEnd, sr.entry, sr.res,
                  (StringFind(sr.res, "WIN") == 0) ? clrLime : (StringFind(sr.res, "LOSS") == 0) ? clrRed : clrSilver);

         if(AlertOnSignal && j == rates_total - 2 && time[j] != lastAlert)
         {
            lastAlert = time[j];
            Alert(_Symbol, " ", EnumToString(Preset), " ", dir, (effM5 ? " zone " : " LIMIT "), DoubleToString(entry0, _Digits),
                  "  SL ", DoubleToString(sl0, _Digits), (effM5 ? "  (attendre confirmation M5)" : ""));
         }
      }
   }
   ChartRedraw();
   return(rates_total);
}
