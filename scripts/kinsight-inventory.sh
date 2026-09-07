#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASE 6 : inventaire RÉEL des modèles RH exposés par l'API
# -----------------------------------------------------------------------------
#  N'invente RIEN : interroge la base vivante via l'API JSON-2 d'Odoo 19.
#  Fonctionne avec la clé K-Insight (droits minimaux) :
#    · ir.module.module/search_read → modules réellement installés
#    · <modèle>/fields_get          → existence + champs/types/relations
#    · <modèle>/search_count        → les DONNÉES sont-elles lisibles ?
#  Sources complémentaires, seulement si la clé fournie est ADMIN :
#    · /doc-bearer/index.json  (groupe api_doc.group_allow_doc requis)
#    · ir.model / ir.model.fields (groupe base.group_erp_manager requis)
#  L'absence de ces droits n'est PAS une erreur : le rapport le signale.
#
#  Usage :
#     export KINSIGHT_URL="https://rh-test.kaydan.tech"
#     export KINSIGHT_KEY="<clé API>"
#     bash scripts/kinsight-inventory.sh [dossier_sortie]
# =============================================================================
set -uo pipefail

URL="${KINSIGHT_URL:?export KINSIGHT_URL=https://rh-test.kaydan.tech}"
KEY="${KINSIGHT_KEY:?export KINSIGHT_KEY=<clé API>}"
URL="${URL%/}"
OUT="${1:-inventaire-kinsight-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

post() { # $1 = chemin ; $2 = corps JSON
  curl -sS -X POST "${URL}$1" \
    -H "Authorization: bearer ${KEY}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "User-Agent: kaydan-kinsight-inventory/1.0" \
    -d "$2" 2>/dev/null
}
call() { post "/json/2/$1/$2" "$3"; }

echo "═══ Inventaire RH réel — ${URL} ═══"

# 0. L'API répond-elle ?
probe="$(call ir.module.module search_count '{"domain": [["state","=","installed"]]}')"
case "$probe" in
  ''|*'"name"'*) echo "⛔ /json/2 inaccessible ou clé refusée. Réponse : ${probe:0:220}"; exit 1 ;;
  *[!0-9]*)      echo "⛔ Réponse inattendue : ${probe:0:220}"; exit 1 ;;
esac
echo "   ✓ API JSON-2 joignable · ${probe} modules installés"

# 1. Modules installés
call ir.module.module search_read \
  '{"domain": [["state","=","installed"]], "fields": ["name","shortdesc","latest_version"], "limit": 0, "order": "name"}' \
  > "${OUT}/modules-installes.json"

# 2. Sources ADMIN (facultatives)
post /doc-bearer/index.json '{}' > "${OUT}/doc-index.json" 2>/dev/null
grep -q '"models"' "${OUT}/doc-index.json" 2>/dev/null \
  && echo "   ✓ /doc accessible (clé avec api_doc.group_allow_doc)" \
  || echo "   — /doc non accessible avec cette clé (normal pour la clé K-Insight)"

# 3. Modèles cibles : existence, champs, lisibilité des données
TARGETS="hr.employee hr.employee.public hr.department hr.job hr.version hr.contract.type \
hr.leave hr.leave.type hr.leave.allocation hr.applicant hr.recruitment.stage \
hr.skill hr.skill.type hr.resume.line hr.attendance hr.expense hr.employee.category \
hr.departure.reason hr.work.location hr.employee.transfer res.company res.users"

: > "${OUT}/etat-modeles.csv"; echo "modele,present,donnees_lisibles,nb_enregistrements" >> "${OUT}/etat-modeles.csv"
for m in $TARGETS; do
  fg="$(call "$m" fields_get '{"attributes": ["string","type","relation","required","store","groups","readonly"]}')"
  case "$fg" in
    *'does not exist'*) echo "   — ${m} : ABSENT de cette base"; echo "${m},non,-,-" >> "${OUT}/etat-modeles.csv"; continue ;;
    ''|*'"name": "werkzeug'*|*'AccessError'*) echo "   ⚠ ${m} : métadonnées refusées"; echo "${m},?,non,-" >> "${OUT}/etat-modeles.csv"; continue ;;
  esac
  printf '%s' "$fg" > "${OUT}/champs-${m}.json"
  cnt="$(call "$m" search_count '{"domain": []}')"
  case "$cnt" in
    ''|*[!0-9]*) echo "   ✓ ${m} : présent · données NON lisibles (droits)"; echo "${m},oui,non,-" >> "${OUT}/etat-modeles.csv" ;;
    *)           echo "   ✓ ${m} : présent · ${cnt} enregistrement(s) lisibles"; echo "${m},oui,oui,${cnt}" >> "${OUT}/etat-modeles.csv" ;;
  esac
done

# 4. Rapport lisible
KINSIGHT_URL="$URL" python3 - "$OUT" <<'PY'
import json, os, sys, csv, datetime
out = sys.argv[1]
def load(p, default=None):
    try:
        with open(os.path.join(out, p)) as f: return json.load(f)
    except Exception: return default if default is not None else []

mods = load('modules-installes.json')
doc  = load('doc-index.json', {})
doc_models = {m['model']: m for m in (doc.get('models') or []) if isinstance(m, dict)}
state = list(csv.DictReader(open(os.path.join(out, 'etat-modeles.csv'))))
present = [r['modele'] for r in state if r['present'] == 'oui']
readable = {r['modele']: r for r in state if r['donnees_lisibles'] == 'oui'}
installed = {m['name'] for m in mods if isinstance(m, dict)}

FAMILIES = [
    ("RH CORE",     ["hr"],                                 ["hr.employee","hr.employee.public","hr.department","hr.job","hr.version","hr.contract.type","hr.employee.category","hr.departure.reason","hr.work.location"]),
    ("CONGÉS",      ["hr_holidays"],                        ["hr.leave","hr.leave.type","hr.leave.allocation"]),
    ("RECRUTEMENT", ["hr_recruitment"],                     ["hr.applicant","hr.job","hr.recruitment.stage"]),
    ("PAIE",        ["hr_payroll","om_hr_payroll"],         []),
    ("PERFORMANCE", ["hr_appraisal"],                       []),
    ("COMPÉTENCES", ["hr_skills"],                          ["hr.skill","hr.skill.type","hr.resume.line"]),
    ("FORMATION",   ["slides","hr_skills_slides","survey"], []),
    ("PRÉSENCES",   ["hr_attendance"],                      ["hr.attendance"]),
    ("FRAIS",       ["hr_expense"],                         ["hr.expense"]),
    ("KAYDAN",      ["kaydan_hr","kaydan_kinsight","kaydan_hr_dashboard","kaydan_api"], ["hr.employee.transfer"]),
]
SENSITIVE = {'wage','contract_wage','cnps_number','ssnid','identification_id','passport_id',
             'bank_account_id','private_street','private_email','private_phone','birthday',
             'place_of_birth','spouse_complete_name','children','marital','km_home_work',
             'pin','barcode','password','emergency_contact','emergency_phone'}
USEFUL = {'name','matricule','display_name','active','department_id','job_id','job_title',
          'company_id','company_ids','parent_id','coach_id','work_email','work_phone',
          'employee_type','state','request_date_from','request_date_to','number_of_days',
          'holiday_status_id','employee_id','contract_type_id','total_employee','stage_id',
          'partner_name','hire_date','seniority','departure_date','departure_reason_id',
          'manager_id','no_of_recruitment','date','to_company_id','from_company_id'}

L = ["# Inventaire RÉEL des APIs RH — Kaydan ERP\n",
     f"Source : `{os.environ.get('KINSIGHT_URL','?')}` · relevé le {datetime.datetime.now():%Y-%m-%d %H:%M}\n",
     "API : **POST `/json/2/<modèle>/<méthode>`** (en-tête `Authorization: bearer`)\n",
     f"- Modules installés : **{len(mods)}**",
     f"- Modèles cibles présents : **{len(present)}** · dont données lisibles avec cette clé : **{len(readable)}**",
     f"- Modèles décrits par /doc : **{len(doc_models) if doc_models else '— (droit api_doc.group_allow_doc absent)'}**\n",
     "## Disponibilité par famille fonctionnelle\n",
     "| Famille | Module(s) requis | Installé ? | Modèles présents |", "|---|---|---|---|"]
for fam, req, models_ in FAMILIES:
    got = [r for r in req if r in installed]
    gm = [m for m in models_ if m in present]
    L.append(f"| {fam} | {', '.join(req)} | {'✅ ' + ', '.join(got) if got else '❌ absent'} | {', '.join(gm) if gm else '—'} |")
L.append("")
L.append("## Détail par modèle\n")
for r in state:
    m = r['modele']
    if r['present'] != 'oui':
        continue
    fields = load(f'champs-{m}.json', {})
    if not isinstance(fields, dict): fields = {}
    docm = doc_models.get(m, {})
    rels = {k: v for k, v in fields.items() if v.get('type') in ('many2one','one2many','many2many')}
    company = 'company_id' if 'company_id' in fields else ('company_ids' if 'company_ids' in fields else None)
    sens = sorted(set(fields) & SENSITIVE)
    restricted = sorted(k for k, v in fields.items() if v.get('groups'))
    L.append(f"### `{m}`" + (f" — {docm['name']}" if docm.get('name') else "") + "\n")
    L.append(f"- **Champs** : {len(fields)} · **relations** : {len(rels)}")
    L.append(f"- **Données lisibles avec cette clé** : "
             + (f"oui ({r['nb_enregistrements']} enregistrement(s))" if r['donnees_lisibles'] == 'oui' else "**non** (droits insuffisants)"))
    L.append(f"- **Filiale** : {'`'+company+'`' if company else '⚠ aucun champ société'}")
    if docm.get('methods'):
        L.append(f"- **Méthodes JSON-2 publiques** : {len(docm['methods'])} (ex. {', '.join(sorted(docm['methods'])[:8])}…)")
    else:
        L.append("- **Méthodes JSON-2** : publiques uniquement — `search_read`, `read`, `search_count`, `fields_get`, `read_group`")
    if sens:       L.append(f"- 🔒 **Champs sensibles présents** : `{'`, `'.join(sens)}`")
    if restricted: L.append(f"- Champs à accès restreint par groupe : **{len(restricted)}**")
    keys = sorted(set(fields) & USEFUL)
    if keys:
        L.append("\n| Champ | Libellé | Type | Relation |")
        L.append("|---|---|---|---|")
        for k in keys:
            f = fields[k]
            L.append(f"| `{k}` | {f.get('string','')} | {f.get('type','')} | "
                     f"{('`'+f['relation']+'`') if f.get('relation') else ''} |")
    L.append("")
absent = [r['modele'] for r in state if r['present'] == 'non']
L.append("## Modèles cibles ABSENTS de cette base\n")
L.append(("- " + "\n- ".join(f"`{m}`" for m in absent)) if absent else "_aucun_")
open(os.path.join(out, 'INVENTAIRE-KINSIGHT.md'), 'w').write("\n".join(L) + "\n")
print(f"   ✓ rapport : {out}/INVENTAIRE-KINSIGHT.md  ({len(present)} présents, {len(absent)} absents)")
PY

echo "──────────────────────────────────────────────────────────"
echo " Inventaire terminé → ${OUT}/"
echo "   INVENTAIRE-KINSIGHT.md · etat-modeles.csv · modules-installes.json · champs-<modèle>.json"
echo "──────────────────────────────────────────────────────────"
