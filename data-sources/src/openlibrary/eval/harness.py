"""Run the matcher over the labeled set and report the five metrics.

False-merge rate is the one to watch: a wrong merge destroys data, an
abstention costs a review. Everything else is context for it.

Every comparison resolves both sides through redirects (`dataset.resolve_keys`),
so a label written against one dump and an answer produced from another do not
disagree merely because Open Library merged something.
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import typer
from pydantic import BaseModel, Field

from openlibrary.eval.dataset import load_cases, resolve_keys
from openlibrary.eval.schema import EvalCase
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.matcher.decide import Decision, decide, rank
from openlibrary.matcher.features import load_work_views
from openlibrary.matcher.scorer import Weights, load_weights, score_candidate
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

RECALL_AT = (5, 10, 50)


class CaseOutcome(BaseModel):
    case_id: str
    stratum: str
    expected_work_key: str | None
    expected_verdict: str
    decision: Decision
    candidate_rank: int | None = None
    correct: bool = False
    false_merge: bool = False


class Metrics(BaseModel):
    n_cases: int = 0
    n_accepted: int = 0
    n_no_match_cases: int = 0
    candidate_recall: dict[int, float] = Field(default_factory=dict)
    precision_at_accept: float = 0.0
    false_merge_rate: float = 0.0
    abstention_rate: float = 0.0
    correct_no_match_rate: float = 0.0


def _query_for(case: EvalCase) -> BlockingQuery:
    book = case.book
    return BlockingQuery(
        title=book.title,
        subtitle=book.subtitle,
        author_names=book.author_names,
        year=book.first_published_year,
        isbn13=book.isbn13,
        isbn10=book.isbn10,
        asin=book.asin,
        goodreads_id=book.goodreads_id,  # [GOODREADS]
        existing_ol_key=book.existing_ol_work_keys[0] if book.existing_ol_work_keys else None,
    )


def _same(resolved: dict[str, str], a: str | None, b: str | None) -> bool:
    """True when both keys resolve to the same terminal.

    Same semantics as `dataset.same_work`, computed against a redirect map
    that has already been fetched once for the whole case (ruling: one
    `resolve_keys` call per case, not one query per candidate).
    """
    return bool(a and b and resolved.get(a, a) == resolved.get(b, b))


def run(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: list[EvalCase],
    weights: Weights,
) -> tuple[Metrics, list[CaseOutcome]]:
    outcomes: list[CaseOutcome] = []
    recall_hits = dict.fromkeys(RECALL_AT, 0)
    n_positive = 0

    for case in cases:
        query = _query_for(case)
        blocking = generate_candidates(con, paths, query)
        identifier_hits = frozenset(
            k for k, rules in blocking.candidates.items() if "identifier" in rules
        )
        views = load_work_views(con, paths, list(blocking.candidates))
        scored = [
            score_candidate(query, views[key], rules, weights, identifier_hits=identifier_hits)
            for key, rules in blocking.candidates.items()
            if key in views
        ]
        ordered = rank(scored)
        decision = decide(scored, weights)

        expected = case.label.work_key
        resolved = resolve_keys(
            con,
            paths,
            [expected, *blocking.candidates] if expected else list(blocking.candidates),
        )

        candidate_rank: int | None = None
        if expected:
            n_positive += 1
            for position, candidate in enumerate(ordered, start=1):
                if _same(resolved, candidate.work_key, expected):
                    candidate_rank = position
                    break
            for k in RECALL_AT:
                if candidate_rank is not None and candidate_rank <= k:
                    recall_hits[k] += 1

        if case.label.verdict == "match":
            same_as_expected = _same(resolved, decision.work_key, expected)
            correct = decision.verdict == "accept" and same_as_expected
            false_merge = decision.verdict == "accept" and not correct
        elif case.label.verdict == "no_match":
            correct = decision.verdict == "reject"
            false_merge = decision.verdict == "accept"
        else:  # ambiguous -- abstaining is the right answer
            correct = decision.verdict == "abstain"
            false_merge = decision.verdict == "accept"

        outcomes.append(
            CaseOutcome(
                case_id=case.case_id,
                stratum=case.stratum,
                expected_work_key=expected,
                expected_verdict=case.label.verdict,
                decision=decision,
                candidate_rank=candidate_rank,
                correct=correct,
                false_merge=false_merge,
            )
        )

    n = len(outcomes)
    accepted = [o for o in outcomes if o.decision.verdict == "accept"]
    negatives = [o for o in outcomes if o.expected_verdict == "no_match"]

    metrics = Metrics(
        n_cases=n,
        n_accepted=len(accepted),
        n_no_match_cases=len(negatives),
        candidate_recall={
            k: (recall_hits[k] / n_positive if n_positive else 0.0) for k in RECALL_AT
        },
        precision_at_accept=(
            sum(1 for o in accepted if o.correct) / len(accepted) if accepted else 0.0
        ),
        false_merge_rate=(
            sum(1 for o in accepted if o.false_merge) / len(accepted) if accepted else 0.0
        ),
        abstention_rate=(
            sum(1 for o in outcomes if o.decision.verdict == "abstain") / n if n else 0.0
        ),
        correct_no_match_rate=(
            sum(1 for o in negatives if o.correct) / len(negatives) if negatives else 0.0
        ),
    )
    return metrics, outcomes


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
) -> None:
    from openlibrary.pipeline.duck import connect

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    metrics, outcomes = run(con, paths, load_cases(), load_weights())
    con.close()

    typer.echo(f"cases                 {metrics.n_cases}")
    for k, value in sorted(metrics.candidate_recall.items()):
        typer.echo(f"candidate recall @{k:<3}  {value:.3f}")
    typer.echo(f"precision @ accept    {metrics.precision_at_accept:.3f}")
    typer.echo(f"FALSE MERGE RATE      {metrics.false_merge_rate:.4f}  <- the one to watch")
    typer.echo(f"abstention rate       {metrics.abstention_rate:.3f}")
    typer.echo(
        f"correct no-match      {metrics.correct_no_match_rate:.3f} "
        f"({metrics.n_no_match_cases} negatives)"
    )

    typer.echo("\nby stratum:")
    strata = sorted({o.stratum for o in outcomes})
    for stratum in strata:
        rows = [o for o in outcomes if o.stratum == stratum]
        merges = sum(1 for o in rows if o.false_merge)
        positives = [o for o in rows if o.expected_work_key is not None]
        recall_miss = sum(1 for o in positives if o.candidate_rank is None)
        typer.echo(
            f"  {stratum:26} n={len(rows):<4} correct={sum(1 for o in rows if o.correct):<4} "
            f"false_merges={merges:<4} recall_miss={recall_miss}"
        )

    # The direct measurement of the labels the researchers recorded as found
    # outside blocking: a positive case (its label carries a work_key)
    # whose labeled work never showed up among blocking's candidates at all.
    total_positives = [o for o in outcomes if o.expected_work_key is not None]
    total_misses = sum(1 for o in total_positives if o.candidate_rank is None)
    typer.echo(f"\nrecall misses (positives): {total_misses} of {len(total_positives)}")


if __name__ == "__main__":
    app()
