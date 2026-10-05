"""A seeded review sheet for spot-checking researched labels.

Markdown with Open Library links, so a reviewer opens each labelled work in a
browser and marks the row right or wrong. No colour: meaning is in words.
"""

from __future__ import annotations

import random
from pathlib import Path

import typer

from openlibrary.eval.dataset import WorkFacts, fetch_work_facts, load_cases
from openlibrary.eval.schema import EvalCase
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)


def sample_cases(
    cases: list[EvalCase], *, stratum: str | None, with_alternates: bool, n: int, seed: int
) -> list[EvalCase]:
    pool = [
        c
        for c in sorted(cases, key=lambda c: c.case_id)
        if (stratum is None or c.stratum == stratum)
        and (not with_alternates or c.label.alternate_work_keys)
    ]
    random.Random(seed).shuffle(pool)
    return sorted(pool[:n], key=lambda c: c.case_id)


def _work(key: str | None, facts: dict[str, WorkFacts]) -> str:
    if not key:
        return "—"
    f = facts.get(key)
    detail = f"{f.title} / {', '.join(f.author_names)} ({f.edition_count} editions)" if f else "?"
    return f"[{key}](https://openlibrary.org/works/{key}) {detail}"


def render_sheet(cases: list[EvalCase], facts: dict[str, WorkFacts]) -> str:
    lines = [
        "Mark each row RIGHT or WRONG in the last column. WRONG: write the right key or 'none'.",
        "",
        "| case | query | verdict | labelled work | alternates | right? |",
        "|---|---|---|---|---|---|",
    ]
    for c in cases:
        query = f"{c.book.title} / {', '.join(c.book.author_names)}"
        alternates = "<br>".join(_work(k, facts) for k in c.label.alternate_work_keys) or "—"
        lines.append(
            f"| {c.case_id} | {query} | {c.label.verdict} | {_work(c.label.work_key, facts)} | "
            f"{alternates} | |"
        )
    return "\n".join(lines) + "\n"


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option("2026-07-31", "--dump-date"),
    stratum: str | None = typer.Option(None, "--stratum"),
    with_alternates: bool = typer.Option(False, "--with-alternates"),
    n: int = typer.Option(30, "--n"),
    seed: int = typer.Option(20261004, "--seed"),
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    from openlibrary.pipeline.duck import connect

    chosen = sample_cases(
        load_cases(), stratum=stratum, with_alternates=with_alternates, n=n, seed=seed
    )
    keys = [k for c in chosen for k in (c.label.work_key, *c.label.alternate_work_keys) if k]
    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    facts = fetch_work_facts(con, paths, keys)
    con.close()
    out.write_text(render_sheet(chosen, facts))
    typer.echo(f"wrote {len(chosen)} cases to {out}")


if __name__ == "__main__":
    app()
