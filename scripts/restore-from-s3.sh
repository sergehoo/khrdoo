#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Récupération d'une sauvegarde depuis MinIO/S3
# -----------------------------------------------------------------------------
#  Les archives locales (./backups) peuvent manquer si le montage du conteneur
#  de sauvegarde était périmé ; MinIO, lui, reçoit les archives par le réseau.
#
#  Usage (sur le serveur) :
#    bash scripts/restore-from-s3.sh --list
#        Liste les archives disponibles dans le bucket.
#
#    bash scripts/restore-from-s3.sh --verify daily/kaydan_20260908_020001.tar.gpg
#        Restaure dans une base JETABLE et affiche un rapport de contenu.
#        La production n'est PAS touchée. À faire EN PREMIER, toujours.
#
#    bash scripts/restore-from-s3.sh --promote daily/kaydan_20260908_020001.tar.gpg --confirm
#        Restaure en PRODUCTION : sauvegarde préalable, arrêt d'Odoo,
#        restauration base + filestore, purge des assets, redémarrage.
#
#  ⚠ La base de vérification s'appelle `restauration_test` : elle ne matche pas
#    le dbfilter `^kaydan.*$`, donc elle ne perturbe pas la connexion à la prod.
# =============================================================================
set -uo pipefail

PROJECT="capital-humain-rhodoo-n9r1wm"
CODE_DIR="/etc/dokploy/compose/${PROJECT}/code"
PG="kaydan-postgres"; ODOO="kaydan-odoo"; BK="kaydan-backup"
DB="kaydan"; TESTDB="restauration_test"
TS="$(date +%Y%m%d_%H%M%S)"

cd "$CODE_DIR" || { echo "❌ ${CODE_DIR} introuvable"; exit 1; }
log(){ echo "[$(date '+%F %T')] $*"; }
die(){ echo "❌ $*"; exit 1; }

# Le conteneur de sauvegarde doit voir ses scripts (piège d'inode Dokploy)
# ⚠ « backup » est le nom de SERVICE compose ; « kaydan-backup » n'est que le
# container_name — le passer à docker compose échoue (service inconnu).
# On recrée aussi dès que /backups est inaccessible (montage périmé après un
# re-clone Dokploy : le conteneur pointe alors sur un inode supprimé).
if ! docker exec "$BK" test -f /scripts/restore.sh 2>/dev/null \
   || ! docker exec "$BK" test -d /backups 2>/dev/null; then
  log "⚠ montages périmés dans ${BK} → recréation du conteneur"
  docker compose -p "$PROJECT" up -d --no-deps --force-recreate backup 2>&1 | tail -3
  sleep 5
  docker exec "$BK" test -d /backups || die "le conteneur ${BK} ne voit toujours pas /backups"
fi
# Les arguments passent par l'ENVIRONNEMENT : aucun guillemet imbriqué, donc
# aucune surprise de quoting. Les erreurs de mc restent VISIBLES.
mc_(){ docker exec -e MC_CMD="$1" "$BK" sh -c '
  mc alias set k "$BACKUP_S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null \
    || { echo "mc: configuration de l alias impossible (endpoint=$BACKUP_S3_ENDPOINT)" >&2; exit 1; }
  eval "$MC_CMD"'; }
q(){ docker exec "$PG" psql -U odoo -d "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]'; }

ACTION="${1:-}"; ARCHIVE="${2:-}"

# ── Inventaire ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "--list" ]; then
  log "Archives disponibles dans le bucket :"
  mc_ 'mc ls --recursive k/"$BACKUP_S3_BUCKET"/' || die "bucket illisible"
  echo
  echo "  ℹ La TAILLE est le meilleur indicateur : une chute brutale signale"
  echo "    une perte de données. Choisissez la dernière archive de taille normale."
  exit 0
fi

[ -n "$ARCHIVE" ] || die "archive non précisée. Voir : bash scripts/restore-from-s3.sh --list"

# ── Rapatriement depuis S3 ─────────────────────────────────────────────────
BASENAME="$(basename "$ARCHIVE")"
log "Rapatriement de ${ARCHIVE} depuis MinIO…"
docker exec "$BK" mkdir -p /backups/daily

# Voie 1 : le client mc. L'archive est passée par l'ENVIRONNEMENT (aucun
# guillemet imbriqué) et la sortie d'erreur est CONSERVÉE pour diagnostic.
MC_OUT="$(docker exec -e ARCH="$ARCHIVE" "$BK" sh -c '
  mc alias set k "$BACKUP_S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 \
    || { echo "alias mc impossible (endpoint=$BACKUP_S3_ENDPOINT)"; exit 1; }
  mc cp "k/$BACKUP_S3_BUCKET/$ARCH" "/backups/daily/" 2>&1 \
    || mc get "k/$BACKUP_S3_BUCKET/$ARCH" "/backups/daily/${ARCH##*/}" 2>&1
' 2>&1)"
MC_RC=$?
[ "$MC_RC" = "0" ] || { log "   ⚠ mc a échoué :"; printf '%s\n' "$MC_OUT" | tail -4 | sed 's/^/       /'; }

# Voie 2 (repli) : lecture directe du volume MinIO. Les objets y sont stockés
# en clair sous  <bucket>/<objet>/<uuid>/part.1 — on récupère cette partie.
if ! docker exec "$BK" test -s "/backups/daily/${BASENAME}"; then
  log "   → repli : extraction depuis le volume kaydan-minio-data"
  docker run --rm -e OBJ="$BASENAME" \
    -v kaydan-minio-data:/src:ro -v "${CODE_DIR}/backups":/dst \
    alpine sh -c '
      set -e
      d="$(find /src -type d -path "*/daily/$OBJ" 2>/dev/null | head -1)"
      [ -n "$d" ] || { echo "objet \"$OBJ\" introuvable dans le volume MinIO"; exit 1; }
      u="$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
      [ -n "$u" ] || { echo "répertoire de version introuvable sous $d"; exit 1; }
      # MinIO découpe les objets en parts de 16 Mio : il faut TOUTES les
      # concaténer dans l ordre NUMÉRIQUE, sinon l archive est corrompue.
      # (Trier sur le chemin avec « sort -t. » est faux : le nom de l objet
      #  contient lui-même des points — kaydan_....tar.gpg.)
      for f in "$u"/part.*; do
        [ -e "$f" ] || continue
        printf "%s %s\n" "${f##*part.}" "$f"
      done | sort -n | cut -d" " -f2- > /tmp/parts.lst
      [ -s /tmp/parts.lst ] || { echo "aucune part trouvée pour $OBJ"; exit 1; }
      mkdir -p /dst/daily
      : > "/dst/daily/$OBJ"
      n=0
      while IFS= read -r f; do
        cat "$f" >> "/dst/daily/$OBJ"
        n=$((n + 1))
      done < /tmp/parts.lst
      echo "parts concaténées : $n"
      ls -lh "/dst/daily/$OBJ"
    ' || die "récupération impossible (ni mc, ni volume MinIO). Nom exact ? bash scripts/restore-from-s3.sh --list"
fi
docker exec "$BK" test -s "/backups/daily/${BASENAME}" || die "archive absente ou vide après rapatriement"

# INTÉGRITÉ : on déchiffre et on liste le contenu SANS rien extraire. Une
# archive tronquée (parts manquantes) est ainsi détectée AVANT de toucher quoi
# que ce soit — et non au milieu d une restauration de production.
log "Contrôle d intégrité de l archive (déchiffrement + listage)…"
CONTENU="$(docker exec -e A="/backups/daily/${BASENAME}" "$BK" sh -c '
  gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" \
      --decrypt "$A" 2>/dev/null | tar -t 2>/dev/null' | head -20)"
echo "$CONTENU" | grep -q "databases/${DB}.dump" \
  || die "archive corrompue ou incomplète : le dump '${DB}.dump' est introuvable après déchiffrement.
      → Si la voie de secours a été utilisée, des parts MinIO manquent peut-être.
      → Réessayez, ou choisissez une autre archive : bash scripts/restore-from-s3.sh --list"
log "   ✓ archive valide — contenu : $(echo "$CONTENU" | tr '\n' ' ' | cut -c1-120)"
SIZE="$(docker exec "$BK" sh -c "du -h /backups/daily/${BASENAME} | cut -f1")"
log "   ✓ archive disponible (${SIZE})"

# ── Vérification dans une base jetable ─────────────────────────────────────
if [ "$ACTION" = "--verify" ]; then
  log "Restauration dans la base jetable '${TESTDB}' (la PROD n'est pas touchée)…"
  docker exec "$PG" psql -U odoo -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TESTDB}' AND pid<>pg_backend_pid();" >/dev/null 2>&1
  docker exec -e RESTORE_ROLES=0 "$BK" /scripts/restore.sh "$TESTDB" "/backups/daily/${BASENAME}" "$DB" \
    > "/tmp/verify_${TS}.log" 2>&1 || { tail -20 "/tmp/verify_${TS}.log"; die "restauration de vérification échouée"; }

  echo
  echo "════════ CONTENU DE L'ARCHIVE  vs  PRODUCTION ACTUELLE ════════"
  printf "  %-26s %12s %12s\n" "" "ARCHIVE" "PROD"
  for item in \
    "Tables:SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" \
    "Modules installés:SELECT count(*) FROM ir_module_module WHERE state='installed';" \
    "Utilisateurs:SELECT count(*) FROM res_users;" \
    "Sociétés:SELECT count(*) FROM res_company;" ; do
    lbl="${item%%:*}"; sql="${item#*:}"
    printf "  %-26s %12s %12s\n" "$lbl" "$(q "$TESTDB" "$sql")" "$(q "$DB" "$sql")"
  done
  for t in hr_employee hr_department hr_leave crm_lead account_move; do
    a="$(q "$TESTDB" "SELECT CASE WHEN to_regclass('$t') IS NULL THEN 'ABSENTE' ELSE (SELECT count(*)::text FROM $t) END;")"
    p="$(q "$DB"     "SELECT CASE WHEN to_regclass('$t') IS NULL THEN 'ABSENTE' ELSE (SELECT count(*)::text FROM $t) END;")"
    printf "  %-26s %12s %12s\n" "$t" "${a:-?}" "${p:-?}"
  done
  echo "═══════════════════════════════════════════════════════════════"
  echo
  echo " Si la colonne ARCHIVE contient bien vos données, promouvez-la :"
  echo "   bash scripts/restore-from-s3.sh --promote ${ARCHIVE} --confirm"
  echo
  echo " Nettoyer la base de vérification :"
  echo "   docker exec ${PG} dropdb -U odoo --if-exists ${TESTDB}"
  echo "   docker exec ${BK} rm -rf /restore/odoo/filestore/${TESTDB}"
  exit 0
fi

# ── Promotion en production ────────────────────────────────────────────────
if [ "$ACTION" = "--promote" ]; then
  [ "${3:-}" = "--confirm" ] || die "ajoutez --confirm pour restaurer réellement la PRODUCTION"

  log "1/6 — Sauvegarde de l'état ACTUEL avant écrasement (jamais supprimée)"
  docker exec "$BK" /scripts/backup.sh >/dev/null 2>&1 || die "sauvegarde préalable impossible"
  CUR="$(docker exec "$BK" sh -c 'ls -1t /backups/daily/kaydan_*.gpg 2>/dev/null | head -1')"
  mkdir -p backups/avant-restauration
  docker exec "$BK" sh -c "cp -f '${CUR}' /backups/avant-restauration/avant_restauration_${TS}.tar.gpg" 2>/dev/null
  log "   ✓ état actuel conservé : backups/avant-restauration/avant_restauration_${TS}.tar.gpg"

  log "2/6 — Arrêt d'Odoo (fenêtre de maintenance)"
  docker compose -p "$PROJECT" stop odoo >/dev/null 2>&1 || docker stop "$ODOO" >/dev/null 2>&1

  log "3/6 — Fermeture des connexions restantes à ${DB}"
  docker exec "$PG" psql -U odoo -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}' AND pid<>pg_backend_pid();" >/dev/null 2>&1

  log "4/6 — Restauration base + filestore (10-60 s)"
  docker exec -e RESTORE_ROLES=0 "$BK" /scripts/restore.sh "$DB" "/backups/daily/${BASENAME}" "$DB" \
    > "/tmp/promote_${TS}.log" 2>&1 || { tail -25 "/tmp/promote_${TS}.log"; die "restauration échouée — Odoo est ARRÊTÉ, relancer : docker compose -p ${PROJECT} up -d --no-deps odoo"; }

  log "5/6 — Purge des bundles d'assets puis redémarrage"
  docker exec "$PG" psql -U odoo -d "$DB" -c "DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';" >/dev/null 2>&1
  docker compose -p "$PROJECT" up -d --no-deps --force-recreate odoo >/dev/null 2>&1 || die "redémarrage impossible"
  for i in $(seq 1 36); do
    sleep 5
    H="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ODOO" 2>/dev/null)"
    [ "$H" = "healthy" ] && break
  done

  log "6/6 — Contrôles"
  echo "   Odoo          : $(docker exec "$ODOO" odoo --version 2>/dev/null | tr -d '\r') · santé=${H:-?}"
  echo "   Modules       : $(q "$DB" "SELECT count(*) FROM ir_module_module WHERE state='installed';")"
  echo "   Utilisateurs  : $(q "$DB" 'SELECT count(*) FROM res_users;')"
  echo "   Employés      : $(q "$DB" "SELECT CASE WHEN to_regclass('hr_employee') IS NULL THEN 'ABSENTE' ELSE (SELECT count(*)::text FROM hr_employee) END;")"
  echo "   Sociétés      : $(q "$DB" 'SELECT count(*) FROM res_company;')"
  echo "   Erreurs (5 m) : $(docker logs --since 5m "$ODOO" 2>&1 | grep -cE 'ERROR|CRITICAL')"
  cat <<EOF

═══════════════════════════════════════════════════════════════
 ✅ RESTAURATION TERMINÉE — vérifiez https://rh.kaydan.tech
    (videz le cache navigateur : Ctrl+Shift+R)
 État d'avant restauration conservé :
    backups/avant-restauration/avant_restauration_${TS}.tar.gpg
 Journal : /tmp/promote_${TS}.log
═══════════════════════════════════════════════════════════════
EOF
  exit 0
fi

die "action inconnue : '${ACTION}'. Utilisez --list, --verify <archive> ou --promote <archive> --confirm"
