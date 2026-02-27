# OpenSearch Integration

## Overview

The app uses the `opensearch-ruby` gem directly (no abstraction layer like Searchkick). All integration code is hand-rolled under `app/lib/search/`. OpenSearch powers full-text search and autocomplete for music (artists, albums, songs) and games.

**Connection**: A single `OPENSEARCH_URL` environment variable. No Rails initializer — clients are instantiated inline in the base classes.

**Docker (dev)**: Single-node OpenSearch with security disabled, exposed on ports 9200/9600 (see `docker-compose.yml`). Production uses an externally managed OpenSearch service.

## Architecture

```
Model save/destroy
  |  (after_commit)
  v
SearchIndexable concern → creates SearchIndexRequest row (Postgres)
  |
  v  (every 30 seconds)
Search::IndexerJob (Sidekiq cron) → drains queue, deduplicates, bulk indexes
  |
  v
Search::Base::Index subclass → OpenSearch bulk API
```

```
HTTP search request
  |
  v
Controller (e.g., Music::SearchesController)
  |
  v
Search query class (e.g., Search::Music::Search::AlbumGeneral)
  |  calls .call(text, options)
  v
Search::Base::Search → executes query against OpenSearch
  |
  v
Controller hydrates AR records from returned IDs (preserving score order)
  |
  v
View renders results via ViewComponents
```

## File Structure

```
app/lib/search/
  base/
    index.rb              # Base class for all index definitions (CRUD, bulk ops, reindex)
    search.rb             # Base class for all query execution
  shared/
    client.rb             # Singleton client wrapper (health checks, ping)
    utils.rb              # Query DSL builders (match, phrase, term, bool) + text normalization
  music/
    album_index.rb        # Index definition: analyzers, mappings, model_klass, model_includes
    song_index.rb
    artist_index.rb
    search/
      album_general.rb    # Full-text search query (public search page)
      album_autocomplete.rb  # Autocomplete query (admin select widgets)
      album_by_title_and_artists.rb  # Strict match (data import deduplication)
      song_general.rb
      song_autocomplete.rb
      song_by_title_and_artists.rb
      artist_general.rb
      artist_autocomplete.rb
  games/
    game_index.rb
    search/
      game_general.rb
      game_autocomplete.rb
      game_by_title.rb

app/models/
  concerns/search_indexable.rb   # AR concern: after_commit hooks for index queue
  search_index_request.rb        # Polymorphic queue table model
  category_item.rb               # Secondary trigger: reindexes items when categories change

app/sidekiq/search/
  indexer_job.rb                 # Cron job that drains SearchIndexRequest queue

lib/tasks/search.rake            # Rake tasks for bulk reindex
config/schedule.yml              # Sidekiq-cron: IndexerJob every 30 seconds
```

## Indexing Pipeline

### 1. SearchIndexable Concern

**File**: `app/models/concerns/search_indexable.rb`

Any model that `include SearchIndexable` gets:
- `after_commit on: [:create, :update]` → creates a `SearchIndexRequest` with `action: :index_item`
- `after_commit on: :destroy` → creates a `SearchIndexRequest` with `action: :unindex_item`

Currently included in: `Music::Album`, `Music::Song`, `Music::Artist`, `Games::Game`

### 2. SearchIndexRequest Queue Table

**File**: `app/models/search_index_request.rb`

A Postgres-backed outbox/queue pattern. The `after_commit` ensures the queue row is only written if the model transaction succeeds.

| Column | Type | Description |
|---|---|---|
| `parent_type` | string | Polymorphic model class (e.g., `Music::Album`) |
| `parent_id` | bigint | Model ID |
| `action` | integer enum | `0` = index_item, `1` = unindex_item |
| `created_at` | datetime | Used for ordering |

### 3. Category Change Reindexing

**File**: `app/models/category_item.rb`

When a `CategoryItem` is saved or destroyed (category added/removed from an item), it checks if the associated item has `as_indexed_json` with a `:category_ids` key. If so, it creates a `SearchIndexRequest` to keep the OpenSearch document's `category_ids` in sync.

**Note**: Uses `after_save` / `after_destroy` (not `after_commit`) — see commented-out `after_commit` lines. This is inconsistent with `SearchIndexable`.

### 4. IndexerJob (Sidekiq Cron)

**File**: `app/sidekiq/search/indexer_job.rb`
**Schedule**: Every 30 seconds (`config/schedule.yml`)

For each model type (`Music::Artist`, `Music::Album`, `Music::Song`, `Games::Game`):

1. Fetches up to **1,000** oldest `SearchIndexRequest` rows
2. **Deduplicates** by `[parent_type, parent_id, action]` — multiple rapid saves produce only one index operation
3. Resolves the index class dynamically: `"Search::#{domain}::#{model_name}Index".constantize`
4. Re-fetches models with eager-loaded associations via `index_class.model_includes`
5. Calls `bulk_index` or `bulk_unindex`
6. Deletes all processed `SearchIndexRequest` rows

### 5. Document Shape (`as_indexed_json`)

Each model defines what gets indexed:

**Music::Album**:
```ruby
{ title:, artist_names:, artist_ids:, category_ids: }
```

**Music::Song**:
```ruby
{ title:, artist_names:, artist_ids:, album_ids:, category_ids: }
```

**Music::Artist**:
```ruby
{ name:, category_ids: }
```

**Games::Game**:
```ruby
{ title:, developer_names:, developer_ids:, platform_ids:, category_ids: }
```

## Index Definitions

### Base Index Class

**File**: `app/lib/search/base/index.rb`

All domain index classes inherit from `Search::Base::Index`. Key methods:

| Method | Description |
|---|---|
| `index_name` | Auto-derived: `Search::Music::AlbumIndex` -> `music_albums_{env}`. Test appends `_{pid}` for isolation. |
| `create_index` | Idempotent — skips if exists |
| `delete_index` | Logs but doesn't raise on NotFound |
| `bulk_index(items)` | Builds action array from `item.as_indexed_json`, calls bulk API with `refresh: true` |
| `bulk_unindex(item_ids)` | Bulk delete by ID |
| `index_item(item)` | Single-document upsert |
| `reindex_all` | Drops index, recreates, streams all records via `find_in_batches(batch_size: 1000)` |

### Index Naming Convention

```
{domain}_{model_plural}_{environment}
```

Examples:
- `music_albums_production`
- `music_songs_development`
- `games_games_test_12345` (PID-suffixed in test)

### Analyzers (shared across all indexes)

All index classes define the same three analyzers (currently copy-pasted per index class):

| Analyzer | Tokenizer | Filters | Used For |
|---|---|---|---|
| `folding` | standard | lowercase, asciifolding | Main text fields (`title`, `artist_names`, `name`) |
| `autocomplete` | standard | lowercase, edge_ngram (3-20), ascii_folding_with_preserve | Index-time analyzer for `.autocomplete` subfields |
| `autocomplete_search` | standard | lowercase, ascii_folding_with_preserve | Search-time analyzer for `.autocomplete` subfields (no ngrams) |

### Field Mapping Pattern

Text fields use a multi-field pattern:

```
title:
  type: text, analyzer: folding              # Full-text search
  .keyword: keyword, normalizer: lowercase   # Exact match / sorting
  .autocomplete: text, analyzer: autocomplete, search_analyzer: autocomplete_search  # Prefix matching
```

Relationship fields (`artist_ids`, `category_ids`, `platform_ids`) are `keyword` type for exact filtering.

### Album Index Mappings (reference example)

| Field | Type | Subfields |
|---|---|---|
| `title` | text (folding) | `.keyword`, `.autocomplete` |
| `artist_names` | text (folding) | `.keyword` |
| `artist_ids` | keyword | — |
| `category_ids` | keyword | — |

Song index adds `album_ids: keyword`. Artist index uses `name` instead of `title` (same subfield pattern). Game index uses `developer_names`/`developer_ids`/`platform_ids` instead of `artist_*`.

## Search Queries

### Base Search Class

**File**: `app/lib/search/base/search.rb`

Provides `search(query_definition)`, `raw_search`, `count`, `extract_ids`, `extract_hits_with_scores`.

### Query Utils

**File**: `app/lib/search/shared/utils.rb`

Builder methods used by all query classes:
- `normalize_search_text(text)` — lowercase, strip special chars (keeps `-`, `'`, `.`), collapse spaces
- `build_match_query(field, query, boost:, operator:)` — standard full-text match
- `build_match_phrase_query(field, query, boost:)` — exact phrase match
- `build_term_query(field, value, boost:)` — keyword exact match
- `build_bool_query(must:, should:, filter:, minimum_should_match:)` — compose clauses

### Query Types

Each indexed model has up to three query classes:

#### General Search (public search page)

Example: `Search::Music::Search::AlbumGeneral`

Used by the public search controller. Uses `bool/should` with `minimum_should_match: 1` and boost ordering:

| Clause | Field | Boost | Operator |
|---|---|---|---|
| match_phrase | `title` | 10.0 | — |
| term | `title.keyword` | 9.0 | — |
| match | `title` | 8.0 | AND |
| match_phrase | `artist_names` | 6.0 | — |
| match | `artist_names` | 5.0 | AND |

Default `min_score: 1`, `size: 25` (from controller).

#### Autocomplete (admin select widgets)

Example: `Search::Music::Search::AlbumAutocomplete`

Targets the `.autocomplete` edge-ngram subfield for prefix matching:

| Clause | Field | Boost |
|---|---|---|
| match | `title.autocomplete` | 10.0 |
| match_phrase | `title` | 8.0 |
| term | `title.keyword` | 6.0 |

Default `min_score: 0.1`, `size: 20`.

#### By Title and Artists (data import deduplication)

Example: `Search::Music::Search::AlbumByTitleAndArtists`

Used during data imports to find existing records. Much stricter — title is a `must` clause, artists are `should` (boost). Default `min_score: 5.0`.

### Return Format

All query classes return: `[{ id:, score:, source: }, ...]`

## Controllers

### Public Search

**Music**: `app/controllers/music/searches_controller.rb`
**Route**: `GET /search` (music domain, behind `DomainConstraint`)

Fans out to all three query types (Artist, Album, Song), then hydrates AR records from Postgres preserving score order:

**Games**: `app/controllers/games/searches_controller.rb`
**Route**: `GET /search` (games domain, behind `DomainConstraint`)

Single query type (GameGeneral, `size: 50`), same hydration pattern. Results rendered via `Games::CardComponent` in a responsive grid.

```ruby
ids = results.map { |r| r[:id].to_i }.uniq
records_by_id = Model.where(id: ids).includes(...).index_by(&:id)
ids.map { |id| records_by_id[id] }.compact
```

### Admin Autocomplete

Admin controllers (e.g., `Admin::Music::ArtistsController#search`) expose `GET /admin/artists/search?q=...` returning JSON `[{value: id, text: name}]` for select widget autocomplete.

## Views

**File**: `app/views/music/searches/index.html.erb`

Three sections rendered conditionally (artists grid, albums grid, songs table), using:
- `Music::Artists::CardComponent`
- `Music::Albums::CardComponent`
- `Music::Songs::ListItemComponent`
- `Search::EmptyStateComponent` (shared) for empty/blank states

**Games**: `app/views/games/searches/index.html.erb`

Single section: games card grid using `Games::CardComponent`, plus shared `Search::EmptyStateComponent`.

## Rake Tasks

**File**: `lib/tasks/search.rake`

| Task | Description |
|---|---|
| `search:music:recreate_and_reindex_all` | Drop + recreate + reindex all music indices (Artists, Albums, Songs) |
| `search:music:recreate_artists` | Reindex artists only |
| `search:music:recreate_albums` | Reindex albums only |
| `search:music:recreate_songs` | Reindex songs only |
| `search:games:recreate_and_reindex_all` | Drop + recreate + reindex games index |
| `search:games:recreate_games` | Reindex games only |

All tasks call `IndexClass.reindex_all` which handles delete + create + bulk index via `find_in_batches(batch_size: 1000)`.

## Testing

Tests hit a real OpenSearch instance (no mocks/stubs). Per-process PID-suffixed index names (`music_artists_test_12345`) isolate parallel test workers.

Pattern:
```ruby
setup { cleanup_test_index }
teardown { cleanup_test_index }

# cleanup_test_index calls IndexClass.delete_index, rescuing NotFound
```

## Adding a New Domain (Checklist)

To add search for a new domain (e.g., games public search):

1. **Model**: `include SearchIndexable` in the model, define `as_indexed_json`
2. **Index class**: Create `Search::{Domain}::{Model}Index < Search::Base::Index` with `model_klass`, `model_includes`, `index_definition` (analyzers + mappings)
3. **Query classes**: Create under `Search::{Domain}::Search::` — at minimum `{Model}General` and `{Model}Autocomplete`
4. **IndexerJob**: Add model type string to the array in `Search::IndexerJob#perform`
5. **Rake tasks**: Add `search:{domain}:recreate_{model}` tasks in `lib/tasks/search.rake`
6. **Controller**: Create `{Domain}::SearchesController` with hydration logic
7. **Views**: Search results page + ViewComponents for result cards
8. **Routes**: Add search route within the domain constraint
