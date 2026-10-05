"""Regenerate ``fixtures/parity_expected.json`` from ``fixtures/parity_uris.txt``.

    python tests/gen_parity.py

The Python parsers are the reference; the Dart port (``app/lib/domain/
uri_parser.dart``) is tested against the same file. Run this after changing a
parser on purpose, then make the Dart side agree.
"""

from __future__ import annotations

import json
from pathlib import Path

from weronity_collector.outbound import build_outbound
from weronity_collector.parsers import ParseError, iter_uris, parse_uri

FIXTURES = Path(__file__).parent / "fixtures"


def describe(uri: str) -> dict[str, object] | None:
    """What both parsers must agree on for one URI; ``None`` = rejected."""
    try:
        node = parse_uri(uri)
    except ParseError:
        return None
    return {
        "id": node.stable_id(),
        "protocol": node.protocol,
        "transport": node.transport,
        "host": node.endpoint.host,
        "port": node.endpoint.port,
        "sni": node.sni,
        "security": node.security,
        "outbound_type": build_outbound(node)["type"],
    }


def expected() -> list[dict[str, object]]:
    text = (FIXTURES / "parity_uris.txt").read_text("utf-8")
    return [{"uri": uri, "node": describe(uri)} for uri in iter_uris(text)]


if __name__ == "__main__":
    out = FIXTURES / "parity_expected.json"
    # newline="\n": the fixture must be byte-identical whichever OS regenerates it
    out.write_text(json.dumps(expected(), ensure_ascii=False, indent=1) + "\n", "utf-8", newline="\n")
    print(f"wrote {out} ({len(expected())} entries)")
