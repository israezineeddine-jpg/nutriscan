#!/usr/bin/env python3
"""Agent de sélection de challenges prop firm.

Classe les challenges par facilité, rapidité et retraits (payouts), filtrés par
pays (Maroc par défaut), et simule les chances de passer avec TES statistiques.

Exemples :
  python3 propfirm_agent.py classement
  python3 propfirm_agent.py classement --par retrait --budget 500
  python3 propfirm_agent.py simuler --winrate 0.45 --rr 2 --risque 0.5 --trades-jour 2
"""
import argparse
import json
import random
import statistics
from pathlib import Path

DATA = Path(__file__).parent / "data" / "challenges.json"


def load(country, include_unconfirmed):
    challenges = json.loads(DATA.read_text(encoding="utf-8"))["challenges"]
    allowed = {"oui", "a_confirmer"} if include_unconfirmed else {"oui"}
    out = []
    for c in challenges:
        status = c.get("countries", {}).get(country, {}).get("status", "inconnu")
        if country == "ALL" or status in allowed:
            out.append(c)
    return out


# ---------- Scores déterministes (0-100) ----------

def total_target(c):
    return sum(p["target"] for p in c["phases"])


def ease_score(c):
    """Plus la marge de drawdown est grande par rapport à l'objectif, plus c'est facile."""
    room = c["max_dd"] / total_target(c)            # ex. 10 / 13 = 0.77
    score = min(room, 1.2) / 1.2 * 60
    score += min(c["daily_dd"], 5) / 5 * 25
    score += 15 if c["dd_type"] == "static" else 0  # trailing = plus dur
    if c.get("consistency_rule"):
        score -= 10
    return max(0, round(score))


def min_days_to_payout(c):
    """Nombre minimal de jours avant le premier retrait possible."""
    return sum(max(p["min_days"], 1) for p in c["phases"]) + c["first_payout_days"]


def speed_score(c):
    days = min_days_to_payout(c)
    phases = len(c["phases"])
    return round(max(0, 100 - days * 2.5 - (phases - 1) * 10))


def payout_score(c, monthly_return=4.0):
    """Retrait mensuel estimé si tu fais `monthly_return` % par mois sur le compte funded."""
    per_month = c["size"] * monthly_return / 100 * c["profit_split"] / 100
    freq_bonus = 30 / c["payout_every_days"]         # retraits par mois
    score = c["profit_split"] * 0.6 + min(freq_bonus, 4) * 7 + max(0, 21 - c["first_payout_days"])
    return round(min(score, 100)), round(per_month)


def overall(c):
    p, _ = payout_score(c)
    value = min(40, 20000 / c["price_usd"])          # rapport qualité/prix
    return round(ease_score(c) * 0.35 + speed_score(c) * 0.25 + p * 0.25 + value * 0.375)


# ---------- Simulation Monte Carlo ----------

def simulate_one(c, winrate, rr, risk, trades_per_day, rng, max_days=365):
    """Retourne (jours_jusqu_au_premier_retrait, montant_retrait) ou None si échec."""
    size = c["size"]
    day = 0
    for phase in c["phases"]:
        balance, peak = size, size
        phase_days = 0
        limit = phase["time_limit_days"] or max_days
        while True:
            day += 1
            phase_days += 1
            if phase_days > limit or day > max_days:
                return None
            start = balance
            for _ in range(trades_per_day):
                r = risk / 100 * size
                balance += r * rr if rng.random() < winrate else -r
                peak = max(peak, balance)
                floor = (peak if c["dd_type"] == "trailing" else size) - c["max_dd"] / 100 * size
                if start - balance >= c["daily_dd"] / 100 * size or balance <= floor:
                    return None
                if balance - size >= phase["target"] / 100 * size:
                    break
            if balance - size >= phase["target"] / 100 * size and phase_days >= phase["min_days"]:
                break
    # Compte funded : on trade jusqu'au premier retrait
    balance, peak = size, size
    for _ in range(c["first_payout_days"]):
        day += 1
        start = balance
        for _ in range(trades_per_day):
            r = risk / 100 * size
            balance += r * rr if rng.random() < winrate else -r
            peak = max(peak, balance)
            floor = (peak if c["dd_type"] == "trailing" else size) - c["max_dd"] / 100 * size
            if start - balance >= c["daily_dd"] / 100 * size or balance <= floor:
                return None
    profit = max(0.0, balance - size)
    payout = profit * c["profit_split"] / 100
    if c.get("fee_refund") and payout > 0:
        payout += c["price_usd"]
    return day, payout


def simulate(c, winrate, rr, risk, trades_per_day, runs, seed):
    rng = random.Random(seed)
    results = [simulate_one(c, winrate, rr, risk, trades_per_day, rng) for _ in range(runs)]
    ok = [r for r in results if r and r[1] > 0]
    p = len(ok) / runs
    mean_payout = statistics.mean(r[1] for r in ok) if ok else 0
    median_days = statistics.median(r[0] for r in ok) if ok else None
    ev = p * mean_payout - c["price_usd"]
    return {"p_payout": p, "mean_payout": mean_payout, "median_days": median_days, "ev": ev}


# ---------- Affichage ----------

def label(c):
    return f"{c['firm']} – {c['program']}"


def flag(c, country):
    s = c.get("countries", {}).get(country, {}).get("status")
    return " (pays à confirmer)" if s == "a_confirmer" else ""


def cmd_ranking(args):
    items = [c for c in load(args.pays, args.inclure_a_confirmer) if c["price_usd"] <= args.budget]
    if not items:
        print("Aucun challenge ne correspond à ces filtres.")
        return
    keys = {
        "global": overall,
        "facile": ease_score,
        "rapide": speed_score,
        "retrait": lambda c: payout_score(c, args.rendement)[0],
    }
    items.sort(key=keys[args.par], reverse=True)
    print(f"\nClassement '{args.par}' — pays : {args.pays} — budget ≤ ${args.budget}\n")
    print(f"{'#':<3}{'Challenge':<38}{'Prix':>6}{'Facile':>8}{'Rapide':>8}{'Retrait':>9}"
          f"{'Global':>8}{'J→1er $':>9}{'$/mois*':>9}")
    for i, c in enumerate(items, 1):
        p, per_month = payout_score(c, args.rendement)
        print(f"{i:<3}{label(c)[:37]:<38}{c['price_usd']:>6}{ease_score(c):>8}{speed_score(c):>8}"
              f"{p:>9}{overall(c):>8}{min_days_to_payout(c):>9}{per_month:>9}{flag(c, args.pays)}")
    print(f"\n* $/mois = retrait estimé si tu fais {args.rendement}% par mois sur le compte funded.")
    best = items[0]
    print(f"\n👉 Recommandation ({args.par}) : {label(best)}")
    print(f"   Objectifs : {' + '.join(str(p['target']) + '%' for p in best['phases'])} | "
          f"DD jour {best['daily_dd']}% | DD max {best['max_dd']}% ({best['dd_type']}) | "
          f"split {best['profit_split']}% | 1er retrait après {best['first_payout_days']} j")
    note = best.get("countries", {}).get(args.pays, {}).get("note")
    if note:
        print(f"   Pays : {note}")
    print(f"   Source : {best['source']} (données : {best['last_checked']}, à revérifier)")


def cmd_simulate(args):
    items = [c for c in load(args.pays, args.inclure_a_confirmer) if c["price_usd"] <= args.budget]
    rows = [(c, simulate(c, args.winrate, args.rr, args.risque, args.trades_jour, args.runs, args.seed))
            for c in items]
    rows.sort(key=lambda r: r[1]["ev"], reverse=True)
    print(f"\nSimulation {args.runs}x — winrate {args.winrate:.0%}, R:R {args.rr}, "
          f"risque {args.risque}%/trade, {args.trades_jour} trades/jour\n")
    print(f"{'Challenge':<38}{'Prix':>6}{'P(retrait)':>12}{'Jours méd.':>12}{'Retrait moy.':>14}{'Gain espéré':>13}")
    for c, r in rows:
        days = f"{r['median_days']:.0f}" if r["median_days"] else "-"
        print(f"{label(c)[:37]:<38}{c['price_usd']:>6}{r['p_payout']:>11.0%} {days:>11}"
              f"{r['mean_payout']:>13.0f}${r['ev']:>12.0f}${flag(c, args.pays)}")
    print("\nP(retrait) = probabilité de passer le challenge ET de toucher un 1er retrait.")
    print("Gain espéré = P(retrait) × retrait moyen − prix du challenge. Négatif = tu perds de l'argent en moyenne.")
    if rows and rows[0][1]["ev"] <= 0:
        print("⚠️  Avec ces stats, aucun challenge n'est rentable en moyenne : réduis le risque par trade "
              "ou améliore ta stratégie avant d'acheter.")


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--pays", default="MA", help="code pays ISO (MA = Maroc) ou ALL")
    common.add_argument("--inclure-a-confirmer", action="store_true",
                        help="inclure les firms dont l'acceptation du pays n'est pas confirmée")
    common.add_argument("--budget", type=float, default=10_000, help="prix max du challenge en $")
    ap = argparse.ArgumentParser(description="Agent prop firm : meilleurs challenges (Maroc par défaut)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("classement", parents=[common], help="classer les challenges")
    r.add_argument("--par", choices=["global", "facile", "rapide", "retrait"], default="global")
    r.add_argument("--rendement", type=float, default=4.0, help="%% de gain mensuel visé en funded")
    r.set_defaults(func=cmd_ranking)

    s = sub.add_parser("simuler", parents=[common], help="simuler tes chances avec tes stats")
    s.add_argument("--winrate", type=float, required=True, help="ex. 0.45")
    s.add_argument("--rr", type=float, required=True, help="ratio gain/perte moyen, ex. 2")
    s.add_argument("--risque", type=float, default=0.5, help="%% du capital risqué par trade")
    s.add_argument("--trades-jour", type=int, default=2)
    s.add_argument("--runs", type=int, default=5000)
    s.add_argument("--seed", type=int, default=42)
    s.set_defaults(func=cmd_simulate)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
