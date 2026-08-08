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
DRY_RUN=false

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
  bin/run-on-phone.sh [--device <name-or-id>] [--dry-run]

Options:
  --device <name-or-id>  Select a paired iPhone by its name, UDID, or CoreDevice
                         identifier. The default is the first reachable paired
                         physical iPhone, sorted by name.
  --dry-run              Discover the iPhone and print what would run without
                         building or installing anything.
  -h, --help             Show this help.

Environment overrides:
  HOMEBASE_XCODE_APP          Xcode app path (default: /Applications/Xcode.app)
  HOMEBASE_PROJECT_PATH       Project path
  HOMEBASE_SCHEME             Scheme name (default: HomeBase-GUI)
  HOMEBASE_CONFIGURATION      Build configuration (default: Debug)
  HOMEBASE_DERIVED_DATA_PATH  Derived-data directory
  HOMEBASE_DEVICE             Device name or identifier
  HOMEBASE_DEVICE_TIMEOUT     Discovery timeout in seconds (default: 15)
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

TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/homebase-run-on-phone.XXXXXX")"
trap '/bin/rm -rf -- "$TEMPORARY_DIRECTORY"' EXIT
readonly DEVICES_JSON="${TEMPORARY_DIRECTORY}/devices.json"

log "Looking for a paired physical iPhone"
if ! xcrun devicectl list devices \
    --filter "hardwareProperties.platform == 'iOS' AND connectionProperties.pairingState == 'paired'" \
    --sort-by deviceProperties.name \
    --timeout "$DISCOVERY_TIMEOUT" \
    --json-output "$DEVICES_JSON" \
    --quiet; then
    fail "device discovery failed; make sure the paired iPhone is reachable from this Mac"
fi

device_name=""
device_identifier=""
device_udid=""
device_index=0
matched_requested_device=false

establish_developer_tunnel() {
    local identifier="$1"
    local index="$2"
    local details_json="${TEMPORARY_DIRECTORY}/device-details-${index}.json"
    local tunnel_state=""

    if ! xcrun devicectl device info details \
        --device "$identifier" \
        --timeout "$DISCOVERY_TIMEOUT" \
        --json-output "$details_json" \
        --quiet; then
        return 1
    fi

    tunnel_state="$(/usr/bin/plutil \
        -extract result.connectionProperties.tunnelState \
        raw \
        "$details_json" 2>/dev/null || true)"
    [[ "$tunnel_state" == "connected" ]]
}

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
                if [[ -n "$DEVICE_REQUEST" ]]; then
                    fail "could not establish a developer connection to '${DEVICE_REQUEST}'"
                fi
                log "Skipping ${candidate_name}; a developer connection could not be established"
                (( device_index += 1 ))
                continue
            fi
        fi

        device_name="$candidate_name"
        device_identifier="$candidate_identifier"
        device_udid="${candidate_udid:-$candidate_identifier}"
        break
    fi

    (( device_index += 1 ))
done

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
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=${device_udid}" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
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
xcrun devicectl device process launch \
    --device "$device_identifier" \
    --terminate-existing \
    "$BUNDLE_IDENTIFIER"

log "HomeBase GUI is running on ${device_name}"
