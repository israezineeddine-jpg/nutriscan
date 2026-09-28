"""Bar-by-bar execution engine with ATR stops/targets, costs and risk-based sizing."""
from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np
import pandas as pd

from . import indicators as ta
from .metrics import compute_metrics


@dataclass
class BacktestConfig:
    initial_capital: float = 10_000.0
    risk_per_trade: float = 0.01      # fraction of equity lost if the stop is hit
    max_leverage: float = 1.0         # cap on position notional / equity
    commission_pct: float = 0.0005    # per side, fraction of notional
    slippage_pct: float = 0.0002      # per side, adverse fill vs. quoted price
    atr_period: int = 14
    stop_atr: float | None = 2.0      # stop distance in ATRs (None = no stop)
    target_atr: float | None = None   # take-profit distance in ATRs (None = no target)
    trail_atr: float | None = None    # trailing stop distance in ATRs
    max_hold_bars: int | None = None  # time stop
    flatten_eod: bool = False         # close everything on the last bar of each session
    allow_short: bool = True

    @classmethod
    def from_dict(cls, d: dict | None) -> "BacktestConfig":
        d = d or {}
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


def run_backtest(df: pd.DataFrame, signals: pd.Series, config: BacktestConfig | None = None) -> dict:
    cfg = config or BacktestConfig()
    o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    atr = ta.atr(df, cfg.atr_period).bfill().to_numpy(float)
    sig = signals.reindex(df.index).to_numpy(float)
    days = df.index.normalize()
    last_of_day = np.r_[days[1:] != days[:-1], True]
    n = len(df)

    cash = cfg.initial_capital
    pos = 0.0            # signed quantity
    entry_px = stop = target = 0.0
    entry_i = 0
    entry_cost = entry_risk = 0.0
    trades: list[dict] = []
    equity = np.empty(n)

    def fill(px, side):  # side +1 buying, -1 selling
        return px * (1 + side * cfg.slippage_pct)

    def close_position(i, px, reason):
        nonlocal cash, pos
        side = -np.sign(pos)
        fpx = fill(px, side)
        fee = abs(pos) * fpx * cfg.commission_pct
        cash += pos * fpx - fee
        pnl = pos * (fpx - entry_px) - fee - entry_cost
        trades.append({
            "entry_time": df.index[entry_i], "exit_time": df.index[i],
            "side": "long" if pos > 0 else "short", "qty": abs(pos),
            "entry": entry_px, "exit": fpx, "pnl": pnl,
            "return_pct": pnl / (abs(pos) * entry_px) * 100,
            "r_multiple": pnl / entry_risk if entry_risk else np.nan,
            "bars_held": i - entry_i, "exit_reason": reason,
        })
        pos = 0.0

    def open_position(i, direction):
        nonlocal cash, pos, entry_px, stop, target, entry_i, entry_cost, entry_risk
        eq = cash
        fpx = fill(o[i], direction)
        a = atr[i - 1] if i > 0 else atr[i]
        if cfg.stop_atr:
            dist = cfg.stop_atr * a
            qty = eq * cfg.risk_per_trade / dist if dist > 0 else 0.0
        else:
            dist, qty = 0.0, eq * cfg.max_leverage / fpx
        qty = min(qty, eq * cfg.max_leverage / fpx)
        if qty <= 0:
            return
        entry_cost = qty * fpx * cfg.commission_pct
        cash -= direction * qty * fpx + entry_cost
        pos, entry_px, entry_i = direction * qty, fpx, i
        # 1R = planned loss at the stop; without a stop, risk_per_trade of the notional
        entry_risk = qty * dist if dist else qty * fpx * cfg.risk_per_trade
        stop = fpx - direction * dist if cfg.stop_atr else 0.0
        target = fpx + direction * cfg.target_atr * a if cfg.target_atr else 0.0

    for i in range(n):
        # 1) act on the previous bar's signal at this bar's open
        if i > 0 and not np.isnan(sig[i - 1]):
            want = int(sig[i - 1])
            if want == -1 and not cfg.allow_short:
                want = 0
            if pos and np.sign(pos) != want:
                close_position(i, o[i], "signal")
            if want and not pos and not (cfg.flatten_eod and last_of_day[i]):
                open_position(i, want)

        # 2) intrabar exits: stop first (conservative), then target
        if pos:
            d = np.sign(pos)
            if cfg.trail_atr:
                trail = (h[i] - cfg.trail_atr * atr[i]) if d > 0 else (l[i] + cfg.trail_atr * atr[i])
                stop = max(stop, trail) if d > 0 else (min(stop, trail) if stop else trail)
            hit_stop = stop and ((d > 0 and l[i] <= stop) or (d < 0 and h[i] >= stop))
            hit_tgt = target and ((d > 0 and h[i] >= target) or (d < 0 and l[i] <= target))
            if hit_stop:
                px = min(o[i], stop) if d > 0 else max(o[i], stop)  # gap through the stop
                close_position(i, px, "stop")
            elif hit_tgt:
                px = max(o[i], target) if d > 0 else min(o[i], target)
                close_position(i, px, "target")
            elif cfg.max_hold_bars and i - entry_i >= cfg.max_hold_bars:
                close_position(i, c[i], "time")
            elif cfg.flatten_eod and last_of_day[i]:
                close_position(i, c[i], "eod")

        equity[i] = cash + pos * c[i]

    if pos:
        close_position(n - 1, c[-1], "end")
        equity[-1] = cash

    eq = pd.Series(equity, index=df.index, name="equity")
    tr = pd.DataFrame(trades)
    return {
        "config": asdict(cfg),
        "equity": eq,
        "trades": tr,
        "metrics": compute_metrics(eq, tr, df, cfg.initial_capital),
    }
