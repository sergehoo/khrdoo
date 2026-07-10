# -*- coding: utf-8 -*-
from odoo import _, api, fields, models
from odoo.exceptions import UserError


class HrEmployeeTransfer(models.Model):
    _name = "hr.employee.transfer"
    _description = "Mutation inter-filiales"
    _inherit = ["mail.thread"]
    _order = "date desc, id desc"
    _rec_name = "employee_id"

    employee_id = fields.Many2one(
        "hr.employee", string="Employé", required=True, ondelete="cascade", tracking=True)
    date = fields.Date(
        string="Date d'effet", default=fields.Date.context_today, required=True, tracking=True)

    from_company_id = fields.Many2one("res.company", string="Filiale d'origine", readonly=True)
    from_department_id = fields.Many2one("hr.department", string="Département d'origine", readonly=True)

    to_company_id = fields.Many2one("res.company", string="Nouvelle filiale", required=True, tracking=True)
    to_department_id = fields.Many2one(
        "hr.department", string="Nouveau département",
        domain="['|', ('company_id', '=', False), ('company_id', '=', to_company_id)]")
    to_job_id = fields.Many2one(
        "hr.job", string="Nouveau poste",
        domain="['|', ('company_id', '=', False), ('company_id', '=', to_company_id)]")

    reason = fields.Text(string="Motif")
    state = fields.Selection(
        [("draft", "Brouillon"), ("done", "Appliquée")],
        default="draft", tracking=True)

    @api.onchange("employee_id")
    def _onchange_employee_id(self):
        for t in self:
            t.from_company_id = t.employee_id.company_id
            t.from_department_id = t.employee_id.department_id

    def action_apply(self):
        for t in self:
            if t.state == "done":
                continue
            if not t.employee_id:
                raise UserError(_("Sélectionnez un employé."))
            emp = t.employee_id
            # Fige l'origine (au cas où l'onchange n'a pas tourné, ex. création via One2many)
            t.from_company_id = emp.company_id
            t.from_department_id = emp.department_id

            vals = {"company_id": t.to_company_id.id}
            if t.to_department_id:
                vals["department_id"] = t.to_department_id.id
            if t.to_job_id:
                vals["job_id"] = t.to_job_id.id
            emp.write(vals)

            t.state = "done"
            body = _("Mutation inter-filiales : %s → %s (effet le %s).") % (
                t.from_company_id.display_name or "?",
                t.to_company_id.display_name,
                t.date,
            )
            if t.reason:
                body += _("<br/>Motif : %s") % t.reason
            emp.message_post(body=body)
        return True
