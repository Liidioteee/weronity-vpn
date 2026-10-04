#!/usr/bin/env python3
"""Download GeoIP MMDB databases into ``geoip/``.

    python scripts/fetch_geoip.py [--dir geoip]

Source: the sapics/ip-location-db project, served from the jsDelivr CDN — no API
token, MaxMind-compatible record layout.

The country database is **DB-IP Lite** (``dbip-country``): it says where an
address *is*. The registry-based ``geo-whois-asn-country`` set used before says
where the block was *registered*, which is wrong for most hosting ranges — a US
company's servers in Amsterdam came out as "US", and that label is what the
client shows as the node's country.

Licensing: DB-IP Lite is CC BY 4.0 — attribution is required wherever the data
or anything derived from it (the pool) is distributed: "IP Geolocation by DB-IP"
(https://db-ip.com). ASN data derives from the RouteViews/whois dataset.
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

CDN = "https://cdn.jsdelivr.net/npm/@ip-location-db"
DATASETS = {
    # local filename : CDN path
    "dbip-country-lite.mmdb": "dbip-country-mmdb/dbip-country.mmdb",
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
