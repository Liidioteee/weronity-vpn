"""``trojan://password@host:port?params#name`` (TLS, gRPC, WebSocket)."""

from __future__ import annotations

from ..models import Endpoint, ParsedNode, Transport
from .common import (
    ParseError,
    as_bool,
    csv_list,
    first,
    flat_qs,
    require,
    split_name,
    split_userinfo_host,
)

SCHEMES = ("trojan",)

_NET_MAP: dict[str, Transport] = {
    "": "tcp",
    "tcp": "tcp",
    "raw": "tcp",
    "original": "tcp",
    "ws": "ws",
    "websocket": "ws",
    "grpc": "grpc",
    "gun": "grpc",
    "http": "h2",
    "h2": "h2",
    "httpupgrade": "httpupgrade",
}


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("trojan://"), "not a trojan:// uri")
    rest = body[len("trojan://") :]
    rest, _, query = rest.partition("?")
    password, host, port = split_userinfo_host(rest)
    require(password, "trojan: empty password")

    q = flat_qs(query)
    net = (q.get("type") or "tcp").lower()
    if net not in _NET_MAP:
        raise ParseError(f"trojan: unknown network type {net!r}")
    transport = _NET_MAP[net]

    params: dict[str, object] = {
        "password": password,
        "security": (q.get("security") or "tls").lower(),
        "sni": first(q, "sni", "peer", "servername") or host,
        "alpn": csv_list(q.get("alpn")),
        "fingerprint": first(q, "fp") or None,
        "allow_insecure": as_bool(q.get("allowInsecure") or q.get("insecure")),
    }
    if transport in ("ws", "httpupgrade", "h2"):
        params["path"] = first(q, "path", default="/")
        params["host_header"] = first(q, "host") or None
    elif transport == "grpc":
        params["service_name"] = first(q, "serviceName", "servicename")

    return ParsedNode(
        protocol="trojan",
        transport=transport,
        endpoint=Endpoint(host=host, port=port),
        auth=password,
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )
