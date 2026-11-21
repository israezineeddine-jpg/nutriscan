//+------------------------------------------------------------------+
//| OB_CHoCH_M1.mq5                                                  |
//| Zone Order Block M30 (definition OB30) + entree CHoCH en M1      |
//| Memes regles que backtest/ob_choch/ob_choch.py (backtest Python) |
//| A attacher sur XAUUSD (n'importe quelle unite: l'EA lit M1/M30)  |
//+------------------------------------------------------------------+
#property strict
#property version     "1.00"
#property description "OB M30 + CHoCH M1 : SL au-dela de la zone, TP = RR x risque, ordre au marche"
#include <Trade/Trade.mqh>

enum ENUM_SERVER_CLOCK
{
   CLOCK_NY_PLUS_7 = 0,   // serveur = New York + 7h (FTMO, IC Markets...)
   CLOCK_FIXED     = 1    // serveur = UTC + decalage fixe (Exness = 0)
};

input double RiskPercent     = 0.5;    // Risque par trade (% du solde)
input double RR              = 4.0;    // TP = RR x risque
input double SLBuffer        = 1.0;    // SL au-dela de la zone ($)
input int    SwingBars       = 3;      // CHoCH : swing de N bougies M1 de chaque cote
input int    VisitBars       = 15;     // fin de visite apres N bougies M1 sans toucher la zone
input double MinRiskUSD      = 1.0;    // distance SL minimum ($)
input double MaxRiskUSD      = 20.0;   // distance SL maximum ($)
input int    SessionStartUTC = 7;      // entrees a partir de (heure UTC)
input int    SessionEndUTC   = 21;     // entrees avant (heure UTC)
input int    MaxHoldHours    = 24;     // duree maximum d'un trade (heures)
input int    ZoneLifeHours   = 50;     // duree de vie d'une zone (heures)
input int    ZoneGapBars     = 3;      // bougies M30 minimum entre 2 zones du meme sens
input ENUM_SERVER_CLOCK ServerClock = CLOCK_NY_PLUS_7; // heure du serveur
input int    ServerUTCOffset = 0;      // si decalage fixe : heure serveur - UTC (Exness = 0)
input double MaxSpreadUSD    = 0.0;    // pas d'entree si spread > ($), 0 = pas de filtre
input bool   ShowZones       = true;   // dessiner les zones
input long   Magic           = 20261122;

struct Zone
{
   int      dir;        // 1 = achat (OB haussier), -1 = vente
   double   lo;
   double   hi;
   datetime obTime;     // ouverture de la bougie OB (M30)
   datetime act;        // activation = cloture de la 3e bougie apres l'OB
   bool     done;       // CHoCH trouve, zone cassee ou expiree
   bool     armed;      // visite en cours
   long     vstart;     // index M1 (absolu) de la 1re touche de la visite
   long     lastTouch;
   long     extI;       // index M1 du sweep (extreme de la visite)
   double   extV;
   string   name;
};

CTrade   trade;
Zone     zones[];
int      nZones = 0;

// bougies M1 cloturees ; index absolu = g_base + index local
datetime bT[];
double   bO[], bH[], bL[], bC[];
int      nb = 0;
long     g_base = 0;

datetime lastM1Open = 0;     // ouverture de la derniere bougie M1 vue
datetime lastAppended = 0;   // ouverture de la derniere bougie M1 ajoutee au buffer
datetime lastM30Check = 0;
datetime lastBullOB = 0, lastBearOB = 0;
datetime posEntryBar = 0;
int      nSignals = 0, nTrades = 0;

//====================================================================
// Heure : serveur -> UTC / New York (heure d'ete americaine)
//====================================================================
datetime NthSunday(int year, int mon, int nth)
{
   MqlDateTime s;
   s.year = year; s.mon = mon; s.day = 1; s.hour = 0; s.min = 0; s.sec = 0;
   datetime d1 = StructToTime(s);
   MqlDateTime k;
   TimeToStruct(d1, k);
   int first = 1 + (7 - k.day_of_week) % 7;
   return d1 + (datetime)((first - 1 + 7 * (nth - 1)) * 86400);
}

bool UsDst(datetime utc)
{
   MqlDateTime s;
   TimeToStruct(utc, s);
   datetime a = NthSunday(s.year, 3, 2) + 7 * 3600;    // 2h00 heure d'hiver New York
   datetime b = NthSunday(s.year, 11, 1) + 6 * 3600;   // 2h00 heure d'ete New York
   return (utc >= a && utc < b);
}

datetime ToUTC(datetime server)
{
   if(ServerClock == CLOCK_FIXED)
      return server - (datetime)ServerUTCOffset * 3600;
   datetime guess = server - 2 * 3600;                  // hiver : serveur = UTC+2
   if(UsDst(guess))
      return server - 3 * 3600;                         // ete : serveur = UTC+3
   return guess;
}

datetime ToNY(datetime server)
{
   datetime u = ToUTC(server);
   if(UsDst(u))
      return u - 4 * 3600;
   return u - 5 * 3600;
}

//====================================================================
// Buffer des bougies M1 cloturees
//====================================================================
int KeepBars() { return ZoneLifeHours * 60 + 4 * VisitBars + 4 * SwingBars + 500; }

datetime BT(long a) { return bT[(int)(a - g_base)]; }
double   BH(long a) { return bH[(int)(a - g_base)]; }
double   BL(long a) { return bL[(int)(a - g_base)]; }
double   BC(long a) { return bC[(int)(a - g_base)]; }
long     LastIdx()  { return g_base + nb - 1; }

void AppendBar(datetime t, double o, double h, double l, double c)
{
   int cap = ArraySize(bT);
   if(nb >= cap)
   {
      int keep = KeepBars();
      if(cap >= 4 * keep)
      {
         int drop = nb - keep;
         for(int i = 0; i < keep; i++)
         {
            bT[i] = bT[i + drop]; bO[i] = bO[i + drop]; bH[i] = bH[i + drop];
            bL[i] = bL[i + drop]; bC[i] = bC[i + drop];
         }
         nb = keep;
         g_base += drop;
      }
      else
      {
         int nc = cap * 2;
         if(nc < 1024) nc = 1024;
         ArrayResize(bT, nc); ArrayResize(bO, nc); ArrayResize(bH, nc); ArrayResize(bL, nc); ArrayResize(bC, nc);
      }
   }
   bT[nb] = t; bO[nb] = o; bH[nb] = h; bL[nb] = l; bC[nb] = c;
   nb++;
   lastAppended = t;
}

//====================================================================
// Swings (fractal de N bougies de chaque cote)
//====================================================================
bool IsPivotHigh(long k)
{
   int N = SwingBars;
   if(k - N < g_base || k + N > LastIdx()) return false;
   double v = BH(k);
   for(int i = 1; i <= N; i++)
   {
      if(BH(k - i) >= v) return false;   // bougies avant : strictement plus basses
      if(BH(k + i) > v)  return false;   // bougies apres : plus basses ou egales
   }
   return true;
}

bool IsPivotLow(long k)
{
   int N = SwingBars;
   if(k - N < g_base || k + N > LastIdx()) return false;
   double v = BL(k);
   for(int i = 1; i <= N; i++)
   {
      if(BL(k - i) <= v) return false;
      if(BL(k + i) < v)  return false;
   }
   return true;
}

// dernier swing high (index <= lim, >= kmin) qui est le sommet de la jambe jusqu'au sweep extI
long RefHigh(long lim, long extI, long kmin)
{
   double runMax = -DBL_MAX;
   for(long i = lim + 1; i <= extI; i++)
      if(BH(i) > runMax) runMax = BH(i);
   for(long k = lim; k >= kmin && k - SwingBars >= g_base; k--)
   {
      double v = BH(k);
      if(v >= runMax && IsPivotHigh(k)) return k;
      if(v > runMax) runMax = v;
   }
   return -1;
}

long RefLow(long lim, long extI, long kmin)
{
   double runMin = DBL_MAX;
   for(long i = lim + 1; i <= extI; i++)
      if(BL(i) < runMin) runMin = BL(i);
   for(long k = lim; k >= kmin && k - SwingBars >= g_base; k--)
   {
      double v = BL(k);
      if(v <= runMin && IsPivotLow(k)) return k;
      if(v < runMin) runMin = v;
   }
   return -1;
}

//====================================================================
// Zones
//====================================================================
void DrawZone(Zone &z)
{
   if(!ShowZones || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   z.name = "OBC_" + IntegerToString((long)z.obTime) + "_" + IntegerToString(z.dir);
   datetime t2 = z.act + (datetime)ZoneLifeHours * 3600;
   if(ObjectCreate(0, z.name, OBJ_RECTANGLE, 0, z.obTime, z.hi, t2, z.lo))
   {
      ObjectSetInteger(0, z.name, OBJPROP_COLOR, z.dir == 1 ? C'46,139,87' : C'205,92,92');
      ObjectSetInteger(0, z.name, OBJPROP_FILL, 1);
      ObjectSetInteger(0, z.name, OBJPROP_BACK, 1);
      ObjectSetInteger(0, z.name, OBJPROP_SELECTABLE, 0);
   }
}

void EndZoneDraw(Zone &z, datetime t)
{
   if(!ShowZones || MQLInfoInteger(MQL_OPTIMIZATION) || StringLen(z.name) == 0) return;
   ObjectSetInteger(0, z.name, OBJPROP_TIME, 1, t);
}

void AddZone(int dir, double lo, double hi, datetime obTime, datetime act)
{
   ArrayResize(zones, nZones + 1);
   zones[nZones].dir = dir;
   zones[nZones].lo = lo;
   zones[nZones].hi = hi;
   zones[nZones].obTime = obTime;
   zones[nZones].act = act;
   zones[nZones].done = false;
   zones[nZones].armed = false;
   zones[nZones].vstart = -1;
   zones[nZones].lastTouch = -1;
   zones[nZones].extI = -1;
   zones[nZones].extV = 0.0;
   zones[nZones].name = "";
   DrawZone(zones[nZones]);
   nZones++;
}

void CompactZones()
{
   int k = 0;
   for(int i = 0; i < nZones; i++)
   {
      if(zones[i].done) continue;
      if(k != i) zones[k] = zones[i];
      k++;
   }
   if(k != nZones)
   {
      nZones = k;
      ArrayResize(zones, nZones);
   }
}

bool GapOK(datetime lastOB, int shiftP)
{
   if(lastOB == 0) return true;
   int sh = iBarShift(_Symbol, PERIOD_M30, lastOB, false);
   if(sh < 0) return true;
   return (sh - shiftP) > ZoneGapBars;
}

// r[0..12] = 13 bougies M30 cloturees (r[9] = bougie OB p, r[10..12] = p+1..p+3), shiftP = decalage de p
void TestPattern(MqlRates &r[], int shiftP)
{
   int p = 9;
   double hh = r[0].high, ll = r[0].low;
   for(int i = 1; i <= p; i++)
   {
      if(r[i].high > hh) hh = r[i].high;
      if(r[i].low < ll)  ll = r[i].low;
   }
   double maxC = MathMax(r[p + 1].close, MathMax(r[p + 2].close, r[p + 3].close));
   double minC = MathMin(r[p + 1].close, MathMin(r[p + 2].close, r[p + 3].close));
   datetime act = r[p + 3].time + PeriodSeconds(PERIOD_M30);
   if(r[p].close < r[p].open && r[p + 1].close > r[p + 1].open)
   {
      if(maxC > hh && GapOK(lastBullOB, shiftP))
      {
         lastBullOB = r[p].time;
         AddZone(1, r[p].low, r[p].high, r[p].time, act);
      }
   }
   else if(r[p].close > r[p].open && r[p + 1].close < r[p + 1].open)
   {
      if(minC < ll && GapOK(lastBearOB, shiftP))
      {
         lastBearOB = r[p].time;
         AddZone(-1, r[p].low, r[p].high, r[p].time, act);
      }
   }
}

void CheckM30()
{
   datetime t30 = iTime(_Symbol, PERIOD_M30, 0);
   if(t30 == 0 || t30 == lastM30Check) return;
   MqlRates r[];
   if(CopyRates(_Symbol, PERIOD_M30, 1, 13, r) != 13) return;   // historique pas pret : on reessaie au prochain tick
   lastM30Check = t30;
   TestPattern(r, 4);
}

// une bougie M1 cloturee (index j) pour une zone ; true = CHoCH (entree a l'ouverture de la bougie suivante)
bool StepZone(Zone &z, long j)
{
   int  N  = SwingBars;
   int  W  = VisitBars;
   long LB = 2 * W;
   double c = BC(j), h = BH(j), l = BL(j);
   if(z.dir == 1)
   {
      if(c < z.lo) { z.done = true; return false; }            // cloture sous la zone : zone cassee
      if(l <= z.hi)
      {
         if(!z.armed) { z.armed = true; z.vstart = j; z.extV = l; z.extI = j; }
         z.lastTouch = j;
      }
      if(!z.armed) return false;
      if(l < z.extV) { z.extV = l; z.extI = j; }
      if(j - z.lastTouch > W) { z.armed = false; return false; }
      if(j <= z.extI) return false;
      long lim = (z.extI - 1 < j - N) ? z.extI - 1 : j - N;
      long k = RefHigh(lim, z.extI, z.vstart - LB);
      if(k >= 0 && c > BH(k)) { z.done = true; return true; }
   }
   else
   {
      if(c > z.hi) { z.done = true; return false; }
      if(h >= z.lo)
      {
         if(!z.armed) { z.armed = true; z.vstart = j; z.extV = h; z.extI = j; }
         z.lastTouch = j;
      }
      if(!z.armed) return false;
      if(h > z.extV) { z.extV = h; z.extI = j; }
      if(j - z.lastTouch > W) { z.armed = false; return false; }
      if(j <= z.extI) return false;
      long lim = (z.extI - 1 < j - N) ? z.extI - 1 : j - N;
      long k = RefLow(lim, z.extI, z.vstart - LB);
      if(k >= 0 && c < BL(k)) { z.done = true; return true; }
   }
   return false;
}

//====================================================================
// Positions et ordres
//====================================================================
bool SelectPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) return true;
   }
   return false;
}

double CalcLots(double risk)
{
   double money = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || risk <= 0) return 0.0;
   double lots = money / (risk / ts * tv);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lots = MathFloor(lots / step) * step;
   if(lots < vmin) return 0.0;
   if(lots > vmax) lots = vmax;
   return lots;
}

// signal sur une zone : entree au marche a l'ouverture de la bougie M1 en cours (barOpen)
bool TryEntry(Zone &z, datetime barOpen)
{
   if(SelectPosition()) return false;                       // une seule position a la fois
   MqlDateTime u;
   TimeToStruct(ToUTC(barOpen), u);
   if(u.day_of_week == 5 && u.hour >= 18) return false;     // vendredi apres 18h UTC
   if(u.hour < SessionStartUTC || u.hour >= SessionEndUTC) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return false;
   if(MaxSpreadUSD > 0 && ask - bid > MaxSpreadUSD) return false;
   double price = (z.dir == 1) ? ask : bid;
   double sl    = (z.dir == 1) ? z.lo - SLBuffer : z.hi + SLBuffer;
   double risk  = (z.dir == 1) ? price - sl : sl - price;
   if(risk < MinRiskUSD || risk > MaxRiskUSD) return false;
   double tp = price + z.dir * RR * risk;
   double lots = CalcLots(risk);
   if(lots <= 0)
   {
      Print("OB_CHoCH: lot trop petit pour le risque ", DoubleToString(risk, 2), " $ - pas de trade");
      return false;
   }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   bool ok;
   if(z.dir == 1) ok = trade.Buy(lots, _Symbol, 0, sl, tp, "OBCHoCH B");
   else           ok = trade.Sell(lots, _Symbol, 0, sl, tp, "OBCHoCH S");
   if(ok)
   {
      posEntryBar = barOpen;
      nTrades++;
      Print("OB_CHoCH: ", z.dir == 1 ? "BUY" : "SELL", " zone [", DoubleToString(z.lo, _Digits), " - ",
            DoubleToString(z.hi, _Digits), "] sl=", DoubleToString(sl, _Digits), " tp=", DoubleToString(tp, _Digits),
            " risque=", DoubleToString(risk, 2), "$ lots=", DoubleToString(lots, 2));
   }
   else
      Print("OB_CHoCH: ordre refuse ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   return ok;
}

// a l'ouverture d'une nouvelle bougie M1 : duree maximum et fermeture du vendredi
void ManagePosition(datetime barOpen)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      datetime entryBar = (posEntryBar > 0 && posEntryBar <= opened && opened - posEntryBar < 60) ? posEntryBar : opened - opened % 60;
      bool timeUp = barOpen >= entryBar + (datetime)MaxHoldHours * 3600;
      MqlDateTime ny;
      TimeToStruct(ToNY(barOpen), ny);
      bool friClose = (ny.day_of_week == 5 && ny.hour * 60 + ny.min >= 16 * 60 + 30);
      if(timeUp || friClose)
      {
         if(!trade.PositionClose(tk))
            Print("OB_CHoCH: fermeture refusee ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// Traitement d'une bougie M1 cloturee pour toutes les zones
//====================================================================
void ProcessBar(long j, bool canTrade, datetime entryBarOpen)
{
   datetime tj = BT(j);
   for(int i = 0; i < nZones; i++)
   {
      if(zones[i].done) continue;
      if(tj < zones[i].act) continue;
      if(tj > zones[i].act + (datetime)ZoneLifeHours * 3600)
      {
         zones[i].done = true;
         EndZoneDraw(zones[i], tj);
         continue;
      }
      if(StepZone(zones[i], j))
      {
         nSignals++;
         EndZoneDraw(zones[i], tj);
         if(canTrade) TryEntry(zones[i], entryBarOpen);
      }
      else if(zones[i].done)
         EndZoneDraw(zones[i], tj);
   }
   CompactZones();
}

// ajoute les bougies M1 cloturees manquantes ; seule la derniere peut donner une entree (a l'ouverture de barOpen)
void UpdateM1(datetime barOpen, bool canTrade)
{
   MqlRates r[];
   int got = CopyRates(_Symbol, PERIOD_M1, 1, 200, r);
   if(got <= 0) return;
   for(int i = 0; i < got; i++)
   {
      if(r[i].time <= lastAppended) continue;
      AppendBar(r[i].time, r[i].open, r[i].high, r[i].low, r[i].close);
      ProcessBar(LastIdx(), canTrade && i == got - 1, barOpen);
   }
}

//====================================================================
// Demarrage : zones encore vivantes et etat des visites (sans trader)
//====================================================================
void WarmStart()
{
   int keep = KeepBars();
   MqlRates m1[];
   int got1 = CopyRates(_Symbol, PERIOD_M1, 1, keep, m1);
   if(got1 <= 0) return;
   datetime first = m1[0].time;
   // zones M30 dont la duree de vie touche la fenetre M1 chargee
   int need = ZoneLifeHours * 2 + 13 + ZoneGapBars + 20;
   MqlRates m30[];
   int got30 = CopyRates(_Symbol, PERIOD_M30, 1, need + 13, m30);
   if(got30 >= 13)
   {
      MqlRates w[];
      ArrayResize(w, 13);
      for(int e = 12; e < got30; e++)              // e = index de p+3
      {
         for(int q = 0; q < 13; q++) w[q] = m30[e - 12 + q];
         int shiftP = (got30 - 1 - (e - 3)) + 1;      // decalage actuel de la bougie p
         int before = nZones;
         TestPattern(w, shiftP);
         if(nZones > before && zones[nZones - 1].act + (datetime)ZoneLifeHours * 3600 < first)
            zones[nZones - 1].done = true;            // zone deja expiree
      }
      lastM30Check = iTime(_Symbol, PERIOD_M30, 0);
   }
   for(int i = 0; i < got1; i++)
   {
      AppendBar(m1[i].time, m1[i].open, m1[i].high, m1[i].low, m1[i].close);
      ProcessBar(LastIdx(), false, 0);
   }
   Print("OB_CHoCH: demarrage, ", got1, " bougies M1 chargees, ", nZones, " zones actives");
}

//====================================================================
// Export des trades (dossier Files du testeur ou du terminal)
//====================================================================
void ExportTrades()
{
   if(!HistorySelect(0, TimeCurrent())) return;
   int h = FileOpen("OB_CHoCH_trades.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "position", "open_time", "close_time", "side", "volume", "open_price", "close_price", "sl", "tp",
             "profit", "commission", "swap", "close_comment");
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != Magic || HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      long pos = HistoryDealGetInteger(tk, DEAL_POSITION_ID);
      // deal d'entree de la meme position
      ulong tin = 0;
      for(int k = i - 1; k >= 0; k--)
      {
         ulong t2 = HistoryDealGetTicket(k);
         if(HistoryDealGetInteger(t2, DEAL_POSITION_ID) == pos && HistoryDealGetInteger(t2, DEAL_ENTRY) == DEAL_ENTRY_IN) { tin = t2; break; }
      }
      if(tin == 0) continue;
      int side = (HistoryDealGetInteger(tin, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : -1;
      FileWrite(h, IntegerToString(pos),
                TimeToString((datetime)HistoryDealGetInteger(tin, DEAL_TIME), TIME_DATE | TIME_SECONDS),
                TimeToString((datetime)HistoryDealGetInteger(tk, DEAL_TIME), TIME_DATE | TIME_SECONDS),
                IntegerToString(side), DoubleToString(HistoryDealGetDouble(tin, DEAL_VOLUME), 2),
                DoubleToString(HistoryDealGetDouble(tin, DEAL_PRICE), _Digits),
                DoubleToString(HistoryDealGetDouble(tk, DEAL_PRICE), _Digits),
                DoubleToString(HistoryDealGetDouble(tin, DEAL_SL), _Digits),
                DoubleToString(HistoryDealGetDouble(tin, DEAL_TP), _Digits),
                DoubleToString(HistoryDealGetDouble(tk, DEAL_PROFIT), 2),
                DoubleToString(HistoryDealGetDouble(tin, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_COMMISSION), 2),
                DoubleToString(HistoryDealGetDouble(tk, DEAL_SWAP), 2),
                HistoryDealGetString(tk, DEAL_COMMENT));
   }
   FileClose(h);
}

//====================================================================
int OnInit()
{
   if(SwingBars < 1 || VisitBars < 1 || RR <= 0 || RiskPercent <= 0 || SessionEndUTC <= SessionStartUTC)
      return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);
   WarmStart();
   lastM1Open = iTime(_Symbol, PERIOD_M1, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ExportTrades();
   Print("OB_CHoCH: ", nSignals, " CHoCH, ", nTrades, " trades ouverts");
}

void OnTick()
{
   datetime t1 = iTime(_Symbol, PERIOD_M1, 0);
   if(t1 == 0 || t1 == lastM1Open) return;          // une fois par nouvelle bougie M1
   lastM1Open = t1;
   ManagePosition(t1);                              // duree max / vendredi (avant toute nouvelle entree)
   CheckM30();                                      // nouvelles zones
   UpdateM1(t1, true);                              // bougie M1 cloturee -> CHoCH -> entree au marche
}
//+------------------------------------------------------------------+
