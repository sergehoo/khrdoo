#!/usr/bin/env bash
# =============================================================================
#  Point d'entrée du conteneur backup — planifie backup.sh via supercronic
# =============================================================================
set -euo pipefail

mkdir -p /backups/daily /backups/weekly /backups/monthly /var/log/backup

CRON="${BACKUP_CRON:-0 2 * * *}"
echo "${CRON} /scripts/backup.sh >> /var/log/backup/backup.log 2>&1" > /etc/crontab.kaydan

echo "──────────────────────────────────────────────"
echo " Kaydan ERP — service de sauvegarde"
echo "  Planification : ${CRON}"
echo "  Rétention     : J=${BACKUP_RETENTION_DAILY:-30} S=${BACKUP_RETENTION_WEEKLY:-8} M=${BACKUP_RETENTION_MONTHLY:-12}"
echo "  S3/MinIO      : ${BACKUP_S3_ENABLED:-false} (${BACKUP_S3_ENDPOINT:-n/a})"
echo "  Chiffrement   : $([ -n "${BACKUP_PASSPHRASE:-}" ] && echo "AES-256 activé" || echo "DÉSACTIVÉ")"
echo "──────────────────────────────────────────────"

exec /usr/local/bin/supercronic -passthrough-logs /etc/crontab.kaydan
