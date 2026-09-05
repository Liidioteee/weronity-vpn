"""JSON-Schema for ``nodes_pool.json`` and a validation helper."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from .models import Pool

__all__ = ["json_schema", "validate_pool", "validate_file"]


def json_schema() -> dict[str, Any]:
    schema = Pool.model_json_schema(by_alias=True)
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    schema["title"] = "Weronity nodes_pool.json"
    return schema


def validate_pool(data: dict[str, Any]) -> Pool:
    """Validate a decoded pool dict. Raises :class:`pydantic.ValidationError`."""
    return Pool.model_validate(data)


def validate_file(path: str | Path) -> tuple[Pool | None, str | None]:
    try:
        data = json.loads(Path(path).read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"cannot read/parse: {exc}"
    try:
        return validate_pool(data), None
    except ValidationError as exc:
        return None, str(exc)
