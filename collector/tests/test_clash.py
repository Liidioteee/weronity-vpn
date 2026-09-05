from __future__ import annotations

from weronity_collector.parsers.clash import parse_clash


def test_parse_clash_fixture(clash_text: str) -> None:
    nodes = parse_clash(clash_text)
    # 5 proxies in the file, one invalid (no server) is skipped
    by_proto = {n.protocol for n in nodes}
    assert len(nodes) == 4
    assert by_proto == {"vless", "trojan", "shadowsocks", "hysteria2"}


def test_clash_vless_reality_mapping(clash_text: str) -> None:
    n = next(n for n in parse_clash(clash_text) if n.protocol == "vless")
    assert n.security == "reality"
    assert n.params["public_key"].startswith("ABCdef")
    assert n.params["flow"] == "xtls-rprx-vision"
    assert n.params["fingerprint"] == "chrome"


def test_clash_trojan_grpc_and_skip_verify(clash_text: str) -> None:
    n = next(n for n in parse_clash(clash_text) if n.protocol == "trojan")
    assert n.transport == "grpc"
    assert n.params["service_name"] == "tjSvc"
    assert n.params["allow_insecure"] is True


def test_clash_hysteria2_obfs(clash_text: str) -> None:
    n = next(n for n in parse_clash(clash_text) if n.protocol == "hysteria2")
    assert n.transport == "quic"
    assert n.params["obfs"] == "salamander"
    assert n.params["obfs_password"] == "s3cr3t"


def test_clash_without_proxies_key() -> None:
    import pytest

    from weronity_collector.parsers.common import ParseError

    with pytest.raises(ParseError):
        parse_clash("port: 7890\nmode: rule\n")
