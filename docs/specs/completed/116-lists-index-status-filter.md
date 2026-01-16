# 116 - Lists Index Status Filter and Column Consolidation

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-16
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude

## Overview
Add status filtering to both Song Lists and Album Lists admin index pages, and consolidate the Name and Source columns into a single column where the source appears after the name as a clickable link (opens in new window) when a URL is present.

**Scope**:
- Add dropdown filter for status (All, Unapproved, Approved, Rejected, Active)
- Combine Name + Source columns into single "Name" column
- Source displayed after name with link to URL if present

**Non-goals**:
- No changes to Avo resources
- No changes to other admin pages beyond song/album lists

## Context & Links
- Related tasks/phases: Custom admin interface development
- Pattern reference: `web-app/app/controllers/admin/penalties_controller.rb` (status filter implementation)
- View pattern reference: `web-app/app/views/admin/penalties/index.html.erb` (filter dropdown UI)

## Interfaces & Contracts

### Domain Model (no changes)
No database migrations required. Uses existing `List` model with:
- `status` enum: `{unapproved: 0, approved: 1, rejected: 2, active: 3}`
- `name` (string)
- `source` (string, optional)
- `url` (string, optional)

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/music/songs/lists | List song lists with optional status filter | `status` (optional: all/unapproved/approved/rejected/active), `sort`, `direction` | admin |
| GET | /admin/music/albums/lists | List album lists with optional status filter | `status` (optional: all/unapproved/approved/rejected/active), `sort`, `direction` | admin |

### Behaviors (pre/postconditions)
- **Preconditions**: User must be authenticated admin
- **Postconditions**:
  - When `status` param is blank or "all", show all lists
  - When `status` is valid enum value, filter to that status only
  - Invalid status values treated as "all" (graceful degradation)
  - Filter preserved in pagination links
  - Sort params preserved when filtering

### Non-Functionals
- No N+1 queries (maintain existing eager loading)
- Filter applies server-side before pagination
- URL updates with filter param for bookmarkable/shareable links

## Acceptance Criteria
- [ ] Song Lists index page has dropdown filter above table with options: All Statuses, Unapproved, Approved, Rejected, Active
- [ ] Album Lists index page has dropdown filter above table with same options
- [ ] Selecting a filter value immediately filters the table (via Turbo Frame)
- [ ] URL updates with `?status=value` parameter when filter changes
- [ ] Default filter is "All Statuses" (shows all lists)
- [ ] Pagination preserves current filter selection
- [ ] Sorting preserves current filter selection
- [ ] Name column now includes source info:
  - Format: "List Name" followed by source on next line or inline
  - Source is a link (opens new window) if URL is present
  - Source displays `source` field, or falls back to URL domain if source is blank
  - Country origin appended in parentheses if present
- [ ] Source column removed from table
- [ ] Table maintains existing styling (DaisyUI table-zebra, badges, etc.)

### Golden Examples

**Example 1: Name + Source Display (with URL)**
```
Input: list.name = "Rolling Stone's Greatest Albums"
       list.source = "Rolling Stone"
       list.url = "https://www.rollingstone.com/music/lists/..."
       list.source_country_origin = "US"

Output in Name column:
  Rolling Stone's Greatest Albums
  Rolling Stone (US)  <-- this line is a link to the URL, opens in new window
```

**Example 2: Name + Source Display (no URL)**
```
Input: list.name = "NME Best Songs"
       list.source = "NME Magazine"
       list.url = nil
       list.source_country_origin = "UK"

Output in Name column:
  NME Best Songs
  NME Magazine (UK)  <-- plain text, no link
```

**Example 3: Filter by Status**
```
GET /admin/music/songs/lists?status=approved

Response: Only lists with status == "approved" are displayed
          Filter dropdown shows "Approved" selected
          Pagination links include ?status=approved
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Use same filter pattern as `Admin::PenaltiesController`
- Use DaisyUI select/form components consistent with penalties page
- Respect snippet budget (<=40 lines)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests for the Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable filter patterns (already done: penalties_controller)
2) codebase-analyzer -> verify data flow & integration points
3) UI Engineer -> implement view changes following DaisyUI patterns
4) technical-writer -> update docs if needed

### Test Seed / Fixtures
- Existing list fixtures should suffice
- Ensure fixtures include lists with various statuses

---

## Implementation Notes (living)
- Approach taken: Followed the existing filter pattern from `Admin::PenaltiesController` with `apply_status_filter` method
- Important decisions:
  - Filter defaults to "all" when no status param provided
  - Invalid status values gracefully fall back to showing all lists
  - Status filter preserved across pagination and sorting via URL params

### Key Files Touched (paths only)
- `web-app/app/controllers/admin/music/lists_controller.rb` - added `apply_status_filter` method and `@selected_status` assignment
- `web-app/app/views/admin/music/songs/lists/index.html.erb` - added filter dropdown form
- `web-app/app/views/admin/music/songs/lists/_table.html.erb` - combined name/source columns, removed Source column, updated sort links and pagination to preserve status param
- `web-app/app/views/admin/music/albums/lists/index.html.erb` - added filter dropdown form
- `web-app/app/views/admin/music/albums/lists/_table.html.erb` - combined name/source columns, removed Source column, updated sort links and pagination to preserve status param
- `web-app/test/controllers/admin/music/songs/lists_controller_test.rb` - added 8 status filter tests
- `web-app/test/controllers/admin/music/albums/lists_controller_test.rb` - added 8 status filter tests

### Challenges & Resolutions
- None encountered

### Deviations From Plan
- None

## Acceptance Results
- Date: 2026-01-16
- Verifier: Claude
- All 82 controller tests pass (including 16 new status filter tests)

## Future Improvements
- Consider adding additional filters (year range, quality rating, etc.)
- Consider adding text search for list names

## Related PRs
- #...

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
