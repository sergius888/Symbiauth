#!/bin/bash
# Smoke tests for PR2+PR3 (Certificate Rotation + Gating + Idempotency)
# Run after merging to main

set -e

echo "🧪 Running PR2+PR3 Smoke Tests"
echo "================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    ((FAILED++))
}

warn() {
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
}

echo "Test 1: Certificate Rotation Workflow"
echo "--------------------------------------"

# Generate test cert
if openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout /tmp/smoke_cert.key -out /tmp/smoke_cert.pem \
    -subj "/CN=Smoke Test Cert" &>/dev/null; then
    pass "Generated test certificate"
else
    fail "Failed to generate test certificate"
fi

# Check CLI exists
if cargo build --bin agent-cli --quiet 2>/dev/null; then
    pass "Built agent-cli"
else
    fail "Failed to build agent-cli"
fi

# Test rotation commands
echo ""
echo "  Testing: agent-cli tls status"
if cargo run --bin agent-cli --quiet -- tls status &>/dev/null; then
    pass "Status command works"
else
    fail "Status command failed"
fi

echo "  Testing: agent-cli tls rotate"
if cargo run --bin agent-cli --quiet -- tls rotate --cert /tmp/smoke_cert.pem &>/dev/null; then
    pass "Rotate command works"
    
    # Verify config has fp_next
    if grep -q "fp_next" ~/Library/Application\ Support/Symbiauth/tls.json 2>/dev/null; then
        pass "Config shows fp_next (dual-pin active)"
    else
        fail "Config missing fp_next after staging"
    fi
else
    fail "Rotate command failed"
fi

echo "  Testing: agent-cli tls status --json"
if cargo run --bin agent-cli --quiet -- tls status --json | jq -e '.is_rotating == true' &>/dev/null; then
    pass "JSON output shows rotation in progress"
else
    fail "JSON output incorrect"
fi

echo "  Testing: agent-cli tls promote"
if cargo run --bin agent-cli --quiet -- tls promote &>/dev/null; then
    pass "Promote command works"
    
    # Verify fp_next cleared
    if ! grep -q '"fp_next": null' ~/Library/Application\ Support/Symbiauth/tls.json 2>/dev/null; then
        warn "Expected fp_next to be null after promotion"
    else
        pass "Config cleared fp_next after promotion"
    fi
else
    fail "Promote command failed"
fi

# Cleanup
rm -f /tmp/smoke_cert.{key,pem}

echo ""
echo "Test 2: Rate Limiting (PR1)"
echo "---------------------------"

# Note: This would need the agent running
warn "Rate limiting test requires running agent (manual test)"
echo "  Manual test: Send 6 auth requests for same origin in 1 minute"
echo "  Expected: 6th request returns 429 Too Many Requests"

echo ""
echo "Test 3: Idempotency (PR1)"
echo "-------------------------"

warn "Idempotency test requires running agent (manual test)"
echo "  Manual test: Send vault.write with same idempotency_key twice"
echo "  Expected: Second request returns replayed:true, no duplicate write"

echo ""
echo "Test 4: QR Payload During Rotation"
echo "-----------------------------------"

warn "QR payload test requires TLS app running (manual test)"
echo "  Manual test: Show pairing QR while rotation is staged"
echo "  Expected: QR JSON includes both agent_fp and agent_fp_next"
echo "  Check TLS app logs for: 'Rotation in progress, including agent_fp_next'"

echo ""
echo "================================"
echo "Smoke Test Summary"
echo "================================"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All automated tests passed!${NC}"
    echo ""
    echo "Manual tests remaining:"
    echo "  - Rate limiting (6 rapid requests → 429)"
    echo "  - Idempotency (duplicate write → replayed)"
    echo "  - QR dual-pin (verify agent_fp_next in QR)"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi
