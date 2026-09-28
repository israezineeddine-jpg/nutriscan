# Agent Prop Firm — challenges acceptant le Maroc 🇲🇦

Trouve le challenge **le plus facile**, **le plus rapide** et **qui rapporte le plus en retraits**, parmi les prop firms qui acceptent les traders du Maroc.

## Utilisation (Python 3, aucune dépendance)

```bash
cd propfirm-agent

# Liste des firms qui acceptent / refusent le Maroc
python3 propfirm_agent.py firmes

# Classements (par défaut : seulement les firms qui acceptent le Maroc)
python3 propfirm_agent.py classement                 # global
python3 propfirm_agent.py classement --par facile
python3 propfirm_agent.py classement --par rapide
python3 propfirm_agent.py classement --par retrait --budget 500

# Simulation avec TES stats (5000 parcours Monte Carlo)
python3 propfirm_agent.py simuler --winrate 0.45 --rr 2 --risque 0.5 --trades-jour 2
```

Options : `--pays ALL` pour voir toutes les firms, `--inclure-a-confirmer` pour inclure celles dont l'acceptation du Maroc n'est pas sûre (The5ers).

## Mode agent IA

Dans Claude Code, demande par exemple : *« trouve-moi le meilleur challenge prop firm pour le Maroc »*.
La skill `.claude/skills/propfirm-finder` revérifie les règles sur le web, met à jour `data/challenges.json`, lance les calculs et te donne la recommandation.

## ⚠️ Important

- Les prix et règles de `data/challenges.json` sont **approximatifs** et changent souvent : vérifie sur le site officiel avant d'acheter.
- L'acceptation du Maroc a été vérifiée par recherche web en septembre 2026. Confirme-la avec le support avant de payer.
- La simulation suppose des trades indépendants avec un winrate fixe. La réalité est plus dure.
- Ce n'est pas un conseil financier.
