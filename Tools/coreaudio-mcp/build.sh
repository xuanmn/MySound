#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
mkdir -p "${BIN_DIR}"

SWIFT_FILES=$(find "${SCRIPT_DIR}/Sources" -type f -name "*.swift")

swiftc -O \
  -target arm64-apple-macos14.2 \
  -framework Foundation \
  ${SWIFT_FILES} \
  -o "${BIN_DIR}/coreaudio-mcp"

chmod +x "${BIN_DIR}/coreaudio-mcp"
echo "Successfully compiled: ${BIN_DIR}/coreaudio-mcp"
