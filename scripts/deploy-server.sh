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

echo "5/6 — Analyse des modules demandés : ${MODULES}"
# ⚠ FAIT VÉRIFIÉ DANS LE CŒUR D'ODOO (odoo/modules/loading.py) :
#   load_marked_modules(['installed','to upgrade','to remove'])  -> TOUJOURS
#   load_marked_modules(['to install'])                          -> SEULEMENT si -i/-u
# Autrement dit : marquer 'to upgrade' en SQL + redémarrer SUFFIT pour mettre à
# jour un module déjà installé, mais n'INSTALLERA JAMAIS un module absent.
# Les installations passent donc par un processus dédié `-i`, Odoo étant arrêté
# (un second processus Odoo pendant que le premier sert provoque des
# « could not serialize access » sur ir_module_module).
TO_UPGRADE=""; TO_INSTALL=""
for m in $(printf '%s' "$MODULES" | tr ',' ' '); do
  st="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
        "SELECT state FROM ir_module_module WHERE name='${m}';" 2>/dev/null | tr -d '[:space:]')"
  case "$st" in
    installed) TO_UPGRADE="${TO_UPGRADE}${TO_UPGRADE:+,}${m}"; echo "     ${m} : installé -> mise à niveau" ;;
    ""|uninstalled|"to install") TO_INSTALL="${TO_INSTALL}${TO_INSTALL:+,}${m}"; echo "     ${m} : absent -> INSTALLATION" ;;
    *) echo "     ${m} : état '${st}' -> installation forcée"; TO_INSTALL="${TO_INSTALL}${TO_INSTALL:+,}${m}" ;;
  esac
done

if [ -n "$TO_UPGRADE" ]; then
  ups="'$(printf '%s' "$TO_UPGRADE" | sed "s/,/','/g")'"
  docker exec "$PG" psql -U odoo -d "$DB" -c \
    "UPDATE ir_module_module SET state='to upgrade' WHERE name IN (${ups}) AND state='installed';" >/dev/null
fi

echo "6/6 — Application"
restart_odoo(){ docker compose -p "$PROJECT" up -d --no-deps odoo >/dev/null 2>&1 || docker start "$ODOO" >/dev/null 2>&1; }

if [ -n "$TO_INSTALL" ]; then
  echo "     → arrêt d'Odoo puis installation dédiée : ${TO_INSTALL}"
  # GARANTIE ABSOLUE : si l'installation échoue (le script est en `set -e`),
  # Odoo doit être relancé malgré tout — sinon la PRODUCTION reste arrêtée.
  trap 'restart_odoo' EXIT INT TERM
  docker compose -p "$PROJECT" stop odoo >/dev/null 2>&1
  # Remettre à 'uninstalled' les états transitoires d'une tentative précédente,
  # sinon Odoo considère le module comme déjà pris en charge.
  ins="'$(printf '%s' "$TO_INSTALL" | sed "s/,/','/g")'"
  docker exec "$PG" psql -U odoo -d "$DB" -c \
    "UPDATE ir_module_module SET state='uninstalled' WHERE name IN (${ins}) AND state='to install';" >/dev/null
  # Sortie dans un fichier : un pipe + `set -o pipefail` ferait échouer le
  # script AVANT le redémarrage d'Odoo.
  ILOG="/tmp/install_$(date +%Y%m%d_%H%M%S).log"
  INSTALL_RC=0
  docker compose -p "$PROJECT" run --rm --no-deps odoo \
    odoo -d "$DB" -i "$TO_INSTALL" --stop-after-init --no-http --workers=0 --max-cron-threads=0 \
    > "$ILOG" 2>&1 || INSTALL_RC=$?
  grep -iE "Loading module|module .* loaded|ERROR|CRITICAL|Traceback|does not exist|Modules loaded" "$ILOG" | tail -20
  restart_odoo
  trap - EXIT INT TERM
  if [ "$INSTALL_RC" != "0" ]; then
    echo "     ❌ installation en échec (code ${INSTALL_RC}) — Odoo a été RELANCÉ."
    echo "        Journal complet : ${ILOG}"
  fi
else
  echo "     → redémarrage simple (mises à niveau uniquement)"
  docker restart "$ODOO" >/dev/null
fi

echo "     Attente du chargement du registre…"
for i in $(seq 1 36); do
  sleep 5
  H="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO" 2>/dev/null)"
  [ "$H" = "healthy" ] && break
done
PEND="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
echo "--------------------------------------------------------------"
if [ "${PEND:-1}" = "0" ]; then
  echo "✅ Déploiement OK — santé=${H:-?}"
  docker exec "$PG" psql -U odoo -d "$DB" -tAc \
    "SELECT '   '||name||' : '||state||' ('||latest_version||')' FROM ir_module_module WHERE name LIKE 'kaydan%' ORDER BY name;"
else
  echo "⚠ ${PEND} module(s) encore en état transitoire :"
  docker exec "$PG" psql -U odoo -d "$DB" -tAc \
    "SELECT '   '||name||' -> '||state FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');"
  echo "   Journal : docker logs --tail 60 ${ODOO}"
fi
echo "--------------------------------------------------------------"
