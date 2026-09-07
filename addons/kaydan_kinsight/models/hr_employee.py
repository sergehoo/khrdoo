# -*- coding: utf-8 -*-
# =============================================================================
#  Ouverture EN LECTURE de quelques champs Kaydan au groupe K-Insight.
#  Les champs de kaydan_hr portent groups="hr.group_hr_user" : sans cette
#  extension, K-Insight (qui n'a PAS hr.group_hr_user) ne les verrait pas.
#  `cnps_number` est DÉLIBÉRÉMENT absent : donnée personnelle sensible.
# =============================================================================
from odoo import fields, models

_KI = "hr.group_hr_user,kaydan_kinsight.group_kinsight_readonly"


class HrEmployee(models.Model):
    _inherit = "hr.employee"

    # Odoo 19 : toute lecture d'un champ délégué (department_id, job_id,
    # job_title, employee_type) passe par version_id, lui-même restreint à
    # hr.group_hr_user. Sans cette ouverture, K-Insight reçoit un 403 sur
    # TOUT hr.employee.search_read. version_id n'est qu'une clé étrangère :
    # les 47 champs sensibles de hr.version restent protégés individuellement.
    version_id = fields.Many2one(groups=_KI)

    matricule = fields.Char(groups=_KI)
    hire_date = fields.Date(groups=_KI)
    seniority = fields.Char(groups=_KI)
