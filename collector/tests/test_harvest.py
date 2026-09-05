from __future__ import annotations

import base64

from weronity_collector.harvest import harvest
from weronity_collector.sources.base import RawDocument


def _doc(name: str, content: str) -> RawDocument:
    d = RawDocument(source="test", source_file=name, content=content)
    d.kind = d.detect_kind()
    return d


def test_harvest_uri_list(uris_text: str) -> None:
    nodes, stats = harvest([_doc("uris.txt", uris_text)])
    assert stats.documents == 1
    assert stats.parsed == len(nodes) == 10
    assert all(n.source == "test" and n.source_file == "uris.txt" for n in nodes)


def test_harvest_base64_blob(uris_text: str) -> None:
    blob = base64.b64encode(uris_text.encode()).decode()
    doc = _doc("sub_base64.txt", blob)
    assert doc.kind == "base64"
    nodes, stats = harvest([doc])
    assert stats.parsed == 10 == len(nodes)


def test_harvest_clash(clash_text: str) -> None:
    doc = _doc("clash.yaml", clash_text)
    assert doc.kind == "clash"
    nodes, _ = harvest([doc])
    assert len(nodes) == 4


def test_harvest_mixed_and_unknown(uris_text: str) -> None:
    nodes, stats = harvest(
        [
            _doc("a.txt", uris_text),
            _doc("empty.txt", "   \n\n"),
            _doc("junk.txt", "the quick brown fox jumps over the lazy dog again"),
        ]
    )
    assert stats.documents == 3
    assert len(nodes) == 10
