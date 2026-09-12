#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Désinstallation propre de modules
# -----------------------------------------------------------------------------
#  ⚠ UNE DÉSINSTALLATION SUPPRIME LES DONNÉES du module (tables et colonnes).
#    Une sauvegarde est prise automatiquement avant toute opération.
#
#  Pourquoi un script dédié : dans odoo/modules/loading.py, la STEP 5
#  (désinstallation des modules 'to remove') est conditionnée par
#  `update_module`, qui n'est vrai qu'avec -i/-u. Marquer l'état en SQL puis
#  redémarrer ne désinstalle donc RIEN. On passe par
#  `button_immediate_uninstall()`, la voie officielle, dans un processus dédié
#  (Odoo arrêté : un seul processus à la fois).
#
#  Usage :  bash scripts/uninstall-modules.sh mod1,mod2 --confirm
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
ODOO="kaydan-odoo"; PG="kaydan-postgres"; DB="kaydan"
MODULES="${1:-}"
TS="$(date +%Y%m%d_%H%M%S)"

[ -n "$MODULES" ] || { echo "Usage : bash scripts/uninstall-modules.sh mod1,mod2 --confirm"; exit 2; }
if [ "${2:-}" != "--confirm" ]; then
  cat <<EOF
⛔ Désinstallation non lancée (garde-fou).
   Modules visés : ${MODULES}
   Une désinstallation SUPPRIME DÉFINITIVEMENT les données de ces modules
   (leurs tables et leurs colonnes ajoutées aux modèles existants).
   Pour lancer réellement :
     bash scripts/uninstall-modules.sh ${MODULES} --confirm
EOF
  exit 2
fi

cd "$CODE_DIR" || { echo "❌ ${CODE_DIR} introuvable"; exit 1; }
log(){ echo "[$(date '+%F %T')] $*"; }
restart_odoo(){ docker compose -p "$PROJECT" up -d --no-deps odoo >/dev/null 2>&1 || docker start "$ODOO" >/dev/null 2>&1; }

log "1/5 — État actuel des modules visés"
mods_sql="'$(printf '%s' "$MODULES" | sed "s/,/','/g")'"
docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT '     '||name||' : '||state FROM ir_module_module WHERE name IN (${mods_sql});"

log "2/5 — Sauvegarde préalable (conservée, jamais supprimée)"
docker exec "$ODOO" true 2>/dev/null || restart_odoo
docker exec kaydan-backup test -f /scripts/backup.sh 2>/dev/null || {
  docker compose -p "$PROJECT" up -d --no-deps --force-recreate backup >/dev/null 2>&1; sleep 5; }
docker exec kaydan-backup /scripts/backup.sh >/dev/null 2>&1 || { echo "❌ sauvegarde impossible — abandon"; exit 1; }
LAST="$(docker exec kaydan-backup sh -c 'ls -1t /backups/daily/kaydan_*.gpg 2>/dev/null | head -1')"
mkdir -p backups/avant-desinstallation
docker exec kaydan-backup sh -c "cp -f '${LAST}' /backups/avant-desinstallation/avant_desinstallation_${TS}.tar.gpg" 2>/dev/null
log "   ✓ backups/avant-desinstallation/avant_desinstallation_${TS}.tar.gpg"

log "3/5 — Arrêt d'Odoo puis désinstallation (processus dédié)"
trap 'restart_odoo' EXIT INT TERM
docker compose -p "$PROJECT" stop odoo >/dev/null 2>&1
ULOG="/tmp/uninstall_${TS}.log"
PY_LIST="$(printf '%s' "$MODULES" | sed "s/,/','/g")"
RC=0
printf "%s\n" \
  "mods = env['ir.module.module'].search([('name','in',['${PY_LIST}']),('state','!=','uninstalled')])" \
  "print('MODULES_A_DESINSTALLER:', mods.mapped('name'))" \
  "if mods: mods.button_immediate_uninstall()" \
  "env.cr.commit()" \
  "print('TERMINE')" \
  | docker compose -p "$PROJECT" run --rm --no-deps -T odoo \
      odoo shell -d "$DB" --no-http --workers=0 --max-cron-threads=0 > "$ULOG" 2>&1 || RC=$?
grep -iE "MODULES_A_DESINSTALLER|TERMINE|ERROR|CRITICAL|Traceback" "$ULOG" | tail -12

log "4/5 — Redémarrage d'Odoo"
restart_odoo; trap - EXIT INT TERM
for i in $(seq 1 36); do
  sleep 5
  H="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO" 2>/dev/null)"
  [ "$H" = "healthy" ] && break
done

log "5/5 — Contrôles"
echo "   Santé Odoo        : ${H:-?}"
echo "   État des modules  :"
docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT '     '||name||' : '||state FROM ir_module_module WHERE name IN (${mods_sql});"
echo "   Modules installés : $(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM ir_module_module WHERE state='installed';" | tr -d '[:space:]')"
echo "   Employés          : $(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM hr_employee;" 2>/dev/null | tr -d '[:space:]')"
echo "   Erreurs (5 min)   : $(docker logs --since 5m "$ODOO" 2>&1 | grep -cE 'ERROR|CRITICAL')"
echo "--------------------------------------------------------------"
[ "${RC}" = "0" ] && echo " ✅ Désinstallation terminée — journal : ${ULOG}" \
                  || echo " ⚠ Code de retour ${RC} — vérifier ${ULOG} (Odoo a été relancé)"
echo "    Sauvegarde d'avant opération : backups/avant-desinstallation/avant_desinstallation_${TS}.tar.gpg"
echo "--------------------------------------------------------------"
