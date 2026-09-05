"""``hysteria2://auth@host:port?params#name`` (also ``hy2://``); native UDP/QUIC."""

from __future__ import annotations

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

SCHEMES = ("hysteria2", "hy2")


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    scheme, sep, rest = body.partition("://")
    require(sep and scheme in SCHEMES, "not a hysteria2:// uri")
    rest, _, query = rest.partition("?")
    auth, host, port = split_userinfo_host(rest)

    q = flat_qs(query)
    insecure = as_bool(q.get("insecure")) or as_bool(q.get("allowInsecure"))
    params: dict[str, object] = {
        "password": auth,
        "security": "tls",
        "sni": first(q, "sni", "peer", "servername") or None,
        "alpn": csv_list(q.get("alpn")) or ["h3"],
        "allow_insecure": insecure,
        "pin_sha256": first(q, "pinSHA256", "pinsha256") or None,
        "up_mbps": _int(first(q, "up", "upmbps")),
        "down_mbps": _int(first(q, "down", "downmbps")),
        "port_hopping": first(q, "mport") or None,
    }
    obfs = first(q, "obfs").lower()
    if obfs in ("salamander", "salamanderv2"):
        params["obfs"] = "salamander"
        params["obfs_password"] = first(q, "obfs-password", "obfsParam", "obfs_password") or None

    return ParsedNode(
        protocol="hysteria2",
        transport="quic",
        endpoint=Endpoint(host=host, port=port),
        auth=auth,
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )


def _int(value: str) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
