"""Deduplicate parsed nodes by ``host:port + auth + transport + sni`` (decision 3)."""

from __future__ import annotations

from dataclasses import dataclass, field

from ..models import ParsedNode


@dataclass(slots=True)
class DedupResult:
    nodes: list[ParsedNode]
    duplicates_removed: int = 0
    occurrences: dict[str, int] = field(default_factory=dict)  # stable_id -> count


def dedup(nodes: list[ParsedNode]) -> DedupResult:
    seen: dict[str, ParsedNode] = {}
    occ: dict[str, int] = {}
    dupes = 0
    for node in nodes:
        key = node.dedup_key()
        sid = node.stable_id()
        occ[sid] = occ.get(sid, 0) + 1
        if key in seen:
            dupes += 1
            continue
        seen[key] = node
    return DedupResult(nodes=list(seen.values()), duplicates_removed=dupes, occurrences=occ)
