#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASE 3 : MIGRATION 18 -> 19 SUR STAGING (OpenUpgrade)
# -----------------------------------------------------------------------------
#  NE TOUCHE PAS À LA PROD : ni la base `kaydan`, ni le conteneur `kaydan-odoo`,
#  ni le volume `kaydan-odoo-data`. Rejouable à volonté.
#
#  ⚠ La base de staging s'appelle `stg19` et NON `kaydan19` : le dbfilter de
#    production est `^kaydan.*$` ; une seconde base correspondante rendrait
#    `db_monodb()` ambigu et, avec `list_db = False`, CASSERAIT la connexion
#    à https://rh.kaydan.tech. Ne jamais nommer une base jetable `kaydan*`.
#
#   0. Garde-fous (conflits de conteneurs, modules stables, kaydan_hr_demo)
#   1. Sauvegarde fraîche de la prod
#   2. Copie base   kaydan -> stg19
#   3. Copie filestore -> volume kaydan-odoo19-data
#   4. Neutralisation du staging (crons + serveurs de mail)
#   5. addons19/ : copie + `odoo upgrade_code` + overlay migration19/
#   6. config/odoo/odoo19.conf (dbfilter ^stg19$)
#   7. OpenUpgrade : conversion du schéma + mise à jour de tous les modules
#   8. Démarrage du staging + CONTRÔLES automatisés
#
#  Usage (sur le serveur) :  bash scripts/migrate19-staging.sh
#  Prérequis : phase 1 au vert · DNS A `rh-test.kaydan.tech` -> VPS
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
PG="kaydan-postgres"
DB="kaydan"
STG="stg19"                      # ⚠ ne doit PAS matcher ^kaydan.*$
OU_DIR="openupgrade19"
MODULES="kaydan_branding kaydan_hr_dashboard kaydan_api kaydan_hr kaydan_kinsight"
LOG="/tmp/openupgrade19_$(date +%Y%m%d_%H%M%S).log"

cd "$CODE_DIR" || { echo "❌ ${CODE_DIR} introuvable"; exit 1; }
die(){ echo "❌ $*"; exit 1; }

# Secrets : lus DIRECTEMENT dans le conteneur PostgreSQL.
# (Ne jamais faire `. ./.env` : bash interpréterait `BACKUP_CRON=0 2 * * *`
#  comme une commande et mangerait les caractères spéciaux des mots de passe.)
POSTGRES_PASSWORD="$(docker exec "$PG" printenv POSTGRES_PASSWORD 2>/dev/null || true)"
[ -n "$POSTGRES_PASSWORD" ] || die "mot de passe PostgreSQL introuvable (conteneur ${PG} arrêté ?)"
DOMAIN_V="$(grep -m1 '^DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r\"' || true)"
HOST19="$(grep -m1 '^ODOO19_HOST=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r\"' || true)"
# DOMAIN doit être le domaine RACINE (kaydan.tech). S'il contient déjà un
# préfixe d'hôte (rh.kaydan.tech), on le retire : sinon le staging viserait
# « rh-test.rh.kaydan.tech », qui ne résout pas.
case "$DOMAIN_V" in
  rh.*|www.*) DOMAIN_V="${DOMAIN_V#*.}" ;;
esac
HOST19="${HOST19:-rh-test.${DOMAIN_V:-kaydan.tech}}"
case "$HOST19" in
  *.*.*.*) echo "   ⚠ hôte de staging à 3 niveaux : ${HOST19}"
           echo "     Il ne résoudra probablement pas. Fixez ODOO19_HOST dans .env"
           echo "     (ex. ODOO19_HOST=rh-test.kaydan.tech) — le staging fonctionnera"
           echo "     de toute façon, seul l'accès HTTPS sera indisponible." ;;
esac

# ── 0. Garde-fous ───────────────────────────────────────────────────────────
echo "══ 0/8 — Garde-fous ══"
# a) conteneurs Odoo en conflit : on SIGNALE, on ne répare pas ici (rôle phase 1)
PARA="$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' \
        | grep -E '^kaydan-odoo\|' | grep -v "^kaydan-odoo|${PROJECT}$" || true)"
[ -z "$PARA" ] || { echo "$PARA" | sed 's/^/     /'; die "conteneur(s) Odoo hors projet ${PROJECT} — lancer d'abord : bash scripts/migrate19-phase1-secure.sh"; }
# b) prod stable
T="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
[ "${T:-1}" = "0" ] || die "prod instable : ${T:-?} module(s) en transition — corriger avant migration"
# c) kaydan_hr_demo (dépend de hr_contract, données de DÉMO)
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
# d) sources indispensables
[ -f config/odoo/odoo.conf ] || die "config/odoo/odoo.conf absent — lancer scripts/tune.sh"
[ -d migration19/kaydan_hr ] || die "migration19/ absent — portage hr.contract→hr.version impossible"
for m in $MODULES; do [ -d "addons/${m}" ] || die "addons/${m} absent du dépôt"; done
# e) OCA
OCA_N="$(ls -1 addons/oca 2>/dev/null | grep -v -e '^\.gitkeep$' -e '^README.md$' | wc -l | tr -d ' ')"
[ "${OCA_N:-0}" = "0" ] && echo "   ✓ aucun module OCA sur disque (rien à porter)" \
                        || echo "   ⚠ ${OCA_N} module(s) OCA présent(s) : à re-fetch en branche 19.0"
echo "   ✓ garde-fous OK (staging = base '${STG}', hôte ${HOST19})"

# ── 1. Sauvegarde ───────────────────────────────────────────────────────────
echo "══ 1/8 — Sauvegarde fraîche de la prod ══"
# Le conteneur backup monte ./scripts ; après un re-clone du dossier code par
# Dokploy il garde l'ANCIEN inode -> "/scripts/backup.sh: no such file".
docker exec kaydan-backup test -f /scripts/backup.sh 2>/dev/null || {
  echo "   ⚠ montage /scripts périmé dans kaydan-backup → recréation"
  docker compose -p "$PROJECT" up -d --no-deps --force-recreate backup >/dev/null 2>&1
  sleep 5
}
docker exec kaydan-backup /scripts/backup.sh >/dev/null 2>&1 && echo "   ✓ sauvegarde OK" || die "sauvegarde échouée"

# ── 2. Copie de la base ─────────────────────────────────────────────────────
echo "══ 2/8 — Copie ${DB} -> ${STG} ══"
# bash (et non sh/dash) pour disposer de `pipefail` : sans lui, un pg_dump
# interrompu en cours de flux donnait un pg_restore « réussi » sur base tronquée.
docker exec "$PG" bash -c "
  set -o pipefail
  psql -U odoo -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STG}' AND pid<>pg_backend_pid();\" >/dev/null
  dropdb -U odoo --if-exists ${STG} && createdb -U odoo -O odoo ${STG} &&
  pg_dump -U odoo -Fc ${DB} | pg_restore -U odoo -d ${STG} --no-owner --role=odoo --exit-on-error
" 2>&1 | tail -15
docker exec "$PG" psql -U odoo -d "$STG" -tAc "SELECT 1 FROM ir_module_module LIMIT 1;" >/dev/null 2>&1 \
  || die "copie de base incomplète (ir_module_module illisible dans ${STG})"
echo "   ✓ base ${STG} prête"

# ── 3. Copie du filestore ───────────────────────────────────────────────────
echo "══ 3/8 — Copie du filestore ══"
ODOO_UID="$(docker run --rm --entrypoint id odoo:19 -u 2>/dev/null | tr -d '[:space:]')"
ODOO_UID="${ODOO_UID:-101}"
docker run --rm -v kaydan-odoo-data:/src:ro alpine sh -c "[ -d /src/filestore/${DB} ]" \
  || die "filestore de prod introuvable (/var/lib/odoo/filestore/${DB})"
docker volume create kaydan-odoo19-data >/dev/null
docker run --rm -v kaydan-odoo-data:/src:ro -v kaydan-odoo19-data:/dst alpine sh -c "
  set -e
  mkdir -p /dst/filestore /dst/sessions
  rm -rf /dst/filestore/${STG}
  cp -a /src/filestore/${DB} /dst/filestore/${STG}
  chown -R ${ODOO_UID}:${ODOO_UID} /dst
" || die "copie du filestore échouée"
echo "   ✓ filestore copié (uid ${ODOO_UID})"

# ── 4. Neutralisation ───────────────────────────────────────────────────────
echo "══ 4/8 — Neutralisation du staging ══"
q_stg(){ docker exec "$PG" psql -U odoo -d "$STG" -c "$1" >/dev/null 2>&1; }
q_stg "UPDATE ir_cron SET active=false;"
q_stg "UPDATE ir_mail_server SET active=false;"
q_stg "UPDATE fetchmail_server SET active=false;"
q_stg "INSERT INTO ir_config_parameter(key,value) VALUES ('database.is_neutralized','True') ON CONFLICT (key) DO UPDATE SET value='True';"
q_stg "UPDATE ir_config_parameter SET value='https://${HOST19}' WHERE key='web.base.url';"
q_stg "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';"
echo "   ✓ crons + mails désactivés, base marquée neutralisée, assets purgés"

# ── 5. addons19/ : upgrade_code + overlay de portage ───────────────────────
echo "══ 5/8 — Génération des addons 19 (addons19/) ══"
rm -rf addons19 && mkdir -p addons19/oca && touch addons19/oca/.gitkeep
for m in $MODULES; do cp -a "addons/${m}" "addons19/${m}" || die "copie de ${m} échouée"; done

# 5a. Réécriture par l'outil OFFICIEL d'Odoo 19.
#     --glob est INDISPENSABLE : sans lui, upgrade_code parcourt aussi les
#     addons du cœur (montés en lecture seule) et échoue sur PermissionError.
echo "   → odoo upgrade_code --from 18.0 --to 19.0 (portée : kaydan_*)"
docker run --rm -v "$PWD/addons19":/work --entrypoint bash odoo:19 -lc \
  "set -o pipefail; odoo --addons-path=/work upgrade_code --from 18.0 --to 19.0 --glob 'kaydan_*/**/*' 2>&1 | tail -15" \
  || die "odoo upgrade_code a échoué"

# 5b. Overlay de portage manuel (ce que l'outil ne peut pas deviner)
echo "   → overlay migration19/ (hr.contract -> hr.version)"
rm -f addons19/kaydan_hr/models/hr_contract.py                              || die "overlay : suppression hr_contract.py"
cp -a migration19/kaydan_hr/models/hr_version.py addons19/kaydan_hr/models/  || die "overlay : hr_version.py"
cp -a migration19/kaydan_hr/data/ir_cron_data.xml addons19/kaydan_hr/data/   || die "overlay : ir_cron_data.xml"
sed -i 's/from \. import hr_contract/from . import hr_version/' addons19/kaydan_hr/models/__init__.py || die "overlay : models/__init__.py"
sed -i 's/\["hr", "hr_contract"\]/["hr"]/' addons19/kaydan_hr/__manifest__.py || die "overlay : manifeste"
# kaydan_kinsight : hr.version et hr.employee.version_id n'existent qu'en 19.
# Le module de base en est dépourvu (sinon il casse l'installation en 18) ;
# l'overlay les rétablit pour la cible 19.
if [ -d migration19/kaydan_kinsight ]; then
  cp -a migration19/kaydan_kinsight/models/hr_version.py addons19/kaydan_kinsight/models/     || die "overlay kinsight : hr_version.py"
  cp -a migration19/kaydan_kinsight/models/__init__.py addons19/kaydan_kinsight/models/       || die "overlay kinsight : __init__.py"
  cp -a migration19/kaydan_kinsight/security/ir.model.access.csv addons19/kaydan_kinsight/security/ || die "overlay kinsight : ACL"
  echo "   ✓ overlay kaydan_kinsight (hr.version + version_id rétablis pour la 19)"
fi
grep -q 'hr_contract' addons19/kaydan_hr/__manifest__.py && die "manifeste kaydan_hr NON porté (hr_contract encore présent)"

# 5c. Versions des manifestes 18.0.x -> 19.0.x
find addons19 -name "__manifest__.py" -exec sed -i 's/"18\.0\./"19.0./' {} \;

# 5d. Vérification ciblée sur ce qui CASSE réellement au chargement en v19.
#     (Ne pas chercher « hr_contract » partout : les commentaires et les accès
#      gardés par `if "hr.contract" in self.env` sont légitimes — le module doit
#      fonctionner en 18 comme en 19.)
#     Quatre motifs bloquants :
#       · "hr_contract" dans les depends d'un manifeste
#       · _inherit = "hr.contract"
#       · ref="hr_contract.<xmlid>" dans une donnée XML
#       · from . import hr_contract
LEFT="$(grep -rnE 'depends[^]]*hr_contract|_inherit[[:space:]]*=[[:space:]]*["'"'"']hr\.contract|ref="hr_contract\.|from[[:space:]]+\.[[:space:]]+import[[:space:]]+hr_contract' \
        addons19 --include='*.py' --include='*.xml' 2>/dev/null || true)"
if [ -z "$LEFT" ]; then
  echo "   ✓ aucune dépendance ni héritage hr_contract résiduel (commentaires et accès gardés ignorés)"
else
  echo "$LEFT" | sed 's/^/     /'
  die "références hr_contract BLOQUANTES restantes (dépendance, _inherit, ref XML ou import)"
fi
echo "   ✓ addons19/ prêt : $(ls -1 addons19 | grep -v oca | tr '\n' ' ')"

# ── 6. Configuration du staging ─────────────────────────────────────────────
echo "══ 6/8 — config/odoo/odoo19.conf ══"
sed -e "s/^dbfilter = .*/dbfilter = ^${STG}\$/" \
    -e "s/^workers = .*/workers = 2/" \
    -e "s/^max_cron_threads = .*/max_cron_threads = 0/" \
    config/odoo/odoo.conf > config/odoo/odoo19.conf || die "génération odoo19.conf"
grep -q '^dbfilter' config/odoo/odoo19.conf || echo "dbfilter = ^${STG}\$" >> config/odoo/odoo19.conf
grep -q '^admin_passwd' config/odoo/odoo19.conf || die "odoo19.conf incomplet (admin_passwd absent)"
echo "   ✓ dbfilter=^${STG}$ · 2 workers · crons off"

# ── 7. OpenUpgrade ──────────────────────────────────────────────────────────
echo "══ 7/8 — OpenUpgrade 18→19 (10-40 min, log : ${LOG}) ══"
if [ -d "$OU_DIR/.git" ]; then (cd "$OU_DIR" && git fetch --depth 1 origin 19.0 -q && git reset --hard -q FETCH_HEAD)
else rm -rf "$OU_DIR"; git clone --depth 1 -b 19.0 https://github.com/OCA/OpenUpgrade.git "$OU_DIR" -q; fi
[ -d "$OU_DIR/openupgrade_scripts/scripts" ] || die "OpenUpgrade incomplet (openupgrade_scripts/scripts absent)"

# Mot de passe passé par l'ENVIRONNEMENT (jamais interpolé dans la commande :
# une apostrophe casserait le quoting, et `ps aux` exposerait le secret).
# -i rpc,api_doc : rend l'API JSON-2 et /doc déterministes (sinon dépendant
# de l'évaluation auto_install).
docker run --rm --network kaydan-internal \
  -e PGPASSWORD="$POSTGRES_PASSWORD" -e ODOO_DB="$STG" \
  -v "$PWD/$OU_DIR":/openupgrade:ro \
  -v "$PWD/addons19":/mnt/extra-addons:ro \
  -v kaydan-odoo19-data:/var/lib/odoo \
  --entrypoint bash odoo:19 -lc '
    pip3 install --quiet --break-system-packages openupgradelib 2>/dev/null || pip3 install --quiet openupgradelib
    odoo -d "$ODOO_DB" --db_host=postgres -r odoo -w "$PGPASSWORD" \
      --addons-path=/openupgrade,/mnt/extra-addons,/mnt/extra-addons/oca \
      --upgrade-path=/openupgrade/openupgrade_scripts/scripts \
      --load=base,web,openupgrade_framework \
      --update all -i rpc,api_doc --stop-after-init --workers=0 --max-cron-threads=0
  ' > "$LOG" 2>&1
grep -iE "error|critical|traceback" "$LOG" | tail -20
# ⚠ RE-NEUTRALISATION : la mise à jour des modules recharge leurs fichiers de
# données, ce qui RÉACTIVE les crons (et peut recréer des serveurs de mail).
# Neutraliser avant la migration ne suffit donc pas.
q_stg "UPDATE ir_cron SET active=false;"
q_stg "UPDATE ir_mail_server SET active=false;"
q_stg "UPDATE fetchmail_server SET active=false;"
q_stg "INSERT INTO ir_config_parameter(key,value) VALUES ('database.is_neutralized','True') ON CONFLICT (key) DO UPDATE SET value='True';"
echo "   ✓ staging re-neutralisé après migration (crons et mails désactivés)"

BASEV="$(docker exec "$PG" psql -U odoo -d "$STG" -tAc "SELECT latest_version FROM ir_module_module WHERE name='base';" | tr -d '[:space:]')"
case "$BASEV" in 19.0*) echo "   ✓ SCHÉMA MIGRÉ : base=${BASEV}" ;; *) die "schéma non migré (base=${BASEV:-?}) — analyser ${LOG}" ;; esac

# ── 8. Démarrage + contrôles ───────────────────────────────────────────────
echo "══ 8/8 — Démarrage du staging et contrôles ══"
docker rm -f kaydan-odoo19 >/dev/null 2>&1
# --no-deps : le service odoo19 déclare depends_on: postgres ; sans cette option
# compose tenterait de créer un second conteneur nommé kaydan-postgres.
docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.staging19.yml up -d --no-deps odoo19 \
  || die "démarrage du staging impossible (relancer sans redirection pour voir l'erreur)"
for i in $(seq 1 30); do
  sleep 10
  H="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' kaydan-odoo19 2>/dev/null)"
  echo "   t+$((i*10))s — santé: ${H}"
  [ "$H" = "healthy" ] && break
done

q(){ docker exec "$PG" psql -U odoo -d "$STG" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
c(){ docker exec kaydan-odoo19 sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:8069$1" 2>/dev/null; }
FAILED=0
chk(){ if [ "$2" = "$3" ] || { [ "$3" = ">0" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null; }; then echo "   ✓ $1 : $2"
       else echo "   ✗ $1 : $2 (attendu ${3})"; FAILED=$((FAILED+1)); fi; }

echo "   ── Contrôles ──"
chk "santé conteneur"        "${H:-?}"                "healthy"
chk "page de connexion"      "$(c /web/login)"        "200"
DOC_CODE="$(c /doc)"
# /json/2/<modèle>/<méthode> n'accepte QUE POST : une sonde GET retombe sur la
# route attrape-tout qui renvoie un 404 délibéré. On interroge donc en POST ;
# sans jeton Bearer, la réponse attendue est 401 (auth requise) — jamais 404.
J2_CODE="$(docker exec kaydan-odoo19 sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://localhost:8069/json/2/res.users/search_read" 2>/dev/null)"
[ -n "$DOC_CODE" ] && [ "$DOC_CODE" != "404" ] && echo "   ✓ route /doc présente (HTTP ${DOC_CODE} = auth requise, attendu)" \
  || { echo "   ✗ route /doc absente (HTTP ${DOC_CODE:-?})"; FAILED=$((FAILED+1)); }
[ -n "$J2_CODE" ] && [ "$J2_CODE" != "404" ] && echo "   ✓ route /json/2 présente (HTTP ${J2_CODE} = auth requise, attendu)" \
  || { echo "   ✗ route /json/2 absente (HTTP ${J2_CODE:-?})"; FAILED=$((FAILED+1)); }
chk "modules transitoires"   "$(q "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');")" "0"
chk "utilisateurs actifs"    "$(q 'SELECT count(*) FROM res_users WHERE active;')"  ">0"
chk "sociétés"               "$(q 'SELECT count(*) FROM res_company;')"             ">0"
chk "employés"               "$(q 'SELECT count(*) FROM hr_employee;')"             ">0"
chk "pièces jointes"         "$(q 'SELECT count(*) FROM ir_attachment;')"           ">0"
chk "groupes/ACL"            "$(q 'SELECT count(*) FROM ir_model_access;')"         ">0"
chk "modules rpc+api_doc"    "$(q "SELECT count(*) FROM ir_module_module WHERE name IN ('rpc','api_doc') AND state='installed';")" "2"
chk "hr.version (contrats)"  "$(q "SELECT count(*) FROM ir_model WHERE model='hr.version';")" "1"
chk "hr.contract supprimé"   "$(q "SELECT count(*) FROM ir_model WHERE model='hr.contract';")" "0"
chk "kaydan_kinsight"        "$(q "SELECT count(*) FROM ir_module_module WHERE name='kaydan_kinsight' AND state='installed';")" "1"
echo "   Modules Kaydan  : $(q "SELECT string_agg(name||':'||state,' ') FROM ir_module_module WHERE name LIKE 'kaydan%';")"
echo "   Crons actifs (0 attendu) : $(q 'SELECT count(*) FROM ir_cron WHERE active;')"
echo "   Erreurs au démarrage     : $(docker logs --since 5m kaydan-odoo19 2>&1 | grep -cE 'ERROR|CRITICAL')"
echo "   Prod intacte             : base=$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT latest_version FROM ir_module_module WHERE name='base';" | tr -d '[:space:]')"

echo "──────────────────────────────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
  echo " ✅ STAGING 19 VERT — https://${HOST19}"
  echo "    (copie de la prod : mêmes identifiants ; crons et mails neutralisés)"
  echo "    Étapes suivantes : check-list docs/22, puis si tout est bon :"
  echo "      bash scripts/migrate19-bascule.sh --confirm"
else
  echo " ⚠ STAGING : ${FAILED} contrôle(s) en échec — analyser ${LOG} puis :"
  echo "    docker logs --tail 100 kaydan-odoo19"
fi
echo " La PROD (base ${DB}, image 18) n'a PAS été modifiée."
echo "──────────────────────────────────────────────────────────────"
