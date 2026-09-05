"""GitHub repository source.

During development the only configured source is
``github.com/igareck/vpn-configs-for-russia`` (all files). Uses the Git tree API
to enumerate blobs and downloads the text-like ones from ``raw.githubusercontent``.
Honours ``GITHUB_TOKEN`` for a higher rate limit.
"""

from __future__ import annotations

import os
from collections.abc import Iterable
from urllib.parse import quote

import httpx

from .base import RawDocument

_TEXT_SUFFIXES = (".txt", ".yaml", ".yml", ".json", ".conf", ".list", ".ini", "")
_SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".pdf", ".zip", ".gz")
_MAX_BYTES = 3_000_000


class GitHubRepoSource:
    def __init__(
        self,
        repo: str = "igareck/vpn-configs-for-russia",
        ref: str = "HEAD",
        *,
        timeout: float = 30.0,
        client: httpx.Client | None = None,
    ) -> None:
        self.repo = repo
        self.ref = ref
        self.name = f"github:{repo}"
        self._timeout = timeout
        self._client = client

    # -- helpers --------------------------------------------------------------
    def _headers(self) -> dict[str, str]:
        h = {"Accept": "application/vnd.github+json", "User-Agent": "weronity-collector"}
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            h["Authorization"] = f"Bearer {token}"
        return h

    def _list_blobs(self, client: httpx.Client) -> list[str]:
        url = f"https://api.github.com/repos/{self.repo}/git/trees/{self.ref}?recursive=1"
        resp = client.get(url, headers=self._headers())
        resp.raise_for_status()
        tree = resp.json().get("tree", [])
        paths: list[str] = []
        for entry in tree:
            if entry.get("type") != "blob":
                continue
            path = entry["path"]
            low = path.lower()
            if low.endswith(_SKIP_SUFFIXES):
                continue
            if entry.get("size", 0) > _MAX_BYTES:
                continue
            if low.endswith(_TEXT_SUFFIXES) or "base64" in low:
                paths.append(path)
        return paths

    # -- Source protocol ----------------------------------------------------
    def fetch(self) -> Iterable[RawDocument]:
        owns = self._client is None
        client = self._client or httpx.Client(timeout=self._timeout, follow_redirects=True)
        try:
            for path in self._list_blobs(client):
                raw_url = (
                    f"https://raw.githubusercontent.com/{self.repo}/{self.ref}/"
                    f"{quote(path)}"
                )
                r = client.get(raw_url, headers={"User-Agent": "weronity-collector"})
                if r.status_code != 200 or not r.text.strip():
                    continue
                doc = RawDocument(source=self.name, source_file=path, content=r.text)
                doc.kind = doc.detect_kind()
                yield doc
        finally:
            if owns:
                client.close()
