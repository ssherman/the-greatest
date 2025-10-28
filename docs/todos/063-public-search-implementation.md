# 063 - Public Search Implementation

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-10-26
- **Started**:
- **Completed**:
- **Developer**: AI Assistant

## Overview
Implement a public-facing search feature that allows users to search across artists, albums, and songs simultaneously from a top-level search input in the header. The search should leverage the existing OpenSearch infrastructure and return combined, relevant results across all three music model types.

## Context
- OpenSearch integration is already complete with search classes for artists, albums, and songs (todos 014, 024)
- All music models are indexed with searchable fields (names, titles, artist names, category IDs)
- Background indexing is functional via Sidekiq jobs
- No public search UI or endpoints currently exist
- Users currently cannot search the music catalog from the front end
- The existing search infrastructure returns arrays of hashes with id, score, and source keys

## Requirements

### Backend
- [ ] Create `Music::SearchesController` to handle search requests
- [ ] Implement unified search method that queries all three model types (artists, albums, songs)
- [ ] Limit results to 25 per type (no pagination)
- [ ] Determine highest relevance score across all results
- [ ] Order result sections by highest scoring type first
- [ ] Handle empty/blank search queries gracefully
- [ ] Add appropriate database eager loading to prevent N+1 queries

### Frontend UI
- [ ] Add simple search form to navbar-end section of music layout
- [ ] Create responsive search input that works on mobile and desktop
- [ ] Add search icon/button to submit form
- [ ] Display "no results" message when search returns empty

### Search Results Page
- [ ] Create search results view at `/search?q=query`
- [ ] Display results grouped by type (Artists, Albums, Songs)
- [ ] Order sections by highest relevance score (e.g., if top song score > top album/artist, show Songs first)
- [ ] Show result count per type
- [ ] Include relevant metadata for each result (images, artist names, years, categories)
- [ ] Link results to their respective show pages
- [ ] Show up to 25 results per type

### ViewComponent
- [ ] Create `Music::Search::EmptyStateComponent` for no results message using generator
- [ ] Rename `Music::Albums::RankedCardComponent` to `Music::Albums::CardComponent`
- [ ] Modify `Music::Albums::CardComponent` to support optional rank (accept `album:` OR `ranked_item:`)
- [ ] Update all existing usages of `Music::Albums::RankedCardComponent` to use new name
- [ ] Create `Music::Artists::CardComponent` for artist cards (with optional rank support) using generator
- [ ] Create `Music::Songs::ListItemComponent` for song table rows (with optional rank support) using generator
- [ ] Refactor existing views to use new components (artist index, song index)

**Generator Commands:**
```bash
cd web-app
bin/rails generate view_component:component Music::Search::EmptyState message --sidecar
bin/rails generate view_component:component Music::Artists::Card artist --sidecar
bin/rails generate view_component:component Music::Songs::ListItem song --sidecar
```

**Note:** All components are namespaced under `Music::` to maintain domain-driven design consistency. Use `--sidecar` to place templates in component subdirectories (standard practice).

**Reference:** See `docs/view-components.md` for ViewComponent conventions and best practices

## Technical Approach

### Search Controller Architecture

**Location**: `web-app/app/controllers/music/searches_controller.rb`

```ruby
class Music::SearchesController < ApplicationController
  layout "music/application"

  def index
    @query = params[:q]

    if @query.blank?
      @artists = []
      @albums = []
      @songs = []
      @ordered_sections = []
      return
    end

    # Execute searches (25 results per type)
    @artist_results = Search::Music::Search::ArtistGeneral.call(@query, size: 25)
    @album_results = Search::Music::Search::AlbumGeneral.call(@query, size: 25)
    @song_results = Search::Music::Search::SongGeneral.call(@query, size: 25)

    # Convert results to ActiveRecord objects with eager loading
    @artists = load_artists(@artist_results)
    @albums = load_albums(@album_results)
    @songs = load_songs(@song_results)

    # Track total counts
    @total_count = @artists.size + @albums.size + @songs.size

    # Determine section order by highest relevance score
    @ordered_sections = determine_section_order
  end

  private

  def determine_section_order
    # Get highest score from each type
    sections = []

    sections << { type: :artists, score: @artist_results.first&.dig(:score) || 0 } if @artists.any?
    sections << { type: :albums, score: @album_results.first&.dig(:score) || 0 } if @albums.any?
    sections << { type: :songs, score: @song_results.first&.dig(:score) || 0 } if @songs.any?

    # Sort by score descending
    sections.sort_by { |s| -s[:score] }.map { |s| s[:type] }
  end

  def load_artists(results)
    return [] if results.empty?
    ids = results.map { |r| r[:id] }
    Music::Artist.where(id: ids)
      .includes(:categories, :primary_image)
      .index_by(&:id)
      .slice(*ids)
      .values
  end

  def load_albums(results)
    return [] if results.empty?
    ids = results.map { |r| r[:id] }
    Music::Album.where(id: ids)
      .includes(:artists, :categories, :primary_image)
      .index_by(&:id)
      .slice(*ids)
      .values
  end

  def load_songs(results)
    return [] if results.empty?
    ids = results.map { |r| r[:id] }
    Music::Song.where(id: ids)
      .includes(:artists, :categories)
      .index_by(&:id)
      .slice(*ids)
      .values
  end
end
```

**Key decisions**:
- Use `.call()` method on existing search classes with `size: 25`
- Convert OpenSearch results to ActiveRecord objects for view rendering
- Preserve order from OpenSearch results (sorted by relevance)
- Use `index_by(&:id).slice(*ids).values` pattern to maintain search order
- Eager load associations to prevent N+1 queries
- Determine section order by comparing highest score from each type
- `@ordered_sections` array determines which section to show first in view

### Route Configuration

**Location**: `web-app/config/routes.rb`

Add to music domain routes section:
```ruby
scope module: :music, domain: music_domain do
  # ... existing routes

  get "/search", to: "searches#index", as: :search
end
```

### Layout Modification

**Location**: `web-app/app/views/layouts/music/application.html.erb`

Modify `navbar-end` section (currently line 50-53):
```erb
<div class="navbar-end">
  <!-- Search Form -->
  <div class="form-control mr-4">
    <%= form_with url: search_path, method: :get, local: true, class: "flex" do |f| %>
      <%= f.search_field :q,
          value: params[:q],
          placeholder: "Search music...",
          class: "input input-bordered w-64",
          autocomplete: "off" %>
      <%= button_tag type: "submit", class: "btn btn-square btn-ghost" do %>
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
        </svg>
      <% end %>
    <% end %>
  </div>

  <!-- Login Button -->
  <button class="btn btn-primary" onclick="login_modal.showModal()">Login</button>
</div>
```

**Mobile responsive variant**:
- On small screens, reduce input width or collapse to icon-only
- Can also add search link to mobile dropdown menu

### Search Results View

**Location**: `web-app/app/views/music/searches/index.html.erb`

```erb
<div class="container mx-auto px-4 py-8">
  <div class="mb-8">
    <h1 class="text-4xl font-bold text-base-content mb-2">
      Search Results
      <% if @query.present? %>
        for "<%= @query %>"
      <% end %>
    </h1>
    <% if @total_count > 0 %>
      <p class="text-base-content/70">
        Found <%= pluralize(@total_count, "result") %>
      </p>
    <% end %>
  </div>

  <% if @query.blank? %>
    <%= render Music::Search::EmptyStateComponent.new(message: "Enter a search term to find artists, albums, and songs") %>

  <% elsif @total_count == 0 %>
    <%= render Music::Search::EmptyStateComponent.new(message: "No results found for \"#{@query}\"") %>

  <% else %>
    <!-- Display sections in order of highest relevance -->
    <% @ordered_sections.each do |section_type| %>
      <% case section_type %>
      <% when :artists %>
        <% if @artists.any? %>
          <section class="mb-12">
            <h2 class="text-2xl font-bold text-base-content mb-4 flex items-center">
              Artists
              <span class="badge badge-ghost badge-lg ml-2"><%= @artists.size %></span>
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <% @artists.each do |artist| %>
                <%= render Music::Artists::CardComponent.new(artist: artist) %>
              <% end %>
            </div>
          </section>
        <% end %>

      <% when :albums %>
        <% if @albums.any? %>
          <section class="mb-12">
            <h2 class="text-2xl font-bold text-base-content mb-4 flex items-center">
              Albums
              <span class="badge badge-ghost badge-lg ml-2"><%= @albums.size %></span>
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
              <% @albums.each do |album| %>
                <%= render Music::Albums::CardComponent.new(album: album) %>
              <% end %>
            </div>
          </section>
        <% end %>

      <% when :songs %>
        <% if @songs.any? %>
          <section class="mb-12">
            <h2 class="text-2xl font-bold text-base-content mb-4 flex items-center">
              Songs
              <span class="badge badge-ghost badge-lg ml-2"><%= @songs.size %></span>
            </h2>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body p-0">
                <div class="overflow-x-auto">
                  <table class="table">
                    <thead>
                      <tr>
                        <th>Song</th>
                        <th class="hidden lg:table-cell">Year</th>
                        <th class="hidden lg:table-cell">Genres</th>
                      </tr>
                    </thead>
                    <tbody>
                      <% @songs.each do |song| %>
                        <%= render Music::Songs::ListItemComponent.new(song: song) %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </section>
        <% end %>
      <% end %>
    <% end %>
  <% end %>
</div>
```

### ViewComponents

**Note:** Use Rails generators to create all ViewComponents. See `docs/view-components.md` for conventions.

**Empty State Component**:
```ruby
# web-app/app/components/music/search/empty_state_component.rb
module Music
  module Search
    class EmptyStateComponent < ViewComponent::Base
      def initialize(message:)
        @message = message
      end

      private

      attr_reader :message
    end
  end
end
```

```erb
<!-- web-app/app/components/music/search/empty_state_component/empty_state_component.html.erb (sidecar) -->
<div class="text-center py-16">
  <div class="text-6xl mb-4">🔍</div>
  <p class="text-xl text-base-content/70">
    <%= message %>
  </p>
</div>
```

**Sidecar Structure:**
```
app/components/music/search/
├── empty_state_component.rb
└── empty_state_component/
    └── empty_state_component.html.erb
```

**Artist Card Component**:
```ruby
# web-app/app/components/music/artists/card_component.rb
module Music
  module Artists
    class CardComponent < ViewComponent::Base
      include Music::DefaultHelper

      def initialize(artist:, ranked_item: nil, ranking_configuration: nil)
        @artist = artist
        @ranked_item = ranked_item
        @ranking_configuration = ranking_configuration
      end

      private

      attr_reader :artist, :ranked_item, :ranking_configuration

      def show_rank?
        ranked_item.present?
      end
    end
  end
end
```

Usage in search: `<%= render Music::Artists::CardComponent.new(artist: artist) %>`
Usage in rankings: `<%= render Music::Artists::CardComponent.new(artist: ranked_item.item, ranked_item: ranked_item) %>`

**Album Card Component** (renamed from RankedCardComponent):
```ruby
# web-app/app/components/music/albums/card_component.rb
module Music
  module Albums
    class CardComponent < ViewComponent::Base
      include Music::DefaultHelper

      def initialize(album: nil, ranked_item: nil, ranking_configuration: nil)
        if album.nil? && ranked_item.nil?
          raise ArgumentError, "Must provide either album: or ranked_item:"
        end

        @album = album
        @ranked_item = ranked_item
        @ranking_configuration = ranking_configuration
      end

      private

      attr_reader :album, :ranked_item, :ranking_configuration

      def show_rank?
        ranked_item.present?
      end

      def item_album
        @item_album ||= album || ranked_item.item
      end
    end
  end
end
```

**Files to rename:**
- `app/components/music/albums/ranked_card_component.rb` → `card_component.rb`
- `app/components/music/albums/ranked_card_component/` → `card_component/`
- Template directory and file

**Existing usages to update:**
- `app/views/music/albums/ranked_items/index.html.erb`
- `app/views/music/categories/show.html.erb`
- `app/views/music/albums/categories/show.html.erb`

Usage in search: `<%= render Music::Albums::CardComponent.new(album: album) %>`
Usage in rankings: `<%= render Music::Albums::CardComponent.new(ranked_item: ranked_item, ranking_configuration: @ranking_configuration) %>`

**Song List Item Component**:
```ruby
# web-app/app/components/music/songs/list_item_component.rb
module Music
  module Songs
    class ListItemComponent < ViewComponent::Base
      include Music::DefaultHelper

      def initialize(song:, ranked_item: nil, ranking_configuration: nil, show_index: nil)
        @song = song
        @ranked_item = ranked_item
        @ranking_configuration = ranking_configuration
        @show_index = show_index
      end

      private

      attr_reader :song, :ranked_item, :ranking_configuration, :show_index

      def show_rank?
        ranked_item.present?
      end
    end
  end
end
```

Template renders a table row `<tr>` with conditional rank badge or index number.

Usage in search: `<%= render Music::Songs::ListItemComponent.new(song: song) %>`
Usage in rankings: `<%= render Music::Songs::ListItemComponent.new(song: ranked_item.item, ranked_item: ranked_item, ranking_configuration: @ranking_configuration) %>`

## Dependencies
- Existing OpenSearch integration (todos 014, 024) - ✅ Complete
- Search classes: `Search::Music::Search::ArtistGeneral`, `AlbumGeneral`, `SongGeneral` - ✅ Complete
- Music models with `as_indexed_json` methods - ✅ Complete
- Background indexing via `SearchIndexable` concern - ✅ Complete
- DaisyUI CSS framework - ✅ Already in use
- ViewComponent gem - ✅ Already in use

## Acceptance Criteria

### Search Functionality
- [ ] Search input visible in music domain header on desktop and mobile
- [ ] Submitting search form navigates to `/search?q=query` with results
- [ ] Results display artists, albums, and songs in separate sections
- [ ] Sections ordered by highest relevance score (highest scoring type appears first)
- [ ] Maximum 25 results shown per type
- [ ] Result counts shown for each section
- [ ] Empty search query shows helpful message
- [ ] No results shows helpful message with query
- [ ] All results link to their respective show pages
- [ ] Search preserves relevance ordering from OpenSearch within each section
- [ ] No N+1 queries when loading results
- [ ] Mobile responsive search UI

### ViewComponent Refactoring
- [ ] `Music::Albums::RankedCardComponent` renamed to `Music::Albums::CardComponent`
- [ ] All existing usages updated to use new component name
- [ ] `Music::Albums::CardComponent` works with or without rank
- [ ] `Music::Artists::CardComponent` created and works with or without rank
- [ ] `Music::Songs::ListItemComponent` created and works with or without rank
- [ ] `Music::Search::EmptyStateComponent` created for no results/empty states
- [ ] Artist index page refactored to use new component
- [ ] Song index page refactored to use new component
- [ ] Search results page uses all four components
- [ ] All existing ranked album views still work correctly after rename
- [ ] All components properly namespaced under `Music::`

## Design Decisions
- **Multi-search approach**: Execute separate searches for each model type rather than a unified index
  - Rationale: Easier to maintain separate indexes, allows different boost values per type
  - Tradeoff: Three queries instead of one, but should be fast enough with OpenSearch

- **Simple form submission**: Standard form POST without JavaScript interactivity
  - Rationale: Simpler implementation, no debouncing or auto-submit complexity
  - User explicitly submits search via button or Enter key

- **Dynamic section ordering**: Order sections by highest relevance score
  - Rationale: Most relevant type appears first, improving discoverability
  - Implementation: Compare first result score from each type, sort sections accordingly

- **Result ordering preservation**: Use `index_by(&:id).slice(*ids).values` pattern
  - Rationale: ActiveRecord `where(id:)` doesn't preserve order, must manually reorder
  - Reference: Common Rails pattern for preserving custom sort order

- **Grouped results display**: Show artists, albums, songs in separate sections
  - Rationale: Clearer UX than mixed results
  - Alternative considered: Combined list sorted by score (rejected for clarity)

- **No pagination initially**: Fixed limit of 25 results per type
  - Rationale: Simpler implementation, sufficient for most searches
  - Users can refine query if not finding what they need
  - Future enhancement: Can add pagination if needed

- **No autocomplete initially**: Start with full search results page
  - Rationale: Simpler implementation, can add autocomplete dropdown later
  - Future enhancement: Dropdown with top 5 results per type

- **Smart ViewComponents with optional rank**: Make components flexible for both ranked and unranked contexts
  - Rationale: Single component can be used in search results, index pages, and ranked pages
  - Reduces code duplication across the application
  - Components accept either direct model (`artist:`, `album:`, `song:`) or `ranked_item:` parameter
  - Template conditionally displays rank badge when `ranked_item` is present
  - Allows future refactoring of existing index/show pages to use same components

- **Rename `RankedCardComponent` to `CardComponent`**: Remove "Ranked" from name since component works for both contexts
  - Rationale: Name should reflect general purpose, not specific use case
  - "CardComponent" is more intuitive and consistent with other components
  - Implementation supports both ranked and unranked via optional parameters
  - Breaking change: Requires updating 3 existing view files

- **ViewComponent architecture**: Create reusable result components
  - Rationale: Consistent with existing codebase patterns
  - Allows easy styling and maintenance
  - Refactor existing inline markup to use components (reduces duplication)

## Future Enhancements
- Real-time autocomplete dropdown with top results
- Pagination for results (if 25 per type isn't sufficient)
- Filters by category, year, etc.
- Search history for logged-in users
- Search analytics and trending searches
- Query suggestions ("Did you mean...?")
- Advanced search with boolean operators
- Search within specific sections (artists only, albums only, etc.)
- Keyboard shortcuts to focus search input (/ key)
- Recently viewed items in search
- Highlight matching terms in results
- Share search results via URL
- Search performance monitoring
- Debounced auto-submit as user types

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken

### Key Files Changed

### Challenges Encountered

### Deviations from Plan

### Code Examples

### Testing Approach

### Performance Considerations

### Lessons Learned

### Related PRs

### Documentation Updated
