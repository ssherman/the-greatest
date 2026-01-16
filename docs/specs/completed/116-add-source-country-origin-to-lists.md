# [116] - Add source_country_origin Field to Lists

## Status
- **Status**: Completed
- **Priority**: Low
- **Created**: 2026-01-16
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude

## Overview
Add a new `source_country_origin` text field to the List model to track the country where the source publication is based (e.g., USA, Germany, UK). The field is optional, has no validation, and is admin-only.

## Context & Links
- Related tasks/phases: None
- Source files (authoritative): `app/models/list.rb`, `app/controllers/admin/music/lists_controller.rb`
- External docs: None

## Interfaces & Contracts

### Domain Model (diffs only)
- Added `source_country_origin :string` column to `lists` table
- Migration: `db/migrate/20260116060845_add_source_country_origin_to_lists.rb`

### Endpoints
No new endpoints. Existing endpoints modified:
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST/PATCH | /admin/albums/lists | Create/update album list | +source_country_origin | admin |
| POST/PATCH | /admin/songs/lists | Create/update song list | +source_country_origin | admin |

### Schemas (JSON)
```json
{
  "source_country_origin": {
    "type": "string",
    "description": "Country where the source publication is based",
    "examples": ["USA", "Germany", "UK"],
    "nullable": true
  }
}
```

### Behaviors (pre/postconditions)
- Preconditions: None
- Postconditions: Field is persisted to database
- Edge cases: Blank values allowed, no validation

### Non-Functionals
- No performance impact (simple string column)
- Admin-only access (not exposed in public list submission forms)

## Acceptance Criteria
- [x] Migration adds `source_country_origin` string column to `lists` table
- [x] Admin controller permits `source_country_origin` in strong params
- [x] Album list form displays field in Source Information section
- [x] Song list form displays field in Source Information section
- [x] Album list index table shows country in parentheses after source (e.g., "Rolling Stone (USA)")
- [x] Song list index table shows country in parentheses after source
- [x] Album list show page displays country in parentheses after source
- [x] Song list show page displays country in parentheses after source
- [x] Country parentheses only shown when source_country_origin is present
- [x] Existing tests pass

### Golden Examples
```text
Input: Create album list with source_country_origin: "USA"
Output: List saved with source_country_origin = "USA"

Input: Create album list without source_country_origin
Output: List saved with source_country_origin = nil
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
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → Found `musicbrainz_series_id` as pattern to follow
2) codebase-analyzer → Verified form structure and strong params location

### Test Seed / Fixtures
- None required (no new fixtures needed)

---

## Implementation Notes (living)
- Approach taken: Standard Rails pattern - migration, strong params, form field
- Important decisions: Placed field after `source` in forms for semantic grouping

### Key Files Touched (paths only)
- `db/migrate/20260116060845_add_source_country_origin_to_lists.rb`
- `app/controllers/admin/music/lists_controller.rb`
- `app/views/admin/music/albums/lists/_form.html.erb`
- `app/views/admin/music/songs/lists/_form.html.erb`
- `app/views/admin/music/albums/lists/_table.html.erb`
- `app/views/admin/music/songs/lists/_table.html.erb`
- `app/views/admin/music/albums/lists/show.html.erb`
- `app/views/admin/music/songs/lists/show.html.erb`

### Challenges & Resolutions
- None

### Deviations From Plan
- None

## Acceptance Results
- Date: 2026-01-16
- Verifier: Claude
- Artifacts: Migration ran successfully, model test passes, field accessible on model

## Future Improvements
- Could add autocomplete with common country values
- Could normalize to ISO country codes if needed

## Related PRs
- (pending)

## Documentation Updated
- [x] Spec file created
- [x] Schema annotation auto-updated by migration
