# OpenSearch Integration for Video Games

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-09
- **Started**: 2026-02-09
- **Completed**: 2026-02-09
- **Developer**: Claude

## Overview
Add OpenSearch search support for `Games::Game`, following the exact patterns established by the Music domain (Albums, Artists, Songs). The Game model already includes `SearchIndexable` and implements `as_indexed_json`; this task creates the missing index class, search classes, IndexerJob wiring, rake tasks, and tests.

**Scope**: `GameIndex`, `GameGeneral`, `GameAutocomplete`, IndexerJob update, rake tasks, tests.
**Non-goals**: Public search controller, admin search endpoints, UI changes (these can be added in a follow-up).

## Context & Links
- Related: Music OpenSearch integration (pattern to follow exactly)
- Existing search-ready model: `app/models/games/game.rb` (lines 30, 133-141)
- Base classes: `app/lib/search/base/index.rb`, `app/lib/search/base/search.rb`
- Music examples: `app/lib/search/music/album_index.rb`, `app/lib/search/music/search/album_general.rb`
- IndexerJob: `app/sidekiq/search/indexer_job.rb`
- Rake tasks: `lib/tasks/search.rake`

## Interfaces & Contracts

### Domain Model (no changes needed)

`Games::Game` already implements:
- `include SearchIndexable` (auto-queues `SearchIndexRequest` on create/update/destroy)
- `as_indexed_json` returning:

```json
{
  "title": "The Legend of Zelda: Breath of the Wild",
  "developer_names": ["Nintendo EPD"],
  "developer_ids": [42],
  "platform_ids": [7, 12],
  "category_ids": [101, 102]
}
```

No migration needed. No model changes needed.

### GameIndex — Index Definition

**File**: `app/lib/search/games/game_index.rb`

Extends `Search::Base::Index`. Follow `Search::Music::AlbumIndex` pattern exactly.

| Property | Type | Analyzer | Sub-fields | Notes |
|---|---|---|---|---|
| `title` | text | folding | `.keyword` (keyword, lowercase normalizer), `.autocomplete` (edge n-gram 3-20) | Primary search field |
| `developer_names` | text | folding | `.keyword` (keyword, lowercase normalizer) | Search by developer |
| `developer_ids` | keyword | — | — | Filter only |
| `platform_ids` | keyword | — | — | Filter only |
| `category_ids` | keyword | — | — | Filter only |

**Analyzers** (identical to Music):
- `folding`: standard tokenizer + lowercase + asciifolding
- `autocomplete`: standard tokenizer + lowercase + edge_ngram(3-20) + asciifolding(preserve)
- `autocomplete_search`: standard tokenizer + lowercase + asciifolding(preserve)

**Class contract**:
- `model_klass` → `::Games::Game`
- `model_includes` → `[:companies, :platforms]` (eager-loads associations used in `as_indexed_json`)
- `index_name` → auto-derived: `games_games_{env}` (from `Search::Games::GameIndex`)

### Search Classes

**File**: `app/lib/search/games/search/game_general.rb`

Follow `Search::Music::Search::AlbumGeneral` pattern. Extends `Search::Base::Search`.

| Method | Signature | Returns |
|---|---|---|
| `.call` | `(text, options = {})` | `Array<{id:, score:, source:}>` or `[]` |
| `.index_name` | — | delegates to `GameIndex.index_name` |

**Boosting strategy** (mirrors Album pattern with title + developer_names instead of artist_names):

| Clause | Field | Boost | Operator |
|---|---|---|---|
| match_phrase | title | 10.0 | — |
| term | title.keyword | 9.0 | — |
| match | title | 8.0 | AND |
| match_phrase | developer_names | 6.0 | — |
| match | developer_names | 5.0 | AND |

**Defaults**: `min_score: 1`, `size: 10`, `from: 0`

---

**File**: `app/lib/search/games/search/game_autocomplete.rb`

Follow `Search::Music::Search::AlbumAutocomplete` pattern. Extends `Search::Base::Search`.

| Clause | Field | Boost |
|---|---|---|
| match | title.autocomplete | 10.0 |
| match_phrase | title | 8.0 |
| term | title.keyword | 6.0 |

**Defaults**: `min_score: 0.1`, `size: 20`, `from: 0`

### IndexerJob Update

**File**: `app/sidekiq/search/indexer_job.rb` (modify existing)

Add `"Games::Game"` to the model types array (line 10):

```ruby
# Before
%w[Music::Artist Music::Album Music::Song].each do |model_type|

# After
%w[Music::Artist Music::Album Music::Song Games::Game].each do |model_type|
```

The job's `index_class` resolution (line 33) uses:
```ruby
"Search::Music::#{model_type.demodulize}Index".constantize
```

This must be updated to handle the Games domain. The pattern should resolve:
- `Music::Artist` → `Search::Music::ArtistIndex`
- `Games::Game` → `Search::Games::GameIndex`

**New resolution logic**:
```ruby
# reference only — derive domain + model from the model_type
domain = model_type.deconstantize  # "Music" or "Games"
model_name = model_type.demodulize # "Artist" or "Game"
"Search::#{domain}::#{model_name}Index".constantize
```

### Rake Tasks

**File**: `lib/tasks/search.rake` (modify existing)

Add a `search:games` namespace with:

| Task | Purpose |
|---|---|
| `search:games:recreate_games` | Delete + create + bulk reindex all games |
| `search:games:recreate_and_reindex_all` | Same as above (only one model, but follows Music's namespace pattern) |

### Behaviors (pre/postconditions)

**Preconditions**:
- OpenSearch running and accessible at `OPENSEARCH_URL`
- `Games::Game` records exist with associations loaded

**Postconditions**:
- After `GameIndex.reindex_all`: all `Games::Game` records indexed with correct JSON structure
- After model save: `SearchIndexRequest` created (existing behavior via `SearchIndexable`)
- After `IndexerJob.perform`: games requests processed, deduplicated, bulk indexed/unindexed
- Search classes return results ordered by relevance score

**Edge cases**:
- Game with no developers → `developer_names: []`, `developer_ids: []` (empty arrays, still indexable)
- Game with no platforms → `platform_ids: []`
- Game with no categories → `category_ids: []`
- Deleted game → `SearchIndexRequest` with `unindex_item` action, processed by IndexerJob
- Accented characters (e.g., "Pokemon" vs "Pok\u00e9mon") → handled by asciifolding analyzer

### Non-Functionals
- **No N+1**: `model_includes` eager-loads `[:companies, :platforms]` for `as_indexed_json`
- **Batch size**: 1000 per batch (inherited from `Base::Index.reindex_all`)
- **Index refresh**: 30-second cycle via Sidekiq cron (existing schedule, no change needed)
- **Test isolation**: Process-ID-suffixed index names (inherited from `Base::Index`)

## Acceptance Criteria

- [x] `Search::Games::GameIndex` class created, follows `AlbumIndex` pattern exactly
- [x] `GameIndex.create_index` creates index with correct mappings (title, developer_names, developer_ids, platform_ids, category_ids) and analyzers (folding, autocomplete, autocomplete_search)
- [x] `GameIndex.reindex_all` indexes all games with correct JSON
- [x] `Search::Games::Search::GameGeneral.call("zelda")` returns matching games ranked by relevance
- [x] `Search::Games::Search::GameAutocomplete.call("zel")` returns autocomplete matches
- [x] Both search classes return `[]` for blank/nil input
- [x] `IndexerJob` processes `Games::Game` index requests (index + unindex)
- [x] `IndexerJob` correctly resolves `Search::Games::GameIndex` from `Games::Game` model type
- [x] Rake task `search:games:recreate_games` works end-to-end
- [x] All existing Music tests still pass (no regressions from IndexerJob changes)
- [x] New tests for GameIndex (create/delete/index/find)
- [x] New tests for GameGeneral (blank input, find by title, find by developer, relevance order)
- [x] New tests for GameAutocomplete (blank input, prefix matching)
- [x] New tests for IndexerJob with Games::Game model type

### Golden Examples

```text
Input: GameGeneral.call("Zelda Breath")
Output: [{id: <breath_of_the_wild_id>, score: >5.0, source: {title: "The Legend of Zelda: Breath of the Wild", ...}}]

Input: GameAutocomplete.call("res")
Output: [{id: <re4_id>, ...}, {id: <re4_remake_id>, ...}]  (both Resident Evil 4 entries)

Input: GameGeneral.call("")
Output: []

Input: GameGeneral.call("Nintendo")  (searching by developer name)
Output: [{id: <breath_of_the_wild_id>, ...}, ...]  (games developed by Nintendo)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable patterns from Music domain
2) codebase-analyzer -> verify `as_indexed_json` loads associations correctly, verify IndexerJob resolution logic
3) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing: `test/fixtures/games/games.yml` (breath_of_the_wild, resident_evil_4, resident_evil_4_remake, half_life_2, tears_of_the_kingdom)
- May need: `test/fixtures/games/companies.yml` and `test/fixtures/games/game_companies.yml` fixtures for developer association tests
- Verify fixture names before referencing in tests

---

## Implementation Notes (living)
- Approach taken: Followed Music domain OpenSearch pattern exactly. Created `GameIndex`, `GameGeneral`, and `GameAutocomplete` classes mirroring `AlbumIndex`, `AlbumGeneral`, and `AlbumAutocomplete`. Updated `IndexerJob` with domain-agnostic index class resolution using `deconstantize`/`demodulize`.
- Important decisions:
  - Used `[:companies, :platforms]` for `model_includes` (the `developers` method applies a merge filter on `game_companies`, so the through association is preloaded but the filtered query still executes per-record during bulk indexing — same trade-off as `categories.active.pluck(:id)` in Music).
  - Generalized `IndexerJob` index class resolution from `"Search::Music::#{model_type.demodulize}Index"` to `"Search::#{domain}::#{model_name}Index"` — supports any future domain without further changes.

### Key Files Touched (paths only)
- `app/lib/search/games/game_index.rb` (new)
- `app/lib/search/games/search/game_general.rb` (new)
- `app/lib/search/games/search/game_autocomplete.rb` (new)
- `app/sidekiq/search/indexer_job.rb` (modify — add Games::Game + generalize index_class resolution)
- `lib/tasks/search.rake` (modify — add `search:games` namespace)
- `test/lib/search/games/game_index_test.rb` (new — 6 tests)
- `test/lib/search/games/search/game_general_test.rb` (new — 5 tests)
- `test/lib/search/games/search/game_autocomplete_test.rb` (new — 5 tests)
- `test/sidekiq/search/indexer_job_test.rb` (modify — 3 new Games::Game test cases)

### Challenges & Resolutions
- IndexerJob had hardcoded `Search::Music::` prefix for index class resolution. Replaced with `deconstantize`/`demodulize` pattern to derive domain from model type string, making it work for any domain.

### Deviations From Plan
- Spec originally listed `model_includes` as `[:game_companies]`. Changed to `[:companies, :platforms]` to match the Music pattern of including through-associations directly.

## Acceptance Results
- **Date**: 2026-02-09
- **Verifier**: Automated test suite
- **Results**: 3355 tests, 8929 assertions, 0 failures, 0 errors (full suite). 17 new Games search tests all passing. 15 IndexerJob tests all passing (including 3 new Games tests).

## Future Improvements
- Public `Games::SearchesController` for game search page
- Admin search endpoints for game management UI
- `GameByTitleAndDevelopers` search class for enrichment/dedup matching (if needed for data import)
- Consider indexing `platform_names` and `release_year` for richer search if needed

## Related PRs
-

## Documentation Updated
- [x] Spec file completed with implementation notes, deviations, and acceptance results
- [ ] `documentation.md` — no updates needed (no new public endpoints or user-facing features)
- [ ] Class docs — not applicable (follows established patterns, no new abstractions)
