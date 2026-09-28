"""AI backtesting agent (Claude + tool use) for scalping, day trading and swing trading.

    export ANTHROPIC_API_KEY=...          # or `ant auth login`
    python agent.py                        # interactive chat
    python agent.py "Backtest scalping strategies on synthetic 1m data and pick the most robust"
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import anthropic
from anthropic import beta_tool

from backtester import STRATEGIES, load_data
from backtester.optimize import OBJECTIVES, backtest_strategy, grid_search, monte_carlo, walk_forward

MODEL = os.environ.get("BACKTEST_AGENT_MODEL", "claude-opus-5")
REPORTS = Path(__file__).parent / "reports"

SYSTEM = """You are a quantitative trading research agent. You design, backtest and stress-test
scalping, day-trading and swing-trading strategies using the tools provided, then report
honestly on what the evidence shows.

How to work:
- Load data first. Match timeframe to style: scalping 1m-5m, day trading 5m-15m (intraday
  data only covers the last ~60 days on Yahoo), swing trading 1h-1d. 'synthetic' data is
  a random walk: useful for checking mechanics, never evidence of an edge - say so.
- Start from library strategies, then tune with optimize_strategy, and always confirm a
  tuned result with walk_forward_test (out-of-sample) and monte_carlo_test before calling
  anything promising. A strategy whose out-of-sample Sharpe collapses is overfit.
- You can invent strategies with strategy="custom" and boolean rules in params.
- Compare against buy-and-hold, and account for trade count: fewer than ~30 trades is
  not statistically meaningful.
- Keep costs realistic (commission_pct and slippage_pct matter most for scalping).

Final answer: a concise report with a results table (return, CAGR, max drawdown, Sharpe,
win rate, profit factor, trades), the chosen parameters, robustness findings, the main
risks, and next experiments. Backtests are not financial advice; state that once."""

_datasets: dict = {}
_results: dict = {}


def _dump(obj) -> str:
    return json.dumps(obj, default=str, indent=1)


def _summary(res: dict, trades: int = 5) -> dict:
    tr = res["trades"]
    last = tr.tail(trades).assign(entry_time=lambda d: d.entry_time.astype(str),
                                  exit_time=lambda d: d.exit_time.astype(str)).round(4)
    return {"metrics": res["metrics"], "last_trades": last.to_dict("records") if len(tr) else []}


@beta_tool
def list_strategies(style: str = "all") -> str:
    """List built-in strategies with their default parameters and optimisation grids.

    Args:
        style: "scalp", "day", "swing" or "all".
    """
    out = [{"name": s.name, "style": s.style, "description": s.description, "defaults": s.defaults,
            "grid": s.grid, "engine_defaults": s.engine}
           for s in STRATEGIES.values() if style in ("all", s.style)]
    out.append({"name": "custom", "style": "any",
                "description": "Rule-based strategy. params: long_entry, short_entry, exit_rule as boolean "
                               "expressions over open, high, low, close, volume, vwap, ema_N, sma_N, rsi_N, "
                               "atr_N and prev_<name>; use 'and'/'or'. Example: long_entry='close > ema_200 "
                               "and rsi_2 < 10', exit_rule='close > sma_5'."})
    return _dump(out)


@beta_tool
def load_market_data(source: str, interval: str = "1d", period: str = "2y", bars: int = 2000) -> str:
    """Load OHLCV data and return a dataset_id for the other tools.

    Args:
        source: Ticker for Yahoo Finance (e.g. AAPL, SPY, BTC-USD, EURUSD=X, GC=F), a path to a CSV file, or "synthetic".
        interval: Bar size: 1m, 2m, 5m, 15m, 30m, 1h, 1d, 1wk.
        period: History to download, e.g. 5d, 60d, 1y, 5y, max (Yahoo limits: 1m≈7d, intraday≈60d).
        bars: Number of bars when source is "synthetic".
    """
    df = load_data(source, interval=interval, period=period, bars=bars)
    ds_id = f"{source}_{interval}_{len(_datasets) + 1}"
    _datasets[ds_id] = df
    return _dump({"dataset_id": ds_id, "bars": len(df), "start": df.index[0], "end": df.index[-1],
                  "first_close": round(df.close.iloc[0], 4), "last_close": round(df.close.iloc[-1], 4)})


def _df(dataset_id: str):
    if dataset_id not in _datasets:
        raise KeyError(f"unknown dataset_id {dataset_id!r}; loaded: {list(_datasets)}")
    return _datasets[dataset_id]


@beta_tool
def run_backtest(dataset_id: str, strategy: str, params: dict | None = None, config: dict | None = None) -> str:
    """Backtest one strategy and return metrics plus a result_id.

    Args:
        dataset_id: From load_market_data.
        strategy: Strategy name from list_strategies, or "custom".
        params: Strategy parameters overriding the defaults (for custom: long_entry/short_entry/exit_rule).
        config: Engine overrides: initial_capital, risk_per_trade, max_leverage, commission_pct, slippage_pct, atr_period, stop_atr, target_atr, trail_atr, max_hold_bars, flatten_eod, allow_short.
    """
    res = backtest_strategy(_df(dataset_id), strategy, params, config)
    rid = f"r{len(_results) + 1}"
    _results[rid] = {**res, "dataset_id": dataset_id, "strategy": strategy, "params": params or {}}
    return _dump({"result_id": rid, "engine_config": res["config"], **_summary(res)})


@beta_tool
def compare_strategies(dataset_id: str, strategies: list[str], config: dict | None = None) -> str:
    """Backtest several strategies with default parameters on the same data and rank them by Sharpe.

    Args:
        dataset_id: From load_market_data.
        strategies: Strategy names to compare.
        config: Engine overrides applied to every strategy.
    """
    rows = []
    for name in strategies:
        m = backtest_strategy(_df(dataset_id), name, None, config)["metrics"]
        rows.append({"strategy": name, **{k: m.get(k) for k in (
            "total_return_pct", "cagr_pct", "max_drawdown_pct", "sharpe", "win_rate_pct",
            "profit_factor", "trades", "buy_and_hold_pct")}})
    return _dump(sorted(rows, key=lambda r: r["sharpe"], reverse=True))


@beta_tool
def optimize_strategy(dataset_id: str, strategy: str, grid: dict | None = None, config: dict | None = None,
                      objective: str = "sharpe", min_trades: int = 20) -> str:
    """Grid-search strategy parameters (in-sample only - confirm with walk_forward_test).

    Args:
        dataset_id: From load_market_data.
        strategy: Library strategy name.
        grid: Mapping of parameter -> list of values; defaults to the strategy's grid.
        config: Engine overrides.
        objective: One of sharpe, sortino, calmar, total_return_pct, profit_factor, expectancy_per_trade.
        min_trades: Discard combinations with fewer trades.
    """
    if objective not in OBJECTIVES:
        raise ValueError(f"objective must be one of {OBJECTIVES}")
    top = grid_search(_df(dataset_id), strategy, grid, config, objective, min_trades, top=5)
    return _dump([{"params": r["params"], "score": r["score"],
                   **{k: r["metrics"].get(k) for k in ("total_return_pct", "max_drawdown_pct", "sharpe",
                                                       "win_rate_pct", "profit_factor", "trades")}}
                  for r in top])


@beta_tool
def walk_forward_test(dataset_id: str, strategy: str, grid: dict | None = None, config: dict | None = None,
                      objective: str = "sharpe", folds: int = 4) -> str:
    """Walk-forward analysis: optimise on each training window, then test on the following unseen window.

    Args:
        dataset_id: From load_market_data.
        strategy: Library strategy name.
        grid: Parameter grid; defaults to the strategy's grid.
        config: Engine overrides.
        objective: Optimisation objective (see optimize_strategy).
        folds: Number of rolling train/test windows.
    """
    return _dump(walk_forward(_df(dataset_id), strategy, grid, config, objective, folds))


@beta_tool
def monte_carlo_test(result_id: str, runs: int = 1000) -> str:
    """Resample a backtest's trades to estimate the distribution of returns and worst-case drawdowns.

    Args:
        result_id: From run_backtest.
        runs: Number of simulations.
    """
    res = _results[result_id]
    return _dump(monte_carlo(res["trades"], res["config"]["initial_capital"], runs))


@beta_tool
def save_report(result_id: str) -> str:
    """Save a backtest's trade list, equity curve and metrics to the reports/ folder.

    Args:
        result_id: From run_backtest.
    """
    res = _results[result_id]
    out = REPORTS / f"{result_id}_{res['strategy']}"
    out.mkdir(parents=True, exist_ok=True)
    res["trades"].to_csv(out / "trades.csv", index=False)
    res["equity"].to_csv(out / "equity.csv")
    (out / "summary.json").write_text(_dump({k: res[k] for k in ("dataset_id", "strategy", "params",
                                                                 "config", "metrics")}))
    return f"saved to {out}"


TOOLS = [list_strategies, load_market_data, run_backtest, compare_strategies, optimize_strategy,
         walk_forward_test, monte_carlo_test, save_report]


def ask(client: anthropic.Anthropic, messages: list) -> None:
    """Run the agent loop for the latest user message; appends everything to `messages`."""
    runner = client.beta.messages.tool_runner(
        model=MODEL,
        max_tokens=16000,
        system=SYSTEM,
        tools=TOOLS,
        messages=messages,
        thinking={"type": "adaptive"},
        output_config={"effort": "high"},
        # on a safety decline, the API retries the same request on a fallback model
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
    )
    for message in runner:
        messages.append({"role": "assistant", "content": message.content})
        for block in message.content:
            if block.type == "text" and block.text.strip():
                print(block.text)
            elif block.type == "tool_use":
                print(f"  -> {block.name}({json.dumps(block.input)[:160]})", file=sys.stderr)
        if message.stop_reason == "refusal":
            print("[the model declined this request]", file=sys.stderr)
        tool_response = runner.generate_tool_call_response()
        if tool_response is not None:
            messages.append(tool_response)


def main() -> None:
    client = anthropic.Anthropic()
    messages: list = []
    prompt = " ".join(sys.argv[1:])
    try:
        while True:
            if not prompt:
                prompt = input("\nyou> ").strip()
                if prompt.lower() in {"exit", "quit", "q"}:
                    break
                if not prompt:
                    continue
            messages.append({"role": "user", "content": prompt})
            try:
                ask(client, messages)
            except anthropic.AuthenticationError:
                sys.exit("Authentication failed: set ANTHROPIC_API_KEY or run `ant auth login`.")
            except anthropic.RateLimitError:
                print("Rate limited - wait a moment and try again.", file=sys.stderr)
            except anthropic.APIStatusError as e:
                print(f"API error {e.status_code}: {e.message}", file=sys.stderr)
            except anthropic.APIConnectionError:
                print("Could not reach the Claude API - check your network.", file=sys.stderr)
            if len(sys.argv) > 1:
                break
            prompt = ""
    except (KeyboardInterrupt, EOFError):
        pass


if __name__ == "__main__":
    main()
