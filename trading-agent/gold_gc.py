"""Backtest intraday strategies on COMEX gold futures (GC / MGC), 5-minute bars.

    python gold_gc.py --csv data/GC_5m.csv            # your exported data (time + OHLCV)
    python gold_gc.py --synthetic                      # offline check of the pipeline only
    python gold_gc.py --csv data/GC_5m.csv --contract GC --risk 0.02 --rr 1.5

Timestamps are read as New York time (UTC / unix timestamps are converted). The gold
futures session runs 18:00 -> 17:00 ET; positions are closed at 17:00 ET before the daily
break (and therefore before the weekend) unless --hold-overnight is given.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from backtester import BacktestConfig, run_backtest
from backtester.data import load_csv
from backtester.optimize import monte_carlo
from backtester.strategies import get_strategy

CONTRACTS = {  # point value = $ per 1.00 move in price per contract
    "GC": {"point_value": 100.0, "commission_per_contract": 2.5, "slippage_points": 0.10},
    "MGC": {"point_value": 10.0, "commission_per_contract": 1.0, "slippage_points": 0.10},
}
STRATEGIES = ["ema_vwap_scalp", "rsi_scalp", "bollinger_scalp", "vwap_reversion", "macd_momentum",
              "donchian_breakout"]
SESSION_SHIFT = pd.Timedelta(hours=6)  # 18:00 ET session open -> midnight, so "a day" = one session


def synthetic_gold(days: int = 60, seed: int = 7) -> pd.DataFrame:
    """Random-walk 5m gold bars, 23h sessions, more volatile in London/NY hours. Mechanics check only."""
    rng = np.random.default_rng(seed)
    idx = []
    for d in pd.bdate_range("2026-06-01", periods=days):
        start = d - pd.Timedelta(hours=6)  # 18:00 ET the previous evening
        idx += list(pd.date_range(start, periods=23 * 12, freq="5min"))
    idx = pd.DatetimeIndex(idx)
    hour = idx.hour
    vol = np.where((hour >= 8) & (hour < 12), 0.0012, np.where((hour >= 3) & (hour < 8), 0.0008, 0.0004))
    rets = rng.normal(0, vol)
    close = 3300 * np.exp(np.cumsum(rets))
    open_ = np.r_[3300, close[:-1]]
    wick = np.abs(rng.normal(0, vol * 0.7)) * close
    return pd.DataFrame({"open": open_, "high": np.maximum(open_, close) + wick,
                         "low": np.minimum(open_, close) - wick, "close": close,
                         "volume": rng.integers(50, 2000, len(idx)).astype(float)}, index=idx)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--csv")
    src.add_argument("--synthetic", action="store_true")
    ap.add_argument("--contract", choices=list(CONTRACTS), default="MGC")
    ap.add_argument("--capital", type=float, default=10_000)
    ap.add_argument("--risk", type=float, default=0.01, help="fraction of equity risked per trade")
    ap.add_argument("--stop-atr", type=float, default=1.5, help="stop distance in ATR(14) of 5m bars")
    ap.add_argument("--rr", type=float, default=1.0, help="reward:risk, 1.0 = target equals stop")
    ap.add_argument("--hold-overnight", action="store_true")
    ap.add_argument("--strategies", nargs="*", default=STRATEGIES)
    a = ap.parse_args()

    df = synthetic_gold() if a.synthetic else load_csv(a.csv)
    df = df.set_axis(df.index + SESSION_SHIFT)  # sessions (and VWAP resets) start at 18:00 ET
    cfg = {**CONTRACTS[a.contract], "initial_capital": a.capital, "risk_per_trade": a.risk,
           "stop_atr": a.stop_atr, "target_atr": a.stop_atr * a.rr, "max_hold_bars": None,
           "flatten_eod": not a.hold_overnight, "whole_contracts": True, "max_leverage": 50,
           "commission_pct": 0.0, "slippage_pct": 0.0}

    first = (df.index[0] - SESSION_SHIFT)
    last = (df.index[-1] - SESSION_SHIFT)
    print(f"{'SYNTHETIC ' if a.synthetic else ''}{a.contract} 5m: {len(df)} bars, {first} -> {last} (ET)")
    print(f"capital ${a.capital:,.0f} | risk {a.risk:.1%}/trade | stop {a.stop_atr} ATR | R:R 1:{a.rr}\n")

    cols = ["total_return_pct", "max_drawdown_pct", "win_rate_pct", "profit_factor", "trades",
            "expectancy_per_trade", "sharpe", "skipped_entries_too_small"]
    rows, results = [], {}
    for name in a.strategies:
        strat = get_strategy(name)
        res = run_backtest(df, strat.signals(df), BacktestConfig.from_dict(cfg))
        results[name] = res
        rows.append({"strategy": name, **{c: res["metrics"].get(c, 0) for c in cols}})
    table = pd.DataFrame(rows).set_index("strategy").sort_values("total_return_pct", ascending=False)
    print(table.to_string())

    if table.trades.sum() == 0:
        print(f"\nNo trades: {a.risk:.1%} of ${a.capital:,.0f} is less than the stop-loss of one {a.contract} "
              f"contract. Use --contract MGC or a larger --risk.")
        return
    best = table.index[0]
    res = results[best]
    print(f"\nbest: {best}")
    print("Monte Carlo:", monte_carlo(res["trades"], a.capital))
    out = Path("reports") / f"gold_{a.contract}_{best}"
    out.mkdir(parents=True, exist_ok=True)
    trades = res["trades"].copy()
    for c in ("entry_time", "exit_time"):
        trades[c] = trades[c] - SESSION_SHIFT
    trades.to_csv(out / "trades.csv", index=False)
    table.to_csv(out.parent / f"gold_{a.contract}_comparison.csv")
    print(f"saved {out}/trades.csv")
    if a.synthetic:
        print("\nNOTE: synthetic random-walk data - these numbers only prove the pipeline works.")


if __name__ == "__main__":
    main()
