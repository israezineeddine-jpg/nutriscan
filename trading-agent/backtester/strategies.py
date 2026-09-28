"""Strategy library for scalping, day trading and swing trading.

Every strategy returns a *target position* series aligned with the data:
  1 = be long, -1 = be short, 0 = be flat, NaN = keep whatever position is open.
The signal on bar t is computed from data up to and including bar t's close and
is executed by the engine at the open of bar t+1 (no look-ahead).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable

import numpy as np
import pandas as pd

from . import indicators as ta


@dataclass
class Strategy:
    name: str
    style: str  # "scalp" | "day" | "swing"
    description: str
    fn: Callable[..., pd.Series]
    defaults: dict
    grid: dict = field(default_factory=dict)
    # engine defaults that suit the style; users/agent can override
    engine: dict = field(default_factory=dict)

    def signals(self, df: pd.DataFrame, **params) -> pd.Series:
        p = {**self.defaults, **{k: v for k, v in params.items() if k in self.defaults}}
        return self.fn(df, **p).reindex(df.index)


def _cross_up(a, b):
    return (a > b) & (a.shift() <= b.shift())


def _cross_down(a, b):
    return (a < b) & (a.shift() >= b.shift())


# ---------------------------------------------------------------- scalping
def ema_vwap_scalp(df, fast=9, slow=21):
    f, s, vwap = ta.ema(df.close, fast), ta.ema(df.close, slow), ta.session_vwap(df)
    sig = pd.Series(np.nan, index=df.index)
    sig[_cross_up(f, s) & (df.close > vwap)] = 1
    sig[_cross_down(f, s) & (df.close < vwap)] = -1
    return sig


def rsi_scalp(df, period=7, lower=20, upper=80):
    r = ta.rsi(df.close, period)
    sig = pd.Series(np.nan, index=df.index)
    sig[_cross_up(r, pd.Series(50, index=df.index)) | _cross_down(r, pd.Series(50, index=df.index))] = 0
    sig[r < lower] = 1
    sig[r > upper] = -1
    return sig


def bollinger_scalp(df, period=20, k=2.0):
    lo, mid, hi = ta.bollinger(df.close, period, k)
    sig = pd.Series(np.nan, index=df.index)
    sig[_cross_up(df.close, mid) | _cross_down(df.close, mid)] = 0
    sig[df.close < lo] = 1
    sig[df.close > hi] = -1
    return sig


# ---------------------------------------------------------------- day trading
def opening_range_breakout(df, range_bars=6):
    """Break of the first `range_bars` bars of each session; one trade per side per day."""
    day = df.index.normalize()
    bar_no = df.groupby(day).cumcount()
    in_range = bar_no < range_bars
    or_high = df.high.where(in_range).groupby(day).transform("max")
    or_low = df.low.where(in_range).groupby(day).transform("min")
    long_break = (~in_range) & (df.close > or_high)
    short_break = (~in_range) & (df.close < or_low)
    # only the first break of each direction per day
    long_first = long_break & (long_break.astype(int).groupby(day).cumsum() == 1)
    short_first = short_break & (short_break.astype(int).groupby(day).cumsum() == 1)
    sig = pd.Series(np.nan, index=df.index)
    sig[long_first] = 1
    sig[short_first] = -1
    return sig


def vwap_reversion(df, atr_period=14, band=1.5):
    vwap, a = ta.session_vwap(df), ta.atr(df, atr_period)
    dev = (df.close - vwap) / a
    sig = pd.Series(np.nan, index=df.index)
    sig[_cross_up(df.close, vwap) | _cross_down(df.close, vwap)] = 0
    sig[dev < -band] = 1
    sig[dev > band] = -1
    return sig


def macd_momentum(df, fast=12, slow=26, signal=9, trend=50):
    line, sig_line, _ = ta.macd(df.close, fast, slow, signal)
    t = ta.ema(df.close, trend)
    sig = pd.Series(np.nan, index=df.index)
    sig[_cross_down(line, sig_line) | _cross_up(line, sig_line)] = 0
    sig[_cross_up(line, sig_line) & (df.close > t)] = 1
    sig[_cross_down(line, sig_line) & (df.close < t)] = -1
    return sig


# ---------------------------------------------------------------- swing trading
def sma_crossover(df, fast=20, slow=50):
    f, s = ta.sma(df.close, fast), ta.sma(df.close, slow)
    return pd.Series(np.where(f > s, 1, -1), index=df.index).where(s.notna())


def rsi2_pullback(df, trend=200, period=2, entry=10, exit_ma=5):
    """Connors-style: buy short-term oversold dips inside a long-term uptrend."""
    t, r, e = ta.sma(df.close, trend), ta.rsi(df.close, period), ta.sma(df.close, exit_ma)
    sig = pd.Series(np.nan, index=df.index)
    sig[df.close > e] = 0
    sig[(df.close > t) & (r < entry)] = 1
    return sig


def donchian_breakout(df, entry=20, exit=10):
    """Turtle-style channel breakout, long and short."""
    hi_e, lo_e = (x.shift() for x in ta.donchian(df, entry))
    hi_x, lo_x = (x.shift() for x in ta.donchian(df, exit))
    sig = pd.Series(np.nan, index=df.index)
    sig[(df.close < lo_x) | (df.close > hi_x)] = 0
    sig[df.close > hi_e] = 1
    sig[df.close < lo_e] = -1
    return sig


SCALP_ENGINE = {"stop_atr": 1.0, "target_atr": 1.5, "max_hold_bars": 30, "flatten_eod": True}
DAY_ENGINE = {"stop_atr": 1.5, "target_atr": 3.0, "max_hold_bars": None, "flatten_eod": True}
SWING_ENGINE = {"stop_atr": 3.0, "target_atr": None, "max_hold_bars": None, "flatten_eod": False}

STRATEGIES: dict[str, Strategy] = {s.name: s for s in [
    Strategy("ema_vwap_scalp", "scalp", "EMA fast/slow cross filtered by session VWAP side (1m-5m bars).",
             ema_vwap_scalp, {"fast": 9, "slow": 21}, {"fast": [5, 9, 13], "slow": [21, 34, 55]}, SCALP_ENGINE),
    Strategy("rsi_scalp", "scalp", "Fade RSI extremes, exit when RSI crosses 50 (1m-5m bars).",
             rsi_scalp, {"period": 7, "lower": 20, "upper": 80},
             {"period": [5, 7, 9], "lower": [15, 20, 25], "upper": [75, 80, 85]}, SCALP_ENGINE),
    Strategy("bollinger_scalp", "scalp", "Fade closes outside Bollinger Bands, exit at the middle band.",
             bollinger_scalp, {"period": 20, "k": 2.0}, {"period": [14, 20, 30], "k": [1.5, 2.0, 2.5]}, SCALP_ENGINE),
    Strategy("opening_range_breakout", "day", "Trade the first break of the opening range, flat at session end (5m-15m bars).",
             opening_range_breakout, {"range_bars": 6}, {"range_bars": [3, 6, 12]}, DAY_ENGINE),
    Strategy("vwap_reversion", "day", "Fade stretches of N ATRs away from session VWAP, exit back at VWAP.",
             vwap_reversion, {"atr_period": 14, "band": 1.5}, {"band": [1.0, 1.5, 2.0, 2.5]}, DAY_ENGINE),
    Strategy("macd_momentum", "day", "MACD signal-line cross in the direction of the EMA trend.",
             macd_momentum, {"fast": 12, "slow": 26, "signal": 9, "trend": 50},
             {"fast": [8, 12], "slow": [21, 26], "trend": [50, 100]}, DAY_ENGINE),
    Strategy("sma_crossover", "swing", "Always-in-market fast/slow SMA trend following (daily bars).",
             sma_crossover, {"fast": 20, "slow": 50}, {"fast": [10, 20, 50], "slow": [50, 100, 200]}, SWING_ENGINE),
    Strategy("rsi2_pullback", "swing", "Buy RSI(2) dips above the 200 SMA, exit above the 5 SMA (daily bars).",
             rsi2_pullback, {"trend": 200, "period": 2, "entry": 10, "exit_ma": 5},
             {"entry": [5, 10, 15], "exit_ma": [5, 10]}, SWING_ENGINE),
    Strategy("donchian_breakout", "swing", "Turtle channel breakout with a shorter exit channel (daily bars).",
             donchian_breakout, {"entry": 20, "exit": 10}, {"entry": [20, 40, 55], "exit": [10, 20]}, SWING_ENGINE),
]}


def get_strategy(name: str) -> Strategy:
    if name not in STRATEGIES:
        raise KeyError(f"unknown strategy {name!r}; choose from {sorted(STRATEGIES)}")
    return STRATEGIES[name]


# ---------------------------------------------------------------- custom rules
_IND = re.compile(r"\b(ema|sma|rsi|atr)_(\d+)\b")
_ALLOWED = re.compile(r"^[\w\s\.\(\)<>=!&|~+\-*/]+$")


def _feature_frame(df: pd.DataFrame, exprs: list[str]) -> pd.DataFrame:
    feats = df.copy()
    feats["vwap"] = ta.session_vwap(df)
    for expr in exprs:
        for kind, n in _IND.findall(expr):
            col, n = f"{kind}_{n}", int(n)
            if col in feats:
                continue
            feats[col] = {"ema": lambda: ta.ema(df.close, n), "sma": lambda: ta.sma(df.close, n),
                          "rsi": lambda: ta.rsi(df.close, n), "atr": lambda: ta.atr(df, n)}[kind]()
    for col in ["open", "high", "low", "close", "volume", "vwap"] + [c for c in feats if _IND.fullmatch(c)]:
        feats[f"prev_{col}"] = feats[col].shift()
    return feats


def custom_rule_signals(df: pd.DataFrame, long_entry: str = "", short_entry: str = "",
                        exit_rule: str = "") -> pd.Series:
    """Build a signal from boolean expressions, e.g. long_entry="close > ema_50 and rsi_14 < 30".

    Available names: open, high, low, close, volume, vwap, ema_N, sma_N, rsi_N, atr_N and
    prev_<name> for the previous bar's value.
    """
    exprs = [e for e in (long_entry, short_entry, exit_rule) if e]
    for e in exprs:
        if not _ALLOWED.match(e) or "__" in e:
            raise ValueError(f"unsupported characters in rule: {e!r}")
    feats = _feature_frame(df, exprs)
    sig = pd.Series(np.nan, index=df.index)

    def ev(e):
        return feats.eval(e.replace(" and ", " & ").replace(" or ", " | "), engine="python").fillna(False).astype(bool)

    if exit_rule:
        sig[ev(exit_rule)] = 0
    if long_entry:
        sig[ev(long_entry)] = 1
    if short_entry:
        sig[ev(short_entry)] = -1
    return sig
