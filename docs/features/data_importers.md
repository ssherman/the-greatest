# DataImporters Feature

## Overview
The DataImporters system provides a flexible, extensible framework for importing and enriching data from external sources across all media types (books, movies, games, music). It uses a strategy pattern with domain-agnostic base classes and domain-specific implementations to handle complex data integration workflows.

## Architecture

### Core Design Principles
- **Strategy Pattern**: Separates concerns between orchestration (Importers), finding (Finders), and data fetching (Providers)
- **Domain-Agnostic Base Classes**: Shared logic for all media types
- **Incremental Saving**: Items saved after each successful provider for background job compatibility
- **Provider Aggregation**: Multiple providers can enrich the same record
- **Finder returns a decision, not a record**: every finder answers with a `Match` (matched or unmatched, confidence, candidates, who decided, why) and records a `MatchDecision`. See [Import finder](./import-finder.md).

### System Components

#### Base Classes (Domain-Agnostic)
- **ImporterBase** - Main orchestration logic with provider aggregation and incremental saving
- **FinderBase** - The four-stage finder pipeline (gather candidates, rules, AI selection, record); see [Import finder](./import-finder.md)
- **ProviderBase** - Base class for external data source integration
- **ImportQuery** - Factory for domain-specific query objects with validation
- **ImportResult** - Aggregated results from all providers with success/failure tracking
- **ProviderResult** - Individual provider success/failure tracking

#### Domain-Specific Implementation Structure
```
DataImporters::{Domain}::{Model}::
  - Importer < ImporterBase
  - Finder < FinderBase
  - ImportQuery < ImportQuery
  - Providers::{SourceName} < ProviderBase
```

### Key Features

#### Incremental Saving Architecture
Items are saved immediately after each successful provider execution, enabling:
- **Background Job Compatibility**: Items persisted before async providers run
- **Fast User Feedback**: Users see results after first provider, subsequent providers enhance over time
- **Reliable Updates**: Each provider's data saved immediately upon success
- **Failure Recovery**: First provider saves basic item, later providers enhance it

#### Force Providers Option
The `force_providers: true` parameter allows:
- Re-enriching existing items with new provider data
- Adding new providers to previously imported items
- Updating stale data from external sources

#### Provider Patterns

**Synchronous Provider:**
```ruby
class Providers::MusicBrainz < ProviderBase
  def populate(item, query:, match: nil)
    # Fetch and populate data immediately
    # Save happens automatically after this returns success
    ProviderResult.new(success: true, provider_name: self.class.name)
  end
end
```

**Asynchronous Provider:**
```ruby
class Providers::CoverArt < ProviderBase
  def populate(item, query:, match: nil)
    # Queue background job for rate-limited API
    Games::CoverArtDownloadJob.perform_async(item.id)
    # Return success immediately - job updates item later
    success_result(data_populated: [:cover_art_queued])
  end
end
```

## Current Implementation

### Supported Media Types

| Domain | Model | Providers | Status |
|--------|-------|-----------|--------|
| Music | Artist | MusicBrainz, AiDescription, Amazon | Complete |
| Music | Album | MusicBrainz, AiDescription, Amazon | Complete |
| Music | Release | MusicBrainz | Complete |
| Games | Game | IGDB, CoverArt, Amazon | Complete |
| Games | Company | IGDB | Complete |
| Books | Book | OpenLibrary, Authors, AiEnrichment, AuthorEnrichment | Complete |
| Books | Author | OpenLibrary | Complete (Wikidata, VIAF, AI step; Reject link and backfill still to come) |

### Music Providers

#### MusicBrainz
- Artist, album, and release data import
- Graceful "not found" handling (treated as success)
- Identifier management: MusicBrainz IDs, ISNIs
- Category population from tags (genres, locations)
- Relationship handling: artist credits, album associations

#### AI Description (Async)
- Queues `AiDescriptionJob` for AI-generated descriptions
- Uses OpenAI (the `standard` role, see `ai_agents.md`) for natural language descriptions

#### Amazon Product (Async)
- Searches Amazon for related products
- AI validation filters unrelated results
- Creates external links with product metadata

### Games Providers

#### IGDB Provider (Sync)
Primary data source for games and companies.

**Game Data Mapping:**
| IGDB Field | Game Attribute |
|------------|----------------|
| `name` | `title` |
| `summary` | `description` |
| `first_release_date` | `release_year` (Unix timestamp → year) |
| `category` | `game_type` (mapped via IGDB_CATEGORY_MAP) |
| `involved_companies` | Recursive company import |
| `platforms` | Find or create platforms by slug |
| `genres` | Categories (category_type: :genre) |
| `themes` | Categories (category_type: :theme) |
| `game_modes` | Categories (category_type: :game_mode) |
| `player_perspectives` | Categories (category_type: :player_perspective) |

**Company Data Mapping:**
| IGDB Field | Company Attribute |
|------------|-------------------|
| `name` | `name` |
| `description` | `description` |
| `country` | `country` (IGDB numeric → ISO 2-letter via CountryCodeConverter) |
| `start_date` | `year_founded` (Unix timestamp → year) |

**Key Behaviors:**
- Recursive company import during game import
- Platform auto-creation: finds by slug or creates with inferred `platform_family`
- Game-company role tracking: `developer` and `publisher` flags on join records
- Category auto-creation with `import_source: :igdb`

#### CoverArt Provider (Async)
- Queues `Games::CoverArtDownloadJob`
- Downloads from IGDB CDN (`t_1080p` size)
- Skips if game already has primary image
- No Amazon fallback (prevents wrong cover art from merchandise)

#### Amazon Provider (Async)
- Queues `Games::AmazonProductEnrichmentJob`
- Searches Amazon for game-related products
- AI validation via `AmazonGameMatchTask`
- Creates external links (no image download)

### Books Providers

#### Open Library (Sync)
Single provider, backed by the [Open Library data service](./open-library-data-service.md)
(`data-sources/`, a separate Python process reached over HTTP -- see that doc's "Rails client"
section for the full contract).

- **Query** (`ImportQuery`) takes `title` (required unless an identifier is present),
  `author_names`, `year`, `isbn13`, `isbn10`, `asin`, `goodreads_id`, `open_library_work_key`.
- **Finder** runs four candidate sources in order (identifiers, an exact title/author match, an
  OpenSearch title-plus-authors query, and the Open Library `/resolve` service); see
  [Import finder](./import-finder.md) for what each one does.
- **Provider** calls the service's `/resolve` endpoint with the *book's* current state (not just
  the query) and, on an accept verdict, applies fills only to blank fields (`title`, `subtitle`,
  `description`, `first_published_year`); for a new book it reuses the resolution the finder
  already obtained, so a title import makes one `/resolve` call in total. `title`, `subtitle` and
  `first_published_year` are blank
  scalar columns; `description` is stored as a `descriptions` row (`source: openlibrary`) via
  `Describable#assign_description`, never the legacy `books_books.description` column, and "ours"
  sent to the service is the book's primary description. A populated field the service calls a
  conflict or an enrichment is left alone and reported in `data_populated` as `"skipped:<field>"`.
  On accept, a book with no authors gets the accepted work's authors through the author importer, by
  key and name, in Open Library's order. Subjects are never applied.
- **Idempotency:** re-running `Importer.call` with any identifier is idempotent (the finder's
  identifier and exact sources find it; the provider persists the query's identifiers on accept),
  including a query keyed by an OLD (redirected) OL key as long as it still carries the title the
  service can accept on: the service resolves the old key to its terminal work,
  `OpenLibrarySource#local_holders` finds the book holding that canonical key (it also counts any
  key in the work's `redirected_from` list, which `/resolve` does not populate), and rule 2 matches
  on the external accept. A key-only re-run earns no accept, because the service has no title or
  identifier evidence for it, so that one reaches the AI. A title+author import is idempotent when
  the linked author carries the query's author name (a newly created author, or a match on that
  name): the exact source finds the book by title joined to that name on the next run. An author
  matched under a variant name leaves the re-run to OpenSearch and the AI, and a book linked
  through an Open Library accept is found again by the service's accept on the same key.

#### AI Enrichment (Async)
Queues `Books::EnrichBookJob` and returns `[:ai_enrichment_queued]`. Runs after OpenLibrary and
Authors, so the AI fills fewer blanks, and before AuthorEnrichment. Requires a title and either
`book.authors` names (the usual case, since the author steps run first) or the query's
`author_names` when the book still has no authors. When the import created one of the book's
linked authors, it queues nothing: it writes a skipped `deferred_to_authors` ledger row and
returns `[:ai_enrichment_deferred_to_authors]`, and the author chain hands the book on when the
author is enriched. See `docs/features/books_enrichment.md` and
`docs/features/books-author-enrichment.md`.

#### Author Enrichment (Async)
`Providers::AuthorEnrichment` runs last, after AiEnrichment, and queues
`Books::Authors::WikidataJob` for each author this import created, returning
`[:author_enrichment_queued]`. It runs after the importer has saved the book and its
`book_authors` rows, so the author chain sees the book among the author's titles -- and after
AiEnrichment has already written the book's `deferred_to_authors` row, so a chain that finishes
fast cannot reach its hand-off before the book's wait is even recorded. It does nothing, and
reports failure, for a book that was never persisted.

#### Authors (Sync)
`Providers::Authors` runs after Open Library. When the book still has no authors (Open Library abstained,
rejected, or was unreachable -- the service is not deployed to production), each of the query's
`author_names` goes through `DataImporters::Books::Author::Importer` by name and is linked in the query's
order. A book that already has authors is left alone. Both author steps call the author importer with
`providers: Author::Importer::BOOK_STEP_PROVIDERS` (`[:open_library]`), leaving out its async
`Providers::Enrichment`, and collect the ids of the authors the import created for the providers after
them.

### Books Author importer
`DataImporters::Books::Author::Importer.call(name:, open_library_author_key:, birth_year:, death_year:,
alternate_names:, work_titles:)`. `name` is required unless a key is given. The finder's sources are the
Open Library author key, an exact normalized name-or-alternate-name lookup, OpenSearch
`Search::Books::Search::AuthorByName`, and the Open Library author record for the key; rule 4 is an equal
normalized name with no birth- or death-year conflict. Stored names and alternate names are normalized on
save (quotes, exotic spaces), so the exact source can compare them directly. The importer saves the new
author before providers run (`save_before_providers?`), so a name alone always persists;
`ImportResult#created?` says whether it made the author. The Open Library provider fills blank years,
unions alternate names, stamps `books_author_openlibrary_id`, and writes `name` only when blank. When another
author already holds the key (or a key it redirects from), it applies nothing, flags the two authors as an
`external_key_collision` pair on the duplicates page, and reports a failure.

**Enrichment (async).** Queues `Books::Authors::WikidataJob` for the new author and returns
`[:author_enrichment_queued]`. The job resolves the author to a Wikidata person or to none,
fills blanks from the item, and links the English Wikipedia article only through that item. See
`docs/features/books-author-enrichment.md`. Providers run only for a new author, so a matched
author is never re-enriched from an import.

On a Wikidata miss, `WikidataJob` chains into `Books::Authors::ViafJob` — VIAF is not a provider of
its own, but a job the Wikidata step can lead to. Every chain ends in `Books::Authors::EnrichJob`,
the AI facts step, which also hands the author's waiting books on to book enrichment. See
`docs/features/books-author-enrichment.md`, "The AI step", and
`docs/superpowers/specs/2026-09-27-books-author-importer-design.md`. The Reject link action
(increment 5) and the backfill rake task (increment 6) are still to come.

## Usage Examples

### Music Import

```ruby
# Import an artist by name
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  artist = result.item
  puts "Created artist: #{artist.name} (#{artist.kind})"
  puts "Data from: #{result.successful_providers.map(&:provider_name).join(', ')}"
end

# Import using MusicBrainz ID for precise matching
result = DataImporters::Music::Artist::Importer.call(
  musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
)

# Re-enrich existing item
result = DataImporters::Music::Artist::Importer.call(
  name: "Pink Floyd",
  force_providers: true
)
```

### Games Import

```ruby
# Import a game by IGDB ID
result = DataImporters::Games::Game::Importer.call(igdb_id: 7346)

if result.success?
  game = result.item
  puts "Imported: #{game.title} (#{game.release_year})"
  puts "Platforms: #{game.platforms.map(&:name).join(', ')}"
  puts "Developers: #{game.developers.map(&:name).join(', ')}"
end

# Import a company
result = DataImporters::Games::Company::Importer.call(igdb_id: 70)

if result.success?
  company = result.item
  puts "Company: #{company.name} (#{company.country})"
end

# Re-enrich existing game (updates from IGDB, re-queues async jobs)
result = DataImporters::Games::Game::Importer.call(
  igdb_id: 7346,
  force_providers: true
)

# Enrich existing game object
game = Games::Game.find_by(title: "Zelda")
result = DataImporters::Games::Game::Importer.call(item: game)

# Run specific providers only
result = DataImporters::Games::Game::Importer.call(
  item: game,
  providers: [:igdb, :cover_art]
)
```

## Import Flow

### Standard Single-Item Import
1. **Input Validation**: Domain-specific query object validates parameters
2. **Find Existing**: The finder returns a `Match`; `match.record` is the existing record or nil
3. **Early Return**: Skip providers if a record matched (unless force_providers: true); providers otherwise receive the match as `populate(item, query:, match:)`
4. **Initialize Item**: Create new record if none found
5. **Provider Execution**: Each provider contributes data, item saved after successful providers
6. **Result Aggregation**: Return detailed ImportResult with provider feedback

### Games-Specific Flow
1. **IGDB Provider** (sync): Fetches core data, recursively imports companies
2. **Platform Resolution**: Finds existing platforms by slug or creates new ones
3. **Category Population**: Creates/links genres, themes, game modes, perspectives
4. **CoverArt Provider** (async): Queues job for IGDB CDN image download
5. **Amazon Provider** (async): Queues job for product search + AI validation

### Multi-Item Import (Releases)
1. **Input Validation**: Album provided as context
2. **Provider Orchestration**: Providers handle creation and persistence of multiple items
3. **Bulk Processing**: All releases for an album imported in single operation
4. **Incremental Support**: Skips existing releases for safe re-imports

## AI Task Integration

### Amazon Product Matching
Both Music and Games use AI to validate Amazon search results.

**Base Class:** `Services::Ai::Tasks::AmazonProductMatchTask`
- Shared prompt structure and response handling
- Abstract methods: `domain_name`, `item_description`, `match_criteria`, `non_match_criteria`
- Runs on the `fast` role (see `ai_agents.md`) with structured outputs

**Music Implementation:** `AmazonAlbumMatchTask`
- Matches: vinyl, CD, cassette, digital, box sets, special editions
- Excludes: unrelated albums, compilations without the album

**Games Implementation:** `AmazonGameMatchTask`
- Matches: game editions, guides, artbooks, soundtracks, collectibles, DLC, bundles
- Excludes: different games with similar names, unofficial merchandise
- Returns `product_type` for each match (game, guide, artbook, etc.)

## Utility Services

### Country Code Converter
`Services::Games::CountryCodeConverter` converts IGDB numeric country codes to ISO 2-letter codes.

```ruby
Services::Games::CountryCodeConverter.igdb_to_iso(840)  # => "US"
Services::Games::CountryCodeConverter.igdb_to_iso(392)  # => "JP"
Services::Games::CountryCodeConverter.igdb_to_iso(826)  # => "GB"
```

### Platform Family Inference
When creating new platforms, the IGDB provider infers `platform_family` from slug/name:
- PlayStation patterns → `:playstation`
- Xbox patterns → `:xbox`
- Nintendo/Switch/Wii → `:nintendo`
- PC/Windows/Mac/Linux → `:pc`
- iOS/Android → `:mobile`
- Others → `:other`

## Error Handling

### Provider Isolation
- Individual provider failures don't stop the import
- Items saved after each successful provider if valid and changed
- Database save failures logged and gracefully handled
- Failed saves convert provider success to failure result

### Comprehensive Feedback
- Overall success/failure status
- Which providers succeeded/failed with detailed error messages
- Complete error aggregation for debugging
- Item persistence status tracking

### Async Job Resilience
- Jobs are idempotent (safe to retry)
- Use `queue: :serial` for rate-limited APIs
- Skip processing if item already has data (e.g., primary image exists)

## Extension Points

### Adding New Providers
1. Create provider class inheriting from `ProviderBase`
2. Implement `populate(item, query:, match: nil)`; `match` is the finder's Match for a query-based import, nil for an item-based one — see [Import finder](./import-finder.md)
3. Use `find_or_initialize_by` for identifiers to prevent duplicates
4. Add to domain-specific importer's `providers` array

### Adding New Media Types
1. Create domain namespace (e.g., `DataImporters::Books::Book`)
2. Implement domain-specific `Importer`, `Finder`, and `ImportQuery` classes
3. Create provider classes for relevant external APIs
4. Follow established patterns for consistency

### Adding Amazon AI Tasks
1. Create task class inheriting from `AmazonProductMatchTask`
2. Implement abstract methods: `domain_name`, `item_description`, `match_criteria`, `non_match_criteria`
3. Define `MatchResult` and `ResponseSchema` classes with domain-specific fields
4. Create corresponding service and job classes

## File Structure

```
app/lib/data_importers/
├── importer_base.rb
├── finder_base.rb
├── provider_base.rb
├── import_query.rb
├── import_result.rb
├── provider_result.rb
├── music/
│   ├── artist/
│   │   ├── importer.rb
│   │   ├── finder.rb
│   │   ├── import_query.rb
│   │   └── providers/
│   │       ├── musicbrainz.rb
│   │       ├── ai_description.rb
│   │       └── amazon.rb
│   ├── album/
│   │   └── ...
│   └── release/
│       └── ...
└── games/
    ├── game/
    │   ├── importer.rb
    │   ├── finder.rb
    │   ├── import_query.rb
    │   └── providers/
    │       ├── igdb.rb
    │       ├── cover_art.rb
    │       └── amazon.rb
    └── company/
        ├── importer.rb
        ├── finder.rb
        ├── import_query.rb
        └── providers/
            └── igdb.rb

app/lib/services/
├── ai/tasks/
│   ├── amazon_product_match_task.rb  # Base class
│   ├── music/
│   │   └── amazon_album_match_task.rb
│   └── games/
│       └── amazon_game_match_task.rb
└── games/
    ├── amazon_product_service.rb
    └── country_code_converter.rb

app/sidekiq/games/
├── cover_art_download_job.rb
└── amazon_product_enrichment_job.rb
```

## Performance Considerations

### Efficiency Features
- **Batch Operations**: Multi-item imports process multiple records efficiently
- **Duplicate Prevention**: External identifier lookup prevents redundant processing
- **Strategic Caching**: Provider results can be cached for repeated operations
- **Background Processing**: Async providers don't block user interactions

### Rate Limiting
- IGDB: 4 requests/second (handled by existing rate limiter)
- Amazon: Uses `queue: :serial` for controlled throughput
- IGDB CDN: Uses `queue: :serial` for image downloads

### Monitoring
- **Structured Logging**: Comprehensive logs for all operations
- **Error Tracking**: Provider-specific error reporting
- **Performance Metrics**: Import timing and success rates
- **Business Intelligence**: Track data enrichment coverage

## Related Documentation

For implementation details, see individual class documentation:
- [ImporterBase](../lib/data_importers/importer_base.md) - Core orchestration logic
- [FinderBase](../lib/data_importers/finder_base.md) - Duplicate detection strategies
- [ProviderBase](../lib/data_importers/provider_base.md) - External data integration patterns

For external API documentation:
- [IGDB API Wrapper](./igdb-api-wrapper.md) - IGDB integration details

For specs:
- [Games Data Importers Spec](../specs/completed/games-data-importers.md) - Implementation details
