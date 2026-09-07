"""Sort eval cases into ones a machine may settle and ones that need Shane.

Hand-labelling 450 cases has taken days, and most of that time went to cases
that were never in doubt: our ISBN lands on exactly one Open Library work, that
work is already on screen, and the answer is `same_work`. Measured against the
204 labels Shane made by hand, that shape agreed with him 77 times in 79.

The rest of the time went somewhere else entirely. Where nothing of ours
reaches Open Library and blocking produced no candidate, his label agreed with
"not in Open Library" only 38 times in 57. The other 19 were books that ARE
there -- `My Hero Academia, Vol. 2` under its english title, `Vládce Klanů` as
`Lord of the Clans` -- reachable only by a search no blocking rule performs.

So this module routes; it does not decide the hard cases. Auto-answering the
second bucket would have written 19 false negatives into the one artifact that
cannot be regenerated.
"""

from __future__ import annotations

import datetime
import json
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import typer

from common.normalize import MIN_BLOCKING_FP_LENGTH, name_fingerprint, title_fingerprints
from openlibrary.eval.build_pool import PoolCandidate, PoolEntry, _identifier_pairs
from openlibrary.eval.schema import EvalBook
from openlibrary.pipeline.paths import ArtifactPaths

# Strata where the identifier rule has a measured failure. Shane overrode the
# identifier on anthology_or_collection-002 (Synge's Collected Plays: the id
# reached OL15206548W, he chose OL31748277W because its subtitle enumerated the
# plays his edition actually holds) and on -004. Both are collections, where
# "which OL work is this collection" is a judgement about contents rather than
# a lookup. high_frequency_title -- "selected poems", "collected works" -- is
# the same shape, so the rule is not extrapolated into it.
JUDGEMENT_STRATA = frozenset({"anthology_or_collection", "high_frequency_title"})

BUCKETS = ("decisive_match", "needs_human")

# A title only corroborates when the shorter fingerprint is long enough to
# block on AND is most of the longer one. Both halves are load-bearing, and
# both come from cases this shipped wrongly: `1` (non_latin_title-013) passed
# a bare substring test and is shared by 1,675 OL works, while `america`
# inside `america the book` (shared_key_collision-023) is long enough yet only
# 44% of it, and they are different books. `the women could fly` against
# `women could fly` is 79% and has to survive, which brackets the threshold.
MIN_TITLE_OVERLAP = 0.6


@dataclass(frozen=True)
class IdentifierReach:
    """What our stored identifiers actually reach in Open Library.

    `absent` and `orphaned` are counts rather than a single "missing" flag
    because they mean different things: absent is a book Open Library does not
    hold under that number, orphaned is one it holds on an edition with no work
    key -- 1,947,922 such editions exist, and blocking cannot see any of them.
    """

    works: frozenset[str]
    absent: int = 0
    orphaned: int = 0


@dataclass(frozen=True)
class Triage:
    bucket: str
    reason: str
    work_key: str | None = None
    identity_rule: str | None = None


def corroborated(book: EvalBook, candidate: PoolCandidate) -> bool:
    """Does anything OTHER than the identifier agree?

    An identifier is a claim, not a proof. Book #24233's ISBN really does sit
    on `the official 2012 blackbook price guide` -- a different year of an
    annual, by a different Hudgeons -- and our row is the 1960 one. Requiring a
    second, independent signal is what separates that from a genuine hit.

    Author agreement reuses the audit's classifier rather than comparing
    fingerprint sets, because `Feng Jicai` against `jicai feng` is the same
    person and a set comparison says otherwise. `surname_collision` is
    deliberately NOT accepted: that class means the wrong person 10,607 times
    over in this catalogue, and accepting it would corroborate precisely the
    failure this exists to catch.

    A matching YEAR is not accepted at all, on measured evidence. It was, and
    it shipped a false merge: Pamela Anderson's `I Love You` (2024) carries an
    isbn13 that Open Library holds on `New Cookbook by Paul Anthony` -- three
    editions, all 2024 -- so `2024 <= 2024 <= 2024` proposed her memoir as a
    Paul Anthony cookbook. With one distinct year the test degenerates to
    "published the same year". Two of 73 proposals rested on it alone and one
    was that, so the limb is gone rather than weakened; author and title each
    still stand alone.
    """
    from openlibrary.audit.authors import classify_disagreement

    ours_a = [name_fingerprint(n) for n in book.author_names]
    theirs_a = [name_fingerprint(n) for n in candidate.author_names]
    agreeing = {"agrees", "name_order", "name_subset"}
    if any(ours_a) and any(theirs_a) and classify_disagreement(ours_a, theirs_a) in agreeing:
        return True

    ours_t = title_fingerprints(book.title).full
    theirs_t = title_fingerprints(candidate.title or "").full
    if ours_t and theirs_t:
        short, long_ = sorted((ours_t, theirs_t), key=len)
        if (
            len(short) >= MIN_BLOCKING_FP_LENGTH
            and short in long_
            and len(short) / len(long_) >= MIN_TITLE_OVERLAP
        ):
            return True

    return False


def triage(
    *,
    stratum: str,
    candidate_keys: Sequence[str],
    reach: IdentifierReach,
    corroborates: bool = False,
) -> Triage:
    """Decide whether this case can be proposed automatically.

    Pure: every fact it needs is already gathered. That is what lets the rule
    be re-measured against the labels Shane has already written whenever it
    changes.

    `corroborates` defaults to False so a caller that forgets it loses a
    proposal rather than gaining an unchecked one. The two mistakes do not
    cost the same: a missed proposal is one more case for Shane to read, an
    unchecked one writes a false merge into ground truth that cannot be
    regenerated.
    """
    shown = set(candidate_keys)

    if len(reach.works) > 1:
        return Triage(
            "needs_human",
            f"our identifiers reach {len(reach.works)} different works; picking one is a judgement",
        )

    if reach.works:
        (work_key,) = reach.works
        if work_key not in shown:
            return Triage(
                "needs_human",
                f"our identifiers reach {work_key}, which blocking never surfaced -- "
                "usually a wrong identifier on our side",
            )
        if stratum in JUDGEMENT_STRATA:
            return Triage(
                "needs_human",
                f"{stratum} is a collection stratum; the identifier names an edition, "
                "not which work is the collection",
            )
        if not corroborates:
            return Triage(
                "needs_human",
                f"our identifiers reach {work_key}, but nothing corroborates it -- "
                "no author, title or year agreement",
            )
        return Triage(
            "decisive_match",
            f"our identifiers reach exactly one work ({work_key}) and it is on screen",
            work_key=work_key,
            identity_rule="same_work",
        )

    if shown:
        return Triage(
            "needs_human",
            f"{len(shown)} candidates, none of them reached by any identifier of ours",
        )

    return Triage(
        "needs_human",
        f"nothing reachable: {reach.absent} identifiers absent from OL, "
        f"{reach.orphaned} on editions with no work, and blocking found nothing -- "
        "one in three of these is in OL under another title",
    )


def fetch_identifier_reach(
    root: Path, dump_date: str, entries: Sequence[PoolEntry]
) -> dict[str, IdentifierReach] | None:
    """Resolve every stored identifier against Open Library, once for the pool.

    Deliberately wider than `label.fetch_identifier_hits`, which only asks
    whether an identifier reaches a work already on the candidate list. The
    interesting failures are the ones off that list: von Baer's ISBN belongs to
    a different book entirely, and an identifier sitting on an edition with no
    work key is invisible to blocking however correct it is. Both have to be
    distinguishable from "Open Library has never heard of this number".

    Returns None when the artifact is not mounted.
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
    reach: dict[str, IdentifierReach] = {e.case_id: IdentifierReach(frozenset()) for e in entries}
    if not pairs:
        return reach
    con = connect(paths, memory_limit="4GB")
    try:
        con.execute("CREATE TABLE ours (case_id VARCHAR, id_type VARCHAR, value VARCHAR)")
        con.executemany("INSERT INTO ours VALUES (?,?,?)", pairs)
        rows = con.execute(
            f"""
            SELECT o.case_id,
                   list(DISTINCT i.work_key) FILTER (WHERE i.work_key IS NOT NULL),
                   count(*) FILTER (WHERE i.value IS NULL),
                   count(*) FILTER (WHERE i.value IS NOT NULL AND i.work_key IS NULL)
            FROM ours o
            LEFT JOIN '{paths.table("identifiers")}' i
              ON i.id_type = o.id_type AND i.value = o.value
            GROUP BY 1
            """
        ).fetchall()
    finally:
        con.close()
    for case_id, works, absent, orphaned in rows:
        reach[case_id] = IdentifierReach(frozenset(works or []), int(absent), int(orphaned))
    return reach


def blocking_produced(entry: PoolEntry) -> set[str]:
    """Every work key blocking generated, not just the 20 the CLI renders.

    `PoolEntry.candidates` is capped for terminal display. Judging "blocking
    never surfaced this work" against the capped list would call a key that
    blocking did produce -- just at position 21 -- a wrong identifier.
    """
    return {c.work_key for c in entry.candidates} | {g.work_key for g in entry.all_generated}


def _proposed_case(entry: PoolEntry, t: Triage, dump_date: str) -> dict:
    """An EvalCase the labels file would accept, stamped as machine-written.

    Written to its own file rather than appended to cases/labels.jsonl. The
    value of that file is that a human who knows this catalogue decided every
    row; merging unreviewed proposals into it would spend that in one command,
    and no later measurement could tell which rows were which.
    """
    from openlibrary.eval.schema import EvalCase, EvalLabel

    shown = ", ".join(sorted(c.work_key for c in entry.candidates))
    case = EvalCase(
        case_id=entry.case_id,
        stratum=entry.stratum,
        book=entry.book,
        candidates_shown=[{"work_key": c.work_key, "rules": c.rules} for c in entry.candidates],
        label=EvalLabel(
            verdict="match",
            work_key=t.work_key,
            identity_rule=t.identity_rule,
            rationale=(
                f"PROPOSED, unreviewed: {t.reason}. Candidates blocking produced: {shown or 'none'}"
            ),
            labeled_at=datetime.date.today(),
            labeled_against_dump_date=dump_date,
            labeled_by="agent",
        ),
    )
    return case.model_dump(mode="json")


def main(
    pool: Path = typer.Option(..., "--pool"),  # noqa: B008
    labels: Path = typer.Option(..., "--labels"),  # noqa: B008
    proposed: Path = typer.Option(..., "--proposed"),  # noqa: B008
    report: Path = typer.Option(..., "--report"),  # noqa: B008
    dump_date: str = typer.Option("2026-07-31", "--dump-date"),
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
) -> None:
    # proposed.open("w") truncates and report.write_text overwrites. Both
    # default to the directory holding labels.jsonl and one shares its
    # extension, so a mistyped flag would silently destroy 204 hand labels
    # that took days and have no other copy.
    if labels in (proposed, report) or proposed == report:
        typer.echo(
            f"refusing to write over {labels}: --proposed and --report must be "
            "distinct paths and neither may be --labels",
            err=True,
        )
        raise typer.Exit(2)

    entries = [PoolEntry(**json.loads(line)) for line in _read_lines(pool)]
    done: set[str] = set()
    if labels.exists():
        done = {json.loads(line)["case_id"] for line in _read_lines(labels)}
    todo = [e for e in entries if e.case_id not in done]

    reach = fetch_identifier_reach(root, dump_date, todo)
    if reach is None:
        typer.echo(f"no artifact under {root} for {dump_date}", err=True)
        raise typer.Exit(1)

    decided, human = [], []
    for entry in todo:
        r = reach[entry.case_id]
        # Only a candidate carries title/author/year, so a work reached solely
        # through `all_generated` cannot be corroborated and goes to the human.
        detailed = {c.work_key: c for c in entry.candidates}
        corroborates = any(
            corroborated(entry.book, detailed[key]) for key in r.works if key in detailed
        )
        t = triage(
            stratum=entry.stratum,
            candidate_keys=sorted(blocking_produced(entry)),
            reach=r,
            corroborates=corroborates,
        )
        (decided if t.bucket == "decisive_match" else human).append((entry, t))

    # Build the whole file before touching the destination: EvalCase validates
    # on construction, and truncating first would leave a half-written
    # proposals file behind if any row ever failed.
    proposed.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(
        json.dumps(_proposed_case(entry, t, dump_date), ensure_ascii=False) + "\n"
        for entry, t in decided
    )
    tmp = proposed.with_suffix(proposed.suffix + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    tmp.replace(proposed)

    by_stratum: dict[str, list] = {}
    for entry, t in human:
        by_stratum.setdefault(entry.stratum, []).append((entry, t))
    lines = [
        "# Cases that still need you",
        "",
        f"{len(todo)} unlabelled. {len(decided)} proposed automatically",
        f"(`{proposed}`, unreviewed). {len(human)} below.",
        "",
        "The split is measured, not assumed: on the 204 cases already labelled by hand,",
        "the proposed rule agreed 77/79, and every case below sits in a shape where it",
        "either failed or was never tested.",
        "",
    ]
    for stratum in sorted(by_stratum):
        rows = by_stratum[stratum]
        lines += [f"## {stratum} ({len(rows)})", ""]
        for entry, t in rows:
            b = entry.book
            fields = (
                ("isbn13", b.isbn13),
                ("isbn10", b.isbn10),
                ("asin", b.asin),
                ("goodreads", b.goodreads_id),
            )
            ids = ", ".join(f"{k}={v}" for k, v in fields if v)
            lines += [
                f"### {entry.case_id} — #{b.book_id} {b.title!r}",
                f"- authors: {', '.join(b.author_names) or '(none)'}"
                f"   year: {b.first_published_year}",
                f"- {ids or 'no identifiers'}",
                f"- **why you:** {t.reason}",
                f"- candidates: {len(entry.candidates)}",
            ]
            for c in entry.candidates[:6]:
                lines.append(
                    f"    - `{c.work_key}` {(c.title or '')[:52]!r} "
                    f"{c.edition_count} eds  rl={c.readinglog_count}  fp_freq={c.title_fp_freq}  "
                    f"[{', '.join(c.rules)}]"
                )
            lines.append("")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines), encoding="utf-8")

    typer.echo(f"{len(decided)} proposed -> {proposed}")
    typer.echo(f"{len(human)} need you   -> {report}")


def _read_lines(path: Path) -> list[str]:
    """Split on \\n only. `Path.read_text().splitlines()` also breaks on \\x85
    and \\u2028, which truncated a JSON record in this pool once already."""
    with path.open(encoding="utf-8", newline="\n") as fh:
        return [line for line in fh.read().split("\n") if line.strip()]


if __name__ == "__main__":
    typer.run(main)
