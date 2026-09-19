#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPOSITORY_ROOT="${SCRIPT_DIR:h}"

PROJECT_PATH="${HOMEBASE_PROJECT_PATH:-${REPOSITORY_ROOT}/HomeBase-GUI.xcodeproj}"
SCHEME="${HOMEBASE_SCHEME:-HomeBase-GUI}"
CONFIGURATION="${HOMEBASE_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${HOMEBASE_DERIVED_DATA_PATH:-${REPOSITORY_ROOT}/.build/DerivedData}"
DEVICE_REQUEST="${HOMEBASE_DEVICE:-}"
DISCOVERY_TIMEOUT="${HOMEBASE_DEVICE_TIMEOUT:-15}"
VPN_DISCOVERY="${HOMEBASE_VPN_DISCOVERY:-1}"
IPHONE_VPN_IP="${HOMEBASE_IPHONE_VPN_IP:-10.19.0.100}"
BONJOUR_INTERFACE="${HOMEBASE_BONJOUR_INTERFACE:-en0}"
DYNAMIC_PORTS="${HOMEBASE_COREDEVICE_PORTS:-55000-59000}"
LOCAL_CONTROL_PORT="${HOMEBASE_COREDEVICE_LOCAL_PORT:-49151}"
BONJOUR_STATE_DIRECTORY="${HOMEBASE_BONJOUR_STATE_DIR:-${REPOSITORY_ROOT}/.build/CoreDeviceVPN}"
DRY_RUN=false
ATTACH_CONSOLE=false

log() {
    print -r -- "==> $*"
}

fail() {
    print -ru2 -- "error: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Build, install, and launch HomeBase GUI on a physical iPhone.

Usage:
  bin/run-on-phone.sh [--device <name-or-id>] [--dry-run] [--console]
                      [--no-vpn-discovery]

Options:
  --device <name-or-id>  Select a paired iPhone by its name, UDID, or CoreDevice
                         identifier. The default is the first reachable paired
                         physical iPhone, sorted by name.
  --dry-run              Discover the iPhone and print what would run without
                         building or installing anything.
  --console              Attach to the launched app's console and wait until
                         the app exits. Useful for reproducing crashes.
  --no-vpn-discovery     Do not publish and relay the cached CoreDevice Bonjour
                         service through the iPhone's VPN address.
  -h, --help             Show this help.

Environment overrides:
  HOMEBASE_XCODE_APP          Xcode app path (default: /Applications/Xcode.app)
  HOMEBASE_PROJECT_PATH       Project path
  HOMEBASE_SCHEME             Scheme name (default: HomeBase-GUI)
  HOMEBASE_CONFIGURATION      Build configuration (default: Debug)
  HOMEBASE_DERIVED_DATA_PATH  Derived-data directory
  HOMEBASE_DEVICE             Device name or identifier
  HOMEBASE_DEVICE_TIMEOUT     Discovery timeout in seconds (default: 15)
  HOMEBASE_VPN_DISCOVERY      Set to 0 to disable VPN discovery (default: 1)
  HOMEBASE_IPHONE_VPN_IP      Fixed iPhone VPN address (default: 10.19.0.100)
  HOMEBASE_BONJOUR_INTERFACE  LAN interface for the synthetic service (default: en0)
  HOMEBASE_COREDEVICE_PORTS   Trusted-tunnel TCP/UDP relay range (default: 55000-59000)
  HOMEBASE_COREDEVICE_LOCAL_PORT Local TCP/UDP relay port (default: 49151)
  HOMEBASE_BONJOUR_STATE_DIR  Metadata and process-state directory
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --device)
            (( $# >= 2 )) || fail "--device requires a name or identifier"
            DEVICE_REQUEST="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --console)
            ATTACH_CONSOLE=true
            shift
            ;;
        --no-vpn-discovery)
            VPN_DISCOVERY=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1 (try --help)"
            ;;
    esac
done

find_developer_directory() {
    local selected_directory=""
    local requested_xcode="${HOMEBASE_XCODE_APP:-/Applications/Xcode.app}"
    local candidate=""
    local -a candidates

    selected_directory="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    candidates=(
        "${requested_xcode}/Contents/Developer"
        "${selected_directory}"
        /Applications/Xcode*.app/Contents/Developer(N)
    )

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == *.app/Contents/Developer && -x "$candidate/usr/bin/xcodebuild" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done

    return 1
}

DEVELOPER_DIRECTORY="$(find_developer_directory)" || \
    fail "full Xcode was not found; install it or set HOMEBASE_XCODE_APP"
export DEVELOPER_DIR="$DEVELOPER_DIRECTORY"

[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found: $PROJECT_PATH"
[[ "$DISCOVERY_TIMEOUT" == <-> ]] || fail "HOMEBASE_DEVICE_TIMEOUT must be a whole number"
[[ "$VPN_DISCOVERY" == 0 || "$VPN_DISCOVERY" == 1 ]] || \
    fail "HOMEBASE_VPN_DISCOVERY must be 0 or 1"

TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/homebase-run-on-phone.XXXXXX")"
ACTIVE_LOCK_DIRECTORY=""
ACTIVE_RELAY_PID=""
ACTIVE_RELAY_SCRIPT=""
ACTIVE_RELAY_PID_FILE=""
ACTIVE_RELAY_READY_FILE=""

cleanup() {
    if [[ "$ACTIVE_RELAY_PID" == <-> ]] && \
       /bin/kill -0 "$ACTIVE_RELAY_PID" 2>/dev/null; then
        relay_command="$(/bin/ps -p "$ACTIVE_RELAY_PID" -o command= 2>/dev/null || true)"
        if [[ -n "$ACTIVE_RELAY_SCRIPT" && "$relay_command" == *"$ACTIVE_RELAY_SCRIPT"* ]]; then
            /bin/kill -TERM "$ACTIVE_RELAY_PID" 2>/dev/null || true
            wait "$ACTIVE_RELAY_PID" 2>/dev/null || true
        fi
    fi
    [[ -n "$ACTIVE_RELAY_READY_FILE" ]] && \
        /bin/rm -f -- "$ACTIVE_RELAY_READY_FILE"
    if [[ -n "$ACTIVE_RELAY_PID_FILE" && -f "$ACTIVE_RELAY_PID_FILE" ]] && \
       [[ "$(<"$ACTIVE_RELAY_PID_FILE")" == "$ACTIVE_RELAY_PID" ]]; then
        /bin/rm -f -- "$ACTIVE_RELAY_PID_FILE"
    fi
    if [[ -n "$ACTIVE_LOCK_DIRECTORY" && -d "$ACTIVE_LOCK_DIRECTORY" ]]; then
        /bin/rm -f -- "${ACTIVE_LOCK_DIRECTORY}/owner"
        /bin/rmdir -- "$ACTIVE_LOCK_DIRECTORY" 2>/dev/null || true
    fi
    /bin/rm -rf -- "$TEMPORARY_DIRECTORY"
}

trap cleanup EXIT
readonly DEVICES_JSON="${TEMPORARY_DIRECTORY}/devices.json"

is_valid_ipv4_address() {
    local address="$1"
    local octet=""
    local -a octets

    [[ "$address" == <->.<->.<->.<-> ]] || return 1
    octets=("${(@s:.:)address}")
    (( ${#octets} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
    done
}

validate_bonjour_metadata() {
    local metadata_file="$1"
    local instance=""
    local port=""
    local line=""
    local txt_count=0
    local has_identifier=false
    local has_auth_tag=false

    while IFS= read -r line; do
        case "$line" in
            instance=*) instance="${line#instance=}" ;;
            port=*) port="${line#port=}" ;;
            txt=identifier=*) has_identifier=true; (( txt_count += 1 )) ;;
            txt=authTag=*) has_auth_tag=true; (( txt_count += 1 )) ;;
            txt=*) (( txt_count += 1 )) ;;
            *) return 1 ;;
        esac
    done < "$metadata_file"

    [[ "$instance" =~ '^[A-Za-z0-9._-]+$' ]] || return 1
    [[ "$port" == <-> ]] || return 1
    (( port > 0 && port < 65536 )) || return 1
    (( txt_count > 0 )) || return 1
    $has_identifier && $has_auth_tag
}

capture_bonjour_metadata() {
    local destination="$1"
    local zone_file="${TEMPORARY_DIRECTORY}/remotepairing.zone"
    local candidate="${TEMPORARY_DIRECTORY}/remotepairing.metadata"
    local service_suffix="._remotepairing._tcp"
    local instance=""
    local port=""
    local line=""
    local -a txt_records

    /usr/bin/dns-sd -t 3 -Z _remotepairing._tcp local. > "$zone_file" 2>&1 || true

    instance="$(/usr/bin/awk \
        '$1 == "_remotepairing._tcp" && $2 == "PTR" { print $3; exit }' \
        "$zone_file")"
    instance="${instance%${service_suffix}}"
    [[ -n "$instance" ]] || return 1

    port="$(/usr/bin/awk \
        '$2 == "SRV" { print $5; exit }' \
        "$zone_file")"
    [[ "$port" == <-> ]] || return 1

    txt_records=("${(@f)$(/usr/bin/awk '
        $2 == "TXT" {
            for (field = 3; field <= NF; field++) {
                record = $field
                sub(/^"/, "", record)
                sub(/"$/, "", record)
                print record
            }
            exit
        }
    ' "$zone_file")}")
    (( ${#txt_records} > 0 )) || return 1

    {
        print -r -- "instance=${instance}"
        print -r -- "port=${port}"
        for line in "${txt_records[@]}"; do
            [[ "$line" =~ '^[A-Za-z][A-Za-z0-9]*=[A-Za-z0-9+/_=.-]+$' ]] || return 1
            print -r -- "txt=${line}"
        done
    } > "$candidate"

    validate_bonjour_metadata "$candidate" || return 1
    /bin/mkdir -p "${destination:h}"
    /bin/chmod 700 "${destination:h}"
    /bin/mv -f -- "$candidate" "$destination"
    /bin/chmod 600 "$destination"
}

relay_process_is_running() {
    local pid_file="$1"
    local relay_script="$2"
    local pid=""
    local command=""

    [[ -f "$pid_file" ]] || return 1
    pid="$(<"$pid_file")"
    [[ "$pid" == <-> ]] || return 1
    /bin/kill -0 "$pid" 2>/dev/null || return 1
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"$relay_script"* ]]
}

acquire_vpn_discovery_lock() {
    local lock_directory="$1"
    local owner_file="${lock_directory}/owner"
    local owner=""
    local attempt=0

    while (( attempt < 50 )); do
        if /bin/mkdir "$lock_directory" 2>/dev/null; then
            ACTIVE_LOCK_DIRECTORY="$lock_directory"
            print -r -- "$$" > "$owner_file"
            return 0
        fi

        owner="$(<"$owner_file" 2>/dev/null || true)"
        if [[ "$owner" != <-> ]] || ! /bin/kill -0 "$owner" 2>/dev/null; then
            /bin/rm -f -- "$owner_file"
            /bin/rmdir -- "$lock_directory" 2>/dev/null || true
        else
            /bin/sleep 0.1
        fi
        (( attempt += 1 ))
    done

    fail "timed out waiting for the VPN discovery lock"
}

release_vpn_discovery_lock() {
    [[ -n "$ACTIVE_LOCK_DIRECTORY" ]] || return 0
    /bin/rm -f -- "${ACTIVE_LOCK_DIRECTORY}/owner"
    /bin/rmdir -- "$ACTIVE_LOCK_DIRECTORY" 2>/dev/null || true
    ACTIVE_LOCK_DIRECTORY=""
}

ensure_vpn_discovery() {
    local relay_script="${SCRIPT_DIR}/coredevice-vpn-relay.py"
    local metadata_file="${BONJOUR_STATE_DIRECTORY}/remotepairing.metadata"
    local pid_file="${BONJOUR_STATE_DIRECTORY}/relay.pid"
    local ready_file="${BONJOUR_STATE_DIRECTORY}/relay.ready"
    local log_file="${BONJOUR_STATE_DIRECTORY}/relay.log"
    local lock_directory="${BONJOUR_STATE_DIRECTORY}/lock"
    local route_output=""
    local route_interface=""
    local local_ip=""
    local existing_pid=""
    local attempt=0
    local proxy_hostname="homebase-coredevice-vpn.local."

    is_valid_ipv4_address "$IPHONE_VPN_IP" || \
        fail "HOMEBASE_IPHONE_VPN_IP is not a valid IPv4 address: $IPHONE_VPN_IP"
    [[ "$DYNAMIC_PORTS" =~ '^[0-9]+-[0-9]+$' ]] || \
        fail "HOMEBASE_COREDEVICE_PORTS must use START-END syntax"
    [[ "$LOCAL_CONTROL_PORT" == <-> ]] && \
        (( LOCAL_CONTROL_PORT > 0 && LOCAL_CONTROL_PORT < 65536 )) || \
        fail "HOMEBASE_COREDEVICE_LOCAL_PORT must be between 1 and 65535"
    [[ -x "$relay_script" ]] || fail "CoreDevice VPN relay is not executable: $relay_script"
    command -v python3 >/dev/null || fail "python3 is required for VPN device discovery"

    route_output="$(/sbin/route -n get "$IPHONE_VPN_IP" 2>&1)" || \
        fail "there is no route to the iPhone VPN address $IPHONE_VPN_IP"
    route_interface="$(print -r -- "$route_output" | /usr/bin/awk '$1 == "interface:" { print $2; exit }')"
    [[ -n "$route_interface" ]] || fail "could not identify the route to $IPHONE_VPN_IP"
    log "VPN route to ${IPHONE_VPN_IP} uses ${route_interface}"

    if ! /usr/bin/nc -vz -w 3 "$IPHONE_VPN_IP" 49152 >/dev/null 2>&1; then
        fail "the iPhone CoreDevice endpoint is not reachable at ${IPHONE_VPN_IP}:49152"
    fi
    log "Reached the iPhone CoreDevice endpoint at ${IPHONE_VPN_IP}:49152"

    local_ip="$(/usr/sbin/ipconfig getifaddr "$BONJOUR_INTERFACE" 2>/dev/null || true)"
    is_valid_ipv4_address "$local_ip" || \
        fail "${BONJOUR_INTERFACE} does not have an IPv4 address for the synthetic Bonjour service"

    /bin/mkdir -p "$BONJOUR_STATE_DIRECTORY"
    /bin/chmod 700 "$BONJOUR_STATE_DIRECTORY"
    acquire_vpn_discovery_lock "$lock_directory"

    if relay_process_is_running "$pid_file" "$relay_script"; then
        existing_pid="$(<"$pid_file")"
        log "Stopping a relay left by an earlier invocation (PID ${existing_pid})"
        /bin/kill -TERM "$existing_pid"
        attempt=0
        while /bin/kill -0 "$existing_pid" 2>/dev/null && (( attempt < 50 )); do
            /bin/sleep 0.1
            (( attempt += 1 ))
        done
        /bin/kill -0 "$existing_pid" 2>/dev/null && \
            fail "the previous VPN discovery relay did not stop (PID ${existing_pid})"
    fi

    if ! validate_bonjour_metadata "$metadata_file"; then
        fail "no cached CoreDevice metadata is available; connect the iPhone once by USB or local Wi-Fi"
    fi

    /bin/rm -f -- "$pid_file" "$ready_file" "${BONJOUR_STATE_DIRECTORY}/relay.config"
    : > "$log_file"
    /usr/bin/python3 "$relay_script" \
        --interface "$BONJOUR_INTERFACE" \
        --listen-host "$local_ip" \
        --remote-host "$IPHONE_VPN_IP" \
        --proxy-hostname "$proxy_hostname" \
        --metadata-file "$metadata_file" \
        --listen-control-port "$LOCAL_CONTROL_PORT" \
        --dynamic-ports "$DYNAMIC_PORTS" \
        --ready-file "$ready_file" \
        >> "$log_file" 2>&1 < /dev/null &
    ACTIVE_RELAY_PID=$!
    ACTIVE_RELAY_SCRIPT="$relay_script"
    ACTIVE_RELAY_PID_FILE="$pid_file"
    ACTIVE_RELAY_READY_FILE="$ready_file"
    print -r -- "$ACTIVE_RELAY_PID" > "$pid_file"

    attempt=0
    while [[ ! -f "$ready_file" ]] && \
          /bin/kill -0 "$ACTIVE_RELAY_PID" 2>/dev/null && \
          (( attempt < 100 )); do
        /bin/sleep 0.1
        (( attempt += 1 ))
    done

    if [[ ! -f "$ready_file" ]] || \
       ! /bin/kill -0 "$ACTIVE_RELAY_PID" 2>/dev/null; then
        /bin/rm -f -- "$pid_file" "$ready_file"
        /usr/bin/tail -n 30 "$log_file" >&2 || true
        fail "could not start the CoreDevice VPN discovery relay"
    fi

    /bin/chmod 600 "$pid_file" "$log_file"
    log "Published the iPhone through ${BONJOUR_INTERFACE} and relaying it to ${IPHONE_VPN_IP} for this run (PID ${ACTIVE_RELAY_PID})"
}

device_name=""
device_identifier=""
device_udid=""
matched_requested_device=false

establish_developer_tunnel() {
    local identifier="$1"
    local index="$2"
    local details_json="${TEMPORARY_DIRECTORY}/device-details-${index}.json"
    local tunnel_state=""
    local attempt=1

    while (( attempt <= 6 )); do
        /bin/rm -f -- "$details_json"
        if xcrun devicectl device info details \
            --device "$identifier" \
            --timeout "$DISCOVERY_TIMEOUT" \
            --json-output "$details_json" \
            --quiet; then
            tunnel_state="$(/usr/bin/plutil \
                -extract result.connectionProperties.tunnelState \
                raw \
                "$details_json" 2>/dev/null || true)"
            [[ "$tunnel_state" == "connected" ]] && return 0
        fi

        (( attempt += 1 ))
        (( attempt <= 6 )) && /bin/sleep 2
    done

    return 1
}

discover_device() {
    local device_index=0
    local candidate_name=""
    local candidate_identifier=""
    local candidate_udid=""
    local candidate_tunnel_state=""

    device_name=""
    device_identifier=""
    device_udid=""
    /bin/rm -f -- "$DEVICES_JSON"

    if ! xcrun devicectl list devices \
        --filter "hardwareProperties.platform == 'iOS' AND connectionProperties.pairingState == 'paired'" \
        --sort-by deviceProperties.name \
        --timeout "$DISCOVERY_TIMEOUT" \
        --json-output "$DEVICES_JSON" \
        --quiet; then
        return 1
    fi

    while candidate_name="$(/usr/bin/plutil -extract "result.devices.${device_index}.deviceProperties.name" raw "$DEVICES_JSON" 2>/dev/null)"; do
        candidate_identifier="$(/usr/bin/plutil -extract "result.devices.${device_index}.identifier" raw "$DEVICES_JSON")"
        candidate_udid="$(/usr/bin/plutil -extract "result.devices.${device_index}.hardwareProperties.udid" raw "$DEVICES_JSON" 2>/dev/null || true)"
        candidate_tunnel_state="$(/usr/bin/plutil -extract "result.devices.${device_index}.connectionProperties.tunnelState" raw "$DEVICES_JSON" 2>/dev/null || true)"

        if [[ -z "$DEVICE_REQUEST" || \
              "$DEVICE_REQUEST" == "$candidate_name" || \
              "$DEVICE_REQUEST" == "$candidate_identifier" || \
              "$DEVICE_REQUEST" == "$candidate_udid" ]]; then
            if [[ -n "$DEVICE_REQUEST" ]]; then
                matched_requested_device=true
            fi

            if [[ "$candidate_tunnel_state" != "connected" ]]; then
                log "Connecting to ${candidate_name}"
                if ! establish_developer_tunnel "$candidate_identifier" "$device_index"; then
                    log "Skipping ${candidate_name}; a developer connection could not be established"
                    (( device_index += 1 ))
                    continue
                fi
            fi

            device_name="$candidate_name"
            device_identifier="$candidate_identifier"
            device_udid="${candidate_udid:-$candidate_identifier}"
            return 0
        fi

        (( device_index += 1 ))
    done

    return 1
}

if (( VPN_DISCOVERY )); then
    metadata_file="${BONJOUR_STATE_DIRECTORY}/remotepairing.metadata"
    /bin/mkdir -p "$BONJOUR_STATE_DIRECTORY"
    /bin/chmod 700 "$BONJOUR_STATE_DIRECTORY"
    if capture_bonjour_metadata "$metadata_file"; then
        log "Captured current CoreDevice Bonjour metadata"
    fi
fi

log "Looking for a paired physical iPhone through normal discovery"
if ! discover_device; then
    if (( VPN_DISCOVERY )); then
        log "No developer connection was available through normal discovery; trying the VPN fallback"
        ensure_vpn_discovery
        log "Looking for a paired physical iPhone through the VPN fallback"
        discover_device || true
    fi
fi

if [[ -z "$device_identifier" ]]; then
    if [[ -n "$DEVICE_REQUEST" ]]; then
        if $matched_requested_device; then
            fail "could not establish a developer connection to '${DEVICE_REQUEST}'"
        fi
        fail "no paired physical iPhone matched '$DEVICE_REQUEST'"
    fi
    fail "no reachable paired physical iPhone was found; unlock it or connect it by cable"
fi

log "Using ${device_name} (${device_udid})"
log "Xcode: ${DEVELOPER_DIRECTORY}"
log "Scheme: ${SCHEME} (${CONFIGURATION})"

if $DRY_RUN; then
    log "Dry run complete; the phone is available and would be selected"
    exit 0
fi

/bin/mkdir -p "$DERIVED_DATA_PATH"

log "Building for ${device_name}"
# The pinned AWS SDK 1.7.78 uses Smithy's package code-generation plugin.
# CLI deployment cannot show Xcode's plugin trust dialog; build the reviewed,
# version-locked package graph without that interactive validation step.
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=${device_udid}" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -skipPackagePluginValidation \
    -allowProvisioningUpdates \
    build

readonly APP_BUNDLE="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphoneos/HomeBase-GUI.app"
[[ -d "$APP_BUNDLE" ]] || fail "build succeeded but the app bundle was not found at $APP_BUNDLE"

BUNDLE_IDENTIFIER="$(/usr/bin/plutil -extract CFBundleIdentifier raw "${APP_BUNDLE}/Info.plist")"
[[ -n "$BUNDLE_IDENTIFIER" ]] || fail "could not read the app's bundle identifier"

log "Installing ${BUNDLE_IDENTIFIER} on ${device_name}"
xcrun devicectl device install app \
    --device "$device_identifier" \
    "$APP_BUNDLE"

log "Launching ${BUNDLE_IDENTIFIER} on ${device_name}"
if $ATTACH_CONSOLE; then
    xcrun devicectl device process launch \
        --device "$device_identifier" \
        --terminate-existing \
        --console \
        "$BUNDLE_IDENTIFIER"
else
    xcrun devicectl device process launch \
        --device "$device_identifier" \
        --terminate-existing \
        "$BUNDLE_IDENTIFIER"
fi

log "HomeBase GUI is running on ${device_name}"
