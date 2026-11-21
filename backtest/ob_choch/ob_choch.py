"""Backtest: HTF Order Block (M30, definition of the user's OB30 EA) + LTF CHoCH entry (M1 or M5).

Rules (long side; short side is the mirror):
  1. Zone = OB30 M30 order block: last bearish candle p, next candle bullish, one of the next 3 closes breaks the
     highest high of the 10 candles p-9..p. Zone = [low_p, high_p]. Active from the close of candle p+3,
     valid 50 calendar hours, invalid as soon as an LTF candle CLOSES below the zone low.
  2. Tap: an LTF candle trades into the zone (low <= zone high). While the zone is being visited we track the lowest
     low since the first touch (the "sweep" low). The visit ends if price stays away more than W LTF candles.
  3. CHoCH: an LTF candle CLOSES above the last confirmed swing high (fractal of N candles each side) that is the top
     of the leg down to the sweep low (no higher high between it and the sweep), formed after (visit start - LB).
     -> MARKET entry at the open of the next LTF candle.
  4. SL: 'swing' = sweep low - buffer, or 'zone' = zone low - buffer. TP = entry + RR x risk.
     Risk must be within [min_risk, max_risk]. One trade at a time, max hold 24 h, close before the weekend,
     no entry Friday after 18:00 UTC.
  Costs: spread is charged once per trade (R_net = R - spread / risk).
"""
import numpy as np
import pandas as pd
from numpy.lib.stride_tricks import sliding_window_view


def load_utc(path):
    d = pd.read_csv(path, parse_dates=["datetime"]).set_index("datetime")
    return d[["o", "h", "l", "c"]].astype(float)


def market_hours(d):
    """Keep gold trading hours: Sun 18:00 -> Fri 17:00 New York, without the daily 17:00-18:00 NY break."""
    ny = d.index.tz_localize("UTC").tz_convert("America/New_York")
    dow, hr = ny.dayofweek, ny.hour
    keep = hr != 17
    keep &= ~((dow == 4) & (hr >= 17))
    keep &= dow != 5
    keep &= ~((dow == 6) & (hr < 18))
    x = d[np.asarray(keep)]
    flat = (x.h == x.l) & (x.o == x.c)
    return x[~flat.values]


def resample(d, rule):
    r = d.resample(rule, label="left", closed="left").agg({"o": "first", "h": "max", "l": "min", "c": "last"})
    return r.dropna()


def build_zones(m30, gap=3, tf_min=30):
    o, h, l, c = (m30[x].values for x in "ohlc")
    t = m30.index.values
    zones, last_bull, last_bear = [], -10**9, -10**9
    for p in range(9, len(m30) - 3):
        hh = h[p - 9:p + 1].max(); ll = l[p - 9:p + 1].min()
        if c[p] < o[p] and c[p + 1] > o[p + 1]:
            if c[p + 1:p + 4].max() > hh and (p - last_bull) > gap:
                last_bull = p
                zones.append((1, l[p], h[p], t[p + 3] + np.timedelta64(tf_min, "m")))
        elif c[p] > o[p] and c[p + 1] < o[p + 1]:
            if c[p + 1:p + 4].min() < ll and (p - last_bear) > gap:
                last_bear = p
                zones.append((-1, l[p], h[p], t[p + 3] + np.timedelta64(tf_min, "m")))
    return zones


def pivots(h, l, N):
    n = len(h)
    ph = np.zeros(n, bool); pl = np.zeros(n, bool)
    if n > 2 * N:
        hw = sliding_window_view(h, 2 * N + 1); lw = sliding_window_view(l, 2 * N + 1)
        ph[N:n - N] = hw.argmax(1) == N
        pl[N:n - N] = lw.argmin(1) == N
    return np.flatnonzero(ph), np.flatnonzero(pl)


def ref_high(ph_idx, h, lim, ext_i, kmin):
    """Last confirmed swing high (index <= lim, >= kmin) that is the top of the leg down to the sweep low ext_i."""
    kp = int(np.searchsorted(ph_idx, lim, "right")) - 1
    while kp >= 0 and ph_idx[kp] >= kmin:
        k = ph_idx[kp]
        if h[k] >= h[k:ext_i + 1].max():
            return k
        kp -= 1
    return -1


def ref_low(pl_idx, l, lim, ext_i, kmin):
    kp = int(np.searchsorted(pl_idx, lim, "right")) - 1
    while kp >= 0 and pl_idx[kp] >= kmin:
        k = pl_idx[kp]
        if l[k] <= l[k:ext_i + 1].min():
            return k
        kp -= 1
    return -1


def find_entries(zones, ltf, N, W, LB=None, life_h=50):
    """One candidate per zone: the first CHoCH after a tap. Returns a list of dicts (index in ltf arrays)."""
    LB = 2 * W if LB is None else LB
    t = ltf.index.values; o, h, l, c = (ltf[x].values for x in "ohlc")
    n = len(t)
    ph_idx, pl_idx = pivots(h, l, N)
    life = np.timedelta64(life_h, "h")
    out = []
    for zi, (d, zlo, zhi, act) in enumerate(zones):
        j0 = int(np.searchsorted(t, act, "left")); j1 = int(np.searchsorted(t, act + life, "right"))
        armed = False; vstart = last_touch = ext_i = -1; ext_v = 0.0
        for j in range(j0, min(j1, n - 1)):
            if d == 1:
                if c[j] < zlo: break
                if l[j] <= zhi:
                    if not armed: armed = True; vstart = j; ext_v = l[j]; ext_i = j
                    last_touch = j
                if not armed: continue
                if l[j] < ext_v: ext_v = l[j]; ext_i = j
                if j - last_touch > W: armed = False; continue
                if j <= ext_i: continue
                k = ref_high(ph_idx, h, min(ext_i - 1, j - N), ext_i, vstart - LB)
                if k >= 0 and c[j] > h[k]:
                    out.append(dict(zone=zi, dir=1, sig=j, ent=j + 1, sweep=ext_v, zlo=zlo, zhi=zhi, ref=h[k])); break
            else:
                if c[j] > zhi: break
                if h[j] >= zlo:
                    if not armed: armed = True; vstart = j; ext_v = h[j]; ext_i = j
                    last_touch = j
                if not armed: continue
                if h[j] > ext_v: ext_v = h[j]; ext_i = j
                if j - last_touch > W: armed = False; continue
                if j <= ext_i: continue
                k = ref_low(pl_idx, l, min(ext_i - 1, j - N), ext_i, vstart - LB)
                if k >= 0 and c[j] < l[k]:
                    out.append(dict(zone=zi, dir=-1, sig=j, ent=j + 1, sweep=ext_v, zlo=zlo, zhi=zhi, ref=l[k])); break
    return out


class Exec:
    """Arrays used to simulate exits (M1 when available)."""
    def __init__(self, d):
        self.t = d.index.values; self.o, self.h, self.l, self.c = (d[x].values for x in "ohlc")
        ny = d.index.tz_localize("UTC").tz_convert("America/New_York")
        # bars at/after Friday 16:30 New York: close everything before the weekend
        self.fri_close = np.asarray((ny.dayofweek == 4) & ((ny.hour * 60 + ny.minute) >= 16 * 60 + 30))
        self.step = np.timedelta64(int(np.median(np.diff(self.t[:1000]).astype("timedelta64[s]").astype(int))), "s")


def simulate(cands, ltf, ex, sl_mode, buf, rr_list, spread=0.35, min_risk=1.0, max_risk=20.0,
             session=None, hold_h=24):
    """Returns, for each RR, a DataFrame of trades taken (one trade at a time)."""
    t_ltf = ltf.index.values
    rows = []
    for cd in cands:
        te = t_ltf[cd["ent"]]
        hr = pd.Timestamp(te).hour; dow = pd.Timestamp(te).dayofweek
        if dow == 4 and hr >= 18: continue
        if session is not None and not (session[0] <= hr < session[1]): continue
        if te < ex.t[0]: continue
        e0 = int(np.searchsorted(ex.t, te, "left"))
        if e0 >= len(ex.t) - 2: continue
        entry = ex.o[e0]; d = cd["dir"]
        if d == 1:
            sl = (cd["sweep"] if sl_mode == "swing" else cd["zlo"]) - buf
            risk = entry - sl
        else:
            sl = (cd["sweep"] if sl_mode == "swing" else cd["zhi"]) + buf
            risk = sl - entry
        if not (min_risk <= risk <= max_risk): continue
        e1 = int(np.searchsorted(ex.t, te + np.timedelta64(hold_h, "h"), "left"))
        fc = np.flatnonzero(ex.fri_close[e0 + 1:e1])
        if len(fc): e1 = e0 + 1 + fc[0]
        e1 = min(e1, len(ex.t) - 1)
        lo = ex.l[e0:e1]; hi = ex.h[e0:e1]
        if d == 1:
            slm = lo <= sl
        else:
            slm = hi >= sl
        sl_i = int(np.argmax(slm)) if slm.any() else 10**9
        res = {}
        for rr in rr_list:
            tp = entry + d * rr * risk
            tpm = (hi >= tp) if d == 1 else (lo <= tp)
            tp_i = int(np.argmax(tpm)) if tpm.any() else 10**9
            if sl_i == 10**9 and tp_i == 10**9:
                xi = e1; px = ex.o[e1] if e1 < len(ex.o) else ex.c[-1]; why = "time"
                R = d * (px - entry) / risk
            elif sl_i <= tp_i:
                xi = e0 + sl_i; R = -1.0; why = "SL"
            else:
                xi = e0 + tp_i; R = rr; why = "TP"
            res[rr] = (ex.t[min(xi, len(ex.t) - 1)], R - spread / risk, why)
        rows.append((te, d, entry, sl, risk, res, cd["zone"]))
    out = {}
    for rr in rr_list:
        taken = []; busy = np.datetime64("1970-01-01")
        for te, d, entry, sl, risk, res, zi in sorted(rows, key=lambda r: r[0]):
            if te < busy: continue
            tx, R, why = res[rr]
            taken.append((te, tx, d, entry, sl, risk, R, why)); busy = tx
        out[rr] = pd.DataFrame(taken, columns=["open", "close", "dir", "entry", "sl", "risk", "R", "why"])
    return out


def stats(df, risk_pct=(0.5, 1.0)):
    if df is None or len(df) == 0:
        return dict(n=0)
    R = df.R.values
    eq = np.cumsum(R); dd = float((np.maximum.accumulate(np.r_[0, eq])[1:] - eq).max())
    gp = R[R > 0].sum(); gl = -R[R <= 0].sum()
    s = dict(n=len(R), win=round(100 * (R > 0).mean(), 1), PF=round(gp / gl, 2) if gl > 0 else 99.0,
             totR=round(R.sum(), 1), avgR=round(R.mean(), 3), ddR=round(dd, 1),
             avg_risk=round(df.risk.mean(), 2))
    for rp in risk_pct:
        e = np.cumprod(1 + rp / 100.0 * R)
        mdd = float((1 - e / np.maximum.accumulate(e)).max())
        s[f"ROI%@{rp}"] = round(100 * (e[-1] - 1), 1)
        s[f"DD%@{rp}"] = round(100 * mdd, 1)
    m = df.groupby(pd.to_datetime(df.open).dt.to_period("M")).R.sum()
    s["months+"] = f"{int((m > 0).sum())}/{len(m)}"
    return s
