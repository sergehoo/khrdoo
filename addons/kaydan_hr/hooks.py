# -*- coding: utf-8 -*-
import logging

_logger = logging.getLogger(__name__)


def post_init_hook(env):
    """Attribue un matricule aux employés existants qui n'en ont pas
    (le matricule n'est sinon généré qu'à la création)."""
    employees = env["hr.employee"].sudo().with_context(active_test=False).search(
        [("matricule", "in", [False, ""])]
    )
    done = 0
    for emp in employees:
        try:
            emp.matricule = emp._next_matricule()
            done += 1
        except Exception as e:  # noqa: BLE001 - ne jamais bloquer l'installation
            _logger.warning("Backfill matricule ignoré pour %s : %s", emp.id, e)
    if done:
        _logger.info("Kaydan RH : %d matricule(s) attribué(s) aux employés existants.", done)
