# -*- coding: utf-8 -*-
{
    "name": "Kaydan ERP — Tableau de bord RH",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "summary": "Tableau de bord RH : effectifs, départements, genre, congés, présences, contrats",
    "description": """
Kaydan ERP — Tableau de bord Ressources Humaines
=================================================
Action client OWL affichant les indicateurs clés RH en temps réel :
- Effectif total, nombre de départements, arrivées du mois
- Effectif par département (graphe), répartition par genre
- Congés à approuver / approuvés (si hr_holidays installé)
- Présents en ce moment (si hr_attendance installé)
- Contrats expirant sous 30 jours (si hr_contract installé)

Sans dépendance externe (graphes CSS), respecte les droits d'accès Odoo.
""",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "license": "LGPL-3",
    "depends": ["hr", "web"],
    "data": [
        "views/hr_dashboard_views.xml",
    ],
    "assets": {
        "web.assets_backend": [
            "kaydan_hr_dashboard/static/src/scss/hr_dashboard.scss",
            "kaydan_hr_dashboard/static/src/js/hr_dashboard.js",
            "kaydan_hr_dashboard/static/src/xml/hr_dashboard.xml",
        ],
    },
    "installable": True,
    "application": False,
    "auto_install": False,
}
