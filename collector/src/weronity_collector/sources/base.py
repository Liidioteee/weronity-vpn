"""Source abstraction. A source yields :class:`RawDocument` blobs; the harvester
turns those into :class:`~weronity_collector.models.ParsedNode` objects.
"""

from __future__ import annotations

import base64
import binascii
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable

DocKind = Literal["uri_list", "clash", "base64", "json", "unknown"]


@dataclass(slots=True)
class RawDocument:
    source: str          # e.g. "github:igareck/vpn-configs-for-russia"
    source_file: str     # path within the source
    content: str
    kind: DocKind = "unknown"

    def detect_kind(self) -> DocKind:
        text = self.content.strip()
        if not text:
            return "unknown"
        low = self.source_file.lower()
        if low.endswith((".yaml", ".yml")) and "proxies:" in text:
            return "clash"
        if "proxies:" in text[:2000] and ("server:" in text or "type:" in text):
            return "clash"
        if any(
            s in text
            for s in ("vless://", "vmess://", "trojan://", "hysteria2://", "hy2://", "ss://", "tuic://")
        ):
            return "uri_list"
        if _looks_base64(text):
            return "base64"
        return "unknown"


def _looks_base64(text: str) -> bool:
    sample = "".join(text.split())
    if len(sample) < 24:
        return False
    try:
        decoded = base64.b64decode(sample + "=" * (-len(sample) % 4), validate=True)
    except (binascii.Error, ValueError):
        return False
    try:
        decoded.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return "://" in decoded.decode("utf-8", "replace")


@runtime_checkable
class Source(Protocol):
    name: str

    def fetch(self) -> Iterable[RawDocument]:
        """Return raw documents. Network errors should raise; empty is allowed."""
        ...
