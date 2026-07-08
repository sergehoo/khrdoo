# -*- coding: utf-8 -*-
from dateutil.relativedelta import relativedelta

from odoo import api, fields, models


class HrContract(models.Model):
    _inherit = "hr.contract"

    @api.model
    def _cron_contract_alerts(self, days=30):
        """Planifie des activités « à faire » pour les contrats dont le CDD ou la
        période d'essai arrive à échéance dans les `days` prochains jours."""
        today = fields.Date.context_today(self)
        limit = today + relativedelta(days=days)

        cdd = self.search([
            ("state", "=", "open"),
            ("date_end", "!=", False),
            ("date_end", ">=", today),
            ("date_end", "<=", limit),
        ])
        for c in cdd:
            c._kaydan_alert("Fin de CDD le %s — %s" % (c.date_end, c.employee_id.name or ""))

        # trial_date_end : présent en Odoo 18 (fin de période d'essai)
        if "trial_date_end" in self._fields:
            trials = self.search([
                ("state", "=", "open"),
                ("trial_date_end", "!=", False),
                ("trial_date_end", ">=", today),
                ("trial_date_end", "<=", limit),
            ])
            for c in trials:
                c._kaydan_alert("Fin de période d'essai le %s — %s" % (c.trial_date_end, c.employee_id.name or ""))

    def _kaydan_alert(self, summary):
        """Crée une activité « à faire » sur le contrat (sans doublon)."""
        self.ensure_one()
        Activity = self.env["mail.activity"].sudo()
        act_type = self.env.ref("mail.mail_activity_data_todo", raise_if_not_found=False)
        if not act_type:
            return
        model_id = self.env["ir.model"]._get_id("hr.contract")
        already = Activity.search_count([
            ("res_model_id", "=", model_id),
            ("res_id", "=", self.id),
            ("summary", "=", summary),
        ])
        if already:
            return
        responsible = self.hr_responsible_id or self.env.user
        Activity.create({
            "activity_type_id": act_type.id,
            "res_model_id": model_id,
            "res_id": self.id,
            "summary": summary,
            "user_id": responsible.id,
            "date_deadline": fields.Date.context_today(self),
        })
