"""Lightweight bar-by-bar backtester for scalping, day trading and swing trading."""
from .data import load_data, synthetic_data
from .engine import BacktestConfig, run_backtest
from .strategies import STRATEGIES, get_strategy

__all__ = ["load_data", "synthetic_data", "BacktestConfig", "run_backtest", "STRATEGIES", "get_strategy"]
