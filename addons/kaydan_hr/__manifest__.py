# -*- coding: utf-8 -*-
{
    "name": "Kaydan ERP — RH avancé (multi-filiales)",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "summary": "Dossier employé enrichi (matricule par filiale, CNPS, ancienneté) + alertes contrats",
    "description": """
Kaydan ERP — RH avancé (multi-filiales)
=======================================
Enrichit le socle RH d'Odoo Community pour un groupe multi-sociétés :

- **Matricule automatique par filiale** (préfixe société + séquence dédiée).
- **N° CNPS**, **date d'embauche**, **ancienneté** calculée.
- **Alertes contrats** : fin de CDD et fin de période d'essai (activités
  planifiées automatiquement au responsable RH, via une action planifiée).
- Compatible **multi-sociétés** natif d'Odoo (données cloisonnées par filiale).

Hors périmètre v1 (voir feuille de route) : paie, recrutement, mobilité
inter-filiales, évaluations.
""",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "license": "LGPL-3",
    "depends": ["hr", "hr_contract"],
    "data": [
        "views/hr_employee_views.xml",
        "data/ir_cron_data.xml",
    ],
    "installable": True,
    "application": False,
    "auto_install": False,
}
