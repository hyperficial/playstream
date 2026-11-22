#!/bin/bash
# Generates the Xcode project and builds PlayStream.app.
# Usage: build-app.sh [Release|Debug]   (default Release -> build/release, Debug -> build/app)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Release}"
if [ "$CONFIG" = "Release" ]; then OUT="$ROOT/build/release"; else OUT="$ROOT/build/app"; fi
[ -f build/chiaki/lib/libchiaki.a ] || ./scripts/build-chiaki.sh
xcodegen generate --quiet
xcodebuild -project PlayStream.xcodeproj -scheme PlayStream -configuration "$CONFIG" \
	-derivedDataPath build/xcode -destination 'platform=macOS,arch=arm64' \
	CONFIGURATION_BUILD_DIR="$OUT" build 2>&1 | grep -E "error|warning: unre|BUILD|Signing Identity" || true
echo "App: $OUT/PlayStream.app"
