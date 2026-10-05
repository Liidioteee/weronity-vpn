"""Decode a Clash / Clash.Meta / mihomo YAML config into :class:`ParsedNode` objects.

Only the ``proxies:`` list is read; ``proxy-groups`` and ``rules`` are ignored.
"""

from __future__ import annotations

from typing import Any

import yaml

from ..models import Endpoint, ParsedNode, Protocol, Transport
from .common import ParseError, as_int

_TYPE_MAP: dict[str, Protocol] = {
    "vless": "vless",
    "vmess": "vmess",
    "trojan": "trojan",
    "ss": "shadowsocks",
    "shadowsocks": "shadowsocks",
    "hysteria2": "hysteria2",
    "hy2": "hysteria2",
    "tuic": "tuic",
}
_NET_MAP: dict[str, Transport] = {
    "": "tcp",
    "tcp": "tcp",
    "ws": "ws",
    "grpc": "grpc",
    "h2": "h2",
    "http": "h2",
    "httpupgrade": "httpupgrade",
}


def _as_dict(v: Any) -> dict[str, Any]:
    """Option blocks (``ws-opts``…) are dicts in a well-formed config; anything else → empty."""
    return v if isinstance(v, dict) else {}


def _as_list(v: Any) -> list[str]:
    if v is None:
        return []
    if isinstance(v, str):
        return [v]
    return [str(x) for x in v]


def _one(px: dict[str, Any]) -> ParsedNode:
    ptype = str(px.get("type", "")).lower()
    if ptype not in _TYPE_MAP:
        raise ParseError(f"clash: unsupported proxy type {ptype!r}")
    protocol = _TYPE_MAP[ptype]

    server = str(px.get("server", "")).strip()
    if not server:
        raise ParseError("clash: proxy without server")
    try:
        port = int(px["port"])
    except (KeyError, ValueError, TypeError) as exc:
        raise ParseError("clash: proxy without valid port") from exc
    if not 1 <= port <= 65535:
        raise ParseError(f"clash: port {port} out of range")
    name = str(px.get("name") or f"{server}:{port}")

    network: Transport = _NET_MAP.get(str(px.get("network", "tcp")).lower(), "tcp")
    if protocol in ("hysteria2", "tuic"):
        network = "quic"

    tls_on = bool(px.get("tls")) or protocol in ("hysteria2", "tuic", "trojan")
    reality = _as_dict(px.get("reality-opts"))
    params: dict[str, Any] = {
        "security": "reality" if reality else ("tls" if tls_on else "none"),
        "sni": px.get("sni") or px.get("servername") or None,
        "alpn": _as_list(px.get("alpn")),
        "fingerprint": px.get("client-fingerprint") or None,
        "allow_insecure": bool(px.get("skip-cert-verify")),
    }
    if reality:
        params["public_key"] = reality.get("public-key", "")
        params["short_id"] = reality.get("short-id", "")

    if network == "ws":
        wopts = _as_dict(px.get("ws-opts"))
        params["path"] = wopts.get("path", "/")
        headers = _as_dict(wopts.get("headers"))
        params["host_header"] = headers.get("Host") or headers.get("host") or None
    elif network == "grpc":
        gopts = _as_dict(px.get("grpc-opts"))
        params["service_name"] = gopts.get("grpc-service-name", "")

    if protocol == "vless":
        auth = str(px.get("uuid", ""))
        params["uuid"] = auth
        if px.get("flow"):
            params["flow"] = px["flow"]
    elif protocol == "vmess":
        auth = str(px.get("uuid", ""))
        params["uuid"] = auth
        params["alter_id"] = as_int(px.get("alterId", px.get("alter-id", 0)))
        params["cipher"] = str(px.get("cipher", "auto") or "auto")
    elif protocol == "trojan":
        auth = str(px.get("password", ""))
        params["password"] = auth
    elif protocol == "shadowsocks":
        method = str(px.get("cipher", ""))
        password = str(px.get("password", ""))
        params["method"] = method
        params["password"] = password
        auth = f"{method}:{password}"
    elif protocol == "hysteria2":
        auth = str(px.get("password", ""))
        params["password"] = auth
        if px.get("obfs") == "salamander" or px.get("obfs"):
            params["obfs"] = "salamander"
            params["obfs_password"] = px.get("obfs-password") or px.get("obfs-param")
        params["up_mbps"] = _int(px.get("up"))
        params["down_mbps"] = _int(px.get("down"))
    elif protocol == "tuic":
        uuid = str(px.get("uuid", ""))
        password = str(px.get("password", ""))
        params["uuid"] = uuid
        params["password"] = password
        params["congestion_control"] = px.get("congestion-controller", "bbr")
        params["udp_relay_mode"] = px.get("udp-relay-mode", "native")
        auth = f"{uuid}:{password}"
    else:  # pragma: no cover
        raise ParseError(f"clash: no mapping for {protocol!r}")

    clean = {k: v for k, v in params.items() if v not in (None, [], "")}
    return ParsedNode(
        protocol=protocol,
        transport=network,
        endpoint=Endpoint(host=server, port=port),
        auth=auth,
        tag=name,
        raw_uri=f"clash://{protocol}/{server}:{port}",
        params=clean,
    )


def parse_clash(text: str) -> list[ParsedNode]:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ParseError(f"clash: invalid YAML: {exc}") from exc
    if not isinstance(doc, dict) or "proxies" not in doc:
        raise ParseError("clash: no 'proxies' key")
    out: list[ParsedNode] = []
    for px in doc.get("proxies") or []:
        if not isinstance(px, dict):
            continue
        try:
            out.append(_one(px))
        except Exception:  # noqa: BLE001 - one malformed proxy must not drop the file
            continue
    return out


def _int(value: Any) -> int | None:
    try:
        return int(str(value).rstrip(" Mbps").strip())
    except (TypeError, ValueError):
        return None
