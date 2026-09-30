"""Download free Dukascopy history (e.g. XAUUSD spot gold) and save 5-minute OHLCV bars.

    python dukascopy.py XAUUSD 2025-01-01 2026-09-01 --tf 5min -o data/XAUUSD_5m.csv
    python dukascopy.py XAUUSD 2022-01-01 2026-09-29 --tf all      # M1 M5 M15 M30 H1 H4 D1 W1 MN, one file each
    python gold_gc.py --csv data/XAUUSD_5m.csv

Uses Dukascopy's public daily 1-minute candle files (BID side). Requires network access to
datafeed.dukascopy.com. Times are converted from UTC to New York time, which gold_gc.py expects.
Note: XAUUSD is spot gold, not the GC futures contract; prices differ by the futures basis
(a few dollars) but intraday moves are nearly identical, so it is a good proxy for backtests.
"""
from __future__ import annotations

import argparse
import lzma
import struct
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd

URL = "https://datafeed.dukascopy.com/datafeed/{sym}/{y}/{m:02d}/{d:02d}/BID_candles_min_1.bi5"
# price divisor per instrument (Dukascopy stores prices as integers)
SCALE = {"XAUUSD": 1000, "XAGUSD": 1000, "USA500IDXUSD": 1000, "USATECHIDXUSD": 1000}
RECORD = struct.Struct(">5if")  # seconds from midnight, open, close, low, high, volume


def decode_day(raw: bytes, day: pd.Timestamp, scale: float) -> pd.DataFrame:
    if not raw:
        return pd.DataFrame()
    data = lzma.decompress(raw)
    rows = [RECORD.unpack_from(data, i) for i in range(0, len(data) - RECORD.size + 1, RECORD.size)]
    df = pd.DataFrame(rows, columns=["t", "open", "close", "low", "high", "volume"])
    df.index = day + pd.to_timedelta(df.pop("t"), unit="s")
    df[["open", "close", "low", "high"]] /= scale
    return df[df.volume > 0][["open", "high", "low", "close", "volume"]]  # drop flat filler minutes


def fetch_day(sym: str, day: pd.Timestamp, scale: float, cache: Path, retries: int = 6):
    """Return the day's 1-minute bars; None if the server kept failing (rerun to retry only those days)."""
    url = URL.format(sym=sym, y=day.year, m=day.month - 1, d=day.day)  # month is 0-based in the URL
    f = cache / f"{sym}_{day:%Y%m%d}.bi5"
    if f.exists():
        return decode_day(f.read_bytes(), day, scale)
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                raw = r.read()
            cache.mkdir(parents=True, exist_ok=True)
            f.write_bytes(raw)                       # cache raw file (even empty = holiday) so reruns skip it
            return decode_day(raw, day, scale)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                cache.mkdir(parents=True, exist_ok=True)
                f.write_bytes(b"")
                return pd.DataFrame()
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(2 ** attempt)                     # 1s, 2s, 4s ... server busy / 503
    return None


TIMEFRAMES = {"1min": "1min", "5min": "5min", "15min": "15min", "30min": "30min", "1h": "1h",
              "4h": "4h", "1D": "1D", "1W": "W-SUN", "1M": "MS"}
AGG = {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}


def download_m1(sym: str, start: str, end: str, workers: int = 4,
                cache_dir: str = "data/.dukascopy_cache") -> pd.DataFrame:
    """All 1-minute bars (UTC, naive index) between start and end."""
    sym = sym.upper()
    scale = SCALE.get(sym, 100_000)
    days = [d for d in pd.date_range(start, end, freq="D") if d.weekday() != 5]  # no Saturday data
    cache = Path(cache_dir)
    with ThreadPoolExecutor(workers) as pool:
        results = list(pool.map(lambda d: fetch_day(sym, d, scale, cache), days))
    failed = [d.date() for d, r in zip(days, results) if r is None]
    if failed:
        print(f"WARNING: {len(failed)} days failed (server busy). Run the same command again to retry only those: "
              f"{failed[:5]}{' ...' if len(failed) > 5 else ''}", file=sys.stderr)
    parts = [r for r in results if r is not None and len(r)]
    if not parts:
        raise RuntimeError("no data downloaded - check the symbol, dates and your connection")
    return pd.concat(parts).sort_index()


def to_bars(m1: pd.DataFrame, tf: str) -> pd.DataFrame:
    """Resample 1-minute bars. Result index is New York time.
    Intraday frames are aligned in UTC; 1D / 1W / 1M follow the 17:00 New York session roll (the forex/gold trading day)."""
    rule = TIMEFRAMES.get(tf, tf)
    if tf in ("1D", "1W", "1M"):
        ny = m1.tz_localize("UTC").tz_convert("America/New_York")
        shifted = ny.set_axis(ny.index + pd.Timedelta(hours=7))          # 17:00 New York -> midnight
        bars = shifted.resample(rule, label="left", closed="left").agg(AGG).dropna()
        bars = bars.set_axis(bars.index - pd.Timedelta(hours=7))          # label = session start (17:00 NY)
        bars.index = bars.index.tz_localize(None)
    else:
        bars = m1.resample(rule, label="left", closed="left").agg(AGG).dropna()
        bars.index = bars.index.tz_localize("UTC").tz_convert("America/New_York").tz_localize(None)
    bars.index.name = "datetime"
    return bars


def download(sym: str, start: str, end: str, tf: str = "5min", workers: int = 4,
             cache_dir: str = "data/.dukascopy_cache") -> pd.DataFrame:
    return to_bars(download_m1(sym, start, end, workers, cache_dir), tf)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("symbol")
    ap.add_argument("start")
    ap.add_argument("end")
    ap.add_argument("--tf", default="5min",
                    help="1min 5min 15min 30min 1h 4h 1D 1W 1M, several separated by commas, or 'all'")
    ap.add_argument("-o", "--out", help="output file (single timeframe only)")
    ap.add_argument("--outdir", default="data", help="output folder when several timeframes are requested")
    a = ap.parse_args()
    tfs = list(TIMEFRAMES) if a.tf == "all" else a.tf.split(",")
    m1 = download_m1(a.symbol, a.start, a.end)
    for tf in tfs:
        bars = to_bars(m1, tf)
        out = Path(a.out) if a.out and len(tfs) == 1 else Path(a.outdir) / f"{a.symbol.upper()}_{tf}.csv"
        out.parent.mkdir(parents=True, exist_ok=True)
        bars.round(3).to_csv(out)
        print(f"{tf:>5}: {len(bars):>8} bars {bars.index[0]} -> {bars.index[-1]} (New York time) -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
