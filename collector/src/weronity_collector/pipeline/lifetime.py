"""Track when each node was first/last seen across CI runs and derive its
lifetime class (``fresh`` / ``short_lived`` / ``long_lived``) and ``stability``.

State lives in ``state/seen.json`` (committed to the ``pool-data`` branch by CI):

    {
      "runs_total": 128,
      "window": 336,                         # hours the stability window spans
      "nodes": {
        "<stable_id>": {"first_seen": "...Z", "last_seen": "...Z", "seen_runs": 41,
                        "first_run": 88}
      }
    }

``first_run`` is the value ``runs_total`` had when the node first appeared, so
``stability`` can be "share of the runs *since it appeared* in which it was
alive" — not a share of every run the collector has ever made, which would
sink towards zero for any node younger than the state file.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from ..models import Lifetime

FRESH_MAX_H = 24
SHORT_MAX_H = 72  # > 72h → long_lived (ТЗ: «более 3 дней»)
DEFAULT_WINDOW_H = 24 * 14

log = logging.getLogger(__name__)


def classify_age(age_hours: float) -> str:
    if age_hours < FRESH_MAX_H:
        return "fresh"
    if age_hours <= SHORT_MAX_H:
        return "short_lived"
    return "long_lived"


@dataclass(slots=True)
class SeenState:
    runs_total: int = 0
    window_h: int = DEFAULT_WINDOW_H
    nodes: dict[str, dict[str, Any]] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.nodes is None:
            self.nodes = {}

    # -- io ---------------------------------------------------------------
    @classmethod
    def load(cls, path: str | Path) -> SeenState:
        p = Path(path)
        if not p.is_file():
            return cls()
        try:
            raw = json.loads(p.read_text("utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("top level is not an object")
        except (OSError, ValueError) as exc:
            # A corrupt state file would otherwise fail every run from now on.
            # Losing the observation history is the lesser evil.
            log.error("seen state %s is unreadable (%s) — starting fresh", p, exc)
            return cls()
        return cls(
            runs_total=int(raw.get("runs_total", 0)),
            window_h=int(raw.get("window", DEFAULT_WINDOW_H)),
            nodes=dict(raw.get("nodes", {})),
        )

    def save(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(
            json.dumps(
                {"runs_total": self.runs_total, "window": self.window_h, "nodes": self.nodes},
                indent=1,
                sort_keys=True,
            ),
            "utf-8",
        )
        os.replace(tmp, p)  # atomic: a killed run never leaves a half-written file

    # -- update ---------------------------------------------------------------
    def observe(self, present_ids: set[str], now: datetime | None = None) -> None:
        """Record a new CI run in which ``present_ids`` were seen."""
        now = now or datetime.now(UTC)
        stamp = now.replace(microsecond=0).isoformat().replace("+00:00", "Z")
        self.runs_total += 1
        for sid in present_ids:
            entry = self.nodes.get(sid)
            if entry is None:
                self.nodes[sid] = {
                    "first_seen": stamp,
                    "last_seen": stamp,
                    "seen_runs": 1,
                    "first_run": self.runs_total,
                }
            else:
                entry["last_seen"] = stamp
                entry["seen_runs"] = int(entry.get("seen_runs", 0)) + 1
        self._prune(now)

    def _prune(self, now: datetime) -> None:
        cutoff = now - timedelta(hours=self.window_h)
        drop = [
            sid
            for sid, e in self.nodes.items()
            if _parse(str(e["last_seen"])) < cutoff
        ]
        for sid in drop:
            del self.nodes[sid]

    # -- derive -------------------------------------------------------------
    def lifetime_for(self, sid: str, now: datetime | None = None) -> Lifetime:
        now = now or datetime.now(UTC)
        entry = self.nodes[sid]
        first = _parse(str(entry["first_seen"]))
        last = _parse(str(entry["last_seen"]))
        age_h = max(0, int((now - first).total_seconds() // 3600))
        seen_runs = int(entry.get("seen_runs", 1))
        # Entries written before `first_run` existed: assume the node was present
        # in every run since it appeared (it starts at 1.0 and decays from there).
        first_run = int(entry.get("first_run", self.runs_total - seen_runs + 1))
        runs_since = max(1, self.runs_total - max(1, first_run) + 1)
        stability = round(seen_runs / runs_since, 3)
        return Lifetime.model_validate(
            {
                "first_seen": _fmt(first),
                "last_seen": _fmt(last),
                "age_hours": age_h,
                "class": classify_age(age_h),
                "seen_runs": seen_runs,
                "stability": min(stability, 1.0),
            }
        )


def _parse(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _fmt(d: datetime) -> str:
    return d.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
