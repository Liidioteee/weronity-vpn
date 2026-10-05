"""Primary reachability check.

* TCP protocols — TCP connect + best-effort TLS handshake.
* QUIC protocols (hysteria2, tuic) — a UDP probe. They have no TCP listener, so a
  TCP connect says nothing about them. We send one QUIC long-header packet with a
  reserved ("greased") version; every QUIC server must answer an unknown version
  with a Version Negotiation packet (RFC 9000 §6), which needs no crypto and no
  credentials. Hysteria2's Salamander obfuscation is applied when the node uses it.

Runs concurrently with a bounded semaphore. A node whose RTT exceeds
``timeout_ms`` (default 2000) — or that never answers — is considered dead and
dropped downstream.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import os
import ssl
import time
from collections.abc import Sequence
from dataclasses import dataclass

_TLS_CTX = ssl.create_default_context()
_TLS_CTX.check_hostname = False
_TLS_CTX.verify_mode = ssl.CERT_NONE
_TLS_CTX.set_alpn_protocols(["h2", "http/1.1"])

# A version of the form 0x?a?a?a?a is reserved to force version negotiation.
_QUIC_GREASE_VERSION = b"\x1a\x2a\x3a\x4a"
# Servers ignore unknown-version datagrams shorter than this (anti-amplification).
_QUIC_MIN_DATAGRAM = 1200
_SALAMANDER_SALT_LEN = 8
_SALAMANDER_KEY_LEN = 32


@dataclass(slots=True)
class PingTarget:
    host: str
    port: int
    sni: str | None = None
    want_tls: bool = False
    # QUIC-based protocol: probe over UDP instead of TCP.
    udp: bool = False
    # Hysteria2 Salamander pre-shared key, when the node is obfuscated.
    obfs_password: str | None = None


# ``(host, port, sni, want_tls)`` is accepted as shorthand for a TCP target.
TargetLike = PingTarget | tuple[str, int, str | None, bool]


@dataclass(slots=True)
class PingResult:
    # "reachable": the TCP connect succeeded, or the QUIC server answered the probe.
    # The field keeps its historical name — it is part of the published schema.
    tcp_ok: bool = False
    tls_ok: bool = False
    ping_ms: int | None = None


async def _tcp_connect(host: str, port: int, timeout: float) -> tuple[bool, int | None]:
    start = time.perf_counter()
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except (OSError, TimeoutError):
        return False, None
    rtt = int((time.perf_counter() - start) * 1000)
    writer.close()
    with contextlib.suppress(OSError):
        await writer.wait_closed()
    return True, rtt


async def _tls_connect(host: str, port: int, sni: str | None, timeout: float) -> bool:
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port, ssl=_TLS_CTX, server_hostname=sni or host),
            timeout,
        )
    except (OSError, ssl.SSLError, TimeoutError):
        return False
    writer.close()
    with contextlib.suppress(OSError, ssl.SSLError):
        await writer.wait_closed()
    return True


# ---- QUIC ---------------------------------------------------------------------


def quic_probe_packet() -> bytes:
    """A padded long-header packet with a greased version and random connection IDs."""
    header = (
        b"\xc0"  # long header, fixed bit set
        + _QUIC_GREASE_VERSION
        + b"\x08" + os.urandom(8)  # destination connection id
        + b"\x08" + os.urandom(8)  # source connection id
    )
    return header + os.urandom(_QUIC_MIN_DATAGRAM - len(header))


def is_version_negotiation(datagram: bytes) -> bool:
    """Long header with version 0 — the only thing a server sends back to our probe."""
    return len(datagram) >= 7 and bool(datagram[0] & 0x80) and datagram[1:5] == b"\x00\x00\x00\x00"


def _salamander_xor(psk: bytes, salt: bytes, data: bytes) -> bytes:
    key = hashlib.blake2b(psk + salt, digest_size=_SALAMANDER_KEY_LEN).digest()
    return bytes(b ^ key[i % _SALAMANDER_KEY_LEN] for i, b in enumerate(data))


def salamander_obfuscate(psk: bytes, packet: bytes) -> bytes:
    salt = os.urandom(_SALAMANDER_SALT_LEN)
    return salt + _salamander_xor(psk, salt, packet)


def salamander_deobfuscate(psk: bytes, datagram: bytes) -> bytes:
    if len(datagram) <= _SALAMANDER_SALT_LEN:
        return b""
    salt, body = datagram[:_SALAMANDER_SALT_LEN], datagram[_SALAMANDER_SALT_LEN:]
    return _salamander_xor(psk, salt, body)


class _QuicProbe(asyncio.DatagramProtocol):
    def __init__(self, psk: bytes | None) -> None:
        self._psk = psk
        self.answered: asyncio.Future[bool] = asyncio.get_running_loop().create_future()

    def datagram_received(self, data: bytes, addr: object) -> None:
        if self._psk is not None:
            data = salamander_deobfuscate(self._psk, data)
        if is_version_negotiation(data) and not self.answered.done():
            self.answered.set_result(True)

    def error_received(self, exc: Exception) -> None:  # ICMP port unreachable etc.
        if not self.answered.done():
            self.answered.set_result(False)


async def _quic_probe(
    host: str, port: int, timeout: float, obfs_password: str | None
) -> tuple[bool, int | None]:
    psk = obfs_password.encode() if obfs_password else None
    loop = asyncio.get_running_loop()
    try:
        transport, proto = await asyncio.wait_for(
            loop.create_datagram_endpoint(lambda: _QuicProbe(psk), remote_addr=(host, port)),
            timeout,
        )
    except (OSError, TimeoutError):
        return False, None
    try:
        packet = quic_probe_packet()
        start = time.perf_counter()
        # UDP is lossy — send twice, half a timeout apart.
        for _ in range(2):
            transport.sendto(salamander_obfuscate(psk, packet) if psk is not None else packet)
            try:
                ok = await asyncio.wait_for(asyncio.shield(proto.answered), timeout / 2)
            except TimeoutError:
                continue
            if not ok:
                return False, None
            return True, int((time.perf_counter() - start) * 1000)
        return False, None
    except OSError:
        return False, None
    finally:
        transport.close()


# ---- driver -------------------------------------------------------------------


async def _probe_one(t: PingTarget, timeout: float) -> PingResult:
    if t.udp:
        ok, rtt = await _quic_probe(t.host, t.port, timeout, t.obfs_password)
        return PingResult(tcp_ok=ok, ping_ms=rtt)
    tcp_ok, rtt = await _tcp_connect(t.host, t.port, timeout)
    res = PingResult(tcp_ok=tcp_ok, ping_ms=rtt)
    if tcp_ok and t.want_tls:
        res.tls_ok = await _tls_connect(t.host, t.port, t.sni, timeout)
    return res


async def ping_many(
    targets: Sequence[TargetLike],
    *,
    timeout_ms: int = 2000,
    concurrency: int = 64,
) -> list[PingResult]:
    """Probe every target; output order matches input."""
    sem = asyncio.Semaphore(concurrency)
    timeout = timeout_ms / 1000

    async def guarded(t: TargetLike) -> PingResult:
        target = t if isinstance(t, PingTarget) else PingTarget(*t)
        async with sem:
            return await _probe_one(target, timeout)

    return list(await asyncio.gather(*(guarded(t) for t in targets)))
