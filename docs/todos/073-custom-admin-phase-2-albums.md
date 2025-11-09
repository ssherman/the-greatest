# 073 - Custom Admin Interface - Phase 2: Music Albums

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-09
- **Started**: [TBD]
- **Completed**: [TBD]
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin CRUD interface for Music::Album following the patterns established in Phase 1 (Artists). Replace Avo album resource and actions with custom Rails admin built on ViewComponents + Hotwire (Turbo + Stimulus).

## Context
- **Phase 1 Complete**: Artists admin interface completed (docs/todos/072-custom-admin-phase-1-artists.md)
- **Proven Architecture**: ViewComponents, Hotwire, DaisyUI, OpenSearch patterns established
- **Avo to Replicate**: Need to migrate album resource, 2 core actions, and integrate with artist show pages
- **More Complex**: Albums have more associations than artists (releases, tracks, multiple artists, etc.)

## Requirements

### Base Album CRUD
- [x] Route namespace for `/admin/albums` path (inside domain constraint)
- [x] Admin::Music::AlbumsController with full CRUD
- [x] Base album views following artist patterns

### Album Index Page
- [x] Display columns: ID, Title, Artists (comma-separated), Release Year, Categories, Created at
- [x] Search/filter by title and artist names (OpenSearch)
- [x] Pagination (Pagy, 25 items per page)
- [x] Bulk selection UI
- [x] Sort by columns (title, release_year, created_at)
- [x] Album count badge

### Album Show Page
- [x] All album fields displayed
- [x] Associations displayed:
  - Artists (via album_artists join table with position)
  - Releases (format, status, release_date, country, labels)
  - Categories
  - Identifiers (MusicBrainz release group ID, ASIN, Discogs, AllMusic)
  - Images (with primary image highlighted)
  - External links (Amazon, Wikipedia, etc.)
  - Credits (polymorphic association)
  - List items (which lists contain this album)
  - Ranked items (ranking positions)
- [x] Primary image display
- [x] External links
- [x] Action buttons

### Album New/Create
- [x] Form with all editable fields:
  - Title (required)
  - Description (textarea)
  - Release Year (number)
- [x] Validation error display
- [x] Note: Artists association handled separately (Phase 3)

### Album Edit/Update
- [x] Same form as New
- [x] Pre-populated values

### Album Destroy
- [x] Confirmation dialog (Turbo Frame)
- [x] Dependent records handling (releases, images, etc.)
- [x] Warning about list items and rankings

### Admin Actions System
- [x] Two album actions to replicate from Avo:
  1. **Merge Album** (single record action)
  2. **Generate AI Description** (bulk action)

### Artist Show Page Enhancement
- [x] Add "Albums" section to artist show page
- [x] Display albums with links to album admin pages
- [x] Show album count badge
- [x] Link to filtered album index (showing only this artist's albums)

## Technical Approach

### 1. Routing & Controllers

```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  # ... other music routes ...

  namespace :admin, module: "admin/music" do
    root to: "dashboard#index"

    resources :artists do
      # ... existing artist routes ...
    end

    resources :albums do
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
- `admin_albums_path` → `/admin/albums`
- `admin_album_path(@album)` → `/admin/albums/:id`
- `execute_action_admin_album_path(@album)` → `/admin/albums/:id/execute_action`
- `bulk_action_admin_albums_path` → `/admin/albums/bulk_action`
- `search_admin_albums_path` → `/admin/albums/search`

### 2. Controller Architecture

```ruby
# app/controllers/admin/music/albums_controller.rb
class Admin::Music::AlbumsController < Admin::Music::BaseController
  before_action :set_album, only: [:show, :edit, :update, :destroy, :execute_action]

  def index
    load_albums_for_index
  end

  def show
    # Eager load all associations to prevent N+1 queries
    @album = Music::Album
      .includes(
        :categories,
        :identifiers,
        :primary_image,
        :external_links,
        album_artists: [:artist],
        releases: [:primary_image],
        images: [],
        credits: [:artist]
      )
      .find(params[:id])
  end

  def new
    @album = Music::Album.new
  end

  def create
    @album = Music::Album.new(album_params)

    if @album.save
      redirect_to admin_album_path(@album), notice: "Album created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    # @album loaded by before_action
  end

  def update
    if @album.update(album_params)
      redirect_to admin_album_path(@album), notice: "Album updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @album.destroy!
    redirect_to admin_albums_path, notice: "Album deleted successfully."
  end

  def execute_action
    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: [@album])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "flash",
          partial: "admin/shared/flash",
          locals: { result: result }
        )
      end
      format.html { redirect_to admin_album_path(@album), notice: result.message }
    end
  end

  def bulk_action
    album_ids = params[:album_ids] || []
    albums = Music::Album.where(id: album_ids)

    action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
    result = action_class.call(user: current_user, models: albums)

    load_albums_for_index

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "admin/shared/flash", locals: { result: result }),
          turbo_stream.replace("albums_table", partial: "admin/music/albums/table", locals: { albums: @albums, pagy: @pagy })
        ]
      end
      format.html { redirect_to admin_albums_path, notice: result.message }
    end
  end

  def search
    # Use existing OpenSearch implementation
    search_results = ::Search::Music::Search::AlbumGeneral.call(params[:q], size: 10)
    album_ids = search_results.map { |r| r[:id].to_i }

    # Handle empty results to prevent ArgumentError
    if album_ids.empty?
      render json: []
      return
    end

    # Load album records preserving search order
    albums = Music::Album
      .includes(:artists)
      .in_order_of(:id, album_ids)

    render json: albums.map { |a|
      {
        value: a.id,
        text: "#{a.title} - #{a.artists.map(&:name).join(", ")}"
      }
    }
  end

  private

  def set_album
    @album = Music::Album.find(params[:id])
  end

  def load_albums_for_index
    if params[:q].present?
      # Use OpenSearch for search
      search_results = ::Search::Music::Search::AlbumGeneral.call(params[:q], size: 1000)
      album_ids = search_results.map { |r| r[:id].to_i }

      # Handle empty results
      if album_ids.empty?
        @albums = Music::Album.none
      else
        # Preserve search order using Rails 7+ in_order_of
        @albums = Music::Album
          .includes(:categories, album_artists: [:artist])
          .in_order_of(:id, album_ids)
      end

      @pagy, @albums = pagy(@albums, items: 25)
    else
      # Normal database query for browsing
      @albums = Music::Album.all
        .includes(:categories, album_artists: [:artist])

      # Apply sorting
      sort_column = sortable_column(params[:sort])
      @albums = @albums.order(sort_column)

      @pagy, @albums = pagy(@albums, items: 25)
    end
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "music_albums.id",
      "title" => "music_albums.title",
      "release_year" => "music_albums.release_year",
      "created_at" => "music_albums.created_at"
    }

    allowed_columns.fetch(column.to_s, "music_albums.title")
  end

  def album_params
    params.require(:music_album).permit(
      :title,
      :description,
      :release_year
    )
  end
end
```

### 3. Album Actions

#### Action 1: Merge Album

```ruby
# app/lib/actions/admin/music/merge_album.rb
module Actions
  module Admin
    module Music
      class MergeAlbum < Actions::Admin::BaseAction
        def self.name
          "Merge Another Album Into This One"
        end

        def self.message
          "Enter the ID of a duplicate album to merge into the current album. The source album will be permanently deleted after merging."
        end

        def self.confirm_button_label
          "Merge Album"
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single album.") if models.count != 1

          target_album = models.first

          # For custom admin, we need a different approach than Avo's fields
          # This will be handled via a form in the view that posts to execute_action with fields hash
          source_album_id = fields[:source_album_id]
          confirm_merge = fields[:confirm_merge]

          unless source_album_id.present?
            return error("Please enter the ID of the album to merge.")
          end

          unless confirm_merge
            return error("Please confirm you understand this action cannot be undone.")
          end

          source_album = ::Music::Album.find_by(id: source_album_id)

          unless source_album
            return error("Album with ID #{source_album_id} not found.")
          end

          if source_album.id == target_album.id
            return error("Cannot merge an album with itself. Please enter a different album ID.")
          end

          result = ::Music::Album::Merger.call(source: source_album, target: target_album)

          if result.success?
            succeed "Successfully merged '#{source_album.title}' (ID: #{source_album.id}) into '#{target_album.title}'. The source album has been deleted."
          else
            error "Failed to merge albums: #{result.errors.join(", ")}"
          end
        end
      end
    end
  end
end
```

**Note**: The existing `Music::Album::Merger` service already implements the full merge logic:
- Merges releases, identifiers, category_items, images, external_links, list_items
- Handles primary image preservation logic
- Wraps in database transaction
- Triggers search reindexing
- Schedules ranking recalculation
- Location: `/home/shane/dev/the-greatest/web-app/app/lib/music/album/merger.rb`

#### Action 2: Generate AI Description

```ruby
# app/lib/actions/admin/music/generate_album_description.rb
module Actions
  module Admin
    module Music
      class GenerateAlbumDescription < Actions::Admin::BaseAction
        def self.name
          "Generate AI Description"
        end

        def self.message
          "This will generate AI descriptions for the selected album(s) in the background."
        end

        def self.confirm_button_label
          "Generate Descriptions"
        end

        def call
          album_ids = models.map(&:id)

          album_ids.each do |album_id|
            ::Music::AlbumDescriptionJob.perform_async(album_id)
          end

          succeed "#{album_ids.length} album(s) queued for AI description generation."
        end
      end
    end
  end
end
```

**Note**: This action delegates to existing `Music::AlbumDescriptionJob` which:
- Calls `Services::Ai::Tasks::Music::AlbumDescriptionTask`
- Uses OpenAI GPT-5-mini model
- Allows AI to abstain if uncertain about album
- Only updates album if AI provides description and doesn't abstain
- Location: `/home/shane/dev/the-greatest/web-app/app/sidekiq/music/album_description_job.rb`

### 4. View Structure

```
app/views/admin/music/albums/
├── index.html.erb          # List view with search, sort, pagination
├── show.html.erb           # Detail view with all associations
├── new.html.erb            # New album form
├── edit.html.erb           # Edit album form
├── _form.html.erb          # Shared form partial
└── _table.html.erb         # Table partial for Turbo Frame updates
```

#### Index View Features
- Search component (reuse `Admin::SearchComponent`)
- Sort links (title, release_year, created_at)
- Bulk selection checkboxes
- Pagination with Pagy
- Album count badge
- Action buttons (bulk AI description generation)

#### Show View Features
- **Basic Info Section**: Title, release year, description, slug
- **Artists Section**:
  - Ordered list of artists via `album_artists` join
  - Show position for multi-artist albums
  - Links to artist admin pages
- **Releases Section**:
  - Format (vinyl, cd, digital, cassette, other)
  - Status (official, promotion, bootleg, etc.)
  - Release date, country, labels
  - Link to release admin page (Phase 3)
- **Categories Section**: Genre tags with links
- **Images Section**:
  - Primary image (large display)
  - All images (thumbnail gallery)
  - Upload functionality (reuse existing patterns)
- **Identifiers Section**: MusicBrainz, ASIN, Discogs, AllMusic IDs
- **External Links Section**: Amazon, Wikipedia, other links
- **Credits Section**: Polymorphic credits (producer, engineer, etc.)
- **Lists Section**: Which lists contain this album
- **Rankings Section**: Current ranking positions
- **Action Buttons**: Merge Album, Generate AI Description

#### Form Features
- Title (required)
- Description (textarea with AI-generated helper text)
- Release Year (number input)
- Validation error display
- Note: Artist associations handled in Phase 3 (junction table CRUD)

### 5. Search Integration

**OpenSearch Service**: Use existing `Search::Music::Search::AlbumGeneral`

**Already Indexed**: Albums are indexed via `SearchIndexable` concern

**Search Fields**:
- `title` - Text with folding analyzer + keyword subfield
- `artist_names` - Text with folding analyzer + keyword subfield
- `artist_ids` - Keyword
- `category_ids` - Keyword

**Boost Values**:
- Title exact phrase: 10.0
- Title match: 8.0
- Title keyword: 9.0
- Artist names match: 5.0
- Artist names phrase: 6.0

**Size Limits**:
- Index action: 1000 results (then paginated)
- Autocomplete: 10 results (JSON endpoint)

### 6. Artist Show Page Enhancement

Update artist show page to display albums:

```erb
<!-- app/views/admin/music/artists/show.html.erb -->

<!-- Add this section after existing sections -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">
      Albums
      <div class="badge badge-primary"><%= @artist.albums.count %></div>
    </h2>

    <% if @artist.albums.any? %>
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
            <% @artist.album_artists.includes(:album).ordered.each do |album_artist| %>
              <tr>
                <td><%= album_artist.album.title %></td>
                <td><%= album_artist.album.release_year %></td>
                <td><%= album_artist.position %></td>
                <td>
                  <%= link_to "View", admin_album_path(album_artist.album),
                              class: "btn btn-sm btn-ghost",
                              data: { turbo_frame: "_top" } %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= link_to "View All Albums →",
                  admin_albums_path(artist_id: @artist.id),
                  class: "btn btn-outline btn-sm" %>
    <% else %>
      <p class="text-base-content/50">No albums found for this artist.</p>
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
      album_artists: [:album],  # Add this
      albums: [:primary_image],  # Add this
      images: []
    )
    .find(params[:id])
end
```

**Index Enhancement** (optional):
Add filter to show only albums for a specific artist:

```ruby
def load_albums_for_index
  base_query = Music::Album.all

  # Filter by artist if provided
  if params[:artist_id].present?
    artist = Music::Artist.find(params[:artist_id])
    base_query = artist.albums
    @filtered_by_artist = artist
  end

  # ... rest of search/pagination logic ...
end
```

## Dependencies
- **Existing**: Tailwind CSS, DaisyUI, ViewComponents, Hotwire (Turbo + Stimulus), OpenSearch
- **Phase 1 Complete**: Artist admin, base controllers, base actions, search component
- **Existing Services**:
  - `Music::Album::Merger` - Album merge logic
  - `Music::AlbumDescriptionJob` - AI description generation
  - `Services::Ai::Tasks::Music::AlbumDescriptionTask` - AI task
  - `Search::Music::Search::AlbumGeneral` - OpenSearch service
- **Pagy**: Already installed (from Phase 1)

## Acceptance Criteria
- [ ] `/admin/albums` path shows album index with search, sort, pagination
- [ ] Album show page displays all fields and associations
- [ ] Album new/create/edit/update/destroy CRUD operations work
- [ ] Two album actions execute successfully:
  - [ ] Merge Album (single record action with validation)
  - [ ] Generate AI Description (bulk action)
- [ ] Artist show page displays albums section with:
  - [ ] Album count badge
  - [ ] Table of albums with position
  - [ ] Links to album admin pages
  - [ ] "View All Albums" link with artist filter
- [ ] Search is debounced and returns results within 300ms
- [ ] Bulk selection UI allows selecting multiple albums
- [ ] Action buttons are visible based on context (index vs show)
- [ ] Authorization prevents non-admin/editor access
- [ ] All pages are responsive (mobile, tablet, desktop)
- [ ] N+1 queries prevented with eager loading
- [ ] Empty search results handled gracefully
- [ ] Sort column SQL injection prevented with whitelist
- [ ] All tests passing with >95% coverage

## Design Decisions

### Why Replicate Only 2 Actions (Not All List Actions)
- **List Actions Separate**: List-related actions (EnrichItemsJson, ValidateItemsJson, ImportItemsFromJson) belong to Music::Albums::List admin, not Album admin
- **Phase 3 or Later**: List admin will be tackled in a later phase
- **Core Actions Only**: Focus on album-specific actions (Merge, AI Description)

### Album-Artist Relationship Display
- **Show Page Only**: Display artists on album show page in ordered table
- **Edit in Phase 3**: Junction table CRUD (album_artists) deferred to next phase
- **Prevent Complexity**: Keep Phase 2 focused on core album CRUD

### Merge Album Action Challenges
- **Field Handling**: Avo actions have built-in `fields` DSL, custom admin needs alternative
- **Options**:
  1. Modal with form (best UX, more complex)
  2. Separate page with form (simpler, less seamless)
  3. Inline form in action panel (compromise)
- **Recommendation**: Start with inline form, enhance to modal in later iteration

### Search Autocomplete Enhancement
Albums are more complex than artists (include artist names in results):
```json
[
  { "value": 123, "text": "Dark Side of the Moon - Pink Floyd" },
  { "value": 456, "text": "Abbey Road - The Beatles" }
]
```

### Release Count Display (Deferred)
- **Complexity**: Releases are many-to-one with albums
- **N+1 Risk**: Counting releases per album requires SQL aggregate or N+1 queries
- **Decision**: Defer release count to Phase 3 when releases admin is built
- **Show Page Only**: Display releases on show page with eager loading

## Acceptance Criteria for Testing

### Controller Tests Required
Similar to artist controller tests, create comprehensive test suite:

```ruby
# test/controllers/admin/music/albums_controller_test.rb

class Admin::Music::AlbumsControllerTest < ActionDispatch::IntegrationTest
  # Standard CRUD tests (7 tests)
  test "should get index"
  test "should get new"
  test "should create album"
  test "should show album"
  test "should get edit"
  test "should update album"
  test "should destroy album"

  # Search tests (3 tests)
  test "should search albums via opensearch"
  test "should handle empty search results without error"
  test "should return json for autocomplete endpoint"

  # Pagination tests (1 test)
  test "should paginate albums"

  # Sorting tests (2 tests)
  test "should sort albums by allowed columns"
  test "should reject invalid sort parameters and default to title"

  # Action execution tests (4 tests)
  test "should execute single record action"
  test "should execute bulk action"
  test "should handle action errors gracefully"
  test "should update flash and table via turbo stream"

  # Authorization tests (2 tests)
  test "should require admin or editor role"
  test "should redirect non-admin users to root"

  # N+1 prevention tests (2 tests)
  test "should not have N+1 queries on index"
  test "should not have N+1 queries on show"

  # Artist filter tests (2 tests)
  test "should filter albums by artist_id"
  test "should display artist name when filtered"

  # Error handling (1 test)
  test "should handle invalid album id"

  # Total: ~24 tests
end
```

### Action Tests Required

```ruby
# test/lib/actions/admin/music/merge_album_test.rb
class Actions::Admin::Music::MergeAlbumTest < ActiveSupport::TestCase
  test "should merge albums successfully"
  test "should reject merge without source_album_id"
  test "should reject merge without confirmation"
  test "should reject merge with invalid source album id"
  test "should reject self-merge"
  test "should reject multiple album selection"

  # Total: 6 tests
end

# test/lib/actions/admin/music/generate_album_description_test.rb
class Actions::Admin::Music::GenerateAlbumDescriptionTest < ActiveSupport::TestCase
  test "should queue jobs for selected albums"
  test "should handle single album"
  test "should handle multiple albums"
  test "should return correct message with count"

  # Total: 4 tests
end
```

### Integration/System Tests (Optional, Recommended)

```ruby
# test/system/admin/albums_test.rb
class Admin::AlbumsTest < ApplicationSystemTestCase
  test "admin can create album"
  test "admin can edit album"
  test "admin can delete album with confirmation"
  test "admin can search albums"
  test "admin can merge albums"
  test "admin can generate AI descriptions for albums"

  # Total: 6 tests
end
```

**Target Coverage**: >95% for controllers and actions, 100% for critical paths (merge, create, destroy)

## Technical Approach - Additional Details

### 1. Merge Album Action - Modal Implementation (Recommended Approach)

Since Avo actions have a built-in fields DSL but our custom admin doesn't, implement merge action via modal:

```erb
<!-- app/views/admin/music/albums/show.html.erb -->

<!-- Add modal trigger button in action section -->
<%= button_tag "Merge Another Album",
               class: "btn btn-warning",
               data: {
                 controller: "modal",
                 action: "click->modal#open",
                 modal_target_value: "merge-album-modal"
               } %>

<!-- Merge album modal -->
<dialog id="merge-album-modal" class="modal">
  <div class="modal-box">
    <h3 class="font-bold text-lg">Merge Another Album Into This One</h3>
    <p class="py-4">
      Enter the ID of a duplicate album to merge into the current album.
      The source album will be permanently deleted after merging.
    </p>

    <%= form_with url: execute_action_admin_album_path(@album),
                  method: :post,
                  class: "space-y-4" do |f| %>
      <%= f.hidden_field :action_name, value: "MergeAlbum" %>

      <div class="form-control">
        <%= f.label :source_album_id, "Source Album ID (to be deleted)", class: "label" %>
        <%= f.number_field :source_album_id,
                          class: "input input-bordered w-full",
                          placeholder: "e.g., 123",
                          required: true %>
        <label class="label">
          <span class="label-text-alt">Enter the ID of the duplicate album</span>
        </label>
      </div>

      <div class="form-control">
        <%= f.check_box :confirm_merge,
                       class: "checkbox",
                       required: true %>
        <%= f.label :confirm_merge, "I understand this action cannot be undone", class: "label cursor-pointer" %>
        <label class="label">
          <span class="label-text-alt">The source album will be permanently deleted after merging</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="merge_album_modal.close()">Cancel</button>
        <%= f.submit "Merge Album", class: "btn btn-warning" %>
      </div>
    <% end %>
  </div>
</dialog>
```

**Stimulus Controller** (if not already created):
```javascript
// app/javascript/controllers/admin/modal_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  open(event) {
    const modalId = event.params.targetValue
    const modal = document.getElementById(modalId)
    modal.showModal()
  }

  close(event) {
    const modal = event.target.closest("dialog")
    modal.close()
  }
}
```

**Updated Action to Handle Fields**:
```ruby
def call
  return error("This action can only be performed on a single album.") if models.count != 1

  target_album = models.first

  # Fields come from form submission
  source_album_id = fields["source_album_id"] || fields[:source_album_id]
  confirm_merge = fields["confirm_merge"] || fields[:confirm_merge]

  # ... rest of validation and merge logic ...
end
```

**Controller Update**:
```ruby
def execute_action
  # Extract fields from params
  fields_hash = params.except(:controller, :action, :id, :action_name, :album_ids)

  action_class = "Actions::Admin::Music::#{params[:action_name]}".constantize
  result = action_class.call(
    user: current_user,
    models: [@album],
    fields: fields_hash
  )

  # ... rest of response handling ...
end
```

### 2. N+1 Prevention Strategy

Albums have more complex associations than artists, requiring careful eager loading:

```ruby
# Index - Multiple associations
@albums = Music::Album.all
  .includes(
    :categories,
    album_artists: [:artist]  # Nested includes for join table
  )
  .left_joins(:releases)
  .select("music_albums.*, COUNT(DISTINCT music_releases.id) as releases_count")
  .group("music_albums.id")

# Show - Deep nesting for all associations
@album = Music::Album
  .includes(
    :categories,
    :identifiers,
    :primary_image,
    :external_links,
    album_artists: [:artist],         # Artists via join table
    releases: [:primary_image],       # Releases with images
    images: [],                        # All images
    credits: [:artist],                # Credits with artists
    list_items: [:list],               # List memberships
    ranked_items: [:ranking_configuration]  # Ranking positions
  )
  .find(params[:id])
```

**Key Differences from Artist**:
- `album_artists` join table requires nested include
- Multiple `has_many through` associations
- Polymorphic associations (credits, images, external_links)

### 3. Table-Qualified Column Names

Prevent ambiguous column errors with qualified names:

```ruby
def sortable_column(column)
  allowed_columns = {
    "id" => "music_albums.id",
    "title" => "music_albums.title",
    "release_year" => "music_albums.release_year",
    "created_at" => "music_albums.created_at"
  }

  # Default to title if invalid column
  allowed_columns.fetch(column.to_s, "music_albums.title")
end
```

**Why table-qualified**:
- Joins with `album_artists` and `releases` can cause ambiguous column errors
- `id` exists in multiple tables (albums, artists, releases)
- `created_at` exists in multiple tables

### 4. OpenSearch Integration

Album search is more complex than artist search (includes artist names):

```ruby
# Index search
search_results = ::Search::Music::Search::AlbumGeneral.call(params[:q], size: 1000)
album_ids = search_results.map { |r| r[:id].to_i }

# Autocomplete search (JSON endpoint)
search_results = ::Search::Music::Search::AlbumGeneral.call(params[:q], size: 10)
album_ids = search_results.map { |r| r[:id].to_i }

albums = Music::Album
  .includes(:artists)  # Need artists for display
  .in_order_of(:id, album_ids)

render json: albums.map { |a|
  {
    value: a.id,
    text: "#{a.title} - #{a.artists.map(&:name).join(", ")}"
  }
}
```

**Search Behavior**:
- Searches both album title AND artist names
- Returns albums where either field matches
- Boost values favor title matches over artist matches

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Phase 2 Implementation Steps

1. **Generate Controller** ✅
   ```bash
   cd web-app
   bin/rails generate controller Admin::Music::Albums index show new edit
   ```

2. **Build Album Views** ✅
   - Index view with search, table, pagination
   - Show view with all associations
   - Form partial for new/edit
   - Table partial for Turbo Frame updates

3. **Create Album Actions** ✅
   - MergeAlbum action class
   - GenerateAlbumDescription action class
   - Modal component for merge action

4. **Update Routes** ✅
   - Add albums resources inside admin namespace
   - Add member and collection routes for actions

5. **Update Artist Show Page** ✅
   - Add albums section
   - Display album count
   - Link to filtered album index

6. **Update Sidebar Navigation** ✅
   - Add "Albums" link under Music section
   - Update active state detection

7. **Testing & Refinement** ✅
   - Manual testing of all CRUD operations
   - Test both actions
   - Test artist-album integration
   - Mobile responsiveness check
   - Automated test coverage (target: >95%)

### Approach Taken
*[Document implementation approach here]*

### Key Files Created
*[List all new files with paths]*

### Key Files Modified
*[List all modified files with paths]*

### Challenges Encountered
*[Document any unexpected issues and resolutions]*

### Deviations from Plan
*[Note any changes from the original technical approach and why]*

### Testing Approach
*[How the feature was tested, any edge cases discovered]*

### Performance Considerations
*[Any optimizations made or needed]*

### Future Improvements
*[Potential enhancements identified during implementation]*

### Lessons Learned
*[What worked well, what could be done better next time]*

### Related PRs
*[Link pull requests when created]*

### Documentation Updated
- [ ] Class documentation for Admin::Music::AlbumsController
- [ ] Class documentation for Actions::Admin::Music::MergeAlbum
- [ ] Class documentation for Actions::Admin::Music::GenerateAlbumDescription
- [ ] Update testing documentation with album test patterns
- [ ] This todo file with comprehensive implementation notes

### Tests Created
- [ ] Admin::Music::AlbumsController tests (target: ~24 tests)
- [ ] Actions::Admin::Music::MergeAlbum tests (target: 6 tests)
- [ ] Actions::Admin::Music::GenerateAlbumDescription tests (target: 4 tests)
- [ ] System tests for album admin (optional, target: 6 tests)

## Next Phases

### Phase 3: Music Join Tables & Remaining CRUD (TODO #074)
- Admin::Music::AlbumArtistsController (junction table CRUD)
- Admin::Music::ReleasesController
- Admin::Music::TracksController
- Admin::Music::CreditsController
- Admin::Music::SongsController
- Autocomplete for artist/album/song associations (OpenSearch + Slim-Select)

### Phase 4: Music Ranking Admin (TODO #075)
- Admin::Music::ArtistsRankingConfigurationsController
- Admin::Music::AlbumsRankingConfigurationsController
- Admin::Music::SongsRankingConfigurationsController

### Phase 5: Global Resources (TODO #076)
- Admin::PenaltiesController
- Admin::UsersController

### Phase 6: Movies, Books, Games (TODO #077-079)
- Replicate Music pattern for other domains

### Phase 7: Avo Removal (TODO #080)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files

## Research References

### Album-Specific Considerations
- **Multiple Artists**: Albums can have multiple artists via `album_artists` join table
- **Position Ordering**: Artists displayed in order via `position` column
- **Releases vs Albums**: One album can have many releases (vinyl, CD, digital)
- **Track Associations**: Tracks belong to releases, not directly to albums

### Avo Action Patterns
- **Fields DSL**: Avo actions have built-in `fields` method returning field definitions
- **Handle Method**: Core logic in `handle(query:, fields:, current_user:, resource:, **args)`
- **Success/Error**: Return `succeed("message")` or `error("message")` from handle method
- **Standalone Flag**: `self.standalone = true` restricts to show page only

### Custom Admin Action Pattern
- **Fields via Form**: Use modal or separate page with form to collect field data
- **Fields Hash**: Pass fields to action via `fields:` parameter in controller
- **ActionResult**: Return custom result object with `success?`, `message`, `data`
- **Turbo Stream**: Update flash and optionally refresh table/content

## Additional Resources
- [Phase 1 Spec](todos/072-custom-admin-phase-1-artists.md) - Artists implementation reference
- [Admin::Music::ArtistsController Docs](controllers/admin/music/artists_controller.md) - Controller patterns
- [DaisyUI Modal Component](https://daisyui.com/components/modal/) - Modal pattern
- [Pagy Documentation](https://github.com/ddnexus/pagy) - Pagination
- [Hotwire Handbook](https://hotwired.dev/) - Turbo + Stimulus patterns
- [ViewComponent Guide](https://viewcomponent.org/) - Component architecture
