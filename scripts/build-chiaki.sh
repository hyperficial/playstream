#!/bin/bash
# Builds vendor/chiaki-ng's protocol library (static) into build/chiaki.
# Requires: brew install pkgconf miniupnpc libevent protobuf json-c opus openssl@4 curl cmake ninja
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/chiaki-ng"
OUT="$ROOT/build/chiaki"
PY="$ROOT/build/pyenv/bin/python"

if [ ! -x "$PY" ]; then
	python3 -m venv "$ROOT/build/pyenv"
	"$ROOT/build/pyenv/bin/pip" -q install protobuf grpcio-tools
fi

BREW="$(brew --prefix)"
export PKG_CONFIG_PATH="$BREW/opt/openssl@4/lib/pkgconfig:$BREW/opt/curl/lib/pkgconfig:$BREW/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$ROOT/build/pyenv/bin:$PATH"

cmake -S "$SRC" -B "$OUT" -G Ninja \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_PREFIX_PATH="$BREW/opt/openssl@4;$BREW/opt/curl;$BREW" \
	-DPYTHON_EXECUTABLE="$PY" \
	-DPython3_EXECUTABLE="$PY" \
	-DCHIAKI_ENABLE_TESTS=OFF \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_GUI=OFF \
	-DCHIAKI_ENABLE_SETSU=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
	-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
	-DCHIAKI_ENABLE_PI_DECODER=OFF \
	-DCHIAKI_ENABLE_SPEEX=OFF \
	-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
	-DCHIAKI_USE_SYSTEM_CURL=ON
cmake --build "$OUT"
find "$OUT" -name '*.a'
