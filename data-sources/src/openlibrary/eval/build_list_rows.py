"""Build the `list_row` pool: legacy books list items as cases.

Each case is a list row exactly as a list page gave it: `metadata.title` and
`metadata.authors` from the legacy list item, no year, no identifiers, no
existing key -- the shape the books list wizard sends `/resolve`. The linked
book's stored Open Library keys ride along as `hint_work_keys` for the
researcher, never as the label.

The export ranks rows by md5(list_items.id); the 2026-10-04 spike examined
ranks 1-200, so those are skipped here and the cases are held out from the
analysis that shaped the design.

Like build_pool, this module must not import openlibrary.matcher.
"""

from __future__ import annotations

import re
from pathlib import Path

import typer
from pydantic import BaseModel, Field

from openlibrary.eval.build_pool import GeneratedCandidateKey, PoolEntry, naive_candidates
from openlibrary.eval.schema import EvalBook
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

_AUTHOR_SPLIT = re.compile(r"\s*;\s*|\s+&\s+|\s+and\s+", re.IGNORECASE)


class ListRow(BaseModel):
    list_item_id: int
    md5_rank: int
    title: str
    authors: str | list[str] | None = None
    book_id: int
    book_ol_work_keys: list[str] = Field(default_factory=list)


def split_authors(raw: str | list[str] | None) -> list[str]:
    """Split a list row's author text into names. Commas never split: they
    sit inside "King, Jr." and "Last, First"."""
    if not raw:
        return []
    parts = raw if isinstance(raw, list) else [raw]
    names = [name.strip() for part in parts for name in _AUTHOR_SPLIT.split(str(part))]
    return [name for name in names if name]


def select_rows(
    rows: list[ListRow], *, skip_ranks_through: int = 200, n: int = 150
) -> list[ListRow]:
    picked: list[ListRow] = []
    seen_books: set[int] = set()
    for row in sorted(rows, key=lambda r: r.md5_rank):
        if row.md5_rank <= skip_ranks_through or row.book_id in seen_books:
            continue
        seen_books.add(row.book_id)
        picked.append(row)
        if len(picked) == n:
            break
    return picked


def to_book(row: ListRow) -> EvalBook:
    return EvalBook(book_id=row.book_id, title=row.title, author_names=split_authors(row.authors))


def load_rows(path: Path) -> list[ListRow]:
    with Path(path).open(encoding="utf-8") as fh:
        return [ListRow.model_validate_json(line) for line in fh if line.strip()]


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    rows_path: Path = typer.Option(..., "--rows"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    from openlibrary.pipeline.duck import connect

    rows = select_rows(load_rows(rows_path))
    books = [to_book(r) for r in rows]
    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    candidates = naive_candidates(con, paths, books)
    con.close()

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        for index, (row, book) in enumerate(zip(rows, books, strict=True), start=1):
            generated = candidates.get(book.book_id, [])
            ranked = sorted(
                generated, key=lambda c: (-c.readinglog_count, -c.edition_count, c.work_key)
            )
            entry = PoolEntry(
                case_id=f"list_row-{index:03d}",
                stratum="list_row",
                book=book,
                candidates=ranked[:20],
                all_generated=[
                    GeneratedCandidateKey(work_key=c.work_key, rules=c.rules) for c in generated
                ],
                hint_work_keys=row.book_ol_work_keys,
            )
            fh.write(entry.model_dump_json() + "\n")
    typer.echo(f"wrote {len(rows)} list-row pool entries to {out}")


if __name__ == "__main__":
    app()
