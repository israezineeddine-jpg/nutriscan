"""Parameter search, walk-forward analysis and Monte Carlo robustness checks."""
from __future__ import annotations

import itertools

import numpy as np
import pandas as pd

from .engine import BacktestConfig, run_backtest
from .strategies import custom_rule_signals, get_strategy

OBJECTIVES = ("sharpe", "sortino", "calmar", "total_return_pct", "profit_factor", "expectancy_per_trade")


def backtest_strategy(df: pd.DataFrame, name: str, params: dict | None = None,
                      config: dict | None = None) -> dict:
    """Run a library strategy (or name='custom' with rule params) using its style's engine defaults."""
    params = params or {}
    if name == "custom":
        sig = custom_rule_signals(df, params.get("long_entry", ""), params.get("short_entry", ""),
                                  params.get("exit_rule", ""))
        engine = {}
    else:
        strat = get_strategy(name)
        sig = strat.signals(df, **params)
        engine = strat.engine
    cfg = BacktestConfig.from_dict({**engine, **(config or {})})
    return run_backtest(df, sig, cfg)


def _score(metrics: dict, objective: str, min_trades: int) -> float:
    if metrics.get("trades", 0) < min_trades:
        return -np.inf
    v = metrics.get(objective, -np.inf)
    return -np.inf if v is None or (isinstance(v, float) and np.isnan(v)) else min(float(v), 1e6)


def grid_search(df, name, grid=None, config=None, objective="sharpe", min_trades=10, top=5) -> list[dict]:
    grid = grid or get_strategy(name).grid
    keys = list(grid)
    rows = []
    for combo in itertools.product(*(grid[k] for k in keys)):
        params = dict(zip(keys, combo))
        m = backtest_strategy(df, name, params, config)["metrics"]
        rows.append({"params": params, "score": _score(m, objective, min_trades), "metrics": m})
    rows.sort(key=lambda r: r["score"], reverse=True)
    return rows[:top]


def walk_forward(df, name, grid=None, config=None, objective="sharpe", folds=4,
                 train_frac=0.7, min_trades=5) -> dict:
    """Anchored-free rolling walk-forward: optimize on each train window, test on the next unseen slice."""
    n = len(df)
    window = n // folds
    results, oos_equity = [], []
    for k in range(folds):
        seg = df.iloc[k * window:(k + 1) * window if k < folds - 1 else n]
        cut = int(len(seg) * train_frac)
        train, test = seg.iloc[:cut], seg.iloc[cut:]
        if len(test) < 20:
            continue
        best = grid_search(train, name, grid, config, objective, min_trades, top=1)[0]
        oos = backtest_strategy(test, name, best["params"], config)
        results.append({
            "fold": k + 1, "train": f"{train.index[0]} -> {train.index[-1]}",
            "test": f"{test.index[0]} -> {test.index[-1]}", "best_params": best["params"],
            "in_sample": {x: best["metrics"].get(x) for x in ("sharpe", "total_return_pct", "trades")},
            "out_of_sample": {x: oos["metrics"].get(x) for x in
                              ("sharpe", "total_return_pct", "max_drawdown_pct", "trades", "win_rate_pct")},
        })
        oos_equity.append(oos["equity"].pct_change().fillna(0))
    oos_ret = (np.prod([1 + r for s in oos_equity for r in s]) - 1) * 100 if oos_equity else 0.0
    is_sh = np.mean([r["in_sample"]["sharpe"] for r in results]) if results else 0
    oos_sh = np.mean([r["out_of_sample"]["sharpe"] for r in results]) if results else 0
    return {
        "folds": results,
        "oos_compounded_return_pct": round(float(oos_ret), 2),
        "avg_in_sample_sharpe": round(float(is_sh), 2),
        "avg_out_of_sample_sharpe": round(float(oos_sh), 2),
        "sharpe_degradation": round(float(oos_sh / is_sh), 2) if is_sh else None,
    }


def monte_carlo(trades: pd.DataFrame, capital: float, runs: int = 1000, seed: int = 0) -> dict:
    """Resample trade P&L with replacement to estimate the spread of outcomes and drawdowns."""
    if trades is None or len(trades) < 5:
        return {"error": "need at least 5 trades for Monte Carlo"}
    rng = np.random.default_rng(seed)
    rets = (trades.pnl / capital).to_numpy()  # approximate each trade as % of starting capital
    finals, dds = [], []
    for _ in range(runs):
        path = capital * np.cumprod(1 + rng.choice(rets, len(rets), replace=True))
        path = np.r_[capital, path]
        finals.append(path[-1] / capital - 1)
        dds.append((path / np.maximum.accumulate(path) - 1).min())
    finals, dds = np.array(finals) * 100, np.array(dds) * 100
    return {
        "runs": runs,
        "return_pct_p5": round(float(np.percentile(finals, 5)), 2),
        "return_pct_median": round(float(np.median(finals)), 2),
        "return_pct_p95": round(float(np.percentile(finals, 95)), 2),
        "max_drawdown_pct_median": round(float(np.median(dds)), 2),
        "max_drawdown_pct_p95_worst": round(float(np.percentile(dds, 5)), 2),
        "prob_loss_pct": round(float((finals < 0).mean() * 100), 2),
    }
