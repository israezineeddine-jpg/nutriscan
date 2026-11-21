# OB30 zone + entrée CHoCH (M1 ou M5) – XAUUSD

Backtest d'une seule stratégie : zone Order Block M30 (définition de l'EA OB30), entrée sur un CHoCH
en M1 ou en M5. Le but : trouver le meilleur SL / TP / RR et mesurer le ROI.

## Règles (achat ; la vente est le miroir)

1. **Zone OB (M30)**
   - La bougie `p` est baissière et la bougie `p+1` haussière.
   - Une des clôtures de `p+1..p+3` casse le plus haut des 10 bougies `p-9..p`.
   - Zone = `[low_p, high_p]`, active après la clôture de `p+3`, valable 50 h.
   - Annulée si une bougie clôture sous la zone.
2. **Touche** : le prix entre dans la zone. On suit le plus bas atteint depuis la première touche (le *sweep*).
3. **CHoCH** : une bougie (M1 ou M5) clôture au-dessus du dernier swing high (fractal de N bougies de chaque côté).
   - Ce swing est le sommet de la jambe qui a amené le prix au sweep.
   - **Entrée au marché** à l'ouverture de la bougie suivante.
4. **SL** = bas de la zone − buffer. **TP** = entrée + RR × risque.
5. **Gestion**
   - Un seul trade à la fois, durée max 24 h.
   - Vendredi : pas d'entrée après 18:00 UTC, tout est fermé à 16:30 New York.
6. **Coûts** : spread de 0,35 $ par trade (350 points).

## Les deux recettes retenues

| | M1 (recommandée) | M5 |
|---|---|---|
| Swing CHoCH | N = 3 bougies M1 | N = 3 bougies M5 |
| Fin de visite | 15 bougies sans toucher la zone | 6 bougies |
| SL | bord de la zone ± **1,0 $** | bord de la zone ± **0,5 $** |
| TP | **RR 1:4** | **RR 1:3** (1:2,5 proche) |
| Heures | 07–21 UTC (Londres + New York) | toutes |
| Risque moyen | ~11,6 $ | ~13 $ |
| Trades par mois | ~15 | ~12 |

Le SL au-delà de la zone bat le SL sous le sweep, sur M1 comme sur M5.

## Résultats (spread 0,35 $, ROI composé)

| Recette | Période | Trades | Win % | PF | Total R | ROI @1 % | DD max @1 % |
|---|---|---|---|---|---|---|---|
| **M1 RR4** | juin 2025 → nov. 2026 (18 mois) | 261 | 33 | 1,57 | **+99,7** | **+155 %** | 18,6 % |
| M1 RR4 | hors échantillon seulement (juin 2025 → juil. 2026) | 199 | 33 | 1,51 | +67,3 | +88 % | 18,6 % |
| M5 RR3 | juin 2025 → nov. 2026 (18 mois) | 205 | 35 | 1,26 | +35,0 | +38 % | 23,9 % |

À 0,5 % de risque par trade, M1 RR4 fait +62 % sur 18 mois avec un DD max de 9,7 %.

Le résultat dépend beaucoup de la période :

| Période | M1 RR4 | M5 RR3 |
|---|---|---|
| juin → sept. 2025 | −15,7 R | −7,3 R |
| oct. 2025 → janv. 2026 | +6,5 R | +15,4 R |
| févr. → juil. 2026 | **+76,5 R** | +26,2 R |
| août → nov. 2026 (période de choix M1) | +32,4 R | +0,8 R |

Comparaison des RR sur 18 mois (même entrée, même SL) :

| RR | M1 : win % | M1 : ROI @1 % (DD max) | M1 : pire série de pertes | M5 : win % | M5 : ROI @1 % (DD max) |
|---|---|---|---|---|---|
| 1:1 | 52 | +2,5 % (13 %) | 6 | 50 | −10,6 % (19 %) |
| 1:2 | 40 | +28,6 % (19 %) | 7 | 41 | +29,1 % (26 %) |
| 1:3 | 34 | +53,3 % (25 %) | 18 | 35 | +37,7 % (24 %) |
| 1:4 | 33 | **+155 %** (19 %) | 18 | 31 | +26,1 % (25 %) |

- Le RR 1:1 ne paie pas : le win rate reste autour de 50 % et le spread mange le reste.
- Le RR 1:2 gagne, mais peu ; sa pire série de pertes est beaucoup plus courte (7 au lieu de 18).
- Sur M1, le RR 1:4 est le meilleur dans chaque période sauf juin → sept. 2025, où tous les RR perdent.

Tous les chiffres sont dans `results/report.txt`. Les trades sont dans `results/trades_*.csv` et la courbe dans
`results/equity_ob_choch.png`.

## Méthode (contre le sur-apprentissage)

**M5**
- Grille de 756 réglages : N, W, type de SL, buffer, RR, session.
- Choix sur juin 2025 → févr. 2026, test sur mars → nov. 2026.
- La zone N ≥ 3 + SL au bord de la zone est positive dans les deux moitiés, pour W de 3 à 12. C'est un plateau,
  pas un pic isolé.

**M1**
- Grille de 2 520 réglages sur août → nov. 2026 seulement.
- La recette a été figée et écrite (`results/preregistered.txt`) **avant** de télécharger les autres données M1.
- Elle a ensuite été testée sans aucun changement :
  - test 1, févr. → juil. 2026 : +76,5 R ;
  - test 2, juin 2025 → janv. 2026 : −9,2 R.

## Limites (à lire)

- **Source des données**
  - Twelve Data XAU/USD, pas le flux Exness. Les spreads, les mèches et les heures peuvent différer.
  - Il faut refaire le test sur les données du broker avant de trader.
- **Trous dans M1**
  - De juin à sept. 2025, il manque 6 à 23 % des minutes M1. Les résultats M1 de cette période sont moins fiables.
  - Les données M5 sont complètes.
- **Une période porte le résultat** : 77 % du gain M1 vient de févr. → juil. 2026, une période de baisse forte
  et très volatile. Sur 97 % des 768 variantes M1, cette période était positive.
- **Dépendance au régime**
  - En juin → sept. 2025, les deux versions perdent.
  - La stratégie gagne surtout dans le sens de la grande tendance : longs en hausse, shorts en baisse.
- **Séries de pertes**
  - Le win rate est d'environ 33 % avec RR 1:4.
  - La pire série du test : 18 pertes d'affilée en M1 (12 en M5), soit environ −17 % à 1 % de risque.

## EA MetaTrader 5 : `OB_CHoCH_M1.mq5`

Mêmes règles que la recette M1 : zone OB M30, CHoCH M1 (swing 3), SL au-delà de la zone ± 1 $, TP 1:4,
entrées 07–21 UTC, un trade à la fois, 24 h maximum, fermeture le vendredi à 16:30 New York.

- Ordre au marché à l'ouverture de la bougie M1 qui suit le CHoCH.
- Lot calculé pour risquer `RiskPercent` % du solde.
- Heure du serveur : `ServerClock = NY+7` pour FTMO, IC Markets et les autres serveurs GMT+2/+3. Pour Exness,
  choisir `CLOCK_FIXED` avec `ServerUTCOffset = 0`.
- Au démarrage, l'EA recharge environ 50 h d'historique pour retrouver les zones encore actives.
- À la fin d'un test, il écrit `OB_CHoCH_trades.csv` dans le dossier `MQL5/Files` de l'agent du testeur.

**Vérification (mqlsim, voir `../mqlsim/README.md`)** : le code de l'EA a été converti en C++ et exécuté tick
par tick sur les mêmes bougies M1 que le backtest Python.

| Test | Résultat |
|---|---|
| Heure FTMO, spread 0 | 260 trades sur 260 identiques au Python (même minute d'entrée, même sens, même SL, même résultat) |
| Heure Exness (UTC+0) | mêmes 260 trades |
| EA lancé au milieu des données (3 dates) | trades identiques à partir du lancement |
| Spread 0,35 $ (bid/ask) | 262 trades, +100,8 R, PF 1,59 |

Le test ne remplace pas la compilation dans MetaEditor ni le testeur MT5 : c'est la prochaine étape, avec les vraies
données du broker.

## Reproduire

```bash
python3 collect_twelvedata.py <dossier exports Twelve Data> <data>   # -> xau_m1_utc.csv, xau_m5_utc.csv
python3 grid.py   <data> results     # grilles M5 (18 mois) et M1 (août-nov. 2026)
python3 report.py <data> results     # les recettes sur chaque période + trades + courbe
```

Les fichiers de données brutes ne sont pas dans le dépôt (M1 = 700 000 bougies).
