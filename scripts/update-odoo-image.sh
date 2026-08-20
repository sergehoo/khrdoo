#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Mise à jour SÛRE de l'image Odoo (dernière build 18.0)
# -----------------------------------------------------------------------------
#  Ce script reste dans la MÊME version majeure (18.0) : correctifs + sécurité.
#  (Une migration 19.0 est un projet distinct : OpenUpgrade + portage modules.)
#
#  Étapes : sauvegarde → pull image → marquage 'to upgrade' de TOUS les modules
#  installés (SQL, pas de process odoo concurrent) → recréation du conteneur
#  (nouvelle image + montage re-lié) → un SEUL démarrage applique la MAJ.
#
#  Usage (sur le serveur) :  bash update-odoo-image.sh
#  Durée : ~5-15 min. Prévoir une fenêtre de maintenance (utilisateurs déconnectés).
# =============================================================================
set -euo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
ODOO="kaydan-odoo"
PG="kaydan-postgres"
DB="kaydan"

cd "$CODE_DIR"

echo "1/7 — Sauvegarde complète AVANT mise à jour…"
docker exec kaydan-backup /scripts/backup.sh || { echo "❌ Sauvegarde échouée — mise à jour ANNULÉE."; exit 1; }

echo "2/7 — Image actuelle (pour rollback éventuel)…"
OLD_IMG="$(docker inspect --format '{{.Image}}' "$ODOO")"
echo "     Image en service : ${OLD_IMG}"
docker tag "$OLD_IMG" odoo:18-rollback
echo "     Taguée odoo:18-rollback (rollback possible)."

echo "3/7 — Récupération de la dernière build odoo:18…"
docker compose -p "$PROJECT" pull odoo

NEW_IMG="$(docker image inspect --format '{{.Id}}' "$(docker compose -p "$PROJECT" config --images | grep '^odoo' | head -1)" 2>/dev/null || docker image inspect --format '{{.Id}}' odoo:18)"
if [ "$OLD_IMG" = "$NEW_IMG" ]; then
  echo "✅ Déjà sur la dernière build 18.0 — rien à faire."
  exit 0
fi

echo "4/7 — Marquage de TOUS les modules installés en 'to upgrade' (SQL)…"
docker exec "$PG" psql -U odoo -d "$DB" -c \
  "UPDATE ir_module_module SET state='to upgrade' WHERE state='installed';" >/dev/null

echo "5/7 — Purge des bundles d'assets (régénération propre)…"
docker exec "$PG" psql -U odoo -d "$DB" -c \
  "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';" >/dev/null

echo "6/7 — Recréation du conteneur Odoo avec la nouvelle image…"
docker compose -p "$PROJECT" up -d --force-recreate odoo
echo "     La mise à niveau des modules s'applique au démarrage (un seul processus)."
echo "     Suivi : docker logs -f ${ODOO}   (attendre 'Modules loaded' / 'Registry loaded')"

echo "7/7 — Attente de la fin de la mise à niveau…"
for i in $(seq 1 60); do
  sleep 10
  pending="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
    "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]' || echo '?')"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO")"
  echo "     t+$((i*10))s — modules en cours: ${pending} · santé: ${health}"
  [ "$pending" = "0" ] && [ "$health" = "healthy" ] && break
done

echo "--------------------------------------------------------------"
if [ "${pending:-1}" = "0" ]; then
  echo "✅ Mise à jour terminée. Vérifiez https://rh.kaydan.tech (hard refresh Ctrl+Shift+R)."
  echo "   L'ancienne image reste disponible : odoo:18-rollback"
else
  echo "⚠ Des modules sont encore en transition — consultez : docker logs --tail 100 ${ODOO}"
  echo "  ROLLBACK si nécessaire :"
  echo "    docker exec $PG psql -U odoo -d $DB -c \"UPDATE ir_module_module SET state='installed' WHERE state='to upgrade';\""
  echo "    ODOO_VERSION=18-rollback docker compose -p $PROJECT up -d --force-recreate odoo"
  echo "    puis restaurer la sauvegarde si besoin (scripts/restore.sh)."
fi
echo "--------------------------------------------------------------"
