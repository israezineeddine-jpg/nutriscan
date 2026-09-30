import numpy as np
import pandas as pd
import pytest

from backtester import BacktestConfig, STRATEGIES, run_backtest, synthetic_data
from backtester.optimize import backtest_strategy, grid_search, monte_carlo, walk_forward
from backtester.strategies import custom_rule_signals


def flat_df(prices):
    idx = pd.bdate_range("2024-01-01", periods=len(prices))
    p = np.asarray(prices, float)
    return pd.DataFrame({"open": p, "high": p + 0.5, "low": p - 0.5, "close": p, "volume": 1000.0}, index=idx)


def test_no_lookahead_entry_at_next_open():
    df = flat_df([100, 101, 102, 103, 104])
    sig = pd.Series([1, np.nan, np.nan, np.nan, np.nan], index=df.index)
    cfg = BacktestConfig(commission_pct=0, slippage_pct=0, stop_atr=None, max_leverage=1.0)
    res = run_backtest(df, sig, cfg)
    t = res["trades"].iloc[0]
    assert t.entry_time == df.index[1] and t.entry == 101
    assert t.exit == 104 and t.exit_reason == "end"
    assert res["metrics"]["final_equity"] == pytest.approx(10_000 * 104 / 101, rel=1e-6)


def test_stop_loss_hits_and_limits_risk():
    df = flat_df([100, 100, 100, 90, 90])
    sig = pd.Series([1, np.nan, np.nan, np.nan, np.nan], index=df.index)
    cfg = BacktestConfig(commission_pct=0, slippage_pct=0, stop_atr=2.0, risk_per_trade=0.01)
    res = run_backtest(df, sig, cfg)
    t = res["trades"].iloc[0]
    assert t.exit_reason == "stop"
    # gapped through the stop -> filled at the open, loss larger than 1R
    assert t.r_multiple < -1


def test_flatten_eod_intraday():
    df = synthetic_data(bars=78 * 3, interval="5m")
    sig = pd.Series(1.0, index=df.index)
    res = run_backtest(df, sig, BacktestConfig(flatten_eod=True, stop_atr=None))
    assert (res["trades"].exit_reason.isin(["eod", "end"])).all()
    assert (res["trades"].entry_time.dt.date == res["trades"].exit_time.dt.date).all()


@pytest.mark.parametrize("name", sorted(STRATEGIES))
def test_every_strategy_runs(name):
    style = STRATEGIES[name].style
    df = synthetic_data(bars=1500, interval="1d" if style == "swing" else "5m")
    m = backtest_strategy(df, name)["metrics"]
    assert m["bars"] == 1500 and np.isfinite(m["final_equity"])


def test_custom_rules_and_injection_guard():
    df = synthetic_data(bars=500)
    sig = custom_rule_signals(df, "close > ema_50 and rsi_14 < 40", exit_rule="rsi_14 > 60")
    assert set(sig.dropna().unique()) <= {0.0, 1.0}
    with pytest.raises(ValueError):
        custom_rule_signals(df, "close.__class__")


def test_optimizers():
    df = synthetic_data(bars=1200)
    top = grid_search(df, "sma_crossover", {"fast": [10, 20], "slow": [50, 100]}, min_trades=1, top=2)
    assert len(top) == 2 and top[0]["score"] >= top[1]["score"]
    wf = walk_forward(df, "sma_crossover", {"fast": [10, 20], "slow": [50]}, folds=3, min_trades=1)
    assert len(wf["folds"]) == 3
    res = backtest_strategy(df, "donchian_breakout")
    mc = monte_carlo(res["trades"], 10_000, runs=200)
    assert mc["return_pct_p5"] <= mc["return_pct_median"] <= mc["return_pct_p95"]


def test_futures_contract_sizing_and_pnl():
    df = flat_df([3300, 3300, 3310, 3320, 3320])
    sig = pd.Series([1, np.nan, np.nan, np.nan, np.nan], index=df.index)
    cfg = BacktestConfig(point_value=10.0, whole_contracts=True, stop_atr=None, max_leverage=50,
                         commission_pct=0, slippage_pct=0, commission_per_contract=1.0)
    t = run_backtest(df, sig, cfg)["trades"].iloc[0]
    assert t.qty == np.floor(10_000 * 50 / (3300 * 10))
    assert t.pnl == pytest.approx(t.qty * (20 * 10 - 2.0))  # $20 move x $10/point, minus fees


def test_dukascopy_decode():
    import lzma
    import struct

    from dukascopy import decode_day

    rec = struct.Struct(">5if")
    raw = lzma.compress(rec.pack(0, 3300000, 3301500, 3299000, 3302000, 1.5)
                        + rec.pack(60, 3301500, 3301500, 3301500, 3301500, 0.0), format=lzma.FORMAT_ALONE)
    df = decode_day(raw, pd.Timestamp("2026-07-01"), 1000)
    assert len(df) == 1  # zero-volume filler minute dropped
    row = df.iloc[0]
    assert (row.open, row.high, row.low, row.close) == (3300.0, 3302.0, 3299.0, 3301.5)
    assert df.index[0] == pd.Timestamp("2026-07-01 00:00")


def test_dukascopy_all_timeframes():
    from dukascopy import TIMEFRAMES, to_bars

    idx = pd.date_range("2026-01-04 23:00", "2026-03-10 22:00", freq="min")  # UTC, spans a DST change
    idx = idx[idx.weekday < 5]
    rng = np.random.default_rng(0)
    close = 4000 + np.cumsum(rng.normal(0, 0.2, len(idx)))
    m1 = pd.DataFrame({"open": close, "high": close + 0.3, "low": close - 0.3, "close": close, "volume": 1.0}, index=idx)
    counts = {}
    for tf in TIMEFRAMES:
        b = to_bars(m1, tf)
        counts[tf] = len(b)
        assert (b.high >= b[["open", "close"]].max(axis=1)).all() and b.index.is_monotonic_increasing
        assert b.volume.sum() == pytest.approx(len(m1))            # no minute lost in any timeframe
    assert counts["1min"] > counts["5min"] > counts["1h"] > counts["1D"] > counts["1W"] >= counts["1M"] >= 2
