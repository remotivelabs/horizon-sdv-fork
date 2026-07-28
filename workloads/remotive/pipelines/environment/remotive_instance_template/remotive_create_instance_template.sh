#!/usr/bin/env bash

# Copyright (c) 2026 RemotiveLabs, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Description:
#   Bake the remotive-topology (RemotiveTopology) golden image with Packer and
#   publish a GCE instance template via KCC ComputeInstanceTemplate — the remotive
#   analogue of cf_instance_template/cf_create_instance_template.sh (stages 1/3;
#   there is no SSH-metadata stage: access is OS Login / IAP, no baked keys).
#
#   Compute Engine REST operations (image/template delete, orphan Packer disks,
#   OS Login key prune) use the shared helper
#   workloads/android/pipelines/common/gcp/gcp_compute_rest.py with a
#   cloud-platform token from the GCE metadata server.
#
# Stages:
#   1 (default)    Packer build → global disk image → KCC ComputeInstanceTemplate
#   3              Delete this target's KCC CR, GCP template, image, builder VMs
#   orphan-disks   Best-effort delete all unattached packer-* disks in ZONE (Argo onExit)
#
# Environment (defaults set in the block below; override via env / Helm / Argo):
#   PROJECT, REGION, ZONE, NETWORK, SUBNET, SERVICE_ACCOUNT
#   MACHINE_TYPE, BOOT_DISK_SIZE, BOOT_DISK_TYPE
#   OS_PROJECT, OS_FAMILY (image family; tracks latest image in family)
#   REMOTIVE_INSTANCE_NAME  Instance/template naming stem (default remotive-vm)
#   DEFAULT_USER       Login account baked into the image (docker group)
#   ENABLE_NESTED_VIRTUALIZATION  "true" for Cuttlefish-capable templates
#   MAX_RUN_DURATION   Max lifetime of VMs created FROM the template (default 12h; 0 = uncapped)
#   PACKER_BUILD_MAX_RUN_DURATION  Max lifetime of the Packer BUILDER VM only (default 4h)
#   PACKER_USE_IAP / PACKER_SSH_TIMEOUT / PACKER_IAP_TUNNEL_LAUNCH_WAIT
#   WORKFLOWS_NAMESPACE  Namespace for the KCC ComputeInstanceTemplate CR

set -uo pipefail

GREEN='\033[1;32m'
RED='\033[1;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
SCRIPT_NAME=$(basename "$0")

REMOTIVE_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root; prefer WORKSPACE (Argo git artifact) so the shared gcp helpers resolve.
REPO_ROOT="${WORKSPACE:-$(cd "${REMOTIVE_SCRIPT_PATH}/../../../../.." && pwd)}"

# -----------------------------------------------------------------------------
# Environment defaults (authoritative — single place for default literals)
# -----------------------------------------------------------------------------
BOOT_DISK_SIZE=${BOOT_DISK_SIZE:-100GB}
BOOT_DISK_SIZE=$(echo "${BOOT_DISK_SIZE}" | awk '{print toupper($0)}' | xargs)
BOOT_DISK_TYPE=${BOOT_DISK_TYPE:-pd-balanced}
DEFAULT_USER=${DEFAULT_USER:-horizon}
ENABLE_NESTED_VIRTUALIZATION=${ENABLE_NESTED_VIRTUALIZATION:-false}
MACHINE_TYPE=${MACHINE_TYPE:-e2-standard-4}
MACHINE_TYPE=$(echo "${MACHINE_TYPE}" | xargs)
MAX_RUN_DURATION=${MAX_RUN_DURATION:-12h}
NETWORK=${NETWORK:-sdv-network}
OS_PROJECT=${OS_PROJECT:-ubuntu-os-cloud}
OS_FAMILY=${OS_FAMILY:-ubuntu-2404-lts-amd64}
PACKER_USE_IAP=${PACKER_USE_IAP:-true}
PACKER_SSH_TIMEOUT=${PACKER_SSH_TIMEOUT:-15m}
PACKER_IAP_TUNNEL_LAUNCH_WAIT=${PACKER_IAP_TUNNEL_LAUNCH_WAIT:-300}
PROJECT=${PROJECT:-$(gcloud config list --format 'value(core.project)' 2>/dev/null | head -n 1)}
REGION=${REGION:-${CLOUD_REGION:-europe-west1}}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-$(gcloud projects describe "${PROJECT}" --format='get(projectNumber)' 2>/dev/null)-compute@developer.gserviceaccount.com}
REMOTIVE_INSTANCE_NAME=${REMOTIVE_INSTANCE_NAME:-remotive-vm}
REMOTIVE_INSTANCE_NAME=$(echo "${REMOTIVE_INSTANCE_NAME}" | awk '{print tolower($0)}' | xargs)
SUBNET=${SUBNET:-sdv-subnet}
WORKFLOWS_NAMESPACE=${WORKFLOWS_NAMESPACE:-workflows}
ZONE=${ZONE:-${CLOUD_ZONE:-europe-west1-d}}
WORKSPACE=${WORKSPACE:-}

# -----------------------------------------------------------------------------
# Derived GCP / KCC resource names
# -----------------------------------------------------------------------------
declare remotive_name=${REMOTIVE_INSTANCE_NAME//./-}
remotive_name=${remotive_name//\//-}
declare -r vm_remotive_image=image-"${remotive_name}"
declare -r vm_remotive_instance_template=instance-template-"${remotive_name}"
declare -r packer_template_path="${REMOTIVE_SCRIPT_PATH}/packer/remotive.pkr.hcl"
declare -r packer_provision_script_path="${REMOTIVE_SCRIPT_PATH}/packer/provision_remotive_host.sh"
declare -r gcp_compute_rest_py="${REPO_ROOT}/workloads/android/pipelines/common/gcp/gcp_compute_rest.py"

function echo_formatted() {
    echo -e "\r${GREEN}[$SCRIPT_NAME] $1${NC}"
}

# -----------------------------------------------------------------------------
# GCP metadata token + Compute REST wrappers (shared gcp_compute_rest.py)
# -----------------------------------------------------------------------------
function gcp_metadata_access_token() {
    local raw=""
    local base
    for base in \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token"; do
        raw="$(curl -fsS --connect-timeout 2 --max-time 8 \
            -H "Metadata-Flavor: Google" \
            "${base}?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform" 2>/dev/null)" && break
        raw=""
    done
    [ -n "${raw}" ] || return 1
    printf '%s' "${raw}" | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])' 2>/dev/null || return 1
}

# Run one gcp_compute_rest.py subcommand with a fresh metadata token; best-effort
# (returns 0 with a warning when token/helper are unavailable).
function compute_rest_best_effort() {
    local token
    if [ ! -f "${gcp_compute_rest_py}" ] || ! command -v python3 >/dev/null 2>&1; then
        echo -e "${ORANGE}WARNING: Missing ${gcp_compute_rest_py} or python3; skipped: $*${NC}" >&2
        return 0
    fi
    if ! token="$(gcp_metadata_access_token 2>/dev/null)" || [ -z "${token}" ]; then
        echo -e "${ORANGE}WARNING: Metadata token unavailable; skipped: $*${NC}" >&2
        return 0
    fi
    CF_COMPUTE_REST_TOKEN="${token}" python3 "${gcp_compute_rest_py}" "$@" || {
        echo -e "${ORANGE}WARNING: gcp_compute_rest.py $* failed (best-effort)${NC}" >&2
        return 0
    }
}

function cleanup_orphan_packer_boot_disks() {
    echo_formatted "Post-Packer orphan disk scan (zone=${ZONE}, sizeGb=$1)"
    compute_rest_best_effort cleanup-orphan-packer-disks "${PROJECT}" "${ZONE}" "$1"
}

function cleanup_all_unattached_packer_disks_in_zone() {
    echo_formatted "Orphan Packer disk scan — all unattached packer-* (zone=${ZONE})"
    compute_rest_best_effort cleanup-orphan-packer-disks "${PROJECT}" "${ZONE}" "any"
}

function terminate() {
    echo -e "${RED}CTRL+C: exit requested!${NC}"
    cleanup_orphan_packer_boot_disks "$(boot_disk_size_gb)" || true
    exit 1
}
trap terminate SIGINT

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function boot_disk_size_gb() {
    local value
    value=$(echo "${BOOT_DISK_SIZE}" | awk '{print toupper($0)}' | xargs)
    value=${value%GB}
    value=${value%G}
    echo "${value}"
}

function parse_duration_to_seconds() {
    local value
    value="$(echo "$1" | xargs)"
    if [ -z "${value}" ] || [ "${value}" = "0" ]; then
        echo "0"
        return 0
    fi
    if [[ "${value}" =~ ^([0-9]+)h$ ]]; then
        echo "$((BASH_REMATCH[1] * 3600))"
        return 0
    fi
    if [[ "${value}" =~ ^([0-9]+)m$ ]]; then
        echo "$((BASH_REMATCH[1] * 60))"
        return 0
    fi
    if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo -e "${RED}Unsupported duration: ${value}. Use 0, Nh, Nm, or Ns (e.g. 12h).${NC}" >&2
    return 1
}

# Kubernetes object name for the KCC ComputeInstanceTemplate (DNS-1123);
# spec.resourceID carries the actual GCP instance template name.
function remotive_kcc_template_k8s_name() {
    echo "remotive-it-$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/--+/-/g'
}

function get_packer_ssh_username() {
    if [[ "${OS_PROJECT}" == ubuntu* ]]; then
        echo "ubuntu"
    else
        echo "debian"
    fi
}

function echo_environment() {
    echo_formatted "Environment variables:"
    echo "BOOT_DISK_SIZE=${BOOT_DISK_SIZE}"
    echo "BOOT_DISK_TYPE=${BOOT_DISK_TYPE}"
    echo "DEFAULT_USER=${DEFAULT_USER}"
    echo "ENABLE_NESTED_VIRTUALIZATION=${ENABLE_NESTED_VIRTUALIZATION}"
    echo "MACHINE_TYPE=${MACHINE_TYPE}"
    echo "MAX_RUN_DURATION=${MAX_RUN_DURATION}"
    echo "NETWORK=${NETWORK}"
    echo "OS_PROJECT=${OS_PROJECT}"
    echo "OS_FAMILY=${OS_FAMILY}"
    echo "PACKER_BUILD_MAX_RUN_DURATION=${PACKER_BUILD_MAX_RUN_DURATION:-(unset; default 4h)}"
    echo "PACKER_USE_IAP=${PACKER_USE_IAP}"
    echo "PACKER_SSH_TIMEOUT=${PACKER_SSH_TIMEOUT}"
    echo "PACKER_IAP_TUNNEL_LAUNCH_WAIT=${PACKER_IAP_TUNNEL_LAUNCH_WAIT}"
    echo "PROJECT=${PROJECT}"
    echo "REGION=${REGION}"
    echo "SERVICE_ACCOUNT=${SERVICE_ACCOUNT}"
    echo "REMOTIVE_INSTANCE_NAME=${remotive_name}"
    echo "SUBNET=${SUBNET}"
    echo "WORKFLOWS_NAMESPACE=${WORKFLOWS_NAMESPACE}"
    echo "WORKSPACE=${WORKSPACE}"
    echo "ZONE=${ZONE}"
    echo
}

function check_environment() {
    if [ -z "${PROJECT}" ]; then
        echo -e "${RED}Environment variable PROJECT must be defined${NC}"
        exit 1
    fi
    if [ -z "${SERVICE_ACCOUNT}" ]; then
        echo -e "${RED}Environment variable SERVICE_ACCOUNT must be defined${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Stage 1a: Packer build
# -----------------------------------------------------------------------------
function build_image_with_packer() {
    echo_formatted "1. Build remotive-topology image with Packer"

    if ! command -v packer >/dev/null 2>&1; then
        echo -e "${RED}ERROR: packer binary not found in PATH.${NC}"
        exit 1
    fi
    if [ ! -f "${packer_template_path}" ] || [ ! -f "${packer_provision_script_path}" ]; then
        echo -e "${RED}ERROR: Packer files missing under ${REMOTIVE_SCRIPT_PATH}/packer.${NC}"
        exit 1
    fi

    local disk_size_gb
    disk_size_gb=$(boot_disk_size_gb)

    local _packer_default_duration='4h'
    local packer_max_run_seconds
    packer_max_run_seconds="$(parse_duration_to_seconds "${PACKER_BUILD_MAX_RUN_DURATION:-${_packer_default_duration}}")" || exit 1
    if [ "${packer_max_run_seconds}" -eq 0 ]; then
        packer_max_run_seconds="$(parse_duration_to_seconds "${_packer_default_duration}")" || exit 1
    fi
    echo_formatted "Packer builder GCE max run: ${packer_max_run_seconds}s (auto-delete if job hangs or client is lost)"

    local packer_use_iap=true
    case "$(printf '%s' "${PACKER_USE_IAP}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        0|false|no|off) packer_use_iap=false ;;
    esac

    # Delete any previous image with this name (Packer refuses to overwrite).
    compute_rest_best_effort delete-global-image "${PROJECT}" "${vm_remotive_image}"
    # Stale keys from prior runs can fill the OS Login profile until Google
    # rejects Packer's key import (32 KiB profile limit).
    echo_formatted "Pruning OS Login SSH keys for current identity"
    compute_rest_best_effort prune-os-login-ssh-keys

    # Packer writes crash.log to cwd; Argo git artifacts often leave WORKSPACE read-only.
    local packer_work
    packer_work="$(mktemp -d "${TMPDIR:-/tmp}/remotive-packer-work.XXXXXX")" || exit 1
    chmod 700 "${packer_work}"
    local packer_rc=0
    if ! (
        set -e
        cd "${packer_work}"
        packer init "${packer_template_path}"
        packer build \
            -var "project_id=${PROJECT}" \
            -var "zone=${ZONE}" \
            -var "region=${REGION}" \
            -var "network=${NETWORK}" \
            -var "subnetwork=${SUBNET}" \
            -var "source_image_project_id=${OS_PROJECT}" \
            -var "source_image_family=${OS_FAMILY}" \
            -var "machine_type=${MACHINE_TYPE}" \
            -var "disk_size_gb=${disk_size_gb}" \
            -var "disk_type=${BOOT_DISK_TYPE}" \
            -var "image_name=${vm_remotive_image}" \
            -var "image_description=${vm_remotive_image}" \
            -var "ssh_username=$(get_packer_ssh_username)" \
            -var "default_user=${DEFAULT_USER}" \
            -var "remotive_script_path=${REMOTIVE_SCRIPT_PATH}" \
            -var "use_iap=${packer_use_iap}" \
            -var "ssh_timeout=${PACKER_SSH_TIMEOUT}" \
            -var "iap_tunnel_launch_wait=${PACKER_IAP_TUNNEL_LAUNCH_WAIT}" \
            -var "packer_max_run_duration_seconds=${packer_max_run_seconds}" \
            "${packer_template_path}"
    ); then
        packer_rc=1
    fi
    rm -rf "${packer_work}" || true
    cleanup_orphan_packer_boot_disks "${disk_size_gb}"
    if [ "${packer_rc}" -ne 0 ]; then
        echo -e "${RED}ERROR: Packer build failed.${NC}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Stage 1b: publish KCC ComputeInstanceTemplate from the baked image
# -----------------------------------------------------------------------------
function publish_instance_template_from_image() {
    if ! command -v kubectl >/dev/null 2>&1; then
        echo -e "${RED}ERROR: kubectl binary not found in PATH.${NC}"
        return 1
    fi

    local boot_disk_size
    boot_disk_size="$(boot_disk_size_gb)"
    local max_run_seconds
    max_run_seconds="$(parse_duration_to_seconds "${MAX_RUN_DURATION}")" || return 1
    local k8s_name
    k8s_name="$(remotive_kcc_template_k8s_name "${vm_remotive_instance_template}")"

    echo_formatted "Publishing instance template via Config Connector (namespace: ${WORKFLOWS_NAMESPACE})"
    echo_formatted "Target GCP instance template: ${vm_remotive_instance_template}"

    # Delete + recreate: most template fields are immutable. Delete the CR first
    # (wait); then best-effort REST deletes remove an orphan GCP template that
    # exists without a CR (apply would otherwise adopt the stale object).
    local kcc_delete_timeout="${KCC_INSTANCE_TEMPLATE_DELETE_TIMEOUT:-15m}"
    if ! kubectl -n "${WORKFLOWS_NAMESPACE}" delete computeinstancetemplate "${k8s_name}" \
        --ignore-not-found=true --wait=true --timeout="${kcc_delete_timeout}"; then
        echo -e "${RED}ERROR: kubectl delete ComputeInstanceTemplate ${k8s_name} failed or timed out.${NC}" >&2
        return 1
    fi
    compute_rest_best_effort delete-instance-template "${PROJECT}" "${vm_remotive_instance_template}"
    compute_rest_best_effort delete-regional-instance-template "${PROJECT}" "${REGION}" "${vm_remotive_instance_template}"

    if ! kubectl -n "${WORKFLOWS_NAMESPACE}" apply -f - <<EOF
apiVersion: compute.cnrm.cloud.google.com/v1beta1
kind: ComputeInstanceTemplate
metadata:
  name: ${k8s_name}
  labels:
    horizon-sdv.io/remotive-kcc-template: "true"
  annotations:
    cnrm.cloud.google.com/project-id: "${PROJECT}"
spec:
  resourceID: "${vm_remotive_instance_template}"
  description: "${vm_remotive_instance_template}"
  region: "${REGION}"
  machineType: "${MACHINE_TYPE}"
  instanceDescription: "${vm_remotive_instance_template}"
$(if [ "${ENABLE_NESTED_VIRTUALIZATION}" = "true" ]; then cat <<EOM
  advancedMachineFeatures:
    enableNestedVirtualization: true
EOM
fi)
  shieldedInstanceConfig:
    enableVtpm: true
    enableSecureBoot: false
    enableIntegrityMonitoring: true
  disk:
    - boot: true
      autoDelete: true
      type: PERSISTENT
      diskType: "${BOOT_DISK_TYPE}"
      diskSizeGb: ${boot_disk_size}
      sourceImageRef:
        external: "https://www.googleapis.com/compute/v1/projects/${PROJECT}/global/images/${vm_remotive_image}"
  networkInterface:
    - networkRef:
        external: "https://www.googleapis.com/compute/v1/projects/${PROJECT}/global/networks/${NETWORK}"
      subnetworkRef:
        external: "https://www.googleapis.com/compute/v1/projects/${PROJECT}/regions/${REGION}/subnetworks/${SUBNET}"
      stackType: "IPV4_ONLY"
  metadata:
    - key: enable-oslogin
      value: "true"
  scheduling:
    automaticRestart: false
    preemptible: false
$(if [ "${max_run_seconds}" != "0" ]; then cat <<EOM
    maxRunDuration:
      seconds: ${max_run_seconds}
    instanceTerminationAction: "DELETE"
EOM
fi)
  serviceAccount:
    serviceAccountRef:
      external: "${SERVICE_ACCOUNT}"
    scopes:
      - "https://www.googleapis.com/auth/devstorage.read_write"
      - "https://www.googleapis.com/auth/logging.write"
      - "https://www.googleapis.com/auth/monitoring.write"
EOF
    then
        echo -e "${RED}ERROR: kubectl apply ComputeInstanceTemplate failed.${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}ComputeInstanceTemplate applied; Config Connector will reconcile to GCP.${NC}"
    echo_formatted "Published template name (use as remotive-launcher instanceTemplateName): ${vm_remotive_instance_template}"
}

# -----------------------------------------------------------------------------
# Stage 3: scoped teardown (this target only)
# -----------------------------------------------------------------------------
function delete_remotive_publish_target_only() {
    echo_formatted "Scoped teardown for this publish target only (${vm_remotive_instance_template})"

    local k8s_name
    k8s_name="$(remotive_kcc_template_k8s_name "${vm_remotive_instance_template}")"
    if command -v kubectl >/dev/null 2>&1; then
        kubectl -n "${WORKFLOWS_NAMESPACE}" delete computeinstancetemplate "${k8s_name}" \
            --ignore-not-found=true --wait=true --timeout="${KCC_INSTANCE_TEMPLATE_DELETE_TIMEOUT:-15m}" || \
            echo -e "${ORANGE}WARNING: kubectl delete ComputeInstanceTemplate ${k8s_name} failed${NC}" >&2
    else
        echo -e "${ORANGE}WARNING: kubectl not in PATH; skipped KCC CR delete${NC}" >&2
    fi

    compute_rest_best_effort delete-instance-template "${PROJECT}" "${vm_remotive_instance_template}"
    compute_rest_best_effort delete-regional-instance-template "${PROJECT}" "${REGION}" "${vm_remotive_instance_template}"
    compute_rest_best_effort delete-global-image "${PROJECT}" "${vm_remotive_image}"
    cleanup_all_unattached_packer_disks_in_zone
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
function run_packer_build_and_publish_template() {
    build_image_with_packer
    if ! publish_instance_template_from_image; then
        local rc=$?
        echo -e "${RED}ERROR: Instance template publish failed (exit ${rc}); running scoped delete for this target only.${NC}" >&2
        delete_remotive_publish_target_only || true
        return "${rc}"
    fi
    return 0
}

function print_usage() {
    echo "Usage: [env overrides] ./${SCRIPT_NAME} [1|3|orphan-disks]"
    echo "  1 (default)    Build image with Packer and publish instance template"
    echo "  3              Delete generated artifacts for this target only"
    echo "  orphan-disks   Best-effort delete all unattached packer-* disks in ZONE (Argo onExit)"
}

function main() {
    if [[ "${1:-}" != "orphan-disks" ]]; then
        echo_environment
        check_environment
    fi
    case "${1:-}" in
        orphan-disks)
            if [ -z "${PROJECT}" ] || [ -z "${ZONE}" ]; then
                echo -e "${RED}orphan-disks requires PROJECT and ZONE.${NC}" >&2
                exit 1
            fi
            cleanup_all_unattached_packer_disks_in_zone || true
            exit 0
            ;;
        1|"")
            run_packer_build_and_publish_template || exit 1
            echo_formatted "Done. Instance template ${vm_remotive_instance_template} is ready for remotive-launcher."
            ;;
        3)
            delete_remotive_publish_target_only || exit 1
            ;;
        *)
            print_usage
            exit 0
            ;;
    esac
}

main "${1:-}"
