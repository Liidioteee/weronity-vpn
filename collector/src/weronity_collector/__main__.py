"""CLI: ``weronity-collector {run,validate,stats,schema}``."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from pathlib import Path

from . import __version__
from .harvest import harvest
from .pipeline.build import build_pool
from .schema import json_schema, validate_file
from .sources.base import RawDocument
from .sources.github import GitHubRepoSource


def _add_run(sub: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    p = sub.add_parser("run", help="collect nodes and write nodes_pool.json")
    p.add_argument("--out", default="out/nodes_pool.json", type=Path)
    p.add_argument("--source-repo", default="igareck/vpn-configs-for-russia")
    p.add_argument("--ref", default="HEAD")
    p.add_argument("--geoip-dir", default="geoip", type=Path)
    p.add_argument("--seen", default="state/seen.json", type=Path)
    p.add_argument("--timeout-ms", type=int, default=2000)
    p.add_argument("--concurrency", type=int, default=64)
    p.add_argument("--recommend-per-country", type=int, default=15)
    p.add_argument("--keep-dead", action="store_true", help="do not drop unreachable nodes")
    p.add_argument("--source-run", default=None, help="opaque CI run id for provenance")
    p.add_argument(
        "--offline",
        type=Path,
        metavar="DIR",
        help="read *.txt/*.yaml from DIR instead of fetching the source",
    )


def _load_offline(directory: Path) -> list[RawDocument]:
    docs: list[RawDocument] = []
    for path in sorted(directory.rglob("*")):
        if path.suffix.lower() not in (".txt", ".yaml", ".yml", ".json", ".b64"):
            continue
        doc = RawDocument(
            source=f"offline:{directory.name}",
            source_file=str(path.relative_to(directory)),
            content=path.read_text("utf-8", "replace"),
        )
        doc.kind = doc.detect_kind()
        docs.append(doc)
    return docs


def cmd_run(args: argparse.Namespace) -> int:
    if args.offline:
        docs = _load_offline(args.offline)
    else:
        docs = list(GitHubRepoSource(args.source_repo, args.ref).fetch())
    logging.info("fetched %d documents", len(docs))

    parsed, hstats = harvest(docs)
    logging.info(
        "harvested %d nodes (%d failed) from %d docs",
        hstats.parsed,
        hstats.failed,
        hstats.documents,
    )
    if not parsed:
        logging.error("no nodes parsed — aborting")
        return 2

    pool = asyncio.run(
        build_pool(
            parsed,
            geoip_dir=args.geoip_dir,
            seen_path=args.seen,
            source_run=args.source_run,
            timeout_ms=args.timeout_ms,
            ping_concurrency=args.concurrency,
            recommend_per_country=args.recommend_per_country,
            keep_dead=args.keep_dead,
        )
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(pool.model_dump(by_alias=True), ensure_ascii=False, indent=1), "utf-8"
    )
    s = pool.stats
    logging.info("wrote %s — %d nodes | %s | lifetime %s", args.out, s.total, s.by_protocol, s.by_lifetime)
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    pool, err = validate_file(args.file)
    if err:
        print(f"INVALID: {err}", file=sys.stderr)
        return 1
    assert pool is not None
    print(f"OK: {pool.stats.total} nodes, schema v{pool.schema_version}, generated {pool.generated_at}")
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    pool, err = validate_file(args.file)
    if err:
        print(f"INVALID: {err}", file=sys.stderr)
        return 1
    assert pool is not None
    s = pool.stats
    print(f"total: {s.total}")
    for title, d in (("protocol", s.by_protocol), ("country", s.by_country), ("lifetime", s.by_lifetime)):
        print(f"\nby {title}:")
        for k, v in sorted(d.items(), key=lambda kv: -kv[1]):
            print(f"  {k:<16} {v}")
    rec = sum(1 for n in pool.nodes if n.recommended)
    print(f"\nrecommended: {rec}/{s.total}")
    return 0


def cmd_schema(_args: argparse.Namespace) -> int:
    print(json.dumps(json_schema(), indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="weronity-collector")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="cmd", required=True)
    _add_run(sub)
    vp = sub.add_parser("validate", help="validate a nodes_pool.json against the schema")
    vp.add_argument("file", type=Path)
    sp = sub.add_parser("stats", help="print stats for a nodes_pool.json")
    sp.add_argument("file", type=Path)
    sub.add_parser("schema", help="print the JSON Schema")

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )
    return {
        "run": cmd_run,
        "validate": cmd_validate,
        "stats": cmd_stats,
        "schema": cmd_schema,
    }[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
