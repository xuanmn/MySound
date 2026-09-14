#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${SCRIPT_DIR}/bin/coreaudio-mcp"

if [ ! -f "${BIN}" ]; then
  "${SCRIPT_DIR}/build.sh"
fi

echo "=== Running coreaudio-mcp Automated Smoke Tests ==="

send_request() {
  local req="$1"
  echo "$req" | "${BIN}" 2>/dev/null
}

echo "Test 1: initialize handshake..."
RESP1=$(send_request '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0"}}}')
echo "$RESP1" | grep -q '"protocolVersion":"2024-11-05"'
echo "$RESP1" | grep -q '"name":"coreaudio-mcp"'
echo "  Passed."

echo "Test 2: tools/list..."
RESP2=$(send_request '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
echo "$RESP2" | grep -q '"name":"search_apis"'
echo "$RESP2" | grep -q '"name":"get_api_details"'
echo "$RESP2" | grep -q '"name":"get_code_recipe"'
echo "$RESP2" | grep -q '"name":"check_realtime_safety"'
echo "  Passed."

echo "Test 3: tools/call search_apis..."
RESP3=$(send_request '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_apis","arguments":{"query":"tap"}}}')
echo "$RESP3" | grep -q "CATapDescription"
echo "$RESP3" | grep -q "AudioHardwareCreateProcessTap"
echo "  Passed."

echo "Test 4: tools/call get_api_details..."
RESP4=$(send_request '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_api_details","arguments":{"symbol":"CATapDescription"}}}')
echo "$RESP4" | grep -q "CATapDescription"
echo "$RESP4" | grep -q "System Audio Recording"
echo "  Passed."

echo "Test 5: tools/call get_code_recipe..."
RESP5=$(send_request '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_code_recipe","arguments":{"recipe_id":"process_tap_setup"}}}')
echo "$RESP5" | grep -q "AudioHardwareCreateProcessTap"
echo "  Passed."

echo "Test 6: tools/call check_realtime_safety (detect unsafe malloc and Task)..."
UNSAFE_REQ='{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"check_realtime_safety","arguments":{"code":"func render() {\n  malloc(1024)\n  Task { await doWork() }\n}"}}}'
RESP6=$(send_request "$UNSAFE_REQ")
echo "$RESP6" | grep -q "VIOLATIONS DETECTED"
echo "$RESP6" | grep -q "Heap Allocation"
echo "$RESP6" | grep -q "Swift Concurrency"
echo "  Passed."

echo "Test 7: tools/call check_realtime_safety (safe code passes)..."
SAFE_REQ='{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"check_realtime_safety","arguments":{"code":"func render() {\n  vDSP_vsmul(samples, 1, &gain, samples, 1, count)\n}"}}}'
RESP7=$(send_request "$SAFE_REQ")
echo "$RESP7" | grep -q "PASSED AUDIT"
echo "  Passed."

echo "=== All 7 Smoke Tests Passed Successfully! ==="
