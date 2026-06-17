#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Récupération des modules OCA (branche 18.0)
#  Couvre les fonctionnalités non présentes dans Odoo Community :
#    Helpdesk, GED/Documents (DMS), Signature électronique, SSO OIDC.
#  Les modules sont copiés dans addons/oca/ (monté dans /mnt/extra-addons/oca).
#  Usage : bash scripts/fetch-oca.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BRANCH="18.0"
DEST="addons/oca"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DEST"

# Format : "repo_git|module1 module2 ..."
REPOS=(
  "https://github.com/OCA/helpdesk.git|helpdesk_mgmt helpdesk_mgmt_timesheet"
  "https://github.com/OCA/dms.git|dms"
  "https://github.com/OCA/sign.git|sign_oca"
  "https://github.com/OCA/server-auth.git|auth_oidc"
  "https://github.com/OCA/server-ux.git|mail_activity_board"
  "https://github.com/OCA/account-financial-reporting.git|account_financial_report"
)

for entry in "${REPOS[@]}"; do
  repo="${entry%%|*}"; mods="${entry##*|}"
  name="$(basename "$repo" .git)"
  echo "── ${name} (${BRANCH})"
  if git clone --quiet --depth 1 --branch "$BRANCH" "$repo" "$TMP/$name" 2>/dev/null; then
    for m in $mods; do
      if [ -d "$TMP/$name/$m" ]; then
        rm -rf "${DEST:?}/$m"
        cp -a "$TMP/$name/$m" "$DEST/$m"
        echo "   ✓ $m"
      else
        echo "   ⚠ $m introuvable sur la branche $BRANCH (porté plus tard ?)"
      fi
    done
  else
    echo "   ❌ clone impossible ($repo) — réseau ? branche $BRANCH absente ?"
  fi
done

echo
echo "✅ Modules OCA disponibles dans ${DEST}/ :"
ls -1 "$DEST" | grep -v -E '^(README|\.)' | sed 's/^/   - /'
echo
echo "Ensuite : redémarrez Odoo puis activez le mode développeur ->"
echo "  Applications -> Mettre à jour la liste -> installer les modules."
echo "  ⚠ auth_oidc nécessite l'image Odoo OIDC (voir docker-compose.oidc.yml)."
