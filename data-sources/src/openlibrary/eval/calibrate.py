"""Learn the weight vector offline.

Two methods, compared on a held-out split, and whichever wins writes
weights.json:

  1. A random coordinate search over the weight vector and the three
     thresholds. Cheap, transparent, and it is the baseline Splink must beat.
     It runs against PREPARED cases (Task 27, ruling R47): blocking,
     `load_work_views`, `extract` and `conflicts` -- the expensive,
     DuckDB-touching steps, ~4.5s/case -- run ONCE via `harness.prepare`, and
     the search calls `harness.evaluate` (pure Python, milliseconds) once per
     candidate weight vector, thousands of times over.
  2. Splink (the `calibration` extra). The design names it; this is where it is
     evaluated rather than assumed.

Honest about the sample: 300-500 labeled cases split 60/40 is small. These
weights are better than "all equal", not optimal. The seed, the split and the
objective are recorded so the next round is comparable.
"""

from __future__ import annotations

import collections
import copy
import datetime
import json
import random
from pathlib import Path

import typer

from openlibrary.eval.dataset import load_cases
from openlibrary.eval.harness import (
    Metrics,
    PreparedCase,
    evaluate,
    prepare,
    read_prepared_cache,
    write_prepared_cache,
)
from openlibrary.eval.schema import EvalCase
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import MATCHER_VERSION, Weights, load_weights
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

# A false merge destroys data (10): the wrong answer is recorded as fact. A
# false reject (R53) silently creates a duplicate Book that a later dedup
# pass must find and re-merge (1) -- real cost, but recoverable, and strictly
# worse than doing nothing. An abstention costs one review (0.1 effective,
# via the inline factor below): a human looks and decides -- cheap by
# comparison to either kind of wrong answer, but not free.
FALSE_MERGE_COST = 10.0
FALSE_REJECT_COST = 1.0
ABSTENTION_COST = 1.0

# A matcher that never accepts has a perfect false-merge rate and no value;
# the objective must not reward it. This is the floor used throughout this
# module's own CLI -- `search_weights` takes it as an explicit parameter so
# tests and callers can vary it.
DEFAULT_MIN_ACCEPT_RATE = 0.3


def equal_weights() -> Weights:
    """The design's placeholder `Weights`, built in code (R55).

    NOT `load_weights()`: `weights.json` is the file this module's own CLI
    overwrites on every calibration run, so a baseline read from disk is
    whatever the LAST run happened to leave behind -- true only on a checkout
    that has never been calibrated, and silently false, with no error, on
    every rerun after. The CLI's printed "baseline" and the search's
    cold-start point are both `equal_weights()`; `--base` opts into starting
    from a specific file instead (see `main`).
    """
    return Weights(
        matcher_version=MATCHER_VERSION,
        calibrated=False,
        calibrated_at=None,
        feature_weights={**dict.fromkeys(FEATURES, 1.0), "popularity_prior": 0.1},
        conflict_penalties={"identifier": 0.35},
        accept_threshold=0.9,
        reject_threshold=0.4,
        margin_threshold=0.05,
    )


def split_cases(
    cases: list[EvalCase],
    *,
    seed: int,
    train_fraction: float = 0.6,
) -> tuple[list[EvalCase], list[EvalCase]]:
    by_stratum: dict[str, list[EvalCase]] = collections.defaultdict(list)
    for case in cases:
        by_stratum[case.stratum].append(case)

    train: list[EvalCase] = []
    test: list[EvalCase] = []
    for stratum in sorted(by_stratum):
        members = sorted(by_stratum[stratum], key=lambda c: c.case_id)
        random.Random(seed).shuffle(members)
        cut = round(len(members) * train_fraction)
        train.extend(members[:cut])
        test.extend(members[cut:])
    return train, test


def objective(metrics: Metrics, *, min_accept_rate: float) -> float:
    """Higher is better. Bounded in (-inf, 1]."""
    accept_rate = metrics.n_accepted / metrics.n_cases if metrics.n_cases else 0.0
    if accept_rate < min_accept_rate:
        # A matcher that never accepts has a perfect false-merge rate and no value.
        return -1.0 - (min_accept_rate - accept_rate)
    return (
        metrics.precision_at_accept
        - FALSE_MERGE_COST * metrics.false_merge_rate
        - FALSE_REJECT_COST * metrics.false_reject_rate
        - ABSTENTION_COST * 0.1 * metrics.abstention_rate
    )


def search_weights(
    prepared_train: list[PreparedCase],
    *,
    base: Weights,
    iterations: int = 2000,
    seed: int = 20260901,
    min_accept_rate: float = DEFAULT_MIN_ACCEPT_RATE,
) -> tuple[Weights, float]:
    """Random coordinate hill-climb over `prepared_train`.

    Ruling R47: `prepared_train` is already blocked, viewed, featurized and
    redirect-resolved (`harness.prepare`, run once by the caller). Each of
    `iterations` steps is `harness.evaluate(prepared_train, candidate)` --
    pure Python, no DuckDB -- which is what makes a few thousand iterations
    cheap where re-running `harness.run` per iteration was not (~200 * 20min
    != 67 hours).
    """
    rng = random.Random(seed)
    best = copy.deepcopy(base)
    best_metrics, _ = evaluate(prepared_train, best)
    best_score = objective(best_metrics, min_accept_rate=min_accept_rate)

    for step in range(iterations):
        candidate = copy.deepcopy(best)
        knob = rng.choice([*FEATURES, "accept_threshold", "reject_threshold", "margin_threshold"])
        if knob in candidate.feature_weights:
            candidate.feature_weights[knob] = max(
                0.0, candidate.feature_weights[knob] + rng.uniform(-0.4, 0.4)
            )
        else:
            setattr(
                candidate,
                knob,
                min(1.0, max(0.0, getattr(candidate, knob) + rng.uniform(-0.08, 0.08))),
            )
        if candidate.reject_threshold >= candidate.accept_threshold:
            continue

        metrics, _ = evaluate(prepared_train, candidate)
        score = objective(metrics, min_accept_rate=min_accept_rate)
        if score > best_score:
            best, best_score = candidate, score
            typer.echo(f"  step {step}: objective {score:.4f} (moved {knob})")

    return best, best_score


def splink_weights(prepared_train: list[PreparedCase]) -> Weights | None:
    """One concrete, bounded attempt to fit m/u probabilities with Splink.

    Splink is a RECORD-linkage model: `Linker` takes one or two record
    dataframes that share raw column names, generates left/right pairs itself
    (via a blocking rule, or via a supplied pairwise-labels table), and
    computes every declared `Comparison`'s gamma level from `l.<col>` and
    `r.<col>` -- both sides, always, before any condition is evaluated.

    `PreparedCase` does not have that shape. The "book" side carries no raw
    fields at all (only `case_id`, `expected_work_key`, `expected_verdict`);
    the 9 values in `PreparedCandidate.values` (`matcher.features.FEATURES`)
    are already PAIR-level comparison OUTPUTS -- `title_similarity` is a
    property of (book, candidate) together, not an attribute either side owns
    on its own. There is consequently no column name Splink's generated SQL
    can select from both a "books" frame and a "candidates" frame for any of
    our 9 features.

    The attempt made here, concretely: a "books" frame of bare `unique_id`s,
    a "candidates" frame of `unique_id` plus the 9 feature columns, an
    `ExactMatch` comparison per feature, and
    `linker.training.estimate_m_from_pairwise_labels` fed the training
    split's true-match pairs. Verified against the real Splink 4.0.16 API
    (2026-09-13): this fails with a `SplinkException` wrapping a DuckDB
    `Binder Error: Table "l" does not have a column named "<feature>"` --
    Splink's generated SQL unconditionally projects `l.<feature>` from the
    "books" frame, which has no such column, for every one of the 9 features,
    regardless of which one is tried first. That confirms the mismatch is
    structural, not a fixable detail of this particular mapping.

    A real integration would need: record-level book/work frames carrying raw
    fields (title, author names, year, identifiers, language) on BOTH sides;
    a mapping from our 9 asymmetric features to Splink `Comparison`s defined
    over those raw fields (Splink would then compute its own gamma levels,
    duplicating `matcher.features.extract`); m and u fitted on the ~269
    labelled training pairs; and a translation of the resulting per-level
    match weights into the weighted-mean shape `scorer.score_features`
    expects. None of that is reachable from `PreparedCase` as it stands.

    Always returns `None`, with the specific reason `typer.echo`'d: either
    the `calibration` extra is not installed, or the attempt above fails as
    demonstrated (every time it has been tried, against the real Splink
    4.0.16 API). There is deliberately no "translate a successful fit"
    branch here -- writing one would mean committing code no run of this
    function has ever exercised, for an outcome the analysis above shows
    cannot occur with this data shape. "Splink never produced a fit to
    evaluate" is itself the design's requested Splink evaluation result.
    """
    try:
        import pandas as pd
        import splink.comparison_library as cl
        from splink import DuckDBAPI, Linker, SettingsCreator
    except ImportError as exc:
        typer.echo(f"  splink not installed ({exc}); skipping (install with --extra calibration)")
        return None

    books_rows = [{"unique_id": case.case_id} for case in prepared_train]
    candidate_rows: list[dict] = []
    label_rows: list[dict] = []
    for case in prepared_train:
        for candidate in case.candidates:
            row_id = f"{case.case_id}::{candidate.work_key}"
            candidate_rows.append({"unique_id": row_id, **candidate.values})
            if case.expected_verdict == "match" and candidate.work_key == case.expected_work_key:
                label_rows.append(
                    {
                        "source_dataset_l": "books",
                        "unique_id_l": case.case_id,
                        "source_dataset_r": "candidates",
                        "unique_id_r": row_id,
                    }
                )

    if not candidate_rows or not label_rows:
        typer.echo("  splink: training split has no labeled positive pairs to fit from; skipping")
        return None

    settings = SettingsCreator(
        link_type="link_only",
        comparisons=[cl.ExactMatch(name) for name in FEATURES],
    )
    try:
        linker = Linker(
            [pd.DataFrame(books_rows), pd.DataFrame(candidate_rows)],
            settings,
            db_api=DuckDBAPI(),
            input_table_aliases=["books", "candidates"],
        )
        linker.table_management.register_table(
            pd.DataFrame(label_rows), "pairwise_labels", overwrite=True
        )
        linker.training.estimate_m_from_pairwise_labels("pairwise_labels")
    except Exception as exc:
        # Splink's error carries ~260 lines of the generated SQL it failed on
        # (useful once, while diagnosing this -- see the docstring for the
        # exact reproduction); only its final line ("Error was: ...") says
        # what actually went wrong, so that is what gets echoed.
        # Splink's own message carries ~260 lines of the SQL it generated and
        # failed on (useful once, while diagnosing this -- see the docstring
        # for the reproduction); the actual "what went wrong" is the one line
        # starting "Error was: ..." a few lines before the end (the true
        # last line is just the `^` caret DuckDB prints under the offending
        # token, not text worth echoing).
        lines = str(exc).strip().splitlines()
        reason_line = next(
            (line.strip() for line in lines if line.strip().startswith("Error was:")),
            lines[-1].strip() if lines else "",
        )
        typer.echo(
            f"  splink: estimate_m_from_pairwise_labels failed -- "
            f"{type(exc).__name__}: {reason_line}\n"
            "  Reason: Splink projects `l.<feature>` and `r.<feature>` for every "
            "declared Comparison from BOTH linked frames; our 'books' side (built "
            "from PreparedCase, which carries only case_id) has none of the 9 "
            "feature columns, because those features are pair-level comparison "
            "outputs, not an attribute either side owns alone. See "
            "openlibrary.eval.calibrate.splink_weights's docstring for what a real "
            "integration would need."
        )
        return None


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    out: Path = typer.Option(  # noqa: B008
        Path("src/openlibrary/matcher/weights.json"), "--out"
    ),
    seed: int = typer.Option(20260901, "--seed"),
    iterations: int = typer.Option(2000, "--iterations"),
    prepared_cache: Path | None = typer.Option(  # noqa: B008
        None,
        "--prepared-cache",
        help="Cache the prepare() pass at this path across runs (~31min the "
        "first time, seconds after -- R54). A change to blocking, "
        "matcher.features, or the labelled case set requires deleting this file.",
    ),
    base_path: Path | None = typer.Option(  # noqa: B008
        None,
        "--base",
        help="Start the search from this weights file instead of equal_weights() "
        "(R55). equal_weights() is still evaluated and printed either way "
        "(Minor #3), and the write gate is the MAX of the two scores -- a "
        "search seeded here must beat equal weights too, not just this file.",
    ),
) -> None:
    paths = ArtifactPaths(root=root, dump_date=dump_date)

    cases = load_cases()
    train, test = split_cases(cases, seed=seed)
    typer.echo(f"train {len(train)} / test {len(test)} cases, seed {seed}")

    # Ruling R47/R48 (controller resolution 2): prepare ALL cases exactly
    # once -- the expensive DuckDB pass, ~4.5s/case -- then split the already
    # PreparedCase list along the same train/test partition, so nothing
    # downstream of this line touches DuckDB again. R54: skip the pass
    # entirely when a matching prepared-cases cache is on disk.
    prepared = (
        read_prepared_cache(prepared_cache, dump_date, len(cases)) if prepared_cache else None
    )
    if prepared is not None:
        typer.echo(f"loaded {len(prepared)} prepared cases from {prepared_cache}")
    else:
        from openlibrary.pipeline.duck import connect

        typer.echo(f"preparing {len(cases)} cases (one DuckDB pass, ~4.5s/case)...")
        con = connect(paths, memory_limit="8GB")
        prepared = prepare(con, paths, cases)
        con.close()
        if prepared_cache:
            write_prepared_cache(prepared_cache, dump_date, prepared)
            typer.echo(f"wrote {len(prepared)} prepared cases to {prepared_cache}")

    prepared_by_id = {p.case_id: p for p in prepared}
    prepared_train = [prepared_by_id[c.case_id] for c in train]
    prepared_test = [prepared_by_id[c.case_id] for c in test]

    # R55: `equal_weights()`, not `load_weights()` -- this module's own CLI is
    # what overwrites weights.json, so reading it back as "the baseline" is
    # only ever true on a never-calibrated checkout. `--base` opts in to a
    # warm start from a specific file (e.g. a previous calibration round) IN
    # ADDITION to that equal-weights floor, never instead of it (Minor #3):
    # a search seeded from a weak `--base` file must still beat plain equal
    # weights, not merely beat the file it happened to start from.
    equal = equal_weights()
    equal_metrics, _ = evaluate(prepared_test, equal)
    equal_score = objective(equal_metrics, min_accept_rate=DEFAULT_MIN_ACCEPT_RATE)
    typer.echo(
        f"baseline (all weights equal) on TEST: "
        f"false_merge={equal_metrics.false_merge_rate:.4f} "
        f"false_reject={equal_metrics.false_reject_rate:.4f} "
        f"precision={equal_metrics.precision_at_accept:.3f} "
        f"abstain={equal_metrics.abstention_rate:.3f} "
        f"objective={equal_score:.4f}"
    )

    if base_path:
        base = load_weights(base_path)
        base_metrics, _ = evaluate(prepared_test, base)
        base_score = objective(base_metrics, min_accept_rate=DEFAULT_MIN_ACCEPT_RATE)
        typer.echo(
            f"start (--base {base_path}) on TEST: "
            f"false_merge={base_metrics.false_merge_rate:.4f} "
            f"false_reject={base_metrics.false_reject_rate:.4f} "
            f"precision={base_metrics.precision_at_accept:.3f} "
            f"abstain={base_metrics.abstention_rate:.3f} "
            f"objective={base_score:.4f}"
        )
    else:
        base, base_score = equal, equal_score

    # The floor the chosen result must clear to be written: whichever of
    # equal weights or the (optional) `--base` file already scores higher.
    floor_score = max(equal_score, base_score)

    searched, train_score = search_weights(
        prepared_train, base=base, iterations=iterations, seed=seed
    )
    searched_metrics, _ = evaluate(prepared_test, searched)
    test_score = objective(searched_metrics, min_accept_rate=DEFAULT_MIN_ACCEPT_RATE)
    typer.echo(
        f"searched on TEST: false_merge={searched_metrics.false_merge_rate:.4f} "
        f"false_reject={searched_metrics.false_reject_rate:.4f} "
        f"precision={searched_metrics.precision_at_accept:.3f} "
        f"abstain={searched_metrics.abstention_rate:.3f}"
    )
    typer.echo(f"searched objective -- TRAIN: {train_score:.4f}  TEST: {test_score:.4f}")

    fitted = splink_weights(prepared_train)
    chosen, chosen_score, label = searched, test_score, "random-search"
    if fitted is not None:
        fitted_metrics, _ = evaluate(prepared_test, fitted)
        fitted_score = objective(fitted_metrics, min_accept_rate=DEFAULT_MIN_ACCEPT_RATE)
        typer.echo(
            f"splink on TEST: false_merge={fitted_metrics.false_merge_rate:.4f} "
            f"false_reject={fitted_metrics.false_reject_rate:.4f} "
            f"precision={fitted_metrics.precision_at_accept:.3f} objective={fitted_score:.4f}"
        )
        if fitted_score > chosen_score:
            chosen, chosen_score, label = fitted, fitted_score, "splink"

    # Per the design: an overfitted weight vector on ~270 training cases is
    # worse than an honest uncalibrated one. If nothing beat the FLOOR --
    # equal weights, and the `--base` file too when one was given (Minor
    # #3) -- on the held-out split, leave `out` exactly as it is. This
    # message describes what was (not) done, not what `out` currently
    # contains -- that could be a prior calibration, an untouched default,
    # or (with `--base`) the file just read above, and asserting which
    # would be exactly the kind of claim this task's other bugs were made
    # of.
    if chosen_score <= floor_score:
        typer.echo(
            f"{label} objective {chosen_score:.4f} does not beat the floor "
            f"(max of equal weights and any --base file: {floor_score:.4f}) on TEST -- "
            f"leaving {out} untouched."
        )
        return

    chosen.calibrated = True
    chosen.calibrated_at = datetime.datetime.now(datetime.UTC).isoformat()
    Path(out).write_text(json.dumps(chosen.model_dump(), indent=2) + "\n")
    typer.echo(
        f"{label} beat the floor on TEST ({chosen_score:.4f} > {floor_score:.4f}): "
        f"wrote {label} weights to {out} (train objective {train_score:.4f})"
    )


if __name__ == "__main__":
    app()
