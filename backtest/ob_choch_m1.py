"""OB M30 + confirmation CHoCH M1 vs entree limite. Usage: python3 ob_choch_m1.py m30.csv m1.csv"""
import sys, itertools
import numpy as np, pandas as pd
from ob_backtest import load, prep, find_obs, stats, COST

def sim(m30, m1, obs, rr, mode, piv, k_buf=0.1, valid_h=20, min_risk=0.5, pre=10):
    t1 = m1.index.values
    o, h, l, c = (m1[x].values for x in "ohlc")
    out = []; busy = -1
    for (i, dr, lo, hi) in obs:
        ts = np.datetime64(m30.index[i] + pd.Timedelta(minutes=30))
        s = int(np.searchsorted(t1, ts))
        if s >= len(m1) - 5 or t1[s] > ts + np.timedelta64(2, 'h'):
            continue  # pas de donnees M1 pour ce signal
        e = min(len(m1), s + valid_h * 60)
        atr = m30.atr.values[i]
        s = max(s, busy + 1)
        j = s; touched = None
        while j < e:
            if (dr == 1 and c[j] < lo) or (dr == -1 and c[j] > hi):
                break  # invalide
            if touched is None:
                if (dr == 1 and l[j] <= hi) or (dr == -1 and h[j] >= lo):
                    touched = j
                    if mode == "limit":
                        px = (lo + hi) / 2
                        if (dr == 1 and l[j] > px) or (dr == -1 and h[j] < px):
                            touched = None; j += 1; continue
                        entry_j, entry = j, px
                        sl = (lo - k_buf * atr) if dr == 1 else (hi + k_buf * atr)
                        break
                else:
                    j += 1; continue
            if mode == "choch":
                # dernier pivot (high pour buy, low pour sell) confirme apres 'touched-pre'
                a = max(s, touched - pre)
                lvl = None
                for p in range(a + piv, j - piv + 1):
                    if dr == 1 and h[p] == h[p - piv:p + piv + 1].max():
                        lvl = h[p]
                    if dr == -1 and l[p] == l[p - piv:p + piv + 1].min():
                        lvl = l[p]
                if lvl is not None and ((dr == 1 and c[j] > lvl) or (dr == -1 and c[j] < lvl)) and j > touched:
                    entry_j, entry = j, c[j]
                    ext = l[touched:j + 1].min() if dr == 1 else h[touched:j + 1].max()
                    sl = (min(ext, hi) - k_buf * atr) if dr == 1 else (max(ext, lo) + k_buf * atr)
                    break
            j += 1
        else:
            continue
        if touched is None or j >= e or 'entry' not in locals() or entry_j != j:
            continue
        risk = abs(entry - sl)
        if risk < min_risk:
            continue
        tp = entry + dr * rr * risk
        q = j if mode == "limit" else j + 1
        res = None
        for q in range(q, min(len(m1), j + 60 * 24)):
            sl_hit = (dr == 1 and l[q] <= sl) or (dr == -1 and h[q] >= sl)
            tp_hit = (dr == 1 and h[q] >= tp) or (dr == -1 and l[q] <= tp)
            if sl_hit: res = -1 - COST / risk; break
            if tp_hit: res = rr - COST / risk; break
        if res is None: continue
        out.append((m1.index[q], res)); busy = q
    return pd.DataFrame(out, columns=["t", "R"])

if __name__ == "__main__":
    m30 = prep(load(sys.argv[1])); m1 = load(sys.argv[2])
    print("M1:", m1.index[0], "->", m1.index[-1])
    rows = []
    for k in [1.0, 1.5]:
        obs = find_obs(m30, k)
        for rr, mode, piv in itertools.product([1, 1.5, 2, 3], ["limit", "choch"], [2, 3, 5]):
            if mode == "limit" and piv != 2: continue
            r = sim(m30, m1, obs, rr, mode, piv)
            s = stats(r)
            rows.append(dict(k=k, rr=rr, mode=mode, piv=piv if mode == "choch" else "-", **s))
    R = pd.DataFrame(rows); pd.set_option("display.width", 200)
    R.round(2).to_csv("results_choch.csv", index=False)
    print(R.round(2).to_string(index=False))
