# [098] - Song Wizard: Search MusicBrainz Artists Action

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-12-27
- **Started**: 2025-12-27
- **Completed**: 2025-12-27
- **Developer**: Claude Opus 4.5

## Overview

Add a new "Search MusicBrainz Artists" action to the song list wizard review step, allowing users to search and select MusicBrainz artists via autocomplete. When an artist is selected, replace the `mb_artist_ids` and `mb_artist_names` metadata fields with the selected artist. Additionally, rename the existing "Search MusicBrainz" action and its internals to "Search MusicBrainz Recordings" for clarity and consistency.

**Scope**:
1. Add new artist search action with modal and autocomplete
2. Rename existing recording search for clarity (UI label + internal names)

**Non-goals**:
- Adding multiple artists to the array (future enhancement)
- Applying to other list types besides songs (already song-specific)

## Context & Links

### Related Tasks/Phases
- `docs/specs/completed/093-song-step-4-actions.md` - Original review step actions
- `docs/specs/completed/097-song-wizard-single-modal-refactor.md` - Shared modal pattern

### Source Files (Authoritative)
- `app/controllers/admin/music/songs/list_items_actions_controller.rb` - Actions controller
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz.html.erb` - Current modal
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` - Dropdown menu
- `app/lib/music/musicbrainz/search/artist_search.rb` - MusicBrainz artist search
- `app/components/admin/music/songs/wizard/shared_modal_component.rb` - Shared modal

### External Docs
- MusicBrainz Artist Search API: https://musicbrainz.org/doc/MusicBrainz_API/Search

## Interfaces & Contracts

### Domain Model (diffs only)

No model changes required. Uses existing `metadata` JSONB column on `ListItem`:

**Affected Metadata Fields**:
- `mb_artist_ids` (Array<String>) - MusicBrainz artist MBIDs
- `mb_artist_names` (Array<String>) - Artist names from MusicBrainz

### Endpoints

**New Endpoints (Artist Search)**:

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/admin/songs/:list_id/items/:id/modal/search_musicbrainz_artists` | Load artist search modal | - | admin |
| POST | `/admin/songs/:list_id/items/:id/link_musicbrainz_artist` | Link selected artist to item | `mb_artist_id` | admin |
| GET | `/admin/songs/:list_id/wizard/musicbrainz_artist_search` | Autocomplete artist search | `q` (query string) | admin |

**Renamed Endpoints (Recording Search)**:

| Old Path | New Path | Purpose |
|---|---|---|
| `.../modal/search_musicbrainz` | `.../modal/search_musicbrainz_recordings` | Load recording search modal |
| `.../link_musicbrainz` | `.../link_musicbrainz_recording` | Link selected recording |
| `.../musicbrainz_search` | `.../musicbrainz_recording_search` | Autocomplete recording search |

> Source of truth: `config/routes.rb`

### Rename Mapping (Internal Names)

| Component | Old Name | New Name |
|---|---|---|
| Modal type constant | `search_musicbrainz` | `search_musicbrainz_recordings` |
| Modal partial | `_search_musicbrainz.html.erb` | `_search_musicbrainz_recordings.html.erb` |
| Link action | `link_musicbrainz` | `link_musicbrainz_recording` |
| Search action | `musicbrainz_search` | `musicbrainz_recording_search` |
| Route helper | `musicbrainz_search_*_path` | `musicbrainz_recording_search_*_path` |
| Route helper | `link_musicbrainz_*_path` | `link_musicbrainz_recording_*_path` |

### Schemas (JSON)

**Artist Search Response** (from `musicbrainz_artist_search` endpoint):
```json
[
  {
    "value": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
    "text": "The Beatles (Group from Liverpool, UK)"
  }
]
```

**Link Request** (to `link_musicbrainz_artist`):
```json
{
  "mb_artist_id": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
}
```

**Turbo Stream Response** (from `link_musicbrainz_artist`):
- Replace `item_row_{id}` with updated row partial
- Replace `review_stats_{list_id}` with updated stats

### Behaviors (pre/postconditions)

**Preconditions**:
- User has admin access
- List item exists and belongs to a Music::Songs::List
- For artist search: query string has minimum 2 characters

**Postconditions/Effects**:
- `mb_artist_ids` replaced with single-element array containing selected artist MBID
- `mb_artist_names` replaced with single-element array containing selected artist name
- Item row updated via Turbo Stream to reflect new artist info
- Modal closes on successful save

**Edge Cases & Failure Modes**:
- Empty search query: Return empty array
- No artists found: Display empty state in autocomplete
- MusicBrainz API timeout: Return empty array, log error
- Invalid MBID submitted: Return error message via Turbo Stream
- Artist lookup fails: Show error in modal, don't close

### Non-Functionals

**Performance**:
- Autocomplete debounce: 300ms
- MusicBrainz API timeout: 10s
- Results limit: 10 artists

**Security/Roles**:
- Admin authentication required for all endpoints

**UX**:
- Autocomplete shows artist name, type, and disambiguation (e.g., country)
- Display format: "Artist Name (Type from Location)"

## Acceptance Criteria

### New Artist Search Feature
- [x] "Search MusicBrainz Artists" action appears in item dropdown menu
- [x] Clicking action opens modal with artist autocomplete input
- [x] Typing 2+ characters triggers MusicBrainz artist search
- [x] Autocomplete shows artist name with type/location disambiguation
- [x] Selecting an artist and clicking "Link" updates item metadata
- [x] `mb_artist_ids` is replaced with `[selected_artist_mbid]`
- [x] `mb_artist_names` is replaced with `[selected_artist_name]`
- [x] Item row updates via Turbo Stream after successful link
- [x] Modal closes on successful submission
- [x] Error messages display in modal on failure

### Rename Recording Search
- [x] Dropdown shows "Search MusicBrainz Recordings" (was "Search MusicBrainz")
- [x] All internal names updated per rename mapping table
- [x] Routes updated with new path names
- [x] All existing recording search functionality works unchanged
- [x] No broken links or route errors

### Golden Examples

**Input** (artist search query):
```
q=beatles
```

**Output** (autocomplete results):
```json
[
  {"value": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", "text": "The Beatles (Group from Liverpool)"},
  {"value": "4d5bbb57-8c4c-4a7f-a3ab-8b6e6c9c8e4c", "text": "Beatles (Group from São Paulo)"}
]
```

**Input** (link artist):
```
POST /admin/songs/1/items/42/link_musicbrainz_artist
mb_artist_id: b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d
```

**Output** (metadata after):
```json
{
  "title": "Come Together",
  "artists": ["The Beatles"],
  "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names": ["The Beatles"],
  "musicbrainz_match": true
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Use existing `SharedModalComponent` for modal rendering
- Use existing `AutocompleteComponent` for artist search
- Reuse patterns from existing `search_musicbrainz` action
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → use existing modal/autocomplete patterns
2) codebase-analyzer → verify data flow & integration points
3) web-search-researcher → MusicBrainz artist search API docs if needed
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Create list_item with test metadata containing artist info

---

## Implementation Notes (living)

### Approach

**Phase 1: Rename Recording Search**
1. Rename `_search_musicbrainz.html.erb` → `_search_musicbrainz_recordings.html.erb`
2. Update `VALID_MODAL_TYPES`: `search_musicbrainz` → `search_musicbrainz_recordings`
3. Rename controller actions: `link_musicbrainz` → `link_musicbrainz_recording`, `musicbrainz_search` → `musicbrainz_recording_search`
4. Update routes with new action names
5. Update dropdown menu labels and links in `_item_row.html.erb` and `review_step_component.html.erb`
6. Update modal partial to use new route helper names
7. Run tests to verify no regressions

**Phase 2: Add Artist Search**
1. Add `search_musicbrainz_artists` to `VALID_MODAL_TYPES` constant
2. Create modal partial `_search_musicbrainz_artists.html.erb`
3. Add `musicbrainz_artist_search` action using `ArtistSearch.search_by_name`
4. Add `link_musicbrainz_artist` action to update metadata
5. Add routes for new endpoints
6. Add dropdown menu item for artist search
7. Write tests for new functionality

### Key Files Touched (paths only)

**New Files**:
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_artists.html.erb`

**Modified Files (Artist Search)**:
- `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- `config/routes.rb`
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
- `app/components/admin/music/songs/wizard/review_step_component.html.erb`

**Renamed Files (Recording Search)**:
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz.html.erb` → `_search_musicbrainz_recordings.html.erb`

**Tests**:
- `test/controllers/admin/music/songs/list_items_actions_controller_test.rb`

### Reference: Artist Search Service (non-authoritative, from codebase)

The existing `ArtistSearch` class provides:
```ruby
# app/lib/music/musicbrainz/search/artist_search.rb:32-34
def search_by_name(name, options = {})
  search_by_field("name", name, options)
end

# Returns response with data["artists"] array containing:
# - id: MBID
# - name: artist name
# - type: "Person", "Group", etc.
# - country: country code
# - disambiguation: additional context
```

### Challenges & Resolutions
- No significant challenges; existing patterns were well-established and easy to follow

### Deviations From Plan
- None; implementation followed the planned approach exactly

## Acceptance Results
- Date: 2025-12-27
- Verifier: Claude Opus 4.5
- All 37 controller tests pass (9 new tests added for artist search functionality)
- Artifacts: Test output shows 37 runs, 133 assertions, 0 failures

## Future Improvements
- Allow adding multiple artists (append to array instead of replace)
- Show current artist(s) in modal before search
- Auto-trigger recording re-search after artist change

## Related PRs
- #...

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Added Review Step Item Actions section
- [x] `docs/controllers/admin/music/songs/list_items_actions_controller.md` - Updated with new actions
