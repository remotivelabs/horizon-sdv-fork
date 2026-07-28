#!/usr/bin/env bash

# Copyright (c) 2026 RemotiveLabs, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:
#   Initialise a RemotiveTopology (remotive-topology) host. Runs as root inside
#   the Packer builder VM. Bash translation of the upstream remote-deployment
#   ansible roles (docker, remotivebus, remotive_cli) plus the dependencies.yaml
#   playbook from remotivelabs-ecu-simulations examples/remote-deployment.
#
#   Installs:
#     - base packages (CAN utilities, networking tools, rsync)
#     - vcan kernel module support (linux-modules-extra when needed)
#     - Docker CE + compose plugin (docker group for DEFAULT_USER)
#     - remotivebusd + remotivelabs-cli from packages.remotivelabs.com
#     - nodejs/npm (Ubuntu repo) for workloads/common/mtk-connect's JS scripts,
#       invoked from the guest by remotive_argo_remote_entry.sh
#
#   Environment:
#     - DEFAULT_USER: Linux account for interactive SSH (created if missing;
#       docker group; no baked SSH keys — access is via OS Login / IAP).

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

DEFAULT_USER=${DEFAULT_USER:-horizon}

echo "== remotive host initialise: base packages =="
apt-get update -y
# adb: the MTK Connect agent spawns the adb binary for the screen/terminal/touch
# interfaces of descriptor adb_devices (mtk_connect.sh only auto-detects hosts
# from adb when MTK_CONNECT_HOST_LIST is not provided, so having adb installed
# does not affect the launcher's explicit device registration).
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    bridge-utils iproute2 net-tools pciutils \
    make can-utils socat rsync jq unzip \
    python3 python3-yaml nodejs npm adb

echo "== remotive host initialise: SSH key-only login =="
cat > /etc/ssh/sshd_config.d/99-disable-passwords.conf <<'EOF'
PasswordAuthentication no
ChallengeResponseAuthentication no
EOF

echo "== remotive host initialise: vcan / vhost kernel modules =="
# Virtual CAN is required by most topologies; linux-modules-extra carries it on
# GCE Ubuntu images. vhost_vsock/vhost_net are needed only by Cuttlefish-based
# topologies — install alongside vcan, load at boot best-effort.
if ! modprobe vcan 2>/dev/null; then
    apt-get install -y "linux-modules-extra-$(uname -r)"
    modprobe vcan
fi
cat > /etc/modules-load.d/remotive-topology.conf <<'EOF'
vcan
vhost_vsock
vhost_net
EOF

echo "== remotive host initialise: default user ${DEFAULT_USER} =="
if ! id "${DEFAULT_USER}" >/dev/null 2>&1; then
    useradd -ms /bin/bash "${DEFAULT_USER}"
fi

echo "== remotive host initialise: Docker CE =="
# Match the upstream docker role: skip when docker is already present (unknown origin).
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "${DEFAULT_USER}"
systemctl enable docker

echo "== remotive host initialise: RemotiveLabs apt repo (remotivebusd, remotivelabs-cli) =="
curl -fsSL https://packages.remotivelabs.com/apt-repo-signing-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/remotivelabs-apt.gpg
echo "deb [signed-by=/usr/share/keyrings/remotivelabs-apt.gpg] https://packages.remotivelabs.com remotivelabs-apt main" \
    > /etc/apt/sources.list.d/remotivelabs.list
apt-get update -y
apt-get install -y remotivebusd remotivelabs-cli

echo "== remotive host initialise: versions =="
docker --version
docker compose version
remotive --version || true
node --version
npm --version

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "== remotive host initialise: done =="
