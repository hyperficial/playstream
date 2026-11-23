#!/bin/bash
# Generates the Xcode project and builds PlayStream.app.
# Usage: build-app.sh [Release|Debug] [output-dir]
#   default output: Release -> build/release, Debug -> build/app
# Never build into the directory of a PlayStream that is running: use scripts/hot-swap.sh,
# which builds into a free slot and swaps the new build in.
# Exit status is xcodebuild's, so callers can tell a failed build from a finished one.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Release}"
if [ "$CONFIG" = "Release" ]; then OUT="$ROOT/build/release"; else OUT="$ROOT/build/app"; fi
if [ -n "${2:-}" ]; then
	mkdir -p "$2"
	OUT="$(cd "$2" && pwd)"
fi
[ -f build/chiaki/lib/libchiaki.a ] || ./scripts/build-chiaki.sh || exit 1
xcodegen generate --quiet || exit 1
LOG="$ROOT/build/xcodebuild-last.log"
# Signing is machine-specific and stays out of the repository. With a Local.xcconfig next to
# project.yml (one line: DEVELOPMENT_TEAM = <your Apple team id>) the app is signed with your
# Apple Development certificate; without one it is signed ad hoc, which is enough to run it.
if [ -f "$ROOT/Local.xcconfig" ]; then
	SIGNING=(-xcconfig "$ROOT/Local.xcconfig")
else
	SIGNING=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
xcodebuild -project PlayStream.xcodeproj -scheme PlayStream -configuration "$CONFIG" \
	-derivedDataPath build/xcode -destination 'platform=macOS,arch=arm64' \
	CONFIGURATION_BUILD_DIR="$OUT" "${SIGNING[@]}" build > "$LOG" 2>&1
STATUS=$?
grep -E "error:|warning: unre|\*\* BUILD|Signing Identity|^stamp-build" "$LOG" || true
if [ $STATUS -ne 0 ]; then
	echo "Build failed (full log: $LOG)"
	exit $STATUS
fi
echo "App: $OUT/PlayStream.app"
