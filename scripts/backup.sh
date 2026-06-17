#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Sauvegarde complète (PostgreSQL + filestore + addons + config)
#  Stratégie : quotidienne -> hebdomadaire (dimanche) -> mensuelle (1er du mois)
#  Sortie    : archive .tar chiffrée AES-256 (.tar.gpg) + envoi MinIO/S3
#  Exécution : automatique (supercronic) ou manuelle (make backup)
# =============================================================================
set -euo pipefail

# --- Paramètres (issus de l'environnement du conteneur backup) ---------------
PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-odoo}"
export PGPASSWORD="${PGPASSWORD:-}"

BACKUP_ROOT="/backups"
WORK_DIR="$(mktemp -d /tmp/kaydan-backup.XXXXXX)"
TS="$(date +%Y%m%d_%H%M%S)"
DOW="$(date +%u)"          # 1=lundi … 7=dimanche
DOM="$(date +%d)"          # jour du mois
DAILY_DIR="${BACKUP_ROOT}/daily"
WEEKLY_DIR="${BACKUP_ROOT}/weekly"
MONTHLY_DIR="${BACKUP_ROOT}/monthly"

RET_D="${BACKUP_RETENTION_DAILY:-30}"
RET_W="${BACKUP_RETENTION_WEEKLY:-8}"
RET_M="${BACKUP_RETENTION_MONTHLY:-12}"

log() { echo "[$(date '+%F %T')] $*"; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" "$MONTHLY_DIR"
log "=== Début sauvegarde Kaydan ERP (${TS}) ==="

# --- 1. Dump de toutes les bases (hors templates et 'postgres') --------------
mkdir -p "${WORK_DIR}/databases"
DATABASES="$(psql -h "$PGHOST" -U "$PGUSER" -d postgres -At \
  -c "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres';")"

for db in $DATABASES; do
  log "  → dump base '${db}'"
  pg_dump -h "$PGHOST" -U "$PGUSER" -d "$db" -Fc -Z6 \
    -f "${WORK_DIR}/databases/${db}.dump"
done

# Dump global des rôles/permissions (utile en restauration complète)
pg_dumpall -h "$PGHOST" -U "$PGUSER" --roles-only \
  > "${WORK_DIR}/databases/_roles.sql"

# --- 2. Filestore Odoo -------------------------------------------------------
if [ -d /data/odoo/filestore ]; then
  log "  → archivage filestore"
  tar -czf "${WORK_DIR}/filestore.tar.gz" -C /data/odoo filestore
fi

# --- 3. Addons personnalisés + configurations --------------------------------
[ -d /data/addons ] && { log "  → archivage addons";  tar -czf "${WORK_DIR}/addons.tar.gz" -C /data addons; }
[ -d /data/config ] && { log "  → archivage config";  tar -czf "${WORK_DIR}/config.tar.gz" -C /data config; }

# --- 4. Manifeste ------------------------------------------------------------
cat > "${WORK_DIR}/MANIFEST.txt" <<EOF
Kaydan ERP — sauvegarde
Date       : $(date '+%F %T %Z')
Bases      : ${DATABASES}
Hôte PG    : ${PGHOST}
Contenu    : databases/ filestore.tar.gz addons.tar.gz config.tar.gz
Chiffrement: $([ -n "${BACKUP_PASSPHRASE:-}" ] && echo "AES-256 (gpg symétrique)" || echo "aucun")
EOF

# --- 5. Archive unique -------------------------------------------------------
ARCHIVE="kaydan_${TS}.tar"
ITEMS=(databases MANIFEST.txt)
for f in filestore.tar.gz addons.tar.gz config.tar.gz; do
  [ -f "${WORK_DIR}/$f" ] && ITEMS+=("$f")
done
tar -cf "${WORK_DIR}/${ARCHIVE}" -C "$WORK_DIR" "${ITEMS[@]}"

# --- 6. Chiffrement AES-256 (PII at-rest) ------------------------------------
if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  log "  → chiffrement AES-256"
  gpg --batch --yes --pinentry-mode loopback \
      --passphrase "${BACKUP_PASSPHRASE}" \
      --symmetric --cipher-algo AES256 \
      -o "${DAILY_DIR}/${ARCHIVE}.gpg" "${WORK_DIR}/${ARCHIVE}"
  FINAL="${ARCHIVE}.gpg"
else
  log "  ⚠ chiffrement désactivé (BACKUP_PASSPHRASE vide)"
  gzip -c "${WORK_DIR}/${ARCHIVE}" > "${DAILY_DIR}/${ARCHIVE}.gz"
  FINAL="${ARCHIVE}.gz"
fi
log "  ✓ archive quotidienne : ${DAILY_DIR}/${FINAL}"

# --- 7. Promotions hebdo / mensuelle -----------------------------------------
if [ "$DOW" = "7" ]; then cp -f "${DAILY_DIR}/${FINAL}" "${WEEKLY_DIR}/"; log "  ✓ copie hebdomadaire"; fi
if [ "$DOM" = "01" ]; then cp -f "${DAILY_DIR}/${FINAL}" "${MONTHLY_DIR}/"; log "  ✓ copie mensuelle"; fi

# --- 8. Rotation -------------------------------------------------------------
rotate() {  # $1=dossier  $2=nb à conserver
  local dir="$1" keep="$2" count
  count=$(ls -1t "$dir"/kaydan_*.{gpg,gz} 2>/dev/null | wc -l || echo 0)
  if [ "$count" -gt "$keep" ]; then
    ls -1t "$dir"/kaydan_*.{gpg,gz} 2>/dev/null | tail -n +"$((keep+1))" | xargs -r rm -f
    log "  ✓ rotation ${dir} (conserve ${keep})"
  fi
}
rotate "$DAILY_DIR"   "$RET_D"
rotate "$WEEKLY_DIR"  "$RET_W"
rotate "$MONTHLY_DIR" "$RET_M"

# --- 9. Envoi vers MinIO / S3 ------------------------------------------------
if [ "${BACKUP_S3_ENABLED:-false}" = "true" ]; then
  log "  → envoi vers ${BACKUP_S3_ENDPOINT}/${BACKUP_S3_BUCKET}"
  mc alias set kaydan "${BACKUP_S3_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1
  mc mb --ignore-existing "kaydan/${BACKUP_S3_BUCKET}" >/dev/null 2>&1 || true
  mc cp "${DAILY_DIR}/${FINAL}" "kaydan/${BACKUP_S3_BUCKET}/daily/" >/dev/null
  # Cycle de vie : expiration côté objet alignée sur la rétention quotidienne
  mc ilm rule add --expire-days "${RET_D}" "kaydan/${BACKUP_S3_BUCKET}" >/dev/null 2>&1 || true
  log "  ✓ envoi S3 terminé"
fi

log "=== Sauvegarde terminée : ${FINAL} ==="
