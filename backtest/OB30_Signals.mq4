//+------------------------------------------------------------------+
//| OB30_Signals.mq4  -  Indicateur MT4 v3 (meme code que la version  |
//| MT5 OB30_Signals.mq5)                                            |
//| Affiche ENTRY / SL / TP des signaux de l'EA OB30 (P1):           |
//|  - zones OB sur M30, signal sur bougie M5 (touche de la zone,    |
//|    couleur du sens, divergence SMT Or vs Argent)                 |
//|  - ORDRE AU MARCHE (market) a l'ouverture de la bougie M5        |
//|    suivante: BUY au Ask, SELL au Bid                             |
//|  - SL = meche de la bougie signal -/+ SLFixPts, TP = RR x risque |
//| A mettre sur XAUUSD (M5 conseille). Il faut le symbole argent    |
//| dans le Market Watch avec l'historique M5.                       |
//| Le resultat WIN/LOSS est une SIMULATION sur bougies M5.          |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 0
#property strict

input string SilverSymbol   = "XAGUSDm";  // symbole de l'argent chez le broker
input bool   UseSMT         = true;       // filtre SMT Or vs Argent
input int    SMTWindow      = 24;         // fenetre SMT (bougies M5)
input bool   NeedColor      = true;       // bougie de la couleur du sens
input double RR             = 2.0;        // TP = RR x risque
input double SLFixPts       = 2.0;        // SL a X (prix) au-dela de la meche
input double MaxRiskPts     = 20.0;       // risque max (prix), 0 = off
input int    ZoneGap        = 3;          // ecart mini entre 2 OB de meme sens (bougies M30)
input int    ExpireBars     = 576;        // duree de vie d'un OB (bougies M5)
input int    HoldBars       = 288;        // duree max d'un trade (bougies M5)
input double SpreadAssumed  = 0.26;       // spread suppose pour la simulation (prix)
input bool   NoWeekend      = true;       // pas de position pendant le week-end
input int    FriEntryCutHour= 18;         // vendredi: plus d'entree a partir de (heure serveur)
input int    FriCloseHour   = 20;         // vendredi: fermeture a (heure serveur)
input int    FriCloseMin    = 30;
input int    HistoryBars    = 4000;       // bougies M5 analysees (~14 jours, garder <= 10000)
input bool   ShowAllZones   = false;      // dessiner aussi les zones sans trade
input bool   ShowOutcome    = true;       // afficher TP / SL / ...
input bool   ShowDashboard  = true;
input bool   AlertOnSignal  = true;
input int    DashX          = 10;
input int    DashY          = 25;
input color  BuyColor       = clrDodgerBlue;
input color  SellColor      = clrOrangeRed;

#define PFX "OB30_"

//--- donnees M5 / M30 / argent
datetime t5[]; double o5[], h5[], l5[], c5[];
datetime ts[]; double hs[], ls[];
int n5 = 0, nS = 0;

//--- zones
int      zDir[]; double zLo[], zHi[]; datetime zAct[], zOB[]; int zA5[], zBrk[]; bool zUsed[];
int nz = 0;

//--- trades (res: 0 ouvert, 1 TP, 2 SL, 3 TIMEOUT, 4 WEEKEND)
datetime trSig[], trEnt[], trEnd[]; int trDir[], trRes[], trZone[];
double   trPrice[], trSL[], trTP[], trRisk[], trExit[], trR[];
int nt = 0;

datetime lastSig   = 0;
datetime lastAlert = 0;
string   g_silver  = "";          // symbole argent reellement utilise
string   g_why     = "";          // raison du dernier echec de chargement (affichee sur le graphique)
string   g_lastMsg = "";          // dernier message ecrit dans le journal (anti-spam)
bool     g_incomplete = false;    // historique M5 encore en cours de telechargement
int      g_n30 = 0;               // nombre de bougies M30 chargees
uint     g_lastResolve = 0;

string Lines[]; color Cols[]; int nLines = 0;

//+------------------------------------------------------------------+
void Note(string msg)
{
   if(msg == g_lastMsg) return;
   g_lastMsg = msg;
   Print("OB30 Signals: ", msg);
}

// cherche le symbole argent: celui des inputs, sinon XAGUSD*, sinon XAG*, sinon *SILVER* (le plus court nom)
string ResolveSilver()
{
   if(SymbolSelect(SilverSymbol, true)) return(SilverSymbol);
   string best = "";
   int tot = SymbolsTotal(false);
   for(int pass = 0; pass < 3 && best == ""; pass++)
   {
      for(int i = 0; i < tot; i++)
      {
         string nm = SymbolName(i, false);
         string up = nm;
         StringToUpper(up);
         bool ok = false;
         if(pass == 0) ok = (StringFind(up, "XAGUSD") == 0);
         if(pass == 1) ok = (StringFind(up, "XAG") == 0);
         if(pass == 2) ok = (StringFind(up, "SILVER") >= 0);
         if(ok && (best == "" || StringLen(nm) < StringLen(best))) best = nm;
      }
   }
   if(best != "" && SymbolSelect(best, true)) return(best);
   return(SilverSymbol);
}

int OnInit()
{
   if(SMTWindow < 1 || HistoryBars < 500 || RR <= 0.0 || ExpireBars < 1) return(INIT_PARAMETERS_INCORRECT);
   IndicatorShortName("OB30 Signals");
   g_silver = ResolveSilver();
   Print("OB30 Signals v3: or = ", _Symbol, " | argent = ", g_silver);
   EventSetTimer(3);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ObjectsDeleteAll(0, "OB30D_");
}

//+------------------------------------------------------------------+
int DOW(datetime t)  { MqlDateTime d; TimeToStruct(t, d); return d.day_of_week; }
int HOURS(datetime t){ MqlDateTime d; TimeToStruct(t, d); return d.hour; }
int MINS(datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.min; }

bool IsFriBlock(datetime t) { return(NoWeekend && DOW(t) == 5 && HOURS(t) >= FriEntryCutHour); }
bool IsWeekendClose(datetime t)
{
   return(NoWeekend && DOW(t) == 5 && (HOURS(t) * 60 + MINS(t)) >= FriCloseHour * 60 + FriCloseMin);
}

int LowerBound(const datetime &a[], int n, datetime t)   // premier index avec a[i] >= t
{
   int lo = 0, hi = n;
   while(lo < hi) { int m = (lo + hi) / 2; if(a[m] < t) lo = m + 1; else hi = m; }
   return lo;
}

int UpperBound(const datetime &a[], int n, datetime t)   // premier index avec a[i] > t
{
   int lo = 0, hi = n;
   while(lo < hi) { int m = (lo + hi) / 2; if(a[m] <= t) lo = m + 1; else hi = m; }
   return lo;
}

//+------------------------------------------------------------------+
void AddZone(int dir, double lo, double hi, datetime act, datetime tob)
{
   ArrayResize(zDir, nz + 1); ArrayResize(zLo, nz + 1); ArrayResize(zHi, nz + 1);
   ArrayResize(zAct, nz + 1); ArrayResize(zOB, nz + 1); ArrayResize(zA5, nz + 1);
   ArrayResize(zBrk, nz + 1); ArrayResize(zUsed, nz + 1);
   zDir[nz] = dir; zLo[nz] = lo; zHi[nz] = hi; zAct[nz] = act; zOB[nz] = tob;
   zUsed[nz] = false; zA5[nz] = 0; zBrk[nz] = 1000000000;
   nz++;
}

// OB: derniere bougie inverse p, 1ere bougie suivante de la couleur du sens, un des 3 closes suivants
// casse le plus haut / bas des 10 dernieres bougies (OB inclus). Sans ATR.
void BuildZones(const MqlRates &r[], int n)
{
   nz = 0;
   int lastBull = -1000000, lastBear = -1000000;
   for(int p = 9; p < n - 4; p++)                      // p+3 <= n-2 : bougies cloturees seulement
   {
      double hh = -1.0, ll = 1.0e10;
      for(int k = p - 9; k <= p; k++) { hh = MathMax(hh, r[k].high); ll = MathMin(ll, r[k].low); }
      if(r[p].close < r[p].open && r[p + 1].close > r[p + 1].open)
      {
         double mx = MathMax(r[p + 1].close, MathMax(r[p + 2].close, r[p + 3].close));
         if(mx > hh && (p - lastBull) > ZoneGap)
         {
            lastBull = p;
            AddZone(1, r[p].low, r[p].high, r[p + 3].time + 1800, r[p].time);
         }
      }
      else if(r[p].close > r[p].open && r[p + 1].close < r[p + 1].open)
      {
         double mn = MathMin(r[p + 1].close, MathMin(r[p + 2].close, r[p + 3].close));
         if(mn < ll && (p - lastBear) > ZoneGap)
         {
            lastBear = p;
            AddZone(-1, r[p].low, r[p].high, r[p + 3].time + 1800, r[p].time);
         }
      }
   }
}

//+------------------------------------------------------------------+
bool SilverRange(datetime ta, datetime tb, bool wantMin, double &val)
{
   int a = LowerBound(ts, nS, ta);
   int b = UpperBound(ts, nS, tb);
   if(b <= a) return(false);
   double v = wantMin ? 1.0e10 : -1.0e10;
   for(int i = a; i < b; i++)
   {
      if(wantMin) v = MathMin(v, ls[i]); else v = MathMax(v, hs[i]);
   }
   val = v;
   return(true);
}

bool SMTOk(int s, int d)
{
   if(!UseSMT) return(true);
   int n = SMTWindow;
   if(s - 2 * n + 1 < 0) return(false);
   datetime ta1 = t5[s - n + 1], tb1 = t5[s], ta0 = t5[s - 2 * n + 1], tb0 = t5[s - n];
   if(d == 1)
   {
      double g1 = 1.0e10, g0 = 1.0e10;
      for(int i = s - n + 1; i <= s; i++) g1 = MathMin(g1, l5[i]);
      for(int i = s - 2 * n + 1; i <= s - n; i++) g0 = MathMin(g0, l5[i]);
      if(!(l5[s] <= g1 && g1 < g0)) return(false);          // l'or fait un nouveau plus bas
      double s1, s0;
      if(!SilverRange(ta1, tb1, true, s1) || !SilverRange(ta0, tb0, true, s0)) return(false);
      return(s1 >= s0);                                      // l'argent ne confirme pas
   }
   double h1 = -1.0e10, h0 = -1.0e10;
   for(int i = s - n + 1; i <= s; i++) h1 = MathMax(h1, h5[i]);
   for(int i = s - 2 * n + 1; i <= s - n; i++) h0 = MathMax(h0, h5[i]);
   if(!(h5[s] >= h1 && h1 > h0)) return(false);
   double t1, t0;
   if(!SilverRange(ta1, tb1, false, t1) || !SilverRange(ta0, tb0, false, t0)) return(false);
   return(t1 <= t0);
}

//+------------------------------------------------------------------+
void AddTrade(int zi, int dir, datetime tsig, datetime tent, double price, double sl, double tp, double risk)
{
   ArrayResize(trSig, nt + 1); ArrayResize(trEnt, nt + 1); ArrayResize(trEnd, nt + 1);
   ArrayResize(trDir, nt + 1); ArrayResize(trRes, nt + 1); ArrayResize(trZone, nt + 1);
   ArrayResize(trPrice, nt + 1); ArrayResize(trSL, nt + 1); ArrayResize(trTP, nt + 1);
   ArrayResize(trRisk, nt + 1); ArrayResize(trExit, nt + 1); ArrayResize(trR, nt + 1);
   trSig[nt] = tsig; trEnt[nt] = tent; trEnd[nt] = tent; trDir[nt] = dir; trRes[nt] = 0; trZone[nt] = zi;
   trPrice[nt] = price; trSL[nt] = sl; trTP[nt] = tp; trRisk[nt] = risk; trExit[nt] = 0.0; trR[nt] = 0.0;
   nt++;
}

void CloseTrade(int i, double px, int res, datetime t)
{
   trExit[i] = px; trRes[i] = res; trEnd[i] = t;
   trR[i] = trDir[i] * (px - trPrice[i]) / trRisk[i];
}

// SL/TP sur la bougie q pour le trade i (SL prioritaire). Retourne true si clos.
bool CheckExit(int i, int q)
{
   int d = trDir[i];
   if(d == 1)
   {
      if(l5[q] <= trSL[i]) { CloseTrade(i, MathMin(trSL[i], o5[q]), 2, t5[q]); return(true); }
      if(h5[q] >= trTP[i]) { CloseTrade(i, trTP[i], 1, t5[q]); return(true); }
   }
   else
   {
      if(h5[q] + SpreadAssumed >= trSL[i]) { CloseTrade(i, MathMax(trSL[i], o5[q] + SpreadAssumed), 2, t5[q]); return(true); }
      if(l5[q] + SpreadAssumed <= trTP[i]) { CloseTrade(i, trTP[i], 1, t5[q]); return(true); }
   }
   return(false);
}

//--- simulation chronologique (meme logique que l'EA et la replique Python)
void Simulate()
{
   nt = 0;
   int open = -1;                                        // index du trade ouvert
   int qStart = MathMax(2 * SMTWindow, 1);
   for(int q = qStart; q < n5; q++)
   {
      bool closedIntra = false;
      if(open >= 0 && q > LowerBound(t5, n5, trEnt[open]))
      {
         bool timeout = (t5[q] - trEnt[open]) >= HoldBars * 300;
         bool wk = IsWeekendClose(t5[q]);
         if(timeout || wk)
         {
            double px = (trDir[open] == 1) ? o5[q] : o5[q] + SpreadAssumed;
            CloseTrade(open, px, timeout ? 3 : 4, t5[q]);
            open = -1;
         }
      }
      if(open >= 0)
      {
         if(CheckExit(open, q)) { open = -1; closedIntra = true; }
      }
      if(open >= 0 || closedIntra) continue;

      int s = q - 1;
      for(int z = 0; z < nz; z++)
      {
         if(zUsed[z] || zA5[z] > s) continue;
         if(s + 1 - zA5[z] > ExpireBars || zBrk[z] <= s || (t5[q] - zAct[z]) > ExpireBars * 300 + 7200)
         {
            zUsed[z] = true;
            continue;
         }
         bool sig; double slv;
         if(zDir[z] == 1)
         {
            sig = (l5[s] <= zHi[z]) && (!NeedColor || c5[s] > o5[s]) && SMTOk(s, 1);
            slv = l5[s] - SLFixPts;
         }
         else
         {
            sig = (h5[s] >= zLo[z]) && (!NeedColor || c5[s] < o5[s]) && SMTOk(s, -1);
            slv = h5[s] + SLFixPts;
         }
         if(!sig) continue;
         zUsed[z] = true;
         if(IsFriBlock(t5[q])) break;
         int d = zDir[z];
         double price = (d == 1) ? o5[q] + SpreadAssumed : o5[q];   // MARKET: BUY au Ask, SELL au Bid
         double risk = MathAbs(price - slv);
         if((d == 1 && slv >= price) || (d == -1 && slv <= price) || risk <= 0.0) break;
         if(MaxRiskPts > 0.0 && risk > MaxRiskPts) break;
         double tp = price + d * RR * risk;
         AddTrade(z, d, t5[s], t5[q], price, slv, tp, risk);
         open = nt - 1;
         if(CheckExit(open, q)) { open = -1; }              // la bougie d'entree compte aussi
         break;
      }
   }
}

//+------------------------------------------------------------------+
void Line(string name, datetime t1, datetime t2, double price, color clr, ENUM_LINE_STYLE st, int w)
{
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, st);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void Txt(string name, datetime t, double price, string txt, color clr)
{
   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void Zone(string name, datetime t1, double p1, datetime t2, double p2, color clr)
{
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

string ResText(int r)
{
   if(r == 1) return("TP");
   if(r == 2) return("SL");
   if(r == 3) return("TIMEOUT");
   if(r == 4) return("WEEKEND");
   return("OPEN");
}

void DrawAll()
{
   ObjectsDeleteAll(0, PFX);
   datetime tNow = t5[n5 - 1];
   datetime tFar = tNow + 12 * 300;
   bool zoneDrawn[];
   ArrayResize(zoneDrawn, MathMax(nz, 1));
   for(int z = 0; z < nz; z++) zoneDrawn[z] = false;

   for(int i = 0; i < nt; i++)
   {
      color c = (trDir[i] == 1) ? BuyColor : SellColor;
      string id = PFX + IntegerToString(i);
      datetime tEnd = (trRes[i] == 0) ? tFar : trEnd[i] + 300;
      int z = trZone[i];
      Zone(id + "_z", zOB[z], zHi[z], tEnd, zLo[z], c);
      zoneDrawn[z] = true;
      ENUM_OBJECT ot = (trDir[i] == 1) ? OBJ_ARROW_BUY : OBJ_ARROW_SELL;
      ObjectCreate(0, id + "_a", ot, 0, trEnt[i], trPrice[i]);
      ObjectSetInteger(0, id + "_a", OBJPROP_COLOR, c);
      Line(id + "_en", trEnt[i], tEnd, trPrice[i], c, STYLE_SOLID, 2);
      Line(id + "_sl", trEnt[i], tEnd, trSL[i], clrRed, STYLE_DOT, 1);
      Line(id + "_tp", trEnt[i], tEnd, trTP[i], clrLime, STYLE_SOLID, 2);
      string side = (trDir[i] == 1) ? "BUY MARKET " : "SELL MARKET ";
      Txt(id + "_ten", trEnt[i], trPrice[i], side + DoubleToString(trPrice[i], _Digits), c);
      Txt(id + "_tsl", trEnt[i], trSL[i], "SL " + DoubleToString(trSL[i], _Digits), clrRed);
      Txt(id + "_ttp", trEnt[i], trTP[i], "TP 1:" + DoubleToString(RR, 1) + " " + DoubleToString(trTP[i], _Digits), clrLime);
      if(ShowOutcome)
      {
         string rt = ResText(trRes[i]);
         if(trRes[i] != 0) rt += "  " + (trR[i] >= 0 ? "+" : "") + DoubleToString(trR[i], 2) + "R";
         Txt(id + "_res", tEnd, trPrice[i], rt, (trRes[i] == 1 ? clrLime : (trRes[i] == 2 ? clrRed : clrSilver)));
      }
   }
   // zones actives (en attente d'une touche)
   for(int z = 0; z < nz; z++)
   {
      if(zoneDrawn[z]) continue;
      bool active = !zUsed[z] && zA5[z] <= n5 - 1 && (tNow - zAct[z]) <= ExpireBars * 300 + 7200 && zBrk[z] > n5 - 1;
      if(!active && !ShowAllZones) continue;
      color c = (zDir[z] == 1) ? BuyColor : SellColor;
      Zone(PFX + "zz" + IntegerToString(z), zOB[z], zHi[z], active ? tFar : zAct[z], zLo[z], active ? c : clrDimGray);
   }
}

//+------------------------------------------------------------------+
void AddLine(string t, color c = clrWhite)
{
   ArrayResize(Lines, nLines + 1); ArrayResize(Cols, nLines + 1);
   Lines[nLines] = t; Cols[nLines] = c; nLines++;
}

string F(double v, int d = 1) { return DoubleToString(v, d); }
string SR(double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2) + "R"; }

void Dashboard()
{
   ObjectsDeleteAll(0, "OB30D_");
   if(!ShowDashboard) return;
   nLines = 0;
   int w = 0, l = 0, o = 0, nAct = 0;
   double totR = 0, gp = 0, gl = 0;
   for(int i = 0; i < nt; i++)
   {
      if(trRes[i] == 0) { o++; continue; }
      totR += trR[i];
      if(trR[i] > 0) { w++; gp += trR[i]; } else { l++; gl += -trR[i]; }
   }
   int closed = w + l;
   double pf = (gl > 0) ? gp / gl : (gp > 0 ? 99.9 : 0);
   for(int z = 0; z < nz; z++)
      if(!zUsed[z] && zA5[z] <= n5 - 1 && (t5[n5 - 1] - zAct[z]) <= ExpireBars * 300 + 7200 && zBrk[z] > n5 - 1) nAct++;

   AddLine("OB30 SIGNALS v3  " + _Symbol + "  (M30 OB + M5 SMT)", clrAqua);
   AddLine("TYPE D'ORDRE: MARCHE (market) a l'ouverture de la", clrYellow);
   AddLine("bougie M5 suivante. BUY=Ask  SELL=Bid  (pas de limit)", clrYellow);
   AddLine("SL = meche bougie signal " + F(SLFixPts, 1) + " | TP = " + F(RR, 1) + "R", clrWhite);
   AddLine("SMT: " + (UseSMT ? ("ON " + g_silver + " win " + IntegerToString(SMTWindow)) : "OFF") +
           " | couleur: " + (NeedColor ? "oui" : "non"), clrWhite);
   if(UseSMT && nS <= 0) AddLine("!! Pas de donnees " + g_silver + " (M5): verifier le nom du symbole !!", clrTomato);
   AddLine("Donnees: M5 " + IntegerToString(n5) + " | M30 " + IntegerToString(g_n30) + " | " + g_silver + " " + IntegerToString(nS), clrSilver);
   AddLine("-----------------------------------------------", clrDimGray);
   AddLine("Zones OB actives (en attente): " + IntegerToString(nAct), clrWhite);
   AddLine("SIGNAUX: " + IntegerToString(nt) + "  TP " + IntegerToString(w) + "  SL " + IntegerToString(l) + "  ouvert " + IntegerToString(o), clrWhite);
   AddLine("Win% " + F(closed > 0 ? 100.0 * w / closed : 0, 1) + "  Total " + SR(totR) + "  PF " + F(pf, 2),
           (totR >= 0 ? clrLime : clrTomato));
   AddLine("(simulation M5, spread " + F(SpreadAssumed, 2) + ")", clrSilver);
   AddLine("-----------------------------------------------", clrDimGray);
   if(nt > 0)
   {
      int i = nt - 1;
      AddLine("DERNIER SIGNAL", clrAqua);
      AddLine((trDir[i] == 1 ? "BUY MARKET  " : "SELL MARKET ") + TimeToString(trEnt[i], TIME_DATE | TIME_MINUTES),
              (trDir[i] == 1 ? BuyColor : SellColor));
      AddLine("Entry " + DoubleToString(trPrice[i], _Digits) + "  SL " + DoubleToString(trSL[i], _Digits) +
              "  TP " + DoubleToString(trTP[i], _Digits), clrWhite);
      AddLine("Statut: " + ResText(trRes[i]) + (trRes[i] != 0 ? ("  " + SR(trR[i])) : ""), clrYellow);
   }
   else AddLine("Aucun signal sur la periode analysee", clrSilver);
   AddLine("Sans filtres EA: perte jour 2% / 3 pertes de suite", clrDimGray);
   AddLine("Aide visuelle, pas un conseil financier", clrDimGray);

   int h = nLines * 15 + 12;
   ObjectCreate(0, "OB30D_bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_XDISTANCE, DashX);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_YDISTANCE, DashY);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_XSIZE, 440);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_YSIZE, h);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_BGCOLOR, C'18,22,30');
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_BACK, false);
   ObjectSetInteger(0, "OB30D_bg", OBJPROP_SELECTABLE, false);
   for(int k = 0; k < nLines; k++)
   {
      string nm = "OB30D_l" + IntegerToString(k);
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, DashX + 8);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, DashY + 6 + k * 15);
      ObjectSetString(0, nm, OBJPROP_TEXT, Lines[k]);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, Cols[k]);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
bool LoadData()
{
   MqlRates r5[], r30[], rs[];
   ArraySetAsSeries(r5, false); ArraySetAsSeries(r30, false); ArraySetAsSeries(rs, false);
   int got5 = CopyRates(_Symbol, PERIOD_M5, 0, HistoryBars, r5);
   if(got5 < 2 * SMTWindow + 10)
   {
      g_why = "M5 " + _Symbol + ": " + IntegerToString(got5) + " barres (historique en cours de chargement)";
      return(false);
   }
   if(r5[got5 - 1].time != iTime(_Symbol, PERIOD_M5, 0)) { g_why = "M5: historique pas encore a jour"; return(false); }
   n5 = got5;
   g_incomplete = (got5 < HistoryBars && got5 < iBars(_Symbol, PERIOD_M5));
   ArrayResize(t5, n5); ArrayResize(o5, n5); ArrayResize(h5, n5); ArrayResize(l5, n5); ArrayResize(c5, n5);
   for(int i = 0; i < n5; i++) { t5[i] = r5[i].time; o5[i] = r5[i].open; h5[i] = r5[i].high; l5[i] = r5[i].low; c5[i] = r5[i].close; }
   datetime tStop = t5[n5 - 1] + 3600;
   datetime t30Start = t5[0] - 60 * 1800;

   int got30 = CopyRates(_Symbol, PERIOD_M30, t30Start, tStop, r30);
   if(got30 < 20) { g_why = "M30 " + _Symbol + ": " + IntegerToString(got30) + " barres (chargement)"; return(false); }
   if(r30[got30 - 1].time < t5[n5 - 1] - 1800) { g_why = "M30 pas encore a jour"; return(false); }
   g_n30 = got30;

   nS = 0;
   if(UseSMT)
   {
      datetime tsStart = t5[0] - 3600;
      int gs = CopyRates(g_silver, PERIOD_M5, tsStart, tStop, rs);
      if(gs > 2 * SMTWindow && rs[gs - 1].time >= t5[n5 - 1] - 6 * 3600)
      {
         nS = gs;
         ArrayResize(ts, nS); ArrayResize(hs, nS); ArrayResize(ls, nS);
         for(int i = 0; i < nS; i++) { ts[i] = rs[i].time; hs[i] = rs[i].high; ls[i] = rs[i].low; }
      }
      else
      {
         g_why = "argent " + g_silver + ": " + IntegerToString(gs) + " barres M5";
         if(gs > 0) g_why += " (derniere " + TimeToString(rs[gs - 1].time) + ")";
      }
   }
   BuildZones(r30, got30);
   for(int z = 0; z < nz; z++)
   {
      zA5[z] = LowerBound(t5, n5, zAct[z]);
      zBrk[z] = 1000000000;
      for(int q = zA5[z]; q < n5; q++)
      {
         if((zDir[z] == 1 && c5[q] < zLo[z]) || (zDir[z] == -1 && c5[q] > zHi[z])) { zBrk[z] = q; break; }
      }
   }
   return(true);
}

void StatusLabel(string nm, int row, string msg, color clr)
{
   ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, DashX);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, DashY + row * 16);
   ObjectSetString(0, nm, OBJPROP_TEXT, msg);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
}

void ShowStatus(string l1, string l2)
{
   if(!ShowDashboard) return;
   ObjectsDeleteAll(0, "OB30D_");
   StatusLabel("OB30D_l0", 0, l1, clrYellow);
   if(l2 != "") StatusLabel("OB30D_l1", 1, l2, clrYellow);
}

void Refresh(bool force)
{
   static uint lastTry = 0;
   datetime cur = iTime(_Symbol, PERIOD_M5, 0);
   if(cur == 0)
   {
      Note("attente de l'historique M5 de " + _Symbol);
      ShowStatus("OB30 v3: attente de l'historique M5 de " + _Symbol + "...", "");
      return;
   }
   if(!force && cur == lastSig && !g_incomplete) return;       // une evaluation par bougie M5
   uint now = GetTickCount();
   if(now - lastTry < 2000) return;                            // limite les essais
   lastTry = now;

   if(!LoadData())
   {
      Note(g_why);
      ShowStatus("OB30 v3: chargement des donnees...", g_why);
      return;
   }
   if(UseSMT && nS <= 0)
   {
      if(now - g_lastResolve > 30000)                          // on re-cherche le symbole argent de temps en temps
      {
         g_lastResolve = now;
         string again = ResolveSilver();
         if(again != g_silver) { g_silver = again; Note("symbole argent = " + g_silver); }
      }
      Note(g_why);
      ShowStatus("OB30 v3: pas de donnees argent (" + g_silver + ")", g_why + " | ouvrez son graphique M5");
      return;                                                  // reessai au prochain timer
   }
   Note("OK: " + IntegerToString(n5) + " barres M5, " + IntegerToString(g_n30) + " M30, argent " + g_silver + " " + IntegerToString(nS));
   lastSig = t5[n5 - 1];
   Simulate();
   DrawAll();
   Dashboard();

   // alerte: trade dont l'entree est la bougie M5 qui vient de s'ouvrir
   if(AlertOnSignal && nt > 0)
   {
      int i = nt - 1;
      if(trEnt[i] == t5[n5 - 1] && trEnt[i] != lastAlert)
      {
         lastAlert = trEnt[i];
         Alert(_Symbol, (trDir[i] == 1 ? " BUY MARKET " : " SELL MARKET "), DoubleToString(trPrice[i], _Digits),
               "  SL ", DoubleToString(trSL[i], _Digits), "  TP ", DoubleToString(trTP[i], _Digits));
      }
   }
   ChartRedraw();
}

void OnTimer() { Refresh(false); }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   Refresh(prev_calculated == 0);
   return(rates_total);
}
