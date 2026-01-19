# Year Filtering for Ranked Items

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-18
- **Started**: 2026-01-19
- **Completed**: 2026-01-19
- **Developer**: Claude

## Overview
Implement year filtering for album and song ranked item lists with SEO-friendly URLs. Users can filter by decade (1990s), year range (1980-2000), single year (1994), open-ended since (since/1980), or open-ended through (through/1980). Pages display rankings sorted by rank with dynamic SEO titles and descriptions. No UI controls yet - manual URL testing only.

**Non-goals:**
- UI filters (dropdown, date picker) - future spec
- Genre filtering - future spec
- OpenSearch integration - future optimization

## Context & Links
- Related tasks: Future genre filtering, OpenSearch optimization, singular show routes spec
- Source files (authoritative):
  - `app/lib/filters/year_filter.rb`
  - `app/lib/services/ranked_items_filter_service.rb`
  - `app/controllers/music/albums/ranked_items_controller.rb`
  - `app/controllers/music/songs/ranked_items_controller.rb`
  - `app/models/music/album.rb`
  - `app/models/music/song.rb`
- External docs: None required

## Interfaces & Contracts

### Domain Model (diffs only)

**Indexes added:**
- `music_albums.release_year` - standard btree index
- `music_songs.release_year` - standard btree index

Migration file: `db/migrate/20260119020707_add_release_year_indexes_to_music.rb`

### Endpoints
| Verb | Path | Purpose | Params | Auth |
|---|---|---|---|---|
| GET | /albums/:year | Albums filtered by decade/range/single | year: `1990s`, `1980-2000`, `1994` | public |
| GET | /albums/since/:year | Albums since year (open-ended) | year: `1980` | public |
| GET | /albums/through/:year | Albums through year (open-ended) | year: `1980` | public |
| GET | /songs/:year | Songs filtered by decade/range/single | year: `1990s`, `1980-2000`, `1994` | public |
| GET | /songs/since/:year | Songs since year (open-ended) | year: `1980` | public |
| GET | /songs/through/:year | Songs through year (open-ended) | year: `1980` | public |
| GET | /rc/:id/albums/:year | Albums by year with specific RC | ranking_configuration_id, year | public |
| GET | /rc/:id/songs/:year | Songs by year with specific RC | ranking_configuration_id, year | public |

> Note: Pagination handled via query string `?page=2` (Pagy default).

> Source of truth: `config/routes.rb` - routes use constraints to validate year format.

### Schemas (JSON)

**YearFilter Result:**
```json
{
  "type": "object",
  "required": ["display", "type"],
  "properties": {
    "start_year": { "type": ["integer", "null"] },
    "end_year": { "type": ["integer", "null"] },
    "display": { "type": "string" },
    "type": { "type": "string", "enum": ["decade", "range", "single", "since", "through"] }
  },
  "additionalProperties": false
}
```

**Examples:**
- `1990s` → `{start_year: 1990, end_year: 1999, display: "1990s", type: :decade}`
- `1980-2000` → `{start_year: 1980, end_year: 2000, display: "1980-2000", type: :range}`
- `1994` → `{start_year: 1994, end_year: 1994, display: "1994", type: :single}`
- `since/1980` → `{start_year: 1980, end_year: nil, display: "1980", type: :since}`
- `through/1980` → `{start_year: nil, end_year: 1980, display: "1980", type: :through}`

**SEO title generation** uses the `type` field:
- `:decade` → "Greatest Albums of the 1990s"
- `:range` → "Greatest Albums from 1980 to 2000"
- `:single` → "Greatest Albums of 1994"
- `:since` → "Greatest Albums Since 1980"
- `:through` → "Greatest Albums Through 1980"

### Behaviors (pre/postconditions)

**Preconditions:**
- Year parameter must match appropriate regex per route
- Decades must be valid (1900s-2020s typically)
- Range start must be <= end
- Ranking configuration must exist (or use default)

**Postconditions/effects:**
- Results filtered by release_year within range (or open-ended)
- Results ordered by rank (ascending)
- Results paginated (100 per page)
- Page title dynamically set based on filter type
- Cache-Control headers set (6 hours)

**Edge cases & failure modes:**
- Invalid year format → 404 Not Found
- No results for year → Empty state (already handled)
- Year range reversed (2000-1980) → Treat as invalid, return 404
- Null release_year records → Excluded from filtered results (WHERE clause)
- Single year outside valid range → Return empty (no error)

### Non-Functionals
- **Performance**: Index on release_year ensures O(log n) filtering
- **Query limits**: Pagy pagination limits to 100 per page
- **N+1**: Existing `.includes()` pattern preserved
- **Security**: Public pages, no auth required
- **Caching**: Existing Cacheable concern applies (6 hour cache per URL)

## Acceptance Criteria
- [x] `/albums/1990s` returns albums with release_year 1990-1999, ordered by rank
- [x] `/songs/1990s` returns songs with release_year 1990-1999, ordered by rank
- [x] `/albums/1980-2000` returns albums with release_year 1980-2000, ordered by rank
- [x] `/albums/1994` returns albums with release_year = 1994, ordered by rank
- [x] `/albums/since/1980` returns albums with release_year >= 1980, ordered by rank
- [x] `/albums/through/1980` returns albums with release_year <= 1980, ordered by rank
- [x] `/songs/since/1980` returns songs with release_year >= 1980, ordered by rank
- [x] `/songs/through/1980` returns songs with release_year <= 1980, ordered by rank
- [x] `/albums/1990s?page=2` returns second page of filtered results
- [x] `/rc/:id/albums/1990s` works with specific ranking configuration
- [x] Page title is "Greatest Albums of the 1990s" for decades
- [x] Page title is "Greatest Albums from 1980 to 2000" for ranges
- [x] Page title is "Greatest Albums of 1994" for single years
- [x] Page title is "Greatest Albums Since 1980" for since
- [x] Page title is "Greatest Albums Through 1980" for through
- [x] Meta description includes year context
- [x] Invalid year format returns 404
- [x] Indexes exist on release_year for both tables
- [x] All tests pass (3128 runs, 0 failures)

### Golden Examples

**Decade filtering:**
```text
Input: GET /albums/1990s
Output: Albums ranked 1-100 where release_year BETWEEN 1990 AND 1999
Page Title: "Greatest Albums of the 1990s"
```

**Range filtering:**
```text
Input: GET /songs/1980-2000
Output: Songs ranked 1-100 where release_year BETWEEN 1980 AND 2000
Page Title: "Greatest Songs from 1980 to 2000"
```

**Single year filtering:**
```text
Input: GET /albums/1994
Output: Albums ranked 1-100 where release_year = 1994
Page Title: "Greatest Albums of 1994"
```

**Since (open-ended):**
```text
Input: GET /albums/since/1980
Output: Albums ranked 1-100 where release_year >= 1980
Page Title: "Greatest Albums Since 1980"
```

**Through (open-ended):**
```text
Input: GET /songs/through/1970
Output: Songs ranked 1-100 where release_year <= 1970
Page Title: "Greatest Songs Through 1970"
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → completed (service patterns, model scopes)
2) codebase-analyzer → completed (controller structure, routing)
3) web-search-researcher → not needed
4) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Use existing album/song fixtures
- Ensure fixtures have varied release_year values (1980s, 1990s, 2000s, etc.)

---

## Implementation Notes (living)

### Approach
- Created `Filters::YearFilter` query object for parsing year parameters (returns Result struct with start_year, end_year, display, type)
- Created `Services::RankedItemsFilterService` for applying filters to queries (handles nil start/end for open-ended ranges)
- Added model scope: `released_in_range(start_year, end_year)` - all formats use this single scope
- Added helper module `Music::RankedItemsHelper` for SEO title generation (uses `type` field)
- Minimal controller changes to integrate filtering
- Routes use constraints to validate year format before reaching controller
- Routes use `defaults: {year_mode: "since"}` and `defaults: {year_mode: "through"}` for open-ended modes

### Important Decisions
- Using path-based routing (`/albums/1990s`, `/albums/since/1980`) for SEO vs query params
- Service class for filtering to enable future genre extension
- Single `released_in_range` scope handles all formats (decades, ranges, single years are all just start/end ranges)
- SEO title format derived from `type` field in YearFilter::Result struct
- Open-ended routes use path segments (`/since/`, `/through/`) rather than suffixes (rejected `+` as not URL-safe)
- Route ordering: Year routes before `:id` routes to avoid conflicts with album slugs (future spec for singular routes)

### Key Files Touched (paths only)

**New files:**
- `app/lib/filters/year_filter.rb`
- `app/lib/services/ranked_items_filter_service.rb`
- `app/helpers/music/ranked_items_helper.rb`
- `app/helpers/music/songs/ranked_items_helper.rb`
- `db/migrate/20260119020707_add_release_year_indexes_to_music.rb`
- `test/lib/filters/year_filter_test.rb`
- `test/lib/services/ranked_items_filter_service_test.rb`
- `test/helpers/music/albums/ranked_items_helper_test.rb`
- `test/helpers/music/songs/ranked_items_helper_test.rb`

**Modified files:**
- `config/routes.rb`
- `app/models/music/album.rb`
- `app/models/music/song.rb`
- `app/controllers/music/ranked_items_controller.rb` (added shared `parse_year_filter`)
- `app/controllers/music/albums/ranked_items_controller.rb`
- `app/controllers/music/songs/ranked_items_controller.rb`
- `app/helpers/music/albums/ranked_items_helper.rb`
- `app/views/music/albums/ranked_items/index.html.erb`
- `app/views/music/songs/ranked_items/index.html.erb`
- `test/controllers/music/albums/ranked_items_controller_test.rb`
- `test/controllers/music/songs/ranked_items_controller_test.rb`

### Challenges & Resolutions
- **Route priority**: Year routes must come before `:id` routes to avoid conflicts with album slugs
- **Filter position in JOIN query**: Must filter on joined table column (music_albums.release_year)
- **Namespace conflict**: `Filters::YearFilter` conflicts with Rails' `ActiveSupport::Callbacks::Filters` - resolved using `::Filters::YearFilter`
- **Open-ended ranges**: Service handles nil start_year (through) and nil end_year (since) with separate WHERE clauses

### Deviations From Plan
- Added `type` field to YearFilter::Result struct (initially removed, then re-added for since/through support)
- Added `Music::RankedItemsHelper` as shared module for DRY year title/description generation
- Moved `parse_year_filter` to parent controller `Music::RankedItemsController` to eliminate duplication
- Added since/through open-ended filtering (not in original scope, added per user request)

## Acceptance Results
- Date: 2026-01-19
- Verifier: Claude
- All 3128 tests pass
- Manual testing confirmed all URL patterns work correctly

## Future Improvements
- UI controls for year selection (dropdowns, sliders)
- Genre filtering using same pattern
- Combined year + genre filtering
- OpenSearch integration for performance at scale
- Breadcrumb navigation with filter context
- Singular show routes to avoid collision with numeric album slugs (see `docs/specs/singular-show-routes.md`)

## Related PRs
- Pending

## Documentation Updated
- [x] Class docs for `Filters::YearFilter` - see `docs/lib/filters/year_filter.md`
- [x] Class docs for `Services::RankedItemsFilterService` - see `docs/lib/services/ranked_items_filter_service.md`
- [x] Class docs for `Music::RankedItemsHelper` - see `docs/helpers/music/ranked_items_helper.md`
