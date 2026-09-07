#!/usr/bin/env bash
# Build libweronity_core.so for Linux (x86_64) and drop it where the Flutter
# desktop app can load it.
#
#   native/scripts/build-linux.sh [debug|release]
#
# Requires: Go (with CGO) and a native gcc. Must run *on* Linux — cgo does not
# cross-compile from Windows without a full linux/amd64 toolchain.
#
# VPN (TUN) mode on Linux needs no wintun equivalent (the kernel provides
# /dev/net/tun), but it does need privileges: run the app as root, or grant the
# executable CAP_NET_ADMIN once:
#
#   sudo setcap 'cap_net_admin,cap_net_raw+ep' /path/to/weronity
#
# Without them sing-box fails to create the interface and the app reports the
# same "needs elevation" error it shows on Windows.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-debug}"
src="$here/../weronity_core"
repo="$here/../.."

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: run this on Linux — cgo needs a native toolchain." >&2
  exit 1
fi

export CGO_ENABLED=1
export GOOS=linux
export GOARCH=amd64

if ! command -v gcc >/dev/null 2>&1; then
  echo "error: gcc not found — needed for CGO." >&2
  echo "  debian/ubuntu: sudo apt install build-essential" >&2
  exit 1
fi
echo "using $(gcc --version | head -1)"

out_dir="$repo/native/build/linux"
mkdir -p "$out_dir"

# Same tag set as the Windows build — see build-windows.sh for why each one is
# there and why with_clash_api is not.
SB_TAGS="with_quic,with_utls,with_gvisor"

echo "building libweronity_core.so ($mode, tags=$SB_TAGS) with $(go version)"
( cd "$src" && go build -buildmode=c-shared \
    -tags "$SB_TAGS" \
    -ldflags="-s -w" \
    -o "$out_dir/libweronity_core.so" . )

cp "$out_dir/libweronity_core.h" "$repo/native/include/weronity_core_linux.h"
echo "  -> $out_dir/libweronity_core.so"

for d in \
  "$repo/app/build/linux/x64/debug/bundle" \
  "$repo/app/build/linux/x64/release/bundle"; do
  if [ -d "$d" ]; then
    cp "$out_dir/libweronity_core.so" "$d/lib/" 2>/dev/null ||
      cp "$out_dir/libweronity_core.so" "$d/"
    echo "  -> $d"
  fi
done
