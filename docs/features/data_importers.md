# DataImporters Feature

## Overview
The DataImporters system provides a flexible, extensible framework for importing and enriching data from external sources across all media types (books, movies, games, music). It uses a strategy pattern with domain-agnostic base classes and domain-specific implementations to handle complex data integration workflows.

## Architecture

### Core Design Principles
- **Strategy Pattern**: Separates concerns between orchestration (Importers), finding (Finders), and data fetching (Providers)
- **Domain-Agnostic Base Classes**: Shared logic for all media types
- **Incremental Saving**: Items saved after each successful provider for background job compatibility
- **Provider Aggregation**: Multiple providers can enrich the same record
- **Intelligent Duplicate Detection**: Uses external identifiers and fallback matching strategies

### System Components

#### Base Classes (Domain-Agnostic)
- **ImporterBase** - Main orchestration logic with provider aggregation and incremental saving
- **FinderBase** - Base class for finding existing records via external identifiers
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
  def populate(item, query:)
    # Fetch and populate data immediately
    # Save happens automatically after this returns success
    ProviderResult.new(success: true, provider_name: self.class.name)
  end
end
```

**Asynchronous Provider:**
```ruby
class Providers::CoverArt < ProviderBase
  def populate(item, query:)
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

### Music Providers

#### MusicBrainz
- Artist, album, and release data import
- Graceful "not found" handling (treated as success)
- Identifier management: MusicBrainz IDs, ISNIs
- Category population from tags (genres, locations)
- Relationship handling: artist credits, album associations

#### AI Description (Async)
- Queues `AiDescriptionJob` for AI-generated descriptions
- Uses Claude for natural language descriptions

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
2. **Find Existing**: Use external identifiers for reliable duplicate detection
3. **Early Return**: Skip providers if existing item found (unless force_providers: true)
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
- Uses `gpt-5-mini` model with structured outputs

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
2. Implement `populate(item, query:)` method
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
