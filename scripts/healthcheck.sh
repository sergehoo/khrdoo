#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Contrôle de santé rapide de la stack
#  Usage : bash scripts/healthcheck.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
COMPOSE="docker compose"
RC=0

echo "═══ État des conteneurs ═══"
$COMPOSE ps

echo; echo "═══ Santé Docker (healthcheck) ═══"
for c in kaydan-postgres kaydan-odoo kaydan-redis kaydan-minio; do
  status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo absent)"
  printf "  %-22s %s\n" "$c" "$status"
  case "$status" in healthy|running) ;; *) RC=1 ;; esac
done

echo; echo "═══ PostgreSQL ═══"
$COMPOSE exec -T postgres pg_isready -U "${POSTGRES_USER:-odoo}" && \
  $COMPOSE exec -T postgres psql -U "${POSTGRES_USER:-odoo}" -d postgres -At \
    -c "SELECT count(*)||' connexions actives' FROM pg_stat_activity;" || RC=1

echo; echo "═══ Odoo (santé HTTP interne) ═══"
$COMPOSE exec -T odoo curl -fsS http://localhost:8069/web/health >/dev/null \
  && echo "  ✓ /web/health OK" || { echo "  ✗ /web/health KO"; RC=1; }

echo; echo "═══ Espace disque ═══"
df -h / | awk 'NR==1 || /\/$/'

echo; echo "═══ Dernière sauvegarde ═══"
ls -1t backups/daily/kaydan_* 2>/dev/null | head -n1 || echo "  ⚠ aucune sauvegarde locale"

[ "$RC" -eq 0 ] && echo -e "\n✅ Tout est opérationnel." || echo -e "\n❌ Anomalies détectées (voir ci-dessus)."
exit "$RC"
