#!/bin/bash

# Nuclear Microphone Reset - Standalone Version
# This script performs a complete, forceful reset of the microphone subsystem

echo "🔥 NUCLEAR MICROPHONE RESET - STANDALONE"
echo "======================================"
echo "This script will FORCEFULLY reset your microphone subsystem"
echo "Use this when all other methods have failed"
echo ""

# Check for sudo
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script requires sudo privileges"
    echo "Please run: sudo ./nuclear_reset.sh"
    exit 1
fi

echo "💀 Step 1/7: Killing ALL audio processes..."
killall pulseaudio jackd arecord aplay 2>/dev/null
pkill -9 pulseaudio jackd arecord aplay 2>/dev/null
echo "   ✅ Audio processes killed"

echo "🔄 Step 2/7: Unloading ALL sound modules..."
alsa_modules=$(lsmod | grep snd | awk '{print $1}')
if [[ -n "$alsa_modules" ]]; then
    modprobe -r $alsa_modules 2>/dev/null
    echo "   ✅ Sound modules unloaded"
else
    echo "   ℹ️  No sound modules to unload"
fi

echo "🗑️  Step 3/7: Removing ALSA state..."
rm -f /var/lib/alsa/asound.state 2>/dev/null
rm -f ~/.asoundrc 2>/dev/null
rm -f /etc/asound.conf 2>/dev/null
echo "   ✅ ALSA state removed"

echo "🔧 Step 4/7: Resetting ALSA completely..."
alsa force-reload
systemctl restart alsa-state 2>/dev/null
echo "   ✅ ALSA reset completed"

echo "🔄 Step 5/7: Reloading ALL sound modules..."
modprobe -a snd 2>/dev/null
echo "   ✅ Sound modules reloaded"

echo "🔄 Step 6/7: Restarting audio services..."
systemctl restart alsa-state 2>/dev/null
echo "   ✅ Audio services restarted"

echo "🎤 Step 7/7: Resetting microphone state..."
amixer sset Capture off 2>/dev/null
amixer sset Capture on 2>/dev/null
amixer sset Capture off 2>/dev/null
echo "   ✅ Microphone state reset"

echo ""
echo "✅ NUCLEAR MICROPHONE RESET COMPLETED"
echo "Your microphone subsystem has been forcefully reset"
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
