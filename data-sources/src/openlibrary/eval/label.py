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

from openlibrary.eval.build_pool import PoolEntry
from openlibrary.eval.schema import IDENTITY_RULES, EvalCandidate, EvalCase, EvalLabel

app = typer.Typer(add_completion=False)

_WORK_KEY = re.compile(r"^OL\d+W$")


@dataclass(frozen=True)
class Choice:
    kind: str  # candidate | manual_key | no_match | ambiguous | skip | quit | invalid
    work_key: str | None = None


def render_case(entry: PoolEntry, *, index: int, total: int) -> str:
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
    identifier_bits = []
    if book.isbn13:
        identifier_bits.append(f"isbn13={','.join(book.isbn13[:3])}")
    if book.goodreads_id:
        identifier_bits.append(f"goodreads={','.join(book.goodreads_id[:3])}")  # [GOODREADS]
    if book.asin:
        identifier_bits.append(f"asin={','.join(book.asin[:3])}")
    if identifier_bits:
        lines.append("       " + "  ".join(identifier_bits))
    if book.existing_ol_work_keys:
        lines.append(
            "       stored OL key(s): "
            + ", ".join(book.existing_ol_work_keys)
            + "   [UNTRUSTED -- do not treat as the answer: 9.9% are dead, 380 are shared]"
        )

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
        lines.append(f"     https://openlibrary.org/works/{candidate.work_key}")
    # A 20-candidate case renders ~136 lines, so the detail for candidate [1] has
    # scrolled off long before the prompt. Repeat the choices compactly here so
    # the final screen is self-sufficient and nobody has to scroll back mid-decision.
    if entry.candidates:
        lines += ["", "CHOOSE  (detail above; this repeats it in one line each)"]
        for position, candidate in enumerate(entry.candidates, start=1):
            title = (candidate.title or "")[:52]
            lines.append(
                f" [{position:>2}] {candidate.work_key:<13} {title:<52} "
                f"{candidate.edition_count:>4} eds  rl={candidate.readinglog_count}"
            )

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
    stratum: str | None = typer.Option(None, "--stratum"),
) -> None:
    entries = [
        PoolEntry.model_validate_json(line)
        for line in pool.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if stratum:
        entries = [e for e in entries if e.stratum == stratum]
    done = already_labeled(out)
    remaining = [e for e in entries if e.case_id not in done]
    typer.echo(f"{len(done)} already labeled, {len(remaining)} to go")

    for offset, entry in enumerate(remaining, start=1):
        typer.echo(render_case(entry, index=len(done) + offset, total=len(entries)))
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

        rationale = ""
        while len(rationale) < 10:
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
