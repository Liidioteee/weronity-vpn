from __future__ import annotations

from weronity_collector.outbound import build_outbound
from weronity_collector.parsers import parse_uri


def _ob(uri: str) -> dict:
    return build_outbound(parse_uri(uri))


def test_vless_reality_outbound() -> None:
    ob = _ob(
        "vless://uuid@h:443?type=tcp&security=reality&pbk=PK&sid=ab&fp=chrome"
        "&sni=www.apple.com&flow=xtls-rprx-vision#t"
    )
    assert ob["type"] == "vless"
    assert ob["server"] == "h" and ob["server_port"] == 443
    assert ob["uuid"] == "uuid" and ob["flow"] == "xtls-rprx-vision"
    assert ob["tls"]["reality"] == {"enabled": True, "public_key": "PK", "short_id": "ab"}
    assert ob["tls"]["server_name"] == "www.apple.com"
    assert ob["tls"]["utls"]["fingerprint"] == "chrome"
    assert "transport" not in ob


def test_vless_ws_outbound_transport() -> None:
    ob = _ob("vless://uuid@h:443?type=ws&security=tls&path=%2Fx&host=cdn.example&sni=cdn.example#t")
    assert ob["transport"] == {"type": "ws", "path": "/x", "headers": {"Host": "cdn.example"}}
    assert ob["tls"]["enabled"] is True


def test_trojan_grpc_outbound() -> None:
    ob = _ob("trojan://pw@h:443?type=grpc&security=tls&serviceName=svc&sni=h#t")
    assert ob["type"] == "trojan" and ob["password"] == "pw"
    assert ob["transport"] == {"type": "grpc", "service_name": "svc"}


def test_hysteria2_outbound_obfs_and_tls() -> None:
    ob = _ob("hysteria2://pw@h:443?obfs=salamander&obfs-password=xy&up=10&down=50&insecure=1&sni=s#t")
    assert ob["type"] == "hysteria2"
    assert ob["up_mbps"] == 10 and ob["down_mbps"] == 50
    assert ob["obfs"] == {"type": "salamander", "password": "xy"}
    assert ob["tls"]["enabled"] is True and ob["tls"]["insecure"] is True


def test_shadowsocks_outbound() -> None:
    ob = _ob("ss://YWVzLTI1Ni1nY206cGFzcw==@h:8388#t")
    assert ob == {
        "tag": "t",
        "server": "h",
        "server_port": 8388,
        "type": "shadowsocks",
        "method": "aes-256-gcm",
        "password": "pass",
    }


def test_tuic_outbound() -> None:
    ob = _ob("tuic://uuid:pw@h:2053?sni=h&congestion_control=bbr&udp_relay_mode=native#t")
    assert ob["type"] == "tuic"
    assert ob["uuid"] == "uuid" and ob["password"] == "pw"
    assert ob["congestion_control"] == "bbr"
    assert ob["tls"]["enabled"] is True


def test_vmess_outbound() -> None:
    ob = _ob(
        "vmess://eyJ2IjoiMiIsInBzIjoieCIsImFkZCI6ImgiLCJwb3J0IjoiNDQzIiwiaWQiOiJ1IiwiYWlkIjoi"
        "MCIsIm5ldCI6InRjcCIsInRscyI6IiJ9"
    )
    assert ob["type"] == "vmess" and ob["uuid"] == "u"
    assert ob["alter_id"] == 0 and ob["security"] == "auto"
    assert "tls" not in ob
