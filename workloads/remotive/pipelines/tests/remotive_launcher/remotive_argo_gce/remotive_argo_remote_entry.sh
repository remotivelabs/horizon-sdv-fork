#!/usr/bin/env bash
#
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
#   Runs on the ephemeral remotive VM, twice (like cvd_argo_remote_entry.sh):
#     REMOTIVE_ARGO_REMOTE_PHASE=main     — resolve topology project, remotive topology
#                                      build, docker compose up, optional MTK
#                                      Connect, optional tests, keep-alive
#     REMOTIVE_ARGO_REMOTE_PHASE=teardown — MTK stop, docker compose down, gather logs
#
#   Topology descriptor <project>/<TOPOLOGY_NAME>.launcher.yaml (required; the
#   path relative to the project root can be overridden via REMOTIVE_LAUNCHER_FILE):
#     topology_instances: [instances/main.instance.yaml]   # -f flags, in order (required, non-empty)
#     compose_overlays: []                                 # extra compose -f files
#     compose_profiles: []                                 # long-running profiles
#     test_service: tester                                 # compose run target for tests
#     forward_ports: [{name: RemotiveBroker, port: 50051}] # topology ports (IAP SSH forward + MTK tunnels)
#     adb_devices: [{name: IHU, port: 6520}]               # Android adb endpoints registered as
#                                                          # streamed MTK Connect devices (optional)
#
#   RemotiveStudio (port 57123) is started by this launcher during the keep-alive
#   window as the primary UI: reachable via IAP SSH port-forward and the only
#   service exposed through MTK Connect. It connects to the topology broker on
#   localhost:50051 (it does not launch its own topology).

set -euo pipefail

# shellcheck source=/dev/null
source /tmp/remotive_argo_guest_common.sh

: "${WORKSPACE:?}"
: "${REMOTIVE_ARGO_REMOTE_PHASE:?main or teardown}"
: "${REMOTIVE_ARGO_OUTPUT_URI:?}"
: "${TOPOLOGY_NAME:?}"
: "${REMOTE_ARTIFACT_TGZ:=/tmp/remotive-argo-artifacts.tgz}"

PROJECTS_BASE="/opt/remotive/projects"
PROJECT_PATH="${PROJECTS_BASE}/${TOPOLOGY_NAME}"
# REMOTIVE_LAUNCHER_FILE (optional): descriptor path relative to the project root.
DESCRIPTOR="${PROJECT_PATH}/${REMOTIVE_LAUNCHER_FILE:-${TOPOLOGY_NAME}.launcher.yaml}"
ARTIFACT_DIR="/tmp/remotive-argo-out"
MARKER=/tmp/remotive-argo-mtk.marker
# RemotiveStudio: primary UI, launcher-managed (not from the descriptor). Exposed
# via IAP SSH port-forward and MTK Connect; connects to the broker on :50051.
STUDIO_PORT=57123
STUDIO_LOG=/tmp/remotive-argo-studio.log

# -----------------------------------------------------------------------------
# Descriptor parsing (python3 + PyYAML; both baked into the golden image)
# -----------------------------------------------------------------------------
# _descriptor_list <key> — one item per line; empty when descriptor/key missing.
function _descriptor_list() {
  local key="${1:?}"
  [[ -f "${DESCRIPTOR}" ]] || return 0
  python3 - "$key" "${DESCRIPTOR}" <<'PY'
import sys, yaml
key, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
for item in data.get(key) or []:
    print(item)
PY
}

function _descriptor_scalar() {
  local key="${1:?}" default="${2:-}"
  if [[ -f "${DESCRIPTOR}" ]]; then
    local v
    v="$(python3 - "$key" "${DESCRIPTOR}" <<'PY'
import sys, yaml
key, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
v = data.get(key)
print(v if v is not None else "")
PY
)"
    [[ -n "${v}" ]] && { printf '%s' "${v}"; return 0; }
  fi
  printf '%s' "${default}"
}

# _descriptor_named_ports <key> — one "name:port" line per entry of a
# {name, port} mapping list (forward_ports, adb_devices). Strict format: every
# entry must be a mapping with both name and port (integer); anything else exits
# non-zero so the run fails loudly. Names are sanitized for the
# MTK_CONNECT_TUNNEL_LIST / MTK_CONNECT_DEVICE_NAME_LIST separators (comma,
# colon) and whitespace.
function _descriptor_named_ports() {
  local key="${1:?}"
  [[ -f "${DESCRIPTOR}" ]] || return 0
  python3 - "$key" "${DESCRIPTOR}" <<'PY'
import re, sys, yaml
key = sys.argv[1]
with open(sys.argv[2]) as f:
    data = yaml.safe_load(f) or {}
for item in data.get(key) or []:
    if not isinstance(item, dict) or "name" not in item or "port" not in item:
        sys.exit(f"ERROR: {key} entries must be mappings with name and port, got: {item!r}")
    if not isinstance(item["port"], int):
        sys.exit(f"ERROR: {key} port must be an integer, got: {item['port']!r}")
    name = re.sub(r"[,:\s]+", "-", str(item["name"]).strip())
    if not name:
        sys.exit(f"ERROR: {key} name must be non-empty, got: {item!r}")
    print(f"{name}:{item['port']}")
PY
}

# -----------------------------------------------------------------------------
# Compose invocation shared by main/teardown/tests
# -----------------------------------------------------------------------------
function _generated_compose_file() {
  find "${PROJECT_PATH}/build" -maxdepth 2 -name docker-compose.yml 2>/dev/null | head -n1
}

function _compose_cmd() {
  local compose_file
  compose_file="$(_generated_compose_file)"
  [[ -n "${compose_file}" ]] || return 1
  local -a cmd=(docker compose -f "${compose_file}")
  local overlay profile
  while IFS= read -r overlay; do
    [[ -n "${overlay}" ]] && cmd+=(-f "${PROJECT_PATH}/${overlay}")
  done < <(_descriptor_list compose_overlays)
  while IFS= read -r profile; do
    [[ -n "${profile}" ]] && cmd+=(--profile "${profile}")
  done < <(_descriptor_list compose_profiles)
  printf '%s\n' "${cmd[@]}"
}

function _run_compose() {
  local -a cmd=()
  local line
  while IFS= read -r line; do cmd+=("${line}"); done < <(_compose_cmd)
  if [[ "${#cmd[@]}" -eq 0 ]]; then
    echo "[remotive-argo-remote] ERROR: no generated docker-compose.yml under ${PROJECT_PATH}/build" >&2
    return 1
  fi
  "${cmd[@]}" "$@"
}

# -----------------------------------------------------------------------------
# MTK Connect (optional; RemotiveStudio + topology forward_ports as TCP tunnels)
# -----------------------------------------------------------------------------
function _mtk_testbench_user() {
  if [[ "${MTK_CONNECT_PUBLIC:-false}" == "true" ]]; then
    echo "everyone"
  else
    echo "${BUILD_USER_ID:-everyone}"
  fi
}

function run_mtk_start() {
  if [[ -z "${MTK_CONNECT_USERNAME:-}" ]] || [[ -z "${MTK_CONNECT_PASSWORD:-}" ]]; then
    echo "[remotive-argo-remote] MTK credentials not set; skipping MTK Connect"
    return 0
  fi
  # RemotiveStudio plus the topology's forward_ports are exposed as raw TCP
  # tunnels (MTK_CONNECT_TUNNEL_LIST, name:port entries) for the MTK Connect
  # Tunnel client. Best-effort — IAP SSH port-forwarding is the primary access
  # path.
  local host_ip
  host_ip="$(hostname -I | sed 's/ .*//')"
  # All raw TCP tunnels (RemotiveStudio + forward_ports) live on a dedicated
  # host-only MTK device with this hardcoded name.
  local topology_device="RemotiveTopology"
  local tunnel_list="RemotiveStudio:${STUDIO_PORT}" fwd entry
  fwd="$(_descriptor_named_ports forward_ports)" || { echo "[remotive-argo-remote] ERROR: invalid forward_ports in ${DESCRIPTOR}" >&2; return 1; }
  while IFS= read -r entry; do
    [[ -n "${entry}" && "${entry##*:}" != "${STUDIO_PORT}" ]] && tunnel_list+=",${entry}"
  done <<<"${fwd}"
  # Topology adb_devices (name:port entries) become full MTK Connect Android
  # devices (screen, adb terminal, logcat, touch) alongside the host-only
  # RemotiveTopology device that carries the named TCP tunnels
  # (MTK_CONNECT_TUNNEL_DEVICE_NAME). Without adb_devices only the
  # RemotiveTopology host device is created.
  local adb_devices
  adb_devices="$(_descriptor_named_ports adb_devices)" || { echo "[remotive-argo-remote] ERROR: invalid adb_devices in ${DESCRIPTOR}" >&2; return 1; }
  local host_only=true devices=0 host_list="${host_ip}" port_list="${STUDIO_PORT}" name_list="${topology_device}"
  if [[ -n "${adb_devices}" ]]; then
    # MTK_CONNECT_DEVICE_NAME_LIST carries adb names only; the topology device
    # is named via MTK_CONNECT_TUNNEL_DEVICE_NAME.
    host_only=false host_list="" port_list="" name_list=""
    while IFS= read -r entry; do
      [[ -n "${entry}" ]] || continue
      devices=$((devices + 1))
      host_list+="${host_list:+,}${host_ip}"
      port_list+="${port_list:+,}${entry##*:}"
      name_list+="${name_list:+,}${entry%:*}"
    done <<<"${adb_devices}"
  else
    devices=1
  fi
  # The MTK Connect agent (root) spawns the adb binary for the screen/terminal/
  # touch interfaces of adb devices; attach each device to the local adb server
  # up front — mtk_connect.sh only starts/connects adb itself when it
  # auto-detects devices, which the explicit host list above disables.
  if [[ "${host_only}" == "false" ]]; then
    if command -v adb >/dev/null 2>&1; then
      sudo adb start-server >/dev/null 2>&1 || true
      while IFS= read -r entry; do
        [[ -n "${entry}" ]] && sudo adb connect "${host_ip}:${entry##*:}" || true
      done <<<"${adb_devices}"
    else
      echo "[remotive-argo-remote] WARNING: adb_devices set but adb is not installed on the VM; MTK screen/terminal interfaces will fail" >&2
    fi
  fi
  # HOST terminal login user: the image's interactive account (DEFAULT_USER at
  # bake time, default horizon). Empty when absent -> upstream fallback chain.
  local terminal_user=""
  id -un horizon >/dev/null 2>&1 && terminal_user="horizon"
  local _mtk_user
  _mtk_user="$(_mtk_testbench_user)"
  # Readable testbench name; timestamped, so persisted in the marker for the
  # teardown phase (a separate script invocation). Sanitized to the same
  # character set as the device/tunnel names.
  local testbench
  testbench="remotive-launcher-${TOPOLOGY_NAME}-$(date +%Y%m%d-%H%M%S)"
  testbench="$(printf '%s' "${testbench}" | tr -cs 'A-Za-z0-9._-' '-')"
  _trace "[remotive-argo-remote] MTK Connect --start: host=${host_ip} tunnels=${tunnel_list} adb_devices=${name_list:-none} user=${_mtk_user} testbench=${testbench}"
  {
    echo "export MTK_RAN=true"
    echo "export MTK_DEVICES=${devices}"
    echo "export MTK_TESTBENCH=${testbench}"
  } >"${MARKER}"
  pushd "${WORKSPACE}/workloads/common/mtk-connect" >/dev/null
  set +e
  sudo \
    MTK_CONNECT_TUNNEL_PORT="${MTK_CONNECT_TUNNEL_PORT:-8555}" \
    MTK_CONNECT_DOMAIN="${HORIZON_DOMAIN:?}" \
    MTK_CONNECT_USERNAME="${MTK_CONNECT_USERNAME}" \
    MTK_CONNECT_PASSWORD="${MTK_CONNECT_PASSWORD}" \
    MTK_CONNECTED_DEVICES="${devices}" \
    MTK_CONNECT_HOST_LIST="${host_list}" \
    MTK_CONNECT_HOST_PORT_LIST="${port_list}" \
    MTK_CONNECT_HOST_ONLY="${host_only}" \
    MTK_CONNECT_DEVICE_NAME_LIST="${name_list}" \
    MTK_CONNECT_TUNNEL_LIST="${tunnel_list}" \
    MTK_CONNECT_TUNNEL_DEVICE_NAME="${topology_device}" \
    MTK_CONNECT_TERMINAL_USER="${terminal_user}" \
    MTK_CONNECT_DEVICE_PREFIX="Remotive" \
    MTK_CONNECT_TEST_ARTIFACT="${TOPOLOGY_NAME}" \
    MTK_CONNECT_TESTBENCH="${testbench}" \
    MTK_CONNECT_TESTBENCH_USER="${_mtk_user}" \
    timeout 15m bash ./mtk_connect.sh --start
  local st=$?
  set -e
  popd >/dev/null || true
  if [[ "${st}" -ne 0 ]]; then
    echo "[remotive-argo-remote] WARNING: MTK Connect --start failed (${st}); topology stays reachable via IAP SSH" >&2
  fi
  return 0
}

function run_mtk_stop() {
  [[ -f "${MARKER}" ]] || return 0
  # shellcheck source=/dev/null
  source "${MARKER}"
  pushd "${WORKSPACE}/workloads/common/mtk-connect" >/dev/null || return 0
  set +e
  sudo \
    MTK_CONNECT_TUNNEL_PORT="${MTK_CONNECT_TUNNEL_PORT:-8555}" \
    MTK_CONNECT_DOMAIN="${HORIZON_DOMAIN:-}" \
    MTK_CONNECT_USERNAME="${MTK_CONNECT_USERNAME:-}" \
    MTK_CONNECT_PASSWORD="${MTK_CONNECT_PASSWORD:-}" \
    MTK_CONNECTED_DEVICES="${MTK_DEVICES:-1}" \
    MTK_CONNECT_TESTBENCH="${MTK_TESTBENCH}" \
    timeout 10m bash ./mtk_connect.sh --stop || true
  set -e
  popd >/dev/null || true
}

# -----------------------------------------------------------------------------
# RemotiveStudio (primary UI; fire-and-forget, viewer on the running broker)
# -----------------------------------------------------------------------------
function run_studio_start() {
  # Studio is a web UI that connects to the already-running topology broker
  # (docker compose publishes gRPC on localhost:50051). Fire-and-forget: it is
  # NOT reaped in teardown; the ephemeral VM is deleted after the run.
  #   --host 0.0.0.0  so both IAP SSH port-forward and MTK Connect can reach it
  #   --no-browser    the VM is headless; never try to open a browser
  #   --broker-url    connect to the existing broker; do not launch a topology
  #   (no --force)    never clobber the workspace the launcher just built
  echo "[remotive-argo-remote] starting RemotiveStudio on 0.0.0.0:${STUDIO_PORT} (workspace ${PROJECTS_BASE})"
  nohup remotive studio "${PROJECTS_BASE}" \
    --host 0.0.0.0 \
    --port "${STUDIO_PORT}" \
    --no-browser \
    --broker-url "http://localhost:50051" \
    >"${STUDIO_LOG}" 2>&1 &
  local studio_pid=$!
  # One-shot readiness check: Studio may pull/start a container, so poll ~60s.
  local i
  for i in $(seq 1 30); do
    if ! kill -0 "${studio_pid}" 2>/dev/null; then
      echo "[remotive-argo-remote] WARNING: RemotiveStudio exited during startup (see ${STUDIO_LOG}); topology still reachable via IAP SSH on 50051" >&2
      return 0
    fi
    if (exec 3<>"/dev/tcp/127.0.0.1/${STUDIO_PORT}") 2>/dev/null; then
      echo "[remotive-argo-remote] RemotiveStudio is listening on ${STUDIO_PORT}"
      return 0
    fi
    sleep 2
  done
  echo "[remotive-argo-remote] WARNING: RemotiveStudio not listening on ${STUDIO_PORT} after startup window (see ${STUDIO_LOG}); leaving it running" >&2
  return 0
}

# -----------------------------------------------------------------------------
# Main phase
# -----------------------------------------------------------------------------
# Sanitize REMOTIVE_KEEP_ALIVE_TIME to a non-negative integer number of minutes.
function _keep_alive_minutes() {
  local keep_mins="${REMOTIVE_KEEP_ALIVE_TIME:-0}"
  keep_mins="$(echo "${keep_mins}" | tr -d '[:space:]')"
  if [[ -n "${keep_mins}" && "${keep_mins}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${keep_mins}"
  else
    printf '0'
  fi
}

function resolve_topology_project() {
  sudo mkdir -p "${PROJECTS_BASE}"
  sudo chown -R "$(id -un):$(id -gn)" "${PROJECTS_BASE}"
  rm -rf "${PROJECT_PATH}"

  if [[ -n "${TOPOLOGY_DOWNLOAD_URL:-}" ]]; then
    echo "[remotive-argo-remote] fetching topology project from ${TOPOLOGY_DOWNLOAD_URL}"
    mkdir -p "${PROJECT_PATH}"
    case "${TOPOLOGY_DOWNLOAD_URL}" in
      gs://*)
        gcloud storage cp -r "${TOPOLOGY_DOWNLOAD_URL%/}/*" "${PROJECT_PATH}/"
        ;;
      *.tgz|*.tar.gz)
        curl -fsSL "${TOPOLOGY_DOWNLOAD_URL}" | tar xz -C "${PROJECT_PATH}"
        ;;
      *)
        echo "[remotive-argo-remote] ERROR: unsupported TOPOLOGY_DOWNLOAD_URL (use gs://dir or a .tgz/.tar.gz URL)" >&2
        return 1
        ;;
    esac
  else
    local vendored="${WORKSPACE}/workloads/remotive/topologies/${TOPOLOGY_NAME}"
    if [[ ! -d "${vendored}" ]]; then
      echo "[remotive-argo-remote] ERROR: no vendored topology '${TOPOLOGY_NAME}' and no topologyDownloadUrl" >&2
      return 1
    fi
    cp -a "${vendored}" "${PROJECT_PATH}"
  fi
  rm -rf "${PROJECT_PATH}/build"
}

function publish_access_info() {
  local keep_mins="${1:-0}"
  local fwd
  fwd="$(_descriptor_named_ports forward_ports)" || { echo "[remotive-argo-remote] ERROR: invalid forward_ports in ${DESCRIPTOR}" >&2; return 1; }
  # RemotiveStudio only runs during the keep-alive window; advertise its port for
  # IAP SSH port-forward alongside the topology's own forward_ports.
  if [[ "${keep_mins}" -gt 0 ]]; then
    [[ -n "${fwd}" ]] && fwd+=$'\n'
    fwd+="RemotiveStudio:${STUDIO_PORT}"
  fi
  local ports_json
  ports_json="$(printf '%s\n' "${fwd}" | python3 -c 'import json,sys
entries = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line:
        continue
    name, _, port = line.rpartition(":")
    entries.append({"name": name, "port": int(port)})
print(json.dumps({"forward_ports": entries}))')"
  printf '%s' "${ports_json}" >/tmp/remotive-argo-access.json
  gcloud storage cp /tmp/remotive-argo-access.json "${REMOTIVE_ARGO_OUTPUT_URI}/access.json" >/dev/null 2>&1 || true
}

function run_main() {
  : "${REMOTIVE_CLOUD_AUTH_TOKEN:?RemotiveCloud token missing — create the workflow-remotive-cloud-auth Secret}"
  : "${REMOTIVE_CLOUD_ORGANIZATION:?RemotiveCloud organization missing — create the workflow-remotive-cloud-auth Secret}"

  resolve_topology_project

  if [[ ! -f "${DESCRIPTOR}" ]]; then
    echo "[remotive-argo-remote] ERROR: descriptor not found: ${DESCRIPTOR}" >&2
    return 1
  fi

  # Workspace marker lives in the PARENT of the project so `rm -rf build` and
  # project re-syncs never wipe it (upstream topology-up.yaml pattern).
  (cd "${PROJECTS_BASE}" && remotive topology workspace init --force)

  local -a build_flags=()
  local inst
  while IFS= read -r inst; do
    [[ -n "${inst}" ]] && build_flags+=(-f "${inst}")
  done < <(_descriptor_list topology_instances)
  if [[ "${#build_flags[@]}" -eq 0 ]]; then
    echo "[remotive-argo-remote] ERROR: no topology_instances listed in ${DESCRIPTOR}" >&2
    return 1
  fi

  echo "[remotive-argo-remote] remotive topology build ${build_flags[*]}"
  (cd "${PROJECT_PATH}" && remotive topology build "${build_flags[@]}" build)

  echo "[remotive-argo-remote] starting docker compose"
  (cd "${PROJECT_PATH}" && _run_compose up --build -d)

  local keep_mins
  keep_mins="$(_keep_alive_minutes)"

  publish_access_info "${keep_mins}"

  if [[ "${RUN_TOPOLOGY_TESTS:-false}" == "true" ]]; then
    local test_service
    test_service="$(_descriptor_scalar test_service tester)"
    echo "[remotive-argo-remote] running topology tests (compose service '${test_service}')"
    (cd "${PROJECT_PATH}" && _run_compose --profile "${test_service}" run --rm "${test_service}")
    echo "[remotive-argo-remote] topology tests passed"
  fi

  # RemotiveStudio and MTK Connect only matter while a user can reach the VM, i.e.
  # during the keep-alive window. Skip both when keepAlive is disabled. Studio is
  # started first so the port MTK registers is already listening.
  if [[ "${keep_mins}" -gt 0 ]]; then
    run_studio_start
    run_mtk_start
    echo "[remotive-argo-remote] keep-alive ${keep_mins} minutes (RemotiveStudio on ${STUDIO_PORT} via IAP SSH / MTK Connect; topology gRPC on 50051 via IAP SSH)"
    sleep "$((keep_mins * 60))"
  fi
}

# -----------------------------------------------------------------------------
# Teardown phase
# -----------------------------------------------------------------------------
function gather_artifacts() {
  rm -rf "${ARTIFACT_DIR}"
  mkdir -p "${ARTIFACT_DIR}"
  if [[ -d "${PROJECT_PATH}" ]]; then
    (cd "${PROJECT_PATH}" && _run_compose ps -a >"${ARTIFACT_DIR}/compose-ps.txt" 2>&1) || true
    (cd "${PROJECT_PATH}" && _run_compose logs --no-color >"${ARTIFACT_DIR}/compose-logs.txt" 2>&1) || true
  fi
  cp /tmp/remotive-argo-guest-startup.log "${ARTIFACT_DIR}/" 2>/dev/null || true
  cp /tmp/remotive-argo-access.json "${ARTIFACT_DIR}/" 2>/dev/null || true
  cp "${STUDIO_LOG}" "${ARTIFACT_DIR}/" 2>/dev/null || true
}

function create_artifact_tgz() {
  tar czf "${REMOTE_ARTIFACT_TGZ}" -C "$(dirname "${ARTIFACT_DIR}")" "$(basename "${ARTIFACT_DIR}")"
}

function run_teardown() {
  run_mtk_stop || true
  # Container state and logs must be captured before `compose down` removes the
  # containers, otherwise compose-ps.txt and compose-logs.txt come out empty.
  gather_artifacts
  if [[ -d "${PROJECT_PATH}" ]]; then
    echo "[remotive-argo-remote] stopping docker compose"
    (cd "${PROJECT_PATH}" && _run_compose down --remove-orphans) || true
  fi
  create_artifact_tgz
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "${REMOTIVE_ARGO_REMOTE_PHASE}" in
  main)
    run_main
    ;;
  teardown)
    run_teardown
    ;;
  *)
    echo "[remotive-argo-remote] ERROR: unknown REMOTIVE_ARGO_REMOTE_PHASE=${REMOTIVE_ARGO_REMOTE_PHASE}" >&2
    exit 2
    ;;
esac
