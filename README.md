# Endimic - Advanced Linux Mic Toggle

A privacy-first Linux microphone control tool that mutes all physical mics and routes apps to a safe loopback source. It includes an audible trust test, loopback verification, and a simple interactive menu.

## Features

- **Mute all physical mics** when set to off (internal + external)
- **Loopback privacy mode**: apps hear a loopback source instead of the physical mic
- **White noise test** with audible confirmation and loopback verification
- **Security checks** and activity monitoring
- **Interactive menu** with advanced diagnostics
- **Logging** to user-owned files

## Installation

### Requirements
- Linux system with ALSA
- `amixer`, `aplay` (alsa-utils)
- PulseAudio or PipeWire (`pactl`, `paplay`/`pw-play` recommended)
- sudo privileges for microphone control

### Install Dependencies

```bash
# On Debian/Ubuntu
sudo apt-get install alsa-utils pulseaudio-utils

# On Fedora/RHEL
sudo dnf install alsa-utils pulseaudio-utils

# On Arch Linux
sudo pacman -S alsa-utils pulseaudio
```

### One-Click Installer

```bash
./install.sh
```

The installer detects your package manager, installs dependencies, and makes `endimic.sh` executable.

### Manual Install Endimic

```bash
# Clone the repository or download the script
git clone https://github.com/Z-A-P-P-I-T/Advanced-Linux-Sound-Architecture-Mic-Toggle.git
cd endimic

# Make the script executable
chmod +x endimic.sh

# Optional: Install system-wide
sudo cp endimic.sh /usr/local/bin/endimic
sudo chmod +x /usr/local/bin/endimic
```

## Usage

### Basic Usage

```bash
# Show menu (default)
./endimic.sh

# Toggle microphone state
./endimic.sh -o toggle

# Turn microphone on
./endimic.sh -o on

# Turn microphone off
./endimic.sh -o off
```

### Advanced Options

```bash
# Show help
./endimic.sh -h
./endimic.sh --help

# Show version
./endimic.sh -v
./endimic.sh --version

# Enable verbose output (no pause)
./endimic.sh -V
./endimic.sh --verbose

# White noise test with verification
./endimic.sh -w --verify

# Diagnostics (read-only)
./endimic.sh --diagnose
```

## Configuration

Endimic creates:
- `~/.endimic_config` (optional overrides)
- `~/.endimic.log` (activity log)
- `~/.endimic_security.log` (security log)
- `~/.endimic_state` (last verification status/time)

### Privacy Model

- When muted, the default source is set to `endimic_loopback`, so apps do not access the physical mic.
- In privacy mode (`LOOPBACK_MODE="null"`), the loopback is fed from a **private null sink**. Apps hear silence/noise, not your mic or system audio.
- Audible playback is optional and only used to build trust that the test ran.

### How It Works (Short)

1. Mutes all physical microphone sources (internal + external).
2. Sets the default input to a loopback source (`endimic_loopback`).
3. In privacy mode, the loopback comes from a private null sink so apps cannot hear system audio.
4. Optional audible white noise test helps you confirm the pipeline without exposing the physical mic.

### Common Overrides

```bash
# Force a specific output sink for audible tests
AUDIBLE_SINK=alsa_output.pci-0000_00_1f.3.analog-stereo

# Privacy mode (recommended)
LOOPBACK_MODE="null"

# Use system audio as loopback source (less private)
# LOOPBACK_MODE="monitor"

# Mute all physical sources when mic is off
AUTO_MUTE_ALL_SOURCES=true
FORCE_LOOPBACK_ON_MUTE=true
```

## Troubleshooting

### "amixer not found" error
Ensure alsa-utils is installed:
```bash
sudo apt-get install alsa-utils  # Debian/Ubuntu
```

### Permission denied errors
The script requires sudo privileges to modify microphone state. You can:
1. Run with sudo: `sudo ./endimic.sh -o toggle`
2. Configure sudoers to allow passwordless execution for this script
3. Use `pkexec` instead of sudo for better security

### Microphone not detected
Check your ALSA configuration and ensure your microphone is properly connected.

### No audible white noise during test
1. Run `./endimic.sh --diagnose` and set `AUDIBLE_SINK` accordingly.
2. Confirm you can hear the saved file:
   `aplay -D pulse ~/.endimic_white_noise.wav`

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please open issues or pull requests on GitHub.

## Author

Created by Kimi Autto (github.com/Z-A-P-P-I-T)

## Version History

- **v2.0**: Major rewrite with improved error handling, logging, and user interface
- **v1.0**: Initial release with basic toggle functionality
