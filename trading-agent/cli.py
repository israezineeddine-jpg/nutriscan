"""Run backtests directly, without the AI agent.

    python cli.py list
    python cli.py run sma_crossover --source SPY --interval 1d --period 5y
    python cli.py run ema_vwap_scalp --source synthetic --interval 1m --bars 5000
    python cli.py compare --style day --source QQQ --interval 5m --period 60d
    python cli.py optimize rsi2_pullback --source SPY --period 10y --walk-forward
"""
from __future__ import annotations

import argparse
import json

from backtester import STRATEGIES, load_data
from backtester.optimize import backtest_strategy, grid_search, monte_carlo, walk_forward

KEYS = ("total_return_pct", "cagr_pct", "buy_and_hold_pct", "max_drawdown_pct", "sharpe",
        "win_rate_pct", "profit_factor", "trades")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["list", "run", "compare", "optimize"])
    ap.add_argument("strategy", nargs="?")
    ap.add_argument("--source", default="synthetic")
    ap.add_argument("--interval", default="1d")
    ap.add_argument("--period", default="2y")
    ap.add_argument("--bars", type=int, default=2000)
    ap.add_argument("--style", choices=["scalp", "day", "swing"])
    ap.add_argument("--params", type=json.loads, default=None, help='JSON, e.g. \'{"fast": 10}\'')
    ap.add_argument("--config", type=json.loads, default=None, help='JSON engine overrides')
    ap.add_argument("--objective", default="sharpe")
    ap.add_argument("--walk-forward", action="store_true")
    a = ap.parse_args()

    if a.command == "list":
        for s in STRATEGIES.values():
            print(f"{s.style:6} {s.name:24} {s.description}")
        return
    df = load_data(a.source, a.interval, a.period, a.bars)
    print(f"{a.source} {a.interval}: {len(df)} bars {df.index[0]} -> {df.index[-1]}\n")

    if a.command == "run":
        res = backtest_strategy(df, a.strategy, a.params, a.config)
        print(json.dumps(res["metrics"], indent=1, default=str))
        print("\nMonte Carlo:", json.dumps(monte_carlo(res["trades"], res["config"]["initial_capital"])))
    elif a.command == "compare":
        names = [n for n, s in STRATEGIES.items() if not a.style or s.style == a.style]
        print(f"{'strategy':24}" + "".join(f"{k[:12]:>13}" for k in KEYS))
        for n in names:
            m = backtest_strategy(df, n, None, a.config)["metrics"]
            print(f"{n:24}" + "".join(f"{str(m.get(k, '-')):>13}" for k in KEYS))
    elif a.command == "optimize":
        for r in grid_search(df, a.strategy, None, a.config, a.objective):
            print(r["params"], {k: r["metrics"].get(k) for k in KEYS})
        if a.walk_forward:
            print(json.dumps(walk_forward(df, a.strategy, None, a.config, a.objective), indent=1, default=str))


if __name__ == "__main__":
    main()
