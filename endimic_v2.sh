#!/bin/bash

# Advanced Linux Sound Architecture Mic Toggle
# Version: 2.0
# Description: Toggle or set microphone capture state using ALSA
# Usage: ./endimic.sh [-o on|off|toggle] [-h] [-v]

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
CAPTURE_CONTROL=""
CONTROL_BACKEND=""

# Initialize variables
state=""
show_help=false
show_version=false
verbose=false
state_set=false

# Load user overrides if present
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Logging function
log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" >> "$LOG_FILE"
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

get_default_source() {
    local source
    source=$(run_user_cmd pactl get-default-source 2>/dev/null || true)
    if [[ -z "$source" ]]; then
        source=$(run_user_cmd pactl list short sources 2>/dev/null | awk 'NR==1 {print $2}')
    fi
    echo "$source"
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

# Set microphone state
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
    
    if [[ "$target_state" == "toggle" ]]; then
        case "$CONTROL_BACKEND" in
            alsa)
                if check_sudo; then
                    current_before=$(get_current_state)
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
                    run_user_cmd pactl set-source-mute "$source" 0
                else
                    run_user_cmd pactl set-source-mute "$source" 1
                fi
                echo "$(get_current_state)"
                ;;
            wpctl)
                if [[ "$target_state" == "on" ]]; then
                    run_user_cmd wpctl set-mute @DEFAULT_SOURCE@ 0
                else
                    run_user_cmd wpctl set-mute @DEFAULT_SOURCE@ 1
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

# Show help message
show_help_message() {
    cat << EOF
endimic.sh - Advanced Linux Mic Toggle
Version: $VERSION

Usage: $0 [OPTIONS]

Options:
  -o, --state STATE  Set microphone state (on, off, or toggle)
  -h, --help        Show this help message
  -v, --version     Show version information
  -V, --verbose     Enable verbose output

Examples:
  $0 -o toggle      Toggle current microphone state
  $0 -o on         Turn microphone on
  $0 -o off        Turn microphone off
  $0               Show current microphone state

Note: This script requires sudo privileges to modify microphone state.
EOF
}

# Show version information
show_version_info() {
    cat << EOF
endimic.sh - Version $VERSION
Author: $AUTHOR
License: MIT

A simple ALSA microphone toggle utility for Linux systems.
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
            -o|--state)
                # Next argument is the state
                state_set=true
                ;;
            *)
                if [[ "$state_set" == true ]]; then
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
}

# Main script execution
main() {
    # Parse arguments
    parse_arguments "$@"
    
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
    
    # Display header
    echo "------------------------------------------------------------"
    echo "------- Advanced Linux Sound Architecture Mic Toggle -------"
    echo "------------------------------------------------------------"
    
    # Determine and set state
    if [[ -z "$state" ]]; then
        # No state specified, show current state
        current_state=$(get_current_state)
        echo "Current Microphone State: $current_state"
        log "INFO: Displayed current state: $current_state"
    else
        # State specified, try to set it
        if [[ "$state" == "on" || "$state" == "off" || "$state" == "toggle" ]]; then
            final_state=$(set_mic_state "$state")
            echo "Microphone State Set To: $final_state"
        else
            echo "Error: Invalid state '$state'. Use 'on', 'off', or 'toggle'." >&2
            log "ERROR: Invalid state argument: $state"
            exit 1
        fi
    fi
    
    echo "------------------------------------------------------------"
    echo "--------------- Your Mic Has Been Modified -----------------"
    echo "------------------------------------------------------------"
    
    # Pause before exit (3 seconds or key press)
    if [[ "$verbose" == false ]]; then
        read -p "Press any key to continue" -t 3 -n 1 -s
        echo ""
    fi
}

# Run main function with all arguments
main "$@"
