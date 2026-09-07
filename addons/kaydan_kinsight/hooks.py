# -*- coding: utf-8 -*-
# =============================================================================
#  Création idempotente de l'utilisateur de service K-Insight.
#  Fait en Python (et non en XML) car le champ des groupes de res.users a été
#  RENOMMÉ en Odoo 19 : `groups_id` (18) -> `group_ids` (19). Ce hook fonctionne
#  donc sur les deux versions.
#
#  L'utilisateur n'a PAS de mot de passe : il s'authentifie uniquement par clé
#  API (en-tête `Authorization: bearer …`), à créer dans l'UI :
#     se connecter en 'kinsight' → Préférences → Sécurité du compte → Nouvelle clé API
# =============================================================================
import logging

_logger = logging.getLogger(__name__)

LOGIN = "kinsight@kaydangroupe.com"


def post_init_hook(env):
    Users = env["res.users"].sudo()
    groups_field = "group_ids" if "group_ids" in Users._fields else "groups_id"
    group = env.ref("kaydan_kinsight.group_kinsight_readonly", raise_if_not_found=False)
    if not group:
        _logger.warning("K-Insight : groupe introuvable, utilisateur non créé.")
        return

    base_user = env.ref("base.group_user")
    existing = Users.with_context(active_test=False).search([("login", "=", LOGIN)], limit=1)
    if existing:
        existing.write({groups_field: [(4, base_user.id), (4, group.id)], "active": True})
        _logger.info("K-Insight : utilisateur %s mis à jour (%s).", LOGIN, groups_field)
        return

    try:
        user = Users.with_context(no_reset_password=True).create({
            "name": "K-Insight (service technique)",
            "login": LOGIN,
            "share": False,
            groups_field: [(6, 0, [base_user.id, group.id])],
        })
        _logger.info("K-Insight : utilisateur de service créé (id=%s).", user.id)
    except Exception as e:  # ne jamais faire échouer l'installation pour ça
        _logger.warning("K-Insight : création de l'utilisateur impossible (%s).", e)
