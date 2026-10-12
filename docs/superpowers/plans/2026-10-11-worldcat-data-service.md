# WorldCat Data Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only ISBN/OCLC exact-lookup service once from the Anna's Archive WorldCat dump, deploy it as a fourth small VM on the home server, and give Rails a reviewed genre/subject mapping plus an idempotent backfill that links WorldCat genres to our curated categories.

**Architecture:** A `worldcat` Python package beside `openlibrary` in `data-sources/`: a frame-parallel extractor over the seekable-zstd file writes Parquet shards, DuckDB distills them into four tables with gates and a manifest, and a FastAPI app serves exact lookups. Rails gets a typed client copied from the Open Library one, a one-time AI vocabulary mapping checked in as data, and a Sidekiq backfill that applies it additively.

**Tech Stack:** Python 3.12, `zstandard` (build only), DuckDB 1.5, FastAPI, typer, pytest; Rails 8, Faraday, WebMock/Mocha, Sidekiq, `OpenAI::BaseModel` structured output; Proxmox provisioning shell under `deployment/home-server/`.

**Spec:** `docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md`

## Global Constraints

- Run Python commands from `data-sources/`, Rails commands from `web-app/`. Docs live in `docs/` at the repo root.
- `uv sync --locked --extra fetcher --extra recommender --extra worldcat` is the install form once Task 1 adds the extra; `uv.lock` is regenerated with `uv lock` in Task 1 only. Every other task must not touch dependencies.
- `zstandard` is a `worldcat` extra only. It must never appear in `dependencies` (the Open Library image installs no extras).
- Python lint: `uv run ruff check .` and `uv run ruff format --check .` must pass. Line length 100.
- Rails lint is `bundle exec standardrb` (never `bin/rubocop`). Tests are Minitest 6: use `assert_nil`, never `assert_equal nil`.
- HTTP in Rails tests is stubbed with WebMock (`stub_request`); everything else with Mocha. The breaker takes a `Books::OpenLibrary::FakeRedis` in tests; never touch `REDIS_POOL`.
- Sidekiq jobs are generated with `bin/rails generate sidekiq:job`, live in `app/sidekiq/`, and use `queue: :low`.
- Services live in `app/lib/services/<domain>/` and return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- AI response schemas are `OpenAI::BaseModel` subclasses; `to_json_schema` is a class method.
- The new Rails setting is `WORLDCAT_SERVICE_URL` (the `*_SERVICE_URL` convention). Cloudflare Access credentials reuse `CLOUDFLARE_ACCESS_CLIENT_ID`/`SECRET` through `CloudflareAccess::Credentials.from_env`.
- The service has no `/healthz`: like the Open Library API its only meta route is `GET /version`, and the heartbeat curls that.
- The artifact is static. No downloader, no refresh timer, no promotion; `WC_DATA_VERSION` is set by hand to `2025-09-04`.
- Nothing from WorldCat is created as a category. Genres link to existing `Books::Category` genre rows; subjects resolve against existing subject rows or are counted as unresolved.
- Commit after every task on the worktree branch `worktree-worldcat-data-service`. Never push without asking.

## Review Focus

1. **An ISBN-10 ending in `X` or with hyphens on `GET /isbns/{isbn}`** must normalise to its ISBN-13 and answer, not 422. Pinned in Task 9 (`test_isbn10_with_x_and_hyphens_is_normalised`).
2. **A record whose only ISBN fails its check digit** must still be in `records` (keyed by OCLC) but must not create an `isbns` row that a lookup can hit. Pinned in Task 5 (`test_bad_checksum_isbn_is_kept_on_the_record_but_not_indexed`).
3. **The same OCLC number across two passes with different genre** must yield one row carrying the newest pass's genre, never a union of both. Pinned in Task 5 (`test_duplicate_passes_collapse_to_the_newest`).
4. **A book with one matched record whose single genre term maps to a genre** must receive it (the single-record exception), while a stray term on one of thirty records must not. Pinned in Task 19 (`test_single_record_book_gets_its_genre` and `test_stray_term_on_one_of_many_records_is_ignored`).
5. **A tripped circuit breaker mid-backfill** must stop the run and leave untouched books untouched, never mark them done. Pinned in Task 20 (`test_an_open_circuit_stops_the_run_without_skipping_books`).

---

## File Structure

**Python (`data-sources/`)**

| Path | Responsibility |
|---|---|
| `src/worldcat/__init__.py` | `__version__` |
| `src/worldcat/pipeline/paths.py` | `WorldcatPaths`: the one owner of `<root>/versions/<date>/…` |
| `src/worldcat/pipeline/seektable.py` | parse the seekable-zstd seek table; split frames into worker ranges |
| `src/worldcat/pipeline/extract.py` | per-worker frame decode, byte pre-filter, record reduction, Parquet shard writer |
| `src/worldcat/pipeline/distill.py` | DuckDB SQL: pass ranking, `records`, `isbns`, `redirects`, `holdings` |
| `src/worldcat/pipeline/gates.py` | the seven gates |
| `src/worldcat/pipeline/report.py` | `build_report.json`, `manifest.json`, `PIPELINE_VERSION` |
| `src/worldcat/pipeline/build.py` | typer CLI; stage order; `BuildFailed` |
| `src/worldcat/api/deps.py` | `Settings` (`WC_*` env), `ArtifactState`, `open_artifact`, `cursor` |
| `src/worldcat/api/schemas.py` | `Record`, `Holdings`, `IsbnResponse`, `LookupRequest/Response` |
| `src/worldcat/api/retrieval.py` | `/isbns/{isbn}`, `/oclc/{number}`, `/lookup` |
| `src/worldcat/api/meta.py` | `/version` |
| `src/worldcat/api/main.py` | app factory |
| `worldcat.Dockerfile`, `docker-compose.yml` (`worldcat` service) | image and local compose |
| `tests/fixtures/worldcat/sample.jsonl` | committed corpus (plain JSONL, ~300 lines) |
| `tests/fixtures/worldcat/seekable.py` | `write_seekable(lines, path, frame_lines)` test writer |
| `tests/fixtures/worldcat/extract_fixtures.py` | regenerates the corpus from the real file |
| `tests/fixtures/worldcat/test_fixture_corpus.py` | negative-class assertions |
| `tests/worldcat/…` | one test module per source module |

**Deployment (`deployment/home-server/`)**: `lib/vm.sh`, `lib/common.sh`, `lib/verify.sh`, `provision`, `host/firewall/130.fw`, `compose.worldcat.yml`, `compose.tunnel.yml`, `guest/{lib,compose,deploy,first-boot,install-units,heartbeat}.sh`, `test/*_test.sh`, `docs/features/home-server.md`.

**Rails (`web-app/`)**

| Path | Responsibility |
|---|---|
| `app/lib/books/world_cat/{configuration,exceptions,base_client,client,record}.rb` | typed client |
| `app/lib/books/world_cat/isbn_export.rb` | our ISBN-13s to a file for the coverage gate |
| `app/lib/books/world_cat/genre_map.rb` | loads `config/worldcat/genre_map.yml`; term → verdict |
| `app/lib/services/books/world_cat/vocabulary_snapshot.rb` | counts genre terms over our matched records |
| `app/lib/services/ai/tasks/books/world_cat_genre_mapping_task.rb` | the structured-output task |
| `app/lib/services/books/world_cat/map_vocabulary.rb` | runs the task in batches, writes the YAML |
| `app/lib/services/books/world_cat/mapping_report.rb` | the two reports |
| `app/lib/services/books/world_cat/apply_aliases.rb` | alternative names on genre categories |
| `app/lib/services/books/world_cat/apply_categories.rb` | one book + its records → category links |
| `app/lib/services/books/world_cat/backfill.rb` | the run: batches, lock, breaker handling |
| `app/sidekiq/books/world_cat_backfill_job.rb` | queues the run |
| `lib/tasks/worldcat.rake` | `worldcat:{export_isbns,vocabulary,map,report,apply_aliases,backfill}` |
| `config/worldcat/genre_map.yml`, `genre_terms.csv`, `genre_terms_tail.csv` | the data files (produced by the rake tasks; the YAML is committed after review) |
| `docs/features/worldcat-data-service.md`, `docs/launch-todo.md` | feature doc and owner steps |

---

### Task 1: Package skeleton, extra, CI

**Files:**
- Create: `data-sources/src/worldcat/__init__.py`, `data-sources/src/worldcat/pipeline/__init__.py`, `data-sources/src/worldcat/api/__init__.py`, `data-sources/tests/worldcat/__init__.py`, `data-sources/tests/fixtures/worldcat/__init__.py`
- Modify: `data-sources/pyproject.toml` (extras, hatch packages), `data-sources/uv.lock` (via `uv lock`), `data-sources/tests/test_packaging.py`, `.github/workflows/ci.yml` (python job install line), `data-sources/.dockerignore`

**Interfaces:**
- Produces: importable `worldcat` package; `uv sync --locked --extra worldcat` installs `zstandard`.

- [ ] **Step 1: Write the failing packaging test**

Append to `data-sources/tests/test_packaging.py`:

```python
def test_worldcat_is_a_sibling_source_not_part_of_openlibrary():
    import worldcat

    assert worldcat.__version__ == "0.1.0"
    assert "openlibrary" not in worldcat.__file__


def test_zstandard_is_an_extra_not_a_core_dependency():
    import tomllib
    from pathlib import Path

    project = tomllib.loads((Path(__file__).parent.parent / "pyproject.toml").read_text())["project"]
    assert not any(dep.startswith("zstandard") for dep in project["dependencies"])
    assert any(dep.startswith("zstandard") for dep in project["optional-dependencies"]["worldcat"])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd data-sources && uv run pytest tests/test_packaging.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'worldcat'`

- [ ] **Step 3: Create the package and declare the extra**

`src/worldcat/__init__.py`:
```python
__version__ = "0.1.0"
```
`src/worldcat/pipeline/__init__.py` and `src/worldcat/api/__init__.py`: empty files. `tests/worldcat/__init__.py` and `tests/fixtures/worldcat/__init__.py`: empty files.

In `pyproject.toml`, under `[project.optional-dependencies]` add:
```toml
# The WorldCat build reads the Anna's Archive seekable-zstd dump. Build only:
# the API image never decompresses anything, so this stays out of the core set.
worldcat = ["zstandard>=0.23,<0.24"]
```
and change the hatch line to:
```toml
packages = ["src/common", "src/openlibrary", "src/fetcher", "src/recommender", "src/worldcat"]
```
Then `uv lock` and `uv sync --locked --extra fetcher --extra recommender --extra worldcat`.

In `.github/workflows/ci.yml`, the python job's install step becomes:
```yaml
        run: uv sync --locked --extra fetcher --extra recommender --extra worldcat
```
In `data-sources/.dockerignore` add the lines `*.zst` and `*.jsonl`.

In `AGENTS.md`, the sentence naming the install form (`uv sync --locked --extra fetcher --extra recommender`) gains `--extra worldcat` in both places it appears.

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/test_packaging.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add data-sources/src/worldcat data-sources/tests/worldcat data-sources/tests/fixtures/worldcat data-sources/pyproject.toml data-sources/uv.lock data-sources/tests/test_packaging.py data-sources/.dockerignore .github/workflows/ci.yml AGENTS.md
git commit -m "WorldCat: package skeleton and the worldcat extra"
```

---

### Task 2: Paths and the seek table

**Files:**
- Create: `data-sources/src/worldcat/pipeline/paths.py`, `data-sources/src/worldcat/pipeline/seektable.py`, `data-sources/tests/fixtures/worldcat/seekable.py`
- Test: `data-sources/tests/worldcat/test_paths.py`, `data-sources/tests/worldcat/test_seektable.py`

**Interfaces:**
- Produces: `WorldcatPaths(root, dump_date)` with `.version_dir`, `.staging_dir`, `.tmp_dir`, `.manifest_path`, `.report_path`, `.table(name)`, `.shard(worker, index)`, `.ensure()`; `TABLES = ("records", "isbns", "redirects", "holdings")`.
- Produces: `Frame(index, offset, compressed_size, decompressed_size)`; `read_seek_table(path) -> list[Frame]`; `frame_ranges(n_frames, workers) -> list[tuple[int, int]]`.
- Produces (tests only): `write_seekable(lines: list[bytes], path: Path, *, frame_lines: int) -> int` returning the frame count.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_paths.py`:
```python
from pathlib import Path

from worldcat.pipeline.paths import TABLES, WorldcatPaths


def test_layout_is_versions_slash_date(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    assert paths.version_dir == tmp_path / "versions" / "2025-09-04"
    assert paths.staging_dir == paths.version_dir / "_staging"
    assert paths.table("records") == paths.version_dir / "records.parquet"
    assert paths.shard(3, 7) == paths.staging_dir / "shard_003_00007.parquet"
    assert paths.manifest_path == paths.version_dir / "manifest.json"
    assert paths.tmp_dir == tmp_path / "tmp"


def test_ensure_creates_every_directory(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    for directory in (paths.version_dir, paths.staging_dir, paths.tmp_dir):
        assert directory.is_dir()


def test_tables_are_the_four_in_the_spec():
    assert TABLES == ("records", "isbns", "redirects", "holdings")
```

`tests/fixtures/worldcat/seekable.py` (a test helper, not a test):
```python
"""Write a zstd *seekable* file the way the Anna's Archive dump is written:
one standard zstd frame per chunk, then a skippable frame holding the seek
table (zstd's seekable format, magic 0x8F92EAB1, no checksums)."""

import struct
from pathlib import Path

import zstandard

SEEKABLE_MAGIC = 0x8F92EAB1
SKIPPABLE_MAGIC = 0x184D2A5E


def write_seekable(lines: list[bytes], path: Path, *, frame_lines: int) -> int:
    compressor = zstandard.ZstdCompressor(level=3)
    entries: list[tuple[int, int]] = []
    with path.open("wb") as out:
        for start in range(0, len(lines), frame_lines):
            raw = b"".join(line + b"\n" for line in lines[start : start + frame_lines])
            frame = compressor.compress(raw)
            out.write(frame)
            entries.append((len(frame), len(raw)))
        table = b"".join(struct.pack("<II", c, d) for c, d in entries)
        footer = struct.pack("<IBI", len(entries), 0, SEEKABLE_MAGIC)
        body = table + footer
        out.write(struct.pack("<II", SKIPPABLE_MAGIC, len(body)))
        out.write(body)
    return len(entries)
```

`tests/worldcat/test_seektable.py`:
```python
from pathlib import Path

import pytest
import zstandard

from tests.fixtures.worldcat.seekable import write_seekable
from worldcat.pipeline.seektable import Frame, frame_ranges, read_seek_table


def test_reads_every_frame_with_offsets_that_chain(tmp_path: Path):
    path = tmp_path / "sample.jsonl.seekable.zst"
    lines = [b'{"n":%d}' % i for i in range(25)]
    assert write_seekable(lines, path, frame_lines=10) == 3

    frames = read_seek_table(path)

    assert [f.index for f in frames] == [0, 1, 2]
    assert frames[0].offset == 0
    assert frames[1].offset == frames[0].compressed_size
    assert frames[2].offset == frames[1].offset + frames[1].compressed_size
    with path.open("rb") as fh:
        fh.seek(frames[2].offset)
        raw = zstandard.ZstdDecompressor().decompress(
            fh.read(frames[2].compressed_size), max_output_size=frames[2].decompressed_size
        )
    assert raw == b'{"n":20}\n{"n":21}\n{"n":22}\n{"n":23}\n{"n":24}\n'


def test_a_plain_zstd_file_is_refused(tmp_path: Path):
    path = tmp_path / "plain.zst"
    path.write_bytes(zstandard.ZstdCompressor().compress(b"hello\n"))
    with pytest.raises(ValueError, match="seekable"):
        read_seek_table(path)


def test_frame_ranges_cover_every_frame_once_in_order():
    ranges = frame_ranges(10, 3)
    assert ranges == [(0, 3), (3, 6), (6, 10)]
    assert frame_ranges(2, 8) == [(0, 1), (1, 2)]


def test_frame_is_a_plain_record():
    frame = Frame(index=0, offset=0, compressed_size=5, decompressed_size=9)
    assert frame.decompressed_size == 9
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_paths.py tests/worldcat/test_seektable.py -v`
Expected: FAIL with `ModuleNotFoundError` for `worldcat.pipeline.paths` / `worldcat.pipeline.seektable`

- [ ] **Step 3: Implement paths and the seek-table reader**

`src/worldcat/pipeline/paths.py`:
```python
"""The one owner of the artifact's directory layout.

    <root>/versions/<dump-date>/<table>.parquet
    <root>/versions/<dump-date>/_staging/shard_<worker>_<index>.parquet   (deleted on success)
    <root>/versions/<dump-date>/manifest.json
    <root>/versions/<dump-date>/build_report.json
    <root>/tmp/                                                           (DuckDB spill)

There is no dumps/ directory: the source file is wherever the operator says
(--source) and is read once. The API opens an explicit <dump-date> directory,
never a symlink and never "the latest".
"""

from dataclasses import dataclass
from pathlib import Path

TABLES = ("records", "isbns", "redirects", "holdings")


@dataclass(frozen=True)
class WorldcatPaths:
    root: Path
    dump_date: str

    @property
    def version_dir(self) -> Path:
        return self.root / "versions" / self.dump_date

    @property
    def staging_dir(self) -> Path:
        return self.version_dir / "_staging"

    @property
    def tmp_dir(self) -> Path:
        return self.root / "tmp"

    @property
    def manifest_path(self) -> Path:
        return self.version_dir / "manifest.json"

    @property
    def report_path(self) -> Path:
        return self.version_dir / "build_report.json"

    def table(self, name: str) -> Path:
        return self.version_dir / f"{name}.parquet"

    def shard(self, worker: int, index: int) -> Path:
        return self.staging_dir / f"shard_{worker:03d}_{index:05d}.parquet"

    def ensure(self) -> None:
        for directory in (self.version_dir, self.staging_dir, self.tmp_dir):
            directory.mkdir(parents=True, exist_ok=True)
```

`src/worldcat/pipeline/seektable.py`:
```python
"""Read the seek table a zstd *seekable* file carries in its last frame.

The dump is 277,369 independent zstd frames of ~10.5 MB followed by one
skippable frame listing every frame's compressed and decompressed size. With
that table a worker can decompress any frame on its own, which is what makes
the build parallel and a lookup by position cheap. Frames are decoded one at a
time on purpose: a streaming decoder that hits a read error is left in an
inconsistent state and then reports "data corruption" (measured 2026-10-10).
"""

import struct
from dataclasses import dataclass
from pathlib import Path

SEEKABLE_MAGIC = 0x8F92EAB1
FOOTER_SIZE = 9  # <I number_of_frames> <B descriptor> <I magic>
CHECKSUM_FLAG = 0x80


@dataclass(frozen=True)
class Frame:
    index: int
    offset: int
    compressed_size: int
    decompressed_size: int


def read_seek_table(path: Path) -> list[Frame]:
    size = path.stat().st_size
    with path.open("rb") as fh:
        fh.seek(size - FOOTER_SIZE)
        n_frames, descriptor, magic = struct.unpack("<IBI", fh.read(FOOTER_SIZE))
        if magic != SEEKABLE_MAGIC:
            raise ValueError(f"{path} is not a zstd seekable file (no seek table footer)")
        entry_size = 12 if descriptor & CHECKSUM_FLAG else 8
        fh.seek(size - FOOTER_SIZE - n_frames * entry_size)
        table = fh.read(n_frames * entry_size)
    frames: list[Frame] = []
    offset = 0
    for index in range(n_frames):
        compressed, decompressed = struct.unpack_from("<II", table, index * entry_size)
        frames.append(Frame(index, offset, compressed, decompressed))
        offset += compressed
    return frames


def frame_ranges(n_frames: int, workers: int) -> list[tuple[int, int]]:
    """Contiguous [start, end) frame ranges, one per worker, never empty."""
    workers = max(1, min(workers, n_frames))
    bounds = [n_frames * i // workers for i in range(workers + 1)]
    return [(bounds[i], bounds[i + 1]) for i in range(workers)]
```

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat/test_paths.py tests/worldcat/test_seektable.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add data-sources/src/worldcat/pipeline/paths.py data-sources/src/worldcat/pipeline/seektable.py data-sources/tests/fixtures/worldcat/seekable.py data-sources/tests/worldcat/test_paths.py data-sources/tests/worldcat/test_seektable.py
git commit -m "WorldCat: artifact paths and the seekable-zstd seek table"
```

---
### Task 3: The fixture corpus and its negative class

**Files:**
- Create: `data-sources/tests/fixtures/worldcat/extract_fixtures.py`, `data-sources/tests/fixtures/worldcat/sample.jsonl` (generated, committed), `data-sources/tests/fixtures/worldcat/test_fixture_corpus.py`
- Modify: `data-sources/tests/fixtures/worldcat/seekable.py` (add `frame_bytes`), `data-sources/tests/conftest.py` (two session fixtures)

**Interfaces:**
- Produces: `sample.jsonl`, one dump line per row, plus synthetic rows tagged `"_synthetic"` inside `metadata`.
- Produces: `write_seekable(lines, path, *, frame_lines=None, frame_bytes=None)`; with `frame_bytes` the byte stream is cut every N bytes so lines span frames, as in the real file.
- Produces (conftest): `worldcat_source` (a seekable file built from the corpus with `frame_bytes=4096`) and `worldcat_artifact` (a `WorldcatPaths` for a built artifact, session-scoped, read-only to consumers).
- Consumes: `read_seek_table`, `Frame` (Task 2).

- [ ] **Step 1: Extend the seekable writer**

Replace `write_seekable` in `tests/fixtures/worldcat/seekable.py` with:
```python
def write_seekable(
    lines: list[bytes], path: Path, *, frame_lines: int | None = None, frame_bytes: int | None = None
) -> int:
    if (frame_lines is None) == (frame_bytes is None):
        raise ValueError("give exactly one of frame_lines or frame_bytes")
    if frame_lines is not None:
        chunks = [
            b"".join(line + b"\n" for line in lines[i : i + frame_lines])
            for i in range(0, len(lines), frame_lines)
        ]
    else:
        stream = b"".join(line + b"\n" for line in lines)
        chunks = [stream[i : i + frame_bytes] for i in range(0, len(stream), frame_bytes)]
    compressor = zstandard.ZstdCompressor(level=3)
    entries: list[tuple[int, int]] = []
    with path.open("wb") as out:
        for raw in chunks:
            frame = compressor.compress(raw)
            out.write(frame)
            entries.append((len(frame), len(raw)))
        table = b"".join(struct.pack("<II", c, d) for c, d in entries)
        footer = struct.pack("<IBI", len(entries), 0, SEEKABLE_MAGIC)
        body = table + footer
        out.write(struct.pack("<II", SKIPPABLE_MAGIC, len(body)))
        out.write(body)
    return len(entries)
```
Run `uv run pytest tests/worldcat/test_seektable.py -v`: still PASS (the existing calls pass `frame_lines=`).

- [ ] **Step 2: Write the extractor script**

`tests/fixtures/worldcat/extract_fixtures.py`:
```python
"""Regenerate sample.jsonl from the real dump. Run by hand; the output is committed.

    uv run python tests/fixtures/worldcat/extract_fixtures.py \
        --source "/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst"

Selection is by explicit OCLC number, never "the first N lines": every line the
dump holds for each seeded number (all passes, all types) is kept, in file order,
then the synthetic rows below are appended. The real file is sorted by 13-digit
zero-padded OCLC number, so one number is a binary search over frame first keys.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import zstandard

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "src"))
from worldcat.pipeline.seektable import read_seek_table  # noqa: E402

OUT = Path(__file__).parent / "sample.jsonl"
R_OCLC = re.compile(rb'"oclc_number":"(\d{13})"')

# Each seed is there for a reason; keep the comment when you add one.
SEED_OCLCS = [
    1,  # the first record: Book, no ISBN, French + English subjects, four scrape passes
    1055766559,  # Atomic Habits: canary; three title passes, brief from the editions endpoint, holdings
    1000415078,  # The Hobbit: canary; one title + one brief, "Fiction" genre
    1002380292,  # A Game of Thrones: canary; six ISBNs on one record
    1003236695,  # redirect_title_json -> 37975719 (canary)
    37975719,  # the redirect target
    123177986,  # The 48 Laws of Power as AudioBook/CD: a NON-Book format that must be dropped
    1010924379,  # It Ends With Us (Polish): "Powieść" genre, pol cataloguing language
    676190796,  # a brief record from an ISBN range query (pass "range_query")
    11280578,  # Animal Farm (Danish): a Book title record with NO ISBN
]


def _title(oclc: str, pass_name: str, **record) -> dict:
    base = {
        "oclcNumber": oclc.lstrip("0"), "generalFormat": "Book", "specificFormat": "PrintBook",
        "contributors": [], "otherFormats": [], "publisher": None, "publicationPlace": None,
        "publicationDate": None, "edition": None, "physicalDescription": None, "series": None,
        "summary": None, "mergedOclcNumbers": None, "catalogingLanguage": "eng", "totalEditions": 1,
    }
    base.update(record)
    return {"metadata": {"oclc_number": oclc, "type": "title_json", "from_filenames": [pass_name], "record": base}}


def _tag(row: dict, tag: str, aacid: str) -> dict:
    row["aacid"] = f"aacid__worldcat__synthetic__{aacid}"
    row["metadata"]["_synthetic"] = tag
    return row


def _redirect(oclc: str, to: int, tag: str, aacid: str) -> dict:
    return _tag({"metadata": {"oclc_number": oclc, "type": "redirect_title_json",
                              "from_filenames": [f"w2/v7/0001/{aacid}"],
                              "record": {"redirected_oclc_number": to}}}, tag, aacid)


SYNTHETIC = [
    # A title record whose only ISBN fails its check digit: `isbns` must not index it.
    _tag(_title("0009000000001", "w2/v7/0001/1", title="Synthetic bad ISBN", creator="Nobody",
                isbns=["9780000000001"], genre="Fiction", subjectsText=["Fiction"], machineReadableDate="2001"),
         "bad_checksum", "badisbn"),
    # The Hobbit again in an OLDER pass with a different genre: the newest pass must win.
    _tag(_title("0001000415078", "2023_04_v3/1000/1000415078", title="The Hobbit (older pass)",
                creator="J. R. R. Tolkien", isbns=["0395476909", "9780395476901"], genre="STALE GENRE",
                subjectsText=["Fiction"], machineReadableDate="1989"),
         "older_pass", "olderpass"),
    # A redirect chain A -> B -> Atomic Habits, and a cycle D <-> E.
    _redirect("0009000000010", 9000000011, "chain", "chain1"),
    _redirect("0009000000011", 1055766559, "chain", "chain2"),
    _redirect("0009000000020", 9000000021, "cycle", "cycle1"),
    _redirect("0009000000021", 9000000020, "cycle", "cycle2"),
    # A second, later holdings summary for Atomic Habits: the higher pass index must win.
    _tag({"metadata": {"oclc_number": "0001055766559", "type": "search_holdings_summary_all_editions",
                       "from_filenames": ["search_holdings_summary_all_editions/2025-01-01_02.tar/9"],
                       "record": {"oclc_number": 1055766559, "total_holding_count": 4000, "total_editions": 25}}},
         "later_holdings", "holdings2"),
    # A brief record whose subjects are dicts, as some search responses return them.
    _tag({"metadata": {"oclc_number": "0009000000030", "type": "briefrecords_json",
                       "from_filenames": ["range_query/9780000###"],
                       "record": {"oclcNumber": "9000000030", "title": "Synthetic dict subjects", "creator": "Nobody",
                                  "generalFormat": "Book", "specificFormat": "PrintBook", "isbns": ["9780306406157"],
                                  "subjects": [{"text": "Science fiction"}, {"text": "Robots"}],
                                  "machineReadableDate": "1999", "catalogingLanguage": "eng", "publisher": "Nobody Press"}}},
         "dict_subjects", "dictsubjects"),
]


def lines_for(path: Path, frames, oclc: int) -> list[bytes]:
    key = str(oclc).zfill(13).encode()
    dctx = zstandard.ZstdDecompressor()
    cache: dict[int, bytes] = {}

    def frame(i: int) -> bytes:
        if i not in cache:
            f = frames[i]
            with path.open("rb") as fh:
                fh.seek(f.offset)
                cache[i] = dctx.decompress(fh.read(f.compressed_size), max_output_size=f.decompressed_size)
        return cache[i]

    def first_key(i: int) -> bytes | None:
        for ln in frame(i).split(b"\n")[1:3]:
            m = R_OCLC.search(ln)
            if m:
                return m.group(1)
        return None

    lo, hi = 0, len(frames) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        k = first_key(mid)
        if k is not None and k <= key:
            lo = mid
        else:
            hi = mid - 1
    out = []
    for i in (lo, lo + 1):
        if i >= len(frames):
            continue
        for ln in frame(i).split(b"\n"):
            if b'"oclc_number":"' + key + b'"' in ln:
                try:
                    json.loads(ln)
                except ValueError:
                    continue  # cut by a frame boundary; its other half is in the neighbour
                out.append(ln)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    args = ap.parse_args()
    frames = read_seek_table(args.source)
    kept: list[bytes] = []
    for oclc in SEED_OCLCS:
        found = lines_for(args.source, frames, oclc)
        if not found:
            raise SystemExit(f"OCLC {oclc} not found; the seed list is wrong")
        kept.extend(found)
    kept.extend(json.dumps(row, ensure_ascii=False).encode() for row in SYNTHETIC)
    OUT.write_bytes(b"\n".join(kept) + b"\n")
    print(f"{OUT.name}: {len(kept)} lines, {OUT.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
```

Run it once against the real file (on `/mnt/e`), then stage `tests/fixtures/worldcat/sample.jsonl`. Expected: about 45 lines, under 200 KB. Lines that span a frame boundary in the real file are skipped by `lines_for` and reported as missing only if a seed yields nothing; if that happens, pick a neighbouring frame by widening `(lo, lo + 1)` to `(lo - 1, lo, lo + 1)`.

- [ ] **Step 3: Write the corpus assertions**

`tests/fixtures/worldcat/test_fixture_corpus.py`:
```python
"""Every assertion below names a FAILING case the corpus must keep. If one
breaks after a regeneration, restore the row; deleting the assertion returns
the guard it protects to being untestable."""

import json
from pathlib import Path

CORPUS = Path(__file__).parent / "sample.jsonl"


def _rows():
    for line in CORPUS.read_text(encoding="utf-8").splitlines():
        yield json.loads(line)


def _records(kind: str):
    return [r for r in _rows() if r["metadata"]["type"] == kind]


def test_corpus_stays_small_enough_to_commit():
    assert CORPUS.stat().st_size < 400_000


def test_corpus_holds_the_four_canaries():
    numbers = {r["metadata"]["oclc_number"].lstrip("0") for r in _rows()}
    assert {"1055766559", "1000415078", "1002380292", "1003236695"} <= numbers


def test_corpus_contains_a_non_book_format_title():
    assert any(r["metadata"]["record"].get("generalFormat") != "Book" for r in _records("title_json"))


def test_corpus_contains_a_book_with_no_isbn():
    assert any(
        r["metadata"]["record"].get("generalFormat") == "Book" and not r["metadata"]["record"].get("isbns")
        for r in _records("title_json")
    )


def test_corpus_contains_an_isbn_with_a_wrong_check_digit():
    from common.normalize import normalize_isbn

    bad = [
        v
        for r in _records("title_json") + _records("briefrecords_json")
        for v in (r["metadata"]["record"].get("isbns") or [])
        if (n := normalize_isbn(v)) is not None and not n.checksum_ok
    ]
    assert bad, "no ISBN in the corpus fails its check digit"


def test_corpus_contains_the_same_oclc_in_two_passes_with_different_genre():
    by_oclc: dict[str, set] = {}
    for r in _records("title_json"):
        by_oclc.setdefault(r["metadata"]["oclc_number"], set()).add(r["metadata"]["record"].get("genre"))
    assert any(len(genres) > 1 for genres in by_oclc.values())


def test_corpus_contains_a_brief_only_record():
    titles = {r["metadata"]["oclc_number"] for r in _records("title_json")}
    assert any(r["metadata"]["oclc_number"] not in titles for r in _records("briefrecords_json"))


def test_corpus_contains_a_redirect_chain_and_a_cycle():
    to = {
        r["metadata"]["oclc_number"].lstrip("0"): str(r["metadata"]["record"]["redirected_oclc_number"])
        for r in _records("redirect_title_json")
    }
    assert any(target in to for target in to.values()), "no chain"
    assert any(to.get(to[src]) == src for src in to), "no cycle"


def test_corpus_contains_an_english_record_with_french_headings():
    assert any(
        r["metadata"]["record"].get("catalogingLanguage") == "eng"
        and any("Habitude" in s or "Romans" in s for s in (r["metadata"]["record"].get("subjectsText") or []))
        for r in _records("title_json")
    )


def test_corpus_contains_two_holdings_summaries_for_one_number():
    counts: dict[str, int] = {}
    for r in _records("search_holdings_summary_all_editions"):
        counts[r["metadata"]["oclc_number"]] = counts.get(r["metadata"]["oclc_number"], 0) + 1
    assert max(counts.values()) >= 2


def test_corpus_contains_a_brief_record_whose_subjects_are_dicts():
    assert any(
        isinstance((r["metadata"]["record"].get("subjects") or [None])[0], dict)
        for r in _records("briefrecords_json")
    )
```

- [ ] **Step 4: Add the session fixtures**

Append to `tests/conftest.py`:
```python
WORLDCAT_FIXTURE = Path(__file__).parent / "fixtures" / "worldcat" / "sample.jsonl"
WORLDCAT_DUMP_DATE = "2025-09-04"


@pytest.fixture(scope="session")
def worldcat_source(tmp_path_factory) -> Path:
    """The committed corpus as a seekable-zstd file cut every 4 KiB, so lines span frames."""
    from tests.fixtures.worldcat.seekable import write_seekable

    path = tmp_path_factory.mktemp("wc-source") / "sample.jsonl.seekable.zst"
    write_seekable(WORLDCAT_FIXTURE.read_bytes().splitlines(), path, frame_bytes=4096)
    return path


@pytest.fixture(scope="session")
def worldcat_artifact(tmp_path_factory, worldcat_source):
    """A real build of the corpus, once per session. Read-only for its consumers."""
    from worldcat.pipeline.build import build
    from worldcat.pipeline.paths import WorldcatPaths

    root = tmp_path_factory.mktemp("wc-artifact")
    build(source=worldcat_source, root=root, dump_date=WORLDCAT_DUMP_DATE, workers=2, memory_limit="1GB")
    return WorldcatPaths(root=root, dump_date=WORLDCAT_DUMP_DATE)
```
`worldcat_artifact` is first consumed in Task 7; until `build` exists nothing requests it.

- [ ] **Step 5: Run the corpus tests and lint**

Run: `uv run pytest tests/fixtures/worldcat -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 6: Commit**

Stage `data-sources/tests/fixtures/worldcat` and `data-sources/tests/conftest.py`; commit as `WorldCat: fixture corpus with its negative class`.

---

### Task 4: Extraction (frame-parallel, byte pre-filter, Parquet shards)

**Files:**
- Create: `data-sources/src/worldcat/pipeline/extract.py`
- Test: `data-sources/tests/worldcat/test_extract.py`

**Interfaces:**
- Produces: `SHARD_COLUMNS: dict[str, str]` (DuckDB types; shared with distill), `keep(line: bytes) -> bool`, `reduce(row: dict) -> dict | None`, `ExtractStats(worker, lines, kept, shards, bad_frames: list[tuple[int, str]])`, `extract_range(source, paths, worker, start, end, *, batch_size=50_000) -> ExtractStats`, `extract_all(source, paths, *, workers, batch_size=50_000) -> list[ExtractStats]`.
- Consumes: `read_seek_table`, `Frame`, `frame_ranges`, `WorldcatPaths`.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_extract.py`:
```python
import json
from pathlib import Path

import duckdb

from tests.fixtures.worldcat.seekable import write_seekable
from worldcat.pipeline.extract import SHARD_COLUMNS, extract_all, extract_range, keep, reduce
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table

CORPUS = Path(__file__).parent.parent / "fixtures" / "worldcat" / "sample.jsonl"


def _rows():
    return [json.loads(line) for line in CORPUS.read_text(encoding="utf-8").splitlines()]


def _synthetic(tag: str) -> dict:
    return next(r for r in _rows() if r["metadata"].get("_synthetic") == tag)


def test_keep_wants_isbn_bearing_book_titles_redirects_and_holdings_summaries():
    assert keep(b'{"metadata":{"type":"title_json","record":{"generalFormat":"Book","isbns":["1"]}}}')
    assert keep(b'{"metadata":{"type":"briefrecords_json","record":{"generalFormat":"Book","isbns":["1"]}}}')
    assert keep(b'{"metadata":{"type":"redirect_title_json","record":{"redirected_oclc_number":5}}}')
    assert keep(b'{"metadata":{"type":"search_holdings_summary_all_editions","record":{}}}')
    assert not keep(b'{"metadata":{"type":"title_json","record":{"generalFormat":"Book","isbns":[]}}}')
    assert not keep(b'{"metadata":{"type":"title_json","record":{"generalFormat":"Music","isbns":["1"]}}}')
    assert not keep(b'{"metadata":{"type":"not_found_title_json","record":{"not_found":1}}}')
    assert not keep(b'{"metadata":{"type":"legacysearch_html","html":"<td>"}}')


def test_reduce_flattens_a_title_record():
    row = next(
        r for r in _rows()
        if r["metadata"]["oclc_number"] == "0001055766559" and r["metadata"]["type"] == "title_json"
        and "_synthetic" not in r["metadata"]
    )
    out = reduce(row)
    assert set(out) == set(SHARD_COLUMNS)
    assert out["kind"] == "record"
    assert out["oclc"] == 1055766559
    assert out["type"] == "title_json"
    assert out["pass"] == "w2"
    assert out["title"].startswith("Atomic habits")
    assert out["year"] == 2018
    assert "9780735211292" in out["isbns_raw"]
    assert out["genre"] == "Nonfiction"
    assert "Habit" in out["subjects"]
    assert isinstance(out["merged_oclc"], list) and isinstance(out["other_format_oclc"], list)
    assert out["total_editions"] >= 16


def test_reduce_reads_dict_subjects_and_a_range_query_pass():
    out = reduce(_synthetic("dict_subjects"))
    assert out["subjects"] == ["Science fiction", "Robots"]
    assert out["pass"] == "range_query"
    assert out["pass_index"] is None


def test_reduce_flattens_a_redirect():
    out = reduce(_synthetic("chain1"))
    assert (out["kind"], out["oclc"], out["redirect_to"]) == ("redirect", 9000000010, 9000000011)
    assert out["title"] is None and out["isbns_raw"] is None


def test_reduce_flattens_a_holdings_summary_with_its_pass_index():
    out = reduce(_synthetic("later_holdings"))
    assert (out["kind"], out["oclc"]) == ("holdings", 1055766559)
    assert (out["total_holding_count"], out["holdings_total_editions"]) == (4000, 25)
    assert out["pass_index"] == 9


def test_extract_range_carries_a_line_across_a_frame_boundary(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    n = write_seekable(lines, source, frame_bytes=2048)
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_range(source, paths, 0, 0, n, batch_size=10)

    assert stats.lines == len(lines)
    assert stats.bad_frames == []
    expected = sum(1 for ln in lines if keep(ln))
    assert stats.kept == expected
    (count,) = duckdb.connect().execute(
        f"SELECT count(*) FROM read_parquet('{paths.staging_dir}/shard_*.parquet')"
    ).fetchone()
    assert count == expected
    assert stats.shards >= 2


def test_extract_all_splits_frames_across_workers_and_writes_progress(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    write_seekable(lines, source, frame_bytes=4096)
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_all(source, paths, workers=2)

    assert sorted(s.worker for s in stats) == [0, 1]
    assert sum(s.lines for s in stats) == len(lines)
    assert (paths.staging_dir / "progress_000.txt").read_text().startswith("100.0%")


def test_a_corrupt_frame_is_counted_not_fatal(tmp_path: Path):
    lines = CORPUS.read_bytes().splitlines()
    source = tmp_path / "s.zst"
    n = write_seekable(lines, source, frame_bytes=4096)
    frames = read_seek_table(source)
    data = bytearray(source.read_bytes())
    f = frames[1]
    data[f.offset + 8 : f.offset + 24] = b"\x00" * 16
    source.write_bytes(bytes(data))
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()

    stats = extract_range(source, paths, 0, 0, n)

    assert [i for i, _ in stats.bad_frames] == [1]
    assert stats.lines > 0
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_extract.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'worldcat.pipeline.extract'`

- [ ] **Step 3: Implement extraction**

`src/worldcat/pipeline/extract.py`:
```python
"""Stage 1: read the dump once, keep what the artifact needs, write Parquet shards.

Each worker owns a contiguous range of frames, decodes one frame at a time,
carries the partial last line into the next frame, and drops a line with a
byte-level pre-filter BEFORE parsing JSON (most of the 2 billion lines are
not-found stubs, HTML, or non-Book records). Kept lines are reduced to the
shard columns and flushed to Parquet through DuckDB every `batch_size` rows.
A worker keeps no state that grows with the file: a per-worker set of OCLC
numbers exhausted a 45 GB machine on the spike.
"""

import errno
import json
import multiprocessing as mp
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
import zstandard

from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import Frame, frame_ranges, read_seek_table

SHARD_COLUMNS: dict[str, str] = {
    "kind": "VARCHAR",  # record | redirect | holdings
    "oclc": "BIGINT",
    "type": "VARCHAR",
    "pass": "VARCHAR",
    "pass_index": "BIGINT",
    "title": "VARCHAR",
    "subtitle": "VARCHAR",
    "creator": "VARCHAR",
    "contributors": "VARCHAR[]",
    "year": "INTEGER",
    "publication_date_raw": "VARCHAR",
    "publisher": "VARCHAR",
    "publication_place": "VARCHAR",
    "cataloging_language": "VARCHAR",
    "specific_format": "VARCHAR",
    "edition_statement": "VARCHAR",
    "physical_description": "VARCHAR",
    "series": "VARCHAR",
    "genre": "VARCHAR",
    "subjects": "VARCHAR[]",
    "isbns_raw": "VARCHAR[]",
    "merged_oclc": "BIGINT[]",
    "other_format_oclc": "BIGINT[]",
    "total_editions": "INTEGER",
    "summary": "VARCHAR",
    "redirect_to": "BIGINT",
    "total_holding_count": "INTEGER",
    "holdings_total_editions": "INTEGER",
}

_RECORD_TYPES = (b'"type":"title_json"', b'"type":"briefrecords_json"')
_REDIRECT = b'"type":"redirect_title_json"'
_HOLDINGS = b'"type":"search_holdings_summary_all_editions"'
_BOOK = b'"generalFormat":"Book"'
_HAS_ISBN = b'"isbns":["'
_YEAR = re.compile(r"\d{4}")
_INT = re.compile(r"\d+")


def keep(line: bytes) -> bool:
    if _REDIRECT in line or _HOLDINGS in line:
        return True
    return any(t in line for t in _RECORD_TYPES) and _BOOK in line and _HAS_ISBN in line


def _pass(meta: dict) -> tuple[str, int | None]:
    """('w2', 315408380) from 'w2/v7/3154/315408380'; a tar member path such as
    'x/2025-01-01_02.tar/9' gives its member number; a range query gives None."""
    names = meta.get("from_filenames") or []
    if not names:
        return "unknown", None
    parts = str(names[0]).split("/")
    last = parts[-1]
    return parts[0], (int(last) if last.isdigit() else None)


def _int(value) -> int | None:
    if value is None:
        return None
    m = _INT.search(str(value))
    return int(m.group()) if m else None


def _year(value) -> int | None:
    if value is None:
        return None
    m = _YEAR.search(str(value))
    return int(m.group()) if m else None


def _text(value) -> str | None:
    if isinstance(value, dict):
        value = value.get("text")
    return value if isinstance(value, str) and value else None


def _subjects(record: dict) -> list[str]:
    out = []
    for item in record.get("subjectsText") or record.get("subjects") or []:
        text = item if isinstance(item, str) else _text(item)
        if text:
            out.append(text)
    return out


def _contributors(record: dict) -> list[str]:
    out = []
    for c in record.get("contributors") or []:
        name = " ".join(p for p in (_text(c.get("firstName")), _text(c.get("secondName"))) if p)
        if name:
            out.append(name)
    return out


def _oclc_list(value) -> list[int]:
    out = []
    for item in value or []:
        number = _int(item.get("oclcNumber") if isinstance(item, dict) else item)
        if number is not None:
            out.append(number)
    return out


def reduce(row: dict) -> dict | None:
    meta = row.get("metadata") or {}
    kind = meta.get("type")
    oclc = _int(meta.get("oclc_number"))
    if oclc is None:
        return None
    record = meta.get("record") or {}
    pass_name, pass_index = _pass(meta)
    out: dict = dict.fromkeys(SHARD_COLUMNS)
    out["oclc"], out["type"], out["pass"], out["pass_index"] = oclc, kind, pass_name, pass_index
    if kind == "redirect_title_json":
        out["kind"] = "redirect"
        out["redirect_to"] = _int(record.get("redirected_oclc_number"))
        return out if out["redirect_to"] is not None else None
    if kind == "search_holdings_summary_all_editions":
        out["kind"] = "holdings"
        out["total_holding_count"] = _int(record.get("total_holding_count"))
        out["holdings_total_editions"] = _int(record.get("total_editions"))
        return out
    if kind not in ("title_json", "briefrecords_json"):
        return None
    out["kind"] = "record"
    out["title"] = _text(record.get("title")) or _text(record.get("titleInfo"))
    out["subtitle"] = _text(record.get("subtitle"))
    out["creator"] = _text(record.get("creator"))
    out["contributors"] = _contributors(record)
    out["year"] = _year(
        record.get("machineReadableDate") or record.get("publicationDate") or record.get("date")
    )
    out["publication_date_raw"] = _text(record.get("publicationDate") or record.get("date"))
    out["publisher"] = _text(record.get("publisher") or record.get("publisherName"))
    out["publication_place"] = _text(record.get("publicationPlace"))
    out["cataloging_language"] = _text(record.get("catalogingLanguage") or record.get("language"))
    out["specific_format"] = _text(record.get("specificFormat"))
    out["edition_statement"] = _text(record.get("edition"))
    out["physical_description"] = _text(record.get("physicalDescription"))
    out["series"] = _text(record.get("series"))
    out["genre"] = _text(record.get("genre"))
    out["subjects"] = _subjects(record)
    out["isbns_raw"] = [str(i) for i in (record.get("isbns") or []) if i]
    out["merged_oclc"] = _oclc_list(record.get("mergedOclcNumbers"))
    out["other_format_oclc"] = _oclc_list(record.get("otherFormats"))
    out["total_editions"] = _int(record.get("totalEditions"))
    out["summary"] = _text(record.get("summary"))
    return out


@dataclass
class ExtractStats:
    worker: int
    lines: int = 0
    kept: int = 0
    shards: int = 0
    bad_frames: list[tuple[int, str]] = field(default_factory=list)


class ShardWriter:
    """Buffers reduced rows and writes each batch as one Parquet file via DuckDB
    (no pyarrow in this environment, so rows go through a temp JSONL file)."""

    def __init__(self, paths: WorldcatPaths, worker: int, batch_size: int) -> None:
        self.paths, self.worker, self.batch_size = paths, worker, batch_size
        self.rows: list[dict] = []
        self.index = 0
        self.con = duckdb.connect()

    def add(self, row: dict) -> None:
        self.rows.append(row)
        if len(self.rows) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        if not self.rows:
            return
        tmp = self.paths.tmp_dir / f"shard_{self.worker:03d}_{self.index:05d}.jsonl"
        with tmp.open("w", encoding="utf-8") as fh:
            for row in self.rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        columns = ", ".join(f"'{name}': '{sql_type}'" for name, sql_type in SHARD_COLUMNS.items())
        target = self.paths.shard(self.worker, self.index)
        self.con.execute(
            f"COPY (SELECT * FROM read_json('{tmp}', format='newline_delimited', "
            f"columns={{{columns}}})) TO '{target}' (FORMAT parquet, COMPRESSION zstd)"
        )
        tmp.unlink()
        self.rows = []
        self.index += 1

    def close(self) -> int:
        self.flush()
        self.con.close()
        return self.index


def _read_frame(fh, frame: Frame, dctx: zstandard.ZstdDecompressor) -> bytes:
    for attempt in range(30):
        try:
            fh.seek(frame.offset)
            blob = fh.read(frame.compressed_size)
            if len(blob) != frame.compressed_size:
                raise OSError(errno.EIO, "short read")
            return dctx.decompress(blob, max_output_size=frame.decompressed_size)
        except OSError as exc:
            # WSL's drvfs returns ENOMEM under concurrent large reads: back off and retry.
            if exc.errno not in (errno.ENOMEM, errno.EIO) or attempt == 29:
                raise
            time.sleep(0.5 * (attempt + 1))
    raise AssertionError("unreachable")


def _consume(line: bytes, writer: ShardWriter, stats: ExtractStats) -> None:
    stats.lines += 1
    if not keep(line):
        return
    try:
        row = reduce(json.loads(line))
    except ValueError:
        return
    if row is not None:
        writer.add(row)
        stats.kept += 1


def extract_range(
    source: Path, paths: WorldcatPaths, worker: int, start: int, end: int, *, batch_size: int = 50_000
) -> ExtractStats:
    frames = read_seek_table(source)
    stats = ExtractStats(worker=worker)
    writer = ShardWriter(paths, worker, batch_size)
    dctx = zstandard.ZstdDecompressor()
    progress = paths.staging_dir / f"progress_{worker:03d}.txt"
    started = time.time()
    carry = b""
    with source.open("rb") as fh:
        for i in range(start, end):
            try:
                raw = _read_frame(fh, frames[i], dctx)
            except (zstandard.ZstdError, OSError) as exc:
                stats.bad_frames.append((i, str(exc)[:100]))
                carry = b""
                continue
            parts = (carry + raw).split(b"\n")
            carry = parts.pop()
            for line in parts:
                if line:
                    _consume(line, writer, stats)
            if (i - start) % 500 == 0:
                progress.write_text(
                    f"{(i - start + 1) / (end - start) * 100:.1f}% lines={stats.lines} "
                    f"kept={stats.kept} bad={len(stats.bad_frames)} elapsed={time.time() - started:.0f}s\n"
                )
    if carry.strip():
        _consume(carry, writer, stats)
    stats.shards = writer.close()
    progress.write_text(
        f"100.0% lines={stats.lines} kept={stats.kept} bad={len(stats.bad_frames)} done\n"
    )
    return stats


def _work(args: tuple) -> ExtractStats:
    source, paths, worker, start, end, batch_size = args
    return extract_range(source, paths, worker, start, end, batch_size=batch_size)


def extract_all(
    source: Path, paths: WorldcatPaths, *, workers: int, batch_size: int = 50_000
) -> list[ExtractStats]:
    n_frames = len(read_seek_table(source))
    jobs = [
        (source, paths, w, start, end, batch_size)
        for w, (start, end) in enumerate(frame_ranges(n_frames, workers))
    ]
    if len(jobs) == 1:
        return [_work(jobs[0])]
    with mp.get_context("fork").Pool(len(jobs)) as pool:
        return list(pool.imap_unordered(_work, jobs))
```

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat/test_extract.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS. If `test_reduce_flattens_a_title_record` fails on `year`, read the Atomic Habits `machineReadableDate` in the corpus and fix the expected value, not the code.

- [ ] **Step 5: Commit**

Stage `data-sources/src/worldcat/pipeline/extract.py` and `data-sources/tests/worldcat/test_extract.py`; commit as `WorldCat: frame-parallel extraction to Parquet shards`.

---
### Task 5: Distillation (pass ranking, records, isbns, redirects, holdings)

**Files:**
- Create: `data-sources/src/worldcat/pipeline/distill.py`
- Test: `data-sources/tests/worldcat/test_distill.py`

**Interfaces:**
- Produces: `PASS_ORDER: tuple[str, ...]` (newest first), `UnknownPass(RuntimeError)`, `shards_glob(paths) -> str`, `unknown_passes(con, paths) -> list[str]`, `build_records(con, paths) -> int`, `build_isbns(con, paths) -> int`, `build_redirects(con, paths) -> int`, `build_holdings(con, paths) -> int`. Each builder writes `paths.table(name)` and returns its row count.
- Consumes: `SHARD_COLUMNS` shards from Task 4; `common.normalize.isbn13_sql(expr)` and `isbn_checksum_ok_sql(expr)`.

Rules the SQL encodes (from the spec, "Build"):
- A record row is the **newest pass** of that OCLC number (`PASS_ORDER` rank, then `title_json` before `briefrecords_json`, then higher `pass_index`). Scalar fields come from that one row only.
- `isbn13s` on the row is the **union across every pass** of that number, normalised to ISBN-13, bad check digits kept (the record says what it says).
- `isbns` indexes only ISBN-13s whose check digit is valid.
- A pass prefix not in `PASS_ORDER` raises `UnknownPass`; the build never guesses a rank.
- Redirects resolve transitively, at most ten hops; a target that is itself still a source after that is `is_cycle = true`.
- Holdings: the summary with the highest `pass_index` wins.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_distill.py`:
```python
from pathlib import Path

import duckdb
import pytest

from worldcat.pipeline.distill import (
    PASS_ORDER,
    UnknownPass,
    build_holdings,
    build_isbns,
    build_records,
    build_redirects,
    unknown_passes,
)
from worldcat.pipeline.extract import extract_range
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table


@pytest.fixture()
def built(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    n = len(read_seek_table(worldcat_source))
    extract_range(worldcat_source, paths, 0, 0, n, batch_size=20)
    con = duckdb.connect()
    con.execute("SET memory_limit='1GB'")
    assert unknown_passes(con, paths) == []
    counts = {
        "records": build_records(con, paths),
        "isbns": build_isbns(con, paths),
        "redirects": build_redirects(con, paths),
        "holdings": build_holdings(con, paths),
    }
    yield con, paths, counts
    con.close()


def _one(con, sql, params=()):
    return con.execute(sql, params).fetchone()


def test_pass_order_is_newest_first():
    assert PASS_ORDER[0] == "w2"
    assert "worldcat_2022_09_titles_1_backup_2022_10_12" == PASS_ORDER[-1]


def test_duplicate_passes_collapse_to_the_newest(built):
    con, paths, _ = built
    row = _one(con, f"SELECT genre, source_pass, source_type FROM '{paths.table('records')}' WHERE oclc = 1000415078")
    assert row[0] == "Fiction"  # not the synthetic "STALE GENRE" from the older 2023_04_v3 pass
    assert row[1] in PASS_ORDER[:2]
    (n,) = _one(con, f"SELECT count(*) FROM '{paths.table('records')}' WHERE oclc = 1055766559")
    assert n == 1


def test_isbns_union_every_pass_of_a_number(built):
    con, paths, _ = built
    (isbns,) = _one(con, f"SELECT isbn13s FROM '{paths.table('records')}' WHERE oclc = 1055766559")
    assert "9780735211292" in isbns and "9781847941831" in isbns  # the brief pass carried the UK ISBN
    assert _one(con, f"SELECT oclc FROM '{paths.table('isbns')}' WHERE isbn13 = '9781847941831'") == (1055766559,)


def test_non_book_and_isbn_less_records_are_absent(built):
    con, paths, _ = built
    for oclc in (123177986, 11280578):
        assert _one(con, f"SELECT count(*) FROM '{paths.table('records')}' WHERE oclc = ?", [oclc]) == (0,)


def test_bad_checksum_isbn_is_kept_on_the_record_but_not_indexed(built):
    con, paths, _ = built
    (isbns,) = _one(con, f"SELECT isbn13s FROM '{paths.table('records')}' WHERE oclc = 9000000001")
    assert isbns == ["9780000000001"]
    assert _one(con, f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE isbn13 = '9780000000001'") == (0,)


def test_an_isbn10_is_indexed_as_its_isbn13(built):
    con, paths, _ = built
    assert _one(con, f"SELECT oclc FROM '{paths.table('isbns')}' WHERE isbn13 = '9780395476901'") == (1000415078,)
    assert _one(con, f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE length(isbn13) <> 13") == (0,)


def test_redirect_chains_collapse_and_cycles_are_flagged(built):
    con, paths, _ = built
    t = paths.table("redirects")
    assert _one(con, f"SELECT to_oclc, is_cycle FROM '{t}' WHERE from_oclc = 1003236695") == (37975719, False)
    assert _one(con, f"SELECT to_oclc, is_cycle FROM '{t}' WHERE from_oclc = 9000000010") == (1055766559, False)
    assert _one(con, f"SELECT is_cycle FROM '{t}' WHERE from_oclc = 9000000020") == (True,)


def test_holdings_take_the_latest_summary(built):
    con, paths, _ = built
    row = _one(con, f"SELECT total_holding_count, total_editions FROM '{paths.table('holdings')}' WHERE oclc = 1055766559")
    assert row == (4000, 25)


def test_builders_return_row_counts_and_sort_by_key(built):
    con, paths, counts = built
    for name, n in counts.items():
        assert _one(con, f"SELECT count(*) FROM '{paths.table(name)}'") == (n,)
    key = {"records": "oclc", "isbns": "isbn13", "redirects": "from_oclc", "holdings": "oclc"}
    for name, column in key.items():
        (unsorted,) = _one(
            con,
            f"SELECT count(*) FROM (SELECT {column}, lag({column}) OVER () AS prev FROM '{paths.table(name)}') WHERE prev > {column}",
        )
        assert unsorted == 0, name


def test_an_unknown_pass_prefix_is_refused(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    n = len(read_seek_table(worldcat_source))
    extract_range(worldcat_source, paths, 0, 0, n)
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * REPLACE ('mystery_pass' AS pass) FROM read_parquet('{paths.staging_dir}/shard_*.parquet') LIMIT 1) "
        f"TO '{paths.shard(9, 0)}' (FORMAT parquet)"
    )
    assert unknown_passes(con, paths) == ["mystery_pass"]
    with pytest.raises(UnknownPass, match="mystery_pass"):
        build_records(con, paths)
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_distill.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'worldcat.pipeline.distill'`

- [ ] **Step 3: Implement distillation**

`src/worldcat/pipeline/distill.py`:
```python
"""Stage 2: DuckDB SQL over the shards into the four artifact tables."""

import duckdb

from common.normalize import isbn13_sql, isbn_checksum_ok_sql
from worldcat.pipeline.paths import WorldcatPaths

# Newest scrape pass first. The prefix is the first path segment of
# `from_filenames[0]`. Anything not listed fails the build (UnknownPass): a
# rank is a claim about recency, and a guess here would silently decide which
# copy of a record is the truth.
PASS_ORDER: tuple[str, ...] = (
    "w2",
    "2023_05_v4_type123",
    "2023_04_v3",
    "t123",
    "search_editions_response",
    "range_query",
    "worldcat_2022_09_titles_1_backup_2022_10_12",
)
MAX_REDIRECT_HOPS = 10
ROW_GROUP = 100_000


class UnknownPass(RuntimeError):
    """A pass prefix the ranking list does not know."""


def shards_glob(paths: WorldcatPaths) -> str:
    return str(paths.staging_dir / "shard_*.parquet")


def _pass_rank_cte() -> str:
    values = ", ".join(f"('{name}', {rank})" for rank, name in enumerate(PASS_ORDER, start=1))
    return f"pr AS (SELECT * FROM (VALUES {values}) AS t(pass, pass_rank))"


def unknown_passes(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> list[str]:
    known = ", ".join(f"'{p}'" for p in PASS_ORDER)
    rows = con.execute(
        f"SELECT DISTINCT pass FROM read_parquet('{shards_glob(paths)}') "
        f"WHERE kind = 'record' AND pass NOT IN ({known}) ORDER BY pass"
    ).fetchall()
    return [r[0] for r in rows]


def _require_known_passes(con, paths) -> None:
    unknown = unknown_passes(con, paths)
    if unknown:
        raise UnknownPass(f"pass prefixes not in PASS_ORDER: {unknown}; add them with their recency, then rebuild")


def _count(con, target) -> int:
    (n,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return n


def build_records(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    _require_known_passes(con, paths)
    target = paths.table("records")
    con.execute(
        f"""
        COPY (
          WITH {_pass_rank_cte()},
          src AS (
            SELECT s.*, pr.pass_rank,
                   CASE s.type WHEN 'title_json' THEN 0 ELSE 1 END AS type_rank
            FROM read_parquet('{shards_glob(paths)}') s JOIN pr USING (pass)
            WHERE s.kind = 'record'
          ),
          ranked AS (
            SELECT *, row_number() OVER (
              PARTITION BY oclc ORDER BY pass_rank, type_rank, pass_index DESC NULLS LAST
            ) AS rn
            FROM src
          ),
          isbn_union AS (
            SELECT oclc,
                   list_distinct(list_filter(
                     list_transform(flatten(list(isbns_raw)), x -> {isbn13_sql("x")}),
                     x -> x IS NOT NULL)) AS isbn13s
            FROM src GROUP BY oclc
          )
          SELECT r.oclc, r.title, r.subtitle, r.creator, r.contributors, r.year, r.publication_date_raw,
                 r.publisher, r.publication_place, r.cataloging_language, r.specific_format,
                 r.edition_statement, r.physical_description, r.series, r.genre, r.subjects,
                 u.isbn13s, r.merged_oclc, r.other_format_oclc, r.total_editions, r.summary,
                 r.type AS source_type, r.pass AS source_pass
          FROM ranked r JOIN isbn_union u USING (oclc)
          WHERE r.rn = 1
          ORDER BY r.oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    return _count(con, target)


def build_isbns(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("isbns")
    con.execute(
        f"""
        COPY (
          SELECT DISTINCT isbn13, oclc FROM (
            SELECT oclc, {isbn13_sql("raw")} AS isbn13, {isbn_checksum_ok_sql("raw")} AS ok
            FROM (SELECT oclc, unnest(isbns_raw) AS raw
                  FROM read_parquet('{shards_glob(paths)}') WHERE kind = 'record')
          )
          WHERE ok AND isbn13 IS NOT NULL AND length(isbn13) = 13
          ORDER BY isbn13, oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    return _count(con, target)


def build_redirects(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("redirects")
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE r0 AS
        SELECT oclc AS from_oclc, arg_max(redirect_to, coalesce(pass_index, 0)) AS to_oclc
        FROM read_parquet('{shards_glob(paths)}')
        WHERE kind = 'redirect' AND redirect_to <> oclc
        GROUP BY oclc
        """
    )
    con.execute("CREATE OR REPLACE TEMP TABLE cur AS SELECT from_oclc, to_oclc FROM r0")
    for _ in range(MAX_REDIRECT_HOPS):
        con.execute(
            """
            CREATE OR REPLACE TEMP TABLE nxt AS
            SELECT c.from_oclc, coalesce(n.to_oclc, c.to_oclc) AS to_oclc
            FROM cur c LEFT JOIN r0 n ON n.from_oclc = c.to_oclc AND n.to_oclc <> c.from_oclc
            """
        )
        (changed,) = con.execute(
            "SELECT count(*) FROM nxt n JOIN cur c USING (from_oclc) WHERE n.to_oclc <> c.to_oclc"
        ).fetchone()
        con.execute("CREATE OR REPLACE TEMP TABLE cur AS SELECT * FROM nxt")
        if changed == 0:
            break
    con.execute(
        f"""
        COPY (
          SELECT c.from_oclc, c.to_oclc,
                 EXISTS (SELECT 1 FROM r0 WHERE r0.from_oclc = c.to_oclc) AS is_cycle
          FROM cur c ORDER BY c.from_oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    con.execute("DROP TABLE IF EXISTS r0; DROP TABLE IF EXISTS cur; DROP TABLE IF EXISTS nxt")
    return _count(con, target)


def build_holdings(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("holdings")
    con.execute(
        f"""
        COPY (
          SELECT oclc,
                 arg_max(total_holding_count, coalesce(pass_index, 0)) AS total_holding_count,
                 arg_max(holdings_total_editions, coalesce(pass_index, 0)) AS total_editions
          FROM read_parquet('{shards_glob(paths)}')
          WHERE kind = 'holdings'
          GROUP BY oclc ORDER BY oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    return _count(con, target)
```

If `isbn13_sql`/`isbn_checksum_ok_sql` in `common/normalize.py` take the expression as their only positional argument (they do: `(expr: str) -> str`), the lambda form `x -> <expr>` is valid DuckDB. If DuckDB rejects the lambda because the twin references a column alias, replace the `list_transform` with an `unnest`/`list()` re-aggregation inside `isbn_union`; the test on `isbn13s` is the contract, not the exact SQL.

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat/test_distill.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

Stage `data-sources/src/worldcat/pipeline/distill.py` and `data-sources/tests/worldcat/test_distill.py`; commit as `WorldCat: distill shards into records, isbns, redirects, holdings`.

---

### Task 6: Gates and the report

**Files:**
- Create: `data-sources/src/worldcat/pipeline/gates.py`, `data-sources/src/worldcat/pipeline/report.py`
- Test: `data-sources/tests/worldcat/test_gates.py`, `data-sources/tests/worldcat/test_report.py`

**Interfaces:**
- Produces: `Thresholds` dataclass (defaults are the production floors from the spec), `CANARIES`, `run_gates(con, paths, *, extract_stats, thresholds, catalogue_isbns: Path | None) -> list[GateResult]`, `gates_passed(results) -> bool`.
- Produces: `PIPELINE_VERSION = 1`, `StageTimings`, `write_build_report(con, paths, *, dump_date, source_fingerprint, gate_results, timings, extract) -> dict`, `write_manifest(paths, *, dump_date, source_fingerprint, gate_results, timings, tables) -> dict`.
- Consumes: `common.gates.GateResult`, `TABLES`, `ExtractStats`, `shards_glob`, `PASS_ORDER`.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_gates.py`:
```python
from pathlib import Path

import duckdb
import pytest

from common.gates import GateResult
from worldcat.pipeline.distill import build_holdings, build_isbns, build_records, build_redirects
from worldcat.pipeline.extract import ExtractStats, extract_range
from worldcat.pipeline.gates import Thresholds, gates_passed, run_gates
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import read_seek_table

LOOSE = Thresholds(min_records=1, max_records=10**9, min_redirects=1)


@pytest.fixture()
def built(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    stats = extract_range(worldcat_source, paths, 0, 0, len(read_seek_table(worldcat_source)))
    con = duckdb.connect()
    for builder in (build_records, build_isbns, build_redirects, build_holdings):
        builder(con, paths)
    yield con, paths, [stats]
    con.close()


def _by_name(results: list[GateResult]) -> dict[str, GateResult]:
    return {r.name: r for r in results}


def test_a_clean_build_passes_every_gate_and_skips_coverage_without_a_catalogue(built):
    con, paths, stats = built
    results = _by_name(run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None))
    assert [r.name for r in results.values() if r.status == "fail"] == []
    assert results["catalogue_coverage"].status == "skipped"
    assert results["canaries"].status == "pass"
    assert results["pass_prefixes"].status == "pass"
    assert results["bad_frames"].status == "pass"
    assert 0.9 < results["isbn_checksums"].observed["share_ok"] < 1.0  # the synthetic bad ISBN
    assert gates_passed(list(results.values()))


def test_production_floors_fail_a_tiny_build(built):
    con, paths, stats = built
    results = _by_name(run_gates(con, paths, extract_stats=stats, thresholds=Thresholds(), catalogue_isbns=None))
    assert results["row_counts"].status == "fail"
    assert "records" in results["row_counts"].detail
    assert not gates_passed(list(results.values()))


def test_catalogue_coverage_measures_our_isbns(built, tmp_path: Path):
    con, paths, stats = built
    isbns = tmp_path / "ours.txt"
    isbns.write_text("9780735211292\n9780395476901\n9999999999999\n")
    results = _by_name(run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=isbns))
    assert results["catalogue_coverage"].status == "fail"
    assert results["catalogue_coverage"].observed == {"isbns": 3, "resolved": 2, "share": pytest.approx(2 / 3)}
    results = _by_name(run_gates(
        con, paths, extract_stats=stats, thresholds=Thresholds(min_records=1, max_records=10**9, min_redirects=1, min_catalogue_coverage=0.5),
        catalogue_isbns=isbns,
    ))
    assert results["catalogue_coverage"].status == "pass"


def test_a_bad_frame_fails_the_build(built):
    con, paths, _ = built
    stats = [ExtractStats(worker=0, lines=1, kept=1, shards=1, bad_frames=[(7, "boom")])]
    results = _by_name(run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None))
    assert results["bad_frames"].status == "fail"
    assert results["bad_frames"].observed == {"bad_frames": [[7, "boom"]]}


def test_a_missing_canary_fails(built):
    con, paths, stats = built
    con.execute(f"COPY (SELECT * FROM '{paths.table('isbns')}' WHERE isbn13 <> '9780735211292') TO '{paths.table('isbns')}' (FORMAT parquet)")
    results = _by_name(run_gates(con, paths, extract_stats=stats, thresholds=LOOSE, catalogue_isbns=None))
    assert results["canaries"].status == "fail"
    assert "9780735211292" in results["canaries"].detail
```

`tests/worldcat/test_report.py`:
```python
import json
from pathlib import Path

import duckdb

from common.gates import GateResult
from worldcat.pipeline.distill import build_holdings, build_isbns, build_records, build_redirects
from worldcat.pipeline.extract import ExtractStats, extract_range
from worldcat.pipeline.paths import TABLES, WorldcatPaths
from worldcat.pipeline.report import PIPELINE_VERSION, StageTimings, write_build_report, write_manifest
from worldcat.pipeline.seektable import read_seek_table


def test_report_and_manifest_describe_the_build(tmp_path: Path, worldcat_source: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    stats = extract_range(worldcat_source, paths, 0, 0, len(read_seek_table(worldcat_source)))
    con = duckdb.connect()
    for builder in (build_records, build_isbns, build_redirects, build_holdings):
        builder(con, paths)
    timings = StageTimings()
    timings.record("extract", 1.5, rows=stats.kept)
    gates = [GateResult(name="row_counts", status="pass", detail="ok"), GateResult(name="x", status="skipped", detail="n/a")]

    report = write_build_report(con, paths, dump_date="2025-09-04", source_fingerprint="abc", gate_results=gates, timings=timings, extract=[stats])
    manifest = write_manifest(paths, dump_date="2025-09-04", source_fingerprint="abc", gate_results=gates, timings=timings, tables=report["tables"])

    assert set(report["tables"]) == set(TABLES)
    assert report["tables"]["records"]["rows"] > 0 and report["tables"]["records"]["bytes"] > 0
    assert report["extract"] == {"lines": stats.lines, "kept": stats.kept, "bad_frames": []}
    assert report["pipeline_version"] == PIPELINE_VERSION
    on_disk = json.loads(paths.manifest_path.read_text())
    assert on_disk == manifest
    assert manifest["gates_passed"] is True
    assert manifest["source_fingerprint"] == "abc"
    assert manifest["tables"]["isbns"] == report["tables"]["isbns"]["rows"]
    assert manifest["stages"] == ["extract"]


def test_a_failed_gate_marks_the_manifest(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    manifest = write_manifest(paths, dump_date="2025-09-04", source_fingerprint="abc",
                              gate_results=[GateResult(name="row_counts", status="fail", detail="too few")],
                              timings=StageTimings(), tables={})
    assert manifest["gates_passed"] is False
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_gates.py tests/worldcat/test_report.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement gates and report**

`src/worldcat/pipeline/gates.py`:
```python
"""The seven gates from the spec. A gate never raises; it returns a GateResult."""

from dataclasses import dataclass
from pathlib import Path

import duckdb

from common.gates import GateResult
from common.normalize import isbn_checksum_ok_sql, normalize_isbn
from worldcat.pipeline.distill import PASS_ORDER, shards_glob
from worldcat.pipeline.extract import ExtractStats
from worldcat.pipeline.paths import TABLES, WorldcatPaths

# (isbn13 or None, oclc, expected genre or None): real records chosen on the spike.
CANARIES: tuple[tuple[str | None, int, str | None], ...] = (
    ("9780735211292", 1055766559, "Nonfiction"),  # Atomic Habits
    ("9780395476901", 1000415078, None),  # The Hobbit
    ("9780553103540", 1002380292, None),  # A Game of Thrones
)
CANARY_REDIRECT = (1003236695, 37975719)


@dataclass(frozen=True)
class Thresholds:
    """Production floors. Deliberately loose for the first build; tighten them to
    the measured values afterwards and record the measurement in the feature doc."""

    min_records: int = 20_000_000
    max_records: int = 120_000_000
    min_redirects: int = 10_000_000
    min_genre_share: float = 0.25
    min_subject_share: float = 0.50
    min_year_share: float = 0.80
    min_checksum_share: float = 0.98
    min_catalogue_coverage: float = 0.80


def _one(con, sql, params=()):
    return con.execute(sql, params).fetchone()


def _row_counts(con, paths, t: Thresholds) -> GateResult:
    counts = {}
    for name in TABLES:
        target = paths.table(name)
        counts[name] = _one(con, f"SELECT count(*) FROM '{target}'")[0] if target.exists() else None
    problems = [name for name, n in counts.items() if n is None]
    if counts["records"] is not None and not (t.min_records <= counts["records"] <= t.max_records):
        problems.append(f"records={counts['records']:,} outside [{t.min_records:,}, {t.max_records:,}]")
    if counts["isbns"] is not None and counts["records"] is not None and counts["isbns"] < counts["records"]:
        problems.append(f"isbns={counts['isbns']:,} < records={counts['records']:,}")
    if counts["redirects"] is not None and counts["redirects"] < t.min_redirects:
        problems.append(f"redirects={counts['redirects']:,} < {t.min_redirects:,}")
    return GateResult("row_counts", "fail" if problems else "pass",
                      "; ".join(problems) if problems else "all tables within bounds", {"counts": counts})


def _field_coverage(con, paths, t: Thresholds) -> GateResult:
    records = paths.table("records")
    genre, subjects, year, total = _one(
        con,
        f"SELECT count(*) FILTER (WHERE genre IS NOT NULL), count(*) FILTER (WHERE len(subjects) > 0), "
        f"count(*) FILTER (WHERE year IS NOT NULL), count(*) FROM '{records}'",
    )
    shares = {"genre": genre / total if total else 0, "subjects": subjects / total if total else 0, "year": year / total if total else 0}
    floors = {"genre": t.min_genre_share, "subjects": t.min_subject_share, "year": t.min_year_share}
    low = [f"{k}={shares[k]:.3f} < {floors[k]}" for k in shares if shares[k] < floors[k]]
    return GateResult("field_coverage", "fail" if low else "pass", "; ".join(low) or "coverage within bounds", shares)


def _isbn_checksums(con, paths, t: Thresholds) -> GateResult:
    ok, total = _one(
        con,
        f"SELECT count(*) FILTER (WHERE {isbn_checksum_ok_sql('raw')}), count(*) "
        f"FROM (SELECT unnest(isbns_raw) AS raw FROM read_parquet('{shards_glob(paths)}') WHERE kind = 'record')",
    )
    share = ok / total if total else 0.0
    status = "pass" if share >= t.min_checksum_share else "fail"
    return GateResult("isbn_checksums", status, f"{share:.4f} of raw ISBNs pass their check digit", {"share_ok": share, "total": total})


def _pass_prefixes(con, paths) -> GateResult:
    known = ", ".join(f"'{p}'" for p in PASS_ORDER)
    unknown = [r[0] for r in con.execute(
        f"SELECT DISTINCT pass FROM read_parquet('{shards_glob(paths)}') WHERE pass NOT IN ({known}) AND kind = 'record'"
    ).fetchall()]
    return GateResult("pass_prefixes", "fail" if unknown else "pass",
                      f"unknown: {unknown}" if unknown else "every pass prefix is ranked", {"unknown": unknown})


def _canaries(con, paths) -> GateResult:
    missing = []
    for isbn13, oclc, genre in CANARIES:
        if isbn13 and _one(con, f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE isbn13 = ? AND oclc = ?", [isbn13, oclc])[0] == 0:
            missing.append(f"isbn {isbn13} -> {oclc}")
        row = _one(con, f"SELECT genre FROM '{paths.table('records')}' WHERE oclc = ?", [oclc])
        if row is None:
            missing.append(f"record {oclc}")
        elif genre is not None and row[0] != genre:
            missing.append(f"record {oclc} genre {row[0]!r} != {genre!r}")
    src, dst = CANARY_REDIRECT
    if _one(con, f"SELECT to_oclc FROM '{paths.table('redirects')}' WHERE from_oclc = ?", [src]) != (dst,):
        missing.append(f"redirect {src} -> {dst}")
    return GateResult("canaries", "fail" if missing else "pass",
                      f"missing: {missing}" if missing else "all canaries resolve", {"missing": missing})


def _catalogue_coverage(con, paths, t: Thresholds, catalogue_isbns: Path | None) -> GateResult:
    if catalogue_isbns is None or not catalogue_isbns.exists():
        return GateResult("catalogue_coverage", "skipped", "no catalogue ISBN export given (--catalogue-isbns)")
    wanted = sorted({n.isbn13 for line in catalogue_isbns.read_text().split()
                     if (n := normalize_isbn(line)) is not None and n.isbn13})
    con.execute("CREATE OR REPLACE TEMP TABLE ours (isbn13 VARCHAR)")
    con.executemany("INSERT INTO ours VALUES (?)", [(i,) for i in wanted])
    (resolved,) = _one(con, f"SELECT count(DISTINCT o.isbn13) FROM ours o JOIN '{paths.table('isbns')}' i USING (isbn13)")
    con.execute("DROP TABLE ours")
    share = resolved / len(wanted) if wanted else 0.0
    status = "pass" if share >= t.min_catalogue_coverage else "fail"
    return GateResult("catalogue_coverage", status, f"{resolved:,} of {len(wanted):,} catalogue ISBNs resolve ({share:.3f})",
                      {"isbns": len(wanted), "resolved": resolved, "share": share})


def _bad_frames(extract_stats: list[ExtractStats]) -> GateResult:
    bad = [list(item) for s in extract_stats for item in s.bad_frames]
    return GateResult("bad_frames", "fail" if bad else "pass",
                      f"{len(bad)} frame(s) failed to decompress" if bad else "every frame decoded", {"bad_frames": bad})


def run_gates(
    con: duckdb.DuckDBPyConnection,
    paths: WorldcatPaths,
    *,
    extract_stats: list[ExtractStats],
    thresholds: Thresholds,
    catalogue_isbns: Path | None,
) -> list[GateResult]:
    return [
        _row_counts(con, paths, thresholds),
        _field_coverage(con, paths, thresholds),
        _isbn_checksums(con, paths, thresholds),
        _pass_prefixes(con, paths),
        _canaries(con, paths),
        _catalogue_coverage(con, paths, thresholds, catalogue_isbns),
        _bad_frames(extract_stats),
    ]


def gates_passed(results: list[GateResult]) -> bool:
    return all(r.status != "fail" for r in results)
```

`src/worldcat/pipeline/report.py`:
```python
"""build_report.json (everything) and manifest.json (what the API checks at boot)."""

import datetime
import json
from dataclasses import dataclass, field

import duckdb

from common.gates import GateResult
from worldcat.pipeline.extract import ExtractStats
from worldcat.pipeline.paths import TABLES, WorldcatPaths

PIPELINE_VERSION = 1


@dataclass
class StageTimings:
    stages: dict[str, dict] = field(default_factory=dict)

    def record(self, name: str, seconds: float, rows: int | None = None) -> None:
        self.stages[name] = {"seconds": round(seconds, 3), "rows": rows}

    def as_dict(self) -> dict:
        return dict(self.stages)


def _table_stats(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> dict:
    out = {}
    for name in TABLES:
        target = paths.table(name)
        if not target.exists():
            out[name] = {"rows": 0, "bytes": 0, "missing": True}
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
        out[name] = {"rows": rows, "bytes": target.stat().st_size}
    return out


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def write_build_report(
    con, paths: WorldcatPaths, *, dump_date: str, source_fingerprint: str,
    gate_results: list[GateResult], timings: StageTimings, extract: list[ExtractStats],
) -> dict:
    tables = _table_stats(con, paths)
    report = {
        "dump_date": dump_date,
        "built_at": _now(),
        "pipeline_version": PIPELINE_VERSION,
        "source_fingerprint": source_fingerprint,
        "tables": tables,
        "total_bytes": sum(t["bytes"] for t in tables.values()),
        "extract": {
            "lines": sum(s.lines for s in extract),
            "kept": sum(s.kept for s in extract),
            "bad_frames": [list(b) for s in extract for b in s.bad_frames],
        },
        "gates": [{"name": g.name, "status": g.status, "detail": g.detail, "observed": g.observed} for g in gate_results],
        "timings": timings.as_dict(),
    }
    paths.report_path.write_text(json.dumps(report, indent=2, default=str))
    return report


def write_manifest(
    paths: WorldcatPaths, *, dump_date: str, source_fingerprint: str,
    gate_results: list[GateResult], timings: StageTimings, tables: dict,
) -> dict:
    manifest = {
        "dump_date": dump_date,
        "built_at": _now(),
        "pipeline_version": PIPELINE_VERSION,
        "source_fingerprint": source_fingerprint,
        "gates_passed": all(g.status != "fail" for g in gate_results),
        "tables": {name: stats.get("rows", 0) for name, stats in tables.items()},
        "stages": list(timings.as_dict()),
    }
    paths.manifest_path.write_text(json.dumps(manifest, indent=2, default=str))
    return manifest
```

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat/test_gates.py tests/worldcat/test_report.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

Stage the two source files and two test files; commit as `WorldCat: gates, build report and manifest`.

---

### Task 7: The build command

**Files:**
- Create: `data-sources/src/worldcat/pipeline/build.py`
- Test: `data-sources/tests/worldcat/test_build.py`

**Interfaces:**
- Produces: `BuildFailed(RuntimeError)`, `source_fingerprint(source: Path) -> str`, `build(*, source: Path, root: Path, dump_date: str, workers: int = 8, memory_limit: str = "16GB", threads: int | None = None, keep_staging: bool = False, catalogue_isbns: Path | None = None, thresholds: Thresholds | None = None) -> dict`, the typer `app`.
- Consumes: everything from Tasks 2 to 6.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_build.py`:
```python
import json
from pathlib import Path

import pytest

from worldcat.pipeline.build import BuildFailed, build, source_fingerprint
from worldcat.pipeline.gates import Thresholds
from worldcat.pipeline.paths import TABLES, WorldcatPaths

LOOSE = Thresholds(min_records=1, max_records=10**9, min_redirects=1)


def test_a_build_produces_four_tables_a_report_and_a_passing_manifest(worldcat_artifact: WorldcatPaths):
    for table in TABLES:
        assert worldcat_artifact.table(table).exists(), table
    manifest = json.loads(worldcat_artifact.manifest_path.read_text())
    assert manifest["gates_passed"] is True
    assert manifest["dump_date"] == "2025-09-04"
    report = json.loads(worldcat_artifact.report_path.read_text())
    assert [g["name"] for g in report["gates"] if g["status"] == "fail"] == []
    assert not worldcat_artifact.staging_dir.exists()


def test_the_session_fixture_built_with_loose_thresholds_and_two_workers(worldcat_artifact: WorldcatPaths):
    report = json.loads(worldcat_artifact.report_path.read_text())
    assert report["extract"]["bad_frames"] == []
    assert "extract" in report["timings"] and "records" in report["timings"]


def test_a_failed_gate_raises_keeps_staging_and_marks_the_manifest(tmp_path: Path, worldcat_source: Path):
    with pytest.raises(BuildFailed, match="gates"):
        build(source=worldcat_source, root=tmp_path, dump_date="2025-09-04", workers=1, memory_limit="1GB")
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    assert json.loads(paths.manifest_path.read_text())["gates_passed"] is False
    assert paths.staging_dir.exists()


def test_catalogue_isbns_feed_the_coverage_gate(tmp_path: Path, worldcat_source: Path):
    ours = tmp_path / "ours.txt"
    ours.write_text("9780735211292\n9999999999999\n")
    with pytest.raises(BuildFailed):
        build(source=worldcat_source, root=tmp_path, dump_date="2025-09-04", workers=1, memory_limit="1GB",
              catalogue_isbns=ours, thresholds=LOOSE)
    report = json.loads(WorldcatPaths(root=tmp_path, dump_date="2025-09-04").report_path.read_text())
    gate = next(g for g in report["gates"] if g["name"] == "catalogue_coverage")
    assert gate["status"] == "fail" and gate["observed"]["resolved"] == 1


def test_source_fingerprint_changes_with_the_file(tmp_path: Path, worldcat_source: Path):
    a = source_fingerprint(worldcat_source)
    other = tmp_path / "other.zst"
    other.write_bytes(worldcat_source.read_bytes()[:-1] + b"\x00")
    assert a != source_fingerprint(other)
    assert len(a) == 64
```

The session fixture in `tests/conftest.py` must pass `thresholds=Thresholds(min_records=1, max_records=10**9, min_redirects=1)` to `build`; update it in this task (import `Thresholds` lazily inside the fixture).

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_build.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'worldcat.pipeline.build'`

- [ ] **Step 3: Implement the build**

`src/worldcat/pipeline/build.py`:
```python
"""Build the WorldCat artifact once from the Anna's Archive dump.

    uv run python -m worldcat.pipeline.build \
        --source "/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__20250804T000000Z--20250804T000000Z.jsonl.seekable.zst" \
        --root /home/shane/wc-data --dump-date 2025-09-04 --workers 8 --memory-limit 16GB \
        --catalogue-isbns /home/shane/wc-data/our_isbns.txt

Stages: extract (frame-parallel) -> records -> isbns -> redirects -> holdings ->
gates -> report + manifest. A failed gate raises BuildFailed, leaves _staging in
place for inspection, and writes gates_passed=false so the API refuses the
version. There is no download, refresh or promotion: the dump is frozen.
"""

import hashlib
import shutil
import time
from pathlib import Path

import typer

from worldcat.pipeline import distill
from worldcat.pipeline.extract import extract_all
from worldcat.pipeline.gates import Thresholds, gates_passed, run_gates
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.report import StageTimings, write_build_report, write_manifest
from worldcat.pipeline.seektable import read_seek_table

app = typer.Typer(add_completion=False)


class BuildFailed(RuntimeError):
    """A quality gate refused the build."""


def source_fingerprint(source: Path) -> str:
    """sha256 over the file size, the first frame and the last frame: enough to
    tell two files apart without reading 281 GB."""
    frames = read_seek_table(source)
    digest = hashlib.sha256(str(source.stat().st_size).encode())
    with source.open("rb") as fh:
        for frame in (frames[0], frames[-1]):
            fh.seek(frame.offset)
            digest.update(fh.read(frame.compressed_size))
    return digest.hexdigest()


def _connect(paths: WorldcatPaths, memory_limit: str, threads: int | None):
    import duckdb

    con = duckdb.connect(database=":memory:")
    con.execute("SET preserve_insertion_order=false")
    con.execute(f"SET memory_limit='{memory_limit}'")
    con.execute(f"SET temp_directory='{paths.tmp_dir}'")
    if threads is not None:
        con.execute(f"SET threads={threads}")
    return con


def build(
    *,
    source: Path,
    root: Path,
    dump_date: str,
    workers: int = 8,
    memory_limit: str = "16GB",
    threads: int | None = None,
    keep_staging: bool = False,
    catalogue_isbns: Path | None = None,
    thresholds: Thresholds | None = None,
) -> dict:
    thresholds = thresholds or Thresholds()
    paths = WorldcatPaths(root=root, dump_date=dump_date)
    paths.ensure()
    timings = StageTimings()
    con = _connect(paths, memory_limit, threads)

    def stage(name: str, fn):
        started = time.time()
        result = fn()
        rows = result if isinstance(result, int) else None
        timings.record(name, time.time() - started, rows=rows)
        typer.echo(f"  {name}: {time.time() - started:.1f}s{f', {rows:,} rows' if rows else ''}")
        return result

    typer.echo(f"building {dump_date} in {paths.version_dir} from {source}")
    fingerprint = source_fingerprint(source)
    extract = stage("extract", lambda: extract_all(source, paths, workers=workers))
    timings.record("extract", timings.stages["extract"]["seconds"], rows=sum(s.kept for s in extract))
    stage("records", lambda: distill.build_records(con, paths))
    stage("isbns", lambda: distill.build_isbns(con, paths))
    stage("redirects", lambda: distill.build_redirects(con, paths))
    stage("holdings", lambda: distill.build_holdings(con, paths))

    results = run_gates(con, paths, extract_stats=extract, thresholds=thresholds, catalogue_isbns=catalogue_isbns)
    for result in results:
        typer.echo(f"  gate {result.name}: {result.status} -- {result.detail}")
    report = write_build_report(con, paths, dump_date=dump_date, source_fingerprint=fingerprint,
                                gate_results=results, timings=timings, extract=extract)
    write_manifest(paths, dump_date=dump_date, source_fingerprint=fingerprint, gate_results=results,
                   timings=timings, tables=report["tables"])
    con.close()

    if not gates_passed(results):
        raise BuildFailed("quality gates failed; _staging is kept and the manifest says gates_passed=false")
    if not keep_staging and paths.staging_dir.exists():
        shutil.rmtree(paths.staging_dir)
    typer.echo(f"built {dump_date}: {report['total_bytes'] / 1e9:.2f} GB across {len(report['tables'])} tables")
    return report


@app.command()
def main(
    source: Path = typer.Option(..., "--source", exists=True, dir_okay=False),  # noqa: B008
    root: Path = typer.Option(Path("/home/shane/wc-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option("2025-09-04", "--dump-date"),
    workers: int = typer.Option(8, "--workers"),
    memory_limit: str = typer.Option("16GB", "--memory-limit"),
    threads: int | None = typer.Option(None, "--threads"),
    keep_staging: bool = typer.Option(False, "--keep-staging"),
    catalogue_isbns: Path | None = typer.Option(None, "--catalogue-isbns"),  # noqa: B008
) -> None:
    build(source=source, root=root, dump_date=dump_date, workers=workers, memory_limit=memory_limit,
          threads=threads, keep_staging=keep_staging, catalogue_isbns=catalogue_isbns)


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the whole worldcat suite and lint**

Run: `uv run pytest tests/worldcat tests/fixtures/worldcat -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

Stage `data-sources/src/worldcat/pipeline/build.py`, `data-sources/tests/worldcat/test_build.py`, `data-sources/tests/conftest.py`; commit as `WorldCat: the build command`.

---
### Task 8: API settings, artifact state and `/version`

**Files:**
- Create: `data-sources/src/worldcat/api/deps.py`, `data-sources/src/worldcat/api/schemas.py`, `data-sources/src/worldcat/api/meta.py`, `data-sources/src/worldcat/api/main.py`
- Test: `data-sources/tests/worldcat/test_api_deps.py`, `data-sources/tests/worldcat/test_api_meta.py`

**Interfaces:**
- Produces: `Settings(data_root, data_version, memory_limit="2GB", temp_dir, threads=2, deadline_s=5.0)` with `Settings.from_env()` reading `WC_DATA_ROOT` (default `/data`), `WC_DATA_VERSION` (required), `WC_API_MEMORY_LIMIT`, `WC_API_TEMP_DIR`, `WC_API_THREADS`, `WC_API_DEADLINE_S`; exceptions `ConfigurationError`, `SymlinkedVersion`, `MissingTable`, `GatesFailed`, `VersionMismatch`, `MalformedArtifactFile`; `ArtifactState(paths, connection, manifest, report, deadline_s)`; `open_artifact(settings) -> ArtifactState`; `get_state(request)`; `cursor(state)` context manager.
- Produces: pydantic `Holdings`, `Record`, `IsbnResponse`, `LookupRequest`, `LookupResponse`.
- Produces: `create_app(state=None) -> FastAPI`, `factory()`; `meta.router` with `GET /version`.
- Consumes: `WorldcatPaths`, `TABLES`, `PIPELINE_VERSION`.

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_api_deps.py`:
```python
import json
import shutil
from pathlib import Path

import pytest

from worldcat.api.deps import (
    ConfigurationError,
    GatesFailed,
    MissingTable,
    Settings,
    SymlinkedVersion,
    VersionMismatch,
    open_artifact,
)
from worldcat.pipeline.paths import WorldcatPaths


def _settings(paths: WorldcatPaths, tmp_path: Path) -> Settings:
    return Settings(data_root=paths.root, data_version=paths.dump_date, temp_dir=tmp_path)


def _copied(tmp_path: Path, artifact: WorldcatPaths) -> WorldcatPaths:
    shutil.copytree(artifact.version_dir, tmp_path / "versions" / artifact.dump_date)
    return WorldcatPaths(root=tmp_path, dump_date=artifact.dump_date)


def test_from_env_reads_every_variable(monkeypatch):
    monkeypatch.setenv("WC_DATA_ROOT", "/srv/x")
    monkeypatch.setenv("WC_DATA_VERSION", "2025-09-04")
    monkeypatch.setenv("WC_API_MEMORY_LIMIT", "3GB")
    monkeypatch.setenv("WC_API_TEMP_DIR", "/tmp/wc")
    monkeypatch.setenv("WC_API_THREADS", "4")
    monkeypatch.setenv("WC_API_DEADLINE_S", "7.5")
    s = Settings.from_env()
    assert (s.data_root, s.data_version, s.memory_limit) == (Path("/srv/x"), "2025-09-04", "3GB")
    assert (s.temp_dir, s.threads, s.deadline_s) == (Path("/tmp/wc"), 4, 7.5)


def test_from_env_defaults_and_treats_empty_as_unset(monkeypatch):
    monkeypatch.setenv("WC_DATA_VERSION", "2025-09-04")
    monkeypatch.setenv("WC_API_THREADS", "")
    for name in ("WC_DATA_ROOT", "WC_API_MEMORY_LIMIT", "WC_API_DEADLINE_S"):
        monkeypatch.delenv(name, raising=False)
    s = Settings.from_env()
    assert (s.data_root, s.memory_limit, s.threads, s.deadline_s) == (Path("/data"), "2GB", 2, 5.0)


def test_from_env_without_a_version_is_a_configuration_error(monkeypatch):
    monkeypatch.delenv("WC_DATA_VERSION", raising=False)
    with pytest.raises(ConfigurationError, match="WC_DATA_VERSION"):
        Settings.from_env()


def test_a_gate_failed_version_refuses_to_boot(tmp_path, worldcat_artifact):
    paths = _copied(tmp_path, worldcat_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["gates_passed"] = False
    paths.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(GatesFailed, match=worldcat_artifact.dump_date):
        open_artifact(_settings(paths, tmp_path))


def test_a_missing_manifest_missing_table_symlink_and_old_pipeline_each_refuse(tmp_path, worldcat_artifact):
    paths = _copied(tmp_path, worldcat_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["pipeline_version"] = 99
    paths.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(VersionMismatch):
        open_artifact(_settings(paths, tmp_path))
    paths.manifest_path.unlink()
    with pytest.raises(GatesFailed, match="manifest"):
        open_artifact(_settings(paths, tmp_path))
    paths.table("holdings").unlink()
    with pytest.raises(MissingTable, match="holdings"):
        open_artifact(_settings(paths, tmp_path))
    link_root = tmp_path / "linked"
    (link_root / "versions").mkdir(parents=True)
    (link_root / "versions" / "current").symlink_to(worldcat_artifact.version_dir)
    with pytest.raises(SymlinkedVersion):
        open_artifact(Settings(data_root=link_root, data_version="current", temp_dir=tmp_path))


def test_a_good_version_opens_with_the_manifest_and_report(tmp_path, worldcat_artifact):
    state = open_artifact(_settings(worldcat_artifact, tmp_path))
    try:
        assert state.manifest["gates_passed"] is True
        assert state.report["tables"]["records"]["rows"] > 0
        assert state.deadline_s == 5.0
        (one,) = state.connection.execute("SELECT 1").fetchone()
        assert one == 1
    finally:
        state.connection.close()
```

`tests/worldcat/test_api_meta.py`:
```python
import duckdb
import pytest
from fastapi.testclient import TestClient

from worldcat.api.deps import Settings, open_artifact
from worldcat.api.main import create_app


@pytest.fixture(scope="module")
def client(worldcat_artifact, tmp_path_factory):
    state = open_artifact(Settings(data_root=worldcat_artifact.root, data_version=worldcat_artifact.dump_date,
                                   temp_dir=tmp_path_factory.mktemp("wc-tmp")))
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_version_reports_the_dump_and_the_gates(client):
    body = client.get("/version").json()
    assert body["source"] == "worldcat"
    assert body["dump_date"] == "2025-09-04"
    assert body["pipeline_version"] == 1
    assert body["gates_passed"] is True
    assert body["tables"]["records"] > 0
    assert {g["name"] for g in body["gates"]} >= {"row_counts", "canaries", "bad_frames"}
    assert len(body["source_fingerprint"]) == 64


def test_no_endpoint_accepts_a_write_method(client):
    for method in ("put", "patch", "delete"):
        assert getattr(client, method)("/version").status_code in (404, 405)


def test_the_connection_is_closed_when_the_app_shuts_down(worldcat_artifact, tmp_path):
    state = open_artifact(Settings(data_root=worldcat_artifact.root, data_version=worldcat_artifact.dump_date, temp_dir=tmp_path))
    with TestClient(create_app(state)):
        pass
    with pytest.raises(duckdb.ConnectionException):
        state.connection.execute("select 1")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_api_deps.py tests/worldcat/test_api_meta.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'worldcat.api.deps'`

- [ ] **Step 3: Implement settings, state, schemas, meta and the app**

`src/worldcat/api/deps.py`:
```python
"""Settings from the environment, the artifact opened at boot, per-request cursors."""

from __future__ import annotations

import contextlib
import json
import math
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
from fastapi import Request

from worldcat.pipeline.paths import TABLES, WorldcatPaths
from worldcat.pipeline.report import PIPELINE_VERSION

SOURCE = "worldcat"


class ConfigurationError(RuntimeError): ...


class SymlinkedVersion(RuntimeError): ...


class MissingTable(RuntimeError): ...


class GatesFailed(RuntimeError): ...


class VersionMismatch(RuntimeError): ...


class MalformedArtifactFile(RuntimeError): ...


def _positive_env(name: str, parse, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default  # Compose forwards an unset host variable as ""
    try:
        value = parse(raw)
    except ValueError:
        value = None
    if value is None or not math.isfinite(value) or value <= 0:
        raise ConfigurationError(f"{name} must be a positive number, not {raw!r}")
    return value


@dataclass(frozen=True)
class Settings:
    data_root: Path
    data_version: str
    memory_limit: str = "2GB"
    temp_dir: Path = field(default_factory=lambda: Path(tempfile.gettempdir()))
    threads: int = 2
    deadline_s: float = 5.0

    @classmethod
    def from_env(cls) -> Settings:
        version = os.environ.get("WC_DATA_VERSION")
        if not version:
            raise ConfigurationError(
                "WC_DATA_VERSION is not set -- the API opens an explicit versions/<dump-date> and never guesses"
            )
        return cls(
            data_root=Path(os.environ.get("WC_DATA_ROOT") or "/data"),
            data_version=version,
            memory_limit=os.environ.get("WC_API_MEMORY_LIMIT") or "2GB",
            temp_dir=Path(os.environ.get("WC_API_TEMP_DIR") or tempfile.gettempdir()),
            threads=_positive_env("WC_API_THREADS", int, 2),
            deadline_s=_positive_env("WC_API_DEADLINE_S", float, 5.0),
        )


@dataclass
class ArtifactState:
    paths: WorldcatPaths
    connection: duckdb.DuckDBPyConnection
    manifest: dict
    report: dict
    deadline_s: float = 5.0


def _read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as exc:
        raise MalformedArtifactFile(f"{path} is not valid JSON: {exc}") from None


def open_artifact(settings: Settings) -> ArtifactState:
    paths = WorldcatPaths(root=settings.data_root, dump_date=settings.data_version)
    if paths.version_dir.is_symlink():
        raise SymlinkedVersion(f"{paths.version_dir} is a symlink; point WC_DATA_VERSION at a real version directory")
    for name in TABLES:
        if not paths.table(name).exists():
            raise MissingTable(f"version {settings.data_version} has no {name}.parquet")
    if not paths.manifest_path.exists():
        raise GatesFailed(f"version {settings.data_version} has no manifest.json -- an unfinished build is not a version")
    manifest = _read_json(paths.manifest_path)
    if manifest.get("gates_passed") is not True:
        raise GatesFailed(
            f"version {settings.data_version} did not pass its quality gates "
            f"(manifest gates_passed={manifest.get('gates_passed')!r}); refusing to serve it"
        )
    if manifest.get("pipeline_version") != PIPELINE_VERSION:
        raise VersionMismatch(
            f"artifact pipeline_version {manifest.get('pipeline_version')!r} != running {PIPELINE_VERSION}"
        )
    report = _read_json(paths.report_path)
    settings.temp_dir.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(database=":memory:")
    connection.execute(f"SET memory_limit='{settings.memory_limit}'")
    connection.execute(f"SET threads={settings.threads}")
    connection.execute(f"SET temp_directory='{settings.temp_dir}'")
    return ArtifactState(paths=paths, connection=connection, manifest=manifest, report=report,
                         deadline_s=settings.deadline_s)


def get_state(request: Request) -> ArtifactState:
    return request.app.state.artifact


@contextlib.contextmanager
def cursor(state: ArtifactState):
    """A per-request cursor. Never share the connection itself across threads."""
    handle = state.connection.cursor()
    try:
        yield handle
    finally:
        handle.close()
```

`src/worldcat/api/schemas.py`:
```python
from pydantic import BaseModel, Field


class Holdings(BaseModel):
    total_holding_count: int
    total_editions: int | None = None


class Record(BaseModel):
    oclc: int
    title: str | None = None
    subtitle: str | None = None
    creator: str | None = None
    contributors: list[str] = []
    year: int | None = None
    publication_date_raw: str | None = None
    publisher: str | None = None
    publication_place: str | None = None
    cataloging_language: str | None = None
    specific_format: str | None = None
    edition_statement: str | None = None
    physical_description: str | None = None
    series: str | None = None
    genre: str | None = None
    subjects: list[str] = []
    isbn13s: list[str] = []
    merged_oclc: list[int] = []
    other_format_oclc: list[int] = []
    total_editions: int | None = None
    summary: str | None = None
    source_type: str | None = None
    holdings: Holdings | None = None
    redirected_from: int | None = None


class IsbnResponse(BaseModel):
    isbn13: str
    records: list[Record]


class LookupRequest(BaseModel):
    isbn13s: list[str] = Field(max_length=500)


class LookupResponse(BaseModel):
    results: dict[str, list[Record]]
```

`src/worldcat/api/meta.py`:
```python
from fastapi import APIRouter, Depends

from worldcat.api.deps import SOURCE, ArtifactState, get_state
from worldcat.pipeline.report import PIPELINE_VERSION

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    return {
        "source": SOURCE,
        "dump_date": state.manifest.get("dump_date"),
        "pipeline_version": PIPELINE_VERSION,
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "source_fingerprint": state.manifest.get("source_fingerprint"),
        "tables": state.manifest.get("tables", {}),
        "gates": state.report.get("gates", []),
    }
```

`src/worldcat/api/main.py`:
```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from worldcat.api import meta, retrieval
from worldcat.api.deps import ArtifactState, Settings, open_artifact


def create_app(state: ArtifactState | None = None) -> FastAPI:
    artifact_state = state or open_artifact(Settings.from_env())

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        artifact_state.connection.close()

    app = FastAPI(title="WorldCat data service", version="0.1.0", lifespan=lifespan)
    app.state.artifact = artifact_state
    app.include_router(meta.router)
    app.include_router(retrieval.router)
    return app


def factory() -> FastAPI:
    return create_app()
```

Until Task 9 exists, create `src/worldcat/api/retrieval.py` containing only `from fastapi import APIRouter` and `router = APIRouter()`.

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat/test_api_deps.py tests/worldcat/test_api_meta.py -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

Stage the four source files, the stub `retrieval.py` and the two tests; commit as `WorldCat API: settings, artifact state, /version`.

---

### Task 9: Lookup routes

**Files:**
- Modify: `data-sources/src/worldcat/api/retrieval.py`
- Test: `data-sources/tests/worldcat/test_api_retrieval.py`

**Interfaces:**
- Produces: `GET /isbns/{isbn}` → `IsbnResponse`; `GET /oclc/{number}` → `Record`; `POST /lookup` → `LookupResponse`; `fetch_records(cur, paths, oclcs: list[int]) -> dict[int, Record]`; `resolve_oclc(cur, paths, number) -> tuple[int, int | None]`.
- Consumes: `cursor`, `get_state`, `ArtifactState`, schemas (Task 8); `common.normalize.normalize_isbn`; `openlibrary.api.limits.Deadline` (the existing interrupt-on-deadline helper, reused as is).

- [ ] **Step 1: Write the failing tests**

`tests/worldcat/test_api_retrieval.py`:
```python
import pytest
from fastapi.testclient import TestClient

from worldcat.api.deps import Settings, open_artifact
from worldcat.api.main import create_app


@pytest.fixture(scope="module")
def client(worldcat_artifact, tmp_path_factory):
    state = open_artifact(Settings(data_root=worldcat_artifact.root, data_version=worldcat_artifact.dump_date,
                                   temp_dir=tmp_path_factory.mktemp("wc-tmp")))
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_an_isbn13_returns_its_records_with_holdings(client):
    body = client.get("/isbns/9780735211292").json()
    assert body["isbn13"] == "9780735211292"
    records = {r["oclc"]: r for r in body["records"]}
    atomic = records[1055766559]
    assert atomic["genre"] == "Nonfiction"
    assert "Habit" in atomic["subjects"]
    assert atomic["holdings"] == {"total_holding_count": 4000, "total_editions": 25}
    assert atomic["redirected_from"] is None
    assert "9781847941831" in atomic["isbn13s"]


def test_isbn10_with_x_and_hyphens_is_normalised(client):
    body = client.get("/isbns/0-395-47690-9").json()
    assert body["isbn13"] == "9780395476901"
    assert [r["oclc"] for r in body["records"]] == [1000415078]
    assert client.get("/isbns/080442957X").status_code == 200  # a valid X check digit is accepted


def test_an_unknown_isbn_is_an_empty_list_not_a_404(client):
    body = client.get("/isbns/9780306406157").json()  # synthetic brief-only record exists
    assert body["records"][0]["oclc"] == 9000000030
    body = client.get("/isbns/9783161484100").json()
    assert body == {"isbn13": "9783161484100", "records": []}


def test_a_bad_check_digit_or_garbage_is_422(client):
    assert client.get("/isbns/9780000000001").status_code == 422
    assert client.get("/isbns/not-an-isbn").status_code == 422


def test_oclc_lookup_follows_redirects_and_reports_the_source(client):
    direct = client.get("/oclc/1055766559").json()
    assert direct["redirected_from"] is None and direct["title"].startswith("Atomic")
    chained = client.get("/oclc/9000000010").json()
    assert chained["oclc"] == 1055766559 and chained["redirected_from"] == 9000000010
    assert client.get("/oclc/424242424242").status_code == 404
    assert client.get("/oclc/9000000020").status_code == 404  # a cycle resolves to nothing
    assert client.get("/oclc/abc").status_code == 422


def test_lookup_batch_keys_every_request_as_given(client):
    body = client.post("/lookup", json={"isbn13s": ["9780735211292", "0-395-47690-9", "9783161484100"]}).json()
    assert set(body["results"]) == {"9780735211292", "0-395-47690-9", "9783161484100"}
    assert body["results"]["0-395-47690-9"][0]["oclc"] == 1000415078
    assert body["results"]["9783161484100"] == []


def test_lookup_rejects_more_than_500_or_an_invalid_isbn(client):
    assert client.post("/lookup", json={"isbn13s": ["9780735211292"] * 501}).status_code == 422
    response = client.post("/lookup", json={"isbn13s": ["9780735211292", "garbage"]})
    assert response.status_code == 422
    assert "garbage" in response.json()["detail"]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `uv run pytest tests/worldcat/test_api_retrieval.py -v`
Expected: FAIL with 404s (the stub router has no routes)

- [ ] **Step 3: Implement the routes**

`src/worldcat/api/retrieval.py`:
```python
"""Exact lookups. Routes are sync `def` on purpose: DuckDB blocks, and FastAPI
runs sync routes in its threadpool."""

import duckdb
from fastapi import APIRouter, Depends, HTTPException

from common.normalize import normalize_isbn
from openlibrary.api.limits import Deadline
from worldcat.api.deps import ArtifactState, cursor, get_state
from worldcat.api.schemas import Holdings, IsbnResponse, LookupRequest, LookupResponse, Record
from worldcat.pipeline.paths import WorldcatPaths

router = APIRouter()
MAX_BATCH = 500
RECORD_COLUMNS = (
    "oclc", "title", "subtitle", "creator", "contributors", "year", "publication_date_raw",
    "publisher", "publication_place", "cataloging_language", "specific_format", "edition_statement",
    "physical_description", "series", "genre", "subjects", "isbn13s", "merged_oclc",
    "other_format_oclc", "total_editions", "summary", "source_type",
)


def fetch_records(cur: duckdb.DuckDBPyConnection, paths: WorldcatPaths, oclcs: list[int]) -> dict[int, Record]:
    if not oclcs:
        return {}
    placeholders = ", ".join("?" for _ in oclcs)
    columns = ", ".join(f"r.{c}" for c in RECORD_COLUMNS)
    rows = cur.execute(
        f"SELECT {columns}, h.total_holding_count, h.total_editions AS holdings_editions "
        f"FROM '{paths.table('records')}' r "
        f"LEFT JOIN '{paths.table('holdings')}' h USING (oclc) "
        f"WHERE r.oclc IN ({placeholders})",
        oclcs,
    ).fetchall()
    out: dict[int, Record] = {}
    for row in rows:
        data = dict(zip(RECORD_COLUMNS, row[: len(RECORD_COLUMNS)], strict=True))
        for key in ("contributors", "subjects", "isbn13s", "merged_oclc", "other_format_oclc"):
            data[key] = data[key] or []
        holding_count, holding_editions = row[len(RECORD_COLUMNS) :]
        if holding_count is not None:
            data["holdings"] = Holdings(total_holding_count=holding_count, total_editions=holding_editions)
        out[data["oclc"]] = Record(**data)
    return out


def resolve_oclc(cur, paths: WorldcatPaths, number: int) -> tuple[int, int | None]:
    """(current number, redirected_from). A cycle resolves to nothing: (number, None) with no record."""
    row = cur.execute(
        f"SELECT to_oclc, is_cycle FROM '{paths.table('redirects')}' WHERE from_oclc = ?", [number]
    ).fetchone()
    if row is None or row[1]:
        return number, None
    return row[0], number


def _isbn13_or_422(value: str) -> str:
    normalized = normalize_isbn(value)
    if normalized is None or not normalized.checksum_ok or not normalized.isbn13:
        raise HTTPException(status_code=422, detail=f"{value!r} is not a valid ISBN")
    return normalized.isbn13


def _records_for_isbn13s(cur, paths: WorldcatPaths, isbn13s: list[str]) -> dict[str, list[Record]]:
    if not isbn13s:
        return {}
    placeholders = ", ".join("?" for _ in isbn13s)
    pairs = cur.execute(
        f"SELECT isbn13, oclc FROM '{paths.table('isbns')}' WHERE isbn13 IN ({placeholders})", isbn13s
    ).fetchall()
    records = fetch_records(cur, paths, sorted({oclc for _, oclc in pairs}))
    out: dict[str, list[Record]] = {isbn: [] for isbn in isbn13s}
    for isbn13, oclc in pairs:
        if oclc in records:
            out[isbn13].append(records[oclc])
    return out


def _with_deadline(state: ArtifactState, fn):
    with cursor(state) as cur, Deadline(cur, state.deadline_s) as deadline:
        try:
            return fn(cur)
        except duckdb.InterruptException:
            if not deadline.expired:
                raise
            raise HTTPException(status_code=504, detail=f"deadline: lookup stopped after {state.deadline_s:g} s") from None


@router.get("/isbns/{isbn}", response_model=IsbnResponse)
def get_isbn(isbn: str, state: ArtifactState = Depends(get_state)):
    isbn13 = _isbn13_or_422(isbn)
    records = _with_deadline(state, lambda cur: _records_for_isbn13s(cur, state.paths, [isbn13]))
    return IsbnResponse(isbn13=isbn13, records=records.get(isbn13, []))


@router.get("/oclc/{number}", response_model=Record)
def get_oclc(number: int, state: ArtifactState = Depends(get_state)):
    def run(cur):
        current, redirected_from = resolve_oclc(cur, state.paths, number)
        record = fetch_records(cur, state.paths, [current]).get(current)
        if record is None:
            raise HTTPException(status_code=404, detail=f"unknown OCLC number: {number}")
        return record.model_copy(update={"redirected_from": redirected_from})

    return _with_deadline(state, run)


@router.post("/lookup", response_model=LookupResponse)
def post_lookup(request: LookupRequest, state: ArtifactState = Depends(get_state)):
    if len(request.isbn13s) > MAX_BATCH:
        raise HTTPException(status_code=422, detail=f"at most {MAX_BATCH} ISBNs per request")
    normalized: dict[str, str] = {}
    bad = []
    for value in request.isbn13s:
        parsed = normalize_isbn(value)
        if parsed is None or not parsed.checksum_ok or not parsed.isbn13:
            bad.append(value)
        else:
            normalized[value] = parsed.isbn13
    if bad:
        raise HTTPException(status_code=422, detail=f"invalid ISBN(s): {bad}")
    found = _with_deadline(
        state, lambda cur: _records_for_isbn13s(cur, state.paths, sorted(set(normalized.values())))
    )
    return LookupResponse(results={value: found.get(isbn13, []) for value, isbn13 in normalized.items()})
```

`LookupRequest.isbn13s` already carries `max_length=500`, so pydantic answers 422 before the handler for the 501 case; the explicit check stays as documentation of intent.

- [ ] **Step 4: Run the tests and lint**

Run: `uv run pytest tests/worldcat -v && uv run ruff check . && uv run ruff format --check .`
Expected: PASS

- [ ] **Step 5: Commit**

Stage `data-sources/src/worldcat/api/retrieval.py` and the test; commit as `WorldCat API: ISBN, OCLC and batch lookups`.

---

### Task 10: Image and local compose

**Files:**
- Create: `data-sources/worldcat.Dockerfile`
- Modify: `data-sources/docker-compose.yml` (add the `worldcat` service), `data-sources/README.md` (one paragraph)

**Interfaces:**
- Produces: image `the-greatest/worldcat:latest`, port 8082, `uvicorn --factory worldcat.api.main:factory`; compose service `worldcat` under profile `worldcat`, binding `${WC_API_BIND:-127.0.0.1}:8082:8082`, mounting `${WC_DATA_HOST:-/home/shane/wc-data}:/data:ro`.

The API never decompresses anything, so the image installs no extras: `zstandard` is for the build on the development machine only.

- [ ] **Step 1: Write the Dockerfile**

`data-sources/worldcat.Dockerfile`:
```dockerfile
# The WorldCat lookup API. Same shape as the Open Library image: core
# dependencies only (no extras -- the build-time zstd reader never ships).
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project
COPY src/ ./src/
RUN uv sync --locked --no-dev
ENV PATH="/app/.venv/bin:$PATH"
RUN useradd --create-home --uid 10001 worldcat
USER worldcat
EXPOSE 8082
CMD ["uvicorn", "--factory", "worldcat.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8082"]
```

- [ ] **Step 2: Add the compose service**

Append to `data-sources/docker-compose.yml` under `services:`:
```yaml
  # WorldCat exact-lookup API (docs/features/worldcat-data-service.md). Behind a
  # profile so `docker compose up` on the Open Library VM never starts it; the
  # worldcat VM's deploy names it explicitly. Every variable is forwarded with a
  # default because Compose does not pass through an unlisted host variable.
  worldcat:
    build:
      context: .
      dockerfile: worldcat.Dockerfile
    image: the-greatest/worldcat:latest
    profiles: ["worldcat"]
    restart: unless-stopped
    ports:
      - "${WC_API_BIND:-127.0.0.1}:8082:8082"
    volumes:
      - ${WC_DATA_HOST:-/home/shane/wc-data}:/data:ro
    environment:
      WC_DATA_ROOT: /data
      WC_DATA_VERSION: "${WC_DATA_VERSION:-2025-09-04}"
      WC_API_MEMORY_LIMIT: "${WC_API_MEMORY_LIMIT:-2GB}"
      WC_API_TEMP_DIR: "${WC_API_TEMP_DIR:-/tmp}"
      WC_API_THREADS: "${WC_API_THREADS:-2}"
      WC_API_DEADLINE_S: "${WC_API_DEADLINE_S:-5}"
```

- [ ] **Step 3: Verify the image builds and boots against a real or fixture artifact**

Run from `data-sources/`:
```bash
docker compose --profile worldcat build worldcat
WC_DATA_HOST=/home/shane/wc-data WC_DATA_VERSION=2025-09-04 docker compose --profile worldcat up -d worldcat
curl -fsS 127.0.0.1:8082/version | head -c 300
docker compose --profile worldcat down
```
Expected: the build succeeds; if no real artifact exists yet, point `WC_DATA_HOST` at a copy of the test-session artifact (`uv run pytest tests/worldcat/test_build.py -k four_tables --basetemp=/tmp/wc-fixture` leaves one under `/tmp/wc-fixture/wc-artifact0`) and `/version` answers with `"gates_passed": true`.

- [ ] **Step 4: Document and commit**

Add to `data-sources/README.md` a short "WorldCat" paragraph: what the package is, the build command from Task 7's docstring, the compose profile, and that the dump is frozen. Stage `data-sources/worldcat.Dockerfile`, `data-sources/docker-compose.yml`, `data-sources/README.md`; commit as `WorldCat: image and compose service`.

---
### Task 11: The `worldcat` VM role on the host side

**Files:**
- Modify: `deployment/home-server/lib/vm.sh` (`vm_spec`, `render_vm_env`, tunnel loops), `deployment/home-server/lib/common.sh` (`running_foreign_vmids`), `deployment/home-server/lib/host.sh` (firewall pairs), `deployment/home-server/provision` (role loops, `--rebuild` help), `deployment/home-server/lib/verify.sh`
- Create: `deployment/home-server/host/firewall/130.fw`
- Test: `deployment/home-server/test/render_test.sh`, `deployment/home-server/test/provision_test.sh`

**Interfaces:**
- Produces: role `worldcat`: `VMID=130 NAME=worldcat CORES=2 MEM=4096 OSDISK=32 DATADISK=40`, LAN bridge `vmbr0`, `STARTUP="order=3"`; env keys `ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH` (HC_REFRESH empty, like fetcher); secrets `WORLDCAT_TUNNEL_TOKEN`, `HC_WORLDCAT_HEARTBEAT`, `HC_WORLDCAT_DEPLOY`.
- Consumes: the existing `vm_spec`/`render_vm_env` case statements.

- [ ] **Step 1: Write the failing shell tests**

In `deployment/home-server/test/render_test.sh`, extend the role loop to `for role in ol fetcher worldcat` and add:
```bash
t_worldcat_vm_spec() { vm_spec worldcat && [ "$VMID $CORES $MEM $OSDISK $DATADISK $STARTUP" = "130 2 4096 32 40 order=3" ]; }
t_worldcat_env_keys() {
  render_vm_env worldcat "$tmp/wc.env"
  [ "$(cut -d= -f1 "$tmp/wc.env" | tr '\n' ' ')" = "ROLE REPO_REF TUNNELS_ENABLED TUNNEL_TOKEN HC_HEARTBEAT HC_DEPLOY HC_REFRESH " ]
}
t_worldcat_token_isolation() {
  WORLDCAT_TUNNEL_TOKEN=wc-tok OL_TUNNEL_TOKEN=ol-tok FETCHER_TUNNEL_TOKEN=f-tok render_vm_env worldcat "$tmp/wc.env"
  grep -q '^TUNNEL_TOKEN=wc-tok$' "$tmp/wc.env" && ! grep -q 'ol-tok\|f-tok\|RECOMMENDATIONS' "$tmp/wc.env"
}
t_worldcat_firewall_rendered() { [ -f "$REPO_ROOT/deployment/home-server/host/firewall/130.fw" ] && grep -q 'dport 22' "$REPO_ROOT/deployment/home-server/host/firewall/130.fw"; }
check worldcat_vm_spec t_worldcat_vm_spec
check worldcat_env_keys t_worldcat_env_keys
check worldcat_token_isolation t_worldcat_token_isolation
check worldcat_firewall_rendered t_worldcat_firewall_rendered
```
Follow the file's own variable names for the temp dir and repo root (read the existing `t_env_keys` and `t_vm_spec_sizes` and mirror them exactly).

In `deployment/home-server/test/provision_test.sh` add a check that `running_foreign_vmids` ignores 130: find the existing test of that function (it feeds a fake `qm list` through a stub) and add a row `130 worldcat running` to its input, asserting 130 is not reported as foreign.

Run: `deployment/home-server/test/run.sh`
Expected: the new checks FAIL (`unknown VM role 'worldcat'`).

- [ ] **Step 2: Add the role**

`lib/vm.sh`, inside `vm_spec`'s `case` before `*)`:
```bash
    worldcat)
      VMID=130 NAME=worldcat CORES=2 MEM=4096 OSDISK=32 DATADISK=40
      NET="virtio,bridge=vmbr0,firewall=1" IPCONFIG="ip=dhcp,ip6=auto" NAMESERVER="" STARTUP="order=3" ;;
```
and change the `die` text to `(ol, fetcher or worldcat)`.

Inside `render_vm_env`'s `case`:
```bash
    worldcat) printf '%s\n' "ROLE=worldcat" "REPO_REF=$REPO_REF" "TUNNELS_ENABLED=$TUNNELS_ENABLED" \
          "TUNNEL_TOKEN=${WORLDCAT_TUNNEL_TOKEN:-}" "HC_HEARTBEAT=${HC_WORLDCAT_HEARTBEAT:-}" \
          "HC_DEPLOY=${HC_WORLDCAT_DEPLOY:-}" "HC_REFRESH=" ;;
```
`enable_tunnels`/`disable_tunnels`: require `WORLDCAT_TUNNEL_TOKEN` alongside the other two and loop `for role in fetcher ol worldcat`. Every other `for role in fetcher ol` in `vm.sh` and `provision` (converge, push-env) becomes `for role in fetcher ol worldcat`. `provision`'s `--rebuild` message and help become `ol|fetcher|worldcat`.

`lib/common.sh` `running_foreign_vmids`: `$1 != 110 && $1 != 120 && $1 != 130`.

`lib/host.sh` `converge_host_firewall`: copy `130.fw` alongside `110.fw` and add `"130.fw:/etc/pve/firewall/130.fw"` to `pairs`.

`host/firewall/130.fw`:
```
# VM 130 `worldcat`, on the LAN. Nothing listens beyond SSH: the API publishes
# on loopback and leaves through cloudflared.
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT
dhcp: 1
ndp: 1
radv: 0

[RULES]
IN ACCEPT -source +lan -p tcp -dport 22 -log nolog
```

`lib/verify.sh`: `verify_vms` and `verify_idempotent` loop over `ol fetcher worldcat`; after the `ol` version check add:
```bash
  if vm_ssh worldcat "test -f /srv/wc-data/current-version"; then
    expect "worldcat: /version answers" vm_ssh worldcat "curl -fsS 127.0.0.1:8082/version"
  else
    echo "SKIP  worldcat: no WorldCat version yet (copy the artifact and write current-version: docs/features/worldcat-data-service.md)"
  fi
```
and in `verify_recovery` add `crash_service worldcat the-greatest-worldcat-1 "curl -fsS 127.0.0.1:8082/version"` under the same guard.

- [ ] **Step 3: Run the shell tests**

Run: `deployment/home-server/test/run.sh`
Expected: PASS, shellcheck clean.

- [ ] **Step 4: Commit**

Stage the changed files under `deployment/home-server/`; commit as `Home server: worldcat VM role (130, 2 vCPU, 4 GB, 40 GB data disk)`.

---

### Task 12: The `worldcat` VM role on the guest side

**Files:**
- Modify: `deployment/home-server/guest/lib.sh`, `guest/compose.sh`, `guest/deploy.sh`, `guest/first-boot.sh`, `guest/install-units.sh`, `guest/heartbeat.sh`, `deployment/home-server/compose.tunnel.yml`
- Create: `deployment/home-server/compose.worldcat.yml`
- Test: `deployment/home-server/test/deploy_test.sh`, `test/timers_test.sh`, `test/compose_config_test.sh`

**Interfaces:**
- Produces: on the VM, the data disk is `LABEL=wc-data` mounted at `/srv/wc-data` (`WC_DATA` in `lib.sh`); `compose.sh` exports `WC_DATA_HOST="$WC_DATA"` and reads `WC_DATA_VERSION` from `/srv/wc-data/current-version` when unset; `deploy.sh` builds and starts service `worldcat` (plus `cloudflared` when tunnels are on) only when `current-version` exists; the heartbeat curls `127.0.0.1:8082/version`; no extra units.

- [ ] **Step 1: Write the failing shell tests**

`test/deploy_test.sh`: mirror `t_ol_without_version` and `t_ol_with_version` as `t_worldcat_without_version` (ROLE=worldcat, no `current-version` → `called '^compose build worldcat$'` and NOT `called '^compose up -d --remove-orphans worldcat'`) and `t_worldcat_with_version` (writes `$WC_DATA/current-version` → `called '^compose up -d --remove-orphans worldcat$'`). The sandbox helper must export `WC_DATA` the way it exports `OL_DATA` (add it to `helpers.sh new_sandbox`).

`test/timers_test.sh`: `t_worldcat_beats_on_version` (stub `curl` to succeed for `127.0.0.1:8082/version`, assert the heartbeat pings) and `t_units_for_worldcat` (install-units installs only the three base units).

`test/compose_config_test.sh`: `t_worldcat_api` using `cfg worldcat worldcat` (second argument sets `COMPOSE_PROFILES`), asserting with jq: `.services.worldcat.environment.WC_API_MEMORY_LIMIT == "2GB"`, `.services.worldcat.environment.WC_API_THREADS == "2"`, `.services.worldcat.volumes[0].read_only == true`, `.services.worldcat.mem_limit` is `3g` (Compose renders it as bytes: `3221225472`), and `t_worldcat_alias` asserting `.services.worldcat.networks.default.aliases == ["worldcat"]`.

Run: `deployment/home-server/test/run.sh`
Expected: the new checks FAIL.

- [ ] **Step 2: Implement the guest side**

`guest/lib.sh`: add `WC_DATA="${WC_DATA:-/srv/wc-data}"` next to `OL_DATA`.

`guest/compose.sh`: after the `OL_DATA_VERSION` block add:
```bash
export WC_DATA_HOST="$WC_DATA"
if [ -z "${WC_DATA_VERSION:-}" ] && [ -f "$WC_DATA/current-version" ]; then
  WC_DATA_VERSION="$(cat "$WC_DATA/current-version")"
  export WC_DATA_VERSION
fi
```

`guest/deploy.sh`: in the role `case` add `worldcat) service=worldcat; build=(worldcat) ;;` and change the version guard to:
```bash
if [ "$ROLE" = ol ] && [ ! -f "$OL_DATA/current-version" ]; then
  log "no Open Library version yet; ol-refresh starts api after the first build"
  if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then "$COMPOSE" up -d cloudflared || fail "compose up cloudflared"; fi
elif [ "$ROLE" = worldcat ] && [ ! -f "$WC_DATA/current-version" ]; then
  log "no WorldCat version yet; copy the artifact and write $WC_DATA/current-version, then touch force-deploy"
  if [ "${TUNNELS_ENABLED:-0}" = 1 ]; then "$COMPOSE" up -d cloudflared || fail "compose up cloudflared"; fi
else
  ...unchanged...
fi
```

`guest/first-boot.sh`: add a `worldcat)` branch identical to the `ol)` one with `mkfs.ext4 -q -L wc-data`, `LABEL=wc-data $WC_DATA`, and `mkdir -p "$WC_DATA"`. Factor the shared disk logic into a function `mount_data_disk <label> <mountpoint>` called by both branches, so the two stay identical.

`guest/install-units.sh`: add `worldcat) ;;` (base units only). `guest/heartbeat.sh`: add `worldcat) url=http://127.0.0.1:8082/version ;;`.

`compose.worldcat.yml`:
```yaml
# The `worldcat` VM's production settings (docs/features/worldcat-data-service.md),
# merged over data-sources/docker-compose.yml by guest/compose.sh. Sized for a
# 2-vCPU, 4 GB VM: 2 GB for DuckDB, the rest is page cache over the artifact.
# Exact lookups touch one row group; nothing here spills.
services:
  worldcat:
    mem_limit: 3g
    environment:
      WC_API_MEMORY_LIMIT: 2GB
      WC_API_THREADS: "2"
```

`compose.tunnel.yml`: add
```yaml
  worldcat:
    networks:
      default:
        aliases: [worldcat]
```
(the Cloudflare tunnel's ingress for `worldcat-api.thegreatestbooks.org` points at `http://worldcat:8082`; the hostname-to-alias mapping lives in the dashboard, as the file's header says).

- [ ] **Step 3: Run the shell tests**

Run: `deployment/home-server/test/run.sh`
Expected: PASS, shellcheck clean. `t_build_cpus_fit_vm` in `provision_test.sh` still passes: `compose.worldcat.yml` sets no `cpus:`.

- [ ] **Step 4: Commit**

Stage the changed and new files under `deployment/home-server/`; commit as `Home server: worldcat guest role, compose overlay, heartbeat`.

---

### Task 13: Runbook and owner steps

**Files:**
- Modify: `docs/features/home-server.md` (VM table, secrets-keys table, alerts table, rebuild runbook), `docs/launch-todo.md`, `deployment/ENV.md`, `.env.example`

- [ ] **Step 1: Update the home-server runbook**

In `docs/features/home-server.md`:
- VM table: add `| 130 \`worldcat\` | WorldCat exact-lookup API | 2 | 4 GB, no ballooning | 32 GB OS disk on \`local-zfs\`; 40 GB data disk on \`rpool2\`, ext4, mounted at \`/srv/wc-data\` | \`vmbr0\`, LAN |`.
- Secrets-keys table: `WORLDCAT_TUNNEL_TOKEN`, `HC_WORLDCAT_HEARTBEAT`, `HC_WORLDCAT_DEPLOY`, each "optional; the worldcat VM".
- Alerts table: two rows, `worldcat heartbeat` (every 10 min, `/version` on loopback) and `worldcat deploy`.
- Rebuild runbook: `--rebuild ol|fetcher|worldcat`; note that the worldcat data disk is kept, like `ol`'s.
- A new subsection "Loading the WorldCat artifact (once)":
  ```
  rsync -a --info=progress2 /home/shane/wc-data/versions/2025-09-04/ \
      <worldcat-vm>:/srv/wc-data/versions/2025-09-04/
  ssh <worldcat-vm> 'echo 2025-09-04 | sudo tee /srv/wc-data/current-version && sudo touch /var/lib/the-greatest/force-deploy && sudo systemctl start the-greatest-deploy.service'
  curl -fsS https://worldcat-api.thegreatestbooks.org/version -H "CF-Access-Client-Id: ..." -H "CF-Access-Client-Secret: ..."
  ```
  with the note that there is no refresh timer and never will be: the dump is frozen.

- [ ] **Step 2: Declare the Rails setting**

`.env.example`, after the page fetcher block:
```
# WorldCat lookup service (data-sources/, docs/features/worldcat-data-service.md).
# Same posture and the same home server as the two services above.
WORLDCAT_SERVICE_URL=http://127.0.0.1:8082
```
`deployment/ENV.md`, under "Home server data services":
```
#### WORLDCAT_SERVICE_URL
- **Description**: WorldCat lookup service base URL
- **Required**: Yes, for the WorldCat genre backfill
- **Value**: `https://worldcat-api.thegreatestbooks.org`
- **Used By**: web, worker
```
and change the Cloudflare Access description from "both clients" to "all three clients".

- [ ] **Step 3: Add the owner steps to the launch todo**

In `docs/launch-todo.md`, add a "WorldCat" section listing, in order: (1) run the build on the dev machine with `--catalogue-isbns` from `bin/rails worldcat:export_isbns`; (2) `provision` creates VM 130 (`provision` then `provision --enable-tunnels` after the tunnel token is in SOPS); (3) create the `home-worldcat` tunnel, the `worldcat-api.thegreatestbooks.org` hostname with ingress `http://worldcat:8082`, and the Access application reusing the `prod-rails` service token with `bin/cfzerotrust apply` in the cloudflare repo; (4) rsync the artifact and write `current-version`; (5) add `WORLDCAT_SERVICE_URL` to production SOPS and deploy; (6) `bin/rails worldcat:vocabulary`, `worldcat:map`, `worldcat:report`, review and edit `config/worldcat/genre_map.yml`, commit; (7) `worldcat:apply_aliases` in production; (8) `worldcat:backfill[all]` in production; (9) re-run `worldcat:report` and commit the data-quality page. Mark steps 2, 3 and 5 as "Shane runs with `!`" (DNS and production changes).

- [ ] **Step 4: Commit**

Stage the four docs; commit as `Docs: worldcat VM runbook, env declaration, launch steps`.

---
### Task 14: The Rails client

**Files:**
- Create: `web-app/app/lib/books/world_cat/configuration.rb`, `exceptions.rb`, `base_client.rb`, `client.rb`, `record.rb`
- Test: `web-app/test/lib/books/world_cat/configuration_test.rb`, `base_client_test.rb`, `client_test.rb`, `record_test.rb`

**Interfaces:**
- Produces: `Books::WorldCat::Configuration.new(base_url: nil, timeout: nil, open_timeout: nil, batch_timeout: nil, logger: nil, access: nil)` reading `WORLDCAT_SERVICE_URL` (default `http://127.0.0.1:8082`), timeouts 5 / 3 / 20 s.
- Produces: `Books::WorldCat::Exceptions::{Error, ConfigurationError, NetworkError, TimeoutError, HttpError, ClientError, ServerError, NotFoundError, ParseError, CircuitOpenError}` with the same constructors as the Open Library ones.
- Produces: `Books::WorldCat::BaseClient.new(config = nil, breaker: nil)` with `get(path, params = {}, timeout: nil)` and `post(path, body, timeout: nil)` returning `{success:, data:, errors:, metadata:}`; breaker key `"books:world_cat"`, threshold 5, cooldown 60; the breaker is `Books::OpenLibrary::CircuitBreaker` (reused as is, it is source-agnostic).
- Produces: `Books::WorldCat::Client.new(config: nil, breaker: nil, base_client: nil)` with `record_by_isbn(isbn) -> Array<Record>`, `record_by_oclc(number) -> Record | nil`, `lookup(isbn13s) -> Hash{String => Array<Record>}` (chunks at `MAX_BATCH = 500`, keys are the strings given), `version -> Hash`.
- Produces: `Books::WorldCat::Record = Data.define(:oclc, :title, :subtitle, :creator, :contributors, :year, :publisher, :publication_place, :cataloging_language, :specific_format, :edition_statement, :genre, :subjects, :isbn13s, :merged_oclc, :other_format_oclc, :total_editions, :summary, :holding_count, :holdings_editions, :redirected_from)` with `Record.from_hash(hash)`.

- [ ] **Step 1: Write the failing tests**

`test/lib/books/world_cat/record_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class RecordTest < ActiveSupport::TestCase
      test "from_hash reads every field and flattens holdings" do
        record = Record.from_hash(
          "oclc" => 1055766559, "title" => "Atomic habits", "subtitle" => nil, "creator" => "James Clear",
          "contributors" => ["James Clear"], "year" => 2018, "publisher" => "Avery", "publication_place" => "New York",
          "cataloging_language" => "eng", "specific_format" => "PrintBook", "edition_statement" => nil,
          "genre" => "Nonfiction", "subjects" => ["Habit"], "isbn13s" => ["9780735211292"],
          "merged_oclc" => [1], "other_format_oclc" => [2], "total_editions" => 18, "summary" => nil,
          "holdings" => {"total_holding_count" => 3097, "total_editions" => 22}, "redirected_from" => nil
        )
        assert_equal [1055766559, "Nonfiction", ["Habit"], 3097, 22], [record.oclc, record.genre, record.subjects, record.holding_count, record.holdings_editions]
        assert_nil record.redirected_from
      end

      test "from_hash tolerates missing lists and absent holdings" do
        record = Record.from_hash("oclc" => 5)
        assert_equal [[], [], [], [], []], [record.contributors, record.subjects, record.isbn13s, record.merged_oclc, record.other_format_oclc]
        assert_nil record.holding_count
      end
    end
  end
end
```

`test/lib/books/world_cat/configuration_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class ConfigurationTest < ActiveSupport::TestCase
      test "reads WORLDCAT_SERVICE_URL and applies the lookup timeouts" do
        config = Configuration.new(base_url: "http://wc.test:8082")
        assert_equal ["http://wc.test:8082", 5, 3, 20], [config.base_url, config.timeout, config.open_timeout, config.batch_timeout]
      end

      test "defaults to the local port when the variable is unset" do
        saved = ENV.delete("WORLDCAT_SERVICE_URL")
        assert_equal "http://127.0.0.1:8082", Configuration.new.base_url
      ensure
        ENV["WORLDCAT_SERVICE_URL"] = saved if saved
      end

      test "rejects a blank or non-http url naming the variable" do
        error = assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "ftp://x") }
        assert_match(/WORLDCAT_SERVICE_URL/, error.message)
        assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "") }
      end

      test "a partial Access credential pair is a configuration error" do
        access = CloudflareAccess::Credentials.new(client_id: "id", client_secret: nil)
        assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "http://wc.test", access: access) }
      end
    end
  end
end
```
(If `CloudflareAccess::Credentials.new` takes different keyword names, read `app/lib/cloudflare_access/credentials.rb` and use its constructor; the assertion is on `partial?`.)

`test/lib/books/world_cat/base_client_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class BaseClientTest < ActiveSupport::TestCase
      BASE_URL = "http://wc.test:8082"

      def setup
        @config = Configuration.new(base_url: BASE_URL, logger: nil)
        @breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:world_cat", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new)
        @client = BaseClient.new(@config, breaker: @breaker)
      end

      test "a 200 returns parsed data and metadata" do
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: {dump_date: "2025-09-04"}.to_json)
        result = @client.get("/version")
        assert_equal({"dump_date" => "2025-09-04"}, result[:data])
        assert_equal 200, result[:metadata][:status_code]
      end

      test "sends User-Agent, Accept and the Access headers" do
        access = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: "sec")
        client = BaseClient.new(Configuration.new(base_url: BASE_URL, logger: nil, access: access), breaker: @breaker)
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: "{}")
        client.get("/version")
        assert_requested :get, "#{BASE_URL}/version", headers: {"Accept" => "application/json", "CF-Access-Client-Id" => "cid", "CF-Access-Client-Secret" => "sec"}
      end

      test "404, 422 and 500 map to NotFoundError, ClientError and ServerError" do
        {404 => Exceptions::NotFoundError, 422 => Exceptions::ClientError, 500 => Exceptions::ServerError}.each do |status, klass|
          stub_request(:get, "#{BASE_URL}/x#{status}").to_return(status: status, body: "{}")
          assert_raises(klass) { @client.get("/x#{status}") }
        end
      end

      test "five 404s leave the breaker closed; five 500s open it" do
        stub_request(:get, "#{BASE_URL}/missing").to_return(status: 404, body: "{}")
        5.times { assert_raises(Exceptions::NotFoundError) { @client.get("/missing") } }
        assert_not @breaker.open?
        stub_request(:get, "#{BASE_URL}/broken").to_return(status: 500, body: "{}")
        5.times { assert_raises(Exceptions::ServerError) { @client.get("/broken") } }
        assert @breaker.open?
        assert_raises(Exceptions::CircuitOpenError) { @client.get("/version") }
      end

      test "timeouts, connection failures and malformed JSON raise typed errors" do
        stub_request(:get, "#{BASE_URL}/slow").to_timeout
        assert_raises(Exceptions::TimeoutError) { @client.get("/slow") }
        stub_request(:get, "#{BASE_URL}/down").to_raise(Faraday::ConnectionFailed.new("down"))
        assert_raises(Exceptions::NetworkError) { @client.get("/down") }
        stub_request(:get, "#{BASE_URL}/junk").to_return(status: 200, body: "not json")
        assert_raises(Exceptions::ParseError) { @client.get("/junk") }
      end

      test "post sends JSON with its own timeout" do
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: ["1"]}.to_json, headers: {"Content-Type" => "application/json"}).to_return(status: 200, body: {results: {}}.to_json)
        assert_equal({"results" => {}}, @client.post("/lookup", {isbn13s: ["1"]}, timeout: 20)[:data])
      end

      test "never writes the Access secret or the session cookie to the request log" do
        io = StringIO.new
        access = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: "sec-ret")
        client = BaseClient.new(Configuration.new(base_url: BASE_URL, logger: Logger.new(io), access: access), breaker: @breaker)
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: "{}", headers: {"Set-Cookie" => "CF_Authorization=abc.def; Path=/"})
        client.get("/version")
        assert_no_match(/sec-ret/, io.string)
        assert_no_match(/abc\.def/, io.string)
      end
    end
  end
end
```

`test/lib/books/world_cat/client_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class ClientTest < ActiveSupport::TestCase
      BASE_URL = "http://wc.test:8082"

      def setup
        @breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:world_cat:client", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new)
        @client = Client.new(config: Configuration.new(base_url: BASE_URL, logger: nil), breaker: @breaker)
      end

      def record_hash(oclc, genre: "Fiction")
        {"oclc" => oclc, "title" => "T", "genre" => genre, "subjects" => ["S"], "isbn13s" => ["9780735211292"], "holdings" => nil}
      end

      test "#record_by_isbn returns records for a hit and an empty array for a miss" do
        stub_request(:get, "#{BASE_URL}/isbns/9780735211292").to_return(status: 200, body: {isbn13: "9780735211292", records: [record_hash(1)]}.to_json)
        stub_request(:get, "#{BASE_URL}/isbns/9783161484100").to_return(status: 200, body: {isbn13: "9783161484100", records: []}.to_json)
        assert_equal [1], @client.record_by_isbn("9780735211292").map(&:oclc)
        assert_equal [], @client.record_by_isbn("9783161484100")
      end

      test "#record_by_oclc returns nil on 404 and the record otherwise" do
        stub_request(:get, "#{BASE_URL}/oclc/5").to_return(status: 404, body: {detail: "unknown"}.to_json)
        stub_request(:get, "#{BASE_URL}/oclc/1").to_return(status: 200, body: record_hash(1).merge("redirected_from" => 9).to_json)
        assert_nil @client.record_by_oclc(5)
        assert_equal 9, @client.record_by_oclc(1).redirected_from
      end

      test "#lookup chunks at 500, keys every request as given, and uses the batch timeout" do
        isbns = Array.new(501) { |i| "978#{i.to_s.rjust(10, "0")}" }
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: isbns.first(500)}.to_json)
          .to_return(status: 200, body: {results: isbns.first(500).to_h { |i| [i, [record_hash(1)]] }}.to_json)
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: isbns.last(1)}.to_json)
          .to_return(status: 200, body: {results: {isbns.last => []}}.to_json)

        result = @client.lookup(isbns)

        assert_equal 501, result.size
        assert_equal [1], result[isbns.first].map(&:oclc)
        assert_equal [], result[isbns.last]
        assert_requested :post, "#{BASE_URL}/lookup", times: 2
      end

      test "#lookup with no ISBNs makes no request" do
        assert_equal({}, @client.lookup([]))
        assert_not_requested :post, "#{BASE_URL}/lookup"
      end

      test "#version returns the symbolised version hash" do
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: {dump_date: "2025-09-04", gates_passed: true}.to_json)
        assert_equal "2025-09-04", @client.version[:dump_date]
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/books/world_cat`
Expected: FAIL with `NameError: uninitialized constant Books::WorldCat`

- [ ] **Step 3: Implement the client**

`app/lib/books/world_cat/exceptions.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    module Exceptions
      class Error < StandardError; end

      class ConfigurationError < Error; end

      class NetworkError < Error
        attr_reader :original_error

        def initialize(message, original_error = nil)
          super(message)
          @original_error = original_error
        end
      end

      class TimeoutError < NetworkError; end

      class HttpError < Error
        attr_reader :status_code, :response_body

        def initialize(message, status_code, response_body = nil)
          super(message)
          @status_code = status_code
          @response_body = response_body
        end
      end

      class ClientError < HttpError; end

      class ServerError < HttpError; end

      class NotFoundError < ClientError; end

      class ParseError < Error
        attr_reader :response_body

        def initialize(message, response_body = nil)
          super(message)
          @response_body = response_body
        end
      end

      class CircuitOpenError < Error; end
    end
  end
end
```

`app/lib/books/world_cat/configuration.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    class Configuration
      DEFAULT_URL = "http://127.0.0.1:8082"
      DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
      DEFAULT_TIMEOUT = 5
      DEFAULT_OPEN_TIMEOUT = 3
      DEFAULT_BATCH_TIMEOUT = 20

      attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :batch_timeout, :logger, :access

      def initialize(base_url: nil, timeout: nil, open_timeout: nil, batch_timeout: nil, user_agent: nil, logger: nil, access: nil)
        @base_url = base_url.nil? ? ENV.fetch("WORLDCAT_SERVICE_URL", DEFAULT_URL) : base_url
        @timeout = timeout || DEFAULT_TIMEOUT
        @open_timeout = open_timeout || DEFAULT_OPEN_TIMEOUT
        @batch_timeout = batch_timeout || DEFAULT_BATCH_TIMEOUT
        @user_agent = user_agent || DEFAULT_USER_AGENT
        @logger = logger.nil? ? Rails.logger : logger
        @access = access.nil? ? CloudflareAccess::Credentials.from_env : access
        validate_configuration!
      end

      private

      def validate_configuration!
        if access.partial?
          raise Exceptions::ConfigurationError, "CLOUDFLARE_ACCESS_CLIENT_ID and CLOUDFLARE_ACCESS_CLIENT_SECRET must both be set, or neither"
        end
        raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL cannot be blank" if base_url.blank?
        uri = URI.parse(base_url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL must be a valid HTTP/HTTPS URL"
        end
      rescue URI::InvalidURIError
        raise Exceptions::ConfigurationError, "WORLDCAT_SERVICE_URL must be a valid URL"
      end
    end
  end
end
```
When `logger: nil` is passed explicitly the Rails logger is used; the base-client tests pass `logger: nil` and still exercise the filter through a `Logger.new(io)` where they need to read the log.

`app/lib/books/world_cat/base_client.rb`: the Open Library `BaseClient` (`app/lib/books/open_library/base_client.rb`) copied verbatim into `module Books; module WorldCat`, with these edits and no others: the breaker default is `Books::OpenLibrary::CircuitBreaker.new(key: "books:world_cat", failure_threshold: 5, cooldown: 60)`; `perform` calls `breaker.call { ... }` with no `ignore:`; `classify_response` has no 503/busy branch (a 503 is a `ServerError` like any 5xx); `busy?` and `busy_error` are removed. The log filter lines (`CF-Access-Client-Secret` and `CF_Authorization`) are kept exactly; the header comment says why they exist. Exception references resolve to `Books::WorldCat::Exceptions` because the constant lookup is lexical.

`app/lib/books/world_cat/record.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    Record = Data.define(
      :oclc, :title, :subtitle, :creator, :contributors, :year, :publisher, :publication_place,
      :cataloging_language, :specific_format, :edition_statement, :genre, :subjects, :isbn13s,
      :merged_oclc, :other_format_oclc, :total_editions, :summary, :holding_count, :holdings_editions,
      :redirected_from
    ) do
      def self.from_hash(hash)
        holdings = hash["holdings"] || {}
        new(
          oclc: hash["oclc"], title: hash["title"], subtitle: hash["subtitle"], creator: hash["creator"],
          contributors: hash["contributors"] || [], year: hash["year"], publisher: hash["publisher"],
          publication_place: hash["publication_place"], cataloging_language: hash["cataloging_language"],
          specific_format: hash["specific_format"], edition_statement: hash["edition_statement"],
          genre: hash["genre"], subjects: hash["subjects"] || [], isbn13s: hash["isbn13s"] || [],
          merged_oclc: hash["merged_oclc"] || [], other_format_oclc: hash["other_format_oclc"] || [],
          total_editions: hash["total_editions"], summary: hash["summary"],
          holding_count: holdings["total_holding_count"], holdings_editions: holdings["total_editions"],
          redirected_from: hash["redirected_from"]
        )
      end
    end
  end
end
```

`app/lib/books/world_cat/client.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    # Typed client for the WorldCat lookup service (docs/features/worldcat-data-service.md).
    # Exact lookups only; every method returns value objects or nil, never raw JSON.
    class Client
      MAX_BATCH = 500

      attr_reader :config, :base_client

      def initialize(config: nil, breaker: nil, base_client: nil)
        @config = config || Configuration.new
        @base_client = base_client || BaseClient.new(@config, breaker: breaker)
      end

      # @return [Array<Record>] empty when the service has no record for the ISBN
      def record_by_isbn(isbn)
        (get("/isbns/#{isbn}")["records"] || []).map { |hash| Record.from_hash(hash) }
      end

      # @return [Record, nil] nil when the number is unknown (a 404 is an answer, not a failure)
      def record_by_oclc(number)
        Record.from_hash(get("/oclc/#{number}"))
      rescue Exceptions::NotFoundError
        nil
      end

      # @return [Hash{String => Array<Record>}] one key per ISBN given, as given
      def lookup(isbn13s)
        isbn13s.each_slice(MAX_BATCH).each_with_object({}) do |slice, out|
          results = post("/lookup", {isbn13s: slice}, timeout: config.batch_timeout)["results"] || {}
          slice.each { |isbn| out[isbn] = (results[isbn] || []).map { |hash| Record.from_hash(hash) } }
        end
      end

      def version
        get("/version").deep_symbolize_keys
      end

      private

      def get(path)
        base_client.get(path)[:data]
      end

      def post(path, body, timeout:)
        base_client.post(path, body, timeout: timeout)[:data]
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/books/world_cat && bundle exec standardrb app/lib/books/world_cat test/lib/books/world_cat`
Expected: PASS, no offenses. `CI=1 bin/rails zeitwerk:check` must also pass (a new `app/lib` directory).

- [ ] **Step 5: Commit**

Stage `web-app/app/lib/books/world_cat` and `web-app/test/lib/books/world_cat`; commit as `Books: WorldCat client`.

---

### Task 15: ISBN export for the coverage gate

**Files:**
- Create: `web-app/app/lib/books/world_cat/isbn_export.rb`, `web-app/lib/tasks/worldcat.rake` (first task only)
- Test: `web-app/test/lib/books/world_cat/isbn_export_test.rb`, `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Books::WorldCat::IsbnExport.call(io:) -> Integer` writing one ISBN-13 per line, distinct, from `books_work_isbn13` identifiers on books that are not E2E leftovers (same title filter as `Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE`).
- Produces: rake `worldcat:export_isbns[path]` (default `tmp/our_isbn13s.txt`).

- [ ] **Step 1: Write the failing tests**

`test/lib/books/world_cat/isbn_export_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class IsbnExportTest < ActiveSupport::TestCase
      test "writes each distinct work ISBN-13 once and returns the count" do
        book = books_books(:crime_and_punishment)
        ::Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780140449136")
        ::Identifier.create!(identifiable: books_books(:got), identifier_type: :books_work_isbn13, value: "9780140449136")
        io = StringIO.new
        count = IsbnExport.call(io: io)
        lines = io.string.lines.map(&:strip)
        assert_equal lines.uniq.sort, lines.sort
        assert_includes lines, "9780140447934" # the war_and_peace fixture
        assert_includes lines, "9780140449136"
        assert_equal lines.size, count
      end

      test "skips E2E leftover books" do
        leftover = ::Books::Book.create!(title: "E2E Smoke Book 1700000000000")
        ::Identifier.create!(identifiable: leftover, identifier_type: :books_work_isbn13, value: "9780306406157")
        io = StringIO.new
        IsbnExport.call(io: io)
        assert_not_includes io.string, "9780306406157"
      end
    end
  end
end
```

`test/lib/tasks/worldcat_rake_test.rb` (grown in later tasks):
```ruby
require "test_helper"
require "rake"

class WorldcatRakeTest < ActiveSupport::TestCase
  TASKS = %w[worldcat:export_isbns].freeze

  setup do
    unless Rake::Task.task_defined?("worldcat:export_isbns")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/worldcat.rake").to_s }
    end
    TASKS.each { |name| Rake::Task[name].reenable }
  end

  test "export_isbns writes the file and reports the count" do
    path = Rails.root.join("tmp", "worldcat_rake_test_isbns.txt").to_s
    Books::WorldCat::IsbnExport.expects(:call).with { |args| args[:io].respond_to?(:puts) }.returns(3)
    assert_output(/wrote 3 ISBNs to #{Regexp.escape(path)}/) { Rake::Task["worldcat:export_isbns"].invoke(path) }
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/books/world_cat/isbn_export_test.rb test/lib/tasks/worldcat_rake_test.rb`
Expected: FAIL (`NameError` / rake file missing)

- [ ] **Step 3: Implement**

`app/lib/books/world_cat/isbn_export.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    # Our ISBN-13s, one per line, for the build's catalogue_coverage gate
    # (data-sources: `--catalogue-isbns`). Mirrors EvalExport's E2E-leftover filter.
    class IsbnExport
      def self.call(io:)
        new(io).call
      end

      def initialize(io)
        @io = io
      end

      def call
        count = 0
        scope.distinct.pluck(:value).each do |isbn|
          @io.puts(isbn)
          count += 1
        end
        count
      end

      private

      def scope
        ::Identifier
          .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
          .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
          .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
      end
    end
  end
end
```

`lib/tasks/worldcat.rake`:
```ruby
# frozen_string_literal: true

namespace :worldcat do
  desc "Write our ISBN-13s one per line for the WorldCat build's coverage gate: worldcat:export_isbns[<path>]"
  task :export_isbns, [:path] => :environment do |_task, args|
    path = args[:path] || Rails.root.join("tmp", "our_isbn13s.txt").to_s
    count = File.open(path, "w") { |file| Books::WorldCat::IsbnExport.call(io: file) }
    puts "wrote #{count} ISBNs to #{path}"
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/books/world_cat/isbn_export_test.rb test/lib/tasks/worldcat_rake_test.rb && bundle exec standardrb`
Expected: PASS

- [ ] **Step 5: Commit**

Stage the four files; commit as `Books: WorldCat ISBN export for the coverage gate`.

---

### Task 16: Vocabulary snapshot

**Files:**
- Create: `web-app/app/lib/services/books/world_cat/vocabulary_snapshot.rb`
- Modify: `web-app/lib/tasks/worldcat.rake` (add `worldcat:vocabulary`)
- Test: `web-app/test/lib/services/books/world_cat/vocabulary_snapshot_test.rb`, `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Services::Books::WorldCat::VocabularySnapshot.call(client:, out_dir:, head_share: 0.98, batch_size: 500) -> Result` with `data: {books_seen:, books_matched:, terms:, head:, tail:}` and two files: `<out_dir>/genre_terms.csv` (`term,uses,books`, ordered by uses desc, the head up to `head_share` of cumulative uses) and `<out_dir>/genre_terms_tail.csv` (the rest, same columns).
- Consumes: `Books::WorldCat::Client#lookup`.

A "use" is one matched record carrying the term; "books" is the number of distinct books with at least one matched record carrying it. Terms are compared exactly (case and punctuation kept): folding is the mapping pass's job.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/world_cat/vocabulary_snapshot_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class VocabularySnapshotTest < ActiveSupport::TestCase
        class FakeClient
          def initialize(map) = @map = map
          def lookup(isbns) = isbns.to_h { |i| [i, @map.fetch(i, [])] }
        end

        def record(oclc, genre)
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre)
        end

        setup do
          @dir = Dir.mktmpdir
          ::Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_isbn13, value: "9780140449136")
          @client = FakeClient.new(
            "9780140447934" => [record(1, "Fiction"), record(2, "Fiction"), record(3, "Romans")],
            "9780140449136" => [record(4, "Fiction"), record(5, nil)]
          )
        end

        teardown { FileUtils.remove_entry(@dir) }

        test "counts uses and books per term and splits head from tail at the share" do
          result = VocabularySnapshot.call(client: @client, out_dir: @dir, head_share: 0.80)

          assert result.success?
          assert_equal 2, result.data[:books_matched]
          assert_equal({"Fiction" => {uses: 3, books: 2}, "Romans" => {uses: 1, books: 1}}, result.data[:terms])
          assert_equal ["Fiction"], result.data[:head]
          assert_equal ["Romans"], result.data[:tail]
          assert_equal "term,uses,books\nFiction,3,2\n", File.read(File.join(@dir, "genre_terms.csv"))
          assert_equal "term,uses,books\nRomans,1,1\n", File.read(File.join(@dir, "genre_terms_tail.csv"))
        end

        test "a term carried only by a book with one record still counts one book" do
          result = VocabularySnapshot.call(client: @client, out_dir: @dir)
          assert_equal 1, result.data[:terms]["Romans"][:books]
        end

        test "a client failure is a failed result, not an exception" do
          client = mock
          client.stubs(:lookup).raises(::Books::WorldCat::Exceptions::ServerError.new("boom", 500))
          result = VocabularySnapshot.call(client: client, out_dir: @dir)
          assert_not result.success?
          assert_match(/boom/, result.errors.first)
        end
      end
    end
  end
end
```

Add to `test/lib/tasks/worldcat_rake_test.rb` (`TASKS` gains `worldcat:vocabulary`):
```ruby
  test "vocabulary writes the two CSVs under config/worldcat and prints the split" do
    result = Services::Books::WorldCat::VocabularySnapshot::Result.new(success?: true, data: {books_seen: 10, books_matched: 7, terms: {}, head: %w[a b], tail: %w[c]}, errors: [])
    Services::Books::WorldCat::VocabularySnapshot.expects(:call).with { |args| args[:out_dir].to_s.end_with?("config/worldcat") }.returns(result)
    assert_output(/7 of 10 books matched; 2 head terms, 1 tail terms/) { Rake::Task["worldcat:vocabulary"].invoke }
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/world_cat test/lib/tasks/worldcat_rake_test.rb`
Expected: FAIL with `NameError`

- [ ] **Step 3: Implement**

`app/lib/services/books/world_cat/vocabulary_snapshot.rb`:
```ruby
# frozen_string_literal: true

require "csv"

module Services
  module Books
    module WorldCat
      # Counts WorldCat genre terms across the records our ISBN-13s resolve to
      # and writes the head of the distribution for the mapping pass
      # (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Vocabulary mapping").
      class VocabularySnapshot
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        HEAD_FILE = "genre_terms.csv"
        TAIL_FILE = "genre_terms_tail.csv"

        def self.call(client:, out_dir:, head_share: 0.98, batch_size: 500)
          new(client:, out_dir:, head_share:, batch_size:).call
        end

        def initialize(client:, out_dir:, head_share:, batch_size:)
          @client = client
          @out_dir = Pathname(out_dir)
          @head_share = head_share
          @batch_size = batch_size
        end

        def call
          uses = Hash.new(0)
          books_by_term = Hash.new { |h, k| h[k] = Set.new }
          books_seen = 0
          books_matched = 0

          isbns_by_book.each_slice(@batch_size) do |slice|
            results = @client.lookup(slice.flat_map(&:last).uniq)
            slice.each do |book_id, isbns|
              books_seen += 1
              records = isbns.flat_map { |isbn| results.fetch(isbn, []) }.uniq(&:oclc)
              next if records.empty?

              books_matched += 1
              records.each do |record|
                next if record.genre.blank?

                uses[record.genre] += 1
                books_by_term[record.genre] << book_id
              end
            end
          end

          terms = uses.sort_by { |term, n| [-n, term] }.to_h { |term, n| [term, {uses: n, books: books_by_term[term].size}] }
          head, tail = split(terms)
          write(HEAD_FILE, terms.slice(*head))
          write(TAIL_FILE, terms.slice(*tail))
          Result.new(success?: true, data: {books_seen:, books_matched:, terms:, head:, tail:}, errors: [])
        rescue ::Books::WorldCat::Exceptions::Error => e
          Result.new(success?: false, data: nil, errors: ["WorldCat lookup failed: #{e.message}"])
        end

        private

        # [[book_id, [isbn13, ...]], ...] in id order, E2E leftovers excluded.
        def isbns_by_book
          ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
            .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
            .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
            .order(:identifiable_id)
            .pluck(:identifiable_id, :value)
            .group_by(&:first)
            .map { |book_id, pairs| [book_id, pairs.map(&:last).uniq] }
        end

        def split(terms)
          total = terms.values.sum { |v| v[:uses] }
          cumulative = 0
          head = []
          terms.each do |term, v|
            break if total.positive? && cumulative >= @head_share * total

            head << term
            cumulative += v[:uses]
          end
          [head, terms.keys - head]
        end

        def write(name, terms)
          @out_dir.mkpath
          CSV.open(@out_dir.join(name), "w") do |csv|
            csv << %w[term uses books]
            terms.each { |term, v| csv << [term, v[:uses], v[:books]] }
          end
        end
      end
    end
  end
end
```

Add to `lib/tasks/worldcat.rake`:
```ruby
  desc "Count WorldCat genre terms across our books and write config/worldcat/genre_terms.csv (+ _tail.csv)"
  task vocabulary: :environment do
    result = Services::Books::WorldCat::VocabularySnapshot.call(client: Books::WorldCat::Client.new, out_dir: Rails.root.join("config", "worldcat"))
    abort result.errors.join("; ") unless result.success?
    d = result.data
    puts "#{d[:books_matched]} of #{d[:books_seen]} books matched; #{d[:head].size} head terms, #{d[:tail].size} tail terms -> config/worldcat/"
  end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/services/books/world_cat test/lib/tasks/worldcat_rake_test.rb && bundle exec standardrb`
Expected: PASS

- [ ] **Step 5: Commit**

Stage the service, its test, the rake file and rake test; commit as `Books: WorldCat genre vocabulary snapshot`.

---
### Task 17: The mapping pass (AI task + runner)

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/world_cat_genre_mapping_task.rb`, `web-app/app/lib/services/books/world_cat/map_vocabulary.rb`
- Modify: `web-app/lib/tasks/worldcat.rake` (add `worldcat:map`)
- Test: `web-app/test/lib/services/ai/tasks/books/world_cat_genre_mapping_task_test.rb`, `web-app/test/lib/services/books/world_cat/map_vocabulary_test.rb`, `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Services::Ai::Tasks::Books::WorldCatGenreMappingTask.new(terms:, genres:, parent: nil, provider: nil, model: nil)` where `terms` is `[[term, uses, books], ...]` (at most 100) and `genres` the genre category names; `call` returns `Services::Ai::Result` with `data: {verdicts: [{term:, verdict:, genre:, subject:, language:, reason:}]}`; `verdict ∈ %w[genre subject drop]`; a `genre` verdict names one of `genres` exactly; `reason ∈ %w[format language_of_material not_a_genre too_specific]` for drops.
- Produces: `Services::Books::WorldCat::MapVocabulary.call(terms_path:, out_path:, genres:, task_class: WorldCatGenreMappingTask, batch_size: 100) -> Result` with `data: {mapped:, skipped_existing:, batches:}`; writes `out_path` (YAML, schema below); resumable: terms already in an existing `out_path` are not sent again.

The YAML written (`config/worldcat/genre_map.yml`):
```yaml
# WorldCat genre terms -> our curated genres. Generated by `bin/rails worldcat:map`
# on <date>, then edited by hand. The pass never reruns; edit this file.
version: 1
genres: ["Fiction", "Nonfiction", ...]   # the genre names the pass was shown
terms:
  "Fiction": {verdict: genre, genre: "Fiction", language: en, uses: 176078, books: 90000}
  "Romans": {verdict: genre, genre: "Fiction", language: fr, uses: 85115, books: 40000}
  "History": {verdict: subject, subject: "History", language: en, uses: 62097, books: 30000}
  "Large type books": {verdict: drop, reason: format, language: en, uses: 5495, books: 4000}
```

- [ ] **Step 1: Write the failing tests**

`test/lib/services/ai/tasks/books/world_cat_genre_mapping_task_test.rb`:
```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class WorldCatGenreMappingTaskTest < ActiveSupport::TestCase
          setup do
            @terms = [["Romans", 85115, 40000], ["Large type books", 5495, 4000], ["Bildungsromans", 3281, 2000]]
            @genres = ["Fiction", "Coming of age", "Nonfiction"]
            @task = WorldCatGenreMappingTask.new(terms: @terms, genres: @genres)
          end

          test "runs on the standard role with json mode and needs no parent" do
            assert_equal :standard, @task.send(:task_role)
            assert_equal :openai, @task.send(:task_provider)
            assert_equal({type: "json_object"}, @task.send(:response_format))
            assert_equal WorldCatGenreMappingTask::ResponseSchema, @task.send(:response_schema)
          end

          test "the prompt lists every term with its counts and every genre" do
            prompt = @task.send(:user_prompt)
            assert_match(/Romans \(85115 uses on 40000 books\)/, prompt)
            assert_match(/Coming of age/, prompt)
            assert_match(/Large type books/, prompt)
          end

          test "the schema has verdicts with term, verdict, genre, subject, language and reason" do
            schema = WorldCatGenreMappingTask::ResponseSchema.to_json_schema
            assert_equal ["verdicts"], schema[:properties].keys.map(&:to_s)
            item = WorldCatGenreMappingTask::Verdict.to_json_schema
            assert_equal %w[term verdict genre subject language reason], item[:properties].keys.map(&:to_s)
          end

          test "keeps well-formed verdicts and rejects a genre not in the list" do
            response = {parsed: {verdicts: [
              {term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil},
              {term: "Large type books", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"},
              {term: "Bildungsromans", verdict: "genre", genre: "Coming of age", subject: nil, language: "en", reason: nil}
            ]}}
            result = @task.send(:process_and_persist, response)
            assert result.success?
            assert_equal %w[Romans Large\ type\ books Bildungsromans], result.data[:verdicts].map { |v| v[:term] }
            assert_equal "Coming of age", result.data[:verdicts].last[:genre]

            bad = {parsed: {verdicts: [{term: "Romans", verdict: "genre", genre: "Novels", subject: nil, language: "fr", reason: nil}]}}
            assert_not @task.send(:process_and_persist, bad).success?
          end

          test "a verdict for a term that was not asked about is dropped, and a missing term fails" do
            extra = {parsed: {verdicts: [
              {term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil},
              {term: "Large type books", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"},
              {term: "Bildungsromans", verdict: "subject", genre: nil, subject: "Coming of age", language: "en", reason: nil},
              {term: "Not asked", verdict: "drop", genre: nil, subject: nil, language: "en", reason: "format"}
            ]}}
            result = @task.send(:process_and_persist, extra)
            assert result.success?
            assert_equal 3, result.data[:verdicts].size

            missing = {parsed: {verdicts: [{term: "Romans", verdict: "genre", genre: "Fiction", subject: nil, language: "fr", reason: nil}]}}
            result = @task.send(:process_and_persist, missing)
            assert_not result.success?
            assert_match(/Large type books/, result.error)
          end
        end
      end
    end
  end
end
```

`test/lib/services/books/world_cat/map_vocabulary_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class MapVocabularyTest < ActiveSupport::TestCase
        class FakeTask
          cattr_accessor :calls, default: []

          def initialize(terms:, genres:, parent: nil)
            @terms = terms
            self.class.calls << terms.map(&:first)
          end

          def call
            verdicts = @terms.map do |term, _uses, _books|
              {term: term, verdict: (term == "Large type books") ? "drop" : "genre", genre: (term == "Large type books") ? nil : "Fiction",
               subject: nil, language: "en", reason: (term == "Large type books") ? "format" : nil}
            end
            ::Services::Ai::Result.new(success: true, data: {verdicts: verdicts})
          end
        end

        setup do
          FakeTask.calls = []
          @dir = Dir.mktmpdir
          @terms_path = File.join(@dir, "genre_terms.csv")
          File.write(@terms_path, "term,uses,books\nFiction,10,8\nRomans,5,4\nLarge type books,2,2\n")
          @out = File.join(@dir, "genre_map.yml")
        end

        teardown { FileUtils.remove_entry(@dir) }

        test "writes a verdict per term with counts, batched" do
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: FakeTask, batch_size: 2)

          assert result.success?
          assert_equal({mapped: 3, skipped_existing: 0, batches: 2}, result.data)
          assert_equal [["Fiction", "Romans"], ["Large type books"]], FakeTask.calls
          yaml = YAML.safe_load_file(@out)
          assert_equal 1, yaml["version"]
          assert_equal ["Fiction"], yaml["genres"]
          assert_equal({"verdict" => "genre", "genre" => "Fiction", "language" => "en", "uses" => 5, "books" => 4}, yaml["terms"]["Romans"])
          assert_equal({"verdict" => "drop", "reason" => "format", "language" => "en", "uses" => 2, "books" => 2}, yaml["terms"]["Large type books"])
        end

        test "an existing file is extended, not re-asked" do
          File.write(@out, {"version" => 1, "genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction", "uses" => 10, "books" => 8}}}.to_yaml)
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: FakeTask)
          assert_equal({mapped: 2, skipped_existing: 1, batches: 1}, result.data)
          assert_equal [["Romans", "Large type books"]], FakeTask.calls
          assert_equal 3, YAML.safe_load_file(@out)["terms"].size
        end

        test "a failed batch stops and reports, keeping what was written" do
          failing = Class.new do
            define_method(:initialize) { |**| }
            define_method(:call) { ::Services::Ai::Result.new(success: false, error: "quota") }
          end
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: failing)
          assert_not result.success?
          assert_match(/quota/, result.errors.first)
        end
      end
    end
  end
end
```

Add to the rake test (`TASKS` gains `worldcat:map`):
```ruby
  test "map runs the vocabulary mapping against the current genre list" do
    result = Services::Books::WorldCat::MapVocabulary::Result.new(success?: true, data: {mapped: 5, skipped_existing: 1, batches: 1}, errors: [])
    Services::Books::WorldCat::MapVocabulary.expects(:call).with { |args| args[:genres].include?("Fiction") && args[:out_path].to_s.end_with?("genre_map.yml") }.returns(result)
    assert_output(/mapped 5 terms \(1 already mapped\) in 1 batch/) { Rake::Task["worldcat:map"].invoke }
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/world_cat_genre_mapping_task_test.rb test/lib/services/books/world_cat/map_vocabulary_test.rb test/lib/tasks/worldcat_rake_test.rb`
Expected: FAIL with `NameError`

- [ ] **Step 3: Implement the task**

`app/lib/services/ai/tasks/books/world_cat_genre_mapping_task.rb`:
```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Maps WorldCat genre terms onto our curated genre list, once
        # (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Vocabulary mapping").
        # Parentless: the result is a data file, not a record.
        class WorldCatGenreMappingTask < BaseTask
          VERDICTS = %w[genre subject drop].freeze
          REASONS = %w[format language_of_material not_a_genre too_specific].freeze

          attr_reader :terms, :genres

          def initialize(terms:, genres:, parent: nil, provider: nil, model: nil)
            @terms = terms
            @genres = genres
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You classify library catalogue genre/form terms for a book website.
              The terms come from WorldCat records and may be in any language, with
              variant spellings, trailing punctuation, or BISAC-style headings.

              For each term give exactly one verdict:
              - "genre": the term describes what kind of book it is and fits one of the
                site's genres. Set "genre" to that genre's name, copied exactly from the list.
                Fold variants and translations onto the same genre ("Biographies",
                "Biografías" and "Biography" all map to the genre named Biography).
              - "subject": the term says what the book is ABOUT rather than what it is,
                and no genre fits. Set "subject" to a short canonical English phrase.
              - "drop": the term describes the physical item or its language ("Large type
                books", "Electronic books", "Spanish language materials", "Audiobooks",
                "Translations"), is not a genre or subject at all, or is too specific to
                be useful. Set "reason" to one of: format, language_of_material,
                not_a_genre, too_specific.

              Always set "language" to the ISO 639-1 code of the term's language.
              Never invent a genre: a "genre" verdict must name one from the list.
              Answer with JSON matching the schema, one verdict per term, in order.
            SYSTEM
          end

          def user_prompt
            lines = ["Site genres (use these names exactly):"]
            genres.each { |name| lines << "- #{name}" }
            lines << ""
            lines << "Terms to classify (uses = WorldCat records carrying the term; books = our books):"
            terms.each_with_index do |(term, uses, books), index|
              lines << "#{index + 1}. #{term} (#{uses} uses on #{books} books)"
            end
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def process_and_persist(provider_response)
            asked = terms.map(&:first)
            raw = Array(provider_response[:parsed][:verdicts]).map { |v| normalize(v) }
            verdicts = raw.select { |v| asked.include?(v[:term]) }.uniq { |v| v[:term] }

            missing = asked - verdicts.map { |v| v[:term] }
            return failure("No verdict for: #{missing.join(", ")}") if missing.any?

            bad = verdicts.reject { |v| VERDICTS.include?(v[:verdict]) }
            return failure("Unknown verdict #{bad.first[:verdict].inspect} for #{bad.first[:term].inspect}") if bad.any?

            wrong_genre = verdicts.select { |v| v[:verdict] == "genre" && !genres.include?(v[:genre]) }
            return failure("#{wrong_genre.first[:genre].inspect} is not a site genre (term #{wrong_genre.first[:term].inspect})") if wrong_genre.any?

            no_subject = verdicts.select { |v| v[:verdict] == "subject" && v[:subject].blank? }
            return failure("Subject verdict without a phrase for #{no_subject.first[:term].inspect}") if no_subject.any?

            bad_reason = verdicts.select { |v| v[:verdict] == "drop" && !REASONS.include?(v[:reason]) }
            return failure("Unknown drop reason #{bad_reason.first[:reason].inspect} for #{bad_reason.first[:term].inspect}") if bad_reason.any?

            Services::Ai::Result.new(success: true, data: {verdicts: verdicts}, ai_chat: chat)
          end

          def normalize(verdict)
            hash = verdict.respond_to?(:to_h) ? verdict.to_h : verdict
            hash = JSON.parse(hash.to_json, symbolize_names: true)
            {term: hash[:term].to_s, verdict: hash[:verdict].to_s, genre: hash[:genre].presence,
             subject: hash[:subject].presence, language: hash[:language].presence, reason: hash[:reason].presence}
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Verdict < OpenAI::BaseModel
            required :term, String, doc: "The term exactly as given"
            required :verdict, String, doc: "genre, subject or drop"
            required :genre, String, nil?: true, doc: "For genre: a site genre name, exactly as listed"
            required :subject, String, nil?: true, doc: "For subject: a short canonical English phrase"
            required :language, String, doc: "ISO 639-1 code of the term's language"
            required :reason, String, nil?: true, doc: "For drop: format, language_of_material, not_a_genre or too_specific"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :verdicts, OpenAI::ArrayOf[Verdict], doc: "One per term, in the order given"
          end
        end
      end
    end
  end
end
```

`app/lib/services/books/world_cat/map_vocabulary.rb`:
```ruby
# frozen_string_literal: true

require "csv"

module Services
  module Books
    module WorldCat
      # Runs the mapping task over config/worldcat/genre_terms.csv in batches and
      # writes config/worldcat/genre_map.yml. Resumable: terms already in the file
      # are skipped, so a failed batch costs one rerun, not a restart.
      class MapVocabulary
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        VERSION = 1

        def self.call(terms_path:, out_path:, genres:, task_class: ::Services::Ai::Tasks::Books::WorldCatGenreMappingTask, batch_size: 100)
          new(terms_path:, out_path:, genres:, task_class:, batch_size:).call
        end

        def initialize(terms_path:, out_path:, genres:, task_class:, batch_size:)
          @terms_path = terms_path
          @out_path = Pathname(out_path)
          @genres = genres
          @task_class = task_class
          @batch_size = batch_size
        end

        def call
          existing = load_existing
          counts = read_terms
          todo = counts.keys - existing.keys
          mapped = 0
          batches = 0
          todo.each_slice(@batch_size) do |slice|
            batches += 1
            result = @task_class.new(terms: slice.map { |t| [t, counts[t][:uses], counts[t][:books]] }, genres: @genres, parent: nil).call
            unless result.success?
              write(existing)
              return Result.new(success?: false, data: {mapped:, skipped_existing: counts.size - todo.size, batches:}, errors: ["batch #{batches} failed: #{result.error}"])
            end
            result.data[:verdicts].each do |v|
              existing[v[:term]] = entry(v, counts[v[:term]])
              mapped += 1
            end
            write(existing)
          end
          Result.new(success?: true, data: {mapped:, skipped_existing: counts.size - todo.size, batches:}, errors: [])
        end

        private

        def read_terms
          CSV.read(@terms_path, headers: true).to_h { |row| [row["term"], {uses: row["uses"].to_i, books: row["books"].to_i}] }
        end

        def load_existing
          return {} unless @out_path.exist?

          (YAML.safe_load_file(@out_path)["terms"] || {})
        end

        def entry(verdict, counts)
          base = {"verdict" => verdict[:verdict]}
          base["genre"] = verdict[:genre] if verdict[:verdict] == "genre"
          base["subject"] = verdict[:subject] if verdict[:verdict] == "subject"
          base["reason"] = verdict[:reason] if verdict[:verdict] == "drop"
          base["language"] = verdict[:language] if verdict[:language]
          base.merge("uses" => counts[:uses], "books" => counts[:books])
        end

        def write(terms)
          @out_path.dirname.mkpath
          header = "# WorldCat genre terms -> our curated genres. Generated by `bin/rails worldcat:map`\n" \
                   "# on #{Date.current}, then edited by hand. The pass never reruns; edit this file.\n"
          @out_path.write(header + {"version" => VERSION, "genres" => @genres, "terms" => terms}.to_yaml)
        end
      end
    end
  end
end
```

Add to `lib/tasks/worldcat.rake`:
```ruby
  desc "Run the one-time AI pass mapping config/worldcat/genre_terms.csv onto our genre categories -> config/worldcat/genre_map.yml"
  task map: :environment do
    genres = Books::Category.active.genre.order(:name).pluck(:name)
    result = Services::Books::WorldCat::MapVocabulary.call(
      terms_path: Rails.root.join("config", "worldcat", "genre_terms.csv"),
      out_path: Rails.root.join("config", "worldcat", "genre_map.yml"),
      genres: genres
    )
    abort result.errors.join("; ") unless result.success?
    d = result.data
    puts "mapped #{d[:mapped]} terms (#{d[:skipped_existing]} already mapped) in #{d[:batches]} batch#{"es" unless d[:batches] == 1}; review config/worldcat/genre_map.yml"
  end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/services/ai/tasks/books/world_cat_genre_mapping_task_test.rb test/lib/services/books/world_cat/map_vocabulary_test.rb test/lib/tasks/worldcat_rake_test.rb && bundle exec standardrb`
Expected: PASS

- [ ] **Step 5: Commit**

Stage the two services, their tests, the rake file and rake test; commit as `Books: WorldCat genre mapping pass`.

---

### Task 18: The mapping file, its reports, and alias application

**Files:**
- Create: `web-app/app/lib/books/world_cat/genre_map.rb`, `web-app/app/lib/services/books/world_cat/mapping_report.rb`, `web-app/app/lib/services/books/world_cat/apply_aliases.rb`, `web-app/test/fixtures/files/worldcat_genre_map.yml`
- Modify: `web-app/lib/tasks/worldcat.rake` (add `worldcat:report`, `worldcat:apply_aliases`)
- Test: `web-app/test/lib/books/world_cat/genre_map_test.rb`, `web-app/test/lib/services/books/world_cat/mapping_report_test.rb`, `web-app/test/lib/services/books/world_cat/apply_aliases_test.rb`, `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Books::WorldCat::GenreMap.load(path = DEFAULT_PATH) -> GenreMap`; `#verdict(term) -> Hash | nil` (string keys `verdict`, `genre`, `subject`, `reason`, `language`, `uses`, `books`); `#genre_for(term) -> String | nil`; `#subject_for(term) -> String | nil`; `#terms_by_genre -> Hash{String => Array<String>}`; `#genres -> Array<String>`; `#size`. `DEFAULT_PATH = Rails.root.join("config", "worldcat", "genre_map.yml")`. Loading is uncached: the file changes while the owner edits it.
- Produces: `Services::Books::WorldCat::MappingReport.call(map:, out_path:, top: 300) -> Result` with `data: {top:, unplaced:, counts: {genre:, subject:, drop:}}`; writes the markdown page.
- Produces: `Services::Books::WorldCat::ApplyAliases.call(map:) -> Result` with `data: {categories_updated:, aliases_added:, missing_genres: []}`.

- [ ] **Step 1: Write the fixture file and the failing tests**

`test/fixtures/files/worldcat_genre_map.yml`:
```yaml
version: 1
genres: ["Fiction", "Nonfiction", "Novels"]
terms:
  "Fiction": {verdict: genre, genre: "Fiction", language: en, uses: 100, books: 80}
  "Romans": {verdict: genre, genre: "Fiction", language: fr, uses: 50, books: 40}
  "novels": {verdict: genre, genre: "Novels", language: en, uses: 20, books: 15}
  "History": {verdict: subject, subject: "Politics", language: en, uses: 30, books: 25}
  "Large type books": {verdict: drop, reason: format, language: en, uses: 10, books: 9}
  "Bildungsromans": {verdict: drop, reason: not_a_genre, language: en, uses: 8, books: 7}
```

`test/lib/books/world_cat/genre_map_test.rb`:
```ruby
require "test_helper"

module Books
  module WorldCat
    class GenreMapTest < ActiveSupport::TestCase
      setup { @map = GenreMap.load(file_fixture("worldcat_genre_map.yml")) }

      test "answers genre, subject and drop verdicts by exact term" do
        assert_equal "Fiction", @map.genre_for("Romans")
        assert_nil @map.genre_for("History")
        assert_equal "Politics", @map.subject_for("History")
        assert_nil @map.subject_for("Romans")
        assert_equal "format", @map.verdict("Large type books")["reason"]
        assert_nil @map.verdict("Unknown term")
        assert_nil @map.genre_for("fiction")  # exact match: folding is the pass's job
      end

      test "groups terms by genre and exposes the genre list" do
        assert_equal({"Fiction" => %w[Fiction Romans], "Novels" => ["novels"]}, @map.terms_by_genre)
        assert_equal ["Fiction", "Nonfiction", "Novels"], @map.genres
        assert_equal 6, @map.size
      end

      test "a missing file is an empty map" do
        map = GenreMap.load(Rails.root.join("tmp", "does-not-exist.yml"))
        assert_equal 0, map.size
        assert_nil map.genre_for("Fiction")
      end
    end
  end
end
```

`test/lib/services/books/world_cat/mapping_report_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class MappingReportTest < ActiveSupport::TestCase
        setup do
          @map = ::Books::WorldCat::GenreMap.load(file_fixture("worldcat_genre_map.yml"))
          @out = Rails.root.join("tmp", "worldcat-genre-mapping-test.md")
        end

        teardown { File.delete(@out) if File.exist?(@out) }

        test "writes the top table and the unplaced list ranked by books" do
          result = MappingReport.call(map: @map, out_path: @out, top: 3)
          assert result.success?
          assert_equal({genre: 3, subject: 1, drop: 2}, result.data[:counts])
          assert_equal %w[Fiction Romans History], result.data[:top].map { |row| row[:term] }
          assert_equal %w[History Bildungsromans], result.data[:unplaced].map { |row| row[:term] }
          page = File.read(@out)
          assert_match(/^# WorldCat genre mapping/, page)
          assert_match(/\| Romans \| 50 \| 40 \| genre \| Fiction \|/, page)
          assert_match(/## Terms with no genre/, page)
          assert_no_match(/Large type books.*not_a_genre/, page)
        end
      end
    end
  end
end
```

`test/lib/services/books/world_cat/apply_aliases_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class ApplyAliasesTest < ActiveSupport::TestCase
        setup { @map = ::Books::WorldCat::GenreMap.load(file_fixture("worldcat_genre_map.yml")) }

        test "adds mapped terms as alternative names on the genre, skipping the genre's own name" do
          result = ApplyAliases.call(map: @map)
          assert result.success?
          assert_equal ["Romans"], categories(:books_fiction_genre).reload.alternative_names
          assert_equal ["novels"], categories(:books_novels_genre).reload.alternative_names
          assert_equal({categories_updated: 2, aliases_added: 2, missing_genres: []}, result.data)
        end

        test "is idempotent and reports a genre the map names that does not exist" do
          ApplyAliases.call(map: @map)
          categories(:books_fiction_genre).update!(alternative_names: ["Romans", "Kept"])
          result = ApplyAliases.call(map: @map)
          assert_equal ["Romans", "Kept"], categories(:books_fiction_genre).reload.alternative_names
          assert_equal 0, result.data[:aliases_added]

          map = ::Books::WorldCat::GenreMap.new({"genres" => ["Nope"], "terms" => {"X" => {"verdict" => "genre", "genre" => "Nope"}}})
          result = ApplyAliases.call(map: map)
          assert result.success?
          assert_equal ["Nope"], result.data[:missing_genres]
        end

        test "a name match is case-insensitive and ignores deleted categories" do
          categories(:books_fiction_genre).update!(name: "fiction")
          ApplyAliases.call(map: @map)
          assert_includes categories(:books_fiction_genre).reload.alternative_names, "Romans"
          assert_equal [], categories(:books_deleted_genre).reload.alternative_names
        end
      end
    end
  end
end
```

Add to the rake test (`TASKS` gains `worldcat:report` and `worldcat:apply_aliases`):
```ruby
  test "report writes the data-quality page" do
    result = Services::Books::WorldCat::MappingReport::Result.new(success?: true, data: {top: [], unplaced: [1, 2], counts: {genre: 3, subject: 1, drop: 2}}, errors: [])
    Services::Books::WorldCat::MappingReport.expects(:call).with { |args| args[:out_path].to_s.end_with?("docs/data-quality/worldcat-genre-mapping.md") }.returns(result)
    assert_output(/3 genre, 1 subject, 2 drop; 2 terms with no genre/) { Rake::Task["worldcat:report"].invoke }
  end

  test "apply_aliases reports what it added" do
    result = Services::Books::WorldCat::ApplyAliases::Result.new(success?: true, data: {categories_updated: 2, aliases_added: 5, missing_genres: ["Nope"]}, errors: [])
    Services::Books::WorldCat::ApplyAliases.expects(:call).returns(result)
    assert_output(/added 5 aliases on 2 genres; genres named by the map but missing: Nope/) { Rake::Task["worldcat:apply_aliases"].invoke }
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/books/world_cat/genre_map_test.rb test/lib/services/books/world_cat test/lib/tasks/worldcat_rake_test.rb`
Expected: FAIL with `NameError`

- [ ] **Step 3: Implement**

`app/lib/books/world_cat/genre_map.rb`:
```ruby
# frozen_string_literal: true

module Books
  module WorldCat
    # The reviewed mapping table, config/worldcat/genre_map.yml. Read fresh on
    # every load: the owner edits the file between backfill runs.
    class GenreMap
      DEFAULT_PATH = Rails.root.join("config", "worldcat", "genre_map.yml")

      def self.load(path = DEFAULT_PATH)
        path = Pathname(path)
        new(path.exist? ? YAML.safe_load_file(path) : {})
      end

      def initialize(data)
        @genres = Array(data["genres"])
        @terms = data["terms"] || {}
      end

      attr_reader :genres

      def size = @terms.size

      def verdict(term) = @terms[term]

      def genre_for(term)
        entry = @terms[term]
        entry["genre"] if entry && entry["verdict"] == "genre"
      end

      def subject_for(term)
        entry = @terms[term]
        entry["subject"] if entry && entry["verdict"] == "subject"
      end

      def terms_by_genre
        @terms.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(term, entry), out|
          out[entry["genre"]] << term if entry["verdict"] == "genre"
        end.transform_values(&:sort).sort.to_h
      end

      def each_term(&) = @terms.each(&)
    end
  end
end
```

`app/lib/services/books/world_cat/mapping_report.rb`:
```ruby
# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # Two reports for the owner: the top terms with their verdicts (a sanity check)
      # and the terms the pass could not place on a genre, ranked by how many of our
      # books carry them (the list for deciding whether a new genre is warranted).
      class MappingReport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        UNPLACED_DROP_REASONS = %w[not_a_genre too_specific].freeze

        def self.call(map:, out_path:, top: 300)
          new(map:, out_path:, top:).call
        end

        def initialize(map:, out_path:, top:)
          @map = map
          @out_path = Pathname(out_path)
          @top = top
        end

        def call
          rows = []
          @map.each_term { |term, entry| rows << row(term, entry) }
          rows.sort_by! { |r| [-r[:uses], r[:term]] }
          top = rows.first(@top)
          unplaced = rows.select { |r| r[:verdict] == "subject" || (r[:verdict] == "drop" && UNPLACED_DROP_REASONS.include?(r[:reason])) }
            .sort_by { |r| [-r[:books], r[:term]] }
          counts = %w[genre subject drop].to_h { |v| [v.to_sym, rows.count { |r| r[:verdict] == v }] }
          @out_path.dirname.mkpath
          @out_path.write(render(top, unplaced, counts))
          Result.new(success?: true, data: {top:, unplaced:, counts:}, errors: [])
        end

        private

        def row(term, entry)
          {term:, verdict: entry["verdict"], genre: entry["genre"], subject: entry["subject"], reason: entry["reason"],
           language: entry["language"], uses: entry["uses"].to_i, books: entry["books"].to_i}
        end

        def target(r)
          r[:genre] || r[:subject] || r[:reason]
        end

        def render(top, unplaced, counts)
          lines = ["# WorldCat genre mapping", "",
            "**Generated #{Date.current}** by `bin/rails worldcat:report` from `config/worldcat/genre_map.yml`",
            "(#{@map.size} terms: #{counts[:genre]} genre, #{counts[:subject]} subject, #{counts[:drop]} drop).",
            "Regenerate after editing the map; this page describes one file on one day.", "",
            "## Top #{top.size} terms by uses", "", "| Term | Uses | Books | Verdict | Target |", "|---|---:|---:|---|---|"]
          top.each { |r| lines << "| #{r[:term]} | #{r[:uses]} | #{r[:books]} | #{r[:verdict]} | #{target(r)} |" }
          lines += ["", "## Terms with no genre", "",
            "Subject verdicts and drops for `not_a_genre`/`too_specific`, ranked by how many of our books carry them.",
            "Each is a candidate for a new genre, a merge onto an existing one, or staying as it is.", "",
            "| Term | Books | Uses | Verdict | Target | Language |", "|---|---:|---:|---|---|---|"]
          unplaced.each { |r| lines << "| #{r[:term]} | #{r[:books]} | #{r[:uses]} | #{r[:verdict]} | #{target(r)} | #{r[:language]} |" }
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
```

`app/lib/services/books/world_cat/apply_aliases.rb`:
```ruby
# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # Adds every genre-verdict term as an alternative name on its genre category,
      # the same field Categories::Merger fills, so the mapping is visible in the
      # admin and survives future merges. Idempotent.
      class ApplyAliases
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(map:)
          new(map).call
        end

        def initialize(map)
          @map = map
        end

        def call
          updated = 0
          added = 0
          missing = []
          @map.terms_by_genre.each do |genre_name, terms|
            category = ::Books::Category.active.genre.by_name(genre_name).first
            if category.nil?
              missing << genre_name
              next
            end
            aliases = terms.reject { |t| t.casecmp?(category.name) || category.alternative_names.any? { |a| a.casecmp?(t) } }
            next if aliases.empty?

            category.update!(alternative_names: category.alternative_names + aliases)
            updated += 1
            added += aliases.size
          end
          Result.new(success?: true, data: {categories_updated: updated, aliases_added: added, missing_genres: missing}, errors: [])
        end
      end
    end
  end
end
```

Add to `lib/tasks/worldcat.rake`:
```ruby
  desc "Write docs/data-quality/worldcat-genre-mapping.md from config/worldcat/genre_map.yml"
  task report: :environment do
    result = Services::Books::WorldCat::MappingReport.call(
      map: Books::WorldCat::GenreMap.load,
      out_path: Rails.root.join("..", "docs", "data-quality", "worldcat-genre-mapping.md").expand_path
    )
    abort result.errors.join("; ") unless result.success?
    c = result.data[:counts]
    puts "#{c[:genre]} genre, #{c[:subject]} subject, #{c[:drop]} drop; #{result.data[:unplaced].size} terms with no genre -> docs/data-quality/worldcat-genre-mapping.md"
  end

  desc "Add every mapped WorldCat term as an alternative name on its genre category (idempotent)"
  task apply_aliases: :environment do
    result = Services::Books::WorldCat::ApplyAliases.call(map: Books::WorldCat::GenreMap.load)
    abort result.errors.join("; ") unless result.success?
    d = result.data
    line = "added #{d[:aliases_added]} aliases on #{d[:categories_updated]} genres"
    line += "; genres named by the map but missing: #{d[:missing_genres].join(", ")}" if d[:missing_genres].any?
    puts line
  end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/books/world_cat test/lib/services/books/world_cat test/lib/tasks/worldcat_rake_test.rb && bundle exec standardrb`
Expected: PASS. A `Category` update fires `queue_items_for_reindexing`; with `Sidekiq.testing!(:inline)` that runs `Categories::ItemReindexer` synchronously against the fixture, which is fine.

- [ ] **Step 5: Commit**

Stage the new files, the fixture, the rake file and tests; commit as `Books: WorldCat genre map, reports and alias application`.

---
### Task 19: Applying categories to one book

**Files:**
- Create: `web-app/app/lib/services/books/world_cat/apply_categories.rb`
- Test: `web-app/test/lib/services/books/world_cat/apply_categories_test.rb`

**Interfaces:**
- Produces: `Services::Books::WorldCat::ApplyCategories.call(book:, records:, map:) -> Result` with `data: {records:, genres_linked: [names], subjects_linked: [names], subjects_unresolved: [phrases], already_linked:}`.
- Consumes: `Books::WorldCat::Record` (Task 14), `Books::WorldCat::GenreMap` (Task 18).

Rules (spec, "Backfill"):
- Support for a mapped genre is the number of records whose `genre` term maps to it. A genre is applied when support is at least two, or when the book has exactly one record.
- Subject phrases come from `subject` verdicts on terms in either `genre` or `subjects`; the same support rule applies; a phrase resolves to an existing active subject category by name, then by alternative name; unresolved phrases are returned, never created.
- Links are additive and idempotent (`CategoryItem.find_or_create_by!`); nothing is ever unlinked.
- Nonfiction is never inferred from the absence of a fiction term.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/world_cat/apply_categories_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class ApplyCategoriesTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @map = ::Books::WorldCat::GenreMap.new(
            "genres" => ["Fiction", "Novels"],
            "terms" => {
              "Fiction" => {"verdict" => "genre", "genre" => "Fiction"},
              "Romans" => {"verdict" => "genre", "genre" => "Fiction"},
              "novels" => {"verdict" => "genre", "genre" => "Novels"},
              "Politics and government" => {"verdict" => "subject", "subject" => "Politics"},
              "Napoleonic Wars" => {"verdict" => "subject", "subject" => "Napoleonic Wars"},
              "Large type books" => {"verdict" => "drop", "reason" => "format"}
            }
          )
        end

        def record(oclc, genre: nil, subjects: [])
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre, "subjects" => subjects)
        end

        def names(type)
          @book.reload.categories.where(category_type: type).order(:name).pluck(:name)
        end

        test "links a genre carried by at least two records" do
          records = [record(1, genre: "Fiction"), record(2, genre: "Romans"), record(3, genre: "novels")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert result.success?
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_includes names(:genre), "Fiction"
          assert_equal 3, result.data[:records]
        end

        test "test_single_record_book_gets_its_genre" do
          result = ApplyCategories.call(book: @book, records: [record(1, genre: "Romans")], map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
        end

        test "test_stray_term_on_one_of_many_records_is_ignored" do
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")] + Array.new(28) { |i| record(10 + i, genre: "Large type books") }
          records << record(99, genre: "novels")
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction"], result.data[:genres_linked]
          assert_not_includes result.data[:genres_linked], "Novels"
        end

        test "subjects resolve by name or alternative name and unresolved phrases are reported, not created" do
          categories(:books_politics_subject).update!(alternative_names: ["Politics"])
          categories(:books_politics_subject).update!(name: "Government")
          records = [record(1, subjects: ["Politics and government", "Napoleonic Wars"]), record(2, subjects: ["Politics and government", "Napoleonic Wars"])]
          before = ::Books::Category.count
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Government"], result.data[:subjects_linked]
          assert_equal ["Napoleonic Wars"], result.data[:subjects_unresolved]
          assert_equal before, ::Books::Category.count
        end

        test "a subject verdict on the genre field counts too" do
          records = [record(1, genre: "Politics and government"), record(2, genre: "Politics and government")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Politics"], result.data[:subjects_linked]
        end

        test "is additive and idempotent" do
          @book.category_items.create!(category: categories(:books_nonfiction_genre))
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")]
          ApplyCategories.call(book: @book, records: records, map: @map)
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal ["Fiction", "Nonfiction"], names(:genre).sort & ["Fiction", "Nonfiction"]
          assert_equal 1, result.data[:already_linked]
          assert_equal 1, @book.category_items.where(category: categories(:books_fiction_genre)).count
        end

        test "never infers Nonfiction and never links a deleted category" do
          ::Books::Category.active.genre.by_name("Fiction").update_all(deleted: true)
          records = [record(1, genre: "Fiction"), record(2, genre: "Fiction")]
          result = ApplyCategories.call(book: @book, records: records, map: @map)
          assert_equal [], result.data[:genres_linked]
          assert_not_includes names(:genre), "Nonfiction"
        end

        test "no records is a success that links nothing" do
          result = ApplyCategories.call(book: @book, records: [], map: @map)
          assert result.success?
          assert_equal 0, result.data[:records]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/world_cat/apply_categories_test.rb`
Expected: FAIL with `NameError`

- [ ] **Step 3: Implement**

`app/lib/services/books/world_cat/apply_categories.rb`:
```ruby
# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # One book plus its WorldCat records -> category links, through the reviewed
      # map (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Backfill").
      # Additive and idempotent; nothing is created or unlinked.
      class ApplyCategories
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        MIN_SUPPORT = 2

        def self.call(book:, records:, map:)
          new(book:, records:, map:).call
        end

        def initialize(book:, records:, map:)
          @book = book
          @records = records.uniq(&:oclc)
          @map = map
        end

        def call
          genre_support = Hash.new(0)
          subject_support = Hash.new(0)
          @records.each do |record|
            genre = record.genre.present? && @map.genre_for(record.genre)
            genre_support[genre] += 1 if genre
            phrases = ([record.genre] + record.subjects).compact.filter_map { |term| @map.subject_for(term) }.uniq
            phrases.each { |phrase| subject_support[phrase] += 1 }
          end

          genres_linked = []
          subjects_linked = []
          unresolved = []
          already = 0

          supported(genre_support).each do |name|
            category = ::Books::Category.active.genre.by_name(name).first
            next unless category

            created = link(category)
            created ? genres_linked << category.name : already += 1
          end
          supported(subject_support).each do |phrase|
            category = ::Books::Category.active.subject.by_name(phrase).first ||
              ::Books::Category.active.subject.by_alternative_name(phrase).first
            if category.nil?
              unresolved << phrase
              next
            end
            created = link(category)
            created ? subjects_linked << category.name : already += 1
          end

          Result.new(success?: true, errors: [], data: {
            records: @records.size, genres_linked: genres_linked.sort, subjects_linked: subjects_linked.sort,
            subjects_unresolved: unresolved.sort, already_linked: already
          })
        end

        private

        def supported(support)
          threshold = (@records.size == 1) ? 1 : MIN_SUPPORT
          support.select { |_name, n| n >= threshold }.keys
        end

        # @return [Boolean] true when a new link was made
        def link(category)
          item = ::CategoryItem.find_or_create_by!(category: category, item: @book)
          item.previously_new_record?
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/services/books/world_cat/apply_categories_test.rb && bundle exec standardrb`
Expected: PASS. Each new `CategoryItem` enqueues one `SearchIndexRequest` through the model callback; that is the designed reindex path.

- [ ] **Step 5: Commit**

Stage the service and its test; commit as `Books: WorldCat categories applied to a book`.

---

### Task 20: The backfill run, its job and its rake task

**Files:**
- Create: `web-app/app/lib/services/books/world_cat/backfill.rb`, `web-app/app/sidekiq/books/world_cat_backfill_job.rb` (via `bin/rails generate sidekiq:job books/world_cat_backfill`)
- Modify: `web-app/lib/tasks/worldcat.rake` (add `worldcat:backfill`)
- Test: `web-app/test/lib/services/books/world_cat/backfill_test.rb`, `web-app/test/sidekiq/books/world_cat_backfill_job_test.rb` (generated), `web-app/test/lib/tasks/worldcat_rake_test.rb`

**Interfaces:**
- Produces: `Services::Books::WorldCat::Backfill.call(limit:, run_id:, client: nil, map: nil, batch_size: 100, sleeper: nil, scope: nil) -> Result` with `data: {processed:, matched:, genres_linked:, subjects_linked:, subjects_unresolved: Hash{phrase => count}, stopped:, error:}`; one run at a time (advisory lock); walks books with an ISBN-13 in id order; on `Books::WorldCat::Exceptions::Error` retries the batch after `RETRY_DELAYS = [15, 30, 60, 120, 240, 300]` seconds, then stops with `stopped: true` leaving the remaining books untouched.
- Produces: `Books::WorldCatBackfillJob.perform(limit, run_id)` on queue `low`, `retry: false`.
- Produces: rake `worldcat:backfill[<count>|all]`.
- Consumes: `Client#lookup`, `GenreMap.load`, `ApplyCategories`.

- [ ] **Step 1: Generate the job and write the failing tests**

Run: `bin/rails generate sidekiq:job books/world_cat_backfill`

`test/lib/services/books/world_cat/backfill_test.rb`:
```ruby
require "test_helper"

module Services
  module Books
    module WorldCat
      class BackfillTest < ActiveSupport::TestCase
        class FakeClient
          attr_reader :calls

          def initialize(map, fail_times: 0, error: ::Books::WorldCat::Exceptions::ServerError.new("boom", 500))
            @map = map
            @fail_times = fail_times
            @error = error
            @calls = 0
          end

          def lookup(isbns)
            @calls += 1
            raise @error if (@fail_times -= 1) >= 0

            isbns.to_h { |i| [i, @map.fetch(i, [])] }
          end
        end

        def record(oclc, genre)
          ::Books::WorldCat::Record.from_hash("oclc" => oclc, "genre" => genre)
        end

        setup do
          @map = ::Books::WorldCat::GenreMap.new("genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction"}})
          @war = books_books(:war_and_peace)       # fixture ISBN 9780140447934
          @crime = books_books(:crime_and_punishment)
          ::Identifier.create!(identifiable: @crime, identifier_type: :books_work_isbn13, value: "9780140449136")
          @responses = {"9780140447934" => [record(1, "Fiction"), record(2, "Fiction")], "9780140449136" => [record(3, "Fiction")]}
          @sleeps = []
        end

        def run(client, **opts)
          Backfill.call(limit: nil, run_id: "run-1", client: client, map: @map, sleeper: ->(s) { @sleeps << s }, **opts)
        end

        test "links categories for every book with an ISBN and reports counts" do
          result = run(FakeClient.new(@responses))
          assert result.success?
          assert_equal [2, 2, 2, false], result.data.values_at(:processed, :matched, :genres_linked, :stopped)
          assert_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "a limit walks that many books in id order" do
          result = run(FakeClient.new(@responses), limit: 1)
          assert_equal 1, result.data[:processed]
          assert_includes @war.reload.categories.pluck(:name), "Fiction"
          assert_not_includes @crime.reload.categories.pluck(:name), "Fiction"
        end

        test "a failing batch is retried with backoff and then the run stops" do
          client = FakeClient.new(@responses, fail_times: 2)
          result = run(client)
          assert_equal [15, 30], @sleeps
          assert result.success?
          assert_equal 2, result.data[:matched]
        end

        test "test_an_open_circuit_stops_the_run_without_skipping_books" do
          client = FakeClient.new(@responses, fail_times: 99, error: ::Books::WorldCat::Exceptions::CircuitOpenError.new("open"))
          result = run(client)
          assert_not result.success?
          assert_equal [15, 30, 60, 120, 240, 300], @sleeps
          assert result.data[:stopped]
          assert_match(/open/, result.data[:error])
          assert_equal 0, result.data[:processed]
          assert_not_includes @war.reload.categories.pluck(:name), "Fiction"
        end

        test "unresolved subjects are tallied across the run" do
          map = ::Books::WorldCat::GenreMap.new("genres" => [], "terms" => {"Magic" => {"verdict" => "subject", "subject" => "Sorcery"}})
          responses = {"9780140447934" => [record(1, "Magic")], "9780140449136" => [record(3, "Magic")]}
          result = Backfill.call(limit: nil, run_id: "r", client: FakeClient.new(responses), map: map, sleeper: ->(_) {})
          assert_equal({"Sorcery" => 2}, result.data[:subjects_unresolved])
        end

        test "a second run while one holds the lock exits at once" do
          # Advisory locks are re-entrant within one session, so the holder must be
          # a different connection than the one the service will use.
          other = ::ActiveRecord::Base.connection_pool.checkout
          assert other.select_value("SELECT pg_try_advisory_lock(#{Backfill::LOCK_KEY})")
          result = run(FakeClient.new(@responses))
          assert_not result.success?
          assert_match(/already running/, result.errors.first)
        ensure
          if other
            other.execute("SELECT pg_advisory_unlock(#{Backfill::LOCK_KEY})")
            ::ActiveRecord::Base.connection_pool.checkin(other)
          end
        end
      end
    end
  end
end
```

`test/sidekiq/books/world_cat_backfill_job_test.rb` (replace the generated body):
```ruby
require "test_helper"

class Books::WorldCatBackfillJobTest < ActiveSupport::TestCase
  test "runs the backfill with its limit and run id on the low queue without retries" do
    result = Services::Books::WorldCat::Backfill::Result.new(success?: true, data: {processed: 10, matched: 8, genres_linked: 9, subjects_linked: 2, subjects_unresolved: {}, stopped: false, error: nil}, errors: [])
    Services::Books::WorldCat::Backfill.expects(:call).with(limit: 10, run_id: "run-1").returns(result)

    Books::WorldCatBackfillJob.new.perform(10, "run-1")

    options = Books::WorldCatBackfillJob.get_sidekiq_options
    assert_equal ["low", false], [options["queue"].to_s, options["retry"]]
  end
end
```

Add to the rake test (`TASKS` gains `worldcat:backfill`):
```ruby
  test "backfill queues one run with a count or all" do
    Books::WorldCatBackfillJob.expects(:perform_async).with(100, instance_of(String))
    assert_output(/queued WorldCat backfill run .*: 100 books/) { Rake::Task["worldcat:backfill"].invoke("100") }
    Rake::Task["worldcat:backfill"].reenable
    Books::WorldCatBackfillJob.expects(:perform_async).with(nil, instance_of(String))
    assert_output(/all books/) { Rake::Task["worldcat:backfill"].invoke("all") }
  end

  test "backfill aborts with usage on anything else" do
    Books::WorldCatBackfillJob.expects(:perform_async).never
    assert_output(nil, /usage: worldcat:backfill/) { assert_raises(SystemExit) { Rake::Task["worldcat:backfill"].invoke("soon") } }
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/world_cat/backfill_test.rb test/sidekiq/books/world_cat_backfill_job_test.rb test/lib/tasks/worldcat_rake_test.rb`
Expected: FAIL with `NameError` / the generated job test

- [ ] **Step 3: Implement**

`app/lib/services/books/world_cat/backfill.rb`:
```ruby
# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # One backfill run: every book with an ISBN-13, in id order, looked up in
      # batches and handed to ApplyCategories. Reruns are safe (ApplyCategories is
      # additive and idempotent). A service failure is retried with backoff; when
      # the retries run out the run STOPS and the books it never reached stay
      # untouched -- a tripped breaker must never look like "done".
      class Backfill
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LOCK_KEY = 7_203_911_014
        RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze

        def self.call(limit:, run_id:, client: nil, map: nil, batch_size: 100, sleeper: nil, scope: nil)
          new(limit:, run_id:, client:, map:, batch_size:, sleeper:, scope:).call
        end

        def initialize(limit:, run_id:, client:, map:, batch_size:, sleeper:, scope:)
          @limit = limit
          @run_id = run_id
          @client = client || ::Books::WorldCat::Client.new
          @map = map || ::Books::WorldCat::GenreMap.load
          @batch_size = batch_size
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @scope = scope
        end

        def call
          return failure("a WorldCat backfill is already running") unless try_lock

          stats = {processed: 0, matched: 0, genres_linked: 0, subjects_linked: 0, subjects_unresolved: Hash.new(0), stopped: false, error: nil}
          books_with_isbns.each_slice(@batch_size) do |slice|
            results = lookup_with_retries(slice.flat_map(&:last).uniq)
            if results.nil?
              stats[:stopped] = true
              break
            end
            slice.each do |book_id, isbns|
              book = ::Books::Book.find_by(id: book_id)
              next if book.nil?

              records = isbns.flat_map { |isbn| results.fetch(isbn, []) }
              outcome = ApplyCategories.call(book: book, records: records, map: @map).data
              stats[:processed] += 1
              stats[:matched] += 1 if outcome[:records].positive?
              stats[:genres_linked] += outcome[:genres_linked].size
              stats[:subjects_linked] += outcome[:subjects_linked].size
              outcome[:subjects_unresolved].each { |phrase| stats[:subjects_unresolved][phrase] += 1 }
            end
            Rails.logger.info("WorldCat backfill #{@run_id}: #{stats[:processed]} books, #{stats[:genres_linked]} genre links")
          end
          stats[:error] = @last_error&.message
          stats[:subjects_unresolved] = stats[:subjects_unresolved].sort_by { |phrase, n| [-n, phrase] }.to_h
          Result.new(success?: !stats[:stopped], data: stats, errors: stats[:stopped] ? ["stopped: #{stats[:error]}"] : [])
        ensure
          unlock
        end

        private

        def books_with_isbns
          scope = @scope || ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
            .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
            .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
          pairs = scope.order(:identifiable_id).pluck(:identifiable_id, :value).group_by(&:first)
          books = pairs.map { |book_id, rows| [book_id, rows.map(&:last).uniq] }
          @limit ? books.first(@limit) : books
        end

        def lookup_with_retries(isbns)
          attempts = 0
          begin
            @client.lookup(isbns)
          rescue ::Books::WorldCat::Exceptions::Error => e
            @last_error = e
            return nil if attempts >= RETRY_DELAYS.size

            @sleeper.call(RETRY_DELAYS[attempts])
            attempts += 1
            retry
          end
        end

        def try_lock
          ::ActiveRecord::Base.connection.uncached do
            ::ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
          end
        end

        def unlock
          ::ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})")
        end

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
```

`app/sidekiq/books/world_cat_backfill_job.rb`:
```ruby
# frozen_string_literal: true

# The WorldCat genre/subject backfill (docs/features/worldcat-data-service.md).
# Queued by worldcat:backfill. One run walks every book with an ISBN; `low`
# keeps it behind members' work, and retry is off because the run is its own
# retry loop and a second run while the first holds the lock exits at once.
class Books::WorldCatBackfillJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, run_id)
    data = ::Services::Books::WorldCat::Backfill.call(limit: limit, run_id: run_id).data
    return Rails.logger.warn("WorldCat backfill #{run_id}: did not start (another run holds the lock)") if data.nil?

    Rails.logger.info(
      "WorldCat backfill #{run_id}: #{data[:processed]} books, #{data[:matched]} matched, " \
      "#{data[:genres_linked]} genre links, #{data[:subjects_linked]} subject links, " \
      "#{data[:subjects_unresolved].size} unresolved subject phrases" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}"
    )
  end
end
```

Add to `lib/tasks/worldcat.rake`:
```ruby
  desc "Queue one WorldCat genre/subject backfill run over <count> books (id order) or all: worldcat:backfill[<count>|all]"
  task :backfill, [:limit] => :environment do |_task, args|
    usage = "usage: worldcat:backfill[<count>|all]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    run_id = SecureRandom.uuid
    Books::WorldCatBackfillJob.perform_async(limit, run_id)
    puts "queued WorldCat backfill run #{run_id}: #{limit || "all"} books. One run at a time; a second exits at once. Progress: the worker log."
  end
```

- [ ] **Step 4: Run the tests and lint**

Run: `bin/rails test test/lib/services/books/world_cat test/sidekiq/books/world_cat_backfill_job_test.rb test/lib/tasks/worldcat_rake_test.rb && bundle exec standardrb`
Expected: PASS. Then the full suite: `bin/rails test` must be green with no new warning lines.

- [ ] **Step 5: Commit**

Stage the service, the job, the rake file and the three tests; commit as `Books: WorldCat backfill run, job and rake task`.

---

### Task 21: Feature doc and spec corrections

**Files:**
- Create: `docs/features/worldcat-data-service.md`
- Modify: `docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md`

- [ ] **Step 1: Correct the spec where implementation found it wrong**

In the spec: `WORLDCAT_API_URL` → `WORLDCAT_SERVICE_URL` (Deployment section); remove the `GET /healthz` row and say the heartbeat curls `/version`; in "Tables", `isbns` has columns `isbn13, oclc` only and "indexes only check-digit-valid ISBN-13s; the invalid share is the `isbn_checksums` gate's observation"; in "Build" add "`isbn13s` on a record is the union across every pass of that number"; in "Backfill" add "subject verdicts are honoured on terms from either the `genre` or the `subjects` field". Keep the spec's status line as "approved; corrections from the plan noted".

- [ ] **Step 2: Write the feature doc**

`docs/features/worldcat-data-service.md`, modelled on `open-library-data-service.md`'s opening sections, covering: what it is and the four boundaries; the frozen-dump status and why there is no refresh; the build command and where the source and artifact live; the four tables with their columns; the measured build (rows, bytes, time and gate results copied from the real `build_report.json` once the build has run; until then the section reads "not yet built" rather than carrying estimates); the HTTP contract; deployment (VM 130, the compose profile, loading the artifact); the Rails side (client, the four rake steps, the mapping file's schema and where it lives, the backfill and its support rule); and "What this does not do" (no matching, no editions, no subject creation, no identifiers yet). Link the spec and this plan at the top.

- [ ] **Step 3: Commit**

Stage both docs; commit as `Docs: WorldCat data service feature guide`.

---

## Self-review notes

- **Spec coverage.** Build and tables: Tasks 2–7. Gates: Task 6. HTTP contract: Tasks 8–9. Image and compose: Task 10. Deployment and runbook: Tasks 11–13. Client: Task 14. Vocabulary snapshot, mapping, review, aliases: Tasks 15–18. Backfill rules: Tasks 19–20. Increments 2 and 3 are out of this plan by design.
- **Type consistency.** `Record.from_hash` keys match `worldcat.api.schemas.Record` fields; `GenreMap#genre_for`/`#subject_for` are used by both `ApplyCategories` and `ApplyAliases`; `Backfill` consumes `ApplyCategories.call(...).data` keys `records`, `genres_linked`, `subjects_linked`, `subjects_unresolved`; `Thresholds` is passed through `build()` and the conftest fixture.
- **Review Focus pins.** 1 → Task 9 `test_isbn10_with_x_and_hyphens_is_normalised`; 2 → Task 5 `test_bad_checksum_isbn_is_kept_on_the_record_but_not_indexed`; 3 → Task 5 `test_duplicate_passes_collapse_to_the_newest`; 4 → Task 19 (`test_single_record_book_gets_its_genre`, `test_stray_term_on_one_of_many_records_is_ignored`); 5 → Task 20 `test_an_open_circuit_stops_the_run_without_skipping_books`.
