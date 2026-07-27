#!/bin/bash
# ============================================================
# open.sh — Open FileUploadPlus in Xcode
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

SCHEME="FileUploadPlus"

# ---------- check ----------
check_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found. Install Xcode CLI tools." >&2; exit 1; }
}

echo "===== Open FileUploadPlus ====="
check_tool xcodebuild

# Prefer .xcodeproj if it exists (demo app); otherwise open Package.swift
if [ -f "FileUploadPlus.xcodeproj/project.pbxproj" ]; then
    echo "→ Opening Xcode project..."
    open "FileUploadPlus.xcodeproj"
else
    echo "→ Opening Swift Package..."
    open "Package.swift"
fi
echo "Done."
