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
input double CostPerTrade      = 0.26;    // cout par trade (spread, en prix) pour les stats en R
input bool   OneTradeAtATime   = true;    // stats: ignorer les signaux pendant une position ouverte
input bool   ShowDashboard     = true;    // afficher le tableau de bord
input int    DashX             = 10;      // position X du tableau de bord
input int    DashY             = 25;      // position Y du tableau de bord
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

struct SigRec
{
   datetime tSig;
   int      side;
   double   entry0;
   double   sl0;
   bool     entered;
   datetime tEntry;
   datetime tEnd;
   double   entry;
   double   sl;
   double   tp;
   string   res;
   double   R;        // seulement pour WIN / LOSS
};

SigRec sigs[];
int    nSig = 0;

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

void OnDeinit(const int reason) { ObjectsDeleteAll(0, P); ObjectsDeleteAll(0, "OBD_"); }

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

string Lines[];
color  Cols[];
int    nLines = 0;

void AddLine(string t, color c = clrWhite)
{
   ArrayResize(Lines, nLines + 1); ArrayResize(Cols, nLines + 1);
   Lines[nLines] = t; Cols[nLines] = c; nLines++;
}

string F(double v, int d = 1) { return DoubleToString(v, d); }
string SR(double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2) + "R"; }

void DrawDashboard(int rates_total, const datetime &time[], int start)
{
   ObjectsDeleteAll(0, "OBD_");
   if(!ShowDashboard) return;
   nLines = 0;

   // compteurs par statut
   int cWin = 0, cLoss = 0, cOpen = 0, cPend = 0, cExp = 0, cCan = 0, cSkip = 0;
   for(int i = 0; i < nSig; i++)
   {
      string r = sigs[i].res;
      if(StringFind(r, "WIN") == 0) cWin++;
      else if(StringFind(r, "LOSS") == 0) cLoss++;
      else if(r == "OPEN") cOpen++;
      else if(r == "PENDING") cPend++;
      else if(r == "EXPIRED") cExp++;
      else if(r == "CANCELLED") cCan++;
      else cSkip++;
   }

   // trades clos tries par heure d'entree (+ filtre 1 trade a la fois)
   int idx[]; int m = 0;
   for(int i = 0; i < nSig; i++)
      if(sigs[i].entered && (StringFind(sigs[i].res, "WIN") == 0 || StringFind(sigs[i].res, "LOSS") == 0 || sigs[i].res == "OPEN"))
      { ArrayResize(idx, m + 1); idx[m++] = i; }
   for(int a = 1; a < m; a++)                     // tri par insertion
   {
      int key = idx[a]; int b = a - 1;
      while(b >= 0 && sigs[idx[b]].tEntry > sigs[key].tEntry) { idx[b + 1] = idx[b]; b--; }
      idx[b + 1] = key;
   }
   int taken[]; int nt = 0; datetime busy = 0;
   for(int a = 0; a < m; a++)
   {
      SigRec s = sigs[idx[a]];
      if(OneTradeAtATime && s.tEntry < busy) continue;
      ArrayResize(taken, nt + 1); taken[nt++] = idx[a];
      busy = (s.res == "OPEN") ? (datetime)D'2100.01.01' : s.tEnd;
   }
   int tw = 0, tl = 0, streak = 0, maxStreak = 0, nLong = 0, nShort = 0;
   double totR = 0, gp = 0, gl = 0, eq = 0, peak = 0, dd = 0, rLong = 0, rShort = 0;
   for(int a = 0; a < nt; a++)
   {
      SigRec s = sigs[taken[a]];
      if(s.res == "OPEN") continue;
      totR += s.R; eq += s.R; peak = MathMax(peak, eq); dd = MathMax(dd, peak - eq);
      if(s.R > 0) { tw++; gp += s.R; streak = 0; } else { tl++; gl += -s.R; streak++; maxStreak = MathMax(maxStreak, streak); }
      if(s.side == 1) { nLong++; rLong += s.R; } else { nShort++; rShort += s.R; }
   }
   int nClosed = tw + tl;
   double winPct = (nClosed > 0) ? 100.0 * tw / nClosed : 0;
   double pf = (gl > 0) ? gp / gl : (gp > 0 ? 99.9 : 0);
   double avgR = (nClosed > 0) ? totR / nClosed : 0;

   string modeTxt = effM5 ? "Confirmation M5" : "Limit";
   AddLine("OB INDICATOR  " + EnumToString(Preset), clrAqua);
   AddLine(_Symbol + " " + EnumToString((ENUM_TIMEFRAMES)_Period) + "  |  historique: " + IntegerToString(rates_total - start) + " bougies", clrSilver);
   AddLine("RR 1:" + F(effRR, 1) + " | Entree: " + modeTxt + " | NoGap: " + (effNoGap ? "ON" : "OFF"), clrWhite);
   AddLine("DispATR " + F(DispATR, 1) + " | Lookback " + IntegerToString(Lookback) + " | SL buf " + F(SLBufATR, 2) + " ATR", clrWhite);
   AddLine("Cout/trade: " + F(CostPerTrade, 2) + " | 1 trade a la fois: " + (OneTradeAtATime ? "ON" : "OFF"), clrWhite);
   AddLine("---------------------------------------------", clrDimGray);
   AddLine("SIGNAUX: " + IntegerToString(nSig) + "   WIN " + IntegerToString(cWin) + "  LOSS " + IntegerToString(cLoss) + "  OPEN " + IntegerToString(cOpen), clrWhite);
   AddLine("Annules " + IntegerToString(cCan) + " | Expires " + IntegerToString(cExp) + " | En attente " + IntegerToString(cPend) + " | Ignores " + IntegerToString(cSkip), clrSilver);
   AddLine("---------------------------------------------", clrDimGray);
   AddLine("RESULTATS (trades clos retenus: " + IntegerToString(nClosed) + ")", clrAqua);
   AddLine("WIN " + IntegerToString(tw) + "  LOSS " + IntegerToString(tl) + "  Win% " + F(winPct, 1), (winPct >= 50 ? clrLime : clrOrange));
   AddLine("Total " + SR(totR) + "  Moy " + SR(avgR) + "  PF " + F(pf, 2), (totR >= 0 ? clrLime : clrTomato));
   AddLine("Max DD " + F(dd, 1) + "R | Pire serie: " + IntegerToString(maxStreak) + " pertes", clrWhite);
   AddLine("Long: " + IntegerToString(nLong) + " (" + SR(rLong) + ")  Short: " + IntegerToString(nShort) + " (" + SR(rShort) + ")", clrWhite);
   AddLine("---------------------------------------------", clrDimGray);
   if(nSig > 0)
   {
      SigRec L = sigs[nSig - 1];
      AddLine("DERNIER SIGNAL", clrAqua);
      AddLine((L.side == 1 ? "BUY" : "SELL") + "  " + TimeToString(L.tSig, TIME_DATE | TIME_MINUTES), (L.side == 1 ? BuyColor : SellColor));
      if(L.entered)
         AddLine("Entry " + DoubleToString(L.entry, _Digits) + "  SL " + DoubleToString(L.sl, _Digits) + "  TP " + DoubleToString(L.tp, _Digits), clrWhite);
      else
         AddLine("Zone " + DoubleToString(L.entry0, _Digits) + "  SL " + DoubleToString(L.sl0, _Digits), clrWhite);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      AddLine("Statut: " + L.res + "   Prix: " + DoubleToString(bid, _Digits), clrYellow);
      AddLine("---------------------------------------------", clrDimGray);
   }
   AddLine("DERNIERS TRADES", clrAqua);
   int shown = 0;
   for(int a = nt - 1; a >= 0 && shown < 5; a--)
   {
      SigRec s = sigs[taken[a]];
      if(s.res == "OPEN") { AddLine(TimeToString(s.tEntry, TIME_DATE | TIME_MINUTES) + (s.side == 1 ? " BUY  " : " SELL ") + "OPEN", clrYellow); shown++; continue; }
      AddLine(TimeToString(s.tEntry, TIME_DATE | TIME_MINUTES) + (s.side == 1 ? " BUY  " : " SELL ") + SR(s.R), (s.R > 0 ? clrLime : clrTomato));
      shown++;
   }
   if(shown == 0) AddLine("(aucun)", clrSilver);
   AddLine("Simulation M5 - pas un conseil financier", clrDimGray);

   int w = 360, h = nLines * 15 + 12;
   ObjectCreate(0, "OBD_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_XDISTANCE, DashX);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_YDISTANCE, DashY);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_XSIZE, w);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_YSIZE, h);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_BGCOLOR, C'18,22,30');
   ObjectSetInteger(0, "OBD_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_BACK, false);
   ObjectSetInteger(0, "OBD_bg", OBJPROP_SELECTABLE, false);
   for(int i = 0; i < nLines; i++)
   {
      string nm = "OBD_l" + IntegerToString(i);
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, DashX + 8);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, DashY + 6 + i * 15);
      ObjectSetString(0, nm, OBJPROP_TEXT, Lines[i]);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, Cols[i]);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
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
   nSig = 0; ArrayResize(sigs, 0);

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

         {
            double rk = MathAbs(sr.entry - sr.sl);
            double Rv = 0;
            if(sr.entered && rk > 0)
            {
               if(StringFind(sr.res, "WIN") == 0)  Rv = effRR - CostPerTrade / rk;
               if(StringFind(sr.res, "LOSS") == 0) Rv = -1.0 - CostPerTrade / rk;
            }
            ArrayResize(sigs, nSig + 1);
            sigs[nSig].tSig = time[j]; sigs[nSig].side = side; sigs[nSig].entry0 = entry0; sigs[nSig].sl0 = sl0;
            sigs[nSig].entered = sr.entered; sigs[nSig].tEntry = sr.tEntry; sigs[nSig].tEnd = sr.tEnd;
            sigs[nSig].entry = sr.entry; sigs[nSig].sl = sr.sl; sigs[nSig].tp = sr.tp; sigs[nSig].res = sr.res; sigs[nSig].R = Rv;
            nSig++;
         }
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
   DrawDashboard(rates_total, time, start);
   ChartRedraw();
   return(rates_total);
}
