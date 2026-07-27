# ============================================================
# Makefile — FileUploadPlus Build Automation
# ============================================================

DESTINATION := platform=iOS Simulator,name=iPhone 17
SCHEME      := FileUploadPlus
PROJECT     := FileUploadPlus.xcodeproj

.PHONY: all open build-spm build-xcode build-release test clean help

# ---------- Default ----------
all: build-spm

# ---------- Open ----------
open:
	@bash scripts/open.sh

# ---------- Build (SPM) ----------
build-spm:
	@bash scripts/build.sh spm debug

build-spm-release:
	@bash scripts/build.sh spm release

# ---------- Build (Xcode) ----------
build-xcode:
	@bash scripts/build.sh xcode debug "$(DESTINATION)"

build-xcode-release:
	@bash scripts/build.sh xcode release "$(DESTINATION)"

# ---------- Test ----------
test:
	swift test

test-xcode:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "$(DESTINATION)" test

# ---------- Clean ----------
clean:
	@echo "→ Cleaning build artifacts..."
	rm -rf .build
	rm -rf ~/Library/Developer/Xcode/DerivedData/FileUploadPlus-*
	@echo "Clean done."

clean-xcode:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean

# ---------- Lint / Format ----------
lint:
	@echo "→ Running swift-format lint..."
	swift-format lint --recursive Sources/ --strict 2>/dev/null || echo "Install swift-format: brew install swift-format"

format:
	@echo "→ Running swift-format..."
	swift-format format --recursive Sources/ --in-place 2>/dev/null || echo "Install swift-format: brew install swift-format"

# ---------- Help ----------
help:
	@echo "FileUploadPlus — Build Automation"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  all               Default: build-spm"
	@echo "  open              Open project in Xcode"
	@echo "  build-spm         Build with Swift Package Manager (debug)"
	@echo "  build-spm-release Build with SPM (release)"
	@echo "  build-xcode       Build with Xcode project (debug)"
	@echo "  build-xcode-release Build with Xcode (release)"
	@echo "  test              Run SPM tests"
	@echo "  test-xcode        Run Xcode tests"
	@echo "  clean             Remove build artifacts"
	@echo "  lint              Lint source with swift-format"
	@echo "  format            Format source with swift-format"
