# Open Library matcher: make `/resolve` decide on list-style queries

**Status:** design, awaiting review · **Date:** 2026-10-04 · **Branch:** `worktree-books-list-wizard`

This is the first of three specs for the books list wizard:

1. **This spec:** fix the Open Library matcher so it can decide on title + author queries.
2. The books list wizard, plus a refactor of the shared list-wizard code (its own spec).
3. A backfill of Open Library keys and duplicate keys for books and authors. Shane runs it only
   after he moves over to the new site, so it gets its own spec later. The wizard does not
   depend on it.

## Why

A list row gives us a title and author names, sometimes a year, and almost never an identifier.
On those inputs `POST /resolve` almost never decides.

Measured 2026-10-04 on 200 of the 948 legacy books list items that still carry the original list
text (`metadata.title` / `metadata.authors`) next to the book they were linked to:

| | Rows |
|---|---|
| Open Library `abstain` | **193 (96.5%)** |
| Open Library `accept` | 7 (3.5%). 5 agree with our stored key; 2 are Open Library duplicates of it |
| The labelled work was Open Library's #1 candidate, and it still abstained | 139 of 189 |
| For comparison, our local `Book::Finder` matched silently | 196, with 0 real errors |

The documented abstention rate is 0.665. It comes from a labelled set where 438 of 448 cases carry
identifiers. When identifiers are present, the right candidate gets +1.31 weight and every other
candidate takes a −0.35 penalty, so margins come easily. Only 10 cases look like a list row.

Across the 193 abstains, the root causes are:

| # | Defect | Where | Abstains |
|---|---|---|---|
| D1 | `title_similarity` = max(`token_set_ratio`, `token_sort_ratio`, `WRatio`). A title whose words are a subset of another's scores 1.0 ("Dune" vs "Children of Dune", "The Road" vs "The Road to Wigan Pier"). Any shared word scores 0.855 when the lengths differ ("The Wife" vs "The Interestings"). | `common/scoring.py` | ~47 |
| D2 | `fingerprint` turns non-Latin titles into `""`. A translation then has no title evidence and scores a flat 0.913 on author agreement alone. It can never be accepted (R58), but as the runner-up it puts a 0.175 margin out of reach (the top would need 1.088). Eight times it **outranked** the real work. | `common/normalize.py`, `matcher/decide.py` | ~34 |
| D3 | Open Library holds duplicate works with identical title and authors. They differ only in popularity, worth at most 0.064 of score, so the margin can never be reached. | `matcher/decide.py` | ~85 |
| D4 | The query title includes its subtitle ("THE CITY IN HISTORY: Its Origins…"). The work's stored title has no subtitle, so `title_variant_exact` is 0 and the score sits just under 0.9. | `matcher/features.py` | ~15 |
| — | Genuinely uncertain ("The Wife" → "The Interestings") | — | ~6 |

The 0.175 margin is itself a product of the labels. Each label holds one work key. In 105
`duplicate_work` cases the labeller picked one of 4–5 identical works by a tiebreak, so the
harness counts an accept of any other duplicate as a false merge, at 10× the cost of an
abstention. Calibration learned to abstain on every duplicate, and D1 makes many candidates look
like duplicates.

The real harm of accepting a non-canonical duplicate is **split keys**. Two of our books stamped
with different unmerged duplicates of one work are never paired by the duplicate sweep, which
groups on identical keys and `redirected_from` only. That harm is real but bounded: the book is
still the right book.

## Goals

- `/resolve` accepts when the evidence identifies one book, including when Open Library holds
  stub duplicates of it, and including famous authors whose translations appear on their shelf.
- No rise in false merges. The existing gates hold: false merge ≤ 0.015, precision ≥ 0.98,
  false reject ≤ 0.005, recall@10 ≥ 0.90.
- List-style queries are measured and gated, so this cannot regress unseen again.
- No artifact rebuild, and no changes to Rails behavior.

## Non-goals

- Transliterating non-Latin titles ("Анна Каренина" → "anna karenina"). `title_fp` is computed at
  build time, so this needs a full artifact rebuild and a re-download of the dump. English lists
  do not need it. A Latin query against a work whose only title is non-Latin still abstains, as
  it does today.
- Recognizing OL duplicates in Rails, stamping duplicate keys, or any backfill (spec 3).
- Changing blocking (which candidates are found).
- An author-name search endpoint.

## Design

### 1. Labelled set: a list-row category and duplicate-aware labels

The set must be fixed before the matcher, or the matcher is graded against the wrong answers.

**New stratum `list_row`** (declared in `eval/schema.py`; its pool is built by a new
`eval/build_list_rows.py` from a list-item export, since `build_pool.assign_strata` draws its
cases from books, not list items):
- ~150 cases sampled from the 948 legacy books list items with original list text.
- The 200 rows already examined in the 2026-10-04 spike are excluded, so the cases are held out
  from the analysis that shaped this design.
- Each query is built exactly as a list row arrives: `metadata.title` as given (subtitle, caps
  and all), `metadata.authors` split into names, no year, no identifiers.
- The query's `existing_ol_key` is **not** passed: a list row has none.

**Labelling (option A, agreed with Shane):**
1. An agent researches each case against the artifact, following the existing research brief
   (`docs/guides/openlibrary-case-research-brief.md`). Our linked book's stored Open Library key,
   where one exists, is a hint only, never the answer.
2. Each case records the work key or `not_in_open_library`, the identity rule, and the work's
   verified duplicates.
3. The rows carry a new provenance value, `agent_researched`. `dataset.load_cases` includes it.
4. Shane spot-checks a random 30 in `eval/label.py` before any calibration run. His corrections
   are applied. If more than 3 of the 30 are wrong, the whole batch is re-researched.

**Duplicate-aware labels:**
- `schema.py` gains `alternate_work_keys: list[str]`: verified unmerged duplicates of the labelled
  work. The labelled `work_key` stays the canonical choice.
- `harness._same()` counts an accept as correct when the redirect-resolved key is the label's
  work key **or** one of its alternates.
- A new `canonical_rate` metric reports how often an accept picked the canonical key. It is
  informational, not a gate.
- The 105 existing `duplicate_work` labels get alternates where their rationale names duplicates.
  An agent proposes them, checking each against the artifact (same normalized title, shared
  author, not a redirect). Shane spot-checks 15.
- The harness reports how many existing decisions this re-grading flips, before any matcher
  change, so the label change and the matcher change are measured separately.

### 2. Title similarity (D1, D4)

Replace `common.scoring.title_similarity` with a variant-aware, length-sensitive comparison.

- **Query variants**, computed at query time from the raw query title with the existing
  normalizer helpers: full, no-subtitle (cut at the first `:`, `;` or `(`, the same rule as
  `title_fp_nosub`), no leading article, and no-subtitle-no-article.
- **Work variants**, already stored: `title_fp`, `title_fp_nosub`, `title_fp_noart`.
- **`title_similarity`** = the maximum over all (query variant, work variant) pairs of
  `fuzz.token_sort_ratio / 100`. That ratio ignores word order but is length-sensitive, so
  "the road" vs "the road to wigan pier" scores 0.53, not 1.0.
- **Subtitle-dropped pairs** (a query no-subtitle variant that differs from the full title) count
  at most 0.95 (`DERIVED_TITLE_FACTOR`). Without the cap, "Star Wars: A New Hope" would score its
  own work and a plain "Star Wars" work identically on title. The cap makes a full-title match
  outrank a subtitle-dropped one.
- **Containment credit:** when one variant's tokens are a strict subset of the other's, the pair
  scores `max(token_sort, subset_title_credit)`. `subset_title_credit` is a new calibrated
  parameter in `weights.json`, searched in [0, 0.9]. The data decides whether containment
  deserves any credit.
- **`title_variant_exact`** becomes 1.0 when any query variant equals any work variant. So
  "THE CITY IN HISTORY: Its Origins…" matches `the city in history` exactly.
- **`subtitle_agreement`:** when the request has no `subtitle` and the raw title has one by the
  no-subtitle rule, the derived subtitle is compared with the work's `subtitle`. An explicit
  `subtitle` in the request still wins.
- `WRatio` and `token_set_ratio` are removed.
- Absence stays neutral (R40): an empty fingerprint on either side still gives `None`.

### 3. Candidates with no comparable title (D2)

A candidate has identity evidence when a title feature is present or its identifier agrees (the
existing `_has_identity_evidence`, R58). R58 already says a candidate without identity evidence
can never be accepted. This change makes the rest of the decision agree with that:

- **Ranking:** candidates with identity evidence rank above candidates without it, then by score,
  then by work key. A translation can no longer outrank the work it translates.
- **Margin:** the runner-up is the best-ranked candidate that has identity evidence and is not in
  the winner's duplicate cluster (section 4). A candidate that could not itself be accepted can no
  longer be the reason another candidate isn't.
- When no candidate has identity evidence, the outcome is unchanged: abstain, "no identity
  evidence".

### 4. Duplicate clusters (D3)

A new stage, `matcher/cluster.py`, runs between scoring and deciding, over the same candidates
and `WorkView`s.

**Cluster membership.** Two candidates belong to the same cluster when all of these hold:
- their full title fingerprints (`title_fp`) are equal, or their article-stripped fingerprints
  (`title_fp_noart`) are (non-empty). The subtitle-stripped variant is deliberately excluded:
  "The Lord of the Rings: The Two Towers" and the "Lord of the Rings" omnibus share
  `title_fp_nosub`, and the dominance rule would then accept the omnibus, a false merge (ruling
  during implementation, 2026-10-04);
- they share an author `name_fp` (primary or alternate name, the same fingerprints blocking uses);
- their `year_agreement` values with the query do not diverge by more than 0.5. Both `None`
  passes. When the query has a year and only one member matches it, they are kept apart.

Clusters are the connected components of that relation. Candidates without identity evidence are
never clustered.

**The cluster's representative**, chosen in order:
1. The member whose identifier agrees with the query (identifier-reached works come first, as in
   the labelling tiebreak), if exactly one does.
2. Otherwise, the member with the most editions, **but only if it dominates**:
   `edition_count ≥ duplicate_dominance_ratio × the next member's edition_count`.
   `duplicate_dominance_ratio` is a new calibrated parameter in `weights.json`, default 3.0,
   searched in [1.5, 10].
3. Otherwise the cluster has no representative.

Measured on the artifact, dominance separates the two cases a title-frequency guard could not:

| Author + title | OL works | Editions per work (top 6) | Outcome |
|---|---|---|---|
| Shakespeare, *Hamlet* | 146 | 2377, 81, 55, 50, 50, 44 | dominant → the 2377-edition work |
| Herbert, *Dune* | 4 | 160, 3, 1, 1 | dominant |
| Munro, *Selected Stories* | 2 | 9, 1 | dominant |
| Dickinson, *Poems* | 16 | 14, 10, 10, 7, 7, 6 | no representative → abstain |

**Decision with clusters:**
- The top-ranked candidate's cluster is the winner's cluster.
- If that cluster has more than one member and no representative, abstain: "duplicate cluster
  with no dominant member".
- Otherwise the representative is the candidate considered for accept. Its score is the cluster's
  best score (the members are the same book). Margin uses the cluster-aware runner-up from
  section 3.
- Accept, reject, middle band, identifier conflict and volume guards keep their existing rules
  and order.

**Response.** `decision` gains `duplicates`: the other members of the winning cluster, as keys.
It is evidence only. The Rails client ignores fields it does not read, so nothing changes there.

Each candidate's `margin` becomes its score minus the best-ranked candidate below it that has
identity evidence and is outside its cluster (or minus 0.0 when there is none). So
`candidates[0].margin == decision.margin` (R85) still holds, with `candidates[0]` being the
representative.

### 5. Calibration and gates

- `MATCHER_VERSION` 2 → 3. Every prepared cache and pinned threshold from version 2 is stale.
- The prepared cache must also carry what clustering needs per candidate: title variants, author
  name fingerprints and edition count. Sections 2 and 4 change `features.py` and
  `common/scoring.py`, so the cache is re-prepared anyway (~31 minutes for ~600 cases).
- Calibrate with `--base` from the shipped vector, on the expanded set, with the existing
  objective and costs. The search covers the existing weights and thresholds plus
  `subset_title_credit` and `duplicate_dominance_ratio`. The R65 write gate applies unchanged.
- Re-pin `thresholds.json` from the shipped reading, with the existing headroom policy.
- **New gates:**
  - `list_row` abstention ≤ measured + headroom.
  - `list_row` false merges = 0.

  The existing global gates stay at their current values: false merge ≤ 0.015, precision
  ≥ 0.98, false reject ≤ 0.005, recall@10 ≥ 0.90.
- Every accept on the labelled set that disagrees with its label (outside its alternates) is read
  by hand and recorded in the docs, as the current reading's lone false merge is.

### 6. Code touched

| File | Change |
|---|---|
| `src/common/scoring.py` | new variant-aware `title_similarity`, containment credit |
| `src/common/normalize.py` | query-side variant helpers (same rules as the SQL twin; no change to stored fingerprints, so `NORMALIZER_VERSION` is unchanged) |
| `src/openlibrary/matcher/features.py` | query variants, derived subtitle, carry clustering inputs |
| `src/openlibrary/matcher/cluster.py` | **new**: clusters and representatives |
| `src/openlibrary/matcher/decide.py` | identity-first ranking, cluster-aware margin, the no-dominant-member abstain |
| `src/openlibrary/matcher/scorer.py` | `MATCHER_VERSION = 3`; `Weights` gains the two parameters |
| `src/openlibrary/matcher/weights.json` | recalibrated |
| `src/openlibrary/api/resolve.py` | cluster stage, `decision.duplicates`, cluster-aware per-candidate margin |
| `src/openlibrary/eval/{schema,dataset,harness,build_pool,calibrate}.py`, `thresholds.json`, `cases/` | `list_row` stratum, `alternate_work_keys`, `agent_researched`, `canonical_rate`, new gates, new parameters |
| `docs/features/open-library-data-service.md` | the new reading, rulings, the list-row measurement |

No Rails file changes.

## Before/after evaluation

"More accurate" is the claim to prove, not "more accepts". The comparison is a required
deliverable, committed as a report in the PR and summarized in
`docs/features/open-library-data-service.md`.

1. **Baseline first.** Before any matcher change, score the expanded labelled set (existing cases
   with alternates, plus `list_row`) with the **current** matcher (version 2, shipped weights).
   Record it as the baseline reading. It is the same labels and the same cases the new matcher
   will face, so the two readings differ only by the matcher.
2. **After.** Score the same set with version 3.
3. **Side by side**, overall and per stratum: precision@accept, false merge, false reject,
   abstention, correct no-match, recall@10, and the new canonical rate.
4. **Decision diff.** Every case whose verdict or accepted key changed between the two readings
   is listed: newly accepted, newly abstained, newly rejected, key changed. Each newly accepted or
   key-changed case is read by hand and marked right or wrong.
5. **End to end in Rails.** Re-run the spike harness (the Rails book finder plus `/resolve`) on
   the 200 replay rows against both matcher versions, and compare finder outcomes against our
   linked books. More OL accepts mean more finder `certain` matches (rule 2), so this checks that
   the stronger signal stays right.

**Acceptance criteria.** All must hold to merge:
- False merges on the expanded set are **no higher than the baseline**, not merely under the
  0.015 gate. Precision@accept is no lower than the baseline minus 0.01.
- `list_row` abstention falls substantially. There is no fixed target, but a drop to under half
  the baseline is the expectation. If it doesn't fall that far, the remaining abstain reasons are
  explained in the report.
- No newly accepted case in the decision diff is a wrong book. A non-canonical duplicate counts as
  right but is noted.
- The Rails replay shows no row where the finder's answer got worse.

## Testing

- **Unit tests** for each rule, in the existing test layout:
  - title similarity on the measured pairs (Dune/Children of Dune, The Road/…Wigan Pier,
    The Wife/The Interestings, Emma/Emma: A Novel, a query with an inline subtitle);
  - identity-first ranking with a title-less translation that outscores the real work;
  - cluster membership, including the year-divergence split;
  - each representative rule, including the Dickinson-shaped no-dominance abstain;
  - the R85 margin invariant.

  Each new rule gets a negative case that fails without the rule.
- **Harness:** the full labelled set (448 existing + ~150 `list_row`) passes every gate in
  `thresholds.json`, enforced by `test_eval_regression.py` and the build gate.
- **Replay** (diagnostic, not a gate): the 200 spike rows before and after. The report gives the
  verdict mix, accepts versus our stored key or its verified duplicates, and the remaining
  abstain reasons.
- `test_decide.py` and the scorer tests updated for the new weights and version.

## Rollout

1. **Before opening the PR:** the artifact-backed harness passes locally against
   `/home/shane/ol-data/versions/2026-07-31/`, where the artifact lives. CI runs the
   `data-sources` suite but cannot run the artifact-backed tests.
2. **Merging to main is the deploy.** The home-server VMs track `main`, and
   `the-greatest-deploy.timer` runs `deploy.sh` every 15 minutes
   (`docs/features/home-server.md`). The OL API restarts on the same artifact with the new code.
   A failed build leaves the old container serving and pings `ol-deploy` `fail`.
3. The next dump refresh (`ol-refresh.sh`) runs the build gate against the new labelled set and
   the re-pinned `thresholds.json`. A failing gate keeps the previous version serving.
4. No Rails deploy is needed. Rails starts receiving accepts where it used to receive abstains,
   and every caller (book importer, Goodreads resolver, duplicate sweep) already handles accepts.

**What changes downstream after deploy:** more `accept` verdicts reach the book finder.
- An accept on a key we already hold makes the finder's rule 2 return `certain`.
- An accept on a key nobody holds makes rule 5 return unmatched with an external work, so the
  importer creates from Open Library data and imports authors by OL author key.

Both are intended. That is why the false-merge gates must hold.

## Risks

- **Clustering merges two different books** that share a title and author, such as an omnibus
  and a volume, or two different "Collected Stories". Mitigations: the dominance rule, the year
  split, the existing `anthology_or_collection` stratum, and a hand-read of every disagreeing
  accept.
- **Dropping `token_set_ratio` loses recall** on Open Library titles carrying a series prefix
  ("Discworld 1: The Colour of Magic"). `subset_title_credit` lets calibration restore
  containment credit if the data wants it. Recall@10 and per-stratum `correct` are compared
  against reading 7, and any stratum that loses more than one correct case is investigated
  before merging.
- **Label quality.** Agent-researched labels can be wrong. Shane's 30-case spot-check, with a
  re-research threshold, gates their use.
- **Overfitting to the spike.** The spike rows are excluded from `list_row`, and calibration's
  held-out test split applies to the new stratum as to every other.
