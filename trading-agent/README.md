# AI Backtesting Agent — Scalping, Day Trading, Swing Trading

A Python backtesting engine plus a Claude-powered research agent that loads market data,
runs strategies, tunes parameters, checks for overfitting (walk-forward + Monte Carlo) and
writes up the results.

## Setup

```bash
cd trading-agent
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...   # only needed for the AI agent
```

## Use the AI agent

```bash
python agent.py                                   # interactive chat
python agent.py "Find the best swing strategy for SPY over 10 years of daily data and check it out-of-sample"
python agent.py "Compare scalping strategies on BTC-USD 1m data with 0.1% commission"
python agent.py "Build a custom day-trading rule: buy above VWAP when RSI(14) < 35, test on QQQ 5m"
```

The agent's tools:

| Tool | What it does |
|---|---|
| `list_strategies` | Built-in strategies per style, defaults and tuning grids |
| `load_market_data` | Yahoo Finance ticker, CSV file, or `synthetic` random-walk data |
| `run_backtest` | One backtest → metrics + recent trades |
| `compare_strategies` | Rank several strategies on the same data |
| `optimize_strategy` | Parameter grid search (in-sample) |
| `walk_forward_test` | Optimise on train windows, test on unseen windows |
| `monte_carlo_test` | Resample trades → return / drawdown distribution |
| `save_report` | Write `trades.csv`, `equity.csv`, `summary.json` to `reports/` |

It uses `claude-opus-5` by default (set `BACKTEST_AGENT_MODEL` to change it), with adaptive
thinking and the API's refusal fallback enabled.

## Or run backtests directly (no API key needed)

```bash
python cli.py list
python cli.py run sma_crossover --source SPY --interval 1d --period 5y
python cli.py compare --style scalp --source synthetic --interval 1m --bars 5000
python cli.py optimize rsi2_pullback --source SPY --period 10y --walk-forward
python cli.py run custom --params '{"long_entry": "close > ema_200 and rsi_2 < 10", "exit_rule": "close > sma_5"}'
```

## Gold futures (GC / MGC), 5-minute bars

`gold_gc.py` compares the intraday strategies on COMEX gold with whole-contract sizing,
per-contract commission, 1-tick slippage and a 1:1 reward:risk by default.

```bash
python gold_gc.py --csv data/GC_5m.csv                 # MGC, $10,000, 1% risk, 1:1
python gold_gc.py --csv data/GC_5m.csv --contract GC   # full contract ($100 per $1 move)
python gold_gc.py --csv data/GC_5m.csv --rr 2 --stop-atr 2
python gold_gc.py --synthetic                          # pipeline check only, no real data
```

The CSV needs a time column (ISO dates in New York time, or unix timestamps as in a
TradingView export) plus open, high, low, close, volume. Sessions run 18:00 -> 17:00 ET and
positions are closed at 17:00 ET unless `--hold-overnight` is set. With $10,000 and 1% risk,
one full GC contract is usually too large for an ATR stop on 5m bars, so MGC is the default.

## Strategies

| Style | Strategy | Idea | Default risk engine |
|---|---|---|---|
| scalp | `ema_vwap_scalp` | EMA 9/21 cross on the VWAP side | 1 ATR stop, 1.5 ATR target, 30-bar time stop, flat at close |
| scalp | `rsi_scalp` | Fade RSI(7) extremes, exit at 50 | same |
| scalp | `bollinger_scalp` | Fade band breaks, exit at middle band | same |
| day | `opening_range_breakout` | First break of the opening range | 1.5 ATR stop, 3 ATR target, flat at close |
| day | `vwap_reversion` | Fade N-ATR stretches from VWAP | same |
| day | `macd_momentum` | MACD cross with the EMA trend | same |
| swing | `sma_crossover` | 20/50 SMA trend following | 3 ATR stop, hold overnight |
| swing | `rsi2_pullback` | Buy RSI(2) dips above the 200 SMA | same |
| swing | `donchian_breakout` | Turtle 20/10 channel breakout | same |
| any | `custom` | Your own rules: `close`, `vwap`, `ema_N`, `sma_N`, `rsi_N`, `atr_N`, `prev_*` | engine defaults |

Add your own by writing a function that returns a target-position series (1 long, -1 short,
0 flat, NaN hold) and registering it in `STRATEGIES` in `backtester/strategies.py`.

## Engine

- Signals are computed on bar close and filled at the **next bar's open** (no look-ahead).
- Position size = `risk_per_trade` × equity ÷ stop distance, capped by `max_leverage`.
- ATR stop / target / trailing stop, time stop, end-of-day flattening for intraday styles.
- If stop and target are both touched in one bar, the stop is assumed (conservative);
  gaps through a stop fill at the open.
- Commission and slippage per side.
- Metrics: total return, CAGR, buy & hold, max drawdown, Sharpe, Sortino, Calmar, win rate,
  profit factor, expectancy, average R-multiple, exposure, exit reasons.

## Limitations

- Bar data only: intrabar order of stop/target is unknown, and there is no order book,
  spread or partial fills — scalping results are the least reliable; use conservative costs.
- Yahoo Finance limits intraday history (1m ≈ 7 days, 5m/15m ≈ 60 days). Use a CSV from your
  broker for longer intraday tests.
- Past performance does not predict future results. This is a research tool, not financial advice.

## Tests

```bash
python -m pytest -q tests
```
