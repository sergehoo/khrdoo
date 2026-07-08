# -*- coding: utf-8 -*-
import logging
import random
from datetime import date, datetime, timedelta

from dateutil.relativedelta import relativedelta

_logger = logging.getLogger(__name__)

FIRST_M = ["Kouadio", "Yao", "Koffi", "Adama", "Ibrahim", "Serge", "Jean", "Marc",
           "Paul", "Éric", "Olivier", "Hervé", "Aboubacar", "Désiré"]
FIRST_F = ["Awa", "Aminata", "Fatou", "Marie", "Adjoua", "Akissi", "Nadia", "Sandra",
           "Clarisse", "Aya", "Rokia", "Mariam", "Estelle", "Bintou"]
LAST = ["Koné", "Traoré", "Diabaté", "N'Guessan", "Bamba", "Ouattara", "Touré", "Yapo",
        "Kouassi", "Doumbia", "Cissé", "Aka", "Brou", "Gnamien", "Konaté"]
DEPTS = ["Direction Générale", "Ressources Humaines", "Commercial",
         "Technique", "Finance & Comptabilité"]
JOBS = ["Chargé(e) de mission", "Responsable d'équipe", "Technicien(ne)", "Comptable",
        "Commercial(e)", "Assistant(e)", "Manager", "Analyste"]
ETYPES = ["employee", "employee", "employee", "employee", "contractor", "student", "trainee"]


def post_init_hook(env):
    """Point d'entrée : idempotent + garde-fou (ne fait JAMAIS échouer l'install)."""
    param = env["ir.config_parameter"].sudo()
    if param.get_param("kaydan_hr_demo.loaded") == "1":
        _logger.info("Kaydan HR demo : déjà chargé, ignoré.")
        return
    try:
        count = _generate(env)
        param.set_param("kaydan_hr_demo.loaded", "1")
        _logger.info("Kaydan HR demo : %d employés générés.", count)
    except Exception as e:  # noqa: BLE001 - démo : ne jamais bloquer l'installation
        _logger.error("Kaydan HR demo : génération échouée (install non bloquée) : %s", e, exc_info=True)


def _generate(env):
    random.seed(42)
    today = date.today()
    company = env.company
    Employee = env["hr.employee"].sudo()
    Dept = env["hr.department"].sudo()
    Category = env["hr.employee.category"].sudo()

    demo_tag = Category.search([("name", "=", "DÉMO")], limit=1) or Category.create({"name": "DÉMO"})

    # --- Départements ----------------------------------------------------
    depts = []
    for n in DEPTS:
        d = Dept.search([("name", "=", n), ("company_id", "=", company.id)], limit=1) \
            or Dept.create({"name": n, "company_id": company.id})
        depts.append(d)

    # --- Types de contrat ------------------------------------------------
    CT = env["hr.contract.type"].sudo()
    ctypes = {}
    for n in ["CDI", "CDD", "Stage", "Consultant"]:
        ctypes[n] = CT.search([("name", "=", n)], limit=1) or CT.create({"name": n})

    # --- Employés (création + back-dating de create_date) ----------------
    created = []
    for _i in range(32):
        g = random.choice(["male", "female"])
        fn = random.choice(FIRST_M if g == "male" else FIRST_F)
        ln = random.choice(LAST)
        slug = (fn + "." + ln).lower().replace(" ", "").replace("'", "").replace("é", "e")
        emp = Employee.create({
            "name": "%s %s" % (fn, ln),
            "gender": g,
            "department_id": random.choice(depts).id,
            "employee_type": random.choice(ETYPES),
            "job_title": random.choice(JOBS),
            "work_email": "%s@kaydan.tech" % slug,
            "company_id": company.id,
            "category_ids": [(4, demo_tag.id)],
        })
        created.append(emp)
        months_ago = random.randint(0, 14)
        cdate = datetime.combine(
            today - relativedelta(months=months_ago) - timedelta(days=random.randint(0, 27)),
            datetime.min.time(),
        )
        env.cr.execute("UPDATE hr_employee SET create_date=%s WHERE id=%s", (cdate, emp.id))

    # --- Contrats en cours (≈24 employés) --------------------------------
    Contract = env["hr.contract"].sudo()
    pick = [ctypes["CDI"], ctypes["CDI"], ctypes["CDI"], ctypes["CDD"], ctypes["Stage"], ctypes["Consultant"]]
    for emp in created[:24]:
        try:
            Contract.create({
                "name": "Contrat — %s" % emp.name,
                "employee_id": emp.id,
                "contract_type_id": random.choice(pick).id,
                "date_start": today - relativedelta(months=random.randint(1, 12)),
                "wage": float(random.choice([150000, 200000, 300000, 450000, 600000])),
                "state": "open",
            })
        except Exception as e:  # noqa: BLE001
            _logger.warning("Demo contrat (%s) ignoré : %s", emp.name, e)

    # --- Congés validés (top congés) -------------------------------------
    # Odoo 18 : pas de action_confirm ; state défaut 'confirm' ; pour un type
    # 'no_validation', action_validate() valide directement.
    LeaveType = env["hr.leave.type"].sudo()
    lt = LeaveType.search([("requires_allocation", "=", "no")], limit=1) or LeaveType.create({
        "name": "Congé (démo)",
        "requires_allocation": "no",
        "leave_validation_type": "no_validation",
        "request_unit": "day",
    })
    Leave = env["hr.leave"].sudo()
    for emp in random.sample(created, min(12, len(created))):
        start = today - relativedelta(months=random.randint(0, 5)) - timedelta(days=random.randint(0, 20))
        length = random.randint(1, 5)
        try:
            lv = Leave.create({
                "name": "Congé démo",
                "employee_id": emp.id,
                "holiday_status_id": lt.id,
                "request_date_from": start,
                "request_date_to": start + timedelta(days=length - 1),
            })
            lv.action_validate()
        except Exception as e:  # noqa: BLE001
            _logger.warning("Demo congé (%s) ignoré : %s", emp.name, e)

    # --- Départs avec motif (top départs, 12 mois) -----------------------
    reasons = []
    for ref in ["hr.departure_resigned", "hr.departure_fired", "hr.departure_retired"]:
        r = env.ref(ref, raise_if_not_found=False)
        if r:
            reasons.append(r)
    if not reasons:
        reasons = [env["hr.departure.reason"].sudo().create({"name": "Démission"})]
    for emp in created[-5:]:
        try:
            emp.write({
                "departure_reason_id": random.choice(reasons).id,
                "departure_date": today - relativedelta(months=random.randint(1, 11)),
                "active": False,
            })
        except Exception as e:  # noqa: BLE001
            _logger.warning("Demo départ (%s) ignoré : %s", emp.name, e)

    return len(created)
