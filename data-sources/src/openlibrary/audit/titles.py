"""Title text that the matcher cannot see past.

The pipeline already fingerprints three ways -- `title_fp`, `title_fp_nosub`
and `title_fp_noart` -- and `author_title_fp` tries all nine combinations of
them. None of that helps when the noise is *inside* the title string, because
`nosub` strips the separate `subtitle` field and nothing else.

The old importer concatenated. Book #143219 is stored as `Andrew Jackson And
The Course Of The American Empire, 1767 1821 Volume I` while Open Library holds
`Andrew Jackson and the Course of the American Empire` (OL273027W); the glued-on
date range and volume number are the entire reason four blocking rules produced
nothing for a book Open Library has three copies of.

Two different jobs live here. `title_repeats_subtitle` finds a *data defect* to
repair. `strip_matching_noise` is a *matcher* normalisation: a volume number is
not wrong, it is just absent from the string OL indexes, so the fix is another
blocking key rather than an edit to the row.
"""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

import typer

from common.normalize import fingerprint
from openlibrary.eval.build_pool import _load_rows, load_books
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# A subtitle shorter than this inside a title is a coincidence, not a repeat:
# "Ice" sits inside "A Book of Ice" without either being wrong.
MIN_SUBTITLE_ECHO = 4

_ROMAN = r"M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})"
_VOLUME = re.compile(rf"[,\s]*\b(?:vol\.?|volume)\s+(?:\d+|{_ROMAN})\s*$", re.IGNORECASE)
# Four-digit years only, and only as a RANGE. A lone year is often the title
# itself (`1984`) or the actual subject (`The War Book ... 1914`).
_YEAR_RANGE = re.compile(r"[,\s]*\b(1[0-9]{3}|20[0-9]{2})\s*[-–—]?\s*(1[0-9]{3}|20[0-9]{2})\b")


def _drop_range(match: re.Match[str]) -> str:
    first, second = int(match.group(1)), int(match.group(2))
    return "" if second >= first else match.group(0)


def strip_matching_noise(title: str) -> str:
    """Remove a trailing volume designator and any four-digit date range.

    For *matching* only -- the result is a blocking key, never a replacement
    for the stored title. A title that is nothing but noise (`Volume II`,
    `1767-1821`) is returned unchanged, because an empty fingerprint would
    block against every other empty one.
    """
    stripped = _YEAR_RANGE.sub(_drop_range, _VOLUME.sub("", title or ""))
    stripped = stripped.strip(" ,;:-–—")
    return stripped if stripped else title


def title_repeats_subtitle(title: str, subtitle: str | None) -> bool:
    """Did the importer write the subtitle into the title as well as beside it?

    This one is a data defect: the row holds the same words twice, and
    `title_fp_nosub` -- whose whole job is to compare without the subtitle --
    silently does nothing on these books.
    """
    if not subtitle or not title:
        return False
    needle = subtitle.strip().casefold()
    if len(needle) < MIN_SUBTITLE_ECHO:
        return False
    return needle in title.casefold()


# `#N` shapes. Measured on the 2026-07-31 export, no title fires more than one
# of these, so the order below is defensive rather than a specification -- do
# not read precedence into it.
_ISSUE_RANGE = re.compile(r"#\s*\d+\s*[-\u2013]\s*\d+\b|#\s*\d+\s+\d+\b")
_ISSUE_ANNOTATION = re.compile(r"#\s*\d+(?:\.\d+)?\s*[)\]]\s*$")
_ISSUE_TRAILING = re.compile(r"#\s*\d+(?:\.\d+)?\s*$")


def classify_issue_title(title: str) -> str:
    """What does a `#N` in one of our titles actually mean?

    1,048 exported titles carry one and they are four different things, wanting
    opposite handling:

    - `single_issue`      `Batman #614`. A 26-page floppy. Open Library has no
                          `Batman #614`, and none at all for The Walking Dead,
                          Nightwing or Descender. The matcher should abstain,
                          not reach for the collected trade sitting next to it.
    - `collected_range`   `The Dark Tower #1 3`. A span, so the omnibus is the
                          right target rather than any single work.
    - `series_annotation` `Ranma 1/2, Vol. 20 , #20)`. Goodreads writes
                          `Title (Series #N)`; the importer kept the closing
                          bracket and lost the opening one. These are ordinary
                          books that match once the annotation is gone.
    - `none`              `The #1 Lawyer`, `C#`, `#Girlboss`. A number sign.

    The trailing bracket is what separates the third from the first: `Vol. 20`
    and `#20)` in one title is Goodreads saying the same thing twice, not an
    issue number. All 22 in the export have lost their opening bracket, and
    none has a well-formed `(... #N)`, so nothing here tests for balance.
    """
    text = (title or "").strip()
    if not text:
        return "none"
    if _ISSUE_RANGE.search(text):
        return "collected_range"
    if _ISSUE_ANNOTATION.search(text):
        return "series_annotation"
    if _ISSUE_TRAILING.search(text):
        return "single_issue"
    return "none"


def classify_title_collision(work_sets: list[set[str]]) -> str:
    """Why do several of our Book rows share one (author, title)?

    Two opposite defects produce the same symptom. The importer truncated a
    series title, so different books collapsed onto one string and the repair
    is to SPLIT them; or the same book was imported twice and the repair is to
    MERGE them. The title cannot tell them apart.

    Open Library arbitrates. `work_sets` holds, per row, the OL works that
    row's identifiers resolve to -- an empty set for a row OL cannot place.

    - `unresolved`    fewer than two rows resolved. One opinion is not a
                      comparison, and 70 of the 146 real groups land here.
    - `duplicate_rows` every resolved row shares a work: one book, many rows.
    - `distinct_books` no two resolved rows share a work: different books.
    - `mixed`         some rows share and some do not, so the group holds both
                      defects and neither repair is safe applied wholesale.
    """
    resolved = [set(s) for s in work_sets if s]
    if len(resolved) < 2:
        return "unresolved"
    if set.intersection(*resolved):
        return "duplicate_rows"
    if all(not (a & b) for i, a in enumerate(resolved) for b in resolved[i + 1 :]):
        return "distinct_books"
    return "mixed"


def audit(root: Path, dump_date: str, books_path: Path, out_path: Path | None) -> dict[str, int]:
    """Count the defects, then measure what the normalisation would actually buy.

    The counts alone do not justify code. The number that does is how many
    books currently reaching NO Open Library work gain one when the stripped
    fingerprint is used as an extra blocking key.
    """
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="16GB")
    books = load_books(books_path)

    counts: Counter[str] = Counter({"books": len(books)})
    rows, gained = [], []
    for book in books:
        raw_fp = fingerprint(book.title)
        clean_fp = fingerprint(strip_matching_noise(book.title))
        if title_repeats_subtitle(book.title, book.subtitle):
            counts["title_repeats_subtitle"] += 1
        if _VOLUME.search(book.title or ""):
            counts["trailing_volume"] += 1
        if _YEAR_RANGE.search(book.title or ""):
            counts["date_range"] += 1
        if clean_fp != raw_fp:
            counts["fingerprint_changes"] += 1
            rows.append((book.book_id, book.title, raw_fp, clean_fp))

    _load_rows(
        con,
        "local_titles",
        [
            ("book_id", "INTEGER"),
            ("title", "VARCHAR"),
            ("raw_fp", "VARCHAR"),
            ("clean_fp", "VARCHAR"),
        ],
        rows,
    )
    # Books whose RAW fingerprint reaches no work but whose STRIPPED one does.
    gained = con.execute(
        f"""
        SELECT t.book_id, t.title, t.clean_fp, count(DISTINCT w.work_key) AS works
        FROM local_titles t
        JOIN '{paths.table("works")}' w ON w.title_fp = t.clean_fp
        WHERE NOT EXISTS (
            SELECT 1 FROM '{paths.table("works")}' r WHERE r.title_fp = t.raw_fp
        )
        GROUP BY 1, 2, 3
        ORDER BY works
        """
    ).fetchall()
    con.close()

    counts["gain_a_candidate"] = len(gained)
    if out_path:
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        Path(out_path).write_text(
            "\n".join(
                json.dumps(
                    {"book_id": b, "title": t, "stripped_fp": fp, "ol_works": n},
                    ensure_ascii=False,
                )
                for b, t, fp, n in gained
            )
            + "\n",
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
    total = counts["books"]
    typer.echo(f"exported books: {total:,}\n")
    for name in ("title_repeats_subtitle", "trailing_volume", "date_range", "fingerprint_changes"):
        n = counts.get(name, 0)
        typer.echo(f"  {name:<24} {n:>8,}  ({n / total:5.2%})")
    gained = counts["gain_a_candidate"]
    typer.echo(f"\n  books with no title_fp work today that gain one: {gained:,}")
    if out:
        typer.echo(f"wrote them to {out}")


if __name__ == "__main__":
    app()
