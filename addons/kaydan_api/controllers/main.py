# -*- coding: utf-8 -*-
import functools
import json
import logging

from odoo import http
from odoo.http import request
from odoo.exceptions import AccessError, UserError, ValidationError

_logger = logging.getLogger(__name__)

API = "/api/v1/hr"
DEFAULT_LIMIT = 50
MAX_LIMIT = 200


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
def _json(data, status=200):
    return request.make_json_response(data, status=status)


def _error(message, status=400):
    return request.make_json_response({"error": message, "status": status}, status=status)


def _authenticate():
    """Valide `Authorization: Bearer <api_key>` via les clés d'API natives Odoo.
    Retourne l'uid (int) ou None."""
    header = request.httprequest.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    key = header[7:].strip()
    if not key:
        return None
    try:
        uid = request.env["res.users.apikeys"].sudo()._check_credentials(scope="rpc", key=key)
    except Exception:
        return None
    return uid or None


def _paging(kw):
    try:
        limit = min(int(kw.get("limit", DEFAULT_LIMIT)), MAX_LIMIT)
    except (TypeError, ValueError):
        limit = DEFAULT_LIMIT
    try:
        offset = max(int(kw.get("offset", 0)), 0)
    except (TypeError, ValueError):
        offset = 0
    return max(limit, 1), offset


def _body():
    """Parse le corps JSON d'une requête (tolérant)."""
    try:
        raw = request.httprequest.get_data(as_text=True) or "{}"
        return json.loads(raw)
    except (ValueError, TypeError):
        return {}


def api_endpoint(auth_required=True):
    """Décorateur : auth optionnelle par clé d'API + gestion uniforme des erreurs JSON."""
    def deco(func):
        @functools.wraps(func)
        def wrapper(self, *args, **kwargs):
            try:
                if auth_required:
                    uid = _authenticate()
                    if not uid:
                        return _error("Authentification requise (Authorization: Bearer <api_key>)", 401)
                    request.update_env(user=uid)
                return func(self, *args, **kwargs)
            except AccessError:
                return _error("Accès refusé", 403)
            except (UserError, ValidationError) as e:
                return _error(str(e), 400)
            except Exception:
                _logger.exception("Kaydan API — erreur non gérée")
                return _error("Erreur interne du serveur", 500)
        return wrapper
    return deco


class KaydanHrApi(http.Controller):

    # =====================================================================
    #  Santé (public)
    # =====================================================================
    @http.route(f"{API}/health", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint(auth_required=False)
    def health(self, **kw):
        return _json({"status": "ok", "service": "kaydan-hr-api", "version": "1.0"})

    # =====================================================================
    #  Employés
    # =====================================================================
    @http.route(f"{API}/employees", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def employees(self, **kw):
        limit, offset = _paging(kw)
        domain = []
        if kw.get("department_id"):
            domain.append(("department_id", "=", int(kw["department_id"])))
        if kw.get("employee_type"):
            domain.append(("employee_type", "=", kw["employee_type"]))
        if kw.get("q"):
            domain.append(("name", "ilike", kw["q"]))
        Employee = request.env["hr.employee"]
        total = Employee.search_count(domain)
        recs = Employee.search(domain, limit=limit, offset=offset, order="name")
        results = [{
            "id": e.id,
            "name": e.name,
            "job_title": e.job_title or None,
            "department": e.department_id.name or None,
            "department_id": e.department_id.id or None,
            "work_email": e.work_email or None,
            "work_phone": e.work_phone or None,
            "employee_type": e.employee_type,
        } for e in recs]
        return _json({"count": total, "limit": limit, "offset": offset, "results": results})

    @http.route(f"{API}/employees/<int:emp_id>", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def employee_detail(self, emp_id, **kw):
        e = request.env["hr.employee"].browse(emp_id).exists()
        if not e:
            return _error("Employé introuvable", 404)
        return _json({
            "id": e.id,
            "name": e.name,
            "job_title": e.job_title or None,
            "department": e.department_id.name or None,
            "manager": e.parent_id.name or None,
            "work_email": e.work_email or None,
            "work_phone": e.work_phone or None,
            "mobile_phone": e.mobile_phone or None,
            "employee_type": e.employee_type,
            "company": e.company_id.name or None,
        })

    # =====================================================================
    #  Départements
    # =====================================================================
    @http.route(f"{API}/departments", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def departments(self, **kw):
        recs = request.env["hr.department"].search([], order="name")
        results = [{
            "id": d.id,
            "name": d.name,
            "manager": d.manager_id.name or None,
            "headcount": d.total_employee,
        } for d in recs]
        return _json({"count": len(results), "results": results})

    # =====================================================================
    #  Congés (hr_holidays)
    # =====================================================================
    @http.route(f"{API}/leaves", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def leaves(self, **kw):
        if "hr.leave" not in request.env:
            return _error("Module Congés (hr_holidays) non installé", 501)
        limit, offset = _paging(kw)
        domain = []
        if kw.get("employee_id"):
            domain.append(("employee_id", "=", int(kw["employee_id"])))
        if kw.get("state"):
            domain.append(("state", "=", kw["state"]))
        if kw.get("date_from"):
            domain.append(("date_from", ">=", kw["date_from"]))
        if kw.get("date_to"):
            domain.append(("date_to", "<=", kw["date_to"]))
        Leave = request.env["hr.leave"]
        total = Leave.search_count(domain)
        recs = Leave.search(domain, limit=limit, offset=offset, order="date_from desc")
        results = [{
            "id": l.id,
            "employee": l.employee_id.name or None,
            "employee_id": l.employee_id.id or None,
            "leave_type": l.holiday_status_id.name or None,
            "date_from": str(l.date_from) if l.date_from else None,
            "date_to": str(l.date_to) if l.date_to else None,
            "number_of_days": l.number_of_days,
            "state": l.state,
        } for l in recs]
        return _json({"count": total, "limit": limit, "offset": offset, "results": results})

    @http.route(f"{API}/leaves", type="http", auth="public", methods=["POST"], csrf=False, save_session=False)
    @api_endpoint()
    def create_leave(self, **kw):
        if "hr.leave" not in request.env:
            return _error("Module Congés (hr_holidays) non installé", 501)
        data = _body()
        required = ["employee_id", "holiday_status_id", "date_from", "date_to"]
        missing = [f for f in required if not data.get(f)]
        if missing:
            return _error("Champs requis manquants : %s" % ", ".join(missing), 422)
        leave = request.env["hr.leave"].create({
            "employee_id": int(data["employee_id"]),
            "holiday_status_id": int(data["holiday_status_id"]),
            "date_from": data["date_from"],
            "date_to": data["date_to"],
            "name": data.get("name") or "Demande via API",
        })
        return _json({
            "id": leave.id,
            "state": leave.state,
            "number_of_days": leave.number_of_days,
        }, status=201)

    # =====================================================================
    #  Présences (hr_attendance)
    # =====================================================================
    @http.route(f"{API}/attendances", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def attendances(self, **kw):
        if "hr.attendance" not in request.env:
            return _error("Module Présences (hr_attendance) non installé", 501)
        limit, offset = _paging(kw)
        domain = []
        if kw.get("employee_id"):
            domain.append(("employee_id", "=", int(kw["employee_id"])))
        if kw.get("date_from"):
            domain.append(("check_in", ">=", kw["date_from"]))
        if kw.get("date_to"):
            domain.append(("check_in", "<=", kw["date_to"]))
        Att = request.env["hr.attendance"]
        total = Att.search_count(domain)
        recs = Att.search(domain, limit=limit, offset=offset, order="check_in desc")
        results = [{
            "id": a.id,
            "employee": a.employee_id.name or None,
            "employee_id": a.employee_id.id or None,
            "check_in": str(a.check_in) if a.check_in else None,
            "check_out": str(a.check_out) if a.check_out else None,
            "worked_hours": a.worked_hours,
        } for a in recs]
        return _json({"count": total, "limit": limit, "offset": offset, "results": results})

    # =====================================================================
    #  Tableau de bord (si module kaydan_hr_dashboard installé)
    # =====================================================================
    @http.route(f"{API}/dashboard", type="http", auth="public", methods=["GET"], csrf=False, save_session=False)
    @api_endpoint()
    def dashboard(self, **kw):
        Employee = request.env["hr.employee"]
        if not hasattr(Employee, "get_kaydan_dashboard_data"):
            return _error("Module Tableau de bord (kaydan_hr_dashboard) non installé", 501)
        company_id = int(kw["company_id"]) if kw.get("company_id") else None
        return _json(Employee.get_kaydan_dashboard_data(company_id))
