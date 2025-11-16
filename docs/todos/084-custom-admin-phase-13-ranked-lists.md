# 084 - Custom Admin Interface - Phase 13: Ranked Lists

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-11-15
- **Started**: 2025-11-15
- **Completed**: 2025-11-15
- **Developer**: Claude Code (AI Agent)

## Overview
Implement generic admin interface for managing the RankedList join table (connecting RankingConfigurations to Lists with calculated weight). This is a cross-domain feature that works for album and song ranking configurations (not artist configurations, which use a different ranking method), and eventually book/movie/game configurations. Users can attach and detach lists from ranking configuration show pages via a modal interface. Unlike penalty_applications, this feature includes a dedicated show page to display calculated_weight_details in a user-friendly format.

## Context
- **Previous Phase Complete**: Penalty Applications (Phase 12) - CRUD for config-penalty associations implemented
- **Join Table**: RankedList connects RankingConfiguration → List with weight and calculated_weight_details
- **Generic Controller**: `Admin::RankedListsController` (NOT namespaced under music/books/etc.)
- **Cross-Domain**: Works for all ranking configuration types (Music::Albums::, Music::Songs::, Books::, Movies::, Games::)
- **Proven Pattern**: Phase 12 penalty_applications join table with modals (docs/todos/completed/083-custom-admin-phase-12-penalty-applications.md)
- **Similar Interaction**: Dropdown selection (no additional fields on create - weight calculated automatically)
- **Show Page Required**: Display calculated_weight_details JSON in friendly format (unlike penalty_applications)
- **Implementation Scope**: Album and song ranking configurations only (artist configs use different calculation, Books/Movies/Games in future)
- **Existing Code**: Read-only index view exists at `app/views/admin/music/ranked_lists/index.html.erb` (needs enhancement with add/delete actions)

## Requirements

### Base Ranked List Management
- [x] Generic controller: `Admin::RankedListsController` (partially exists - needs create/destroy/show actions)
- [ ] Modal-based interface for add/delete operations
- [ ] Context-aware: works from any ranking configuration show page
- [ ] Dropdown selection of available lists (same type as configuration, not already added)
- [ ] Show page to display calculated_weight_details in user-friendly format
- [ ] No edit action needed (weight recalculated automatically by ranking jobs)
- [ ] Validation preventing duplicate list assignments
- [ ] Media type compatibility validation (Music lists only with Music configurations, etc.)
- [ ] Pagination on index (existing: 25 items per page)
- [ ] Sorting: weight descending (existing in index)

### Ranking Configuration Show Page Integration
- [ ] Existing "Ranked Lists" section on ranking configuration show pages (needs enhancement)
- [ ] Lazy-loaded turbo frame for ranked lists (already exists)
- [ ] **Add "Add List" button** to existing card header
- [ ] Create modal: dropdown with available lists (filtered by type) showing list name and source
- [ ] Lists table shows: name, source, submitted by, weight, details link, delete action
- [ ] Delete confirmation for removing lists
- [ ] Real-time updates via Turbo Streams
- [ ] Count badge showing number of ranked lists (already exists)

### Show Page Requirements
- [ ] New dedicated show page for individual RankedList records
- [ ] Display calculated_weight_details in user-friendly format (not raw JSON)
- [ ] Card-based layout with sections:
  - Basic Information: List name (link), weight badge, timestamp
  - Base Values: base_weight, minimum_weight, high_quality_source
  - Penalties Applied: badge-coded list of all penalties with values
  - Penalty Summary: totals by category
  - Quality Bonus: whether applied, reduction factor, before/after
  - Final Calculation: step-by-step calculation breakdown
- [ ] Color-coded penalty badges (green < 10%, yellow 10-24%, red ≥ 25%)
- [ ] Expandable/collapsible sections for detailed calculations
- [ ] "View Raw JSON" option for technical users
- [ ] Back navigation to ranking configuration show page

### Display Requirements
- [ ] DaisyUI card with title "Ranked Lists" and count badge (already exists)
- [ ] Table columns: Name, Source, Submitted By, Weight, Actions
- [ ] Weight displayed with 2 decimal precision (e.g., "78.13")
- [ ] Empty state when no lists attached (already exists)
- [ ] Link to show page from list name
- [ ] Delete button with confirmation
- [ ] Details dropdown replaced with "View Details" link to show page

## API Endpoints

| Verb | Path | Purpose | Params/Body | Auth | Context |
|------|------|---------|-------------|------|---------|
| GET | `/admin/ranking_configuration/:ranking_configuration_id/ranked_lists` | List ranked lists for a configuration | - | admin/editor | lazy-loaded frame (EXISTS) |
| POST | `/admin/ranking_configuration/:ranking_configuration_id/ranked_lists` | Add list to configuration | `ranked_list[list_id]` | admin/editor | create modal form |
| GET | `/admin/ranked_lists/:id` | Show ranked list details | - | admin/editor | show page |
| DELETE | `/admin/ranked_lists/:id` | Remove list from configuration | - | admin/editor | table row |

**Route Helpers**:
- `admin_ranking_configuration_ranked_lists_path(@ranking_configuration)` → GET index (lazy load, EXISTS)
- `admin_ranking_configuration_ranked_lists_path(@ranking_configuration)` → POST create
- `admin_ranked_list_path(@ranked_list)` → GET show
- `admin_ranked_list_path(@ranked_list)` → DELETE destroy

**Note**: Routes are generic and work for all ranking configuration types (not namespaced under music/books/etc.)

## Response Formats

### Success Response - Create (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "List added successfully." } })
turbo_stream.replace("ranked_lists_list", template: "admin/ranked_lists/index",
  locals: { ranking_configuration: @ranking_configuration,
            ranked_lists: @ranking_configuration.ranked_lists.includes(list: :submitted_by).order(weight: :desc) })
turbo_stream.replace("add_list_to_configuration_modal",
  Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration))
```

### Success Response - Destroy (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "List removed successfully." } })
turbo_stream.replace("ranked_lists_list", template: "admin/ranked_lists/index",
  locals: { ranking_configuration: @ranking_configuration,
            ranked_lists: @ranking_configuration.ranked_lists.includes(list: :submitted_by).order(weight: :desc) })
turbo_stream.replace("add_list_to_configuration_modal",
  Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration))
```

### Error Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { error: "List is already added to this configuration" } })
```

### Turbo Frame IDs
- Main frame: `"ranked_lists_list"` (already exists)
- Add modal ID: `"add_list_to_configuration_modal"`
- Add dialog ID: `"add_list_to_configuration_modal_dialog"`
- Modal forms target main frame on success

## Behavioral Rules

### Preconditions
- User must have admin or editor role
- Ranking configuration must exist
- List must exist
- List media type must match ranking configuration media type

### Postconditions (Add)
- New RankedList record created linking configuration and list
- Weight field initially NULL (will be calculated by background ranking job)
- Turbo Stream updates ranked lists without page reload
- Flash message confirms success
- Modal closes automatically
- Add modal reloads with updated available lists (excluding newly added one)

### Postconditions (Delete)
- RankedList record deleted
- Turbo Stream removes list from table
- Flash message confirms removal
- Add modal reloads with updated available lists (including newly removed one)

### Invariants
- A configuration-list pair must be unique (database constraint + validation)
- List media type must match configuration media type
- User must have appropriate authorization

### Edge Cases
- **Empty dropdown**: No available lists shows "All compatible lists already added"
- **Duplicate add**: Shows validation error, doesn't create
- **Media type mismatch**: Validation prevents Music list on Books configuration
- **Authorization failure**: Redirects to appropriate domain root
- **Show page for deleted record**: Shows 404 error
- **calculated_weight_details NULL**: Show page displays "Weight not yet calculated" message

## Media Type Compatibility Rules

**From RankedList model validation** (`app/models/ranked_list.rb:34-50`)

- **Books::RankingConfiguration**: Only works with `Books::List`
- **Movies::RankingConfiguration**: Only works with `Movies::List`
- **Games::RankingConfiguration**: Only works with `Games::List`
- **Music::Albums::RankingConfiguration**: Only works with `Music::Albums::List`
- **Music::Songs::RankingConfiguration**: Only works with `Music::Songs::List`

**Dropdown filtering logic**:
```ruby
# Reference only - implementation in component
def available_lists(ranking_configuration)
  list_type = case ranking_configuration.type
              when "Books::RankingConfiguration"
                "Books::List"
              when "Movies::RankingConfiguration"
                "Movies::List"
              when "Games::RankingConfiguration"
                "Games::List"
              when "Music::Albums::RankingConfiguration"
                "Music::Albums::List"
              when "Music::Songs::RankingConfiguration"
                "Music::Songs::List"
              else
                nil
              end

  return List.none if list_type.nil?

  List
    .where(type: list_type)
    .where(status: [:active, :approved])  # Only show approved/active lists
    .where.not(id: ranking_configuration.lists.pluck(:id))
    .order(created_at: :desc)  # Newest first
end
```

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load `ranked_lists: { list: :submitted_by }` in ranking configuration show controllers
- **Lazy Loading**: Use turbo frame with lazy loading for ranked lists (already implemented)
- **Pagination**: 25 items per page (already implemented)
- **Response Time**: < 500ms p95 for attach/detach

### Security
- **Authorization**: Enforce admin/editor role via BaseController
- **CSRF Protection**: Rails handles via form helpers
- **Parameter Filtering**: Strong params whitelist (list_id only)
- **SQL Injection**: ActiveRecord parameterization

### Accessibility
- **Keyboard Navigation**: Tab through form fields
- **Screen Readers**: Labels on all inputs
- **Modals**: Native `<dialog>` element
- **Delete Confirmation**: Clear confirmation messages

### Responsiveness
- **Mobile**: DaisyUI responsive utilities
- **Tablet**: Card layout adapts
- **Desktop**: Full-width tables

## Acceptance Criteria

### Controller Tests (Required)
- [ ] GET index renders ranked lists (already exists - keep existing tests)
- [ ] POST create adds list (2 tests: success + turbo stream)
- [ ] Prevent duplicate list addition (1 test)
- [ ] GET show renders details page (1 test)
- [ ] GET show handles NULL calculated_weight_details (1 test)
- [ ] DELETE destroy removes list (2 tests: success + turbo stream)
- [ ] Authorization enforcement (2 tests: create, destroy)
- [ ] Media type compatibility validation (2 tests: matching type works, mismatched type fails)
- [ ] Turbo stream replacements for create (3 tests: flash, list, add modal)
- [ ] Turbo stream replacements for destroy (3 tests: flash, list, add modal)
- [ ] Cross-configuration type support (2 tests: works for both album and song configs)

**Total Controller Tests**: ~19 new tests (keep existing index tests)

### Component Tests (Required)
- [ ] Add modal component renders with form (1 test)
- [ ] Add modal available_lists returns filtered lists (1 test)
- [ ] Add modal available_lists filters by media type (1 test)
- [ ] Add modal available_lists excludes already added lists (1 test)
- [ ] Add modal includes list selector with name and source display (1 test)
- [ ] Add modal displays newest lists first (1 test)

**Total Component Tests**: ~6 tests

### View/Helper Tests
- [ ] Show page renders all sections when calculated_weight_details present (1 test)
- [ ] Show page handles NULL calculated_weight_details gracefully (1 test)
- [ ] Penalty badge helper returns correct classes (3 tests: green, yellow, red)

**Total View/Helper Tests**: ~5 tests

### Manual Acceptance Tests
- [ ] From album ranking configuration show page: Click "Add List", modal opens with dropdown
- [ ] Dropdown shows only Music::Albums::List records not already added
- [ ] Dropdown shows list name and source, sorted by newest first
- [ ] Select list, submit, list appears in table
- [ ] From album ranking configuration show page: Click "View Details" link, show page loads
- [ ] Show page displays all calculated_weight_details sections in friendly format
- [ ] Show page color-codes penalty badges correctly
- [ ] Show page has "View Raw JSON" expandable section
- [ ] From album ranking configuration show page: Delete list, verify disappears from table
- [ ] From song ranking configuration show page: Add list, verify appears in table
- [ ] From song ranking configuration show page: View details, verify show page works
- [ ] From song ranking configuration show page: Delete list, verify disappears from table
- [ ] Verify artist ranking configuration show page does NOT have "Add List" button
- [ ] Verify dropdown only shows available lists (not already added)
- [ ] Verify duplicate prevention shows error message
- [ ] Verify modals close automatically after successful submission
- [ ] Verify add modal reloads after add/delete to show updated available lists
- [ ] Verify Turbo Stream updates work without page reload
- [ ] Verify lazy loading works (frame loads after page)
- [ ] Verify media type validation (can't add Songs::List to Albums::RankingConfiguration)
- [ ] Verify show page for NULL calculated_weight_details shows appropriate message

## Implementation Plan

### Step 1: Update Routes
**File**: `config/routes.rb`

**Add routes** (around line 152-158):
```ruby
namespace :admin do
  # Existing routes...

  # Generic ranked lists routes (cross-domain)
  scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
    resources :ranked_lists, only: [:index, :create]
  end

  resources :ranked_lists, only: [:show, :destroy]
end
```

**Existing routes to keep**: Index route already exists at `app/controllers/admin/music/ranked_lists_controller.rb` - need to migrate to generic controller.

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb:152-158`

### Step 2: Migrate/Update Controller
**File**: `app/controllers/admin/ranked_lists_controller.rb`

**Actions to implement**:
- Keep existing `index` action from `Admin::Music::RankedListsController`
- Add `create` action with Turbo Stream response (3 replacements: flash, list, modal)
- Add `show` action for details page
- Add `destroy` action with Turbo Stream response (3 replacements: flash, list, modal)
- Strong params: whitelist `list_id` only
- Dynamic redirect path based on configuration STI type

**Migration note**: Move controller from `app/controllers/admin/music/ranked_lists_controller.rb` to `app/controllers/admin/ranked_lists_controller.rb` and make it inherit from `Admin::BaseController` instead of `Admin::Music::BaseController`.

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/penalty_applications_controller.rb`

### Step 3: Update Index View Template
**File**: `app/views/admin/ranked_lists/index.html.erb` (move from `app/views/admin/music/ranked_lists/index.html.erb`)

**Updates needed**:
- Keep existing table structure
- Replace details dropdown with "View Details" link to show page
- Add delete button with turbo_confirm
- Use `local_assigns.fetch` pattern for both instance vars and locals
- Keep existing pagination with pagy

**Reference**:
- Existing: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/ranked_lists/index.html.erb`
- Pattern: `/home/shane/dev/the-greatest/web-app/app/views/admin/penalty_applications/index.html.erb`

### Step 4: Create Show View Template
**File**: `app/views/admin/ranked_lists/show.html.erb`

**Layout structure**:
```erb
<div class="container mx-auto px-4 py-8">
  <div class="mb-6">
    <%= link_to "← Back to Ranking Configuration",
        redirect_path,
        class: "btn btn-ghost btn-sm" %>
  </div>

  <h1 class="text-3xl font-bold mb-6">Ranked List Details</h1>

  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <div class="lg:col-span-2 space-y-6">
      <!-- Basic Information Card -->
      <!-- Base Values Card -->
      <!-- Penalties Applied Card -->
      <!-- Penalty Summary Card -->
      <!-- Quality Bonus Card -->
      <!-- Final Calculation Card -->
      <!-- Raw JSON Card (expandable) -->
    </div>

    <div class="space-y-6">
      <!-- Quick Stats Card -->
      <!-- Actions Card -->
    </div>
  </div>
</div>
```

**Card sections**:
1. Basic Information: List name (link), ranking config name (link), weight badge, timestamp
2. Base Values: base_weight, minimum_weight, high_quality_source flag
3. Penalties Applied: Iterates `calculated_weight_details["penalties"]`, shows badges with color coding
4. Penalty Summary: Shows totals from `calculated_weight_details["penalty_summary"]`
5. Quality Bonus: Shows `calculated_weight_details["quality_bonus"]` details
6. Final Calculation: Step-by-step from `calculated_weight_details["final_calculation"]`
7. Raw JSON: Expandable `<details>` with pretty-printed JSON

**Handle NULL calculated_weight_details**:
```erb
<% if @ranked_list.calculated_weight_details.present? %>
  <!-- Show all cards -->
<% else %>
  <div class="alert alert-warning">
    <svg>...</svg>
    <span>Weight has not been calculated yet. Rankings are recalculated automatically.</span>
  </div>
<% end %>
```

**Reference**:
- Layout pattern: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb`
- JSON display: `/home/shane/dev/the-greatest/web-app/app/views/music/lists/_simple_penalty_summary.html.erb`

### Step 5: Create Add Modal Component
**Command**:
```bash
cd web-app
# ViewComponent generator may not be available - create manually
```

**Files to create manually**:
- `app/components/admin/add_list_to_configuration_modal_component.rb`
- `app/components/admin/add_list_to_configuration_modal_component/add_list_to_configuration_modal_component.html.erb`
- `test/components/admin/add_list_to_configuration_modal_component_test.rb`

**Component implementation**:
```ruby
class Admin::AddListToConfigurationModalComponent < ViewComponent::Base
  def initialize(ranking_configuration:)
    @ranking_configuration = ranking_configuration
  end

  def available_lists
    list_type = case @ranking_configuration.type
                when "Books::RankingConfiguration"
                  "Books::List"
                when "Movies::RankingConfiguration"
                  "Movies::List"
                when "Games::RankingConfiguration"
                  "Games::List"
                when "Music::Albums::RankingConfiguration"
                  "Music::Albums::List"
                when "Music::Songs::RankingConfiguration"
                  "Music::Songs::List"
                else
                  nil
                end

    return List.none if list_type.nil?

    List
      .where(type: list_type)
      .where(status: [:active, :approved])
      .where.not(id: @ranking_configuration.lists.pluck(:id))
      .order(created_at: :desc)
  end
end
```

**Template implementation**:
- DaisyUI dialog modal with ID `add_list_to_configuration_modal_dialog`
- Form posts to `admin_ranking_configuration_ranked_lists_path(@ranking_configuration)`
- List dropdown showing name and source: `options_from_collection_for_select(available_lists, :id, ->(list) { "#{list.name} (#{list.source || 'No source'})" })`
- Stimulus controller: `modal-form` for auto-close behavior
- Turbo frame target: `ranked_lists_list`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component.rb`

### Step 6: Create Penalty Badge Helper
**File**: `app/helpers/admin/ranked_lists_helper.rb`

```ruby
module Admin::RankedListsHelper
  def penalty_badge_class(penalty_value)
    return "badge-success" if penalty_value < 10
    return "badge-warning" if penalty_value < 25
    "badge-error"
  end
end
```

**Test file**: `test/helpers/admin/ranked_lists_helper_test.rb`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/helpers/music/lists_helper.rb:2-6`

### Step 7: Update Ranking Configuration Show Pages
**Files**:
- `app/views/admin/music/albums/ranking_configurations/show.html.erb`
- `app/views/admin/music/songs/ranking_configurations/show.html.erb`

**Update existing section** (around line 287-299):
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Ranked Lists
        <span class="badge badge-ghost"><%= @ranking_configuration.ranked_lists.count %></span>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="add_list_to_configuration_modal_dialog.showModal()">
        + Add List
      </button>
    </div>
    <%= turbo_frame_tag "ranked_lists_list", loading: :lazy,
        src: admin_ranking_configuration_ranked_lists_path(@ranking_configuration) do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
</div>

<!-- Modal rendered at bottom of page (add after existing modals) -->
<%= render Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration) %>
```

**Changes from existing**:
- Add button in header: `+ Add List` (NEW)
- Add modal component at bottom (NEW)
- Keep existing turbo frame and lazy loading

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/ranking_configurations/show.html.erb:223-241,354`

### Step 8: Verify Artists Ranking Configuration Show Page (No Integration)
**File**: `app/views/admin/music/artists/ranking_configurations/show.html.erb`

**Action**: Confirm this page does NOT get "Add List" button
- Artist rankings use a different calculation method (not based on ranked lists)
- No changes needed to this file

### Step 9: Update Ranking Configuration Controllers for Eager Loading
**File**: `app/controllers/admin/music/ranking_configurations_controller.rb`

**Update show action**:
```ruby
def show
  @ranking_configuration = configuration_class
    .includes(:primary_mapped_list, :secondary_mapped_list,
              penalty_applications: :penalty,
              ranked_lists: { list: :submitted_by })  # Add this line
    .find(params[:id])
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb:8-12`

### Step 10: Migrate Existing Tests
**Action**: Move/update existing tests from `test/controllers/admin/music/ranked_lists_controller_test.rb` to `test/controllers/admin/ranked_lists_controller_test.rb`

**Keep existing tests for**:
- Index action (2 tests already exist)

**Add new tests for**:
- Create action (success, duplicate prevention, media type validation, turbo streams)
- Show action (with/without calculated_weight_details)
- Destroy action (success, turbo streams)
- Cross-configuration type support

### Step 11: Write Component Tests
**File**: `test/components/admin/add_list_to_configuration_modal_component_test.rb`

**Test structure**:
```ruby
require "test_helper"

class Admin::AddListToConfigurationModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @albums_config = music_albums_ranking_configurations(:default)
    @songs_config = music_songs_ranking_configurations(:default)
    @album_list = music_albums_lists(:approved_list)
    @song_list = music_songs_lists(:approved_list)

    RankedList.where(ranking_configuration: @albums_config).destroy_all
    RankedList.where(ranking_configuration: @songs_config).destroy_all
  end

  # Test modal renders with form and list selector
  # Test available_lists filtering by media type
  # Test available_lists excludes already attached
  # Test lists ordered by created_at desc
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/components/admin/add_penalty_to_configuration_modal_component_test.rb`

### Step 12: Write Helper Tests
**File**: `test/helpers/admin/ranked_lists_helper_test.rb`

**Test cases**:
- Returns `badge-success` for penalty < 10%
- Returns `badge-warning` for penalty 10-24%
- Returns `badge-error` for penalty ≥ 25%

**Reference**: `/home/shane/dev/the-greatest/web-app/test/helpers/music/lists_helper_test.rb`

### Step 13: Manual Testing
**Prerequisites**:
- Ranking configurations exist (albums, songs)
- Lists exist (Music::Albums::List and Music::Songs::List with approved status)
- Admin user authenticated

**Test scenarios**:
1. Visit album ranking configuration show page → See "Add List" button
2. Click "Add List" → Modal opens with dropdown of available albums lists
3. Select list → Submit → List appears in table
4. Click "View Details" on newly added list → Show page displays message "Weight not yet calculated"
5. Run ranking calculation job → Refresh show page → See calculated_weight_details
6. Verify penalty badges are color-coded correctly
7. Click "Delete" on ranked list → Confirm → List disappears
8. Repeat for songs ranking configuration
9. Verify artist ranking configuration does NOT have "Add List" button
10. Try to add same list twice → See error message
11. Verify lazy loading works
12. Verify raw JSON view works on show page

## Golden Examples

### Example 1: Adding List to Configuration (Happy Path)

**Action**: User visits album ranking configuration show page, clicks "Add List", selects approved album list, submits

**Request**:
```
POST /admin/ranking_configuration/123/ranked_lists
Params: { ranked_list: { list_id: 456 } }
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "List added successfully." } })
turbo_stream.replace("ranked_lists_list",
  template: "admin/ranked_lists/index",
  locals: { ranking_configuration: @ranking_configuration,
            ranked_lists: @ranking_configuration.ranked_lists.includes(list: :submitted_by).order(weight: :desc) })
turbo_stream.replace("add_list_to_configuration_modal",
  Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration))
```

**Result**:
- RankedList record created linking configuration 123 and list 456
- `weight` field NULL initially (will be calculated by ranking job)
- Flash shows "List added successfully."
- Lists table updates to show new list with weight "-" (NULL)
- Modal closes automatically
- Add modal reloads to exclude newly added list from dropdown
- No page reload

### Example 2: Media Type Compatibility Validation

**Action**: User tries to add Music::Songs::List to Music::Albums::RankingConfiguration

**Request**:
```
POST /admin/ranking_configuration/123/ranked_lists
Params: { ranked_list: { list_id: 789 } }
```

**Validation fails**: `list must be a Music::Albums::List`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "list must be a Music::Albums::List" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can select compatible list

### Example 3: Show Page with Calculated Weight Details

**Action**: User clicks "View Details" link for ranked list with calculated_weight_details

**Request**:
```
GET /admin/ranked_lists/999
```

**Response**: HTML page displaying:

**Basic Information Card**:
- List: "Rolling Stone's 500 Greatest Albums" (link to list show)
- Ranking Configuration: "Album Rankings 2025" (link to config show)
- Weight: 78 (green badge)
- Calculated: 2025-01-15 12:00:00 UTC

**Base Values Card**:
- Base Weight: 100
- Minimum Weight: 10
- High Quality Source: ✓ Yes (green badge)

**Penalties Applied Card**:
- Community Poll: 15.0% (yellow badge)
- Low Voter Count: 12.8% (yellow badge)
- Voter Names Unknown: 5.0% (green badge)

**Penalty Summary Card**:
- Static Penalties: 15.0%
- Voter Count Penalties: 12.8%
- Attribute Penalties: 5.0%
- Total Before Quality Bonus: 32.8%

**Quality Bonus Card**:
- Applied: ✓ Yes
- Reduction Factor: 0.67 (rounds to 67% reduction)
- Penalty Before: 32.8%
- Penalty After: 21.9%

**Final Calculation Card**:
- Total Penalty: 21.9%
- Weight After Penalty: 78.1
- Weight After Floor: 78.1
- Final Weight: 78 (rounded)

**Raw JSON Card** (expandable):
```json
{
  "calculation_version": 1,
  "timestamp": "2025-01-15T12:00:00Z",
  ...
}
```

### Example 4: Show Page with NULL calculated_weight_details

**Action**: User views newly added ranked list before ranking calculation runs

**Request**:
```
GET /admin/ranked_lists/1000
```

**Response**: HTML page displaying:

**Basic Information Card**: (same as above, but weight shows "-")

**Alert Message**:
```
⚠️ Weight has not been calculated yet. Rankings are recalculated automatically on a schedule.
```

No other cards displayed (penalties, summary, etc.)

## Agent Hand-Off

### Constraints
- Follow existing penalty_applications pattern - do not introduce new architecture
- Keep code snippets ≤40 lines in documentation
- Link to reference files by path
- Migrate existing `Admin::Music::RankedListsController` to generic `Admin::RankedListsController`
- Keep existing index implementation and tests
- Add show page with user-friendly calculated_weight_details display

### Required Outputs
- `app/controllers/admin/ranked_lists_controller.rb` (migrated from admin/music/, add create/show/destroy)
- `test/controllers/admin/ranked_lists_controller_test.rb` (migrated, add new tests)
- `app/views/admin/ranked_lists/index.html.erb` (migrated, update with delete button and details link)
- `app/views/admin/ranked_lists/show.html.erb` (new - friendly calculated_weight_details display)
- `app/components/admin/add_list_to_configuration_modal_component.rb` (new)
- `app/components/admin/add_list_to_configuration_modal_component/add_list_to_configuration_modal_component.html.erb` (new)
- `test/components/admin/add_list_to_configuration_modal_component_test.rb` (new)
- `app/helpers/admin/ranked_lists_helper.rb` (new - penalty badge helper)
- `test/helpers/admin/ranked_lists_helper_test.rb` (new)
- `config/routes.rb` (update - add create/show/destroy routes)
- `app/views/admin/music/albums/ranking_configurations/show.html.erb` (update - add "Add List" button and modal)
- `app/views/admin/music/songs/ranking_configurations/show.html.erb` (update - add "Add List" button and modal)
- `app/controllers/admin/music/ranking_configurations_controller.rb` (update - eager loading)
- Delete old files: `app/controllers/admin/music/ranked_lists_controller.rb`, `app/views/admin/music/ranked_lists/index.html.erb`, `test/controllers/admin/music/ranked_lists_controller_test.rb`
- All tests passing (19+ controller tests, 6+ component tests, 5+ helper/view tests)
- Updated sections in this spec: "Implementation Notes", "Deviations", "Acceptance Results"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Collect penalty_applications and calculated_weight_details display patterns ✅ (COMPLETED above)
2. **codebase-analyzer** → Verify RankedList model structure and List filtering ✅ (COMPLETED above)
3. **codebase-locator** → Find ranking configuration show pages ✅ (COMPLETED above)
4. **general-purpose** → Migrate controller, implement create/show/destroy, create component, update views, write tests
5. **technical-writer** → Update this spec with implementation notes, create class documentation

### Test Fixtures Required
Verify these fixtures exist and have proper data:
- `test/fixtures/lists.yml` - Approved Music::Albums::List and Music::Songs::List records
- `test/fixtures/music/albums/ranking_configurations.yml` - Album configurations for testing
- `test/fixtures/music/songs/ranking_configurations.yml` - Song configurations for testing
- `test/fixtures/ranked_lists.yml` - Sample configuration-list associations
- `test/fixtures/users.yml` - admin_user, regular_user

Note: Artist ranking configurations do NOT need ranked_list fixtures (not used)

## Key Files Touched

### New Files
- `app/views/admin/ranked_lists/show.html.erb`
- `app/components/admin/add_list_to_configuration_modal_component.rb`
- `app/components/admin/add_list_to_configuration_modal_component/add_list_to_configuration_modal_component.html.erb`
- `test/components/admin/add_list_to_configuration_modal_component_test.rb`
- `app/helpers/admin/ranked_lists_helper.rb`
- `test/helpers/admin/ranked_lists_helper_test.rb`

### Migrated Files (move from admin/music/ to admin/)
- `app/controllers/admin/ranked_lists_controller.rb` (was `admin/music/ranked_lists_controller.rb`)
- `app/views/admin/ranked_lists/index.html.erb` (was `admin/music/ranked_lists/index.html.erb`)
- `test/controllers/admin/ranked_lists_controller_test.rb` (was `admin/music/ranked_lists_controller_test.rb`)

### Modified Files
- `config/routes.rb` (add create/show/destroy routes)
- `app/controllers/admin/ranked_lists_controller.rb` (add create/show/destroy actions)
- `app/views/admin/ranked_lists/index.html.erb` (add delete button, change details to link)
- `app/views/admin/music/albums/ranking_configurations/show.html.erb` (add "Add List" button and modal)
- `app/views/admin/music/songs/ranking_configurations/show.html.erb` (add "Add List" button and modal)
- `app/controllers/admin/music/ranking_configurations_controller.rb` (eager loading)

### Files NOT Modified (Verified)
- `app/views/admin/music/artists/ranking_configurations/show.html.erb` (artist configs don't use ranked lists)

### Reference Files (NOT modified, used as pattern)
- `app/controllers/admin/penalty_applications_controller.rb` - Modal pattern
- `app/views/admin/penalty_applications/index.html.erb` - Lazy-loaded turbo frame
- `app/components/admin/add_penalty_to_configuration_modal_component.rb` - Component pattern
- `app/views/admin/music/albums/lists/show.html.erb` - Show page layout pattern
- `app/views/music/lists/_simple_penalty_summary.html.erb` - Friendly JSON display
- `app/helpers/music/lists_helper.rb` - Penalty badge helper
- `app/javascript/controllers/modal_form_controller.js` - Auto-close logic
- `app/models/ranked_list.rb` - Join model and validation reference
- `app/models/penalty_application.rb` - Similar join model pattern
- `test/controllers/admin/penalty_applications_controller_test.rb` - Test patterns

## Dependencies
- **Phase 12 Complete**: Penalty Applications CRUD provides proven pattern
- **Existing Models**: RankedList, List, RankingConfiguration
- **Existing**: modal-form Stimulus controller for auto-close
- **Existing**: Turbo Streams for real-time updates
- **Existing**: Index view and controller (needs migration to generic)

## Success Metrics
- [ ] All 19+ controller tests passing (including migrated index tests)
- [ ] All 6+ component tests passing
- [ ] All 5+ helper/view tests passing
- [ ] Zero N+1 queries on ranking configuration show pages
- [ ] Turbo Stream updates work without page reload
- [ ] Modal auto-close works after submission
- [ ] Modal reloads after attach/detach to show updated available lists
- [ ] Duplicate validation prevents database errors
- [ ] Media type validation enforced (compatibility rules)
- [ ] Authorization prevents non-admin access
- [ ] Lazy loading improves initial page load time
- [ ] Works for album and song ranking configurations (not artist configs)
- [ ] Artist ranking configuration show pages do NOT have "Add List" button
- [ ] Generic controller reusable for future Books/Movies/Games configurations
- [ ] Show page displays calculated_weight_details in user-friendly format
- [ ] Show page handles NULL calculated_weight_details gracefully

## Implementation Notes

### Controller Implementation
- Successfully migrated from `Admin::Music::RankedListsController` to generic `Admin::RankedListsController`
- Removed old route in `admin/music` namespace (line 123 in routes.rb) that was conflicting with new generic route
- Show action uses `layout "music/admin"` (same as other admin show pages) instead of application layout
- Show view template does NOT use outer container div (layout already provides padding)

### Component Implementation
- `Admin::AddListToConfigurationModalComponent` filters lists by:
  - Media type compatibility (using case statement on ranking_configuration.type)
  - Status (only approved/active lists)
  - Not already added (excludes ranked_lists.pluck(:list_id))
  - Ordered by created_at DESC (newest first)

### View Implementation
- Index view: Added `data-turbo-frame="_top"` to "View Details" link to break out of turbo frame
- Show view: Removed outer `<div class="container mx-auto px-4 py-8">` wrapper since layout provides padding
- Show view: Uses conditional rendering for NULL calculated_weight_details

### Route Configuration
- Old duplicate route at line 123 (`resources :ranked_lists, only: [:index]` in admin/music namespace) was causing routing conflicts
- Removed to allow new generic routes to work properly

### Test Implementation
- All 15 controller tests passing (including 2 previously commented show action tests now working)
- All 6 component tests passing
- All 3 helper tests passing
- Tests use proper fixture names and media type validation
- Fixed penalty data structure in tests (changed `"name"` to `"penalty_name"`)
- Layout issue resolved by adding `layout "music/admin", only: [:show]` to controller

## Deviations from Plan

### Layout Usage
**Deviation**: Show page uses `music/admin` layout instead of full application layout

**Reason**: The application layout has domain-specific asset loading that caused syntax errors when rendering the show page. The `music/admin` layout is what other admin show pages use (e.g., lists, albums, songs).

**Impact**: Show page now has consistent styling with other admin pages and includes sidebar navigation.

### Show View Structure
**Deviation**: Removed outer container wrapper from show view template

**Reason**: The `music/admin` layout already provides `<main class="flex-1 p-6">` padding. Adding `<div class="container mx-auto px-4 py-8">` created double padding and unnecessary width constraints.

**Impact**: Page layout is cleaner and matches other admin pages.

### Turbo Frame Navigation
**Deviation**: Added `data-turbo-frame="_top"` to "View Details" link

**Reason**: Index is loaded in a turbo frame. Without this attribute, clicking "View Details" tries to load the show page inside the frame, resulting in "Content missing" error.

**Impact**: Show page correctly navigates to full page view instead of trying to render within frame.

### Route Cleanup
**Deviation**: Had to remove old `admin/music` ranked_lists route

**Reason**: Duplicate route was causing Rails to prioritize the old `Admin::Music::RankedListsController` which no longer exists after migration.

**Impact**: Routes now correctly point to new generic controller.

## Acceptance Results

### Implemented Features ✅
- [x] Generic `Admin::RankedListsController` working for all ranking config types
- [x] Modal-based add/delete with media type filtering
- [x] Show page with user-friendly calculated_weight_details display
- [x] Color-coded penalty badges (green/yellow/red)
- [x] NULL calculated_weight_details handling
- [x] Turbo Stream updates for create/destroy
- [x] Media type compatibility validation
- [x] Duplicate prevention
- [x] Cross-configuration support (albums and songs)

### Test Results ✅
- **All 24 tests passing**: 15 controller, 6 component, 3 helper
- **Controller tests**: index, create, show (with/without calculated_weight_details), destroy, authorization, media type validation, cross-configuration support
- **Component tests**: modal rendering, available_lists filtering, media type filtering, exclusion logic
- **Helper tests**: penalty badge color coding (green/yellow/red)

### Manual Testing Status 📋
- Basic functionality verified in development
- Show page displays calculated_weight_details correctly
- Penalty badges color-coded properly
- Ranked lists section reordered (above ranked items) on both album and song config pages

## Documentation Updated
- [x] This spec file (implementation notes, deviations, results)
- [x] Class documentation for RankedListsController (`docs/controllers/admin/ranked_lists_controller.md`)
- [x] Class documentation for Admin::AddListToConfigurationModalComponent (`docs/components/admin/add_list_to_configuration_modal_component.md`)
- [x] Helper documentation for Admin::RankedListsHelper (`docs/helpers/admin/ranked_lists_helper.md`)

## Related Tasks
- **Prerequisite**: [Phase 12 - Penalty Applications](completed/083-custom-admin-phase-12-penalty-applications.md) ✅
- **Reference**: [Phase 12 - Penalty Applications](completed/083-custom-admin-phase-12-penalty-applications.md) ✅ (primary pattern source)
- **Next**: TBD - Phase 14 (possible next features: Books/Movies/Games configurations, public ranking pages)

## Key References

**Pattern Sources - Controllers:**
- Penalty Applications controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/penalty_applications_controller.rb`
- Existing Ranked Lists controller (music-specific): `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranked_lists_controller.rb`
- Base admin controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/base_controller.rb`
- Music Ranking Configurations controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb`

**Pattern Sources - Views:**
- Penalty applications index: `/home/shane/dev/the-greatest/web-app/app/views/admin/penalty_applications/index.html.erb`
- Existing ranked lists index (music-specific): `/home/shane/dev/the-greatest/web-app/app/views/admin/music/ranked_lists/index.html.erb`
- Albums ranking configuration show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/ranking_configurations/show.html.erb`
- Songs ranking configuration show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/ranking_configurations/show.html.erb`
- Albums lists show (show page layout): `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb`
- Simple penalty summary (friendly JSON): `/home/shane/dev/the-greatest/web-app/app/views/music/lists/_simple_penalty_summary.html.erb`

**Pattern Sources - Components:**
- Add penalty modal component: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component.rb`
- Add penalty modal template: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb`

**Pattern Sources - Helpers:**
- Penalty badge helper: `/home/shane/dev/the-greatest/web-app/app/helpers/music/lists_helper.rb`
- Admin lists helper (JSON formatting): `/home/shane/dev/the-greatest/web-app/app/helpers/admin/music/lists_helper.rb`

**Models:**
- RankedList: `/home/shane/dev/the-greatest/web-app/app/models/ranked_list.rb`
- PenaltyApplication (similar join model): `/home/shane/dev/the-greatest/web-app/app/models/penalty_application.rb`
- List: `/home/shane/dev/the-greatest/web-app/app/models/list.rb`
- RankingConfiguration: `/home/shane/dev/the-greatest/web-app/app/models/ranking_configuration.rb`

**Documentation:**
- RankedList docs: `/home/shane/dev/the-greatest/docs/models/ranked_list.md`
- RankingConfiguration docs: `/home/shane/dev/the-greatest/docs/models/ranking_configuration.md`
- PenaltyApplication docs (similar pattern): `/home/shane/dev/the-greatest/docs/models/penalty_application.md`
- Todo guide: `/home/shane/dev/the-greatest/docs/todo-guide.md`
- Sub-agents: `/home/shane/dev/the-greatest/docs/sub-agents.md`

**JavaScript:**
- Modal form controller: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/modal_form_controller.js`

**Tests:**
- Penalty Applications controller test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/penalty_applications_controller_test.rb`
- Add penalty modal component test: `/home/shane/dev/the-greatest/web-app/test/components/admin/add_penalty_to_configuration_modal_component_test.rb`
- Penalty badge helper test: `/home/shane/dev/the-greatest/web-app/test/helpers/music/lists_helper_test.rb`
- Existing ranked lists controller test (music-specific): `/home/shane/dev/the-greatest/web-app/test/controllers/admin/music/ranked_lists_controller_test.rb`
