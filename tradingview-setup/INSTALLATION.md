# Connecter TradingView à Claude Code (sur VOTRE ordinateur)

⚠️ **Important** : cette installation doit se faire sur l'ordinateur où TradingView
Desktop est installé. Elle ne peut PAS se faire dans une session Claude Code web/cloud,
car le serveur MCP se connecte à l'application TradingView qui tourne sur la même machine.

## Prérequis

- [TradingView Desktop](https://www.tradingview.com/desktop/) installé
- [Node.js](https://nodejs.org/) installé (version 18 ou plus)
- [Claude Code](https://claude.com/claude-code) installé en local (CLI ou app de bureau)

## Étape 1 — Installer le serveur MCP

Ouvrez un terminal sur votre PC :

```bash
git clone https://github.com/tradesdontlie/tradingview-mcp.git ~/tradingview-mcp
cd ~/tradingview-mcp
npm install
```

> ⚠️ Ce projet est un outil communautaire **non officiel** (ni TradingView, ni Anthropic).
> Il pilote votre session TradingView connectée. Vérifiez le code du dépôt avant de
> l'installer, et n'utilisez ce genre d'outil qu'en lecture/analyse, jamais pour passer
> des ordres automatiquement.

## Étape 2 — Déclarer le serveur MCP dans Claude Code

La méthode fiable est la commande `claude mcp add` (elle écrit la config au bon
endroit, inutile d'éditer des fichiers à la main) :

```bash
claude mcp add --scope user tradingview -- node ~/tradingview-mcp/src/server.js
```

Sous Windows (PowerShell), remplacez `~` par votre dossier utilisateur, par exemple :

```powershell
claude mcp add --scope user tradingview -- node C:\Users\VOTRE_NOM\tradingview-mcp\src\server.js
```

Vérifiez ensuite :

```bash
claude mcp list
```

## Étape 3 — Copier votre fichier de règles de trading

Copiez le fichier `rules.json` (dans ce même dossier du dépôt) vers :

```
~/tradingview-mcp/rules.json
```

Il contient votre configuration swing-trading crypto : watchlist (BTC, ETH, SOL,
LINK, AVAX, SUI + indices TOTAL/TOTAL3/BTC.D), unités de temps 1W/1D/4H, critères
de biais haussier/baissier, règles de risque (1 % max par trade, ratio R/R ≥ 2)
et indicateurs suivis (RSI 14, MACD, EMA 50/200, Volume).

## Étape 4 — Lancer TradingView avec le port de débogage

Fermez TradingView s'il est ouvert, puis relancez-le avec le flag `--remote-debugging-port` :

- **Mac** :
  ```bash
  /Applications/TradingView.app/Contents/MacOS/TradingView --remote-debugging-port=9222
  ```
- **Windows** (PowerShell) :
  ```powershell
  & "$env:LOCALAPPDATA\TradingView\TradingView.exe" --remote-debugging-port=9222
  ```
- **Linux** :
  ```bash
  /opt/TradingView/tradingview --remote-debugging-port=9222
  ```

> 🔒 **Sécurité** : le port 9222 donne le contrôle total de l'application à tout
> programme local. Ne l'activez que le temps de vos sessions d'analyse, et jamais
> sur une machine partagée.

## Étape 5 — Vérifier la connexion

Redémarrez Claude Code (les serveurs MCP sont chargés au démarrage de la session),
puis demandez-lui :

> lance tv_health_check

Si la réponse contient `cdp_connected: true`, la connexion fonctionne.

## Étape 6 — Utiliser

Exemples de demandes à Claude Code une fois connecté :

- « Donne-moi le prix actuel de BTCUSDT »
- « Analyse le graphique ETHUSDT en 4H : tendance, supports et résistances »
- « Passe en revue ma watchlist selon mes règles dans rules.json et donne le biais de chaque paire »

## En cas de problème

- `tv_health_check` échoue → vérifiez que TradingView a bien été lancé **avec** le
  flag `--remote-debugging-port=9222` (étape 4) et qu'aucune autre instance ne
  tournait déjà.
- Le serveur `tradingview` n'apparaît pas dans `claude mcp list` → refaites l'étape 2
  et vérifiez le chemin vers `server.js`.
- Les outils `tv_*` n'apparaissent pas dans Claude Code → redémarrez complètement
  Claude Code après l'étape 2.
