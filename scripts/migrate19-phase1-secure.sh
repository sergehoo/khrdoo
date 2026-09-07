#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — PHASE 1 : SÉCURISER (préflight avant migration 18 -> 19)
# -----------------------------------------------------------------------------
#  Ne modifie RIEN de fonctionnel, sauf :
#   - suppression des conteneurs Odoo PARALLÈLES / EN CONFLIT (données dans les
#     volumes : rien n'est perdu) et remise en service du conteneur légitime ;
#   - création d'une sauvegarde + d'une base de TEST de restauration (supprimée
#     à la fin).
#
#  Produit un rapport d'inventaire dans backups/preflight-<horodatage>/ :
#     inventaire.txt · modules.csv · restore-test.txt
#
#  Usage (sur le serveur, en root) :
#     bash scripts/migrate19-phase1-secure.sh            # inventaire + backup + test restore
#     bash scripts/migrate19-phase1-secure.sh --no-restore-test   # sans test restauration
#
#  Sortie : code 0 = FEU VERT pour la phase 3 ; code != 0 = blocage à traiter.
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
ODOO="kaydan-odoo"
PG="kaydan-postgres"
DB="kaydan"
TESTDB="kaydan_restoretest"
DO_RESTORE_TEST=1
[ "${1:-}" = "--no-restore-test" ] && DO_RESTORE_TEST=0

TS="$(date +%Y%m%d_%H%M%S)"
OUT="${CODE_DIR}/backups/preflight-${TS}"
BLOCKERS=0

cd "$CODE_DIR" || { echo "❌ Dossier code introuvable : $CODE_DIR"; exit 1; }
mkdir -p "$OUT"
REPORT="${OUT}/inventaire.txt"

say()  { echo "$*" | tee -a "$REPORT"; }
head2(){ say ""; say "── $* ────────────────────────────────────────────"; }
ko()   { say "   ❌ BLOQUANT : $*"; BLOCKERS=$((BLOCKERS+1)); }
ok()   { say "   ✓ $*"; }
warn() { say "   ⚠ $*"; }

say "KAYDAN ERP — Rapport de préflight migration 18→19"
say "Date : $(date '+%F %T %Z')   ·   Hôte : $(hostname)"

# =============================================================================
head2 "1. Conteneurs Odoo : détection des parallèles / conflits"
# =============================================================================
# Tout conteneur dont le nom commence par kaydan-odoo OU basé sur une image odoo
mapfile -t ODOO_CTS < <(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Label "com.docker.compose.project"}}' \
  | grep -E '\|kaydan-odoo|\|odoo:' || true)

if [ "${#ODOO_CTS[@]}" -eq 0 ]; then
  ko "aucun conteneur Odoo trouvé (l'instance est arrêtée ou supprimée)"
else
  for line in "${ODOO_CTS[@]}"; do
    IFS='|' read -r cid cname cimg cstat cproj <<<"$line"
    say "   • ${cname}  [${cimg}]  projet='${cproj:-—}'  ${cstat}"
  done
fi

# Le conteneur légitime : nom kaydan-odoo ET projet = $PROJECT
LEGIT="$(docker ps -a --filter "name=^/${ODOO}$" \
  --format '{{.ID}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null || true)"
LEGIT_ID="${LEGIT%%|*}"; LEGIT_PROJ="${LEGIT##*|}"

# Conteneurs à éliminer : image odoo, PAS le nom officiel, OU nom officiel mais mauvais projet
REMOVED=0
while IFS='|' read -r cid cname cimg cstat cproj; do
  [ -z "${cid:-}" ] && continue
  if [ "$cname" != "$ODOO" ] && [ "$cname" != "kaydan-odoo19" ]; then
    warn "conteneur Odoo parallèle détecté : ${cname} (projet '${cproj:-—}') → suppression"
    docker rm -f "$cid" >/dev/null 2>&1 && { ok "supprimé : ${cname}"; REMOVED=$((REMOVED+1)); }
  fi
done < <(printf '%s\n' "${ODOO_CTS[@]:-}")

if [ -n "$LEGIT_ID" ] && [ "$LEGIT_PROJ" != "$PROJECT" ]; then
  warn "'${ODOO}' appartient au projet '${LEGIT_PROJ}' au lieu de '${PROJECT}' → recréation"
  docker rm -f "$ODOO" >/dev/null 2>&1 && REMOVED=$((REMOVED+1))
fi

# Remise en service via le BON projet (corrige aussi le montage des addons)
say "   → remise en service via le projet ${PROJECT}"
if docker compose -p "$PROJECT" up -d odoo >/dev/null 2>&1; then
  ok "conteneur ${ODOO} en service (projet ${PROJECT})"
else
  ko "impossible de démarrer ${ODOO} : docker compose -p ${PROJECT} up -d odoo"
fi
[ "$REMOVED" -gt 0 ] && warn "${REMOVED} conteneur(s) en conflit supprimé(s) — cause probable : un 'docker compose up' lancé SANS -p ${PROJECT}"

# Attente de disponibilité
for i in $(seq 1 30); do
  docker exec "$PG" pg_isready -U odoo >/dev/null 2>&1 && break; sleep 2
done

# =============================================================================
head2 "2. Versions (Odoo / édition / PostgreSQL)"
# =============================================================================
ODOO_VER="$(docker exec "$ODOO" odoo --version 2>/dev/null | tr -d '\r')"
say "   Odoo         : ${ODOO_VER:-inconnu}"
case "$ODOO_VER" in
  *" 18."*) ok "version 18.x confirmée" ;;
  *)        ko "version inattendue (18.x attendue) : ${ODOO_VER:-inconnu}" ;;
esac

# Édition : l'image Docker Hub 'odoo' est Community ; on le vérifie par 3 signaux
say "   Image        : $(docker inspect --format '{{.Config.Image}}' "$ODOO" 2>/dev/null)"
ENT_PATH="$(docker exec "$ODOO" sh -c 'ls -d /usr/lib/python3/dist-packages/odoo/addons/../../enterprise 2>/dev/null || true' 2>/dev/null)"
ENT_MODS="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state='installed' AND name IN ('hr_appraisal','hr_payroll','account_accountant','documents','sign','helpdesk','planning','quality_control','marketing_automation');" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$ENT_PATH" ] && [ "${ENT_MODS:-0}" = "0" ]; then
  ok "édition = Community (aucun chemin 'enterprise', aucun module EE installé)"
else
  warn "signaux Enterprise détectés (chemin='${ENT_PATH:-none}', modules EE installés=${ENT_MODS:-?}) → à trancher AVANT migration"
fi

PG_VER="$(docker exec "$PG" psql -U odoo -d postgres -tAc 'SHOW server_version;' 2>/dev/null | tr -d '[:space:]')"
say "   PostgreSQL   : ${PG_VER:-inconnu}"
case "$PG_VER" in
  1[2-9]*|2[0-9]*) ok "version PostgreSQL compatible Odoo 19 (>= 12)" ;;
  *) ko "version PostgreSQL non confirmée : ${PG_VER:-inconnu}" ;;
esac

# =============================================================================
head2 "3. Chemins d'addons (standard + custom)"
# =============================================================================
docker exec "$ODOO" sh -c 'grep -E "^addons_path" /etc/odoo/odoo.conf' 2>/dev/null | tee -a "$REPORT"
say "   Contenu de /mnt/extra-addons (vu PAR le conteneur) :"
docker exec "$ODOO" sh -c 'ls -1 /mnt/extra-addons 2>/dev/null' 2>/dev/null | sed 's/^/     - /' | tee -a "$REPORT"
say "   Contenu de /mnt/extra-addons/oca :"
docker exec "$ODOO" sh -c 'ls -1 /mnt/extra-addons/oca 2>/dev/null' 2>/dev/null | sed 's/^/     - /' | tee -a "$REPORT"
# Cohérence montage <-> dépôt (piège d'inode Dokploy)
HOST_MODS="$(ls -1 addons 2>/dev/null | grep -v '^oca$' | sort | tr '\n' ' ')"
CT_MODS="$(docker exec "$ODOO" sh -c 'ls -1 /mnt/extra-addons 2>/dev/null' | grep -v '^oca$' | sort | tr '\n' ' ')"
if [ "$HOST_MODS" = "$CT_MODS" ]; then ok "montage addons cohérent avec le dépôt"
else warn "DÉCALAGE montage/dépôt (inode périmé) — dépôt='${HOST_MODS}' vs conteneur='${CT_MODS}'"; fi

# =============================================================================
head2 "4. Modules installés (inventaire complet)"
# =============================================================================
docker exec "$PG" psql -U odoo -d "$DB" -tAF',' -c \
  "SELECT name, state, latest_version FROM ir_module_module WHERE state <> 'uninstalled' ORDER BY name;" \
  > "${OUT}/modules.csv" 2>/dev/null
say "   → $(wc -l < "${OUT}/modules.csv" | tr -d ' ') modules (liste : modules.csv)"
say "   Custom Kaydan :"
grep -E '^kaydan' "${OUT}/modules.csv" | sed 's/^/     /' | tee -a "$REPORT"
TRANSIT="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc \
  "SELECT count(*) FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable');" 2>/dev/null | tr -d '[:space:]')"
if [ "${TRANSIT:-0}" = "0" ]; then ok "aucun module en état transitoire"
else ko "${TRANSIT} module(s) en état transitoire (to install/to upgrade) → régler avant migration"; fi

# =============================================================================
head2 "5. Volumes (base + filestore) et occupation"
# =============================================================================
for v in kaydan-postgres-data kaydan-odoo-data; do
  mp="$(docker volume inspect "$v" --format '{{.Mountpoint}}' 2>/dev/null || echo '?')"
  sz="$(du -sh "$mp" 2>/dev/null | cut -f1 || echo '?')"
  say "   ${v} : ${sz}  (${mp})"
done
DBSIZE="$(docker exec "$PG" psql -U odoo -d postgres -tAc "SELECT pg_size_pretty(pg_database_size('${DB}'));" 2>/dev/null | tr -d '[:space:]')"
say "   Taille base ${DB} : ${DBSIZE:-?}"
say "   Espace disque :"; df -h / | tail -1 | sed 's/^/     /' | tee -a "$REPORT"
FREE_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ "${FREE_GB:-0}" -ge 15 ]; then ok "espace libre suffisant (${FREE_GB} Go)"
else ko "espace libre insuffisant (${FREE_GB:-?} Go) — la migration duplique base + filestore"; fi

# =============================================================================
head2 "6. Sauvegarde complète (obligatoire)"
# =============================================================================
if docker exec kaydan-backup /scripts/backup.sh 2>&1 | tail -5 | tee -a "$REPORT"; then
  LAST="$(ls -1t backups/daily/kaydan_*.gpg backups/daily/kaydan_*.gz 2>/dev/null | head -1)"
  if [ -n "$LAST" ]; then ok "sauvegarde créée : ${LAST} ($(du -h "$LAST" | cut -f1))"
  else ko "aucune archive produite dans backups/daily/"; fi
else
  ko "le script de sauvegarde a échoué"
fi

# =============================================================================
head2 "7. Test de restauration (base jetable ${TESTDB})"
# =============================================================================
if [ "$DO_RESTORE_TEST" = "1" ] && [ -n "${LAST:-}" ]; then
  ARCH_IN_CT="/backups/daily/$(basename "$LAST")"
  say "   → restauration de ${ARCH_IN_CT} vers ${TESTDB}"
  if docker exec kaydan-backup /scripts/restore.sh "$TESTDB" "$ARCH_IN_CT" > "${OUT}/restore-test.txt" 2>&1; then
    T_TABLES="$(docker exec "$PG" psql -U odoo -d "$TESTDB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')"
    T_EMP="$(docker exec "$PG" psql -U odoo -d "$TESTDB" -tAc "SELECT count(*) FROM hr_employee;" 2>/dev/null | tr -d '[:space:]')"
    T_USR="$(docker exec "$PG" psql -U odoo -d "$TESTDB" -tAc "SELECT count(*) FROM res_users;" 2>/dev/null | tr -d '[:space:]')"
    P_TABLES="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')"
    P_EMP="$(docker exec "$PG" psql -U odoo -d "$DB" -tAc "SELECT count(*) FROM hr_employee;" 2>/dev/null | tr -d '[:space:]')"
    say "   Tables  : prod=${P_TABLES:-?}  restauré=${T_TABLES:-?}"
    say "   Employés: prod=${P_EMP:-?}  restauré=${T_EMP:-?}   ·   Utilisateurs restaurés=${T_USR:-?}"
    if [ -n "${T_TABLES:-}" ] && [ "${T_TABLES:-0}" = "${P_TABLES:-x}" ] && [ "${T_EMP:-0}" = "${P_EMP:-x}" ]; then
      ok "RESTAURATION VALIDÉE (structure et volumétrie identiques)"
    else
      ko "restauration incohérente avec la prod → la sauvegarde n'est pas fiable"
    fi
    # Nettoyage de la base + filestore de test
    docker exec "$PG" dropdb -U odoo --if-exists "$TESTDB" >/dev/null 2>&1
    docker exec kaydan-backup sh -c "rm -rf /restore/odoo/filestore/${TESTDB}" >/dev/null 2>&1
    ok "base et filestore de test nettoyés"
  else
    ko "le test de restauration a échoué (détail : ${OUT}/restore-test.txt)"
  fi
else
  warn "test de restauration ignoré"
fi

# =============================================================================
head2 "8. Santé de l'instance"
# =============================================================================
HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO" 2>/dev/null)"
say "   État conteneur : ${HEALTH:-inconnu}"
[ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "running" ] && ok "instance en service" || ko "instance non saine : ${HEALTH:-?}"
ERRS="$(docker logs --since 1h "$ODOO" 2>&1 | grep -cE "ERROR|CRITICAL" || true)"
say "   Erreurs dans la dernière heure : ${ERRS:-0}"

# =============================================================================
say ""
say "══════════════════════════════════════════════════════════════"
if [ "$BLOCKERS" -eq 0 ]; then
  say " ✅ PHASE 1 OK — aucun bloquant. Rapport : ${OUT}"
  say "    Étape suivante : bash scripts/migrate19-staging.sh"
else
  say " ⛔ PHASE 1 : ${BLOCKERS} BLOQUANT(S) — ne PAS migrer avant résolution."
  say "    Détail : ${REPORT}"
fi
say "══════════════════════════════════════════════════════════════"
exit "$BLOCKERS"
