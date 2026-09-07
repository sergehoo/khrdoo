# -*- coding: utf-8 -*-
{
    "name": "Kaydan — Accès K-Insight (lecture seule)",
    "summary": "Groupe technique et utilisateur de service pour la consommation "
               "en LECTURE SEULE des données RH par K-Insight (API JSON-2).",
    "version": "18.0.1.0.0",
    "category": "Human Resources",
    "author": "Kaydan Groupe",
    "website": "https://kaydan.tech",
    "description": """
Accès K-Insight — moindre privilège
===================================
Crée :
  * un groupe **K-Insight (lecture seule)** : uniquement `perm_read` sur les
    modèles RH nécessaires (aucun write / create / unlink, nulle part) ;
  * un utilisateur de service **kinsight** (interne, sans mot de passe : il
    s'authentifie exclusivement par clé API, en-tête `Authorization: bearer`).

`hr.version` est lisible (Odoo 19 y délègue department_id / job_id / job_title
depuis hr.employee), mais ses 47 champs sensibles restent protégés AU NIVEAU
CHAMP par hr.group_hr_manager.

Volontairement INACCESSIBLES à K-Insight :
  * **salaires** (`wage`, `contract_wage`) et contrats (`contract_type_id`,
    `contract_date_*`, `trial_date_end`, `date_start/end`) ;
  * `cnps_number` (donnée personnelle sensible) ;
  * toute écriture, et tout modèle hors périmètre RH.

Les présences / effectifs terrain / sites restent servis par **KShield**
(source prioritaire) ; Odoo ne fournit ici que le référentiel RH.
""",
    "license": "LGPL-3",
    "depends": ["hr", "hr_holidays", "kaydan_hr"],
    "data": [
        "security/kinsight_groups.xml",
        "security/ir.model.access.csv",
    ],
    "post_init_hook": "post_init_hook",
    "installable": True,
    "application": False,
    "auto_install": False,
}
