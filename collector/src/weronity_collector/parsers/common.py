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
    # urlsplit() and .port raise a bare ValueError on a bad IPv6 literal or an
    # out-of-range / non-numeric port; a scraped list is full of those.
    try:
        parts = urlsplit("//" + rest)
        hostname, port = parts.hostname, parts.port
    except ValueError as exc:
        raise ParseError(f"bad authority {rest!r}: {exc}") from exc
    require(hostname, f"no host in {rest!r}")
    require(port, f"no port in {rest!r}")
    userinfo = ""
    if "@" in parts.netloc:
        userinfo = parts.netloc.rsplit("@", 1)[0]
    assert hostname is not None and port is not None
    return unquote(userinfo), hostname, port


def first(d: dict[str, str], *keys: str, default: str = "") -> str:
    for k in keys:
        if k in d and d[k] != "":
            return d[k]
    return default


def as_bool(value: str | None) -> bool:
    return str(value).lower() in ("1", "true", "yes", "on")


def as_int(value: object, default: int = 0) -> int:
    """Lenient int: garbage (``"abc"``, ``None``, ``"1.0"``) degrades to ``default``."""
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def csv_list(value: str | None) -> list[str]:
    if not value:
        return []
    return [x for x in (p.strip() for p in value.split(",")) if x]
