#!/bin/bash
# Build phase: writes the git commit, branch and build time into the built app's Info.plist,
# so the running app can say exactly which build it is (`psctl status`, first line of core.log).
# Runs after the Info.plist has been processed and before the bundle is signed.
set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST" ] || { echo "stamp-build: $PLIST not found" >&2; exit 1; }

cd "${SRCROOT}"
COMMIT="$(git rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
# Uncommitted changes to tracked files make the commit alone a lie: say so.
if [ "$COMMIT" != unknown ] && [ -n "$(git status --porcelain --untracked-files=no --ignore-submodules=all 2>/dev/null)" ]; then
	COMMIT="${COMMIT}+dirty"
fi
TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/bin/plutil -replace PSGitCommit -string "$COMMIT" "$PLIST"
/usr/bin/plutil -replace PSGitBranch -string "$BRANCH" "$PLIST"
/usr/bin/plutil -replace PSBuildTime -string "$TIME" "$PLIST"
echo "stamp-build: $COMMIT ($BRANCH) at $TIME"
