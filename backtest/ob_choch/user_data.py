"""Run the OB30 zone + CHoCH recipes on the user's own XAUUSD files (MT4 / MT5 exports or any OHLC CSV).

usage: python3 user_data.py <file> [<file> ...] --out <dir> [--ref <dir with xau_m5_utc.csv>]

- Accepted formats (auto-detected):
  - MT5 "Export bars" (<DATE> <TIME> <OPEN> ...);
  - MT4 history CSV without header (2025.06.02,01:00,o,h,l,c,v);
  - any CSV with date/time + open/high/low/close columns (separator , ; or tab).
- Broker server time is detected week by week from the gold daily break (17:00-18:00 New York) and converted to UTC.
- The finest timeframe given is used. M1 runs the M1 and M5 recipes; M5 runs only the M5 recipe.
- Zones are always built from M30 bars resampled from that data.
"""
import argparse, os, re
import numpy as np
import pandas as pd
import ob_choch as ob

KEYS = ("date", "time", "open", "high", "low", "close")


def _norm(c):
    return re.sub(r"[<>\s]", "", str(c)).lower()


def _to_dt(s):
    s = s.astype(str).str.strip()
    s = s.str.replace(r"^(\d{4})\.(\d{2})\.(\d{2})", r"\1-\2-\3", regex=True)      # 2025.06.02 -> 2025-06-02
    dayfirst = bool(re.match(r"^\d{2}[./-]\d{2}[./-]\d{4}", s.iloc[0]))         # 02.06.2025 (Dukascopy)
    return pd.to_datetime(s, dayfirst=dayfirst, errors="coerce")


def load_any(path):
    with open(path, "r", errors="replace") as f:
        first = f.readline().strip()
    sep = "\t" if "\t" in first else (";" if first.count(";") >= 3 else ",")
    header = any(k in first.lower() for k in KEYS)
    if header:
        d = pd.read_csv(path, sep=sep)
        d.columns = [_norm(c) for c in d.columns]
        col = {k: next((c for c in d.columns if c == k or c.startswith(k)), None) for k in ("open", "high", "low", "close")}
        if "date" in d.columns and "time" in d.columns:
            dt = _to_dt(d["date"].astype(str) + " " + d["time"].astype(str))
        else:
            tcol = next(c for c in d.columns if any(w in c for w in ("datetime", "timestamp", "gmttime", "localtime", "time", "date")))
            dt = _to_dt(d[tcol])
        o, h, l, c = (pd.to_numeric(d[col[k]], errors="coerce") for k in ("open", "high", "low", "close"))
    else:
        d = pd.read_csv(path, sep=sep, header=None)
        if re.match(r"^\d{1,2}:\d{2}", str(d.iloc[0, 1])):                         # date, time, o, h, l, c
            dt = _to_dt(d[0].astype(str) + " " + d[1].astype(str)); k0 = 2
        else:
            dt = _to_dt(d[0]); k0 = 1
        o, h, l, c = (pd.to_numeric(d[k0 + i], errors="coerce") for i in range(4))
    out = pd.DataFrame({"o": o.values, "h": h.values, "l": l.values, "c": c.values}, index=pd.DatetimeIndex(dt, name="datetime"))
    out = out[~out.index.isna()].dropna()
    out = out[~out.index.duplicated()].sort_index()
    return out


def server_offsets(d):
    """Hours to subtract (per ISO week) to go from broker server time to UTC, using the 1-hour daily break."""
    idx = d.index
    wk = idx.to_period("W")
    res = {}
    for w, g in pd.Series(idx.hour, index=idx)[idx.dayofweek < 4].groupby(wk[idx.dayofweek < 4]):   # Mon-Thu
        cnt = g.value_counts().reindex(range(24), fill_value=0)
        if cnt.median() == 0 or cnt.min() > 0.2 * cnt.median():
            continue                                                                # no clear break this week
        empty = int(cnt.idxmin())
        wed = (w.start_time + pd.Timedelta(days=2)).normalize() + pd.Timedelta(hours=17)
        brk_utc = wed.tz_localize("America/New_York").tz_convert("UTC").hour
        res[w] = ((empty - brk_utc + 12) % 24) - 12
    if not res:
        return None
    s = pd.Series(res).sort_index()
    full = pd.period_range(wk.min(), wk.max(), freq="W")
    return s.reindex(full).ffill().bfill()


def to_utc(d):
    off = server_offsets(d)
    if off is None:
        print("  no daily break found: timestamps kept as they are (assumed UTC)")
        return d, {}
    hours = off.reindex(d.index.to_period("W")).values
    u = d.copy()
    u.index = d.index - pd.to_timedelta(hours, unit="h")
    return u[~u.index.duplicated()].sort_index(), off.value_counts().to_dict()


def step_min(d):
    return int(pd.Series(d.index[:5000]).diff().dt.total_seconds().mode().iloc[0] // 60)


RECIPES = [  # (name, entry TF, N, W, SL buffer $, session UTC)
    ("M1", "M1", 3, 15, 1.0, (7, 21)),
    ("M5", "M5", 3, 6, 0.5, None),
]
RRS = [1, 2, 3, 4]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ref", default=None, help="folder with the Twelve Data xau_m5_utc.csv to compare prices")
    ap.add_argument("--spread", type=float, default=0.35)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    data = {}
    for f in a.files:
        raw = load_any(f)
        tf = step_min(raw)
        utc, offs = to_utc(raw)
        print(f"{os.path.basename(f)}: M{tf}, {len(raw)} bars {raw.index[0]} -> {raw.index[-1]} | server offset (h): {offs}")
        data[tf] = ob.market_hours(utc)
    base = data[min(data)]
    m1 = data.get(1)
    m5 = data.get(5) if 5 in data else (ob.resample(m1, "5min") if m1 is not None else None)
    if m5 is None:
        raise SystemExit("need M1 or M5 data")
    zones = ob.build_zones(ob.resample(base, "30min"))
    print("zones:", len(zones), "| data", base.index[0], "->", base.index[-1])
    if a.ref:
        ref = ob.market_hours(ob.load_utc(os.path.join(a.ref, "xau_m5_utc.csv")))
        j = m5.join(ref, rsuffix="_ref", how="inner")
        if len(j):
            diff = (j.c - j.c_ref).abs()
            print(f"price check vs Twelve Data on {len(j)} common M5 bars: median |close diff| = {diff.median():.2f} $,"
                  f" 95% = {diff.quantile(.95):.2f} $")
    rows = []
    t0, t1 = base.index[0], base.index[-1]
    halves = pd.date_range(t0.to_period("Q").start_time, t1, freq="6MS")
    for name, tf, N, W, buf, sess in RECIPES:
        if tf == "M1" and m1 is None:
            continue
        ltf = m1 if tf == "M1" else m5
        ex = ob.Exec(ltf)
        res = ob.simulate(ob.find_entries(zones, ltf, N=N, W=W), ltf, ex, "zone", buf, RRS, spread=a.spread, session=sess)
        for rr, tr in res.items():
            tr.to_csv(os.path.join(a.out, f"user_trades_{name}_RR{rr}.csv"), index=False)
            t = pd.to_datetime(tr.open)
            for i, start in enumerate(halves):
                end = halves[i + 1] if i + 1 < len(halves) else t1 + pd.Timedelta(days=1)
                d = tr[(t >= start) & (t < end)]
                if len(d):
                    rows.append(dict(recipe=f"{name} RR1:{rr}", period=f"{start:%Y-%m}..{(end - pd.Timedelta(days=1)):%Y-%m}", **ob.stats(d)))
            rows.append(dict(recipe=f"{name} RR1:{rr}", period="TOTAL", **ob.stats(tr)))
    rep = pd.DataFrame(rows)
    rep.to_csv(os.path.join(a.out, "user_report.csv"), index=False)
    cols = ["recipe", "period", "n", "win", "PF", "totR", "ddR", "ROI%@0.5", "DD%@0.5", "ROI%@1.0", "DD%@1.0", "months+"]
    print(rep[[c for c in cols if c in rep.columns]].to_string(index=False))


if __name__ == "__main__":
    main()
