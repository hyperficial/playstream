#!/bin/bash
# Builds this checkout and swaps the new build into a running PlayStream without anyone
# touching the app: the running instance closes its session, starts the new build and exits;
# the new build reconnects to the console and goes back to full screen by itself.
#
# Usage: hot-swap.sh [--now] [--idle-seconds N] [--timeout N] [--build-only]
#   default       wait until the controller has been untouched for N seconds (default 5), so
#                 the swap lands in a pause; give up after --timeout seconds (default 900)
#   --now         swap immediately
#   --build-only  build into the free slot and print the psctl command, swap nothing
#
# The build goes into build/slot-a or build/slot-b, whichever the running app is not using,
# so the bundle of the running app is never written to. If the new build does not come up, the
# relaunch helper starts the previous one again (see ~/Library/Logs/PlayStream/relaunch.log).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSCTL="$ROOT/scripts/psctl"

NOW=0
BUILD_ONLY=0
IDLE=5
TIMEOUT=900
while [ $# -gt 0 ]; do
	case "$1" in
	--now) NOW=1 ;;
	--build-only) BUILD_ONLY=1 ;;
	--idle-seconds) IDLE="$2"; shift ;;
	--timeout) TIMEOUT="$2"; shift ;;
	*) echo "usage: hot-swap.sh [--now] [--idle-seconds N] [--timeout N] [--build-only]" >&2; exit 3 ;;
	esac
	shift
done

RUNNING="$("$PSCTL" --json status 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["app"]["bundlePath"])' 2>/dev/null || true)"
case "$RUNNING" in
"$ROOT/build/slot-a/"*) OUT="$ROOT/build/slot-b" ;;
*) OUT="$ROOT/build/slot-a" ;;
esac

echo "Running: ${RUNNING:-none (or the control channel is off)}"
echo "Building into $OUT"
"$ROOT/scripts/build-app.sh" Release "$OUT" || exit 1
APP="$OUT/PlayStream.app"

if [ "$BUILD_ONLY" = 1 ] || [ -z "$RUNNING" ]; then
	[ -z "$RUNNING" ] && echo "PlayStream is not running, nothing to swap."
	echo "Built $APP"
	echo "Swap it in with: scripts/psctl relaunch \"$APP\" --when-idle --wait"
	exit 0
fi

"$PSCTL" mark "hot-swap: new build ready at $APP" > /dev/null
if [ "$NOW" = 1 ]; then
	exec "$PSCTL" relaunch "$APP" --wait
else
	exec "$PSCTL" relaunch "$APP" --when-idle --idle-seconds "$IDLE" --timeout "$TIMEOUT" --wait
fi
