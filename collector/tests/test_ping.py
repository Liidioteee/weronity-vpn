from __future__ import annotations

import asyncio

import pytest

from weronity_collector.pipeline.ping import ping_many


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
