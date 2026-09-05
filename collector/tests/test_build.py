from __future__ import annotations

from datetime import UTC, datetime

import pytest

from weronity_collector.harvest import harvest
from weronity_collector.pipeline import build as build_mod
from weronity_collector.pipeline.ping import PingResult
from weronity_collector.schema import validate_pool
from weronity_collector.sources.base import RawDocument


@pytest.fixture
def parsed_nodes(uris_text: str):
    d = RawDocument(source="github:test", source_file="uris.txt", content=uris_text)
    d.kind = d.detect_kind()
    nodes, _ = harvest([d])
    return nodes


async def _fake_ping(targets, *, timeout_ms=2000, concurrency=64):
    # first target dead, rest alive with increasing latency
    out = []
    for i, _ in enumerate(targets):
        if i == 0:
            out.append(PingResult(tcp_ok=False, tls_ok=False, ping_ms=None))
        else:
            out.append(PingResult(tcp_ok=True, tls_ok=True, ping_ms=50 + i * 10))
    return out


async def test_build_pool_end_to_end(parsed_nodes, tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _fake_ping)
    now = datetime(2026, 9, 5, 12, 0, tzinfo=UTC)

    pool = await build_mod.build_pool(
        parsed_nodes,
        geoip_dir=tmp_path / "no-geoip",
        seen_path=tmp_path / "seen.json",
        source_run="run-1",
        now=now,
    )

    validate_pool(pool.model_dump(by_alias=True))  # must not raise
    assert pool.schema_version == 1
    assert pool.source_run == "run-1"
    # 10 parsed → 10 unique → 1 dropped as dead → 9 published
    assert pool.stats.total == 9
    assert len(pool.nodes) == 9
    assert sum(pool.stats.by_protocol.values()) == 9
    assert all(n.lifetime.class_ == "fresh" for n in pool.nodes)
    assert all(n.outbound["server"] == n.endpoint.host for n in pool.nodes)
    assert (tmp_path / "seen.json").is_file()


async def test_build_pool_marks_recommended(parsed_nodes, tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _fake_ping)
    pool = await build_mod.build_pool(
        parsed_nodes,
        geoip_dir=tmp_path / "x",
        seen_path=tmp_path / "seen.json",
        recommend_per_country=1,
        now=datetime(2026, 9, 5, tzinfo=UTC),
    )
    # no geoip → every node country is None → single "??" bucket → 1 recommended
    assert sum(1 for n in pool.nodes if n.recommended) == 1


async def test_build_pool_keep_dead(parsed_nodes, tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _fake_ping)
    pool = await build_mod.build_pool(
        parsed_nodes,
        geoip_dir=tmp_path / "x",
        seen_path=tmp_path / "seen.json",
        keep_dead=True,
        now=datetime(2026, 9, 5, tzinfo=UTC),
    )
    assert pool.stats.total == 10


async def test_build_pool_stability_grows_across_runs(parsed_nodes, tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _fake_ping)
    seen = tmp_path / "seen.json"
    kw = {"geoip_dir": tmp_path / "x", "seen_path": seen}
    p1 = await build_mod.build_pool(parsed_nodes, now=datetime(2026, 9, 1, tzinfo=UTC), **kw)
    p2 = await build_mod.build_pool(parsed_nodes, now=datetime(2026, 9, 2, tzinfo=UTC), **kw)
    assert p1.nodes[0].lifetime.stability == 1.0
    assert p2.nodes[0].lifetime.seen_runs == 2
    assert p2.nodes[0].lifetime.stability == 1.0
