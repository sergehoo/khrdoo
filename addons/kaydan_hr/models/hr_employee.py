# -*- coding: utf-8 -*-
from dateutil.relativedelta import relativedelta

from odoo import api, fields, models


class HrEmployee(models.Model):
    _inherit = "hr.employee"

    matricule = fields.Char(
        string="Matricule", copy=False, index=True, readonly=True,
        groups="hr.group_hr_user", tracking=True,
        help="Généré automatiquement à la création : préfixe société + séquence par filiale.",
    )
    cnps_number = fields.Char(
        string="N° CNPS", groups="hr.group_hr_user", tracking=True,
        help="Numéro de sécurité sociale (CNPS).",
    )
    hire_date = fields.Date(
        string="Date d'embauche", groups="hr.group_hr_user", tracking=True,
    )
    seniority = fields.Char(
        string="Ancienneté", compute="_compute_seniority",
        groups="hr.group_hr_user",
    )
    transfer_ids = fields.One2many(
        "hr.employee.transfer", "employee_id", string="Mutations",
        groups="hr.group_hr_user",
    )

    @api.depends("hire_date")
    def _compute_seniority(self):
        today = fields.Date.context_today(self)
        for emp in self:
            if emp.hire_date and emp.hire_date <= today:
                d = relativedelta(today, emp.hire_date)
                parts = []
                if d.years:
                    parts.append("%d an%s" % (d.years, "s" if d.years > 1 else ""))
                if d.months:
                    parts.append("%d mois" % d.months)
                emp.seniority = " ".join(parts) or "moins d'un mois"
            else:
                emp.seniority = ""

    @api.model_create_multi
    def create(self, vals_list):
        employees = super().create(vals_list)
        for emp in employees:
            if not emp.matricule:
                emp.sudo().matricule = emp.sudo()._next_matricule()
        return employees

    def _next_matricule(self):
        """Matricule = <PREFIXE SOCIÉTÉ>-<séquence propre à la filiale>."""
        self.ensure_one()
        company = self.company_id or self.env.company
        base = "".join(ch for ch in (company.name or "EMP") if ch.isalnum()).upper()
        prefix = base[:3] or "EMP"
        code = "kaydan.hr.matricule.%d" % company.id
        Seq = self.env["ir.sequence"].sudo()
        seq = Seq.search([("code", "=", code)], limit=1)
        if not seq:
            seq = Seq.create({
                "name": "Matricule RH — %s" % (company.name or company.id),
                "code": code,
                "padding": 5,
                "implementation": "no_gap",
                "company_id": company.id,
            })
        return "%s-%s" % (prefix, seq.next_by_id())
