# 047 - Music Lists UI Controllers and Show Pages

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-10-05
- **Started**:
- **Completed**:
- **Developer**: Claude

## Overview
Create comprehensive UI for browsing and viewing Music Lists. This includes a top-level Lists index showing all album and song lists, dedicated index pages for album lists and song lists separately, and detailed show pages for individual lists displaying all items. This will provide users with rich list browsing capabilities and improve discoverability of curated music collections.

## Context
- Currently, we have working `Music::Albums::RankedItemsController` and `Music::Songs::RankedItemsController` that display ranked items with Tailwind/DaisyUI styling
- We have `Music::AlbumsController#show` and `Music::SongsController#show` that display individual items
- Album and Song show pages already display lists they appear on, but without links to the list pages
- The Music domain has `List` models using STI pattern: `Music::Albums::List` and `Music::Songs::List`
- Lists can be linked to RankingConfigurations via `RankedList` join table with weights
- Lists have a `weight` attribute through the `RankedList` association to determine importance/quality
- We use Tailwind CSS and DaisyUI (https://daisyui.com/llms.txt) for all UI components
- Pages need to be responsive for both mobile and desktop
- SEO is important for discoverability
- All routes should be scoped within optional ranking_configuration parameter

## Requirements
- [ ] **MUST use Rails generator** to create `Music::ListsController` with index action
- [ ] **MUST use Rails generator** to create `Music::Albums::ListsController` with index and show actions
- [ ] **MUST use Rails generator** to create `Music::Songs::ListsController` with index and show actions
- [ ] Add controller tests for all new endpoints (following `docs/testing.md` best practices)
- [ ] Add helper tests for all new URL helper methods
- [ ] Implement SEO title and meta description support for each page
- [ ] Use Tailwind + DaisyUI for all UI components
- [ ] Ensure mobile and desktop responsive design
- [ ] Add pagination using Pagy on all index pages
- [ ] Add sorting capability (by weight desc [default], created_at)
- [ ] Update album/song show pages with working links to list pages
- [ ] Add helper methods for linking to lists with ranking configuration awareness

## Technical Approach

### Controllers to Create

1. **Music::ListsController#index**
   - Display both album lists and song lists together (limited preview)
   - Show list name, source, description, weight (from RankedList), item count
   - Include external source link to original list URL
   - **Always sorted by weight (desc)** - no sorting options
   - **No pagination** - show limited number (e.g., top 10 of each type)
   - At bottom, show "View All Album Lists" and "View All Song Lists" links
   - Link to `/albums/lists` and `/songs/lists` for full paginated views
   - **Special case**: This controller needs to load TWO ranking configurations:
     - `@albums_ranking_configuration` for album lists
     - `@songs_ranking_configuration` for song lists
   - Each defaults to their respective `.default_primary` (no param support)
   - Route: `/lists` only (no ranking_configuration_id support)
   - **Note**: This is a simplified overview page, not configurable by ranking config

2. **Music::Albums::ListsController#index**
   - Display album lists only
   - Show list name, source, description, weight, album count
   - Include external source link
   - Default sort by weight (desc)
   - Optional sort by created_at (via query param)
   - Use pagination (Pagy)
   - `before_action :find_ranking_configuration` loads `@ranking_configuration`
   - Defaults to `Music::Albums::RankingConfiguration.default_primary` if no param
   - Query: `@ranking_configuration.ranked_lists.joins(:list).where(lists: { type: 'Music::Albums::List' })`
   - Route: `/albums/lists` and `/rc/:ranking_configuration_id/albums/lists`
   - **Note**: Literal segment `lists` is matched before dynamic `:id`, so no conflict with `/albums/:id`

3. **Music::Albums::ListsController#show**
   - Display individual album list with all albums
   - Show list metadata (name, source, description, year_published, etc.)
   - Display albums with rank/position (if ranked), title, artists, release year, primary image
   - Link to album show pages
   - `before_action :find_ranking_configuration` loads `@ranking_configuration`
   - Defaults to `Music::Albums::RankingConfiguration.default_primary` if no param
   - Load list with `Music::Albums::List.includes(list_items: { item: [:artists, :primary_image] }).find(params[:id])`
   - Optionally load `@ranked_list` to show weight badge
   - Route: `/albums/lists/:id` and `/rc/:ranking_configuration_id/albums/lists/:id`
   - **Note**: Lists use numeric IDs, not FriendlyId slugs

4. **Music::Songs::ListsController#index**
   - Display song lists only
   - Show list name, source, description, weight, song count
   - Include external source link
   - Default sort by weight (desc)
   - Optional sort by created_at (via query param)
   - Use pagination (Pagy)
   - `before_action :find_ranking_configuration` loads `@ranking_configuration`
   - Defaults to `Music::Songs::RankingConfiguration.default_primary` if no param
   - Query: `@ranking_configuration.ranked_lists.joins(:list).where(lists: { type: 'Music::Songs::List' })`
   - Route: `/songs/lists` and `/rc/:ranking_configuration_id/songs/lists`
   - **Note**: Literal segment `lists` is matched before dynamic `:id`, so no conflict with `/songs/:id`

5. **Music::Songs::ListsController#show**
   - Display individual song list with all songs
   - Show list metadata (name, source, description, year_published, etc.)
   - Display songs more condensed: rank/position (if ranked), song title, artists, release year
   - No images for songs (more compact display)
   - Link to song show pages
   - `before_action :find_ranking_configuration` loads `@ranking_configuration`
   - Defaults to `Music::Songs::RankingConfiguration.default_primary` if no param
   - Load list with `Music::Songs::List.includes(list_items: { item: :artists }).find(params[:id])`
   - Optionally load `@ranked_list` to show weight badge
   - Route: `/songs/lists/:id` and `/rc/:ranking_configuration_id/songs/lists/:id`
   - **Note**: Lists use numeric IDs, not FriendlyId slugs

### RankingConfiguration Loading Strategy

For all list controllers:
- **Always load a ranking configuration** in a `before_action` filter
- If `params[:ranking_configuration_id]` is present, load that specific configuration
- Otherwise, load the default primary configuration for the type
- Pattern from task 045:
  ```ruby
  before_action :find_ranking_configuration

  def find_ranking_configuration
    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      Music::Albums::RankingConfiguration.default_primary
    end
  end
  ```
- Once loaded, use `@ranking_configuration.ranked_lists` to access lists with weights
- This ensures we always have a ranking configuration and simplifies view logic

### Querying Strategy

**Index Pages (Lists of Lists):**
- Always load ranking configuration in `before_action` (see strategy above)
- Start from `@ranking_configuration.ranked_lists` to access lists with weights
- Filter by list type using STI
- Order by weight desc (default) or created_at (from params[:sort])
- Use `includes` to eager load list and list_items for item counts
- Example:
  ```ruby
  # In controller after before_action :find_ranking_configuration
  sort_order = params[:sort] == 'created_at' ? { 'lists.created_at': :desc } : { weight: :desc }

  @ranking_configuration.ranked_lists
    .joins(:list)
    .where(lists: { type: 'Music::Albums::List' })
    .includes(list: :list_items)
    .order(sort_order)
  ```

**Show Pages (Individual List with Items):**
- Always load ranking configuration in `before_action` (see strategy above)
- Load the list with all associations
- Load list_items with their items (albums or songs)
- Include artists, categories, primary_image for albums
- Optionally load the ranked_list to access weight for this configuration
- **Note**: Lists use numeric IDs, not FriendlyId - use `.find(params[:id])` not `.friendly.find`
- Example:
  ```ruby
  # In controller after before_action :find_ranking_configuration
  @list = Music::Albums::List.includes(list_items: { item: [:artists, :primary_image] })
    .find(params[:id])

  # Optional: get the weight for this list in current ranking configuration
  @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
  ```

### SEO Implementation

Following 2025 SEO best practices from task 045:
- Title format: "Primary Content - Details | The Greatest Music"
- Use pipe `|` separator before brand name
- Keep titles 45-55 characters
- Meta descriptions: content only, no brand name, 150-160 characters

**Music::ListsController#index:**
```
Title: "Greatest Music Lists - Albums & Songs | The Greatest Music" (65 chars - acceptable)
Description: "Browse curated lists of the greatest albums and songs. Discover expert rankings, user favorites, and authoritative music collections from trusted sources." (160 chars)
```

**Music::Albums::ListsController#index:**
```
Title: "Greatest Album Lists & Rankings | The Greatest Music" (60 chars)
Description: "Explore curated lists of the greatest albums of all time. Discover expert rankings, critical favorites, and authoritative album collections." (145 chars)
```

**Music::Albums::ListsController#show:**
```
Title: "#{list.name} - Album List | The Greatest Music" (target: 45-55 chars)
Description: "Explore #{list.name}, featuring #{list.list_items.count} albums. #{truncate(list.description, length: 90)} Source: #{list.source}." (target: 150-160 chars)
```

**Music::Songs::ListsController#index:**
```
Title: "Greatest Song Lists & Rankings | The Greatest Music" (59 chars)
Description: "Explore curated lists of the greatest songs ever recorded. Discover expert rankings, fan favorites, and authoritative song collections." (140 chars)
```

**Music::Songs::ListsController#show:**
```
Title: "#{list.name} - Song List | The Greatest Music" (target: 45-55 chars)
Description: "Explore #{list.name}, featuring #{list.list_items.count} songs. #{truncate(list.description, length: 90)} Source: #{list.source}." (target: 150-160 chars)
```

### UI/UX Guidelines

- Use DaisyUI components: `card`, `badge`, `btn`, `stats`, `divider`, `table`, etc.
- Maintain consistent spacing with Tailwind utilities
- Display list metadata prominently (source, year_published, voter info)
- Show item counts for each list on index pages
- Include external link buttons to original source URLs
- Use responsive grid layouts for list cards on index pages
- Use table layout for list items on show pages (better for ranked lists)
- Add appropriate loading states and empty states
- Show weight badges on index pages to indicate list quality/importance

### Helper Methods to Add

Add to `Music::DefaultHelper`:

```ruby
def music_albums_lists_path_with_rc(ranking_configuration = nil)
  # Return path with or without ranking_configuration_id
end

def music_songs_lists_path_with_rc(ranking_configuration = nil)
  # Return path with or without ranking_configuration_id
end

def music_album_list_path_with_rc(list, ranking_configuration = nil)
  # Return path with or without ranking_configuration_id
end

def music_song_list_path_with_rc(list, ranking_configuration = nil)
  # Return path with or without ranking_configuration_id
end

def link_to_album_list(list, ranking_configuration = nil, **options, &block)
  # Smart link helper
end

def link_to_song_list(list, ranking_configuration = nil, **options, &block)
  # Smart link helper
end
```

## Dependencies
- Existing models: `Music::Albums::List`, `Music::Songs::List`, `RankedList`
- Existing associations: lists -> list_items -> items (albums/songs)
- `Music::Albums::RankingConfiguration` and `Music::Songs::RankingConfiguration`
- Pagy gem for pagination
- Tailwind CSS and DaisyUI
- Testing framework: Minitest with fixtures and Mocha (see `docs/testing.md` for best practices)
- **Note**: Lists do NOT use FriendlyId - use numeric IDs only

## Acceptance Criteria
- [ ] Music::ListsController#index displays both album and song lists with all metadata
- [ ] Music::Albums::ListsController#index displays album lists with pagination and sorting
- [ ] Music::Albums::ListsController#show displays individual list with all albums and metadata
- [ ] Music::Songs::ListsController#index displays song lists with pagination and sorting
- [ ] Music::Songs::ListsController#show displays individual list with all songs and metadata
- [ ] All pages have custom SEO titles and meta descriptions
- [ ] All pages are responsive and work well on mobile and desktop
- [ ] Controller tests exist for all new actions with 100% coverage
- [ ] Helper tests exist for all new URL helper methods with 100% coverage
- [ ] Lists use weight from RankedList for default sorting
- [ ] Sorting by created_at works correctly on index pages
- [ ] UI follows existing DaisyUI patterns from albums/songs ranked pages
- [ ] Helper methods handle ranking configuration URLs correctly
- [ ] Helper methods correctly omit ranking_configuration_id when using default/primary
- [ ] Helper methods correctly include ranking_configuration_id when using non-default
- [ ] Album and song show pages have working links to their lists
- [ ] Navigation includes "Lists" link in appropriate location
- [ ] Use Technical Writer agent to create class documentation for all new controllers following `docs/documentation.md` standards
- [ ] Use Technical Writer agent to update this task file's Implementation Notes section upon completion

## Design Decisions
- **CRITICAL: MUST use Rails generators for ALL controllers** - Do NOT manually create controller files
  - `bin/rails generate controller Music::Lists index`
  - `bin/rails generate controller Music::Albums::Lists index show`
  - `bin/rails generate controller Music::Songs::Lists index show`
- Follow RESTful conventions for routing
- Scope all routes under music domain constraint with optional ranking_configuration
- Keep controllers thin, push logic to models/services if needed
- Use existing layout pattern from `Music::Albums::RankedItemsController`
- Start queries from `RankedList` when weight sorting is needed for performance
- Load both `RankedList` and `List` to access both weight and list metadata
- Use table layout for list show pages (better for displaying ranked items with positions)
- Use card layout for list index pages (better for browsing multiple lists)
- Music::ListsController#index is a preview page (top 10 each type) with "View All" links

## Existing Files to Edit

### Controllers & Views to Update
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/show.html.erb` - Add working links to album lists
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/show.html.erb` - Add working links to song lists
- `/home/shane/dev/the-greatest/web-app/app/views/layouts/music/application.html.erb` - Add "Lists" navigation link

### Helpers to Update
- `/home/shane/dev/the-greatest/web-app/app/helpers/music/default_helper.rb` - Add list link helper methods

### Routes
- `/home/shane/dev/the-greatest/web-app/config/routes.rb` - Add new routes for Lists controllers

### Reference Files (Patterns to Follow)
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/ranked_items_controller.rb` - Base controller pattern
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/albums/ranked_items_controller.rb` - Ranked items pattern
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/albums_controller.rb` - Show page pattern
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/ranked_items/index.html.erb` - UI/styling reference for index pages
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/show.html.erb` - UI/styling reference for show pages
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/albums/ranked_items_controller_test.rb` - Controller test pattern
- `/home/shane/dev/the-greatest/web-app/app/helpers/music/default_helper.rb` - Helper pattern for ranking configuration URLs
- `/home/shane/dev/the-greatest/web-app/test/helpers/music/default_helper_test.rb` - Helper test pattern (if exists, check first)

### Testing Guidelines
- See `docs/testing.md` for comprehensive testing best practices
- Use Minitest with fixtures (never assume fixture names like `:one` - always check actual fixture files)
- Namespace all Music tests in `module Music`
- Test all public controller actions
- Mock external services with Mocha (not applicable here)
- Ensure 100% test coverage
- Test both with and without ranking_configuration_id parameter
- Test sorting functionality (weight vs created_at)
- Test pagination
- **Test all helper methods** in `test/helpers/music/default_helper_test.rb`:
  - Test `music_albums_lists_path_with_rc` with and without ranking configuration
  - Test `music_songs_lists_path_with_rc` with and without ranking configuration
  - Test `music_album_list_path_with_rc` with default and non-default ranking configurations
  - Test `music_song_list_path_with_rc` with default and non-default ranking configurations
  - Test `link_to_album_list` helper with block and without block
  - Test `link_to_song_list` helper with block and without block

### Files to Create

**CRITICAL: Controllers MUST be generated using Rails generators:**

Run these commands in order from `/home/shane/dev/the-greatest/web-app/` directory:

```bash
cd /home/shane/dev/the-greatest/web-app
bin/rails generate controller Music::Lists index
bin/rails generate controller Music::Albums::Lists index show
bin/rails generate controller Music::Songs::Lists index show
```

**Expected Generated Files (DO NOT create these manually):**
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/lists_controller.rb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/lists/index.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/albums/lists_controller.rb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/lists/index.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/albums/lists/show.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/controllers/music/songs/lists_controller.rb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/lists/index.html.erb`
- `/home/shane/dev/the-greatest/web-app/app/views/music/songs/lists/show.html.erb`

**Tests (manually created following patterns):**
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/lists_controller_test.rb`
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/albums/lists_controller_test.rb`
- `/home/shane/dev/the-greatest/web-app/test/controllers/music/songs/lists_controller_test.rb`
- `/home/shane/dev/the-greatest/web-app/test/helpers/music/default_helper_test.rb` - Add tests for new helper methods

**Documentation (created by Technical Writer agent):**
- `/home/shane/dev/the-greatest/docs/controllers/music/lists_controller.md`
- `/home/shane/dev/the-greatest/docs/controllers/music/albums/lists_controller.md`
- `/home/shane/dev/the-greatest/docs/controllers/music/songs/lists_controller.md`

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
- [ ] Task file updated with implementation notes
- [ ] Class documentation files created for all new controllers
- [ ] API documentation updated if needed (N/A - no API changes)
- [ ] README updated if needed (N/A - no README changes needed)
