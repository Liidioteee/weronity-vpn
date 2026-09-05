#!/usr/bin/env bash
# Build weronity_core.dll for Windows (x86_64) and drop it where the Flutter
# desktop app can load it.
#
#   native/scripts/build-windows.sh [debug|release]
#
# Requires: Go (with CGO), a mingw-w64 gcc on PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-debug}"
src="$here/../weronity_core"
repo="$here/../.."

export CGO_ENABLED=1
export GOOS=windows
export GOARCH=amd64

# Find a mingw-w64 gcc. Prefer one already on PATH, else probe the winlibs /
# MSYS2 install locations (Git-Bash's own PATH does not carry it).
if ! command -v gcc >/dev/null 2>&1; then
  shopt -s nullglob
  for cand in \
    /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs*/mingw64/bin \
    /c/mingw64/bin /c/msys64/mingw64/bin /c/tools/mingw64/bin; do
    if [ -x "$cand/gcc.exe" ]; then
      export PATH="$cand:$PATH"
      break
    fi
  done
  shopt -u nullglob
fi

if ! command -v gcc >/dev/null 2>&1; then
  echo "error: gcc (mingw-w64) not found — needed for CGO on Windows." >&2
  echo "  install: winget install BrechtSanders.WinLibs.POSIX.UCRT" >&2
  exit 1
fi
echo "using $(gcc --version | head -1)"

out_dir="$repo/native/build/windows"
mkdir -p "$out_dir"

# Tags: with_quic (hysteria2/tuic), with_utls (uTLS/REALITY). No with_clash_api —
# the log writer is attached to the factory after box.New (see engine.go), so
# sing-box builds neither a clash server nor a cache.db. Everything else
# (tailscale, acme, dhcp, wireguard, naive, openvpn, gvisor…) is left out on
# purpose — smaller binary, smaller attack surface.
SB_TAGS="with_quic,with_utls"

echo "building weronity_core.dll ($mode, tags=$SB_TAGS) with $(go version)"
( cd "$src" && go build -buildmode=c-shared \
    -tags "$SB_TAGS" \
    -ldflags="-s -w" \
    -o "$out_dir/weronity_core.dll" . )

cp "$out_dir/weronity_core.h" "$repo/native/include/weronity_core.h"
echo "  -> $out_dir/weronity_core.dll"
echo "  -> $repo/native/include/weronity_core.h"

# Make it loadable by `flutter run` / the built exe without CMake wiring.
for d in \
  "$repo/app/build/windows/x64/runner/Debug" \
  "$repo/app/build/windows/x64/runner/Release"; do
  if [ -d "$d" ]; then
    cp "$out_dir/weronity_core.dll" "$d/"
    echo "  -> $d/weronity_core.dll"
  fi
done
