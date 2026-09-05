"""``shadowtls://<base64-json>`` — ShadowTLS v2/v3 in front of SS/Trojan.

No cross-client standard exists for a ShadowTLS URI; the common form (used by a
few generators) is base64 of a JSON object::

    {"version":3,"host":"gateway.example.com","port":443,"password":"...",
     "sni":"www.microsoft.com","detour":{...ss/trojan node...}}

ShadowTLS more often arrives via Clash/sing-box config; this parser is a
best-effort fallback for the URI form.
"""

from __future__ import annotations

import json

from ..models import Endpoint, ParsedNode
from .common import ParseError, b64decode_any, require, split_name

SCHEMES = ("shadowtls",)


def parse(uri: str) -> ParsedNode:
    body, name = split_name(uri)
    require(body.startswith("shadowtls://"), "not a shadowtls:// uri")
    try:
        obj = json.loads(b64decode_any(body[len("shadowtls://") :]))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ParseError(f"shadowtls: bad json payload: {exc}") from exc
    require(isinstance(obj, dict), "shadowtls: payload not an object")

    host = str(obj.get("host") or obj.get("server") or "").strip()
    require(host, "shadowtls: missing host")
    try:
        port = int(obj["port"])
    except (KeyError, ValueError, TypeError) as exc:
        raise ParseError("shadowtls: missing/invalid port") from exc

    password = str(obj.get("password") or "")
    version = int(obj.get("version", 3) or 3)
    params: dict[str, object] = {
        "password": password,
        "version": version,
        "security": "shadowtls",
        "sni": str(obj.get("sni") or obj.get("servername") or "") or None,
        "detour": obj.get("detour") or obj.get("outbound") or None,
    }
    return ParsedNode(
        protocol="shadowtls",
        transport="tcp",
        endpoint=Endpoint(host=host, port=port),
        auth=f"{password}:v{version}",
        tag=name or f"{host}:{port}",
        raw_uri=uri.strip(),
        params={k: v for k, v in params.items() if v not in (None, [], "")},
    )
