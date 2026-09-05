"""Generate a sing-box ``outbound`` object from a :class:`ParsedNode`.

Reference: https://sing-box.sagernet.org/configuration/outbound/
The generated dict is embedded verbatim in ``nodes_pool.json`` (decision 1 in
``docs/pool-schema.md``); the client can also regenerate it from ``raw_uri``.
"""

from __future__ import annotations

from typing import Any

from .models import ParsedNode


def _tls_block(node: ParsedNode) -> dict[str, Any] | None:
    p = node.params
    sec = node.security
    if sec == "none" and node.protocol not in ("hysteria2", "tuic"):
        return None
    tls: dict[str, Any] = {"enabled": True}
    sni = p.get("sni")
    if sni:
        tls["server_name"] = sni
    if p.get("allow_insecure"):
        tls["insecure"] = True
    alpn = p.get("alpn")
    if alpn:
        tls["alpn"] = list(alpn)
    fp = p.get("fingerprint")
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if sec == "reality":
        reality: dict[str, Any] = {"enabled": True, "public_key": p.get("public_key", "")}
        if p.get("short_id"):
            reality["short_id"] = p["short_id"]
        tls["reality"] = reality
        tls.setdefault("utls", {"enabled": True, "fingerprint": fp or "chrome"})
    return tls


def _transport_block(node: ParsedNode) -> dict[str, Any] | None:
    p = node.params
    t = node.transport
    if t == "ws":
        block: dict[str, Any] = {"type": "ws", "path": p.get("path", "/")}
        if p.get("host_header"):
            block["headers"] = {"Host": p["host_header"]}
        return block
    if t == "grpc":
        return {"type": "grpc", "service_name": p.get("service_name", "")}
    if t == "httpupgrade":
        block = {"type": "httpupgrade", "path": p.get("path", "/")}
        if p.get("host_header"):
            block["host"] = p["host_header"]
        return block
    if t == "h2":
        block = {"type": "http", "path": p.get("path", "/")}
        if p.get("host_header"):
            block["host"] = [p["host_header"]]
        return block
    return None


def _base(node: ParsedNode) -> dict[str, Any]:
    return {"tag": node.tag, "server": node.endpoint.host, "server_port": node.endpoint.port}


def build_outbound(node: ParsedNode) -> dict[str, Any]:
    p = node.params
    ob = _base(node)

    if node.protocol == "vless":
        ob["type"] = "vless"
        ob["uuid"] = p["uuid"]
        if p.get("flow"):
            ob["flow"] = p["flow"]
        ob["packet_encoding"] = "xudp"
    elif node.protocol == "vmess":
        ob["type"] = "vmess"
        ob["uuid"] = p["uuid"]
        ob["alter_id"] = int(p.get("alter_id", 0))
        ob["security"] = p.get("cipher", "auto")
    elif node.protocol == "trojan":
        ob["type"] = "trojan"
        ob["password"] = p["password"]
    elif node.protocol == "shadowsocks":
        ob["type"] = "shadowsocks"
        ob["method"] = p["method"]
        ob["password"] = p["password"]
        if p.get("plugin"):
            ob["plugin"] = p["plugin"]
            ob["plugin_opts"] = p.get("plugin_opts", "")
    elif node.protocol == "hysteria2":
        ob["type"] = "hysteria2"
        ob["password"] = p["password"]
        if p.get("up_mbps"):
            ob["up_mbps"] = int(p["up_mbps"])
        if p.get("down_mbps"):
            ob["down_mbps"] = int(p["down_mbps"])
        if p.get("obfs") == "salamander":
            ob["obfs"] = {"type": "salamander", "password": p.get("obfs_password", "")}
    elif node.protocol == "tuic":
        ob["type"] = "tuic"
        ob["uuid"] = p["uuid"]
        ob["password"] = p["password"]
        ob["congestion_control"] = p.get("congestion_control", "bbr")
        ob["udp_relay_mode"] = p.get("udp_relay_mode", "native")
    elif node.protocol == "shadowtls":
        ob["type"] = "shadowtls"
        ob["version"] = int(p.get("version", 3))
        ob["password"] = p.get("password", "")
    else:  # pragma: no cover - Protocol literal is exhaustive
        raise ValueError(f"no outbound builder for {node.protocol!r}")

    tls = _tls_block(node)
    if tls is not None:
        ob["tls"] = tls
    transport = _transport_block(node)
    if transport is not None:
        ob["transport"] = transport
    return ob
