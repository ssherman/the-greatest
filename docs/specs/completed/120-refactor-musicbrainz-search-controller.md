# 120 - Refactor MusicBrainz Search into Dedicated Controller

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-16
- **Started**: 2026-01-16
- **Completed**: 2026-01-16
- **Developer**: Claude

## Overview
Extract MusicBrainz search endpoints from `ListItemsActions` concern into a dedicated `Admin::Music::MusicbrainzSearchController`. This consolidates MusicBrainz API search functionality in one place and enables reuse across multiple admin features (list wizard, artist import, future features).

**Scope**:
- Extract `musicbrainz_artist_search` into new controller
- Update wizard controllers and views to use new endpoint
- Prepare for future addition of recording/release searches

**Non-goals**:
- Moving `musicbrainz_recording_search` and `musicbrainz_release_search` (these require item context and are more specialized)
- Changing MusicBrainz API integration logic

## Context & Links
- Enables: Spec 119 (Admin Import Artist from MusicBrainz)
- Related: List Wizard (`docs/features/list-wizard.md`)
- Current location: `app/controllers/concerns/list_items_actions.rb:96-114`

### Source Files (authoritative)
- `app/controllers/concerns/list_items_actions.rb`
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_artists.html.erb`
- `app/views/admin/music/albums/list_items_actions/modals/_search_musicbrainz_artists.html.erb`
- `config/routes.rb`

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params | Auth |
|------|------|---------|--------|------|
| GET | `/admin/music/musicbrainz/artists` | Artist autocomplete search | `q` (query, min 2 chars) | admin |

> Future endpoints (not in scope):
> - GET `/admin/music/musicbrainz/recordings` - Recording search
> - GET `/admin/music/musicbrainz/releases` - Release group search

### Schemas (JSON)

**GET /admin/music/musicbrainz/artists Response:**
```json
[
  {
    "value": "83d91898-7763-47d7-b03b-b92132375c47",
    "text": "Pink Floyd (Group from United Kingdom)"
  }
]
```

### Behaviors

**Preconditions:**
- User is authenticated admin
- Query parameter `q` is at least 2 characters

**Postconditions:**
- Returns JSON array of matching artists from MusicBrainz API
- Empty array if query too short, API fails, or no results

**Edge cases:**
- Query < 2 chars: Return `[]`
- MusicBrainz API timeout/error: Return `[]` (graceful degradation)
- No results: Return `[]`

### Non-Functionals
- Response time dependent on MusicBrainz API (typically < 2s)
- No database queries required

## Acceptance Criteria

- [x] New controller `Admin::Music::MusicbrainzSearchController` exists at `app/controllers/admin/music/musicbrainz_search_controller.rb`
- [x] Route `/admin/music/musicbrainz/artists` works and returns JSON
- [x] `musicbrainz_artist_search` method removed from `ListItemsActions` concern
- [x] Songs wizard modal updated to use new endpoint path
- [x] Albums wizard modal updated to use new endpoint path
- [x] All existing wizard functionality works unchanged
- [x] Tests pass for new controller (14 tests, 28 assertions)

### Golden Example

```text
GET /admin/music/musicbrainz/artists?q=pink+floyd

Response:
[
  {"value": "83d91898-7763-47d7-b03b-b92132375c47", "text": "Pink Floyd (Group from United Kingdom)"},
  {"value": "...", "text": "Pink Floyd Experience (Group from ...)"}
]
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines)
- Do not duplicate authoritative code; **link to file paths**
- Keep `format_artist_display` helper logic (move it to new controller)

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → Verify controller patterns in admin/music namespace
2) codebase-analyzer → Find all references to `musicbrainz_artist_search` path helpers
3) technical-writer → Update docs if needed

### Test Seed / Fixtures
- Mock MusicBrainz API responses in controller tests

---

## Implementation Notes (living)

### Approach

**1. Create New Controller**

Create `app/controllers/admin/music/musicbrainz_search_controller.rb`:
```ruby
# reference only
class Admin::Music::MusicbrainzSearchController < Admin::Music::BaseController
  def artists
    query = params[:q]
    return render json: [] if query.blank? || query.length < 2

    search = Music::Musicbrainz::Search::ArtistSearch.new
    response = search.search_by_name(query, limit: 10)

    return render json: [] unless response[:success]

    artists = response[:data]["artists"] || []
    render json: artists.map { |artist|
      { value: artist["id"], text: format_artist_display(artist) }
    }
  end

  private

  def format_artist_display(artist)
    # Move helper from ListItemsActions
  end
end
```

**2. Add Routes**

Add to `config/routes.rb` inside `namespace :admin, module: "admin/music" do`:
```ruby
# Use scope (not namespace) to avoid creating Admin::Music::Musicbrainz module
scope :musicbrainz, controller: "musicbrainz_search", as: "musicbrainz" do
  get :artists
  # Future: get :recordings
  # Future: get :releases
end
```

This creates: `admin_musicbrainz_artists_path` → `/admin/musicbrainz/artists`

**3. Update Views**

Update autocomplete URLs in wizard modals:
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_artists.html.erb`
- `app/views/admin/music/albums/list_items_actions/modals/_search_musicbrainz_artists.html.erb`

Change from:
```erb
url: musicbrainz_artist_search_admin_songs_list_wizard_path(list_id: list.id)
```
To:
```erb
url: admin_musicbrainz_artists_path
```

**4. Clean Up Concern**

Remove from `app/controllers/concerns/list_items_actions.rb`:
- `musicbrainz_artist_search` method (lines 96-114)
- `format_artist_display` helper (lines 165-184)

**5. Update Route Files**

Remove `musicbrainz_artist_search` route from wizard routes if defined there.

### Key Files Touched (paths only)
- `app/controllers/admin/music/musicbrainz_search_controller.rb` (new)
- `app/controllers/concerns/list_items_actions.rb`
- `config/routes.rb`
- `app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_artists.html.erb`
- `app/views/admin/music/albums/list_items_actions/modals/_search_musicbrainz_artists.html.erb`
- `test/controllers/admin/music/musicbrainz_search_controller_test.rb` (new)

### Challenges & Resolutions
- Need to find all route references to the old endpoint - use grep for `musicbrainz_artist_search`

### Deviations From Plan
- Used `scope` instead of `namespace` in routes to avoid creating `Admin::Music::Musicbrainz` module
- Route helper is `admin_musicbrainz_artists_path` (not `admin_music_musicbrainz_artists_path`)
- Also removed the old `musicbrainz_artist_search` routes from wizard routes

## Acceptance Results
- Date: 2026-01-16
- Verifier: Claude
- All 79 related tests pass (14 new + 65 existing wizard tests)

## Future Improvements
- Move `musicbrainz_recording_search` to this controller (needs artist_mbid param)
- Move `musicbrainz_release_search` to this controller (needs artist_mbid param)
- Add caching layer for frequent searches

## Related PRs
-

## Documentation Updated
- [x] Controller docs: `docs/controllers/admin/music/musicbrainz_search_controller.md`
