"""Shared helpers for URI parsers."""

from __future__ import annotations

import base64
import binascii
from urllib.parse import parse_qs, unquote, urlsplit


class ParseError(ValueError):
    """Raised when a URI cannot be parsed into a node."""


def b64decode_any(data: str) -> bytes:
    """Decode base64 that may be URL-safe and/or unpadded."""
    s = data.strip().replace("\n", "").replace("\r", "")
    s = s.replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s, validate=False)
    except (binascii.Error, ValueError) as exc:  # pragma: no cover - defensive
        raise ParseError(f"bad base64: {exc}") from exc


def split_name(uri: str) -> tuple[str, str]:
    """Return ``(uri_without_fragment, display_name)`` with the name URL-decoded."""
    if "#" in uri:
        body, frag = uri.split("#", 1)
        return body, unquote(frag).strip()
    return uri, ""


def flat_qs(query: str) -> dict[str, str]:
    """Parse a query string, keeping the last value for repeated keys."""
    return {k: v[-1] for k, v in parse_qs(query, keep_blank_values=True).items()}


def require(cond: object, msg: str) -> None:
    if not cond:
        raise ParseError(msg)


def split_userinfo_host(rest: str) -> tuple[str, str, int]:
    """Split ``userinfo@host:port`` → ``(userinfo, host, port)``.

    Host may be an IPv6 literal in brackets.
    """
    parts = urlsplit("//" + rest)
    require(parts.hostname, f"no host in {rest!r}")
    require(parts.port, f"no port in {rest!r}")
    userinfo = ""
    if "@" in parts.netloc:
        userinfo = parts.netloc.rsplit("@", 1)[0]
    assert parts.hostname is not None and parts.port is not None
    return unquote(userinfo), parts.hostname, parts.port


def first(d: dict[str, str], *keys: str, default: str = "") -> str:
    for k in keys:
        if k in d and d[k] != "":
            return d[k]
    return default


def as_bool(value: str | None) -> bool:
    return str(value).lower() in ("1", "true", "yes", "on")


def csv_list(value: str | None) -> list[str]:
    if not value:
        return []
    return [x for x in (p.strip() for p in value.split(",")) if x]
