"""Orchestrate: dedup → resolve/geoip → ping → lifetime → classify → Pool."""

from __future__ import annotations

import logging
from collections import Counter, defaultdict
from datetime import UTC, datetime
from pathlib import Path

from .. import GENERATOR
from ..models import Geo, Health, Node, ParsedNode, Pool, PoolStats, Provenance
from ..outbound import build_outbound
from .classify import classify
from .dedup import dedup
from .geoip import GeoResolver
from .lifetime import SeenState
from .ping import PingResult, ping_many

log = logging.getLogger(__name__)


async def build_pool(
    parsed: list[ParsedNode],
    *,
    geoip_dir: str | Path = "geoip",
    seen_path: str | Path = "state/seen.json",
    source_run: str | None = None,
    timeout_ms: int = 2000,
    ping_concurrency: int = 64,
    recommend_per_country: int = 15,
    keep_dead: bool = False,
    now: datetime | None = None,
) -> Pool:
    now = now or datetime.now(UTC)
    dd = dedup(parsed)
    log.info("dedup: %d unique, %d duplicates removed", len(dd.nodes), dd.duplicates_removed)

    geo = GeoResolver(geoip_dir)
    geo_by_host: dict[str, Geo] = {}
    try:
        for node in dd.nodes:
            host = node.endpoint.host
            if host not in geo_by_host:
                geo_by_host[host] = geo.lookup(host)
                node.endpoint.resolved_ip = geo.resolve_ip(host)
            else:
                node.endpoint.resolved_ip = geo.resolve_ip(host)
    finally:
        geo.close()

    targets = [
        (n.endpoint.host, n.endpoint.port, n.sni, n.security in ("tls", "reality"))
        for n in dd.nodes
    ]
    pings = await ping_many(targets, timeout_ms=timeout_ms, concurrency=ping_concurrency)
    checked_at = now.replace(microsecond=0).isoformat().replace("+00:00", "Z")

    alive: list[tuple[ParsedNode, PingResult]] = []
    for node, res in zip(dd.nodes, pings, strict=True):
        ok = res.tcp_ok and res.ping_ms is not None and res.ping_ms <= timeout_ms
        if ok or keep_dead:
            alive.append((node, res))
    log.info("ping: %d/%d alive", len(alive), len(dd.nodes))

    seen = SeenState.load(seen_path)
    present_ids = {n.stable_id() for n, _ in alive}
    seen.observe(present_ids, now=now)

    nodes: list[Node] = []
    for node, res in alive:
        sid = node.stable_id()
        g = geo_by_host.get(node.endpoint.host, Geo())
        lifetime = seen.lifetime_for(sid, now=now)
        cls = classify(node, g)
        nodes.append(
            Node(
                id=sid,
                protocol=node.protocol,
                transport=node.transport,
                tag=node.tag,
                endpoint=node.endpoint,
                geo=g,
                health=Health(
                    tcp_ok=res.tcp_ok,
                    tls_ok=res.tls_ok,
                    ping_ms=res.ping_ms,
                    checked_at=checked_at,
                ),
                lifetime=lifetime,
                classification=cls,
                provenance=Provenance(
                    source=node.source or "unknown",
                    source_file=node.source_file or "",
                    imported=False,
                    raw_uri_sha1=node.raw_uri_sha1(),
                ),
                raw_uri=node.raw_uri,
                outbound=build_outbound(node),
            )
        )

    _mark_recommended(nodes, per_country=recommend_per_country)
    seen.save(seen_path)

    return Pool(
        generated_at=checked_at,
        generator=GENERATOR,
        source_run=source_run,
        stats=_stats(nodes),
        nodes=nodes,
    )


def _mark_recommended(nodes: list[Node], *, per_country: int) -> None:
    by_country: dict[str, list[Node]] = defaultdict(list)
    for n in nodes:
        by_country[n.geo.country or "??"].append(n)
    for group in by_country.values():
        group.sort(
            key=lambda n: (-n.lifetime.stability, n.health.ping_ms if n.health.ping_ms is not None else 9999)
        )
        for n in group[:per_country]:
            n.recommended = True


def _stats(nodes: list[Node]) -> PoolStats:
    return PoolStats(
        total=len(nodes),
        by_protocol=dict(Counter(n.protocol for n in nodes)),
        by_country=dict(Counter(n.geo.country or "??" for n in nodes)),
        by_lifetime=dict(Counter(n.lifetime.class_ for n in nodes)),
    )
