"""``vless://uuid@host:port?params#name`` (Reality/XTLS, WS, gRPC, HTTPUpgrade, TCP)."""

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

SCHEMES = ("vless",)

_NET_MAP: dict[str, Transport] = {
    "tcp": "tcp",
    "raw": "tcp",
    "ws": "ws",
    "websocket": "ws",
    "grpc": "grpc",
    "gun": "grpc",
    "http": "h2",
    "h2": "h2",
    "h2mux": "h2",
    "httpupgrade": "httpupgrade",
    "xhttp": "httpupgrade",
    "splithttp": "httpupgrade",
    "kcp": "mkcp",
    "mkcp": "mkcp",
    "quic": "quic",
}


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("vless://"), "not a vless:// uri")
    rest = body[len("vless://") :]
    rest, _, query = rest.partition("?")
    uuid, host, port = split_userinfo_host(rest)
    require(uuid, "vless: empty uuid")

    q = flat_qs(query)
    net = q.get("type", "tcp").lower()
    if net not in _NET_MAP:
        raise ParseError(f"vless: unknown network type {net!r}")
    transport = _NET_MAP[net]

    security = (q.get("security") or "none").lower()
    params: dict[str, object] = {
        "uuid": uuid,
        "encryption": q.get("encryption", "none"),
        "security": security,
        "flow": first(q, "flow") or None,
        "sni": first(q, "sni", "peer", "servername") or None,
        "alpn": csv_list(q.get("alpn")),
        "fingerprint": first(q, "fp") or None,
        "allow_insecure": as_bool(q.get("allowInsecure") or q.get("insecure")),
    }
    if security == "reality":
        params["public_key"] = first(q, "pbk")
        params["short_id"] = first(q, "sid")
        require(params["public_key"], "vless reality: missing pbk")

    if transport == "ws" or transport == "httpupgrade":
        params["path"] = first(q, "path", default="/")
        params["host_header"] = first(q, "host") or None
    elif transport == "grpc":
        params["service_name"] = first(q, "serviceName", "servicename")
    elif transport == "h2":
        params["path"] = first(q, "path", default="/")
        params["host_header"] = first(q, "host") or None
    elif transport == "tcp" and q.get("headerType") == "http":
        params["header_type"] = "http"
        params["path"] = first(q, "path", default="/")
        params["host_header"] = first(q, "host") or None

    return ParsedNode(
        protocol="vless",
        transport=transport,
        endpoint=Endpoint(host=host, port=port),
        auth=uuid,
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )
