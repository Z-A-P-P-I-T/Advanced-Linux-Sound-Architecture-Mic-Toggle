#!/bin/bash

# Test script for endimic.sh
# This script tests the functionality without requiring sudo privileges

echo "Starting Endimic Test Suite"
echo "========================================"

# Test 1: Check if script exists and is executable
echo "Test 1: Checking script permissions..."
if [[ -f "endimic_v2.sh" && -x "endimic_v2.sh" ]]; then
    echo "✓ Script exists and is executable"
else
    echo "✗ Script not found or not executable"
    exit 1
fi

# Test 2: Check help functionality
echo ""
echo "Test 2: Testing help functionality..."
if ./endimic_v2.sh --help | grep -q "Advanced Linux Mic Toggle"; then
    echo "✓ Help message works correctly"
else
    echo "✗ Help message not working"
fi

# Test 3: Check version functionality
echo ""
echo "Test 3: Testing version functionality..."
if ./endimic_v2.sh --version | grep -q "Version 2.0"; then
    echo "✓ Version information works correctly"
else
    echo "✗ Version information not working"
fi

# Test 4: Check amixer dependency detection
echo ""
echo "Test 4: Testing dependency checking..."
if command -v amixer &> /dev/null; then
    echo "✓ amixer is available"
    
    # Test 5: Check current state display (without sudo)
    echo ""
    echo "Test 5: Testing current state display..."
    if ./endimic_v2.sh | grep -q "Current Microphone State"; then
        echo "✓ Current state display works"
    else
        echo "✗ Current state display not working"
    fi
else
    echo "⚠ amixer not available, skipping state tests"
fi

# Test 6: Check error handling for invalid arguments
echo ""
echo "Test 6: Testing error handling..."
if ./endimic_v2.sh -o invalid 2>&1 | grep -q "Invalid state"; then
    echo "✓ Error handling works correctly"
else
    echo "✗ Error handling not working"
fi

echo ""
echo "========================================"
echo "Test Suite Complete"
echo ""
echo "Note: Some tests require sudo privileges and were skipped."
echo "To test full functionality, run:"
echo "  sudo ./endimic_v2.sh -o toggle"
echo "  sudo ./endimic_v2.sh -o on"
echo "  sudo ./endimic_v2.sh -o off"