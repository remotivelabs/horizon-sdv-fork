#!/usr/bin/env bash

# Copyright (c) 2024-2026 Accenture, All Rights Reserved.
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

# Description:
# Start(Launch) and Stop Cuttlefish Virtual Device (CVD) host.
#
# References:
# * https://github.com/google/android-cuttlefish
# * https://source.android.com/docs/devices/cuttlefish/multi-tenancy
# * https://source.android.com/docs/devices/cuttlefish/get-started
#
# Notes:
# Cuttlefish multi-tenancy allows for your host machine to launch multiple
# virtual guest devices with a single launch invocation. TCP sockets start
# at port 6520 and increment. The cuttlefish-base debian package, preallocates
# resources for 10 instances.
#
# Include common functions and variables.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")"/cvd_environment.sh "$0"
# Colours: GREEN/ORANGE/RED/NC from cvd_environment.sh.

declare BOOTED_INSTANCES=0

# CVD log file.
declare -r logfile="${HOME}"/cvd-"${BUILD_NUMBER}".log
# WiFi device status
declare -r wifilogfile="${WORKSPACE}"/wifi_connection_status.log

# Download CVD host package and Cuttlefish AVD artifacts
function cuttlefish_extract_artifacts() {
    sudo rm -rf "${HOME}"/cf
    mkdir -p "${HOME}"/cf
    cd "${HOME}"/cf || exit

    local _quiet=false
    [[ "${CVD_ARGO_QUIET_GUEST_EXTRACT:-}" == "true" ]] && _quiet=true

    case "${CUTTLEFISH_DOWNLOAD_URL}" in
        gs://*)
            if "${_quiet}"; then
                gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}"/cvd-host_package.tar.gz . >/dev/null 2>&1 \
                    || { echo -e "${RED}gcloud cp cvd-host_package failed (see guest /tmp/cvd-argo-remote-main.log)${NC}" >&2; exit 1; }
                gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}/*img*.zip" . >/dev/null 2>&1 \
                    || { echo -e "${RED}gcloud cp aosp_cf image failed${NC}" >&2; exit 1; }
                echo -e "${GREEN}[cvd] Downloaded Cuttlefish artifacts from GCS (quiet guest extract)${NC}" >&2
                ls -lh cvd-host_package.tar.gz *img*.zip 2>/dev/null | sed 's/^/[cvd] /' >&2 || true
            else
                gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}"/cvd-host_package.tar.gz .
                gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}/*img*.zip" .
            fi
            # Allow this to fail.
            gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}/${WIFI_APK_NAME}" . >/dev/null 2>&1 || true
            ;;
        *)
            wget -nv "${CUTTLEFISH_DOWNLOAD_URL}"/cvd-host_package.tar.gz .
            wget -r -nd -nv --no-parent -A "*img*.zip" "${CUTTLEFISH_DOWNLOAD_URL}"/ || true
            # Allow this to fail.
            wget -nv "${CUTTLEFISH_DOWNLOAD_URL}/${WIFI_APK_NAME}" . > /dev/null 2>&1 || true
            ;;
    esac

    # Unpack the host packages.
    if "${_quiet}"; then
        if ! tar -xf cvd-host_package.tar.gz; then
            echo -e "${RED}Failed to extract cvd-host_package.tar.gz${NC}" >&2
            exit 1
        fi
        if ! unzip -qo -- ./*img*.zip; then
            echo -e "${RED}Failed to extract device image zip(s) (./*img*.zip)${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}[cvd] Extracted host package and CF image (quiet guest extract)${NC}" >&2
    elif ! tar -xvf cvd-host_package.tar.gz; then
        echo -e "${RED}Failed to extract cvd-host_package.tar.gz${NC}" >&2
        exit 1
    elif ! unzip -o -- ./*img*.zip; then
        echo -e "${RED}Failed to extract CF image${NC}" >&2
        exit 1
    fi

    # Clean up
    rm -f ./*img*.zip
    rm -f ./cvd-host_package.tar.gz

    # SDV cvd wrapper from build storage (AAOS: host/linux-x86/bin/sdv-cf). Fetch after unpack so
    # it is not overwritten by the host tarball. Optional when the bucket has no sdv-cf (legacy).
    case "${CUTTLEFISH_DOWNLOAD_URL}" in
        gs://*)
            gcloud storage cp "${CUTTLEFISH_DOWNLOAD_URL}/sdv-cf" . >/dev/null 2>&1 || true
            ;;
        *)
            wget -nv "${CUTTLEFISH_DOWNLOAD_URL}/sdv-cf" . >/dev/null 2>&1 || true
            ;;
    esac
}

# Adjust cuttlefish resources
function cuttlefish_adjust_resources() {
    if (( NUM_INSTANCES > 10 )); then
        # Modify the resource file to support > 10 devices
        sudo echo num_cvd_accounts="${NUM_INSTANCES}" | sudo tee -a /etc/default/cuttlefish-host-resources
        # Restart resource
        sudo systemctl restart cuttlefish-host-resources

        # Check how many are available
        INTERFACES=$(ip -c a | grep -c cvd-wtap)
        if (( NUM_INSTANCES == INTERFACES )); then
            echo -e "${GREEN}Cuttlefish updated for $NUM_INSTANCES instances${NC}"
        else
            echo -e "${ORANGE}Warning: resources $INTERFACES != $NUM_INSTANCES${NC}"
        fi
    fi
}

# Start Cuttlefish Virtual Device (CVD) host.
function cuttlefish_start() {
    echo -e "${GREEN}cuttlefish_start${NC}"

    cd "${HOME}"/cf || exit

    # Remove log file.
    rm -f "${logfile}"

    # Start the CF devices (must be run as sudo).
    # CVD_COMMAND_LINE: full command after HOME=… (default set in cvd_environment.sh).
    CVD_COMMAND_LINE=$(echo "${CVD_COMMAND_LINE}" | xargs)
    if [[ -z "${CVD_COMMAND_LINE}" ]]; then
        echo -e "${RED}ERROR: CVD_COMMAND_LINE is empty after cvd_environment.sh${NC}" >&2
        exit 1
    fi

    # Ensure sdv-cf is executable
    if [[ -f "${PWD}/sdv-cf" ]]; then
        chmod +x "${PWD}/sdv-cf"
    fi

    CVD_CMD="sudo HOME=\"${PWD}\" ${CVD_COMMAND_LINE} >> \"${logfile}\" 2>&1 &"
    echo -e "${GREEN}Running ${CVD_CMD} in background.${NC}"
    if ! eval "${CVD_CMD}"
    then
        echo -e "${RED}ERROR: command ${CVD_CMD} failed, exit!${NC}" >&2
        exit 1
    fi
}

# Install WiFi
function cuttlefish_install_wifi() {
    cd "${HOME}"/cf || exit

    if [ -f "${WIFI_APK_NAME}" ]; then

        echo -e "${GREEN}WiFi Device Summary:${NC}" | tee "${wifilogfile}"

        echo -e "${GREEN}Start adb server in readiness to install Wifi${NC}"
        sudo adb kill-server || true
        sleep 10
        sudo adb start-server || true
        sleep 20

        # shellcheck disable=SC2207
        DEVICES=($(adb devices | grep -E '0.+device$' | cut -f1))
        for device in "${DEVICES[@]}"; do
            echo -e "${GREEN}Installing ${WIFI_APK_NAME} on ${device}${NC}"
            adb -s "${device}" install -g -r "${WIFI_APK_NAME}"

            echo -e "${GREEN}Enabling WiFi service on ${device}${NC}"
            adb -s "${device}" shell su root svc wifi enable

            echo -e "${GREEN}Connecting WiFi to Network on ${device}${NC}"
            adb -s "${device}" shell am instrument -e method "connectToNetwork" -e scan_ssid "false" -e ssid "VirtWifi" -w com.android.tradefed.utils.wifi/.WifiUtil | tee connection_result.log
            if ! grep -E -q "INSTRUMENTATION_RESULT.*result=true" connection_result.log
            then
                echo -e "${ORANGE}${device}: Failed to connect to wifi${NC}" | tee -a "${wifilogfile}"
                connection_result=$(grep "INSTRUMENTATION_RESULT:" connection_result.log)
                if [ -n "${connection_result}" ]; then
                    echo -e "${ORANGE}    ${connection_result}${NC}" | tee -a "${wifilogfile}"
                fi
            else
                echo -e "${GREEN}${device}: Successfully connected to wifi${NC}" | tee -a "${wifilogfile}"
            fi

            echo -e "${GREEN}WiFi status on ${device}${NC}"
            echo -e "${GREEN}=================================================${NC}"
            adb -s "${device}" shell su root dumpsys wifi | grep "current SSID"
            echo -e "${GREEN}=================================================${NC}"
        done
    else
        echo -e "${ORANGE}Unable to find ${WIFI_APK_NAME}${NC}"
    fi
}

# Wait for device to boot (VIRTUAL_DEVICE_BOOT_COMPLETED) or timeout.
function cuttlefish_wait_for_device_booted() {
    local -r timeout="${SECONDS}"+"${CUTTLEFISH_MAX_BOOT_TIME}"
    echo -e "${GREEN}Wait for boot: ${CUTTLEFISH_MAX_BOOT_TIME} seconds${NC}"
    while (( "${SECONDS}" < "${timeout}" )); do
        # Newer cvd versions no longer print VIRTUAL_DEVICE_BOOT_COMPLETED to
        # stdout (only to the instance launcher.log); they print
        # "Virtual device booted successfully" instead. Accept either marker.
        BOOTED_INSTANCES=$(grep -c VIRTUAL_DEVICE_BOOT_COMPLETED "${logfile}")
        BOOTED_SUCCESS_MSGS=$(grep -c "Virtual device booted successfully" "${logfile}")
        if (( BOOTED_SUCCESS_MSGS > BOOTED_INSTANCES )); then
            BOOTED_INSTANCES="${BOOTED_SUCCESS_MSGS}"
        fi
        if (( BOOTED_INSTANCES == NUM_INSTANCES )); then
            echo -e "${GREEN}Boot completed.${NC}"
            break
        fi
        echo -e "${ORANGE}Waiting on boot, sleep 20s ...${NC}"
        sleep 20
    done
}

# Cleanup cuttlefish directory.
function cuttlefish_cleanup() {
    echo -e "${GREEN}cuttlefish_cleanup${NC}"
    cd "${HOME}" || exit
    sudo rm -rf cf > /dev/null 2>&1
}

function cuttlefish_nuclear() {
    # dnsmasq process can remain and block a new start. Kill Cuttlefish host processes.
    # NEVER use pkill -f cvd — too broad; match binary names/paths only.
    echo -e "${ORANGE}cuttlefish_nuclear${NC}"
    sudo pkill -9 -x cvd || true
    sudo pkill -9 -f '/usr/bin/cvd' || true
    sudo pkill -9 -f '/usr/local/bin/cvd' || true
    echo -e "${GREEN}cuttlefish_nuclear done${NC}"
}

# Stop CVD.
function cuttlefish_stop() {
    echo -e "${ORANGE}cuttlefish_stop${NC}"
    # Bound wait: stuck adb can block teardown for a long time.
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 adb reboot 2>/dev/null || true
    else
        adb reboot || true
    fi
    sudo adb kill-server || true
    sudo /usr/bin/cvd stop > /dev/null 2>&1
    sudo /usr/bin/cvd remove > /dev/null 2>&1
    sudo /usr/bin/cvd reset -y --clean-runtime-dir >/dev/null 2>&1
}

# Archive logs
function cuttlefish_archive_logs() {
    cp -f "${logfile}" "${WORKSPACE}" 2>/dev/null || true
    local instances_dir="${HOME}/cf/cuttlefish/instances"
    if [[ ! -d "${instances_dir}" ]]; then
        return 0
    fi
    # zip exits 12 with "Nothing to do!" when cvd*/logs/ is missing or empty; skip in that case.
    if [[ -z "$(find "${instances_dir}" -type f -path '*/cvd*/logs/*' 2>/dev/null | head -n 1)" ]]; then
        return 0
    fi
    # Restore with an explicit path — never use `cd -` (fails with "OLDPWD not set" if no prior cd succeeded).
    local _prev_pwd
    _prev_pwd=$(pwd)
    cd "${instances_dir}" || return 0
    zip -qr "${WORKSPACE}/cuttlefish_logs-${BUILD_NUMBER}.zip" cvd*/logs/ || true
    cd "${_prev_pwd}" || cd "${WORKSPACE}" || true
}

case "${1}" in
    --stop)
        # Stop
        cuttlefish_archive_logs
        cuttlefish_stop
        cuttlefish_cleanup
        cuttlefish_nuclear
        ;;
    --start|*)
        # Adjust resources based on instances requested
        cuttlefish_adjust_resources
        # Start
        cuttlefish_cleanup
        cuttlefish_extract_artifacts
        # This works around CVD issues.
        # CVD can fail to boot any devices, so we retry start.
        # Refer to Google for the reasons why!
        NUM_RETRIES=4
        for (( i = 1; i <= NUM_RETRIES; ++i )); do
            if (( i > 1 )); then
                echo -e "${ORANGE}Attempt ${i} of ${NUM_RETRIES} (retry after failed boot) ...${NC}"
            else
                echo -e "${GREEN}Attempt ${i} of ${NUM_RETRIES} ...${NC}"
            fi
            cuttlefish_start
            cuttlefish_wait_for_device_booted
            if (( BOOTED_INSTANCES == NUM_INSTANCES )); then
                echo -e "${GREEN}Booted ${BOOTED_INSTANCES} instances of ${NUM_INSTANCES}${NC}"
            else
                echo -e "${ORANGE}Booted ${BOOTED_INSTANCES} instances of ${NUM_INSTANCES} (expected ${NUM_INSTANCES})${NC}"
            fi
            if (( BOOTED_INSTANCES == NUM_INSTANCES )); then
                sudo /usr/bin/cvd status
                break;
            else
                cuttlefish_stop
            fi
        done

        if (( BOOTED_INSTANCES == 0 )); then
            echo -e "${RED}Error: android guest instances/devices not booted.${NC}" >&2
            # Stop and clean up
            cuttlefish_archive_logs
            cuttlefish_stop
            cuttlefish_cleanup
            exit 1
        elif (( BOOTED_INSTANCES != NUM_INSTANCES )); then
            echo -e "${RED}ERROR: Only booted ${BOOTED_INSTANCES} of requested ${NUM_INSTANCES}!${NC}" >&2
            echo -e "${RED}       Terminating.${NC}" >&2
            exit 1
        fi
        if [[ "${CUTTLEFISH_INSTALL_WIFI}" == "true" ]]; then
            cuttlefish_install_wifi
        fi
        ;;
esac
