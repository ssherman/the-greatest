# [119] - Year Filtering for Ranked Items

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2026-01-18
- **Started**:
- **Completed**:
- **Developer**: Claude

## Overview
Implement year filtering for album and song ranked item lists with SEO-friendly URLs. Users can filter by decade (1990s), year range (1980-2000), or single year (1994). Pages display rankings sorted by rank with dynamic SEO titles and descriptions. No UI controls yet - manual URL testing only.

**Non-goals:**
- UI filters (dropdown, date picker) - future spec
- Genre filtering - future spec
- OpenSearch integration - future optimization

## Context & Links
- Related tasks: Future genre filtering, OpenSearch optimization
- Source files (authoritative):
  - `app/controllers/music/albums/ranked_items_controller.rb`
  - `app/controllers/music/songs/ranked_items_controller.rb`
  - `app/models/music/album.rb`
  - `app/models/music/song.rb`
- External docs: None required

## Interfaces & Contracts

### Domain Model (diffs only)

**Indexes to add:**
- `music_albums.release_year` - standard btree index
- `music_songs.release_year` - standard btree index

Migration file: `db/migrate/YYYYMMDDHHMMSS_add_release_year_indexes_to_music.rb`

### Endpoints
| Verb | Path | Purpose | Params | Auth |
|---|---|---|---|---|
| GET | /albums/:year | Albums filtered by year | year: decade/range/single | public |
| GET | /albums/:year/page/:page | Paginated albums by year | year, page | public |
| GET | /songs/:year | Songs filtered by year | year: decade/range/single | public |
| GET | /songs/:year/page/:page | Paginated songs by year | year, page | public |
| GET | /rc/:id/albums/:year | Albums by year with specific RC | ranking_configuration_id, year | public |
| GET | /rc/:id/songs/:year | Songs by year with specific RC | ranking_configuration_id, year | public |

> Source of truth: `config/routes.rb` - routes use constraints to validate year format.

### Schemas (JSON)

**YearFilter Result:**
```json
{
  "type": "object",
  "required": ["type", "start_year", "end_year", "display"],
  "properties": {
    "type": { "enum": ["decade", "range", "single"] },
    "start_year": { "type": "integer" },
    "end_year": { "type": "integer" },
    "display": { "type": "string" }
  },
  "additionalProperties": false
}
```

**Examples:**
- `1990s` → `{type: "decade", start_year: 1990, end_year: 1999, display: "1990s"}`
- `1980-2000` → `{type: "range", start_year: 1980, end_year: 2000, display: "1980-2000"}`
- `1994` → `{type: "single", start_year: 1994, end_year: 1994, display: "1994"}`

### Behaviors (pre/postconditions)

**Preconditions:**
- Year parameter must match regex: `/\d{4}(s|-\d{4})?/`
- Decades must be valid (1900s-2020s typically)
- Range start must be <= end
- Ranking configuration must exist (or use default)

**Postconditions/effects:**
- Results filtered by release_year within range
- Results ordered by rank (ascending)
- Results paginated (100 per page)
- Page title dynamically set based on filter
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
- [ ] `/albums/1990s` returns albums with release_year 1990-1999, ordered by rank
- [ ] `/songs/1990s` returns songs with release_year 1990-1999, ordered by rank
- [ ] `/albums/1980-2000` returns albums with release_year 1980-2000, ordered by rank
- [ ] `/albums/1994` returns albums with release_year = 1994, ordered by rank
- [ ] `/albums/1990s/page/2` returns second page of filtered results
- [ ] `/rc/:id/albums/1990s` works with specific ranking configuration
- [ ] Page title is "Greatest Albums of the 1990s | The Greatest Music" for decades
- [ ] Page title is "Greatest Albums from 1980 to 2000 | The Greatest Music" for ranges
- [ ] Page title is "Greatest Albums of 1994 | The Greatest Music" for single years
- [ ] Meta description includes year context
- [ ] Invalid year format returns 404
- [ ] Indexes exist on release_year for both tables
- [ ] All tests pass

### Golden Examples

**Decade filtering:**
```text
Input: GET /albums/1990s
Output: Albums ranked 1-100 where release_year BETWEEN 1990 AND 1999
Page Title: "Greatest Albums of the 1990s | The Greatest Music"
```

**Range filtering:**
```text
Input: GET /songs/1980-2000
Output: Songs ranked 1-100 where release_year BETWEEN 1980 AND 2000
Page Title: "Greatest Songs from 1980 to 2000 | The Greatest Music"
```

**Single year filtering:**
```text
Input: GET /albums/1994
Output: Albums ranked 1-100 where release_year = 1994
Page Title: "Greatest Albums of 1994 | The Greatest Music"
```

### Optional Reference Snippet (≤40 lines, non-authoritative)

```ruby
# reference only - YearFilter.parse interface
class Filters::YearFilter
  DECADE_PATTERN = /^(\d{4})s$/
  RANGE_PATTERN = /^(\d{4})-(\d{4})$/
  SINGLE_PATTERN = /^(\d{4})$/

  def self.parse(param)
    return nil if param.blank?

    case param
    when DECADE_PATTERN
      start_year = $1.to_i
      { type: :decade, start_year: start_year, end_year: start_year + 9, display: param }
    when RANGE_PATTERN
      start_year, end_year = $1.to_i, $2.to_i
      raise ArgumentError if start_year > end_year
      { type: :range, start_year: start_year, end_year: end_year, display: param }
    when SINGLE_PATTERN
      year = $1.to_i
      { type: :single, start_year: year, end_year: year, display: param }
    else
      raise ArgumentError, "Invalid year format: #{param}"
    end
  end
end
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
1) codebase-pattern-finder → already completed (service patterns, model scopes)
2) codebase-analyzer → already completed (controller structure, routing)
3) web-search-researcher → not needed
4) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Use existing album/song fixtures
- Ensure fixtures have varied release_year values (1980s, 1990s, 2000s, etc.)

---

## Implementation Notes (living)

### Approach
- Create `Filters::YearFilter` query object for parsing year parameters
- Create `Services::RankedItemsFilterService` for applying filters to queries
- Add model scopes: `released_in_year`, `released_in_decade`, `released_in_range`
- Add helper module for SEO title generation
- Minimal controller changes to integrate filtering
- Routes use constraints to validate year format before reaching controller

### Important Decisions
- Using path-based routing (`/albums/1990s`) for SEO vs query params
- Service class for filtering to enable future genre extension
- Scopes on models for testability and reuse

### Key Files Touched (paths only)

**New files:**
- `app/lib/filters/year_filter.rb`
- `app/lib/services/ranked_items_filter_service.rb`
- `app/helpers/music/ranked_items_helper.rb`
- `db/migrate/YYYYMMDDHHMMSS_add_release_year_indexes_to_music.rb`
- `test/lib/filters/year_filter_test.rb`
- `test/lib/services/ranked_items_filter_service_test.rb`
- `test/helpers/music/ranked_items_helper_test.rb`

**Modified files:**
- `config/routes.rb`
- `app/models/music/album.rb`
- `app/models/music/song.rb`
- `app/controllers/music/albums/ranked_items_controller.rb`
- `app/controllers/music/songs/ranked_items_controller.rb`
- `app/views/music/albums/ranked_items/index.html.erb`
- `app/views/music/songs/ranked_items/index.html.erb`

### Challenges & Resolutions
- Route priority: Year routes must come before `:id` routes to avoid conflicts with album slugs
- Filter position in JOIN query: Must filter on joined table column (music_albums.release_year)

### Deviations From Plan
- (To be filled during implementation)

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- UI controls for year selection (dropdowns, sliders)
- Genre filtering using same pattern
- Combined year + genre filtering
- OpenSearch integration for performance at scale
- Breadcrumb navigation with filter context

## Related PRs
- #...

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs for new services/filters
