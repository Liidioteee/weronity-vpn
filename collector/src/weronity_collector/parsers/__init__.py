"""URI-scheme parsers. Each module exposes ``SCHEMES`` and ``parse(uri) -> ParsedNode``."""

from __future__ import annotations

from collections.abc import Callable

from ..models import ParsedNode
from . import hysteria2, shadowsocks, shadowtls, trojan, tuic, vless, vmess
from .common import ParseError

_MODULES = (vless, vmess, trojan, hysteria2, shadowsocks, tuic, shadowtls)

REGISTRY: dict[str, Callable[[str], ParsedNode]] = {
    scheme: mod.parse for mod in _MODULES for scheme in mod.SCHEMES
}

SUPPORTED_SCHEMES = frozenset(REGISTRY)

__all__ = ["ParseError", "REGISTRY", "SUPPORTED_SCHEMES", "parse_uri", "iter_uris"]


def scheme_of(uri: str) -> str | None:
    head, sep, _ = uri.partition("://")
    return head.lower().strip() if sep else None


def parse_uri(uri: str) -> ParsedNode:
    """Parse a single proxy URI. Raises :class:`ParseError` if unsupported/invalid."""
    scheme = scheme_of(uri)
    if scheme is None:
        raise ParseError(f"no scheme in {uri[:40]!r}")
    fn = REGISTRY.get(scheme)
    if fn is None:
        raise ParseError(f"unsupported scheme {scheme!r}")
    return fn(uri.strip())


def iter_uris(text: str) -> list[str]:
    """Extract candidate proxy URIs from a blob of text (skips ``#`` comments)."""
    out: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        if scheme_of(line) in SUPPORTED_SCHEMES:
            out.append(line)
    return out
