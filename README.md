# Kubernetes HA Homelab on Vagrant (Apple Silicon)

Same production-grade K8s cluster as [k8s-utm-ha-homelab](../k8s-utm-ha-homelab), but using **Vagrant + QEMU** instead of UTM for VM management. Reuses the existing Ansible roles — no code duplication.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Mac Host (Apple Silicon)                        │
│           SSH only to jump (bastion) — no direct VM access         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                     Vagrant / QEMU + socket_vmnet
                      subnet auto-detected from
                        socket_vmnet config
                               │ (SSH only)
                         ┌─────┴─────┐
                         │   Jump    │
                         │   .12     │
                         │ (bastion) │
                         │  kubectl  │
                         │  ansible  │
                         └─────┬─────┘
                               │ (SSH to all VMs)
       ┌───────────┬───────────┼───────────┬───────────┐
       │           │           │           │           │
  ┌────┴────┐ ┌────┴────┐ ┌────┴────┐ ┌────┴────┐     │
  │ HAProxy │ │  Vault  │ │  etcd   │ │ master  │     │
  │   .10   │ │   .11   │ │ .21-.23 │ │ .31-.32 │     │
  │   (LB)  │ │  (PKI)  │ │(cluster)│ │  (CP)   │     │
  └─────────┘ └─────────┘ └─────────┘ └─────────┘     │
                                                       │
                                    ┌──────────────────┘
                                    │
                              ┌─────┴─────┐
                              │  workers  │
                              │ .41-.43   │
                              └───────────┘
```

## Key Difference from UTM Version

| | UTM Version | Vagrant Version |
|---|---|---|
| VM management | UTM + utmctl CLI | Vagrant + QEMU provider |
| Ansible controller | Jump server (bastion) | Jump server (bastion) — same pattern |
| VM provisioning | cloud-init ISO | Vagrant shell provisioner |
| SSH from Mac | Jump only (bastion) | Jump only (bastion) — same pattern |
| Roles | Original | **Included** (same roles) |

## VM Specifications

Subnet is auto-detected from socket_vmnet (`/Library/LaunchDaemons/homebrew.mxcl.socket_vmnet.plist`).
All IPs use the format `<prefix>.<suffix>` where prefix comes from the gateway config.

| VM | Role | IP Suffix | vCPU | RAM | SSH Port |
|----|------|-----------|------|-----|----------|
| haproxy | API Server Load Balancer | .10 | 2 | 2 GB | 51010 |
| vault | PKI & Secrets (Vault 1.15.4) | .11 | 2 | 4 GB | 51011 |
| jump | kubectl access point | .12 | 2 | 4 GB | 51012 |
| etcd-1 | etcd cluster member | .21 | 2 | 2 GB | 51021 |
| etcd-2 | etcd cluster member | .22 | 2 | 2 GB | 51022 |
| etcd-3 | etcd cluster member | .23 | 2 | 2 GB | 51023 |
| master-1 | K8s control plane | .31 | 2 | 4 GB | 51031 |
| master-2 | K8s control plane | .32 | 2 | 4 GB | 51032 |
| worker-1 | K8s worker node | .41 | 2 | 6 GB | 51041 |
| worker-2 | K8s worker node | .42 | 2 | 6 GB | 51042 |
| worker-3 | K8s worker node | .43 | 2 | 6 GB | 51043 |
| **Total** | **11 VMs** | | **22** | **42 GB** | |

## Prerequisites

- **macOS** on Apple Silicon
- **Vagrant** with QEMU provider: `vagrant plugin install vagrant-qemu`
- **socket_vmnet**: `brew install socket_vmnet`
- **Ansible** on Mac: `brew install ansible`
- **Python hvac**: `pip3 install hvac`
- **~42 GB free RAM**

## Quick Start

```bash
# 1. One-time setup (generate SSH key, check prerequisites)
./setup.sh

# 2. Install Ansible collections
cd ansible && ansible-galaxy collection install -r requirements.yml && cd ..
```

Two fully automated options to deploy the entire cluster end-to-end:

### Option A: Shell Script (`deploy.sh`)

Same approach as `k8s-utm-ha-homelab.sh` — runs `vagrant up`, configures jump
(bastion), then SSHes into jump to run each playbook with per-step timing.

```bash
./deploy.sh                     # Full deploy (vagrant up + all 14 steps)
./deploy.sh --ansible-only      # Skip vagrant up, run playbooks only
./deploy.sh --from-step 8       # Resume from step 8 (Vault setup)
```

### Option B: Ansible Playbook (`deploy.yml`)

Same approach as `k8s-utm-ha-homelab.yml` — a single Ansible playbook that
orchestrates the entire deployment. Phase 1-2 run on Mac, Phase 3 runs ON jump.

```bash
vagrant up                      # Create VMs first
cd ansible
ansible-playbook -i inventory/localhost.yml playbooks/deploy.yml --ask-become-pass
```

## Project Structure

```
vagrant-lab/
├── Vagrantfile                    # 11 VMs (QEMU + socket_vmnet)
├── setup.sh                       # One-time: SSH key, prereq check
├── deploy.sh                      # Shell script deployment (like k8s-utm-ha-homelab.sh)
├── README.md
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml
    ├── inventory/
    │   ├── localhost.yml          # Mac-side: only localhost + jump (bastion)
    │   └── homelab.yml            # Jump-side: all VMs (no ansible_host)
    ├── playbooks/
    │   ├── deploy.yml             # Ansible playbook deployment (like k8s-utm-ha-homelab.yml)
    │   ├── vault-full-setup.yml   # Vault bootstrap + PKI
    │   ├── vault-bootstrap.yml    # Vault only
    │   ├── vault-pki.yml          # PKI only
    │   ├── k8s-certs.yml          # Issue & deploy certificates
    │   ├── etcd-cluster.yml       # Deploy etcd
    │   ├── haproxy.yml            # Deploy HAProxy
    │   ├── control-plane.yml      # Deploy K8s masters
    │   ├── worker.yml             # Deploy K8s workers
    │   └── ping.yml               # Connectivity test
    └── roles/                     # Ansible roles (from k8s-utm-ha-homelab)
```

Mirrors the UTM project structure:

| UTM Project | Vagrant Lab | Purpose |
|---|---|---|
| `scripts/k8s-utm-ha-homelab.sh` | `deploy.sh` | Shell script — full deploy with timing |
| `ansible/playbooks/k8s-utm-ha-homelab.yml` | `ansible/playbooks/deploy.yml` | Ansible playbook — full deploy |
| `ansible/roles/` | `ansible/roles/` | All roles included in repo |

## Individual Playbooks

Component playbooks run **ON the jump server** (bastion architecture).
SSH to jump first, then run playbooks using the jump-side inventory:

```bash
# SSH to jump
ssh jump

# On jump server:
cd ~/vagrant-lab/ansible

# Test connectivity from jump to all VMs
ansible-playbook -i inventory/homelab.yml playbooks/ping.yml

# Deploy components individually
ansible-playbook -i inventory/homelab.yml playbooks/vault-full-setup.yml
ansible-playbook -i inventory/homelab.yml playbooks/k8s-certs.yml
ansible-playbook -i inventory/homelab.yml playbooks/etcd-cluster.yml
ansible-playbook -i inventory/homelab.yml playbooks/haproxy.yml
ansible-playbook -i inventory/homelab.yml playbooks/control-plane.yml
ansible-playbook -i inventory/homelab.yml playbooks/worker.yml
```

## VM Management

```bash
vagrant status                  # Show all VM states
vagrant up haproxy vault jump   # Start specific VMs
ssh jump                        # SSH to jump (bastion) from Mac
ssh jump "ssh master-1"         # SSH to cluster VMs through jump
vagrant halt                    # Stop all VMs
vagrant destroy -f              # Delete all VMs
```

## SSH Architecture (Bastion)

```
Mac → jump (only direct SSH target)
       ├── haproxy
       ├── vault
       ├── etcd-1, etcd-2, etcd-3
       ├── master-1, master-2
       └── worker-1, worker-2, worker-3
```

- Mac SSH config only has `jump` entry
- Mac `/etc/hosts` only has `jump` and `vault` (for browser access)
- All ansible playbooks run ON the jump server
- `kubectl` runs from jump server
