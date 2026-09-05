"""Primary reachability check: TCP connect + best-effort TLS handshake.

Runs concurrently with a bounded semaphore. A node whose TCP RTT exceeds
``timeout_ms`` (default 2000) — or that fails to connect — is considered dead and
dropped downstream.
"""

from __future__ import annotations

import asyncio
import contextlib
import ssl
import time
from dataclasses import dataclass

_TLS_CTX = ssl.create_default_context()
_TLS_CTX.check_hostname = False
_TLS_CTX.verify_mode = ssl.CERT_NONE
_TLS_CTX.set_alpn_protocols(["h2", "http/1.1"])


@dataclass(slots=True)
class PingResult:
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


async def _probe_one(host: str, port: int, sni: str | None, timeout: float, want_tls: bool) -> PingResult:
    tcp_ok, rtt = await _tcp_connect(host, port, timeout)
    res = PingResult(tcp_ok=tcp_ok, ping_ms=rtt)
    if tcp_ok and want_tls:
        res.tls_ok = await _tls_connect(host, port, sni, timeout)
    return res


async def ping_many(
    targets: list[tuple[str, int, str | None, bool]],
    *,
    timeout_ms: int = 2000,
    concurrency: int = 64,
) -> list[PingResult]:
    """``targets`` = ``(host, port, sni, want_tls)`` tuples; output order matches input."""
    sem = asyncio.Semaphore(concurrency)
    timeout = timeout_ms / 1000

    async def guarded(host: str, port: int, sni: str | None, want_tls: bool) -> PingResult:
        async with sem:
            return await _probe_one(host, port, sni, timeout, want_tls)

    return list(await asyncio.gather(*(guarded(*t) for t in targets)))
