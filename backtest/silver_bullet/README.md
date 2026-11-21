# SilverBullet_XAU.mq5 – réplique Python et backtest

`sb_backtest.py` refait la logique de l'EA (`SilverBullet_XAU.mq5`) bougie par bougie :
- fenêtres 3h, 10h et 14h New York ;
- sweep de la liquidité des 10 dernières bougies contre les 20 d'avant ;
- FVG sur les bougies 1 à 3, ordre limite au bord du FVG ;
- SL derrière la mèche du sweep, TP = RR × risque ;
- 1 achat et 1 vente maximum par fenêtre, une seule position à la fois, sortie seulement par SL ou TP.

Le spread est simulé avec un bid et un ask. Les achats sortent au bid. Les ventes sortent à l'ask, donc leur SL est
touché plus tôt.

## Données et tests

- Données Twelve Data XAU/USD : M5 de juin 2025 à nov. 2026, M1 d'oct. 2025 à nov. 2026. Spread 0,35 $.
- Deux réglages de points :
  - 2 décimales (FTMO) : FVG minimum 0,50 $, buffer 0,20 $ ;
  - 3 décimales (Exness) : FVG minimum 0,05 $, buffer 0,02 $.

## Résultat : perdant partout

| | RR 1 | RR 2 (défaut) | RR 3 | RR 4 |
|---|---|---|---|---|
| M5 – PF | 0,79 | 0,76 | 0,76 | 0,78 |
| M5 – ROI à 0,5 % | −20 % | −28 % | −29 % | −27 % |
| M1 – PF | 0,61 | 0,73 | 0,83 | 0,86 |
| M1 – ROI à 0,5 % | −48 % | −40 % | −29 % | −26 % |

(réglage 2 décimales ; le réglage 3 décimales est pire)

- **Sans aucun spread**, le PF reste sous 1 : 0,87 à 0,89 en M5, 0,68 à 0,88 en M1.
- C'est négatif dans les deux moitiés de la période.
- Le résultat reste négatif quand on retire les trades touchés par le SL dans la bougie d'entrée.

Le détail par fenêtre et par sens est dans `results/sb_report.txt`.

## Points du code à corriger

1. `ServerMinusNY = 7` est fixe.
   - C'est juste pour un serveur GMT+2/+3 qui change d'heure avec New York, comme FTMO.
   - Sur Exness (GMT+0), il faut 4 en été et 5 en hiver.
2. `MinFVGPoints` et `SLBufferPoints` sont en points. Sur un symbole à 3 décimales, le buffer vaut 0,02 $, moins
   que le spread : le SL des ventes est touché avant que le prix revienne à la mèche.
3. Il n'y a pas de sortie par le temps ni de fermeture le vendredi : une position peut passer le week-end.
4. `ORDER_TIME_SPECIFIED` peut être refusé par certains brokers. `ORDER_TIME_GTC` suffit, car l'EA supprime déjà les
   ordres hors fenêtre.
5. Le FVG est lu sur les bougies 1 à 3 dès la première bougie de la fenêtre. Il peut donc être formé avant la
   fenêtre, alors que le Silver Bullet classique cherche un FVG formé dans la fenêtre.
6. Il n'y a pas de filtre de spread, alors qu'il y a des news à 10h New York.

## Reproduire

```bash
python3 sb_backtest.py <dossier avec xau_m1_utc.csv et xau_m5_utc.csv> results
```
