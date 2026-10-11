# mqlsim - run the MQL5 indicator source on real data (no MetaEditor needed)

`mql2cpp.py` rewrites `OB30_Signals.mq5` into C++ (string literals, arrays, `input`), `mql_shim.h` emulates the MQL5
API used by the indicator (CopyRates, iTime, ObjectCreate..., bounds-checked arrays, poisoned `ArrayResize`) and
`harness.cpp` feeds it gold M5/M30 and silver M5 CSV files (`gold5.csv`, `gold30.csv`, `silver5.csv` in the same folder).

    python3 mql2cpp.py ../OB30_Signals.mq5 ind_gen.cpp
    g++ -std=c++17 -O2 -o harness harness.cpp
    ./harness full .          # whole history -> trades (compare with backtest_ob30.py / the MT4 report)
    ./harness live . 1500     # replay at the first tick of selected M5 bars with HistoryBars=4000
    ./harness warmup .        # history not ready at attach: recovery through OnTimer
    ./harness partial .       # history still downloading
    ./harness options .       # input combinations
    ./harness early .         # steps over the whole history (bounds checks)

Limits: it validates the algorithm and the control flow, not MetaEditor compilation nor real terminal behaviour.
