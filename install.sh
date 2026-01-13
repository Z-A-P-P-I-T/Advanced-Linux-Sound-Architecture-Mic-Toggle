#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Endimic installer"
echo "================="

need_sudo=false
missing=()

if ! command -v aplay &> /dev/null; then
    missing+=("alsa-utils")
fi

if ! command -v amixer &> /dev/null; then
    if [[ ! " ${missing[*]} " =~ " alsa-utils " ]]; then
        missing+=("alsa-utils")
    fi
fi

if ! command -v pactl &> /dev/null; then
    missing+=("pulseaudio-utils")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing packages: ${missing[*]}"
    need_sudo=true
else
    echo "All required packages found."
fi

if [[ "$need_sudo" == true ]]; then
    echo ""
    echo "Install missing packages now? (y/N): "
    read -r -n 1 reply
    echo ""
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Skipping package installation."
    else
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y "${missing[@]}"
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm "${missing[@]}"
        elif command -v zypper &> /dev/null; then
            sudo zypper install -y "${missing[@]}"
        else
            echo "No supported package manager found."
            echo "Please install: ${missing[*]}"
        fi
    fi
fi

chmod +x "$PROJECT_DIR/endimic.sh"
echo "Done. Run: ./endimic.sh"
