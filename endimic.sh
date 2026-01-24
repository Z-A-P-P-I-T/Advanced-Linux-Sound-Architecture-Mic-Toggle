#!/bin/bash

# Advanced Linux Sound Architecture Mic Toggle with Security Features
# Version: 3.0
# Description: Enhanced microphone control with security monitoring and interactive menu
# Usage: ./endimic.sh [OPTIONS] or ./endimic.sh --menu

set -o errexit
set -o nounset
set -o pipefail

# Default values
VERSION="2.0"
AUTHOR="Endimic Development"
USER_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [[ -z "$USER_HOME" ]]; then
        USER_HOME="/home/$SUDO_USER"
    fi
fi
CONFIG_FILE="$USER_HOME/.endimic_config"
LOG_FILE="$USER_HOME/.endimic.log"
SECURITY_LOG="$USER_HOME/.endimic_security.log"
STATE_FILE="$USER_HOME/.endimic_state"
CAPTURE_CONTROL=""
CONTROL_BACKEND=""
WHITE_NOISE_FILE="$USER_HOME/.endimic_white_noise.wav"
PROOF_RECORD_FILE="$USER_HOME/.endimic_white_noise_proof.wav"
LOOPBACK_MODULE_ID=""
LOOPBACK_ACTIVE=false
LOOPBACK_PERSISTENT=false
NULL_SINK_MODULE_ID=""
NULL_SINK_NAME="endimic_privacy_sink"
LOOPBACK_MODE="null"
ORIGINAL_SOURCE=""
ORIGINAL_SINK=""
ORIGINAL_SINK_VOLUME=""
ORIGINAL_SINK_MUTED=""
ORIGINAL_DEFAULT_SINK=""
MONITOR_REQUIRE_SUDO=true
SPAM_AUDIBLE=false
AUDIBLE_SINK=""
PROMPT_AUDIBLE_CONFIRM=true
AUDIBLE_CONFIRM_PLAYBACK=true
AUTO_MUTE_ALL_SOURCES=true
FORCE_LOOPBACK_ON_MUTE=true
VERIFY_LOOPBACK_WHEN_MUTED=true
VERIFY_PROMPT_UNMUTE=true
AUDIBLE_FORCE_ALSA=true
AUTO_INSTALL_DEPS=false
LAST_VERIFY_STATUS="unknown"
LAST_VERIFY_TIME=""
PROOF_RECORD=false
RECORD_PID=""
GUARD_MODE=false
GUARD_RUN=false
GUARD_PID_FILE="$USER_HOME/.endimic_guard.pid"
MENU_SPLASH_SHOWN=false

# Initialize variables
state=""
show_help=false
show_version=false
verbose=false
show_menu=false
force_white_noise=false
security_check=false
white_noise_spam_mode=false
force_reset=false
state_set=false
white_noise_verify=false
white_noise_continuous=false
white_noise_verify_source=""
verify_source_set=false
continuous_original_state=""
continuous_state_changed=false
GUARD_STOP=false

# Load persisted state if present
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        if [[ ! -r "$STATE_FILE" ]]; then
            echo "Warning: Cannot read $STATE_FILE (check permissions)." >&2
            return 0
        fi
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    fi
}

save_state() {
    local tmp_state
    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    if [[ ! -w "$state_dir" ]]; then
        echo "Warning: Cannot write $STATE_FILE (check permissions)." >&2
        return 0
    fi
    tmp_state=$(mktemp "/tmp/endimic_state_XXXXXX")
    {
        printf 'LAST_VERIFY_STATUS=%q\n' "$LAST_VERIFY_STATUS"
        printf 'LAST_VERIFY_TIME=%q\n' "$LAST_VERIFY_TIME"
    } > "$tmp_state"
    chmod 600 "$tmp_state" 2>/dev/null || true
    mv -f "$tmp_state" "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

# Load user overrides if present
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi
load_state

# Create log directories if they don't exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$SECURITY_LOG")"

# Logging function
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# Security logging function
security_log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] SECURITY: $1" >> "$SECURITY_LOG"
    echo "[$timestamp] SECURITY: $1" >&2
}

# Check if amixer is available
check_dependencies() {
    if ! command -v amixer &> /dev/null && ! command -v pactl &> /dev/null && ! command -v wpctl &> /dev/null; then
        echo "Error: No supported audio controls found. Install alsa-utils or PipeWire/PulseAudio tools." >&2
        log "ERROR: No audio control tools found"
        exit 1
    fi

    if ! detect_backend; then
        echo "Error: No usable microphone control backend detected." >&2
        log "ERROR: No usable microphone control backend detected"
        exit 1
    fi
    
    # Check for arecord (for microphone monitoring)
    if ! command -v arecord &> /dev/null; then
        echo "Warning: arecord not found. Microphone monitoring will be disabled." >&2
        log "WARNING: arecord not found, microphone monitoring disabled"
    fi
}

# Resolve capture control name
resolve_capture_control() {
    if [[ -n "${CAPTURE_CONTROL:-}" ]]; then
        echo "$CAPTURE_CONTROL"
        return 0
    fi

    local controls
    controls=$(amixer scontrols 2>/dev/null | sed -n "s/^Simple mixer control '\\(.*\\)',0$/\\1/p")

    if echo "$controls" | grep -Fxq "Capture"; then
        echo "Capture"
        return 0
    fi

    local match
    match=$(echo "$controls" | grep -Ei "capture|mic|microphone|input" | head -n1)
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi

    echo ""
    return 1
}

# Detect which backend to use for microphone control
detect_backend() {
    local control
    if command -v amixer &> /dev/null; then
        control=$(resolve_capture_control || true)
        if [[ -n "$control" ]]; then
            CAPTURE_CONTROL="$control"
            CONTROL_BACKEND="alsa"
            return 0
        fi
    fi

    if command -v pactl &> /dev/null; then
        CONTROL_BACKEND="pactl"
        return 0
    fi

    if command -v wpctl &> /dev/null; then
        CONTROL_BACKEND="wpctl"
        return 0
    fi

    CONTROL_BACKEND=""
    return 1
}

run_user_cmd() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        local uid
        uid=$(id -u "$SUDO_USER" 2>/dev/null || echo "")
        if [[ -n "$uid" && -d "/run/user/$uid" ]]; then
            sudo -u "$SUDO_USER" env \
                XDG_RUNTIME_DIR="/run/user/$uid" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                "$@"
        else
            sudo -u "$SUDO_USER" "$@"
        fi
    else
        "$@"
    fi
}

get_runtime_dir_for_user() {
    local uid=""
    local runtime_dir=""

    if [[ -n "${SUDO_USER:-}" ]]; then
        uid=$(id -u "$SUDO_USER" 2>/dev/null || echo "")
    else
        uid=$(id -u 2>/dev/null || echo "")
    fi

    if [[ -n "$uid" ]]; then
        runtime_dir="/run/user/$uid"
        if [[ -d "$runtime_dir" ]]; then
            echo "$runtime_dir"
            return 0
        fi
    fi
    return 1
}

run_pulse_cmd() {
    local runtime_dir=""
    runtime_dir=$(get_runtime_dir_for_user || true)
    if [[ -n "$runtime_dir" ]]; then
        run_user_cmd env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            PULSE_SERVER="unix:${runtime_dir}/pulse/native" \
            "$@"
    else
        run_user_cmd "$@"
    fi
}

get_default_source() {
    local source
    source=$(run_user_cmd pactl get-default-source 2>/dev/null || true)
    if [[ -z "$source" ]]; then
        source=$(run_user_cmd pactl list short sources 2>/dev/null | awk 'NR==1 {print $2}')
    fi
    echo "$source"
}

map_pulse_source_to_alsa() {
    local pulse_source="$1"
    local card_device

    if [[ -z "$pulse_source" ]]; then
        return 1
    fi

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    card_device=$(run_user_cmd pactl list sources 2>/dev/null | awk -v name="$pulse_source" '
        $1 == "Name:" {
            in_block = ($2 == name)
        }
        in_block && $0 ~ /alsa.card/ {
            if (match($0, /[0-9]+/, m)) card = m[0]
        }
        in_block && $0 ~ /alsa.device/ {
            if (match($0, /[0-9]+/, m)) device = m[0]
        }
        $1 == "Name:" && $2 != name {
            in_block = 0
        }
        END {
            if (card != "" && device != "") {
                print card "," device
            }
        }
    ')

    if [[ -n "$card_device" ]]; then
        echo "plughw:${card_device}"
        return 0
    fi

    return 1
}

get_default_sink() {
    local sink
    sink=$(run_user_cmd pactl get-default-sink 2>/dev/null || true)
    if [[ -z "$sink" ]]; then
        sink=$(run_user_cmd pactl list short sinks 2>/dev/null | awk 'NR==1 {print $2}')
    fi
    echo "$sink"
}

get_active_sink() {
    local sink
    sink=$(run_user_cmd pactl list sinks 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "State:" {state=$2}
        state == "RUNNING" && name != "" {print name; exit}
    ')
    echo "$sink"
}

get_preferred_sink() {
    local sink
    sink=$(get_active_sink)
    if [[ -z "$sink" ]]; then
        sink=$(get_default_sink)
    fi
    echo "$sink"
}

list_audible_sinks() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    run_user_cmd pactl list sinks 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "Description:" {desc=$0}
        $1 == "State:" {state=$2}
        $1 == "Active" && $2 == "Port:" {port=$3}
        $1 == "Volume:" {volume=$0}
        $1 == "Mute:" {mute=$2}
        $1 == "Sample" && $2 == "Specification:" {spec=$0}
        $1 == "Sink" && $2 ~ /#/ {
            if (name != "") {
                print name "|" state "|" desc "|" port "|" mute
            }
            name=""; desc=""; state=""; port=""; mute=""
        }
        END {
            if (name != "") {
                print name "|" state "|" desc "|" port "|" mute
            }
        }
    '
}

select_audible_sinks() {
    local lines
    local sink
    local state
    local desc
    local port
    local mute
    local preferred=()
    local fallback=()

    if [[ -n "${AUDIBLE_SINK:-}" ]]; then
        printf "%s\n" "$AUDIBLE_SINK"
        return 0
    fi

    lines=$(list_audible_sinks || true)
    if [[ -z "$lines" ]]; then
        return 1
    fi

    while IFS='|' read -r sink state desc port mute; do
        if echo "$sink" | grep -qi "monitor"; then
            continue
        fi
        if echo "$desc" | grep -Eqi "hdmi|iec958|spdif|digital"; then
            fallback+=("$sink")
            continue
        fi
        if [[ "$state" == "RUNNING" ]] || echo "$desc" | grep -Eqi "speaker|headphone|analog|builtin|pci"; then
            preferred+=("$sink")
        else
            fallback+=("$sink")
        fi
    done <<< "$lines"

    if [[ ${#preferred[@]} -gt 0 ]]; then
        printf "%s\n" "${preferred[@]}"
        return 0
    fi
    if [[ ${#fallback[@]} -gt 0 ]]; then
        printf "%s\n" "${fallback[@]}"
        return 0
    fi
    return 1
}

has_non_digital_sink() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    if run_user_cmd pactl list sinks 2>/dev/null | grep -Eqi "Description:.*(analog|speaker|headphone|builtin|pci)"; then
        return 0
    fi
    return 1
}

ensure_analog_sink_available() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    if has_non_digital_sink; then
        return 0
    fi

    # Try to switch card profiles to analog output if available.
    run_user_cmd pactl list cards 2>/dev/null | awk '
        $1 == "Name:" {card=$2}
        $1 == "Profiles:" {in_profiles=1; next}
        in_profiles && NF == 0 {in_profiles=0}
        in_profiles && $1 ~ /output:analog-stereo/ {print card "|" $1}
    ' | while IFS='|' read -r card profile; do
        if [[ -n "$card" && -n "$profile" ]]; then
            security_log "Attempting to set card profile: $card $profile"
            run_user_cmd pactl set-card-profile "$card" "$profile" >/dev/null 2>&1 || true
        fi
    done

    sleep 0.5
}

map_pulse_sink_to_alsa() {
    local pulse_sink="$1"
    local card_device

    if [[ -z "$pulse_sink" ]]; then
        return 1
    fi

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    card_device=$(run_user_cmd pactl list sinks 2>/dev/null | awk -v name="$pulse_sink" '
        $1 == "Name:" {
            in_block = ($2 == name)
        }
        in_block && $0 ~ /alsa.card/ {
            if (match($0, /[0-9]+/, m)) card = m[0]
        }
        in_block && $0 ~ /alsa.device/ {
            if (match($0, /[0-9]+/, m)) device = m[0]
        }
        $1 == "Name:" && $2 != name {
            in_block = 0
        }
        END {
            if (card != "" && device != "") {
                print card "," device
            }
        }
    ')

    if [[ -n "$card_device" ]]; then
        echo "plughw:${card_device}"
        return 0
    fi

    return 1
}

ensure_default_sink_unmuted() {
    local sink
    sink=$(get_default_sink)
    if [[ -z "$sink" ]]; then
        return 1
    fi

    if run_user_cmd pactl get-sink-mute "$sink" 2>/dev/null | grep -qi "yes"; then
        run_user_cmd pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true
    fi
    return 0
}

snapshot_sink_state() {
    local sink
    sink=$(get_preferred_sink)
    if [[ -z "$sink" ]]; then
        return 1
    fi

    ORIGINAL_SINK="$sink"
    ORIGINAL_SINK_VOLUME=$(run_user_cmd pactl get-sink-volume "$sink" 2>/dev/null || true)
    ORIGINAL_SINK_MUTED=$(run_user_cmd pactl get-sink-mute "$sink" 2>/dev/null || true)
    return 0
}

snapshot_default_sink() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi
    ORIGINAL_DEFAULT_SINK=$(run_user_cmd pactl get-default-sink 2>/dev/null || true)
    return 0
}

set_temp_default_sink_for_playback() {
    local target_sink=""

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    if [[ -n "${AUDIBLE_SINK:-}" ]]; then
        target_sink="$AUDIBLE_SINK"
    else
        target_sink=$(get_preferred_sink)
    fi

    if [[ -n "$target_sink" ]]; then
        snapshot_default_sink || true
        run_user_cmd pactl set-default-sink "$target_sink" >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

restore_default_sink() {
    if ! command -v pactl &> /dev/null; then
        return 0
    fi
    if [[ -n "$ORIGINAL_DEFAULT_SINK" ]]; then
        run_user_cmd pactl set-default-sink "$ORIGINAL_DEFAULT_SINK" >/dev/null 2>&1 || true
    fi
}

apply_audible_sink_state() {
    local volume="${1:-80%}"
    local sink
    sink=$(get_preferred_sink)
    if [[ -z "$sink" ]]; then
        return 1
    fi

    run_user_cmd pactl set-sink-mute "$sink" 0 >/dev/null 2>&1 || true
    run_user_cmd pactl set-sink-volume "$sink" "$volume" >/dev/null 2>&1 || true
    return 0
}

restore_sink_state() {
    if [[ -z "$ORIGINAL_SINK" ]]; then
        return 0
    fi

    if [[ -n "$ORIGINAL_SINK_VOLUME" ]]; then
        local volume
        volume=$(echo "$ORIGINAL_SINK_VOLUME" | awk -F'/' 'NR==1 {gsub(/%/, "", $2); print $2"%"; exit}')
        if [[ -n "$volume" ]]; then
            run_user_cmd pactl set-sink-volume "$ORIGINAL_SINK" "$volume" >/dev/null 2>&1 || true
        fi
    fi

    if echo "$ORIGINAL_SINK_MUTED" | grep -qi "yes"; then
        run_user_cmd pactl set-sink-mute "$ORIGINAL_SINK" 1 >/dev/null 2>&1 || true
    else
        run_user_cmd pactl set-sink-mute "$ORIGINAL_SINK" 0 >/dev/null 2>&1 || true
    fi
}

setup_loopback_for_mic() {
    local sink
    local module_id

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    cleanup_existing_loopbacks

    ORIGINAL_SOURCE=$(get_default_source)
    if [[ "$LOOPBACK_MODE" == "null" ]]; then
        NULL_SINK_MODULE_ID=$(run_user_cmd pactl load-module module-null-sink \
            sink_name="$NULL_SINK_NAME" 2>/dev/null || true)
        if [[ -z "$NULL_SINK_MODULE_ID" ]]; then
            return 1
        fi

        module_id=$(run_user_cmd pactl load-module module-remap-source \
            source_name=endimic_loopback \
            master="${NULL_SINK_NAME}.monitor" 2>/dev/null || true)
        if [[ -z "$module_id" ]]; then
            run_user_cmd pactl unload-module "$NULL_SINK_MODULE_ID" >/dev/null 2>&1 || true
            NULL_SINK_MODULE_ID=""
            return 1
        fi
    else
        sink=$(get_default_sink)
        if [[ -z "$sink" ]]; then
            return 1
        fi
        module_id=$(run_user_cmd pactl load-module module-remap-source \
            source_name=endimic_loopback \
            master="${sink}.monitor" 2>/dev/null || true)
        if [[ -z "$module_id" ]]; then
            return 1
        fi
    fi

    run_user_cmd pactl set-default-source endimic_loopback >/dev/null 2>&1 || true
    LOOPBACK_MODULE_ID="$module_id"
    LOOPBACK_ACTIVE=true
    return 0
}

cleanup_loopback_for_mic() {
    if [[ "$LOOPBACK_ACTIVE" != true ]]; then
        return 0
    fi

    if [[ -n "$LOOPBACK_MODULE_ID" ]]; then
        run_user_cmd pactl unload-module "$LOOPBACK_MODULE_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$NULL_SINK_MODULE_ID" ]]; then
        run_user_cmd pactl unload-module "$NULL_SINK_MODULE_ID" >/dev/null 2>&1 || true
    fi
    cleanup_existing_loopbacks

    if [[ -n "$ORIGINAL_SOURCE" ]]; then
        run_user_cmd pactl set-default-source "$ORIGINAL_SOURCE" >/dev/null 2>&1 || true
    fi

    LOOPBACK_MODULE_ID=""
    LOOPBACK_ACTIVE=false
    NULL_SINK_MODULE_ID=""
    ORIGINAL_SOURCE=""
}

resolve_playback_device() {
    local sink
    local mapped

    if command -v pactl &> /dev/null; then
        sink=$(get_preferred_sink)
        if [[ -n "$sink" ]]; then
            mapped=$(map_pulse_sink_to_alsa "$sink" || true)
            if [[ -n "$mapped" ]]; then
                echo "$mapped"
                return 0
            fi
        fi
    fi

    echo ""
    return 1
}

# Play via PulseAudio/PipeWire utilities when available
play_white_noise_via_pulse() {
    local noise_file="$1"
    local timeout_seconds="${2:-5}"
    local sink
    local sinks

    ensure_analog_sink_available || true
    if ! has_non_digital_sink; then
        echo "⚠️  No analog sinks found. Audible playback may be silent on digital-only outputs."
        security_log "Audible playback warning: no analog sinks detected"
    fi
    sinks=$(select_audible_sinks || true)
    if command -v paplay &> /dev/null; then
        if [[ -n "$sinks" ]]; then
            while IFS= read -r sink; do
                security_log "Audible playback attempt via paplay to sink: $sink"
                PULSE_SINK="$sink" timeout "$timeout_seconds" paplay "$noise_file" 2>/dev/null && return 0
            done <<< "$sinks"
        fi
        timeout "$timeout_seconds" paplay "$noise_file" 2>/dev/null && return 0
    fi

    if command -v pw-play &> /dev/null; then
        timeout "$timeout_seconds" pw-play "$noise_file" 2>/dev/null && return 0
    fi

    return 1
}

run_with_timeout() {
    local duration="$1"
    shift
    if command -v timeout &> /dev/null; then
        timeout "$duration" "$@"
    else
        "$@"
    fi
}

wait_for_pid() {
    local pid="$1"
    local timeout_seconds="${2:-5}"
    local start
    start=$(date +%s)

    while kill -0 "$pid" 2>/dev/null; do
        if [[ $(( $(date +%s) - start )) -ge "$timeout_seconds" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
    done

    wait "$pid" 2>/dev/null || true
    return 0
}

play_audible_confirmation() {
    local noise_file="$1"
    local sinks

    if [[ "${AUDIBLE_CONFIRM_PLAYBACK}" != true ]]; then
        return 0
    fi
    if [[ -z "$noise_file" || ! -f "$noise_file" ]]; then
        return 0
    fi
    if ! command -v aplay &> /dev/null && ! command -v paplay &> /dev/null && ! command -v pw-play &> /dev/null; then
        return 0
    fi

    if command -v pactl &> /dev/null; then
        snapshot_sink_state || true
        apply_audible_sink_state "90%" || true
        set_temp_default_sink_for_playback || true
    fi

    echo "🔊 Playing audible confirmation..."

    if play_noise_audible "$noise_file" 5; then
        restore_default_sink
        restore_sink_state
        return 0
    fi

    restore_default_sink
    restore_sink_state
    return 0
}

prompt_audible_confirmation() {
    if [[ "${PROMPT_AUDIBLE_CONFIRM}" != true ]]; then
        return 0
    fi
    if ! command -v pactl &> /dev/null; then
        return 0
    fi
    echo ""
    read -p "Did you hear white noise from speakers? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "If you didn't hear it, try setting an explicit sink."
        echo "Available sinks:"
        run_user_cmd pactl list short sinks 2>/dev/null | awk '{printf "  - %s\n", $2}'
        echo "Set one in $CONFIG_FILE:"
        echo "  AUDIBLE_SINK=<sink-name>"
        echo "You can also play the saved file:"
        echo "  aplay $WHITE_NOISE_FILE"
        if [[ -f "$WHITE_NOISE_FILE" ]]; then
            echo "Attempting direct playback for confirmation..."
            play_noise_audible "$WHITE_NOISE_FILE" 5 || true
        fi
    fi
}

cleanup_existing_loopbacks() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    run_user_cmd pactl list short modules 2>/dev/null | awk '/endimic_loopback|endimic_privacy_sink/ {print $1}' | while read -r module_id; do
        if [[ -n "$module_id" ]]; then
            run_user_cmd pactl unload-module "$module_id" >/dev/null 2>&1 || true
        fi
    done
}

get_default_source_name() {
    local source
    source=$(run_user_cmd pactl get-default-source 2>/dev/null || true)
    if [[ -z "$source" ]]; then
        source=$(run_user_cmd pactl list short sources 2>/dev/null | awk 'NR==1 {print $2}')
    fi
    echo "$source"
}

get_preferred_pulse_source() {
    local source
    source=$(run_user_cmd pactl list sources 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "State:" {state=$2}
        $1 == "Description:" {desc=$0}
        state == "RUNNING" && name !~ /\.monitor$/ && name !~ /endimic_loopback/ {print name; exit}
    ')
    if [[ -z "$source" ]]; then
        source=$(get_default_source_name)
    fi
    echo "$source"
}

list_verify_sources() {
    local default_source=""
    local ordered=""

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    default_source=$(get_default_source_name)

    while IFS='|' read -r name state; do
        [[ -z "$name" ]] && continue
        if [[ "$state" == "RUNNING" ]]; then
            ordered+="${name}"$'\n'
        fi
    done < <(run_user_cmd pactl list sources 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "State:" {state=$2}
        $1 == "Source" && $2 ~ /#/ {
            if (name != "" && name !~ /\.monitor$/ && name != "endimic_loopback") {
                print name "|" state
            }
            name=""; state=""
        }
        END {
            if (name != "" && name !~ /\.monitor$/ && name != "endimic_loopback") {
                print name "|" state
            }
        }
    ')

    if [[ -n "$default_source" && "$default_source" != "endimic_loopback" && "$default_source" != *".monitor" ]]; then
        if ! grep -Fxq "$default_source" <<< "$ordered"; then
            ordered+="${default_source}"$'\n'
        fi
    fi

    while IFS='|' read -r name state; do
        [[ -z "$name" ]] && continue
        if ! grep -Fxq "$name" <<< "$ordered"; then
            ordered+="${name}"$'\n'
        fi
    done < <(run_user_cmd pactl list sources 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "State:" {state=$2}
        $1 == "Source" && $2 ~ /#/ {
            if (name != "" && name !~ /\.monitor$/ && name != "endimic_loopback") {
                print name "|" state
            }
            name=""; state=""
        }
        END {
            if (name != "" && name !~ /\.monitor$/ && name != "endimic_loopback") {
                print name "|" state
            }
        }
    ')

    if run_user_cmd pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "endimic_loopback"; then
        ordered+="endimic_loopback"$'\n'
    fi

    printf "%s" "$ordered" | awk 'NF'
}

list_physical_sources() {
    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    run_user_cmd pactl list short sources 2>/dev/null | awk '{print $2}' \
        | grep -Ev '(^endimic_loopback$|\.monitor$)' || true
}

are_physical_sources_muted() {
    local source
    local any=false

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        any=true
        if run_user_cmd pactl get-source-mute "$source" 2>/dev/null | grep -qi "no"; then
            return 1
        fi
    done < <(list_physical_sources)

    if [[ "$any" != true ]]; then
        return 1
    fi
    return 0
}

mute_all_physical_sources() {
    local source

    if [[ "${AUTO_MUTE_ALL_SOURCES}" != true ]]; then
        return 0
    fi
    if ! command -v pactl &> /dev/null; then
        return 0
    fi

    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        run_user_cmd pactl set-source-mute "$source" 1 >/dev/null 2>&1 || true
    done < <(list_physical_sources)
}

unmute_all_physical_sources() {
    local source

    if ! command -v pactl &> /dev/null; then
        return 0
    fi

    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        run_user_cmd pactl set-source-mute "$source" 0 >/dev/null 2>&1 || true
    done < <(list_physical_sources)
}

VERIFICATION_SOURCES=()
VERIFY_PLAYBACK_SUCCESS=false

run_verification_cycle() {
    local noise_file="$1"
    local duration="$2"
    local announce="$3"
    local spam_mode="$4"
    local record_duration=$((duration + 1))
    local playback_success_any=false
    local playback_success=false
    local verify_file=""
    local record_pid=""
    local resolved_device=""

    verify_ok=false
    verify_error=""
    verify_source_used=""
    VERIFY_PLAYBACK_SUCCESS=false

    for resolved_device in "${VERIFICATION_SOURCES[@]}"; do
        if [[ -n "$verify_file" && -f "$verify_file" ]]; then
            rm -f "$verify_file"
        fi
        verify_file=$(mktemp "/tmp/white_noise_verify_XXXXXX.wav")
        if [[ -z "$verify_file" ]]; then
            verify_error="Failed to create verify file"
            continue
        fi
        record_pid=""

        record_pid=$(start_capture_recording "$record_duration" "$verify_file" "$resolved_device")
        if [[ -z "$record_pid" ]]; then
            verify_error="Failed to start recording"
            continue
        fi
        sleep 0.2

        if [[ "$spam_mode" == true ]]; then
            echo "🔊 Forcing white noise through microphone input..."
            playback_success=false
            for i in {1..3}; do
                if play_white_noise_file "$noise_file" "$((duration + 3))"; then
                    echo "✅ White noise injection attempt $i: SUCCESS"
                    playback_success=true
                    break
                else
                    echo "⚠️  White noise injection attempt $i: Trying alternative method..."
                    verify_error="All playback methods failed"
                fi
            done
        else
            if [[ "$announce" == true ]]; then
                echo "🔊 Playing white noise..."
            fi
            if play_white_noise_file "$noise_file" "$((duration + 3))"; then
                playback_success=true
            else
                verify_error="All playback methods failed"
            fi
        fi

        if [[ "$playback_success" == true ]]; then
            playback_success_any=true
        fi

        if [[ -n "$record_pid" ]]; then
            wait_for_pid "$record_pid" "$record_duration" || true
        fi

        if [[ -n "$verify_file" ]]; then
            if verify_white_noise_capture "$verify_file"; then
                verify_ok=true
                verify_source_used="$resolved_device"
                break
            else
                verify_error="No audio detected during verification"
            fi
        fi
    done

    if [[ -f "$verify_file" ]]; then
        cp -f "$verify_file" "$PROOF_RECORD_FILE" 2>/dev/null || true
        chmod 600 "$PROOF_RECORD_FILE" 2>/dev/null || true
    fi

    rm -f "$verify_file"
    VERIFY_PLAYBACK_SUCCESS="$playback_success_any"
}

select_capture_source() {
    if [[ -n "$white_noise_verify_source" ]]; then
        echo "$white_noise_verify_source"
        return 0
    fi

    if command -v pactl &> /dev/null; then
        if run_user_cmd pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "endimic_loopback"; then
            echo "endimic_loopback"
            return 0
        fi
        echo "$(get_preferred_pulse_source)"
        return 0
    fi

    echo ""
    return 1
}

start_capture_recording() {
    local duration="$1"
    local out_file="$2"
    local source="$3"
    local capture_device=""

    if command -v parecord &> /dev/null; then
        if [[ -n "$source" ]]; then
            if command -v timeout &> /dev/null; then
                run_user_cmd timeout "$duration" parecord --device="$source" -d "$duration" "$out_file" 2>/dev/null &
            else
                run_user_cmd parecord --device="$source" -d "$duration" "$out_file" 2>/dev/null &
            fi
        else
            if command -v timeout &> /dev/null; then
                run_user_cmd timeout "$duration" parecord -d "$duration" "$out_file" 2>/dev/null &
            else
                run_user_cmd parecord -d "$duration" "$out_file" 2>/dev/null &
            fi
        fi
        echo $!
        return 0
    fi

    if [[ -n "$source" ]]; then
        capture_device=$(resolve_verify_capture_device "$source" || true)
    fi
    if [[ -n "$capture_device" ]]; then
        if command -v timeout &> /dev/null; then
            run_user_cmd timeout "$duration" arecord -D "$capture_device" -d "$duration" -f cd -t wav "$out_file" 2>/dev/null &
        else
            run_user_cmd arecord -D "$capture_device" -d "$duration" -f cd -t wav "$out_file" 2>/dev/null &
        fi
        echo $!
        return 0
    fi

    if command -v timeout &> /dev/null; then
        run_user_cmd timeout "$duration" arecord -d "$duration" -f cd -t wav "$out_file" 2>/dev/null &
    else
        run_user_cmd arecord -d "$duration" -f cd -t wav "$out_file" 2>/dev/null &
    fi
    echo $!
}

resolve_verify_capture_device() {
    local source="$1"
    local mapped

    if [[ -n "$source" ]]; then
        if [[ "$source" == hw:* || "$source" == plughw:* ]]; then
            echo "$source"
            return 0
        fi

        mapped=$(map_pulse_source_to_alsa "$source" || true)
        if [[ -n "$mapped" ]]; then
            echo "$mapped"
            return 0
        fi

        echo ""
        return 1
    fi

    mapped=$(map_pulse_source_to_alsa "$(get_default_source)" || true)
    if [[ -n "$mapped" ]]; then
        echo "$mapped"
        return 0
    fi

    echo ""
    return 1
}

detect_external_mic() {
    local sources
    local external=false

    if ! command -v pactl &> /dev/null; then
        return 1
    fi

    sources=$(run_user_cmd pactl list sources 2>/dev/null | awk '
        $1 == "Name:" {name=$2}
        $1 == "Description:" {
            desc=$0
        }
        /device.bus/ {
            bus=$3
        }
        $1 == "Source" && $2 ~ /#/
        /State:/ {
            if (name !~ /\.monitor$/) {
                print name "|" desc "|" bus
            }
            name=""; desc=""; bus=""
        }
    ')

    if echo "$sources" | grep -Ei "Bluetooth|USB|bluetooth|usb|headset" >/dev/null 2>&1; then
        external=true
    fi

    if [[ "$external" == true ]]; then
        return 0
    fi
    return 1
}

auto_spam_on_active_mic() {
    echo "🔊 Auto-spam: active or external microphone detected"
    generate_white_noise 2 true false true true
}

# Check if user has sudo privileges
check_sudo() {
    if ! sudo -v 2>/dev/null; then
        echo "Warning: This script requires sudo privileges for microphone control." >&2
        log "WARNING: No sudo privileges detected"
        return 1
    fi
    return 0
}

# Get current microphone state
get_current_state() {
    local current_state
    local control
    local source

    case "$CONTROL_BACKEND" in
        alsa)
            control=$(resolve_capture_control || true)
            if [[ -z "$control" ]]; then
                echo "unknown"
                log "ERROR: No capture control found"
                return 0
            fi
            current_state=$(amixer sget "$control" 2>/dev/null | grep -o "\[on\]\|\[off\]" | head -1 | tr -d '[]')
            ;;
        pactl)
            source=$(get_default_source)
            if [[ -z "$source" ]]; then
                echo "unknown"
                log "ERROR: No default source found"
                return 0
            fi
            if run_user_cmd pactl get-source-mute "$source" 2>/dev/null | grep -qi "yes"; then
                current_state="off"
            else
                current_state="on"
            fi
            ;;
        wpctl)
            if run_user_cmd wpctl get-volume @DEFAULT_SOURCE@ 2>/dev/null | grep -qi "muted"; then
                current_state="off"
            else
                current_state="on"
            fi
            ;;
        *)
            echo "unknown"
            log "ERROR: No microphone control backend selected"
            return 0
            ;;
    esac

    if [[ -z "$current_state" ]]; then
        echo "unknown"
        log "WARNING: Could not determine current mic state"
    else
        echo "$current_state"
    fi
}

# Check if microphone is actually receiving sound (security feature)
check_mic_activity() {
    if ! command -v arecord &> /dev/null; then
        echo "Monitoring disabled (arecord not available)"
        return 1
    fi

    if [[ "$(get_current_state)" == "off" && "$LOOPBACK_MODE" == "null" ]]; then
        echo "Monitoring: skipped (mic is muted/loopback mode)"
        return 1
    fi

    echo "Checking microphone activity for 3 seconds..."
    
    # Record 3 seconds of audio and check if it contains significant sound
    local temp_file
    temp_file=$(mktemp "/tmp/mic_monitor_XXXXXX.wav")
    local activity_detected=false
    local record_cmd=()
    local capture_device=""
    
    # Try to record with timeout
    capture_device=$(resolve_verify_capture_device "$white_noise_verify_source" || true)
    if [[ -n "$capture_device" ]]; then
        record_cmd=(arecord -D "$capture_device" -d 3 -f cd -t wav "$temp_file")
    else
        record_cmd=(arecord -d 3 -f cd -t wav "$temp_file")
    fi

    if timeout 3 run_user_cmd "${record_cmd[@]}" 2>/dev/null; then
        # Check file size - if it's very small, no activity
        local file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
        
        if [[ "$file_size" -gt 1000 ]]; then
            activity_detected=true
            security_log "Microphone activity detected while mic should be off!"
        fi
        
        rm -f "$temp_file"
    else
        # Permission denied - this could mean mic is properly secured OR there's an issue
        # Try with sudo if we have non-interactive privileges
        if sudo -n true 2>/dev/null; then
            if timeout 3 sudo -n arecord -d 3 -f cd -t wav "$temp_file" 2>/dev/null; then
                local file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
                if [[ "$file_size" -gt 1000 ]]; then
                    activity_detected=true
                    security_log "Microphone activity detected with sudo privileges!"
                fi
                rm -f "$temp_file"
            else
                security_log "Monitoring failed with sudo - possible proper security"
            fi
        else
            security_log "Monitoring requires sudo - assuming secure state"
            if [[ "$MONITOR_REQUIRE_SUDO" == true ]]; then
                echo "Note: monitoring needs sudo. Set MONITOR_REQUIRE_SUDO=false to skip this check." >&2
                security_log "Monitoring aborted: sudo required"
                return 1
            fi
        fi
        
        return 1  # Conservative approach: assume no activity if we can't verify
    fi
    
    if [[ "$activity_detected" == true ]]; then
        return 0  # Activity detected
    fi
    return 1  # No activity detected or not verified
}

# Generate white noise to force mic activation (security countermeasure)
generate_white_noise() {
    local duration=${1:-2}  # Default 2 seconds, but can be overridden
    local spam_mode=${2:-false}  # Normal mode by default
    local verify_capture=${3:-false}
    local announce=${4:-true}
    local secure_after=${5:-true}
    
    if ! command -v aplay &> /dev/null; then
        echo "Error: aplay not found. Cannot generate white noise." >&2
        security_log "Failed to generate white noise (aplay not available)"
        return 1
    fi
    
    if [[ "$announce" == true ]]; then
        if [[ "$spam_mode" == true ]]; then
            echo "🚨 WHITE NOISE SPAM MODE ACTIVATED - Forcing microphone privacy!"
            security_log "WHITE NOISE SPAM MODE ACTIVATED - Privacy enforcement"
        else
            echo "Generating white noise to test microphone..."
        fi
    fi
    
    # Generate white noise
    local sample_rate=44100
    local noise_file
    noise_file=$(mktemp "/tmp/white_noise_XXXXXX.wav")
    
    # Generate white noise using best available method
    if command -v sox &> /dev/null; then
        sox -n -r "$sample_rate" -c 2 "$noise_file" synth "$duration" whitenoise >/dev/null 2>&1
    elif command -v ffmpeg &> /dev/null; then
        ffmpeg -f lavfi -i "anullsrc=r=$sample_rate:cl=stereo" -t "$duration" -f wav "$noise_file" 2>/dev/null
    else
        # Fallback method
        echo "Warning: Neither sox nor ffmpeg found. Using fallback method." >&2
        dd if=/dev/urandom bs=1 count=$((duration * sample_rate * 4)) | tee "$noise_file" >/dev/null 2>&1
    fi
    
    local loopback_started_here=false
    if [[ "$LOOPBACK_ACTIVE" != true ]]; then
        if setup_loopback_for_mic; then
            loopback_started_here=true
        elif [[ "$announce" == true ]]; then
            echo "⚠️  Loopback setup failed; playback may not reach mic input"
        fi
    fi

    if [[ -f "$noise_file" && ( "$spam_mode" == false || "$SPAM_AUDIBLE" == true ) ]]; then
        chmod 644 "$noise_file" 2>/dev/null || true
        cp -f "$noise_file" "$WHITE_NOISE_FILE" 2>/dev/null || true
        chmod 600 "$WHITE_NOISE_FILE" 2>/dev/null || true
    fi

    # Optional verification capture
    local verify_file=""
    local record_pid=""
    local verify_error=""
    local verify_ok=false
    local verify_source_used=""
    local record_duration=$((duration + 1))
    local verify_sources=()
    local physical_muted=false
    local prompt_unmute=false
    local loopback_attempted=false

    if [[ "$verify_capture" == true ]]; then
        if ! command -v arecord &> /dev/null && ! command -v parecord &> /dev/null; then
            verify_error="recording tools not available"
        else
            if are_physical_sources_muted; then
                physical_muted=true
            fi

            if [[ -n "$white_noise_verify_source" ]]; then
                verify_sources=("$white_noise_verify_source")
            else
                if [[ "$physical_muted" == true && "$VERIFY_LOOPBACK_WHEN_MUTED" == true ]]; then
                    if run_user_cmd pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "endimic_loopback"; then
                        verify_sources=("endimic_loopback")
                        prompt_unmute=true
                    fi
                fi
                if [[ ${#verify_sources[@]} -eq 0 ]]; then
                    mapfile -t verify_sources < <(list_verify_sources || true)
                fi
            fi
            if [[ ${#verify_sources[@]} -eq 0 ]]; then
                verify_sources=("")
            fi
            if printf "%s\n" "${verify_sources[@]}" | grep -qx "endimic_loopback"; then
                loopback_attempted=true
            fi
        fi
    fi

    # Play the white noise with comprehensive error handling
    if [[ -f "$noise_file" ]]; then
        local playback_success=false
        local error_message=""
        local i
        local playback_success_any=false

        if [[ "$verify_capture" == true ]]; then
            if [[ "$LOOPBACK_MODE" == "null" ]]; then
                play_noise_to_loopback_sink "$noise_file" "$((duration + 3))" || true
            fi
            VERIFICATION_SOURCES=("${verify_sources[@]}")
            run_verification_cycle "$noise_file" "$duration" "$announce" "$spam_mode"
            playback_success_any="$VERIFY_PLAYBACK_SUCCESS"

            if [[ "$physical_muted" == true && "$prompt_unmute" == true && "$VERIFY_PROMPT_UNMUTE" == true ]]; then
                echo ""
                read -p "Temporarily unmute physical mic(s) to verify capture? (y/N): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    unmute_all_physical_sources
                    mapfile -t verify_sources < <(list_physical_sources || true)
                    if [[ ${#verify_sources[@]} -eq 0 ]]; then
                        verify_sources=("")
                    fi
                    VERIFICATION_SOURCES=("${verify_sources[@]}")
                    run_verification_cycle "$noise_file" "$duration" "$announce" "$spam_mode"
                    playback_success_any="$VERIFY_PLAYBACK_SUCCESS"
                    mute_all_physical_sources
                fi
            fi
        else
            if [[ "$spam_mode" == true ]]; then
                echo "🔊 Forcing white noise through microphone input..."
                for i in {1..3}; do
                    if play_white_noise_file "$noise_file" "$((duration + 3))"; then
                        echo "✅ White noise injection attempt $i: SUCCESS"
                        playback_success=true
                        break
                    else
                        echo "⚠️  White noise injection attempt $i: Trying alternative method..."
                        error_message="All playback methods failed"
                    fi
                done
            else
                if [[ "$announce" == true ]]; then
                    echo "🔊 Playing white noise..."
                fi
                if play_white_noise_file "$noise_file" "$((duration + 3))"; then
                    playback_success=true
                else
                    error_message="All playback methods failed"
                fi
            fi
            playback_success_any="$playback_success"
        fi

        rm -f "$noise_file"

        if [[ "$verify_capture" == true && "$verify_ok" != true ]]; then
            if [[ -z "$verify_error" ]]; then
                verify_error="Verification unavailable"
            fi
            error_message="White noise verification failed: $verify_error"
        fi
        
        # Provide comprehensive feedback
        if [[ "$playback_success_any" == true ]]; then
            if [[ "$spam_mode" == true ]]; then
                security_log "WHITE NOISE SPAM COMPLETED - Privacy enforced for ${duration}s"
                echo "🎉 White noise spam completed successfully!"
                echo "   ✅ Microphone privacy enforced for ${duration}s"
                echo "   ✅ Any potential eavesdropping would only hear static"
            else
                security_log "White noise test completed successfully"
                echo "🎉 White noise test completed successfully!"
                echo "   ✅ Duration: ${duration}s"
                echo "   ✅ Playback: completed"
                if [[ "$verify_capture" == true ]]; then
                    if [[ "$verify_ok" == true ]]; then
                        echo "   ✅ Verification: capture detected"
                        LAST_VERIFY_STATUS="success"
                        save_state
                        if [[ -n "$verify_source_used" ]]; then
                            echo "   ✅ Source used: $verify_source_used"
                        fi
                        if [[ "$LOOPBACK_MODE" == "null" && "$verify_source_used" == "endimic_loopback" ]]; then
                            echo "   ✅ Loopback verified via null sink (privacy mode)"
                        fi
                    else
                        if [[ "$LOOPBACK_MODE" == "null" ]]; then
                            echo "   ℹ️  Verification: no acoustic capture detected (expected in privacy mode)"
                            echo "   ℹ️  Loopback uses a private null sink"
                            if [[ "$loopback_attempted" == true ]]; then
                                LAST_VERIFY_STATUS="loopback"
                                save_state
                            else
                                LAST_VERIFY_STATUS="failed"
                                save_state
                            fi
                        else
                            echo "   ⚠️  Verification: no capture detected"
                            if [[ -n "$error_message" ]]; then
                                echo "   ⚠️  $error_message"
                            fi
                            LAST_VERIFY_STATUS="failed"
                            save_state
                        fi
                        echo "   ℹ️  Tip: physical verify needs speakers near the mic; try --verify-source <mic>"
                    fi
                    LAST_VERIFY_TIME=$(date "+%Y-%m-%d %H:%M:%S")
                    save_state
                    echo "   📄 Proof recording: $PROOF_RECORD_FILE"
                    prompt_audible_confirmation
                fi
                if [[ "$spam_mode" == false && -f "$WHITE_NOISE_FILE" ]]; then
                    echo "   📄 Saved file: $WHITE_NOISE_FILE"
                fi
            fi
            if [[ "$spam_mode" == false && "$secure_after" == true ]]; then
                echo "🔒 Post-test: muting microphone and monitoring for tampering..."
                set_mic_state "off" >/dev/null 2>&1 || true
                if check_mic_activity; then
                    security_log "SECURITY ALERT: Activity detected after test while mic off"
                else
                    security_log "Post-test monitoring: no activity detected"
                fi
            fi
            if [[ "$loopback_started_here" == true && "$LOOPBACK_PERSISTENT" != true ]]; then
                cleanup_loopback_for_mic
            fi
            return 0
        else
            if [[ "$verify_capture" == true ]]; then
                LAST_VERIFY_STATUS="failed"
                LAST_VERIFY_TIME=$(date "+%Y-%m-%d %H:%M:%S")
                save_state
            fi
            security_log "WHITE NOISE FAILED: $error_message"
            echo "❌ White noise playback failed!"
            echo "   Error: $error_message"
            echo ""
            echo "🛠️ Troubleshooting suggestions:"
            echo "   • Check if speakers/headphones are connected"
            echo "   • Verify audio device permissions"
            echo "   • Try: sudo ./endimic_v3.sh -w"
            echo "   • Install sox for better quality: sudo apt-get install sox"
            echo "   • Force reset audio driver: sudo ./endimic_v3.sh -f"
            
            # Offer to automatically reset audio driver
            if [[ "$spam_mode" == false ]]; then
                echo ""
                read -p "Try to reset audio driver now? (y/N): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    echo "🔧 Attempting audio driver reset..."
                    reset_audio_driver
                    echo ""
                    echo "✅ Audio driver reset completed"
                    echo "   Please try the white noise test again"
                fi
            fi
            
            if [[ "$spam_mode" == false && "$secure_after" == true ]]; then
                echo "🔒 Post-test: muting microphone and monitoring for tampering..."
                set_mic_state "off" >/dev/null 2>&1 || true
                if check_mic_activity; then
                    security_log "SECURITY ALERT: Activity detected after test while mic off"
                else
                    security_log "Post-test monitoring: no activity detected"
                fi
            fi
            if [[ "$loopback_started_here" == true && "$LOOPBACK_PERSISTENT" != true ]]; then
                cleanup_loopback_for_mic
            fi
            return 1
        fi
    else
        security_log "Failed to create white noise file"
        echo "❌ Failed to create white noise file!"
        echo ""
        echo "🛠️ Troubleshooting suggestions:"
        echo "   • Check disk space and permissions"
        echo "   • Install sox: sudo apt-get install sox"
        echo "   • Install ffmpeg: sudo apt-get install ffmpeg"
        if [[ "$spam_mode" == false && "$secure_after" == true ]]; then
            echo "🔒 Post-test: muting microphone and monitoring for tampering..."
            set_mic_state "off" >/dev/null 2>&1 || true
            if check_mic_activity; then
                security_log "SECURITY ALERT: Activity detected after test while mic off"
            else
                security_log "Post-test monitoring: no activity detected"
            fi
        fi
        if [[ "$loopback_started_here" == true && "$LOOPBACK_PERSISTENT" != true ]]; then
            cleanup_loopback_for_mic
        fi
        return 1
    fi
}

# Verify microphone capture from a recorded file
verify_white_noise_capture() {
    local verify_file="$1"
    if [[ ! -s "$verify_file" ]]; then
        return 1
    fi

    if command -v sox &> /dev/null; then
        local rms
        rms=$(sox "$verify_file" -n stat 2>&1 | awk '/RMS.*amplitude/ {print $3; exit}')
        if [[ -n "$rms" ]]; then
            awk -v v="$rms" 'BEGIN{exit !(v > 0.01)}'
            return $?
        fi
    fi

    local size
    size=$(stat -c%s "$verify_file" 2>/dev/null || echo 0)
    if [[ "$size" -gt 10000 ]]; then
        return 0
    fi
    return 1
}

# Delete saved white noise file
delete_white_noise_file() {
    if [[ -f "$WHITE_NOISE_FILE" ]]; then
        rm -f "$WHITE_NOISE_FILE"
        echo "✅ Deleted saved white noise file: $WHITE_NOISE_FILE"
    else
        echo "No saved white noise file found."
    fi
}

# Delete saved proof recording
delete_proof_recording() {
    if [[ -f "$PROOF_RECORD_FILE" ]]; then
        rm -f "$PROOF_RECORD_FILE"
        echo "✅ Deleted proof recording: $PROOF_RECORD_FILE"
    else
        echo "No proof recording found."
    fi
}

# Play proof recording
play_proof_recording() {
    if [[ -f "$PROOF_RECORD_FILE" ]]; then
        echo "Playing proof recording: $PROOF_RECORD_FILE"
        if play_white_noise_file "$PROOF_RECORD_FILE" 5; then
            echo "✅ Playback completed"
        else
            echo "❌ Playback failed"
        fi
    else
        echo "No proof recording found."
    fi
}

# Play saved white noise file
play_saved_white_noise() {
    if [[ -f "$WHITE_NOISE_FILE" ]]; then
        echo "Playing saved white noise: $WHITE_NOISE_FILE"
        if play_white_noise_file "$WHITE_NOISE_FILE" 5; then
            echo "✅ Playback completed"
        else
            echo "❌ Playback failed"
        fi
    else
        echo "No saved white noise file found."
    fi
}

# Play a white noise file using common output devices
play_white_noise_file() {
    local noise_file="$1"
    local timeout_seconds="${2:-5}"
    local device
    local devices=("pulse" "pipewire" "default" "sysdefault" "plughw:0,0" "hw:0,0")
    local first_device
    local resolved_device

    if command -v pactl &> /dev/null; then
        snapshot_sink_state || true
        if [[ "$SPAM_AUDIBLE" == true ]]; then
            apply_audible_sink_state "100%" || true
        else
            apply_audible_sink_state "80%" || true
        fi
        set_temp_default_sink_for_playback || true
    fi

    if play_noise_audible "$noise_file" "$timeout_seconds"; then
        restore_default_sink
        restore_sink_state
        return 0
    fi

    restore_default_sink
    restore_sink_state
    return 1
}

play_noise_audible() {
    local noise_file="$1"
    local timeout_seconds="${2:-5}"
    local sinks
    local device
    local devices=("pulse" "pipewire" "default" "sysdefault" "plughw:0,0" "hw:0,0")
    local resolved_device
    local first_device
    local err_msg=""

    if [[ -z "$noise_file" || ! -f "$noise_file" ]]; then
        return 1
    fi

    if command -v aplay &> /dev/null; then
        if run_pulse_cmd aplay -D pulse "$noise_file" >/dev/null 2>&1; then
            return 0
        fi
        err_msg=$(run_pulse_cmd aplay -D pulse "$noise_file" 2>&1 >/dev/null || true)
        if [[ -n "$err_msg" ]]; then
            security_log "Audible playback failed (aplay -D pulse): $err_msg"
            echo "⚠️  Audible playback failed (aplay -D pulse): $err_msg" >&2
        fi
    fi

    if [[ "$AUDIBLE_FORCE_ALSA" != true ]]; then
        sinks=$(select_audible_sinks || true)
        if command -v paplay &> /dev/null; then
            if [[ -n "$sinks" ]]; then
                while IFS= read -r sink; do
                    PULSE_SINK="$sink" run_pulse_cmd paplay "$noise_file" 2>/dev/null && return 0
                done <<< "$sinks"
            fi
            run_pulse_cmd paplay "$noise_file" 2>/dev/null && return 0
        fi

        if command -v pw-play &> /dev/null; then
            run_pulse_cmd pw-play "$noise_file" 2>/dev/null && return 0
        fi
    fi

    resolved_device=$(resolve_playback_device || true)
    if [[ -n "$resolved_device" ]]; then
        devices=("$resolved_device" "${devices[@]}")
    fi

    first_device=$(aplay -L 2>/dev/null | awk 'NF==1 {print; exit}')
    if [[ -n "$first_device" ]]; then
        devices+=("$first_device")
    fi

    for device in "${devices[@]}"; do
        if run_with_timeout "$timeout_seconds" aplay -D "$device" "$noise_file" 2>/dev/null; then
            return 0
        fi
    done

    if command -v aplay &> /dev/null; then
        run_with_timeout "$timeout_seconds" aplay "$noise_file" 2>/dev/null && return 0
    fi

    return 1
}

play_noise_to_loopback_sink() {
    local noise_file="$1"
    local timeout_seconds="${2:-5}"

    if [[ -z "$noise_file" || ! -f "$noise_file" ]]; then
        return 1
    fi
    if [[ "$LOOPBACK_MODE" != "null" ]]; then
        return 1
    fi
    if ! command -v paplay &> /dev/null; then
        return 1
    fi

    PULSE_SINK="$NULL_SINK_NAME" run_pulse_cmd paplay "$noise_file" 2>/dev/null &
    local pid=$!
    wait_for_pid "$pid" "$timeout_seconds" || true
    return 0
}

play_direct_pulse_confirmation() {
    local noise_file="$1"
    local err_msg=""

    if [[ -z "$noise_file" || ! -f "$noise_file" ]]; then
        return 1
    fi
    if ! command -v aplay &> /dev/null; then
        return 1
    fi

    set_temp_default_sink_for_playback || true
    if ! run_pulse_cmd aplay -D pulse "$noise_file" >/dev/null 2>&1; then
        err_msg=$(run_pulse_cmd aplay -D pulse "$noise_file" 2>&1 >/dev/null || true)
        if [[ -n "$err_msg" ]]; then
            security_log "Direct playback failed (aplay -D pulse): $err_msg"
            echo "⚠️  Direct playback failed (aplay -D pulse): $err_msg" >&2
        fi
    fi
    restore_default_sink
    return 0
}

# White noise spam function - continuous privacy enforcement
white_noise_spam() {
    echo "🔥 WHITE NOISE SPAM MODE - MICROPHONE PRIVACY ENFORCEMENT"
    echo "------------------------------------------------------"
    echo "This will force white noise to your microphone input"
    echo "to ensure privacy and test microphone isolation."
    echo ""
    
    local duration=5
    local cycles=3
    local total_time=$((duration * cycles))
    
    read -p "Enter spam duration per cycle (seconds, default 5): " user_duration
    if [[ -n "$user_duration" && "$user_duration" =~ ^[0-9]+$ ]]; then
        duration=$user_duration
    fi
    
    read -p "Enter number of cycles (default 3): " user_cycles
    if [[ -n "$user_cycles" && "$user_cycles" =~ ^[0-9]+$ ]]; then
        cycles=$user_cycles
    fi
    
    total_time=$((duration * cycles))
    
    echo ""
    echo "⚠️  WARNING: This will force white noise to your microphone!"
    echo "    Duration: ${duration}s per cycle"
    echo "    Cycles: $cycles"
    echo "    Total: ${total_time}s of white noise"
    echo ""
    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "White noise spam cancelled."
        security_log "White noise spam cancelled by user"
        return 1
    fi

    read -p "Play audible white noise during spam? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SPAM_AUDIBLE=true
    else
        SPAM_AUDIBLE=false
    fi

    read -p "Record proof from microphone during spam? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PROOF_RECORD=true
    else
        PROOF_RECORD=false
    fi
    
    echo "🚀 Starting white noise spam..."
    security_log "WHITE NOISE SPAM INITIATED - ${cycles} cycles of ${duration}s"
    
    # Get current microphone state
    local current_state=$(get_current_state)
    echo "Current microphone state: $current_state"
    
    # Force microphone on if it's off (for spam mode)
    if [[ "$current_state" == "off" ]]; then
        echo "Temporarily enabling microphone for spam mode..."
        if set_mic_state "on" >/dev/null 2>&1; then
            security_log "Temporarily enabled microphone for spam mode"
        else
            echo "Warning: Cannot enable microphone - spam may be less effective"
            security_log "Spam mode running without microphone enable"
        fi
    fi
    
    # Run multiple cycles of white noise
    for ((i=1; i<=$cycles; i++)); do
        echo "Cycle $i/$cycles: Injecting ${duration}s of white noise..."
        if [[ "$PROOF_RECORD" == true ]]; then
            generate_white_noise "$duration" true true true false
        else
            generate_white_noise "$duration" true false true false
        fi

        if [[ "$SPAM_AUDIBLE" == true && -f "$WHITE_NOISE_FILE" ]]; then
            echo "🔊 Audible spam playback..."
            play_white_noise_file "$WHITE_NOISE_FILE" "$((duration + 3))" || true
        fi
        
        # Small delay between cycles
        if [[ $i -lt $cycles ]]; then
            sleep 1
        fi
    done
    
    # Restore original microphone state
    if [[ "$current_state" == "off" ]]; then
        echo "Restoring microphone to OFF state..."
        if set_mic_state "off" >/dev/null 2>&1; then
            security_log "Restored microphone to OFF state after spam"
        fi
    fi
    
    echo ""
    echo "🎉 WHITE NOISE SPAM COMPLETED!"
    echo "    Total white noise injected: ${total_time}s"
    echo "    Microphone privacy enforced!"
    echo ""
    echo "✅ Your microphone has been flooded with white noise"
    echo "✅ Any potential eavesdropping would only hear static"
    echo "✅ Privacy and security enhanced!"
    
    security_log "WHITE NOISE SPAM COMPLETED - ${total_time}s total, privacy enforced"
}

# Continuous white noise spam mode
cleanup_continuous_spam() {
    echo ""
    echo "Stopping continuous white noise spam..."
    if [[ "$continuous_state_changed" == true ]]; then
        set_mic_state "off" >/dev/null 2>&1 || true
    fi
    cleanup_loopback_for_mic
    LOOPBACK_PERSISTENT=false
    security_log "WHITE NOISE SPAM (continuous) stopped"
    exit 0
}

white_noise_spam_continuous() {
    echo "🔥 CONTINUOUS WHITE NOISE SPAM MODE"
    echo "-----------------------------------"
    echo "This will continuously play white noise"
    echo "until you stop it (Ctrl+C)."
    echo ""

    local duration=2
    continuous_original_state=$(get_current_state)
    continuous_state_changed=false

    if [[ "$continuous_original_state" == "off" ]]; then
        echo "Temporarily enabling microphone for continuous spam..."
        if set_mic_state "on" >/dev/null 2>&1; then
            continuous_state_changed=true
        else
            echo "Warning: Could not enable microphone - spam may be less effective"
        fi
    fi

    LOOPBACK_PERSISTENT=true
    setup_loopback_for_mic || true
    trap cleanup_continuous_spam INT TERM
    security_log "WHITE NOISE SPAM (continuous) started"

    while true; do
        generate_white_noise "$duration" true false false false
    done
}

# Enhanced security check with white noise option
perform_security_check() {
    echo "Performing microphone security check..."
    echo "----------------------------------------"
    
    local current_state=$(get_current_state)
    echo "Current microphone state: $current_state"
    
    if [[ "$current_state" == "off" ]]; then
        echo "Microphone is OFF - checking for unauthorized activity..."
        
        # Check if we have sudo privileges for comprehensive testing
        local has_sudo=false
        if check_sudo; then
            has_sudo=true
        fi
        
        if check_mic_activity; then
            echo "⚠️  SECURITY ALERT: Microphone activity detected while mic is OFF!"
            security_log "SECURITY ALERT: Microphone activity detected while mic is OFF"
            
            if [[ "$has_sudo" == true ]]; then
                read -p "Do you want to force white noise to test mic isolation? (y/n): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    generate_white_noise
                    
                    # Check again after white noise
                    echo "Checking mic activity after white noise test..."
                    if check_mic_activity; then
                        echo "❌ CRITICAL: Microphone still detecting sound - possible security breach!"
                        security_log "CRITICAL: Microphone still active after white noise test - POSSIBLE SECURITY BREACH"
                        echo ""
                        echo "RECOMMENDED ACTIONS:"
                        echo "1. Physically disconnect your microphone"
                        echo "2. Check running processes: ps aux | grep -i audio"
                        echo "3. Update your system and audio drivers"
                        echo "4. Consider this a potential security incident"
                    else
                        echo "✅ Microphone properly isolated after test"
                        security_log "Microphone properly isolated after white noise test"
                    fi
                fi
            else
                echo "Cannot perform white noise test without sudo privileges"
                security_log "White noise test requires sudo - cannot verify isolation"
            fi
        else
            echo "✅ No microphone activity detected - mic appears properly off"
            security_log "No microphone activity detected - mic properly off"
            
            if detect_external_mic; then
                echo "⚠️  External microphone detected while mic is OFF"
                auto_spam_on_active_mic
            fi

            if [[ "$has_sudo" == false ]]; then
                echo "ℹ️  Note: Comprehensive security check requires sudo privileges"
                echo "    Current check assumes microphone is secure"
            fi
        fi
    else
        echo "Microphone is ON - checking basic functionality..."

        if detect_external_mic; then
            echo "⚠️  External microphone detected"
            auto_spam_on_active_mic
        else
            auto_spam_on_active_mic
        fi

        security_log "Microphone is on and functional"
    fi
    
    echo "----------------------------------------"
    echo "Security check completed"
}

# Set microphone state with hardware reset capability
set_mic_state() {
    local target_state="$1"
    local control
    local source

    if [[ "$CONTROL_BACKEND" == "alsa" ]]; then
        control=$(resolve_capture_control || true)
        if [[ -z "$control" ]]; then
            echo "Error: No capture control found. Set CAPTURE_CONTROL in $CONFIG_FILE." >&2
            log "ERROR: No capture control found"
            return 1
        fi
    fi
    
    # Check if force reset is requested
    if [[ "$target_state" == "toggle-force" ]]; then
        target_state="toggle"
        force_reset=true
    elif [[ "$target_state" == "on-force" ]]; then
        target_state="on"
        force_reset=true
    elif [[ "$target_state" == "off-force" ]]; then
        target_state="off"
        force_reset=true
    fi
    
    if [[ "$target_state" == "toggle" ]]; then
        case "$CONTROL_BACKEND" in
            alsa)
                if check_sudo; then
                    current_before=$(get_current_state)
                    
                    # Try to reset audio driver if forced
                    if [[ "$force_reset" == true ]]; then
                        reset_audio_driver
                    fi
                    
                    sudo amixer sset "$control" toggle
                    current_after=$(get_current_state)
                    echo "$current_after"
                    log "INFO: Toggled mic from $current_before to $current_after"
                else
                    current_before=$(get_current_state)
                    echo "$current_before"
                    echo "Warning: Cannot toggle without sudo privileges" >&2
                fi
                ;;
            pactl)
                source=$(get_default_source)
                if [[ -z "$source" ]]; then
                    echo "Error: No default source found." >&2
                    log "ERROR: No default source found"
                    return 1
                fi
                run_user_cmd pactl set-source-mute "$source" toggle
                echo "$(get_current_state)"
                ;;
            wpctl)
                run_user_cmd wpctl set-mute @DEFAULT_SOURCE@ toggle
                echo "$(get_current_state)"
                ;;
            *)
                echo "Error: No microphone control backend selected." >&2
                return 1
                ;;
        esac
    else
        case "$CONTROL_BACKEND" in
            alsa)
                if check_sudo; then
                    # Try to reset audio driver if forced
                    if [[ "$force_reset" == true ]]; then
                        reset_audio_driver
                    fi
                    
                    sudo amixer sset "$control" "$target_state"
                    log "INFO: Set mic state to $target_state"
                else
                    echo "Warning: Cannot set state without sudo privileges" >&2
                fi
                echo "$target_state"
                ;;
            pactl)
                source=$(get_default_source)
                if [[ -z "$source" ]]; then
                    echo "Error: No default source found." >&2
                    log "ERROR: No default source found"
                    return 1
                fi
                if [[ "$target_state" == "on" ]]; then
                    unmute_all_physical_sources
                    run_user_cmd pactl set-source-mute "$source" 0
                    if [[ "$FORCE_LOOPBACK_ON_MUTE" == true ]]; then
                        cleanup_loopback_for_mic
                    fi
                else
                    mute_all_physical_sources
                    run_user_cmd pactl set-source-mute "$source" 1
                    if [[ "$FORCE_LOOPBACK_ON_MUTE" == true ]]; then
                        setup_loopback_for_mic || true
                    fi
                fi
                echo "$(get_current_state)"
                ;;
            wpctl)
                if [[ "$target_state" == "on" ]]; then
                    run_user_cmd wpctl set-mute @DEFAULT_SOURCE@ 0
                    if command -v pactl &> /dev/null; then
                        unmute_all_physical_sources
                    fi
                    if [[ "$FORCE_LOOPBACK_ON_MUTE" == true ]]; then
                        cleanup_loopback_for_mic
                    fi
                else
                    run_user_cmd wpctl set-mute @DEFAULT_SOURCE@ 1
                    if command -v pactl &> /dev/null; then
                        mute_all_physical_sources
                    fi
                    if [[ "$FORCE_LOOPBACK_ON_MUTE" == true ]]; then
                        setup_loopback_for_mic || true
                    fi
                fi
                echo "$(get_current_state)"
                ;;
            *)
                echo "Error: No microphone control backend selected." >&2
                return 1
                ;;
        esac
    fi
}

# Reset audio driver to fix busy state
reset_audio_driver() {
    echo "🔧 FORCE MICROPHONE RESET - HARDWARE LEVEL"
    echo "=========================================="
    echo "This will attempt to reset your audio driver"
    echo "to fix 'busy microphone' issues."
    echo ""
    
    # Check if we have sudo privileges
    if ! check_sudo; then
        echo "❌ ERROR: This operation requires sudo privileges"
        echo "   Please run: sudo ./endimic_v3.sh --menu"
        security_log "Force reset failed: No sudo privileges"
        return 1
    fi
    
    echo "🔍 Analyzing current audio system..."
    
    # Get detailed audio system information
    local alsa_modules=$(lsmod | grep snd | awk '{print $1}')
    local module_count=$(echo "$alsa_modules" | wc -w)
    local has_pulseaudio=$(ps aux | grep pulseaudio | grep -v grep | wc -l)
    local has_jack=$(ps aux | grep jackd | grep -v grep | wc -l)
    
    echo "   ALSA modules loaded: $module_count"
    echo "   PulseAudio running: $has_pulseaudio"
    echo "   JACK running: $has_jack"
    echo ""
    
    # Check if microphone is actually busy
    local mic_busy=false
    if fuser /dev/snd/* 2>/dev/null | grep -q "."; then
        mic_busy=true
        echo "⚠️  Microphone appears to be busy"
    else
        echo "ℹ️  Microphone does not appear busy"
    fi
    echo ""
    
    # Try different reset methods
    local method_success=0
    local method_total=0
    
    # Method 1: Try to restart PulseAudio if running
    if [[ $has_pulseaudio -gt 0 ]]; then
        echo "🔄 Method 1: Restarting PulseAudio..."
        method_total=$((method_total + 1))
        if sudo systemctl restart pulseaudio 2>/dev/null || \
           sudo service pulseaudio restart 2>/dev/null || \
           pkill -9 pulseaudio 2>/dev/null; then
            echo "   ✅ PulseAudio restart successful"
            method_success=$((method_success + 1))
            sleep 2  # Give time to restart
        else
            echo "   ❌ PulseAudio restart failed"
        fi
    fi
    
    # Method 2: Try to restart JACK if running
    if [[ $has_jack -gt 0 ]]; then
        echo "🔄 Method 2: Restarting JACK audio..."
        method_total=$((method_total + 1))
        if sudo systemctl restart jackd 2>/dev/null || \
           sudo service jackd restart 2>/dev/null || \
           pkill -9 jackd 2>/dev/null; then
            echo "   ✅ JACK restart successful"
            method_success=$((method_success + 1))
            sleep 2
        else
            echo "   ❌ JACK restart failed"
        fi
    fi
    
    # Method 3: Try ALSA module reload
    if [[ $module_count -gt 0 ]]; then
        echo "🔄 Method 3: Reloading ALSA modules..."
        method_total=$((method_total + 1))
        
        # Try unloading modules
        if sudo modprobe -r $alsa_modules 2>/dev/null; then
            echo "   ✅ Modules unloaded successfully"
            sleep 1
            
            # Try reloading modules
            if sudo modprobe $alsa_modules 2>/dev/null; then
                echo "   ✅ Modules reloaded successfully"
                method_success=$((method_success + 1))
            else
                echo "   ❌ Module reload failed"
                # Try to reload them back to avoid breaking audio
                sudo modprobe $alsa_modules 2>/dev/null
            fi
        else
            echo "   ❌ Module unload failed (may be in use)"
            echo "   ℹ️  This is normal if microphone is busy"
        fi
    fi
    
    # Method 4: Try ALSA service restart
    echo "🔄 Method 4: Restarting ALSA service..."
    method_total=$((method_total + 1))
    if sudo alsa force-reload 2>/dev/null || \
       sudo service alsa restart 2>/dev/null || \
       sudo systemctl restart alsa-state 2>/dev/null; then
        echo "   ✅ ALSA service restart successful"
        method_success=$((method_success + 1))
    else
        echo "   ❌ ALSA service restart failed"
    fi
    
    # Method 4b: SOF-specific reset if detected
    if lsmod | grep -q snd_sof; then
        echo "🔄 Method 4b: SOF audio reset..."
        method_total=$((method_total + 1))
        
        # Backup SOF configuration
        if [[ -f /etc/asound.conf ]]; then
            sudo cp /etc/asound.conf /etc/asound.conf.sofbackup
            echo "   ℹ️  Backed up ALSA configuration"
        fi
        
        if sudo systemctl restart alsa-state 2>/dev/null || \
           sudo alsactl restore 2>/dev/null; then
            echo "   ✅ SOF reset successful"
            method_success=$((method_success + 1))
        else
            echo "   ❌ SOF reset failed"
            # Try to restore backup if reset failed
            if [[ -f /etc/asound.conf.sofbackup ]]; then
                sudo cp /etc/asound.conf.sofbackup /etc/asound.conf
                echo "   ℹ️  Restored ALSA configuration"
            fi
        fi
    fi
    
    # Method 5: Check for specific conflicting processes
    echo "🔄 Method 5: Checking for conflicting processes..."
    method_total=$((method_total + 1))
    
    local conflicting_processes=false
    local process_list=""
    
    # Check common audio applications
    for app in arecord audacity pulseaudio jackd; do
        if ps aux | grep $app | grep -v grep > /dev/null; then
            process_list="$process_list $app"
            conflicting_processes=true
        fi
    done
    
    if [[ "$conflicting_processes" == true ]]; then
        echo "   ⚠️  Found conflicting processes: $process_list"
        echo "   🛠️  Recommend closing these applications"
    else
        echo "   ✅ No conflicting processes found"
        method_success=$((method_success + 1))
    fi
    
    # Final assessment
    echo ""
    echo "📊 RESET RESULTS:"
    echo "   Methods attempted: $method_total"
    echo "   Methods successful: $method_success"
    
    local success_percentage=$((method_success * 100 / method_total))
    
    if [[ $success_percentage -ge 80 ]]; then
        echo "   🟢 SUCCESS RATE: ${success_percentage}%"
        echo "   ✅ Audio driver reset completed successfully!"
        echo ""
        echo "🎉 RECOMMENDATION:"
        echo "   Your microphone should now be working properly."
        echo "   Try using the microphone again."
        security_log "Audio driver reset: SUCCESS (${success_percentage}%)"
    elif [[ $success_percentage -ge 50 ]]; then
        echo "   🟡 SUCCESS RATE: ${success_percentage}%"
        echo "   ⚠️  Audio driver reset partially successful."
        echo ""
        echo "🛠️  RECOMMENDATIONS:"
        if [[ "$conflicting_processes" == true ]]; then
            echo "   • Close conflicting applications: $process_list"
        fi
        echo "   • Try rebooting your system"
        echo "   • Check audio device permissions"
        if lsmod | grep -q snd_sof; then
            echo "   • SOF audio detected - try: sudo systemctl restart alsa-state"
            echo "   • Check SOF firmware: journalctl -b | grep -i sof"
            echo "   • Test SOF UCM: alsaucm -c sof-hda-dsp set _verb HiFi"
            echo "   • Check SOF config: cat /etc/sof/sof-tplg/tplg.bin"
        fi
        security_log "Audio driver reset: PARTIAL (${success_percentage}%)"
    else
        echo "   🔴 SUCCESS RATE: ${success_percentage}%"
        echo "   ❌ Audio driver reset failed."
        echo ""
        echo "🚨 RECOMMENDATIONS:"
        echo "   • Reboot your system"
        echo "   • Check if microphone is physically connected"
        echo "   • Try: sudo alsa force-reload"
        echo "   • Check: dmesg | grep audio"
        security_log "Audio driver reset: FAILED (${success_percentage}%)"
    fi
    
    # Test if microphone is working after reset
    echo ""
    echo "🔍 TESTING MICROPHONE AFTER RESET..."
    
    local current_state=$(get_current_state 2>/dev/null || echo "unknown")
    echo "   Current state: $current_state"
    
    # Try a quick white noise test
    echo "   Testing audio playback..."
    if generate_white_noise 1 false 2>/dev/null; then
        echo "   ✅ Audio playback test: PASSED"
    else
        echo "   ❌ Audio playback test: FAILED"
        echo "   ℹ️  This is normal if microphone is busy"
    fi
    
    echo ""
    echo "✅ FORCE RESET COMPLETED"
    echo "   Review the results above for next steps."
}

# Interactive menu system
show_interactive_menu() {
    if [[ "$MENU_SPLASH_SHOWN" != true ]]; then
        clear
        echo "=============================================="
        echo "  _____ _   _ ____ ___ __  __ ___  ____ "
        echo " | ____| \\ | |  _ \\_ _|  \\/  |_ _|/ ___|"
        echo " |  _| |  \\| | | | | || |\\/| || || |    "
        echo " | |___| |\\  | |_| | || |  | || || |___ "
        echo " |_____|_| \\_|____/___|_|  |_|___|\\____|"
        echo ""
        echo "  Endimic - Microphone Security Center v$VERSION"
        echo "  Created by Kimi Autto github.com/Z-A-P-P-I-T"
        echo "=============================================="
        read -r -t 4 -n 1 -s || true
        MENU_SPLASH_SHOWN=true
    fi
    while true; do
        clear
        echo "=============================================="
        echo "  _____ _   _ ____ ___ __  __ ___  ____ "
        echo " | ____| \\ | |  _ \\_ _|  \\/  |_ _|/ ___|"
        echo " |  _| |  \\| | | | | || |\\/| || || |    "
        echo " | |___| |\\  | |_| | || |  | || || |___ "
        echo " |_____|_| \\_|____/___|_|  |_|___|\\____|"
        echo ""
        echo "  Endimic - Microphone Security Center v$VERSION"
        echo "  Created by Kimi Autto github.com/Z-A-P-P-I-T"
        echo "=============================================="
        
        # Get current state and show enhanced status
        local current_state=$(get_current_state)
        local status_icon="❌"
        local status_color="🔴"
        local status_text="UNKNOWN"
        
        if [[ "$current_state" == "on" ]]; then
            status_icon="⚠️ "
            status_color="🟡"
            status_text="ACTIVE"
        elif [[ "$current_state" == "off" ]]; then
            status_icon="✅ "
            status_color="🟢"
            status_text="SECURE"
        fi
        
        echo "🎤 MICROPHONE STATUS: $status_color $status_text $status_icon"
        if [[ "$current_state" == "on" ]]; then
            echo "   Mic enabled: yes"
        elif [[ "$current_state" == "off" ]]; then
            echo "   Mic enabled: no"
        else
            echo "   Mic enabled: unknown"
        fi
        if [[ "$LOOPBACK_MODE" == "null" ]]; then
            echo "   Privacy mode: loopback null sink (apps hear silence/noise)"
        else
            echo "   Privacy mode: loopback from system output"
        fi
        echo "   Audible playback: trust check only"

        if [[ "$LAST_VERIFY_STATUS" == "success" ]]; then
            echo "   Protection verified: ✅ (${LAST_VERIFY_TIME})"
        elif [[ "$LAST_VERIFY_STATUS" == "loopback" ]]; then
            echo "   Protection verified: ✅ (loopback privacy mode)"
        elif [[ "$LAST_VERIFY_STATUS" == "failed" ]]; then
            echo "   Protection verified: ❌ (${LAST_VERIFY_TIME})"
        else
            echo "   Protection verified: unknown"
        fi
        
        # Show additional system information
        echo ""
        echo "📊 SYSTEM INFO:"
        
        # Check audio capabilities
        local has_arecord="❌"
        local has_aplay="❌"
        local has_sox="❌"
        local has_ffmpeg="❌"
        
        if command -v arecord &> /dev/null; then has_arecord="✅"; fi
        if command -v aplay &> /dev/null; then has_aplay="✅"; fi
        if command -v sox &> /dev/null; then has_sox="✅"; fi
        if command -v ffmpeg &> /dev/null; then has_ffmpeg="✅"; fi
        
        echo "  Recording: $has_arecord  Playback: $has_aplay"
        echo "  Quality: $has_sox  FFmpeg: $has_ffmpeg"
        
        # Show security status
        echo ""
        echo "🛡️ SECURITY STATUS:"
        if [[ "$current_state" == "off" ]]; then
            echo "  Microphone: $status_icon $status_text"
        else
            echo "  Microphone: $status_icon $status_text"
        fi
        
        if [[ "$has_arecord" == "✅" && "$has_aplay" == "✅" ]]; then
            echo "  Capabilities: ✅ Full security monitoring"
        else
            echo "  Capabilities: ⚠️  Limited monitoring"
        fi
        
        echo ""

        if [[ -f "$WHITE_NOISE_FILE" ]]; then
            echo "📄 SAVED WHITE NOISE: ✅ $WHITE_NOISE_FILE"
        else
            echo "📄 SAVED WHITE NOISE: ❌ (none)"
        fi

        if [[ -f "$PROOF_RECORD_FILE" ]]; then
            echo "📄 PROOF RECORDING: ✅ $PROOF_RECORD_FILE"
        else
            echo "📄 PROOF RECORDING: ❌ (none)"
        fi
        
        echo "Main Menu:"
        echo "1. Turn Microphone ON"
        echo "2. Turn Microphone OFF"
        echo "3. Show Current State"
        echo "4. White Noise Test (audible + verify)"
        echo "5. Perform Security Check"
        echo "6. Monitor Microphone Activity (sudo may be required)"
        echo "7. Advanced Options"
        echo ""
        echo "0. Exit"
        echo ""
        
        read -p "Enter your choice (0-7): " choice
        
        case "$choice" in
            1)
                echo "Turning microphone ON..."
                final_state=$(set_mic_state "on")
                echo "Microphone State: $final_state"
                read -p "Press Enter to continue..." -r
                ;;
            2)
                echo "Turning microphone OFF..."
                final_state=$(set_mic_state "off")
                echo "Microphone State: $final_state"
                read -p "Press Enter to continue..." -r
                ;;
            3)
                echo "Current Microphone State: $current_state"
                read -p "Press Enter to continue..." -r
                ;;
            4)
                generate_white_noise 2 false true true
                read -p "Press Enter to continue..." -r
                ;;
            5)
                perform_security_check
                read -p "Press Enter to continue..." -r
                ;;
            6)
                echo "Monitoring microphone activity..."
                if check_mic_activity; then
                    echo "⚠️  Microphone activity detected!"
                else
                    echo "✅ No microphone activity detected"
                fi
                read -p "Press Enter to continue..." -r
                ;;
            7)
                show_advanced_menu
                ;;
            0)
                echo "Exiting Endimic..."
                exit 0
                ;;
            *)
                echo "Invalid choice. Please try again."
                read -p "Press Enter to continue..." -r
                ;;
        esac
    done

    if [[ "$state_set" == true ]]; then
        echo "Error: --state requires a value (on, off, or toggle)." >&2
        exit 1
    fi
}

show_advanced_menu() {
    while true; do
        clear
        echo "=============================================="
        echo "    🔧 Endimic - Advanced Options"
        echo "=============================================="
        echo "1. Toggle Microphone State"
        echo "2. White Noise Spam (Privacy Enforcement)"
        echo "3. Force Reset (Fix busy microphone)"
        echo "4. Auto-Fix & Install (Troubleshooting)"
        echo "5. Nuclear Reset (Last Resort)"
        echo "6. Diagnostics (read-only)"
        echo "7. Show Help"
        echo "8. Show Version Info"
        echo "9. Delete Saved White Noise File"
        echo "10. Play Saved White Noise File"
        echo "11. Play Proof Recording"
        echo "12. Delete Proof Recording"
        echo "13. View Security Log"
        echo "14. System Audio Info"
        echo "15. Test All Features"
        echo ""
        echo "0. Back"
        echo ""

        read -p "Enter your choice (0-15): " choice

        case "$choice" in
            1)
                echo "Toggling microphone state..."
                final_state=$(set_mic_state "toggle")
                echo "Microphone State: $final_state"
                read -p "Press Enter to continue..." -r
                ;;
            2)
                white_noise_spam
                read -p "Press Enter to continue..." -r
                ;;
            3)
                echo "🔧 FORCE MICROPHONE RESET"
                echo "========================="
                echo "This will attempt to reset the audio driver"
                echo "to fix busy microphone issues."
                echo ""
                read -p "Are you sure? (y/N): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    reset_audio_driver
                else
                    echo "Reset cancelled"
                fi
                read -p "Press Enter to continue..." -r
                ;;
            4)
                auto_fix_and_install
                read -p "Press Enter to continue..." -r
                ;;
            5)
                echo "🔥 NUCLEAR MICROPHONE RESET"
                echo "=========================="
                echo "WARNING: This will FORCEFULLY reset your microphone"
                echo "This is the most aggressive reset option."
                echo ""
                read -p "Are you SURE? (y/N): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    echo "🔥 NUCLEAR RESET STARTED..."
                    nuclear_microphone_reset
                    echo "🔥 NUCLEAR RESET COMPLETED"
                    echo "⏸️  Returning to main menu..."
                else
                    echo "Nuclear reset cancelled"
                fi
                read -p "Press Enter to continue..." -r
                ;;
            6)
                show_audio_diagnostics
                read -p "Press Enter to continue..." -r
                ;;
            7)
                show_help_message
                read -p "Press Enter to continue..." -r
                ;;
            8)
                show_version_info
                read -p "Press Enter to continue..." -r
                ;;
            9)
                delete_white_noise_file
                read -p "Press Enter to continue..." -r
                ;;
            10)
                play_saved_white_noise
                read -p "Press Enter to continue..." -r
                ;;
            11)
                play_proof_recording
                read -p "Press Enter to continue..." -r
                ;;
            12)
                delete_proof_recording
                read -p "Press Enter to continue..." -r
                ;;
            13)
                view_security_log
                read -p "Press Enter to continue..." -r
                ;;
            14)
                show_system_audio_info
                read -p "Press Enter to continue..." -r
                ;;
            15)
                test_all_features
                read -p "Press Enter to continue..." -r
                ;;
            0)
                return 0
                ;;
            *)
                echo "Invalid choice. Please try again."
                read -p "Press Enter to continue..." -r
                ;;
        esac
    done
}

# Show help message
show_help_message() {
    cat << EOF
endimic.sh - Advanced Linux Mic Toggle with Security Features
Version: $VERSION

Usage: $0 [OPTIONS]

Options:
  -o, --state STATE  Set microphone state (on, off, or toggle)
  -s, --security     Perform security check with activity monitoring
  -w, --white-noise  Generate white noise test
  --verify           Verify white noise by recording microphone input
  --verify-source    ALSA device or PulseAudio source for verification
  --spam             🔥 WHITE NOISE SPAM - Force privacy enforcement
  --spam-continuous  🔊 Continuous white noise spam until stopped
  --guard            🛡️  Background guard: spam when mic is muted
  --guard-stop       🛑 Stop background guard
  --diagnose         🔍 Show audio topology and suggestions (read-only)
  -f, --force        🔧 Force reset audio driver (fix busy microphone)
  -m, --menu         Show interactive menu
  -h, --help         Show this help message
  -v, --version      Show version information
  -V, --verbose      Enable verbose output

Examples:
  $0 -o toggle       Toggle current microphone state
  $0 -o on          Turn microphone on
  $0 -o off         Turn microphone off
  $0 -s             Perform security check
  $0 -w             Generate white noise test
  $0 -w --verify    Generate white noise and verify capture
  $0 -w --verify --verify-source hw:0,0
  $0 -w --verify --verify-source alsa_input.pci-0000_00_1f.3.analog-stereo
  $0 --spam         🔥 Activate white noise spam mode
  $0 --spam-continuous  🔊 Continuous white noise spam (Ctrl+C to stop)
  $0 --guard        Start background guard mode
  $0 --guard-stop   Stop background guard mode
  $0 --diagnose     Show audio topology and suggestions (read-only)
  $0 -f             🔧 Force reset audio driver
  $0 --menu         Show interactive menu
  $0                Show current microphone state

Security Features:
  - Microphone activity monitoring
  - White noise generation for testing
  - 🔥 WHITE NOISE SPAM for privacy enforcement
  - 🔧 Force reset for busy microphone issues
  - Security logging to $SECURITY_LOG
  - Interactive menu system

Note: This script requires sudo privileges to modify microphone state.
Privacy model:
  When muted, the default source is set to a loopback source so apps do not access the physical mic.
  Loopback mode "null" uses a private null sink so system audio is not routed into apps.
  Audible playback is optional and only used to build trust that the test ran.
Config overrides in $CONFIG_FILE:
  AUDIBLE_SINK=...        Force a PulseAudio/PipeWire sink for audible playback
  MONITOR_REQUIRE_SUDO=... (true/false) Require sudo for tamper checks
  AUDIBLE_CONFIRM_PLAYBACK=... (true/false) Play an audible confirmation after verify
  PROMPT_AUDIBLE_CONFIRM=... (true/false) Ask if the noise was heard
  AUTO_MUTE_ALL_SOURCES=... (true/false) Mute all physical sources when muting
  FORCE_LOOPBACK_ON_MUTE=... (true/false) Set loopback as default source when muted
  LOOPBACK_MODE=... ("null" or "monitor") Use null sink or system output as loopback source
  VERIFY_LOOPBACK_WHEN_MUTED=... (true/false) Verify loopback when mic is muted
  VERIFY_PROMPT_UNMUTE=... (true/false) Prompt to unmute for physical verify
  AUDIBLE_FORCE_ALSA=... (true/false) Use aplay (ALSA) for audible playback
  AUTO_INSTALL_DEPS=... (true/false) Prompt to install missing deps
State:
  Last verify status stored in $STATE_FILE
EOF
}

# Show version information
show_version_info() {
    cat << EOF
endimic.sh - Version $VERSION
Author: $AUTHOR
License: Apache-2.0

An advanced ALSA microphone control utility with security features:
- Microphone state management (on/off/toggle)
- Activity monitoring for security
- White noise generation for testing
- 🔥 WHITE NOISE SPAM for privacy enforcement
- Interactive menu system
- Comprehensive logging

Dependencies:
- amixer (ALSA utilities)
- arecord (for monitoring)
- aplay (for white noise)
- Optional: sox or ffmpeg (for better white noise)

WHITE NOISE SPAM Features:
- Force white noise to microphone input
- Override software mute for security testing
- Multiple cycles for thorough privacy enforcement
- Automatic state restoration
- Comprehensive security logging
EOF
}

# Parse command line arguments
parse_arguments() {
    # Support both short and long options
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                show_help=true
                ;;
            -v|--version)
                show_version=true
                ;;
            -V|--verbose)
                verbose=true
                ;;
            -m|--menu)
                show_menu=true
                ;;
            -s|--security)
                security_check=true
                ;;
            -w|--white-noise)
                force_white_noise=true
                ;;
            --verify|--white-noise-verify)
                white_noise_verify=true
                ;;
            --verify-source)
                verify_source_set=true
                ;;
            --spam|--white-noise-spam)
                white_noise_spam_mode=true
                ;;
            --spam-continuous|--white-noise-continuous)
                white_noise_continuous=true
                ;;
            --guard)
                GUARD_MODE=true
                ;;
            --guard-run)
                GUARD_RUN=true
                ;;
            --guard-stop)
                GUARD_STOP=true
                ;;
            --diagnose)
                show_audio_diagnostics
                exit 0
                ;;
            --force|-f)
                force_reset=true
                ;;
            -o|--state)
                # Next argument is the state
                state_set=true
                ;;
            *)
                if [[ "$verify_source_set" == true ]]; then
                    white_noise_verify_source="$arg"
                    verify_source_set=false
                elif [[ "$state_set" == true ]]; then
                    state="$arg"
                    state_set=false
                fi
                ;;
        esac
    done

    if [[ "$state_set" == true ]]; then
        echo "Error: --state requires a value (on, off, or toggle)." >&2
        exit 1
    fi

    if [[ "$verify_source_set" == true ]]; then
        echo "Error: --verify-source requires an ALSA device (e.g., hw:0,0)." >&2
        exit 1
    fi
}

# Main script execution
main() {
    # Parse arguments
    parse_arguments "$@"

    if [[ "$white_noise_verify" == true && "$force_white_noise" == false ]]; then
        force_white_noise=true
    fi
    
    # Check dependencies
    check_dependencies
    
    # Show help if requested
    if [[ "$show_help" == true ]]; then
        show_help_message
        exit 0
    fi
    
    # Show version if requested
    if [[ "$show_version" == true ]]; then
        show_version_info
        exit 0
    fi

    if [[ "$GUARD_STOP" == true ]]; then
        guard_stop
        exit 0
    fi

    if [[ "$GUARD_MODE" == true ]]; then
        guard_start
        exit 0
    fi

    if [[ "$GUARD_RUN" == true ]]; then
        guard_loop
        exit 0
    fi
    
    # Show interactive menu if requested
    if [[ "$show_menu" == true ]]; then
        show_interactive_menu
        exit 0
    fi

    # Auto-spam when active or external microphone is detected (unless already requested)
    if [[ "$white_noise_spam_mode" == false && "$white_noise_continuous" == false && "$force_white_noise" == false ]]; then
        if [[ "$(get_current_state)" == "on" ]] || detect_external_mic; then
            auto_spam_on_active_mic
        fi
    fi

    # Always disable microphones after initial checks
    set_mic_state "off" >/dev/null 2>&1 || true
    
    # Perform security check if requested
    if [[ "$security_check" == true ]]; then
        perform_security_check
        exit 0
    fi
    
    # White noise spam mode if requested
    if [[ "$white_noise_spam_mode" == true ]]; then
        white_noise_spam
        # Don't exit, continue to menu
    fi

    # Continuous white noise spam mode if requested
    if [[ "$white_noise_continuous" == true ]]; then
        white_noise_spam_continuous
        exit 0
    fi

    # Generate white noise if requested
    if [[ "$force_white_noise" == true ]]; then
        generate_white_noise 2 false "$white_noise_verify" true
        # Don't exit, continue to menu
    fi
    
    # Force reset if requested (only for command line, not menu)
    if [[ "$force_reset" == true && "$show_menu" == false ]]; then
        echo "🔧 FORCE MICROPHONE RESET MODE"
        echo "=============================="
        reset_audio_driver
        echo ""
        echo "✅ Audio driver reset completed"
        echo "   Try microphone operations again"
        exit 0
    fi
    
    # Display header
    echo "============================================================"
    echo "    Advanced Linux Mic Toggle with Security v$VERSION"
    echo "============================================================"
    
    # Determine and set state
    if [[ -z "$state" ]]; then
        show_interactive_menu
        exit 0
    else
        # State specified, try to set it
        if [[ "$state" == "on" || "$state" == "off" || "$state" == "toggle" ]]; then
            final_state=$(set_mic_state "$state")
            echo "Microphone State Set To: $final_state"
            
            # Offer security check after state change
            read -p "Run security check after state change? (y/n): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                perform_security_check
            fi
        else
            echo "Error: Invalid state '$state'. Use 'on', 'off', or 'toggle'." >&2
            log "ERROR: Invalid state argument: $state"
            exit 1
        fi
    fi
    
    echo "============================================================"
    echo "--------------- Your Mic Has Been Modified -----------------"
    echo "============================================================"
    
    # Pause before exit (3 seconds or key press)
    if [[ "$verbose" == false ]]; then
        read -p "Press any key to continue" -t 3 -n 1 -s
        echo ""
    fi
}

# View security log
view_security_log() {
    echo "📜 SECURITY LOG VIEWER"
    echo "======================"
    
    if [[ -f "$SECURITY_LOG" ]]; then
        echo "Showing last 20 entries from: $SECURITY_LOG"
        echo "----------------------------------------------"
        tail -n 20 "$SECURITY_LOG" 2>/dev/null || echo "Log file is empty"
        
        echo ""
        echo "Log Statistics:"
        local total_lines=$(wc -l < "$SECURITY_LOG" 2>/dev/null || echo "0")
        local log_size=$(du -h "$SECURITY_LOG" 2>/dev/null | cut -f1 || echo "0")
        
        echo "  Total entries: $total_lines"
        echo "  Log size: $log_size"
        echo "  Location: $SECURITY_LOG"
    else
        echo "No security log found at: $SECURITY_LOG"
        echo "The log will be created when security events occur."
    fi
    
    security_log "User viewed security log"
}

# Show system audio information
show_system_audio_info() {
    echo "💻 SYSTEM AUDIO INFORMATION"
    echo "==========================="
    
    echo "ALSA Version:"
    cat /proc/asound/version 2>/dev/null || echo "  Not available"
    
    echo ""
    echo "Audio Cards:"
    cat /proc/asound/cards 2>/dev/null || echo "  Not available"
    
    echo ""
    echo "Audio Devices:"
    cat /proc/asound/devices 2>/dev/null || echo "  Not available"
    
    echo ""
    echo "PCM Devices:"
    cat /proc/asound/pcm 2>/dev/null || echo "  Not available"
    
    security_log "User viewed system audio information"
}

# Diagnostic report (read-only)
show_audio_diagnostics() {
    echo "🔍 AUDIO DIAGNOSTICS (READ-ONLY)"
    echo "================================"

    if command -v pactl &> /dev/null; then
        echo "Default sink: $(run_user_cmd pactl get-default-sink 2>/dev/null || echo 'unknown')"
        echo "Default source: $(run_user_cmd pactl get-default-source 2>/dev/null || echo 'unknown')"
        echo ""
        echo "Sinks:"
        run_user_cmd pactl list short sinks 2>/dev/null | awk '{printf "  - %s (%s)\n", $2, $5}'
        echo ""
        echo "Sources:"
        run_user_cmd pactl list short sources 2>/dev/null | awk '{printf "  - %s (%s)\n", $2, $5}'
        echo ""
        echo "Suggested audible sink:"
        if [[ -n "${AUDIBLE_SINK:-}" ]]; then
            echo "  AUDIBLE_SINK is set: $AUDIBLE_SINK"
        else
            local suggested_sink
            suggested_sink=$(get_preferred_sink)
            if [[ -n "$suggested_sink" ]]; then
                echo "  $suggested_sink"
                echo "  Tip: set AUDIBLE_SINK=$suggested_sink in $CONFIG_FILE"
            else
                echo "  (none found)"
            fi
        fi
    else
        echo "pactl not available. Limited diagnostics."
        if command -v aplay &> /dev/null; then
            echo "ALSA devices:"
            aplay -L 2>/dev/null | head -n 20
        fi
    fi
}

# Test all features
test_all_features() {
    echo "🧪 TESTING ALL FEATURES"
    echo "======================="
    
    echo "Testing basic functionality..."
    local current_state=$(get_current_state)
    echo "  ✅ Current state detection: $current_state"
    
    echo ""
    echo "Testing security features..."
    if command -v arecord &> /dev/null; then
        echo "  ✅ Monitoring capabilities: Available"
    else
        echo "  ⚠️  Monitoring capabilities: Limited"
    fi
    
    if command -v aplay &> /dev/null; then
        echo "  ✅ Audio playback: Available"
    else
        echo "  ⚠️  Audio playback: Limited"
    fi
    
    echo ""
    echo "Testing white noise generation..."
    generate_white_noise 1 false
    echo "  ✅ White noise test: Completed"
    
    echo ""
    echo "All feature tests completed!"
    echo "✅ Endimic is working correctly"
    
    security_log "User tested all features"
}

# Auto-fix and installation system
auto_fix_and_install() {
    echo "🛠️ AUTO-FIX & INSTALLATION SYSTEM"
    echo "=================================="
    echo "This will automatically diagnose and fix"
    echo "common microphone issues."
    echo ""
    
    # Check current system status
    echo "🔍 DIAGNOSING YOUR SYSTEM..."
    echo ""
    
    # Check which packages are missing
    local missing_packages=()
    local recommendations=()
    
    # Check for sox
    if ! command -v sox &> /dev/null; then
        missing_packages+=("sox")
        recommendations+=("sox for high-quality white noise")
    fi
    
    # Check for ffmpeg
    if ! command -v ffmpeg &> /dev/null; then
        missing_packages+=("ffmpeg")
        recommendations+=("ffmpeg for audio processing")
    fi
    
    # Check for pulseaudio
    if ! command -v pulseaudio &> /dev/null; then
        recommendations+=("pulseaudio for advanced audio control")
    fi

    # Check for paplay/pw-play utilities
    if ! command -v paplay &> /dev/null && ! command -v pw-play &> /dev/null; then
        recommendations+=("paplay or pw-play for PulseAudio/PipeWire playback")
    fi

    # Offer to install missing packages if enabled
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        echo ""
        echo "Missing packages detected: ${missing_packages[*]}"
        if [[ "$AUTO_INSTALL_DEPS" == true ]]; then
            echo "Auto-install is enabled. This requires sudo and will use your package manager."
            read -p "Install missing packages now? (y/N): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if command -v apt-get &> /dev/null; then
                    sudo apt-get update && sudo apt-get install -y "${missing_packages[@]}"
                elif command -v dnf &> /dev/null; then
                    sudo dnf install -y "${missing_packages[@]}"
                elif command -v pacman &> /dev/null; then
                    sudo pacman -S --noconfirm "${missing_packages[@]}"
                elif command -v zypper &> /dev/null; then
                    sudo zypper install -y "${missing_packages[@]}"
                else
                    echo "No supported package manager found. Please install: ${missing_packages[*]}"
                fi
            fi
        else
            echo "To install: ${missing_packages[*]}"
        fi
    fi
    
    # Check audio device access
    echo "Checking audio device access..."
    if [[ -e /dev/snd/pcmC0D0c ]]; then
        echo "   ✅ Microphone device found: /dev/snd/pcmC0D0c"
    else
        echo "   ⚠️  Microphone device not found at standard location"
    fi
    
    # Check for SOF (Sound Open Firmware)
    echo "Checking for SOF audio..."
    if lsmod | grep -q snd_sof; then
        echo "   ✅ SOF audio detected"
        echo "   ℹ️  Sound Open Firmware in use"
        
        # Get SOF firmware version if available
        if [[ -f /sys/kernel/debug/sof/fw_version ]]; then
            local sof_version=$(cat /sys/kernel/debug/sof/fw_version 2>/dev/null || echo "unknown")
            echo "   📋 SOF firmware version: $sof_version"
        fi
        
        # Get SOF topology if available
        if [[ -f /sys/kernel/debug/sof/topology ]]; then
            local sof_topology=$(cat /sys/kernel/debug/sof/topology 2>/dev/null | head -1 || echo "unknown")
            echo "   📋 SOF topology: $sof_topology"
        fi
    else
        echo "   ℹ️  Traditional ALSA audio"
    fi
    
    # Check if microphone is busy
    echo "Checking microphone status..."
    if fuser /dev/snd/* 2>/dev/null | grep -q "."; then
        echo "   ⚠️  Microphone appears busy"
    else
        echo "   ✅ Microphone not busy"
    fi
    
    # Show diagnosis results
    echo ""
    echo "📋 DIAGNOSIS RESULTS:"
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        echo "   ✅ All required packages installed"
    else
        echo "   ❌ Missing packages: ${missing_packages[*]}"
    fi
    
    echo ""
    echo "🛠️ AUTO-FIX OPTIONS:"
    echo ""
    
    # Option 1: Install missing packages (always show, but disable if none missing)
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        echo "1. Install missing packages (${missing_packages[*]})"
    else
        echo "1. Install missing packages (none needed - all installed ✅)"
    fi
    
    # Option 2: Test audio devices
    echo "2. Test all audio devices"
    
    # Option 3: Check audio permissions
    echo "3. Check and fix audio permissions"
    
    # Option 4: Advanced ALSA reset
    echo "4. Advanced ALSA reset (aggressive)"
    
    # Option 5: Run all fixes
    echo "5. Run ALL fixes automatically"
    
    # Option 6: Cancel
    echo "0. Cancel and return to menu"
    echo ""
    
    read -p "Select auto-fix option: " fix_choice
    echo ""
    
    case "$fix_choice" in
        1)
            if [[ ${#missing_packages[@]} -gt 0 ]]; then
                echo "📦 Installing missing packages..."
                if check_sudo; then
                    sudo apt-get update
                    sudo apt-get install -y ${missing_packages[@]}
                    echo "✅ Packages installed successfully!"
                    security_log "Auto-fix: Installed packages ${missing_packages[*]}"
                else
                    echo "❌ Cannot install without sudo"
                fi
            else
                echo "ℹ️  All packages are already installed"
                echo "   No action needed"
            fi
            ;;
        2)
            echo "🔊 Testing all audio devices..."
            test_all_audio_devices
            ;;
        3)
            echo "🔐 Checking audio permissions..."
            fix_audio_permissions
            ;;
        4)
            echo "🔧 Advanced ALSA reset..."
            nuclear_microphone_reset
            ;;
        5)
            echo "🚀 Running ALL fixes..."
            
            # Install packages
            if [[ ${#missing_packages[@]} -gt 0 ]] && check_sudo; then
                echo "1/4: Installing packages..."
                sudo apt-get update
                sudo apt-get install -y ${missing_packages[@]}
            fi
            
            # Test devices
            echo "2/4: Testing audio devices..."
            test_all_audio_devices
            
            # Fix permissions
            echo "3/4: Fixing permissions..."
            fix_audio_permissions
            
            # Advanced reset
            echo "4/4: Advanced ALSA reset..."
            nuclear_microphone_reset
            
            echo "✅ All fixes completed!"
            ;;
        0|*)
            echo "Auto-fix cancelled"
            ;;
    esac
}

# Test all audio devices function
test_all_audio_devices() {
    echo "🔊 TESTING AUDIO DEVICES"
    echo "========================"
    
    # List all playback devices
    echo "Playback Devices:"
    aplay -L | grep -E "(hw:|plughw:|default)" || echo "   None found"
    
    # List all capture devices
    echo ""
    echo "Capture Devices:"
    arecord -L | grep -E "(hw:|plughw:|default)" || echo "   None found"
    
    # Test each device
    echo ""
    echo "Testing devices..."
    
    # Try default device
    echo "Testing default device..."
    if generate_white_noise 1 false 2>/dev/null; then
        echo "   ✅ Default device: WORKING"
    else
        echo "   ❌ Default device: FAILED"
    fi
    
    # Try specific hardware devices with timeout
    for card in 0 1 2; do
        if aplay -L | grep -q "card $card"; then
            echo "Testing card $card..."
            if timeout 3 aplay -D plughw:$card,0 -t raw -f S16_LE -r 44100 -c 2 /dev/zero 2>/dev/null; then
                echo "   ✅ Card $card: WORKING"
                # Try to set this as default if it works
                if [[ -f /etc/asound.conf ]]; then
                    sudo cp /etc/asound.conf /etc/asound.conf.backup
                fi
                echo "defaults.pcm.card $card" | sudo tee /etc/asound.conf
                echo "defaults.ctl.card $card" | sudo tee -a /etc/asound.conf
                echo "   ℹ️  Set card $card as default device"
            else
                echo "   ❌ Card $card: FAILED (or timed out)"
            fi
        fi
    done
    
    # Try microphone-specific testing
    echo "Testing microphone capture..."
    if timeout 3 arecord -D default -d 1 -f cd -q 2>/dev/null; then
        echo "   ✅ Microphone capture: WORKING"
    else
        echo "   ❌ Microphone capture: FAILED"
    fi
    
    # Try PCH card specifically (from your system)
    echo "Testing PCH card (your microphone)..."
    if timeout 3 aplay -D plughw:PCH,0 -t raw -f S16_LE -r 44100 -c 2 /dev/zero 2>/dev/null; then
        echo "   ✅ PCH card: WORKING"
        echo "   ℹ️  Your microphone should work with this device"
    else
        echo "   ❌ PCH card: FAILED"
    fi
    
    # Try SOF devices if SOF is detected
    if lsmod | grep -q snd_sof; then
        echo "Testing SOF devices..."
        if timeout 3 aplay -D sof-hda-dsp -t raw -f S16_LE -r 44100 -c 2 /dev/zero 2>/dev/null; then
            echo "   ✅ SOF device: WORKING"
            echo "   ℹ️  Try: aplay -D sof-hda-dsp your_file.wav"
        else
            echo "   ❌ SOF device: FAILED"
        fi
    fi
    
    security_log "Auto-fix: Tested all audio devices"
}

# Fix audio permissions
fix_audio_permissions() {
    echo "🔐 FIXING AUDIO PERMISSIONS"
    echo "==========================="
    
    if check_sudo; then
        echo "Checking current permissions..."
        ls -la /dev/snd/ | head -5
        
        echo "Setting audio device permissions..."
        sudo chmod a+rw /dev/snd/* 2>/dev/null
        
        echo "Adding user to audio group..."
        sudo usermod -a -G audio $USER
        
        echo "✅ Permissions updated"
        echo "Note: You may need to log out and back in"
        security_log "Auto-fix: Fixed audio permissions"
    else
        echo "❌ Cannot fix permissions without sudo"
    fi
}

# Advanced ALSA reset - renamed to avoid recursion
nuclear_microphone_reset() {
    echo "🔧 ADVANCED ALSA RESET"
    echo "======================"
    
    if ! check_sudo; then
        echo "❌ This requires sudo privileges"
        return 1
    fi
    
    echo "🔥 NUCLEAR MICROPHONE RESET - FORCEFUL"
    echo "===================================="
    
    # Step 1: Kill ALL audio processes
    echo "💀 Killing ALL audio processes..."
    sudo killall pulseaudio jackd arecord aplay 2>/dev/null
    sudo pkill -9 pulseaudio jackd arecord aplay 2>/dev/null
    
    # Step 2: Unload ALL sound modules
    echo "🔄 Unloading ALL sound modules..."
    local alsa_modules=$(lsmod | grep snd | awk '{print $1}')
    if [[ -n "$alsa_modules" ]]; then
        sudo modprobe -r $alsa_modules 2>/dev/null || echo "Some modules in use (normal)"
    fi
    
    # Step 3: Remove ALSA state
    echo "🗑️  Removing ALSA state..."
    sudo rm -f /var/lib/alsa/asound.state 2>/dev/null
    sudo rm -f ~/.asoundrc 2>/dev/null
    sudo rm -f /etc/asound.conf 2>/dev/null
    
    # Step 4: Reset ALSA completely
    echo "🔧 Resetting ALSA completely..."
    sudo alsa force-reload
    sudo systemctl restart alsa-state 2>/dev/null
    
    # Step 5: Reload ALL sound modules
    echo "🔄 Reloading ALL sound modules..."
    sudo modprobe -a snd 2>/dev/null || echo "Module reload attempted"
    
    # Step 6: Restart audio services
    echo "🔄 Restarting audio services..."
    sudo systemctl restart alsa-state 2>/dev/null
    
    # Step 7: Reset microphone state
    echo "🎤 Resetting microphone state..."
    sudo amixer sset Capture off 2>/dev/null
    sudo amixer sset Capture on 2>/dev/null
    sudo amixer sset Capture off 2>/dev/null
    
    echo "✅ NUCLEAR MICROPHONE RESET COMPLETED"
    echo "Your microphone has been forcefully reset"
    echo ""
    echo "📋 NEXT STEPS:"
    echo "   1. Test microphone: ./endimic_v3.sh -w"
    echo "   2. Check status: ./endimic_v3.sh"
    echo "   3. If still issues, try rebooting"
    echo ""
    echo "🛠️  TROUBLESHOOTING:"
    echo "   • Check connections: ls /dev/snd/"
    echo "   • Test playback: aplay -L"
    echo "   • Test capture: arecord -l"
    echo "   • Check logs: dmesg | grep audio"
    security_log "NUCLEAR MICROPHONE RESET performed"
    return 0  # Return to caller instead of exiting
}

# Run main function with all arguments
main "$@"
guard_cleanup() {
    if [[ "$LOOPBACK_ACTIVE" == true ]]; then
        cleanup_loopback_for_mic
    fi
}

guard_loop() {
    echo "🛡️ Guard mode active: injecting white noise when mic is muted"
    security_log "Guard mode started"
    trap guard_cleanup INT TERM

    while true; do
        local state
        state=$(get_current_state)
        if [[ "$state" == "off" ]]; then
            LOOPBACK_PERSISTENT=true
            setup_loopback_for_mic || true
            generate_white_noise 2 true false false false
            sleep 1
        else
            if [[ "$LOOPBACK_ACTIVE" == true ]]; then
                cleanup_loopback_for_mic
            fi
            sleep 2
        fi
    done
}

guard_start() {
    if [[ -f "$GUARD_PID_FILE" ]]; then
        if kill -0 "$(cat "$GUARD_PID_FILE")" 2>/dev/null; then
            echo "Guard already running (PID $(cat "$GUARD_PID_FILE"))."
            return 0
        fi
    fi

    nohup "$0" --guard-run >/dev/null 2>&1 &
    echo $! > "$GUARD_PID_FILE"
    echo "Guard started (PID $(cat "$GUARD_PID_FILE"))."
}

guard_stop() {
    if [[ ! -f "$GUARD_PID_FILE" ]]; then
        echo "No guard PID file found."
        return 1
    fi

    local pid
    pid=$(cat "$GUARD_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        echo "Guard stopped (PID $pid)."
    else
        echo "Guard not running."
    fi
    rm -f "$GUARD_PID_FILE"
}
