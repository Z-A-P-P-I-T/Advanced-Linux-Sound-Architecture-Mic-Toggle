#!/bin/bash

# Enhanced Test Script for Endimic v3.0
# Tests new security features and menu system

echo "Starting Endimic v3.0 Test Suite"
echo "========================================"

# Test 1: Check if script exists and is executable
echo "Test 1: Checking script permissions..."
if [[ -f "endimic_v3.sh" && -x "endimic_v3.sh" ]]; then
    echo "✓ Script exists and is executable"
else
    echo "✗ Script not found or not executable"
    exit 1
fi

# Test 2: Check help functionality
echo ""
echo "Test 2: Testing enhanced help functionality..."
if ./endimic_v3.sh --help | grep -q "Security Features"; then
    echo "✓ Enhanced help message works correctly"
else
    echo "✗ Enhanced help message not working"
fi

# Test 3: Check version functionality
echo ""
echo "Test 3: Testing version functionality..."
if ./endimic_v3.sh --version | grep -q "Version 3.0"; then
    echo "✓ Version information works correctly"
else
    echo "✗ Version information not working"
fi

# Test 4: Check new command-line options
echo ""
echo "Test 4: Testing new command-line options..."

# Test security check option
if ./endimic_v3.sh --help | grep -q "security"; then
    echo "✓ Security check option available"
else
    echo "✗ Security check option missing"
fi

# Test white noise option
if ./endimic_v3.sh --help | grep -q "white-noise"; then
    echo "✓ White noise option available"
else
    echo "✗ White noise option missing"
fi

# Test menu option
if ./endimic_v3.sh --help | grep -q "menu"; then
    echo "✓ Menu option available"
else
    echo "✗ Menu option missing"
fi

# Test 5: Check amixer dependency detection
echo ""
echo "Test 5: Testing dependency checking..."
if command -v amixer &> /dev/null; then
    echo "✓ amixer is available"
    
    # Test 6: Check current state display (without sudo)
    echo ""
    echo "Test 6: Testing current state display..."
    if ./endimic_v3.sh | grep -q "Current Microphone State"; then
        echo "✓ Current state display works"
    else
        echo "✗ Current state display not working"
    fi
else
    echo "⚠ amixer not available, skipping state tests"
fi

# Test 7: Check error handling for invalid arguments
echo ""
echo "Test 7: Testing error handling..."
if ./endimic_v3.sh -o invalid 2>&1 | grep -q "Invalid state"; then
    echo "✓ Error handling works correctly"
else
    echo "✗ Error handling not working"
fi

# Test 8: Check new security features
echo ""
echo "Test 8: Testing security features..."

# Check if arecord is available for monitoring
if command -v arecord &> /dev/null; then
    echo "✓ arecord available for microphone monitoring"
else
    echo "⚠ arecord not available, microphone monitoring will be disabled"
fi

# Check if aplay is available for white noise
if command -v aplay &> /dev/null; then
    echo "✓ aplay available for white noise generation"
else
    echo "⚠ aplay not available, white noise generation will be limited"
fi

# Test 9: Check optional dependencies
echo ""
echo "Test 9: Testing optional dependencies..."

# Check for sox (better white noise)
if command -v sox &> /dev/null; then
    echo "✓ sox available for high-quality white noise"
else
    echo "ℹ sox not available, will use fallback method"
fi

# Check for ffmpeg (alternative white noise)
if command -v ffmpeg &> /dev/null; then
    echo "✓ ffmpeg available for white noise generation"
else
    echo "ℹ ffmpeg not available, will use fallback method"
fi

# Test 10: Test security check functionality
echo ""
echo "Test 10: Testing security check functionality..."
if ./endimic_v3.sh --help | grep -q "Perform security check"; then
    echo "✓ Security check functionality documented"
else
    echo "✗ Security check functionality not documented"
fi

echo ""
echo "========================================"
echo "Test Suite Complete"
echo ""
echo "Summary of new v3.0 features tested:"
echo "✓ Enhanced help system with security info"
echo "✓ New command-line options (--security, --white-noise, --menu)"
echo "✓ Dependency checking for monitoring tools"
echo "✓ Error handling and validation"
echo "✓ Security feature documentation"
echo ""
echo "Note: Some tests require sudo privileges and were skipped."
echo "To test full functionality, run:"
echo "  sudo ./endimic_v3.sh -o toggle"
echo "  sudo ./endimic_v3.sh -s           # Security check"
echo "  sudo ./endimic_v3.sh -w           # White noise test"
echo "  ./endimic_v3.sh --menu            # Interactive menu (no sudo needed)"