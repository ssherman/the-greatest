"""Build the stratified candidate pool a human labels in Task 19-20.

NAIVE blocking only -- identifier, existing key, author + title fingerprint, and
title fingerprint under a frequency guard. These are exactly the four rules the
design measured (union recall 82.2%, exactly-one 44.6%).

This module must NOT import openlibrary.matcher. The evaluation set is the thing
the matcher is judged against; if tuning the matcher could change which cases
exist or which candidates a labeler saw, the metrics would measure nothing. A
work key the labeler enters by hand and that no rule here produced is recorded
as `found_outside_blocking` -- that is how a recall failure becomes visible.
"""

from __future__ import annotations

import random
from pathlib import Path

import duckdb
import typer
from pydantic import BaseModel, Field

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    name_fingerprint,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    title_fingerprints,
)
from openlibrary.eval.schema import STRATA, EvalBook
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# The design's data-driven guard. A fingerprint shared by more than this many
# works is not a blocking key; it is "selected poems".
MAX_TITLE_FP_FREQ = 50
# No rule may return more candidates than this for one book. A visible gap beats
# a query that never returns: "!!!" once produced a 604,144-row join.
MAX_CANDIDATES_PER_RULE = 200


class PoolCandidate(BaseModel):
    work_key: str
    rules: list[str] = Field(default_factory=list)
    title: str | None = None
    author_names: list[str] = Field(default_factory=list)
    declared_year: int | None = None
    min_edition_year: int | None = None
    modal_edition_year: int | None = None
    edition_count: int = 0
    readinglog_count: int = 0
    ratings_count: int = 0
    title_fp_freq: int = 0


class GeneratedCandidateKey(BaseModel):
    """A blocking-produced key with no evidence fields -- provenance only.

    Deliberately smaller than `PoolCandidate`: `PoolEntry.all_generated` exists
    only so `found_outside_blocking` can be computed correctly, not to carry
    display evidence for candidates nobody will see rendered.
    """

    work_key: str
    rules: list[str] = Field(default_factory=list)


class PoolEntry(BaseModel):
    case_id: str
    stratum: str
    book: EvalBook
    candidates: list[PoolCandidate] = Field(default_factory=list)
    # The COMPLETE set of keys blocking generated for this book, before the
    # `[:20]` display slice below. `candidates` is capped at 20 for the
    # labeling CLI's terminal rendering; `all_generated` is what
    # `EvalCase.found_outside_blocking` must be computed against, so that a
    # manually-entered key blocking DID produce -- just outside the top 20 --
    # is not misrecorded as a recall failure. Do NOT collapse this back into
    # `candidates`; see label.py's `candidates_shown_for`.
    all_generated: list[GeneratedCandidateKey] = Field(default_factory=list)


def load_books(path: Path) -> list[EvalBook]:
    books = []
    with Path(path).open(encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                books.append(EvalBook.model_validate_json(line))
    return books


def _load_rows(
    con: duckdb.DuckDBPyConnection,
    table: str,
    columns: list[tuple[str, str]],
    rows: list[tuple],
) -> None:
    """Replace `table` with `rows`, via CREATE TABLE + parameterized INSERT.

    `con.register(name, list_of_dicts)` is rejected in this environment:
    DuckDB's Python replacement scan only accepts a pandas DataFrame, a
    DuckDBPyRelation, a pyarrow Table/Dataset/Scanner, or a NumPy ndarray --
    and despite the docstring's expectation, pyarrow is NOT actually present
    here (duckdb 1.5.5 does not pull it in transitively in this project's
    lockfile, confirmed via `uv run python -c "import pyarrow"` failing with
    ModuleNotFoundError). Adding it to pyproject.toml is out of scope for this
    task. A parameterized `executemany` needs no extra dependency and binds
    list-typed columns (VARCHAR[]) correctly.
    """
    col_defs = ", ".join(f"{name} {sql_type}" for name, sql_type in columns)
    con.execute(f"CREATE OR REPLACE TABLE {table} ({col_defs})")
    if rows:
        placeholders = ", ".join(["?"] * len(columns))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)


_EVAL_BOOKS_COLUMNS = [
    ("book_id", "INTEGER"),
    ("title_fp", "VARCHAR"),
    ("title_fp_nosub", "VARCHAR"),
    ("title_fp_noart", "VARCHAR"),
    ("author_fps", "VARCHAR[]"),
    ("id_types", "VARCHAR[]"),
    ("id_values", "VARCHAR[]"),
    ("existing_keys", "VARCHAR[]"),
]


def _identifier_pairs(book: EvalBook) -> list[tuple[str, str]]:
    """Canonicalize a book's locally-stored identifiers before they are joined.

    `identifiers.parquet` stores values already run through `isbn13_sql` /
    `isbn10_sql` / `asin_sql` / `goodreads_sql` (see pipeline/editions.py).
    Rule 1's join is exact equality, so a local value in any other form -- a
    hyphenated ISBN, a lowercase ISBN-10 check digit, a slugged Goodreads id
    -- silently misses. Every value is pushed through the matching Python
    normalizer (the twin of the SQL one) before it is registered here; values
    that normalize to None are dropped rather than registered raw.
    """
    pairs: set[tuple[str, str]] = set()

    for value in [*book.isbn13, *book.isbn10]:
        normalized = normalize_isbn(value)
        if normalized is None:
            continue
        if normalized.isbn13:
            pairs.add(("isbn13", normalized.isbn13))
        if normalized.isbn10:
            pairs.add(("isbn10", normalized.isbn10))

    for value in book.asin:
        asin = normalize_asin(value)
        if asin is not None:
            pairs.add(("asin", asin))
        # An Amazon ASIN for a book is usually its ISBN-10 -- mirrors what the
        # design specifies for rule 1 (matcher/blocking.py does not exist yet).
        normalized = normalize_isbn(value)
        if normalized is not None:
            if normalized.isbn13:
                pairs.add(("isbn13", normalized.isbn13))
            if normalized.isbn10:
                pairs.add(("isbn10", normalized.isbn10))

    for value in book.goodreads_id:  # [GOODREADS]
        goodreads = normalize_goodreads(value)
        if goodreads is not None:
            pairs.add(("goodreads", goodreads))

    return sorted(pairs)


def _register_books(con: duckdb.DuckDBPyConnection, books: list[EvalBook]) -> None:
    rows = []
    for book in books:
        fps = title_fingerprints(book.title)
        identifiers = _identifier_pairs(book)
        rows.append(
            (
                book.book_id,
                fps.full,
                fps.nosub,
                fps.noart,
                [fp for fp in (name_fingerprint(n) for n in book.author_names) if fp],
                [t for t, _ in identifiers],
                [v for _, v in identifiers],
                list(book.existing_ol_work_keys),
            )
        )
    _load_rows(con, "eval_books", _EVAL_BOOKS_COLUMNS, rows)


def naive_candidates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books: list[EvalBook],
) -> dict[int, list[PoolCandidate]]:
    _register_books(con, books)

    con.execute(
        f"""
        CREATE OR REPLACE TABLE eval_hits AS
        -- rule 1: identifier
        SELECT b.book_id, i.work_key, 'identifier' AS rule
        FROM (SELECT book_id, unnest(id_types) AS id_type, unnest(id_values) AS value
              FROM eval_books) b
        JOIN '{paths.table("identifiers")}' i
          ON i.id_type = b.id_type AND i.value = b.value
        WHERE i.work_key IS NOT NULL

        UNION
        -- rule 2: the existing stored key, resolved through redirects
        SELECT b.book_id,
               COALESCE(r.terminal_key, b.existing_key) AS work_key,
               'existing_key' AS rule
        FROM (SELECT book_id, unnest(existing_keys) AS existing_key FROM eval_books) b
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = b.existing_key AND r.entity = 'work' AND NOT r.is_cycle
        WHERE COALESCE(r.terminal_key, b.existing_key) IS NOT NULL

        UNION
        -- rule 3: resolved author + any title fingerprint variant
        SELECT b.book_id, w.work_key, 'author_title_fp' AS rule
        FROM (SELECT book_id, unnest(author_fps) AS author_fp,
                     title_fp, title_fp_nosub, title_fp_noart
              FROM eval_books) b
        JOIN '{paths.table("author_names")}' an ON an.name_fp = b.author_fp
        JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
        JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
        WHERE w.title_fp IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)
           OR w.title_fp_nosub IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)
           OR w.title_fp_noart IN (b.title_fp, b.title_fp_nosub, b.title_fp_noart)

        UNION
        -- rule 4: title fingerprint alone, guarded by frequency
        SELECT b.book_id, w.work_key, 'title_fp' AS rule
        FROM eval_books b
        JOIN '{paths.table("works")}' w
          ON w.title_fp = b.title_fp
        WHERE length(b.title_fp) >= {MIN_BLOCKING_FP_LENGTH}
          AND w.title_fp_freq <= {MAX_TITLE_FP_FREQ};
        """
    )

    rows = con.execute(
        f"""
        WITH capped AS (
          SELECT book_id, work_key, list(DISTINCT rule) AS rules
          FROM eval_hits
          GROUP BY book_id, work_key
        ),
        ranked AS (
          SELECT *, row_number() OVER (PARTITION BY book_id ORDER BY work_key) AS rn
          FROM capped
        )
        SELECT
          c.book_id, c.work_key, c.rules,
          w.title, w.title_fp_freq,
          y.declared_year, y.min_edition_year, y.modal_edition_year,
          COALESCE(p.edition_count, 0), COALESCE(p.readinglog_count, 0),
          COALESCE(p.ratings_count, 0),
          COALESCE(list(a.name) FILTER (WHERE a.name IS NOT NULL), []) AS author_names
        FROM ranked c
        JOIN '{paths.table("works")}' w USING (work_key)
        LEFT JOIN '{paths.table("year_evidence")}' y USING (work_key)
        LEFT JOIN '{paths.table("popularity")}' p USING (work_key)
        LEFT JOIN '{paths.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{paths.table("authors")}' a USING (author_key)
        WHERE c.rn <= {MAX_CANDIDATES_PER_RULE}
        GROUP BY c.book_id, c.work_key, c.rules, w.title, w.title_fp_freq,
                 y.declared_year, y.min_edition_year, y.modal_edition_year,
                 p.edition_count, p.readinglog_count, p.ratings_count
        """
    ).fetchall()

    result: dict[int, list[PoolCandidate]] = {}
    for row in rows:
        result.setdefault(row[0], []).append(
            PoolCandidate(
                work_key=row[1],
                rules=sorted(row[2]),
                title=row[3],
                title_fp_freq=row[4] or 0,
                declared_year=row[5],
                min_edition_year=row[6],
                modal_edition_year=row[7],
                edition_count=row[8],
                readinglog_count=row[9],
                ratings_count=row[10],
                author_names=list(row[11] or []),
            )
        )
    return result


def assign_strata(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books: list[EvalBook],
    candidates: dict[int, list[PoolCandidate]],
) -> dict[str, list[int]]:
    """Assign each book to at most one stratum, most-specific first.

    Order matters: a book can satisfy several predicates, and the rare strata
    must claim their members before `easy_baseline` absorbs them.
    """
    by_id = {b.book_id: b for b in books}

    shared_keys = _keys_attached_to_more_than_one_book(books)
    stale_keys = _stale_keys(con, paths, books)
    reused_isbns = _reused_isbns(con, paths, books)
    alt_name_only = _authors_matching_only_alternate_names(con, paths, books)

    assigned: dict[str, list[int]] = {name: [] for name in STRATA}
    taken: set[int] = set()

    def claim(stratum: str, book_ids) -> None:
        for book_id in book_ids:
            if book_id in taken or book_id not in by_id:
                continue
            taken.add(book_id)
            assigned[stratum].append(book_id)

    claim(
        "shared_key_collision",
        (b.book_id for b in books if set(b.existing_ol_work_keys) & shared_keys),
    )
    claim("stale_ol_key", (b.book_id for b in books if set(b.existing_ol_work_keys) & stale_keys))
    claim("isbn_reuse", (b.book_id for b in books if set(b.isbn13) & reused_isbns))
    claim(
        "degenerate_title",
        (
            b.book_id
            for b in books
            if len(title_fingerprints(b.title).full) < MIN_BLOCKING_FP_LENGTH
        ),
    )
    # A LETTER outside the Latin blocks (Basic Latin, Latin-1 Supplement, Latin
    # Extended-A/B all end at U+024F). `ord(ch) > 0x2000` was wrong twice over:
    # Greek (U+0370) and Cyrillic (U+0400) sit BELOW it and were structurally
    # unreachable, while typographic punctuation above it -- an en dash in
    # "Novels 1896-1899" -- claimed pure-Latin titles. `.isalpha()` is what
    # excludes the punctuation; 0x024F is what includes the scripts.
    claim(
        "non_latin_title",
        (b.book_id for b in books if any(ch.isalpha() and ord(ch) > 0x024F for ch in b.title)),
    )
    claim("author_less_work", (b.book_id for b in books if not b.author_names))
    claim("pseudonym_or_alt_name", alt_name_only)
    claim(
        "anthology_or_collection",
        (
            b.book_id
            for b in books
            if any(
                word in b.title.lower()
                for word in ("anthology", "collected", "complete works", "omnibus", "selected")
            )
        ),
    )
    claim("no_candidates", (b.book_id for b in books if not candidates.get(b.book_id)))
    claim(
        "high_frequency_title",
        (
            b.book_id
            for b in books
            if any(c.title_fp_freq > MAX_TITLE_FP_FREQ for c in candidates.get(b.book_id, []))
        ),
    )
    claim(
        "no_popularity_signal",
        (
            b.book_id
            for b in books
            if candidates.get(b.book_id)
            and all(c.readinglog_count == 0 and c.ratings_count == 0 for c in candidates[b.book_id])
        ),
    )
    claim("easy_baseline", (b.book_id for b in books if len(candidates.get(b.book_id, [])) == 1))

    return assigned


def _keys_attached_to_more_than_one_book(books: list[EvalBook]) -> set[str]:
    counts: dict[str, int] = {}
    for book in books:
        for key in set(book.existing_ol_work_keys):
            counts[key] = counts.get(key, 0) + 1
    return {key for key, count in counts.items() if count > 1}


def _stale_keys(con, paths: ArtifactPaths, books: list[EvalBook]) -> set[str]:
    keys = sorted({k for b in books for k in b.existing_ol_work_keys})
    if not keys:
        return set()
    _load_rows(con, "stored_keys", [("work_key", "VARCHAR")], [(k,) for k in keys])
    rows = con.execute(
        f"""
        SELECT s.work_key FROM stored_keys s
        WHERE s.work_key NOT IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchall()
    return {row[0] for row in rows}


def _reused_isbns(con, paths: ArtifactPaths, books: list[EvalBook]) -> set[str]:
    values = sorted({v for b in books for v in b.isbn13})
    if not values:
        return set()
    _load_rows(con, "stored_isbns", [("value", "VARCHAR")], [(v,) for v in values])
    rows = con.execute(
        f"""
        SELECT i.value FROM '{paths.table("identifiers")}' i
        JOIN stored_isbns s USING (value)
        WHERE i.id_type = 'isbn13' AND i.work_key IS NOT NULL
        GROUP BY i.value
        HAVING count(DISTINCT i.work_key) > 1
        """
    ).fetchall()
    return {row[0] for row in rows}


def _authors_matching_only_alternate_names(con, paths, books) -> list[int]:
    rows_in = []
    for book in books:
        for name in book.author_names:
            fp = name_fingerprint(name)
            if fp:
                rows_in.append((book.book_id, fp))
    if not rows_in:
        return []
    _load_rows(con, "eval_author_fps", [("book_id", "INTEGER"), ("name_fp", "VARCHAR")], rows_in)
    rows = con.execute(
        f"""
        SELECT e.book_id
        FROM eval_author_fps e
        JOIN '{paths.table("author_names")}' an USING (name_fp)
        GROUP BY e.book_id
        HAVING count(*) FILTER (WHERE an.source = 'primary') = 0
           AND count(*) FILTER (WHERE an.source = 'alternate') > 0
        """
    ).fetchall()
    return [row[0] for row in rows]


def build_pool(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    books_path: Path,
    out_path: Path,
    *,
    seed: int = 20260901,
) -> dict[str, int]:
    books = load_books(books_path)
    candidates = naive_candidates(con, paths, books)
    assigned = assign_strata(con, paths, books, candidates)
    by_id = {b.book_id: b for b in books}

    rng = random.Random(seed)
    counts: dict[str, int] = {}
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with Path(out_path).open("w", encoding="utf-8") as fh:
        for stratum, quota in STRATA.items():
            members = assigned.get(stratum, [])
            rng.shuffle(members)
            chosen = members[:quota]
            counts[stratum] = len(chosen)
            for index, book_id in enumerate(chosen, start=1):
                generated = candidates.get(book_id, [])
                ranked = sorted(
                    generated,
                    key=lambda c: (-c.readinglog_count, -c.edition_count, c.work_key),
                )
                entry = PoolEntry(
                    case_id=f"{stratum}-{index:03d}",
                    stratum=stratum,
                    book=by_id[book_id],
                    # Capped at 20 -- see the `all_generated` field docstring.
                    candidates=ranked[:20],
                    all_generated=[
                        GeneratedCandidateKey(work_key=c.work_key, rules=c.rules) for c in generated
                    ],
                )
                fh.write(entry.model_dump_json() + "\n")
    return counts


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    books: Path = typer.Option(..., "--books"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    counts = build_pool(con, paths, books, out)
    con.close()
    for stratum, quota in STRATA.items():
        got = counts.get(stratum, 0)
        marker = "OK " if got >= quota else "SHORT"
        typer.echo(f"  {marker} {stratum:26} {got:>4} / {quota}")
    typer.echo(f"total {sum(counts.values())} cases written to {out}")


if __name__ == "__main__":
    app()
