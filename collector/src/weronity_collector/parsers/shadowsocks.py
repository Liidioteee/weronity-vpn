"""``ss://`` — SIP002 and legacy forms, incl. 2022-blake3 AEAD ciphers."""

from __future__ import annotations

from urllib.parse import unquote

from ..models import Endpoint, ParsedNode
from .common import ParseError, b64decode_any, flat_qs, require, split_name

SCHEMES = ("ss",)

_KNOWN_METHODS = {
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "chacha20-poly1305",
    "none",
    "plain",
}


def _split_method_pass(userinfo: str) -> tuple[str, str]:
    # SIP002: userinfo is base64(method:password); 2022 spec: percent-encoded
    # method:password (not base64). Try both.
    if ":" in userinfo and userinfo.split(":", 1)[0].lower() in _KNOWN_METHODS:
        method, password = userinfo.split(":", 1)
        return method, password
    try:
        decoded = b64decode_any(userinfo).decode("utf-8", "replace")
    except ParseError:
        decoded = userinfo
    require(":" in decoded, "ss: cannot split method:password")
    method, password = decoded.split(":", 1)
    return method, password


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("ss://"), "not a ss:// uri")
    rest = body[len("ss://") :]

    query = ""
    if "?" in rest:
        rest, _, query = rest.partition("?")

    if "@" in rest:
        userinfo, hostport = rest.rsplit("@", 1)
        method, password = _split_method_pass(unquote(userinfo))
    else:
        # legacy: whole thing is base64(method:password@host:port)
        decoded = b64decode_any(rest).decode("utf-8", "replace")
        require("@" in decoded, "ss legacy: no '@' after decode")
        userinfo, hostport = decoded.rsplit("@", 1)
        require(":" in userinfo, "ss legacy: bad userinfo")
        method, password = userinfo.split(":", 1)

    require(":" in hostport, "ss: missing port")
    host, port_s = hostport.rsplit(":", 1)
    host = host.strip("[]")
    try:
        port = int(port_s)
    except ValueError as exc:
        raise ParseError(f"ss: bad port {port_s!r}") from exc

    q = flat_qs(query)
    params: dict[str, object] = {"method": method, "password": password}
    plugin = q.get("plugin")
    if plugin:
        pin, _, popts = plugin.partition(";")
        params["plugin"] = pin
        params["plugin_opts"] = popts
        if pin in ("shadow-tls", "shadowtls"):
            params["security"] = "shadowtls"

    return ParsedNode(
        protocol="shadowsocks",
        transport="tcp",
        endpoint=Endpoint(host=host, port=port),
        auth=f"{method}:{password}",
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params=params,
    )
