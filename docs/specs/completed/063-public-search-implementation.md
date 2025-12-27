# 063 - Public Search Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-26
- **Started**: 2025-10-28
- **Completed**: 2025-10-28
- **Developer**: AI Assistant (Claude)

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

### Approach Taken

Implemented the public search feature by manually creating the controller (should have used generator), view, and ViewComponents. The implementation follows the planned approach with a few simplifications.

**Controller Creation:**
- Created `Music::SearchesController` manually (⚠️ mistake - should have used generator)
- Implemented `index` action with search logic
- Created private methods to load and convert search results

**ViewComponent Creation:**
- Generated three new components using `rails generate component`:
  - `Music::Search::EmptyStateComponent`
  - `Music::Artists::CardComponent`
  - `Music::Songs::ListItemComponent`
- Renamed existing `Music::Albums::RankedCardComponent` to `CardComponent`
- Updated all components to support optional rank parameter

**View Implementation:**
- Created search results view with grouped sections
- Added search form to navbar in music layout
- Used ViewComponents for consistent rendering

### Key Files Changed

**New Files:**
- `app/controllers/music/searches_controller.rb` - Search controller
- `app/views/music/searches/index.html.erb` - Search results view
- `app/components/music/search/empty_state_component.rb` + template
- `app/components/music/artists/card_component.rb` + template
- `app/components/music/songs/list_item_component.rb` + template
- `test/controllers/music/searches_controller_test.rb` - Controller tests
- `docs/controllers/music/searches_controller.md` - Controller documentation

**Modified Files:**
- `config/routes.rb` - Added search route
- `app/views/layouts/music/application.html.erb` - Added search form to navbar
- `app/components/music/albums/ranked_card_component.rb` → `card_component.rb` (renamed)
- `app/views/music/albums/ranked_items/index.html.erb` - Updated to use renamed component
- `app/views/music/artists/ranked_items/index.html.erb` - Refactored to use new component
- `app/views/music/songs/ranked_items/index.html.erb` - Refactored to use new component + removed genres column
- `app/lib/search/music/search/artist_general.rb` - Changed match operator to "and"
- `app/lib/search/music/search/album_general.rb` - Changed match operator to "and"
- `app/lib/search/music/search/song_general.rb` - Changed match operator to "and"
- `app/javascript/controllers/authentication_controller.js` - Fixed button selector
- `test/controllers/music/default_controller_test.rb` - Simplified HTML tests
- `docs/testing.md` - Added controller testing guidelines
- `docs/dev-core-values.md` - Added generator usage guidelines

### Challenges Encountered

#### 1. Namespace Collision (NameError)
**Problem:** `Music::Search::Music` - Ruby looked for `Music::Search::Music::Search::ArtistGeneral` instead of `Search::Music::Search::ArtistGeneral`

**Solution:** Added leading `::` to all search class references to force root namespace lookup: `::Search::Music::Search::ArtistGeneral`

**Lesson:** Inside a namespaced module, always use `::` prefix for classes outside that namespace.

#### 2. No Search Results Returned
**Problem:** OpenSearch returned results but controller displayed empty arrays

**Solution:** OpenSearch returns string IDs but ActiveRecord expects integers. Added `.to_i` conversion:
```ruby
ids = results.map { |r| r[:id].to_i }.uniq
```

**Lesson:** Always check data types when bridging OpenSearch and ActiveRecord.

#### 3. Turbo Form Submission Breaking Modal
**Problem:** Search form submission caused login modal to randomly appear and created duplicate login buttons

**Solution:** Disabled Turbo for search form with `data: { turbo: false }`

**Reason:** Form submission was interfering with modal state management.

#### 4. Artist Card Layout Broken (Horizontal Instead of Vertical)
**Problem:** Artist cards displayed horizontally (image left, text right) instead of vertically stacked

**Solution:** Changed card structure - made `<div class="card">` the outer wrapper instead of wrapping entire card in a link. Only image and title are links now.

**Lesson:** DaisyUI card structure is sensitive to which element has the `.card` class.

#### 5. Duplicate Login Buttons in Navbar
**Problem:** Search button was displaying "Login" text instead of search icon SVG

**Root Cause:** `authentication_controller.js` used selector `.navbar-end .btn` which matched BOTH the search button and login button, then set textContent on the search button.

**Solution:**
- Changed JavaScript selector from `.navbar-end .btn` to `getElementById('navbar_login_button')`
- Added explicit `id="navbar_login_button"` to login button
- Changed search button from `button_tag` helper to plain HTML `<button>` tag

**Lesson:** CSS selectors in JavaScript must be specific enough to avoid unintended matches.

#### 6. Search Quality Issues - "The Cure" Returning "The Band"
**Problem:** Searching "The Cure" returned "The Band" and "The Zombies" because search used OR logic

**Solution:** Changed OpenSearch match queries from `operator: "or"` (default) to `operator: "and"` in all three search classes

**Lesson:** OpenSearch defaults to OR matching. For phrase searches, require ALL terms with AND operator.

#### 7. Missing Artist from Index
**Problem:** "Depeche Mode" artist existed in database but not returning in search results

**Root Cause:** Artist was missing from OpenSearch index (2070 in DB vs 2069 in index)

**Solution:** Re-indexed the missing artist using `::Search::Music::ArtistIndex.index_item(artist)`

**Lesson:** Always verify data is in search index, not just database.

#### 8. No Tests Created Initially
**Problem:** Manually created controller without using generator, so no test file was created

**Solution:** Manually wrote comprehensive test file with 10 tests

**Lesson:** ⚠️ ALWAYS use Rails generators - they automatically create test files with proper structure.

#### 9. Brittle HTML Tests
**Problem:** Initial tests checked specific CSS classes, heading sizes, and element order - too fragile for UI changes

**Solution:** Simplified tests to only verify:
- No errors/exceptions (`assert_response :success`)
- Controller behavior (correct method parameters)
- No HTML structure testing

**Lesson:** Controller tests should validate behavior, not view implementation. "If a designer could change it, don't test it."

### Deviations from Plan

#### 1. Removed Dynamic Section Ordering
**Original Plan:** Order sections by highest relevance score (e.g., if songs score highest, show songs first)

**Actual Implementation:** Fixed order - Artists → Albums → Songs

**Rationale:** Simpler code, more predictable UX. Users expect consistent section ordering.

**Code Removed:**
- `determine_section_order` method
- `@ordered_sections` logic
- Score comparison between types

#### 2. Reduced Song Result Limit
**Original Plan:** 25 results for all types

**Actual Implementation:** 25 artists, 25 albums, 10 songs

**Rationale:** Songs display in table format taking more vertical space. 10 songs is sufficient without pagination.

#### 3. Removed Genres Column from Song Tables
**Discovered:** Songs don't have genres populated in the database

**Change:** Updated song table headers from "Song / Year / Genres" to "Song / Artist / Year"

**Files Updated:**
- `Music::Songs::ListItemComponent` template
- `app/views/music/songs/ranked_items/index.html.erb`
- `app/views/music/searches/index.html.erb`

#### 4. Did Not Use Generator for Controller
**Plan:** Should have used `rails generate controller Music::Searches index`

**Actual:** Manually created controller file

**Impact:** Had to manually create test file afterward, missing proper generator boilerplate

**Documentation Updated:** Added generator guidelines to `docs/dev-core-values.md` to prevent future mistakes

### Code Examples

**Namespace Resolution:**
```ruby
# ❌ Wrong - causes NameError inside Music module
Search::Music::Search::ArtistGeneral.call(@query, size: 25)

# ✅ Correct - forces root namespace lookup
::Search::Music::Search::ArtistGeneral.call(@query, size: 25)
```

**ID Conversion and Deduplication:**
```ruby
def load_artists(results)
  return [] if results.empty?
  ids = results.map { |r| r[:id].to_i }.uniq  # Convert strings to integers, remove duplicates
  records_by_id = Music::Artist.where(id: ids)
    .includes(:categories, :primary_image)
    .index_by(&:id)
  ids.map { |id| records_by_id[id] }.compact  # Preserve OpenSearch order
end
```

**Turbo Disabling:**
```erb
<%= form_with url: search_path, method: :get, data: { turbo: false }, class: "flex" do |f| %>
  <%# form fields %>
<% end %>
```

**OpenSearch AND Operator:**
```ruby
# Changed in artist_general.rb, album_general.rb, song_general.rb
::Search::Shared::Utils.build_match_query("title", cleaned_text, boost: 8.0, operator: "and")
```

### Testing Approach

**Test File:** `test/controllers/music/searches_controller_test.rb`

**Coverage (10 tests):**
1. Blank query handling
2. Empty query parameter handling
3. No results without error
4. Artist results without error
5. Album results without error
6. Song results without error
7. Mixed results without error
8. Correct size parameters (25/25/10)
9. Special characters in query
10. Duplicate ID handling

**Key Testing Decisions:**
- Mock search classes with Mocha (`stubs(:call).returns(...)`)
- Test controller behavior, not HTML structure
- Only verify HTTP response codes and method parameters
- Avoid brittle tests that break with UI changes

**Additional Testing Documentation:**
- Created `docs/testing.md` with controller testing guidelines
- Added "what NOT to test" section with examples
- Documented the "designer rule": If a designer could change it, don't test it

### Performance Considerations

**N+1 Prevention:**
- Eager load `:categories`, `:primary_image` for artists
- Eager load `:artists`, `:categories`, `:primary_image` for albums
- Eager load `:artists`, `:categories` for songs

**Query Optimization:**
- Three separate OpenSearch queries (sequential, not parallel)
- Limited result sets (25/25/10) to prevent excessive data
- Use `index_by(&:id)` for efficient lookup when preserving order

**Search Quality:**
- Changed to AND operator for better phrase matching
- All words in query must match for result to appear

### Lessons Learned

#### 1. Always Use Generators
**Mistake:** Manually created controller without using `rails generate controller Music::Searches index`

**Impact:**
- No test file created automatically
- Had to manually write tests later
- Missed generator boilerplate and proper setup

**Solution:** Updated `docs/dev-core-values.md` with explicit generator guidelines

**Generators to Always Use:**
- `rails generate controller`
- `rails generate model`
- `rails generate component`
- `rails generate stimulus`
- `rails generate avo:resource`

#### 2. Test Behavior, Not Implementation
**Mistake:** Initial tests verified specific CSS classes, exact text, element order

**Impact:** Tests would break with reasonable UI changes

**Solution:**
- Simplified tests to only verify no errors and correct behavior
- Documented guidelines in `docs/testing.md`
- Fixed existing brittle test in `Music::DefaultControllerTest`

**Rule:** "If a designer could change it without consulting a developer, don't test it"

#### 3. Check Namespace Context
**Mistake:** Used relative class names inside namespaced module causing NameError

**Solution:** Always use `::` prefix for classes outside current namespace

**Pattern:**
```ruby
module Music
  class SearchesController
    # Inside Music module, need :: to escape to root
    ::Search::Music::Search::ArtistGeneral.call(...)
  end
end
```

#### 4. Verify Search Index Completeness
**Mistake:** Assumed all database records were in search index

**Discovery:** One artist missing from index (2070 DB vs 2069 index)

**Solution:** Always verify index counts match database counts, re-index if needed

#### 5. OpenSearch Defaults to OR Matching
**Mistake:** Didn't realize OpenSearch uses OR by default for multi-word queries

**Impact:** "The Cure" matched "The Band" (matched on "The")

**Solution:** Explicitly set `operator: "and"` for phrase searches

#### 6. JavaScript Selector Specificity Matters
**Mistake:** Used `.navbar-end .btn` selector which matched multiple buttons

**Impact:** Modified wrong button's content

**Solution:** Use ID selectors or more specific CSS selectors to avoid collisions

### Related PRs
- Not applicable (direct commits to branch)

### Documentation Updated
- [x] Created `docs/controllers/music/searches_controller.md` - Controller class documentation
- [x] Created `docs/testing.md` - Testing guidelines with controller test best practices
- [x] Updated `docs/dev-core-values.md` - Added generator usage guidelines
- [x] Updated this todo file with complete implementation notes

### Future Improvements
Based on implementation experience:

**Search Quality:**
- Add fuzzy matching for typos
- Implement "Did you mean?" suggestions
- Add autocomplete dropdown with top 5 results

**UI Enhancements:**
- Pagination for large result sets
- Keyboard shortcut (/ key) to focus search
- Highlight matching terms in results
- Show recent searches for logged-in users

**Performance:**
- Consider parallel search execution
- Add result caching for common queries
- Monitor search performance metrics

**Testing:**
- Add integration tests for full search workflow
- Consider adding system tests for UI interactions
- Monitor test coverage (currently at controller level only)
