"""Hostile / malformed input must cost one entry, never the whole run."""

from __future__ import annotations

import base64
import json

import pytest

from weronity_collector.__main__ import main
from weronity_collector.harvest import harvest
from weronity_collector.parsers import ParseError, parse_uri
from weronity_collector.pipeline import build as build_mod
from weronity_collector.pipeline.ping import PingResult
from weronity_collector.sources.base import RawDocument

_GOOD = "vless://11111111-1111-1111-1111-111111111111@good.example:443?type=tcp&security=tls#ok"


def _doc(name: str, content: str) -> RawDocument:
    d = RawDocument(source="test", source_file=name, content=content)
    d.kind = d.detect_kind()
    return d


def _vmess(**fields: object) -> str:
    return "vmess://" + base64.b64encode(json.dumps(fields).encode()).decode()


@pytest.mark.parametrize(
    "bad",
    [
        "vless://u@example.com:99999?type=tcp#port-out-of-range",
        "vless://u@example.com:abc?type=tcp#port-not-a-number",
        "vless://u@[::1:443?type=tcp#broken-ipv6",
        "hysteria2://pw@h.example:443,5000-6000?sni=a#port-hopping",
        "vmess://" + base64.b64encode(b"[1,2]").decode(),
    ],
)
def test_one_malformed_uri_does_not_abort_the_document(bad: str) -> None:
    nodes, stats = harvest([_doc("uris.txt", f"{bad}\n{_GOOD}\n")])
    assert [n.tag for n in nodes] == ["ok"]
    assert stats.parsed == 1 and stats.failed == 1


def test_vmess_garbage_alter_id_degrades_to_zero() -> None:
    n = parse_uri(_vmess(add="h.example", port="443", id="u", aid="abc", net="tcp"))
    assert n.params["alter_id"] == 0


@pytest.mark.parametrize(
    "yaml_text",
    [
        "proxies:\n  - {name: a, type: vless, server: [}\n",  # invalid YAML
        "proxies:\n  - {name: a, type: vless, server: h, port: 443, uuid: u, network: ws, ws-opts: oops}\n",
        "proxies:\n  - {name: a, type: vmess, server: h, port: 443, uuid: u, alterId: x}\n",
        "proxies:\n  - {name: a, type: vless, server: h, port: 443, uuid: u, reality-opts: nope}\n",
    ],
)
def test_malformed_clash_file_does_not_abort_the_run(yaml_text: str) -> None:
    nodes, stats = harvest([_doc("a.yaml", yaml_text), _doc("uris.txt", _GOOD)])
    assert stats.documents == 2
    assert any(n.tag == "ok" for n in nodes)


@pytest.mark.parametrize("net", ["xhttp", "splithttp", "kcp", "mkcp", "quic"])
def test_transports_sing_box_cannot_speak_are_rejected(net: str) -> None:
    with pytest.raises(ParseError):
        parse_uri(f"vless://uuid@h:443?type={net}&security=tls#t")
    with pytest.raises(ParseError):
        parse_uri(_vmess(add="h", port=443, id="u", net=net))


def test_tcp_http_header_obfuscation_is_rejected() -> None:
    with pytest.raises(ParseError):
        parse_uri("vless://uuid@h:443?type=tcp&headerType=http&host=a.com#t")
    with pytest.raises(ParseError):
        parse_uri(_vmess(add="h", port=443, id="u", net="tcp", type="http"))


def test_shadowsocks_plugin_nodes_are_rejected() -> None:
    with pytest.raises(ParseError):
        parse_uri("ss://YWVzLTI1Ni1nY206cGFzcw==@h.example:8388?plugin=obfs-local%3Bobfs%3Dhttp#t")


def test_standalone_shadowtls_is_not_a_supported_scheme() -> None:
    with pytest.raises(ParseError):
        parse_uri("shadowtls://eyJob3N0IjoiaCIsInBvcnQiOjQ0M30=")


# --- pool-level guards ---------------------------------------------------------


async def _all_alive(targets, *, timeout_ms=2000, concurrency=64):
    return [PingResult(tcp_ok=True, tls_ok=True, ping_ms=40) for _ in targets]


async def _all_dead(targets, *, timeout_ms=2000, concurrency=64):
    return [PingResult() for _ in targets]


async def test_non_public_addresses_are_dropped(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _all_alive)
    uris = "\n".join(
        [
            "vless://u1@127.0.0.1:443?type=tcp#loopback",
            "vless://u2@192.168.1.10:443?type=tcp#lan",
            "vless://u3@169.254.169.254:80?type=tcp#metadata",
            "vless://u4@8.8.8.8:443?type=tcp#public",
        ]
    )
    parsed, _ = harvest([_doc("u.txt", uris)])
    kw = {"geoip_dir": tmp_path / "x", "seen_path": tmp_path / "seen.json"}

    pool = await build_mod.build_pool(parsed, **kw)
    assert [n.tag for n in pool.nodes] == ["public"]

    pool = await build_mod.build_pool(parsed, allow_private=True, **kw)
    assert len(pool.nodes) == 4


async def test_quic_protocols_are_probed_over_udp(tmp_path, monkeypatch) -> None:
    seen: list = []

    async def capture(targets, *, timeout_ms=2000, concurrency=64):
        seen.extend(targets)
        return [PingResult(tcp_ok=True, ping_ms=30) for _ in targets]

    monkeypatch.setattr(build_mod, "ping_many", capture)
    uris = "\n".join(
        [
            "hysteria2://pw@8.8.8.8:443?obfs=salamander&obfs-password=psk&sni=a#hy2",
            "tuic://uuid:pw@8.8.4.4:2053?sni=a#tuic",
            "vless://u@1.1.1.1:443?type=tcp&security=tls&sni=a#vless",
        ]
    )
    parsed, _ = harvest([_doc("u.txt", uris)])
    await build_mod.build_pool(parsed, geoip_dir=tmp_path / "x", seen_path=tmp_path / "seen.json")

    by_host = {t.host: t for t in seen}
    assert by_host["1.1.1.1"].udp is False and by_host["1.1.1.1"].want_tls is True
    assert by_host["8.8.4.4"].udp is True and by_host["8.8.4.4"].want_tls is False
    assert by_host["8.8.8.8"].udp is True and by_host["8.8.8.8"].obfs_password == "psk"


async def test_display_tag_is_sanitised(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _all_alive)
    name = "A\u0007B  " + "x" * 200
    parsed, _ = harvest([_doc("u.txt", f"vless://u@8.8.8.8:443?type=tcp#{name}")])
    pool = await build_mod.build_pool(parsed, geoip_dir=tmp_path / "x", seen_path=tmp_path / "seen.json")
    tag = pool.nodes[0].tag
    assert len(tag) <= 64 and "\u0007" not in tag and tag.startswith("AB x")


def _offline_args(tmp_path, out) -> list[str]:
    src = tmp_path / "src"
    src.mkdir(exist_ok=True)
    (src / "u.txt").write_text("vless://u@8.8.8.8:443?type=tcp#a\n", "utf-8")
    return [
        "run",
        "--offline", str(src),
        "--out", str(out),
        "--seen", str(tmp_path / "seen.json"),
        "--geoip-dir", str(tmp_path / "x"),
    ]  # fmt: skip


def test_cli_refuses_to_write_an_empty_pool(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _all_dead)
    out = tmp_path / "out" / "nodes_pool.json"
    assert main(_offline_args(tmp_path, out)) == 3
    assert not out.exists()


def test_cli_min_nodes_threshold(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(build_mod, "ping_many", _all_alive)
    out = tmp_path / "nodes_pool.json"
    args = _offline_args(tmp_path, out)
    assert main([*args, "--min-nodes", "5"]) == 3
    assert not out.exists()
    assert main(args) == 0
    assert out.is_file()
