#!/bin/bash
# ============================================================
# build.sh — Build the Swift Package (or Xcode project)
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

MODE="${1:-spm}"          # spm | xcode
CONFIGURATION="${2:-debug}" # debug | release
DESTINATION="${3:-platform=iOS Simulator,name=iPhone 17}"

echo "===== Build FileUploadPlus (mode=$MODE, config=$CONFIGURATION) ====="

build_spm() {
    echo "→ Building with SPM..."
    local flags=""
    [ "$CONFIGURATION" = "release" ] && flags="-c release"
    swift build $flags
    echo "SPM build done."
}

build_xcode() {
    echo "→ Building Xcode project..."
    if [ ! -f "FileUploadPlus.xcodeproj/project.pbxproj" ]; then
        echo "ERROR: No .xcodeproj found. Use 'spm' mode or open Package.swift." >&2
        exit 1
    fi
    local config_flag="-configuration"
    local config_val="${CONFIGURATION^}"  # Debug / Release
    xcodebuild \
        -project FileUploadPlus.xcodeproj \
        -scheme FileUploadPlus \
        -destination "$DESTINATION" \
        $config_flag "$config_val" \
        build
    echo "Xcode build done."
}

case "$MODE" in
    spm)   build_spm ;;
    xcode) build_xcode ;;
    *)
        echo "Usage: $0 [spm|xcode] [debug|release] [destination]"
        exit 1
        ;;
esac
