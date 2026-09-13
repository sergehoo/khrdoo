# -*- coding: utf-8 -*-
{
    "name": "Kaydan — Rôles métier (N / N+1 / N+2)",
    "summary": "Rôles utilisateurs prêts à l'emploi par métier et par niveau "
               "hiérarchique, construits sur les groupes standards d'Odoo.",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "description": """
Rôles métier Kaydan
===================
Odoo ne livre que des groupes techniques par application (« Administrateur »,
« Utilisateur »…). Ce module ajoute des **rôles métier** correspondant à
l'organisation réelle : dans chaque métier, trois niveaux qui s'emboîtent.

  N    — opérationnel : travaille sur ses propres dossiers
  N+1  — encadrement  : voit et valide ceux de son équipe
  N+2  — direction    : administre l'ensemble du métier

Chaque niveau HÉRITE du précédent (implied_ids) : attribuer « Directeur RH »
accorde automatiquement tout ce que possèdent Responsable RH et Assistant RH.
Un rôle par métier apparaît comme une liste déroulante dans la fiche
utilisateur (Paramètres ▸ Utilisateurs & Sociétés ▸ Utilisateurs).

Aucun droit n'est inventé : les rôles ne font que combiner des groupes
standards Odoo déjà présents sur l'instance.
""",
    "license": "LGPL-3",
    "depends": [
        "hr", "hr_holidays", "hr_recruitment", "hr_contract", "hr_attendance",
        "hr_expense", "sales_team", "account", "project", "survey",
    ],
    "data": ["security/kaydan_roles.xml"],
    "installable": True,
    "application": False,
    "auto_install": False,
}
