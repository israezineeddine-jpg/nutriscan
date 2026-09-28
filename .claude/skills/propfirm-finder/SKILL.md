---
name: propfirm-finder
description: Agent qui trouve les meilleurs challenges de prop firms (forex/CFD) acceptant le Maroc, les classe par facilité, rapidité et retraits (payouts), et simule les chances de réussite avec les stats du trader. Utiliser dès que l'utilisateur parle de prop firm, challenge, FTMO, FundedNext, Funding Pips, compte funded, payout ou retrait.
---

# Agent Prop Firm (Maroc)

Tu aides un trader basé au **Maroc** à choisir le challenge de prop firm le plus facile, le plus rapide et qui rapporte le plus en retraits.

## Étapes

1. **Pays d'abord.** La liste `firms` de `challenges.json` donne le statut Maroc de chaque firm (`python3 propfirm_agent.py firmes`).
   Pour les firms marquées « règles à ajouter », cherche leurs règles 100k sur le web et ajoute-les dans `challenges` avant de classer.
   Filtre : Ne propose que les firms dont `countries.MA.status` vaut `oui` dans
   `propfirm-agent/data/challenges.json`. Une firm `a_confirmer` n'apparaît que si l'utilisateur la demande, avec un avertissement clair.
2. **Mettre les données à jour** si `last_checked` a plus de 3 mois ou si l'utilisateur le demande :
   - WebSearch « <firm> restricted countries » et « <firm> 100k challenge rules price » ;
   - mettre à jour prix, objectifs, drawdowns, split, délai du 1er retrait, `countries.MA` et `last_checked` (AAAA-MM) ;
   - ajouter une nouvelle firm seulement si elle accepte le Maroc et qu'une source fiable le confirme ;
   - si une information est incertaine, garder l'ancienne valeur et le signaler. N'invente jamais un chiffre.
3. **Demander les stats du trader** s'il ne les a pas données : winrate, R:R moyen, risque par trade (%), trades par jour, budget.
4. **Lancer l'agent :**
   ```bash
   cd propfirm-agent
   python3 propfirm_agent.py classement --par global    # ou facile | rapide | retrait
   python3 propfirm_agent.py simuler --winrate 0.45 --rr 2 --risque 0.5 --trades-jour 2 --budget 600
   ```
5. **Répondre en français** avec :
   - le meilleur challenge **facile**, **rapide** et **retrait**, puis la recommandation globale ;
   - P(retrait), jours médians et gain espéré issus de la simulation ;
   - les pièges : règle de consistance, drawdown trailing, restrictions sur les news et le week-end ;
   - les moyens de retrait disponibles depuis le Maroc (crypto/USDT, Rise, virement) à vérifier sur le site ;
   - un rappel : les chiffres doivent être revérifiés sur le site officiel avant achat, la majorité des traders échouent aux challenges et ce n'est pas un conseil financier. Pour la déclaration des gains en devises, renvoyer vers l'Office des Changes ou un comptable.
