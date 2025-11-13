# 077 - Custom Admin Interface - Phase 6: Music Ranking Configurations

## Status
- **Status**: 🔄 In Progress
- **Priority**: High
- **Created**: 2025-11-12
- **Started**: TBD
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin CRUD interface for Music::Albums::RankingConfiguration and Music::Songs::RankingConfiguration. This phase is critical as ranking configurations are the heart of The Greatest application. Replace Avo ranking configuration resources and actions with custom Rails admin built on ViewComponents + Hotwire (Turbo + Stimulus).

## Context
- **Phase 1-5 Complete**: Artists, Albums, Song Artists, Album Artists admin interfaces completed
- **Core Application Feature**: Ranking configurations drive the entire ranking system
- **Two Avo Actions**: BulkCalculateWeights, RefreshRankings need conversion
- **Association Management**: Need inline pagination for ranked_items and ranked_lists (25 per page)
- **Shared Code**: Most code shared between albums and songs via base controller
- **Note**: Artists ranking config NOT included (uses different calculation strategy)

## Requirements

### Base Ranking Configuration Infrastructure
- [ ] Shared base controller for ranking configuration CRUD
- [ ] Music::Albums::RankingConfiguration controller extending base
- [ ] Music::Songs::RankingConfiguration controller extending base
- [ ] Shared RankedItemsController for inline pagination (handles both Albums and Songs)
- [ ] Shared RankedListsController for inline pagination (handles both Albums and Songs)

### Music::Albums::RankingConfiguration CRUD
- [ ] Index page with table view
  - [ ] Display: ID, Name, Primary flag, Global flag, Algorithm Version, Published At
  - [ ] Search by name
  - [ ] Pagination (Pagy, 25 items)
  - [ ] Sort by columns (name, algorithm_version, published_at, created_at)
  - [ ] Badge indicators for primary/global/archived status
- [ ] Show page
  - [ ] All configuration fields displayed
  - [ ] Algorithm parameters (exponent, bonus_pool_percentage, min_list_weight)
  - [ ] Penalty configuration (apply_list_dates_penalty, max_age, max_percentage)
  - [ ] Mapped lists (primary_mapped_list, secondary_mapped_list)
  - [ ] **ranked_items** section with inline Turbo Frame pagination (25 per page)
  - [ ] **ranked_lists** section with inline Turbo Frame pagination (25 per page)
  - [ ] Action buttons (BulkCalculateWeights, RefreshRankings)
- [ ] New/Create
  - [ ] Form with all editable fields
  - [ ] Boolean toggles for flags
  - [ ] Number inputs for algorithm parameters
  - [ ] Validation error display
- [ ] Edit/Update
  - [ ] Same form as New
  - [ ] Pre-populated values
- [ ] Destroy
  - [ ] Confirmation dialog (Turbo Frame)
  - [ ] Warning about dependent ranked_items and ranked_lists destruction

### Music::Songs::RankingConfiguration CRUD
- [ ] Same as Albums (shares base controller)
- [ ] Domain-specific: Uses Music::Songs::List for ranked_lists
- [ ] Domain-specific: Uses Music::Song for ranked_items

### Admin Actions System
- [ ] Two ranking configuration actions to replicate:
  1. **BulkCalculateWeights** (index-level action)
  2. **RefreshRankings** (single record action)

### RankedItems Inline Display
- [ ] Turbo Frame pagination (25 items per page)
- [ ] Display: Rank, Item (album/song name + link), Score
- [ ] Sortable by rank or score
- [ ] Load via AJAX without full page refresh
- [ ] Empty state when no rankings calculated

### RankedLists Inline Display
- [ ] Turbo Frame pagination (25 lists per page)
- [ ] Display: List Name (linked), Weight, Calculated Weight Details
- [ ] Sortable by weight
- [ ] Load via AJAX without full page refresh
- [ ] Empty state when no lists included

## Technical Approach

### 1. Routing & Controllers

#### Routes Structure
```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  namespace :admin, module: "admin/music" do
    # ... existing routes ...

    # Ranking Configurations - Albums
    namespace :albums do
      resources :ranking_configurations do
        member do
          post :execute_action  # For single-record actions
        end
        collection do
          post :index_action    # For index-level actions
        end
      end
    end

    # Ranking Configurations - Songs
    namespace :songs do
      resources :ranking_configurations do
        member do
          post :execute_action
        end
        collection do
          post :index_action
        end
      end
    end

    # Shared resources for inline pagination (used by both Albums and Songs)
    # Uses parametric scope to include ranking_configuration_id in path
    scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
      resources :ranked_items, only: [:index]
      resources :ranked_lists, only: [:index]
    end
  end
end
```

**Generated paths:**
- Albums: `admin_albums_ranking_configurations_path` → `/admin/albums/ranking_configurations`
- Songs: `admin_songs_ranking_configurations_path` → `/admin/songs/ranking_configurations`
- Ranked Items: `admin_music_ranking_configuration_ranked_items_path(@config)` → `/admin/music/ranking_configuration/1/ranked_items`
- Ranked Lists: `admin_music_ranking_configuration_ranked_lists_path(@config)` → `/admin/music/ranking_configuration/1/ranked_lists`

### 2. Controller Architecture

#### Base Controller Pattern
**File**: `app/controllers/admin/music/ranking_configurations_controller.rb`

**Responsibilities:**
- Shared CRUD logic (index, show, new, create, edit, update, destroy)
- Action execution endpoints (execute_action, index_action)
- Search and pagination logic
- Sortable columns whitelist

**Protected Methods to Override:**
- `ranking_configuration_class` - Returns `Music::Albums::RankingConfiguration` or `Music::Songs::RankingConfiguration`
- `ranking_configurations_path` - Returns path helper for index
- `ranking_configuration_path(config)` - Returns path helper for show

#### Albums Controller
**File**: `app/controllers/admin/music/albums/ranking_configurations_controller.rb`

```ruby
module Admin
  module Music
    module Albums
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        protected

        def ranking_configuration_class
          ::Music::Albums::RankingConfiguration
        end

        def ranking_configurations_path
          admin_albums_ranking_configurations_path
        end

        def ranking_configuration_path(config)
          admin_albums_ranking_configuration_path(config)
        end
      end
    end
  end
end
```

#### Songs Controller
**File**: `app/controllers/admin/music/songs/ranking_configurations_controller.rb`

Same pattern as Albums, returns Songs-specific classes and paths.

#### RankedItems Controller (Shared)
**File**: `app/controllers/admin/music/ranked_items_controller.rb`

**Note**: Single controller handles both Albums and Songs. Determines type from parent RankingConfiguration.

**Responsibilities:**
- Index action only (for inline pagination)
- Finds parent RankingConfiguration from query param
- Responds with Turbo Frame partial
- Supports sorting (rank, score)
- Pagy pagination (25 items)

**Endpoint contract:**

| Verb | Path | Purpose | Params | Response |
|------|------|---------|--------|----------|
| GET | /admin/music/ranking_configuration/:ranking_configuration_id/ranked_items | Paginated ranked items | page, sort | Turbo Frame HTML partial |

**Implementation approach:**
```ruby
class Admin::Music::RankedItemsController < Admin::Music::BaseController
  def index
    @ranking_config = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_items = @ranking_config.ranked_items
      .includes(:item)
      .order(sortable_column(params[:sort]))

    @pagy, @ranked_items = pagy(@ranked_items, items: 25)

    # View determines display based on @ranking_config.type
    # Or use conditional partial rendering
  end
end
```

**Query:**
- Find parent RankingConfiguration by `:ranking_configuration_id` path param
- Eager load `item` association
- Default sort: rank ascending
- Pagination: 25 per page

#### RankedLists Controller (Shared)
**File**: `app/controllers/admin/music/ranked_lists_controller.rb`

**Note**: Single controller handles both Albums and Songs. Determines type from parent RankingConfiguration.

**Responsibilities:**
- Index action only (for inline pagination)
- Finds parent RankingConfiguration from query param
- Responds with Turbo Frame partial
- Supports sorting (weight)
- Pagy pagination (25 lists)

**Endpoint contract:**

| Verb | Path | Purpose | Params | Response |
|------|------|---------|--------|----------|
| GET | /admin/music/ranking_configuration/:ranking_configuration_id/ranked_lists | Paginated ranked lists | page, sort | Turbo Frame HTML partial |

**Implementation approach:**
```ruby
class Admin::Music::RankedListsController < Admin::Music::BaseController
  def index
    @ranking_config = RankingConfiguration.find(params[:ranking_configuration_id])
    @ranked_lists = @ranking_config.ranked_lists
      .includes(:list)
      .order(sortable_column(params[:sort]))

    @pagy, @ranked_lists = pagy(@ranked_lists, items: 25)

    # View determines display based on @ranking_config.type
  end
end
```

**Query:**
- Find parent RankingConfiguration by `:ranking_configuration_id` path param
- Eager load `list` association
- Default sort: weight descending
- Pagination: 25 per page

### 3. Ranking Configuration Actions

#### Action 1: BulkCalculateWeights
**File**: `app/lib/actions/admin/music/bulk_calculate_weights.rb`

**Class method metadata:**
- `name` → "Bulk Calculate Weights"
- `message` → "Recalculate weights for all ranked lists in the selected configurations."
- `visible?(context)` → true when `context[:view] == :index`

**Contract:**
```ruby
# Input
{
  user: User,
  models: [RankingConfiguration, ...],
  fields: {}
}

# Success Output
ActionResult.new(
  status: :success,
  message: "Weight calculation queued for #{count} configurations."
)

# Error Output
ActionResult.new(
  status: :error,
  message: "No configurations selected."
)
```

**Implementation:**
- Iterates selected configurations
- Calls `Services::RankingConfiguration::CalculateWeights.call(config)` for each
- Returns success with count or error

**Service delegation:**
**File**: `app/lib/services/ranking_configuration/calculate_weights.rb`

**Algorithm:**
1. Get all ranked_lists for configuration
2. For each ranked_list:
   - Calculate base_weight using median voter count
   - Apply dynamic penalties
   - Store in `calculated_weight_details` JSONB field
   - Update `weight` column
3. Return Result with success/errors

#### Action 2: RefreshRankings
**File**: `app/lib/actions/admin/music/refresh_rankings.rb`

**Class method metadata:**
- `name` → "Refresh Rankings"
- `message` → "Recalculate rankings using current configuration and weights."
- `visible?(context)` → true when `context[:view] == :show`

**Contract:**
```ruby
# Input
{
  user: User,
  models: [RankingConfiguration],
  fields: {}
}

# Success Output
ActionResult.new(
  status: :success,
  message: "Ranking calculation queued for #{config.name}."
)

# Error Output
ActionResult.new(
  status: :error,
  message: "This action can only be performed on a single configuration."
)
```

**Implementation:**
- Validates single configuration
- Calls `config.calculate_rankings_async`
- Returns success with configuration name

### 4. View Structure

#### Index Page Components
**File**: `app/views/admin/music/albums/ranking_configurations/index.html.erb`
**File**: `app/views/admin/music/songs/ranking_configurations/index.html.erb`

**Layout:**
- Page header with "New Configuration" button
- Search component (by name)
- Index actions section (BulkCalculateWeights button)
- Turbo Frame wrapping table
- Pagination

**Table columns:**
- Checkbox (bulk selection)
- ID
- Name (linked to show)
- Status Badges (Primary, Global, Archived)
- Algorithm Version
- Published At
- Created At
- Actions (Edit, Delete)

**Badge indicators:**
```erb
<% if config.primary? %>
  <span class="badge badge-primary badge-sm">Primary</span>
<% end %>
<% if config.global? %>
  <span class="badge badge-info badge-sm">Global</span>
<% end %>
<% if config.archived? %>
  <span class="badge badge-warning badge-sm">Archived</span>
<% end %>
```

#### Show Page Structure
**File**: `app/views/admin/music/albums/ranking_configurations/show.html.erb`
**File**: `app/views/admin/music/songs/ranking_configurations/show.html.erb`

**Sections:**
1. **Header** - Name, badges, action dropdown (RefreshRankings)
2. **Basic Info Card**
   - Name, description, type
   - Primary, global, archived flags
   - Published at, created at
3. **Algorithm Configuration Card**
   - Algorithm version
   - Exponent
   - Bonus pool percentage
   - Min list weight
   - List limit
4. **Penalty Configuration Card**
   - Apply list dates penalty
   - Max list dates penalty age
   - Max list dates penalty percentage
5. **Mapped Lists Card** (if applicable)
   - Primary mapped list (linked)
   - Secondary mapped list (linked)
   - Primary cutoff limit
6. **Ranked Items Section**
   - Count badge
   - Turbo Frame with inline pagination
   - Sortable table (rank, item, score)
7. **Ranked Lists Section**
   - Count badge
   - Turbo Frame with inline pagination
   - Sortable table (list, weight, details)

#### Inline Pagination Pattern - Ranked Items

**Show page includes:**
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">
      Ranked Items
      <div class="badge badge-primary"><%= @config.ranked_items.count %></div>
    </h2>

    <%= turbo_frame_tag "ranked_items_list",
        src: admin_music_ranking_configuration_ranked_items_path(@config),
        loading: :lazy do %>
      <div class="flex justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
</div>
```

**Partial loaded via Turbo Frame:**
**File**: `app/views/admin/music/ranked_items/index.html.erb`

**Note**: Single view that conditionally renders based on `@ranking_config.type`, or uses helper methods to determine display logic for Albums vs Songs.

```erb
<%= turbo_frame_tag "ranked_items_list" do %>
  <% if @ranked_items.any? %>
    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>
              <%= link_to "Rank",
                  admin_music_ranking_configuration_ranked_items_path(@ranking_config, sort: "rank"),
                  data: { turbo_frame: "ranked_items_list" } %>
            </th>
            <th>Item</th>
            <th>
              <%= link_to "Score",
                  admin_music_ranking_configuration_ranked_items_path(@ranking_config, sort: "score"),
                  data: { turbo_frame: "ranked_items_list" } %>
            </th>
          </tr>
        </thead>
        <tbody>
          <% @ranked_items.each do |ranked_item| %>
            <tr>
              <td><%= ranked_item.rank %></td>
              <td>
                <% # Conditionally link based on item type %>
                <% if ranked_item.item.is_a?(Music::Album) %>
                  <%= link_to ranked_item.item.title,
                      admin_album_path(ranked_item.item),
                      data: { turbo_frame: "_top" } %>
                <% elsif ranked_item.item.is_a?(Music::Song) %>
                  <%= link_to ranked_item.item.title,
                      admin_song_path(ranked_item.item),
                      data: { turbo_frame: "_top" } %>
                <% end %>
              </td>
              <td><%= number_with_precision(ranked_item.score, precision: 2) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>

    <!-- Pagination -->
    <%= render "admin/shared/pagy_nav", pagy: @pagy, turbo_frame: "ranked_items_list" %>
  <% else %>
    <div class="text-center py-8 text-base-content/50">
      <p>No rankings calculated yet. Click "Refresh Rankings" to calculate.</p>
    </div>
  <% end %>
<% end %>
```

**Key aspects:**
- Lazy loading with `loading: :lazy` and loading spinner
- Sortable headers target same turbo frame
- Item links use `data: { turbo_frame: "_top" }` for full page navigation
- Pagination controls target turbo frame
- Empty state with CTA

#### Inline Pagination Pattern - Ranked Lists

Same pattern as Ranked Items, showing:
- List name (linked to list admin - Phase 7)
- Weight
- Calculated weight details (tooltip or collapsed JSON)

### 5. Form Pattern

#### New/Edit Form Structure
**File**: `app/views/admin/music/albums/ranking_configurations/_form.html.erb`
**File**: `app/views/admin/music/songs/ranking_configurations/_form.html.erb`

**Note**: These can be shared partials if they're identical, placed in a shared directory like `app/views/admin/music/shared/`.

**Sections:**
1. **Error summary** (if errors present)
2. **Basic Information Card**
   - Name (required)
   - Description (textarea)
   - Type (display only, not editable)
3. **Configuration Flags Card**
   - Primary (checkbox)
   - Global (checkbox)
   - Archived (checkbox)
   - Published at (datetime picker)
4. **Algorithm Parameters Card**
   - Algorithm version (number)
   - Exponent (decimal, 0.1 - 10.0)
   - Bonus pool percentage (decimal, 0 - 100)
   - Min list weight (integer, min: 1)
   - List limit (integer, optional)
5. **Penalty Configuration Card**
   - Apply list dates penalty (checkbox)
   - Max list dates penalty age (integer, years)
   - Max list dates penalty percentage (integer, 1-100)
6. **Mapped Lists Card** (optional)
   - Primary mapped list (autocomplete)
   - Secondary mapped list (autocomplete)
   - Primary cutoff limit (integer)
7. **Form actions** (Cancel, Submit)

**Field validations:**
- Name: required, max 255 chars
- Exponent: > 0, <= 10
- Bonus pool percentage: >= 0, <= 100
- Min list weight: integer, > 0
- Max penalty age: integer, > 0
- Max penalty percentage: integer, 1-100

### 6. Pagination Helper

#### Shared Pagy Navigation Partial
**File**: `app/views/admin/shared/_pagy_nav.html.erb`

```erb
<% if pagy.pages > 1 %>
  <div class="flex justify-center py-4">
    <div class="join">
      <% if pagy.prev %>
        <%= link_to "«", pagy_url_for(pagy, pagy.prev),
            class: "join-item btn btn-sm",
            data: { turbo_frame: turbo_frame } %>
      <% else %>
        <button class="join-item btn btn-sm btn-disabled">«</button>
      <% end %>

      <% pagy.series.each do |item| %>
        <% if item == :gap %>
          <button class="join-item btn btn-sm btn-disabled">...</button>
        <% elsif item == pagy.page %>
          <button class="join-item btn btn-sm btn-active"><%= item %></button>
        <% else %>
          <%= link_to item, pagy_url_for(pagy, item),
              class: "join-item btn btn-sm",
              data: { turbo_frame: turbo_frame } %>
        <% end %>
      <% end %>

      <% if pagy.next %>
        <%= link_to "»", pagy_url_for(pagy, pagy.next),
            class: "join-item btn btn-sm",
            data: { turbo_frame: turbo_frame } %>
      <% else %>
        <button class="join-item btn btn-sm btn-disabled">»</button>
      <% end %>
    </div>
  </div>
<% end %>
```

**Helper method:**
**File**: `app/helpers/admin_helper.rb`

```ruby
def pagy_url_for(pagy, page)
  # Preserve existing params and merge page number
  url_for(request.params.merge(page: page))
end
```

## Dependencies
- **Existing**: Tailwind CSS, DaisyUI, ViewComponents, Hotwire (Turbo + Stimulus), Pagy
- **Phase 1-5 Complete**: Artists, Albums, Songs, Album Artists, Song Artists admin
- **Existing Services**:
  - `RankingConfiguration#calculate_rankings_async` - Background ranking calculation
  - `ItemRankings::Music::Albums::Calculator` - Album ranking algorithm
  - `ItemRankings::Music::Songs::Calculator` - Song ranking algorithm
  - `CalculateRankingsJob` - Sidekiq job for ranking calculations
- **New Service**: `Services::RankingConfiguration::CalculateWeights` - Weight calculation logic

## Acceptance Criteria
- [ ] `/admin/albums_ranking_configurations` path shows index with search, sort, pagination
- [ ] `/admin/songs_ranking_configurations` path shows index with same features
- [ ] Ranking configuration show page displays all fields and configuration
- [ ] Ranking configuration new/create/edit/update/destroy CRUD operations work
- [ ] Two ranking configuration actions execute successfully:
  - [ ] BulkCalculateWeights (index-level action)
  - [ ] RefreshRankings (single record action)
- [ ] Ranked items section:
  - [ ] Loads inline via Turbo Frame (lazy)
  - [ ] Paginated (25 items per page)
  - [ ] Sortable by rank and score
  - [ ] Links to album/song admin pages work
  - [ ] Empty state displayed when no rankings
- [ ] Ranked lists section:
  - [ ] Loads inline via Turbo Frame (lazy)
  - [ ] Paginated (25 lists per page)
  - [ ] Sortable by weight
  - [ ] Weight details viewable
  - [ ] Empty state displayed when no lists
- [ ] Primary flag validation (only one per type)
- [ ] Authorization prevents non-admin/editor access
- [ ] All pages are responsive (mobile, tablet, desktop)
- [ ] N+1 queries prevented with eager loading
- [ ] Sort column SQL injection prevented with whitelist
- [ ] All tests passing with >95% coverage

## Agent Hand-Off

### Constraints
- Follow existing project patterns from Phase 1-5
- Do not introduce new architecture
- Respect snippet budget (≤40 lines per snippet)
- Link to authoritative code by path

### Required Outputs
- Base controller: `app/controllers/admin/music/ranking_configurations_controller.rb`
- Albums controller: `app/controllers/admin/music/albums/ranking_configurations_controller.rb`
- Songs controller: `app/controllers/admin/music/songs/ranking_configurations_controller.rb`
- Shared RankedItems controller: `app/controllers/admin/music/ranked_items_controller.rb`
- Shared RankedLists controller: `app/controllers/admin/music/ranked_lists_controller.rb`
- Two actions: BulkCalculateWeights, RefreshRankings
- Calculate weights service
- Index, show, new, edit views for both Albums and Songs
- Shared ranked items view with conditional rendering: `app/views/admin/music/ranked_items/index.html.erb`
- Shared ranked lists view with conditional rendering: `app/views/admin/music/ranked_lists/index.html.erb`
- Form partial shared between Albums and Songs (or domain-specific if needed)
- Updated routes in `config/routes.rb`
- Passing tests (controller, action, service tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Extract inline Turbo Frame pagination patterns from codebase
2. **codebase-analyzer** → Understand RankedItem and RankedList associations and queries
3. **avo-engineer** → Analyze Avo actions to understand BulkCalculateWeights and RefreshRankings behavior
4. **technical-writer** → Update class documentation and task file

### Test Fixtures Required
- Minimal ranking configuration fixtures (primary albums, primary songs)
- Ranked item fixtures (albums and songs)
- Ranked list fixtures (albums and songs)
- Keep fixtures small and focused

## Design Decisions

### Why Base Controller Pattern
- **Code Reuse**: Albums and Songs share 99% of logic
- **DRY Principle**: Override only class/path differences
- **Maintainability**: Changes apply to both automatically
- **Testing**: Test base controller thoroughly, subclasses minimally

### Why Shared RankedItems/RankedLists Controllers
- **DRY Principle**: Controller logic is identical - just find parent config and paginate
- **Parent Config Tells Type**: RankingConfiguration's `type` field already tells us if it's Albums or Songs
- **Simpler Architecture**: 2 controllers instead of 4, fewer routes to maintain
- **View Flexibility**: Views can still differ using conditional rendering or helper methods
- **Music Namespace**: Still domain-specific (Music vs Games vs Books) without being overly nested
- **Parametric Scope Pattern**: Uses Rails routing guide's official pattern for including parent ID in path
- **Clean URLs**: `/admin/music/ranking_configuration/1/ranked_items` is clear and RESTful
- **Path Helpers**: Clean helpers like `admin_music_ranking_configuration_ranked_items_path(@config)`

### Why Lazy Load Turbo Frames
- **Performance**: Show page loads instantly without waiting for ranking data
- **User Experience**: User sees configuration details immediately
- **Progressive Enhancement**: Rankings load in background
- **Large Datasets**: Ranking results can be thousands of items

### Why 25 Items Per Page
- **Consistency**: Matches Phase 1-5 pagination
- **Performance**: Fast queries even with complex joins
- **UX Balance**: Enough items to browse, not overwhelming
- **Mobile Friendly**: Scrollable on small screens

### Why Not Include Artists Ranking Config
- **Different Algorithm**: Artists use aggregation, not list-based ranking
- **No ranked_lists**: Artists don't have list associations
- **Simpler UI**: Artists only have ranked_items, no weight calculation
- **Deferred**: Artists ranking config admin in separate phase if needed

## Technical Approach - Additional Details

### 1. N+1 Prevention Strategy

**Base controller index:**
```ruby
# No associations to eager load - ranking configs are standalone
@configs = ranking_configuration_class.all
  .order(sortable_column(params[:sort]))

@pagy, @configs = pagy(@configs, items: 25)
```

**Base controller show:**
```ruby
# Eager load mapped lists only (ranked_items and ranked_lists loaded separately)
@config = ranking_configuration_class
  .includes(:primary_mapped_list, :secondary_mapped_list)
  .find(params[:id])
```

**RankedItems controller:**
```ruby
# Eager load polymorphic item association
@ranked_items = @config.ranked_items
  .includes(:item)
  .order(sortable_column(params[:sort]))

@pagy, @ranked_items = pagy(@ranked_items, items: 25)
```

**RankedLists controller:**
```ruby
# Eager load list association
@ranked_lists = @config.ranked_lists
  .includes(:list)
  .order(sortable_column(params[:sort]))

@pagy, @ranked_lists = pagy(@ranked_lists, items: 25)
```

### 2. Action Validation Rules

**BulkCalculateWeights:**
- Precondition: At least one configuration selected
- Postcondition: Weight calculation jobs queued
- Side effect: Updates `weight` and `calculated_weight_details` on ranked_lists

**RefreshRankings:**
- Precondition: Exactly one configuration selected
- Postcondition: Ranking calculation job queued
- Side effect: Updates/creates ranked_items with new ranks and scores

### 3. Error Handling

**Controller-level:**
- Invalid sort parameter → default to "name"
- Missing configuration ID → 404 Not Found
- Unauthorized access → redirect to root with alert
- Validation failure → render form with `:unprocessable_entity`

**Action-level:**
- No configurations selected → error message
- Multiple configurations for single-record action → error message
- Background job failure → logged, not shown to user immediately

### 4. Security Considerations

**Sort Parameter Whitelist:**
```ruby
def sortable_column(column)
  allowed_columns = {
    "id" => "ranking_configurations.id",
    "name" => "ranking_configurations.name",
    "algorithm_version" => "ranking_configurations.algorithm_version",
    "published_at" => "ranking_configurations.published_at",
    "created_at" => "ranking_configurations.created_at"
  }

  allowed_columns.fetch(column.to_s, "ranking_configurations.name")
end
```

**Strong Parameters:**
```ruby
def ranking_configuration_params
  params.require(:ranking_configuration).permit(
    :name,
    :description,
    :global,
    :primary,
    :archived,
    :published_at,
    :algorithm_version,
    :exponent,
    :bonus_pool_percentage,
    :min_list_weight,
    :list_limit,
    :apply_list_dates_penalty,
    :max_list_dates_penalty_age,
    :max_list_dates_penalty_percentage,
    :primary_mapped_list_id,
    :secondary_mapped_list_id,
    :primary_mapped_list_cutoff_limit
  )
end
```

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Phase 6 Implementation Steps

1. **Generate Controllers** ✅ / ❌
   ```bash
   cd web-app
   # Base controller (manual - no generator for abstract base)
   # Albums controller
   bin/rails generate controller Admin::Music::Albums::RankingConfigurations index show new edit
   # Songs controller
   bin/rails generate controller Admin::Music::Songs::RankingConfigurations index show new edit
   # Shared resources (used by both Albums and Songs)
   bin/rails generate controller Admin::Music::RankedItems index
   bin/rails generate controller Admin::Music::RankedLists index
   ```

2. **Create Actions and Service** ✅ / ❌
   - BulkCalculateWeights action class
   - RefreshRankings action class
   - CalculateWeights service class

3. **Build Views** ✅ / ❌
   - Index view (shared partial)
   - Show view (shared partial)
   - Form partial (shared)
   - Ranked items partial with Turbo Frame
   - Ranked lists partial with Turbo Frame
   - Pagy navigation partial

4. **Update Routes** ✅ / ❌
   - Add ranking configuration resources
   - Add nested ranked_items and ranked_lists routes
   - Add action endpoints

5. **Update Sidebar Navigation** ✅ / ❌
   - Add "Ranking Configs" submenu under Music section
   - Links to Albums and Songs ranking configuration indexes

6. **Testing & Refinement** ✅ / ❌
   - Manual testing of all CRUD operations
   - Test both actions
   - Test inline pagination (ranked items and lists)
   - Mobile responsiveness check
   - Automated test coverage (target: >95%)

### Approach Taken
*[Document approach decisions here]*

### Key Files Created
*[List all new files with paths]*

### Key Files Modified
*[List all modified files with what changed]*

### Challenges Encountered
*[Document any problems and solutions]*

### Deviations from Plan
*[Document any changes from original spec]*

### Testing Approach
*[Document testing strategy and results]*

### Performance Considerations
*[Document any performance optimizations or issues]*

### Future Improvements
*[Ideas for future enhancements]*

### Lessons Learned
*[Document learnings for future phases]*

## Related PRs
*[To be created when ready to merge]*

## Documentation Updated
- [ ] Class documentation for Admin::Music::RankingConfigurationsController (shared base)
- [ ] Class documentation for Admin::Music::Albums::RankingConfigurationsController
- [ ] Class documentation for Admin::Music::Songs::RankingConfigurationsController
- [ ] Class documentation for Admin::Music::RankedItemsController (shared)
- [ ] Class documentation for Admin::Music::RankedListsController (shared)
- [ ] Class documentation for Actions::Admin::Music::BulkCalculateWeights
- [ ] Class documentation for Actions::Admin::Music::RefreshRankings
- [ ] Class documentation for Services::RankingConfiguration::CalculateWeights
- [ ] This todo file with comprehensive implementation notes
- [ ] Updated main `docs/todo.md`

## Tests Created
- [ ] Admin::Music::RankingConfigurationsController base tests
- [ ] Admin::Music::Albums::RankingConfigurationsController tests
- [ ] Admin::Music::Songs::RankingConfigurationsController tests
- [ ] Admin::Music::RankedItemsController tests (for both Albums and Songs configs)
- [ ] Admin::Music::RankedListsController tests (for both Albums and Songs configs)
- [ ] Actions::Admin::Music::BulkCalculateWeights tests
- [ ] Actions::Admin::Music::RefreshRankings tests
- [ ] Services::RankingConfiguration::CalculateWeights tests
- **Target**: >95% coverage, all tests passing

## Next Phases

### Phase 7: Music Categories, Releases, Tracks (TODO #078)
- Admin::Music::CategoriesController
- Admin::Music::ReleasesController
- Admin::Music::TracksController
- Admin::Music::CreditsController

### Phase 8: Global Resources (TODO #079)
- Admin::PenaltiesController
- Admin::UsersController
- Admin::ListsController (Music::Albums::List, Music::Songs::List)

### Phase 9: Avo Removal (TODO #080)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files
- Update documentation

## Research References

### Turbo Frame Lazy Loading
- **Hotwire Docs**: https://turbo.hotwired.dev/reference/frames#lazy-loaded-frame
- **Loading States**: Use `loading: :lazy` attribute on turbo_frame_tag
- **Spinner Pattern**: Show loading spinner in frame until content loads

### Pagy Pagination
- **Documentation**: https://github.com/ddnexus/pagy
- **Turbo Frame Integration**: Pass turbo_frame parameter to links
- **Custom Navigation**: Create custom nav partial for DaisyUI styling

### Weight Calculation Algorithm
- **Dynamic Penalties**: Voter count, percentage western, voter names unknown
- **Median Voter Count**: Used as baseline for penalty calculation
- **JSONB Storage**: Store calculation details in `calculated_weight_details` field

## Additional Resources
- [Phase 1 Spec](completed/072-custom-admin-phase-1-artists.md) - Artists implementation
- [Phase 2 Spec](completed/073-custom-admin-phase-2-albums.md) - Albums implementation
- [RankingConfiguration Model Docs](../models/ranking_configuration.md) - Model reference
- [RankedItem Model Docs](../models/ranked_item.md) - Association reference
- [RankedList Model Docs](../models/ranked_list.md) - Association reference
- [DaisyUI Components](https://daisyui.com/components/) - UI component library
- [Pagy Documentation](https://github.com/ddnexus/pagy) - Pagination
- [Hotwire Handbook](https://hotwired.dev/) - Turbo + Stimulus patterns
