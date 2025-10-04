# 045 - Music UI Controllers and Album/Song/Artist Show Pages

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2025-10-04
- **Started**: 2025-10-04
- **Completed**: 2025-10-04
- **Developer**: Claude

## Overview
Expand the Music domain UI by adding show pages for Albums, Artists, and Songs, creating a ranked songs index page, improving the music homepage, and implementing SEO optimizations. This will provide users with rich detail pages for browsing music content and improve search engine discoverability.

## Context
- Currently, we have a working `Music::Albums::RankedItemsController` that displays ranked albums with Tailwind/DaisyUI styling
- The Music domain has models for Album, Artist, Song, and RankingConfiguration with proper associations
- Albums can be ranked using RankingConfigurations with `primary` and `global` flags
- The current music homepage (`Music::DefaultController#index`) is empty and needs content
- We use Tailwind CSS and DaisyUI (https://daisyui.com/llms.txt) for all UI components
- Pages need to be responsive for both mobile and desktop
- SEO is important for discoverability

## Requirements
- [x] Create `Music::AlbumsController` with show action
- [x] Create `Music::ArtistsController` with show action
- [x] Generate `Music::Songs::RankedItemsController` for top songs index
- [x] Create `Music::SongsController` with show action
- [x] Update `Music::DefaultController#index` with homepage content
- [x] Add controller tests for all new endpoints (following `docs/testing.md` best practices)
- [x] Implement SEO title and meta description support in layout
- [x] Set custom SEO titles/descriptions for each page
- [x] Use Tailwind + DaisyUI for all UI components
- [x] Ensure mobile and desktop responsive design

## Technical Approach

### Controllers to Create

1. **Music::AlbumsController#show**
   - Display album title, artists, release year, description
   - Show album cover image (if available)
   - Display categories grouped by type
   - Show all tracks/songs on the album
   - List all lists this album appears on
   - Route: `/albums/:id` (scoped to music domain)

2. **Music::ArtistsController#show**
   - Display artist name, description, metadata (born_on, country, year_formed, etc.)
   - Show artist image (if available)
   - Display categories grouped by type
   - Section for "Greatest Albums" (using primary RankingConfiguration)
   - Section for "Greatest Songs" (using primary RankingConfiguration)
   - Section for "All Albums" (non-ranked, chronological)
   - Route: `/artists/:id` (scoped to music domain)

3. **Music::Songs::RankedItemsController#index**
   - Similar pattern to `Music::Albums::RankedItemsController`
   - Display ranked songs without images
   - Show song title, artist(s), rank
   - Link to artist pages
   - Use pagination (Pagy)
   - Load default/primary `Music::Songs::RankingConfiguration`
   - Route: `/songs` and `/rc/:ranking_configuration_id/songs`

4. **Music::SongsController#show**
   - Display song title, artist(s), metadata
   - Show release year, duration, description
   - List all albums the song appears on (with links)
   - Display categories
   - Route: `/songs/:id`

5. **Music::DefaultController#index** (update existing)
   - Add site summary/welcome content
   - Link to Albums ranked page (`Music::Albums::RankedItemsController`)
   - Link to Songs ranked page (`Music::Songs::RankedItemsController`)
   - Consider featuring top albums/songs

### RankingConfiguration Loading Strategy

For pages showing ranked content (e.g., Artist show page's "Greatest Albums" section):
- Query for `RankingConfiguration` where `primary: true` and `global: true` for the specific type
- Use `.default.primary` scope pattern if available
- Example: `Music::Albums::RankingConfiguration.where(primary: true, global: true).first`

### SEO Implementation

**Research Summary**: Based on 2025 SEO best practices research, Google rewrites 76% of title tags. Titles that survive unchanged average 44.47 characters and fall within 30-60 character range. Key findings:
- Append brand name at end (after pipe `|` separator) - front-load keywords
- Keep titles 45-55 characters for optimal performance
- Meta descriptions should focus on content only (NO brand name), 150-160 characters
- Use pipe `|` before brand (more space-efficient than dash)
- Ensure title-content alignment to avoid Google rewrites

1. Modify `app/views/layouts/music/application.html.erb`:
   - Support `content_for :page_title` with fallback to default
   - Support `content_for :meta_description` with fallback to default
   - Example:
     ```erb
     <title><%= content_for?(:page_title) ? yield(:page_title) : "Greatest Songs & Albums Ranked | The Greatest Music" %></title>
     <meta name="description" content="<%= content_for?(:meta_description) ? yield(:meta_description) : "Discover definitive rankings of the greatest songs and albums of all time. Expert reviews, curated lists, and comprehensive music analysis." %>">
     ```

2. Set SEO content in each view (following format: "Primary Content - Details | The Greatest Music"):

   **Homepage** (Music::DefaultController#index):
   ```
   Title: "Greatest Songs & Albums Ranked | The Greatest Music" (58 chars)
   Description: "Discover definitive rankings of the greatest songs and albums of all time. Expert reviews, curated lists, and comprehensive music analysis." (145 chars)
   ```

   **Album Show** (Music::AlbumsController#show):
   ```
   Title: "#{album.title} - #{album.artists.map(&:name).join(', ')} | The Greatest Music" (target: 45-55 chars)
   Description: "Explore our in-depth review and ranking of #{album.title} by #{album.artists.map(&:name).join(', ')}. Features, track listings, and why it's one of the greatest albums in #{genre} history." (target: 150-160 chars)
   ```

   **Artist Show** (Music::ArtistsController#show):
   ```
   Title: "#{artist.name} - Songs & Albums | The Greatest Music" (target: 45-55 chars)
   Description: "Complete guide to #{artist.name}'s greatest songs and albums. Rankings, reviews, and essential listening from their legendary discography." (target: 150-160 chars)
   ```

   **Song Show** (Music::SongsController#show):
   ```
   Title: "#{song.title} - #{song.artists.map(&:name).join(', ')} | The Greatest Music" (target: 45-55 chars)
   Description: "Why #{song.title} by #{song.artists.map(&:name).join(', ')} ranks among the greatest songs ever. Analysis, rankings, and the story behind this iconic track." (target: 150-160 chars)
   ```

   **Songs Index** (Music::Songs::RankedItemsController#index):
   ```
   Title: "Top 100 Greatest Songs of All Time | The Greatest Music" (59 chars)
   Description: "Our definitive ranking of the 100 greatest songs ever recorded. From classic rock to modern masterpieces, discover the songs that changed music." (150 chars)
   ```

   **Albums Index** (Music::Albums::RankedItemsController#index):
   ```
   Title: "Top 100 Greatest Albums of All Time | The Greatest Music" (60 chars)
   Description: "Our definitive ranking of the 100 greatest albums ever recorded. From classic rock to modern masterpieces, discover the albums that changed music." (151 chars)
   ```

**Key Formatting Rules**:
- Format: "Primary Content - Details | The Greatest Music"
- Use pipe `|` separator before brand name
- Keep total length 45-55 characters (avoid Google rewrites)
- Front-load keywords (entity name first)
- Meta descriptions: content only, no brand name, 150-160 chars

### UI/UX Guidelines

- Use DaisyUI components: `card`, `badge`, `btn`, `stats`, `divider`, etc.
- Maintain consistent spacing with Tailwind utilities
- Group categories by `category.category_type` (e.g., Genre, Era, Style)
- Display images with aspect-ratio preservation
- Use placeholder states when images are missing
- Implement responsive grid layouts (`grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3`)
- Add appropriate loading states and empty states

## Dependencies
- Existing models: `Music::Album`, `Music::Artist`, `Music::Song`
- Existing associations: albums <-> artists, songs <-> artists, songs <-> albums (via tracks/releases)
- `Music::Albums::RankingConfiguration` and `Music::Songs::RankingConfiguration`
- Pagy gem for pagination
- Tailwind CSS and DaisyUI
- FriendlyId for slug-based routing
- Testing framework: Minitest with fixtures and Mocha (see `docs/testing.md` for best practices)

## Acceptance Criteria
- [x] Album show page displays all required information with proper styling
- [x] Artist show page displays metadata, greatest albums/songs sections, and all albums
- [x] Songs ranked index page displays top ranked songs with pagination
- [x] Song show page displays song info and all albums it appears on
- [x] Music homepage has welcoming content with links to albums and songs
- [x] All pages have custom SEO titles and meta descriptions
- [x] All pages are responsive and work well on mobile and desktop
- [x] Controller tests exist for all new actions
- [x] Ranked content uses primary/default RankingConfiguration
- [x] UI follows existing DaisyUI patterns from albums ranked page
- [x] Use Technical Writer agent to create/update class documentation for all new controllers following `docs/documentation.md` standards
- [x] Use Technical Writer agent to update this task file's Implementation Notes section upon completion

## Design Decisions
- Use Rails generators where appropriate (`rails g controller Music::Songs::RankedItems`)
- Follow RESTful conventions for routing
- Scope all routes under music domain constraint
- Keep controllers thin, push logic to models/services if needed
- Use existing layout pattern from `Music::Albums::RankedItemsController`

## Existing Files to Edit

### Layouts (for SEO support)
- `/home/shane/dev/the-greatest/web-app/app/views/layouts/music/application.html.erb` - Add page title and meta description support

### Controllers & Views to Update
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/default_controller.rb` - Update with homepage logic
- `/home/shane/dev/the-greatest/web-app/app/views/music/default/index.html.erb` - Add homepage content

### Routes
- `/home/shane/dev/the-greatest/web-app/config/routes.rb` - Add new routes for Albums, Artists, Songs controllers

### Reference Files (Patterns to Follow)
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/ranked_items_controller.rb` - Base controller pattern
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/albums/ranked_items_controller.rb` - Ranked items pattern
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/ranked_items/index.html.erb` - UI/styling reference
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/albums/ranked_items_controller_test.rb` - Test pattern
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/default_controller_test.rb` - Test example

### Testing Guidelines
- See `docs/testing.md` for comprehensive testing best practices
- Use Minitest with fixtures (never assume fixture names like `:one` - always check actual fixture files)
- Namespace all Music tests in `module Music`
- Test all public controller actions
- Mock external services with Mocha
- Ensure 100% test coverage

### Helpers (Available for Use)
- `/home/shane/dev/the-greatest/web-app/app/helpers/application_helper.rb`
- `/home/shane/dev/the-greatest/web-app/app/helpers/domain_helper.rb`
- `/home/shane/dev/the-greatest/web-app/app/helpers/music/default_helper.rb`

---

## Implementation Notes

### Approach Taken

1. **SEO Implementation**: Added `content_for :page_title` and `content_for :meta_description` support to music layout with sensible defaults
2. **Controllers Created**: Built all show controllers (Albums, Artists, Songs) and Songs::RankedItemsController following existing patterns
3. **Ranking Configuration Strategy**: Implemented smart loading - always load a ranking configuration (from param or default primary) using `RankingConfiguration.default_primary` class method
4. **Helper Methods**: Created clean link helpers (`link_to_album`, `link_to_song`, `link_to_artist`) in `Music::DefaultHelper` that intelligently handle ranking configuration params
5. **Navigation**: Updated main nav to link to Albums and Songs ranked pages, removed Genres

### Key Files Changed

**Controllers:**
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/albums_controller.rb` - Album show page
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/artists_controller.rb` - Artist show page with greatest albums/songs sections
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/songs_controller.rb` - Song show page
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/songs/ranked_items_controller.rb` - Songs ranked index
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/default_controller.rb` - Updated homepage with featured content
- `/home/shane/dev/the-greatest/web-app/app/controllers/ranked_items_controller.rb` - Refactored to use `ranking_configuration_class` instead of string type

**Views:**
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/artists/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/ranked_items/index.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/default/index.html.erb` - Updated homepage
- `/home/shane/dev/the-greatest/web-app/app/views/layouts/music/application.html.erb` - SEO support and navigation

**Models:**
- `/home/shane/dev/the-greatest/web-app/app/models/ranking_configuration.rb` - Added `default_primary` class method and `default_primary?` instance method

**Helpers:**
- `/home/shane/dev/the-greatest/web-app/app/helpers/music/default_helper.rb` - Link helpers for smart URL generation

**Routes:**
- `/home/shane/dev/the-greatest/web-app/config/routes.rb` - All routes scoped under optional `/rc/:ranking_configuration_id`

### Challenges Encountered

1. **Track Listing Complexity**: Initially tried to display album tracks but encountered issues with the Release/Track association complexity. Decided to defer track listings to future work and keep album pages simpler for now.
2. **Duplicate Albums on Song Pages**: Songs appeared on multiple album releases/versions causing duplicates. Fixed by using `.distinct` on albums query.
3. **URL Parameter Bloat**: Initially included `ranking_configuration_id` in all URLs, which created long URLs for default rankings. Implemented smart logic to only include param when using non-default ranking configurations.

### Deviations from Plan

1. **No Track Listings**: Original plan included showing all tracks on album show page. Deferred this due to Release/Track association complexity - will revisit later.
2. **Helper Methods Instead of Inline Logic**: Rather than using inline conditionals in views, created clean helper methods for all music resource links.
3. **Class Constants vs Strings**: Changed `expected_ranking_configuration_type` from returning strings to `ranking_configuration_class` returning class constants for better type safety.

### Code Examples

**Smart Ranking Configuration Loading:**
```ruby
# Always loads a ranking configuration (param or default)
@ranking_configuration = if params[:ranking_configuration_id].present?
  RankingConfiguration.find(params[:ranking_configuration_id])
else
  Music::Albums::RankingConfiguration.default_primary
end
```

**Link Helpers with Smart URL Generation:**
```ruby
# Only includes ranking_configuration_id if NOT default primary
def link_to_album(album, ranking_configuration = nil, **options, &block)
  path = music_album_path_with_rc(album, ranking_configuration)
  if block_given?
    link_to path, **options, &block
  else
    link_to album.title, path, **options
  end
end
```

**SEO Implementation:**
```erb
<title><%= content_for?(:page_title) ? yield(:page_title) : "Greatest Songs & Albums Ranked | The Greatest Music" %></title>
<meta name="description" content="<%= content_for?(:meta_description) ? yield(:meta_description) : "Discover definitive rankings..." %>">
```

### Testing Approach

Comprehensive controller tests were created for all new and updated controllers following the patterns in `docs/testing.md`:

**Test Files Created:**
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/albums_controller_test.rb` - 5 tests covering show action, SEO, error handling
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/artists_controller_test.rb` - 5 tests covering show action, ranked sections, SEO
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/songs_controller_test.rb` - 5 tests covering show action, albums association, SEO
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/songs/ranked_items_controller_test.rb` - 6 tests covering index, pagination, ranking configs
- Updated `/home/shane/dev/the-greatest/web-app/test/controllers/music/default_controller_test.rb` - 4 tests covering homepage, featured content, SEO

**Test Coverage:**
- Total new tests: 25 tests, 48 assertions
- All tests passing
- Full test suite: 1314 tests passing
- Coverage includes happy paths, error handling, SEO metadata, and edge cases

**Testing Fixtures:**
- Used existing fixtures in `test/fixtures/music/` directory
- Created proper associations between albums, artists, songs, and ranking configurations
- All tests use real fixture data (no assumptions about `:one`, `:two` patterns)

### Performance Considerations

- All show pages use eager loading (`.includes`) to prevent N+1 queries
- Songs ranked index loads 100 items per page with pagination
- Albums ranked index loads 25 items per page with pagination
- Artist show page limits greatest albums/songs to 10 items each

### Future Improvements

1. **Track Listings**: Implement proper track listing display on album show pages with multi-disc support
2. **Breadcrumbs**: Add breadcrumb navigation to show context
3. **Related Content**: Add "You might also like" sections based on categories/artists
4. **Rich Snippets**: Add structured data (JSON-LD) for better SEO
5. **Caching**: Implement fragment caching for expensive ranked queries
6. **Images**: Add lazy loading for album/artist images

### Bug Fixes During Testing

**Critical Bug: Nil Image Handling**

While writing controller tests, discovered a critical bug where `rails_public_blob_url` was being called on nil when images weren't attached to albums, artists, or songs. This caused 500 errors on pages with entities missing primary images.

**Root Cause:**
Views were checking `album.primary_image.file.attached?` which would fail with NoMethodError when `primary_image` was nil.

**Fix Applied:**
Updated all views to use safe navigation operator:
```ruby
# Before (broken)
if album.primary_image.file.attached?

# After (fixed)
if album.primary_image&.file&.attached?
```

**Files Fixed:**
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/artists/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/default/index.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/ranked_items/index.html.erb`

**Impact:**
This bug would have caused production errors for any entity without an attached image. Writing tests uncovered it before deployment.

### Documentation Created

Used Technical Writer agent to create comprehensive class documentation for all controllers:

**New Documentation Files:**
- `/home/shane/dev/the-greatest/docs/controllers/music/albums_controller.md` - Album show page controller documentation
- `/home/shane/dev/the-greatest/docs/controllers/music/artists_controller.md` - Artist show page with ranked sections documentation
- `/home/shane/dev/the-greatest/docs/controllers/music/songs_controller.md` - Song show page controller documentation
- `/home/shane/dev/the-greatest/docs/controllers/music/songs/ranked_items_controller.md` - Songs ranked index controller documentation
- Updated `/home/shane/dev/the-greatest/docs/controllers/music/default_controller.md` - Homepage controller documentation

**Documentation Standards:**
All documentation follows the template defined in `docs/documentation.md` with:
- Summary and purpose
- Public method documentation
- Dependencies and integrations
- Usage examples
- SEO implementation details
- Helper method integration

### Lessons Learned

1. **Helper methods are cleaner than view logic**: Creating dedicated helper methods resulted in much cleaner, more maintainable views
2. **Always load ranking configurations**: Having a consistent pattern of always loading a ranking config (even if default) simplifies view logic
3. **Start simple, iterate**: Deferring track listings was the right call - get the core functionality working first
4. **Type safety matters**: Using class constants instead of strings for ranking configuration types prevents typos and aids refactoring
5. **Test-driven bug discovery**: Writing comprehensive controller tests uncovered the nil image bug before it reached production - validates the importance of thorough test coverage
6. **Safe navigation is essential**: Always use safe navigation (`&.`) when working with potentially nil associations, especially in views

### Related PRs

*Ready for pull request creation - all implementation, testing, and documentation complete*

### Documentation Updated
- [x] Task file updated with implementation notes
- [x] Class documentation files created for all new controllers
- [ ] API documentation updated if needed (N/A - no API changes)
- [ ] README updated if needed (N/A - no README changes needed)
