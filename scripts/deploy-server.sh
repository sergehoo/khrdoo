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
# Les DÉPENDANCES non installées doivent l'être aussi : marquer uniquement le
# module demandé le laisse bloqué en 'to install' si une dépendance manque
# (cas vu le 12/09 : kaydan_hr dépend de hr_contract, non installé).
docker exec "$PG" psql -U odoo -d "$DB" -c \
  "WITH RECURSIVE cible AS (
       SELECT id, name FROM ir_module_module WHERE name IN (${mods_sql})
     UNION
       SELECT m.id, m.name
       FROM cible c
       JOIN ir_module_module_dependency d ON d.module_id = c.id
       JOIN ir_module_module m ON m.name = d.name
   )
   UPDATE ir_module_module SET state='to install'
   WHERE id IN (SELECT id FROM cible) AND state='uninstalled';" >/dev/null

docker exec "$PG" psql -U odoo -d "$DB" -c \
  "UPDATE ir_module_module SET state='to upgrade'
   WHERE name IN (${mods_sql}) AND state='installed';" >/dev/null

echo "     Modules et dépendances marqués :"
docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT '       '||name||' -> '||state FROM ir_module_module
   WHERE state IN ('to install','to upgrade') ORDER BY name;"

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
