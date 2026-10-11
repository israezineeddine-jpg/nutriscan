"""Rejoue les 47 entrees du rapport MT4 (EA OB30 avec SMT) avec un modele d'execution Python,
pour tester la sensibilite au spread. Les entrees (heure, sens) viennent du rapport."""
import glob, sys
import numpy as np, pandas as pd
sys.path.insert(0, '/home/user/nutriscan/backtest')
import backtest_ob30 as b

REP = """2026.03.27 14:10 sell
2026.04.06 12:30 buy
2026.04.08 18:05 buy
2026.04.10 10:30 sell
2026.04.10 16:10 buy
2026.04.13 09:15 buy
2026.04.14 05:45 buy
2026.04.15 00:05 buy
2026.04.15 03:10 buy
2026.04.16 12:05 sell
2026.04.22 08:40 buy
2026.04.22 16:25 buy
2026.04.24 08:25 sell
2026.05.01 01:15 buy
2026.05.05 11:40 sell
2026.05.08 07:30 buy
2026.05.22 10:15 sell
2026.05.26 10:55 sell
2026.05.27 22:05 sell
2026.06.01 11:25 sell
2026.06.02 05:20 sell
2026.06.02 22:05 sell
2026.06.04 23:05 buy
2026.06.17 09:35 sell
2026.06.22 22:35 sell
2026.06.23 14:15 sell
2026.06.25 16:05 sell
2026.07.06 17:30 sell
2026.07.08 07:10 buy
2026.07.10 16:35 sell
2026.07.14 09:05 buy
2026.07.17 00:05 sell
2026.07.23 02:10 buy
2026.07.28 16:00 sell
2026.07.28 19:00 buy
2026.08.11 18:15 buy
2026.08.13 23:35 sell
2026.08.20 01:10 buy
2026.08.24 08:35 buy
2026.09.01 01:35 buy
2026.09.16 00:15 buy
2026.09.24 13:05 sell
2026.09.29 03:05 sell
2026.09.29 18:00 buy
2026.09.30 14:05 buy
2026.10.01 14:10 buy
2026.10.05 11:55 buy"""

def replay(m5, spread, rr=2.0, risk_pct=0.5, sl_fix=2.0, hold=288, deposit=10000.0, contract=100.0):
    t5 = m5.index.values; o, h, l, c = (m5[x].values for x in 'ohlc')
    ts = pd.DatetimeIndex(t5); wd, hr, mn = ts.weekday.values, ts.hour.values, ts.minute.values
    bal = deposit; out = []; busy_until = -1
    for line in REP.splitlines():
        d_, t_, side = line.split()
        q = int(np.searchsorted(t5, np.datetime64(pd.Timestamp(d_.replace('.', '-') + ' ' + t_))))
        if q <= busy_until:
            continue
        s = q - 1; d = 1 if side == 'buy' else -1
        sl = l[s] - sl_fix if d == 1 else h[s] + sl_fix
        price = o[q] + spread if d == 1 else o[q]
        risk = abs(price - sl)
        if risk <= 0 or risk > 20: continue
        lots = max(0.01, round(np.floor(bal * risk_pct / 100 / (risk * contract) / 0.01) * 0.01, 2))
        tp = price + d * rr * risk
        ex = None; j = q
        while j < len(t5):
            if j > q:
                timeout = (t5[j] - t5[q]) >= np.timedelta64(hold * 300, 's')
                wk = wd[j] == 4 and hr[j] * 60 + mn[j] >= 20 * 60 + 30
                if timeout or wk:
                    ex = o[j] if d == 1 else o[j] + spread; why = 'timeout/we'; break
            if d == 1:
                if l[j] <= sl: ex, why = min(sl, o[j]), 'SL'; break
                if h[j] >= tp: ex, why = tp, 'TP'; break
            else:
                if h[j] + spread >= sl: ex, why = max(sl, o[j] + spread), 'SL'; break
                if l[j] + spread <= tp: ex, why = tp, 'TP'; break
            j += 1
        if ex is None: continue
        pnl = d * (ex - price) * lots * contract; bal += pnl; busy_until = j
        out.append(dict(open=t5[q], side=d, entry=price, sl=sl, exit=ex, why=why, lots=lots, pnl=pnl, R=d * (ex - price) / risk))
    return pd.DataFrame(out)

if __name__ == '__main__':
    U = glob.glob('/root/.claude/uploads/*/')[0]
    m5 = b.load(glob.glob(U + '*m5.csv')[0])
    for sp in (0.0, 0.26, 0.35, 0.6, 1.0):
        df = replay(m5, sp); print('spread', sp, b.stats(df))
