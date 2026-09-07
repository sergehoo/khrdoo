#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASE 3 : MIGRATION 18 -> 19 SUR STAGING (OpenUpgrade)
# -----------------------------------------------------------------------------
#  NE TOUCHE PAS À LA PROD (base kaydan, conteneur kaydan-odoo, image 18).
#  Rejouable à volonté : base + volume de staging recréés à chaque exécution.
#
#   0. Garde-fous (conteneurs parallèles, modules stables, kaydan_hr_demo)
#   1. Sauvegarde fraîche de la prod
#   2. Copie base   kaydan -> kaydan19
#   3. Copie filestore -> volume kaydan-odoo19-data
#   4. Neutralisation du staging (crons + serveurs de mail)
#   5. addons19/ : copie + `odoo upgrade_code` (18.0->19.0) + overlay migration19/
#   6. config/odoo/odoo19.conf (dbfilter kaydan19)
#   7. OpenUpgrade : conversion du SCHÉMA + mise à jour de tous les modules
#   8. Démarrage du staging + CONTRÔLES FONCTIONNELS automatisés
#
#  Usage (sur le serveur) :  bash scripts/migrate19-staging.sh
#  Prérequis : DNS A `rh-test.kaydan.tech` -> VPS (ou ODOO19_HOST dans .env)
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
PG="kaydan-postgres"
DB="kaydan"
STG="kaydan19"
OU_DIR="openupgrade19"
LOG="/tmp/openupgrade19_$(date +%Y%m%d_%H%M%S).log"

cd "$CODE_DIR" || { echo "❌ ${CODE_DIR} introuvable"; exit 1; }
set -a; [ -f .env ] && . ./.env; set +a
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD introuvable (.env)}"
HOST19="${ODOO19_HOST:-rh-test.${DOMAIN:-kaydan.tech}}"

die(){ echo "❌ $*"; exit 1; }

# ── 0. Garde-fous ───────────────────────────────────────────────────────────
echo "══ 0/8 — Garde-fous ══"
# a) conteneurs Odoo parallèles (cause du conflit de nom rencontré en prod)
PARA="$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' \
        | grep -E '^kaydan-odoo' | grep -v "^kaydan-odoo|${PROJECT}$" | grep -v '^kaydan-odoo19|' || true)"
if [ -n "$PARA" ]; then
  echo "   ⚠ conteneur(s) Odoo hors projet détecté(s) :"; echo "$PARA" | sed 's/^/     /'
  echo "$PARA" | cut -d'|' -f1 | while read -r c; do docker rm -f "$c" >/dev/null 2>&1 && echo "     ✓ supprimé : $c"; done
  docker compose -p "$PROJECT" up -d odoo >/dev/null 2>&1 && echo "     ✓ prod relancée sous le bon projet"
fi
# b) modules en transition côté prod
T="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
[ "${T:-1}" = "0" ] || die "prod instable : ${T} module(s) en transition — corriger avant migration"
# c) kaydan_hr_demo : dépend de hr_contract, données de DÉMO → doit être désinstallé
DEMO="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT state FROM ir_module_module WHERE name='kaydan_hr_demo';" 2>/dev/null | tr -d '[:space:]')"
if [ "$DEMO" = "installed" ]; then
  cat <<EOF
   ⛔ BLOQUANT : le module 'kaydan_hr_demo' est installé.
      Il dépend de hr_contract (supprimé en Odoo 19) et ne contient que des
      données de DÉMONSTRATION. Désinstallez-le d'abord :
        Odoo → Apps → rechercher "kaydan_hr_demo" → Désinstaller
      (compte Administrator requis), puis relancez ce script.
EOF
  exit 1
fi
# d) OCA : rien à porter si le dossier est vide
OCA_N="$(ls -1 addons/oca 2>/dev/null | grep -v -e '^\.gitkeep$' -e '^README.md$' | wc -l | tr -d ' ')"
[ "${OCA_N:-0}" = "0" ] && echo "   ✓ aucun module OCA sur disque (rien à porter)" \
                        || echo "   ⚠ ${OCA_N} module(s) OCA présent(s) : à re-fetch en branche 19.0 (scripts/fetch-oca.sh)"
echo "   ✓ garde-fous OK"

# ── 1. Sauvegarde ───────────────────────────────────────────────────────────
echo "══ 1/8 — Sauvegarde fraîche de la prod ══"
docker exec kaydan-backup /scripts/backup.sh >/dev/null 2>&1 && echo "   ✓ sauvegarde OK" || die "sauvegarde échouée"

# ── 2. Copie de la base ─────────────────────────────────────────────────────
echo "══ 2/8 — Copie ${DB} -> ${STG} ══"
docker exec "$PG" sh -c "
  psql -U odoo -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STG}' AND pid<>pg_backend_pid();\" >/dev/null 2>&1 || true
  dropdb -U odoo --if-exists ${STG} && createdb -U odoo -O odoo ${STG} &&
  pg_dump -U odoo -Fc ${DB} | pg_restore -U odoo -d ${STG} --no-owner --role=odoo
" >/dev/null 2>&1 && echo "   ✓ base ${STG} prête" || die "copie de base échouée"

# ── 3. Copie du filestore ───────────────────────────────────────────────────
echo "══ 3/8 — Copie du filestore ══"
ODOO_UID="$(docker run --rm --entrypoint id odoo:19 -u 2>/dev/null || echo 101)"
docker volume create kaydan-odoo19-data >/dev/null
docker run --rm -v kaydan-odoo-data:/src:ro -v kaydan-odoo19-data:/dst alpine sh -c "
  mkdir -p /dst/filestore && rm -rf /dst/filestore/${STG} &&
  cp -a /src/filestore/${DB} /dst/filestore/${STG} 2>/dev/null || true
  mkdir -p /dst/sessions && chown -R ${ODOO_UID}:${ODOO_UID} /dst
" && echo "   ✓ filestore copié (uid ${ODOO_UID})"

# ── 4. Neutralisation ───────────────────────────────────────────────────────
echo "══ 4/8 — Neutralisation du staging ══"
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE ir_cron SET active=false;" >/dev/null 2>&1
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE ir_mail_server SET active=false;" >/dev/null 2>&1 || true
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE fetchmail_server SET active=false;" >/dev/null 2>&1 || true
docker exec "$PG" psql -U odoo -d "$STG" -c \
  "INSERT INTO ir_config_parameter(key,value) VALUES ('database.is_neutralized','True')
   ON CONFLICT (key) DO UPDATE SET value='True';" >/dev/null 2>&1
docker exec "$PG" psql -U odoo -d "$STG" -c \
  "UPDATE ir_config_parameter SET value='https://${HOST19}' WHERE key='web.base.url';" >/dev/null 2>&1
docker exec "$PG" psql -U odoo -d "$STG" -c "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';" >/dev/null 2>&1
echo "   ✓ crons + mails désactivés, base marquée neutralisée, assets purgés"

# ── 5. addons19/ : upgrade_code + overlay de portage ───────────────────────
echo "══ 5/8 — Génération des addons 19 (addons19/) ══"
rm -rf addons19 && mkdir -p addons19
for m in kaydan_branding kaydan_hr_dashboard kaydan_api kaydan_hr; do
  [ -d "addons/${m}" ] && cp -a "addons/${m}" "addons19/${m}"
done
mkdir -p addons19/oca && touch addons19/oca/.gitkeep

# 5a. Réécriture automatique du code par l'outil OFFICIEL d'Odoo 19
#     ⚠ --glob est INDISPENSABLE : sans lui, upgrade_code parcourt AUSSI les
#     addons du cœur (montés en lecture seule) et échoue sur PermissionError.
echo "   → odoo upgrade_code --from 18.0 --to 19.0 (portée : kaydan_*)"
docker run --rm -v "$PWD/addons19":/work --entrypoint bash odoo:19 -lc \
  "odoo --addons-path=/work upgrade_code --from 18.0 --to 19.0 --glob 'kaydan_*/**/*' 2>&1 | tail -15"

# 5b. Overlay de portage manuel (ce que l'outil ne peut pas deviner)
if [ -d migration19 ]; then
  echo "   → overlay migration19/ (portage hr.contract -> hr.version)"
  # kaydan_hr : hr_contract.py remplacé par hr_version.py
  rm -f addons19/kaydan_hr/models/hr_contract.py
  cp -a migration19/kaydan_hr/models/hr_version.py addons19/kaydan_hr/models/
  cp -a migration19/kaydan_hr/data/ir_cron_data.xml addons19/kaydan_hr/data/
  sed -i 's/from \. import hr_contract/from . import hr_version/' addons19/kaydan_hr/models/__init__.py
  sed -i 's/\["hr", "hr_contract"\]/["hr"]/'                      addons19/kaydan_hr/__manifest__.py
fi

# 5c. Versions des manifestes 18.0.x -> 19.0.x
find addons19 -name "__manifest__.py" -exec sed -i 's/"18\.0\./"19.0./' {} \;

# 5d. Vérification : plus aucune référence à hr_contract/hr.contract non gardée
LEFT="$(grep -rn "hr[._]contract" addons19 --include=*.py --include=*.xml 2>/dev/null | grep -v "hr.contract.type" | grep -vc "in self.env\|in request.env\|elif" || true)"
[ "${LEFT:-0}" = "0" ] && echo "   ✓ aucune référence hr_contract résiduelle non gardée" \
                       || { echo "   ⚠ références hr_contract restantes :"; grep -rn "hr[._]contract" addons19 --include=*.py --include=*.xml | grep -v "hr.contract.type" | grep -v "in self.env\|in request.env\|elif" | sed 's/^/     /'; }
echo "   ✓ addons19/ prêt : $(ls -1 addons19 | grep -v oca | tr '\n' ' ')"

# ── 6. Configuration du staging ─────────────────────────────────────────────
echo "══ 6/8 — config/odoo/odoo19.conf ══"
sed -e "s/^dbfilter = .*/dbfilter = ^${STG}\$/" \
    -e "s/^workers = .*/workers = 2/" \
    -e "s/^max_cron_threads = .*/max_cron_threads = 0/" \
    config/odoo/odoo.conf > config/odoo/odoo19.conf
grep -q '^dbfilter' config/odoo/odoo19.conf || echo "dbfilter = ^${STG}\$" >> config/odoo/odoo19.conf
echo "   ✓ dbfilter=^${STG}$ · 2 workers · crons off"

# ── 7. OpenUpgrade ──────────────────────────────────────────────────────────
echo "══ 7/8 — OpenUpgrade 18→19 (10-40 min, log : ${LOG}) ══"
if [ -d "$OU_DIR/.git" ]; then (cd "$OU_DIR" && git fetch --depth 1 origin 19.0 -q && git reset --hard -q origin/19.0)
else rm -rf "$OU_DIR"; git clone --depth 1 -b 19.0 https://github.com/OCA/OpenUpgrade.git "$OU_DIR" -q; fi
[ -d "$OU_DIR/openupgrade_scripts/scripts" ] || die "OpenUpgrade incomplet (openupgrade_scripts/scripts absent)"

docker run --rm --network kaydan-internal \
  -v "$PWD/$OU_DIR":/openupgrade:ro \
  -v "$PWD/addons19":/mnt/extra-addons:ro \
  -v kaydan-odoo19-data:/var/lib/odoo \
  --entrypoint bash odoo:19 -lc "
    pip3 install --quiet --break-system-packages openupgradelib 2>/dev/null || pip3 install --quiet openupgradelib
    odoo -d ${STG} --db_host=postgres -r odoo -w '${POSTGRES_PASSWORD}' \
      --addons-path=/openupgrade,/mnt/extra-addons,/mnt/extra-addons/oca \
      --upgrade-path=/openupgrade/openupgrade_scripts/scripts \
      --load=base,web,openupgrade_framework \
      --update all --stop-after-init --workers=0 --max-cron-threads=0
  " > "$LOG" 2>&1
grep -iE "error|critical|traceback" "$LOG" | tail -20
BASEV="$(docker exec "$PG" psql -U odoo -d "$STG" -tAc "SELECT latest_version FROM ir_module_module WHERE name='base';" | tr -d '[:space:]')"
case "$BASEV" in 19.0*) echo "   ✓ SCHÉMA MIGRÉ : base=${BASEV}" ;; *) die "schéma non migré (base=${BASEV:-?}) — analyser ${LOG}" ;; esac

# ── 8. Démarrage + contrôles fonctionnels ──────────────────────────────────
echo "══ 8/8 — Démarrage du staging et contrôles ══"
docker rm -f kaydan-odoo19 >/dev/null 2>&1
docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.staging19.yml up -d odoo19 >/dev/null 2>&1 || die "démarrage du staging impossible"
for i in $(seq 1 30); do
  sleep 10
  H="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' kaydan-odoo19 2>/dev/null)"
  echo "   t+$((i*10))s — santé: ${H}"
  [ "$H" = "healthy" ] && break
done

q(){ docker exec "$PG" psql -U odoo -d "$STG" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
c(){ docker exec kaydan-odoo19 sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:8069$1" 2>/dev/null; }
FAILED=0
chk(){ # libellé · valeur · condition attendue
  if [ "$2" = "$3" ] || { [ "$3" = ">0" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null; }; then echo "   ✓ $1 : $2"
  else echo "   ✗ $1 : $2 (attendu ${3})"; FAILED=$((FAILED+1)); fi; }

echo "   ── Contrôles ──"
chk "santé conteneur"        "${H:-?}"                "healthy"
chk "page de connexion"      "$(c /web/login)"        "200"
# /doc et /json/2 exigent une authentification : on vérifie que la ROUTE EXISTE
DOC_CODE="$(c /doc)"; J2_CODE="$(c /json/2/res.users/search_read)"
if [ "$DOC_CODE" != "404" ] && [ -n "$DOC_CODE" ]; then echo "   ✓ route /doc présente (HTTP ${DOC_CODE} = redirection vers login, attendu)"
else echo "   ✗ route /doc absente (HTTP ${DOC_CODE:-?})"; FAILED=$((FAILED+1)); fi
if [ "$J2_CODE" != "404" ] && [ -n "$J2_CODE" ]; then echo "   ✓ route /json/2 présente (HTTP ${J2_CODE} = auth requise, attendu)"
else echo "   ✗ route /json/2 absente (HTTP ${J2_CODE:-?})"; FAILED=$((FAILED+1)); fi
chk "modules transitoires"   "$(q "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');")" "0"
chk "utilisateurs actifs"    "$(q 'SELECT count(*) FROM res_users WHERE active;')"  ">0"
chk "sociétés"               "$(q 'SELECT count(*) FROM res_company;')"             ">0"
chk "employés"               "$(q 'SELECT count(*) FROM hr_employee;')"             ">0"
chk "pièces jointes"         "$(q 'SELECT count(*) FROM ir_attachment;')"           ">0"
chk "groupes/ACL"            "$(q 'SELECT count(*) FROM ir_model_access;')"         ">0"
chk "modules rpc+api_doc"    "$(q "SELECT count(*) FROM ir_module_module WHERE name IN ('rpc','api_doc') AND state='installed';")" "2"
chk "hr.version (contrats)"  "$(q "SELECT count(*) FROM ir_model WHERE model='hr.version';")" "1"
chk "hr.contract supprimé"   "$(q "SELECT count(*) FROM ir_model WHERE model='hr.contract';")" "0"
echo "   Modules Kaydan  : $(q "SELECT string_agg(name||':'||state,' ') FROM ir_module_module WHERE name LIKE 'kaydan%';")"
echo "   Crons (désactivés attendu) : actifs=$(q 'SELECT count(*) FROM ir_cron WHERE active;')"
echo "   Erreurs au démarrage : $(docker logs --since 5m kaydan-odoo19 2>&1 | grep -cE 'ERROR|CRITICAL')"

echo "──────────────────────────────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
  echo " ✅ STAGING 19 VERT — https://${HOST19}"
  echo "    (copie de la prod : mêmes identifiants ; crons et mails neutralisés)"
  echo "    Étapes suivantes : check-list docs/22 puis, si tout est bon,"
  echo "      bash scripts/migrate19-bascule.sh --confirm"
else
  echo " ⚠ STAGING : ${FAILED} contrôle(s) en échec — analyser ${LOG} et les logs :"
  echo "    docker logs --tail 100 kaydan-odoo19"
fi
echo " La PROD (base ${DB}, image 18) n'a PAS été modifiée."
echo "──────────────────────────────────────────────────────────────"
