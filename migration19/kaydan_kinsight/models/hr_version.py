# -*- coding: utf-8 -*-
# =============================================================================
#  Odoo 19 : hr.employee DÉLÈGUE vers hr.version (_inherits). Les champs
#  department_id / job_id / job_title / employee_type appartiennent donc à
#  hr.version — leur lecture depuis l'employé exige un droit de LECTURE sur
#  hr.version (accordé en lecture seule dans ir.model.access.csv).
#
#  Ce n'est PAS une fuite de données sensibles : sur hr.version, 47 champs
#  portent une restriction au niveau CHAMP. Restent donc inaccessibles à
#  K-Insight (réservés à hr.group_hr_manager) : wage, contract_wage,
#  contract_type_id, contract_date_start/end, trial_date_end, date_start/end…
#
#  Seule exception ouverte ici : `employee_type` (employé / ouvrier / stagiaire
#  / prestataire…), non sensible et nécessaire aux répartitions d'effectif.
# =============================================================================
from odoo import fields, models


class HrVersion(models.Model):
    _inherit = "hr.version"

    employee_type = fields.Selection(
        groups="hr.group_hr_user,kaydan_kinsight.group_kinsight_readonly"
    )


class HrEmployee(models.Model):
    _inherit = "hr.employee"

    # Odoo 19 : toute lecture d'un champ délégué (department_id, job_id,
    # job_title, employee_type) passe par version_id, lui-même restreint à
    # hr.group_hr_user. Sans cette ouverture, K-Insight reçoit un 403 sur
    # TOUT hr.employee.search_read. version_id n'est qu'une clé étrangère :
    # les 47 champs sensibles de hr.version restent protégés individuellement.
    # ⚠ Ce champ N'EXISTE PAS en Odoo 18 — d'où sa présence dans l'overlay.
    version_id = fields.Many2one(
        groups="hr.group_hr_user,kaydan_kinsight.group_kinsight_readonly"
    )
