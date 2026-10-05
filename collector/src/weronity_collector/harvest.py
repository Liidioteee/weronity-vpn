"""Turn :class:`RawDocument` blobs into :class:`ParsedNode` objects.

Dispatch by ``RawDocument.kind``:

* ``uri_list``  → extract proxy URIs line-by-line, parse each
* ``base64``    → base64-decode the whole blob, then treat as ``uri_list``
* ``clash``     → parse the YAML ``proxies:`` list
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from dataclasses import dataclass

from .models import ParsedNode
from .parsers import ParseError, iter_uris, parse_uri
from .parsers.clash import parse_clash
from .parsers.common import b64decode_any
from .sources.base import RawDocument

log = logging.getLogger(__name__)


@dataclass(slots=True)
class HarvestStats:
    documents: int = 0
    parsed: int = 0
    failed: int = 0


def harvest(docs: Iterator[RawDocument] | list[RawDocument]) -> tuple[list[ParsedNode], HarvestStats]:
    stats = HarvestStats()
    nodes: list[ParsedNode] = []
    for doc in docs:
        stats.documents += 1
        kind = doc.kind if doc.kind != "unknown" else doc.detect_kind()
        text = doc.content
        if kind == "base64":
            try:
                text = b64decode_any(text).decode("utf-8", "replace")
            except ParseError:
                continue
            kind = "uri_list"

        # The source is a third-party repo: anything in it can be malformed. A
        # parser bug or an unexpected shape costs that one entry (or that one
        # file), never the whole run — hence the deliberately broad excepts.
        if kind == "clash":
            try:
                clash_nodes = parse_clash(text)
            except Exception as exc:  # noqa: BLE001
                log.warning("skipping %s: %s", doc.source_file, exc)
                stats.failed += 1
                continue
            for node in clash_nodes:
                node.source, node.source_file = doc.source, doc.source_file
                nodes.append(node)
                stats.parsed += 1
            continue

        if kind == "uri_list":
            for uri in iter_uris(text):
                try:
                    node = parse_uri(uri)
                except ParseError:
                    stats.failed += 1
                    continue
                except Exception as exc:  # noqa: BLE001
                    log.debug("unexpected %s parsing %r", type(exc).__name__, uri[:60])
                    stats.failed += 1
                    continue
                node.source, node.source_file = doc.source, doc.source_file
                nodes.append(node)
                stats.parsed += 1
    return nodes, stats
