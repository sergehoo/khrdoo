#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Migration Odoo 18 -> 19 sur STAGING (OpenUpgrade)
# -----------------------------------------------------------------------------
#  NE TOUCHE PAS À LA PROD. Pipeline complet, rejouable à volonté :
#   1. Sauvegarde fraîche de la prod
#   2. Copie base  : kaydan -> kaydan19   (pg_dump | pg_restore)
#   3. Copie filestore -> volume kaydan-odoo19-data
#   4. Neutralisation du staging (crons, mails sortants/entrants)
#   5. Génération addons19/ (modules kaydan portés 19.0 — voir NOTES)
#   6. Génération config/odoo/odoo19.conf (dbfilter kaydan19)
#   7. Clone OpenUpgrade 19.0 + exécution de la migration (--update all)
#   8. Démarrage du staging odoo19 + rapport
#
#  NOTES portage v19 (générées automatiquement dans addons19/) :
#   - hr_contract n'existe plus en 19 (fusionné dans hr : modèle hr.version).
#     -> kaydan_hr est embarqué SANS la partie "alertes contrats" (à re-porter
#        sur hr.version ensuite) ; dépendance ramenée à "hr".
#   - kaydan_hr_demo est EXCLU (dépend de hr_contract, données de démo).
#   - Les éventuels modules OCA 18.0 (addons/oca) sont EXCLUS (à re-fetch en 19).
#
#  Usage (sur le serveur) :  bash scripts/migrate19-staging.sh
#  Prérequis : DNS A `rh-test.kaydan.tech` -> VPS (ou ODOO19_HOST dans .env)
# =============================================================================
set -euo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
PG="kaydan-postgres"
DB="kaydan"
STG="kaydan19"
OU_DIR="openupgrade19"

cd "$CODE_DIR"
set -a; [ -f .env ] && . ./.env; set +a
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD introuvable (.env)}"

echo "══ 1/8 — Sauvegarde fraîche de la prod (sécurité) ══"
docker exec kaydan-backup /scripts/backup.sh >/dev/null && echo "   ✓ sauvegarde OK" \
  || { echo "   ❌ sauvegarde échouée — migration annulée"; exit 1; }

echo "══ 2/8 — Copie de la base ${DB} -> ${STG} ══"
docker exec "$PG" sh -c "
  psql -U odoo -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${STG}' AND pid<>pg_backend_pid();\" >/dev/null 2>&1 || true
  dropdb  -U odoo --if-exists ${STG}
  createdb -U odoo -O odoo ${STG}
  pg_dump -U odoo -Fc ${DB} | pg_restore -U odoo -d ${STG} --no-owner --role=odoo
" && echo "   ✓ base ${STG} prête"

echo "══ 3/8 — Copie du filestore vers kaydan-odoo19-data ══"
# UID du user 'odoo' DANS L'IMAGE 19 (peut différer de l'image 18)
ODOO_UID="$(docker run --rm odoo:19 id -u 2>/dev/null || echo 101)"
docker volume create kaydan-odoo19-data >/dev/null
docker run --rm -v kaydan-odoo-data:/src:ro -v kaydan-odoo19-data:/dst alpine sh -c "
  mkdir -p /dst/filestore && rm -rf /dst/filestore/${STG} &&
  cp -a /src/filestore/${DB} /dst/filestore/${STG} &&
  chown -R ${ODOO_UID}:${ODOO_UID} /dst
" && echo "   ✓ filestore copié (uid ${ODOO_UID})"

echo "══ 4/8 — Neutralisation du staging (aucun mail/cron ne partira) ══"
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE ir_cron SET active = false;" >/dev/null
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE ir_mail_server SET active = false;" >/dev/null 2>&1 || true
docker exec "$PG" psql -U odoo -d "$STG" -c "UPDATE fetchmail_server SET active = false;" >/dev/null 2>&1 || true
docker exec "$PG" psql -U odoo -d "$STG" -c \
  "UPDATE ir_config_parameter SET value='https://${ODOO19_HOST:-rh-test.${DOMAIN:-kaydan.tech}}' WHERE key='web.base.url';" >/dev/null
echo "   ✓ crons/mails désactivés, base.url staging"

echo "══ 5/8 — Génération des addons portés (addons19/) ══"
rm -rf addons19 && mkdir -p addons19/oca && touch addons19/oca/.gitkeep
for m in kaydan_branding kaydan_hr_dashboard kaydan_api kaydan_hr; do
  cp -a "addons/${m}" "addons19/${m}"
done
# Version 18.0.x -> 19.0.x dans tous les manifestes copiés
find addons19 -name "__manifest__.py" -exec sed -i 's/"18\.0\./"19.0./' {} \;
# --- kaydan_hr : retrait de la partie hr_contract (n'existe plus en 19) ------
sed -i 's/\["hr", "hr_contract"\]/["hr"]/' addons19/kaydan_hr/__manifest__.py
sed -i '/data\/ir_cron_data.xml/d'          addons19/kaydan_hr/__manifest__.py
rm -f addons19/kaydan_hr/models/hr_contract.py addons19/kaydan_hr/data/ir_cron_data.xml
sed -i '/from . import hr_contract/d'       addons19/kaydan_hr/models/__init__.py
echo "   ✓ addons19/ : kaydan_branding, kaydan_hr_dashboard, kaydan_api, kaydan_hr (sans alertes contrats)"
echo "   ⚠ kaydan_hr_demo exclu · OCA 18.0 exclus (à re-fetch en 19 si besoin)"

echo "══ 6/8 — Génération config/odoo/odoo19.conf ══"
sed -e "s/^dbfilter = .*/dbfilter = ^${STG}\$/" \
    -e "s/^workers = .*/workers = 2/" \
    -e "s/^max_cron_threads = .*/max_cron_threads = 0/" \
    config/odoo/odoo.conf > config/odoo/odoo19.conf
echo "   ✓ odoo19.conf (dbfilter ${STG}, 2 workers, crons off)"

echo "══ 7/8 — OpenUpgrade 18 -> 19 (peut durer 10-40 min) ══"
[ -d "$OU_DIR" ] || git clone --depth 1 -b 19.0 https://github.com/OCA/OpenUpgrade.git "$OU_DIR"
docker run --rm --network kaydan-internal \
  -v "$PWD/$OU_DIR":/openupgrade:ro \
  -v "$PWD/addons19":/mnt/extra-addons:ro \
  -v kaydan-odoo19-data:/var/lib/odoo \
  odoo:19 bash -lc "
    pip3 install --quiet --break-system-packages openupgradelib 2>/dev/null || pip3 install --quiet openupgradelib
    odoo -d ${STG} --db_host=postgres -r odoo -w '${POSTGRES_PASSWORD}' \
      --addons-path=/openupgrade,/mnt/extra-addons,/mnt/extra-addons/oca \
      --upgrade-path=/openupgrade/openupgrade_scripts/scripts \
      --load=base,web,openupgrade_framework \
      --update all --stop-after-init --workers=0 --max-cron-threads=0
  " 2>&1 | tee /tmp/openupgrade19.log | grep -iE "loading module|error|critical|traceback" | tail -40 || true
echo "   → log complet : /tmp/openupgrade19.log"

echo "══ 8/8 — Démarrage du staging + rapport ══"
docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.staging19.yml up -d odoo19
sleep 8
pending="$(docker exec "$PG" psql -U odoo -d "$STG" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" | tr -d '[:space:]')"
errors="$(grep -ciE "^.*(ERROR|CRITICAL)" /tmp/openupgrade19.log || true)"
echo "--------------------------------------------------------------"
echo " Modules en état transitoire : ${pending}   ·   lignes ERROR du log : ${errors}"
if [ "$pending" = "0" ]; then
  echo " ✅ Staging Odoo 19 migré : https://${ODOO19_HOST:-rh-test.${DOMAIN:-kaydan.tech}}"
  echo "    (mêmes identifiants que la prod — c'est une copie)"
else
  echo " ⚠ Migration incomplète — analyser /tmp/openupgrade19.log (grep -i error)"
fi
echo " La PROD (kaydan, odoo:18) n'a pas été modifiée."
echo " Rejouer de zéro : relancer ce script (la base/volume staging sont recréés)."
echo "--------------------------------------------------------------"
