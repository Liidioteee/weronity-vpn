#!/usr/bin/env python3
"""Download GeoIP MMDB databases into ``geoip/``.

    python scripts/fetch_geoip.py [--dir geoip]

Source: the sapics/ip-location-db project, served from the jsDelivr CDN — no API
token, MaxMind-compatible record layout, permissive licensing (country data is
PDDL / CC0-style; ASN data derives from the RouteViews/whois dataset). Attribution
for the derived pool: "IP geolocation by DB-IP / ip-location-db (sapics)".
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

CDN = "https://cdn.jsdelivr.net/npm/@ip-location-db"
DATASETS = {
    # local filename : CDN path
    "dbip-country-lite.mmdb": "geo-whois-asn-country-mmdb/geo-whois-asn-country.mmdb",
    "dbip-asn-lite.mmdb": "asn-mmdb/asn.mmdb",
}
_UA = "weronity-collector fetch_geoip"


def fetch(url: str, out: Path) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": _UA})  # noqa: S310 - fixed https host
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:  # noqa: S310
            data = resp.read()
    except Exception as exc:  # noqa: BLE001 - report and fail the dataset
        print(f"  {url} -> {exc}", file=sys.stderr)
        return False
    out.write_bytes(data)
    print(f"  {out.name}: {len(data) // 1024} KiB")
    return True


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=Path("geoip"))
    args = ap.parse_args(argv)
    args.dir.mkdir(parents=True, exist_ok=True)

    ok = True
    for filename, cdn_path in DATASETS.items():
        if not fetch(f"{CDN}/{cdn_path}", args.dir / filename):
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
