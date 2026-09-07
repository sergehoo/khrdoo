#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASE 4 : BASCULE PROD 18 -> 19
# -----------------------------------------------------------------------------
#  ⚠ À N'EXÉCUTER QUE SI LE STAGING EST VALIDÉ (phase 3 verte).
#  Le script REFUSE de démarrer si le staging n'existe pas / n'est pas sain.
#
#  Déroulé :
#   0. Garde-fous (staging validé, modules stables, espace disque, confirmation)
#   1. Fenêtre de maintenance : arrêt d'Odoo (les données restent intactes)
#   2. Sauvegarde FINALE Odoo 18 étiquetée 'pre19' (JAMAIS supprimée)
#   3. Migration OpenUpgrade sur la base de PROD (conteneur jetable, un seul process)
#   4. Bascule du code : ODOO_VERSION=19 + addons portés
#   5. Démarrage Odoo 19 + purge des assets + contrôles
#   6. Rapport ; en cas d'échec : procédure de ROLLBACK affichée
#
#  Usage :  bash scripts/migrate19-bascule.sh --confirm
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
ODOO="kaydan-odoo"; PG="kaydan-postgres"
DB="kaydan"; STG="stg19"   # stg19 : ne matche pas le dbfilter ^kaydan.*$
OU_DIR="openupgrade19"
TS="$(date +%Y%m%d_%H%M%S)"

if [ "${1:-}" != "--confirm" ]; then
  cat <<EOF
⛔ Bascule PROD non lancée (garde-fou).
   Cette opération migre la base de PRODUCTION vers Odoo 19.
   Pré-requis : staging validé (bash scripts/migrate19-staging.sh puis tests).
   Pour lancer réellement :  bash scripts/migrate19-bascule.sh --confirm
EOF
  exit 2
fi

cd "$CODE_DIR" || exit 1
# Secrets lus DIRECTEMENT dans le conteneur : `. ./.env` interpréterait
# `BACKUP_CRON=0 2 * * *` comme une commande et mangerait les caractères
# spéciaux des mots de passe (le parseur dotenv de compose n'est pas bash).
POSTGRES_PASSWORD="$(docker exec "$PG" printenv POSTGRES_PASSWORD 2>/dev/null || true)"
[ -n "$POSTGRES_PASSWORD" ] || { echo "❌ mot de passe PostgreSQL introuvable"; exit 1; }
ODOO_HOST="$(grep -m1 '^ODOO_HOST=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r\"' || true)"
ODOO_HOST="${ODOO_HOST:-rh.kaydan.tech}"

log(){ echo "[$(date '+%F %T')] $*"; }
fail(){
  log "❌ ÉCHEC : $*"
  cat <<EOF

═══════════════════ ROLLBACK (retour à Odoo 18) ═══════════════════
 1) Revenir à l'image 18 et au code 18 :
      cd ${CODE_DIR}
      sed -i 's/^ODOO_VERSION=19/ODOO_VERSION=18/' .env    # ou via l'UI Dokploy
      git checkout -- addons/ 2>/dev/null || true
 2) Restaurer la base + filestore Odoo 18 (sauvegarde 'pre19') :
      docker compose -p ${PROJECT} stop odoo
      docker exec kaydan-backup /scripts/restore.sh ${DB} /backups/pre19/${PRE19_NAME:-<archive_pre19>}
 3) Redémarrer :
      docker compose -p ${PROJECT} up -d --force-recreate odoo
      docker exec ${PG} psql -U odoo -d ${DB} -c "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';"
      docker restart ${ODOO}
 4) Vérifier : https://${ODOO_HOST:-rh.kaydan.tech}
 La sauvegarde 'pre19' n'est JAMAIS supprimée par ce script.
═══════════════════════════════════════════════════════════════════
EOF
  exit 1
}

# ── 0. Garde-fous ───────────────────────────────────────────────────────────
log "0/6 — Garde-fous"
STG_OK="$(docker exec "$PG" psql -U odoo -d postgres -tAc \
  "SELECT count(*) FROM pg_database WHERE datname='${STG}';" 2>/dev/null | tr -d '[:space:]')"
[ "${STG_OK:-0}" = "1" ] || fail "base de staging '${STG}' absente — la validation (phase 3) n'a pas eu lieu"
STG_PENDING="$(docker exec "$PG" psql -U odoo -d "$STG" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
[ "${STG_PENDING:-1}" = "0" ] || fail "staging non stable (${STG_PENDING} modules en transition)"
STG_VER="$(docker exec "$PG" psql -U odoo -d "$STG" -tAc \
  "SELECT latest_version FROM ir_module_module WHERE name='base';" 2>/dev/null | tr -d '[:space:]')"
case "$STG_VER" in 19.0*) log "   ✓ staging en base 19.0 (${STG_VER})" ;; *) fail "staging non migré (base=${STG_VER:-?})" ;; esac
PROD_PENDING="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
[ "${PROD_PENDING:-1}" = "0" ] || fail "prod instable (${PROD_PENDING} modules en transition) — corriger d'abord"
[ -d "$OU_DIR" ] || fail "OpenUpgrade absent (${OU_DIR}) — lancer d'abord le staging"
[ -d addons19 ] || fail "addons portés absents (addons19/) — lancer d'abord le staging"
[ -d addons19/kaydan_kinsight ] || fail "addons19/kaydan_kinsight absent — relancer le staging (module requis par K-Insight)"
# GARDE-FOU ANTI-REJEU : rejouer OpenUpgrade sur une base déjà en 19 corrompt
# les données tout en affichant un faux succès.
PROD_VER0="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT latest_version FROM ir_module_module WHERE name='base';" 2>/dev/null | tr -d '[:space:]')"
case "$PROD_VER0" in
  18.0*) log "   ✓ prod en 18.0 (${PROD_VER0}) — bascule légitime" ;;
  19.0*) fail "la base ${DB} est DÉJÀ en 19.0 (${PROD_VER0}) — bascule déjà effectuée, ne pas rejouer" ;;
  *)     fail "version de base inattendue : ${PROD_VER0:-inconnue}" ;;
esac
command -v rsync >/dev/null || fail "rsync requis pour la bascule des addons : apt install -y rsync"
FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "${FREE_GB:-0}" -ge 10 ] || fail "espace disque insuffisant (${FREE_GB} Go)"
log "   ✓ tous les garde-fous passés"

# ── 1. Maintenance ──────────────────────────────────────────────────────────
log "1/6 — Fenêtre de maintenance : arrêt d'Odoo"
docker compose -p "$PROJECT" stop odoo >/dev/null 2>&1 || docker stop "$ODOO" >/dev/null 2>&1
log "   ✓ Odoo arrêté (les utilisateurs voient une page d'indisponibilité)"

# ── 2. Sauvegarde finale Odoo 18 ────────────────────────────────────────────
log "2/6 — Sauvegarde FINALE Odoo 18 (conservée définitivement)"
mkdir -p backups/pre19
# backup.sh lit le filestore via le volume : Odoo n'a PAS besoin de tourner.
docker exec kaydan-backup /scripts/backup.sh >/dev/null 2>&1 || fail "sauvegarde finale impossible"
LAST="$(ls -1t backups/daily/kaydan_*.gpg backups/daily/kaydan_*.gz 2>/dev/null | head -1)"
[ -n "$LAST" ] || fail "archive finale introuvable"
PRE19_NAME="pre19_$(basename "$LAST")"
cp -f "$LAST" "backups/pre19/${PRE19_NAME}"
log "   ✓ sauvegarde 18 conservée : backups/pre19/${PRE19_NAME} ($(du -h "backups/pre19/${PRE19_NAME}" | cut -f1))"

# ── 3. Migration OpenUpgrade sur la PROD ────────────────────────────────────
log "3/6 — Migration OpenUpgrade 18→19 sur la base ${DB} (10-40 min)"
docker exec "$PG" psql -U odoo -d "$DB" -c "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';" >/dev/null 2>&1
docker run --rm --network kaydan-internal \
  -e PGPASSWORD="$POSTGRES_PASSWORD" -e ODOO_DB="$DB" \
  -v "$PWD/$OU_DIR":/openupgrade:ro \
  -v "$PWD/addons19":/mnt/extra-addons:ro \
  -v kaydan-odoo-data:/var/lib/odoo \
  --entrypoint bash odoo:19 -lc '
    pip3 install --quiet --break-system-packages openupgradelib 2>/dev/null || pip3 install --quiet openupgradelib
    odoo -d "$ODOO_DB" --db_host=postgres -r odoo -w "$PGPASSWORD" \
      --addons-path=/openupgrade,/mnt/extra-addons,/mnt/extra-addons/oca \
      --upgrade-path=/openupgrade/openupgrade_scripts/scripts \
      --load=base,web,openupgrade_framework \
      --update all -i rpc,api_doc --stop-after-init --workers=0 --max-cron-threads=0
  ' > "/tmp/bascule19_${TS}.log" 2>&1
grep -iE "error|critical|traceback" "/tmp/bascule19_${TS}.log" | tail -30
PROD_VER="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT latest_version FROM ir_module_module WHERE name='base';" | tr -d '[:space:]')"
case "$PROD_VER" in 19.0*) log "   ✓ base migrée en 19.0 (${PROD_VER})" ;; *) fail "base non migrée (base=${PROD_VER:-?}) — voir /tmp/bascule19_${TS}.log" ;; esac

# ── 4. Bascule du code ──────────────────────────────────────────────────────
log "4/6 — Bascule du code applicatif vers 19"
if grep -q '^ODOO_VERSION=' .env 2>/dev/null; then
  sed -i 's/^ODOO_VERSION=.*/ODOO_VERSION=19/' .env
else
  echo 'ODOO_VERSION=19' >> .env
fi
cp -a addons addons18_backup_"$TS" || fail "sauvegarde des addons 18 impossible"
# rsync --delete SANS fallback destructif : `rm -rf addons` changerait l'inode
# du bind-mount et kaydan-backup (non recréé) archiverait indéfiniment les
# anciens addons. On préserve donc le répertoire lui-même.
rsync -a --delete addons19/ addons/ || fail "synchronisation des addons échouée"
docker compose -p "$PROJECT" up -d --no-deps --force-recreate backup >/dev/null 2>&1 \
  && log "   ✓ conteneur backup recréé (montage addons re-lié)"
log "   ✓ ODOO_VERSION=19 · addons portés en place (sauvegarde : addons18_backup_${TS})"
log "   ⚠ Pensez à aligner l'ENV Dokploy (ODOO_VERSION=19) pour les prochains déploiements."

# ── 5. Démarrage Odoo 19 ────────────────────────────────────────────────────
log "5/6 — Démarrage d'Odoo 19"
docker compose -p "$PROJECT" up -d --no-deps --force-recreate odoo >/dev/null 2>&1 || fail "démarrage impossible"
for i in $(seq 1 60); do
  sleep 10
  H="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO" 2>/dev/null)"
  log "   t+$((i*10))s — santé: ${H}"
  [ "$H" = "healthy" ] && break
done
[ "${H:-}" = "healthy" ] || fail "Odoo 19 ne devient pas 'healthy' — voir docker logs ${ODOO}"

# ── 6. Contrôles ────────────────────────────────────────────────────────────
log "6/6 — Contrôles post-bascule"
q(){ docker exec "$PG" psql -U odoo -d "$DB" -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
log "   Odoo         : $(docker exec "$ODOO" odoo --version 2>/dev/null | tr -d '\r')"
log "   Utilisateurs : $(q 'SELECT count(*) FROM res_users WHERE active;')"
log "   Sociétés     : $(q 'SELECT count(*) FROM res_company;')"
log "   Employés     : $(q 'SELECT count(*) FROM hr_employee;')"
log "   Pièces jointes: $(q 'SELECT count(*) FROM ir_attachment;')"
log "   Modules custom: $(q "SELECT string_agg(name||':'||state, ' ') FROM ir_module_module WHERE name LIKE 'kaydan%';")"
log "   Crons actifs : $(q 'SELECT count(*) FROM ir_cron WHERE active;')"
log "   Transitoires : $(q "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');")"
log "   JSON-2 /doc  : $(docker exec "$ODOO" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/doc' 2>/dev/null)"
ERRS="$(docker logs --since 10m "$ODOO" 2>&1 | grep -cE 'ERROR|CRITICAL' || true)"
log "   Erreurs (10 min) : ${ERRS}"
cat <<EOF

═══════════════════════════════════════════════════════════════════
 ✅ BASCULE TERMINÉE — https://${ODOO_HOST:-rh.kaydan.tech}
 Sauvegarde Odoo 18 conservée : backups/pre19/${PRE19_NAME}
 Log de migration            : /tmp/bascule19_${TS}.log
 Addons 18 conservés         : addons18_backup_${TS}/
 Rollback : voir la procédure en tête de ce script (fonction fail).
 À faire ensuite : purger le cache navigateur (Ctrl+Shift+R) et
 valider la check-list docs/22 (login, ACL, sociétés, RH, filestore).
═══════════════════════════════════════════════════════════════════
EOF
