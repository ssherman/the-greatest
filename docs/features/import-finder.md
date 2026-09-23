# Import finder

Every `DataImporters::<Domain>::<Model>::Finder` answers "is this thing already in our
catalog?" with a `DataImporters::Match`, and records that answer as a `MatchDecision` row.
Design: `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md`.

## The contract

`Finder#call(query:, verify: false, subject: nil, exclude: nil) -> Match`

| Field | Meaning |
|---|---|
| `outcome` | `:matched` or `:unmatched` (the spec calls the latter "new") |
| `record` | the local record, nil when unmatched |
| `confidence` | `:certain`, `:high`, `:medium`, `:low` |
| `decided_by` | `:identifier`, `:rule`, `:ai`, `:fallback` |
| `reason` | one sentence |
| `candidates` | every `Candidate` considered, in the order the AI saw them |
| `external` | the best external candidate to hydrate from when unmatched |
| `external_resolution` | a whole external response a source kept for the provider |
| `decision` | the persisted `MatchDecision` |
| `sources_failed` | names of sources that raised |
| `needs_review?` | medium or low confidence, or a fallback |

`verify: true` disables every early exit (identifier hits become evidence, every source
runs). `subject:` is what the caller was resolving for (a list item) and is stored on the
decision and used as the AI chat's parent. `exclude:` drops one record from every source,
which is how a record is resolved against the rest of the catalog.

The finder never creates or mutates catalog records and is not transactional. `ImporterBase`
reads `match.record`, hands the match to every provider (`populate(item, query:, match: nil)`),
and points the decision at a record it creates.

## The four stages (`FinderBase#call`)

1. **Gather.** Each source in `candidate_sources(query)` is called; results are unioned by
   `CandidateSet` (merged by local record or by external key). A source that raises adds
   nothing and is named in `sources_failed`. Gathering stops early at a decisive candidate
   (a `:legacy` hit, or a corroborated identifier hit or external accept) unless `verify`.
2. **Rules** (`Decider`): 0 legacy hit → matched certain; 1 corroborated identifier hit →
   matched certain (several: ranked, then most lists, then oldest; the rest flagged as
   `identifier_collision` pairs); 2 external accept on a locally held key, corroborated →
   matched certain; 3 no candidates → unmatched high; 4 one local candidate that matches
   exactly → matched high; 5 no local candidates and an accepted external → unmatched high
   with `external`; else the AI. Rule 2 also picks among several local candidates holding the
   accepted key with the same ranked/most-lists/oldest preference and flags the rest as
   `external_key_collision` pairs. Rules 0–2 never fire under `verify`.
3. **AI** (`Services::Ai::Tasks::Matching::SelectCandidateTask`, one gpt-5-mini call): the
   incoming item and at most six candidate lines, select one or 0, with confidence,
   reasoning and `same_entity_groups`. `AiSelection` turns that into a decision: a ranked
   record wins a same-entity group over an unranked pick; every group of two local records
   becomes a duplicate pair. A failed call falls back to unmatched, low, `:fallback`.
4. **Record.** A `MatchDecision` is always written (a failed source caps a `high` confidence
   at `medium` so the decision is reviewed; a `certain` decision stands. A Postgres error
   inside a source raises instead of counting as a failed source.). Pairs go through
   `Services::DuplicateCandidates::Flag`. The record stage also flags every pair of local candidates
   sharing an `(external_source, external_key)`, whatever the rules decided, de-duplicated
   against the decision's own pairs.

**Corroboration**: an identifier hit or an external accept is trusted only when the record
agrees with the query on its title (or an alternate title) or on a creator (or an alternate
name), or when the query carried nothing to compare. **Exact match** (rule 4): equal
normalized title, agreeing creators where the domain has them, no year conflict (both
present and more than two apart).

## Sources (`DataImporters::Sources`)

Each has `#name` and `#call -> [Candidate]`. `Identifiers` (Postgres, never decisive on its
own), `Exact` (one relation the finder builds; the `lower(title)`/`lower(name)` expression
indexes serve it), `OpenSearch` (the domain's title-plus-creators query, top five), and
`Legacy` (increment 1 only: the pre-redesign lookup as a single decisive source). A source
that responds to `#resolution` after `#call` has it copied onto the match. `CandidateSet`
keeps a local candidate apart from another local record's candidate that merely shares its
external key (a suspected duplicate), and folds an external-only candidate into the local
record that holds its key.

## Tables

`match_decisions`: one row per finder call — finder, polymorphic record and subject,
outcome/confidence/decided_by enums, `verify`, `query` and `candidates` jsonb snapshots,
`selected_index` (1-based), `reason`, `ai_chat_id`, `sources_failed`, and the audit columns
`needs_review`, `reviewed_at`, `reviewed_by_id`, `review_note`.

`duplicate_candidates`: one row per unordered pair of local records (`item_a_id <
item_b_id`, unique with `item_type`), `source` (identifier_collision, external_key_collision,
ai, human, bulk_verify), `status` (pending, merged, not_duplicate), `evidence`,
`occurrences`, the first `match_decision_id`, and the resolution columns.
`Services::DuplicateCandidates::Flag` never reopens a `merged` or `not_duplicate` row; a
pending one gains an occurrence and evidence. Every merger calls
`Services::DuplicateCandidates::RecordMerge` inside its transaction: the pair becomes
merged, other pending pairs naming the source re-key onto the target, and decisions that
named the source now name the target.

## State after increment 1

Every finder wraps its pre-redesign lookup as the `Legacy` source, so what matches today is
exactly what matched before; the difference is the return type and the decision row.
Increment 2 (books), 5 (games) and 6 (music) replace `candidate_sources` with the real
sources and delete each `legacy_lookup`. The audit UI is increment 3; the authors importer
is increment 4.

## Adding a domain

Subclass `FinderBase`, implement `model_class` and `candidate_sources(query)`, and override
the hooks the rules and the prompt need: `ranking_configuration_class`, `creators_required?`,
`query_title`, `query_creators`, `query_year`, `record_creators`,
`record_creator_alternate_names`, `record_year`, and `domain_guidance` (prompt text).
`describe_query` and `describe_candidate` have sensible defaults built from those hooks.
