#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Déploiement/MAJ SÛR des addons sur le serveur Dokploy
# -----------------------------------------------------------------------------
#  Évite les 2 pièges récurrents :
#   1) Montage bind figé (inode) : Dokploy re-clone le code sans recréer le
#      conteneur -> Odoo lit d'anciens fichiers ("Could not get content…").
#      => on RECRÉE le conteneur (--force-recreate) pour re-lier le montage.
#   2) Collision de processus Odoo (SerializationFailure) : lancer `odoo -u`
#      via `docker exec` pendant que le conteneur sert écrit sur ir_module_module
#      en //. => on NE lance JAMAIS `-u`/`shell`. On marque les modules
#      "to upgrade" en SQL, puis un SEUL redémarrage applique la MAJ.
#
#  Usage (sur le serveur) :
#     bash deploy-server.sh                       # MAJ des 3 modules Kaydan
#     bash deploy-server.sh kaydan_hr_dashboard   # un module précis
#     bash deploy-server.sh kaydan_api,kaydan_branding
# =============================================================================
set -euo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
ODOO="kaydan-odoo"
PG="kaydan-postgres"
DB="kaydan"
MODULES="${1:-kaydan_hr_dashboard,kaydan_branding,kaydan_api}"

cd "$CODE_DIR"

echo "1/6 — Mise à jour du code (origin/main)…"
git fetch origin --quiet
git reset --hard origin/main

echo "2/6 — Recréation du conteneur Odoo (re-lie le montage des addons)…"
docker compose -p "$PROJECT" up -d --force-recreate odoo

echo "3/6 — Attente de PostgreSQL…"
until docker exec "$PG" pg_isready -U "$DB" >/dev/null 2>&1; do sleep 2; done
sleep 3

echo "4/6 — Purge des assets en cache (régénération propre)…"
docker exec "$PG" psql -U odoo -d "$DB" -c \
  "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';" >/dev/null

echo "5/6 — Marquage des modules (install si absent, upgrade si présent) : ${MODULES}"
# Construit la liste SQL 'a','b','c' de façon robuste (indépendant du shell)
mods_sql="'$(printf '%s' "$MODULES" | sed "s/,/','/g")'"
docker exec "$PG" psql -U odoo -d "$DB" -c \
  "UPDATE ir_module_module SET state = CASE
       WHEN state='installed'   THEN 'to upgrade'
       WHEN state='uninstalled' THEN 'to install'
       ELSE state END
   WHERE name IN (${mods_sql});" >/dev/null

echo "6/6 — Redémarrage Odoo SEUL (applique la MAJ + reconstruit les assets)…"
docker restart "$ODOO" >/dev/null
echo "     Attente du chargement du registre…"
sleep 8

pending="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" | tr -d '[:space:]')"

echo "--------------------------------------------------------------"
if [ "$pending" = "0" ]; then
  echo "✅ Déploiement OK. Modules en état transitoire : 0"
  echo "   Fais un HARD REFRESH navigateur : Ctrl/Cmd + Shift + R"
else
  echo "⚠ ${pending} module(s) encore en état transitoire — vérifie les logs :"
  echo "   docker logs --tail 60 ${ODOO}"
fi
echo "--------------------------------------------------------------"
