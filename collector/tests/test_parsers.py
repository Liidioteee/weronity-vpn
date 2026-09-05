from __future__ import annotations

import pytest

from weronity_collector.parsers import ParseError, iter_uris, parse_uri
from weronity_collector.parsers.common import b64decode_any, split_name


def test_all_fixture_uris_parse(uris_text: str) -> None:
    uris = iter_uris(uris_text)
    assert len(uris) == 10
    nodes = [parse_uri(u) for u in uris]
    protos = {n.protocol for n in nodes}
    assert protos == {"vless", "hysteria2", "trojan", "vmess", "shadowsocks", "tuic"}


def test_iter_uris_skips_comments_and_blanks() -> None:
    text = "# comment\n\nvless://u@h:443?type=tcp#x\n// also comment\nnotaurl\n"
    assert iter_uris(text) == ["vless://u@h:443?type=tcp#x"]


def test_vless_reality() -> None:
    n = parse_uri(
        "vless://uuid-1@h.example:443?type=tcp&security=reality"
        "&pbk=PUBKEY&sid=ab12&fp=chrome&sni=www.apple.com&flow=xtls-rprx-vision#t"
    )
    assert n.protocol == "vless" and n.transport == "tcp"
    assert n.security == "reality"
    assert n.params["public_key"] == "PUBKEY"
    assert n.params["short_id"] == "ab12"
    assert n.params["flow"] == "xtls-rprx-vision"
    assert n.auth == "uuid-1"
    assert n.tag == "t"


def test_vless_reality_requires_pbk() -> None:
    with pytest.raises(ParseError):
        parse_uri("vless://uuid@h:443?type=tcp&security=reality#t")


def test_vless_ws_path_and_host() -> None:
    n = parse_uri("vless://uuid@h:443?type=ws&security=tls&path=%2Fabc&host=cdn.example#t")
    assert n.transport == "ws"
    assert n.params["path"] == "/abc"
    assert n.params["host_header"] == "cdn.example"


def test_hysteria2_aliases_and_obfs() -> None:
    n = parse_uri("hy2://pw@h:443?obfs=salamander&obfs-password=xyz&up=20&down=100&insecure=1#t")
    assert n.protocol == "hysteria2" and n.transport == "quic"
    assert n.params["obfs"] == "salamander"
    assert n.params["obfs_password"] == "xyz"
    assert n.params["up_mbps"] == 20 and n.params["down_mbps"] == 100
    assert n.params["allow_insecure"] is True


def test_trojan_grpc() -> None:
    n = parse_uri("trojan://pw@h:443?type=grpc&security=tls&serviceName=svc&sni=h#t")
    assert n.protocol == "trojan" and n.transport == "grpc"
    assert n.params["service_name"] == "svc"
    assert n.auth == "pw"


def test_vmess_base64_json() -> None:
    n = parse_uri(
        "vmess://eyJ2IjoiMiIsInBzIjoieCIsImFkZCI6ImguZXhhbXBsZSIsInBvcnQiOiI0NDMiLCJpZCI6"
        "InV1aWQtOSIsImFpZCI6IjAiLCJuZXQiOiJ3cyIsInBhdGgiOiIvcCIsImhvc3QiOiJoLmV4YW1wbGUi"
        "LCJ0bHMiOiJ0bHMifQ=="
    )
    assert n.protocol == "vmess" and n.transport == "ws"
    assert n.endpoint.host == "h.example" and n.endpoint.port == 443
    assert n.params["uuid"] == "uuid-9"
    assert n.params["path"] == "/p"
    assert n.security == "tls"


def test_vmess_bad_payload() -> None:
    with pytest.raises(ParseError):
        parse_uri("vmess://not-base64-json!!!")


def test_ss_sip002_base64_userinfo() -> None:
    n = parse_uri("ss://YWVzLTI1Ni1nY206cGFzcw==@h.example:8388#tag")
    assert n.protocol == "shadowsocks"
    assert n.params["method"] == "aes-256-gcm"
    assert n.params["password"] == "pass"
    assert n.auth == "aes-256-gcm:pass"


def test_ss_2022_plain_userinfo() -> None:
    n = parse_uri("ss://2022-blake3-aes-128-gcm:c2hvcnRrZXk=@h.example:443#t")
    assert n.params["method"] == "2022-blake3-aes-128-gcm"
    assert n.params["password"] == "c2hvcnRrZXk="


def test_ss_legacy_whole_base64() -> None:
    # base64("aes-256-gcm:pass@h.example:8388")
    n = parse_uri("ss://YWVzLTI1Ni1nY206cGFzc0BoLmV4YW1wbGU6ODM4OA==#t")
    assert n.endpoint.host == "h.example" and n.endpoint.port == 8388
    assert n.params["method"] == "aes-256-gcm"


def test_tuic_v5() -> None:
    n = parse_uri("tuic://uuid:pw@h:2053?sni=h&congestion_control=bbr&udp_relay_mode=native#t")
    assert n.protocol == "tuic" and n.transport == "quic"
    assert n.params["uuid"] == "uuid" and n.params["password"] == "pw"
    assert n.auth == "uuid:pw"


def test_unsupported_scheme() -> None:
    with pytest.raises(ParseError):
        parse_uri("wireguard://whatever")


def test_dedup_key_and_stable_id_are_deterministic() -> None:
    u = "vless://uuid@H.Example:443?type=tcp&security=tls&sni=a.com#name-one"
    v = "vless://uuid@h.example.:443?type=tcp&security=tls&sni=a.com#name-two"
    a, b = parse_uri(u), parse_uri(v)
    assert a.dedup_key() == b.dedup_key()  # host case + trailing dot normalised
    assert a.stable_id() == b.stable_id()


def test_dedup_key_distinguishes_sni_and_transport() -> None:
    base = "vless://uuid@h:443?security=tls&sni={sni}&type={t}#x"
    k1 = parse_uri(base.format(sni="a.com", t="tcp")).dedup_key()
    k2 = parse_uri(base.format(sni="b.com", t="tcp")).dedup_key()
    k3 = parse_uri(base.format(sni="a.com", t="ws")).dedup_key()
    assert k1 != k2 != k3 and k1 != k3


def test_helpers() -> None:
    assert b64decode_any("YQ") == b"a"  # unpadded
    assert split_name("x://y#a%20b") == ("x://y", "a b")
