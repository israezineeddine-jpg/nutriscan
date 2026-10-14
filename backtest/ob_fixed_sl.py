"""Sans ATR: displacement = corps min en $, SL = 10 pips hors OB (1 pip = 0.10$). Usage: python3 ob_fixed_sl.py m30.csv m1.csv"""
import sys, itertools
import pandas as pd
from ob_backtest import load, prep, find_obs, run, stats
from ob_choch_m1 import sim

PIP = 0.10; SL_PIPS = 10
m30 = prep(load(sys.argv[1])); m1 = load(sys.argv[2])
m30["atr"] = 1.0  # neutralise l'ATR: k = corps min en $, buffer = 1.0 * SL_PIPS*PIP
buf = SL_PIPS * PIP
cut = m30.index[int(len(m30) * 0.6)]
rows = []
for body in [2.0, 4.0]:
    obs = find_obs(m30, body)
    for rr in [1, 1.5, 2, 3]:
        for entry in ["mid", "edge"]:
            r = run(m30, obs, rr, entry, buf, False)
            a, b = stats(r[r.t < cut]), stats(r[r.t >= cut])
            rows.append(dict(tf="M30-limit", body=body, rr=rr, entry=entry, n_tr=a["n"], wr_tr=a["wr"], exp_tr=a["exp"], n_te=b["n"], wr_te=b["wr"], pf_te=b["pf"], exp_te=b["exp"], tot_te=b["tot"]))
        for piv in [3, 5]:
            s = stats(sim(m30, m1, obs, rr, "choch", piv, k_buf=buf))
            rows.append(dict(tf="M1-CHoCH", body=body, rr=rr, entry=f"piv{piv}", n_te=s["n"], wr_te=s["wr"], pf_te=s["pf"], exp_te=s["exp"], tot_te=s["tot"]))
R = pd.DataFrame(rows); pd.set_option("display.width", 220)
R.round(2).to_csv("results_fixed_sl.csv", index=False)
print(R.round(2).to_string(index=False))
