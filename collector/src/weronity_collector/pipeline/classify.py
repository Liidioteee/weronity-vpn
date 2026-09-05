"""Derive the :class:`Classification` block (filters shown in the Node Inspector)."""

from __future__ import annotations

import ipaddress

from ..models import Classification, Geo, ParsedNode

# ASN of well-known CDN / cloud edges — a rough "is this fronted" hint.
_CDN_ASNS = {
    13335,   # Cloudflare
    16509, 14618,  # Amazon (CloudFront / EC2)
    15169,   # Google
    20940, 16625, 12222,  # Akamai
    8075,    # Microsoft
    54113,   # Fastly
    13238,   # Yandex Cloud
    139057, 55990, 396982,  # misc cloud
    24429, 37963, 45102,    # Alibaba
}

_UDP_PROTOCOLS = {"hysteria2", "tuic"}


def classify(node: ParsedNode, geo: Geo) -> Classification:
    ipv6 = False
    if node.endpoint.resolved_ip:
        try:
            ipv6 = ipaddress.ip_address(node.endpoint.resolved_ip).version == 6
        except ValueError:
            ipv6 = False

    udp = node.protocol in _UDP_PROTOCOLS or bool(node.params.get("udp"))

    return Classification(
        sni=node.sni,
        security=node.security,
        flow=node.params.get("flow"),
        cdn=geo.asn in _CDN_ASNS if geo.asn is not None else False,
        ipv6=ipv6,
        udp=udp,
    )
