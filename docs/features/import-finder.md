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
   nothing and is named in `sources_failed`; an `ActiveRecord::ActiveRecordError` propagates
   instead, because our own database failing is not a missing candidate. Gathering stops early
   at a decisive candidate (a `:legacy` hit, or a corroborated identifier hit or external
   accept) unless `verify`. `Search::Shared::Utils.normalize_search_text`, which every
   OpenSearch source builds its query text through, now keeps non-ASCII letters instead of
   stripping them (Ruby's `\w` is ASCII-only, so an accented query used to match nothing);
   every domain's search gained this fix on this branch.
2. **Rules** (`Decider`): 0 legacy hit → matched certain; 1 corroborated identifier hit →
   matched certain (several: ranked, then most lists, then oldest; the rest flagged as
   `identifier_collision` pairs); 2 external accept on a locally held key, corroborated →
   matched certain; 3 no candidates → unmatched high; 4 exactly one local candidate that
   matches exactly, and no other local candidate carrying an identifier hit → matched high
   (other, non-exact locals do not block it; an identifier hit on another record sends the
   case to the AI); 5 no local candidates and an accepted external → unmatched high with
   `external`; else the AI. Rule 2
   also picks among several local candidates holding the accepted key with the same
   ranked/most-lists/oldest preference and flags the rest as
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

## State by increment

Increment 1 wrapped every legacy lookup; **increment 2 (books)** replaced the books finder's
sources with `Sources::Identifiers` (Open Library key, ISBN-13, ISBN-10, ASIN, Goodreads),
`Sources::Exact` (normalized title, joined to an author's name or alternate name when the
query has authors), `Sources::OpenSearch` over `Search::Books::Search::BookByTitleAndAuthors`
(title or alternate title required; authors and a year within one as boosts; a higher minimum
score without authors), and `DataImporters::Books::Book::OpenLibrarySource` (`POST /resolve`,
limit 5; one candidate per local holder of the work key or a key it redirects from; the whole
`Resolution` on `match.external_resolution`, which the provider reuses for a new book). Music
and games still run their legacy lookups until increments 5 and 6. The audit UI is increment 3,
the authors importer and the book provider's author step are increment 4, games is increment 5
and music is increment 6.

## The duplicate sweep

`Services::Books::FindDuplicates.call(book:)` resolves one book against the rest of the
catalog: it builds a query from the book's own title, authors, year and identifiers (capped at
`IDENTIFIERS_PER_TYPE` = 3 values per type -- a ranked book can carry dozens, and the sweep
only needs a few for the identifier source's collision evidence), then calls the finder with
`verify: true, subject: book, exclude: book` so no early exit applies. A match raises the pair
as a `bulk_verify` `DuplicateCandidate`; nothing is merged and no provider runs. The result's
`data[:match]` is the finder's `Match` and `data[:pair]` the row, so one book can be swept from
a console. When the finder's Open Library source failed the service fails without flagging --
Open Library is what finds a translation held under another title (spec §16), so a decision
made without it is not the sweep's answer. `Books::FindDuplicatesJob` drives the service one
book per job on the `serial` queue and raises `Books::FindDuplicatesJob::SourceFailed` on a
failed result so Sidekiq retries the book; the
retry writes a fresh `match_decisions` row, bumps `occurrences` on any pair the finder itself
raised, and repeats the AI call when the rules could not decide, which is expected. Watch for a stuck circuit with
`MatchDecision.where("'open_library' = ANY(sources_failed)").count` during a run.

Run the sweep **after** `bin/rails books:normalize_names:apply`: the exact source compares a
normalized query against the stored value, so an unnormalized row is invisible to it until
normalized. Full sequence: `books:normalize_names:report` (read-only) →
`books:normalize_names:apply` → `books:find_duplicates[100]` → inspect the pairs it raised →
`books:find_duplicates[all]`. `books:find_duplicates` requires its argument -- a count or
`all` -- and aborts otherwise; one job per book on the `serial` queue, which the Amazon
enrichment jobs also share, so start small and widen once the first pairs look right.
`Books::FindDuplicatesJob.enqueue_ranked` walks the primary ranking configuration
best-rank-first.

After deploying the redesign, run `ANALYZE` on the seven tables carrying `lower()` expression
indexes (`books_books`, `books_authors`, `music_albums`, `music_artists`, `music_songs`,
`games_games`, `games_companies`) -- they have no statistics until the first analyze, and
without them the planner can pick a full scan over the expression index regardless of the
query shape below. Confirm with `EXPLAIN` that the exact source's query uses
`index_books_books_on_lower_title`:

```ruby
sql = Books::Book.where("LOWER(books_books.title) = ?", "war and peace").distinct.select(:id).to_sql
ActiveRecord::Base.connection.execute("EXPLAIN (ANALYZE, BUFFERS) #{sql}").each { |r| puts r["QUERY PLAN"] }
```

## Stored-name normalization

`Services::Books::NormalizeStoredNames` rewrites every stored book title and author name the
save-time normalizer (`QuoteNormalizer` then `NameNormalizer`) would still change, so the exact
source's `lower(title)`/`lower(name)` comparison can see rows written before that normalizer
existed; it also rewrites `alternate_names`/`alternate_titles` entries the same way and saves a
row whose only defect is in one of those lists, which the report's counts do not include.
`bin/rails books:normalize_names:report` is read-only; `bin/rails books:normalize_names:apply`
saves the changed rows through the model callbacks and flags a `bulk_verify` pair for an author
whose folded name (or a folded alternate name that only now changed) equals another author's, for
a book whose folded title, or a folded alternate title that only now changed, equals another book's
**by an author of the same name** (a book with no authors is never checked), and for a book
whose authors were only made equal by an author rename, checked against the rest of the catalog
without the book itself being saved. Only values the run changed are checked, because the finder
counts alternate titles and alternate names as agreement. The report's "whitespace only" bucket also holds the
handful of rows whose only change is a quote fold (for example the `U+00B4` rows; any row whose
only defect was a curly quote lands there too), because the report classifies each row as
NFKC-or-not and `QuoteNormalizer` folds these before the NFKC step runs. See
`docs/data-quality/books-normalizer-effect.md` for the measured counts.

## Adding a domain

Subclass `FinderBase`, implement `model_class` and `candidate_sources(query)`, and override
the hooks the rules and the prompt need: `ranking_configuration_class`, `creators_required?`,
`query_title`, `query_creators`, `query_year`, `record_creators`,
`record_creator_alternate_names`, `record_year`, `record_extra_evidence`, and
`domain_guidance` (prompt text). `describe_query` and `describe_candidate` have sensible
defaults built from those hooks.
