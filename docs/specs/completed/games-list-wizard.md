# Games List Wizard

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-16
- **Started**: 2026-02-17
- **Completed**: 2026-02-21
- **Developer**: AI Agent

## Overview

Implement the list wizard feature for the games domain, following the same 7-step pattern as music (songs/albums). Uses IGDB instead of MusicBrainz for enrichment and import. Only supports `custom_html` import source (no series/franchise import).

**Scope**: Full wizard (source → parse → enrich → validate → review → import → complete), including shared infrastructure extraction from music.

**Non-goals**: IGDB franchise/series import, public-facing wizard, batch mode for games (can add later).

## Context & Links

- Related: `docs/features/list-wizard.md` (full wizard architecture docs)
- Music albums wizard (pattern to follow): `app/controllers/admin/music/albums/list_wizard_controller.rb`
- IGDB wrapper docs: `docs/features/igdb-api-wrapper.md`
- Games data importer spec: `docs/specs/completed/games-data-importers.md`
- Existing games AI parser: `app/lib/services/ai/tasks/lists/games/raw_parser_task.rb`

## Interfaces & Contracts

### Domain Model (diffs only)

No new migrations needed. `Games::List` already inherits `wizard_state` JSONB from base `List` model.

**New enrichment metadata keys on ListItem**:
- `game_id` - ID of matched `Games::Game` record
- `game_name` - Title of matched game
- `igdb_id` - IGDB game ID from enrichment
- `igdb_name` - Game name from IGDB
- `igdb_developer_names` - Developer names from IGDB
- `opensearch_match` / `opensearch_score` - OpenSearch match data
- `ai_match_invalid` - Set by validator when match is bad
- `imported_game_id` - ID of imported game record
- `imported_at` - Timestamp of import

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/admin/lists/:list_id/wizard` | Redirect to current step | - | admin |
| GET | `/admin/lists/:list_id/wizard/step/:step` | Show wizard step | step name | admin |
| GET | `/admin/lists/:list_id/wizard/step/:step/status` | JSON poll for job status | step name | admin |
| POST | `/admin/lists/:list_id/wizard/step/:step/advance` | Advance to next step | step-specific params | admin |
| POST | `/admin/lists/:list_id/wizard/step/:step/back` | Go to previous step | - | admin |
| POST | `/admin/lists/:list_id/wizard/save_html` | Save raw HTML | raw_html | admin |
| POST | `/admin/lists/:list_id/wizard/reparse` | Reset parse step | - | admin |
| POST | `/admin/lists/:list_id/wizard/restart` | Reset entire wizard | - | admin |
| GET | `/admin/lists/:list_id/wizard/igdb_game_search` | IGDB game search JSON | query | admin |
| GET | `/admin/lists/:list_id/items/:id/modal/:modal_type` | Load modal content | modal_type | admin |
| POST | `/admin/lists/:list_id/items/:id/verify` | Verify item | - | admin |
| POST | `/admin/lists/:list_id/items/:id/skip` | Skip/exclude item | - | admin |
| PATCH | `/admin/lists/:list_id/items/:id/metadata` | Update item metadata | metadata JSON | admin |
| POST | `/admin/lists/:list_id/items/:id/manual_link` | Link to existing game | game_id | admin |
| POST | `/admin/lists/:list_id/items/:id/link_igdb_game` | Link IGDB game to item | igdb_id | admin |
| POST | `/admin/lists/:list_id/items/:id/re_enrich` | Re-enrich single item | - | admin |
| DELETE | `/admin/lists/:list_id/items/:id` | Delete item | - | admin |

> Routes follow the albums wizard pattern. Source of truth: `config/routes.rb`.

### Schemas (JSON)

**step_status response**:
```json
{
  "status": "running|completed|failed|idle",
  "progress": 0-100,
  "error": "string|null",
  "metadata": {}
}
```

**IGDB game search response**:
```json
{
  "games": [
    {
      "igdb_id": 7346,
      "name": "The Legend of Zelda: Breath of the Wild",
      "developers": ["Nintendo"],
      "release_year": 2017,
      "cover_url": "https://images.igdb.com/..."
    }
  ]
}
```

### Behaviors (pre/postconditions)

**Enrichment strategy** (two-tier, mirroring music pattern):
1. **OpenSearch first**: Search local `Games::Game` index by title (developers optional, boost score when present). If score > 5.0, link `listable_id` directly.
2. **IGDB fallback**: If OpenSearch fails, search IGDB by game name (title only; developers not required). Store `igdb_id` in metadata for later import.
3. If IGDB match found AND a local game with that IGDB ID exists, link directly.
4. Unlike music, developers are **not required** — most game lists contain only titles.

**IGDB rate limiting**:
- All IGDB calls go through existing `Games::Igdb::RateLimiter` (4 req/sec distributed via Redis)
- Enrichment job processes items sequentially (not parallel) to respect rate limits
- IGDB game search autocomplete in review step should debounce client-side (300ms minimum)
- Search endpoint returns max 10 results per query

**Import behavior**:
- Uses `DataImporters::Games::Game::Importer.call(igdb_id: X)` for each item with `igdb_id`
- Importer handles deduplication internally (checks existing games by IGDB ID)
- Items already linked (`listable_id` present) are skipped
- Items marked `ai_match_invalid` are skipped

**Edge cases**:
- Empty list (no items parsed) → enrich step shows "No items" message, allows back
- All items already in DB after enrichment → import step has nothing to import, completes immediately
- IGDB rate limit hit during enrichment → rate limiter blocks (waits), does not fail
- IGDB 401 (expired token) → auto-refresh handled by `Games::Igdb::Authentication`

### Non-Functionals

- **Rate limiting**: All IGDB calls must go through the existing rate limiter. Never bypass it.
- **No N+1**: Review step must use `includes(:listable)` when loading items. Import step loads items in batch.
- **Performance**: IGDB search autocomplete should debounce 300ms+ client-side. Backend capped at 10 results.
- **Security**: All endpoints admin-only via `Admin::Games::BaseController` authentication.

## Acceptance Criteria

### Infrastructure Extraction (Phase 1)

- [x] Extract shared wizard controller concern from `Admin::Music::BaseListWizardController` into a reusable `BaseListWizardController` concern or module that both music and games can use
- [x] Extract `Music::BaseWizardParseListJob` into a domain-agnostic `BaseWizardParseListJob`
- [x] Extract `Music::BaseWizardEnrichListItemsJob` into a domain-agnostic `BaseWizardEnrichListItemsJob`
- [x] Extract `Music::BaseWizardValidateListItemsJob` into a domain-agnostic `BaseWizardValidateListItemsJob`
- [x] Extract `Music::BaseWizardImportJob` into a domain-agnostic `BaseWizardImportJob`
- [x] Music songs and albums wizard jobs continue to work after extraction (existing tests pass)
- [x] Extract `Services::Lists::Music::BaseListItemEnricher` into a domain-agnostic `Services::Lists::BaseListItemEnricher`

### Games Wizard Implementation (Phase 2)

- [x] `Admin::Games::ListWizardController` created, inherits shared concern
- [x] Routes added for games wizard under `resources :lists` in games admin namespace
- [x] All 7 wizard steps render without error: source, parse, enrich, validate, review, import, complete
- [x] Source step: saves raw HTML and advances to parse
- [x] Parse step: enqueues `Games::WizardParseListJob`, shows progress, completes
- [x] Enrich step: enqueues `Games::WizardEnrichListItemsJob` (OpenSearch → IGDB), shows progress
- [x] Validate step: enqueues `Games::WizardValidateListItemsJob` (AI validation), shows progress
- [x] Review step: displays items with filter (all/valid/invalid/missing), per-item actions work
- [x] Import step: enqueues `Games::WizardImportGamesJob`, imports via `DataImporters::Games::Game::Importer`
- [x] Complete step: shows import summary

### Review Step Item Actions

- [x] Edit Metadata: opens modal, saves updated JSON metadata
- [x] Link Existing Game: search games in DB, link to list item
- [x] Search IGDB Games: search IGDB, select result, store igdb_id in metadata
- [x] Re-enrich: re-runs enrichment for single item
- [x] Skip: marks item as skipped
- [x] Verify: marks item as verified
- [x] Delete: removes item with confirmation

### Services & Jobs

- [x] `Services::Lists::Games::ListItemEnricher` created (OpenSearch → IGDB enrichment)
- [x] `Games::WizardParseListJob` created, uses existing `Games::RawParserTask`
- [x] `Games::WizardEnrichListItemsJob` created
- [x] `Games::WizardValidateListItemsJob` created (new AI validator task needed)
- [x] `Games::WizardImportGamesJob` created, uses `DataImporters::Games::Game::Importer`
- [x] `Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask` created for AI validation
- [x] All IGDB calls go through rate limiter

### Testing

- [x] Unit tests for `Games::ListItemEnricher` (8 tests)
- [x] Unit tests for all 4 games wizard jobs (20 tests)
- [x] Integration tests for `Admin::Games::ListWizardController` (22 tests)
- [x] Existing music wizard tests continue to pass after base class extraction

### Golden Examples

**Parse step input** (raw HTML):
```text
1. The Legend of Zelda: Breath of the Wild - Nintendo (2017)
2. Red Dead Redemption 2 - Rockstar Games (2018)
3. The Witcher 3: Wild Hunt - CD Projekt Red (2015)
```

**Parse step output** (ListItems created):
```json
[
  {"position": 1, "metadata": {"title": "The Legend of Zelda: Breath of the Wild", "developers": ["Nintendo"], "release_year": 2017}},
  {"position": 2, "metadata": {"title": "Red Dead Redemption 2", "developers": ["Rockstar Games"], "release_year": 2018}},
  {"position": 3, "metadata": {"title": "The Witcher 3: Wild Hunt", "developers": ["CD Projekt Red"], "release_year": 2015}}
]
```

**Enrichment result** (item metadata after enrichment):
```json
{
  "title": "The Legend of Zelda: Breath of the Wild",
  "developers": ["Nintendo"],
  "release_year": 2017,
  "game_id": 42,
  "game_name": "The Legend of Zelda: Breath of the Wild",
  "opensearch_match": true,
  "opensearch_score": 12.5
}
```

**Enrichment result** (IGDB fallback, no local match):
```json
{
  "title": "Celeste",
  "developers": ["Maddy Makes Games"],
  "release_year": 2018,
  "igdb_id": 25076,
  "igdb_name": "Celeste",
  "igdb_developer_names": ["Maddy Makes Games"],
  "igdb_match": true
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture beyond the agreed extraction.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use Rails generators for new controllers, jobs, components, and stimulus controllers.
- All IGDB API calls must use the existing rate limiter.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan

**Phase 1: Infrastructure Extraction**
1) codebase-analyzer → verify all references to `Music::Base*` job classes
2) Extract base jobs to shared namespace (e.g., `app/sidekiq/base_wizard_*.rb`)
3) Extract shared wizard controller concern from `BaseListWizardController`
4) Extract `BaseListItemEnricher` to domain-agnostic location
5) Update music subclasses to inherit from new shared bases
6) Run full music wizard test suite to verify no regressions

**Phase 2: Games Wizard Implementation**
1) codebase-pattern-finder → collect albums wizard patterns for each file type
2) Generate games wizard controller, jobs, components using Rails generators
3) Create `Services::Lists::Games::ListItemEnricher` (OpenSearch → IGDB)
4) Create `Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask`
5) Create games wizard step components (following albums pattern)
6) Create `Admin::Games::ListItemsActionsController` with item actions
7) Add routes, helper module, and view template
8) Write tests for all new code
9) technical-writer → update list-wizard.md and related docs

### Implementation Order

This spec should be implemented in two phases:

**Phase 1** (infrastructure extraction) is a prerequisite. It should be a separate PR that:
- Extracts shared base classes
- Updates music to use them
- Verifies all music tests pass

**Phase 2** (games wizard) builds on Phase 1 and includes all games-specific code.

### Test Seed / Fixtures

Use existing fixtures:
- `test/fixtures/games/games.yml` (breath_of_the_wild, resident_evil_4, etc.)
- `test/fixtures/games/lists.yml` (may need new wizard-specific fixtures)
- `test/fixtures/list_items.yml` (may need games list items)
- `test/fixtures/users.yml` (admin user for controller tests)

New fixtures needed:
- `test/fixtures/games/lists.yml` - A list with wizard_state for testing
- Games-specific list items with metadata matching expected enrichment format

### Key New Files (expected)

**Shared Infrastructure** (Phase 1):
- `app/sidekiq/base_wizard_parse_list_job.rb`
- `app/sidekiq/base_wizard_enrich_list_items_job.rb`
- `app/sidekiq/base_wizard_validate_list_items_job.rb`
- `app/sidekiq/base_wizard_import_job.rb`
- `app/controllers/concerns/base_list_wizard_controller.rb`
- `app/lib/services/lists/base_list_item_enricher.rb`

**Games Wizard** (Phase 2):
- `app/controllers/admin/games/list_wizard_controller.rb`
- `app/controllers/admin/games/list_items_actions_controller.rb`
- `app/helpers/admin/games/list_wizard_helper.rb`
- `app/views/admin/games/list_wizard/show_step.html.erb`
- `app/sidekiq/games/wizard_parse_list_job.rb`
- `app/sidekiq/games/wizard_enrich_list_items_job.rb`
- `app/sidekiq/games/wizard_validate_list_items_job.rb`
- `app/sidekiq/games/wizard_import_games_job.rb`
- `app/lib/services/lists/games/list_item_enricher.rb`
- `app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb`
- `app/components/admin/games/wizard/source_step_component.rb` (+ 6 more step components)
- `app/components/admin/games/wizard/item_row_component.rb`
- `app/components/admin/games/wizard/shared_modal_component.rb`
- `app/views/admin/games/list_items_actions/` (partials for rows, stats, modals)

---

## Implementation Notes (living)

### Phase 1: Infrastructure Extraction
- Approach taken: Extracted shared base classes from Music namespace, music subclasses now inherit from shared bases
- Important decisions:
  - Stats keys in enrich job are abstract methods (subclasses define their own stat names via `default_stats` and `update_stats`)
  - Controller extracted as a concern (`BaseListWizardController`) using `ActiveSupport::Concern` with `include WizardController` dependency
  - `load_review_step_data` and `load_import_step_data` are abstract in the concern (domain-specific eager loading)
  - Enricher base class uses `find_via_external_api` as abstract method; music implements it via `find_via_musicbrainz`, games will implement via IGDB
  - `build_opensearch_enrichment_data` is overridable (music adds artist names)
  - `source_step_next_index` is overridable (music routes musicbrainz_series to review step)
  - `valid_import_sources` is overridable (music adds musicbrainz_series, games uses only custom_html)
  - `series_import_source_name` is overridable on import job (default: "musicbrainz_series")

### Phase 2: Games Wizard Implementation
- Approach taken: Created games-specific wizard components, controllers, jobs, services, and views following the music albums wizard pattern
- Important decisions:
  - **Games-specific step components**: Created standalone step components instead of inheriting from music base step components, since music components contain MusicBrainz-specific stats and references
  - **`metadata_artists_key` on base enricher**: Added overridable `metadata_artists_key` method to `BaseListItemEnricher` (default: `"artists"`) so games enricher can override to `"developers"` without duplicating the full `call` method
  - **OpenSearch compatibility**: `GameByTitleAndDevelopers` accepts the same `artists:` parameter name as the music equivalent but searches the `developer_names` field — maintains API compatibility with base enricher
  - **IGDB ID lookup via identifiers table**: IGDB IDs are stored in the polymorphic `identifiers` table (not a column on `Games::Game`). Added `with_identifier` and `with_igdb_id` scopes to `Games::Game`
  - **Games eager loading**: Overrode `set_item` in `ListItemsActionsController` to use `includes(listable: {game_companies: :company})` instead of music's `includes(listable: :artists)`
  - **`ItemRowComponent` inheritance**: Games `ItemRowComponent` inherits from `Admin::Music::Wizard::ItemRowComponent` and overrides games-specific rendering (developers, IGDB badge, game-specific menu items)
  - **`SharedModalComponent`**: Empty subclass of `Admin::Music::Wizard::SharedModalComponent` with games-specific constants

### Key Files Touched (paths only)

**Phase 1 — New shared base files:**
- `app/sidekiq/base_wizard_parse_list_job.rb`
- `app/sidekiq/base_wizard_enrich_list_items_job.rb`
- `app/sidekiq/base_wizard_validate_list_items_job.rb`
- `app/sidekiq/base_wizard_import_job.rb`
- `app/controllers/concerns/base_list_wizard_controller.rb`
- `app/lib/services/lists/base_list_item_enricher.rb`

**Phase 1 — Modified music files (now inherit from shared bases):**
- `app/sidekiq/music/base_wizard_parse_list_job.rb`
- `app/sidekiq/music/base_wizard_enrich_list_items_job.rb`
- `app/sidekiq/music/base_wizard_validate_list_items_job.rb`
- `app/sidekiq/music/base_wizard_import_job.rb`
- `app/controllers/admin/music/base_list_wizard_controller.rb`
- `app/lib/services/lists/music/base_list_item_enricher.rb`

**Phase 2 — New games wizard files:**
- `app/controllers/admin/games/list_wizard_controller.rb`
- `app/controllers/admin/games/list_items_actions_controller.rb`
- `app/helpers/admin/games/list_wizard_helper.rb`
- `app/helpers/admin/games/list_items_actions_helper.rb`
- `app/views/admin/games/list_wizard/show_step.html.erb`
- `app/views/admin/games/list_items_actions/` (partials: _item_row, _review_stats, _flash_success, _error_message, modals/)
- `app/sidekiq/games/wizard_parse_list_job.rb`
- `app/sidekiq/games/wizard_enrich_list_items_job.rb`
- `app/sidekiq/games/wizard_validate_list_items_job.rb`
- `app/sidekiq/games/wizard_import_games_job.rb`
- `app/lib/services/lists/games/list_item_enricher.rb`
- `app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb`
- `app/lib/search/games/search/game_by_title_and_developers.rb`
- `app/components/admin/games/wizard/` (7 step components + item_row + shared_modal)

**Phase 2 — Modified existing files:**
- `app/lib/services/lists/base_list_item_enricher.rb` (added `metadata_artists_key`, `require_artists?`, title-only enrichment support)
- `app/lib/search/games/search/game_by_title_and_developers.rb` (developers optional, title-only search)
- `app/models/games/game.rb` (added `with_identifier` and `with_igdb_id` scopes)
- `app/lib/services/lists/wizard/state_manager.rb` (added `Games::List` to factory)
- `app/views/admin/games/lists/show.html.erb` (added Launch Wizard button)
- `config/routes.rb` (added games wizard routes)

**Phase 2 — New test files:**
- `test/controllers/admin/games/list_wizard_controller_test.rb` (22 tests)
- `test/lib/services/lists/games/list_item_enricher_test.rb` (8 tests)
- `test/sidekiq/games/wizard_parse_list_job_test.rb` (5 tests)
- `test/sidekiq/games/wizard_enrich_list_items_job_test.rb` (5 tests)
- `test/sidekiq/games/wizard_validate_list_items_job_test.rb` (4 tests)
- `test/sidekiq/games/wizard_import_games_job_test.rb` (6 tests)

### Challenges & Resolutions
- **Module inclusion order** (Phase 1): Using `included do; include WizardController; end` caused `WizardController#wizard_steps` to override `BaseListWizardController#wizard_steps` in Ruby's MRO. Fixed by using `ActiveSupport::Concern`'s dependency mechanism (`include WizardController` at module level) which ensures correct method resolution order.
- **Metadata key mismatch** (Phase 2): Base enricher hardcoded `metadata["artists"]` but games use `metadata["developers"]`. Resolved by adding `metadata_artists_key` override method to the base class.
- **IGDB ID storage** (Phase 2): IGDB IDs stored in polymorphic `identifiers` table, not as a column on `Games::Game`. Added scopes to query through the association.
- **Test isolation** (Phase 2): Advance step tests triggered inline Sidekiq execution which called real APIs. Fixed by stubbing `perform_async` on job classes.
- **Title-only enrichment** (Post-implementation): Enricher originally required developers to be present, but most game lists only have titles. Fixed by adding `require_artists?` override (false for games) and making OpenSearch/IGDB work with title-only queries.
- **IGDB field expansion** (Post-implementation): `search_by_name` default fields returned `involved_companies` as integer IDs instead of expanded objects. Fixed by passing explicit fields (`involved_companies.company.name`, `involved_companies.developer`, `cover.image_id`) to the enricher and controller search calls.
- **Missing Launch Wizard link** (Post-implementation): Games list show page was missing the wizard button. Added matching the music pattern with sparkles icon and "In Progress" badge.

### Deviations From Plan
- **Title-only enrichment**: Spec originally described enrichment requiring both title + developer. Updated to make developers optional for games since most game lists contain only titles. OpenSearch and IGDB both work title-only; developers boost score when present.

## Acceptance Results
- **Phase 1**: 2026-02-17, AI Agent, 3811 tests pass (185 wizard-specific), 0 failures, 0 errors
- **Phase 2**: 2026-02-21, AI Agent, 3860 tests pass (49 games wizard-specific), 0 failures, 0 errors

## Future Improvements
- IGDB franchise/series import as a second import source
- Batch mode support for large game lists
- Developer autocomplete using IGDB CompanySearch in review step
- Platform filtering in review step

## Related PRs
- #...

## Documentation Updated
- [ ] `docs/features/list-wizard.md` - add games implementation section
- [ ] Class docs for new controllers/services
- [ ] `docs/features/igdb-api-wrapper.md` - document new search usage patterns
