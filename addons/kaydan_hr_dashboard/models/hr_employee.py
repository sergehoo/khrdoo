# -*- coding: utf-8 -*-
from datetime import datetime, time, date
from dateutil.relativedelta import relativedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError


def _attach_pct(items):
    """Ajoute à chaque élément {label, value, ...} un champ 'pct' (0-100)
    relatif au max de la liste — utilisé directement par les barres OWL."""
    mx = max((i["value"] for i in items), default=0) or 1
    for i in items:
        i["pct"] = round(i["value"] / mx * 100)
    return items


class HrEmployee(models.Model):
    _inherit = "hr.employee"

    @api.model
    def get_kaydan_dashboard_data(self, company_id=None):
        """Indicateurs RH du tableau de bord Kaydan, filtrables par société.

        Blocs congés / présences / contrats inclus seulement si le module est
        installé ; chaque bloc est protégé par try/except AccessError pour ne
        jamais casser le reste du tableau.
        """
        Employee = self.env["hr.employee"]
        EmployeeAll = Employee.with_context(active_test=False)
        today = fields.Date.context_today(self)
        month_start = today.replace(day=1)
        month_start_dt = datetime.combine(month_start, time.min)

        # --- Périmètre société ----------------------------------------------
        company_ids = [company_id] if company_id else self.env.companies.ids
        comp_dom = [("company_id", "in", company_ids)]
        companies = [{"id": c.id, "name": c.name} for c in self.env.companies]

        # --- Effectif & répartitions ----------------------------------------
        total = Employee.search_count(comp_dom)

        dept_groups = Employee.read_group(comp_dom, ["department_id"], ["department_id"])
        by_department = sorted(
            [{"label": g["department_id"][1] if g.get("department_id") else "Sans département",
              "value": g.get("__count", 0)} for g in dept_groups],
            key=lambda r: r["value"], reverse=True,
        )

        gender_labels = {"male": "Hommes", "female": "Femmes", "other": "Autre"}
        gender_groups = Employee.read_group(comp_dom, ["gender"], ["gender"])
        by_gender = [{"label": gender_labels.get(g.get("gender"), "Non renseigné"),
                      "value": g.get("__count", 0)} for g in gender_groups]

        # Statut (employee_type) — libellés dynamiques depuis la sélection réelle
        et_sel = dict(Employee.fields_get(["employee_type"])["employee_type"].get("selection", []))
        et_groups = Employee.read_group(comp_dom, ["employee_type"], ["employee_type"])
        by_employee_type = sorted(
            [{"label": et_sel.get(g.get("employee_type"), g.get("employee_type") or "Non renseigné"),
              "value": g.get("__count", 0)} for g in et_groups],
            key=lambda r: r["value"], reverse=True,
        )

        # --- KPIs ------------------------------------------------------------
        kpis = {
            "total": total,
            "departments": len([d for d in by_department if d["label"] != "Sans département"]),
            "new_this_month": Employee.search_count(comp_dom + [("create_date", ">=", month_start_dt)]),
        }
        try:
            kpis["departures_12m"] = EmployeeAll.search_count(
                comp_dom + [("departure_date", ">=", today - relativedelta(months=12))]
            )
        except AccessError:
            pass

        # --- Recrutement : fenêtres glissantes ------------------------------
        recruitment = []
        for label, m in [("< 1 mois", 1), ("< 3 mois", 3), ("< 6 mois", 6)]:
            since_dt = datetime.combine(today - relativedelta(months=m), time.min)
            recruitment.append({
                "label": label,
                "value": Employee.search_count(comp_dom + [("create_date", ">=", since_dt)]),
            })

        recent = Employee.search(comp_dom, order="create_date desc", limit=8)
        recent_arrivals = [{
            "name": e.name,
            "department": e.department_id.name or "—",
            "date": fields.Date.to_string(e.create_date.date()) if e.create_date else "",
        } for e in recent]

        # --- Évolution des effectifs sur 12 mois ----------------------------
        evolution = []
        for i in range(11, -1, -1):
            m_first = month_start - relativedelta(months=i)
            m_end = m_first + relativedelta(months=1) - relativedelta(days=1)
            m_end_dt = datetime.combine(m_end, time.max)
            try:
                cnt = EmployeeAll.search_count(comp_dom + [
                    ("create_date", "<=", m_end_dt),
                    "|", ("departure_date", "=", False), ("departure_date", ">", m_end),
                ])
            except AccessError:
                cnt = EmployeeAll.search_count(comp_dom + [("create_date", "<=", m_end_dt)])
            evolution.append({"label": m_first.strftime("%m/%y"), "value": cnt})

        # --- Effectif par type de contrat (hr_contract) ---------------------
        by_contract_type = []
        if "hr.contract" in self.env:
            try:
                Contract = self.env["hr.contract"]
                cdom = [("state", "=", "open"), ("company_id", "in", company_ids)]
                groups = Contract.read_group(cdom, ["contract_type_id"], ["contract_type_id"])
                for g in groups:
                    by_contract_type.append({
                        "label": g["contract_type_id"][1] if g.get("contract_type_id") else "Type non défini",
                        "value": g.get("__count", 0),
                    })
                sans = total - len(set(Contract.search(cdom).employee_id.ids))
                if sans > 0:
                    by_contract_type.append({"label": "Sans contrat", "value": sans})
                by_contract_type.sort(key=lambda r: r["value"], reverse=True)
            except AccessError:
                by_contract_type = []

        # --- Top congés par employé (année en cours) ------------------------
        top_leaves = []
        if "hr.leave" in self.env:
            try:
                Leave = self.env["hr.leave"]
                year_start_dt = datetime.combine(date(today.year, 1, 1), time.min)
                ldom = [("state", "=", "validate"),
                        ("date_from", ">=", year_start_dt),
                        ("employee_id.company_id", "in", company_ids)]
                lg = Leave.read_group(ldom, ["number_of_days:sum"], ["employee_id"])
                lg = sorted([g for g in lg if g.get("employee_id")],
                            key=lambda g: g.get("number_of_days", 0) or 0, reverse=True)
                top_leaves = [{"label": g["employee_id"][1],
                               "value": round(g.get("number_of_days", 0) or 0, 1)} for g in lg[:8]]
                kpis["leaves_to_approve"] = Leave.search_count(
                    [("state", "in", ["confirm", "validate1"]),
                     ("employee_id.company_id", "in", company_ids)]
                )
            except AccessError:
                pass

        # --- Présences (hr_attendance) --------------------------------------
        if "hr.attendance" in self.env:
            try:
                kpis["present_now"] = self.env["hr.attendance"].search_count(
                    [("check_out", "=", False), ("employee_id.company_id", "in", company_ids)]
                )
            except AccessError:
                pass

        # --- Top départs par motif (12 mois) --------------------------------
        top_departures = []
        try:
            ddom = comp_dom + [("departure_date", "!=", False),
                               ("departure_date", ">=", today - relativedelta(months=12))]
            dg = EmployeeAll.read_group(ddom, ["departure_reason_id"], ["departure_reason_id"])
            top_departures = sorted(
                [{"label": g["departure_reason_id"][1] if g.get("departure_reason_id") else "Motif non précisé",
                  "value": g.get("__count", 0)} for g in dg],
                key=lambda r: r["value"], reverse=True,
            )[:8]
        except AccessError:
            pass

        return {
            "companies": companies,
            "company_id": company_id or False,
            "kpis": kpis,
            "by_department": _attach_pct(by_department),
            "by_gender": _attach_pct(by_gender),
            "by_employee_type": _attach_pct(by_employee_type),
            "by_contract_type": _attach_pct(by_contract_type),
            "evolution": _attach_pct(evolution),
            "recruitment": recruitment,
            "recent_arrivals": recent_arrivals,
            "top_leaves": _attach_pct(top_leaves),
            "top_departures": _attach_pct(top_departures),
        }
