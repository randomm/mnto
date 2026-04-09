#!/bin/bash
# Quick verification that OpenAI backend is wired correctly

set -euo pipefail

cd "$(dirname "$0")"

echo "=== Testing OpenAI backend wiring ==="

# Test 1: Verify openai.bash is sourced before backend.bash
echo "Test 1: Checking mnto source order..."
if grep -A 10 "# Source library functions" mnto | grep -q "source.*openai.bash"; then
    if grep -A 10 "# Source library functions" mnto | grep -A 1 "source.*openai.bash" | grep -q "source.*backend.bash"; then
        echo "✓ openai.bash is sourced before backend.bash"
    else
        echo "✗ backend.bash not found after openai.bash"
        exit 1
    fi
else
    echo "✗ openai.bash not found in source list"
    exit 1
fi

# Test 2: Verify stub is removed from backend.bash
echo "Test 2: Checking that stub _infer_openai is removed..."
if grep -q "_infer_openai.*not yet implemented" lib/backend.bash; then
    echo "✗ Stub _infer_openai still present in backend.bash"
    exit 1
else
    echo "✓ Stub _infer_openai removed from backend.bash"
fi

# Test 3: Verify real _infer_openai exists in openai.bash
echo "Test 3: Checking that real _infer_openai exists in openai.bash..."
if grep -q "^_infer_openai()" lib/openai.bash; then
    echo "✓ Real _infer_openai function exists in openai.bash"
else
    echo "✗ _infer_openai function not found in openai.bash"
    exit 1
fi

# Test 4: Verify E2E script has configurable model
echo "Test 4: Checking E2E model configurability..."
if grep -q "E2E_OPENAI_MODEL" test/e2e/e2e-qa.sh; then
    echo "✓ E2E script uses configurable E2E_OPENAI_MODEL"
else
    echo "✗ E2E script missing E2E_OPENAI_MODEL configuration"
    exit 1
fi

# Test 5: Verify tests updated to not expect stub error
echo "Test 5: Checking test assertions updated..."
if grep -q "not yet implemented" test/backend.bats; then
    echo "✗ Tests still contain 'not yet implemented' error message"
    exit 1
else
    echo "✓ Tests updated to remove stub error assertions"
fi

echo ""
echo "=== All checks passed ==="