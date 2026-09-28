"""Performance statistics."""
from __future__ import annotations

import numpy as np
import pandas as pd


def periods_per_year(index: pd.DatetimeIndex) -> float:
    days = pd.Series(index.normalize()).nunique()
    bars_per_day = len(index) / max(days, 1)
    return 252 * max(bars_per_day, 1.0)


def compute_metrics(equity: pd.Series, trades: pd.DataFrame, df: pd.DataFrame, capital: float) -> dict:
    rets = equity.pct_change().fillna(0.0)
    ppy = periods_per_year(equity.index)
    years = max(len(equity) / ppy, 1e-9)
    final = float(equity.iloc[-1])
    total = final / capital - 1
    peak = equity.cummax()
    dd = equity / peak - 1
    sd = rets.std()
    down = rets[rets < 0].std()
    buy_hold = df["close"].iloc[-1] / df["close"].iloc[0] - 1

    m = {
        "start": str(equity.index[0]), "end": str(equity.index[-1]), "bars": len(equity),
        "final_equity": round(final, 2),
        "total_return_pct": round(total * 100, 2),
        "cagr_pct": round(((final / capital) ** (1 / years) - 1) * 100, 2) if final > 0 else -100.0,
        "buy_and_hold_pct": round(buy_hold * 100, 2),
        "max_drawdown_pct": round(dd.min() * 100, 2),
        "sharpe": round(rets.mean() / sd * np.sqrt(ppy), 2) if sd > 0 else 0.0,
        "sortino": round(rets.mean() / down * np.sqrt(ppy), 2) if down and down > 0 else 0.0,
        "trades": int(len(trades)),
    }
    m["calmar"] = round(m["cagr_pct"] / abs(m["max_drawdown_pct"]), 2) if m["max_drawdown_pct"] else 0.0
    if len(trades):
        wins, losses = trades[trades.pnl > 0], trades[trades.pnl <= 0]
        gross_loss = -losses.pnl.sum()
        m.update({
            "win_rate_pct": round(len(wins) / len(trades) * 100, 2),
            "profit_factor": round(wins.pnl.sum() / gross_loss, 2) if gross_loss > 0 else float("inf"),
            "avg_win": round(wins.pnl.mean(), 2) if len(wins) else 0.0,
            "avg_loss": round(losses.pnl.mean(), 2) if len(losses) else 0.0,
            "expectancy_per_trade": round(trades.pnl.mean(), 2),
            "avg_r_multiple": round(trades.r_multiple.mean(), 3),
            "avg_bars_held": round(trades.bars_held.mean(), 1),
            "long_trades": int((trades.side == "long").sum()),
            "short_trades": int((trades.side == "short").sum()),
            "exit_reasons": trades.exit_reason.value_counts().to_dict(),
            "exposure_pct": round(trades.bars_held.sum() / len(equity) * 100, 2),
        })
    return m
