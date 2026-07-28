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
# Builder image for remotive-topology (RemotiveTopology) workflow pods:
# remotive-instance-template (packer bake + KCC publish) and remotive-launcher (ephemeral
# GCE driver). Trimmed from the aaos-builder image — no Android toolchain,
# no Node.js/Gemini.

# Allow user to choose distribution, e.g. ubuntu:24.04
ARG LINUX_DISTRIBUTION=ubuntu:24.04
FROM ${LINUX_DISTRIBUTION}

# Gcloud CLI and kubectl version.
ARG GCLOUD_CLI_VERSION="latest"
ARG KUBECTL_VERSION="latest"
ARG PACKER_VERSION="1.15.0"

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends apt-utils && \
    apt-get -y upgrade && \
    apt-get install -y --no-install-recommends \
    apt-transport-https ca-certificates \
    git gnupg curl wget jq rsync less vim ssh sudo procps \
    python3 python3-pip python3-requests python3-yaml python3-venv \
    zip unzip coreutils findutils gawk bsdutils lsof psmisc && \
    rm -rf /var/lib/apt/lists/*

# gcloud SDK (gcloud storage used for GCS staging) and kubectl (KCC CR apply).
# GCS:START
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update -y && \
    [ "$GCLOUD_CLI_VERSION" = "latest" ] && apt-get install -y google-cloud-cli || \
      apt-get install -y google-cloud-cli="$GCLOUD_CLI_VERSION" google-cloud-cli-anthoscli="$GCLOUD_CLI_VERSION" && \
    [ "$KUBECTL_VERSION" = "latest" ] &&  apt-get install -y kubectl || apt-get install -y kubectl="$KUBECTL_VERSION" && \
    apt-get -y clean
# GCS:END

# Packer for VM image baking via HashiCorp APT repo.
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list && \
    apt-get update -y && \
    [ "$PACKER_VERSION" = "latest" ] && apt-get install -y packer || apt-get install -y "packer=${PACKER_VERSION}-1" && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/* && \
    packer version

# Add USER and provide sudo access (uid 1000 matches workflow securityContext fsGroup).
# ubuntu:24.04 (unlike 22.04) ships a default "ubuntu" account already at UID 1000;
# drop it first so useradd -u 1000 works on either base image.
ARG USER=builder
RUN existing_uid1000="$(getent passwd 1000 | cut -d: -f1)" && \
    if [ -n "${existing_uid1000}" ] && [ "${existing_uid1000}" != "${USER}" ]; then \
        userdel -r "${existing_uid1000}" 2>/dev/null || true; \
    fi && \
    useradd -u 1000 -ms /bin/bash ${USER} && \
    passwd -d ${USER} && \
    usermod -aG sudo ${USER} && \
    echo "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers

USER ${USER}
WORKDIR /home/${USER}

ENV PATH="/usr/local/bin:/usr/bin:$PATH"
