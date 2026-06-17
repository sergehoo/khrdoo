#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Audit de sécurité rapide de l'hôte (Phase 6)
#  Usage : sudo bash security/audit.sh
#  Contrôle (sans rien modifier) la conformité au durcissement attendu.
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
ko()   { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }

echo "═══ Pare-feu ═══"
chk "UFW actif"                         "ufw status | grep -q 'Status: active'"
chk "Politique entrante = deny"         "ufw status verbose | grep -q 'deny (incoming)'"

echo "═══ SSH ═══"
SSHD="$(sshd -T 2>/dev/null)"
echo "$SSHD" | grep -qi 'passwordauthentication no'      && ok "Mot de passe SSH désactivé" || ko "PasswordAuthentication encore actif"
echo "$SSHD" | grep -qi 'permitrootlogin prohibit-password\|permitrootlogin no' && ok "Login root par mot de passe désactivé" || ko "PermitRootLogin trop permissif"
echo "$SSHD" | grep -qi 'pubkeyauthentication yes'       && ok "Auth par clé activée" || ko "PubkeyAuthentication désactivé"

echo "═══ Fail2Ban ═══"
chk "Service Fail2Ban actif"            "systemctl is-active --quiet fail2ban"
chk "Jail sshd présente"                "fail2ban-client status sshd"
chk "Jail odoo-auth présente"           "fail2ban-client status odoo-auth"
chk "Jail traefik-auth présente"        "fail2ban-client status traefik-auth"

echo "═══ Mises à jour automatiques ═══"
chk "unattended-upgrades actif"         "systemctl is-active --quiet unattended-upgrades"

echo "═══ Noyau / sysctl ═══"
chk "ASLR activé"                       "[ \"$(sysctl -n kernel.randomize_va_space)\" = 2 ]"
chk "tcp_syncookies activé"             "[ \"$(sysctl -n net.ipv4.tcp_syncookies)\" = 1 ]"

echo "═══ Docker / secrets ═══"
chk "Fichier .env en 600"               "[ \"$(stat -c '%a' .env 2>/dev/null)\" = 600 ]"
chk "Aucun port DB publié"              "! docker ps --format '{{.Ports}}' | grep -q '5432->'"

echo
echo "──────────────────────────────────────"
echo "  Résultat : ${PASS} OK · ${FAIL} échec(s)"
[ "$FAIL" -eq 0 ] && echo "  ✅ Conforme au durcissement attendu." || echo "  ⚠ Corrigez les points ❌ (voir docs/13-checklist-securite.md)."
echo "──────────────────────────────────────"
