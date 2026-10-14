"""Teste des filtres sur OB M30 (corps>=2$, entree mid, SL 10 pips, sans ATR). Usage: python3 ob_filters.py m30.csv"""
import sys
import numpy as np, pandas as pd
from ob_backtest import load, prep, find_obs, run, stats

m30 = prep(load(sys.argv[1])); m30["atr"] = 1.0
h4 = m30.c.resample("4h").last().dropna()
h4e = h4.ewm(span=50, adjust=False).mean()
h4_up = (h4 > h4e).shift(1)  # H4 deja clos
d1 = m30.c.resample("1D").last().dropna(); d1_up = (d1 > d1.ewm(span=20, adjust=False).mean()).shift(1)
obs = [o for o in find_obs(m30, 2.0) if o[0] >= 100]
idx = m30.index; hh, ll, cc = m30.h.values, m30.l.values, m30.c.values

def feat(o):
    i, dr, lo, hi = o; t = idx[i]
    h4t = h4_up.reindex([t], method="ffill").iloc[0]; d1t = d1_up.reindex([t], method="ffill").iloc[0]
    rng_hi, rng_lo = hh[i-100:i].max(), ll[i-100:i].min(); mid = (lo+hi)/2
    prem = (mid - rng_lo) / (rng_hi - rng_lo + 1e-9)
    sweep = (dr == 1 and ll[i-12:i-1].min() <= ll[i-40:i-12].min()) or (dr == -1 and hh[i-12:i-1].max() >= hh[i-40:i-12].max())
    return dict(hour=t.hour, dow=t.dayofweek, size=hi-lo, with_h4=bool(h4t) == (dr == 1) if pd.notna(h4t) else False,
                with_d1=bool(d1t) == (dr == 1) if pd.notna(d1t) else False,
                disc=(prem < 0.5) if dr == 1 else (prem > 0.5), sweep=bool(sweep), body=abs(cc[i]-m30.o.values[i]))
F = pd.DataFrame([feat(o) for o in obs])
cut = idx[int(len(idx) * 0.6)]
filters = {
 "aucun": np.ones(len(F), bool),
 "H4 EMA50 meme sens": F.with_h4.values,
 "H4 EMA50 contre": ~F.with_h4.values,
 "D1 EMA20 meme sens": F.with_d1.values,
 "H4+D1 meme sens": (F.with_h4 & F.with_d1).values,
 "Discount(buy)/Premium(sell)": F.disc.values,
 "Anti-premium (contre)": ~F.disc.values,
 "Sweep liquidite avant OB": F.sweep.values,
 "OB taille <3$": (F['size'] < 3).values, "OB taille 3-6$": ((F['size'] >= 3) & (F['size'] < 6)).values, "OB taille >=6$": (F['size'] >= 6).values,
 "Corps >=4$": (F.body >= 4).values, "Corps >=6$": (F.body >= 6).values,
 "Heures 0-7 (Asie)": (F.hour < 7).values, "Heures 7-13 (Londres)": F.hour.between(7, 12).values,
 "Heures 13-21 (NY)": F.hour.between(13, 20).values, "Heures 21-24": (F.hour >= 21).values,
 "Lun-Mar": (F.dow <= 1).values, "Mer-Jeu": F.dow.isin([2, 3]).values, "Vendredi": (F.dow == 4).values,
}
rows = []
for rr in [2, 3]:
    for name, m in filters.items():
        sub = [o for o, k in zip(obs, m) if k]
        r = run(m30, sub, rr, "mid", 1.0, False)
        a, b = stats(r[r.t < cut]), stats(r[r.t >= cut])
        rows.append(dict(rr=rr, filtre=name, n_tr=a["n"], wr_tr=a["wr"], exp_tr=a["exp"], n_te=b["n"], wr_te=b["wr"], exp_te=b["exp"], tot_all=r.R.sum()))
R = pd.DataFrame(rows); pd.set_option("display.width", 220)
R.round(2).to_csv("results_filters.csv", index=False)
print(R.round(2).to_string(index=False))
