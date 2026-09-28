"""Market data loading: CSV files, Yahoo Finance (optional), or synthetic bars."""
from __future__ import annotations

import numpy as np
import pandas as pd

REQUIRED = ["open", "high", "low", "close", "volume"]


def _normalize(df: pd.DataFrame) -> pd.DataFrame:
    if isinstance(df.columns, pd.MultiIndex):  # yfinance multi-ticker layout
        df.columns = df.columns.get_level_values(0)
    df = df.rename(columns={c: str(c).strip().lower() for c in df.columns})
    if "adj close" in df.columns and "close" not in df.columns:
        df = df.rename(columns={"adj close": "close"})
    if "volume" not in df.columns:
        df["volume"] = 0.0
    missing = [c for c in REQUIRED if c not in df.columns]
    if missing:
        raise ValueError(f"data is missing columns: {missing}")
    df = df[REQUIRED].astype(float).dropna()
    df.index = pd.to_datetime(df.index)
    if df.index.tz is not None:
        df.index = df.index.tz_localize(None)
    return df.sort_index()


def load_csv(path: str) -> pd.DataFrame:
    """CSV with a datetime column (date/time/datetime/timestamp) and OHLCV columns."""
    raw = pd.read_csv(path)
    lower = {c.lower(): c for c in raw.columns}
    for key in ("datetime", "timestamp", "date", "time"):
        if key in lower:
            raw = raw.set_index(lower[key])
            break
    else:
        raw = raw.set_index(raw.columns[0])
    return _normalize(raw)


def load_yahoo(symbol: str, interval: str = "1d", period: str = "2y") -> pd.DataFrame:
    try:
        import yfinance as yf
    except ImportError as e:  # pragma: no cover
        raise RuntimeError("pip install yfinance to download market data") from e
    df = yf.download(symbol, interval=interval, period=period, progress=False, auto_adjust=True)
    if df.empty:
        raise ValueError(f"no data returned for {symbol} ({interval}, {period})")
    return _normalize(df)


def synthetic_data(bars: int = 2000, interval: str = "1d", seed: int = 42,
                   start_price: float = 100.0, drift: float = 0.0002,
                   vol: float = 0.012) -> pd.DataFrame:
    """Random-walk OHLCV bars with regime-switching trend, for offline testing."""
    rng = np.random.default_rng(seed)
    freq = {"1m": "min", "5m": "5min", "15m": "15min", "1h": "h", "1d": "B"}.get(interval, "B")
    if freq == "B":
        index = pd.bdate_range("2020-01-01", periods=bars)
    else:
        # only regular session hours 09:30-16:00 on weekdays
        per_day = int(390 / pd.Timedelta(freq).total_seconds() * 60)
        days = pd.bdate_range("2024-01-02", periods=bars // per_day + 2)
        index = pd.DatetimeIndex([d + pd.Timedelta(hours=9, minutes=30) + i * pd.Timedelta(freq)
                                  for d in days for i in range(per_day)])[:bars]
    regime = np.repeat(rng.choice([-1, 0, 1], size=bars // 100 + 1), 100)[:bars]
    rets = rng.normal(drift + regime * vol * 0.08, vol, bars)
    close = start_price * np.exp(np.cumsum(rets))
    open_ = np.r_[start_price, close[:-1]] * (1 + rng.normal(0, vol * 0.2, bars))
    spread = np.abs(rng.normal(0, vol * 0.6, bars)) * close
    high = np.maximum(open_, close) + spread
    low = np.minimum(open_, close) - spread
    volume = rng.integers(1_000, 50_000, bars).astype(float)
    return pd.DataFrame({"open": open_, "high": high, "low": low, "close": close,
                         "volume": volume}, index=index)


def load_data(source: str, interval: str = "1d", period: str = "2y", bars: int = 2000) -> pd.DataFrame:
    """source: path to a .csv, 'synthetic', or a ticker symbol (e.g. AAPL, BTC-USD, EURUSD=X)."""
    if source.lower().endswith(".csv"):
        return load_csv(source)
    if source.lower().startswith("synthetic"):
        return synthetic_data(bars=bars, interval=interval)
    return load_yahoo(source, interval=interval, period=period)
