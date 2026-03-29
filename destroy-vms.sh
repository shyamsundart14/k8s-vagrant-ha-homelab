#!/bin/bash
#
# Destroy all K8s Vagrant HA Homelab VMs and clean up host configs
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VMS=("haproxy" "vault" "jump" "etcd-1" "etcd-2" "etcd-3" "master-1" "master-2" "worker-1" "worker-2" "worker-3")

echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  K8s Vagrant HA Homelab - Destroy VMs${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"

# Destroy Vagrant VMs
echo -e "${YELLOW}Destroying Vagrant VMs...${NC}"
cd "$SCRIPT_DIR"
vagrant destroy -f 2>/dev/null || true
rm -rf .vagrant
echo -e "${GREEN}Vagrant VMs destroyed${NC}"

# Clean /etc/hosts
HOSTS_MARKER="# BEGIN K8s Vagrant Homelab"
HOSTS_END="# END K8s Vagrant Homelab"
if grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}Removing /etc/hosts entries (requires sudo)...${NC}"
    sudo sed -i '' "/${HOSTS_MARKER}/,/${HOSTS_END}/d" /etc/hosts
    echo -e "${GREEN}Removed /etc/hosts entries${NC}"
fi

# Clean SSH config
SSH_CONFIG="$HOME/.ssh/config"
SSH_MARKER="# K8s Vagrant Homelab BEGIN"
SSH_END="# K8s Vagrant Homelab END"
if grep -q "$SSH_MARKER" "$SSH_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}Removing SSH config entries...${NC}"
    sed -i '' "/${SSH_MARKER}/,/${SSH_END}/d" "$SSH_CONFIG"
    sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SSH_CONFIG"
    echo -e "${GREEN}Removed SSH config entries${NC}"
fi

# Clean known_hosts (stale host keys cause warnings on recreate)
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [[ -f "$KNOWN_HOSTS" ]]; then
    echo -e "${YELLOW}Removing known_hosts entries for VMs...${NC}"
    for vm in "${VMS[@]}"; do
        ssh-keygen -R "$vm" -f "$KNOWN_HOSTS" 2>/dev/null || true
    done
    echo -e "${GREEN}Removed known_hosts entries${NC}"
fi

echo ""
echo -e "${GREEN}All VMs destroyed and configs cleaned up.${NC}"
