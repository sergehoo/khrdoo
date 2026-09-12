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


    matricule = fields.Char(groups=_KI)
    hire_date = fields.Date(groups=_KI)
    seniority = fields.Char(groups=_KI)
