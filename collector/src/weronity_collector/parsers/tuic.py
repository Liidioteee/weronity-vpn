"""``tuic://uuid:password@host:port?params#name`` (v5, QUIC)."""

from __future__ import annotations

from urllib.parse import unquote

from ..models import Endpoint, ParsedNode
from .common import (
    as_bool,
    csv_list,
    first,
    flat_qs,
    require,
    split_name,
    split_userinfo_host,
)

SCHEMES = ("tuic",)


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("tuic://"), "not a tuic:// uri")
    rest = body[len("tuic://") :]
    rest, _, query = rest.partition("?")
    userinfo, host, port = split_userinfo_host(rest)
    require(":" in userinfo, "tuic: expected uuid:password")
    uuid, password = unquote(userinfo).split(":", 1)

    q = flat_qs(query)
    params: dict[str, object] = {
        "uuid": uuid,
        "password": password,
        "security": "tls",
        "sni": first(q, "sni", "peer", "servername") or None,
        "alpn": csv_list(q.get("alpn")) or ["h3"],
        "congestion_control": first(q, "congestion_control", "congestion-control") or "bbr",
        "udp_relay_mode": first(q, "udp_relay_mode", "udp-relay-mode") or "native",
        "allow_insecure": as_bool(q.get("allow_insecure") or q.get("insecure")),
    }
    return ParsedNode(
        protocol="tuic",
        transport="quic",
        endpoint=Endpoint(host=host, port=port),
        auth=f"{uuid}:{password}",
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )
