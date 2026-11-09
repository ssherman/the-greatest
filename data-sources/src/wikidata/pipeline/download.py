"""Find, fetch and verify the newest Wikidata JSON dump and the redirect SQL.

Entity dumps live in `entities/<YYYYMMDD>/` directories whose name is NOT the file's date: dir
20261102 holds wikidata-20261105-all.json.gz. Some directories hold only lexeme files, so
discovery walks newest first until one holds the entity dump. Wikimedia allows two connections
per IP, so `download` never opens more than two.
"""

import email.utils
import hashlib
import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import httpx

ENTITIES_URL = "https://dumps.wikimedia.org/wikidatawiki/entities/"
REDIRECT_URL = "https://dumps.wikimedia.org/wikidatawiki/latest/wikidatawiki-latest-redirect.sql.gz"
PAGE_URL = "https://dumps.wikimedia.org/wikidatawiki/latest/wikidatawiki-latest-page.sql.gz"
USER_AGENT = "TheGreatest/1.0 (https://thegreatestbooks.org)"
MAX_CONNECTIONS = 2
CHUNK = 8 << 20

_DIR = re.compile(r'href="(\d{8})/"')
_FILE = re.compile(r'href="(?:[^"]*/)?wikidata-(\d{8})-all\.json\.gz"')


class DumpNotFound(RuntimeError):
    """No entity directory holds a full JSON dump."""


class DownloadError(RuntimeError):
    """A download could not be completed or verified."""


@dataclass(frozen=True)
class Dump:
    dump_date: str  # YYYY-MM-DD, from the file name
    url: str
    md5: str


def make_client() -> httpx.Client:
    return httpx.Client(
        headers={"User-Agent": USER_AGENT},
        timeout=httpx.Timeout(30.0, read=600.0),
        follow_redirects=True,
    )


def _iso(compact: str) -> str:
    return f"{compact[:4]}-{compact[4:6]}-{compact[6:]}"


def _md5_for(client: httpx.Client, dir_url: str, compact: str) -> str:
    name = f"wikidata-{compact}-all.json.gz"
    response = client.get(f"{dir_url}wikidata-{compact}-md5sums.txt")
    response.raise_for_status()
    for line in response.text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == name:
            return parts[0].lower()
    raise DumpNotFound(f"no md5 for {name} in {dir_url}")


def discover_latest(client: httpx.Client) -> Dump:
    listing = client.get(ENTITIES_URL)
    listing.raise_for_status()
    for directory in sorted(set(_DIR.findall(listing.text)), reverse=True):
        dir_url = f"{ENTITIES_URL}{directory}/"
        response = client.get(dir_url)
        response.raise_for_status()
        match = _FILE.search(response.text)
        if not match:
            continue
        compact = match.group(1)
        return Dump(
            dump_date=_iso(compact),
            url=f"{dir_url}wikidata-{compact}-all.json.gz",
            md5=_md5_for(client, dir_url, compact),
        )
    raise DumpNotFound("no entity directory holds wikidata-<date>-all.json.gz")


def _size(client: httpx.Client, url: str) -> int:
    response = client.head(url)
    response.raise_for_status()
    return int(response.headers["content-length"])


def _fetch_part(client: httpx.Client, url: str, part: Path, start: int, end: int) -> None:
    """Fetch bytes [start, end] into `part`, resuming whatever is already there."""
    wanted = end - start + 1
    have = part.stat().st_size if part.exists() else 0
    if have > wanted:
        part.unlink()
        have = 0
    if have == wanted:
        return
    with client.stream("GET", url, headers={"Range": f"bytes={start + have}-{end}"}) as response:
        if response.status_code != 206:
            raise DownloadError(
                f"{url}: expected 206 for a range request, got {response.status_code}"
            )
        with part.open("ab") as out:
            for chunk in response.iter_bytes(CHUNK):
                out.write(chunk)
    if part.stat().st_size != wanted:
        raise DownloadError(f"{part.name}: short read, expected {wanted} bytes")


def _md5_of(path: Path) -> str:
    digest = hashlib.md5()  # noqa: S324 - integrity check against Wikimedia's md5
    with path.open("rb") as src:
        while chunk := src.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def download(
    dump: Dump, dest_dir: Path, *, client: httpx.Client, connections: int = MAX_CONNECTIONS
) -> Path:
    if not 1 <= connections <= MAX_CONNECTIONS:
        raise ValueError(f"connections must be 1..{MAX_CONNECTIONS}, got {connections}")
    dest_dir.mkdir(parents=True, exist_ok=True)
    target = dest_dir / dump.url.rsplit("/", 1)[1]
    if target.exists():
        # A rerun after a failed distill: keep a verified copy, never hold two.
        if _md5_of(target) == dump.md5:
            return target
        target.unlink()
    size = _size(client, dump.url)
    step = -(-size // connections)
    ranges = [
        (i * step, min(size, (i + 1) * step) - 1) for i in range(connections) if i * step < size
    ]
    parts = [target.with_name(f"{target.name}.part{i}") for i in range(len(ranges))]

    with ThreadPoolExecutor(max_workers=len(ranges)) as pool:
        futures = [
            pool.submit(_fetch_part, client, dump.url, part, start, end)
            for part, (start, end) in zip(parts, ranges, strict=True)
        ]
        for future in futures:
            future.result()

    digest = hashlib.md5()  # noqa: S324 - Wikimedia publishes md5; this is an integrity check
    with target.open("wb") as out:
        for part in parts:
            with part.open("rb") as src:
                while chunk := src.read(CHUNK):
                    digest.update(chunk)
                    out.write(chunk)
            part.unlink()  # free the space as we go: the dump is over 100 GB
    if digest.hexdigest() != dump.md5:
        target.unlink()
        raise DownloadError(f"md5 mismatch for {target.name}: {digest.hexdigest()} != {dump.md5}")
    return target


def _fetch_whole(client: httpx.Client, url: str, target: Path) -> tuple[Path, str | None]:
    """Returns the file and the server's Last-Modified as an ISO date (None if absent)."""
    partial = target.with_name(target.name + ".part")
    with client.stream("GET", url) as response:
        response.raise_for_status()
        modified = _http_date(response.headers.get("last-modified"))
        with partial.open("wb") as out:
            for chunk in response.iter_bytes(CHUNK):
                out.write(chunk)
    shutil.move(partial, target)
    return target, modified


def _http_date(value: str | None) -> str | None:
    try:
        return email.utils.parsedate_to_datetime(value).date().isoformat() if value else None
    except (TypeError, ValueError):
        return None


def download_redirect_sources(
    dest_dir: Path, *, client: httpx.Client
) -> tuple[Path, Path, str | None]:
    """The redirect and page SQL dumps, plus the redirect dump's date (its Last-Modified).
    These live in `latest/`, so their date can trail the JSON dump's by weeks."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    redirect, redirects_date = _fetch_whole(
        client, REDIRECT_URL, dest_dir / "wikidatawiki-latest-redirect.sql.gz"
    )
    page, _ = _fetch_whole(client, PAGE_URL, dest_dir / "wikidatawiki-latest-page.sql.gz")
    return redirect, page, redirects_date
