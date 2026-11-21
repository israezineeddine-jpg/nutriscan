"""Grid search + walk-forward for the OB30 zone + LTF CHoCH entry (see ob_choch.py).

usage: python3 grid.py <data_dir> <out_dir>
  data_dir must hold xau_m5_utc.csv (and optionally xau_m1_utc.csv), columns datetime,o,h,l,c in UTC.
"""
import itertools, os, sys, time
import numpy as np
import pandas as pd
import ob_choch as ob

RR = [1, 1.5, 2, 2.5, 3, 4, 5]
IS_END = np.datetime64("2026-03-01")          # in-sample: before March 2026, out-of-sample: from March 2026


def seg(df, mask):
    d = df[mask]
    if len(d) == 0:
        return 0, np.nan, 0.0
    R = d.R.values; gl = -R[R <= 0].sum()
    return len(d), round(R[R > 0].sum() / gl, 2) if gl > 0 else 99.0, round(R.sum(), 1)


def run_grid(label, ltf, ex, zones, Ns, Ws, bufs=(0.5, 1.0, 2.0), sessions=(None, (7, 21)), min_risks=(1.0,),
             spread=0.35):
    rows, trades = [], {}
    for N, W in itertools.product(Ns, Ws):
        cands = ob.find_entries(zones, ltf, N=N, W=W)
        for sl_mode, buf, sess, mr in itertools.product(("swing", "zone"), bufs, sessions, min_risks):
            res = ob.simulate(cands, ltf, ex, sl_mode, buf, RR, spread=spread, session=sess, min_risk=mr)
            for rr, df in res.items():
                key = (label, N, W, sl_mode, buf, "all" if sess is None else f"{sess[0]}-{sess[1]}", mr, rr)
                s = ob.stats(df)
                if s["n"] == 0:
                    continue
                t = pd.to_datetime(df.open).values
                n_is, pf_is, r_is = seg(df, t < IS_END)
                n_os, pf_os, r_os = seg(df, t >= IS_END)
                rows.append(dict(zip(("tf", "N", "W", "sl", "buf", "session", "min_risk", "rr"), key), **s,
                                 n_IS=n_is, PF_IS=pf_is, R_IS=r_is, n_OOS=n_os, PF_OOS=pf_os, R_OOS=r_os,
                                 cands=len(cands)))
                trades[key] = df
    return pd.DataFrame(rows), trades


if __name__ == "__main__":
    data, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    m5 = ob.market_hours(ob.load_utc(os.path.join(data, "xau_m5_utc.csv")))
    zones = ob.build_zones(ob.resample(m5, "30min"))
    print("M5 bars", len(m5), m5.index[0], "->", m5.index[-1], "| zones", len(zones))
    t0 = time.time()
    g5, _ = run_grid("M5", m5, ob.Exec(m5), zones, Ns=(1, 2, 3), Ws=(6, 12, 24))
    g5.to_csv(os.path.join(out, "grid_m5_full.csv"), index=False)
    print("M5 grid", len(g5), "rows in", round(time.time() - t0, 1), "s")

    m1_path = os.path.join(data, "xau_m1_utc.csv")
    if os.path.exists(m1_path):
        # same zones (built from M30), same period, exits simulated on M1 for both entry timeframes
        # the M1 recipe was chosen on Aug-Nov 2026 only (earlier M1 history was kept as holdout, see report.py)
        m1 = ob.market_hours(ob.load_utc(m1_path)).loc["2026-07-31":]
        ex1 = ob.Exec(m1)
        print("M1 bars", len(m1), m1.index[0], "->", m1.index[-1])
        ga, _ = run_grid("M5", m5, ex1, zones, Ns=(1, 2, 3, 4), Ws=(6, 12), min_risks=(1.0, 2.0))
        gb, _ = run_grid("M1", m1, ex1, zones, Ns=(2, 3, 5, 8, 15), Ws=(15, 30, 60), min_risks=(1.0, 2.0))
        gm = pd.concat([ga, gb])
        gm.to_csv(os.path.join(out, "grid_m1_period.csv"), index=False)
        print("M1-period grid", len(gm), "rows")
