#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASES 5 & 7 : test de l'API JSON-2 d'Odoo 19 pour K-Insight
# -----------------------------------------------------------------------------
#  API NATIVE Odoo 19 (aucune route maison) :
#     POST https://<hôte>/json/2/<modèle>/<méthode>
#     Authorization: bearer <CLÉ_API>          Content-Type: application/json
#     Corps : {"ids": [...], "context": {...}, "<param>": ...}
#  Documentation vivante de la base : https://<hôte>/doc  (JSON : /doc-bearer/index.json)
#
#  Seules les méthodes PUBLIQUES sont appelables (Odoo refuse tout `_prefixe`
#  et tout @api.private) → search_read / read / search_count / fields_get / …
#
#  Usage :
#     export KINSIGHT_URL="https://rh-test.kaydan.tech"     # staging, puis prod
#     export KINSIGHT_KEY="<clé API de l'utilisateur kinsight>"
#     bash scripts/kinsight-api-test.sh
#
#  ⚠ La clé API se crée dans l'UI : se connecter en tant que 'kinsight'
#    → Préférences → Sécurité du compte → Nouvelle clé API (durée ≤ 3 mois).
#    Ne JAMAIS committer la clé ni l'exposer côté navigateur (backend seulement).
# =============================================================================
set -uo pipefail

URL="${KINSIGHT_URL:?export KINSIGHT_URL=https://rh-test.kaydan.tech}"
KEY="${KINSIGHT_KEY:?export KINSIGHT_KEY=<clé API>}"
URL="${URL%/}"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# call <modèle> <méthode> <json_corps>  -> écrit le corps dans $TMP/out, renvoie le code HTTP
call() {
  curl -sS -o "$TMP/out" -w '%{http_code}' -X POST \
    "${URL}/json/2/$1/$2" \
    -H "Authorization: bearer ${KEY}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "User-Agent: kaydan-kinsight-test/1.0" \
    -d "$3" 2>/dev/null
}
jq_py() { python3 -c "import json,sys; d=json.load(open('$TMP/out')); print($1)" 2>/dev/null || echo "?"; }
ok()   { echo "   ✓ $1"; PASS=$((PASS+1)); }
no()   { echo "   ✗ $1"; FAIL=$((FAIL+1)); }

echo "═══ Test API JSON-2 — ${URL} ═══"

# ── 0. La route existe-t-elle (Odoo 19 requis) ? ────────────────────────────
echo "── 0. Disponibilité de JSON-2"
code="$(call res.users search_count '{"domain": []}')"
if [ "$code" = "404" ]; then
  echo "   ⛔ /json/2 introuvable : l'instance n'est PAS en Odoo 19 (ou le module 'rpc' est absent)."
  echo "      Sur Odoo 18, utiliser l'API existante /api/v1/hr (module kaydan_api) ou XML-RPC."
  exit 1
fi
[ "$code" = "200" ] && ok "route /json/2 opérationnelle (HTTP 200)" || no "réponse inattendue : HTTP ${code} — $(head -c 200 "$TMP/out")"

# ── 1. Identité de la clé (res.users) ───────────────────────────────────────
echo "── 1. Identité de la clé API"
code="$(call res.users search_read '{"domain": [["login","=","kinsight@kaydangroupe.com"]], "fields": ["name","login","company_id","company_ids"], "limit": 1}')"
if [ "$code" = "200" ]; then
  ok "identité lisible : $(jq_py "d[0]['login'] if d else 'aucun résultat'") · société=$(jq_py "d[0]['company_id'][1] if d and d[0].get('company_id') else '?'")"
  echo "      sociétés autorisées : $(jq_py "len(d[0].get('company_ids',[])) if d else 0")"
else no "lecture res.users impossible : HTTP ${code}"; fi

# ── 2. hr.employee search_read ──────────────────────────────────────────────
echo "── 2. hr.employee (référentiel employés)"
code="$(call hr.employee search_read '{"domain": [], "fields": ["name","matricule","department_id","job_id","company_id","work_email","employee_type","parent_id"], "limit": 5, "order": "name"}')"
if [ "$code" = "200" ]; then
  ok "search_read OK — $(jq_py 'len(d)') enregistrement(s) ; champs renvoyés : $(jq_py "', '.join(sorted(d[0].keys())) if d else '—'")"
  echo "      exemple : $(jq_py "d[0].get('name','?') + ' / ' + str(d[0].get('matricule')) if d else '—'")"
else no "hr.employee search_read : HTTP ${code} — $(head -c 200 "$TMP/out")"; fi

code="$(call hr.employee search_count '{"domain": [["active","=",true]]}')"
[ "$code" = "200" ] && ok "search_count OK — effectif actif = $(cat "$TMP/out")" || no "search_count : HTTP ${code}"

# ── 3. hr.department / hr.job ───────────────────────────────────────────────
echo "── 3. Départements et postes"
code="$(call hr.department search_read '{"domain": [], "fields": ["name","company_id","manager_id","parent_id","total_employee"], "limit": 100}')"
[ "$code" = "200" ] && ok "hr.department : $(jq_py 'len(d)') département(s)" || no "hr.department : HTTP ${code}"
code="$(call hr.job search_read '{"domain": [], "fields": ["name","department_id","company_id","no_of_recruitment"], "limit": 100}')"
[ "$code" = "200" ] && ok "hr.job : $(jq_py 'len(d)') poste(s)" || no "hr.job : HTTP ${code}"

# ── 4. company_id : présence et filtrage par filiale ────────────────────────
echo "── 4. Multi-filiales (company_id)"
code="$(call res.company search_read '{"domain": [], "fields": ["name"], "limit": 50}')"
if [ "$code" = "200" ]; then
  NC="$(jq_py 'len(d)')"; CID="$(jq_py "d[0]['id'] if d else 0")"
  ok "res.company : ${NC} société(s) visible(s)"
  code="$(call hr.employee search_count "{\"domain\": [[\"company_id\",\"=\",${CID}]]}")"
  [ "$code" = "200" ] && ok "filtre par filiale (company_id=${CID}) : $(cat "$TMP/out") employé(s)" || no "filtre company_id : HTTP ${code}"
  # Filtrage par contexte allowed_company_ids (comportement multi-société d'Odoo)
  code="$(call hr.employee search_count "{\"context\": {\"allowed_company_ids\": [${CID}]}, \"domain\": []}")"
  [ "$code" = "200" ] && ok "contexte allowed_company_ids respecté : $(cat "$TMP/out") employé(s)" || no "contexte société : HTTP ${code}"
else no "res.company : HTTP ${code}"; fi

# ── 5. Pagination ───────────────────────────────────────────────────────────
echo "── 5. Pagination (limit / offset)"
code="$(call hr.employee search_read '{"domain": [], "fields": ["id","name"], "limit": 2, "offset": 0, "order": "id"}')"
P1="$(jq_py "[r['id'] for r in d]")"
code2="$(call hr.employee search_read '{"domain": [], "fields": ["id","name"], "limit": 2, "offset": 2, "order": "id"}')"
P2="$(jq_py "[r['id'] for r in d]")"
if [ "$code" = "200" ] && [ "$code2" = "200" ] && [ "$P1" != "$P2" ]; then ok "pagination fonctionnelle (page1=${P1} · page2=${P2})"
else no "pagination : page1=${P1} page2=${P2} (HTTP ${code}/${code2})"; fi

# ── 6. Congés (agrégats) ────────────────────────────────────────────────────
echo "── 6. Congés"
code="$(call hr.leave.type search_read '{"domain": [], "fields": ["name","requires_allocation"], "limit": 50}')"
[ "$code" = "200" ] && ok "hr.leave.type : $(jq_py 'len(d)') type(s)" || no "hr.leave.type : HTTP ${code}"
code="$(call hr.leave search_read '{"domain": [["state","=","validate"]], "fields": ["employee_id","holiday_status_id","request_date_from","request_date_to","number_of_days","state"], "limit": 5}')"
[ "$code" = "200" ] && ok "hr.leave (validés) : $(jq_py 'len(d)') ligne(s)" || no "hr.leave : HTTP ${code}"

# ── 7. TESTS NÉGATIFS — le moindre privilège est-il réellement appliqué ? ───
echo "── 7. Tests négatifs (doivent ÉCHOUER côté serveur)"
code="$(call hr.employee write '{"ids": [1], "vals": {"name": "PIRATAGE-TEST"}}')"
if [ "$code" = "200" ]; then no "ÉCRITURE ACCEPTÉE sur hr.employee — droits trop larges, corriger !"
else ok "écriture refusée (HTTP ${code}) — lecture seule confirmée"; fi

code="$(call hr.version search_read '{"domain": [], "fields": ["wage"], "limit": 1}')"
if [ "$code" = "200" ] && [ "$(jq_py "('wage' in d[0]) if d else False")" = "True" ]; then
  no "SALAIRES LISIBLES (hr.version.wage) — retirer cet accès immédiatement !"
else ok "salaires inaccessibles (HTTP ${code}) — protection au niveau champ effective"; fi

code="$(call hr.version search_read '{"domain": [], "fields": ["contract_type_id","contract_date_end"], "limit": 1}')"
if [ "$code" = "200" ] && [ "$(jq_py "('contract_type_id' in d[0]) if d else False")" = "True" ]; then
  no "données de CONTRAT lisibles — réservées à hr.group_hr_manager"
else ok "contrats inaccessibles (HTTP ${code}) — conforme"; fi

# Positif : les champs DÉLÉGUÉS doivent bien être lisibles (dept/poste)
code="$(call hr.employee search_read '{"domain": [], "fields": ["name","department_id","job_id","job_title","employee_type"], "limit": 1}')"
if [ "$code" = "200" ] && [ "$(jq_py "('department_id' in d[0]) if d else False")" = "True" ]; then
  ok "champs délégués (department_id/job_id via hr.version) lisibles — mapping K-Insight opérationnel"
else no "champs délégués illisibles (HTTP ${code}) — vérifier l'ACL de lecture sur hr.version"; fi

code="$(call hr.employee search_read '{"domain": [], "fields": ["cnps_number"], "limit": 1}')"
CN="$(jq_py "('cnps_number' in d[0]) if d else False")"
if [ "$code" = "200" ] && [ "$CN" = "True" ]; then no "CNPS lisible — donnée sensible exposée !"
else ok "numéro CNPS non exposé — conforme"; fi

# Odoo renvoie la clé `password` mais TOUJOURS vide : l'échec n'est réel que
# si une valeur non vide sort.
code="$(call res.users search_read '{"domain": [], "fields": ["password"], "limit": 1}')"
if [ "$code" = "200" ] && [ "$(jq_py "bool(d[0].get('password')) if d else False")" = "True" ]; then
  no "MOT DE PASSE exposé — incident de sécurité !"
else ok "aucune valeur de mot de passe exposée — conforme"; fi

code="$(call hr.employee _read_group '{"domain": [], "groupby": ["department_id"]}')"
if [ "$code" = "200" ]; then no "méthode privée _read_group appelable — anormal"
else ok "méthodes privées refusées (HTTP ${code}) — conforme au contrat JSON-2"; fi

# ── 8. Documentation vivante /doc ───────────────────────────────────────────
echo "── 8. Documentation de la base (/doc-bearer/index.json)"
dcode="$(curl -sS -o "$TMP/out" -w '%{http_code}' -X POST "${URL}/doc-bearer/index.json" \
  -H "Authorization: bearer ${KEY}" -H "Content-Type: application/json" -d '{}' 2>/dev/null)"
case "$dcode" in
  200) ok "index /doc lisible : $(jq_py "len(d.get('models',[]))") modèle(s), $(jq_py "len(d.get('modules',[]))") module(s)" ;;
  403) ok "/doc réservé au groupe api_doc.group_allow_doc (HTTP 403 attendu : non accordé à K-Insight par moindre privilège ; l'inventaire passe par ir.model)" ;;
  *)   no "/doc-bearer/index.json : HTTP ${dcode}" ;;
esac

echo "──────────────────────────────────────────────────────────"
echo " Résultat : ${PASS} test(s) OK · ${FAIL} en échec"
[ "$FAIL" -eq 0 ] && echo " ✅ API JSON-2 conforme et en lecture seule." \
                  || echo " ⚠ Voir les lignes ✗ ci-dessus."
echo "──────────────────────────────────────────────────────────"
exit "$FAIL"
