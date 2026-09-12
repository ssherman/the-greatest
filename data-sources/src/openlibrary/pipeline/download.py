"""Fetch the six dumps and discover which dated version they are.

`ol_dump_<kind>_latest.txt.gz` 302s to an archive.org URL that carries the dump
date, so the pipeline never has to be told which version it is building. All six
must agree: a split date means Open Library is mid-publication and the artifact
would mix two catalogs.
"""

from __future__ import annotations

import re
from pathlib import Path

import httpx

DUMP_KINDS = ("works", "authors", "editions", "redirects", "ratings", "reading-log")
LATEST_TEMPLATE = "https://openlibrary.org/data/ol_dump_{kind}_latest.txt.gz"
_DATE_IN_URL = re.compile(r"ol_dump_[a-z-]+_(\d{4}-\d{2}-\d{2})\.txt\.gz")


class DumpDateMismatch(RuntimeError):
    """The six dumps do not all resolve to the same date."""


class DumpDateUndiscoverable(RuntimeError):
    """The redirect target carried no dump date."""


def latest_url(kind: str) -> str:
    return LATEST_TEMPLATE.format(kind=kind)


def discover_dump_date(client: httpx.Client, kind: str) -> str:
    response = client.head(latest_url(kind), follow_redirects=True)
    match = _DATE_IN_URL.search(str(response.url))
    if not match:
        raise DumpDateUndiscoverable(f"no dump date in redirect target for {kind}: {response.url}")
    return match.group(1)


def discover_all_dump_dates(client: httpx.Client) -> dict[str, str]:
    dates = {kind: discover_dump_date(client, kind) for kind in DUMP_KINDS}
    distinct = set(dates.values())
    if len(distinct) != 1:
        raise DumpDateMismatch(f"dumps resolve to more than one date: {dates}")
    return dates


def download_all(root: Path, *, client: httpx.Client | None = None) -> tuple[str, dict[str, Path]]:
    owned = client is None
    client = client or httpx.Client(timeout=httpx.Timeout(30.0, read=600.0), follow_redirects=True)
    try:
        dates = discover_all_dump_dates(client)
        dump_date = next(iter(dates.values()))
        from .paths import ArtifactPaths

        paths = ArtifactPaths(root=root, dump_date=dump_date)
        paths.ensure()

        downloaded: dict[str, Path] = {}
        for kind in DUMP_KINDS:
            target = paths.dump(kind)
            url = latest_url(kind)
            with client.stream("GET", url) as response:
                response.raise_for_status()
                expected = int(response.headers.get("content-length", 0))
                if target.exists() and expected and target.stat().st_size == expected:
                    downloaded[kind] = target
                    continue
                partial = target.with_suffix(target.suffix + ".part")
                with partial.open("wb") as fh:
                    for chunk in response.iter_bytes(chunk_size=8 << 20):
                        fh.write(chunk)
                if expected and partial.stat().st_size != expected:
                    raise RuntimeError(
                        f"{kind}: downloaded {partial.stat().st_size:,} bytes, "
                        f"expected {expected:,}"
                    )
                partial.rename(target)
            downloaded[kind] = target
        return dump_date, downloaded
    finally:
        if owned:
            client.close()
