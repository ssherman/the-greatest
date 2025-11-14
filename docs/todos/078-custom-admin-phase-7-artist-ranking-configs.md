# 078 - Custom Admin Interface - Phase 7: Artist Ranking Configurations

## Status
- **Status**: 🔜 Not Started
- **Priority**: High
- **Created**: 2025-11-13
- **Started**: TBD
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin CRUD interface for Music::Artists::RankingConfiguration. This phase completes the ranking configuration admin interfaces, providing management for artist rankings which aggregate scores from albums and songs rather than processing lists directly.

## Context
- **Phase 1-6 Complete**: Artists, Albums, Song Artists, Album Artists, Songs, and Album/Song Ranking Configurations admin interfaces completed
- **Artist Rankings Implemented**: Artist ranking system exists with Avo actions attached to Artist resource (see `docs/todos/completed/061-artist-rankings.md`)
- **Simpler Structure**: Artist ranking configurations don't use ranked_lists since they aggregate from existing album/song rankings
- **Shared Base Controller**: Will extend `Admin::Music::RankingConfigurationsController` like albums/songs

## Requirements

### Artist Ranking Configuration CRUD
- [ ] Controller: `Admin::Music::Artists::RankingConfigurationsController` extending base
- [ ] Index page with table view
  - [ ] Display: ID, Name, Primary flag, Global flag, Archived flag, Published At
  - [ ] Search by name
  - [ ] Pagination (Pagy, 25 items)
  - [ ] Sort by columns (name, published_at, created_at)
  - [ ] Badge indicators for primary/global/archived status
- [ ] Show page
  - [ ] All configuration fields displayed
  - [ ] Note that algorithm parameters are inherited but not used (simple aggregation)
  - [ ] Note that list-related fields are inherited but not applicable
  - [ ] **ranked_items** section with inline Turbo Frame pagination (25 per page) - Artists only
  - [ ] **NO ranked_lists section** - Artists don't have ranked_lists
  - [ ] Action buttons (RefreshRankings only - no BulkCalculateWeights)
- [ ] New/Create
  - [ ] Form with relevant fields only (name, description, flags, published_at)
  - [ ] Omit or disable algorithm parameters (not used in aggregation)
  - [ ] Omit or disable list-related parameters (not applicable)
  - [ ] Boolean toggles for flags
  - [ ] Validation error display
- [ ] Edit/Update
  - [ ] Same simplified form as New
  - [ ] Pre-populated values
- [ ] Destroy
  - [ ] Confirmation dialog (Turbo Frame)
  - [ ] Warning about dependent ranked_items destruction

### Admin Actions System
- [ ] One ranking configuration action to replicate:
  1. **RefreshRankings** (single record action) - Already exists, needs integration

**Note on Actions:**
- BulkCalculateWeights is NOT applicable to artist rankings (no ranked_lists to calculate weights for)
- RefreshRankings already exists at `app/lib/actions/admin/music/refresh_rankings.rb` but may need adjustment
- Actions currently attached to Artist resource via Avo - need to work with ranking configuration instead

### RankedItems Inline Display
- [ ] Turbo Frame pagination (25 items per page)
- [ ] Display: Rank, Artist Name (linked to admin artist page), Score
- [ ] Fixed sort by rank ascending (no sortable columns needed)
- [ ] Load via AJAX without full page refresh
- [ ] Empty state when no rankings calculated

### Admin Navigation
- [ ] Update admin sidebar to include "Artist Rankings" link
- [ ] Add under "Ranking Configurations" submenu (alongside Albums, Songs)
- [ ] Link to `admin_artists_ranking_configurations_path`

### Key Differences from Albums/Songs
- **NO ranked_lists**: Artist rankings don't process lists, they aggregate from album/song rankings
- **NO BulkCalculateWeights action**: No list weights to calculate
- **Simplified form**: Many inherited fields are not used (algorithm params, list params)
- **Aggregation note**: Show page should explain that rankings aggregate from album + song rankings

## Technical Approach

### 0. Endpoint Contracts

| Verb | Path | Purpose | Params/Body | Auth | Response |
|------|------|---------|-------------|------|----------|
| GET | /admin/artists/ranking_configurations | Index page | page, q (search), sort | admin/editor | HTML |
| GET | /admin/artists/ranking_configurations/:id | Show page | id | admin/editor | HTML |
| GET | /admin/artists/ranking_configurations/new | New form | - | admin/editor | HTML |
| POST | /admin/artists/ranking_configurations | Create config | ranking_configuration params | admin/editor | Redirect (success) or 422 (errors) |
| GET | /admin/artists/ranking_configurations/:id/edit | Edit form | id | admin/editor | HTML |
| PATCH | /admin/artists/ranking_configurations/:id | Update config | id, ranking_configuration params | admin/editor | Redirect (success) or 422 (errors) |
| DELETE | /admin/artists/ranking_configurations/:id | Destroy config | id | admin/editor | Redirect with notice |
| POST | /admin/artists/ranking_configurations/:id/execute_action | Execute action | id, action_name | admin/editor | Turbo Stream or HTML redirect with ActionResult |
| POST | /admin/artists/ranking_configurations/index_action | Index-level action | action_name | admin/editor | Turbo Stream or HTML redirect with ActionResult |
| GET | /admin/music/ranking_configuration/:ranking_configuration_id/ranked_items | Paginated artists | ranking_configuration_id, page | admin/editor | HTML (Turbo Frame) |

**Notes:**
- All endpoints require authentication and admin/editor role
- execute_action used for RefreshRankings (show page)
- index_action minimal use (no BulkCalculateWeights for artists)
- ranked_items endpoint shared across all ranking configuration types

### 1. Routing & Controllers

#### Routes Structure
```ruby
# config/routes.rb

# Inside Music domain constraint
constraints DomainConstraint.new(Rails.application.config.domains[:music]) do
  namespace :admin, module: "admin/music" do
    # ... existing routes ...

    # Ranking Configurations - Artists
    namespace :artists do
      resources :ranking_configurations do
        member do
          post :execute_action  # For single-record actions
        end
        collection do
          post :index_action    # For index-level actions (minimal use)
        end
      end
    end

    # Shared resource for inline pagination
    scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
      resources :ranked_items, only: [:index]  # Already exists, will handle artists
    end
  end
end
```

**Generated paths:**
- Artists: `admin_artists_ranking_configurations_path` → `/admin/artists/ranking_configurations`
- Ranked Items: `admin_music_ranking_configuration_ranked_items_path(@config)` → `/admin/music/ranking_configuration/1/ranked_items`

### 2. Controller Architecture

#### Concrete Controller Implementation

**File**: `app/controllers/admin/music/artists/ranking_configurations_controller.rb`

```ruby
module Admin
  module Music
    module Artists
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        protected

        def ranking_configuration_class
          ::Music::Artists::RankingConfiguration
        end

        def ranking_configurations_path
          admin_artists_ranking_configurations_path
        end

        def ranking_configuration_path(config)
          admin_artists_ranking_configuration_path(config)
        end

        def table_partial_path
          "admin/music/artists/ranking_configurations/table"
        end
      end
    end
  end
end
```

**Key aspects:**
- Minimal subclass - only implements template methods
- Inherits all CRUD logic from `Admin::Music::RankingConfigurationsController`
- All standard endpoints work automatically (index, show, new, create, edit, update, destroy, execute_action, index_action)

#### Existing Shared Controller

**File**: `app/controllers/admin/music/ranked_items_controller.rb` (already exists)

**Note**: This controller already handles ranked items for all ranking configuration types including artists. The view conditionally renders based on `@ranking_config.type`.

#### Strong Parameters Contract

```ruby
# app/controllers/admin/music/artists/ranking_configurations_controller.rb
# (inherited from base, but documented here for clarity)

def ranking_configuration_params
  params.require(:ranking_configuration).permit(
    :name,              # Required, max 255 chars
    :description,       # Optional, text
    :global,            # Boolean - whether available to all users
    :primary,           # Boolean - whether this is the default config
    :archived,          # Boolean - whether configuration is archived
    :published_at       # DateTime - publication timestamp
  )
  # EXCLUDED: algorithm parameters (algorithm_version, exponent, bonus_pool_percentage,
  #           min_list_weight, list_limit) - not used by artist aggregation
  # EXCLUDED: penalty parameters (apply_list_dates_penalty, max_list_dates_penalty_age,
  #           max_list_dates_penalty_percentage) - not applicable to artists
  # EXCLUDED: mapped list parameters (primary_mapped_list_id, secondary_mapped_list_id,
  #           primary_mapped_list_cutoff_limit) - artists don't use mapped lists
end
```

**Validation Rules:**
- name: required, max 255 chars, unique per type
- primary: only one primary configuration allowed per type (validated by model)
- global: defaults to false

**No changes needed** - existing implementation at line 7 already includes artists via polymorphic item association.

### 3. Admin Actions

#### Action: RefreshRankings

**File**: `app/lib/actions/admin/music/refresh_rankings.rb` (already exists)

**Current implementation** (from research):
```ruby
module Actions
  module Admin
    module Music
      class RefreshRankings < Actions::Admin::BaseAction
        def self.name
          "Refresh Rankings"
        end

        def self.message
          "Recalculate rankings using current configuration and weights."
        end

        def self.visible?(context = {})
          context[:view] == :show
        end

        def call
          return error("This action can only be performed on a single configuration.") if models.count != 1

          config = models.first
          config.calculate_rankings_async

          succeed "Ranking calculation queued for #{config.name}."
        end
      end
    end
  end
end
```

**Assessment**: No changes needed. Action already works for all ranking configuration types via polymorphic pattern. The message "using current configuration and weights" is slightly misleading for artists (no weights involved) but acceptable.

**Alternative**: Create artist-specific action with updated message:
```ruby
# app/lib/actions/admin/music/refresh_artist_rankings.rb
# Message: "Recalculate artist rankings by aggregating album and song scores."
```

### 4. View Structure

#### Index Page Components
**File**: `app/views/admin/music/artists/ranking_configurations/index.html.erb`

**Layout** (similar to albums/songs with minor adjustments):
- Page header with "New Configuration" button
- Search component (by name)
- NO index-level actions section (BulkCalculateWeights not applicable)
- Turbo Frame wrapping table
- Pagination

**Table columns:**
- Checkbox (for potential future bulk operations)
- ID
- Name (linked to show)
- Status Badges (Primary, Global, Archived)
- Published At
- Created At
- Actions (Edit, Delete)

**Badge indicators** (same as albums/songs):
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
**File**: `app/views/admin/music/artists/ranking_configurations/show.html.erb`

**Sections:**
1. **Header** - Name, badges, action dropdown (RefreshRankings only)
2. **Basic Info Card**
   - Name, description, type
   - Primary, global, archived flags
   - Published at, created at
3. **Algorithm Configuration Card** (with note)
   - Display inherited algorithm parameters
   - Add informational note: "Note: These parameters are inherited from the base ranking configuration but not used for artist rankings. Artist rankings use simple aggregation (sum) of album and song scores."
4. **Ranking Source Card** (new, artist-specific)
   - Display: "Artist rankings aggregate from:"
   - Link to primary album ranking configuration
   - Link to primary song ranking configuration
   - Note: "Rankings are calculated by summing all album scores and song scores for each artist from these configurations."
5. **Ranked Items Section** (Artists only)
   - Count badge
   - Turbo Frame with inline pagination
   - Table: Rank, Artist Name (linked), Score
   - Empty state with explanation

**NO Ranked Lists Section** - Artists don't have ranked_lists

**NO Mapped Lists Card** - Not applicable to artists

**NO Penalty Configuration Card** - Artists don't use penalties

#### Simplified Form Pattern

**File**: `app/views/admin/music/artists/ranking_configurations/_form.html.erb`

**Sections:**
1. **Error summary** (if errors present)
2. **Basic Information Card**
   - Name (required)
   - Description (textarea)
   - Type (display only: "Music::Artists::RankingConfiguration")
3. **Configuration Flags Card**
   - Primary (checkbox)
   - Global (checkbox)
   - Archived (checkbox)
   - Published at (datetime picker)
4. **Inherited Parameters Note** (read-only info)
   - Display message: "This configuration inherits schema fields from the base RankingConfiguration model, but artist rankings use a simplified aggregation algorithm that sums album and song scores without applying exponential weighting, bonus pools, or list penalties."
   - DO NOT show editable fields for: algorithm_version, exponent, bonus_pool_percentage, min_list_weight, list_limit, penalty fields, mapped list fields
5. **Form actions** (Cancel, Submit)

**Field validations:**
- Name: required, max 255 chars
- Description: optional, text

**Simplified strong parameters:**
```ruby
def ranking_configuration_params
  params.require(:ranking_configuration).permit(
    :name,
    :description,
    :global,
    :primary,
    :archived,
    :published_at
  )
end
```

### 5. Inline Pagination Pattern - Ranked Items

**Show page includes:**
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <h2 class="card-title">
      Ranked Artists
      <div class="badge badge-primary"><%= @config.ranked_items.where(item_type: "Music::Artist").count %></div>
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
**File**: `app/views/admin/music/ranked_items/index.html.erb` (already exists)

**Update needed**: Existing view already handles multiple item types conditionally. Verify it properly handles `Music::Artist` item type:

```erb
<% if ranked_item.item.is_a?(Music::Artist) %>
  <%= link_to ranked_item.item.name,
      admin_artist_path(ranked_item.item),
      data: { turbo_frame: "_top" } %>
<% elsif ranked_item.item.is_a?(Music::Album) %>
  <!-- Album display -->
<% elsif ranked_item.item.is_a?(Music::Song) %>
  <!-- Song display -->
<% end %>
```

**Key aspects:**
- Lazy loading with `loading: :lazy` and loading spinner
- Fixed sort by rank ascending (no sortable headers)
- Artist name links use `data: { turbo_frame: "_top" }` for full page navigation
- Pagination controls target turbo frame
- Empty state: "No artist rankings calculated yet. Click 'Refresh Rankings' to calculate."

### 6. N+1 Prevention Strategy

#### RankedItems Controller
**File**: `app/controllers/admin/music/ranked_items_controller.rb` (already exists)

```ruby
# Line 7 reference - MUST eager load polymorphic item association
@ranked_items = @ranking_configuration.ranked_items
  .includes(item: :artists)  # For albums/songs: loads associated artists
                             # For artists: no-op (artist IS the item)
  .order(rank: :asc)

@pagy, @ranked_items = pagy(@ranked_items, items: 25)
```

**Query Count Assertion:**
- Loading 25 artist ranked items: 2 queries (ranked_items + artists polymorphic load)
- NO N+1 on `ranked_item.item.name` access in view
- Test with `assert_queries(2) { render partial }`

#### Show Page
**File**: `app/controllers/admin/music/artists/ranking_configurations_controller.rb`

```ruby
# Inherited from base controller - verify base includes these associations
def show
  @ranking_configuration = ranking_configuration_class
    .includes(:primary_mapped_list, :secondary_mapped_list)  # Inherited, unused for artists
    .find(params[:id])
end
```

**Note**: For artist configs, primary_mapped_list and secondary_mapped_list will be nil. Consider adding conditional includes in base controller to avoid unnecessary joins.

### 7. Error Handling Contracts

#### Form Validation Errors
**Response**: 422 Unprocessable Entity (renders form with errors)

```ruby
# ActionResult structure
{
  errors: {
    name: ["can't be blank"],
    primary: ["only one primary configuration allowed per type"]
  }
}
```

**Display**: Form shows inline error messages with `input-error` class and error text below field.

#### Action Execution Errors
**Response**: 200 OK with ActionResult (Turbo Stream or HTML)

```ruby
# RefreshRankings failure
ActionResult.new(
  status: :error,
  message: "Primary album ranking configuration not found. Cannot calculate artist rankings."
)

# Single configuration validation failure
ActionResult.new(
  status: :error,
  message: "This action can only be performed on a single configuration."
)
```

**Display**: Flash alert at top of page with error icon and message.

#### Missing Configuration
**Response**: 404 Not Found

```ruby
# Standard Rails ActiveRecord::RecordNotFound
# Handled by application controller
# Redirects to index with flash alert: "Configuration not found"
```

### 8. View Conditional Logic Contract

**File**: `app/views/admin/music/ranked_items/index.html.erb` (already exists)

**Polymorphic Item Rendering:**
```erb
<% @ranked_items.each do |ranked_item| %>
  <tr>
    <td><%= ranked_item.rank %></td>
    <td>
      <% case ranked_item.item %>
      <% when Music::Artist %>
        <%= link_to ranked_item.item.name,
            admin_artist_path(ranked_item.item),
            class: "link link-hover",
            data: { turbo_frame: "_top" } %>
      <% when Music::Album %>
        <%= link_to ranked_item.item.title,
            admin_album_path(ranked_item.item),
            class: "link link-hover",
            data: { turbo_frame: "_top" } %>
        <span class="text-sm text-base-content/70">
          by <%= ranked_item.item.artists.map(&:name).join(", ") %>
        </span>
      <% when Music::Song %>
        <%= link_to ranked_item.item.title,
            admin_song_path(ranked_item.item),
            class: "link link-hover",
            data: { turbo_frame: "_top" } %>
        <span class="text-sm text-base-content/70">
          by <%= ranked_item.item.artists.map(&:name).join(", ") %>
        </span>
      <% end %>
    </td>
    <td><%= number_with_precision(ranked_item.score, precision: 2) %></td>
  </tr>
<% end %>
```

**Verification Points:**
- Existing controller (line 7) already handles polymorphism via `includes(item: ...)`
- View MUST use `case ranked_item.item` (not `ranked_item.item_type`) for proper polymorphic routing
- Links MUST use `data: { turbo_frame: "_top" }` to break out of turbo frame for navigation

### 9. Admin Navigation Updates

**File to Update**: Find the admin music layout/navigation file (likely `app/views/layouts/music/admin.html.erb` or similar)

**Pattern from Phase 6**: Look for existing "Ranking Configurations" section in sidebar navigation

**Required Changes:**
```erb
<!-- Admin sidebar navigation (example structure) -->
<li>
  <details>
    <summary>Ranking Configurations</summary>
    <ul>
      <li>
        <%= link_to "Albums", admin_albums_ranking_configurations_path,
            class: request.path.start_with?("/admin/albums/ranking_configurations") ? "active" : "" %>
      </li>
      <li>
        <%= link_to "Songs", admin_songs_ranking_configurations_path,
            class: request.path.start_with?("/admin/songs/ranking_configurations") ? "active" : "" %>
      </li>
      <!-- NEW: Add Artist Rankings -->
      <li>
        <%= link_to "Artists", admin_artists_ranking_configurations_path,
            class: request.path.start_with?("/admin/artists/ranking_configurations") ? "active" : "" %>
      </li>
    </ul>
  </details>
</li>
```

**Implementation Notes:**
- Find existing navigation structure using `codebase-pattern-finder` for "Albums" and "Songs" ranking config links
- Add "Artists" link in same section following same pattern
- Ensure active state styling matches existing items
- Test that link works and highlights correctly when on artist ranking config pages

**Alternative Locations:**
- If navigation is in a ViewComponent: `app/components/admin/music/sidebar_component.rb` or similar
- If navigation is in a partial: `app/views/admin/shared/_music_nav.html.erb` or similar
- If navigation is in a Stimulus controller: Check for data-controller attributes

## Dependencies

### Models
- `Music::Artists::RankingConfiguration` - Already exists, no changes needed
- `RankingConfiguration` - Base class, no changes needed
- `RankedItem` - Stores artist ranks, no changes needed

### Controllers
- `Admin::Music::RankingConfigurationsController` - Base controller (already exists from Phase 6)
- `Admin::Music::RankedItemsController` - Shared controller (already exists from Phase 6)

### Actions
- `Actions::Admin::Music::RefreshRankings` - Already exists, usable as-is or create artist-specific version

### Existing Services
- `ItemRankings::Music::Artists::Calculator` - Already exists, no changes needed
- `Music::CalculateArtistRankingJob` - Background job (already exists)
- `Music::CalculateAllArtistsRankingsJob` - Background job (already exists)

### Gems
- No new gems required
- Uses existing: `pagy`, `sidekiq`, Rails 8

## Acceptance Criteria

### Data Model
- [ ] `Music::Artists::RankingConfiguration` model already exists and works
- [ ] No model changes needed

### Controller Layer
- [ ] `/admin/artists/ranking_configurations` path shows index with search, sort, pagination
- [ ] Ranking configuration show page displays relevant fields only
- [ ] Ranking configuration new/create/edit/update/destroy CRUD operations work
- [ ] RefreshRankings action executes successfully from show page

### Navigation
- [ ] Admin sidebar includes "Artists" link under "Ranking Configurations" section
- [ ] "Artists" link navigates to `/admin/artists/ranking_configurations`
- [ ] Active state highlights correctly when on artist ranking config pages
- [ ] Link appears in same section as "Albums" and "Songs" ranking configs

### Public UI
- [ ] Ranked items section:
  - [ ] Loads inline via Turbo Frame (lazy)
  - [ ] Paginated (25 items per page)
  - [ ] Fixed sort by rank ascending
  - [ ] Links to artist admin pages work
  - [ ] Empty state displayed when no rankings

### Show Page
- [ ] NO ranked lists section (artists don't have ranked_lists)
- [ ] Shows informational notes about aggregation algorithm
- [ ] Displays links to source album/song ranking configurations
- [ ] Only RefreshRankings action available (no BulkCalculateWeights)

### Form
- [ ] Form only shows relevant fields (name, description, flags, published_at)
- [ ] Form does NOT show algorithm or list-related parameters
- [ ] Informational note explains inherited but unused fields
- [ ] Validation works for required fields

### Edge Cases
- [ ] Handles missing album or song primary ranking configurations gracefully
- [ ] Empty state when no artists ranked yet
- [ ] Authorization prevents non-admin/editor access
- [ ] All pages are responsive (mobile, tablet, desktop)

### Performance
- [ ] N+1 queries prevented with eager loading
- [ ] Sort column SQL injection prevented with whitelist
- [ ] Page loads in < 1 second

## Design Decisions

### Why Simplified Form?

**Decision**: Show only essential fields in new/edit forms, hiding inherited but unused parameters.

**Rationale**:
1. **User confusion**: Displaying algorithm parameters that don't affect artist rankings would confuse administrators
2. **Simpler UX**: Focus on what matters (name, flags, description)
3. **Schema inheritance**: Fields exist in database (STI) but aren't used by artist calculator
4. **Documentation**: Show page can display all fields with explanatory notes

**Benefits**:
- Cleaner admin interface
- Reduces errors from misconfiguration
- Clearly communicates artist ranking behavior

### Why No BulkCalculateWeights Action?

**Decision**: Omit BulkCalculateWeights action from artist ranking configuration admin.

**Rationale**:
1. **Not applicable**: Artists don't have ranked_lists, so there are no list weights to calculate
2. **Different algorithm**: Artist calculator (`ItemRankings::Music::Artists::Calculator`) overrides `list_type` with `NotImplementedError` and uses aggregation instead
3. **Simplified interface**: Only one action needed (RefreshRankings)

**Benefits**:
- Prevents confusion about what actions apply
- Simpler UI with fewer buttons
- Clear communication that artists work differently

### Why Share Ranked Items Controller?

**Decision**: Use existing `Admin::Music::RankedItemsController` for all item types including artists.

**Rationale**:
1. **DRY**: Controller logic is identical - find parent config, paginate ranked_items
2. **Polymorphic**: RankedItem already supports multiple item types via polymorphism
3. **View flexibility**: View can conditionally render based on item_type
4. **Simpler architecture**: Fewer controllers to maintain

**Benefits**:
- Code reuse from Phase 6
- Consistent behavior across all ranking types
- Single source of truth for ranked item display

### Why Show Algorithm Parameters on Show Page?

**Decision**: Display inherited algorithm parameters on show page with explanatory note, but hide them from forms.

**Rationale**:
1. **Transparency**: Admins can see what's in the database
2. **Debugging**: Helpful to see all schema fields even if unused
3. **Documentation**: Notes explain why they're not relevant
4. **Schema consistency**: All ranking configs share same table structure

**Alternative considered**: Hide them completely
- **Rejected because**: Less transparent, harder to debug, inconsistent with albums/songs views

## Risk Assessment

### High Risk

**Missing Source Configurations**
- **Risk**: Artist ranking fails if album or song primary ranking config doesn't exist
- **Mitigation**: Show page displays links to source configs with status indicator
- **Mitigation**: RefreshRankings action fails gracefully with clear error message
- **Testing**: Test with missing configs

**Form Confusion**
- **Risk**: Admins try to edit algorithm parameters not realizing they don't apply
- **Mitigation**: Hide unused fields from form
- **Mitigation**: Add explanatory notes throughout UI
- **Testing**: User acceptance testing with admins

### Medium Risk

**Action Integration**
- **Risk**: RefreshRankings action needs to work from both Artist resource and RankingConfiguration resource
- **Mitigation**: Action uses polymorphic pattern, should work for all config types
- **Mitigation**: Test action execution from both contexts
- **Testing**: Integration tests for action execution

**View Conditional Logic**
- **Risk**: Ranked items view needs to handle artists correctly alongside albums/songs
- **Mitigation**: Verify existing conditional rendering includes artist case
- **Mitigation**: Add tests for artist item display
- **Testing**: Test ranked_items_controller with artist ranking config

### Low Risk

**UI Consistency**
- **Risk**: Artist ranking config pages feel different from albums/songs
- **Mitigation**: Reuse same base controller and view patterns
- **Mitigation**: Use same DaisyUI components and layout
- **Testing**: Visual regression testing

## Future Enhancements

### Phase 8: Enhanced Artist Rankings
1. **Weighted aggregation** - Allow configurable ratio between album and song contributions
2. **Role filtering** - Only count albums/songs where artist was primary (not featured)
3. **Configuration parameters** - Expose artist-specific weighting parameters
4. **Dependency tracking** - Auto-refresh artist rankings when album/song rankings update

### Performance Optimizations
1. **Cached aggregation** - Cache artist scores to avoid repeated queries
2. **Incremental updates** - Only recalculate artists whose albums/songs changed
3. **Background refresh** - Automatic nightly recalculation

### Admin Features
1. **Dependency visualization** - Show which album/song configs feed artist rankings
2. **Dry run** - Preview ranking changes before applying
3. **Comparison view** - Compare rankings between configurations

## Related Documentation
- [Phase 6 Spec - Albums/Songs Ranking Configurations](completed/077-custom-admin-phase-6-ranking-configs.md)
- [Phase 1 Spec - Artists](completed/072-custom-admin-phase-1-artists.md)
- [Artist Rankings Implementation](completed/061-artist-rankings.md)
- [RankingConfiguration Model](../models/ranking_configuration.md)
- [RankedItem Model](../models/ranked_item.md)
- [ItemRankings::Music::Artists::Calculator](../lib/item_rankings/music/artists/calculator.md)

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns from Phase 1-6
- Reuse base controller from Phase 6 - DO NOT create new architecture
- Respect snippet budget (≤40 lines per snippet)
- Link to authoritative code by path

### Required Outputs
- Artists ranking configurations controller: `app/controllers/admin/music/artists/ranking_configurations_controller.rb`
- Index, show, new, edit views for artists ranking configurations
- Simplified form partial without algorithm/list parameters
- Table partial for index page
- Updated routes in `config/routes.rb`
- **Updated admin navigation** (sidebar or layout file) with "Artists" ranking config link
- Verify ranked_items view handles artists correctly
- Passing tests (controller tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Verify ranked_items view conditional rendering for artists
2. **codebase-pattern-finder** → Find admin navigation structure (sidebar with Albums/Songs ranking config links)
3. **codebase-analyzer** → Confirm RefreshRankings action compatibility with artists
4. **technical-writer** → Update class documentation and task file

### Test Fixtures Required

**Minimal Required Fixtures:**
```yaml
# test/fixtures/music/artists/ranking_configurations.yml
music_artists_global:
  name: "Global Artist Rankings"
  type: "Music::Artists::RankingConfiguration"
  primary: true
  global: true
  published_at: 2025-01-01 00:00:00

music_artists_archived:
  name: "2024 Artist Rankings"
  type: "Music::Artists::RankingConfiguration"
  primary: false
  global: false
  archived: true
  published_at: 2024-01-01 00:00:00

# test/fixtures/ranked_items.yml (add artist entries if missing)
ranked_item_artist_1:
  ranking_configuration: music_artists_global
  item: beatles (Music::Artist)
  rank: 1
  score: 95.5

ranked_item_artist_2:
  ranking_configuration: music_artists_global
  item: radiohead (Music::Artist)
  rank: 2
  score: 92.3
```

**Fixture Strategy:**
- Reuse existing `music_artists_global` fixture if present (check `test/fixtures/ranking_configurations.yml`)
- Create minimal 2-config, 2-ranked-item fixtures if none exist
- DO NOT create large fixture sets - prefer factories for test-specific data

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken
*[Document approach decisions here]*

### Key Files Created
*[List all new files with paths]*

### Key Files Modified
*[List all modified files with what changed]*

### Challenges Encountered
*[Document any issues and solutions]*

### Deviations from Plan
*[Document any changes from the original spec]*

### Testing Approach
*[Document test strategy and coverage]*

## Documentation Updated
*[List documentation files created/updated]*

## Tests Created
*[List test files created with test counts]*

## Next Phases

### Phase 8: Avo Removal (TODO #080)
- Remove Avo gem
- Clean up Avo routes/initializers
- Remove all Avo resource/action files
- Update documentation

---

## Glossary

**Aggregation**: Artist rankings aggregate (sum) scores from album and song rankings rather than processing lists directly.

**Template Method Pattern**: Base controller defines algorithm skeleton, subclasses implement specific steps.

**Polymorphic Association**: RankedItem can belong to any item type (Album, Song, Artist) via item_type and item_id.

**Turbo Frame**: Hotwire component for partial page updates without full page reload.

**STI (Single Table Inheritance)**: All ranking configurations share one database table, differentiated by type column.
