# 114 - Song & Album List Pagination

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-13
- **Started**: 2026-01-13
- **Completed**: 2026-01-13
- **Developer**: AI Agent

## Overview
Add pagination (100 items per page) to individual song list and album list show pages. Currently these pages render all items at once, which causes performance and usability issues when lists have hundreds or thousands of items.

**Goal**: Break large lists into paginated pages of 100 items each with smooth Turbo Frame navigation.

**Non-goals**:
- Changing the list index pages (already paginated)
- Adding infinite scroll
- Changing the ranked items pages (already paginated at 100)

## Context & Links
- Related tasks/phases: N/A (standalone feature)
- Source files (authoritative):
  - `app/controllers/music/songs/lists_controller.rb`
  - `app/controllers/music/albums/lists_controller.rb`
  - `app/views/music/songs/lists/show.html.erb`
  - `app/views/music/albums/lists/show.html.erb`
- External docs:
  - [Pagy Documentation](https://ddnexus.github.io/pagy/)
  - [Turbo Frames Documentation](https://turbo.hotwired.dev/handbook/frames)

## Interfaces & Contracts

### Domain Model (diffs only)
- No schema changes required
- No migrations needed

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /songs/lists/:id | Show song list with paginated items | `page` (optional, default 1) | public |
| GET | /albums/lists/:id | Show album list with paginated items | `page` (optional, default 1) | public |

> Source of truth: `config/routes.rb` (no changes needed - Pagy adds `page` param automatically)

### Behaviors (pre/postconditions)

**Preconditions:**
- List must exist (404 if not found)
- `page` param must be positive integer (Pagy handles validation)

**Postconditions/effects:**
- Returns paginated list items (100 per page)
- Total count displayed in header reflects ALL items, not just current page
- Pagination controls shown at top AND bottom of list (only if >1 page)
- Position/rank numbers remain accurate regardless of page

**Edge cases & failure modes:**
- List with 0 items: Show empty state (existing behavior preserved)
- List with <100 items: No pagination controls shown
- List with exactly 100 items: No pagination controls shown
- Page beyond last page: Pagy redirects to last page (configured via `overflow: :last_page`)
- Invalid page param (negative, string): Pagy handles gracefully

### Non-Functionals
- **Performance budgets**:
  - Only load 100 list_items per request (with eager loading)
  - No N+1 queries - associations must be eager loaded
  - Page load < 500ms for 100 items
- **Security/roles**: Public pages, no auth changes
- **Responsiveness/UX**:
  - Turbo Frames for instant page transitions (no full reload)
  - Scroll position maintained within frame

## Acceptance Criteria
- [x] Song list show page paginates at 100 items per page
- [x] Album list show page paginates at 100 items per page
- [x] Total count in header shows full count (e.g., "500 songs")
- [x] Pagination controls appear at top AND bottom when >1 page
- [x] Pagination controls hidden when <=100 items
- [x] Clicking page links uses Turbo Frames (no full page reload)
- [x] Item positions (ranks) display correctly across all pages
- [x] No N+1 queries (verify via logs or rack-mini-profiler)
- [x] Empty lists still show appropriate empty state

### Golden Examples

**Example 1: Song list with 150 items**
```text
Input: GET /songs/lists/123 (list has 150 songs)
Output:
- Header shows "150 songs"
- Page 1 displays songs ranked #1-100
- Pagination shows "1 2" with page 1 active
- Controls appear at top and bottom

Input: GET /songs/lists/123?page=2
Output:
- Header still shows "150 songs"
- Page 2 displays songs ranked #101-150
- Pagination shows "1 2" with page 2 active
```

**Example 2: Album list with 50 items**
```text
Input: GET /albums/lists/456 (list has 50 albums)
Output:
- Header shows "50 albums"
- All 50 albums displayed
- No pagination controls (<=100 items)
```

### Optional Reference Snippet (controller pattern)
```ruby
# reference only - show action pattern
def show
  @list = Music::Songs::List.find(params[:id])
  @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)

  # Paginate list items with eager loading
  list_items_query = @list.list_items
    .includes(listable: :artists)
    .order(:position)
  @pagy, @pagy_list_items = pagy(list_items_query, limit: 100)
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Use existing Pagy configuration (pagy_bootstrap_nav helper)
- Maintain existing eager loading patterns for performance

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Manual verification of Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> Already completed - found existing pagination patterns
2) codebase-analyzer -> Already completed - understood list/controller structure
3) web-search-researcher -> Not needed - using existing Pagy setup
4) technical-writer -> Update this spec on completion

### Test Seed / Fixtures
- No fixtures needed - use existing list data
- For testing, find lists with >100 items in development/staging

---

## Implementation Notes (living)
- Approach taken: Paginate `list_items` directly in controller using Pagy, wrap list content in Turbo Frame for instant navigation
- Important decisions:
  - Used `@pagy.count` instead of `@list.list_items.size` to avoid extra COUNT query (Pagy caches the count)
  - Kept eager loading inline in controllers rather than extracting to model scopes (simple, explicit)
  - Page overflow handling already configured globally in Pagy initializer (`overflow: :last_page`)

### Key Files Touched (paths only)
- `app/controllers/music/songs/lists_controller.rb`
- `app/controllers/music/albums/lists_controller.rb`
- `app/views/music/songs/lists/show.html.erb`
- `app/views/music/albums/lists/show.html.erb`
- `test/controllers/music/songs/lists_controller_test.rb`
- `test/controllers/music/albums/lists_controller_test.rb`

### Challenges & Resolutions
- **N+1 Query Issue**: Initial implementation used `@list.list_items.size` which triggered a separate COUNT query. Resolved by using `@pagy.count` which reuses the count from pagination.

### Deviations From Plan
- None - implementation followed the planned approach

## Acceptance Results
- Date: 2026-01-13
- Verification: Code review completed by automated agents; all 24 controller tests passing (including 4 new pagination tests)
- Artifacts: See code changes in files listed above

## Future Improvements
- Add "items per page" selector (25/50/100)
- Add keyboard navigation between pages
- Consider counter cache on lists for faster total count

## Related PRs
- (to be filled on completion)

## Documentation Updated
- [x] `documentation.md` - N/A (no new classes created, spec serves as feature documentation)
- [x] Class docs - N/A (modifies existing controllers, no new classes)
