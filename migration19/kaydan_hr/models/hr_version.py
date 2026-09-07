# -*- coding: utf-8 -*-
# =============================================================================
#  PORTAGE ODOO 19 — remplace models/hr_contract.py (module hr_contract supprimé)
# -----------------------------------------------------------------------------
#  En Odoo 19, les contrats sont des « versions d'employé » (hr.version) et
#  hr.employee délègue vers ce modèle (_inherits = {'hr.version': 'version_id'}).
#  Conséquences :
#   - plus de champ `state` ('open') : le contrat en cours = la version courante
#     de l'employé, donc on parcourt les employés actifs ;
#   - `date_end` est CALCULÉ sur hr.version ; le champ stocké est
#     `contract_date_end` (fin de CDD) ; `trial_date_end` existe toujours ;
#   - ces champs portent groups="hr.group_hr_manager" (lecture restreinte) ;
#   - l'activité est posée sur l'EMPLOYÉ (hr.employee porte mail.activity.mixin),
#     ce qui la rend visible dans le chatter de la fiche employé.
# =============================================================================
from dateutil.relativedelta import relativedelta

from odoo import api, fields, models


class HrEmployee(models.Model):
    _inherit = "hr.employee"

    @api.model
    def _cron_contract_alerts(self, days=30):
        """Planifie des activités « à faire » pour les employés dont le CDD ou la
        période d'essai arrive à échéance dans les `days` prochains jours."""
        today = fields.Date.context_today(self)
        limit = today + relativedelta(days=days)
        Employee = self.sudo()  # le cron doit voir les champs restreints

        cdd = Employee.search([
            ("contract_date_end", "!=", False),
            ("contract_date_end", ">=", today),
            ("contract_date_end", "<=", limit),
        ])
        for emp in cdd:
            emp._kaydan_alert(
                "Fin de CDD le %s — %s" % (emp.contract_date_end, emp.name or "")
            )

        trials = Employee.search([
            ("trial_date_end", "!=", False),
            ("trial_date_end", ">=", today),
            ("trial_date_end", "<=", limit),
        ])
        for emp in trials:
            emp._kaydan_alert(
                "Fin de période d'essai le %s — %s" % (emp.trial_date_end, emp.name or "")
            )

    def _kaydan_alert(self, summary):
        """Crée une activité « à faire » sur l'employé (sans doublon)."""
        self.ensure_one()
        Activity = self.env["mail.activity"].sudo()
        act_type = self.env.ref("mail.mail_activity_data_todo", raise_if_not_found=False)
        if not act_type:
            return
        model_id = self.env["ir.model"]._get_id("hr.employee")
        already = Activity.search_count([
            ("res_model_id", "=", model_id),
            ("res_id", "=", self.id),
            ("summary", "=", summary),
        ])
        if already:
            return
        responsible = self.version_id.hr_responsible_id or self.parent_id.user_id or self.env.user
        Activity.create({
            "activity_type_id": act_type.id,
            "res_model_id": model_id,
            "res_id": self.id,
            "summary": summary,
            "user_id": responsible.id,
            "date_deadline": fields.Date.context_today(self),
        })
