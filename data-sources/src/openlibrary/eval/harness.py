"""Run the matcher over the labeled set and report the six metrics.

False-merge rate is the one to watch: a wrong merge destroys data, an
abstention costs a review. Everything else is context for it.

Every comparison resolves both sides through redirects (`dataset.resolve_keys`),
so a label written against one dump and an answer produced from another do not
disagree merely because Open Library merged something.

`run` is `evaluate(prepare(...), ...)` (Task 26b): the uncalibrated baseline
took 4.5s/case, almost all of it in blocking and `load_work_views` -- 448
cases * 4.5s ~= 34 min for the full set, ~20 min for the 268-case train
split -- and Task 27's calibration search calls the equivalent of `run` once
per weight vector it tries -- roughly 200 iterations over the train split,
which at the old per-call cost is 200 * ~20min ~= 67 hours. Weights affect
only scoring and deciding, never blocking, views, features or conflicts, so
`prepare` does every DuckDB-touching step ONCE and `evaluate` re-scores the
result in pure Python in milliseconds, as many times as calibration needs.

`write_prepared_cache`/`read_prepared_cache` (R54) persist a `prepare()` pass
to a JSON file keyed by dump date, matcher version and case count, so a
second run of either CLI against the same artifact and case set costs
seconds instead of the ~31-minute DuckDB pass. That header check catches a
changed dump date, a bumped `MATCHER_VERSION`, or a different case count --
nothing else. It carries no fingerprint of blocking's or `matcher.features`'
actual code, so a change to either (or to the labelled case set) that leaves
those three values unchanged would go undetected and serve stale prepared
candidates: delete the cache file by hand after any such change.
"""

from __future__ import annotations

import json
from pathlib import Path

import duckdb
import typer
from pydantic import BaseModel, Field

from openlibrary.eval.dataset import load_cases, resolve_keys
from openlibrary.eval.schema import EvalCase, Verdict
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.matcher.decide import Decision, decide, rank
from openlibrary.matcher.features import conflicts, extract, load_work_views
from openlibrary.matcher.scorer import MATCHER_VERSION, Weights, load_weights, score_features
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

RECALL_AT = (5, 10, 50)

# The pinned regression thresholds (Task 28) -- read by the pipeline gate and
# by tests/openlibrary/test_eval_regression.py, both against this one path,
# never a CWD-relative string.
THRESHOLDS_PATH = Path(__file__).parent / "thresholds.json"

# R56: the one table of what "regressed" means, each entry
# (label, direction, metrics_attribute, thresholds_key). Both
# `pipeline.gates.threshold_failures` (the build gate) and
# tests/openlibrary/test_eval_regression.py (the regression test and its
# "every threshold has a measured sibling" check) iterate this SAME tuple --
# a threshold pinned in thresholds.json without a matching entry here, or
# vice versa, fails a test rather than silently going unchecked on one side.
THRESHOLD_CHECKS: tuple[tuple[str, str, str, str], ...] = (
    ("recall@10", "min", "candidate_recall", "min_candidate_recall_10"),
    ("false-merge", "max", "false_merge_rate", "max_false_merge_rate"),
    ("precision@accept", "min", "precision_at_accept", "min_precision_at_accept"),
    ("abstention", "max", "abstention_rate", "max_abstention_rate"),
    ("correct no-match", "min", "correct_no_match_rate", "min_correct_no_match_rate"),
    ("false-reject", "max", "false_reject_rate", "max_false_reject_rate"),
)


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
    false_reject_rate: float = 0.0
    abstention_rate: float = 0.0
    correct_no_match_rate: float = 0.0


def threshold_value(metrics: Metrics, attribute: str) -> float:
    """The value a `THRESHOLD_CHECKS` entry's `metrics_attribute` names.

    Every attribute but one is a plain float field on `Metrics`; `candidate_recall`
    is a dict keyed by the depths in `RECALL_AT`, and every `THRESHOLD_CHECKS`
    entry that names it means recall@10 specifically -- the only recall depth
    a threshold is pinned against.
    """
    value = getattr(metrics, attribute)
    return value.get(10, 0.0) if attribute == "candidate_recall" else value


class PreparedCandidate(BaseModel):
    work_key: str
    rules: list[str] = Field(default_factory=list)
    values: dict[str, float | None] = Field(default_factory=dict)
    conflicts: list[str] = Field(default_factory=list)


class PreparedCase(BaseModel):
    case_id: str
    stratum: str
    expected_work_key: str | None
    expected_verdict: Verdict
    candidates: list[PreparedCandidate] = Field(default_factory=list)
    # R59: `BlockingResult.volume_guards_tripped` for this case -- the rules
    # that found something and refused to fetch it. With zero candidates it
    # is what `decide` needs to abstain rather than reject.
    volume_guards_tripped: list[str] = Field(default_factory=list)
    # The `resolve_keys` map for the expected key plus every candidate key,
    # fetched once here so `evaluate` never needs a connection (ruling: one
    # `resolve_keys` call per case, not one query per candidate).
    resolved: dict[str, str] = Field(default_factory=dict)


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


def prepare(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: list[EvalCase],
) -> list[PreparedCase]:
    """Blocking + `load_work_views` + `extract`/`conflicts` + `resolve_keys`, once.

    Everything here touches DuckDB and is independent of `weights` -- it is
    the expensive pass `evaluate` is split off from, so it runs once per
    split rather than once per weight vector Task 27's search tries.
    Candidates without a view are dropped here, exactly as `run` dropped them
    before this split.
    """
    prepared: list[PreparedCase] = []
    for case in cases:
        query = _query_for(case)
        blocking = generate_candidates(con, paths, query)
        identifier_hits = blocking.identifier_hits
        views = load_work_views(con, paths, list(blocking.candidates))
        candidates = [
            PreparedCandidate(
                work_key=key,
                rules=rules,
                values=extract(query, views[key], identifier_hits=identifier_hits),
                conflicts=conflicts(query, views[key], identifier_hits=identifier_hits),
            )
            for key, rules in blocking.candidates.items()
            if key in views
        ]

        expected = case.label.work_key
        resolved = resolve_keys(
            con,
            paths,
            [expected, *blocking.candidates] if expected else list(blocking.candidates),
        )

        prepared.append(
            PreparedCase(
                case_id=case.case_id,
                stratum=case.stratum,
                expected_work_key=expected,
                expected_verdict=case.label.verdict,
                candidates=candidates,
                volume_guards_tripped=list(blocking.volume_guards_tripped),
                resolved=resolved,
            )
        )
    return prepared


def evaluate(
    prepared: list[PreparedCase],
    weights: Weights,
) -> tuple[Metrics, list[CaseOutcome]]:
    """`score_features` + `rank` + `decide` + the outcome/metrics logic.

    Pure Python: no `con`, no `paths`. Safe to call thousands of times per
    `prepare`d split, one call per weight vector Task 27's search tries.
    """
    outcomes: list[CaseOutcome] = []
    recall_hits = dict.fromkeys(RECALL_AT, 0)
    n_positive = 0

    for case in prepared:
        scored = [
            score_features(c.work_key, c.values, c.conflicts, c.rules, weights)
            for c in case.candidates
        ]
        ordered = rank(scored)
        decision = decide(scored, weights, volume_guards_tripped=case.volume_guards_tripped)

        expected = case.expected_work_key
        resolved = case.resolved

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

        if case.expected_verdict == "match":
            same_as_expected = _same(resolved, decision.work_key, expected)
            correct = decision.verdict == "accept" and same_as_expected
            false_merge = decision.verdict == "accept" and not correct
        elif case.expected_verdict == "no_match":
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
                expected_verdict=case.expected_verdict,
                decision=decision,
                candidate_rank=candidate_rank,
                correct=correct,
                false_merge=false_merge,
            )
        )

    n = len(outcomes)
    accepted = [o for o in outcomes if o.decision.verdict == "accept"]
    negatives = [o for o in outcomes if o.expected_verdict == "no_match"]
    # R53: cases the label calls a real match. A `reject` decision on one of
    # these silently turns a true match into what looks like a brand-new,
    # unrelated book -- a false reject, distinct from (and previously
    # invisible next to) an abstention, which at least flags itself for
    # review.
    matches = [o for o in outcomes if o.expected_verdict == "match"]

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
        false_reject_rate=(
            sum(1 for o in matches if o.decision.verdict == "reject") / len(matches)
            if matches
            else 0.0
        ),
        abstention_rate=(
            sum(1 for o in outcomes if o.decision.verdict == "abstain") / n if n else 0.0
        ),
        correct_no_match_rate=(
            sum(1 for o in negatives if o.correct) / len(negatives) if negatives else 0.0
        ),
    )
    return metrics, outcomes


def run(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: list[EvalCase],
    weights: Weights,
) -> tuple[Metrics, list[CaseOutcome]]:
    return evaluate(prepare(con, paths, cases), weights)


def write_prepared_cache(path: Path, dump_date: str, prepared: list[PreparedCase]) -> None:
    """Persist a `prepare()` result so a later run can skip the DuckDB pass.

    The header (`dump_date`, `matcher_version`, `n_cases`) is what
    `read_prepared_cache` checks before trusting the file -- see that
    function for what invalidates it.
    """
    payload = {
        "dump_date": dump_date,
        "matcher_version": MATCHER_VERSION,
        "n_cases": len(prepared),
        "cases": [p.model_dump() for p in prepared],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload))


def read_prepared_cache(path: Path, dump_date: str, n_cases: int) -> list[PreparedCase] | None:
    """Load a `write_prepared_cache` file when its header matches, else `None`.

    A cache is only valid for the exact dump date, matcher version, and case
    count it was built from -- a change to blocking, `matcher.features`, or
    the labelled case set changes what `prepare` would produce without
    necessarily changing `n_cases`, but `matcher_version` exists precisely so
    a scoring-relevant code change can bump it and invalidate every cache.
    Never raises: a missing, corrupt, or mismatched file just means "rebuild",
    and the reason is echoed so a stale-cache run isn't a silent surprise.
    """
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        typer.echo(f"  prepared-cache {path} unreadable ({exc}); rebuilding")
        return None

    expected = {"dump_date": dump_date, "matcher_version": MATCHER_VERSION, "n_cases": n_cases}
    mismatches = {
        key: (want, payload.get(key)) for key, want in expected.items() if payload.get(key) != want
    }
    if mismatches:
        details = ", ".join(
            f"{key} expected {want!r} got {got!r}" for key, (want, got) in mismatches.items()
        )
        typer.echo(f"  prepared-cache {path} header mismatch ({details}); rebuilding")
        return None

    return [PreparedCase.model_validate(c) for c in payload["cases"]]


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    prepared_cache: Path | None = typer.Option(  # noqa: B008
        None,
        "--prepared-cache",
        help="Cache the prepare() pass at this path across runs (~31min the "
        "first time, seconds after). A change to blocking, matcher.features, "
        "or the labelled case set requires deleting this file.",
    ),
) -> None:
    cases = load_cases()

    prepared = (
        read_prepared_cache(prepared_cache, dump_date, len(cases)) if prepared_cache else None
    )
    if prepared is not None:
        typer.echo(f"loaded {len(prepared)} prepared cases from {prepared_cache}")
    else:
        from openlibrary.pipeline.duck import connect

        paths = ArtifactPaths(root=root, dump_date=dump_date)
        con = connect(paths, memory_limit="8GB")
        prepared = prepare(con, paths, cases)
        con.close()
        if prepared_cache:
            write_prepared_cache(prepared_cache, dump_date, prepared)
            typer.echo(f"wrote {len(prepared)} prepared cases to {prepared_cache}")

    metrics, outcomes = evaluate(prepared, load_weights())

    typer.echo(f"cases                 {metrics.n_cases}")
    for k, value in sorted(metrics.candidate_recall.items()):
        typer.echo(f"candidate recall @{k:<3}  {value:.3f}")
    typer.echo(f"precision @ accept    {metrics.precision_at_accept:.3f}")
    typer.echo(f"FALSE MERGE RATE      {metrics.false_merge_rate:.4f}  <- the one to watch")
    typer.echo(
        f"false reject rate     {metrics.false_reject_rate:.4f}  (true matches decided no-match)"
    )
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
