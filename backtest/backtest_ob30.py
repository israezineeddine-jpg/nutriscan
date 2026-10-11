"""Replique Python de l'EA OB30_P1_M30_RR2.mq4 (OB M30 [+ M5] + entree M5 avec SMT Or vs Argent).

Usage:
  python backtest_ob30.py XAUUSDm_M30.csv XAUUSDm_M5.csv [XAGUSDm_M5.csv] [--preset 1..4] [--spread 0.35]
                          [--from 2026-03-27] [--to 2026-10-10]
Sans fichier argent, le filtre SMT est DESACTIVE (le resultat n'est alors PAS celui de l'EA).
Format CSV MT4: date;heure ou "2025.12.04,23:30,o,h,l,c,v" (sans en-tete).
"""
import sys
import numpy as np
import pandas as pd

PRESETS = {1: dict(m30=True, m5=False, rr=2.0, gap=3), 2: dict(m30=True, m5=True, rr=2.0, gap=3),
           3: dict(m30=True, m5=False, rr=3.0, gap=0), 4: dict(m30=True, m5=True, rr=3.0, gap=0)}


def load(p):
    d = pd.read_csv(p, header=None, names=["d", "t", "o", "h", "l", "c", "v"])
    d.index = pd.to_datetime(d.d + " " + d.t, format="%Y.%m.%d %H:%M")
    return d[["o", "h", "l", "c", "v"]]


def build_zones(df, tf_min, gap):
    """OB: derniere bougie inverse i, 1ere bougie suivante de la couleur du sens, et un des 3 closes
    suivants casse le plus haut/bas des 10 dernieres bougies (OB inclus). Pas d'ATR."""
    o, h, l, c = df.o.values, df.h.values, df.l.values, df.c.values
    t = df.index.values
    zones = []
    last_bull = last_bear = -10**9
    for p in range(9, len(df) - 3):
        hh = h[p - 9:p + 1].max(); ll = l[p - 9:p + 1].min()
        if c[p] < o[p] and c[p + 1] > o[p + 1]:
            if c[p + 1:p + 4].max() > hh and (p - last_bull) > gap:
                last_bull = p
                zones.append(dict(dir=1, lo=l[p], hi=h[p], act=t[p + 3] + np.timedelta64(tf_min, "m"), tf=tf_min))
        elif c[p] > o[p] and c[p + 1] < o[p + 1]:
            if c[p + 1:p + 4].min() < ll and (p - last_bear) > gap:
                last_bear = p
                zones.append(dict(dir=-1, lo=l[p], hi=h[p], act=t[p + 3] + np.timedelta64(tf_min, "m"), tf=tf_min))
    return zones


class Silver:
    def __init__(self, df):
        self.t = df.index.values; self.h = df.h.values; self.l = df.l.values

    def rng(self, ta, tb, fn, arr):
        a = np.searchsorted(self.t, ta, "left"); b = np.searchsorted(self.t, tb, "right")
        return fn(arr[a:b]) if b > a else None


def smt_ok(q, d, gold, silver, n=24):
    """SMT sur la bougie M5 q (derniere cloturee). d=1: haussier, -1: baissier."""
    if silver is None:
        return True
    if q - 2 * n + 1 < 0:
        return False
    t = gold["t"]
    ta1, tb1 = t[q - n + 1], t[q]
    ta0, tb0 = t[q - 2 * n + 1], t[q - n]
    if d == 1:
        g1 = gold["l"][q - n + 1:q + 1].min(); g0 = gold["l"][q - 2 * n + 1:q - n + 1].min()
        if not (gold["l"][q] <= g1 and g1 < g0):
            return False
        s1 = silver.rng(ta1, tb1, np.min, silver.l); s0 = silver.rng(ta0, tb0, np.min, silver.l)
        return s1 is not None and s0 is not None and s1 >= s0
    h1 = gold["h"][q - n + 1:q + 1].max(); h0 = gold["h"][q - 2 * n + 1:q - n + 1].max()
    if not (gold["h"][q] >= h1 and h1 > h0):
        return False
    s1 = silver.rng(ta1, tb1, np.max, silver.h); s0 = silver.rng(ta0, tb0, np.max, silver.h)
    return s1 is not None and s0 is not None and s1 <= s0


def run(m30, m5, silver_df=None, preset=1, spread=0.35, start=None, end=None, deposit=10000.0,
        risk_pct=0.5, sl_fix=2.0, max_risk=20.0, expire=576, hold=288, daily_loss=2.0, max_consec=3,
        fri_cut=18, fri_close_min=20 * 60 + 30, smt_win=24, contract=100.0, collect_candidates=False):
    P = PRESETS[preset]
    zones = []
    if P["m30"]:
        zones += build_zones(m30, 30, P["gap"])
    if P["m5"]:
        zones += build_zones(m5, 5, P["gap"])
    t5 = m5.index.values; o5, h5, l5, c5 = (m5[x].values for x in "ohlc")
    gold = dict(t=t5, h=h5, l=l5)
    silver = Silver(silver_df) if silver_df is not None else None
    for z in zones:
        z["a5"] = int(np.searchsorted(t5, z["act"], "left"))
        brk = np.where(c5[z["a5"]:] < z["lo"])[0] if z["dir"] == 1 else np.where(c5[z["a5"]:] > z["hi"])[0]
        z["brk"] = z["a5"] + int(brk[0]) if len(brk) else 10**9
        z["used"] = False
    zones.sort(key=lambda z: (z["tf"] != 30, z["act"]))        # ordre de l'EA: M30 puis M5
    ts = pd.DatetimeIndex(t5)
    wd, hr, mn = ts.weekday.values, ts.hour.values, ts.minute.values
    day = ts.normalize().values

    q0 = 0 if start is None else int(np.searchsorted(t5, np.datetime64(start)))
    q1 = len(t5) - 1 if end is None else int(np.searchsorted(t5, np.datetime64(end)))
    bal = deposit
    trades, cands = [], []
    pos = None
    today_closed = []                                              # (close_time, pnl) du jour
    cur_day = None
    for q in range(q0, q1):
        # ---- gestion de la position au debut de la bougie q (ManageOpen)
        if pos is not None and q > pos["q"]:
            timeout = (t5[q] - pos["t"]) >= np.timedelta64(hold * 300, "s")
            wk = wd[q] == 4 and (hr[q] * 60 + mn[q]) >= fri_close_min
            if timeout or wk:
                px = o5[q] if pos["d"] == 1 else o5[q] + spread
                pos["exit"], pos["why"], pos["tx"] = px, "timeout" if timeout else "weekend", t5[q]
        if pos is not None and "exit" not in pos:
            d = pos["d"]
            if d == 1:
                hit_sl = l5[q] <= pos["sl"]; hit_tp = h5[q] >= pos["tp"]
                if hit_sl:
                    pos["exit"] = min(pos["sl"], o5[q]); pos["why"] = "SL"
                elif hit_tp:
                    pos["exit"] = max(pos["tp"], o5[q]) if o5[q] >= pos["tp"] else pos["tp"]; pos["why"] = "TP"
            else:
                hit_sl = h5[q] + spread >= pos["sl"]; hit_tp = l5[q] + spread <= pos["tp"]
                if hit_sl:
                    pos["exit"] = max(pos["sl"], o5[q] + spread) if o5[q] + spread >= pos["sl"] else pos["sl"]; pos["why"] = "SL"
                elif hit_tp:
                    pos["exit"] = pos["tp"]; pos["why"] = "TP"
            if "exit" in pos:
                pos["tx"] = t5[q]
        closed_intrabar = pos is not None and "exit" in pos and pos["why"] in ("SL", "TP")
        if pos is not None and "exit" in pos:
            pnl = pos["d"] * (pos["exit"] - pos["entry"]) * pos["lots"] * contract
            bal += pnl
            trades.append(dict(open=pos["t"], close=pos["tx"], side=pos["d"], entry=pos["entry"], sl=pos["sl"],
                               tp=pos["tp"], exit=pos["exit"], why=pos["why"], lots=pos["lots"], pnl=pnl,
                               R=pos["d"] * (pos["exit"] - pos["entry"]) / pos["risk"]))
            today_closed.append((t5[q], pnl))
            pos = None
        if day[q] != cur_day:
            cur_day = day[q]; today_closed = [x for x in today_closed if x[0] >= cur_day]
        if pos is not None or q < 1 or closed_intrabar:
            continue
        # ---- CheckSignals sur la bougie cloturee q-1 (la bougie q vient de s'ouvrir)
        s = q - 1
        for z in zones:
            if z["used"] or z["a5"] > s:
                continue
            if s + 1 - z["a5"] > expire or z["brk"] <= s:
                z["used"] = True
                continue
            if z["dir"] == 1:
                sig = l5[s] <= z["hi"] and c5[s] > o5[s] and smt_ok(s, 1, gold, silver, smt_win)
                slv = l5[s] - sl_fix
            else:
                sig = h5[s] >= z["lo"] and c5[s] < o5[s] and smt_ok(s, -1, gold, silver, smt_win)
                slv = h5[s] + sl_fix
            if not sig:
                continue
            z["used"] = True
            if collect_candidates:
                cands.append((t5[q], z["dir"], slv))
            # TradingAllowedNow
            if wd[q] == 4 and hr[q] >= fri_cut:
                break
            pnl_today = sum(p for _, p in today_closed)
            start_bal = bal - pnl_today
            if daily_loss > 0 and start_bal > 0 and pnl_today <= -daily_loss / 100.0 * start_bal:
                break
            if max_consec > 0:
                streak = 0
                for _, p in sorted(today_closed, key=lambda x: x[0], reverse=True):
                    if p < 0: streak += 1
                    else: break
                if streak >= max_consec:
                    break
            d = z["dir"]
            price = o5[q] + spread if d == 1 else o5[q]
            risk = abs(price - slv)
            if (d == 1 and slv >= price) or (d == -1 and slv <= price) or risk <= 0 or (max_risk and risk > max_risk):
                break
            lots = np.floor(bal * risk_pct / 100.0 / (risk * contract) / 0.01) * 0.01
            lots = max(0.01, round(lots, 2))
            tp = price + d * P["rr"] * risk
            pos = dict(d=d, entry=price, sl=slv, tp=tp, risk=risk, lots=lots, t=t5[q], q=q)
            # la bougie d'entree compte aussi pour SL/TP
            if d == 1:
                if l5[q] <= slv: pos["exit"], pos["why"], pos["tx"] = slv, "SL", t5[q]
                elif h5[q] >= tp: pos["exit"], pos["why"], pos["tx"] = tp, "TP", t5[q]
            else:
                if h5[q] + spread >= slv: pos["exit"], pos["why"], pos["tx"] = slv, "SL", t5[q]
                elif l5[q] + spread <= tp: pos["exit"], pos["why"], pos["tx"] = tp, "TP", t5[q]
            if "exit" in pos:
                pnl = d * (pos["exit"] - price) * lots * contract
                bal += pnl
                trades.append(dict(open=pos["t"], close=pos["tx"], side=d, entry=price, sl=slv, tp=tp, exit=pos["exit"],
                                   why=pos["why"], lots=lots, pnl=pnl, R=d * (pos["exit"] - price) / risk))
                today_closed.append((t5[q], pnl)); pos = None
            break
    df = pd.DataFrame(trades)
    return (df, cands, bal) if collect_candidates else (df, bal)


def stats(df, deposit=10000.0):
    if df.empty:
        return "aucun trade"
    eq = deposit + df.pnl.cumsum(); dd = (eq.cummax() - eq).max()
    w = df.pnl[df.pnl > 0].sum(); l = -df.pnl[df.pnl <= 0].sum()
    return dict(trades=len(df), win=round(100 * (df.pnl > 0).mean(), 1), PF=round(w / l, 2) if l else None,
                net=round(df.pnl.sum(), 0), maxDD_usd=round(dd, 0), maxDD_pct=round(100 * dd / deposit, 2),
                avgR=round(df.R.mean(), 2), totalR=round(df.R.sum(), 1))


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    opt = {sys.argv[i]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1) if sys.argv[i].startswith("--")}
    m30, m5 = load(a[0]), load(a[1])
    ag = load(a[2]) if len(a) > 2 else None
    df, bal = run(m30, m5, ag, int(opt.get("--preset", 1)), float(opt.get("--spread", 0.35)),
                  opt.get("--from"), opt.get("--to"))
    print("SMT:", "ACTIF" if ag is not None else "DESACTIVE (pas de fichier argent)")
    print(stats(df)); df.to_csv("ob30_trades.csv", index=False)
