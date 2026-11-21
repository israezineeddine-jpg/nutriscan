"""Parity test: OB_CHoCH_M1.mq5 (run by harness_ea) against the Python backtest (ob_choch.py), same M1 bars.

usage: python3 ea_parity.py <data_dir with xau_m1_utc.csv> <work_dir> [spread]
- exports the M1 bars (after the same market-hours filter) in FTMO server time (UTC+2 / UTC+3 with US DST) and the
  M30 bars built from them, runs the harness, converts the EA trades back to UTC and compares them trade by trade
  with ob_choch.simulate() (zones from the same M30 bars, M1 recipe: N=3, W=15, SL zone +/- 1$, 07-21 UTC, RR 4).
"""
import os, subprocess, sys
import numpy as np
import pandas as pd
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ob_choch"))
import ob_choch as ob

data, work = sys.argv[1], sys.argv[2]
spread = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
os.makedirs(work, exist_ok=True)
m1 = ob.market_hours(ob.load_utc(os.path.join(data, "xau_m1_utc.csv")))
ny = m1.index.tz_localize("UTC").tz_convert("America/New_York")
off = np.where(np.array([bool(x.dst()) for x in ny]), 3, 2)            # FTMO: UTC+3 when New York is on DST
srv = m1.index + pd.to_timedelta(off, unit="h")
epoch = (srv - pd.Timestamp("1970-01-01")) // pd.Timedelta("1s")
pd.DataFrame({"t": epoch, "o": m1.o.values, "h": m1.h.values, "l": m1.l.values, "c": m1.c.values}).to_csv(
    os.path.join(work, "m1_server.csv"), header=False, index=False, float_format="%.5f")
m1s = m1.copy(); m1s.index = srv
m30s = ob.resample(m1s, "30min")
e30 = (m30s.index - pd.Timestamp("1970-01-01")) // pd.Timedelta("1s")
pd.DataFrame({"t": e30, "o": m30s.o.values, "h": m30s.h.values, "l": m30s.l.values, "c": m30s.c.values}).to_csv(
    os.path.join(work, "m30_server.csv"), header=False, index=False, float_format="%.5f")

# Python reference (UTC)
zones = ob.build_zones(ob.resample(m1, "30min"))
cands = ob.find_entries(zones, m1, N=3, W=15)
py = ob.simulate(cands, m1, ob.Exec(m1), "zone", 1.0, [4], spread=spread, session=(7, 21))[4]
py["open"] = pd.to_datetime(py.open)
print(f"python: {len(zones)} zones, {len(cands)} CHoCH, {len(py)} trades, total R {py.R.sum():+.1f}")

# EA through the harness
here = os.path.dirname(os.path.abspath(__file__))
r = subprocess.run([os.path.join(here, "harness_ea"), work, str(spread)], capture_output=True, text=True)
print(r.stdout.strip())
ea = pd.read_csv(os.path.join(work, "OB_CHoCH_trades.csv"))
def to_utc(s):
    t = pd.to_datetime(s, format="%Y.%m.%d %H:%M:%S")
    # server -> UTC: UTC+3 when New York is on DST
    u2 = t - pd.Timedelta(hours=2)
    dst = np.array([bool(x.dst()) for x in u2.dt.tz_localize("UTC").dt.tz_convert("America/New_York")])
    return t - pd.to_timedelta(np.where(dst, 3, 2), unit="h")
ea["open"] = to_utc(ea.open_time).dt.floor("min"); ea["close"] = to_utc(ea.close_time)
ea["R"] = ea.side * (ea.close_price - ea.open_price) / (ea.open_price - ea.sl).abs()
print(f"EA    : {len(ea)} trades, total R {ea.R.sum():+.1f} (spread charged through bid/ask)")

m = py.merge(ea, on="open", how="outer", suffixes=("_py", "_ea"), indicator=True)
both = m[m._merge == "both"]
print("matched by entry minute:", len(both), "| python only:", int((m._merge == "left_only").sum()), "| EA only:", int((m._merge == "right_only").sum()))
same_dir = (both.dir == both.side).mean() if len(both) else np.nan
dsl = (both.sl_py - both.sl_ea).abs().max() if len(both) else np.nan
dR = (both.R_py - both.R_ea).abs()
print(f"same direction: {same_dir:.3f} | max |SL diff|: {dsl:.4f} | |R diff| > 0.05: {(dR > 0.05).sum()}")
cols = ["open", "dir", "side", "entry", "open_price", "sl_py", "sl_ea", "why", "close_comment", "R_py", "R_ea", "close_py", "close_ea"]
m.rename(columns={"close_py": "close_py"}, inplace=True)
diff = m[(m._merge != "both") | (dR.reindex(m.index).fillna(0) > 0.05)]
pd.set_option("display.width", 250)
print(diff[[c for c in cols if c in diff.columns]].head(30).to_string(index=False))
m.to_csv(os.path.join(work, "parity.csv"), index=False)
