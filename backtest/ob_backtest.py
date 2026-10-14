"""Backtest Order Block M30 sur XAUUSD. Usage: python3 ob_backtest.py <csv_m30>"""
import sys, itertools
import numpy as np, pandas as pd

COST = 0.30  # spread+commission en $/oz par trade


def load(p):
    d = pd.read_csv(p, header=None, names=["d", "t", "o", "h", "l", "c", "v"])
    d.index = pd.to_datetime(d.d + " " + d.t, format="%Y.%m.%d %H:%M")
    return d[["o", "h", "l", "c", "v"]]


def prep(d):
    d = d.copy()
    pc = d.c.shift()
    tr = pd.concat([d.h - d.l, (d.h - pc).abs(), (d.l - pc).abs()], axis=1).max(axis=1)
    d["atr"] = tr.rolling(14).mean()
    d["ema"] = d.c.ewm(span=200, adjust=False).mean()
    return d


def find_obs(d, k, piv=3, look=10):
    """Retourne liste (i_signal, dir, ob_low, ob_high)."""
    o, h, l, c, atr = (d[x].values for x in ("o", "h", "l", "c", "atr"))
    n = len(d); obs = []
    sh = sl = None  # dernier swing high/low confirmé (prix, utilisé?)
    sh_used = sl_used = True
    for i in range(piv * 2 + 15, n):
        j = i - piv  # pivot confirmé avec piv barres après
        if h[j] == h[j - piv:j + piv + 1].max():
            sh, sh_used = h[j], False
        if l[j] == l[j - piv:j + piv + 1].min():
            sl, sl_used = l[j], False
        body = abs(c[i] - o[i])
        if body < k * atr[i]:
            continue
        if sh is not None and not sh_used and c[i] > sh and c[i] > o[i]:
            sh_used = True
            for m in range(i - 1, i - look, -1):
                if c[m] < o[m]:
                    obs.append((i, 1, l[m], h[m])); break
        elif sl is not None and not sl_used and c[i] < sl and c[i] < o[i]:
            sl_used = True
            for m in range(i - 1, i - look, -1):
                if c[m] > o[m]:
                    obs.append((i, -1, l[m], h[m])); break
    return obs


def run(d, obs, rr, entry, buf, trend, valid=40, session=None):
    o, h, l, c, atr, ema = (d[x].values for x in ("o", "h", "l", "c", "atr", "ema"))
    hrs = d.index.hour.values
    res = []; busy = -1
    for (i, dr, lo, hi) in obs:
        if trend and ((dr == 1) != (c[i] > ema[i])):
            continue
        px = (lo + hi) / 2 if entry == "mid" else (hi if dr == 1 else lo)
        sl = (lo - buf * atr[i]) if dr == 1 else (hi + buf * atr[i])
        risk = abs(px - sl)
        if risk <= 0.2:
            continue
        tp = px + dr * rr * risk
        j = i + 1; filled = False
        while j < min(i + 1 + valid, len(d)):
            if j <= busy:
                j += 1; continue
            if not filled:
                if (dr == 1 and c[j] < lo) or (dr == -1 and c[j] > hi):
                    break  # OB invalidé
                if session and hrs[j] not in session:
                    j += 1; continue
                if (dr == 1 and l[j] <= px) or (dr == -1 and h[j] >= px):
                    filled = True
                    # même bougie : SL d'abord si touché (conservateur)
                    if (dr == 1 and l[j] <= sl) or (dr == -1 and h[j] >= sl):
                        res.append((d.index[j], -1 - COST / risk)); busy = j; break
                else:
                    j += 1; continue
                j += 1; continue
            hit_sl = (dr == 1 and l[j] <= sl) or (dr == -1 and h[j] >= sl)
            hit_tp = (dr == 1 and h[j] >= tp) or (dr == -1 and l[j] <= tp)
            if hit_sl:
                res.append((d.index[j], -1 - COST / risk)); busy = j; break
            if hit_tp:
                res.append((d.index[j], rr - COST / risk)); busy = j; break
            j += 1
    return pd.DataFrame(res, columns=["t", "R"])


def stats(r):
    if len(r) == 0:
        return dict(n=0, wr=np.nan, pf=np.nan, exp=np.nan, tot=0, dd=0)
    w = r.R[r.R > 0].sum(); ls = -r.R[r.R <= 0].sum()
    eq = r.R.cumsum()
    return dict(n=len(r), wr=(r.R > 0).mean() * 100, pf=w / ls if ls else np.inf,
                exp=r.R.mean(), tot=r.R.sum(), dd=(eq.cummax() - eq).max())


if __name__ == "__main__":
    d = prep(load(sys.argv[1]))
    cut = d.index[int(len(d) * 0.6)]
    rows = []
    for k, rr, entry, buf, trend in itertools.product(
            [1.0, 1.5], [1, 1.5, 2, 3], ["mid", "edge"], [0.1, 0.3], [False, True]):
        obs = find_obs(d, k)
        r = run(d, obs, rr, entry, buf, trend)
        a, b = r[r.t < cut], r[r.t >= cut]
        sa, sb = stats(a), stats(b)
        rows.append(dict(k=k, rr=rr, entry=entry, buf=buf, trend=trend,
                         n_tr=sa["n"], wr_tr=sa["wr"], exp_tr=sa["exp"],
                         n_te=sb["n"], wr_te=sb["wr"], pf_te=sb["pf"], exp_te=sb["exp"],
                         tot_te=sb["tot"], dd_te=sb["dd"]))
    R = pd.DataFrame(rows)
    pd.set_option("display.width", 250); pd.set_option("display.max_columns", 30)
    R.round(2).to_csv("results.csv", index=False)
    print("Barres:", len(d), d.index[0], "->", d.index[-1], "| cut:", cut)
    f = lambda x: x.round(2).to_string(index=False)
    print("\n== Top 5 Winrate (train, n>=40)"); print(f(R[R.n_tr >= 40].nlargest(5, "wr_tr")))
    print("\n== Top 5 Expectancy (train, n>=40)"); print(f(R[R.n_tr >= 40].nlargest(5, "exp_tr")))
    print("\n== Top 5 RR>=2 par Expectancy (train)"); print(f(R[(R.n_tr >= 40) & (R.rr >= 2)].nlargest(5, "exp_tr")))
