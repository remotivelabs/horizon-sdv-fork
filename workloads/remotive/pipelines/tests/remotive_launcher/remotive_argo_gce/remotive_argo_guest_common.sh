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
# Shared helpers for scripts that run on the ephemeral remotive (RemotiveTopology) VM
# (same shape as cvd_argo_gce/cvd_argo_guest_common.sh).
#
# GCE metadata startup often has no HOME and no login shell. These helpers fix
# that and route guest logs to serial port 2 so the Argo pod can read app output
# without kernel noise on port 1.

function _trace() {
  printf '%s\n' "$1" >&2
}

function _remotive_argo_ensure_home() {
  if [[ -n "${HOME:-}" ]]; then
    return 0
  fi
  local passwd_home
  passwd_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
  export HOME="${passwd_home:-/root}"
  _trace "[remotive-argo] HOME unset; using ${HOME}"
}

# Tee stdout/stderr to a log file, optional serial (port 2 = /dev/ttyS1), and journald.
# Serial write runs in a side branch so EIO on /dev/ttyS1 cannot break journald logging.
function _remotive_argo_setup_stdio_redirect() {
  local serial_dev="${1:?}"
  local log_file="${2:?}"
  local syslog_id="${3:-remotive-argo-guest}"

  if [[ ! -c "${serial_dev}" ]]; then
    _trace "[remotive-argo-guest] WARN: ${serial_dev} missing; logs only in ${log_file}"
    if command -v systemd-cat >/dev/null 2>&1; then
      exec > >(tee -a "${log_file}" | systemd-cat -t "${syslog_id}" -p info) 2>&1
    else
      exec > >(tee -a "${log_file}") 2>&1
    fi
    return 0
  fi

  if command -v systemd-cat >/dev/null 2>&1; then
    exec > >(tee -a "${log_file}" >(tee "${serial_dev}" 2>/dev/null >/dev/null) | systemd-cat -t "${syslog_id}" -p info) 2>&1
  else
    exec > >(tee -a "${log_file}" >(tee "${serial_dev}" 2>/dev/null >/dev/null)) 2>&1
  fi
}
