"""``vmess://<base64-json>`` (WebSocket, TCP, mKCP, gRPC, h2)."""

from __future__ import annotations

import json

from ..models import Endpoint, ParsedNode, Transport
from .common import ParseError, b64decode_any, csv_list, require, split_name

SCHEMES = ("vmess",)

_NET_MAP: dict[str, Transport] = {
    "tcp": "tcp",
    "raw": "tcp",
    "ws": "ws",
    "websocket": "ws",
    "grpc": "grpc",
    "gun": "grpc",
    "h2": "h2",
    "http": "h2",
    "kcp": "mkcp",
    "mkcp": "mkcp",
    "quic": "quic",
    "httpupgrade": "httpupgrade",
}


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("vmess://"), "not a vmess:// uri")
    payload = body[len("vmess://") :]
    try:
        obj = json.loads(b64decode_any(payload))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ParseError(f"vmess: bad json payload: {exc}") from exc
    require(isinstance(obj, dict), "vmess: payload is not an object")

    host = str(obj.get("add", "")).strip()
    require(host, "vmess: missing 'add'")
    try:
        port = int(obj["port"])
    except (KeyError, ValueError, TypeError) as exc:
        raise ParseError("vmess: missing/invalid 'port'") from exc
    uuid = str(obj.get("id", "")).strip()
    require(uuid, "vmess: missing 'id'")

    net = str(obj.get("net", "tcp")).lower()
    if net not in _NET_MAP:
        raise ParseError(f"vmess: unknown net {net!r}")
    transport = _NET_MAP[net]

    tls = str(obj.get("tls", "")).lower()
    params: dict[str, object] = {
        "uuid": uuid,
        "alter_id": int(obj.get("aid", 0) or 0),
        "cipher": str(obj.get("scy", "auto") or "auto"),
        "security": "tls" if tls in ("tls", "reality", "xtls") else "none",
        "sni": (str(obj.get("sni") or "") or str(obj.get("host") or "")) or None,
        "alpn": csv_list(str(obj.get("alpn") or "")),
        "fingerprint": str(obj.get("fp") or "") or None,
    }
    if transport in ("ws", "httpupgrade", "h2"):
        params["path"] = str(obj.get("path") or "/")
        params["host_header"] = str(obj.get("host") or "") or None
    elif transport == "grpc":
        params["service_name"] = str(obj.get("path") or obj.get("serviceName") or "")
    elif transport == "tcp" and str(obj.get("type") or "") == "http":
        params["header_type"] = "http"
        params["path"] = str(obj.get("path") or "/")
        params["host_header"] = str(obj.get("host") or "") or None

    display = str(obj.get("ps") or "").strip() or name
    return ParsedNode(
        protocol="vmess",
        transport=transport,
        endpoint=Endpoint(host=host, port=port),
        auth=uuid,
        tag=display or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )
