"""Source implementations. Each exposes ``name`` and ``fetch() -> Iterable[RawDocument]``."""

from .base import RawDocument, Source
from .github import GitHubRepoSource

__all__ = ["GitHubRepoSource", "RawDocument", "Source"]
