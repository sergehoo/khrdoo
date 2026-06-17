#!/usr/bin/env bash
# =============================================================================
#  KAYDAN ERP — Durcissement de l'hôte Ubuntu 24.04 (Phase 6)
#  À LANCER EN ROOT :  sudo bash security/harden.sh
#  Idempotent. Effectue : UFW, Fail2Ban, SSH (clés only), logrotate,
#  sysctl, mises à jour de sécurité automatiques.
#
#  ⚠ SÉCURITÉ : ce script DÉSACTIVE l'authentification SSH par mot de passe.
#    Assurez-vous d'avoir une CLÉ SSH fonctionnelle AVANT (sinon FORCE=0 bloque).
# =============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "❌ À exécuter en root (sudo)."; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT="$(grep -oP '^Port\s+\K[0-9]+' "$HERE/ssh/99-kaydan-hardening.conf" | head -n1 || echo 22)"
FORCE="${FORCE:-0}"

echo "═══ [1/7] Mise à jour & paquets de sécurité ═══"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw fail2ban unattended-upgrades apt-listchanges \
                      gettext-base auditd

echo "═══ [2/7] Pare-feu UFW ═══"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp  comment 'HTTP (ACME + redirection HTTPS)'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
echo "  ⚠ Rappel : Docker contourne UFW pour les ports PUBLIÉS. Ne publiez aucun"
echo "    port conteneur en clair (seul Traefik expose 80/443). Voir docs/13."

echo "═══ [3/7] SSH — authentification par clé uniquement ═══"
KEYS_FOUND=0
for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  [ -s "$f" ] && KEYS_FOUND=1
done
if [ "$KEYS_FOUND" -eq 1 ] || [ "$FORCE" = "1" ]; then
  install -m 0644 "$HERE/ssh/99-kaydan-hardening.conf" /etc/ssh/sshd_config.d/99-kaydan-hardening.conf
  cat > /etc/issue.net <<'BANNER'
***************************************************************************
  KAYDAN ERP — Accès réservé aux personnes autorisées.
  Toute connexion est journalisée et auditée. Article 323-1 et suivants.
***************************************************************************
BANNER
  if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd; echo "  ✓ SSH durci (port ${SSH_PORT})"; else echo "  ❌ Config SSH invalide — non appliquée"; fi
else
  echo "  ⚠ Aucune clé SSH trouvée — durcissement SSH IGNORÉ (risque de lock-out)."
  echo "    Ajoutez votre clé (ssh-copy-id) puis relancez, ou forcez : FORCE=1 sudo bash security/harden.sh"
fi

echo "═══ [4/7] Fail2Ban ═══"
install -m 0644 "$HERE/fail2ban/jail.local" /etc/fail2ban/jail.local
install -m 0644 "$HERE/fail2ban/filter.d/odoo-auth.conf"    /etc/fail2ban/filter.d/odoo-auth.conf
install -m 0644 "$HERE/fail2ban/filter.d/traefik-auth.conf" /etc/fail2ban/filter.d/traefik-auth.conf
sed -i "s/^port     = 22/port     = ${SSH_PORT}/" /etc/fail2ban/jail.local || true
systemctl enable --now fail2ban
systemctl restart fail2ban
echo "  ✓ Fail2Ban actif : $(fail2ban-client status | tr '\n' ' ')"

echo "═══ [5/7] Rotation des journaux ═══"
install -m 0644 "$HERE/logrotate/kaydan" /etc/logrotate.d/kaydan
logrotate --debug /etc/logrotate.d/kaydan >/dev/null && echo "  ✓ logrotate OK"

echo "═══ [6/7] Durcissement noyau (sysctl) ═══"
cat > /etc/sysctl.d/99-kaydan-hardening.conf <<'SYSCTL'
# Réseau
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
# Noyau
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
SYSCTL
sysctl --system >/dev/null && echo "  ✓ sysctl appliqué"

echo "═══ [7/7] Mises à jour de sécurité automatiques ═══"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTO
systemctl enable --now unattended-upgrades
systemctl enable --now auditd

echo
echo "✅ Durcissement terminé."
echo "   ⚠ NE FERMEZ PAS cette session : ouvrez une NOUVELLE connexion SSH par clé"
echo "     pour valider l'accès AVANT de quitter (port ${SSH_PORT})."
