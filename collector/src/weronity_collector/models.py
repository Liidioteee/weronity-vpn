"""Data models: parser output (:class:`ParsedNode`) and the published pool.

The pipeline turns a stream of :class:`ParsedNode` (one per source URI) into a
:class:`Pool` of enriched :class:`Node` objects serialised to ``nodes_pool.json``.
The published schema is documented in ``docs/pool-schema.md``.
"""

from __future__ import annotations

import hashlib
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

Protocol = Literal[
    "vless", "vmess", "trojan", "hysteria2", "shadowsocks", "tuic", "shadowtls"
]
# Network transport only. TLS vs Reality vs plain lives in classification.security
# (and in ParsedNode.security); dedup keys on transport + sni, not on security.
Transport = Literal["tcp", "ws", "grpc", "httpupgrade", "h2", "mkcp", "quic"]
LifetimeClass = Literal["fresh", "short_lived", "long_lived"]
Security = Literal["reality", "tls", "none"]


class Endpoint(BaseModel):
    host: str
    port: int
    resolved_ip: str | None = None


class ParsedNode(BaseModel):
    """Normalised output of a single-URI parser, before enrichment.

    ``params`` is a protocol-agnostic bag consumed by the outbound generator and
    the classifier. Well-known keys: ``uuid``, ``password``, ``method``, ``sni``,
    ``flow``, ``alpn`` (list), ``security``, ``public_key``, ``short_id``,
    ``fingerprint``, ``path``, ``host_header``, ``service_name`` (gRPC),
    ``header_type``, ``obfs``, ``obfs_password``, ``up_mbps``, ``down_mbps``,
    ``congestion_control``, ``udp_relay_mode``, ``allow_insecure`` (bool),
    ``alter_id`` (vmess), ``encryption``.
    """

    model_config = ConfigDict(extra="forbid")

    protocol: Protocol
    transport: Transport
    endpoint: Endpoint
    auth: str
    tag: str
    raw_uri: str
    params: dict[str, Any] = Field(default_factory=dict)
    source: str = ""
    source_file: str = ""

    # --- derived ---------------------------------------------------------------
    @property
    def sni(self) -> str | None:
        v = self.params.get("sni") or self.params.get("host_header")
        return str(v) if v else None

    @property
    def security(self) -> Security:
        sec = str(self.params.get("security") or "").lower()
        if sec == "reality" or self.params.get("public_key"):
            return "reality"
        if sec in ("tls", "xtls") or self.protocol in ("hysteria2", "tuic"):
            return "tls"
        return "none"

    def dedup_key(self) -> str:
        """``protocol|host:port|auth|transport|sni`` — see docs/pool-schema.md."""
        h = self.endpoint.host.lower().rstrip(".")
        return f"{self.protocol}|{h}:{self.endpoint.port}|{self.auth}|{self.transport}|{self.sni or ''}"

    def stable_id(self) -> str:
        return hashlib.sha1(self.dedup_key().encode()).hexdigest()[:12]

    def raw_uri_sha1(self) -> str:
        return hashlib.sha1(self.raw_uri.strip().encode()).hexdigest()


# --- published pool ----------------------------------------------------------


class Geo(BaseModel):
    country: str | None = None
    country_name: str | None = None
    flag: str | None = None
    asn: int | None = None
    as_org: str | None = None
    city: str | None = None


class Health(BaseModel):
    tcp_ok: bool = False
    tls_ok: bool = False
    ping_ms: int | None = None
    checked_at: str


class Lifetime(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    first_seen: str
    last_seen: str
    age_hours: int
    class_: LifetimeClass = Field(alias="class")
    seen_runs: int
    stability: float


class Classification(BaseModel):
    sni: str | None = None
    security: Security = "none"
    flow: str | None = None
    cdn: bool = False
    ipv6: bool = False
    udp: bool = False


class Provenance(BaseModel):
    source: str
    source_file: str
    imported: bool = False
    raw_uri_sha1: str


class Node(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str
    protocol: Protocol
    transport: Transport
    tag: str
    endpoint: Endpoint
    geo: Geo = Field(default_factory=Geo)
    health: Health
    lifetime: Lifetime
    classification: Classification = Field(default_factory=Classification)
    provenance: Provenance
    recommended: bool = False
    raw_uri: str
    outbound: dict[str, Any]


class PoolStats(BaseModel):
    total: int
    by_protocol: dict[str, int]
    by_country: dict[str, int]
    by_lifetime: dict[str, int]


class Pool(BaseModel):
    schema_version: int = 1
    generated_at: str
    generator: str
    source_run: str | None = None
    stats: PoolStats
    nodes: list[Node]
