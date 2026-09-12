"""Where does our stored author disagree with Open Library's?

The books domain's one external source is the Amazon Product API, which cannot
audit what is already stored. This is the first thing the distilled artifact
makes possible: join every local book that carries an identifier to its Open
Library work, and compare the author we hold against every name OL holds.

Comparing by exact fingerprint calls 16.0% of the catalogue a disagreement, and
most of that is noise. `classify_disagreement` splits it, because the classes
need different work and only one of them is a data repair.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

import typer

from common.normalize import name_fingerprint
from openlibrary.eval.build_pool import _identifier_pairs, _load_rows, load_books
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# Names that stand in for "we did not know", so a mismatch says nothing.
PLACEHOLDER_NAMES = frozenset(
    {"unknown", "anonymous", "various", "various authors", "n a", "none", "author unknown"}
)

# A token shorter than this is an initial. Two names sharing only `s` share
# nothing, and counting that as a collision inflates the one number that means
# "repair this".
MIN_SIGNIFICANT_TOKEN = 3

CLASSES = (
    "agrees",
    "placeholder",
    "name_order",
    "name_subset",
    "surname_collision",
    "unrelated",
)


def classify_disagreement(local_fps: list[str], ol_fps: list[str]) -> str:
    """How do our author names differ from the ones Open Library holds?

    `local_fps` and `ol_fps` are name fingerprints (`common.normalize`).
    OL's list should include alternate names as well as primary ones: `Kazuo
    Koike` is only an alternate of `小池一夫`, and comparing primaries alone
    reports a disagreement where there is none.

    Order matters. Agreement wins outright; a placeholder local name is
    excluded before anything is inferred from it; and the formatting classes
    are checked before `surname_collision`, because `davies brian` shares a
    surname with `brian davies` and is not a collision.
    """
    local = [fp for fp in local_fps if fp]
    theirs = [fp for fp in ol_fps if fp]
    if not local or not theirs:
        return "unrelated"
    if set(local) & set(theirs):
        return "agrees"
    if any(fp in PLACEHOLDER_NAMES for fp in local):
        return "placeholder"

    local_tokens = [set(fp.split()) for fp in local]
    ol_tokens = [set(fp.split()) for fp in theirs]

    for ours in local_tokens:
        for other in ol_tokens:
            if ours == other:
                return "name_order"
    for ours in local_tokens:
        for other in ol_tokens:
            if ours and other and (ours <= other or other <= ours):
                return "name_subset"
    for ours in local_tokens:
        for other in ol_tokens:
            shared = {t for t in ours & other if len(t) >= MIN_SIGNIFICANT_TOKEN}
            if shared:
                return "surname_collision"
    return "unrelated"


def audit(root: Path, dump_date: str, books_path: Path, out_path: Path | None) -> dict[str, int]:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="16GB")

    books = load_books(books_path)
    rows, id_rows = [], []
    for book in books:
        fps = sorted({fp for fp in (name_fingerprint(n) for n in book.author_names) if fp})
        rows.append((book.book_id, book.title, book.author_names, fps))
        for id_type, value in _identifier_pairs(book):
            id_rows.append((book.book_id, id_type, value))

    _load_rows(
        con,
        "local_books",
        [
            ("book_id", "INTEGER"),
            ("title", "VARCHAR"),
            ("names", "VARCHAR[]"),
            ("fps", "VARCHAR[]"),
        ],
        rows,
    )
    _load_rows(
        con,
        "local_ids",
        [("book_id", "INTEGER"), ("id_type", "VARCHAR"), ("value", "VARCHAR")],
        id_rows,
    )

    # Every name OL holds for the work's authors, primary AND alternate.
    con.execute(
        f"""
        CREATE OR REPLACE TABLE ol_names AS
        SELECT m.book_id, list(DISTINCT an.name_fp) AS ol_fps
        FROM (SELECT DISTINCT l.book_id, i.work_key
              FROM local_ids l
              JOIN '{paths.table("identifiers")}' i
                ON i.id_type = l.id_type AND i.value = l.value
              WHERE i.work_key IS NOT NULL) m
        JOIN '{paths.table("work_authors")}' wa ON wa.work_key = m.work_key
        JOIN '{paths.table("author_names")}' an ON an.author_key = wa.author_key
        WHERE an.name_fp <> ''
        GROUP BY m.book_id
        """
    )
    pairs = con.execute(
        """
        SELECT b.book_id, b.title, b.names, b.fps, o.ol_fps
        FROM local_books b JOIN ol_names o USING (book_id)
        WHERE len(b.fps) > 0
        """
    ).fetchall()
    con.close()

    counts: Counter[str] = Counter()
    suspects = []
    for book_id, title, names, fps, ol_fps in pairs:
        verdict = classify_disagreement(list(fps), list(ol_fps))
        counts[verdict] += 1
        if verdict in ("surname_collision", "unrelated"):
            suspects.append(
                {
                    "book_id": book_id,
                    "title": title,
                    "ours": list(names),
                    "ol": list(ol_fps),
                    "classification": verdict,
                }
            )

    if out_path:
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        Path(out_path).write_text(
            "\n".join(json.dumps(s, ensure_ascii=False) for s in suspects) + "\n",
            encoding="utf-8",
        )
    return dict(counts)


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    books: Path = typer.Option(..., "--books"),  # noqa: B008
    out: Path | None = typer.Option(None, "--out"),  # noqa: B008
) -> None:
    counts = audit(root, dump_date, books, out)
    total = sum(counts.values())
    typer.echo(f"comparable books (ours has an author, OL identified it): {total:,}")
    for name in CLASSES:
        n = counts.get(name, 0)
        if total:
            typer.echo(f"  {name:<20} {n:>8,}  ({n / total:5.1%})")
    if out:
        typer.echo(f"wrote the surname_collision + unrelated books to {out}")


if __name__ == "__main__":
    app()
