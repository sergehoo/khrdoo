# -*- coding: utf-8 -*-
{
    "name": "Kaydan ERP — Données RH de démo",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "summary": "Jeu de données RH réaliste (employés, départements, contrats, congés, départs) pour alimenter le tableau de bord",
    "description": """
Génère, à l'installation, un jeu de données RH de démonstration :
- ~32 employés répartis sur 5 départements, dates d'arrivée étalées sur 14 mois
- genres + statuts variés (employé, consultant, stagiaire…)
- contrats en cours (CDI / CDD / Stage / Consultant)
- congés validés (top congés)
- départs avec motif sur 12 mois (top départs)

Tous les employés créés portent le tag « DÉMO » pour un nettoyage facile.
⚠ À NE PAS installer sur une base contenant de vraies données de production.
""",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "license": "LGPL-3",
    "depends": ["hr", "hr_holidays", "hr_contract"],
    "data": [],
    "post_init_hook": "post_init_hook",
    "installable": True,
    "application": False,
    "auto_install": False,
}
