#!/bin/bash
# Generates the Xcode project and builds PlayStream.app into build/app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Debug}"
[ -f build/chiaki/lib/libchiaki.a ] || ./scripts/build-chiaki.sh
xcodegen generate --quiet
xcodebuild -project PlayStream.xcodeproj -scheme PlayStream -configuration "$CONFIG" \
	-derivedDataPath build/xcode -destination 'platform=macOS,arch=arm64' \
	CONFIGURATION_BUILD_DIR="$ROOT/build/app" build 2>&1 | grep -E "error|warning: unre|BUILD|Signing Identity" || true
echo "App: $ROOT/build/app/PlayStream.app"
