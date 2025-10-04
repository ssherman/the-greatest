# 045 - Music UI Controllers and Album/Song/Artist Show Pages

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-10-04
- **Started**:
- **Completed**:
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
- [ ] Create `Music::AlbumsController` with show action
- [ ] Create `Music::ArtistsController` with show action
- [ ] Generate `Music::Songs::RankedItemsController` for top songs index
- [ ] Create `Music::SongsController` with show action
- [ ] Update `Music::DefaultController#index` with homepage content
- [ ] Add controller tests for all new endpoints (following `docs/testing.md` best practices)
- [ ] Implement SEO title and meta description support in layout
- [ ] Set custom SEO titles/descriptions for each page
- [ ] Use Tailwind + DaisyUI for all UI components
- [ ] Ensure mobile and desktop responsive design

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
- [ ] Album show page displays all required information with proper styling
- [ ] Artist show page displays metadata, greatest albums/songs sections, and all albums
- [ ] Songs ranked index page displays top ranked songs with pagination
- [ ] Song show page displays song info and all albums it appears on
- [ ] Music homepage has welcoming content with links to albums and songs
- [ ] All pages have custom SEO titles and meta descriptions
- [ ] All pages are responsive and work well on mobile and desktop
- [ ] Controller tests exist for all new actions
- [ ] Ranked content uses primary/default RankingConfiguration
- [ ] UI follows existing DaisyUI patterns from albums ranked page
- [ ] Use Technical Writer agent to create/update class documentation for all new controllers following `docs/documentation.md` standards
- [ ] Use Technical Writer agent to update this task file's Implementation Notes section upon completion

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
- [ ] API documentation updated
- [ ] README updated if needed
