"""Books we hold twice, found through Open Library rather than through titles.

`Books::Book` is work-level, so two of our rows resolving to the same Open
Library work are the same book entered twice. Doing it this way instead of by
title is what catches `Der Grosse Crash 1929` beside `The Great Crash, 1929` --
one book under two languages, which no title comparison will ever pair.

The output is a candidate list, not a verdict, and two limits shape it. Open
Library conflates works of its own: OL16825084W holds three different Veronica
Roth novellas, and three of our rows land on it looking exactly like
duplicates. And a row Open Library cannot place is invisible here -- the German
Galbraith that started this has no ISBN in OL, so the pair that proved the
method exists is the one the method cannot see.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

import typer

from openlibrary.eval.build_pool import _identifier_pairs, _load_rows, load_books
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)


def confident_duplicate_groups(works_of_book: dict[int, set[str]]) -> dict[str, list[int]]:
    """Group book ids by the single Open Library work they all resolve to.

    A row is admitted only when that work is its *only* claim. A row resolving
    to several works shares one of them nearly for free -- book #14079 resolves
    to four works because OL holds `The Great Crash, 1929` nine times -- and an
    overlap that cheap is not evidence of anything.

    Rows Open Library cannot place are ignored rather than grouped, which makes
    every count from this a floor.
    """
    grouped: dict[str, list[int]] = defaultdict(list)
    for book_id, works in works_of_book.items():
        if len(works) == 1:
            grouped[next(iter(works))].append(book_id)
    return {work: sorted(ids) for work, ids in grouped.items() if len(ids) > 1}


def audit(root: Path, dump_date: str, books_path: Path, out_path: Path | None) -> dict[str, int]:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="14GB")
    books = load_books(books_path)

    rows = [
        (book.book_id, id_type, value)
        for book in books
        for id_type, value in _identifier_pairs(book)
    ]
    _load_rows(
        con,
        "local_ids",
        [("book_id", "INTEGER"), ("id_type", "VARCHAR"), ("value", "VARCHAR")],
        rows,
    )
    resolved = con.execute(
        f"""
        SELECT l.book_id, i.work_key
        FROM local_ids l
        JOIN '{paths.table("identifiers")}' i
          ON i.id_type = l.id_type AND i.value = l.value
        WHERE i.work_key IS NOT NULL
        GROUP BY 1, 2
        """
    ).fetchall()
    con.close()

    works_of_book: dict[int, set[str]] = defaultdict(set)
    for book_id, work_key in resolved:
        works_of_book[book_id].add(work_key)

    shared: dict[str, set[int]] = defaultdict(set)
    for book_id, works in works_of_book.items():
        for work in works:
            shared[work].add(book_id)
    shared = {w: ids for w, ids in shared.items() if len(ids) > 1}

    groups = confident_duplicate_groups(dict(works_of_book))
    titles = {b.book_id: (b.title, b.author_names, b.first_published_year) for b in books}
    if out_path:
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        Path(out_path).write_text(
            "\n".join(
                json.dumps(
                    {
                        "work_key": work,
                        "book_ids": ids,
                        "books": [
                            {
                                "book_id": i,
                                "title": titles[i][0],
                                "authors": titles[i][1],
                                "year": titles[i][2],
                            }
                            for i in ids
                        ],
                    },
                    ensure_ascii=False,
                )
                for work, ids in sorted(groups.items())
            )
            + "\n",
            encoding="utf-8",
        )
    return {
        "books": len(books),
        "resolved": len(works_of_book),
        "shared_works": len(shared),
        "shared_books": len({b for ids in shared.values() for b in ids}),
        "confident_works": len(groups),
        "confident_books": len({b for ids in groups.values() for b in ids}),
    }


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    books: Path = typer.Option(..., "--books"),  # noqa: B008
    out: Path | None = typer.Option(None, "--out"),  # noqa: B008
) -> None:
    counts = audit(root, dump_date, books, out)
    typer.echo(f"exported books:              {counts['books']:,}")
    typer.echo(f"  resolved to an OL work:    {counts['resolved']:,}")
    typer.echo(
        f"\nOL works >1 of our books claim: {counts['shared_works']:,} "
        f"({counts['shared_books']:,} books)"
    )
    typer.echo(
        f"  confident (single claim):     {counts['confident_works']:,} "
        f"({counts['confident_books']:,} books)"
    )
    if out:
        typer.echo(f"\nwrote the confident groups to {out}")


if __name__ == "__main__":
    app()
