#!/bin/bash
# =============================================================================
# K8s Vagrant Homelab - Full Deployment Script
# =============================================================================
# Bastion architecture: Mac connects ONLY to jump server.
# All cluster playbooks run ON the jump server via SSH.
#
# Usage:
#   ./deploy.sh                  # Full deploy (vagrant up + all steps)
#   ./deploy.sh --ansible-only   # Skip vagrant up, run playbook steps only
#   ./deploy.sh --from-step N    # Resume from step N (skip prior steps)
# =============================================================================
set -e

# --- Config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
SSH_KEY="$HOME/.ssh/k8slab.key"
PROJECT_DIR_JUMP="~/vagrant-lab"
GROUP_VARS="$ANSIBLE_DIR/inventory/group_vars/all.yml"

# --- Auto-detect network prefix from socket_vmnet ---
PLIST="/Library/LaunchDaemons/homebrew.mxcl.socket_vmnet.plist"
if [[ -f "$PLIST" ]]; then
  DETECTED_PREFIX=$(grep -o 'vmnet-gateway=[0-9.]*' "$PLIST" | head -1 | cut -d= -f2 | awk -F. '{print $1"."$2"."$3}')
fi
NET="${DETECTED_PREFIX:-192.168.105}"

# Update group_vars/all.yml with detected prefix (single source of truth)
if [[ -f "$GROUP_VARS" ]]; then
  CURRENT_PREFIX=$(grep '^network_prefix:' "$GROUP_VARS" | awk '{print $2}' | tr -d '"')
  if [[ "$CURRENT_PREFIX" != "$NET" ]]; then
    sed -i '' "s|^network_prefix:.*|network_prefix: \"$NET\"|" "$GROUP_VARS"
    echo "Updated network_prefix to $NET in group_vars/all.yml"
  fi
fi

JUMP_IP="${NET}.12"

# VM definitions (must match Vagrantfile)
IP_SUFFIXES=(10 11 12 21 22 23 31 32 41 42 43)
VM_NAMES=("haproxy" "vault" "jump" "etcd-1" "etcd-2" "etcd-3" "master-1" "master-2" "worker-1" "worker-2" "worker-3")
VM_IPS=()
for s in "${IP_SUFFIXES[@]}"; do VM_IPS+=("${NET}.${s}"); done

# Binary versions
BIN_DIR="$HOME/vagrant-lab/k8s-binaries"
ETCD_VERSION="3.5.12"
K8S_VERSION="1.32.0"
CONTAINERD_VERSION="1.7.24"
RUNC_VERSION="1.2.4"
CALICO_VERSION="3.28.0"
K8S_URL="https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/arm64"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Parse args ---
SKIP_VAGRANT=false
FROM_STEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ansible-only) SKIP_VAGRANT=true; shift ;;
    --from-step)    FROM_STEP="$2"; shift 2 ;;
    *)              echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Timing ---
SCRIPT_START=$SECONDS
STEP_NAMES=()
STEP_DURATIONS=()

format_duration() {
  local t=$1
  local h=$((t / 3600)) m=$(( (t % 3600) / 60 )) s=$((t % 60))
  if (( h > 0 )); then printf "%dh %dm %ds" "$h" "$m" "$s"
  elif (( m > 0 )); then printf "%dm %ds" "$m" "$s"
  else printf "%ds" "$s"
  fi
}

step_start() { CURRENT_STEP_START=$SECONDS; }

step_end() {
  local name="$1"
  local dur=$(( SECONDS - CURRENT_STEP_START ))
  STEP_NAMES+=("$name")
  STEP_DURATIONS+=("$dur")
  echo -e "  ${GREEN}✓${NC} $name completed in $(format_duration $dur)"
  echo ""
}

header() {
  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
}

# SSH to jump helper
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
jump_ssh() { ssh $SSH_OPTS -i "$SSH_KEY" k8s@$JUMP_IP "$@"; }
jump_scp() { scp $SSH_OPTS -i "$SSH_KEY" "$@"; }

# Run a playbook ON the jump server
jump_playbook() {
  local playbook="$1"
  echo "  Running $playbook on jump..."
  jump_ssh "cd $PROJECT_DIR_JUMP/ansible && ansible-playbook -i inventory/homelab.yml playbooks/$playbook"
}

# =============================================================================
header "K8s Vagrant Homelab — Full Deployment"
echo ""
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Architecture: Mac → jump (bastion) → all VMs"
echo "VMs: ${#VM_NAMES[@]} — $(IFS=', '; echo "${VM_NAMES[*]}")"
echo ""

# =============================================================================
# Pre-flight: Cache sudo credentials early (avoids mid-deploy prompts)
# =============================================================================
if (( FROM_STEP <= 3 )); then
  echo -e "${YELLOW}  Requesting sudo access now (needed for /etc/hosts + sysctl)${NC}"
  echo "  (This avoids a sudo prompt in the middle of deployment)"
  sudo -v
  # Keep sudo alive in background for the duration of the script
  while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
  echo -e "  ${GREEN}✓${NC} sudo credentials cached"
else
  echo -e "  ${GREEN}✓${NC} Skipping sudo (--from-step > 3)"
fi
echo ""

# =============================================================================
# Pre-flight: Kill stale QEMU processes and check port availability
# =============================================================================
header "Pre-flight: Port cleanup"

# Kill orphaned QEMU processes from previous runs
STALE_QEMU=$(pgrep -f "qemu-system.*vagrant" 2>/dev/null || true)
if [[ -n "$STALE_QEMU" ]]; then
  echo "  Killing stale QEMU processes from previous runs..."
  pkill -f "qemu-system.*vagrant" 2>/dev/null || true
  sleep 2
  echo -e "  ${GREEN}✓${NC} Stale QEMU processes killed"
else
  echo "  No stale QEMU processes found"
fi

# Check that our required ports are free
REQUIRED_PORTS=()
for ip in "${VM_IPS[@]}"; do
  suffix="${ip##*.}"
  REQUIRED_PORTS+=("$((51000 + suffix))")
done

BLOCKED_PORTS=()
for port in "${REQUIRED_PORTS[@]}"; do
  if netstat -an 2>/dev/null | grep -qE "\.${port}\b.*LISTEN"; then
    BLOCKED_PORTS+=("$port")
  fi
done

if [[ ${#BLOCKED_PORTS[@]} -gt 0 ]]; then
  echo -e "  ${YELLOW}WARNING: Ports in use: ${BLOCKED_PORTS[*]}${NC}"
  echo "  Attempting to free them (macOS ephemeral connections)..."
  # Set macOS ephemeral port range to start above our ports (51044+)
  # This prevents future conflicts but doesn't fix current connections
  sudo sysctl -w net.inet.ip.portrange.first=51044 > /dev/null 2>&1 || true
  echo "  Waiting 10s for connections to drop..."
  sleep 10
  # Re-check
  STILL_BLOCKED=()
  for port in "${BLOCKED_PORTS[@]}"; do
    if netstat -an 2>/dev/null | grep -qE "\.${port}\b.*LISTEN"; then
      STILL_BLOCKED+=("$port")
    fi
  done
  if [[ ${#STILL_BLOCKED[@]} -gt 0 ]]; then
    echo -e "  ${RED}ERROR: Ports still in use: ${STILL_BLOCKED[*]}${NC}"
    echo "  These are likely ephemeral OS connections. Options:"
    echo "    1. Wait and retry: ./deploy.sh"
    echo "    2. Close apps that may be using these ports"
    exit 1
  fi
  echo -e "  ${GREEN}✓${NC} All ports now free"
else
  echo -e "  ${GREEN}✓${NC} All required ports (${REQUIRED_PORTS[*]}) are free"
fi
echo ""

# =============================================================================
# Steps 1-4: Parallel — vagrant up + SSH key + Mac config + download binaries
# =============================================================================
# vagrant up takes ~2min. Download binaries, SSH key, and Mac config
# have no dependency on VMs, so we run them in parallel.
# =============================================================================

# --- Start vagrant up in background ---
VAGRANT_PID=""
if [[ "$SKIP_VAGRANT" == "false" ]] && (( FROM_STEP <= 1 )); then
  header "Step 1/14: Create VMs (vagrant up) [background]"
  step_start
  cd "$SCRIPT_DIR"
  vagrant up &
  VAGRANT_PID=$!
  echo "  vagrant up running in background (PID $VAGRANT_PID)"
fi

# --- SSH key (instant) ---
if (( FROM_STEP <= 2 )); then
  header "Step 2/14: SSH Key"
  if [[ -f "$SSH_KEY" ]]; then
    echo -e "  ${GREEN}✓${NC} SSH key exists: $SSH_KEY"
  else
    echo "  Generating SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C 'k8s-homelab'
    echo -e "  ${GREEN}✓${NC} SSH key generated"
  fi
  echo ""
fi

# --- Mac config (instant, needs sudo — already cached) ---
if (( FROM_STEP <= 3 )); then
  header "Step 3/14: Configure Mac (jump + vault only)"

  # /etc/hosts — only jump and vault (for browser access)
  if grep -q "K8s Vagrant Homelab" /etc/hosts 2>/dev/null; then
    # Update existing entries if subnet changed
    sudo sed -i '' "/# BEGIN K8s Vagrant Homelab/,/# END K8s Vagrant Homelab/c\\
# BEGIN K8s Vagrant Homelab\\
${NET}.11  vault\\
${NET}.12  jump\\
# END K8s Vagrant Homelab" /etc/hosts
    echo "  /etc/hosts entries updated"
  else
    echo "  Adding jump + vault to /etc/hosts (requires sudo)..."
    printf "\n# BEGIN K8s Vagrant Homelab\n${NET}.11  vault\n${NET}.12  jump\n# END K8s Vagrant Homelab\n" | sudo tee -a /etc/hosts > /dev/null
  fi

  # SSH config — only jump
  SSH_CONFIG="$HOME/.ssh/config"
  if grep -q "K8s Vagrant Homelab" "$SSH_CONFIG" 2>/dev/null; then
    # Remove old block and rewrite
    sed -i '' '/# K8s Vagrant Homelab BEGIN/,/# K8s Vagrant Homelab END/d' "$SSH_CONFIG"
  fi
  echo "  Adding jump to SSH config..."
  cat >> "$SSH_CONFIG" << EOF

# K8s Vagrant Homelab BEGIN
Host jump
    HostName ${NET}.12
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    PreferredAuthentications publickey
# K8s Vagrant Homelab END
EOF
  chmod 600 "$SSH_CONFIG"

  echo -e "  ${GREEN}✓${NC} Mac config done"
fi

# --- Download binaries (runs while vagrant up is still going) ---
if (( FROM_STEP <= 4 )); then
  header "Step 4/14: Download K8s Binaries (Mac cache) [parallel with vagrant up]"
  step_start

  mkdir -p "$BIN_DIR"

  # Quick check: if binaries exist, skip
  if [[ -f "$BIN_DIR/kube-apiserver" ]] && [[ -f "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" ]]; then
    echo "  Binaries already cached in $BIN_DIR"
  else
    echo "  Downloading K8s binaries in parallel..."
    cd "$BIN_DIR"
    DOWNLOAD_PIDS=()

    # K8s binaries
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
      if [[ ! -f "$bin" ]]; then
        curl -sLO "$K8S_URL/$bin" &
        DOWNLOAD_PIDS+=($!)
      fi
    done

    # etcd
    if [[ ! -f "etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" ]]; then
      curl -sLO "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" &
      DOWNLOAD_PIDS+=($!)
    fi

    # containerd
    if [[ ! -f "containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" ]]; then
      curl -sLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" &
      DOWNLOAD_PIDS+=($!)
    fi

    # runc
    if [[ ! -f "runc.arm64" ]]; then
      curl -sLO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.arm64" &
      DOWNLOAD_PIDS+=($!)
    fi

    # calico
    if [[ ! -f "calico.yaml" ]]; then
      curl -sLo calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml" &
      DOWNLOAD_PIDS+=($!)
    fi

    echo "  ${#DOWNLOAD_PIDS[@]} downloads started, waiting..."
    for pid in "${DOWNLOAD_PIDS[@]}"; do wait "$pid"; done
    chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy 2>/dev/null || true
    echo "  Downloaded $(ls -1 | wc -l | tr -d ' ') files to $BIN_DIR"
  fi

  step_end "Download binaries"
fi

# --- Wait for vagrant up to finish (if it ran in background) ---
if [[ -n "$VAGRANT_PID" ]]; then
  header "Waiting for vagrant up to finish..."
  if wait "$VAGRANT_PID"; then
    step_end "vagrant up"
  else
    echo -e "  ${RED}vagrant up FAILED${NC}"
    exit 1
  fi
fi

# =============================================================================
# Step 5: Wait for jump server SSH
# =============================================================================
if (( FROM_STEP <= 5 )); then
  header "Step 5/14: Wait for Jump Server SSH"
  step_start

  # Clean stale host keys from previous VM instances
  for ip in "${VM_IPS[@]}"; do
    ssh-keygen -R "$ip" 2>/dev/null || true
  done
  ssh-keygen -R jump 2>/dev/null || true

  echo -n "  Waiting for jump ($JUMP_IP)..."
  WAIT_START=$SECONDS
  while true; do
    if jump_ssh "exit 0" &>/dev/null; then
      ELAPSED=$(( SECONDS - WAIT_START ))
      echo -e " ${GREEN}ready${NC} (${ELAPSED}s)"
      break
    fi
    if (( SECONDS - WAIT_START >= 300 )); then
      echo -e " ${RED}TIMEOUT${NC}"
      exit 1
    fi
    echo -n "."
    sleep 5
  done

  step_end "Jump SSH"
fi

# =============================================================================
# Step 6: Configure Jump Server
# =============================================================================
if (( FROM_STEP <= 6 )); then
  header "Step 6/14: Configure Jump Server"
  step_start

  # Fix home ownership
  echo -n "  Fixing home directory ownership..."
  jump_ssh "sudo chown -R k8s:k8s /home/k8s" 2>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Copy SSH key
  echo -n "  Copying SSH key..."
  jump_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
  jump_scp "$SSH_KEY" k8s@$JUMP_IP:~/.ssh/k8slab.key 2>/dev/null
  jump_ssh "chmod 600 ~/.ssh/k8slab.key" 2>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Create SSH config for all VMs on jump (dynamically from VM_NAMES/VM_IPS)
  echo -n "  Creating SSH config on jump..."
  SSH_CONFIG_CONTENT=""
  for i in "${!VM_NAMES[@]}"; do
    name="${VM_NAMES[$i]}"
    ip="${VM_IPS[$i]}"
    [[ "$name" == "jump" ]] && continue
    SSH_CONFIG_CONTENT+="Host ${name}
    HostName ${ip}
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

"
  done
  jump_ssh "cat > ~/.ssh/config << 'SSHEOF'
${SSH_CONFIG_CONTENT}SSHEOF
chmod 600 ~/.ssh/config" 2>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Copy project files to jump
  echo -n "  Copying ansible directory to jump..."
  jump_ssh "mkdir -p $PROJECT_DIR_JUMP" 2>/dev/null
  rsync -az --exclude='.vault-credentials' --exclude='fact_cache' \
    -e "ssh $SSH_OPTS -i $SSH_KEY" \
    "$ANSIBLE_DIR/" k8s@$JUMP_IP:$PROJECT_DIR_JUMP/ansible/ 2>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Copy binaries to jump IN BACKGROUND (not needed until Step 10)
  echo "  Copying binaries to jump [background]..."
  (
    jump_ssh "mkdir -p /tmp/k8s-binaries /tmp/etcd-cache /tmp/containerd-cache" 2>/dev/null
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
      [[ -f "$BIN_DIR/$bin" ]] && jump_scp "$BIN_DIR/$bin" k8s@$JUMP_IP:/tmp/k8s-binaries/ 2>/dev/null || true
    done
    [[ -f "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" ]] && \
      jump_scp "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" k8s@$JUMP_IP:/tmp/etcd-cache/ 2>/dev/null || true
    [[ -f "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" ]] && \
      jump_scp "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" k8s@$JUMP_IP:/tmp/containerd-cache/ 2>/dev/null || true
    [[ -f "$BIN_DIR/runc.arm64" ]] && \
      jump_scp "$BIN_DIR/runc.arm64" k8s@$JUMP_IP:/tmp/containerd-cache/ 2>/dev/null || true
    [[ -f "$BIN_DIR/calico.yaml" ]] && \
      jump_scp "$BIN_DIR/calico.yaml" k8s@$JUMP_IP:/tmp/ 2>/dev/null || true
    # Only create pre-cached markers if actual files were copied
    jump_ssh '[[ -f /tmp/k8s-binaries/kube-apiserver ]] && touch /tmp/k8s-binaries/.pre-cached' 2>/dev/null || true
    jump_ssh '[[ -f /tmp/etcd-cache/etcd-v*.tar.gz ]] && touch /tmp/etcd-cache/.pre-cached' 2>/dev/null || true
    jump_ssh '[[ -f /tmp/containerd-cache/containerd-*.tar.gz ]] && touch /tmp/containerd-cache/.pre-cached' 2>/dev/null || true
  ) &
  BINARY_COPY_PID=$!

  # Wait for Ansible (cloud-init)
  echo -n "  Waiting for ansible-playbook (cloud-init)..."
  ANSIBLE_WAIT=0
  while ! jump_ssh 'which ansible-playbook' &>/dev/null; do
    sleep 5
    ANSIBLE_WAIT=$((ANSIBLE_WAIT + 5))
    echo -n "."
    if (( ANSIBLE_WAIT >= 120 )); then
      echo -e " ${RED}TIMEOUT${NC}"
      break
    fi
  done
  echo -e " ${GREEN}OK${NC}"

  # Install Python dependencies (jmespath needed for json_query filter)
  echo -n "  Installing Python dependencies on jump..."
  jump_ssh "pip3 install --break-system-packages jmespath" &>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Install Ansible collections
  echo -n "  Installing Ansible collections..."
  jump_ssh "ansible-galaxy collection install community.hashi_vault ansible.posix" &>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # Vault environment
  echo -n "  Configuring Vault environment..."
  jump_ssh 'grep -q "VAULT_ADDR=" ~/.bashrc 2>/dev/null || cat >> ~/.bashrc << '\''BASHRC'\''

# Vault environment
export VAULT_ADDR="http://vault:8200"
export VAULT_TOKEN=$(jq -r .root_token ~/vagrant-lab/ansible/.vault-credentials/vault-init.json 2>/dev/null)

vault-unseal() {
    echo "Unsealing Vault..."
    local creds="$HOME/vagrant-lab/ansible/.vault-credentials/vault-init.json"
    if [[ ! -f "$creds" ]]; then echo "Error: $creds not found"; return 1; fi
    for key in $(jq -r '\''.keys[:3][]'\'' "$creds"); do
        vault operator unseal "$key"
    done
    echo "Done. Check: vault status"
}
BASHRC' 2>/dev/null
  echo -e " ${GREEN}OK${NC}"

  # .profile
  jump_ssh '[[ -f ~/.profile ]] || cat > ~/.profile << '\''EOF'\''
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
fi
EOF' 2>/dev/null

  step_end "Jump config"
fi

# =============================================================================
# Step 7: Connectivity Test (jump → all VMs)
# =============================================================================
if (( FROM_STEP <= 7 )); then
  header "Step 7/14: Connectivity Test (via jump)"
  step_start

  echo "  Testing SSH from jump to all VMs..."
  echo ""
  SUCCESS=0 FAIL=0
  for i in "${!VM_NAMES[@]}"; do
    name="${VM_NAMES[$i]}"
    [[ "$name" == "jump" ]] && continue
    printf "  %-12s " "$name"
    if jump_ssh "ssh -o ConnectTimeout=5 -o BatchMode=yes $name echo ok" 2>/dev/null | grep -q ok; then
      echo -e "${GREEN}OK (via jump)${NC}"
      SUCCESS=$((SUCCESS + 1))
    else
      echo -e "${RED}FAILED${NC}"
      FAIL=$((FAIL + 1))
    fi
  done
  echo ""
  echo "  Results: $SUCCESS/${#VM_NAMES[@]} reachable via jump"

  step_end "Connectivity"
fi

# =============================================================================
# Step 8: Vault Full Setup (bootstrap + PKI) — runs ON jump
# =============================================================================
if (( FROM_STEP <= 8 )); then
  header "Step 8/14: Vault Full Setup (on jump)"
  step_start
  jump_playbook "vault-full-setup.yml"
  step_end "Vault setup"
fi

# =============================================================================
# Step 9: K8s Certificates — runs ON jump
# =============================================================================
if (( FROM_STEP <= 9 )); then
  header "Step 9/14: Deploy K8s Certificates (on jump)"
  step_start
  jump_playbook "k8s-certs.yml"
  step_end "K8s certs"
fi

# =============================================================================
# Step 10: etcd + HAProxy (parallel) — runs ON jump
# =============================================================================
if (( FROM_STEP <= 10 )); then
  # Wait for binary copy to finish (started in Step 6 background)
  if [[ -n "${BINARY_COPY_PID:-}" ]]; then
    echo -n "  Waiting for binary copy to jump to finish..."
    wait "$BINARY_COPY_PID" && echo -e " ${GREEN}OK${NC}" || echo -e " ${YELLOW}WARNING: some copies may have failed${NC}"
    unset BINARY_COPY_PID
  fi

  header "Step 10/14: Deploy etcd + HAProxy (parallel, on jump)"
  step_start

  echo "  Launching etcd + HAProxy in parallel on jump..."

  jump_ssh "cd $PROJECT_DIR_JUMP/ansible && ansible-playbook -i inventory/homelab.yml playbooks/etcd-cluster.yml" &
  ETCD_PID=$!

  jump_ssh "cd $PROJECT_DIR_JUMP/ansible && ansible-playbook -i inventory/homelab.yml playbooks/haproxy.yml" &
  HAPROXY_PID=$!

  ETCD_OK=false HAPROXY_OK=false
  wait $ETCD_PID && ETCD_OK=true || true
  wait $HAPROXY_PID && HAPROXY_OK=true || true

  [[ "$ETCD_OK" == "true" ]] && echo -e "  ${GREEN}✓${NC} etcd cluster deployed" || echo -e "  ${RED}✗${NC} etcd FAILED"
  [[ "$HAPROXY_OK" == "true" ]] && echo -e "  ${GREEN}✓${NC} HAProxy deployed" || echo -e "  ${RED}✗${NC} HAProxy FAILED"

  if [[ "$ETCD_OK" != "true" ]]; then
    echo -e "${RED}etcd failed — cannot continue${NC}"
    exit 1
  fi

  step_end "etcd + HAProxy"
fi

# =============================================================================
# Step 10.5: Store etcd encryption key in Vault
# =============================================================================
if (( FROM_STEP <= 10 )); then
  header "Step 10.5/14: Store etcd encryption key in Vault"
  step_start
  jump_playbook "vault-etcd-encryption-key.yml"
  step_end "etcd encryption key"
fi

# =============================================================================
# Step 11: Control Plane — runs ON jump
# =============================================================================
if (( FROM_STEP <= 11 )); then
  header "Step 11/14: Deploy Control Plane (on jump)"
  step_start
  jump_playbook "control-plane.yml"
  step_end "Control plane"
fi

# =============================================================================
# Step 12: Worker Nodes — runs ON jump
# =============================================================================
if (( FROM_STEP <= 12 )); then
  header "Step 12/14: Deploy Worker Nodes (on jump)"
  step_start
  jump_playbook "worker.yml"
  step_end "Workers"
fi

# =============================================================================
# Step 13: Calico CNI — runs ON jump
# =============================================================================
if (( FROM_STEP <= 13 )); then
  header "Step 13/14: Install Calico CNI (on jump)"
  step_start

  jump_ssh bash -s << 'CALICO'
    set -e
    [[ -f /tmp/calico.yaml ]] || curl -sL "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml" -o /tmp/calico.yaml
    sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|; s|#   value: "192.168.0.0/16"|  value: "10.244.0.0/16"|' /tmp/calico.yaml
    kubectl apply -f /tmp/calico.yaml
CALICO

  echo "  Waiting 30s for Calico to initialize..."
  sleep 30
  echo "  Cluster status:"
  jump_ssh "kubectl get nodes -o wide" || true

  step_end "Calico CNI"
fi

# =============================================================================
# Step 14: Verify cluster — runs ON jump
# =============================================================================
if (( FROM_STEP <= 14 )); then
  header "Step 14/14: Verify Cluster"

  echo ""
  echo "  Nodes:"
  jump_ssh "kubectl get nodes -o wide" || true
  echo ""
  echo "  Pods (all namespaces):"
  jump_ssh "kubectl get pods -A" || true
  echo ""
fi

# =============================================================================
# Summary
# =============================================================================
TOTAL_DURATION=$(( SECONDS - SCRIPT_START ))

header "Deployment Complete!"
echo ""
echo " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo " Timing Breakdown:"
for i in "${!STEP_NAMES[@]}"; do
  printf "   %-20s %s\n" "${STEP_NAMES[$i]}:" "$(format_duration ${STEP_DURATIONS[$i]})"
done
echo "   ─────────────────────────────────"
printf "   %-20s %s\n" "Total:" "$(format_duration $TOTAL_DURATION)"
echo ""
echo " IP Addresses:"
for i in "${!VM_NAMES[@]}"; do
  printf "   %-12s %s\n" "${VM_NAMES[$i]}" "${VM_IPS[$i]}"
done
echo ""
echo " Access (bastion architecture):"
echo "   SSH to jump:  ssh jump"
echo "   From jump:    ssh master-1, ssh worker-1, etc."
echo "   kubectl:      ssh jump && kubectl get nodes"
echo "   Vault UI:     http://${NET}.11:8200"
echo ""
echo -e "${BLUE}Total time: $(format_duration $TOTAL_DURATION)${NC}"
