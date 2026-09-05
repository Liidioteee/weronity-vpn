from __future__ import annotations

from datetime import UTC, datetime, timedelta

from weronity_collector.pipeline.lifetime import SeenState, classify_age


def test_classify_age_boundaries() -> None:
    assert classify_age(0) == "fresh"
    assert classify_age(23.9) == "fresh"
    assert classify_age(24) == "short_lived"
    assert classify_age(72) == "short_lived"
    assert classify_age(72.1) == "long_lived"
    assert classify_age(500) == "long_lived"


def test_seen_state_tracks_first_and_last_seen() -> None:
    t0 = datetime(2026, 9, 1, tzinfo=UTC)
    st = SeenState()
    st.observe({"a", "b"}, now=t0)
    st.observe({"a"}, now=t0 + timedelta(days=1))
    st.observe({"a"}, now=t0 + timedelta(days=4))

    assert st.runs_total == 3
    life_a = st.lifetime_for("a", now=t0 + timedelta(days=4))
    assert life_a.first_seen == "2026-09-01T00:00:00Z"
    assert life_a.last_seen == "2026-09-05T00:00:00Z"
    assert life_a.age_hours == 96
    assert life_a.class_ == "long_lived"
    assert life_a.seen_runs == 3
    assert life_a.stability == 1.0

    life_b = st.lifetime_for("b", now=t0 + timedelta(days=4))
    assert life_b.seen_runs == 1
    assert round(life_b.stability, 3) == round(1 / 3, 3)


def test_seen_state_prunes_stale_nodes() -> None:
    t0 = datetime(2026, 1, 1, tzinfo=UTC)
    st = SeenState(window_h=48)
    st.observe({"old", "new"}, now=t0)
    st.observe({"new"}, now=t0 + timedelta(hours=72))
    assert "old" not in st.nodes
    assert "new" in st.nodes


def test_seen_state_roundtrip(tmp_path) -> None:
    p = tmp_path / "seen.json"
    st = SeenState()
    st.observe({"x"}, now=datetime(2026, 5, 5, tzinfo=UTC))
    st.save(p)
    loaded = SeenState.load(p)
    assert loaded.runs_total == 1
    assert loaded.nodes["x"]["seen_runs"] == 1


def test_seen_state_load_missing_file(tmp_path) -> None:
    st = SeenState.load(tmp_path / "nope.json")
    assert st.runs_total == 0 and st.nodes == {}
