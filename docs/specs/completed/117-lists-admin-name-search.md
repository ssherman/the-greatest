# [117] - Add Name Search to Song and Album Lists Admin

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-16
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude

## Overview
Add a search input to the Song Lists and Album Lists admin index pages that allows filtering lists by name or source using a case-insensitive wildcard search. Uses PostgreSQL ILIKE for the search implementation. Search works in combination with the existing status filter.

**Non-goals**:
- No full-text search or OpenSearch integration
- No search on other fields (description, url, etc.)
- No search history or autocomplete suggestions

## Context & Links
- Related tasks/phases: 116-lists-index-status-filter (adds status filtering to same pages)
- Source files (authoritative):
  - `app/controllers/admin/music/lists_controller.rb`
  - `app/views/admin/music/songs/lists/index.html.erb`
  - `app/views/admin/music/albums/lists/index.html.erb`
  - `app/components/admin/search_component.rb`
- External docs: PostgreSQL ILIKE documentation

## Interfaces & Contracts

### Domain Model (diffs only)
- No database changes required
- Add `search_by_name` scope to `List` model (pattern exists in `Category` model)

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/songs/lists | Song lists index with optional search | `q` (search query), `status` (filter) | admin |
| GET | /admin/albums/lists | Album lists index with optional search | `q` (search query), `status` (filter) | admin |
> Source of truth: `config/routes.rb` (no route changes needed).

### Schemas (JSON)
Not applicable - uses standard Rails form params.

### Behaviors (pre/postconditions)
- **Preconditions**: User must be authenticated admin
- **Postconditions/effects**:
  - Returns lists where `name ILIKE '%query%' OR source ILIKE '%query%'` (case-insensitive wildcard)
  - Results respect active status filter (search + filter work together)
  - Results maintain current sort order
  - Pagination works correctly with filtered results
- **Edge cases & failure modes**:
  - Empty query (`q` blank or whitespace): Returns all lists (respecting status filter)
  - No matches: Shows "No lists found" message
  - Special characters (`%`, `_`): Must be escaped using `sanitize_sql_like`
  - SQL injection: Prevented by parameterized query

### Non-Functionals
- **Performance**: No additional database indexes needed (lists table is small, full scan acceptable)
- **Security/roles**: Admin-only access (existing authentication)
- **Responsiveness**: Debounced search (300ms) prevents excessive requests; Turbo Frame for smooth UX

## Acceptance Criteria
- [x] Search input appears on Song Lists admin index page (`/admin/songs/lists`)
- [x] Search input appears on Album Lists admin index page (`/admin/albums/lists`)
- [x] Typing in search filters lists by name or source (case-insensitive wildcard match)
- [x] Search is debounced (300ms delay before submitting)
- [x] Search works in combination with status filter (both filters apply)
- [x] Clearing search input shows all lists (respecting status filter)
- [x] Empty search results show "No lists found matching your search" message
- [x] URL updates with search query param (`?q=...`) for bookmarkable searches
- [x] Pagination works correctly with search results
- [x] Special characters in search (`%`, `_`) are properly escaped

### Golden Examples
```text
Input: q="best" on Song Lists page
Output: Lists where name OR source contains "best" (case-insensitive): "Best Songs of 2020", source: "Best Music Magazine"

Input: q="ROLLING" with status="approved"
Output: Approved lists where name OR source contains "rolling": "Rolling Stone 500", source: "Rolling Stone Magazine"

Input: q="100%" (special character)
Output: Lists where name or source literally contains "100%", NOT wildcard matching

Input: q="" (empty/cleared)
Output: All lists (respecting current status filter)
```

### Optional Reference Snippet (<=40 lines, non-authoritative)
```ruby
# reference only - List model scope
scope :search_by_name, ->(query) {
  return all if query.blank?
  sanitized = "%" + sanitize_sql_like(query.to_s.strip) + "%"
  where("name ILIKE ? OR source ILIKE ?", sanitized, sanitized)
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Reuse existing `Admin::SearchComponent` - do not create new components.
- Follow the pattern in `Category.search_by_name` for SQL-safe wildcard search.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable patterns (Admin::SearchComponent usage, Category.search_by_name)
2) codebase-analyzer -> verify integration with existing status filter and Turbo Frame setup
3) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Use existing list fixtures or create minimal test lists with varied names
- Test cases: exact match, partial match, case variations, special characters, no matches

---

## Implementation Notes (living)
- Approach taken: Combined search and status into single form for proper interaction, added `search_by_name` scope to `List` model
- Important decisions:
  - Used `sanitize_sql_like` to properly escape special characters (`%`, `_`) preventing SQL injection
  - Search and status filter combined into single form (not separate forms) to ensure both params are always submitted together
  - Removed "Filter by Status" label for cleaner alignment
  - Sort links and pagination include `q` param to preserve search across interactions
  - Search includes both `name` and `source` fields using OR logic

### Key Files Touched (paths only)
- `app/models/list.rb` (added search_by_name scope at line 71-75)
- `app/controllers/admin/music/lists_controller.rb` (added apply_search_filter method and @search_query tracking)
- `app/views/admin/music/songs/lists/index.html.erb` (combined search input and status dropdown in single form)
- `app/views/admin/music/albums/lists/index.html.erb` (combined search input and status dropdown in single form)
- `app/views/admin/music/songs/lists/_table.html.erb` (updated sort links, pagination, empty state)
- `app/views/admin/music/albums/lists/_table.html.erb` (updated sort links, pagination, empty state)
- `test/models/list_test.rb` (added 4 tests for search_by_name scope including source search)
- `test/controllers/admin/music/songs/lists_controller_test.rb` (added 5 tests for search functionality)
- `docs/models/list.md` (updated with search_by_name scope documentation)
- `docs/controllers/admin/music/lists_controller.md` (updated with search functionality)

### Challenges & Resolutions
- **Challenge**: Search and status filter not working together (status lost when searching)
- **Resolution**: Combined both into single form instead of using separate SearchComponent and status form

### Deviations From Plan
- Did not use `Admin::SearchComponent` - instead created inline form with both search and status to ensure proper interaction
- Added source field to search (not just name) per user request

## Acceptance Results
- Date: 2026-01-16
- Verifier: Claude
- All 22 model tests pass (including 4 new search tests)
- All 87 controller tests pass (including 5 new search tests)

## Future Improvements
- Add search highlighting in results
- Consider full-text search with pg_trgm GIN indexes if list count grows significantly

## Related PRs
- #

## Documentation Updated
- [x] `docs/models/list.md` - Added search_by_name scope documentation
- [x] `docs/controllers/admin/music/lists_controller.md` - Added search functionality documentation
