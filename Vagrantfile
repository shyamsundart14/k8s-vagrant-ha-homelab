# -*- mode: ruby -*-
# vi: set ft=ruby :

# =============================================================================
# Kubernetes HA Homelab on Vagrant (Apple Silicon / QEMU)
# =============================================================================
# Mirrors the k8s-utm-ha-homelab architecture using Vagrant for VM management.
# Reuses the same Ansible roles for K8s deployment.
#
# Architecture:
#   - 11 Ubuntu 24.04 ARM64 VMs on QEMU with socket_vmnet networking
#   - HashiCorp Vault PKI for TLS certificates
#   - 3-node etcd cluster with mutual TLS
#   - HA control plane (2 masters behind HAProxy)
#   - Jump/bastion server for kubectl access
#   - Calico CNI for pod networking
#
# Usage:
#   ./setup.sh           # one-time: symlink roles, generate SSH key
#   vagrant up            # create all VMs
#   cd ansible && ansible-playbook -i inventory/homelab.yml playbooks/deploy.yml --ask-become-pass
# =============================================================================

require 'fileutils'
require 'yaml'

# --- Auto-detect network prefix from socket_vmnet ---
# Reads from ansible/inventory/group_vars/all.yml (single source of truth)
# Falls back to detecting from socket_vmnet plist, then to 192.168.105
group_vars_path = File.join(__dir__, "ansible", "inventory", "group_vars", "all.yml")
if File.exist?(group_vars_path)
  gv = YAML.safe_load(File.read(group_vars_path))
  NETWORK_PREFIX = gv["network_prefix"] || "192.168.105"
else
  # Auto-detect from socket_vmnet plist
  plist_path = "/Library/LaunchDaemons/homebrew.mxcl.socket_vmnet.plist"
  if File.exist?(plist_path)
    match = File.read(plist_path).match(/vmnet-gateway=(\d+\.\d+\.\d+)/)
    NETWORK_PREFIX = match ? match[1] : "192.168.105"
  else
    NETWORK_PREFIX = "192.168.105"
  end
end

# --- SSH Key Setup ---
ssh_key_path = File.expand_path("~/.ssh/k8slab.key")
unless File.exist?(ssh_key_path)
  system("ssh-keygen -t ed25519 -f #{ssh_key_path} -N '' -C 'k8s-homelab'")
end
ssh_pub_key = File.read("#{ssh_key_path}.pub").strip

# --- VM Definitions ---
# name, ip_suffix, ram_mb, cpus (matches k8s-utm-ha-homelab specs)
VMS = [
  { name: "haproxy",  ip: 10, ram: 2048, cpu: 2 },
  { name: "vault",    ip: 11, ram: 4096, cpu: 2 },
  { name: "jump",     ip: 12, ram: 4096, cpu: 2 },
  { name: "etcd-1",   ip: 21, ram: 2048, cpu: 2 },
  { name: "etcd-2",   ip: 22, ram: 2048, cpu: 2 },
  { name: "etcd-3",   ip: 23, ram: 2048, cpu: 2 },
  { name: "master-1", ip: 31, ram: 4096, cpu: 2 },
  { name: "master-2", ip: 32, ram: 4096, cpu: 2 },
  { name: "worker-1", ip: 41, ram: 6144, cpu: 2 },
  { name: "worker-2", ip: 42, ram: 6144, cpu: 2 },
  { name: "worker-3", ip: 43, ram: 6144, cpu: 2 },
]

# /etc/hosts entries for all VMs
HOSTS_ENTRIES = VMS.map { |vm| "#{NETWORK_PREFIX}.#{vm[:ip]}  #{vm[:name]}" }.join("\\n")

Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 600

  VMS.each do |vm|
    config.vm.define vm[:name] do |node|
      node.vm.box      = "perk/ubuntu-24.04-arm64"
      node.vm.hostname = vm[:name]
      node.vm.synced_folder ".", "/vagrant", disabled: true

      node.vm.provider "qemu" do |qemu|
        qemu.memory   = vm[:ram].to_s
        qemu.cpus     = vm[:cpu]
        qemu.ssh_port = 51000 + vm[:ip]
        qemu.qemu_bin = %W(
          /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client
          /opt/homebrew/var/run/socket_vmnet
          /opt/homebrew/bin/qemu-system-aarch64
        )
        qemu.extra_qemu_args = [
          "-device", "virtio-net-pci,netdev=net1,mac=de:ad:be:ef:00:#{vm[:ip]}",
          "-netdev", "socket,id=net1,fd=3",
        ]
      end

      # --- Base provisioning (all VMs) ---
      node.vm.provision "shell", inline: <<-SHELL
        apt-get update -y

        # Create k8s user with passwordless sudo
        if ! id -u k8s &>/dev/null; then
          useradd -m -s /bin/bash -G sudo k8s
          echo 'k8s ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/k8s
          chmod 440 /etc/sudoers.d/k8s
          mkdir -p /home/k8s/.ssh
          echo '#{ssh_pub_key}' > /home/k8s/.ssh/authorized_keys
          chmod 700 /home/k8s/.ssh
          chmod 600 /home/k8s/.ssh/authorized_keys
          chown -R k8s:k8s /home/k8s/.ssh
        fi

        # Configure static IP via socket_vmnet interface
        IFACE=$(ip -o link | awk '/de:ad:be:ef:00:#{vm[:ip]}/{print $2}' | tr -d ":")
        echo "socket_vmnet interface: $IFACE"
        printf "network:\n  version: 2\n  ethernets:\n    $IFACE:\n      dhcp4: no\n      addresses:\n        - #{NETWORK_PREFIX}.#{vm[:ip]}/24\n" > /etc/netplan/99-static.yaml
        chmod 600 /etc/netplan/99-static.yaml
        netplan apply --skip-backends=openvswitch 2>/dev/null

        # Populate /etc/hosts with all VM hostnames
        printf "#{HOSTS_ENTRIES}\\n" >> /etc/hosts

        echo "-------------------------------"
        echo "#{vm[:name]} is up at #{NETWORK_PREFIX}.#{vm[:ip]}"
        echo "-------------------------------"
      SHELL

      # --- Jump server: install Ansible + tools ---
      if vm[:name] == "jump"
        node.vm.provision "shell", inline: <<-SHELL
          apt-get install -y software-properties-common git python3-pip python3-venv \\
                             sshpass jq curl unzip openssh-server

          # Install Ansible via pip (consistent version)
          pip3 install --break-system-packages ansible hvac jmespath

          # Install HashiCorp Vault CLI
          wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
          echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg arch=arm64] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
          apt-get update
          apt-get install -y vault

          # Install Ansible collections as k8s user
          sudo -H -u k8s bash -c 'ansible-galaxy collection install community.hashi_vault ansible.posix'

          echo "-------------------------------"
          echo "jump server tools installed"
          echo "-------------------------------"
        SHELL
      end

    end
  end
end
