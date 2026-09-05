from __future__ import annotations

from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def fixtures_dir() -> Path:
    return FIXTURES


@pytest.fixture
def uris_text() -> str:
    return (FIXTURES / "uris.txt").read_text("utf-8")


@pytest.fixture
def clash_text() -> str:
    return (FIXTURES / "clash.yaml").read_text("utf-8")
