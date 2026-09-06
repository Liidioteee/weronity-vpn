#!/usr/bin/env python3
"""Pack an IPv4 -> ISO-3166 country table into a compact binary asset.

    python app/tool/build_geoip.py

Downloads the country ranges from the sapics/ip-location-db project (jsDelivr
CDN, no token, PDDL / CC0-style licensing), coalesces adjacent same-country
ranges, and writes:

    app/assets/geoip/ipv4_country.v1.bin

Layout (all little-endian):
    magic     4 bytes   b"WGI2"
    n_cc      uint16    number of country codes in the table
    cc_table  n_cc x 2  ISO-3166 alpha-2, ASCII, index 0 is reserved = unknown
    count     uint32    number of records
    records   count x (uint32 start_ip, uint16 cc_index)
              sorted by start_ip, no gaps: a record's range runs to the next
              record's start_ip - 1 (last runs to 0xFFFFFFFF). Unallocated space
              is represented explicitly with cc_index 0.

Lookup: binary-search the last record whose start_ip <= ip; cc_index 0 -> None.
Offline, deterministic, ~2 MB.

Attribution for anything derived from this asset:
    "IP geolocation by DB-IP / ip-location-db (sapics)"
"""

from __future__ import annotations

import struct
import sys
import urllib.request
from pathlib import Path

SRC = (
    "https://cdn.jsdelivr.net/npm/@ip-location-db/"
    "geo-whois-asn-country/geo-whois-asn-country-ipv4-num.csv"
)
OUT = Path(__file__).resolve().parents[1] / "assets" / "geoip" / "ipv4_country.v2.bin"
_UA = "weronity build_geoip"


def main() -> int:
    print(f"downloading {SRC}")
    req = urllib.request.Request(SRC, headers={"User-Agent": _UA})  # noqa: S310
    with urllib.request.urlopen(req, timeout=120) as resp:  # noqa: S310
        text = resp.read().decode("utf-8", "replace")

    rows: list[tuple[int, int, str]] = []
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) != 3:
            continue
        start_s, end_s, cc = (p.strip() for p in parts)
        cc = cc.upper()
        if len(cc) != 2 or not cc.isascii() or not cc.isalpha():
            continue
        try:
            start, end = int(start_s), int(end_s)
        except ValueError:
            continue
        if start < 0 or end > 0xFFFFFFFF or end < start:
            continue
        rows.append((start, end, cc))

    rows.sort(key=lambda r: r[0])

    # Country-code table: index 0 reserved for "unknown".
    cc_index: dict[str, int] = {"": 0}
    for _s, _e, cc in rows:
        cc_index.setdefault(cc, len(cc_index))
    if len(cc_index) > 0xFFFF:
        print("too many country codes", file=sys.stderr)
        return 1

    # Flatten to gap-free (start_ip, cc_index) records. Explicit "unknown"
    # records fill holes between source ranges and before the first / nothing
    # after the last (the last record implicitly runs to 0xFFFFFFFF).
    recs: list[tuple[int, int]] = []
    cursor = 0
    for start, end, cc in rows:
        if start > cursor:
            recs.append((cursor, 0))  # unallocated hole
        # overlapping / out-of-order guard: never move the cursor backwards
        s = max(start, cursor)
        if s > end:
            continue
        recs.append((s, cc_index[cc]))
        cursor = end + 1
    if cursor <= 0xFFFFFFFF:
        recs.append((cursor, 0))

    # Drop consecutive records with the same country (keep it minimal).
    dedup: list[tuple[int, int]] = []
    for start, idx in recs:
        if dedup and dedup[-1][1] == idx:
            continue
        dedup.append((start, idx))

    codes = sorted(cc_index, key=cc_index.get)  # type: ignore[arg-type]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("wb") as f:
        f.write(b"WGI2")
        f.write(struct.pack("<H", len(codes)))
        for cc in codes:
            f.write((cc.ljust(2, "\0")[:2]).encode("ascii"))
        f.write(struct.pack("<I", len(dedup)))
        for start, idx in dedup:
            f.write(struct.pack("<IH", start, idx))

    size = OUT.stat().st_size
    print(
        f"{len(rows)} source ranges, {len(codes) - 1} countries -> "
        f"{len(dedup)} records -> {OUT.relative_to(OUT.parents[2])}  "
        f"({size / 1024:.0f} KiB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
