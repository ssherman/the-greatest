# Update Autocomplete Results Limit from 10 to 20

## Status
- **Status**: Completed
- **Priority**: Low
- **Created**: 2026-01-23
- **Started**: 2026-01-23
- **Completed**: 2026-01-23
- **Developer**: Claude

## Overview
Update all autocomplete endpoints (songs, albums, artists) and MusicBrainz search endpoints to return 20 results instead of 10. This provides more options when linking list items in the wizard and improves discoverability across admin interfaces.

## Context & Links
- Related feature: `docs/features/list-wizard.md`
- Project summary: `docs/summary.md`

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required.

### Endpoints
No new endpoints. Existing endpoints affected:

| Verb | Path | Purpose | Change |
|------|------|---------|--------|
| GET | /admin/songs/search | Song autocomplete | size: 10 -> 20 |
| GET | /admin/albums/search | Album autocomplete | size: 10 -> 20 |
| GET | /admin/artists/search | Artist autocomplete | size: 10 -> 20 |
| GET | /admin/music/songs/lists/:list_id/items/:item_id/musicbrainz_recording_search | MB recording search | limit: 10 -> 20 |
| GET | /admin/music/albums/lists/:list_id/items/:item_id/musicbrainz_release_search | MB release search | limit: 10 -> 20 |
| GET | /admin/music/musicbrainz/artists | MB artist search | limit: 10 -> 20 |

### Behaviors (pre/postconditions)
- **Preconditions**: User must be authenticated admin
- **Postconditions**: Autocomplete dropdowns display up to 20 results instead of 10
- **Edge cases**:
  - If fewer than 20 matches exist, return all matches
  - Empty query returns empty array (unchanged)
  - Query < min_length returns empty array (unchanged)

### Non-Functionals
- **Performance**: OpenSearch queries are already optimized; increasing from 10 to 20 has negligible latency impact
- **Security/roles**: Admin only (unchanged)
- **UX**: Dropdown already has `max-h-80 overflow-y-auto` CSS, accommodates 20+ items

## Acceptance Criteria
- [x] Song autocomplete returns up to 20 results
- [x] Album autocomplete returns up to 20 results
- [x] Artist autocomplete returns up to 20 results
- [x] MusicBrainz recording search returns up to 20 results
- [x] MusicBrainz release search returns up to 20 results
- [x] MusicBrainz artist search returns up to 20 results
- [x] Frontend `maxResults` updated to 20
- [x] Existing tests updated to expect 20 results where applicable

### Golden Examples
```text
Input: User types "teen" in song autocomplete with 50+ matches
Output: JSON array with 20 items (was 10)

Input: User types "love" in album autocomplete with 100+ matches
Output: JSON array with 20 items (was 10)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) This is a straightforward change - no sub-agents needed
2) Update hardcoded values in 6 backend files
3) Update frontend JS controller
4) Update tests if they assert on result count

### Test Seed / Fixtures
- Existing test fixtures sufficient; no new fixtures needed.

---

## Implementation Notes (living)
- Approach taken: Simple search-and-replace of hardcoded `10` values with `20` in all relevant files
- Important decisions: Also updated MusicBrainz artist search endpoint which was discovered during implementation

### Key Files Touched (paths only)
**Backend (OpenSearch autocomplete default values):**
- `app/lib/search/music/search/song_autocomplete.rb` (line 15)
- `app/lib/search/music/search/album_autocomplete.rb` (line 15)
- `app/lib/search/music/search/artist_autocomplete.rb` (line 15)

**Backend (Controller hardcoded values):**
- `app/controllers/admin/music/songs_controller.rb` (line 102)
- `app/controllers/admin/music/albums_controller.rb` (line 103)
- `app/controllers/admin/music/artists_controller.rb` (line 133)

**Backend (MusicBrainz search endpoints):**
- `app/controllers/admin/music/songs/list_items_actions_controller.rb` (line 150)
- `app/controllers/admin/music/albums/list_items_actions_controller.rb` (line 180)
- `app/controllers/admin/music/musicbrainz_search_controller.rb` (line 12)

**Frontend:**
- `app/javascript/controllers/autocomplete_controller.js` (line 80)

**Tests updated:**
- `test/controllers/admin/music/artists_controller_test.rb` (line 328)
- `test/controllers/admin/music/albums_controller_test.rb` (line 274)
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb` (line 386)
- `test/controllers/admin/music/albums/list_items_actions_controller_test.rb` (line 292)
- `test/controllers/admin/music/musicbrainz_search_controller_test.rb` (line 69)

### Challenges & Resolutions
- None; straightforward value change as expected

### Deviations From Plan
- Added `musicbrainz_search_controller.rb` which was not in the initial spec but was discovered during implementation

## Acceptance Results
- Date: 2026-01-23
- Verifier: All relevant tests pass (181 runs, 524 assertions, 0 failures)

## Future Improvements
- Consider making the limit configurable via Stimulus values so different autocomplete instances could have different limits if needed

## Related PRs
-

## Documentation Updated
- [x] `documentation.md` - N/A (no changes to documentation guide needed)
- [x] Class docs - Updated default size in:
  - `docs/lib/search/music/search/artist_autocomplete.md`
  - `docs/lib/search/music/search/album_autocomplete.md`
  - `docs/lib/search/music/search/song_autocomplete.md`
