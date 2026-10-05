# Open Library matcher: list-style queries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `POST /resolve` accept on title + author queries (list rows) when the evidence identifies one book, without raising false merges, and prove it with a before/after evaluation.

**Architecture:** Phase 1 fixes the ruler before the thing being measured. It adds a `list_row` stratum and duplicate-aware labels to the labelled set, plus harness support (alternates, per-stratum metrics, saved readings, a comparison report), and records a baseline reading with the *current* matcher. Phase 2 changes the matcher:
- variant-aware title similarity;
- candidates without a comparable title can neither outrank another candidate nor set its margin;
- a duplicate-cluster stage between scoring and deciding.

Phase 2 then recalibrates, re-pins the gates and produces the after reading and the comparison report.

**Tech Stack:** Python 3.12, `uv`, DuckDB, pydantic v2, rapidfuzz, typer, pytest, ruff (in `data-sources/`). One measurement script runs under Rails (`web-app/`, `bin/rails runner`) and writes nothing.

**Spec:** `docs/superpowers/specs/2026-10-04-ol-matcher-list-queries-design.md`. Read it before starting any task; this plan argues from it.

## Global Constraints

- Python commands run from `data-sources/`: `uv run --locked pytest`, `uv run --locked ruff check src tests`, `uv run --locked ruff format --check src tests`. Line length 100.
- The real artifact lives at `/home/shane/ol-data/versions/2026-07-31/` (`--root /home/shane/ol-data --dump-date 2026-07-31`). Artifact-backed tests run with `OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run --locked pytest -m artifact`.
- Paths under `src/openlibrary/eval/` trip this harness's shell sandbox (the word "eval" in a path). Use the Read/Edit/Write tools for those files, or glob the directory as `src/openlibrary/ev?l/` in shell commands.
- `MATCHER_VERSION` goes from 2 to 3 in **Task 15 only**, together with the re-pinned `thresholds.json` and `weights.json`. Bumping it earlier breaks `test_thresholds_are_recorded_with_the_matcher_version_they_were_measured_on`.
- Absence stays neutral (R40): an empty fingerprint on either side gives `None`, never 0.0.
- `common/normalize.py` gains query-side helpers only. Stored fingerprints, the SQL twins and `NORMALIZER_VERSION` (1) are unchanged, so no artifact rebuild.
- No Rails file changes. The Rails replay script is a measurement tool run with `bin/rails runner` from a file in the session scratchpad, and its finder calls run inside a rolled-back transaction.
- Merging to `main` deploys the OL API to the home server within 15 minutes. Nothing in this plan merges; the branch ends with a report to Shane.
- Commit on branch `worktree-books-list-wizard`. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never edit `docs/specs/` (archived). Docs live at the repo root `docs/`, not `web-app/docs/`.

## Review Focus

These are inputs the spec implies but no happy-path test covers. Each line names the task that pins it with a test.

1. **A query whose colon is part of the title, not a subtitle** ("Star Wars: A New Hope" vs a plain "Star Wars" work). The full-title work must outrank the subtitle-dropped match. Pinned in Task 9 (`test_full_title_match_outranks_a_subtitle_dropped_match`).
2. **Two duplicates with equal edition counts** (including both 0). There is no representative, so the decision abstains and never picks arbitrarily. Pinned in Task 12 (`test_tied_edition_counts_have_no_representative`, `test_zero_edition_counts_have_no_representative`).
3. **A label's alternate that is actually a redirect of the label's key.** That's not a duplicate; the verifier must flag it. Pinned in Task 5 (`test_an_alternate_that_redirects_to_the_label_is_a_problem`).
4. **A relabel that keeps the case count.** A stale prepared cache must be detected, not silently reused. Pinned in Task 2 (`test_cache_header_changes_when_a_label_changes`).
5. **A warm-start calibration from the version-2 weights file**, which has no new parameters and `matcher_version: 2`. It must load, and the written file must carry version 3. Pinned in Task 14 (`test_a_v2_weights_file_loads_with_defaults`, `test_written_weights_carry_the_current_matcher_version`).

---

## File map

**Phase 1 (labelled set, harness, baseline)**

| File | Responsibility |
|---|---|
| `data-sources/src/openlibrary/eval/schema.py` (modify) | `list_row` stratum, `alternate_work_keys`, `agent_researched` labeller, `MAX_CASES` |
| `data-sources/src/openlibrary/eval/harness.py` (modify) | alternates in correctness and recall, `summarize`, `canonical_rate`, list-row metrics, label digest in the cache header, `--reading-out` |
| `data-sources/src/openlibrary/eval/compare.py` (create) | side-by-side metrics and decision diff between two saved readings, as markdown |
| `data-sources/src/openlibrary/eval/build_pool.py` (modify) | `PoolEntry.hint_work_keys` |
| `data-sources/src/openlibrary/eval/build_list_rows.py` (create) | `split_authors`, sampling, list-row `PoolEntry`s |
| `data-sources/src/openlibrary/eval/dataset.py` (modify) | `fetch_work_facts`, `alternate_problems`, `check_alternates` |
| `data-sources/src/openlibrary/eval/spot_check.py` (create) | seeded markdown review sheet for Shane |
| `data-sources/src/openlibrary/eval/cases/list_rows.jsonl` (create) | the researched list-row cases |
| `data-sources/src/openlibrary/eval/cases/{labels,researched}.jsonl` (modify) | `alternate_work_keys` on duplicate labels |
| `data-sources/src/openlibrary/eval/readings/` (create) | saved baseline and after readings (JSON) |

**Phase 2 (matcher v3)**

| File | Responsibility |
|---|---|
| `data-sources/src/common/normalize.py` (modify) | `QueryTitleVariants`, `query_title_variants` |
| `data-sources/src/common/scoring.py` (modify) | `fuzzy_similarity` (renamed, unchanged), `TitleComparison`, `compare_titles` |
| `data-sources/src/openlibrary/matcher/features.py` (modify) | variant-aware title features, derived subtitle, `title_containment` |
| `data-sources/src/openlibrary/matcher/scorer.py` (modify) | `has_identity_evidence` (moved here), containment credit, two new `Weights` fields |
| `data-sources/src/openlibrary/matcher/cluster.py` (create) | `ClusterInputs`, `cluster_inputs`, `ClusterIndex`, `build_clusters` |
| `data-sources/src/openlibrary/matcher/decide.py` (modify) | identity-first, cluster-grouped `rank`; `margins`; cluster-aware `decide`; `Decision.duplicates` |
| `data-sources/src/openlibrary/api/resolve.py` (modify) | cluster stage, `decision.duplicates`, per-candidate margins from `margins` |
| `data-sources/src/openlibrary/eval/calibrate.py` (modify) | bounded knobs for the two parameters; written file carries `MATCHER_VERSION` |
| `data-sources/src/openlibrary/matcher/{scorer.py,weights.json}`, `eval/thresholds.json`, `eval/harness.py` | version 3, recalibrated weights, re-pinned and new gates |
| `docs/data-quality/ol-matcher-v3-before-after.md` (create) | the before/after report |
| `docs/features/open-library-data-service.md` (modify) | reading 8, rulings, list-row measurement |

---

# Phase 1 — the labelled set and the harness

### Task 1: Schema: `list_row` stratum, alternates, `agent_researched`

**Files:**
- Modify: `data-sources/src/openlibrary/eval/schema.py`
- Modify: `data-sources/src/openlibrary/eval/dataset.py:24-46` (docstring only; the filter already keeps everything but `agent`)
- Test: `data-sources/tests/openlibrary/test_eval_schema.py`, `data-sources/tests/openlibrary/test_eval_dataset.py`

**Interfaces:**
- Produces: `STRATA["list_row"] == 150`; `MAX_CASES == 650`; `Labeler` includes `"agent_researched"`; `EvalLabel.alternate_work_keys: list[str]` (default `[]`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/openlibrary/test_eval_schema.py` (it already has a `_label(**overrides)` helper building an `EvalLabel`; reuse it):

```python
def test_list_row_is_a_stratum_with_a_quota():
    assert STRATA["list_row"] == 150


def test_strata_quotas_still_fit_the_case_bounds_with_list_rows():
    assert MIN_CASES <= sum(STRATA.values()) <= MAX_CASES


def test_agent_researched_is_a_labeller():
    label = _label(labeled_by="agent_researched")
    assert label.labeled_by == "agent_researched"


def test_alternate_work_keys_default_to_empty():
    assert _label().alternate_work_keys == []


def test_alternates_are_only_valid_on_a_match():
    with pytest.raises(ValueError, match="alternate_work_keys"):
        _label(
            verdict="no_match",
            work_key=None,
            identity_rule="not_in_open_library",
            alternate_work_keys=["OL2W"],
        )


def test_an_alternate_must_not_repeat_the_work_key():
    with pytest.raises(ValueError, match="alternate_work_keys"):
        _label(work_key="OL1W", alternate_work_keys=["OL1W"])
```

Append to `tests/openlibrary/test_eval_dataset.py`. Its existing helper is `_case(case_id: str, stratum: str, **label_overrides) -> EvalCase`, which defaults to a `no_match` label:

```python
def test_agent_researched_labels_are_ground_truth(tmp_path):
    case = _case("r-1", "list_row", labeled_by="agent_researched")
    (tmp_path / "list_rows.jsonl").write_text(case.model_dump_json() + "\n")
    assert [c.case_id for c in load_cases(tmp_path)] == ["r-1"]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_eval_schema.py tests/openlibrary/test_eval_dataset.py -q`
Expected: FAIL. `KeyError: 'list_row'`, a pydantic literal error for `agent_researched`, and unexpected-keyword errors for `alternate_work_keys`.

- [ ] **Step 3: Implement**

In `schema.py`:

```python
MIN_CASES = 300
# 450 book-shaped cases + 150 list rows (2026-10-04 spec), with headroom.
MAX_CASES = 650
```

Add to `STRATA`, after `"no_candidates": 50,`:

```python
    # A list row exactly as a list page gives it: the title as printed
    # (subtitle, caps and all), author names, no year, no identifiers. 438 of
    # the first 448 cases carry identifiers, which settle most margins; list
    # rows never do (2026-10-04 spec, "Why").
    "list_row": 150,
```

Update the "Sums to 450" comment to "Sums to 600."

Replace the `Labeler` line:

```python
# `agent_researched`: an agent researched the case against the artifact alone,
# and Shane spot-checked a seeded sample (list rows, 2026-10-04 spec section 1).
Labeler = Literal["human", "agent", "agent_confirmed", "agent_researched"]
```

In `EvalLabel`, add the field after `work_key`:

```python
    # Verified unmerged Open Library duplicates of `work_key`: an accept of
    # any of them is correct (2026-10-04 spec, section 1). `work_key` stays
    # the canonical choice.
    alternate_work_keys: list[str] = Field(default_factory=list)
```

and add to `check_verdict_consistency`, before `return self`:

```python
        if self.alternate_work_keys:
            if self.verdict != "match":
                raise ValueError("alternate_work_keys are only valid on a match")
            if self.work_key in self.alternate_work_keys:
                raise ValueError("alternate_work_keys must not repeat work_key")
```

In `dataset.load_cases`'s docstring, change "human labels plus `agent_confirmed` labels only" to "human, `agent_confirmed` and `agent_researched` labels". The code already excludes only `agent`.

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_eval_schema.py tests/openlibrary/test_eval_dataset.py -q`
Expected: PASS. `test_the_committed_set_meets_its_quotas_and_has_enough_negatives` prints `list_row` as below quota (0/150) and still passes.

- [ ] **Step 5: Commit**

```bash
git add data-sources/src/openlibrary/eval/schema.py data-sources/src/openlibrary/eval/dataset.py data-sources/tests/openlibrary/test_eval_schema.py data-sources/tests/openlibrary/test_eval_dataset.py
git commit -m "OL eval: list_row stratum, alternate_work_keys, agent_researched labels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Harness: alternates, `summarize`, new metrics, label digest, saved readings

**Files:**
- Modify: `data-sources/src/openlibrary/eval/harness.py`
- Modify: `data-sources/src/openlibrary/eval/calibrate.py` (two call sites of `read_prepared_cache`)
- Test: `data-sources/tests/openlibrary/test_harness.py`

**Interfaces:**
- Consumes: `EvalLabel.alternate_work_keys` (Task 1).
- Produces:
  - `PreparedCase.alternate_work_keys: list[str]`
  - `CaseOutcome.canonical: bool`
  - `Metrics.canonical_rate`, `Metrics.list_row_abstention_rate`, `Metrics.list_row_false_merge_rate` (floats, default 0.0)
  - `summarize(outcomes: list[CaseOutcome]) -> Metrics`
  - `labels_sha256(cases: list[EvalCase]) -> str`
  - `read_prepared_cache(path, paths, cases: list[EvalCase])` (was `n_cases: int`)
  - `write_reading(path: Path, metrics: Metrics, outcomes: list[CaseOutcome], *, label: str, weights: Weights) -> None`
  - CLI option `--reading-out PATH` with `--reading-label TEXT`

- [ ] **Step 1: Write the failing tests**

`tests/openlibrary/test_harness.py` already has `_equal_weights()` (thresholds 0.9 / 0.4 / 0.05) and `_artifact(tmp_path, dump_date="2026-07-31", built_at=None)` for cache tests. Add:

```python
import datetime

from openlibrary.eval.harness import (
    PreparedCandidate,
    PreparedCase,
    evaluate,
    labels_sha256,
    read_prepared_cache,
    summarize,
    write_prepared_cache,
)
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel
from openlibrary.matcher.features import FEATURES


def _eval_case(case_id, *, work_key, alternates=()):
    return EvalCase(
        case_id=case_id,
        stratum="easy_baseline",
        book=EvalBook(book_id=1, title="A Title"),
        label=EvalLabel(
            verdict="match",
            work_key=work_key,
            alternate_work_keys=list(alternates),
            identity_rule="same_work",
            rationale="Matched by title and author.",
            labeled_at=datetime.date(2026, 10, 4),
            labeled_against_dump_date="2026-07-31",
        ),
    )


def _prepared_from(case):
    return PreparedCase(
        case_id=case.case_id,
        stratum=case.stratum,
        expected_work_key=case.label.work_key,
        expected_verdict=case.label.verdict,
        alternate_work_keys=list(case.label.alternate_work_keys),
    )


def _weights():
    return _equal_weights()


def _accepting_case(case_id, *, expected, accepted, alternates=(), stratum="easy_baseline"):
    """A prepared case whose only candidate is `accepted`, scoring 1.0: a clear
    accept under any weights (only the two title features are present)."""
    values = {name: None for name in FEATURES}
    values.update(title_similarity=1.0, title_variant_exact=1.0)
    return PreparedCase(
        case_id=case_id,
        stratum=stratum,
        expected_work_key=expected,
        expected_verdict="match",
        alternate_work_keys=list(alternates),
        candidates=[PreparedCandidate(work_key=accepted, rules=["title_fp"], values=values)],
        resolved={},
    )


def test_accepting_a_labelled_alternate_is_correct_not_a_false_merge():
    metrics, outcomes = evaluate(
        [_accepting_case("c1", expected="OL1W", accepted="OL2W", alternates=["OL2W"])],
        _weights(),  # the module's existing fixed-threshold Weights helper
    )
    assert outcomes[0].correct and not outcomes[0].false_merge
    assert outcomes[0].canonical is False
    assert metrics.false_merge_rate == 0.0
    assert metrics.canonical_rate == 0.0


def test_accepting_the_labelled_key_is_canonical():
    metrics, outcomes = evaluate(
        [_accepting_case("c1", expected="OL1W", accepted="OL1W", alternates=["OL2W"])],
        _weights(),
    )
    assert outcomes[0].canonical is True
    assert metrics.canonical_rate == 1.0


def test_accepting_a_key_outside_label_and_alternates_is_a_false_merge():
    _, outcomes = evaluate(
        [_accepting_case("c1", expected="OL1W", accepted="OL3W", alternates=["OL2W"])],
        _weights(),
    )
    assert outcomes[0].false_merge


def test_recall_counts_an_alternate_as_the_labelled_work():
    _, outcomes = evaluate(
        [_accepting_case("c1", expected="OL1W", accepted="OL2W", alternates=["OL2W"])],
        _weights(),
    )
    assert outcomes[0].candidate_rank == 1


def test_list_row_metrics_cover_only_list_row_cases():
    metrics, _ = evaluate(
        [
            _accepting_case("a", expected="OL1W", accepted="OL9W", stratum="list_row"),
            _accepting_case("b", expected="OL1W", accepted="OL1W", stratum="easy_baseline"),
        ],
        _weights(),
    )
    assert metrics.list_row_false_merge_rate == 1.0
    assert metrics.list_row_abstention_rate == 0.0
    assert metrics.false_merge_rate == 0.5


def test_summarize_recomputes_the_same_metrics_evaluate_returns():
    prepared = [
        _accepting_case("a", expected="OL1W", accepted="OL1W"),
        _accepting_case("b", expected="OL1W", accepted="OL9W"),
    ]
    metrics, outcomes = evaluate(prepared, _weights())
    assert summarize(outcomes) == metrics


def test_cache_header_changes_when_a_label_changes():  # Review Focus 4
    case = _eval_case("c1", work_key="OL1W")
    relabelled = _eval_case("c1", work_key="OL2W")
    with_alternate = _eval_case("c1", work_key="OL1W", alternates=["OL3W"])
    assert labels_sha256([case]) == labels_sha256([case])
    assert labels_sha256([case]) != labels_sha256([relabelled])
    assert labels_sha256([case]) != labels_sha256([with_alternate])


def test_a_relabel_with_the_same_case_count_invalidates_the_cache(tmp_path):
    paths = _artifact(tmp_path)
    case = _eval_case("c1", work_key="OL1W")
    cache = tmp_path / "prepared.json"
    write_prepared_cache(cache, paths, [_prepared_from(case)])
    assert read_prepared_cache(cache, paths, [case]) is not None
    assert read_prepared_cache(cache, paths, [_eval_case("c1", work_key="OL2W")]) is None
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_harness.py -q`
Expected: FAIL with import errors for `summarize` and `labels_sha256`.

- [ ] **Step 3: Implement**

In `harness.py`:

1. Add to `PreparedCase`, after `expected_verdict`:

```python
    # Verified duplicates of `expected_work_key` (2026-10-04 spec, section 1);
    # an accept of any is correct, and recall counts them as the labelled work.
    alternate_work_keys: list[str] = Field(default_factory=list)
```

2. Add to `CaseOutcome`: `canonical: bool = False`. Add to `Metrics`:

```python
    # Of the correct accepts on `match` cases, the fraction that picked the
    # labelled (canonical) key rather than an alternate. Informational.
    canonical_rate: float = 0.0
    # The same two rates restricted to the `list_row` stratum (gated in Task 15).
    list_row_abstention_rate: float = 0.0
    list_row_false_merge_rate: float = 0.0
```

3. In `prepare`, carry the alternates and resolve them in the same call:

```python
        expected = case.label.work_key
        alternates = list(case.label.alternate_work_keys)
        resolved = resolve_keys(
            con,
            paths,
            [*([expected] if expected else []), *alternates, *blocking.candidates],
        )
```

and pass `alternate_work_keys=alternates` to `PreparedCase(...)`.

4. Add the helper next to `_same`:

```python
def _is_labelled_work(resolved: dict[str, str], key: str | None, case: PreparedCase) -> bool:
    """`key` is the labelled work or one of its verified alternates."""
    return _same(resolved, key, case.expected_work_key) or any(
        _same(resolved, key, alternate) for alternate in case.alternate_work_keys
    )
```

5. Split `evaluate` into outcome-building plus `summarize`. Replace the body after the scoring loop's outcome construction so that:

- `candidate_rank` uses `_is_labelled_work(resolved, candidate.work_key, case)`;
- for `match`: `correct = decision.verdict == "accept" and _is_labelled_work(resolved, decision.work_key, case)`, and `canonical = correct and _same(resolved, decision.work_key, expected)`;
- the `Metrics` construction moves into:

```python
def summarize(outcomes: list[CaseOutcome]) -> Metrics:
    """The metrics of a set of outcomes. Pure, so per-stratum readings and the
    comparison report compute exactly what `evaluate` reports."""
    n = len(outcomes)
    accepted = [o for o in outcomes if o.decision.verdict == "accept"]
    negatives = [o for o in outcomes if o.expected_verdict == "no_match"]
    matches = [o for o in outcomes if o.expected_verdict == "match"]
    positives = [o for o in outcomes if o.expected_work_key is not None]
    correct_matches = [o for o in matches if o.correct]
    list_rows = [o for o in outcomes if o.stratum == "list_row"]
    list_row_accepted = [o for o in list_rows if o.decision.verdict == "accept"]

    def recall(k: int) -> float:
        hits = sum(1 for o in positives if o.candidate_rank is not None and o.candidate_rank <= k)
        return hits / len(positives) if positives else 0.0

    return Metrics(
        n_cases=n,
        n_accepted=len(accepted),
        n_no_match_cases=len(negatives),
        candidate_recall={k: recall(k) for k in RECALL_AT},
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
        canonical_rate=(
            sum(1 for o in correct_matches if o.canonical) / len(correct_matches)
            if correct_matches
            else 0.0
        ),
        list_row_abstention_rate=(
            sum(1 for o in list_rows if o.decision.verdict == "abstain") / len(list_rows)
            if list_rows
            else 0.0
        ),
        list_row_false_merge_rate=(
            sum(1 for o in list_row_accepted if o.false_merge) / len(list_row_accepted)
            if list_row_accepted
            else 0.0
        ),
    )
```

`evaluate` ends with `return summarize(outcomes), outcomes`. Remove the old `recall_hits` / `n_positive` bookkeeping. Recall is now computed from `candidate_rank`, which carries the same information.

6. Label digest in the cache header (Review Focus 4):

```python
def _label_rows(rows) -> str:
    digest = hashlib.sha256()
    for row in sorted(rows):
        digest.update(json.dumps(row).encode())
    return digest.hexdigest()


def labels_sha256(cases: list[EvalCase]) -> str:
    """Digest of what a relabel changes: id, stratum, key, verdict, alternates.
    The header's case count could not see a relabel that kept the count."""
    return _label_rows(
        (
            c.case_id,
            c.stratum,
            c.label.work_key,
            c.label.verdict,
            sorted(c.label.alternate_work_keys),
        )
        for c in cases
    )


def _prepared_labels_sha256(prepared: list[PreparedCase]) -> str:
    return _label_rows(
        (
            p.case_id,
            p.stratum,
            p.expected_work_key,
            p.expected_verdict,
            sorted(p.alternate_work_keys),
        )
        for p in prepared
    )
```

Change `_cache_header(paths, n_cases)` to `_cache_header(paths, n_cases, labels_digest)` and add `"labels_sha256": labels_digest`.
- `write_prepared_cache` passes `_prepared_labels_sha256(prepared)`.
- `read_prepared_cache(path, paths, cases)` passes `len(cases), labels_sha256(cases)`.

Update the module docstring's header description from "five values" to "six values", and remove the sentence saying a relabel that keeps its count "still needs a manual delete". Update both CLI `--prepared-cache` help strings the same way.

Update the callers: `harness.main` and `calibrate.main` pass `cases` instead of `len(cases)`.

7. Saved readings:

```python
def write_reading(
    path: Path, metrics: Metrics, outcomes: list[CaseOutcome], *, label: str, weights: Weights
) -> None:
    """One harness run, saved so two matcher versions can be compared later
    (`openlibrary.eval.compare`)."""
    strata = sorted({o.stratum for o in outcomes})
    payload = {
        "label": label,
        "matcher_version": MATCHER_VERSION,
        "weights_calibrated_at": weights.calibrated_at,
        "metrics": metrics.model_dump(),
        "by_stratum": {
            s: summarize([o for o in outcomes if o.stratum == s]).model_dump() for s in strata
        },
        "outcomes": [o.model_dump() for o in outcomes],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1) + "\n")
```

In `main`, add the options:

```python
    reading_out: Path | None = typer.Option(None, "--reading-out"),  # noqa: B008
    reading_label: str = typer.Option("unlabelled", "--reading-label"),
```

and after `evaluate`: `if reading_out: write_reading(reading_out, metrics, outcomes, label=reading_label, weights=weights)`. Bind `weights = load_weights()` once and pass it to `evaluate`. Also print `canonical rate` and `list_row abstention` / `list_row false merge` lines in the summary block.

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_harness.py tests/openlibrary/test_calibrate.py tests/openlibrary/test_pipeline_gates.py -q`
Expected: PASS. Fix any existing test that called `read_prepared_cache(..., n_cases)` to pass the case list.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/harness.py data-sources/src/openlibrary/eval/calibrate.py data-sources/tests/openlibrary/test_harness.py
git commit -m "OL eval harness: alternates, summarize, list-row metrics, label digest, saved readings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Comparison report (`eval/compare.py`)

**Files:**
- Create: `data-sources/src/openlibrary/eval/compare.py`
- Test: `data-sources/tests/openlibrary/test_compare.py`

**Interfaces:**
- Consumes: the JSON written by `harness.write_reading` (Task 2).
- Produces:
  - `load_reading(path: Path) -> dict`
  - `metric_rows(before: dict, after: dict, *, stratum: str | None = None) -> list[tuple[str, float, float]]`
  - `decision_diff(before: dict, after: dict) -> list[DiffRow]`
  - `render_markdown(before: dict, after: dict) -> str`
  - CLI `--before PATH --after PATH --out PATH`
  - `DiffRow` is a pydantic model with fields `case_id, stratum, change, before_verdict, before_key, after_verdict, after_key, expected_key, after_correct`. `change` is one of `newly_accepted`, `newly_abstained`, `newly_rejected`, `key_changed`, `other`.

- [ ] **Step 1: Write the failing tests**

```python
from openlibrary.eval.compare import decision_diff, metric_rows, render_markdown


def _outcome(case_id, verdict, key, *, expected="OL1W", correct=False, stratum="list_row"):
    return {
        "case_id": case_id,
        "stratum": stratum,
        "expected_work_key": expected,
        "expected_verdict": "match",
        "decision": {"verdict": verdict, "work_key": key, "score": 0.9, "margin": 0.1,
                     "reason": "r", "duplicates": []},
        "candidate_rank": 1,
        "correct": correct,
        "false_merge": verdict == "accept" and not correct,
        "canonical": correct,
    }


def _reading(outcomes, abstention):
    return {
        "label": "x",
        "matcher_version": 2,
        "weights_calibrated_at": None,
        "metrics": {"abstention_rate": abstention, "false_merge_rate": 0.0},
        "by_stratum": {"list_row": {"abstention_rate": abstention, "false_merge_rate": 0.0}},
        "outcomes": outcomes,
    }


def test_decision_diff_lists_only_changed_cases_with_their_kind():
    before = _reading(
        [_outcome("a", "abstain", None), _outcome("b", "accept", "OL1W", correct=True),
         _outcome("c", "accept", "OL1W", correct=True), _outcome("d", "accept", "OL1W", correct=True)],
        0.25,
    )
    after = _reading(
        [_outcome("a", "accept", "OL1W", correct=True), _outcome("b", "accept", "OL1W", correct=True),
         _outcome("c", "accept", "OL2W"), _outcome("d", "abstain", None)],
        0.25,
    )
    rows = {r.case_id: r for r in decision_diff(before, after)}
    assert set(rows) == {"a", "c", "d"}
    assert rows["a"].change == "newly_accepted" and rows["a"].after_correct
    assert rows["c"].change == "key_changed" and not rows["c"].after_correct
    assert rows["d"].change == "newly_abstained"


def test_metric_rows_pairs_before_and_after_values():
    rows = metric_rows(_reading([], 0.9), _reading([], 0.3), stratum="list_row")
    assert ("abstention_rate", 0.9, 0.3) in rows


def test_markdown_names_both_readings_and_every_changed_case():
    before = _reading([_outcome("a", "abstain", None)], 1.0)
    after = _reading([_outcome("a", "accept", "OL1W", correct=True)], 0.0)
    text = render_markdown(before, after)
    assert "| abstention_rate |" in text
    assert "a" in text and "newly_accepted" in text
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_compare.py -q`
Expected: FAIL with `ModuleNotFoundError: openlibrary.eval.compare`.

- [ ] **Step 3: Implement**

```python
"""Compare two saved harness readings (`harness.write_reading`).

The before/after evaluation of the 2026-10-04 spec: the same labelled cases
scored by two matcher versions, side by side, plus every case whose decision
changed, so each new accept can be read by hand.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

import typer
from pydantic import BaseModel

app = typer.Typer(add_completion=False)

METRICS = (
    "precision_at_accept",
    "false_merge_rate",
    "false_reject_rate",
    "abstention_rate",
    "correct_no_match_rate",
    "canonical_rate",
    "list_row_abstention_rate",
    "list_row_false_merge_rate",
)

Change = Literal["newly_accepted", "newly_abstained", "newly_rejected", "key_changed", "other"]


class DiffRow(BaseModel):
    case_id: str
    stratum: str
    change: Change
    before_verdict: str
    before_key: str | None
    after_verdict: str
    after_key: str | None
    expected_key: str | None
    after_correct: bool


def load_reading(path: Path) -> dict:
    return json.loads(Path(path).read_text())


def metric_rows(before: dict, after: dict, *, stratum: str | None = None) -> list[tuple[str, float, float]]:
    b = before["by_stratum"].get(stratum, {}) if stratum else before["metrics"]
    a = after["by_stratum"].get(stratum, {}) if stratum else after["metrics"]
    return [(name, b.get(name, 0.0), a.get(name, 0.0)) for name in METRICS if name in b or name in a]


def _change(before: dict, after: dict) -> Change:
    bv, av = before["decision"]["verdict"], after["decision"]["verdict"]
    if bv != av:
        return {"accept": "newly_accepted", "abstain": "newly_abstained", "reject": "newly_rejected"}[av]
    if av == "accept" and before["decision"]["work_key"] != after["decision"]["work_key"]:
        return "key_changed"
    return "other"


def decision_diff(before: dict, after: dict) -> list[DiffRow]:
    earlier = {o["case_id"]: o for o in before["outcomes"]}
    rows = []
    for later in after["outcomes"]:
        prior = earlier.get(later["case_id"])
        if prior is None:
            continue
        same_verdict = prior["decision"]["verdict"] == later["decision"]["verdict"]
        same_key = prior["decision"]["work_key"] == later["decision"]["work_key"]
        if same_verdict and same_key:
            continue
        rows.append(
            DiffRow(
                case_id=later["case_id"],
                stratum=later["stratum"],
                change=_change(prior, later),
                before_verdict=prior["decision"]["verdict"],
                before_key=prior["decision"]["work_key"],
                after_verdict=later["decision"]["verdict"],
                after_key=later["decision"]["work_key"],
                expected_key=later["expected_work_key"],
                after_correct=later["correct"],
            )
        )
    return sorted(rows, key=lambda r: (r.change, r.stratum, r.case_id))


def _table(rows: list[tuple[str, float, float]]) -> list[str]:
    lines = ["| metric | before | after |", "|---|---|---|"]
    lines += [f"| {name} | {b:.4f} | {a:.4f} |" for name, b, a in rows]
    return lines


def render_markdown(before: dict, after: dict) -> str:
    out = [
        f"## Before: `{before['label']}` (matcher {before['matcher_version']}) · "
        f"After: `{after['label']}` (matcher {after['matcher_version']})",
        "",
        "### Overall",
        *_table(metric_rows(before, after)),
    ]
    for stratum in sorted(set(before["by_stratum"]) | set(after["by_stratum"])):
        out += ["", f"### {stratum}", *_table(metric_rows(before, after, stratum=stratum))]
    diff = decision_diff(before, after)
    out += [
        "",
        f"### Decision diff ({len(diff)} cases)",
        "",
        "| case | stratum | change | before | after | labelled | correct after | hand review |",
        "|---|---|---|---|---|---|---|---|",
    ]
    out += [
        f"| {r.case_id} | {r.stratum} | {r.change} | {r.before_verdict} {r.before_key or ''} | "
        f"{r.after_verdict} {r.after_key or ''} | {r.expected_key or ''} | {r.after_correct} | |"
        for r in diff
    ]
    return "\n".join(out) + "\n"


@app.command()
def main(
    before: Path = typer.Option(..., "--before"),  # noqa: B008
    after: Path = typer.Option(..., "--after"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    text = render_markdown(load_reading(before), load_reading(after))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    typer.echo(f"wrote {out}")


if __name__ == "__main__":
    app()
```

The "hand review" column is filled in by hand in Task 16.

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_compare.py -q`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/compare.py data-sources/tests/openlibrary/test_compare.py
git commit -m "OL eval: before/after comparison report between two saved readings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: List-row pool (export plus `build_list_rows.py`)

**Files:**
- Modify: `data-sources/src/openlibrary/eval/build_pool.py` (`PoolEntry.hint_work_keys`)
- Create: `data-sources/src/openlibrary/eval/build_list_rows.py`
- Test: `data-sources/tests/openlibrary/test_build_list_rows.py`

**Interfaces:**
- Consumes: `build_pool.naive_candidates(con, paths, books) -> dict[int, list[PoolCandidate]]` and `PoolEntry`, `GeneratedCandidateKey`.
- Produces:
  - `split_authors(raw: str | list[str] | None) -> list[str]`
  - `ListRow` pydantic model with fields `list_item_id: int, md5_rank: int, title: str, authors: str | list[str] | None, book_id: int, book_ol_work_keys: list[str]`
  - `select_rows(rows: list[ListRow], *, skip_ranks_through: int = 200, n: int = 150) -> list[ListRow]`
  - `to_book(row: ListRow) -> EvalBook`
  - CLI `--root --dump-date --rows PATH --out PATH`
  - `PoolEntry.hint_work_keys: list[str]` (default `[]`)

- [ ] **Step 1: Write the failing tests**

```python
from openlibrary.eval.build_list_rows import ListRow, select_rows, split_authors, to_book


def test_split_authors_splits_on_and_ampersand_and_semicolon():
    assert split_authors("Jaime Hernandez and Gilbert Hernandez") == ["Jaime Hernandez", "Gilbert Hernandez"]
    assert split_authors("A. Smith & B. Jones; C. Lee") == ["A. Smith", "B. Jones", "C. Lee"]


def test_split_authors_keeps_a_comma_inside_one_name():
    # "Jr." and "Last, First" forms carry commas; commas are never split points.
    assert split_authors("Martin Luther King, Jr.") == ["Martin Luther King, Jr."]


def test_split_authors_accepts_a_list_and_drops_blanks():
    assert split_authors(["Toni Morrison", " ", ""]) == ["Toni Morrison"]
    assert split_authors(None) == []


def _row(item, rank, book, **kw):
    return ListRow(list_item_id=item, md5_rank=rank, title=kw.get("title", f"T{item}"),
                   authors="A", book_id=book, book_ol_work_keys=kw.get("keys", []))


def test_select_rows_skips_the_spike_ranks_and_takes_distinct_books_in_rank_order():
    rows = [_row(1, 1, 10), _row(2, 201, 11), _row(3, 202, 11), _row(4, 203, 12), _row(5, 150, 13)]
    picked = select_rows(rows, skip_ranks_through=200, n=2)
    assert [r.list_item_id for r in picked] == [2, 4]


def test_to_book_carries_no_identifiers_no_year_and_no_existing_keys():
    book = to_book(_row(7, 300, 70, title="THE CITY IN HISTORY: Its Origins", keys=["OL1W"]))
    assert book.book_id == 70
    assert book.title == "THE CITY IN HISTORY: Its Origins"
    assert book.first_published_year is None
    assert book.isbn13 == [] and book.existing_ol_work_keys == []
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_build_list_rows.py -q`
Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement**

In `build_pool.py`, add to `PoolEntry`:

```python
    # Open Library keys our catalog already stores for this case's book. A
    # research HINT only (they are untrusted: see schema.py), never passed to
    # the matcher and never the label by default.
    hint_work_keys: list[str] = Field(default_factory=list)
```

Create `build_list_rows.py`:

```python
"""Build the `list_row` pool: legacy books list items as cases.

Each case is a list row exactly as a list page gave it: `metadata.title` and
`metadata.authors` from the legacy list item, no year, no identifiers, no
existing key -- the shape the books list wizard sends `/resolve`. The linked
book's stored Open Library keys ride along as `hint_work_keys` for the
researcher, never as the label.

The export ranks rows by md5(list_items.id); the 2026-10-04 spike examined
ranks 1-200, so those are skipped here and the cases are held out from the
analysis that shaped the design.

Like build_pool, this module must not import openlibrary.matcher.
"""

from __future__ import annotations

import re
from pathlib import Path

import typer
from pydantic import BaseModel, Field

from openlibrary.eval.build_pool import GeneratedCandidateKey, PoolEntry, naive_candidates
from openlibrary.eval.schema import EvalBook
from openlibrary.pipeline.paths import ArtifactPaths

app = typer.Typer(add_completion=False)

_AUTHOR_SPLIT = re.compile(r"\s*;\s*|\s+&\s+|\s+and\s+", re.IGNORECASE)


class ListRow(BaseModel):
    list_item_id: int
    md5_rank: int
    title: str
    authors: str | list[str] | None = None
    book_id: int
    book_ol_work_keys: list[str] = Field(default_factory=list)


def split_authors(raw: str | list[str] | None) -> list[str]:
    """Split a list row's author text into names. Commas never split: they
    sit inside "King, Jr." and "Last, First"."""
    if not raw:
        return []
    parts = raw if isinstance(raw, list) else [raw]
    names = [name.strip() for part in parts for name in _AUTHOR_SPLIT.split(str(part))]
    return [name for name in names if name]


def select_rows(rows: list[ListRow], *, skip_ranks_through: int = 200, n: int = 150) -> list[ListRow]:
    picked: list[ListRow] = []
    seen_books: set[int] = set()
    for row in sorted(rows, key=lambda r: r.md5_rank):
        if row.md5_rank <= skip_ranks_through or row.book_id in seen_books:
            continue
        seen_books.add(row.book_id)
        picked.append(row)
        if len(picked) == n:
            break
    return picked


def to_book(row: ListRow) -> EvalBook:
    return EvalBook(book_id=row.book_id, title=row.title, author_names=split_authors(row.authors))


def load_rows(path: Path) -> list[ListRow]:
    with Path(path).open(encoding="utf-8") as fh:
        return [ListRow.model_validate_json(line) for line in fh if line.strip()]


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    rows_path: Path = typer.Option(..., "--rows"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    from openlibrary.pipeline.duck import connect

    rows = select_rows(load_rows(rows_path))
    books = [to_book(r) for r in rows]
    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="8GB")
    candidates = naive_candidates(con, paths, books)
    con.close()

    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        for index, (row, book) in enumerate(zip(rows, books, strict=True), start=1):
            generated = candidates.get(book.book_id, [])
            ranked = sorted(generated, key=lambda c: (-c.readinglog_count, -c.edition_count, c.work_key))
            entry = PoolEntry(
                case_id=f"list_row-{index:03d}",
                stratum="list_row",
                book=book,
                candidates=ranked[:20],
                all_generated=[GeneratedCandidateKey(work_key=c.work_key, rules=c.rules) for c in generated],
                hint_work_keys=row.book_ol_work_keys,
            )
            fh.write(entry.model_dump_json() + "\n")
    typer.echo(f"wrote {len(rows)} list-row pool entries to {out}")


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_build_list_rows.py tests/openlibrary/test_build_pool.py tests/openlibrary/test_label_cli.py -q`
Expected: PASS.

- [ ] **Step 5: Export the list rows from the development database (read-only)**

Write this script to the session scratchpad as `export_list_rows.rb`, not into the repo. It only reads:

```ruby
# Read-only export of legacy books list items that still carry the original list text.
require "json"
out = ENV.fetch("OUT")
sql = <<~SQL
  SELECT list_items.id AS list_item_id,
         ROW_NUMBER() OVER (ORDER BY md5(list_items.id::text)) AS md5_rank,
         list_items.metadata->>'title' AS title,
         list_items.metadata->'authors' AS authors,
         list_items.listable_id AS book_id
  FROM list_items JOIN lists ON lists.id = list_items.list_id
  WHERE lists.type = 'Books::List'
    AND list_items.metadata ? 'title'
    AND list_items.listable_id IS NOT NULL
SQL
rows = ActiveRecord::Base.connection.select_all(sql).to_a
keys = Identifier.where(identifiable_type: "Books::Book", identifier_type: :books_work_openlibrary_id,
  identifiable_id: rows.map { _1["book_id"] }).pluck(:identifiable_id, :value)
  .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
File.open(out, "w") do |f|
  rows.each do |r|
    authors = r["authors"] ? JSON.parse(r["authors"]) : nil
    f.puts({list_item_id: r["list_item_id"], md5_rank: r["md5_rank"], title: r["title"],
            authors: authors, book_id: r["book_id"], book_ol_work_keys: keys.fetch(r["book_id"], [])}.to_json)
  end
end
warn "exported #{rows.size} rows to #{out}"
```

Run from `web-app/`:
`OUT=/home/shane/ol-data/eval/list_rows_export.jsonl bin/rails runner <scratchpad>/export_list_rows.rb`
Expected: `exported 948 rows` (± a few if the dev database was refreshed).

The ranking must reproduce the spike's ordering, which was `ORDER BY md5(list_items.id::text)` over the same filter. Spot-check that ranks 1–3 are list items 41060, 40614 and 40929, the first three the spike examined. If they differ, stop and report; the hold-out depends on it.

- [ ] **Step 6: Build the pool**

Run: `cd data-sources && uv run --locked python -m openlibrary.eval.build_list_rows --dump-date 2026-07-31 --rows /home/shane/ol-data/eval/list_rows_export.jsonl --out /home/shane/ol-data/eval/list_row_pool.jsonl`
Expected: `wrote 150 list-row pool entries`. The pool lives outside the repo, like the original `pool.jsonl`.

- [ ] **Step 7: Lint and commit (code only)**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/build_pool.py data-sources/src/openlibrary/eval/build_list_rows.py data-sources/tests/openlibrary/test_build_list_rows.py
git commit -m "OL eval: build the list_row pool from legacy list items, spike ranks held out

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Alternate-key verifier

**Files:**
- Modify: `data-sources/src/openlibrary/eval/dataset.py`
- Test: `data-sources/tests/openlibrary/test_eval_dataset.py`

**Interfaces:**
- Produces:
  - `WorkFacts` pydantic model with fields `work_key: str, title: str | None, title_variants: list[str], author_names: list[str], author_fps: list[str], edition_count: int`
  - `fetch_work_facts(con, paths, keys: Iterable[str]) -> dict[str, WorkFacts]`
  - `alternate_problems(label_key: str, alternate: str, facts: dict[str, WorkFacts], resolved: dict[str, str]) -> list[str]`
  - `check_alternates(con, paths, cases) -> list[tuple[str, str, str]]`, returning `(case_id, alternate, problem)` tuples

- [ ] **Step 1: Write the failing tests**

```python
from openlibrary.eval.dataset import WorkFacts, alternate_problems, fetch_work_facts


def _facts(key, variants=("dune",), authors=("frank herbert",), editions=1):
    return WorkFacts(work_key=key, title=key, title_variants=list(variants),
                     author_names=list(authors), author_fps=list(authors), edition_count=editions)


def test_a_true_duplicate_has_no_problems():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W")}
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == []


def test_an_alternate_that_redirects_to_the_label_is_a_problem():  # Review Focus 3
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W")}
    problems = alternate_problems("OL1W", "OL2W", facts, resolved={"OL2W": "OL1W"})
    assert problems == ["redirects to the labelled work; not a duplicate"]


def test_an_alternate_missing_from_works_is_a_problem():
    assert alternate_problems("OL1W", "OL9W", {"OL1W": _facts("OL1W")}, resolved={}) == [
        "not in works"
    ]


def test_an_alternate_with_another_title_or_author_is_a_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W", variants=("children of dune",),
                                                     authors=("brian herbert",))}
    assert set(alternate_problems("OL1W", "OL2W", facts, resolved={})) == {
        "shares no title variant with the labelled work",
        "shares no author with the labelled work",
    }


def test_fetch_work_facts_reads_title_variants_and_authors(fixture_artifact, fixture_labelled_works):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        key, title, authors = fixture_labelled_works[0]
        facts = fetch_work_facts(con, fixture_artifact, [key])
    assert facts[key].title == title
    assert facts[key].title_variants
    assert facts[key].author_fps
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_eval_dataset.py -q`
Expected: FAIL with an import error.

- [ ] **Step 3: Implement**

Append to `dataset.py`:

```python
class WorkFacts(BaseModel):
    work_key: str
    title: str | None = None
    title_variants: list[str] = Field(default_factory=list)
    author_names: list[str] = Field(default_factory=list)
    author_fps: list[str] = Field(default_factory=list)
    edition_count: int = 0


def fetch_work_facts(
    con: duckdb.DuckDBPyConnection, paths: ArtifactPaths, keys: Iterable[str]
) -> dict[str, WorkFacts]:
    """Title variants, author names/fingerprints and edition count per work --
    what a duplicate claim is checked against and what a reviewer reads."""
    wanted = [k for k in dict.fromkeys(keys) if k]
    if not wanted:
        return {}
    load_rows(con, "facts_keys", [("work_key", "VARCHAR")], [(k,) for k in wanted])
    rows = con.execute(
        f"""
        WITH w AS (
          SELECT w.work_key, w.title, w.title_fp, w.title_fp_nosub, w.title_fp_noart
          FROM facts_keys k JOIN '{paths.table("works")}' w USING (work_key)
        ),
        a AS (
          SELECT wa.work_key, list(DISTINCT an.name ORDER BY an.name) AS names,
                 list(DISTINCT an.name_fp ORDER BY an.name_fp) AS fps
          FROM facts_keys k
          JOIN '{paths.table("work_authors")}' wa USING (work_key)
          JOIN '{paths.table("author_names")}' an USING (author_key)
          WHERE an.name IS NOT NULL
          GROUP BY wa.work_key
        ),
        p AS (
          SELECT p.work_key, p.edition_count
          FROM facts_keys k JOIN '{paths.table("popularity")}' p USING (work_key)
        )
        SELECT w.work_key, w.title, w.title_fp, w.title_fp_nosub, w.title_fp_noart,
               COALESCE(a.names, []), COALESCE(a.fps, []), COALESCE(p.edition_count, 0)
        FROM w LEFT JOIN a USING (work_key) LEFT JOIN p USING (work_key)
        """
    ).fetchall()
    return {
        r[0]: WorkFacts(
            work_key=r[0],
            title=r[1],
            title_variants=sorted({v for v in (r[2], r[3], r[4]) if v}),
            author_names=list(r[5]),
            author_fps=[fp for fp in r[6] if fp],
            edition_count=r[7],
        )
        for r in rows
    }


def alternate_problems(
    label_key: str, alternate: str, facts: dict[str, WorkFacts], resolved: dict[str, str]
) -> list[str]:
    """Why `alternate` is not a verified duplicate of `label_key` ([] when it is)."""
    if resolved.get(alternate, alternate) == resolved.get(label_key, label_key):
        return ["redirects to the labelled work; not a duplicate"]
    if alternate not in facts:
        return ["not in works"]
    label, alt = facts.get(label_key), facts[alternate]
    if label is None:
        return ["labelled work not in works"]
    problems = []
    if not set(label.title_variants) & set(alt.title_variants):
        problems.append("shares no title variant with the labelled work")
    if not set(label.author_fps) & set(alt.author_fps):
        problems.append("shares no author with the labelled work")
    return problems


def check_alternates(
    con: duckdb.DuckDBPyConnection, paths: ArtifactPaths, cases: Iterable[EvalCase]
) -> list[tuple[str, str, str]]:
    with_alternates = [c for c in cases if c.label.alternate_work_keys]
    keys = [k for c in with_alternates for k in (c.label.work_key, *c.label.alternate_work_keys)]
    resolved = resolve_keys(con, paths, keys)
    facts = fetch_work_facts(con, paths, [resolved.get(k, k) for k in keys])
    facts_by_original = {k: facts[resolved.get(k, k)] for k in keys if resolved.get(k, k) in facts}
    return [
        (case.case_id, alternate, problem)
        for case in with_alternates
        for alternate in case.label.alternate_work_keys
        for problem in alternate_problems(case.label.work_key, alternate, facts_by_original, resolved)
    ]
```

Add `from pydantic import BaseModel, Field` to the imports.

Then add an artifact test, next to `test_every_labeled_key_exists_in_the_real_artifact`:

```python
@pytest.mark.artifact
def test_every_alternate_is_a_verified_duplicate_in_the_real_artifact():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")
    from pathlib import Path

    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    with contextlib.closing(con):
        problems = check_alternates(con, paths, load_cases())
    assert problems == [], f"alternates that are not verified duplicates: {problems}"
```

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_eval_dataset.py -q`
Expected: PASS. The artifact test is skipped without the environment variables.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/dataset.py data-sources/tests/openlibrary/test_eval_dataset.py
git commit -m "OL eval: verify that every labelled alternate is a real OL duplicate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Spot-check sheet (`eval/spot_check.py`)

**Files:**
- Create: `data-sources/src/openlibrary/eval/spot_check.py`
- Test: `data-sources/tests/openlibrary/test_spot_check.py`

**Interfaces:**
- Consumes: `load_cases`, `fetch_work_facts`, `WorkFacts` (Task 5).
- Produces:
  - `sample_cases(cases, *, stratum: str | None, with_alternates: bool, n: int, seed: int) -> list[EvalCase]`
  - `render_sheet(cases, facts: dict[str, WorkFacts]) -> str`
  - CLI `--stratum --with-alternates --n --seed --out`

- [ ] **Step 1: Write the failing tests**

```python
import datetime

import pytest

from openlibrary.eval.dataset import WorkFacts
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel
from openlibrary.eval.spot_check import render_sheet, sample_cases


@pytest.fixture
def make_case():
    def build(case_id, *, stratum, work_key="OL1W", title="A Title"):
        return EvalCase(
            case_id=case_id,
            stratum=stratum,
            book=EvalBook(book_id=1, title=title, author_names=["Frank Herbert"]),
            label=EvalLabel(
                verdict="match",
                work_key=work_key,
                identity_rule="same_work",
                rationale="Matched by title and author.",
                labeled_at=datetime.date(2026, 10, 4),
                labeled_against_dump_date="2026-07-31",
                labeled_by="agent_researched",
            ),
        )

    return build


def test_sample_is_seeded_and_filtered(make_case):
    cases = [make_case(f"list_row-{i:03d}", stratum="list_row") for i in range(40)]
    cases += [make_case("easy_baseline-001", stratum="easy_baseline")]
    first = sample_cases(cases, stratum="list_row", with_alternates=False, n=30, seed=1)
    again = sample_cases(cases, stratum="list_row", with_alternates=False, n=30, seed=1)
    assert first == again
    assert len(first) == 30 and all(c.stratum == "list_row" for c in first)


def test_sheet_links_each_labelled_work_and_shows_its_title(make_case):
    case = make_case("list_row-001", stratum="list_row", work_key="OL1W", title="Dune")
    facts = {"OL1W": WorkFacts(work_key="OL1W", title="Dune", author_names=["Frank Herbert"],
                               edition_count=160)}
    sheet = render_sheet([case], facts)
    assert "https://openlibrary.org/works/OL1W" in sheet
    assert "Frank Herbert" in sheet and "160" in sheet
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_spot_check.py -q`
Expected: FAIL with `ModuleNotFoundError`.

- [ ] **Step 3: Implement**

```python
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

    chosen = sample_cases(load_cases(), stratum=stratum, with_alternates=with_alternates, n=n, seed=seed)
    keys = [k for c in chosen for k in (c.label.work_key, *c.label.alternate_work_keys) if k]
    paths = ArtifactPaths(root=root, dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    facts = fetch_work_facts(con, paths, keys)
    con.close()
    out.write_text(render_sheet(chosen, facts))
    typer.echo(f"wrote {len(chosen)} cases to {out}")


if __name__ == "__main__":
    app()
```

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_spot_check.py -q`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/spot_check.py data-sources/tests/openlibrary/test_spot_check.py
git commit -m "OL eval: seeded markdown spot-check sheet for researched labels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Research the labels, then Shane's spot-checks (human in the loop)

This task produces data, not code. It has two stop points where Shane must answer before anything continues.

**Files:**
- Create: `data-sources/src/openlibrary/eval/cases/list_rows.jsonl`
- Modify: `data-sources/src/openlibrary/eval/cases/labels.jsonl`, `data-sources/src/openlibrary/eval/cases/researched.jsonl` (add `alternate_work_keys` only; no other field changes)

**Inputs:** `/home/shane/ol-data/eval/list_row_pool.jsonl` (Task 4); `docs/guides/openlibrary-case-research-brief.md` (the research method, including the duplicate tiebreak: identifier-reached works first, then edition count > reading-log > revision > id types); the local OL API at `http://127.0.0.1:8080` (`/works/{key}`, `/works/{key}/editions`, `/authors/{key}/works`, `/identifiers/{type}/{value}`) and DuckDB over the artifact.

- [ ] **Step 1: Research the 150 list rows**

Split the pool into six batches of 25 (`list_row-001`…`025`, and so on). Give each batch to a research subagent (`model: "opus"`) with these instructions:
- Read the research brief.
- For each pool entry, decide which Open Library work is the book the list row names: a work key, or `not_in_open_library`, or `ambiguous` when the row itself does not identify one book (e.g. two books on one line).
- `hint_work_keys` are our catalog's stored keys: a lead to check, never the answer.
- Record every verified unmerged duplicate of the chosen work in `alternate_work_keys`. A verified duplicate is not a redirect, has the same normalized title, and shares an author. The chosen `work_key` is the canonical one by the brief's tiebreak.

Each line written to `cases/list_rows.jsonl` is an `EvalCase`:

```json
{"case_id": "list_row-001", "stratum": "list_row",
 "book": {"book_id": 70, "title": "<exactly the pool's title>", "author_names": ["..."]},
 "candidates_shown": [{"work_key": "OL...W", "rules": ["author_title"]}],
 "label": {"verdict": "match", "work_key": "OL...W", "alternate_work_keys": ["OL...W"],
           "identity_rule": "same_work",
           "rationale": "<what identified it: title, author, editions checked, why this duplicate is canonical>",
           "labeled_at": "<today>", "labeled_against_dump_date": "2026-07-31",
           "labeled_by": "agent_researched"}}
```

`candidates_shown` comes from `openlibrary.eval.label.candidates_shown_for(entry)`, so `found_outside_blocking` stays meaningful. `book` is copied from the pool entry unchanged.

- [ ] **Step 2: Propose alternates for the existing duplicate labels**

List the cases with `identity_rule == "duplicate_work"` in `labels.jsonl` and `researched.jsonl` (about 105). A research subagent (`model: "opus"`) reads each rationale and adds `alternate_work_keys` for the duplicates it names, checking each against the artifact.
- No other field changes: not the `work_key`, the verdict or the rationale.
- Rows are rewritten in place, keeping file order.

- [ ] **Step 3: Verify mechanically**

Run:

```bash
cd data-sources
uv run --locked pytest tests/openlibrary/test_eval_schema.py tests/openlibrary/test_eval_dataset.py -q
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run --locked pytest -m artifact tests/openlibrary/test_eval_dataset.py -q
```

Expected: PASS, including `test_every_labeled_key_exists_in_the_real_artifact` and `test_every_alternate_is_a_verified_duplicate_in_the_real_artifact`. Fix every reported problem by re-researching that case, not by deleting the alternate silently.

- [ ] **Step 4: STOP: Shane spot-checks the list rows**

Run: `uv run --locked python -m openlibrary.eval.spot_check --stratum list_row --n 30 --out /home/shane/ol-data/eval/spot-check-list-row.md`

Send Shane the absolute path and ask him to mark each row RIGHT or WRONG. Apply his corrections.
- **If more than 3 of the 30 are wrong:** re-research the whole 150, then generate a fresh sheet with `--seed 20261005`.
- **Otherwise:** record "Shane spot-checked 30/150 list rows on <date>: <k> corrected" for the docs (Task 16).

- [ ] **Step 5: STOP: Shane spot-checks the alternates**

Run: `uv run --locked python -m openlibrary.eval.spot_check --with-alternates --n 15 --out /home/shane/ol-data/eval/spot-check-alternates.md`

Same procedure. If more than 2 of the 15 are wrong, re-research every alternate.

- [ ] **Step 6: Commit**

```bash
git add data-sources/src/openlibrary/eval/cases/
git commit -m "OL eval: 150 researched list-row cases; verified alternates on duplicate labels

Spot-checked by Shane: <k>/30 list rows and <j>/15 alternates corrected.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Baseline reading with the current matcher

**Files:**
- Create: `data-sources/src/openlibrary/eval/readings/2026-10-v2-baseline.json`
- Create (outside the repo): `/home/shane/ol-data/eval/replay-v2.jsonl`

- [ ] **Step 1: Confirm the matcher is still version 2 and untouched**

Run: `git diff --stat main -- data-sources/src/openlibrary/matcher data-sources/src/common`
Expected: no output. The baseline must be the shipped matcher.

- [ ] **Step 2: Run the harness and save the reading (~45 minutes for ~600 cases)**

```bash
cd data-sources
uv run --locked python -m openlibrary.eval.harness --dump-date 2026-07-31 \
  --prepared-cache /home/shane/ol-data/tmp/prepared-v2-expanded.json \
  --reading-out src/openlibrary/eval/readings/2026-10-v2-baseline.json \
  --reading-label "v2 baseline, expanded set"
```

Expected: the summary prints. `list_row abstention` should be high (the spike measured 96.5%), and `max_abstention_rate` may exceed the pinned 0.70. That is expected: the gate is re-pinned in Task 15 and nothing merges before then.

- [ ] **Step 2b: Measure what the re-grading alone flipped**

The spec asks for the effect of duplicate-aware labels to be reported separately from the matcher change. Under version 2, an accept of a labelled alternate used to be a false merge and is now correct. Count those cases on the existing (non-`list_row`) strata with a one-off read of the saved reading:

```bash
uv run --locked python - <<'PY'
import json
r = json.load(open("src/openlibrary/eval/readings/2026-10-v2-baseline.json"))
flipped = [o for o in r["outcomes"]
           if o["stratum"] != "list_row" and o["correct"] and not o["canonical"]
           and o["expected_verdict"] == "match"]
print(len(flipped), "accepts of an alternate (were false merges before alternates existed):")
for o in flipped:
    print(" ", o["case_id"], o["decision"]["work_key"], "labelled", o["expected_work_key"])
PY
```

Record the count and the case ids for the report (Task 16, "Label provenance"). If the count is not 0, also note how the shipped reading 7's false-merge rate (0.0068) reads under the new grading.

- [ ] **Step 3: Rails replay against the version-2 service (writes nothing; costs a few cents of AI)**

Write `<scratchpad>/replay.rb`. It is the 2026-10-04 spike script, and it is reproduced in the report (Task 16, "Regenerating"):

```ruby
# Replays the 200 spike rows through the Rails book finder and OL /resolve.
# Writes NOTHING: every finder call runs in a transaction that is rolled back.
# Makes AI calls (the finder's candidate picker): a few cents per run.
require "json"
out = ENV.fetch("OUT")

def split_authors(value)
  Array(value).flat_map { |s| s.to_s.split(/\s*;\s*|\s+&\s+|\s+and\s+/i) }.map(&:strip).reject(&:blank?)
end

items = ListItem.joins(:list).where(lists: {type: "Books::List"})
  .where("list_items.metadata ? 'title'").where.not(listable_id: nil)
  .order(Arel.sql("md5(list_items.id::text)")).limit(200).includes(:listable).to_a
client = Books::OpenLibrary::Client.new

File.open(out, "w") do |f|
  items.each_with_index do |li, i|
    title = li.metadata["title"].to_s
    authors = split_authors(li.metadata["authors"])
    label_keys = Identifier.where(identifiable: li.listable, identifier_type: :books_work_openlibrary_id).pluck(:value)
    row = {id: li.id, title: title, authors: authors, label_id: li.listable_id, label_ol: label_keys}
    begin
      ActiveRecord::Base.transaction do
        match = DataImporters::Books::Book::Finder.new.call(
          query: DataImporters::Books::Book::ImportQuery.new(title: title, author_names: authors)
        )
        row[:finder] = {outcome: match.outcome, confidence: match.confidence, decided_by: match.decided_by,
                        record_id: match.record&.id, correct: match.record&.id == li.listable_id,
                        needs_review: match.needs_review?, reason: match.reason.to_s[0, 300]}
        raise ActiveRecord::Rollback
      end
    rescue => e
      row[:finder_error] = "#{e.class}: #{e.message[0, 200]}"
    end
    begin
      r = client.resolve(title: title, author_names: authors)
      row[:ol] = {verdict: r.decision.verdict, key: r.decision.key, score: r.decision.score,
                  margin: r.decision.margin, reason: r.decision.reason.to_s[0, 200],
                  agrees_with_stored_key: label_keys.any? ? label_keys.include?(r.decision.key) : nil}
    rescue => e
      row[:ol_error] = "#{e.class}: #{e.message[0, 200]}"
    end
    f.puts(row.to_json)
    warn "#{i + 1}/#{items.size}" if ((i + 1) % 20).zero?
  end
end
```

The first three ids written must be 41060, 40614 and 40929, the same rows as the spike.

Confirm the service on port 8080 is version 2: `curl -s http://127.0.0.1:8080/version` reports `"matcher_version":2`.

Run from `web-app/`: `OUT=/home/shane/ol-data/eval/replay-v2.jsonl OPEN_LIBRARY_SERVICE_URL=http://127.0.0.1:8080 bin/rails runner <scratchpad>/replay.rb`

- [ ] **Step 4: Commit the reading**

```bash
git add data-sources/src/openlibrary/eval/readings/2026-10-v2-baseline.json
git commit -m "OL eval: baseline reading of the shipped matcher on the expanded set

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

# Phase 2 — the matcher

### Task 9: Query title variants and `compare_titles`

**Files:**
- Modify: `data-sources/src/common/normalize.py`
- Modify: `data-sources/src/common/scoring.py`
- Test: `data-sources/tests/common/test_normalize.py`, `data-sources/tests/common/test_scoring.py`

**Interfaces:**
- Produces:
  - `QueryTitleVariants(whole: frozenset[str], derived: frozenset[str], derived_subtitle: str | None)`
  - `query_title_variants(title: str | None) -> QueryTitleVariants`
  - `fuzzy_similarity(left, right) -> float | None` (the old `title_similarity`, renamed, behavior unchanged)
  - `TitleComparison(similarity: float | None, exact: float | None, containment: bool)`
  - `compare_titles(whole: Iterable[str], derived: Iterable[str], work_variants: Iterable[str]) -> TitleComparison`
  - `DERIVED_TITLE_FACTOR = 0.95`

- [ ] **Step 1: Write the failing tests**

In `tests/common/test_normalize.py`:

```python
from common.normalize import query_title_variants


def test_a_plain_title_has_no_derived_variants():
    v = query_title_variants("The Great Gatsby")
    assert v.whole == {"the great gatsby", "great gatsby"}
    assert v.derived == frozenset()
    assert v.derived_subtitle is None


def test_an_inline_subtitle_yields_a_derived_title_and_subtitle():
    v = query_title_variants("THE CITY IN HISTORY: Its Origins, Its Transformations")
    assert "the city in history" in v.derived
    assert "city in history" in v.derived
    assert v.derived_subtitle == "Its Origins, Its Transformations"


def test_a_parenthetical_is_a_subtitle_cut_too():
    v = query_title_variants("Fahrenheit 451 (Ballantine)")
    assert v.derived == {"fahrenheit 451"}
    assert v.derived_subtitle == "Ballantine"


def test_a_degenerate_title_has_no_variants():
    v = query_title_variants("!!!")
    assert v.whole == frozenset() and v.derived == frozenset()
```

Rename the existing `title_similarity` tests in `tests/common/test_scoring.py` to `fuzzy_similarity` (same assertions), and add:

```python
from common.scoring import DERIVED_TITLE_FACTOR, compare_titles


def _cmp(query, work_variants):
    from common.normalize import query_title_variants

    v = query_title_variants(query)
    return compare_titles(v.whole, v.derived, work_variants)


def test_a_sequel_is_no_longer_a_perfect_title_match():
    c = _cmp("Dune", ["children of dune", "children of dune", "children of dune"])
    assert c.similarity < 0.6
    assert c.exact == 0.0
    assert c.containment is True


def test_a_longer_title_containing_ours_is_far_from_perfect():
    assert _cmp("The Road", ["the road to wigan pier", "the road to wigan pier", "road to wigan pier"]).similarity < 0.6


def test_one_shared_word_is_not_a_near_match():
    assert _cmp("The Wife", ["the interestings", "the interestings", "interestings"]).similarity < 0.6


def test_a_work_subtitle_is_matched_through_its_stored_variant():
    c = _cmp("Emma", ["emma a novel", "emma", "emma a novel"])
    assert c.similarity == 1.0 and c.exact == 1.0


def test_an_inline_query_subtitle_matches_through_a_derived_variant():
    c = _cmp("THE CITY IN HISTORY: Its Origins", ["the city in history", "the city in history", "city in history"])
    assert c.exact == 1.0
    assert c.similarity == DERIVED_TITLE_FACTOR


def test_full_title_match_outranks_a_subtitle_dropped_match():  # Review Focus 1
    own = _cmp("Star Wars: A New Hope", ["star wars a new hope", "star wars", "star wars a new hope"])
    other = _cmp("Star Wars: A New Hope", ["star wars", "star wars", "star wars"])
    assert own.similarity == 1.0
    assert other.similarity == DERIVED_TITLE_FACTOR


def test_an_empty_side_is_absence_not_disagreement():
    assert _cmp("!!!", ["dune", "dune", "dune"]) == compare_titles([], [], ["dune"])
    assert compare_titles(["dune"], [], ["", "", ""]).similarity is None


def test_reordered_titles_still_match():
    assert _cmp("Gatsby the Great", ["the great gatsby", "the great gatsby", "great gatsby"]).similarity > 0.85
```

`own` matches through the work's full fingerprint at 1.0. `other` matches only through the derived variant "star wars", capped at 0.95. Note the work's `nosub` variant "star wars" also equals the derived variant for `own`, so `own.exact` is 1.0 either way. The similarity gap is what separates them.

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/common -q`
Expected: FAIL with import errors.

- [ ] **Step 3: Implement**

In `normalize.py`, after `title_fingerprints`:

```python
@dataclass(frozen=True)
class QueryTitleVariants:
    """A query title's fingerprints for comparison against a work's stored
    variants (2026-10-04 spec, section 2).

    `whole`: the title as given, with and without a leading article.
    `derived`: the same after the subtitle cut, only where that differs from
    `whole` -- a match through these counts for less (scoring.DERIVED_TITLE_FACTOR),
    since the colon may be part of the title. `derived_subtitle`: the raw text
    the cut removed, for subtitle agreement when the query has no subtitle.
    Computed at query time only; stored fingerprints are unchanged.
    """

    whole: frozenset[str]
    derived: frozenset[str]
    derived_subtitle: str | None


def query_title_variants(title: str | None) -> QueryTitleVariants:
    fps = title_fingerprints(title)
    whole = frozenset(v for v in (fps.full, fps.noart) if v)
    derived: frozenset[str] = frozenset()
    derived_subtitle = None
    if fps.nosub and fps.nosub != fps.full:
        stripped = _LEADING_ARTICLE.sub("", fps.nosub)
        candidates = {fps.nosub, stripped if len(stripped) >= MIN_BLOCKING_FP_LENGTH else fps.nosub}
        derived = frozenset(candidates - whole)
        head = _SUBTITLE_CUT.match(title or "").group(1)
        rest = (title or "")[len(head) + 1 :].strip().rstrip(")").strip()
        derived_subtitle = rest if fingerprint(rest) else None
    return QueryTitleVariants(whole=whole, derived=derived, derived_subtitle=derived_subtitle)
```

In `scoring.py`, rename `title_similarity` to `fuzzy_similarity` with the same body and docstring. Note in the docstring that it now serves author names and subtitles, where token-set's subset credit is wanted ("tolkien" vs "j r r tolkien"). Then add:

```python
from collections.abc import Iterable
from dataclasses import dataclass

# A match through a query variant that only exists after the subtitle cut
# counts for at most this: the colon may be part of the title ("Star Wars: A
# New Hope"), and a full-title match must outrank it (2026-10-04 spec, section 2).
DERIVED_TITLE_FACTOR = 0.95


@dataclass(frozen=True)
class TitleComparison:
    similarity: float | None
    exact: float | None
    containment: bool


def _strictly_contains(a: str, b: str) -> bool:
    left, right = set(a.split()), set(b.split())
    return left != right and (left < right or right < left)


def compare_titles(
    whole: Iterable[str], derived: Iterable[str], work_variants: Iterable[str]
) -> TitleComparison:
    """Variant-aware, length-sensitive title comparison (replaces the
    token-set/WRatio max for titles: "Dune" vs "Children of Dune" was 1.0, and
    any shared word was 0.855 -- 2026-10-04 spec, D1).

    `similarity`: the best token_sort ratio over (query variant, work variant)
    pairs, derived pairs scaled by DERIVED_TITLE_FACTOR. `exact`: 1.0 when any
    query variant equals any work variant, else 0.0. `containment`: some pair
    is a strict token subset -- the scorer may grant it calibrated credit.
    None/None/False when either side has no fingerprint (R40: absence).
    """
    works = {w for w in work_variants if w}
    whole_set, derived_set = set(whole), set(derived)
    ours = whole_set | derived_set
    if not works or not ours:
        return TitleComparison(similarity=None, exact=None, containment=False)
    best = 0.0
    for q in whole_set:
        for w in works:
            best = max(best, fuzz.token_sort_ratio(q, w) / 100.0)
    for q in derived_set:
        for w in works:
            best = max(best, DERIVED_TITLE_FACTOR * fuzz.token_sort_ratio(q, w) / 100.0)
    return TitleComparison(
        similarity=best,
        exact=1.0 if ours & works else 0.0,
        containment=any(_strictly_contains(q, w) for q in ours for w in works),
    )
```

Update the module docstring's comparator list to name `fuzzy_similarity` and `compare_titles`.

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/common -q`
Expected: PASS. (`features.py` still imports `title_similarity`; Task 10 fixes it. Run only `tests/common` here.)

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src/common tests/common && uv run --locked ruff format --check src/common tests/common
cd .. && git add data-sources/src/common data-sources/tests/common
git commit -m "OL matcher: variant-aware, length-sensitive title comparison

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Features and scorer: new title features, containment credit, `Weights` fields

**Files:**
- Modify: `data-sources/src/openlibrary/matcher/features.py`
- Modify: `data-sources/src/openlibrary/matcher/scorer.py`
- Modify: `data-sources/src/openlibrary/matcher/decide.py` (import `has_identity_evidence` from the scorer)
- Modify: `data-sources/src/openlibrary/eval/harness.py` (`PreparedCandidate.title_containment`, passed through)
- Test: `data-sources/tests/openlibrary/test_features.py`, `data-sources/tests/openlibrary/test_scorer.py`

**Interfaces:**
- Consumes: `query_title_variants`, `compare_titles`, `fuzzy_similarity` (Task 9).
- Produces:
  - `features.title_containment(query: BlockingQuery, work: WorkView) -> bool`
  - `scorer.has_identity_evidence(candidate: ScoredCandidate) -> bool`, with `IDENTITY_FEATURES` and `IDENTIFIER_FEATURE` moved to `scorer.py` and re-exported from `decide.py`
  - `score_features(work_key, values, found_conflicts, rules, weights, *, title_containment: bool = False)`
  - `Weights.subset_title_credit: float = 0.0`, `Weights.duplicate_dominance_ratio: float = 3.0`
  - `PreparedCandidate.title_containment: bool = False`

- [ ] **Step 1: Write the failing tests**

In `test_features.py`:

```python
from openlibrary.matcher.features import title_containment


def test_a_sequel_title_is_no_longer_a_perfect_title_similarity():
    values = extract(
        BlockingQuery(title="Dune"),
        _work(title="Children of Dune", title_fp="children of dune",
              title_fp_nosub="children of dune", title_fp_noart="children of dune"),
    )
    assert values["title_similarity"] < 0.6
    assert values["title_variant_exact"] == 0.0


def test_an_inline_query_subtitle_matches_exactly_and_feeds_subtitle_agreement():
    values = extract(
        BlockingQuery(title="The Great Gatsby: A Novel"),
        _work(subtitle="A Novel"),
    )
    assert values["title_variant_exact"] == 1.0
    assert values["subtitle_agreement"] == 1.0


def test_an_explicit_subtitle_wins_over_a_derived_one():
    values = extract(
        BlockingQuery(title="The Great Gatsby: A Novel", subtitle="Something Else"),
        _work(subtitle="A Novel"),
    )
    assert values["subtitle_agreement"] < 1.0


def test_title_containment_flags_a_strict_subset_pair():
    assert title_containment(BlockingQuery(title="Ulysses A Novel"),
                             _work(title="Ulysses", title_fp="ulysses",
                                   title_fp_nosub="ulysses", title_fp_noart="ulysses"))
    assert not title_containment(BlockingQuery(title="The Great Gatsby"), _work())
```

`test_every_declared_feature_is_returned` stays as it is: `extract` still returns exactly `FEATURES`.

In `test_scorer.py` (it has a `_weights_payload` helper):

```python
def test_containment_credit_raises_title_similarity_to_the_calibrated_floor():
    weights = Weights.model_validate({**_weights_payload(), "subset_title_credit": 0.8})
    values = {name: None for name in FEATURES}
    values["title_similarity"] = 0.4
    plain = score_features("OL1W", values, [], [], weights)
    credited = score_features("OL1W", values, [], [], weights, title_containment=True)
    assert credited.evidence["title_similarity"]["value"] == 0.8
    assert plain.evidence["title_similarity"]["value"] == 0.4


def test_zero_credit_leaves_a_contained_title_alone():
    weights = Weights.model_validate(_weights_payload())
    values = {name: None for name in FEATURES}
    values["title_similarity"] = 0.4
    scored = score_features("OL1W", values, [], [], weights, title_containment=True)
    assert scored.evidence["title_similarity"]["value"] == 0.4


def test_new_weights_fields_default_when_absent():
    weights = Weights.model_validate(_weights_payload())
    assert weights.subset_title_credit == 0.0
    assert weights.duplicate_dominance_ratio == 3.0
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_features.py tests/openlibrary/test_scorer.py -q`
Expected: FAIL (import error on `title_similarity` and `title_containment`; unknown keyword `title_containment`).

- [ ] **Step 3: Implement**

In `features.py`:
- Imports: `from common.normalize import fingerprint, query_title_variants` and `from common.scoring import compare_titles, fuzzy_similarity, identifier_agreement, set_overlap, year_agreement`.
- Replace the title block in `extract` (the `ours = fingerprint(query.title)` through the subtitle block) with:

```python
    # Variant-aware title comparison (2026-10-04 spec, section 2). Absence
    # stays absence (R40): no fingerprint on either side -> None, not 0.0.
    variants = query_title_variants(query.title)
    comparison = compare_titles(
        variants.whole, variants.derived, (work.title_fp, work.title_fp_nosub, work.title_fp_noart)
    )
    title_score = comparison.similarity
    variant_score = comparison.exact

    our_authors = {fingerprint(n) for n in query.author_names if fingerprint(n)}
    their_authors = {fingerprint(n) for n in work.author_names if fingerprint(n)}

    author_similarity: float | None = None
    if our_authors and their_authors:
        author_similarity = max(fuzzy_similarity(a, b) for a in our_authors for b in their_authors)

    # An explicit subtitle wins; otherwise the one the title carried inline.
    our_subtitle = query.subtitle or variants.derived_subtitle
    subtitle_score: float | None = None
    if our_subtitle and work.subtitle:
        subtitle_score = fuzzy_similarity(fingerprint(our_subtitle), fingerprint(work.subtitle))
```

- Add after `extract`:

```python
def title_containment(query: BlockingQuery, work: WorkView) -> bool:
    """Whether some title-variant pair is a strict token subset ("Ulysses a
    novel" vs "Ulysses"). Not a feature: the scorer turns it into the
    calibrated `subset_title_credit`, so `extract` stays weight-independent."""
    variants = query_title_variants(query.title)
    return compare_titles(
        variants.whole, variants.derived, (work.title_fp, work.title_fp_nosub, work.title_fp_noart)
    ).containment
```

In `scorer.py`:
- Move `IDENTITY_FEATURES`, `IDENTIFIER_FEATURE` and the body of `_has_identity_evidence` here as public `has_identity_evidence(candidate: ScoredCandidate) -> bool`, defined after `ScoredCandidate` with the same docstring.
- Add to `Weights`:

```python
    # Calibrated title credit for a strict token-subset title pair (spec section 2);
    # 0.0 = containment earns nothing beyond its token_sort ratio.
    subset_title_credit: float = 0.0
    # How many times the next member's edition count a duplicate cluster's
    # top member needs before it represents the cluster (spec section 4).
    duplicate_dominance_ratio: float = 3.0
```

- In `score_features`, add the keyword parameter `title_containment: bool = False`, and before the loop:

```python
    if title_containment and values.get("title_similarity") is not None:
        values = {
            **values,
            "title_similarity": max(values["title_similarity"], weights.subset_title_credit),
        }
```

- In `score_candidate`, compute `title_containment(query, work)` (import it from `features`) and pass it.

In `decide.py`: `from openlibrary.matcher.scorer import IDENTIFIER_FEATURE, IDENTITY_FEATURES, ScoredCandidate, Weights, has_identity_evidence`. Delete the local definitions and keep `_has_identity_evidence = has_identity_evidence`, so existing imports and tests keep working.

In `harness.py`:
- Add `title_containment: bool = False` to `PreparedCandidate`.
- In `prepare`, set `title_containment=title_containment(query, views[key])` (import it from features).
- In `evaluate`, pass `title_containment=c.title_containment` to `score_features`.

- [ ] **Step 4: Run the whole suite**

Run: `cd data-sources && uv run --locked pytest -q`
Expected: PASS, except tests that pinned the old title similarity's numbers. Update those to the new semantics, and in each test's docstring or commit message name the defect (D1) that made the old number wrong. `test_eval_regression`'s artifact test is skipped without the environment variables.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src data-sources/tests
git commit -m "OL matcher: variant title features, derived subtitle, containment credit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: `decide`: identity-first ranking and identity-aware margin

**Files:**
- Modify: `data-sources/src/openlibrary/matcher/decide.py`
- Test: `data-sources/tests/openlibrary/test_decide.py`

**Interfaces:**
- Produces: `rank(candidates, clusters=None)` and `margins(ranked, clusters=None) -> list[float]`. `clusters` is typed as `ClusterIndex | None` in Task 12; in this task the parameter exists and only `None` is handled. `decide(..., clusters=None)`.

- [ ] **Step 1: Write the failing tests**

Add to `test_decide.py` (it has `_c(work_key, score, conflicts=None, evidence=None)`, and `_c` with `evidence=None` gives title evidence):

```python
def _titleless(work_key, score):
    return _c(work_key, score, evidence={
        "author_overlap": {"value": 1.0, "weight": 1.0, "contribution": 1.0},
        "title_similarity": {"value": None, "weight": 1.0, "contribution": 0.0},
    })


def test_a_titleless_translation_cannot_outrank_the_titled_work():
    ordered = rank([_titleless("OLHEBW", 0.913), _c("OLREALW", 0.885)])
    assert [c.work_key for c in ordered] == ["OLREALW", "OLHEBW"]


def test_a_titleless_runner_up_does_not_set_the_margin():
    decision = decide([_c("OLREALW", 0.974), _titleless("OLHEBW", 0.913)], _equal_weights())
    assert decision.verdict == "accept"
    assert decision.margin == pytest.approx(0.974)


def test_with_only_titleless_candidates_it_still_abstains_for_no_identity():
    decision = decide([_titleless("OL1W", 0.95), _titleless("OL2W", 0.5)], _equal_weights())
    assert decision.verdict == "abstain"
    assert decision.reason.startswith("no identity evidence")


def test_margins_skip_titleless_candidates_below():
    ordered = rank([_c("OL1W", 0.97), _titleless("OL2W", 0.913), _c("OL3W", 0.80)])
    # The title-less candidate ranks last. OL1W's margin is to OL3W; OL3W and
    # OL2W have no titled candidate below them, so each margin is its own score.
    assert [c.work_key for c in ordered] == ["OL1W", "OL3W", "OL2W"]
    assert margins(ordered) == pytest.approx([0.17, 0.80, 0.913])
```

Add `import pytest` and `from openlibrary.matcher.decide import margins` if the module lacks them.

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_decide.py -q`
Expected: FAIL (`margins` missing; the order and margin assertions fail).

- [ ] **Step 3: Implement**

In `decide.py`, replace `rank` and add `margins`:

```python
def _group(candidate: ScoredCandidate, clusters) -> tuple[str, float, bool]:
    """(group id, group best score, is representative) -- a singleton group
    when unclustered."""
    if clusters is None or candidate.work_key not in clusters.of:
        return candidate.work_key, candidate.score, True
    cid = clusters.of[candidate.work_key]
    return cid, clusters.best_score[cid], clusters.representative.get(cid) == candidate.work_key


def rank(candidates: list[ScoredCandidate], clusters=None) -> list[ScoredCandidate]:
    """Identity-bearing candidates first (2026-10-04 spec, section 3), then by
    their group's best score, groups kept together with the representative
    first, then score, then work_key -- deterministic."""

    def key(c: ScoredCandidate):
        cid, best, is_rep = _group(c, clusters)
        return (not has_identity_evidence(c), -best, cid, not is_rep, -c.score, c.work_key)

    return sorted(candidates, key=key)


def margins(ranked: list[ScoredCandidate], clusters=None) -> list[float]:
    """Per candidate: its group's best score minus the best score among
    identity-bearing candidates ranked below it in a different group (0.0 if
    none). A candidate that could not itself be accepted never sets another's
    margin. margins(...)[0] is the decision's margin (R85)."""
    out = []
    for i, candidate in enumerate(ranked):
        cid, best, _ = _group(candidate, clusters)
        below = [
            c.score
            for c in ranked[i + 1 :]
            if has_identity_evidence(c) and _group(c, clusters)[0] != cid
        ]
        out.append(best - max(below, default=0.0))
    return out
```

In `decide`, replace `ordered = rank(candidates)` through `margin = best.score - runner_up` with:

```python
    ordered = rank(candidates, clusters)
    best = ordered[0]
    margin = margins(ordered, clusters)[0]
```

Add the keyword `clusters=None` to `decide`'s signature. The rest of `decide` is unchanged in this task. Update the module docstring with a paragraph on section 3, naming the measured effect (26 margin abstains and 8 displaced top candidates in the 2026-10-04 spike).

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_decide.py tests/openlibrary/test_harness.py tests/openlibrary/test_api_resolve.py -q`
Expected: PASS. `test_api_resolve`'s R85 test (`candidates[0].margin == decision.margin`) still passes because the API computes margins the old way until Task 13. If it fails, switch the API to `margins(ranked)` now, as Task 13 describes.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/matcher/decide.py data-sources/tests/openlibrary/test_decide.py
git commit -m "OL matcher: title-less candidates neither outrank nor set the margin

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Duplicate clusters (`matcher/cluster.py`) and the cluster-aware decision

**Files:**
- Create: `data-sources/src/openlibrary/matcher/cluster.py`
- Modify: `data-sources/src/openlibrary/matcher/decide.py`
- Modify: `data-sources/src/openlibrary/eval/harness.py` (`PreparedCandidate.cluster`; cluster stage in `evaluate`)
- Test: `data-sources/tests/openlibrary/test_cluster.py`, `data-sources/tests/openlibrary/test_decide.py`

**Interfaces:**
- Consumes: `has_identity_evidence`, `Weights.duplicate_dominance_ratio` (Task 10); `rank`, `margins` (Task 11).
- Produces:
  - `ClusterInputs(BaseModel)`: `title_variants: list[str]`, `author_fps: list[str]`, `edition_count: int`
  - `cluster_inputs(work: WorkView) -> ClusterInputs`
  - `ClusterIndex` (frozen dataclass): `of: dict[str, str]`, `members: dict[str, list[str]]`, `representative: dict[str, str | None]`, `best_score: dict[str, float]`
  - `build_clusters(candidates: list[ScoredCandidate], inputs: dict[str, ClusterInputs], weights: Weights) -> ClusterIndex`
  - `YEAR_DIVERGENCE = 0.5`
  - `Decision.duplicates: list[str]`
  - `PreparedCandidate.cluster: ClusterInputs | None = None`

- [ ] **Step 1: Write the failing tests**

`tests/openlibrary/test_cluster.py`:

```python
from openlibrary.matcher.cluster import ClusterInputs, build_clusters
from openlibrary.matcher.features import FEATURES
from openlibrary.matcher.scorer import MATCHER_VERSION, ScoredCandidate, Weights


def _weights(ratio=3.0):
    return Weights(matcher_version=MATCHER_VERSION, calibrated=False,
                   feature_weights=dict.fromkeys(FEATURES, 1.0),
                   conflict_penalties={"identifier": 0.35}, accept_threshold=0.9,
                   reject_threshold=0.4, margin_threshold=0.05, duplicate_dominance_ratio=ratio)


def _c(key, score, *, year=None, identifier=None):
    evidence = {"title_similarity": {"value": 1.0, "weight": 1.0, "contribution": 1.0},
                "year_agreement": {"value": year, "weight": 1.0, "contribution": 0.0},
                "identifier_agreement": {"value": identifier, "weight": 1.0, "contribution": 0.0}}
    return ScoredCandidate(work_key=key, score=score, rules=["author_title"], evidence=evidence)


def _in(title="dune", author="frank herbert", editions=1):
    return ClusterInputs(title_variants=[title], author_fps=[author], edition_count=editions)


def test_same_title_and_author_form_one_cluster_with_the_dominant_representative():
    idx = build_clusters([_c("OLA", 0.96), _c("OLB", 0.95), _c("OLC", 0.94)],
                         {"OLA": _in(editions=3), "OLB": _in(editions=160), "OLC": _in(editions=1)},
                         _weights())
    cid = idx.of["OLA"]
    assert idx.of["OLB"] == cid == idx.of["OLC"]
    assert idx.representative[cid] == "OLB"
    assert idx.best_score[cid] == 0.96


def test_no_dominant_member_means_no_representative():  # Dickinson's 16 "Poems"
    idx = build_clusters([_c("OLA", 0.95), _c("OLB", 0.95), _c("OLC", 0.95)],
                         {"OLA": _in("poems", editions=14), "OLB": _in("poems", editions=10),
                          "OLC": _in("poems", editions=10)},
                         _weights())
    assert idx.representative[idx.of["OLA"]] is None


def test_tied_edition_counts_have_no_representative():  # Review Focus 2
    idx = build_clusters([_c("OLA", 0.95), _c("OLB", 0.95)],
                         {"OLA": _in(editions=5), "OLB": _in(editions=5)}, _weights(ratio=1.5))
    assert idx.representative[idx.of["OLA"]] is None


def test_zero_edition_counts_have_no_representative():  # Review Focus 2
    idx = build_clusters([_c("OLA", 0.95), _c("OLB", 0.95)],
                         {"OLA": _in(editions=0), "OLB": _in(editions=0)}, _weights())
    assert idx.representative[idx.of["OLA"]] is None


def test_the_identifier_agreeing_member_represents_the_cluster():
    idx = build_clusters([_c("OLA", 0.95, identifier=1.0), _c("OLB", 0.95)],
                         {"OLA": _in(editions=1), "OLB": _in(editions=500)}, _weights())
    assert idx.representative[idx.of["OLA"]] == "OLA"


def test_different_authors_never_cluster():
    idx = build_clusters([_c("OLA", 0.95), _c("OLB", 0.95)],
                         {"OLA": _in(author="a"), "OLB": _in(author="b")}, _weights())
    assert idx.of["OLA"] != idx.of["OLB"]


def test_diverging_year_agreement_keeps_same_titled_works_apart():
    idx = build_clusters([_c("OLA", 0.95, year=1.0), _c("OLB", 0.9, year=0.3)],
                         {"OLA": _in(), "OLB": _in()}, _weights())
    assert idx.of["OLA"] != idx.of["OLB"]


def test_one_missing_year_does_not_block_clustering():
    idx = build_clusters([_c("OLA", 0.95, year=1.0), _c("OLB", 0.9, year=None)],
                         {"OLA": _in(editions=50), "OLB": _in(editions=1)}, _weights())
    assert idx.of["OLA"] == idx.of["OLB"]


def test_titleless_candidates_and_candidates_without_inputs_are_singletons():
    titleless = ScoredCandidate(work_key="OLT", score=0.913, rules=["author_shelf"], evidence={})
    idx = build_clusters([_c("OLA", 0.95), titleless, _c("OLN", 0.9)],
                         {"OLA": _in(), "OLT": _in()}, _weights())
    assert idx.members[idx.of["OLT"]] == ["OLT"]
    assert idx.members[idx.of["OLN"]] == ["OLN"]
```

Add to `test_decide.py`:

```python
from openlibrary.matcher.cluster import ClusterInputs, build_clusters


def _dup_inputs(editions):
    return ClusterInputs(title_variants=["dune"], author_fps=["frank herbert"], edition_count=editions)


def test_a_dominant_duplicate_cluster_accepts_its_representative_with_duplicates_listed():
    cands = [_c("OLSTUB", 0.964), _c("OLREAL", 0.951), _c("OLOTHER", 0.70)]
    inputs = {"OLSTUB": _dup_inputs(3), "OLREAL": _dup_inputs(160),
              "OLOTHER": ClusterInputs(title_variants=["children of dune"],
                                       author_fps=["frank herbert"], edition_count=90)}
    weights = _equal_weights()
    clusters = build_clusters(cands, inputs, weights)
    decision = decide(cands, weights, clusters=clusters)
    assert decision.verdict == "accept"
    assert decision.work_key == "OLREAL"
    assert decision.score == pytest.approx(0.964)
    assert decision.margin == pytest.approx(0.964 - 0.70)
    assert decision.duplicates == ["OLSTUB"]


def test_a_cluster_without_a_representative_abstains():
    cands = [_c("OLA", 0.95), _c("OLB", 0.95)]
    inputs = {"OLA": _dup_inputs(14), "OLB": _dup_inputs(10)}
    weights = _equal_weights()
    decision = decide(cands, weights, clusters=build_clusters(cands, inputs, weights))
    assert decision.verdict == "abstain"
    assert decision.reason.startswith("duplicate cluster with no dominant member")
    assert set([decision.work_key, *decision.duplicates]) == {"OLA", "OLB"}


def test_an_identifier_conflict_on_the_representative_still_abstains():
    cands = [_c("OLA", 0.95, conflicts=["identifier"]), _c("OLB", 0.60)]
    inputs = {"OLA": _dup_inputs(100), "OLB": _dup_inputs(1)}
    weights = _equal_weights()
    decision = decide(cands, weights, clusters=build_clusters(cands, inputs, weights))
    assert decision.verdict == "abstain"
    assert decision.reason.startswith("identifier conflict")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_cluster.py tests/openlibrary/test_decide.py -q`
Expected: FAIL with `ModuleNotFoundError: openlibrary.matcher.cluster`.

- [ ] **Step 3: Implement `cluster.py`**

```python
"""Stage 2.5: duplicate clusters. Between scoring and deciding.

Open Library holds unmerged duplicate works -- the same title by the same
author -- that differ only in popularity, worth at most ~0.064 of score; no
margin could separate them (2026-10-04 spec, D3: 85 of 193 list-row abstains).
Two identity-bearing candidates are the same book when a title variant
matches, an author fingerprint is shared, and their year agreement with the
query does not diverge. A cluster is represented by the member whose
identifier agrees, else by the member with the most editions when it
dominates the next by `duplicate_dominance_ratio`; real duplicates are stubs
beside one dominant work (Dune 160/3/1/1, Hamlet 2377/81/55), while different
books that share a title do not dominate (Dickinson's "Poems": 14/10/10).
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from pydantic import BaseModel, Field

from common.normalize import name_fingerprint
from openlibrary.matcher.features import WorkView
from openlibrary.matcher.scorer import ScoredCandidate, Weights, has_identity_evidence

YEAR_DIVERGENCE = 0.5


class ClusterInputs(BaseModel):
    title_variants: list[str] = Field(default_factory=list)
    author_fps: list[str] = Field(default_factory=list)
    edition_count: int = 0


def cluster_inputs(work: WorkView) -> ClusterInputs:
    return ClusterInputs(
        title_variants=sorted({v for v in (work.title_fp, work.title_fp_nosub, work.title_fp_noart) if v}),
        author_fps=sorted({fp for fp in (name_fingerprint(n) for n in work.author_names) if fp}),
        edition_count=work.edition_count,
    )


@dataclass(frozen=True)
class ClusterIndex:
    of: dict[str, str]
    members: dict[str, list[str]]
    representative: dict[str, str | None]
    best_score: dict[str, float]


def _value(candidate: ScoredCandidate, feature: str) -> float | None:
    return candidate.evidence.get(feature, {}).get("value")


def _years_agree(a: ScoredCandidate, b: ScoredCandidate) -> bool:
    ya, yb = _value(a, "year_agreement"), _value(b, "year_agreement")
    return ya is None or yb is None or abs(ya - yb) <= YEAR_DIVERGENCE


def _representative(members: list[str], by_key, inputs, ratio: float) -> str | None:
    if len(members) == 1:
        return members[0]
    agreeing = [k for k in members if _value(by_key[k], "identifier_agreement") == 1.0]
    if len(agreeing) == 1:
        return agreeing[0]
    ordered = sorted(members, key=lambda k: (-inputs[k].edition_count, k))
    top, second = inputs[ordered[0]].edition_count, inputs[ordered[1]].edition_count
    if top > second and top >= ratio * second:
        return ordered[0]
    return None


def build_clusters(
    candidates: list[ScoredCandidate], inputs: dict[str, ClusterInputs], weights: Weights
) -> ClusterIndex:
    by_key = {c.work_key: c for c in candidates}
    parent = {c.work_key: c.work_key for c in candidates}

    def find(k: str) -> str:
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    eligible = [c for c in candidates if has_identity_evidence(c) and c.work_key in inputs]
    by_variant: dict[str, list[str]] = defaultdict(list)
    for c in eligible:
        for variant in inputs[c.work_key].title_variants:
            by_variant[variant].append(c.work_key)

    for keys in by_variant.values():
        for i, a in enumerate(keys):
            for b in keys[i + 1 :]:
                if find(a) == find(b):
                    continue
                if not set(inputs[a].author_fps) & set(inputs[b].author_fps):
                    continue
                if not _years_agree(by_key[a], by_key[b]):
                    continue
                ra, rb = find(a), find(b)
                parent[max(ra, rb)] = min(ra, rb)

    groups: dict[str, list[str]] = defaultdict(list)
    for c in candidates:
        groups[find(c.work_key)].append(c.work_key)
    members = {cid: sorted(keys) for cid, keys in groups.items()}
    return ClusterIndex(
        of={k: cid for cid, keys in members.items() for k in keys},
        members=members,
        representative={
            cid: _representative(keys, by_key, inputs, weights.duplicate_dominance_ratio)
            for cid, keys in members.items()
        },
        best_score={cid: max(by_key[k].score for k in keys) for cid, keys in members.items()},
    )
```

The union-find root is the lexicographically smallest key (`min`), so cluster ids are deterministic.

Note the year rule. Two candidates with values 1.0 and 0.6 agree (|Δ| = 0.4 ≤ 0.5); 1.0 and 0.3 do not. This union is pairwise, so in principle A–B and B–C can join A and C even if A and C diverge. That is accepted: the dominance rule is the backstop. Record it in the docstring.

- [ ] **Step 4: Wire clusters into `decide`**

Add to `Decision`:

```python
    # The other members of the winning duplicate cluster (2026-10-04 spec, section 4).
    duplicates: list[str] = Field(default_factory=list)
```

(Import `Field` from pydantic.) Type `clusters` as `ClusterIndex | None` with `from openlibrary.matcher.cluster import ClusterIndex` under `TYPE_CHECKING` (cluster imports scorer, decide imports cluster, so there is no cycle). Then, in `decide` after computing `best` and `margin`:

```python
    cid = clusters.of.get(best.work_key) if clusters else None
    group = clusters.members.get(cid, [best.work_key]) if clusters else [best.work_key]
    if len(group) > 1 and has_identity_evidence(best):
        rep_key = clusters.representative.get(cid)
        if rep_key is None:
            return Decision(
                verdict="abstain",
                work_key=best.work_key,
                score=clusters.best_score[cid],
                margin=margin,
                reason="duplicate cluster with no dominant member: " + ", ".join(group),
                duplicates=[k for k in group if k != best.work_key],
            )
        representative = next(c for c in ordered if c.work_key == rep_key)
        score = clusters.best_score[cid]
        duplicates = [k for k in group if k != rep_key]
    else:
        representative, score, duplicates = best, best.score, []
```

Then rewrite the remaining checks (conflicts, identity, reject band, accept, the margin abstain, the middle band) to use `representative` for `work_key` and conflicts, and `score` for every threshold comparison and the `score=` field. Pass `duplicates=duplicates` on every returned `Decision` from here on. Keep the reason strings unchanged. Because `rank` puts the representative first in its group (Task 11), `best` already is the representative when one exists; the explicit lookup keeps `decide` correct if a caller passes an unranked list.

- [ ] **Step 5: Wire clusters into the harness**

In `harness.py`:
- `PreparedCandidate` gains `cluster: ClusterInputs | None = None`. `prepare` sets `cluster=cluster_inputs(views[key])`.
- `evaluate`, per case:

```python
        scored = [
            score_features(c.work_key, c.values, c.conflicts, c.rules, weights,
                           title_containment=c.title_containment)
            for c in case.candidates
        ]
        inputs = {c.work_key: c.cluster for c in case.candidates if c.cluster is not None}
        clusters = build_clusters(scored, inputs, weights)
        ordered = rank(scored, clusters)
        decision = decide(scored, weights, volume_guards_tripped=case.volume_guards_tripped,
                          clusters=clusters)
```

Add `matcher/cluster.py` to `CODE_FINGERPRINT_FILES`: it decides what clustering sees, and a change there must invalidate caches built for another version.

- [ ] **Step 6: Run the suite**

Run: `cd data-sources && uv run --locked pytest -q`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src data-sources/tests
git commit -m "OL matcher: duplicate clusters with an edition-dominance representative

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `/resolve`: cluster stage, `decision.duplicates`, cluster-aware margins

**Files:**
- Modify: `data-sources/src/openlibrary/api/resolve.py`
- Test: `data-sources/tests/openlibrary/test_api_resolve.py`

**Interfaces:**
- Consumes: `build_clusters`, `cluster_inputs`, `rank`, `margins`, `Decision.duplicates`.
- Produces: `ResolveDecision.duplicates: list[<the existing key model returned by _key>]`, defaulting to empty.

- [ ] **Step 1: Write the failing tests**

Add to `test_api_resolve.py`, which has the `client` fixture and the `a_title_with_multiple_candidates` fixture (a title shared by at least two works). The existing `test_top_candidate_margin_matches_the_decision_margin` keeps guarding R85 for a single candidate; add the multi-candidate version and the new field:

```python
def test_the_decision_carries_a_duplicates_list_of_keys(client, a_title_with_multiple_candidates):
    data = client.post("/resolve", json={"title": a_title_with_multiple_candidates}).json()["data"]
    duplicates = data["decision"]["duplicates"]
    assert isinstance(duplicates, list)
    assert all(set(d) == {"source", "key"} for d in duplicates)


def test_r85_holds_with_cluster_aware_margins_across_several_candidates(
    client, a_title_with_multiple_candidates
):
    data = client.post("/resolve", json={"title": a_title_with_multiple_candidates}).json()["data"]
    assert len(data["candidates"]) >= 2
    assert data["candidates"][0]["margin"] == pytest.approx(data["decision"]["margin"])
```

The margin arithmetic itself is unit-tested in `test_decide.py` (Tasks 11 and 12); these tests pin the wiring.

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_api_resolve.py -q`
Expected: FAIL (`duplicates` missing from the response; `margins` not imported by the module).

- [ ] **Step 3: Implement**

In `resolve.py`:
- Import `build_clusters`, `cluster_inputs` from `openlibrary.matcher.cluster` and `margins` from `openlibrary.matcher.decide`.
- In `resolve()`, after `scored = [...]`:

```python
    clusters = build_clusters(
        scored, {key: cluster_inputs(views[key]) for key in blocking.candidates if key in views},
        weights,
    )
    ranked = rank(scored, clusters)
    decision = decide(
        scored, weights, volume_guards_tripped=blocking.volume_guards_tripped, clusters=clusters
    )
    all_margins = margins(ranked, clusters)
```

- Replace the inline `margins = [...]` list with `all_margins`. Keep the comment's R85 explanation, updated to say the margin is the candidate's duplicate-group best score minus the best identity-bearing candidate below it outside its group.
- Add `duplicates: list[<key model>] = Field(default_factory=list)` to `ResolveDecision`, and pass `duplicates=[_key(k) for k in decision.duplicates]`.
- `_candidate_verdict` is unchanged: only the decision's own candidate (now the representative) carries the verdict.

- [ ] **Step 4: Run the suite**

Run: `cd data-sources && uv run --locked pytest -q`
Expected: PASS.

- [ ] **Step 5: Confirm the Rails client tolerates the new field**

Read `web-app/app/lib/books/open_library/resolution.rb`: `Resolution.from_response` builds `Decision` from named keys, so an extra `duplicates` key is ignored. Confirm by reading, no edit needed. Record that in the commit message.

- [ ] **Step 6: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/api/resolve.py data-sources/tests/openlibrary/test_api_resolve.py
git commit -m "OL API: duplicate clusters in /resolve, decision.duplicates, cluster-aware margins

Rails' Resolution.from_response reads named keys only, so the new field is ignored there.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Calibration knobs for the two new parameters

**Files:**
- Modify: `data-sources/src/openlibrary/eval/calibrate.py`
- Test: `data-sources/tests/openlibrary/test_calibrate.py`

**Interfaces:**
- Produces: `BOUNDED_KNOBS: dict[str, tuple[float, float, float]]` (low, high, step). The search covers `subset_title_credit` and `duplicate_dominance_ratio`. `calibration_write_gate` writes `matcher_version = MATCHER_VERSION`.

- [ ] **Step 1: Write the failing tests**

```python
def test_a_v2_weights_file_loads_with_defaults(tmp_path):  # Review Focus 5
    v2 = json.loads(WEIGHTS_PATH.read_text())
    v2.pop("subset_title_credit", None)
    v2.pop("duplicate_dominance_ratio", None)
    v2["matcher_version"] = 2
    path = tmp_path / "v2.json"
    path.write_text(json.dumps(v2))
    weights = load_weights(path)
    assert weights.subset_title_credit == 0.0 and weights.duplicate_dominance_ratio == 3.0


def test_written_weights_carry_the_current_matcher_version(tmp_path):  # Review Focus 5
    out = tmp_path / "weights.json"
    chosen = equal_weights().model_copy(update={"matcher_version": 2})
    written = calibration_write_gate(
        [], equal_score=-1.0, base_score=-1.0, chosen=chosen, chosen_score=0.5,
        train_score=0.5, label="random-search", out=out,
    )
    assert written
    assert json.loads(out.read_text())["matcher_version"] == MATCHER_VERSION


def test_the_search_keeps_new_knobs_inside_their_bounds():
    base = equal_weights().model_copy(update={"duplicate_dominance_ratio": 9.9, "subset_title_credit": 0.89})
    best, _ = search_weights(
        _one_clean_match_prepared(), base=base, iterations=300, seed=1, min_accept_rate=0.0
    )
    low, high, _ = BOUNDED_KNOBS["duplicate_dominance_ratio"]
    assert low <= best.duplicate_dominance_ratio <= high
    low, high, _ = BOUNDED_KNOBS["subset_title_credit"]
    assert low <= best.subset_title_credit <= high


def test_the_new_parameters_are_search_knobs():
    assert {"subset_title_credit", "duplicate_dominance_ratio"} <= set(BOUNDED_KNOBS)
```

`_one_clean_match_prepared()` is the module's existing helper. The base starts near the upper bounds, so a step that ignored the bounds would cross them within 300 iterations.

The first test passes trivially if no step ever improves the objective, since `best` is then the base. The second test, plus a code read of the clamp, is what pins the bounds. A mutation check (delete the clamp, rerun the first test with a seed that improves) is optional.

- [ ] **Step 2: Run to verify failure**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_calibrate.py -q`
Expected: FAIL (`BOUNDED_KNOBS` missing; the written file keeps version 2).

- [ ] **Step 3: Implement**

In `calibrate.py`:

```python
# (low, high, step) per non-feature knob. Thresholds keep their [0, 1] range;
# the two 2026-10-04 parameters get their own (spec section 5).
BOUNDED_KNOBS: dict[str, tuple[float, float, float]] = {
    "accept_threshold": (0.0, 1.0, 0.08),
    "reject_threshold": (0.0, 1.0, 0.08),
    "margin_threshold": (0.0, 1.0, 0.08),
    "subset_title_credit": (0.0, 0.9, 0.08),
    "duplicate_dominance_ratio": (1.5, 10.0, 0.5),
}
```

In `search_weights`, build `knobs = [*features_present, *BOUNDED_KNOBS]` and replace the `setattr` branch with:

```python
            low, high, step = BOUNDED_KNOBS[knob]
            setattr(candidate, knob, min(high, max(low, getattr(candidate, knob) + rng.uniform(-step, step))))
```

In `calibration_write_gate`, before `chosen.calibrated = True`, add `chosen.matcher_version = MATCHER_VERSION`, with a comment: a `--base` warm start copies the previous file's version.

In `equal_weights()`, set `subset_title_credit=0.0, duplicate_dominance_ratio=3.0` explicitly.

- [ ] **Step 4: Run the tests**

Run: `cd data-sources && uv run --locked pytest tests/openlibrary/test_calibrate.py -q`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd data-sources && uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
cd .. && git add data-sources/src/openlibrary/eval/calibrate.py data-sources/tests/openlibrary/test_calibrate.py
git commit -m "OL calibrate: search the two new parameters; written weights carry MATCHER_VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Version 3: calibrate, re-pin the gates, after reading

**Files:**
- Modify: `data-sources/src/openlibrary/matcher/scorer.py` (`MATCHER_VERSION = 3`, with the comment updated to name this spec)
- Modify: `data-sources/src/openlibrary/matcher/weights.json`
- Modify: `data-sources/src/openlibrary/eval/harness.py` (`THRESHOLD_CHECKS` gains two entries)
- Modify: `data-sources/src/openlibrary/eval/thresholds.json`
- Create: `data-sources/src/openlibrary/eval/readings/2026-10-v3-after.json`

- [ ] **Step 1: Bump the version and add the two gates**

In `scorer.py`: `MATCHER_VERSION = 3`, with the comment: "3 (2026-10-04 list-query spec): variant title comparison, identity-first ranking and margin, duplicate clusters; every prepared cache and pinned threshold from version 2 is stale."

In `harness.py`'s `THRESHOLD_CHECKS`, append:

```python
    ("list-row abstention", "max", "list_row_abstention_rate", "max_list_row_abstention_rate"),
    ("list-row false-merge", "max", "list_row_false_merge_rate", "max_list_row_false_merge_rate"),
```

- [ ] **Step 2: Calibrate from the shipped vector (~45 minutes to prepare, then the search)**

```bash
cd data-sources
uv run --locked python -m openlibrary.eval.calibrate --dump-date 2026-07-31 \
  --prepared-cache /home/shane/ol-data/tmp/prepared-v3-expanded.json \
  --base src/openlibrary/matcher/weights.json
```

Expected: `random-search beat the floor ... wrote random-search weights to src/openlibrary/matcher/weights.json`, and the file carries `"matcher_version": 3` plus both new parameters.

If the write gate refuses ("does not beat the floor"), stop and report the printed TEST numbers. Do not hand-edit `weights.json`. Under v3 semantics the old vector is the floor, and failing to beat it means the change does not help the objective. That outcome is a finding for Shane, not something to work around.

- [ ] **Step 3: The after reading**

```bash
uv run --locked python -m openlibrary.eval.harness --dump-date 2026-07-31 \
  --prepared-cache /home/shane/ol-data/tmp/prepared-v3-expanded.json \
  --reading-out src/openlibrary/eval/readings/2026-10-v3-after.json \
  --reading-label "v3 after, expanded set"
```

- [ ] **Step 4: Re-pin `thresholds.json`**

Set `matcher_version` 3, `measured_at` today, `n_cases` (about 600), `weights_calibrated_at` from the new `weights.json`, a `source` sentence naming this spec and the reading, and `measured` from the after reading. Pin the bounds with the headroom policy in `docs/features/open-library-data-service.md` ("Gate and cache policy"):
- `max_false_merge_rate` stays **0.015** unless measured is higher. If it is, stop: that fails the merge criteria in Task 16.
- `min_precision_at_accept` stays **0.98**. Same rule.
- `max_false_reject_rate` stays **0.005**.
- `min_candidate_recall_10` stays **0.90**.
- `max_abstention_rate`: measured rounded **up** to the next 0.05.
- `min_correct_no_match_rate`: measured rounded **down** to the next 0.01.
- `max_list_row_abstention_rate`: measured rounded up to the next 0.05.
- `max_list_row_false_merge_rate`: **0.0** (spec section 5). If measured is above 0, stop and report.

- [ ] **Step 5: Run every gate, including the artifact-backed ones**

```bash
cd data-sources
uv run --locked pytest -q
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run --locked pytest -m artifact -q
uv run --locked ruff check src tests && uv run --locked ruff format --check src tests
```

Expected: all PASS. The artifact run includes `test_the_matcher_does_not_regress_against_the_labeled_set`, the labelled-key existence test and the alternates test.

- [ ] **Step 6: Commit**

```bash
cd .. && git add data-sources/src/openlibrary/matcher/scorer.py data-sources/src/openlibrary/matcher/weights.json data-sources/src/openlibrary/eval/harness.py data-sources/src/openlibrary/eval/thresholds.json data-sources/src/openlibrary/eval/readings/2026-10-v3-after.json
git commit -m "OL matcher v3: recalibrated weights, re-pinned gates, list-row gates, after reading

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Before/after report, Rails replay, docs, and the stop for Shane

**Files:**
- Create: `docs/data-quality/ol-matcher-v3-before-after.md`
- Modify: `docs/features/open-library-data-service.md`
- Create (outside the repo): `/home/shane/ol-data/eval/replay-v3.jsonl`

- [ ] **Step 1: Generate the comparison**

```bash
cd data-sources
uv run --locked python -m openlibrary.eval.compare \
  --before src/openlibrary/eval/readings/2026-10-v2-baseline.json \
  --after src/openlibrary/eval/readings/2026-10-v3-after.json \
  --out ../docs/data-quality/ol-matcher-v3-before-after.md
```

- [ ] **Step 2: Hand-review the decision diff**

For every row with `newly_accepted` or `key_changed`:
1. Open both the accepted work and the labelled work (`curl -s http://127.0.0.1:8080/works/<key>` or the artifact).
2. Fill the "hand review" column with `right`, `right (non-canonical duplicate)` or `WRONG: <why>`.

Delegate this in batches to review subagents (`model: "opus"`) if there are more than about 40 rows. Each wrong row is named in the report's summary.

- [ ] **Step 3: Rails replay against version 3**

Start the version-3 API from this worktree on port 8090. Port 8080 keeps serving version 2 for comparison.

```bash
cd data-sources
OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 uv run --locked uvicorn --factory openlibrary.api.main:factory --host 127.0.0.1 --port 8090
```

Run it in the background, and confirm `curl -s http://127.0.0.1:8090/version` reports `"matcher_version":3`. Then, from `web-app/`:

`OUT=/home/shane/ol-data/eval/replay-v3.jsonl OPEN_LIBRARY_SERVICE_URL=http://127.0.0.1:8090 CLOUDFLARE_ACCESS_CLIENT_ID= CLOUDFLARE_ACCESS_CLIENT_SECRET= bin/rails runner <scratchpad>/replay.rb`

Compare `replay-v2.jsonl` with `replay-v3.jsonl` per row:
- the resolve verdict mix;
- accepts that agree with our stored key or one of its verified duplicates;
- finder outcomes vs our linked book;
- every row where the finder's answer changed, each classified better, same or **worse**.

Stop the port-8090 server afterwards.

- [ ] **Step 4: Write the report around the generated tables**

Add these sections to `docs/data-quality/ol-matcher-v3-before-after.md`, above the generated tables:
- **Summary:** the headline numbers (list-row abstention before → after, false merges before → after, precision before → after, wrong new accepts).
- **Acceptance criteria**, each marked met or not met. The criteria are copied from the spec's "Before/after evaluation":
  - false merges ≤ baseline;
  - precision ≥ baseline − 0.01;
  - list-row abstention under half the baseline, or the remaining reasons explained;
  - zero wrong books among new accepts;
  - no finder row worse in the Rails replay.
- **Rails replay** results.
- **Remaining abstains on list rows,** grouped by reason.
- **Label provenance:** Shane's spot-check results from Task 7.
- **Regenerating:** the exact commands, including the full `replay.rb` and `export_list_rows.rb` sources inline, following the convention of the other `docs/data-quality/` files.

- [ ] **Step 5: Update the feature doc**

In `docs/features/open-library-data-service.md`:
- Add reading 8 (matcher v3) to the readings table, with a paragraph explaining the change.
- Add the list-row stratum to the strata tables.
- Add the new rulings to the rulings narrative, numbered after the highest existing R-number (check the doc). They cover: variant title comparison, identity-first ranking and margin, duplicate clusters, alternates in labels, and the label digest in the cache header.
- Update the "Gatsby example" paragraph with what v3 returns for it (run the request against port 8090 before stopping it).
- Update "Gate and cache policy" for the six-value header and the two new gates.

- [ ] **Step 6: Commit**

```bash
git add docs/data-quality/ol-matcher-v3-before-after.md docs/features/open-library-data-service.md
git commit -m "OL matcher v3: before/after report and feature doc

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: STOP: report to Shane**

Do not push and do not open a PR. Report:
- the acceptance criteria table;
- the headline numbers;
- any wrong new accepts;
- the absolute path of the report;
- that branch `worktree-books-list-wizard` is unpushed.

Remind him that merging deploys the OL API within 15 minutes, and that the artifact-backed gates passed locally (CI cannot run them).
