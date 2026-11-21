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

## Expert Advisor OB_CHoCH_M1.mq5

`mql_trade_shim.h` ajoute l'API de trading (CTrade, positions, deals, fichiers). `harness_ea.cpp` joue 4 ticks par
bougie M1 : ouverture, extrême défavorable à la position ouverte (le SL passe avant le TP, comme dans le backtest
Python), extrême favorable, clôture. Les SL et TP sont exécutés au niveau exact.

    python3 mql2cpp_ea.py ../ob_choch/OB_CHoCH_M1.mq5 ea_gen.cpp
    g++ -std=c++17 -O2 -o harness_ea harness_ea.cpp
    python3 ea_parity.py <dossier avec xau_m1_utc.csv> <dossier de travail> 0      # comparaison trade par trade avec ob_choch.py
    ./harness_ea <dossier de travail> 0 260000            # EA lancé à la bougie 260000 (démarrage à chaud)
    ./harness_ea <dossier de travail> 0 0 fixed0          # horloge Exness (UTC+0, fichiers m1_utc.csv / m30_utc.csv)
