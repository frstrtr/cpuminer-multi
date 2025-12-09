#!/bin/bash
# Test script for ASICBoost version-rolling implementation

echo "=========================================="
echo "ASICBoost Version-Rolling Test Script"
echo "=========================================="
echo ""

# Configuration
POOL_HOST="${POOL_HOST:-192.168.86.244}"
POOL_PORT="${POOL_PORT:-7903}"
WORKER="${WORKER:-XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6}"
ALGO="${ALGO:-x11}"

echo "Test Configuration:"
echo "  Pool: stratum+tcp://$POOL_HOST:$POOL_PORT"
echo "  Worker: $WORKER"
echo "  Algorithm: $ALGO"
echo ""

# Check if cpuminer exists
if [ ! -f "./cpuminer" ]; then
    echo "❌ Error: cpuminer not found. Please build first:"
    echo "   ./build.sh"
    exit 1
fi

echo "✓ cpuminer binary found"
echo ""

# Test 1: Version check
echo "Test 1: Checking cpuminer version..."
VERSION=$(./cpuminer --version 2>&1 | head -1)
echo "  $VERSION"
echo ""

# Test 2: Quick connectivity test (1 second)
echo "Test 2: Quick connectivity test (3 seconds)..."
echo "  This will check if we can connect and see version-rolling negotiation"
echo ""

timeout 3s ./cpuminer \
    -a "$ALGO" \
    -o "stratum+tcp://$POOL_HOST:$POOL_PORT" \
    -u "$WORKER" \
    -p x \
    -D 2>&1 | grep -E "(ASICBoost|version-rolling|Stratum connection|Stratum session|difficulty)" | head -10

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 124 ]; then
    echo "✓ Test completed (timeout)"
elif [ $EXIT_CODE -eq 0 ]; then
    echo "✓ Test completed"
else
    echo "⚠ Test exited with code: $EXIT_CODE"
fi

echo ""
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo ""
echo "What to look for:"
echo "  ✓ 'Stratum connection' - Connection established"
echo "  ✓ 'Stratum session id' - Session negotiated"
echo "  ✓ '✓ ASICBoost version-rolling enabled' - Version-rolling active!"
echo "  ⚠ If no ASICBoost message - Pool doesn't support it (graceful fallback)"
echo ""
echo "For full test, run:"
echo "  ./cpuminer -a $ALGO -o stratum+tcp://$POOL_HOST:$POOL_PORT -u $WORKER -p x -D"
echo ""
