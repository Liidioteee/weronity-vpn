"""The committed parity fixture must match what the parsers produce today.

The same JSON is asserted by ``app/test/domain/uri_parser_parity_test.dart``, so
the Python parsers and their Dart port cannot drift apart unnoticed.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from gen_parity import FIXTURES, expected  # noqa: E402


def test_parity_fixture_is_current() -> None:
    committed = json.loads((FIXTURES / "parity_expected.json").read_text("utf-8"))
    assert committed == expected(), "parsers changed — run `python tests/gen_parity.py`"


def test_parity_fixture_covers_accepts_and_rejects() -> None:
    entries = expected()
    accepted = [e for e in entries if e["node"] is not None]
    rejected = [e for e in entries if e["node"] is None]
    assert len(accepted) >= 15 and len(rejected) >= 6
    assert {e["node"]["protocol"] for e in accepted} == {  # type: ignore[index]
        "vless",
        "vmess",
        "trojan",
        "hysteria2",
        "shadowsocks",
        "tuic",
    }
