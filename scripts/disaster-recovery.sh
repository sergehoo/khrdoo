#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Reprise après sinistre (PRA) assistée
#  Restaure la dernière sauvegarde disponible (locale ou MinIO/S3) sur un hôte
#  fraîchement réinstallé. À lancer depuis la racine du projet.
#
#  Pré-requis : .env restauré, images disponibles, réseau dokploy-network créé.
#  Usage      : bash scripts/disaster-recovery.sh [DB_CIBLE]   (défaut: $ODOO_DB_NAME)
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; [ -f .env ] && source .env; set +a
DB_TARGET="${1:-${ODOO_DB_NAME:-kaydan}}"
COMPOSE="docker compose"

echo "════════════════════════════════════════════════════════"
echo "  KAYDAN ERP — PROCÉDURE DE REPRISE APRÈS SINISTRE"
echo "  Base cible : ${DB_TARGET}"
echo "════════════════════════════════════════════════════════"

echo "[1/6] Vérification des prérequis…"
command -v docker >/dev/null || { echo "❌ Docker absent"; exit 1; }
[ -f .env ] || { echo "❌ .env absent — restaurez-le depuis le coffre-fort"; exit 1; }
docker network inspect dokploy-network >/dev/null 2>&1 || docker network create dokploy-network

echo "[2/6] Génération de la configuration Odoo…"
bash scripts/tune.sh

echo "[3/6] Démarrage des services socle (postgres, minio, backup)…"
$COMPOSE up -d postgres minio backup
echo "      Attente de PostgreSQL…"
until $COMPOSE exec -T postgres pg_isready -U "${POSTGRES_USER:-odoo}" >/dev/null 2>&1; do sleep 3; done

echo "[4/6] Localisation de la dernière sauvegarde…"
LATEST="$($COMPOSE exec -T backup bash -lc 'ls -1t /backups/daily/kaydan_*.{gpg,gz} 2>/dev/null | head -n1' || true)"
if [ -z "${LATEST:-}" ] && [ "${BACKUP_S3_ENABLED:-false}" = "true" ]; then
  echo "      Aucune sauvegarde locale — récupération depuis MinIO/S3…"
  $COMPOSE exec -T backup bash -lc '
    mc alias set kaydan "$BACKUP_S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    latest=$(mc ls --recursive "kaydan/$BACKUP_S3_BUCKET/daily/" | sort | tail -n1 | awk "{print \$NF}")
    mc cp "kaydan/$BACKUP_S3_BUCKET/daily/$latest" /backups/daily/'
  LATEST="$($COMPOSE exec -T backup bash -lc 'ls -1t /backups/daily/kaydan_*.{gpg,gz} 2>/dev/null | head -n1')"
fi
[ -n "${LATEST:-}" ] || { echo "❌ Aucune sauvegarde trouvée (locale ni S3)"; exit 1; }
echo "      Sauvegarde retenue : ${LATEST}"

echo "[5/6] Restauration (base + filestore)…"
$COMPOSE exec -T backup /scripts/restore.sh "$DB_TARGET" "$LATEST"

echo "[6/6] Démarrage complet de la stack…"
$COMPOSE up -d

echo "✅ Reprise terminée. Vérifiez : https://erp.${DOMAIN}"
echo "   Contrôlez les journaux : make logs S=odoo"
