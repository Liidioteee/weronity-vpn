"""Track when each node was first/last seen across CI runs and derive its
lifetime class (``fresh`` / ``short_lived`` / ``long_lived``) and ``stability``.

State lives in ``state/seen.json`` (committed to the ``pool-data`` branch by CI):

    {
      "runs_total": 128,
      "window": 336,                         # hours the stability window spans
      "nodes": {
        "<stable_id>": {"first_seen": "...Z", "last_seen": "...Z", "seen_runs": 41}
      }
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from ..models import Lifetime

FRESH_MAX_H = 24
SHORT_MAX_H = 72  # > 72h → long_lived (ТЗ: «более 3 дней»)
DEFAULT_WINDOW_H = 24 * 14


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
        raw = json.loads(p.read_text("utf-8"))
        return cls(
            runs_total=int(raw.get("runs_total", 0)),
            window_h=int(raw.get("window", DEFAULT_WINDOW_H)),
            nodes=dict(raw.get("nodes", {})),
        )

    def save(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(
            json.dumps(
                {"runs_total": self.runs_total, "window": self.window_h, "nodes": self.nodes},
                indent=1,
                sort_keys=True,
            ),
            "utf-8",
        )

    # -- update ---------------------------------------------------------------
    def observe(self, present_ids: set[str], now: datetime | None = None) -> None:
        """Record a new CI run in which ``present_ids`` were seen."""
        now = now or datetime.now(UTC)
        stamp = now.replace(microsecond=0).isoformat().replace("+00:00", "Z")
        self.runs_total += 1
        for sid in present_ids:
            entry = self.nodes.get(sid)
            if entry is None:
                self.nodes[sid] = {"first_seen": stamp, "last_seen": stamp, "seen_runs": 1}
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
        stability = round(seen_runs / self.runs_total, 3) if self.runs_total else 0.0
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
