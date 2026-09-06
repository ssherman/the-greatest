"""The labeling CLI.

Rendering and choice parsing are pure functions so the tool is testable without
a terminal; only `main` touches stdin.

No ANSI colour anywhere. Meaning is carried by symbols, position and words --
a green tick and a red cross that differ only in hue carry no information to a
red-green colour-blind reader.

The `[k]` escape hatch matters more than it looks: if the only work keys this
set ever contains are ones a blocking rule already produced, then candidate
recall measured on it is 100% by construction. `[k]` is how a human finds a
match the blocking rules missed, and `EvalCase.found_outside_blocking` is
computed from exactly that.
"""

from __future__ import annotations

import datetime
import json
import re
from dataclasses import dataclass
from pathlib import Path

import typer

from openlibrary.eval.build_pool import PoolEntry, _identifier_pairs
from openlibrary.eval.schema import IDENTITY_RULES, EvalCandidate, EvalCase, EvalLabel
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

_WORK_KEY = re.compile(r"^OL\d+W$")


MAX_EDITIONS_SHOWN = 4
MAX_IDENTIFIERS_SHOWN = 3


@dataclass(frozen=True)
class EditionRow:
    """One Open Library edition under a candidate work.

    The edition list is the evidence. Work-level fields are summaries and have
    misled on this stratum three times: `min_ed` read as a publication date, a
    work title read as a canonical title, and a work that looked like a clean
    duplicate until its editions showed one subtitled `Volume 2`.
    """

    edition_key: str
    title: str | None = None
    subtitle: str | None = None
    publish_year: int | None = None
    publisher: str | None = None
    language_code: str | None = None
    page_count: int | None = None

    def describe(self) -> str:
        bits = [str(self.publish_year or "????"), (self.publisher or "(no publisher)")[:20]]
        if self.language_code:
            bits.append(f"({self.language_code})")
        if self.page_count:
            bits.append(f"{self.page_count}pp")
        return " ".join(bits)


@dataclass(frozen=True)
class CandidateDetail:
    """Curation signals the pool does not carry.

    `revision` and the spread of identifier types are what separate two OL
    works that are the same book, and neither is in `PoolCandidate`. They are
    read from the artifact at start-up rather than baked into the pool, so the
    pool -- and every case id already labelled against it -- stays untouched.
    """

    revision: int = 0
    last_modified: str | None = None
    id_types: int = 0


@dataclass(frozen=True)
class Choice:
    kind: str  # candidate | manual_key | no_match | ambiguous | skip | quit | invalid
    work_key: str | None = None


def render_case(
    entry: PoolEntry,
    *,
    index: int,
    total: int,
    details: dict[str, CandidateDetail] | None = None,
    id_hits: dict[str, list[str]] | None = None,
    editions: dict[str, list[EditionRow]] | None = None,
    matched_editions: set[str] | None = None,
) -> str:
    book = entry.book
    lines = [
        "",
        "=" * 78,
        f"[{index}/{total}]  stratum={entry.stratum}  case={entry.case_id}",
        "",
        f"OURS   #{book.book_id}  {book.title!r}"
        + (f" -- {book.subtitle!r}" if book.subtitle else ""),
        f"       authors: {', '.join(book.author_names) or '(none)'}",
        f"       year: {book.first_published_year or '(unknown)'}",
    ]
    # Every type, and a count when the list is clipped. `isbn10` used to be
    # omitted entirely and the others capped silently at three, which hid that
    # book #35370 carries ISBNs for TWO different books -- Library of America
    # Lincoln volume 1 AND volume 2 -- and that the stray one was what pulled
    # two volume-2 works into the candidate list.
    for name, values in (
        ("isbn13", book.isbn13),
        ("isbn10", book.isbn10),
        ("goodreads", book.goodreads_id),  # [GOODREADS]
        ("asin", book.asin),
    ):
        if not values:
            continue
        shown = ",".join(values[:MAX_IDENTIFIERS_SHOWN])
        extra = len(values) - MAX_IDENTIFIERS_SHOWN
        lines.append(f"       {name}={shown}" + (f"  +{extra} more" if extra > 0 else ""))
    if book.existing_ol_work_keys:
        lines.append(
            "       stored OL key(s): "
            + ", ".join(book.existing_ol_work_keys)
            + "   [UNTRUSTED -- do not treat as the answer: 9.9% are dead, 380 are shared]"
        )

    # Flush left, unquoted, alone on its line: a triple-click copies the query
    # and nothing else. Every `no_candidates` verdict depends on a hand search
    # of Open Library, and the block above is laid out to be read, not copied.
    search_query = book.title
    if book.author_names:
        search_query += " by " + ", ".join(book.author_names)
    lines += ["", search_query]

    lines.append("")
    if not entry.candidates:
        lines.append("CANDIDATES  (none -- no blocking rule produced anything)")
    else:
        lines.append("CANDIDATES")
    for position, candidate in enumerate(entry.candidates, start=1):
        lines.append(f" [{position}] {candidate.work_key}  {candidate.title!r}")
        lines.append(f"     authors: {', '.join(candidate.author_names) or '(none)'}")
        lines.append(
            f"     years: declared={candidate.declared_year} "
            f"min_ed={candidate.min_edition_year} modal={candidate.modal_edition_year} "
            f"({candidate.edition_count} eds)"
        )
        lines.append(
            f"     signal: readinglog={candidate.readinglog_count} "
            f"ratings={candidate.ratings_count} title_fp_freq={candidate.title_fp_freq}"
        )
        lines.append(f"     rules: {', '.join(candidate.rules)}")
        if id_hits is not None:
            reached = id_hits.get(candidate.work_key) or []
            lines.append(f"     our ids: {', '.join(reached) if reached else 'none'}")
        if editions is not None:
            rows = editions.get(candidate.work_key) or []
            shown = rows[:MAX_EDITIONS_SHOWN]
            for position_row, row in enumerate(shown):
                mark = "*" if row.edition_key in (matched_editions or set()) else " "
                label = "     editions:" if position_row == 0 else "              "
                title = (row.title or "")[:40]
                lines.append(f"{label} {mark} {row.edition_key:<13} {title:<42} {row.describe()}")
                # A subtitle gets its own line rather than a share of a clipped
                # one. `The Lightning Saga - Volume 2 (Justice League of
                # America) (Graphic Novels)` is the only thing separating
                # volume 2 from volume 1, and it sits in the middle of the
                # string -- clipping either end loses it.
                if row.subtitle:
                    lines.append(f"                    subtitle: {row.subtitle[:96]}")
            if len(rows) > MAX_EDITIONS_SHOWN:
                lines.append(f"                +{len(rows) - MAX_EDITIONS_SHOWN} more")
        if details is not None:
            detail = details.get(candidate.work_key, CandidateDetail())
            lines.append(
                f"     curation: rev={detail.revision} id_types={detail.id_types}"
                f" modified={detail.last_modified or '(unknown)'}"
            )
        lines.append(f"     https://openlibrary.org/works/{candidate.work_key}")
    # A 20-candidate case renders ~136 lines, so the detail for candidate [1] has
    # scrolled off long before the prompt. Repeat the choices compactly here so
    # the final screen is self-sufficient and nobody has to scroll back mid-decision.
    if entry.candidates:
        lines += ["", "CHOOSE  (detail above; this repeats it in one line each)"]
        for position, candidate in enumerate(entry.candidates, start=1):
            title = (candidate.title or "")[:44]
            detail = (details or {}).get(candidate.work_key, CandidateDetail())
            lines.append(
                f" [{position:>2}] {candidate.work_key:<13} {title:<44} "
                f"{candidate.edition_count:>3} eds rl={candidate.readinglog_count:<3}"
                f" rev={detail.revision:<3} ids={detail.id_types}"
            )
        if details is not None:
            lines += [
                "",
                "  Work down:",
                "   (1) keep only the candidates 'our ids' reaches. If none does, keep all.",
                "   (2) among those, decide which are the same book. That part is yours.",
                "   (3) break the tie on higher rev, then more ids.",
                "  A candidate matched by title_fp alone is often a different book that",
                "  happens to share the title -- check title_fp_freq before reading",
                "  anything into a long list.",
            ]

    upper = len(entry.candidates)
    pick = f"  [1-{upper}] pick a candidate" if upper else "  (no candidates to pick)"
    lines += [
        "",
        f"{pick:<30}[n] no match in Open Library",
        "  [a] ambiguous                 [k <WORK_KEY>] enter a key no rule produced --",
        "  [s] skip                      [q] save and quit    this is the ONLY way a",
        "                                                     recall failure gets recorded",
    ]
    return "\n".join(lines)


def parse_choice(raw: str, entry: PoolEntry) -> Choice:
    value = (raw or "").strip()
    if not value:
        return Choice("invalid")
    head, _, rest = value.partition(" ")
    head = head.lower()

    if head.isdigit():
        position = int(head)
        if 1 <= position <= len(entry.candidates):
            return Choice("candidate", entry.candidates[position - 1].work_key)
        return Choice("invalid")
    if head == "k":
        key = rest.strip().upper()
        return Choice("manual_key", key) if _WORK_KEY.match(key) else Choice("invalid")
    return {
        "n": Choice("no_match"),
        "a": Choice("ambiguous"),
        "s": Choice("skip"),
        "q": Choice("quit"),
    }.get(head, Choice("invalid"))


def candidates_shown_for(entry: PoolEntry) -> list[EvalCandidate]:
    """Build `EvalCase.candidates_shown` from the COMPLETE generated set.

    Deliberately built from `entry.all_generated`, NOT `entry.candidates`.
    `entry.candidates` is capped at 20 -- all the terminal can usefully render
    -- but `found_outside_blocking` must know whether a manually-entered key
    was ever produced by blocking AT ALL, including at rank 21+. Using the
    capped list here would misrecord a key blocking produced but did not
    display as a recall failure that never happened. Do not "simplify" this
    back to `entry.candidates`.
    """
    return [EvalCandidate(work_key=c.work_key, rules=c.rules) for c in entry.all_generated]


def already_labeled(out_path: Path) -> set[str]:
    path = Path(out_path)
    if not path.exists():
        return set()
    return {
        json.loads(line)["case_id"]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def append_case(out_path: Path, case: EvalCase) -> None:
    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(case.model_dump_json() + "\n")


def default_rationale(entry: PoolEntry, *, verdict: str, work_key: str | None, rule: str) -> str:
    """A factual rationale the labeller accepts with Enter, or "" to make them type.

    Every label carries a rationale of at least 10 characters -- that is a
    schema rule and it does not change here. What changes is that on a case
    whose reasoning is entirely derivable from the case itself, the labeller
    does not have to retype it 450 times. The text below states the evidence
    rather than pretending to be reasoning.

    Two verdicts get no default, because for them the reasoning is the whole
    point and a machine-written one would be a fabrication: `ambiguous`, which
    is a judgement call by definition, and a work key no rule produced, which
    is the only evidence of a candidate-recall failure the set will contain.

    A default states evidence; pressing Enter is the labeller vouching for it.
    Overtype it whenever the case took real work -- a search under a different
    title or language is worth a sentence the next reader cannot reconstruct.
    """
    if verdict == "no_match":
        if not entry.candidates:
            # The `no_candidates` stratum, where nothing was rejected because
            # nothing was offered. The verdict rests entirely on the labeller
            # searching Open Library by hand, so that is what gets recorded --
            # counting an empty list would credit evidence that does not exist.
            return "no blocking rule produced a candidate; searched Open Library, no matching work"
        return f"none of the {len(entry.candidates)} candidates shown is this book"
    if verdict == "match" and work_key:
        candidate = next((c for c in entry.candidates if c.work_key == work_key), None)
        if candidate:
            agreed = ", ".join(candidate.rules)
            if rule == "same_work":
                return f"same work; blocking rules that agreed: {agreed}"
            if rule == "duplicate_work":
                return (
                    f"OL holds this book as more than one work; picked {work_key} of the "
                    f"{len(entry.candidates)} candidates shown; rules that agreed: {agreed}"
                )
    # Every other rule asserts a RELATIONSHIP between two different things --
    # a translation of, a part of, an adaptation of. The evidence for that is
    # not derivable from the case, so it gets typed.
    return ""


def fetch_identifier_hits(
    root: Path, dump_date: str, entries: list[PoolEntry]
) -> dict[str, dict[str, list[str]]] | None:
    """Which of OUR identifiers reach each candidate, per case.

    The pool records that the `identifier` rule fired, never which identifier
    or how many, and that difference decides most of this stratum: on case
    isbn_reuse-013 all three of our ISBNs and our Goodreads id land on
    OL521324W while nothing of ours touches the record with the matching
    declared year.

    One query for the whole pool. Returns None when the artifact is absent.
    """
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    if not paths.table("identifiers").exists():
        return None
    pairs = [
        (entry.case_id, id_type, value)
        for entry in entries
        for id_type, value in _identifier_pairs(entry.book)
    ]
    wanted = [(entry.case_id, c.work_key) for entry in entries for c in entry.candidates]
    if not pairs or not wanted:
        return {}
    con = connect(paths, memory_limit="4GB")
    try:
        con.execute("CREATE TABLE ours (case_id VARCHAR, id_type VARCHAR, value VARCHAR)")
        con.executemany("INSERT INTO ours VALUES (?,?,?)", pairs)
        con.execute("CREATE TABLE cands (case_id VARCHAR, work_key VARCHAR)")
        con.executemany("INSERT INTO cands VALUES (?,?)", wanted)
        rows = con.execute(
            f"""
            SELECT c.case_id, c.work_key, list(DISTINCT o.id_type ORDER BY o.id_type)
            FROM cands c
            JOIN ours o USING (case_id)
            JOIN '{paths.table("identifiers")}' i
              ON i.id_type = o.id_type AND i.value = o.value
             AND i.work_key = c.work_key
            GROUP BY 1, 2
            """
        ).fetchall()
    finally:
        con.close()
    hits: dict[str, dict[str, list[str]]] = {case: {} for case, _ in wanted}
    for case_id, work_key, id_types in rows:
        hits[case_id][work_key] = list(id_types)
    return hits


def fetch_edition_rows(
    root: Path, dump_date: str, work_keys: list[str]
) -> dict[str, list[EditionRow]] | None:
    """Every edition under each candidate work. One query for the whole pool."""
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    if not paths.table("editions").exists() or not work_keys:
        return None
    con = connect(paths, memory_limit="4GB")
    try:
        con.execute("CREATE TABLE wanted (work_key VARCHAR)")
        con.executemany("INSERT INTO wanted VALUES (?)", [(k,) for k in work_keys])
        rows = con.execute(
            f"""
            SELECT e.work_key, e.edition_key, e.title, e.subtitle, e.publish_year,
                   e.publisher, e.language_code, e.page_count
            FROM wanted k
            JOIN '{paths.table("editions")}' e USING (work_key)
            ORDER BY e.work_key, e.publish_year NULLS LAST, e.edition_key
            """
        ).fetchall()
    finally:
        con.close()
    out: dict[str, list[EditionRow]] = {}
    for work_key, edition_key, title, subtitle, year, publisher, lang, pages in rows:
        out.setdefault(work_key, []).append(
            EditionRow(
                edition_key=edition_key,
                title=title,
                subtitle=subtitle,
                publish_year=year,
                publisher=publisher,
                language_code=lang,
                page_count=pages,
            )
        )
    return out


def fetch_matched_editions(
    root: Path, dump_date: str, entries: list[PoolEntry]
) -> dict[str, set[str]] | None:
    """Which EDITION carries the identifier, not just which work.

    Both candidates on isbn_reuse-024 showed the same three identifier types.
    The difference was that one held them on the Atlas Press 1985 printing the
    ISBN actually names and the other had them wrongly attached to a Serpent's
    Tail edition -- invisible at work level.
    """
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    if not paths.table("identifiers").exists():
        return None
    pairs = [
        (entry.case_id, id_type, value)
        for entry in entries
        for id_type, value in _identifier_pairs(entry.book)
    ]
    if not pairs:
        return {}
    con = connect(paths, memory_limit="4GB")
    try:
        con.execute("CREATE TABLE ours2 (case_id VARCHAR, id_type VARCHAR, value VARCHAR)")
        con.executemany("INSERT INTO ours2 VALUES (?,?,?)", pairs)
        rows = con.execute(
            f"""
            SELECT o.case_id, i.edition_key
            FROM ours2 o
            JOIN '{paths.table("identifiers")}' i
              ON i.id_type = o.id_type AND i.value = o.value
            WHERE i.edition_key IS NOT NULL
            GROUP BY 1, 2
            """
        ).fetchall()
    finally:
        con.close()
    out: dict[str, set[str]] = {}
    for case_id, edition_key in rows:
        out.setdefault(case_id, set()).add(edition_key)
    return out


def fetch_candidate_details(
    root: Path, dump_date: str, work_keys: list[str]
) -> dict[str, CandidateDetail] | None:
    """Read revision and identifier spread for every candidate, once.

    One query for the whole pool rather than one per case: the three scans cost
    about half a second together, because DuckDB prunes parquet row groups by
    work key. Returns None when the artifact is not mounted, and the tool
    renders exactly as it did before.
    """
    if not work_keys:
        return {}
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    if not paths.table("works").exists():
        return None
    con = connect(paths, memory_limit="4GB")
    try:
        con.execute("CREATE TABLE wanted (work_key VARCHAR)")
        con.executemany("INSERT INTO wanted VALUES (?)", [(k,) for k in work_keys])
        rows = con.execute(
            f"""
            -- last_modified is a DATE, so the cast is already yyyy-mm-dd and
            -- nothing here trims it.
            SELECT w.work_key, w.revision, CAST(w.last_modified AS VARCHAR),
                   coalesce(i.n, 0)
            FROM wanted k
            JOIN '{paths.table("works")}' w USING (work_key)
            LEFT JOIN (
                SELECT work_key, count(DISTINCT id_type) AS n
                FROM '{paths.table("identifiers")}'
                WHERE work_key IS NOT NULL GROUP BY 1
            ) i USING (work_key)
            """
        ).fetchall()
    finally:
        con.close()
    return {
        key: CandidateDetail(revision=rev or 0, last_modified=mod, id_types=n)
        for key, rev, mod, n in rows
    }


def _prompt_identity_rule() -> str:
    typer.echo("  identity rule:")
    for position, rule in enumerate(IDENTITY_RULES, start=1):
        typer.echo(f"    [{position}] {rule}")
    while True:
        raw = typer.prompt("  rule").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(IDENTITY_RULES):
            return IDENTITY_RULES[int(raw) - 1]
        if raw in IDENTITY_RULES:
            return raw
        typer.echo("  not a rule; pick a number from the list")


@app.command()
def main(
    pool: Path = typer.Option(..., "--pool"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
    dump_date: str = typer.Option("2026-07-31", "--dump-date"),
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    stratum: str | None = typer.Option(None, "--stratum"),
) -> None:
    entries = [
        PoolEntry.model_validate_json(line)
        for line in pool.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if stratum:
        entries = [e for e in entries if e.stratum == stratum]
    details = fetch_candidate_details(
        root, dump_date, sorted({c.work_key for e in entries for c in e.candidates})
    )
    id_hits = fetch_identifier_hits(root, dump_date, entries)
    editions = fetch_edition_rows(
        root, dump_date, sorted({c.work_key for e in entries for c in e.candidates})
    )
    matched_editions = fetch_matched_editions(root, dump_date, entries)
    done = already_labeled(out)
    remaining = [e for e in entries if e.case_id not in done]
    typer.echo(f"{len(done)} already labeled, {len(remaining)} to go")

    for offset, entry in enumerate(remaining, start=1):
        typer.echo(
            render_case(
                entry,
                index=len(done) + offset,
                total=len(entries),
                details=details,
                id_hits=None if id_hits is None else id_hits.get(entry.case_id, {}),
                editions=editions,
                matched_editions=(
                    None if matched_editions is None else matched_editions.get(entry.case_id, set())
                ),
            )
        )
        while True:
            choice = parse_choice(typer.prompt("  choice"), entry)
            if choice.kind == "invalid":
                typer.echo("  not a valid choice")
                continue
            break

        if choice.kind == "quit":
            typer.echo("saved; rerun with the same --out to resume")
            return
        if choice.kind == "skip":
            continue

        if choice.kind == "no_match":
            verdict, work_key, rule = "no_match", None, "not_in_open_library"
        elif choice.kind == "ambiguous":
            verdict, work_key = "ambiguous", None
            rule = _prompt_identity_rule()
        else:
            verdict, work_key = "match", choice.work_key
            rule = _prompt_identity_rule()

        suggested = default_rationale(entry, verdict=verdict, work_key=work_key, rule=rule)
        rationale = ""
        while len(rationale) < 10:
            if suggested:
                rationale = typer.prompt(
                    "  rationale (enter to accept)", default=suggested, show_default=True
                ).strip()
            else:
                rationale = typer.prompt("  rationale (one line, >= 10 chars)").strip()

        append_case(
            out,
            EvalCase(
                case_id=entry.case_id,
                stratum=entry.stratum,
                book=entry.book,
                candidates_shown=candidates_shown_for(entry),
                label=EvalLabel(
                    verdict=verdict,
                    work_key=work_key,
                    identity_rule=rule,
                    rationale=rationale,
                    labeled_at=datetime.date.today(),
                    labeled_against_dump_date=dump_date,
                ),
            ),
        )
        if choice.kind == "manual_key":
            typer.echo("  recorded as found outside blocking -- this is a recall failure case")


if __name__ == "__main__":
    app()
