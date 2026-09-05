"""Resolve host → IP and look up country + ASN.

Reads local ``.mmdb`` files from a ``geoip/`` directory. Both record layouts are
accepted:

* MaxMind / GeoLite2 style — ``{"country": {"iso_code": "US", "names": {...}}}``
* ip-location-db style      — ``{"country_code": "US"}`` (flat, no names)

ASN db uses the GeoLite2-ASN layout (``autonomous_system_number`` /
``autonomous_system_organization``). If a database is missing the corresponding
fields are left ``None`` with a warning — the pipeline still runs (offline dev,
tests).
"""

from __future__ import annotations

import ipaddress
import logging
import socket
from pathlib import Path
from typing import Any, cast

import maxminddb

from ..models import Geo

log = logging.getLogger(__name__)

_COUNTRY_NAMES = "dbip-country-lite.mmdb", "GeoLite2-Country.mmdb", "dbip-city-lite.mmdb"
_ASN_NAMES = "dbip-asn-lite.mmdb", "GeoLite2-ASN.mmdb"


def _flag(iso2: str) -> str:
    if len(iso2) != 2 or not iso2.isalpha():
        return ""
    return chr(0x1F1E6 + ord(iso2[0].upper()) - 65) + chr(0x1F1E6 + ord(iso2[1].upper()) - 65)


class GeoResolver:
    def __init__(self, geoip_dir: str | Path = "geoip") -> None:
        d = Path(geoip_dir)
        self._country = self._open(d, _COUNTRY_NAMES, "country")
        self._asn = self._open(d, _ASN_NAMES, "ASN")
        self._dns_cache: dict[str, str | None] = {}

    @staticmethod
    def _open(d: Path, names: tuple[str, ...], label: str) -> maxminddb.Reader | None:
        for name in names:
            p = d / name
            if p.is_file():
                return maxminddb.open_database(str(p))
        log.warning("geoip: no %s database in %s (fields will be null)", label, d)
        return None

    def resolve_ip(self, host: str) -> str | None:
        try:
            ipaddress.ip_address(host)
            return host
        except ValueError:
            pass
        if host in self._dns_cache:
            return self._dns_cache[host]
        ip: str | None = None
        try:
            info = socket.getaddrinfo(host, None)
            for family, _, _, _, sockaddr in info:
                if family == socket.AF_INET:
                    ip = str(sockaddr[0])
                    break
            if ip is None and info:
                ip = str(info[0][4][0])
        except (socket.gaierror, OSError, IndexError):
            ip = None
        self._dns_cache[host] = ip
        return ip

    def lookup(self, host: str) -> Geo:
        ip = self.resolve_ip(host)
        geo = Geo()
        if not ip:
            return geo
        if self._country is not None:
            rec = cast("dict[str, Any]", self._country.get(ip) or {})
            country = cast("dict[str, Any]", rec.get("country") or {})
            registered = cast("dict[str, Any]", rec.get("registered_country") or {})
            iso = (
                rec.get("country_code")
                or country.get("iso_code")
                or registered.get("iso_code")
            )
            if isinstance(iso, str) and iso:
                geo.country = iso.upper()
                geo.flag = _flag(iso)
                names = cast("dict[str, Any]", country.get("names") or {})
                # ip-location-db has no names; the client localises from ISO2.
                geo.country_name = names.get("en")
            city = cast("dict[str, Any]", rec.get("city") or {})
            city_names = cast("dict[str, Any]", city.get("names") or {})
            geo.city = city_names.get("en")
        if self._asn is not None:
            arec = cast("dict[str, Any]", self._asn.get(ip) or {})
            asn = arec.get("autonomous_system_number")
            if asn is not None:
                geo.asn = int(asn)
                geo.as_org = arec.get("autonomous_system_organization")
        return geo

    def close(self) -> None:
        for r in (self._country, self._asn):
            if r is not None:
                r.close()
