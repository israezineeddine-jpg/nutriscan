"""Final report for the OB30 zone + CHoCH entry: the two recipes on every period, trades CSV and equity chart.

usage: python3 report.py <data_dir> <out_dir>
"""
import os, sys
import numpy as np
import pandas as pd
import ob_choch as ob

RECIPES = {
    # name: (entry TF, N, W, SL mode, buffer $, session UTC or None, RR)
    "M1_RR4": ("M1", 3, 15, "zone", 1.0, (7, 21), 4.0),
    "M1_RR3": ("M1", 3, 15, "zone", 1.0, (7, 21), 3.0),
    "M1_RR2": ("M1", 3, 15, "zone", 1.0, (7, 21), 2.0),
    "M1_RR1": ("M1", 3, 15, "zone", 1.0, (7, 21), 1.0),
    "M5_RR3": ("M5", 3, 6, "zone", 0.5, None, 3.0),
    "M5_RR2.5": ("M5", 3, 6, "zone", 0.5, None, 2.5),
    "M5_RR2": ("M5", 3, 6, "zone", 0.5, None, 2.0),
    "M5_RR1": ("M5", 3, 6, "zone", 0.5, None, 1.0),
}
PERIODS = [  # (label, start, end, role)
    ("2025-06..2025-09", "2025-06-01", "2025-10-01", "M1 holdout #2 (M1 data 6-23% missing) | M5 in-sample"),
    ("2025-10..2026-01", "2025-10-01", "2026-02-01", "M1 holdout #2 | M5 in-sample"),
    ("2026-02..2026-07", "2026-02-01", "2026-08-01", "M1 holdout #1 | M5 out-of-sample from March"),
    ("2026-08..2026-11", "2026-08-01", "2026-12-01", "M1 recipe chosen here | M5 out-of-sample"),
]


def main(data, out):
    os.makedirs(out, exist_ok=True)
    m5 = ob.market_hours(ob.load_utc(os.path.join(data, "xau_m5_utc.csv")))
    m1 = ob.market_hours(ob.load_utc(os.path.join(data, "xau_m1_utc.csv")))
    zones = ob.build_zones(ob.resample(m5, "30min"))
    ex1, ex5 = ob.Exec(m1), ob.Exec(m5)
    rows, all_trades = [], {}
    for name, (tf, N, W, sl, buf, sess, rr) in RECIPES.items():
        ltf, ex = (m1, ex1) if tf == "M1" else (m5, ex5)   # each recipe uses its own timeframe for entries and exits
        cands = ob.find_entries(zones, ltf, N=N, W=W)
        tr = ob.simulate(cands, ltf, ex, sl, buf, [rr], session=sess)[rr]
        tr.to_csv(os.path.join(out, f"trades_{name}.csv"), index=False)
        all_trades[name] = tr
        t = pd.to_datetime(tr.open)
        for lab, a, b, role in PERIODS + [("OOS for M1 (2025-06..2026-07)", "2025-06-01", "2026-08-01", ""),
                                          ("TOTAL 2025-06..2026-11", "2025-06-01", "2026-12-01", "")]:
            d = tr[(t >= a) & (t < b)]
            s = ob.stats(d)
            rows.append(dict(recipe=name, period=lab, **s,
                             R_long=round(d.R[d.dir == 1].sum(), 1), R_short=round(d.R[d.dir == -1].sum(), 1)))
    rep = pd.DataFrame(rows)
    rep.to_csv(os.path.join(out, "report.csv"), index=False)
    cols = ["recipe", "period", "n", "win", "PF", "totR", "R_long", "R_short", "ddR", "ROI%@0.5", "DD%@0.5", "ROI%@1.0",
            "DD%@1.0", "months+"]
    print(rep[cols].to_string(index=False))
    try:
        import matplotlib; matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(11, 5.5), dpi=130)
        for name, tr in all_trades.items():
            if name not in ("M1_RR4", "M5_RR3"):
                continue
            eq = 100 * (np.cumprod(1 + 0.01 * tr.R.values) - 1)
            ax.plot(pd.to_datetime(tr.close), eq, lw=1.8, label=f"{name} ({len(tr)} trades, risk 1%)")
        ax.axvspan(pd.Timestamp("2026-08-01"), pd.Timestamp("2026-11-21"), color="0.88", label="M1 recipe chosen here")
        ax.axvspan(pd.Timestamp("2025-06-01"), pd.Timestamp("2025-10-01"), color="#f6e3c5", label="M1 data 6-23% missing")
        ax.axhline(0, color="0.4", lw=0.8)
        ax.set_ylabel("account %"); ax.set_title("XAUUSD - OB30 zone + CHoCH entry (Twelve Data, spread 0.35)")
        ax.legend(loc="upper left"); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(out, "equity_ob_choch.png"))
        print("chart saved")
    except ImportError:
        print("matplotlib missing: no chart")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
