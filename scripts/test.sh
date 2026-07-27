#!/bin/bash
# ============================================================
# test.sh — Run unit tests
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo "===== Test FileUploadPlus ====="

# SPM tests
swift test 2>&1 | tee test_output.log
echo "Tests done. See test_output.log"
