# -*- coding: utf-8 -*-
{
    "name": "Kaydan ERP — Identité visuelle",
    "version": "18.0.1.0.0",
    "category": "Theme/Backend",
    "summary": "Personnalisation Kaydan : logo, favicon, page de connexion, thème corporate",
    "description": """
Kaydan ERP — Personnalisation premium
======================================
- Logo et favicon Kaydan
- Page de connexion personnalisée (corporate / noir-blanc-jaune orangé)
- Thème backend (couleurs d'accent)
- Suppression des mentions "Powered by Odoo" (autorisée en LGPL)
""",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "license": "LGPL-3",
    "depends": ["web", "base_setup"],
    "data": [
        "views/login_templates.xml",
        "views/layout_templates.xml",
        "data/branding_data.xml",
    ],
    "assets": {
        "web.assets_frontend": [
            "kaydan_branding/static/src/scss/login.scss",
        ],
        "web.assets_backend": [
            "kaydan_branding/static/src/scss/backend.scss",
        ],
    },
    "installable": True,
    "application": False,
    "auto_install": False,
}
