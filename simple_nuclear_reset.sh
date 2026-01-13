#!/bin/bash

# Simple Nuclear Reset - No menu, no complexity
echo "🔥 SIMPLE NUCLEAR RESET"
echo "======================"

# Kill audio processes
killall pulseaudio jackd arecord aplay 2>/dev/null
pkill -9 pulseaudio jackd arecord aplay 2>/dev/null

# Reset ALSA
alsa force-reload

# Restart services
systemctl restart alsa-state 2>/dev/null

# Reset microphone state
amixer sset Capture off 2>/dev/null
amixer sset Capture on 2>/dev/null
amixer sset Capture off 2>/dev/null

echo "✅ Nuclear reset completed"
echo "Please test your microphone with: ./endimic_v3.sh -w"
