# -*- coding: utf-8 -*-
{
    "name": "Kaydan ERP — API REST RH",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "summary": "API REST /api/v1/hr (employés, départements, congés, présences, dashboard) — auth par clé d'API",
    "description": """
Kaydan ERP — API REST Ressources Humaines
==========================================
Endpoints REST JSON sous /api/v1/hr, authentifiés par clé d'API Odoo
(en-tête Authorization: Bearer <api_key>). Sans dépendance externe
(contrôleurs http natifs). Respecte intégralement les droits Odoo de
l'utilisateur porteur de la clé.

Endpoints : /health · /employees · /employees/<id> · /departments ·
/leaves (GET/POST) · /attendances (GET) · /dashboard.
""",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "license": "LGPL-3",
    "depends": ["hr"],
    "data": [],
    "installable": True,
    "application": False,
    "auto_install": False,
}
