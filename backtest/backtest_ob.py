"""Backtest Order Block (ICT) XAUUSD: signaux M30, exécution tick-ordre sur M5.
Usage: python backtest_ob.py M30.csv M5.csv [RR] [cost]
"""
import sys
import numpy as np
import pandas as pd

def load(p):
    d = pd.read_csv(p, header=None, names=["d", "t", "o", "h", "l", "c", "v"])
    d.index = pd.to_datetime(d.d + " " + d.t, format="%Y.%m.%d %H:%M")
    return d[["o", "h", "l", "c", "v"]]

def signals(m30, lookback=10, disp_atr=1.0, max_k=3, expiry_bars=48, sl_buf=0.1, atr_n=14, tf=30, gap_atr=None):
    """Liste des ordres limites generes a la cloture de la bougie de confirmation."""
    o, h, l, c = (m30[x].values for x in "ohlc")
    tr = np.maximum(h - l, np.maximum(abs(h - np.roll(c, 1)), abs(l - np.roll(c, 1))))
    atr = pd.Series(tr).rolling(atr_n).mean().values
    t30 = m30.index
    out = []
    for i in range(lookback + atr_n, len(m30) - max_k - 1):
        for side in (1, -1):
            if side == 1 and not c[i] < o[i]: continue
            if side == -1 and not c[i] > o[i]: continue
            ref_hi = h[i - lookback:i].max(); ref_lo = l[i - lookback:i].min()
            for k in range(1, max_k + 1):
                j = i + k
                ok = (c[j] > ref_hi and c[j] - h[i] > disp_atr * atr[i]) if side == 1 else \
                     (c[j] < ref_lo and l[i] - c[j] > disp_atr * atr[i])
                if ok and gap_atr is not None:
                    ok = all(abs(o[x] - c[x - 1]) <= gap_atr * atr[i] for x in range(i, j + 1))
                if ok:
                    sl = (l[i] - sl_buf * atr[i]) if side == 1 else (h[i] + sl_buf * atr[i])
                    start = t30[j].to_datetime64() + np.timedelta64(tf, "m")
                    out.append(dict(start=start, end=start + np.timedelta64(tf * expiry_bars, "m"),
                                    side=side, entry=o[i], sl=sl, atr=atr[i]))
                    break
    return sorted(out, key=lambda x: x["start"])

def run(m30, m5, rr=2.0, cost=0.30, sigs=None, fri_no_new=None, fri_close=None, **kw):
    """Simulation chronologique (sans look-ahead): le premier ordre rempli gagne,
    les autres ordres en attente sont annules, signaux ignores si position ouverte."""
    sigs = signals(m30, **kw) if sigs is None else sigs
    t5 = m5.index.values; h5, l5, c5 = m5.h.values, m5.l.values, m5.c.values
    wd = m5.index.weekday.values; hr = m5.index.hour.values
    trades, pend, pos, si = [], [], None, 0
    for q in range(len(t5)):
        t = t5[q]
        if fri_close is not None and wd[q] == 4 and hr[q] >= fri_close:     # fin de semaine: tout fermer
            pend = []
            if pos is not None:
                r = pos["side"] * (c5[q] - pos["entry"]) / pos["risk"] - cost / pos["risk"]
                trades.append((pos["open"], t, pos["side"], pos["entry"], pos["sl"], pos["tp"], r))
                pos = None
        while si < len(sigs) and sigs[si]["start"] <= t:
            blocked = (fri_no_new is not None and wd[q] == 4 and hr[q] >= fri_no_new)
            if pos is None and not blocked: pend.append(sigs[si])
            si += 1
        if pos is None and pend:
            keep = []
            for p in pend:
                if t >= p["end"]: continue
                s = p["side"]
                if (s == 1 and l5[q] <= p["entry"]) or (s == -1 and h5[q] >= p["entry"]):
                    if pos is None:
                        risk = abs(p["entry"] - p["sl"])
                        pos = dict(p, risk=risk, tp=p["entry"] + s * rr * risk, open=t)
                    continue
                if (s == 1 and l5[q] < p["sl"]) or (s == -1 and h5[q] > p["sl"]): continue
                keep.append(p)
            pend = [] if pos is not None else keep
        if pos is not None:
            s = pos["side"]
            hit_sl = (l5[q] <= pos["sl"]) if s == 1 else (h5[q] >= pos["sl"])
            hit_tp = (h5[q] >= pos["tp"]) if s == 1 else (l5[q] <= pos["tp"])
            if hit_sl or hit_tp:
                r = (-1.0 if hit_sl else rr) - cost / pos["risk"]
                trades.append((pos["open"], t, s, pos["entry"], pos["sl"], pos["tp"], r))
                pos = None
    return pd.DataFrame(trades, columns=["open", "close", "side", "entry", "sl", "tp", "R"])

def run_conf(m5, sigs, rr=2.0, cost=1.5, win=12, buf=0.1, min_risk_atr=0.3):
    """Entree affinee sur M5: l'OB (M30/H1) doit etre touche, puis on attend une bougie M5
    qui cloture au-dela du haut (bas) de la bougie de touche. SL derriere le swing de la touche."""
    t5 = m5.index.values; o5, h5, l5, c5 = (m5[x].values for x in "ohlc")
    trades, pend, pos, si = [], [], None, 0
    for q in range(len(t5)):
        t = t5[q]
        while si < len(sigs) and sigs[si]["start"] <= t:
            if pos is None: pend.append(dict(sigs[si]))
            si += 1
        if pos is None and pend:
            keep = []
            for p in pend:
                if t >= p["end"]: continue
                s = p["side"]
                if "arm" in p:
                    p["sw"] = min(p["sw"], l5[q]) if s == 1 else max(p["sw"], h5[q])
                    if (s == 1 and p["sw"] < p["sl"]) or (s == -1 and p["sw"] > p["sl"]): continue
                    trig = (c5[q] > h5[p["arm"]]) if s == 1 else (c5[q] < l5[p["arm"]])
                    if trig:
                        e = c5[q]; sl = p["sw"] - s * buf * p["atr"]; risk = abs(e - sl)
                        if risk < min_risk_atr * p["atr"]: continue
                        pos = dict(side=s, entry=e, sl=sl, tp=e + s * rr * risk, risk=risk, open=t, q0=q)
                        break
                    if q - p["arm"] >= win: continue
                    keep.append(p)
                else:
                    if (s == 1 and l5[q] < p["sl"]) or (s == -1 and h5[q] > p["sl"]): continue
                    if (s == 1 and l5[q] <= p["entry"]) or (s == -1 and h5[q] >= p["entry"]):
                        p["arm"] = q; p["sw"] = l5[q] if s == 1 else h5[q]
                    keep.append(p)
            pend = [] if pos is not None else keep
        if pos is not None and q > pos["q0"]:
            s = pos["side"]
            hit_sl = (l5[q] <= pos["sl"]) if s == 1 else (h5[q] >= pos["sl"])
            hit_tp = (h5[q] >= pos["tp"]) if s == 1 else (l5[q] <= pos["tp"])
            if hit_sl or hit_tp:
                r = (-1.0 if hit_sl else rr) - cost / pos["risk"]
                trades.append((pos["open"], t, s, pos["entry"], pos["sl"], pos["tp"], r))
                pos = None
    return pd.DataFrame(trades, columns=["open", "close", "side", "entry", "sl", "tp", "R"])

def stats(df):
    if df.empty: return "aucun trade"
    w = df.R[df.R > 0]; ls = df.R[df.R <= 0]
    eq = df.R.cumsum(); dd = (eq.cummax() - eq).max()
    return dict(trades=len(df), winrate=round(100 * (df.R > 0).mean(), 1),
                PF=round(w.sum() / abs(ls.sum()), 2) if len(ls) else np.inf,
                expectancy_R=round(df.R.mean(), 3), total_R=round(df.R.sum(), 1),
                maxDD_R=round(dd, 1), long=int((df.side == 1).sum()), short=int((df.side == -1).sum()))

if __name__ == "__main__":
    m30, m5 = load(sys.argv[1]), load(sys.argv[2])
    rr = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
    cost = float(sys.argv[4]) if len(sys.argv) > 4 else 0.30
    m30 = m30[m30.index >= m5.index[0]]
    df = run(m30, m5, rr, cost)
    print(stats(df)); df.to_csv("trades_ob.csv", index=False)
