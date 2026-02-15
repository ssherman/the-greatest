# Games Data Importers - Game & Company

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-14
- **Started**: 2026-02-15
- **Completed**: 2026-02-15
- **Developer**: Claude Opus 4.5

## Overview
Implement data importers for `Games::Game` and `Games::Company` models using IGDB as the primary data source. Games import via IGDB ID only, with async providers for cover art (IGDB CDN) and Amazon product enrichment (AI-validated). Companies import via IGDB ID with a single synchronous provider.

**Scope:**
- Import games by IGDB ID (no name search)
- Import companies by IGDB ID (no name search)
- Recursive company import when importing games
- Platform, genre, theme, game_mode, player_perspective category population
- Cover art download from IGDB CDN only (no Amazon fallback)
- Amazon product enrichment with AI validation

**Non-Goals:**
- Name-based search/import (future enhancement)
- AI description generation (future enhancement)
- Bulk import across all IGDB games (future enhancement)

## Context & Links
- Related: `docs/features/data_importers.md` - DataImporters system overview
- Related: `docs/specs/completed/games-data-model.md` - Games data model
- Related: `docs/features/igdb-api-wrapper.md` - IGDB API wrapper documentation
- Pattern source: `app/lib/data_importers/music/artist/` - Music::Artist importer
- Pattern source: `app/lib/data_importers/music/album/` - Music::Album importer

## Interfaces & Contracts

### Domain Model (existing - no migrations needed)
All models and identifier types already exist:
- `Games::Game` - has identifiers, images, categories, external_links, companies, platforms
- `Games::Company` - has identifiers, images, external_links
- `Identifier` - `games_igdb_id: 400`, `games_igdb_company_id: 410`
- `Games::Category` - `category_type`: genre, theme, game_mode, player_perspective

### API Contracts

#### Games::Game::Importer
```ruby
# Import by IGDB ID
result = DataImporters::Games::Game::Importer.call(igdb_id: 7346)

# Re-enrich existing game
result = DataImporters::Games::Game::Importer.call(igdb_id: 7346, force_providers: true)

# Enrich existing game object
result = DataImporters::Games::Game::Importer.call(item: game)

# Selective providers
result = DataImporters::Games::Game::Importer.call(item: game, providers: [:igdb, :cover_art])
```

**Providers (execution order):**
1. `Providers::Igdb` - sync: core data, companies, platforms, categories
2. `Providers::CoverArt` - async: queues `Games::CoverArtDownloadJob`
3. `Providers::Amazon` - async: queues `Games::AmazonProductEnrichmentJob`

#### Games::Company::Importer
```ruby
# Import by IGDB ID
result = DataImporters::Games::Company::Importer.call(igdb_id: 70)

# Re-enrich existing company
result = DataImporters::Games::Company::Importer.call(igdb_id: 70, force_providers: true)
```

**Providers:**
1. `Providers::Igdb` - sync: name, description, country, year_founded

### Schemas (ImportQuery validation)

#### Games::Game::ImportQuery
```json
{
  "type": "object",
  "required": ["igdb_id"],
  "properties": {
    "igdb_id": {
      "type": "integer",
      "minimum": 1,
      "description": "IGDB game ID (required)"
    }
  },
  "additionalProperties": false
}
```

#### Games::Company::ImportQuery
```json
{
  "type": "object",
  "required": ["igdb_id"],
  "properties": {
    "igdb_id": {
      "type": "integer",
      "minimum": 1,
      "description": "IGDB company ID (required)"
    }
  },
  "additionalProperties": false
}
```

### AI Task Schema: AmazonGameMatchTask

**Purpose:** Filter Amazon search results to find products **related to or associated with** the game. Amazon's search is notoriously poor and returns unrelated products - the AI validates relevance.

**What IS a match (include):**
- The game itself (any edition, platform, format)
- Strategy guides and walkthroughs
- Art books and "making of" books
- Official soundtracks
- Collectibles and figures (officially licensed)
- DLC, season passes, expansion packs
- Remasters, remakes, definitive editions
- Bundles that include the game

**What is NOT a match (exclude):**
- Completely unrelated products
- Products for different games with similar names
- Generic gaming accessories not specific to this game
- Fan-made or unofficial merchandise
- Products that just mention the game in reviews/description

**Response Schema:**
```json
{
  "type": "object",
  "required": ["matching_results"],
  "properties": {
    "matching_results": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["asin", "title", "product_type", "explanation"],
        "properties": {
          "asin": { "type": "string" },
          "title": { "type": "string" },
          "product_type": {
            "type": "string",
            "enum": ["game", "guide", "artbook", "soundtrack", "collectible", "dlc", "bundle", "other"]
          },
          "platform": { "type": "string" },
          "explanation": { "type": "string" }
        }
      }
    }
  }
}
```

### Behaviors (pre/postconditions)

#### IGDB Provider - Game
**Preconditions:**
- Query has valid `igdb_id` (positive integer)
- IGDB API credentials configured

**Postconditions:**
- Game populated: title, description, release_year, game_type
- Identifier created: `games_igdb_id`
- Companies imported recursively (via Company::Importer)
- GameCompany join records created (developer/publisher flags)
- Platforms found or created, GamePlatform joins created
- Categories found or created: genres, themes, game_modes, player_perspectives
- CategoryItem joins created

**Edge Cases:**
- IGDB returns 404: return failure_result
- Company import fails: log warning, continue with game import
- Platform not in database: auto-create with name, slug, abbreviation from IGDB; infer platform_family
- Platform data missing slug: skip (slug required for lookup/creation)

#### IGDB Provider - Company
**Preconditions:**
- Query has valid `igdb_id` (positive integer)

**Postconditions:**
- Company populated: name, description, country, year_founded
- Identifier created: `games_igdb_company_id`

#### CoverArt Provider
**Preconditions:**
- Game is persisted (has ID)
- Game has IGDB identifier

**Postconditions:**
- Job queued: `Games::CoverArtDownloadJob.perform_async(game.id)`
- Returns success immediately with `data_populated: [:cover_art_queued]`

**Job Behavior:**
1. Skip if game already has primary image
2. Get IGDB cover image_id from game data (stored in metadata or fetched via CoverSearch)
3. Build URL: `https://images.igdb.com/igdb/image/upload/t_cover_big/{image_id}.jpg`
4. Download via Down gem
5. Create Image record with primary: true
6. No Amazon fallback (all-products search could return books/merchandise with wrong covers)

#### Amazon Provider
**Preconditions:**
- Game is persisted
- Game has title

**Postconditions:**
- Job queued: `Games::AmazonProductEnrichmentJob.perform_async(game.id)`
- Returns success immediately

**Job/Service Behavior:**
1. Search Amazon (all categories) for game title
2. Call AI validation task (`AmazonGameMatchTask`) to filter out unrelated products
   - Amazon search is notoriously poor; AI confirms products are actually related to the game
   - Includes: game editions, guides, artbooks, soundtracks, collectibles, DLC
   - Excludes: unrelated products, different games with similar names
3. Create external_links for validated products (with `product_type` in metadata)
4. No image download (IGDB-only for cover art to avoid merchandise/book images)

### Non-Functionals
- **Performance**: IGDB provider should complete in < 5 seconds (single API call + recursive company imports)
- **Rate Limiting**: IGDB enforces 4 req/sec; existing rate limiter handles this
- **N+1 Prevention**: Batch platform/category lookups where possible
- **Idempotency**: All jobs must be safely retryable
- **Queue**: Async jobs use `queue: :serial` for rate-limited external APIs

## Acceptance Criteria

### Games::Game Importer
- [x] `Importer.call(igdb_id: 7346)` creates game with correct title from IGDB
- [x] Game has identifier with `identifier_type: :games_igdb_id`, `value: "7346"`
- [x] Developers and publishers imported as `Games::Company` records
- [x] `GameCompany` joins created with correct `developer`/`publisher` flags
- [x] Platforms found by slug or auto-created, linked via `GamePlatform` joins
- [x] Categories created: genres, themes, game_modes, player_perspectives
- [x] Duplicate import returns existing game (unless `force_providers: true`)
- [x] `force_providers: true` re-runs all providers on existing game
- [x] CoverArt provider queues job and returns success immediately
- [x] Amazon provider queues job and returns success immediately
- [x] `providers: [:igdb]` runs only IGDB provider

### Games::Company Importer
- [x] `Importer.call(igdb_id: 70)` creates company with correct name from IGDB
- [x] Company has identifier with `identifier_type: :games_igdb_company_id`
- [x] Description, country, year_founded populated from IGDB
- [x] Duplicate import returns existing company

### Sidekiq Jobs
- [x] `CoverArtDownloadJob` downloads image from IGDB CDN
- [x] `CoverArtDownloadJob` skips if primary image exists
- [x] `CoverArtDownloadJob` gracefully handles missing IGDB cover (no fallback)
- [x] `AmazonProductEnrichmentJob` searches Amazon and calls AI validation
- [x] `AmazonProductEnrichmentJob` creates external_links for validated products (no image download)
- [x] Both jobs are idempotent (safe to retry)

### AI Tasks
- [x] `AmazonProductMatchTask` base class extracted from existing Music task
- [x] `AmazonAlbumMatchTask` refactored to inherit from base (no behavior change)
- [x] `AmazonGameMatchTask` inherits from base, uses game-specific prompts
- [x] `AmazonGameMatchTask` finds **related products** (guides, soundtracks, collectibles) not just exact game matches
- [x] `AmazonGameMatchTask` filters out unrelated products from Amazon's poor search results
- [x] `AmazonGameMatchTask` returns `product_type` for each match (game, guide, artbook, soundtrack, collectible, etc.)
- [x] All AI tasks use `gpt-5-mini` model

### Golden Examples

**Game Import:**
```text
Input: DataImporters::Games::Game::Importer.call(igdb_id: 7346)
Output:
  - result.success? == true
  - result.item.title == "The Legend of Zelda: Breath of the Wild"
  - result.item.release_year == 2017
  - result.item.identifiers.find_by(identifier_type: :games_igdb_id).value == "7346"
  - result.item.developers.map(&:name).include?("Nintendo EPD")
  - result.item.platforms.map(&:name).include?("Nintendo Switch")
  - result.item.categories.genre.map(&:name).include?("Adventure")
```

**Amazon AI Validation (after async job runs):**
```text
Input: Amazon search returns 15 products for "Zelda Breath of the Wild"
AI Output (example matching_results):
  - { asin: "B01MS6MO77", title: "Zelda: BotW - Nintendo Switch", product_type: "game" }
  - { asin: "B06XBYCM49", title: "Zelda: BotW Official Strategy Guide", product_type: "guide" }
  - { asin: "B07BFMJ9KX", title: "The Legend of Zelda: BotW - Creating a Champion", product_type: "artbook" }
  - { asin: "B071GSZD8J", title: "Link Nendoroid Figure - BotW", product_type: "collectible" }
Excluded by AI:
  - "Zelda Costume for Kids" (unrelated merchandise)
  - "The Legend of Heroes: Trails..." (different game)
```

**Company Import:**
```text
Input: DataImporters::Games::Company::Importer.call(igdb_id: 70)
Output:
  - result.success? == true
  - result.item.name == "Nintendo"
  - result.item.identifiers.find_by(identifier_type: :games_igdb_company_id).value == "70"
```

---

## Agent Hand-Off

### Constraints
- Follow existing DataImporters patterns exactly (see `Music::Artist::Importer`)
- Use Rails generators for Sidekiq jobs
- Respect snippet budget (<=40 lines per code block in this spec)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → verify Music importer patterns still match
2) codebase-analyzer → verify IGDB search class methods needed
3) technical-writer → update docs/features/data_importers.md with Games support

### Test Seed / Fixtures
- Use existing `games_games.yml` fixtures (if any)
- Create minimal fixtures for tests:
  - `games_game_igdb_test.yml` - game with known IGDB ID
  - `games_company_igdb_test.yml` - company with known IGDB ID

---

## Implementation Notes (living)

### Approach
- Phase 1: Build Games::Company importer first (simpler, no dependencies)
- Phase 2: Build Games::Game importer (depends on Company importer)
- Phase 3: Add CoverArt provider and job
- Phase 4: Extract AmazonProductMatchTask base class
- Phase 5: Add Amazon provider, job, service, and AI task

### Key Implementation Details

**IGDB Provider Data Mapping:**
| IGDB Field | Game Attribute |
|------------|----------------|
| `name` | `title` |
| `summary` | `description` |
| `first_release_date` | `release_year` (extract year from Unix timestamp) |
| `game_type` | `game_type` (map: 0→main_game, 8→remake, 9→remaster) |
| `involved_companies` | recursive import via Company::Importer |
| `platforms` | find_or_create Games::Platform, create GamePlatform joins |
| `genres` | find_or_create Games::Category (category_type: :genre) |
| `themes` | find_or_create Games::Category (category_type: :theme) |
| `game_modes` | find_or_create Games::Category (category_type: :game_mode) |
| `player_perspectives` | find_or_create Games::Category (category_type: :player_perspective) |
| `cover.image_id` | store in metadata for CoverArt job |

**Company Data Mapping:**
| IGDB Field | Company Attribute |
|------------|-------------------|
| `name` | `name` |
| `description` | `description` |
| `country` | `country` (convert IGDB country code to ISO 2-letter) |
| `start_date` | `year_founded` (extract year) |

### Key Files Touched (paths only)
**New Files:**
- `app/lib/data_importers/games/game/importer.rb`
- `app/lib/data_importers/games/game/finder.rb`
- `app/lib/data_importers/games/game/import_query.rb`
- `app/lib/data_importers/games/game/providers/igdb.rb`
- `app/lib/data_importers/games/game/providers/cover_art.rb`
- `app/lib/data_importers/games/game/providers/amazon.rb`
- `app/lib/data_importers/games/company/importer.rb`
- `app/lib/data_importers/games/company/finder.rb`
- `app/lib/data_importers/games/company/import_query.rb`
- `app/lib/data_importers/games/company/providers/igdb.rb`
- `app/sidekiq/games/cover_art_download_job.rb`
- `app/sidekiq/games/amazon_product_enrichment_job.rb`
- `app/lib/services/games/amazon_product_service.rb`
- `app/lib/services/ai/tasks/amazon_product_match_task.rb`
- `app/lib/services/ai/tasks/games/amazon_game_match_task.rb`

**Modified Files:**
- `app/lib/services/ai/tasks/music/amazon_album_match_task.rb` (inherit from base)
- `app/controllers/admin/category_items_controller.rb` (add game_id handling)
- `app/controllers/admin/images_controller.rb` (add game_id, company_id handling)

**Test Files:**
- `test/lib/data_importers/games/game/importer_test.rb`
- `test/lib/data_importers/games/game/finder_test.rb`
- `test/lib/data_importers/games/game/providers/igdb_test.rb`
- `test/lib/data_importers/games/game/providers/cover_art_test.rb`
- `test/lib/data_importers/games/game/providers/amazon_test.rb`
- `test/lib/data_importers/games/company/importer_test.rb`
- `test/lib/data_importers/games/company/providers/igdb_test.rb`
- `test/sidekiq/games/cover_art_download_job_test.rb`
- `test/sidekiq/games/amazon_product_enrichment_job_test.rb`
- `test/lib/services/games/amazon_product_service_test.rb`
- `test/lib/services/ai/tasks/amazon_product_match_task_test.rb`
- `test/lib/services/ai/tasks/games/amazon_game_match_task_test.rb`

### Challenges & Resolutions
- **IGDB game_type mapping**: IGDB uses different numeric values than our enum. Created a mapping table in the provider instead of changing database values.
- **Cover art storage**: Spec mentioned "store in metadata" but Game model doesn't have metadata. Used CoverSearch API approach instead - job fetches image_id from IGDB using game's IGDB ID.
- **OpenAI schema optional fields**: `optional` is not supported in OpenAI structured outputs. Used `required :field, Type, nil?: true` instead.
- **Platform auto-creation**: Initially platforms were only matched by name, causing imports to skip unknown platforms. Changed to find_or_create by slug with automatic `platform_family` inference from slug/name patterns.
- **Admin controllers**: Shared `Admin::CategoryItemsController` and `Admin::ImagesController` needed updates to handle `Games::Game` and `Games::Company` items (added `game_id`/`company_id` params handling).

### Deviations From Plan
- **No migration needed**: game_type enum extension only required model changes, not database migration (Rails enums are model-level mappings)
- **Additional enum values**: Added `expanded_game` and `port` beyond spec to match full IGDB category list
- **Platform auto-creation**: Original spec said "skip unknown platforms" but changed to auto-create to avoid losing platform data from IGDB

## Acceptance Results
- **Date**: 2026-02-15
- **Verifier**: Automated tests
- **Test Results**: 89 new tests, all passing. Full suite: 3795 tests, 0 failures.

## Future Improvements
- Name-based search/import (search IGDB by game name)
- AI description generation provider
- Bulk import for all games in a franchise/series
- Series/franchise import
- Screenshot/artwork import from IGDB
- Release date tracking (multiple releases per platform)

## Related PRs
- TBD

## Documentation Updated
- [x] `docs/specs/games-data-importers.md` - Updated with implementation notes
- [ ] `docs/features/data_importers.md` - Add Games section (follow-up task)
