#!/bin/bash
# Server security setup for a web-folders VPS (Ubuntu/Debian).
# Safe to re-run. Must be executed as root or with sudo.
#
# What it does:
#   1. Updates system packages
#   2. Configures UFW firewall (allows SSH/80/443 only)
#   3. Installs and configures fail2ban (SSH brute-force protection)
#   4. Enables unattended security upgrades
#   5. Configures Docker log rotation (10 MB × 5 files per container)
#   6. Hardens SSH (disables password auth — only if SSH keys exist)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ─── Preflight ────────────────────────────────────────────────────────────────

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root or with sudo."
    exit 1
  fi
}

detect_os() {
  if ! command -v apt-get >/dev/null 2>&1; then
    error "apt-get not found. This script supports Ubuntu/Debian only."
    exit 1
  fi
}

# ─── 1. System update ─────────────────────────────────────────────────────────

update_system() {
  step "System update"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  info "System packages updated."
}

# ─── 2. UFW firewall ──────────────────────────────────────────────────────────

setup_ufw() {
  step "UFW firewall"
  apt-get install -y -qq ufw

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp   comment 'SSH'
  ufw allow 80/tcp   comment 'HTTP'
  ufw allow 443/tcp  comment 'HTTPS'
  ufw --force enable

  info "UFW enabled. Active rules:"
  ufw status verbose
}

# ─── 3. Fail2ban ──────────────────────────────────────────────────────────────

setup_fail2ban() {
  step "Fail2ban"
  apt-get install -y -qq fail2ban

  # Drop our jail config alongside the defaults (never touch jail.conf itself).
  cat > /etc/fail2ban/jail.d/99-web-folders.conf << 'EOF'
[DEFAULT]
# Ban for 1 hour after 5 failures within 10 minutes.
bantime  = 3600
findtime = 600
maxretry = 5
# Notify via syslog (no email needed by default).
action = %(action_)s

[sshd]
enabled  = true
port     = ssh
filter   = sshd
# Covers both journald (systemd) and traditional syslog paths.
backend  = auto
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  info "Fail2ban configured (SSH jail active)."
}

# ─── 4. Unattended security upgrades ──────────────────────────────────────────

setup_unattended_upgrades() {
  step "Unattended security upgrades"
  apt-get install -y -qq unattended-upgrades apt-listchanges

  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  systemctl enable unattended-upgrades
  systemctl restart unattended-upgrades
  info "Unattended upgrades configured (security-only, no auto-reboot)."
}

# ─── 5. Docker log rotation ───────────────────────────────────────────────────

setup_docker_logs() {
  step "Docker log rotation"

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker not found — skipping Docker log rotation."
    return
  fi

  local daemon_json=/etc/docker/daemon.json

  if [ -f "$daemon_json" ] && [ -s "$daemon_json" ]; then
    # Merge into existing config without overwriting other settings.
    python3 - "$daemon_json" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault('log-driver', 'json-file')
lo = cfg.setdefault('log-opts', {})
lo.setdefault('max-size', '10m')
lo.setdefault('max-file', '5')
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
  else
    cat > "$daemon_json" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
  fi

  systemctl reload-or-restart docker
  info "Docker log rotation set to 10 MB × 5 files per container."
  warn "Recreate containers to apply the new log limits:"
  warn "  docker compose down && docker compose up -d"
}

# ─── 6. SSH hardening ─────────────────────────────────────────────────────────

harden_ssh() {
  step "SSH hardening"

  # Safety check: refuse to disable password auth unless at least one
  # authorized_keys file exists (to avoid locking ourselves out).
  local has_keys=0
  for home_dir in /root /home/*; do
    if [ -f "$home_dir/.ssh/authorized_keys" ] && [ -s "$home_dir/.ssh/authorized_keys" ]; then
      has_keys=1
      break
    fi
  done

  if [ "$has_keys" -eq 0 ]; then
    warn "No SSH authorized_keys found anywhere."
    warn "Add your public key first, then re-run to enable SSH hardening:"
    warn "  ssh-copy-id user@<server>  # from your local machine"
    return
  fi

  local drop_in=/etc/ssh/sshd_config.d/99-web-folders-hardening.conf
  cat > "$drop_in" << 'EOF'
# Managed by setup-server.sh — do not edit manually.
PasswordAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3
AllowAgentForwarding no
AllowTcpForwarding no
EOF

  # Validate before restarting to avoid breaking SSH connectivity.
  if sshd -t; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    info "SSH hardened: password auth disabled, root login restricted."
  else
    error "sshd config test failed — reverting SSH hardening changes."
    rm -f "$drop_in"
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${BOLD}════ Setup complete ════${NC}"
  echo ""
  echo -e "${BOLD}UFW status:${NC}"
  ufw status verbose
  echo ""
  echo -e "${BOLD}Fail2ban status:${NC}"
  fail2ban-client status 2>/dev/null || true
  echo ""
  if command -v docker >/dev/null 2>&1; then
    echo -e "${BOLD}Docker log config:${NC}"
    docker info --format '{{json .LoggingDriver}}' 2>/dev/null && \
    cat /etc/docker/daemon.json 2>/dev/null || true
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  require_root
  detect_os

  info "Starting server security setup..."

  update_system
  setup_ufw
  setup_fail2ban
  setup_unattended_upgrades
  setup_docker_logs
  harden_ssh

  print_summary
}

main "$@"
