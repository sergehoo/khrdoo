#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Restauration d'une base + filestore depuis une archive
#  Usage : restore.sh <DB_CIBLE> <CHEMIN_ARCHIVE>
#  Ex.   : /scripts/restore.sh kaydan /backups/daily/kaydan_20260617_020000.tar.gpg
#
#  ⚠ ARRÊTER Odoo AVANT :   docker compose stop odoo
#    Puis relancer APRÈS :   docker compose start odoo
# =============================================================================
set -euo pipefail

DB_TARGET="${1:?Usage: restore.sh <DB_CIBLE> <ARCHIVE>}"
ARCHIVE="${2:?Usage: restore.sh <DB_CIBLE> <ARCHIVE>}"

PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-odoo}"
export PGPASSWORD="${PGPASSWORD:-}"
WORK_DIR="$(mktemp -d /tmp/kaydan-restore.XXXXXX)"

log() { echo "[$(date '+%F %T')] $*"; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

[ -f "$ARCHIVE" ] || { log "❌ Archive introuvable : $ARCHIVE"; exit 1; }
log "=== Restauration '${DB_TARGET}' depuis ${ARCHIVE} ==="

# --- 1. Déchiffrement / décompression ----------------------------------------
TARFILE="${WORK_DIR}/restore.tar"
case "$ARCHIVE" in
  *.gpg)
    [ -n "${BACKUP_PASSPHRASE:-}" ] || { log "❌ BACKUP_PASSPHRASE requis"; exit 1; }
    log "  → déchiffrement AES-256"
    gpg --batch --yes --pinentry-mode loopback --passphrase "${BACKUP_PASSPHRASE}" \
        -o "$TARFILE" -d "$ARCHIVE" ;;
  *.gz)
    log "  → décompression"; gunzip -c "$ARCHIVE" > "$TARFILE" ;;
  *.tar)
    cp "$ARCHIVE" "$TARFILE" ;;
  *) log "❌ Format non reconnu (.gpg/.gz/.tar)"; exit 1 ;;
esac

# --- 2. Extraction -----------------------------------------------------------
tar -xf "$TARFILE" -C "$WORK_DIR"
DUMP="${WORK_DIR}/databases/${DB_TARGET}.dump"
[ -f "$DUMP" ] || {
  log "❌ Dump '${DB_TARGET}.dump' absent de l'archive. Bases disponibles :"
  ls -1 "${WORK_DIR}/databases/" | sed 's/\.dump$//' | grep -v '^_roles'
  exit 1
}

# --- 3. Restauration des rôles (idempotent) ----------------------------------
if [ -f "${WORK_DIR}/databases/_roles.sql" ]; then
  log "  → restauration des rôles"
  psql -h "$PGHOST" -U "$PGUSER" -d postgres -f "${WORK_DIR}/databases/_roles.sql" 2>/dev/null || true
fi

# --- 4. Recréation de la base ------------------------------------------------
log "  → coupure des connexions et recréation de '${DB_TARGET}'"
psql -h "$PGHOST" -U "$PGUSER" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_TARGET}' AND pid<>pg_backend_pid();" >/dev/null
dropdb   -h "$PGHOST" -U "$PGUSER" --if-exists "$DB_TARGET"
createdb -h "$PGHOST" -U "$PGUSER" --owner="$PGUSER" "$DB_TARGET"

# --- 5. pg_restore -----------------------------------------------------------
log "  → restauration des données (pg_restore)"
pg_restore -h "$PGHOST" -U "$PGUSER" -d "$DB_TARGET" --no-owner --role="$PGUSER" \
  --jobs=2 "$DUMP" || log "  ⚠ pg_restore a signalé des avertissements (souvent bénins)"

# --- 6. Restauration du filestore -------------------------------------------
if [ -f "${WORK_DIR}/filestore.tar.gz" ] && [ -d /restore/odoo ]; then
  log "  → restauration du filestore"
  tar -xzf "${WORK_DIR}/filestore.tar.gz" -C "${WORK_DIR}"
  SRC_FS="$(find "${WORK_DIR}/filestore" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
  if [ -n "$SRC_FS" ]; then
    mkdir -p "/restore/odoo/filestore"
    rm -rf "/restore/odoo/filestore/${DB_TARGET}"
    cp -a "$SRC_FS" "/restore/odoo/filestore/${DB_TARGET}"
    log "  ✓ filestore restauré -> /var/lib/odoo/filestore/${DB_TARGET}"
  fi
fi

log "=== Restauration terminée. Relancez Odoo : docker compose start odoo ==="
log "    Pensez à neutraliser les crons/mails si c'est une copie de test :"
log "    odoo shell -> env['ir.config_parameter'].set_param('database.is_neutralized', True)"
