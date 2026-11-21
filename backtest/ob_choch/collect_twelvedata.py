"""Merge Twelve Data XAU/USD time-series exports (JSON files {"result": "datetime;open;high;low;close\n..."})
into M1 and M5 CSVs with UTC timestamps.

usage: python3 collect_twelvedata.py <folder with the exported .txt/.json files> <out_dir>
Twelve Data returned XAU/USD in Australia/Sydney time for this account (the daily break falls at 17:00 New York),
so timestamps are converted from Australia/Sydney to UTC. Weekend / daily-break bars are removed later by
ob_choch.market_hours().
"""
import glob, io, json, os, sys
import pandas as pd

src, out = sys.argv[1], sys.argv[2]
frames = {}
for f in sorted(glob.glob(os.path.join(src, "*.txt")) + glob.glob(os.path.join(src, "*.json"))):
    try:
        txt = json.load(open(f))["result"]
        df = pd.read_csv(io.StringIO(txt), sep=";")
    except Exception:
        continue
    if "datetime" not in df.columns or len(df) < 10:
        continue
    df["datetime"] = pd.to_datetime(df["datetime"])
    step = int(df["datetime"].sort_values().diff().dt.total_seconds().mode().iloc[0] // 60)
    frames.setdefault(step, []).append(df)
for step, fr in frames.items():
    d = pd.concat(fr).drop_duplicates("datetime").sort_values("datetime")
    d["datetime"] = (d["datetime"].dt.tz_localize("Australia/Sydney", ambiguous="NaT", nonexistent="NaT")
                     .dt.tz_convert("UTC").dt.tz_localize(None))
    d = d.dropna(subset=["datetime"]).drop_duplicates("datetime").set_index("datetime")
    d = d[["open", "high", "low", "close"]]
    d.columns = ["o", "h", "l", "c"]
    d.to_csv(os.path.join(out, f"xau_m{step}_utc.csv"))
    print(f"M{step}: {len(d)} bars {d.index[0]} -> {d.index[-1]}")
