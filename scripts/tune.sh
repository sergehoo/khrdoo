#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Génération de config/odoo/odoo.conf selon le profil
#  - Profil explicite : ODOO_PROFILE=small|medium|enterprise (dans .env)
#  - Profil auto       : ODOO_PROFILE=auto  -> détection RAM/CPU
#  Rendu via envsubst (paquet gettext-base : apt install -y gettext-base)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
PROFILES_DIR="${ROOT}/config/odoo/profiles"
OUT="${ROOT}/config/odoo/odoo.conf"

# --- Chargement du .env ------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  set -a; # shellcheck disable=SC1090
  source "$ENV_FILE"; set +a
else
  echo "⚠ .env introuvable — valeurs par défaut utilisées (lancez 'make secrets')."
fi

: "${ODOO_PROFILE:=medium}"
: "${POSTGRES_USER:=odoo}"
: "${POSTGRES_PASSWORD:=CHANGE_ME}"
: "${ODOO_ADMIN_PASSWD:=CHANGE_ME_master_password}"
: "${ODOO_DB_NAME:=kaydan}"

# --- Détection des ressources (Linux + macOS) --------------------------------
detect_ram_gb() {
  if [ -r /proc/meminfo ]; then
    awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo
  elif command -v sysctl >/dev/null; then
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else echo 8; fi
}
detect_cpu() { command -v nproc >/dev/null && nproc || sysctl -n hw.ncpu 2>/dev/null || echo 4; }

RAM_GB="$(detect_ram_gb)"; CPU="$(detect_cpu)"

if [ "$ODOO_PROFILE" = "auto" ]; then
  if   [ "$RAM_GB" -lt 6 ];  then ODOO_PROFILE="small"
  elif [ "$RAM_GB" -lt 13 ]; then ODOO_PROFILE="medium"
  else ODOO_PROFILE="enterprise"; fi
  echo "🔎 Auto-détection : ${RAM_GB} Go RAM / ${CPU} vCPU -> profil '${ODOO_PROFILE}'"
fi

TEMPLATE="${PROFILES_DIR}/${ODOO_PROFILE}.conf"
[ -f "$TEMPLATE" ] || { echo "❌ Profil inconnu : ${ODOO_PROFILE}"; exit 1; }

# --- Rendu -------------------------------------------------------------------
export ODOO_ADMIN_PASSWD POSTGRES_USER POSTGRES_PASSWORD ODOO_DB_NAME
if command -v envsubst >/dev/null; then
  envsubst '${ODOO_ADMIN_PASSWD} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${ODOO_DB_NAME}' \
    < "$TEMPLATE" > "$OUT"
else
  echo "⚠ envsubst absent — installez gettext-base. Substitution sed de secours."
  sed -e "s#\${ODOO_ADMIN_PASSWD}#${ODOO_ADMIN_PASSWD}#g" \
      -e "s#\${POSTGRES_USER}#${POSTGRES_USER}#g" \
      -e "s#\${POSTGRES_PASSWORD}#${POSTGRES_PASSWORD}#g" \
      -e "s#\${ODOO_DB_NAME}#${ODOO_DB_NAME}#g" \
      "$TEMPLATE" > "$OUT"
fi

chmod 640 "$OUT" 2>/dev/null || true
echo "✅ config/odoo/odoo.conf généré (profil '${ODOO_PROFILE}')."
grep -E '^(workers|max_cron_threads|limit_memory_hard|dbfilter)' "$OUT" | sed 's/^/   /'
