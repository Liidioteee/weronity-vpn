from __future__ import annotations

import asyncio

import pytest

from weronity_collector.pipeline.ping import (
    PingTarget,
    is_version_negotiation,
    ping_many,
    quic_probe_packet,
    salamander_deobfuscate,
    salamander_obfuscate,
)


@pytest.fixture
async def tcp_server() -> tuple[str, int]:
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", 0)
    host, port = server.sockets[0].getsockname()[:2]
    yield host, port
    server.close()
    await server.wait_closed()


async def test_ping_alive_and_dead(tcp_server: tuple[str, int]) -> None:
    host, port = tcp_server
    results = await ping_many(
        [(host, port, None, False), ("127.0.0.1", 1, None, False)],
        timeout_ms=500,
    )
    alive, dead = results
    assert alive.tcp_ok is True and alive.ping_ms is not None and alive.ping_ms <= 500
    assert dead.tcp_ok is False and dead.ping_ms is None


async def test_ping_preserves_order(tcp_server: tuple[str, int]) -> None:
    host, port = tcp_server
    targets = [("127.0.0.1", 1, None, False), (host, port, None, False), ("127.0.0.1", 2, None, False)]
    r = await ping_many(targets, timeout_ms=400, concurrency=8)
    assert [x.tcp_ok for x in r] == [False, True, False]


async def test_ping_timeout_is_bounded() -> None:
    # 10.255.255.1 is non-routable → connect will time out, not refuse fast
    loop = asyncio.get_running_loop()
    start = loop.time()
    (res,) = await ping_many([("10.255.255.1", 80, None, False)], timeout_ms=300)
    assert res.tcp_ok is False
    assert loop.time() - start < 2.0


# --- QUIC (hysteria2 / tuic) -----------------------------------------------------


class _FakeQuicServer(asyncio.DatagramProtocol):
    """Answers an unknown-version long-header packet with Version Negotiation."""

    def __init__(self, psk: bytes | None = None, *, answer: bool = True) -> None:
        self.psk = psk
        self.answer = answer
        self.transport: asyncio.DatagramTransport | None = None

    def connection_made(self, transport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        if self.psk is not None:
            data = salamander_deobfuscate(self.psk, data)
        # like a real server: ignore short datagrams and anything that is not a
        # long header carrying a version we do not speak
        if not self.answer or len(data) < 1200 or not data[0] & 0x80:
            return
        if data[1:5] == b"\x00\x00\x00\x01":
            return
        dcid_len = data[5]
        dcid = data[6 : 6 + dcid_len]
        scid_len = data[6 + dcid_len]
        scid = data[7 + dcid_len : 7 + dcid_len + scid_len]
        reply = (
            b"\x80\x00\x00\x00\x00"
            + bytes([len(scid)]) + scid
            + bytes([len(dcid)]) + dcid
            + b"\x00\x00\x00\x01"
        )  # fmt: skip
        if self.psk is not None:
            reply = salamander_obfuscate(self.psk, reply)
        assert self.transport is not None
        self.transport.sendto(reply, addr)


async def _udp_server(proto: _FakeQuicServer) -> tuple[asyncio.DatagramTransport, int]:
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(lambda: proto, local_addr=("127.0.0.1", 0))
    return transport, transport.get_extra_info("sockname")[1]


async def test_quic_probe_gets_version_negotiation() -> None:
    transport, port = await _udp_server(_FakeQuicServer())
    try:
        (res,) = await ping_many([PingTarget("127.0.0.1", port, udp=True)], timeout_ms=1000)
    finally:
        transport.close()
    assert res.tcp_ok is True and res.ping_ms is not None and res.tls_ok is False


async def test_quic_probe_through_salamander_obfs() -> None:
    transport, port = await _udp_server(_FakeQuicServer(psk=b"s3cr3t"))
    try:
        good, wrong_key, no_key = await ping_many(
            [
                PingTarget("127.0.0.1", port, udp=True, obfs_password="s3cr3t"),
                PingTarget("127.0.0.1", port, udp=True, obfs_password="other"),
                PingTarget("127.0.0.1", port, udp=True),
            ],
            timeout_ms=600,
        )
    finally:
        transport.close()
    assert good.tcp_ok is True
    assert wrong_key.tcp_ok is False
    assert no_key.tcp_ok is False


async def test_quic_probe_silent_server_is_dead_and_bounded() -> None:
    transport, port = await _udp_server(_FakeQuicServer(answer=False))
    loop = asyncio.get_running_loop()
    start = loop.time()
    try:
        (res,) = await ping_many([PingTarget("127.0.0.1", port, udp=True)], timeout_ms=400)
    finally:
        transport.close()
    assert res.tcp_ok is False and res.ping_ms is None
    assert loop.time() - start < 2.0


def test_probe_packet_shape_and_salamander_roundtrip() -> None:
    pkt = quic_probe_packet()
    assert len(pkt) == 1200 and pkt[0] & 0xC0 == 0xC0
    assert not is_version_negotiation(pkt)
    assert is_version_negotiation(b"\x80\x00\x00\x00\x00\x08" + b"a" * 8 + b"\x08" + b"b" * 8)
    wrapped = salamander_obfuscate(b"key!", pkt)
    assert len(wrapped) == len(pkt) + 8 and wrapped[8:] != pkt
    assert salamander_deobfuscate(b"key!", wrapped) == pkt
