# Music::ListsController

## Summary
Public-facing controller for browsing and submitting music lists. Handles the lists overview page showing top album and song lists, and provides a public submission form for users to contribute new lists for review.

## Purpose
Provides a consolidated view of the highest-weighted lists for both albums and songs in the music domain, plus a public submission workflow for users to contribute new lists.

## Actions

### `index`
Displays the top 50 album lists and top 50 song lists ordered by weight.

**Query Strategy:**
- Fetches from two separate ranking configurations (albums and songs)
- Joins with the `lists` table to filter by STI type
- Includes `list_items` for efficient display
- Orders by `weight` descending (highest influence first)
- Limits to 50 results per category

**Instance Variables Set:**
- `@albums_ranked_lists` - Top 50 weighted album lists (Array of RankedList)
- `@songs_ranked_lists` - Top 50 weighted song lists (Array of RankedList)
- `@albums_ranking_configuration` - The primary albums ranking configuration
- `@songs_ranking_configuration` - The primary songs ranking configuration

### `new`
Renders the public list submission form.

**Purpose:** Allows any user (anonymous or logged in) to submit a music list for review.

**Instance Variables Set:**
- `@list` - New, unsaved List instance for form binding

### `create`
Processes list submission from the public form.

**Behavior:**
1. Determines list class from `list_type` param:
   - `"albums"` → `Music::Albums::List`
   - `"songs"` → `Music::Songs::List`
2. If invalid/missing list_type, renders form with error
3. Creates list with permitted params
4. Sets `status: :unapproved` (always)
5. Sets `submitted_by` to current user (if logged in)
6. On success: redirects to index with flash notice
7. On failure: re-renders form with validation errors

**Parameters:**
- `list_type` (required) - "albums" or "songs"
- `list[name]` (required) - List name
- `list[description]` - Optional description
- `list[source]` - Publication/organization name
- `list[url]` - Original list URL
- `list[year_published]` - Year published
- `list[number_of_voters]` - Voter count
- `list[num_years_covered]` - Years of releases covered
- `list[location_specific]` - Boolean flag
- `list[category_specific]` - Boolean flag
- `list[yearly_award]` - Boolean flag
- `list[voter_count_estimated]` - Boolean flag
- `list[voter_names_unknown]` - Boolean flag
- `list[voter_count_unknown]` - Boolean flag
- `list[raw_html]` - Free-text list items

**Returns:**
- Success: Redirect to `music_lists_path` with flash notice
- Failure: Render `:new` with status 422

## Routing

**Routes:**
```ruby
# config/routes.rb (within music domain constraint)
scope as: "music" do
  resources :lists, only: [:index, :new, :create], controller: "music/lists"
end
```

**URL Patterns:**
| Verb | Path | Action | Route Helper |
|------|------|--------|--------------|
| GET | /lists | index | `music_lists_path` |
| GET | /lists/new | new | `new_music_list_path` |
| POST | /lists | create | `music_lists_path` |

> Routes use `scope as: "music"` to prefix helpers, preventing conflicts when other domains (games, movies) add similar resources.

## Configuration

### Layout
Uses `music/application` layout for consistent music domain styling.

### Callbacks
- `before_action :load_ranking_configurations, only: [:index]` - Loads ranking configurations for index action only

## Private Methods

### `load_ranking_configurations`
Loads the default primary ranking configurations for both albums and songs.

### `list_class_from_type(list_type)`
Maps list_type string to appropriate List subclass.
- `"albums"` → `Music::Albums::List`
- `"songs"` → `Music::Songs::List`
- Other → `nil`

### `list_params`
Strong parameters for list creation. Permits safe subset of List attributes for public submission.

## Authentication
All actions are public (no authentication required). When a user is logged in, `submitted_by_id` is automatically set on created lists.

## Dependencies

### Models
- `Music::Albums::RankingConfiguration` - Configuration for album ranking algorithms
- `Music::Songs::RankingConfiguration` - Configuration for song ranking algorithms
- `RankedList` - Join model between lists and ranking configurations
- `Music::Albums::List` - Album-specific list model (STI)
- `Music::Songs::List` - Song-specific list model (STI)
- `List` - Base list model
- `ListItem` - Items within each list

## Related Controllers
- `Music::Albums::ListsController` - Detailed album lists browsing and individual list display
- `Music::Songs::ListsController` - Detailed song lists browsing and individual list display

## Views
- `app/views/music/lists/index.html.erb` - Lists overview with top albums/songs lists
- `app/views/music/lists/new.html.erb` - Submission form wrapper
- `app/views/music/lists/_form.html.erb` - Submission form partial with DaisyUI styling

## Tests
- `test/controllers/music/lists_controller_test.rb` - 12 integration tests covering:
  - Index page rendering
  - Submit a List link presence
  - Form rendering
  - Album list creation (anonymous and logged-in)
  - Song list creation
  - Missing list_type validation
  - Missing name validation
  - Invalid URL validation
  - All permitted attributes

## Design Notes

### Why Separate Ranking Configurations?
Albums and songs use separate ranking configurations because:
- They may have different algorithm parameters (exponent, bonus pool, penalties)
- They rank different types of items (Album vs Song models)
- They use different STI list types

### Performance Considerations
- **Limit to 50**: Only fetches top 50 lists per category to keep page load fast
- **Eager Loading**: Uses `includes(list: :list_items)` to prevent N+1 queries
- **Pre-sorted**: Relies on database-level sorting by weight (indexed column)

### Public Submission Design
- Lists are always created with `status: unapproved` for admin review
- `submitted_by_id` tracks who submitted (if logged in) for accountability
- Uses STI to create the correct list subclass based on user selection
- Form collects raw text in `raw_html` field; parsing handled separately by admin wizard

## Related Documentation
- [List Model](../../models/list.md)
- [RankedList Model](../../models/ranked_list.md)
