from __future__ import annotations

import json

import pytest
from pydantic import ValidationError

from weronity_collector.schema import json_schema, validate_file, validate_pool

_MINIMAL = {
    "schema_version": 1,
    "generated_at": "2026-09-05T00:00:00Z",
    "generator": "weronity-collector/0.1.0",
    "source_run": None,
    "stats": {"total": 1, "by_protocol": {"vless": 1}, "by_country": {"DE": 1}, "by_lifetime": {"fresh": 1}},
    "nodes": [
        {
            "id": "abc123",
            "protocol": "vless",
            "transport": "tcp",
            "tag": "n1",
            "endpoint": {"host": "h", "port": 443, "resolved_ip": None},
            "geo": {
                "country": "DE",
                "country_name": "Germany",
                "flag": "\U0001f1e9\U0001f1ea",
                "asn": 1,
                "as_org": "x",
            },
            "health": {"tcp_ok": True, "tls_ok": True, "ping_ms": 100, "checked_at": "2026-09-05T00:00:00Z"},
            "lifetime": {
                "first_seen": "2026-09-05T00:00:00Z",
                "last_seen": "2026-09-05T00:00:00Z",
                "age_hours": 0,
                "class": "fresh",
                "seen_runs": 1,
                "stability": 1.0,
            },
            "classification": {
                "sni": "h",
                "security": "none",
                "flow": None,
                "cdn": False,
                "ipv6": False,
                "udp": False,
            },
            "provenance": {"source": "s", "source_file": "f", "imported": False, "raw_uri_sha1": "x"},
            "recommended": True,
            "raw_uri": "vless://u@h:443",
            "outbound": {"type": "vless", "server": "h", "server_port": 443, "uuid": "u"},
        }
    ],
}


def test_json_schema_shape() -> None:
    s = json_schema()
    assert s["$schema"].startswith("https://json-schema.org/")
    assert "nodes" in s["properties"]
    # alias, not the python attr name
    node_props = s["$defs"]["Node"]["properties"]
    assert "class" not in node_props  # class lives on Lifetime
    assert "class" in s["$defs"]["Lifetime"]["properties"]


def test_validate_minimal_pool() -> None:
    pool = validate_pool(_MINIMAL)
    assert pool.nodes[0].lifetime.class_ == "fresh"
    assert pool.nodes[0].recommended is True


def test_validate_rejects_bad_protocol() -> None:
    bad = json.loads(json.dumps(_MINIMAL))
    bad["nodes"][0]["protocol"] = "wireguard"
    with pytest.raises(ValidationError):
        validate_pool(bad)


def test_validate_file_roundtrip(tmp_path) -> None:
    p = tmp_path / "pool.json"
    p.write_text(json.dumps(_MINIMAL), "utf-8")
    pool, err = validate_file(p)
    assert err is None and pool is not None and pool.stats.total == 1


def test_validate_file_reports_errors(tmp_path) -> None:
    p = tmp_path / "broken.json"
    p.write_text("{not json", "utf-8")
    pool, err = validate_file(p)
    assert pool is None and err
