#!/usr/bin/env bash
# Fetch the official Wintun DLL (needed by sing-box's `tun` inbound on Windows,
# i.e. Weronity's VPN mode). Downloaded, never committed — the binary is a
# WireGuard LLC redistributable, kept out of this GPLv3 tree on purpose.
#
#   native/scripts/fetch-wintun.sh [dest_dir]
#
# Writes  <dest_dir>/wintun.dll   (default: native/build/windows/)
# Idempotent: does nothing if the file is already present.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${1:-$here/../build/windows}"
arch="${WINTUN_ARCH:-amd64}"

# Pin the release. wintun.net publishes a stable zip per version; 0.14.1 is the
# last upstream release and what sing-box itself ships against.
ver="0.14.1"
url="https://www.wintun.net/builds/wintun-${ver}.zip"
sha256_zip="07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"

mkdir -p "$dest"
if [ -f "$dest/wintun.dll" ]; then
  echo "wintun.dll already present ($dest/wintun.dll)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $url"
curl -fsSL --retry 3 -o "$tmp/wintun.zip" "$url"

if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "$tmp/wintun.zip" | cut -d' ' -f1)"
  if [ "$got" != "$sha256_zip" ]; then
    echo "error: wintun-${ver}.zip sha256 mismatch" >&2
    echo "  expected $sha256_zip" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  echo "sha256 ok"
else
  echo "warning: sha256sum not found — skipping checksum verification" >&2
fi

# Zip layout: wintun/bin/<arch>/wintun.dll
if command -v unzip >/dev/null 2>&1; then
  unzip -o -j "$tmp/wintun.zip" "wintun/bin/$arch/wintun.dll" -d "$dest" >/dev/null
else
  powershell -NoProfile -Command \
    "Expand-Archive -Force '$tmp\\wintun.zip' '$tmp\\x'; Copy-Item '$tmp\\x\\wintun\\bin\\$arch\\wintun.dll' '$dest\\wintun.dll'"
fi

test -f "$dest/wintun.dll"
echo "  -> $dest/wintun.dll"
