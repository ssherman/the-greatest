# 062 - Music Category Show Page

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-10-25
- **Started**:
- **Completed**:
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

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken

### Key Files Changed

### Challenges Encountered

### Deviations from Plan

### Code Examples

### Testing Approach

### Performance Considerations

### Future Improvements

### Lessons Learned

### Related PRs

### Documentation Updated
- [ ] Class documentation files updated
- [ ] API documentation updated (if applicable)
- [ ] README updated (if needed)
