"""Python replica of SilverBullet_XAU.mq5 (ICT Silver Bullet: liquidity sweep + FVG, limit entry).

EA logic reproduced bar by bar (bar j = new bar, bars 1..3 = j-1..j-3):
  - windows (New York hour of the new bar): London 3h, NY AM 10h, NY PM 14h; pending orders expire at the end of the hour
  - BUY : lowest low of bars 1..10 < lowest low of bars 11..30 (sweep), sweep bar index >= 3,
          bullish FVG low[1] - high[3] >= MinFVG  -> BUY LIMIT at low[1], SL = sweep low - buffer, TP = RR x risk
  - SELL: mirror (bearish FVG low[3] - high[1] >= MinFVG -> SELL LIMIT at high[1], SL = sweep high + buffer)
  - one buy and one sell order per window, one order/position at a time, no time exit (SL or TP only)
  - bid prices in the data, ask = bid + spread: buy limit fills when ask <= entry, buy exits on bid,
    sell limit fills when bid >= entry, sell exits on ask (SL earlier / TP later by the spread)
  - same-bar ambiguity resolved against the trade (SL first; no TP on the fill bar)
usage: python3 sb_backtest.py <data_dir with xau_m1_utc.csv / xau_m5_utc.csv> <out_dir>
"""
import os, sys
import numpy as np
import pandas as pd
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ob_choch"))
import ob_choch as ob   # loader + market-hours filter + stats

WINDOWS = {3: "London", 10: "NY AM", 14: "NY PM"}


def setups(d, sweep_bars=10, liq_bars=20, min_fvg=0.5):
    o, h, l, c = (d[x].values for x in "ohlc")
    t = d.index.values
    ny = d.index.tz_localize("UTC").tz_convert("America/New_York")
    nyh = np.asarray(ny.hour); nyday = np.asarray((ny.year * 1000 + ny.dayofyear))
    n = len(d); K = sweep_bars + liq_bars
    rows = []
    for j in np.flatnonzero(np.isin(nyh, list(WINDOWS))):
        if j < K + 1:
            continue
        lw = l[j - sweep_bars:j]; hw = h[j - sweep_bars:j]          # bars sweep_bars..1 (oldest first)
        pl = l[j - K:j - sweep_bars].min(); ph = h[j - K:j - sweep_bars].max()
        # MQL iLowest returns the most recent bar on ties -> search from the newest bar
        ri = sweep_bars - 1 - int(np.argmin(lw[::-1])); rlow = lw[ri]; r_shift_low = sweep_bars - ri
        hi_ = sweep_bars - 1 - int(np.argmax(hw[::-1])); rhigh = hw[hi_]; r_shift_high = sweep_bars - hi_
        buy = rlow < pl and r_shift_low >= 3 and (l[j - 1] - h[j - 3]) >= min_fvg
        sell = rhigh > ph and r_shift_high >= 3 and (l[j - 3] - h[j - 1]) >= min_fvg
        if buy or sell:
            rows.append((j, buy, sell, rlow, rhigh, nyday[j] * 10 + list(WINDOWS).index(nyh[j]) + 1, WINDOWS[nyh[j]]))
    return rows


def simulate(d, rows, rr, spread=0.35, buf=0.2):
    o, h, l, c = (d[x].values for x in "ohlc"); t = d.index.values; n = len(d)
    hour = np.timedelta64(1, "h")
    busy = np.datetime64("1970-01-01"); last_buy = last_sell = -1
    out = []
    for j, buy, sell, rlow, rhigh, wid, wname in rows:
        if t[j] < busy:
            continue
        side = 0
        if buy and wid != last_buy:
            entry = l[j - 1]; sl = rlow - buf; risk = entry - sl
            if o[j] + spread > entry and risk > 0:
                side = 1; last_buy = wid
        if side == 0 and sell and wid != last_sell:
            entry = h[j - 1]; sl = rhigh + buf; risk = sl - entry
            if o[j] < entry and risk > 0:
                side = -1; last_sell = wid
        if side == 0:
            continue
        tp = entry + side * rr * risk
        t_exp = t[j] - (t[j] - t[j].astype("datetime64[h]")) + hour     # end of the current hour
        k1 = int(np.searchsorted(t, t_exp, "left"))
        seg = slice(j, k1)
        fill = (l[seg] + spread <= entry) if side == 1 else (h[seg] >= entry)
        if not fill.any():
            busy = t_exp
            out.append(dict(placed=t[j], side=side, window=wname, entry=entry, sl=sl, tp=tp, risk=risk, filled=False))
            continue
        kf = j + int(np.argmax(fill))
        px = min(entry, o[kf] + spread) if side == 1 else max(entry, o[kf])    # gap -> better price
        # exits from the fill bar on: SL on the fill bar counts, TP only from the next bar
        if side == 1:
            slm = l[kf:] <= sl; tpm = h[kf:] >= tp
        else:
            slm = h[kf:] + spread >= sl; tpm = l[kf:] + spread <= tp
        tpm[0] = False
        isl = int(np.argmax(slm)) if slm.any() else 10**9
        itp = int(np.argmax(tpm)) if tpm.any() else 10**9
        if isl == itp == 10**9:
            break                                                           # still open at the end of the data
        if isl <= itp:
            k = kf + isl
            ex = (min(sl, o[k]) if side == 1 else max(sl, o[k] + spread)) if k > kf else sl
            why = "SL"
        else:
            k = kf + itp; ex = tp; why = "TP"
        R = side * (ex - px) / risk
        busy = t[k]
        out.append(dict(placed=t[j], side=side, window=wname, entry=entry, sl=sl, tp=tp, risk=risk, filled=True,
                        open=t[kf], close=t[k], fill=px, exit=ex, R=R, why=why, hold_h=(t[k] - t[kf]) / hour))
    return pd.DataFrame(out)


def summary(tr, label):
    f = tr[tr.filled].copy()
    if not len(f):
        return dict(test=label, n=0)
    f["open"] = pd.to_datetime(f["open"])
    s = ob.stats(f.assign(risk=f.risk), risk_pct=(0.5, 1.0))
    s["fill%"] = round(100 * len(f) / len(tr), 0)
    s["hold_h_med"] = round(f.hold_h.median(), 1)
    return dict(test=label, **s)


if __name__ == "__main__":
    data, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    rows = []
    for tf, fname, start in (("M5", "xau_m5_utc.csv", "2025-06-01"), ("M1", "xau_m1_utc.csv", "2025-10-01")):
        d = ob.market_hours(ob.load_utc(os.path.join(data, fname))).loc[start:]
        for digits, fvg, buf in (("2 digits (FTMO)", 0.5, 0.2), ("3 digits (Exness)", 0.05, 0.02)):
            st = setups(d, min_fvg=fvg)
            for rr in (1, 1.5, 2, 3, 4):
                tr = simulate(d, st, rr, spread=0.35, buf=buf)
                if rr == 2:   # EA default
                    tr.to_csv(os.path.join(out, f"sb_trades_{tf}_{digits.split()[0]}d_RR{rr}.csv"), index=False)
                s = summary(tr, f"{tf} | {digits} | RR {rr}")
                f = tr[tr.filled]
                for w in WINDOWS.values():
                    s[f"R_{w}"] = round(f.R[f.window == w].sum(), 1) if len(f) else 0
                s["R_buy"] = round(f.R[f.side == 1].sum(), 1); s["R_sell"] = round(f.R[f.side == -1].sum(), 1)
                rows.append(s)
    rep = pd.DataFrame(rows)
    rep.to_csv(os.path.join(out, "sb_report.csv"), index=False)
    pd.set_option("display.width", 250)
    cols = ["test", "n", "fill%", "win", "PF", "totR", "ddR", "ROI%@0.5", "DD%@0.5", "months+", "hold_h_med",
            "R_London", "R_NY AM", "R_NY PM", "R_buy", "R_sell"]
    print(rep[cols].to_string(index=False))
