# 062 - Music Category Show Page

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-25
- **Started**: 2025-10-26
- **Completed**: 2025-10-26
- **Developer**: AI Agent

## Overview
Implement a show page for Music::Category that displays the top ranked artists and albums associated with that category. Categories are currently displayed as non-clickable badges on album and artist show pages and index pages. This feature will make those badges clickable and provide dedicated pages for browsing music by category (genre, location, or subject).

**Note**: Songs are not currently populating categories, so this implementation focuses only on artists and albums.

## Context

### Why is this needed?
- Categories are already widely displayed throughout the music site but currently serve no navigation purpose
- Users have no way to browse all albums/artists within a specific genre or category
- SEO opportunity - category pages can rank for genre-specific searches (e.g., "best progressive rock albums")
- Completes the information architecture for music discovery

### What problem does it solve?
- Enables category-based navigation and discovery
- Provides context about what type of category is being viewed (genre vs location vs subject)
- Allows users to explore all ranked content within a category
- Creates SEO-optimized landing pages for category-specific searches

### How does it fit into the larger system?
- Uses existing Category and Music::Category models (STI pattern)
- Leverages existing RankedItem and RankingConfiguration infrastructure
- Follows same patterns as other show pages (artists and albums)
- Integrates with existing pagination and SEO patterns

## Requirements

### Functional Requirements
- [ ] Create Music::CategoriesController with show action
- [ ] Create routes for category show pages with optional ranking configuration
- [ ] Make category badges clickable on existing views (album show, artist show, album/artist ranked index pages)
- [ ] Display category metadata (name, type, description if exists)
- [ ] Show top 10 ranked artists for the category
- [ ] Show top 100 ranked albums for the category
- [ ] Sort both artists and albums by rank (ASC)
- [ ] Implement independent pagination for artists and albums using Turbo Frames
- [ ] Add SEO metadata (page title, meta description)
- [ ] Support ranking configuration namespacing (default to default_primary)
- [ ] Handle categories with no ranked items gracefully

### Technical Requirements
- [ ] Use FriendlyId slug for URLs (category already has slug support)
- [ ] Use Pagy for pagination
- [ ] Implement Turbo Frames for independent artist/album pagination
- [ ] Follow existing controller patterns for loading ranking configurations
- [ ] Use eager loading to prevent N+1 queries
- [ ] Add comprehensive controller tests
- [ ] Follow Music domain namespacing conventions
- [ ] Add helper methods for category links with ranking configuration support

### UI/UX Requirements
- [ ] Display category type badge (Genre/Location/Subject)
- [ ] Use card-based layout for artists (with images)
- [ ] Use card-based layout for albums (with cover art)
- [ ] Show "Top Artists" and "Top Albums" sections with clear headers
- [ ] Paginate artists separately from albums
- [ ] Show artist count and album count if available
- [ ] Use Music domain layout and styling (DaisyUI)
- [ ] Make page responsive (mobile, tablet, desktop)

## Technical Approach

### 1. Routes
Add to `config/routes.rb` within Music domain scope:

```ruby
# Within existing scope "(/rc/:ranking_configuration_id)" do
  get "categories/:id", to: "music/categories#show", as: :music_category
# end
```

### 2. Controller Structure
Create `app/controllers/music/categories_controller.rb`:

```ruby
class Music::CategoriesController < ApplicationController
  layout "music/application"

  before_action :load_artist_ranking_configuration, only: [:show]
  before_action :load_album_ranking_configuration, only: [:show]

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    # Load top 10 artists (with pagination in Turbo Frame)
    @artists_query = build_ranked_artists_query
    @pagy_artists, @artists = pagy(@artists_query, limit: 10, page_param: :artists_page)

    # Load top 100 albums (with pagination in Turbo Frame)
    @albums_query = build_ranked_albums_query
    @pagy_albums, @albums = pagy(@albums_query, limit: 100, page_param: :albums_page)
  end

  private

  def load_artist_ranking_configuration
    load_ranking_configuration(
      config_class: Music::Artists::RankingConfiguration,
      instance_var: :@artist_rc
    )
  end

  def load_album_ranking_configuration
    load_ranking_configuration(
      config_class: Music::Albums::RankingConfiguration,
      instance_var: :@album_rc
    )
  end

  def build_ranked_artists_query
    # Join category_items -> artists -> ranked_items
    # Filter by category and ranking configuration
    # Order by rank ASC
    # Include associations for display
  end

  def build_ranked_albums_query
    # Join category_items -> albums -> ranked_items
    # Filter by category and ranking configuration
    # Order by rank ASC
    # Include associations for display
  end
end
```

### 3. View Structure
Create `app/views/music/categories/show.html.erb`:

- SEO metadata at top (content_for :page_title, :meta_description)
- Category header with type badge
- Two main sections:
  - Top Artists (Turbo Frame with id="category_artists")
  - Top Albums (Turbo Frame with id="category_albums")
- Each section has its own pagination within Turbo Frame
- Use grid layout for cards (responsive)

### 4. Turbo Frame Implementation
Each section wraps content in a Turbo Frame:

```erb
<%= turbo_frame_tag "category_artists" do %>
  <!-- Artist cards grid -->
  <%= pagy_nav(@pagy_artists) if @pagy_artists.pages > 1 %>
<% end %>

<%= turbo_frame_tag "category_albums" do %>
  <!-- Album cards grid -->
  <%= pagy_nav(@pagy_albums) if @pagy_albums.pages > 1 %>
<% end %>
```

### 5. Update Existing Views
Make category badges clickable in:

- `app/views/music/albums/show.html.erb` (lines 67-75)
- `app/views/music/artists/show.html.erb` (lines 83-91)
- `app/views/music/albums/ranked_items/index.html.erb` (lines 52-54)
- `app/views/music/artists/ranked_items/index.html.erb` (lines 51-53)

**Note**: Song views are excluded because songs don't currently populate categories.

Replace `<span class="badge...">` with `<%= link_to_category(category, @ranking_configuration) %>`

### 6. Helper Methods
Add to `app/helpers/music/default_helper.rb`:

```ruby
def music_category_path_with_rc(category, ranking_configuration = nil)
  if ranking_configuration && !ranking_configuration.default_primary?
    music_category_path(category, ranking_configuration_id: ranking_configuration.id)
  else
    music_category_path(category)
  end
end

def link_to_category(category, ranking_configuration = nil, **options)
  path = music_category_path_with_rc(category, ranking_configuration)
  css_classes = options[:class] || "badge badge-lg badge-ghost hover:badge-primary transition-colors"
  link_to category.name, path, class: css_classes, **options.except(:class)
end
```

### 7. SEO Strategy
- Page title: "{Category Name} - {Type} | The Greatest Music"
- Meta description: "Explore the greatest {category_type} music in {category_name}. Top ranked albums and artists..."
- Use category description if available
- Include item counts in description

### 8. Ranking Configuration Strategy
**Critical constraint**: Cannot support multiple ranking configurations because page shows both artists AND albums.

**Solution**:
- Always use the default primary ranking configurations
- Do NOT accept ranking_configuration_id from params
- Load both default configs:
  - `Music::Artists::RankingConfiguration.default_primary`
  - `Music::Albums::RankingConfiguration.default_primary`
- Links from category page use default configs
- If user arrives with RC param, ignore it and redirect to canonical URL

## Dependencies

### Existing Code
- `Category` and `Music::Category` models (already exist)
- `CategoryItem` join model (already exists)
- `RankedItem` and `RankingConfiguration` models (already exist)
- Pagy gem (already installed and configured)
- Turbo Rails (already in use)
- FriendlyId (already configured on Category)
- Music domain layout and styles (already exist)

### External Services
- None

### New Gems
- None

## Acceptance Criteria

### User Experience
- [ ] User can click on a category badge from any album/artist/song page
- [ ] User is taken to category show page at `/categories/{slug}`
- [ ] Page clearly indicates category type (Genre, Location, or Subject)
- [ ] User can see top 10 artists in that category
- [ ] User can see top 100 albums in that category
- [ ] User can page through artists independently of albums
- [ ] User can page through albums independently of artists
- [ ] Artists and albums are sorted by rank (best first)
- [ ] Clicking on artist/album navigates to their respective show pages
- [ ] Category page works on mobile, tablet, and desktop

### Technical
- [ ] Page uses FriendlyId slug in URL (e.g., `/categories/progressive-rock`)
- [ ] Page handles non-existent categories with 404
- [ ] Page handles soft-deleted categories with 404
- [ ] Both artist and album queries are optimized (no N+1)
- [ ] Pagination uses Turbo Frames for seamless UX
- [ ] Each turbo frame updates independently
- [ ] Page has proper SEO metadata
- [ ] All routes follow Music domain conventions
- [ ] All tests pass with 100% coverage

### Performance
- [ ] Initial page load < 500ms
- [ ] Artist pagination < 200ms
- [ ] Album pagination < 200ms
- [ ] Total queries per request < 10
- [ ] No N+1 query warnings in logs

### SEO
- [ ] Page title includes category name and type
- [ ] Meta description includes category information
- [ ] URLs are human-readable (slugs)
- [ ] Category pages are indexable by search engines
- [ ] Canonical URLs are used

## Design Decisions

### Ranking Configuration Approach
**Decision**: Always use default primary ranking configurations for both artists and albums.

**Rationale**:
- Category page displays both artists AND albums
- Different item types may have different ranking configurations
- Supporting arbitrary RC combinations would be complex and confusing
- Users expect "the canonical best" when browsing categories
- Keeps URLs clean and cacheable

**Alternative considered**:
- Accept RC param but only apply to one item type (rejected - confusing UX)
- Support separate RC params for artists and albums (rejected - too complex)

### Pagination Limits
**Decision**: Top 10 artists, top 100 albums

**Rationale**:
- Artists are more visual and take more space (cards with images)
- Albums follow existing pattern (100 per page on album rankings)
- Categories with few items won't feel empty with 10 artist limit
- Most users interested in top items, not exhaustive list

**Alternative considered**:
- Same limit for both (rejected - different use cases)
- 25 artists / 200 albums (rejected - too many artists for card layout)

### Turbo Frame Strategy
**Decision**: Two independent Turbo Frames (one for artists, one for albums)

**Rationale**:
- Allows paging artists without reloading albums and vice versa
- Better UX - only updates relevant section
- Follows progressive enhancement - works without JS
- Uses separate page params (artists_page, albums_page)

**Alternative considered**:
- Single page with both sections reloading (rejected - poor UX)
- Infinite scroll (rejected - adds complexity, accessibility issues)

### Category Type Display
**Decision**: Show category type as prominent badge

**Rationale**:
- Users need to understand context (is this a genre, location, or subject?)
- Category types have different semantic meanings
- Helps with SEO (search intent differs by type)
- Aligns with how categories are grouped on show pages

### Link Behavior
**Decision**: Category links always go to default ranking configuration

**Rationale**:
- Simplifies mental model for users
- Category is "the source of truth" for that category's best items
- Avoids confusion about which RC applies to which item type
- Maintains URL cleanliness

---

## Implementation Notes - Phase 1 (Initial Implementation)

### Approach Taken (Phase 1)
Initial implementation created a single category show page at `/categories/:id` with Turbo Frames for independent pagination of artists and albums.

### Key Files Created/Changed (Phase 1)
**Created:**
- `app/controllers/music/categories_controller.rb` - Controller with show action
- `app/views/music/categories/show.html.erb` - View with Turbo Frames
- `app/helpers/music/default_helper.rb` - Added `music_category_path_with_rc` and `link_to_category` helpers
- `app/components/music/albums/ranked_card_component.rb` - Reusable album card component
- `app/components/music/albums/ranked_card_component/ranked_card_component.html.erb` - Component template
- `test/controllers/music/categories_controller_test.rb` - 12 comprehensive tests
- `test/components/music/albums/ranked_card_component_test.rb` - Component tests

**Modified:**
- `config/routes.rb` - Added `/categories/:id` route outside RC scope
- `app/views/music/albums/show.html.erb` - Made category badges clickable
- `app/views/music/artists/show.html.erb` - Made category badges clickable
- `app/views/music/songs/show.html.erb` - Made category badges clickable
- `app/views/music/albums/ranked_items/index.html.erb` - Updated to use RankedCardComponent
- `app/views/music/artists/ranked_items/index.html.erb` - Made category badges clickable
- `app/views/music/songs/ranked_items/index.html.erb` - Made category badges clickable

### Challenges Encountered (Phase 1)
1. **Nested links bug**: Initially made category badges clickable inside album cards, creating invalid nested links
   - **Solution**: Removed clickable category badges from within cards (kept them as plain spans)

2. **Turbo Frame navigation issue**: Links inside Turbo Frames tried to replace only frame content
   - **Solution**: Added `data: { turbo_frame: "_top" }` to break out of frames for full page navigation

3. **Inconsistent UI**: Category page albums looked different from ranked items page
   - **Solution**: Created `Music::Albums::RankedCardComponent` for consistency

### Testing Approach (Phase 1)
- 12 controller tests covering all scenarios (success, pagination, 404s, missing configs)
- All tests passing ✓
- Tests avoid implementation details (no `assigns` usage)

### Performance Considerations (Phase 1)
- Queries join category_items → ranked_items with proper filtering
- Eager loading prevents N+1 queries (`.includes(item: [:categories, :primary_image])`)
- Uses Pagy for efficient pagination

---

## REVISED APPROACH - Phase 2 (In Progress)

### New Strategy
Based on UX feedback, restructuring to use **three separate pages** instead of one:

1. **Main category overview** (`/categories/:slug`)
   - Shows top artists AND albums
   - **No pagination** (fixed limits)
   - Links to dedicated pages at bottom

2. **Artist-specific category page** (`/artists/categories/:slug`)
   - Shows ONLY artists in that category
   - **Normal pagination** (no Turbo Frames)
   - Full browsing experience

3. **Album-specific category page** (`/albums/categories/:slug`)
   - Shows ONLY albums in that category
   - **Normal pagination** (no Turbo Frames)
   - Full browsing experience

### Why This Approach is Better
- **Simpler UX**: One page = one purpose
- **No Turbo Frame complexity**: Standard Rails pagination
- **Better SEO**: Dedicated URLs for "Progressive Rock artists" vs "Progressive Rock albums"
- **Clearer navigation**: Users know exactly what they're browsing
- **Performance**: Overview page loads faster without complex pagination logic

### Implementation Plan (Phase 2)

#### Step 1: Update Main Category Controller
**File**: `app/controllers/music/categories_controller.rb`
- Remove Turbo Frame pagination logic
- Change to fixed limits: Top 10 artists, Top 10 albums
- Simpler queries (no Pagy)

#### Step 2: Create Artist Categories Controller
**New File**: `app/controllers/music/artists/categories_controller.rb`
```ruby
class Music::Artists::CategoriesController < ApplicationController
  include Pagy::Backend
  layout "music/application"

  before_action :load_ranking_configuration

  def self.ranking_configuration_class
    Music::Artists::RankingConfiguration
  end

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    artists_query = build_ranked_artists_query
    @pagy, @artists = pagy(artists_query, limit: 100)
  end

  private

  def build_ranked_artists_query
    return Music::Artist.none unless @ranking_configuration

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Artist'")
      .joins("JOIN music_artists ON music_artists.id = ranked_items.item_id")
      .where(
        item_type: "Music::Artist",
        ranking_configuration_id: @ranking_configuration.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:categories, :primary_image])
      .order(:rank)
  end
end
```

**Key Points:**
- Uses `load_ranking_configuration` from ApplicationController
- Checks `params[:ranking_configuration_id]`, falls back to `default_primary`
- Same pattern as `Music::Albums::RankedItemsController`

#### Step 3: Create Album Categories Controller
**New File**: `app/controllers/music/albums/categories_controller.rb`
```ruby
class Music::Albums::CategoriesController < ApplicationController
  include Pagy::Backend
  layout "music/application"

  before_action :load_ranking_configuration

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    albums_query = build_ranked_albums_query
    @pagy, @albums = pagy(albums_query, limit: 100)
  end

  private

  def build_ranked_albums_query
    return Music::Album.none unless @ranking_configuration

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Album'")
      .joins("JOIN music_albums ON music_albums.id = ranked_items.item_id")
      .where(
        item_type: "Music::Album",
        ranking_configuration_id: @ranking_configuration.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:artists, :categories, :primary_image])
      .order(:rank)
  end
end
```

**Key Points:**
- Uses `load_ranking_configuration` from ApplicationController
- Checks `params[:ranking_configuration_id]`, falls back to `default_primary`
- Same pattern as `Music::Albums::RankedItemsController`

#### Step 4: Update Routes
**File**: `config/routes.rb`
```ruby
# Main category overview (outside RC scope - always uses defaults)
get "categories/:id", to: "music/categories#show", as: :music_category

# Inside RC scope for artist/album category browsing
scope "(/rc/:ranking_configuration_id)" do
  # Artist-specific category browsing (supports RC)
  get "artists/categories/:id", to: "music/artists/categories#show", as: :music_artist_category

  # Album-specific category browsing (supports RC)
  get "albums/categories/:id", to: "music/albums/categories#show", as: :music_album_category
end
```

**URL Examples:**
- `/categories/progressive-rock` - Overview (always default configs)
- `/artists/categories/progressive-rock` - Artists with default config
- `/rc/123/artists/categories/progressive-rock` - Artists with specific config
- `/albums/categories/progressive-rock` - Albums with default config
- `/rc/456/albums/categories/progressive-rock` - Albums with specific config

#### Step 5: Update Main Category View
**File**: `app/views/music/categories/show.html.erb`
- Remove Turbo Frames
- Show top 10 artists (grid, no pagination)
- Show top 10 albums (grid, no pagination)
- Add links at bottom:
  - "See all #{@category.name} artists →" (links to artists/categories/:slug)
  - "See all #{@category.name} albums →" (links to albums/categories/:slug)

#### Step 6: Create Artist Category View
**New File**: `app/views/music/artists/categories/show.html.erb`
- Page title: "#{@category.name} Artists"
- Grid of all ranked artists in category
- Standard Pagy pagination at bottom
- Link back to main category page

#### Step 7: Create Album Category View
**New File**: `app/views/music/albums/categories/show.html.erb`
- Page title: "#{@category.name} Albums"
- Grid of all ranked albums in category (using RankedCardComponent)
- Standard Pagy pagination at bottom
- Link back to main category page

#### Step 8: Update Helpers
**File**: `app/helpers/music/default_helper.rb`
```ruby
# Artist category path with optional RC
def music_artist_category_path_with_rc(category, ranking_configuration = nil)
  if ranking_configuration && !ranking_configuration.default_primary?
    music_artist_category_path(category, ranking_configuration_id: ranking_configuration.id)
  else
    music_artist_category_path(category)
  end
end

# Album category path with optional RC
def music_album_category_path_with_rc(category, ranking_configuration = nil)
  if ranking_configuration && !ranking_configuration.default_primary?
    music_album_category_path(category, ranking_configuration_id: ranking_configuration.id)
  else
    music_album_category_path(category)
  end
end

# Main category path (always no RC - always uses defaults)
def music_category_path_with_rc(category, ranking_configuration = nil)
  music_category_path(category)
end

# Link to main category overview (from badges)
def link_to_category(category, ranking_configuration = nil, **options, &block)
  path = music_category_path_with_rc(category, ranking_configuration)
  if block_given?
    link_to path, **options, &block
  else
    link_to category.name, path, **options
  end
end
```

#### Step 9: Comprehensive Testing
- Update existing `music/categories_controller_test.rb`
- Create `music/artists/categories_controller_test.rb`
- Create `music/albums/categories_controller_test.rb`
- Test all pagination, 404s, empty states

#### Step 10: Update Category Badges
Decision: Keep show page badges clickable → link to main category overview page

### SEO Benefits
- `/categories/progressive-rock` - "Progressive Rock Music - Genre" (overview)
- `/artists/categories/progressive-rock` - "Progressive Rock Artists" (default ranking)
- `/rc/123/artists/categories/progressive-rock` - "Progressive Rock Artists" (custom ranking)
- `/albums/categories/progressive-rock` - "Progressive Rock Albums" (default ranking)
- `/rc/456/albums/categories/progressive-rock` - "Progressive Rock Albums" (custom ranking)

Each page targets different search intent. Default pages (no RC) are canonical URLs for SEO.

### Acceptance Criteria (Updated)
- [ ] Main category page shows top 10 artists and top 10 albums (always uses default configs)
- [ ] Main category page has "See all" links at bottom
- [ ] Artist category page shows all ranked artists with pagination
- [ ] Artist category page supports ranking configuration parameter
- [ ] Album category page shows all ranked albums with pagination
- [ ] Album category page supports ranking configuration parameter
- [ ] Ranking configuration falls back to default_primary when not specified
- [ ] All pages use FriendlyId slugs
- [ ] All pages have proper SEO metadata
- [ ] All tests pass with 100% coverage
- [ ] No Turbo Frame issues
- [ ] Clean, simple UX
- [ ] RC switching works correctly (URLs update, queries use correct RC)

### Next Steps
1. Refactor existing Music::CategoriesController (remove pagination)
2. Create Music::Artists::CategoriesController
3. Create Music::Albums::CategoriesController
4. Update routes
5. Update views
6. Write tests
7. Verify everything works end-to-end
