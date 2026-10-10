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

def run(m30, m5, rr=2.0, cost=0.30, lookback=10, disp_atr=1.0, max_k=3,
        expiry_bars=48, sl_buf=0.1, atr_n=14):
    o, h, l, c = (m30[x].values for x in "ohlc")
    tr = np.maximum(h - l, np.maximum(abs(h - np.roll(c, 1)), abs(l - np.roll(c, 1))))
    atr = pd.Series(tr).rolling(atr_n).mean().values
    t30 = m30.index
    t5 = m5.index.values
    h5, l5 = m5.h.values, m5.l.values
    trades, busy_until = [], np.datetime64("1970-01-01")
    for i in range(lookback + atr_n, len(m30) - max_k - 1):
        for side in (1, -1):
            # OB = dernière bougie opposée avant l'impulsion
            if side == 1 and not c[i] < o[i]: continue
            if side == -1 and not c[i] > o[i]: continue
            ref_hi = h[i - lookback:i].max(); ref_lo = l[i - lookback:i].min()
            conf = None
            for k in range(1, max_k + 1):
                j = i + k
                if side == 1 and c[j] > ref_hi and c[j] - h[i] > disp_atr * atr[i]: conf = j; break
                if side == -1 and c[j] < ref_lo and l[i] - c[j] > disp_atr * atr[i]: conf = j; break
            if conf is None: continue
            entry = o[i]                                  # bord du corps de l'OB
            sl = (l[i] - sl_buf * atr[i]) if side == 1 else (h[i] + sl_buf * atr[i])
            risk = abs(entry - sl)
            tp = entry + side * rr * risk
            start = t30[conf].to_datetime64() + np.timedelta64(30, "m")
            end = start + np.timedelta64(30 * expiry_bars, "m")
            if start < busy_until: continue
            a = np.searchsorted(t5, start); b = np.searchsorted(t5, end)
            filled = None
            for q in range(a, b):
                # annulé si le prix casse l'OB avant remplissage
                if filled is None:
                    if (side == 1 and l5[q] <= entry) or (side == -1 and h5[q] >= entry):
                        filled = q
                    elif (side == 1 and l5[q] < sl) or (side == -1 and h5[q] > sl):
                        break
                if filled is not None:
                    hit_sl = (l5[q] <= sl) if side == 1 else (h5[q] >= sl)
                    hit_tp = (h5[q] >= tp) if side == 1 else (l5[q] <= tp)
                    if hit_sl or hit_tp:             # SL prioritaire (conservateur)
                        r = -1.0 if hit_sl else rr
                        r -= cost / risk
                        trades.append((t5[filled], t5[q], side, entry, sl, tp, r))
                        busy_until = t5[q]; break
            else:
                continue
    df = pd.DataFrame(trades, columns=["open", "close", "side", "entry", "sl", "tp", "R"])
    return df.sort_values("open").reset_index(drop=True)

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
