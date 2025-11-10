# 075 - Custom Admin Interface - Phase 4: Music Songs

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-09
- **Started**: [TBD]
- **Completed**: [TBD]
- **Developer**: [TBD]

## Overview
Implement custom admin CRUD interface for Music::Song following the patterns established in Phases 1-3 (Artists, Albums, Album Artists). Replace Avo song resource and actions with custom Rails admin built on ViewComponents + Hotwire (Turbo + Stimulus).

## Context
- **Phase 1 Complete**: Artists admin CRUD implemented (docs/todos/072-custom-admin-phase-1-artists.md)
- **Phase 2 Complete**: Albums admin CRUD implemented (docs/todos/073-custom-admin-phase-2-albums.md)
- **Phase 3 Complete**: Album Artists join table implemented (docs/todos/074-custom-admin-phase-3-album-artists.md)
- **Complex Associations**: Songs have many associations (artists, tracks, releases, albums, categories, identifiers, external links, lists, rankings)
- **Autocomplete Ready**: Reusable component exists from Phase 3
- **Search Ready**: `SongAutocomplete` OpenSearch class already exists
- **Deferred Features**: Credits and song relationships not currently populated, will be added in future phase

## Requirements

### Base Song CRUD
- [ ] Route namespace for `/admin/songs` path (inside domain constraint)
- [ ] Admin::Music::SongsController with full CRUD
- [ ] Base song views following artist/album patterns

### Song Index Page
- [ ] Display columns: ID, Title, Artists (comma-separated), Duration, Release Year, Categories, Created at
- [ ] Search/filter by title and artist names (OpenSearch)
- [ ] Pagination (Pagy, 25 items per page)
- [ ] Bulk selection UI
- [ ] Sort by columns (title, release_year, duration_secs, created_at)
- [ ] Song count badge

### Song Show Page
- [ ] All song fields displayed:
  - Title, slug, description, notes
  - Duration (formatted as MM:SS)
  - Release year, ISRC
- [ ] Associations displayed:
  - **Artists Section** (via song_artists join table with position)
  - **Tracks Section** (appearances on releases, grouped by release/album)
  - **Categories Section** (genres/styles)
  - **Identifiers Section** (MusicBrainz recording/work IDs, ISRC)
  - **External Links Section** (streaming, purchase, Wikipedia, etc.)
  - **List Items Section** (which lists contain this song)
  - **Ranked Items Section** (ranking positions)
  - Note: Credits and Song Relationships deferred until data is populated
- [ ] Action buttons (Merge Song)

### Song New/Create
- [ ] Form with all editable fields:
  - Title (required)
  - Description (textarea)
  - Notes (textarea)
  - Duration in seconds (number)
  - Release Year (number)
  - ISRC (text, 12 chars)
- [ ] Validation error display
- [ ] Note: Artists association handled separately (via song_artists controller, Phase 3 pattern)

### Song Edit/Update
- [ ] Same form as New
- [ ] Pre-populated values
- [ ] Slug displayed but not editable (auto-generated from title)

### Song Destroy
- [ ] Confirmation dialog (Turbo Frame)
- [ ] Warning about dependent records (tracks, list items, rankings)
- [ ] Cascade delete all associations

### Admin Actions System
- [ ] One song action to replicate from Avo:
  1. **Merge Song** (single record action with validation)

### Artist Show Page Enhancement
- [ ] Add "Songs" section to artist show page
- [ ] Display songs with links to song admin pages
- [ ] Show song count badge
- [ ] Include position if via song_artists join

### Album Show Page Enhancement
- [ ] Add "Songs" section to album show page (via releases > tracks)
- [ ] Display songs grouped by release/disc
- [ ] Show track numbers and positions
- [ ] Link to song admin pages

## Technical Approach

### 1. Routing & Controllers

```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  namespace :admin, module: "admin/music" do
    root to: "dashboard#index"

    resources :artists do
      # ... existing routes ...
      resources :song_artists, only: [:create, :update, :destroy], shallow: true
    end

    resources :albums do
      # ... existing routes ...
    end

    resources :songs do
      member do
        post :execute_action  # For single-record actions
      end
      collection do
        post :bulk_action     # For bulk actions
        get :search           # For autocomplete
      end
    end
  end
end
```

**Generated paths:**
- `admin_songs_path` → `/admin/songs`
- `admin_song_path(@song)` → `/admin/songs/:id`
- `execute_action_admin_song_path(@song)` → `/admin/songs/:id/execute_action`
- `bulk_action_admin_songs_path` → `/admin/songs/bulk_action`
- `search_admin_songs_path` → `/admin/songs/search`

### 2. Controller Architecture

```ruby
# app/controllers/admin/music/songs_controller.rb
class Admin::Music::SongsController < Admin::Music::BaseController
  before_action :set_song, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    load_songs_for_index
  end

  def show
    # Eager load all associations to prevent N+1 queries
    @song = Music::Song
      .includes(
        :categories,
        :identifiers,
        :external_links,
        song_artists: [:artist],
        tracks: { release: [:album, :primary_image] },
        list_items: [:list],
        ranked_items: [:ranking_configuration]
      )
      .find(params[:id])
  end

  def new
    @song = Music::Song.new
  end

  def create
    @song = Music::Song.new(song_params)

    if @song.save
      redirect_to admin_song_path(@song), notice: "Song created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    # @song loaded by before_action
  end

  def update
    if @song.update(song_params)
      redirect_to admin_song_path(@song), notice: "Song updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @song.destroy!
    redirect_to admin_songs_path, notice: "Song deleted successfully."
  end

  def execute_action
    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [@song])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: { result: result }
        )
      end
      format.html { redirect_to admin_song_path(@song), notice: result.message }
    end
  end

  def bulk_action
    song_ids = params[:song_ids] || []
    songs = Music::Song.where(id: song_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: songs)

    load_songs_for_index

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: { result: result }),
          turbo_stream.replace("songs_table", partial: "admin/music/songs/table", locals: { songs: @songs, pagy: @pagy })
        ]
      end
      format.html { redirect_to admin_songs_path, notice: result.message }
    end
  end

  def search
    # Use existing OpenSearch implementation
    search_results = ::Search::Music::Search::SongAutocomplete.call(params[:q], size: 10)
    song_ids = search_results.map { |r| r[:id].to_i }

    # Handle empty results to prevent ArgumentError
    if song_ids.empty?
      render json: []
      return
    end

    # Load song records preserving search order
    songs = Music::Song
      .includes(:artists)
      .in_order_of(:id, song_ids)

    render json: songs.map { |s|
      {
        value: s.id,
        text: "#{s.title} - #{s.artists.map(&:name).join(", ")}"
      }
    }
  end

  private

  def set_song
    @song = Music::Song.find(params[:id])
  end

  def load_songs_for_index
    if params[:q].present?
      # Use OpenSearch for search
      search_results = ::Search::Music::Search::SongAutocomplete.call(params[:q], size: 1000)
      song_ids = search_results.map { |r| r[:id].to_i }

      # Handle empty results
      if song_ids.empty?
        @songs = Music::Song.none
      else
        # Preserve search order using Rails 7+ in_order_of
        @songs = Music::Song
          .includes(:categories, song_artists: [:artist])
          .in_order_of(:id, song_ids)
      end

      @pagy, @songs = pagy(@songs, items: 25)
    else
      # Normal database query for browsing
      @songs = Music::Song.all
        .includes(:categories, song_artists: [:artist])

      # Apply sorting
      sort_column = sortable_column(params[:sort])
      @songs = @songs.order(sort_column)

      @pagy, @songs = pagy(@songs, items: 25)
    end
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "music_songs.id",
      "title" => "music_songs.title",
      "release_year" => "music_songs.release_year",
      "duration_secs" => "music_songs.duration_secs",
      "created_at" => "music_songs.created_at"
    }

    allowed_columns.fetch(column.to_s, "music_songs.title")
  end

  def song_params
    params.require(:music_song).permit(
      :title,
      :description,
      :notes,
      :duration_secs,
      :release_year,
      :isrc
    )
  end
end
```

**Key aspects:**
- Deep eager loading for show page (prevents N+1 with many associations)
- OpenSearch integration for search/autocomplete
- Turbo Stream responses for dynamic updates
- Same action pattern as albums (execute_action, bulk_action)
- Table-qualified column names for sorting
- Empty result handling for search

### 3. Song Action

#### Action 1: Merge Song

```ruby
# app/lib/actions/admin/music/merge_song.rb
module Actions
  module Admin
    module Music
      class MergeSong < Actions::Admin::BaseAction
        def self.name
          "Merge Another Song Into This One"
        end

        def self.message
          "Enter the ID of a duplicate song to merge into the current song. The source song will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Song"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single song.") if models.count != 1

          target_song = models.first

          # Fields come from form submission
          source_song_id = fields[:source_song_id]
          confirm_merge = fields[:confirm_merge]

          unless source_song_id.present?
            return error("Please enter the ID of the song to merge.")
          end

          unless confirm_merge
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_song = ::Music::Song.find_by(id: source_song_id)

          unless source_song
            return error("Song with ID #{source_song_id} not found.")
          end

          if source_song.id == target_song.id
            return error("Cannot merge a song with itself. Please enter a different song ID.")
          end

          result = ::Music::Song::Merger.call(source: source_song, target: target_song)

          if result.success?
            succeed "Successfully merged '#{source_song.title}' (ID: #{source_song.id}) into '#{target_song.title}'. The source song has been deleted."
          else
            error "Failed to merge songs: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
```

**Note**: The existing `Music::Song::Merger` service already implements the full merge logic:
- Merges tracks, identifiers, category_items, external_links, list_items
- Handles song_relationships (for future when populated)
- Does NOT transfer song_artists (target's artists preserved)
- Wraps in database transaction
- Triggers search reindexing
- Schedules ranking recalculation
- Location: `/home/shane/dev/the-greatest/web-app/app/lib/music/song/merger.rb`

### 4. View Structure

```
app/views/admin/music/songs/
├── index.html.erb          # List view with search, sort, pagination
├── show.html.erb           # Detail view with all associations
├── new.html.erb            # New song form
├── edit.html.erb           # Edit song form
├── _form.html.erb          # Shared form partial
└── _table.html.erb         # Table partial for Turbo Frame updates
```

#### Index View Features
- Search component (reuse `AutocompleteComponent`)
- Sort links (title, release_year, duration_secs, created_at)
- Bulk selection checkboxes
- Pagination with Pagy
- Song count badge
- Action buttons (future bulk actions)
- Artists displayed comma-separated

#### Show View Features
- **Basic Info Section**: Title, slug, description, notes, duration (formatted), release year, ISRC
- **Artists Section**:
  - Ordered list of artists via `song_artists` join
  - Show position for multi-artist songs
  - Links to artist admin pages
- **Tracks Section**:
  - Grouped by album/release
  - Show disc number, track number, position
  - Link to release admin page (Phase 5+)
  - Display track-specific duration if different from song duration
- **Categories Section**: Genre/style tags with links
- **Identifiers Section**: MusicBrainz recording/work IDs, ISRC
- **External Links Section**: Streaming services, purchase links, Wikipedia, etc.
- **Lists Section**: Which lists contain this song
- **Rankings Section**: Current ranking positions
- **Action Buttons**: Merge Song

**Deferred to Future Phases** (not currently populated):
- Credits section
- Song Relationships section
- Lyrics section

#### Form Features
- Title (required)
- Description (textarea)
- Notes (textarea for internal use)
- Duration in seconds (number input, with helper text showing MM:SS conversion)
- Release Year (number input)
- ISRC (text input, 12 characters, with format helper)
- Validation error display
- Note: Artist associations handled via song_artists controller (Phase 3 pattern)

### 5. Search Integration

**OpenSearch Service**: Use existing `Search::Music::Search::SongAutocomplete`

**Already Indexed**: Songs are indexed via `SearchIndexable` concern

**Search Fields**:
- `title` - Text with folding analyzer + keyword + autocomplete subfields
- `artist_names` - Text with folding analyzer + keyword subfield
- `artist_ids` - Keyword
- `album_ids` - Keyword
- `category_ids` - Keyword

**Boost Values**:
- Title autocomplete match: 10.0
- Title phrase match: 8.0
- Title keyword exact match: 6.0

**Size Limits**:
- Index action: 1000 results (then paginated)
- Autocomplete: 10 results (JSON endpoint)

### 6. Artist Show Page Enhancement

Update artist show page to display songs via song_artists join:

```erb
<!-- app/views/admin/music/artists/show.html.erb -->

<!-- Add this section after existing albums section -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">
      Songs
      <div class="badge badge-primary"><%= @artist.song_artists.count %></div>
    </h2>

    <% if @artist.song_artists.any? %>
      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Title</th>
              <th>Release Year</th>
              <th>Position</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <% @artist.song_artists.ordered.includes(:song).each do |song_artist| %>
              <tr>
                <td><%= song_artist.song.title %></td>
                <td><%= song_artist.song.release_year %></td>
                <td><%= song_artist.position %></td>
                <td>
                  <%= link_to "View", admin_song_path(song_artist.song),
                              class: "btn btn-sm btn-ghost",
                              data: { turbo_frame: "_top" } %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= link_to "View All Songs →",
                  admin_songs_path(artist_id: @artist.id),
                  class: "btn btn-outline btn-sm" %>
    <% else %>\
      <p class="text-base-content/50">No songs found for this artist.</p>
    <% end %>
  </div>
</div>
```

**Controller Update**:
```ruby
# app/controllers/admin/music/artists_controller.rb

def show
  @artist = Music::Artist
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      album_artists: [:album],
      song_artists: [:song],  # Add this
      images: []
    )
    .find(params[:id])
end
```

### 7. Album Show Page Enhancement

Update album show page to display songs via releases > tracks:

```erb
<!-- app/views/admin/music/albums/show.html.erb -->

<!-- Add this section after existing sections -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">
      Songs
      <div class="badge badge-primary"><%= @album.releases.sum { |r| r.tracks.count } %></div>
    </h2>

    <% if @album.releases.any? %>
      <% @album.releases.each do |release| %>
        <div class="mb-6">
          <h3 class="text-lg font-semibold mb-2"><%= release.format.titleize %> - <%= release.status.titleize %></h3>

          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Disc</th>
                  <th>Track</th>
                  <th>Title</th>
                  <th>Duration</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <% release.tracks.ordered.includes(:song).each do |track| %>
                  <tr>
                    <td><%= track.medium_number %></td>
                    <td><%= track.position %></td>
                    <td><%= track.song.title %></td>
                    <td><%= format_duration(track.length_secs || track.song.duration_secs) %></td>
                    <td>
                      <%= link_to "View", admin_song_path(track.song),
                                  class: "btn btn-xs btn-ghost",
                                  data: { turbo_frame: "_top" } %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    <% else %>
      <p class="text-base-content/50">No releases with tracks found for this album.</p>
    <% end %>
  </div>
</div>
```

**Helper Method** (add to `ApplicationHelper` or `Admin::MusicHelper`):
```ruby
def format_duration(seconds)
  return "—" if seconds.nil?
  minutes = seconds / 60
  secs = seconds % 60
  "%d:%02d" % [minutes, secs]
end
```

**Controller Update**:
```ruby
# app/controllers/admin/music/albums_controller.rb

def show
  @album = Music::Album
    .includes(
      :categories,
      :identifiers,
      :primary_image,
      :external_links,
      album_artists: [:artist],
      releases: { tracks: [:song] },  # Enhanced eager loading
      images: [],
      credits: [:artist]
    )
    .find(params[:id])
end
```

## Dependencies
- **Existing**: Tailwind CSS, DaisyUI, ViewComponents, Hotwire (Turbo + Stimulus), OpenSearch
- **Phase 1 Complete**: Artist admin with search endpoints
- **Phase 2 Complete**: Album admin with search endpoints
- **Phase 3 Complete**: Album Artists join table, autocomplete component
- **Existing Services**:
  - `Music::Song::Merger` - Song merge logic
  - `Search::Music::Search::SongAutocomplete` - OpenSearch service for autocomplete
  - `Search::Music::Search::SongGeneral` - OpenSearch service for general search
  - `Search::Music::Search::SongByTitleAndArtists` - Structured search by title and artists
- **Pagy**: Already installed (from Phase 1)
- **AutocompleteComponent**: Already exists (from Phase 3)

## Acceptance Criteria
- [ ] `/admin/songs` path shows song index with search, sort, pagination
- [ ] Song show page displays all fields and associations
- [ ] Song new/create/edit/update/destroy CRUD operations work
- [ ] Merge Song action executes successfully:
  - [ ] Single record action with validation
  - [ ] Prevents self-merge
  - [ ] Requires confirmation
  - [ ] Uses existing `Music::Song::Merger` service
- [ ] Artist show page displays songs section with:
  - [ ] Song count badge
  - [ ] Table of songs with position
  - [ ] Links to song admin pages
- [ ] Album show page displays songs section with:
  - [ ] Songs grouped by release
  - [ ] Disc and track numbers
  - [ ] Formatted durations
  - [ ] Links to song admin pages
- [ ] Search is debounced and returns results within 300ms
- [ ] Bulk selection UI allows selecting multiple songs (UI present, Stimulus controller deferred)
- [ ] Action buttons are visible based on context (index vs show)
- [ ] Authorization prevents non-admin/editor access
- [ ] All pages are responsive (mobile, tablet, desktop)
- [ ] N+1 queries prevented with eager loading
- [ ] Empty search results handled gracefully
- [ ] Sort column SQL injection prevented with whitelist
- [ ] Duration formatting helper works correctly (MM:SS format)
- [ ] All tests passing with >95% coverage

## Design Decisions

### Why Songs Are Complex
- **Multiple Join Tables**: song_artists (Phase 3), tracks (link to releases/albums)
- **Duration vs Length**: Songs have `duration_secs`, tracks have `length_secs` (track-specific override)
- **No Direct Album Association**: Songs connect to albums through releases > tracks (many-to-many-to-many)
- **Deferred Associations**: Credits, song relationships, and lyrics not currently populated

### Display Strategy for Tracks
- **Group by Release**: Show tracks organized by which release they appear on
- **Show Release Context**: Format (vinyl, CD, digital) and status (official, bootleg, etc.)
- **Disc Awareness**: Display medium_number for multi-disc releases
- **Duration Fallback**: Show track length if present, otherwise song duration

### Song Relationships (Deferred)
- **Data Not Populated**: Credits and song relationships are not currently being populated
- **Future Phase**: Will add these sections once data import/population is implemented
- **Display Strategy**: When implemented, will show bidirectional relationships (covers/covered_by, etc.)

### Merge Song Action
- **Modal Approach**: Follow Phase 2 pattern (album merge modal)
- **Field Validation**: Source song ID required, confirmation checkbox required
- **Prevents Self-Merge**: Validates source != target
- **Uses Existing Service**: Delegates to `Music::Song::Merger` service
- **No Duplicate Detection UI**: Admin must manually identify duplicates (rake task exists: `bin/rails music:songs:find_duplicates`)


### Duration Formatting
- **Helper Method**: `format_duration(seconds)` returns "M:SS" format
- **Nil Handling**: Shows "—" for missing durations
- **Used Everywhere**: Show page, tracks table, index page (optional)

## Acceptance Criteria for Testing

### Controller Tests Required

```ruby
# test/controllers/admin/music/songs_controller_test.rb

class Admin::Music::SongsControllerTest < ActionDispatch::IntegrationTest
  # Standard CRUD tests (7 tests)
  test "should get index"
  test "should get new"
  test "should create song"
  test "should show song"
  test "should get edit"
  test "should update song"
  test "should destroy song"

  # Search tests (3 tests)
  test "should search songs via opensearch"
  test "should handle empty search results without error"
  test "should return json for autocomplete endpoint"

  # Pagination tests (1 test)
  test "should paginate songs"

  # Sorting tests (2 tests)
  test "should sort songs by allowed columns"
  test "should reject invalid sort parameters and default to title"

  # Action execution tests (3 tests)
  test "should execute merge song action"
  test "should handle merge action errors gracefully"
  test "should update flash via turbo stream"

  # Authorization tests (2 tests)
  test "should require admin or editor role"
  test "should redirect non-admin users to root"

  # N+1 prevention tests (2 tests)
  test "should not have N+1 queries on index"
  test "should not have N+1 queries on show"

  # Error handling (1 test)
  test "should handle invalid song id"

  # Total: ~21 tests
end
```

### Action Tests Required

```ruby
# test/lib/actions/admin/music/merge_song_test.rb
class Actions::Admin::Music::MergeSongTest < ActiveSupport::TestCase
  test "should merge songs successfully"
  test "should reject merge without source_song_id"
  test "should reject merge without confirmation"
  test "should reject merge with invalid source song id"
  test "should reject self-merge"
  test "should reject multiple song selection"

  # Total: 6 tests
end
```

### Helper Tests Required

```ruby
# test/helpers/admin/music_helper_test.rb
class Admin::MusicHelperTest < ActionView::TestCase
  test "format_duration returns MM:SS format"
  test "format_duration handles nil"
  test "format_duration handles zero"
  test "format_duration handles hours (60+ minutes)"

  # Total: 4 tests
end
```

### Integration/System Tests (Optional, Recommended)

```ruby
# test/system/admin/songs_test.rb
class Admin::SongsTest < ApplicationSystemTestCase
  test "admin can create song"
  test "admin can edit song"
  test "admin can delete song with confirmation"
  test "admin can search songs"
  test "admin can merge songs"
  test "duration formats correctly in UI"

  # Total: 6 tests
end
```

**Target Coverage**: >95% for controllers and actions, 100% for critical paths (merge, create, destroy)

## Technical Approach - Additional Details

### 1. Merge Song Action - Modal Implementation

Since album merge modal worked well in Phase 2, follow the same pattern:

```erb
<!-- app/views/admin/music/songs/show.html.erb -->

<!-- Add modal trigger button in action section -->
<%= button_tag "Merge Another Song",
               class: "btn btn-warning",
               data: {
                 controller: "modal",
                 action: "click->modal#open",
                 modal_target_value: "merge-song-modal"
               } %>

<!-- Merge song modal -->
<dialog id="merge-song-modal" class="modal">
  <div class="modal-box">
    <h3 class="font-bold text-lg">Merge Another Song Into This One</h3>
    <p class="py-4">
      Enter the ID of a duplicate song to merge into the current song.
      The source song will be permanently deleted after merging.
    </p>

    <%= form_with url: execute_action_admin_song_path(@song),
                  method: :post,
                  class: "space-y-4",
                  data: { controller: "modal-form" } do |f| %>
      <%= f.hidden_field :action_name, value: "MergeSong" %>

      <div class="form-control">
        <%= f.label :source_song_id, "Source Song ID (to be deleted)", class: "label" %>
        <%= f.number_field :source_song_id,
                          class: "input input-bordered w-full",
                          placeholder: "e.g., 123",
                          required: true %>
        <label class="label">
          <span class="label-text-alt">Enter the ID of the duplicate song</span>
        </label>
      </div>

      <div class="form-control">
        <%= f.check_box :confirm_merge,
                       class: "checkbox",
                       required: true %>
        <%= f.label :confirm_merge, "I understand this action cannot be undone", class: "label cursor-pointer" %>
        <label class="label">
          <span class="label-text-alt">The source song will be permanently deleted after merging</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="merge_song_modal.close()">Cancel</button>
        <%= f.submit "Merge Song", class: "btn btn-warning" %>
      </div>
    <% end %>
  </div>
</dialog>
```

**Modal Form Controller** (already exists from Phase 3):
```javascript
// app/javascript/controllers/modal_form_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.element.addEventListener('turbo:submit-end', (event) => {
      if (event.detail.success) {
        const modal = this.element.closest('dialog')
        if (modal) {
          modal.close()
          this.element.reset()
        }
      }
    })
  }
}
```

### 2. N+1 Prevention Strategy

Songs have many associations, requiring careful eager loading:

```ruby
# Index - Multiple associations
@songs = Music::Song.all
  .includes(
    :categories,
    song_artists: [:artist]  # Nested includes for join table
  )

# Show - Deep nesting for active associations
@song = Music::Song
  .includes(
    :categories,
    :identifiers,
    :external_links,
    song_artists: [:artist],                         # Artists via join table
    tracks: { release: [:album, :primary_image] },   # Tracks with albums
    list_items: [:list],                              # List memberships
    ranked_items: [:ranking_configuration]            # Ranking positions
  )
  .find(params[:id])
```

**Note**: Credits and song_relationships are NOT included since that data is not currently populated.

**Key Differences from Album**:
- `song_artists` join table requires nested include
- `tracks` association is more complex (release > album > primary_image)
- More polymorphic associations than albums

### 3. Duration Formatting

Create a helper method for consistent duration display:

```ruby
# app/helpers/admin/music_helper.rb
module Admin::MusicHelper
  def format_duration(seconds)
    return "—" if seconds.nil? || seconds == 0

    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60

    if hours > 0
      "%d:%02d:%02d" % [hours, minutes, secs]
    else
      "%d:%02d" % [minutes, secs]
    end
  end
end
```

**Usage in views**:
```erb
<td><%= format_duration(@song.duration_secs) %></td>
<td><%= format_duration(track.length_secs || track.song.duration_secs) %></td>
```

### 4. Tracks Display Strategy

Group tracks by release and display with full context:

```erb
<!-- app/views/admin/music/songs/show.html.erb -->

<% if @song.tracks.any? %>
  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">
        Track Appearances
        <div class="badge badge-primary"><%= @song.tracks.count %></div>
      </h2>

      <% tracks_by_release = @song.tracks.includes(release: [:album]).group_by(&:release) %>
      <% tracks_by_release.each do |release, tracks| %>
        <div class="mb-4">
          <h3 class="font-semibold mb-2">
            <%= link_to release.album.title, admin_album_path(release.album),
                        class: "link link-hover",
                        data: { turbo_frame: "_top" } %>
            <span class="text-sm text-gray-500">
              (<%= release.format.titleize %> - <%= release.status.titleize %>)
            </span>
          </h3>

          <div class="overflow-x-auto">
            <table class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Disc</th>
                  <th>Track</th>
                  <th>Duration</th>
                </tr>
              </thead>
              <tbody>
                <% tracks.ordered.each do |track| %>
                  <tr>
                    <td><%= track.medium_number %></td>
                    <td><%= track.position %></td>
                    <td><%= format_duration(track.length_secs || @song.duration_secs) %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
  </div>
<% end %>
```

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Phase 4 Implementation Steps

1. **Generate Controller** ⏳
   ```bash
   cd web-app
   bin/rails generate controller Admin::Music::Songs index show new edit
   ```

2. **Build Song Views** ⏳
   - Index view with search, table, pagination
   - Show view with all associations (most complex view yet)
   - Form partial for new/edit
   - Table partial for Turbo Frame updates

3. **Create Song Action** ⏳
   - MergeSong action class
   - Modal component for merge action (reuse Phase 2 pattern)

4. **Create Duration Helper** ⏳
   - `format_duration(seconds)` method in Admin::MusicHelper
   - Tests for helper method

5. **Update Routes** ⏳
   - Add songs resources inside admin namespace
   - Add member and collection routes for actions

6. **Update Artist Show Page** ⏳
   - Add songs section via song_artists join
   - Display song count
   - Link to filtered song index

7. **Update Album Show Page** ⏳
   - Add songs section via releases > tracks
   - Group by release and disc
   - Show track numbers and durations

8. **Update Sidebar Navigation** ⏳
   - Add "Songs" link under Music section
   - Update active state detection

9. **Testing & Refinement** ⏳
   - Manual testing of all CRUD operations
   - Test merge action
   - Test artist-song and album-song integration
   - Mobile responsiveness check
   - Automated test coverage (target: >95%)

### Approach Taken
*[To be documented during implementation]*

### Key Files Created
*[To be documented during implementation]*

### Key Files Modified
*[To be documented during implementation]*

### Challenges Encountered
*[To be documented during implementation]*

### Deviations from Plan
*[To be documented during implementation]*

### Testing Approach
*[To be documented during implementation]*

### Performance Considerations
*[To be documented during implementation]*

### Future Improvements
- [ ] Credits section (once data is populated)
- [ ] Song relationships section (once data is populated)
- [ ] Lyrics section (once data is populated)
- [ ] Batch edit for multiple songs
- [ ] Export to CSV/JSON
- [ ] Song artwork display (if separate from album artwork)
- [ ] Audio preview integration (if streaming available)
- [ ] Waveform visualization for duration

### Lessons Learned
*[To be documented during implementation]*

### Related PRs
*[To be created when ready to merge]*

### Documentation Updated
- [ ] Class documentation for Admin::Music::SongsController
- [ ] Class documentation for Actions::Admin::Music::MergeSong
- [ ] Helper documentation for Admin::MusicHelper
- [ ] This todo file with comprehensive implementation notes
- [ ] Updated main docs/todo.md

### Tests Created
- [ ] Admin::Music::SongsController tests (~21 tests)
- [ ] Actions::Admin::Music::MergeSong tests (6 tests)
- [ ] Admin::MusicHelper tests (4 tests)
- [ ] Total: ~31 tests minimum

## Next Phases

### Phase 5: Music Junction Tables & Additional Resources (TODO #076)
- Admin::Music::TracksController (song appearances on releases)
- Admin::Music::ReleasesController (enhanced from Phase 2)
- Admin::Music::CategoriesController
- Use autocomplete component for song/artist/release associations
- Future: Credits and Song Relationships (once data is populated)

### Phase 6: Music Ranking Admin (TODO #077)
- Admin::Music::ArtistsRankingConfigurationsController
- Admin::Music::AlbumsRankingConfigurationsController
- Admin::Music::SongsRankingConfigurationsController

### Phase 7: Global Resources (TODO #078)
- Admin::PenaltiesController
- Admin::UsersController

### Phase 8: Movies, Books, Games (TODO #079-081)
- Replicate Music patterns for other domains

### Phase 9: Avo Removal (TODO #082)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files
- Update documentation

## Research References

### Song-Specific Considerations
- **No Direct Album Link**: Songs connect to albums through releases > tracks (many-to-many-to-many)
- **Duration Complexity**: Songs have `duration_secs`, tracks have optional `length_secs` override
- **Multiple Artists**: Songs can have multiple artists via `song_artists` join table with position ordering
- **Deferred Data**: Credits, song relationships, and lyrics not currently populated

### Existing Song Merge Service
- **Location**: `app/lib/music/song/merger.rb`
- **Comprehensive**: Merges tracks, identifiers, categories, external links, list items
- **Transaction Safe**: All operations in single database transaction
- **Ranking Aware**: Schedules recalculation jobs for affected ranking configurations
- **Future Ready**: Already handles song relationships when that data is populated

### Song Search Patterns
- **Three Search Classes**:
  1. `SongAutocomplete` - Edge n-gram autocomplete matching
  2. `SongGeneral` - Full-text with title and artist matching
  3. `SongByTitleAndArtists` - Structured search by title and artists array
- **Index Fields**: title (with autocomplete), artist_names, artist_ids, album_ids, category_ids
- **Boost Strategy**: Title autocomplete (10.0), title phrase (8.0), title keyword (6.0)

## Additional Resources
- [Phase 1 Spec](todos/072-custom-admin-phase-1-artists.md) - Artists implementation
- [Phase 2 Spec](todos/073-custom-admin-phase-2-albums.md) - Albums implementation
- [Phase 3 Spec](todos/074-custom-admin-phase-3-album-artists.md) - Album Artists join table
- [Music::Song Model Docs](models/music/song.md) - Model documentation
- [Music::Song::Merger Service Docs](lib/music/song/merger.md) - Merge service documentation
- [DaisyUI Modal Component](https://daisyui.com/components/modal/) - Modal patterns
- [OpenSearch Documentation](https://opensearch.org/docs/latest/) - Search documentation
