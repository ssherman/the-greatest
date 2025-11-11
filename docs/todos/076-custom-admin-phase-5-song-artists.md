# 076 - Custom Admin Interface - Phase 5: Song Artists (Join Table)

## Status
- **Status**: 🚧 IN PROGRESS
- **Priority**: High
- **Created**: 2025-11-10
- **Started**: 2025-11-10
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin interface for managing the Music::SongArtist join table, allowing users to add, edit, and remove artist associations from both song and artist show pages. This follows the exact pattern established in Phase 3 (album_artists) for join table management.

**Pattern Reference**: This implementation mirrors `docs/todos/completed/074-custom-admin-phase-3-album-artists.md` exactly, adapted for songs instead of albums.

## Context
- **Phase 3 Complete**: Album artists admin CRUD implemented (docs/todos/completed/074-custom-admin-phase-3-album-artists.md)
- **Phase 4 Complete**: Songs admin CRUD implemented (docs/todos/completed/075-custom-admin-phase-4-songs.md)
- **Second Join Table**: Music::SongArtist follows same pattern as Music::AlbumArtist
- **No Top-Level Menu**: Like album_artists, song_artists doesn't get sidebar navigation
- **Dual Context**: Manageable from both artist show page and song show page
- **Autocomplete Reuse**: Existing AutocompleteComponent and song/artist search endpoints
- **Reusable Pattern**: Established autocomplete and modal patterns from Phase 3

## Requirements

### Base Song Artist Management
- [ ] No top-level routes or index page (managed contextually only)
- [ ] Modal-based interface for add/edit/delete operations
- [ ] Context-aware pre-population (artist OR song, depending on parent page)
- [ ] Position management via modal form input
- [ ] Validation preventing duplicate artist-song pairs

### Song Show Page Integration
- [ ] "Add Artist" button opens create modal
- [ ] Create modal: song field pre-populated (disabled), artist autocomplete, position input
- [ ] Edit links open edit modal with all fields populated
- [ ] Edit modal: song field disabled, artist field disabled, position input enabled
- [ ] Delete confirmation for removing artists
- [ ] Real-time updates via Turbo Streams
- [ ] Display artists in position order with edit/delete actions

### Artist Show Page Integration
- [ ] "Add Song" button opens create modal
- [ ] Create modal: artist field pre-populated (disabled), song autocomplete, position input
- [ ] Edit links open edit modal with all fields populated
- [ ] Edit modal: artist field disabled, song field disabled, position input enabled
- [ ] Delete confirmation for removing songs
- [ ] Real-time updates via Turbo Streams
- [ ] Display songs in position order with edit/delete actions

### Reusable Components
- [ ] Reuse existing AutocompleteComponent (app/components/autocomplete_component.rb)
- [ ] Reuse existing autocomplete Stimulus controller (app/javascript/controllers/autocomplete_controller.js)
- [ ] Reuse existing modal-form Stimulus controller (app/javascript/controllers/modal_form_controller.js)
- [ ] Integrate with existing search endpoints (search_admin_songs_path, search_admin_artists_path)

## API Endpoints

| Verb | Path | Purpose | Params/Body | Auth | Context |
|------|------|---------|-------------|------|---------|
| POST | `/admin/songs/:song_id/song_artists` | Create song-artist association | `music_song_artist[artist_id, position]` | admin/editor | song show page |
| POST | `/admin/artists/:artist_id/song_artists` | Create song-artist association | `music_song_artist[song_id, position]` | admin/editor | artist show page |
| PATCH | `/admin/song_artists/:id` | Update position | `music_song_artist[position]` | admin/editor | both contexts |
| DELETE | `/admin/song_artists/:id` | Remove association | - | admin/editor | both contexts |

**Route Helpers**:
- `admin_song_song_artists_path(@song)` → POST `/admin/songs/:song_id/song_artists`
- `admin_artist_song_artists_path(@artist)` → POST `/admin/artists/:artist_id/song_artists`
- `admin_song_artist_path(@song_artist)` → PATCH/DELETE `/admin/song_artists/:id`

## Response Formats

### Success Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Artist added successfully." } })
turbo_stream.replace(turbo_frame_id, partial: partial_path,
  locals: partial_locals)
```

### Error Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { error: "Artist is already associated with this song" } })
```

### Turbo Frame IDs
- Song context: `"song_artists_list"`
- Artist context: `"artist_songs_list"`

## Behavioral Rules

### Preconditions
- User must have admin or editor role
- Song must exist (for song context)
- Artist must exist (for artist context)
- Domain must be music domain

### Postconditions (Create)
- New Music::SongArtist record created
- Position field populated (default: next available position)
- Both song and artist associations valid
- Turbo Stream updates list without page reload
- Flash message confirms success
- Modal closes automatically

### Postconditions (Update)
- Position updated to new value
- Validation passes (position > 0)
- Turbo Stream updates list showing new order
- Flash message confirms success
- Modal closes automatically

### Postconditions (Destroy)
- Music::SongArtist record deleted
- Turbo Stream removes item from list
- Flash message confirms removal
- No orphaned records (foreign keys enforce)

### Invariants
- A song-artist pair must be unique (database constraint + validation)
- Position must be integer > 0
- Both song_id and artist_id must be present
- User must have appropriate authorization

### Edge Cases
- **Empty results**: Search with no matches shows "No results" message
- **Duplicate creation**: Shows validation error, doesn't create
- **Invalid position**: Shows validation error (must be > 0)
- **Missing parent context**: 404 error (route requires parent)
- **Authorization failure**: Redirects to music_root_path

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load associations in show pages
  - Songs: `song_artists: [:artist]`
  - Artists: `song_artists: [:song]`
- **Autocomplete response time**: < 300ms p95
- **Turbo Stream response**: < 500ms p95
- **Search result limit**: 5 items max (prevents modal scrollbars)

### Security
- **Authorization**: Enforce admin/editor role via BaseController
- **CSRF Protection**: Rails handles via form helpers
- **Parameter Filtering**: Strong params whitelist
- **SQL Injection**: ActiveRecord parameterization

### Accessibility
- **Keyboard Navigation**: Tab through form fields
- **Screen Readers**: Labels on all inputs
- **Autocomplete**: WAI-ARIA compliant (autoComplete.js v10.2.9)
- **Modals**: Native `<dialog>` element

### Responsiveness
- **Mobile**: DaisyUI responsive utilities
- **Tablet**: Card layout adapts
- **Desktop**: Full-width tables

## Acceptance Criteria

### Controller Tests (Required)
- [ ] Create song_artist from song context (2 tests: success + turbo stream)
- [ ] Create song_artist from artist context (2 tests: success + turbo stream)
- [ ] Prevent duplicate song_artist creation (1 test)
- [ ] Update song_artist position (2 tests: success + validation)
- [ ] Destroy song_artist (2 tests: success + turbo stream)
- [ ] Authorization enforcement (3 tests: create, update, destroy)
- [ ] Context detection from params (2 tests: song_id, artist_id)
- [ ] Context inference from referer (4 tests: update/destroy × song/artist)

**Total Controller Tests**: ~17 tests

### Manual Acceptance Tests
- [ ] From song show page: Add artist via autocomplete, verify appears in list
- [ ] From song show page: Edit artist position, verify order changes
- [ ] From song show page: Remove artist, verify disappears from list
- [ ] From artist show page: Add song via autocomplete, verify appears in list
- [ ] From artist show page: Edit song position, verify order changes
- [ ] From artist show page: Remove song, verify disappears from list
- [ ] Verify autocomplete search works with partial strings (e.g., "depe" → "Depeche Mode")
- [ ] Verify duplicate prevention shows error message
- [ ] Verify modals close automatically after successful submission
- [ ] Verify Turbo Stream updates work without page reload
- [ ] Verify position validation (must be > 0)

## Implementation Plan

### Step 1: Generate Controller & Tests
```bash
cd web-app
bin/rails generate controller Admin::Music::SongArtists create update destroy --no-helper --no-assets
```

**Files created**:
- `app/controllers/admin/music/song_artists_controller.rb`
- `test/controllers/admin/music/song_artists_controller_test.rb`

**Reference implementation**: `app/controllers/admin/music/album_artists_controller.rb`

### Step 2: Implement Controller
**File**: `app/controllers/admin/music/song_artists_controller.rb`

**Pattern**: Context-aware controller with:
- `before_action :set_song_artist` (update/destroy)
- `before_action :set_parent_context` (create)
- `before_action :infer_context_from_song_artist` (update/destroy)
- `create`, `update`, `destroy` actions with Turbo Stream responses
- Private methods: `song_artist_params`, `redirect_path`, `turbo_frame_id`, `partial_path`, `partial_locals`

**Reference**: See `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/album_artists_controller.rb:1-168`

**Key adaptations**:
- Change `@album` → `@song`
- Change `Music::AlbumArtist` → `Music::SongArtist`
- Change `album_artist_params` → `song_artist_params`
- Change turbo frame IDs: `album_artists_list` → `song_artists_list`, `artist_albums_list` → `artist_songs_list`
- Change partial paths: `albums/artists_list` → `songs/artists_list`, `artists/albums_list` → `artists/songs_list`

### Step 3: Add Routes
**File**: `config/routes.rb`

**Pattern**: Nested resources with shallow option
```ruby
namespace :admin, module: "admin/music" do
  resources :songs do
    resources :song_artists, only: [:create], shallow: true
  end

  resources :artists do
    resources :song_artists, only: [:create], shallow: true
  end

  resources :song_artists, only: [:update, :destroy]
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb:40-66`

### Step 4: Create View Partials

#### Partial A: Artists List (Song Context)
**File**: `app/views/admin/music/songs/_artists_list.html.erb`

**Pattern**: Table with inline edit modals, wrapped in turbo_frame_tag
- Display: position badge, artist name link, edit/remove buttons
- Each row has unique edit modal
- Delete uses `button_to` with `turbo_confirm`
- Eager loading: `song.song_artists.ordered.includes(:artist)`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/_artists_list.html.erb:1-114`

#### Partial B: Songs List (Artist Context)
**File**: `app/views/admin/music/artists/_songs_list.html.erb`

**Pattern**: Table with inline edit modals, wrapped in turbo_frame_tag
- Display: position badge, song title link, duration, edit/remove buttons
- Additional column for song duration (format_duration helper)
- Each row has unique edit modal
- Delete uses `button_to` with `turbo_confirm`
- Eager loading: `artist.song_artists.ordered.includes(:song)`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/_albums_list.html.erb:1-118`

### Step 5: Integrate into Show Pages

#### Song Show Page
**File**: `app/views/admin/music/songs/show.html.erb`

**Add Artists Section** (after existing sections):
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Artists
        <div class="badge badge-primary"><%= @song.song_artists.count %></div>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="add_artist_modal.showModal()">
        + Add Artist
      </button>
    </div>
    <%= turbo_frame_tag "song_artists_list" do %>
      <%= render "artists_list", song: @song %>
    <% end %>
  </div>
</div>

<!-- Add Artist Modal -->
<dialog id="add_artist_modal" class="modal">
  <!-- Modal content with AutocompleteComponent for artist search -->
</dialog>
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/show.html.erb:109-421`

#### Artist Show Page
**File**: `app/views/admin/music/artists/show.html.erb`

**Add Songs Section** (after existing sections):
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Songs
        <div class="badge badge-primary"><%= @artist.song_artists.count %></div>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="add_song_modal.showModal()">
        + Add Song
      </button>
    </div>
    <%= turbo_frame_tag "artist_songs_list" do %>
      <%= render "songs_list", artist: @artist %>
    <% end %>
  </div>
</div>

<!-- Add Song Modal -->
<dialog id="add_song_modal" class="modal">
  <!-- Modal content with AutocompleteComponent for song search -->
</dialog>
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/artists/show.html.erb:151-418`

### Step 6: Enhance Controller Eager Loading

#### Songs Controller
**File**: `app/controllers/admin/music/songs_controller.rb`

**Update show action**:
```ruby
def show
  @song = Music::Song
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      song_artists: [:artist],  # Add this
      images: []
    )
    .find(params[:id])
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/albums_controller.rb` (show action with eager loading)

#### Artists Controller
**File**: `app/controllers/admin/music/artists_controller.rb`

**Update show action**:
```ruby
def show
  @artist = Music::Artist
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      album_artists: { album: [:primary_image] },
      song_artists: { song: [:primary_image] },  # Add this
      images: []
    )
    .find(params[:id])
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/artists_controller.rb` (show action with eager loading)

### Step 7: Write Controller Tests

**File**: `test/controllers/admin/music/song_artists_controller_test.rb`

**Test structure**:
```ruby
require "test_helper"

module Admin
  module Music
    class SongArtistsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @song = music_songs(:teen_spirit)
        @artist = music_artists(:nirvana)
        @song_artist = music_song_artists(:teen_spirit_nirvana)
        @another_artist = music_artists(:foo_fighters)

        host! Rails.application.config.domains[:music]
        sign_in_as(@admin_user, stub_auth: true)
      end

      # Create tests (song context, artist context, duplicate prevention)
      # Update tests (success, validation failure)
      # Destroy tests (success)
      # Authorization tests (create, update, destroy)
      # Context tests (params-based, referer-based)
    end
  end
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/music/album_artists_controller_test.rb:1-149`

**Required fixtures**:
- Verify `test/fixtures/music/song_artists.yml` has test data
- Verify `test/fixtures/music/songs.yml` has test songs
- Verify `test/fixtures/music/artists.yml` has test artists

### Step 8: Manual Testing

**Prerequisites**:
- OpenSearch indices up to date
- Song autocomplete working (edge n-grams)
- Artist autocomplete working (edge n-grams)

**Test scenarios**:
1. Visit song show page → Add artist → Verify appears in list
2. Edit artist position → Verify order changes
3. Remove artist → Verify disappears
4. Visit artist show page → Add song → Verify appears in list
5. Edit song position → Verify order changes
6. Remove song → Verify disappears
7. Test autocomplete partial matching
8. Test duplicate prevention
9. Test modal auto-close
10. Test Turbo Stream updates (no full reload)

## Golden Examples

### Example 1: Adding Artist to Song (Happy Path)

**Action**: User visits `/admin/songs/123/smells-like-teen-spirit`, clicks "+ Add Artist", searches "grohl", selects "Dave Grohl", position 2, submits

**Request**:
```
POST /admin/songs/123/song_artists
Params: { music_song_artist: { song_id: 123, artist_id: 456, position: 2 } }
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Artist added successfully." } })
turbo_stream.replace("song_artists_list",
  partial: "admin/music/songs/artists_list",
  locals: { song: @song })
```

**Result**:
- SongArtist record created: `song_id: 123, artist_id: 456, position: 2`
- Flash shows "Artist added successfully."
- Artists list updates to show Dave Grohl at position 2
- Modal closes automatically
- No page reload

### Example 2: Duplicate Prevention

**Action**: User tries to add same artist to song that already has that artist

**Request**:
```
POST /admin/songs/123/song_artists
Params: { music_song_artist: { song_id: 123, artist_id: 456, position: 1 } }
```

**Validation fails**: `Artist is already associated with this song`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "Artist is already associated with this song" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can correct and retry

## Agent Hand-Off

### Constraints
- Follow existing album_artists pattern exactly - do not introduce new architecture
- Reuse all existing components (AutocompleteComponent, stimulus controllers, modals)
- Keep code snippets ≤40 lines in documentation
- Link to reference files by path

### Required Outputs
- `app/controllers/admin/music/song_artists_controller.rb` (new)
- `test/controllers/admin/music/song_artists_controller_test.rb` (new)
- `app/views/admin/music/songs/_artists_list.html.erb` (new)
- `app/views/admin/music/artists/_songs_list.html.erb` (new)
- `config/routes.rb` (update - add song_artists routes)
- `app/views/admin/music/songs/show.html.erb` (update - add artists section)
- `app/views/admin/music/artists/show.html.erb` (update - add songs section)
- `app/controllers/admin/music/songs_controller.rb` (update - eager loading)
- `app/controllers/admin/music/artists_controller.rb` (update - eager loading)
- All tests passing (17+ controller tests)
- Updated sections in this spec: "Implementation Notes", "Deviations", "Acceptance Results"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Collect album_artists controller and view patterns (COMPLETED)
2. **codebase-analyzer** → Verify song_artists model structure matches requirements (COMPLETED)
3. **general-purpose** → Implement controller, routes, views, tests following patterns
4. **technical-writer** → Update this spec with implementation notes and results

### Test Fixtures Required
Verify these fixtures exist and have proper data:
- `test/fixtures/music/song_artists.yml` - At least 2 associations
- `test/fixtures/music/songs.yml` - At least 2 songs (e.g., teen_spirit, lithium)
- `test/fixtures/music/artists.yml` - At least 3 artists (e.g., nirvana, foo_fighters, pearl_jam)
- `test/fixtures/users.yml` - admin_user, regular_user

## Key Files Touched

### New Files
- `app/controllers/admin/music/song_artists_controller.rb`
- `test/controllers/admin/music/song_artists_controller_test.rb`
- `app/views/admin/music/songs/_artists_list.html.erb`
- `app/views/admin/music/artists/_songs_list.html.erb`

### Modified Files
- `config/routes.rb` (add song_artists routes)
- `app/views/admin/music/songs/show.html.erb` (add artists section)
- `app/views/admin/music/artists/show.html.erb` (add songs section)
- `app/controllers/admin/music/songs_controller.rb` (eager loading)
- `app/controllers/admin/music/artists_controller.rb` (eager loading)

### Reference Files (NOT modified, used as pattern)
- `app/controllers/admin/music/album_artists_controller.rb`
- `test/controllers/admin/music/album_artists_controller_test.rb`
- `app/views/admin/music/albums/_artists_list.html.erb`
- `app/views/admin/music/artists/_albums_list.html.erb`
- `app/views/admin/music/albums/show.html.erb`
- `app/components/autocomplete_component.rb`
- `app/components/autocomplete_component.html.erb`
- `app/javascript/controllers/autocomplete_controller.js`
- `app/javascript/controllers/modal_form_controller.js`

## Dependencies
- **Phase 3 Complete**: AlbumArtists implementation provides all patterns
- **Phase 4 Complete**: Songs admin provides song show page and search endpoint
- **Existing**: AutocompleteComponent, autocomplete Stimulus controller, modal-form Stimulus controller
- **Existing**: Artist search endpoint with edge n-grams
- **Existing**: Song search endpoint (verify edge n-grams enabled)
- **Existing Models**: Music::SongArtist, Music::Song, Music::Artist

## Success Metrics
- [ ] All 17+ controller tests passing
- [ ] Zero N+1 queries on song and artist show pages
- [ ] Autocomplete response time < 300ms
- [ ] Turbo Stream updates work without page reload
- [ ] Modal auto-close works after submission
- [ ] Duplicate validation prevents database errors
- [ ] Position validation enforced (> 0)
- [ ] Authorization prevents non-admin access

## Implementation Notes
_To be filled during implementation_

### Approach Taken
_Describe the implementation strategy and any key decisions_

### Challenges Encountered
_Document any issues and how they were resolved_

### Deviations from Plan
_Note any changes from the original spec and why_

### Testing Results
_Summary of test outcomes and coverage_

## Acceptance Results
_To be filled after manual testing_

### Manual Test Results
- [ ] Song → Add artist: ___
- [ ] Song → Edit position: ___
- [ ] Song → Remove artist: ___
- [ ] Artist → Add song: ___
- [ ] Artist → Edit position: ___
- [ ] Artist → Remove song: ___
- [ ] Autocomplete partial match: ___
- [ ] Duplicate prevention: ___
- [ ] Modal auto-close: ___
- [ ] Turbo Stream updates: ___

## Documentation Updated
- [ ] This spec file (implementation notes, deviations, results)
- [ ] `../todo.md` (move to completed when done)
- [ ] Class documentation for SongArtistsController (optional - code is self-documenting)
- [ ] Updated songs/artists controller docs if needed

## Related Tasks
- **Prerequisite**: [Phase 3 - Album Artists](completed/074-custom-admin-phase-3-album-artists.md) ✅
- **Prerequisite**: [Phase 4 - Songs](completed/075-custom-admin-phase-4-songs.md) ✅
- **Next**: Phase 6 - Credits (polymorphic join table, more complex)

## Next Steps After Completion
1. Mark this spec as COMPLETED with date
2. Move to `docs/todos/completed/`
3. Update `docs/todo.md` to mark as done
4. Create spec for Phase 6 (Credits admin)
5. Consider adding drag-and-drop position reordering in future phase
