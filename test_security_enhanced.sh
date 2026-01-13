#!/bin/bash

# Test the enhanced security features
echo "Testing Enhanced Security Features"
echo "=================================="

# Test 1: Check if the script handles permission issues gracefully
echo "Test 1: Permission handling..."
echo "n" | ./endimic_v3.sh
if [[ $? -eq 0 ]]; then
    echo "✓ Script handles permission issues gracefully"
else
    echo "✗ Script failed with permission issues"
fi

echo ""

# Test 2: Check security check with current state
echo "Test 2: Security check functionality..."
echo "y" | ./endimic_v3.sh | grep -q "Security check"
if [[ $? -eq 0 ]]; then
    echo "✓ Security check initiates correctly"
else
    echo "✗ Security check not working"
fi

echo ""

# Test 3: Check help shows security features
echo "Test 3: Security features in help..."
if ./endimic_v3.sh --help | grep -q "Security Features"; then
    echo "✓ Security features documented in help"
else
    echo "✗ Security features not in help"
fi

echo ""

# Test 4: Check version shows security info
echo "Test 4: Security info in version..."
if ./endimic_v3.sh --version | grep -q "security"; then
    echo "✓ Security info in version output"
else
    echo "✗ Security info missing from version"
fi

echo ""
echo "Enhanced security features test complete!"