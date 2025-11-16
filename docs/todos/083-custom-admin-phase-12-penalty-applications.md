# 083 - Custom Admin Interface - Phase 12: Penalty Applications

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-15
- **Started**:
- **Completed**:
- **Developer**: Claude Code (AI Agent)

## Overview
Implement generic admin interface for managing the PenaltyApplication join table (connecting RankingConfigurations to Penalties with a configurable value 0-100). This is a cross-domain feature that works for album and song ranking configurations (not artist configurations, which use a different calculation method), and eventually book/movie/game configurations. Users can attach and detach penalties from ranking configuration show pages via a modal interface. This follows the proven pattern from Phase 11 (list_penalties) but adds a numeric value input field.

## Context
- **Previous Phase Complete**: List Penalties (Phase 11) - CRUD for list-penalty associations implemented
- **Join Table**: PenaltyApplication connects RankingConfiguration → Penalty with configurable value
- **Generic Controller**: `Admin::PenaltyApplicationsController` (NOT namespaced under music/books/etc.)
- **Cross-Domain**: Works for all ranking configuration types (Music::Albums::, Music::Songs::, Books::, Movies::, Games::)
- **Proven Pattern**: Phase 11 list_penalties join table with modals (docs/todos/completed/082-custom-admin-phase-11-list-penalties.md)
- **Similar Interaction**: Dropdown selection + numeric value input (0-100)
- **Edit Support**: Unlike list_penalties, this feature supports editing the value after creation (common use case)
- **Implementation Scope**: Album and song ranking configurations only (artist configs use different calculation, Books/Movies/Games in future)

## Requirements

### Base Penalty Application Management
- [ ] Generic controller: `Admin::PenaltyApplicationsController` (not namespaced)
- [ ] Modal-based interface for add/edit/delete operations
- [ ] Context-aware: works from any ranking configuration show page
- [ ] Dropdown selection of available penalties (Global + matching media type)
- [ ] Numeric input for value (0-100 percentage)
- [ ] Edit modal to update value after creation
- [ ] Validation preventing duplicate penalty assignments
- [ ] Media type compatibility validation (Music penalties only with Music configurations, etc.)
- [ ] No pagination needed (small number of penalties per configuration)
- [ ] No sorting controls (always alphabetical by penalty name)

### Ranking Configuration Show Page Integration
- [ ] New "Penalty Applications" section on ranking configuration show pages
- [ ] Lazy-loaded turbo frame for penalty applications list
- [ ] "Add Penalty" button opens create modal
- [ ] Create modal: dropdown with available penalties (filtered by media type) + value input (0-100)
- [ ] Penalties table shows: name, type, dynamic_type, value, edit action, delete action
- [ ] Edit button/icon opens edit modal with current value pre-filled
- [ ] Edit modal: penalty name (read-only), value input (editable 0-100)
- [ ] Delete confirmation for removing penalties
- [ ] Real-time updates via Turbo Streams
- [ ] Count badge showing number of applied penalties

### Display Requirements
- [ ] DaisyUI card with title "Penalty Applications" and count badge
- [ ] Table columns: Name, Type, Dynamic Type, Value, Actions
- [ ] Type badges with color coding (Global: primary, Music: secondary, Books: accent, Movies: info, Games: success)
- [ ] Dynamic type badges (Static, Number of Voters, Percentage Western, etc.)
- [ ] Value displayed as percentage (e.g., "75%")
- [ ] Empty state when no penalties attached
- [ ] Edit button/icon for each penalty application
- [ ] Delete button with confirmation

## API Endpoints

| Verb | Path | Purpose | Params/Body | Auth | Context |
|------|------|---------|-------------|------|---------|
| GET | `/admin/ranking_configuration/:ranking_configuration_id/penalty_applications` | List penalty applications for a configuration | - | admin/editor | lazy-loaded frame |
| POST | `/admin/ranking_configuration/:ranking_configuration_id/penalty_applications` | Add penalty to configuration | `penalty_application[penalty_id, value]` | admin/editor | create modal form |
| GET | `/admin/penalty_applications/:id/edit` | Get edit form for penalty application | - | admin/editor | edit modal request |
| PATCH | `/admin/penalty_applications/:id` | Update penalty application value | `penalty_application[value]` | admin/editor | edit modal form |
| DELETE | `/admin/penalty_applications/:id` | Remove penalty from configuration | - | admin/editor | table row |

**Route Helpers**:
- `admin_ranking_configuration_penalty_applications_path(@ranking_configuration)` → GET index (lazy load)
- `admin_ranking_configuration_penalty_applications_path(@ranking_configuration)` → POST create
- `edit_admin_penalty_application_path(@penalty_application)` → GET edit (modal)
- `admin_penalty_application_path(@penalty_application)` → PATCH update
- `admin_penalty_application_path(@penalty_application)` → DELETE destroy

**Note**: Routes are generic and work for all ranking configuration types (not namespaced under music/books/etc.)

## Response Formats

### Success Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Penalty added successfully." } })
turbo_stream.replace("penalty_applications_list", template: "admin/penalty_applications/index",
  locals: { ranking_configuration: @ranking_configuration,
            penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name") })
turbo_stream.replace("add_penalty_to_configuration_modal",
  Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration))
```

### Error Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { error: "Penalty is already applied to this configuration" } })
```

### Turbo Frame IDs
- Main frame: `"penalty_applications_list"`
- Add modal ID: `"add_penalty_to_configuration_modal"`
- Add dialog ID: `"add_penalty_to_configuration_modal_dialog"`
- Edit modal ID: `"edit_penalty_application_modal"`
- Edit dialog ID: `"edit_penalty_application_modal_dialog"`
- Modal forms target main frame on success

## Behavioral Rules

### Preconditions
- User must have admin or editor role
- Ranking configuration must exist
- Penalty must exist
- Penalty media type must be compatible with ranking configuration media type

### Postconditions (Add)
- New PenaltyApplication record created linking configuration and penalty with value
- Turbo Stream updates penalty applications list without page reload
- Flash message confirms success
- Modal closes automatically
- Add modal reloads with updated available penalties (excluding newly added one)

### Postconditions (Edit)
- PenaltyApplication record updated with new value
- Turbo Stream updates penalty applications list without page reload
- Flash message confirms update
- Edit modal closes automatically

### Postconditions (Delete)
- PenaltyApplication record deleted
- Turbo Stream removes penalty from list
- Flash message confirms removal
- Add modal reloads with updated available penalties (including newly removed one)

### Invariants
- A configuration-penalty pair must be unique (database constraint + validation)
- Penalty media type must match configuration media type (or be Global)
- Value must be between 0 and 100 (inclusive)
- User must have appropriate authorization

### Edge Cases
- **Empty dropdown**: No available penalties shows "All compatible penalties already applied"
- **Duplicate add**: Shows validation error, doesn't create
- **Media type mismatch**: Validation prevents Music penalty on Books configuration
- **Value out of range (create)**: Shows validation error (must be 0-100)
- **Value out of range (edit)**: Shows validation error (must be 0-100)
- **Authorization failure**: Redirects to appropriate domain root
- **Edit deleted record**: Shows 404 error

## Media Type Compatibility Rules

**From PenaltyApplication model validation** (`app/models/penalty_application.rb:47-76`)

- **Global::Penalty**: Works with ANY ranking configuration type (Books, Music, Movies, Games)
- **Music::Penalty**: Only works with `Music::*::RankingConfiguration` types (Albums::, Songs::, Artists::)
- **Books::Penalty**: Only works with `Books::RankingConfiguration` types
- **Movies::Penalty**: Only works with `Movies::RankingConfiguration` types
- **Games::Penalty**: Only works with `Games::RankingConfiguration` types

**Dropdown filtering logic**:
```ruby
# Reference only - implementation in component
def available_penalties(ranking_configuration)
  media_type = ranking_configuration.type.split("::").first # "Music", "Books", etc.

  Penalty
    .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
    .where.not(id: ranking_configuration.penalties.pluck(:id))
    .order(:name)
end
```

**Note**: Unlike ListPenalty which filters for static-only, PenaltyApplication works with **both** static and dynamic penalties.

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load `penalty_applications: :penalty` in ranking configuration show controllers
- **Lazy Loading**: Use turbo frame with lazy loading for penalty applications list
- **No Pagination**: Small number of penalties per configuration (typically < 10)
- **Response Time**: < 500ms p95 for attach/detach

### Security
- **Authorization**: Enforce admin/editor role via BaseController
- **CSRF Protection**: Rails handles via form helpers
- **Parameter Filtering**: Strong params whitelist (penalty_id, value)
- **SQL Injection**: ActiveRecord parameterization

### Accessibility
- **Keyboard Navigation**: Tab through form fields
- **Screen Readers**: Labels on all inputs
- **Modals**: Native `<dialog>` element
- **Delete Confirmation**: Clear confirmation messages
- **Value Input**: Number input with min/max attributes

### Responsiveness
- **Mobile**: DaisyUI responsive utilities
- **Tablet**: Card layout adapts
- **Desktop**: Full-width tables

## Acceptance Criteria

### Controller Tests (Required)
- [ ] GET index renders penalty applications list (2 tests: with/without penalties)
- [ ] POST create adds penalty (2 tests: success + turbo stream)
- [ ] POST create validates value range (2 tests: too low, too high)
- [ ] Prevent duplicate penalty application (1 test)
- [ ] GET edit renders edit form (1 test)
- [ ] PATCH update updates value successfully (2 tests: success + turbo stream)
- [ ] PATCH update validates value range (2 tests: too low, too high)
- [ ] DELETE destroy removes penalty (2 tests: success + turbo stream)
- [ ] Authorization enforcement (3 tests: create, update, destroy)
- [ ] Media type compatibility validation (3 tests: Global works, matching type works, mismatched type fails)
- [ ] Turbo stream replacements for create (3 tests: flash, list, add modal)
- [ ] Turbo stream replacements for update (2 tests: flash, list)
- [ ] Cross-configuration type support (2 tests: works for both album and song configs)

**Total Controller Tests**: ~27 tests

### Component Tests (Required)
- [ ] Add modal component renders with form (1 test)
- [ ] Add modal available_penalties returns filtered penalties (1 test)
- [ ] Add modal available_penalties filters by media type (1 test)
- [ ] Add modal available_penalties excludes already applied penalties (1 test)
- [ ] Add modal includes value input field with correct attributes (1 test)
- [ ] Edit modal component renders with form (1 test)
- [ ] Edit modal shows penalty name as read-only (1 test)
- [ ] Edit modal pre-fills current value (1 test)
- [ ] Edit modal includes value input with correct attributes (1 test)

**Total Component Tests**: ~9 tests

### Manual Acceptance Tests
- [ ] From album ranking configuration show page: Add penalty via dropdown + value, verify appears in table
- [ ] From album ranking configuration show page: Click edit icon, modal opens with current value pre-filled
- [ ] From album ranking configuration show page: Edit value, submit, verify updates in table
- [ ] From album ranking configuration show page: Delete penalty, verify disappears from table
- [ ] From song ranking configuration show page: Add penalty via dropdown + value, verify appears in table
- [ ] From song ranking configuration show page: Edit penalty value, verify updates
- [ ] From song ranking configuration show page: Delete penalty, verify disappears from table
- [ ] Verify artist ranking configuration show page does NOT have penalty applications section
- [ ] Verify dropdown only shows available penalties (not already applied)
- [ ] Verify dropdown filters by media type (Global + Music for music configurations)
- [ ] Verify value input accepts 0-100 only (create and edit)
- [ ] Verify duplicate prevention shows error message
- [ ] Verify modals close automatically after successful submission
- [ ] Verify add modal reloads after add/delete to show updated available penalties
- [ ] Verify edit modal shows penalty name as read-only
- [ ] Verify Turbo Stream updates work without page reload
- [ ] Verify lazy loading works (frame loads after page)
- [ ] Verify media type validation (can't add Books penalty to Music configuration)
- [ ] Verify value displays as percentage in table (e.g., "75%")
- [ ] Verify dynamic type badges show correctly

## Implementation Plan

### Step 1: Generate Controller & Routes
**Command**:
```bash
cd web-app
bin/rails generate controller Admin::PenaltyApplications index create edit update destroy --no-helper --no-assets
```

**Files created**:
- `app/controllers/admin/penalty_applications_controller.rb`
- `test/controllers/admin/penalty_applications_controller_test.rb`

**Routes to add** (`config/routes.rb`):
```ruby
namespace :admin do
  # Existing routes...

  # Generic penalty applications routes (cross-domain)
  scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
    resources :penalty_applications, only: [:index, :create]
  end

  resources :penalty_applications, only: [:edit, :update, :destroy]
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb:153-160`

### Step 2: Implement Controller
**File**: `app/controllers/admin/penalty_applications_controller.rb`

**Pattern**: Generic controller that works across all domains
- Inherit from `Admin::BaseController` (NOT music-specific base)
- `index` action: Load penalty_applications with penalties, render without layout
- `create` action: Create new penalty_application with Turbo Stream response (3 replacements: flash, list, add modal)
- `edit` action: Render edit modal form (turbo stream or HTML)
- `update` action: Update penalty_application value with Turbo Stream response (2 replacements: flash, list)
- `destroy` action: Delete penalty_application with Turbo Stream response (3 replacements: flash, list, add modal)
- Strong params (create): whitelist `penalty_id, value`
- Strong params (update): whitelist `value` only (penalty cannot be changed)
- Dynamic redirect path based on configuration STI type

**Key differences from list_penalties**:
- Parent is RankingConfiguration instead of List
- Has value field (0-100) with validation
- Supports edit/update (list_penalties does not)
- Works with both static and dynamic penalties (list_penalties only static)
- Different turbo frame/modal IDs
- Button labeled "Add Penalty" instead of "Attach Penalty"

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/list_penalties_controller.rb`

### Step 3: Create View Template for Index
**File**: `app/views/admin/penalty_applications/index.html.erb`

**Pattern**: Turbo frame wrapping table
- Wrap in `turbo_frame_tag "penalty_applications_list"`
- Table with columns: Name, Type, Dynamic Type, Value, Actions
- Badge styling for type and dynamic_type
- Value displayed as percentage (e.g., "75%")
- Edit button/icon opens edit modal via `data-turbo-frame="_top"` link to edit path
- Delete button with turbo_confirm
- Empty state when no penalties
- No layout (rendered in turbo frame)
- Use `local_assigns.fetch` pattern for both instance vars and locals

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/list_penalties/index.html.erb`

### Step 4: Create Attach Modal Component
**Command**:
```bash
cd web-app
bin/rails generate component Admin::AddPenaltyToConfigurationModal ranking_configuration --sidecar
```

**Files created**:
- `app/components/admin/add_penalty_to_configuration_modal_component.rb`
- `app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb`
- `test/components/admin/add_penalty_to_configuration_modal_component_test.rb`

**Component implementation**:
- Initialize with `ranking_configuration:` parameter
- Define `available_penalties` method with filtering logic
- Filtering: Global::Penalty + matching media type, exclude already attached
- Self-contained (no helper dependency)

**Template implementation**:
- DaisyUI dialog modal with ID `add_penalty_to_configuration_modal_dialog`
- Form posts to `admin_ranking_configuration_penalty_applications_path(@ranking_configuration)`
- Penalty dropdown via `options_from_collection_for_select(available_penalties, :id, :name)`
- Value input: `<input type="number" min="0" max="100" required>`
- Stimulus controller: `modal-form` for auto-close behavior
- Turbo frame target: `penalty_applications_list`

### Step 4b: Create Edit Modal Component
**Command**:
```bash
cd web-app
bin/rails generate component Admin::EditPenaltyApplicationModal penalty_application --sidecar
```

**Files created**:
- `app/components/admin/edit_penalty_application_modal_component.rb`
- `app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb`
- `test/components/admin/edit_penalty_application_modal_component_test.rb`

**Component implementation**:
- Initialize with `penalty_application:` parameter
- No filtering needed (editing existing record)
- Self-contained component

**Template implementation**:
- DaisyUI dialog modal with ID `edit_penalty_application_modal_dialog`
- Form patches to `admin_penalty_application_path(@penalty_application)`
- Penalty name shown as read-only text (not editable)
- Value input: `<input type="number" min="0" max="100" required>` pre-filled with current value
- Stimulus controller: `modal-form` for auto-close behavior
- Turbo frame target: `penalty_applications_list`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/components/admin/attach_penalty_modal_component.rb`

### Step 5: Integrate into Albums Ranking Configuration Show Page
**File**: `app/views/admin/music/albums/ranking_configurations/show.html.erb`

**Add Section** (after Penalty Configuration card, around line 222):
```erb
<!-- Penalty Applications Section -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Penalty Applications
        <span class="badge badge-ghost"><%= @ranking_configuration.penalty_applications.count %></span>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="add_penalty_to_configuration_modal_dialog.showModal()">
        + Attach Penalty
      </button>
    </div>
    <%= turbo_frame_tag "penalty_applications_list", loading: :lazy,
        src: admin_ranking_configuration_penalty_applications_path(@ranking_configuration) do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
</div>

<!-- Modal rendered at bottom of page -->
<%= render Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration) %>
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb:254-272,344`

### Step 6: Integrate into Songs Ranking Configuration Show Page
**File**: `app/views/admin/music/songs/ranking_configurations/show.html.erb`

**Same pattern as Step 5** - add identical penalty applications section with modal

### Step 7: Verify Artists Ranking Configuration Show Page (No Integration)
**File**: `app/views/admin/music/artists/ranking_configurations/show.html.erb`

**Action**: Confirm this page does NOT get penalty applications section
- Artist rankings use a different calculation method (not based on penalties/lists)
- No changes needed to this file

### Step 8: Update Ranking Configuration Controllers for Eager Loading
**File**: `app/controllers/admin/music/ranking_configurations_controller.rb`

**Update show action**:
```ruby
def show
  @ranking_configuration = configuration_class
    .includes(:primary_mapped_list, :secondary_mapped_list, penalty_applications: :penalty)
    .find(params[:id])
end
```

**Add**: `penalty_applications: :penalty` to existing includes

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb:8-12`

### Step 9: Write Controller Tests
**File**: `test/controllers/admin/penalty_applications_controller_test.rb`

**Test structure**:
```ruby
require "test_helper"

module Admin
  class PenaltyApplicationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_config = music_albums_ranking_configurations(:default)
      @song_config = music_songs_ranking_configurations(:default)
      @global_penalty = penalties(:global_penalty)
      @music_penalty = penalties(:music_penalty)
      @books_penalty = penalties(:books_penalty)

      @album_config.penalty_applications.destroy_all
      @song_config.penalty_applications.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    # Index tests (with/without penalties)
    # Create tests (success, duplicate prevention, media type validation, value validation, turbo streams)
    # Destroy tests (success, turbo streams)
    # Cross-configuration type tests (works for both album and song configs)
  end
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/list_penalties_controller_test.rb`

### Step 10: Write Component Tests
**File**: `test/components/admin/add_penalty_to_configuration_modal_component_test.rb`

**Test structure**:
```ruby
require "test_helper"

class Admin::AddPenaltyToConfigurationModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @music_config = music_albums_ranking_configurations(:default)
    @global_penalty = penalties(:global_penalty)
    @music_penalty = penalties(:music_penalty)
    @books_penalty = penalties(:books_penalty)

    PenaltyApplication.where(ranking_configuration: @music_config).destroy_all
  end

  # Test modal renders with form and value input
  # Test available_penalties filtering by media type
  # Test available_penalties excludes already attached
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/components/admin/attach_penalty_modal_component_test.rb`

### Step 11: Manual Testing
**Prerequisites**:
- Ranking configurations exist (albums, songs)
- Penalties exist (Global and Music types)
- Admin user authenticated

**Test scenarios**:
1. Visit album ranking configuration show page → See penalty applications section with count
2. Visit song ranking configuration show page → See penalty applications section with count
3. Visit artist ranking configuration show page → Do NOT see penalty applications section
4. Click "Add Penalty" (on album or song config) → Modal opens with dropdown and value input
5. Select penalty, enter value (e.g., 75) → Submit → Penalty appears in table with "75%"
6. Click edit icon for a penalty → Edit modal opens with current value pre-filled
7. Change value to 50 → Submit → Table updates to show "50%"
8. Click "Delete" → Confirm → Penalty disappears
9. Try to add same penalty twice → See error message
10. Verify dropdown only shows Global + Music penalties
11. Try to enter value outside 0-100 in create modal → See validation error
12. Try to enter value outside 0-100 in edit modal → See validation error
13. Verify lazy loading works

## Golden Examples

### Example 1: Adding Penalty to Configuration (Happy Path)

**Action**: User visits album ranking configuration show page, clicks "Add Penalty", selects "Low Voter Count" global penalty with value 75, submits

**Request**:
```
POST /admin/ranking_configuration/123/penalty_applications
Params: { penalty_application: { penalty_id: 456, value: 75 } }
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Penalty attached successfully." } })
turbo_stream.replace("penalty_applications_list",
  template: "admin/penalty_applications/index",
  locals: { ranking_configuration: @ranking_configuration,
            penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name") })
turbo_stream.replace("add_penalty_to_configuration_modal",
  Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration))
```

**Note**: Three turbo stream replacements ensure modal refreshes with updated available penalties list

**Result**:
- PenaltyApplication record created linking configuration 123 and penalty 456 with value 75
- Flash shows "Penalty added successfully."
- Penalties table updates to show "Low Voter Count | Global | Static | 75%"
- Modal closes automatically
- Add modal reloads to exclude newly added penalty from dropdown
- No page reload

### Example 2: Media Type Compatibility Validation

**Action**: User tries to add Books::Penalty to Music::Albums::RankingConfiguration

**Request**:
```
POST /admin/ranking_configuration/123/penalty_applications
Params: { penalty_application: { penalty_id: 789, value: 50 } }
```

**Validation fails**: `Penalty media type (Books) is not compatible with configuration media type (Music)`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "books penalty cannot be applied to Music::Albums::RankingConfiguration configuration" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can select compatible penalty

### Example 3: Value Range Validation

**Action**: User tries to attach penalty with value 150

**Request**:
```
POST /admin/ranking_configuration/123/penalty_applications
Params: { penalty_application: { penalty_id: 456, value: 150 } }
```

**Validation fails**: `Value must be less than or equal to 100`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "Value must be less than or equal to 100" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can enter valid value (0-100)

### Example 4: Editing Penalty Application Value (Happy Path)

**Action**: User clicks edit icon for existing penalty application with value 75, changes to 50, submits

**Request**:
```
PATCH /admin/penalty_applications/999
Params: { penalty_application: { value: 50 } }
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Penalty application updated successfully." } })
turbo_stream.replace("penalty_applications_list",
  template: "admin/penalty_applications/index",
  locals: { ranking_configuration: @ranking_configuration,
            penalty_applications: @ranking_configuration.penalty_applications.includes(:penalty).order("penalties.name") })
```

**Result**:
- PenaltyApplication record updated with value 50
- Flash shows "Penalty application updated successfully."
- Penalties table updates to show "Low Voter Count | Global | Static | 50%"
- Edit modal closes automatically
- No page reload

**Note**: Update only needs 2 turbo stream replacements (flash, list) - attach modal doesn't need to refresh

## Agent Hand-Off

### Constraints
- Follow existing list_penalties pattern for modals - do not introduce new architecture
- Similar to list_penalties but with value input field (0-100)
- Generic controller (NOT namespaced under music/books/etc.)
- Keep code snippets ≤40 lines in documentation
- Link to reference files by path

### Required Outputs
- `app/controllers/admin/penalty_applications_controller.rb` (new)
- `test/controllers/admin/penalty_applications_controller_test.rb` (new)
- `app/views/admin/penalty_applications/index.html.erb` (new)
- `app/views/admin/penalty_applications/edit.html.erb` (new - edit modal rendered via turbo)
- `app/components/admin/add_penalty_to_configuration_modal_component.rb` (new via generator)
- `app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb` (new)
- `test/components/admin/add_penalty_to_configuration_modal_component_test.rb` (new)
- `app/components/admin/edit_penalty_application_modal_component.rb` (new via generator)
- `app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb` (new)
- `test/components/admin/edit_penalty_application_modal_component_test.rb` (new)
- `config/routes.rb` (update - add penalty_applications routes with edit/update)
- `app/views/admin/music/albums/ranking_configurations/show.html.erb` (update - add penalty applications section)
- `app/views/admin/music/songs/ranking_configurations/show.html.erb` (update - add penalty applications section)
- `app/controllers/admin/music/ranking_configurations_controller.rb` (update - eager loading)
- All tests passing (27+ controller tests, 9+ component tests)
- Updated sections in this spec: "Implementation Notes", "Deviations", "Acceptance Results"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Collect list_penalties modal patterns ✅ (COMPLETED above)
2. **codebase-analyzer** → Verify PenaltyApplication model structure ✅ (COMPLETED above)
3. **codebase-locator** → Find ranking configuration show pages ✅ (COMPLETED above)
4. **general-purpose** → Implement controller, routes, views, component, tests following patterns
5. **technical-writer** → Update this spec with implementation notes, create class documentation

### Test Fixtures Required
Verify these fixtures exist and have proper data:
- `test/fixtures/penalties.yml` - Global and Music penalties
- `test/fixtures/music/albums/ranking_configurations.yml` - Album configurations for testing
- `test/fixtures/music/songs/ranking_configurations.yml` - Song configurations for testing
- `test/fixtures/penalty_applications.yml` - Sample configuration-penalty associations
- `test/fixtures/users.yml` - admin_user, regular_user

Note: Artist ranking configurations do NOT need penalty application fixtures (not used)

## Key Files Touched

### New Files
- `app/controllers/admin/penalty_applications_controller.rb`
- `test/controllers/admin/penalty_applications_controller_test.rb`
- `app/views/admin/penalty_applications/index.html.erb`
- `app/views/admin/penalty_applications/edit.html.erb`
- `app/components/admin/add_penalty_to_configuration_modal_component.rb`
- `app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb`
- `test/components/admin/add_penalty_to_configuration_modal_component_test.rb`
- `app/components/admin/edit_penalty_application_modal_component.rb`
- `app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb`
- `test/components/admin/edit_penalty_application_modal_component_test.rb`

### Modified Files
- `config/routes.rb` (add penalty_applications routes)
- `app/views/admin/music/albums/ranking_configurations/show.html.erb` (add penalty applications section, use ViewComponent)
- `app/views/admin/music/songs/ranking_configurations/show.html.erb` (add penalty applications section, use ViewComponent)
- `app/controllers/admin/music/ranking_configurations_controller.rb` (eager loading in parent controller)

### Files NOT Modified (Verified)
- `app/views/admin/music/artists/ranking_configurations/show.html.erb` (artist configs don't use penalties)

### Reference Files (NOT modified, used as pattern)
- `app/controllers/admin/list_penalties_controller.rb` - Modal pattern
- `app/views/admin/list_penalties/index.html.erb` - Lazy-loaded turbo frame
- `app/components/admin/attach_penalty_modal_component.rb` - Component pattern
- `app/javascript/controllers/modal_form_controller.js` - Auto-close logic
- `app/models/penalty_application.rb` - Join model and validation reference
- `app/models/list_penalty.rb` - Similar join model pattern
- `test/controllers/admin/list_penalties_controller_test.rb` - Test patterns

## Dependencies
- **Phase 11 Complete**: List Penalties CRUD provides proven pattern
- **Phase 10 Complete**: Global Penalties CRUD provides penalty management
- **Existing Models**: PenaltyApplication, Penalty, RankingConfiguration
- **Existing**: modal-form Stimulus controller for auto-close
- **Existing**: Turbo Streams for real-time updates

## Success Metrics
- [ ] All 27+ controller tests passing
- [ ] All 9+ component tests passing
- [ ] Zero N+1 queries on ranking configuration show pages
- [ ] Turbo Stream updates work without page reload
- [ ] Modal auto-close works after submission
- [ ] Modal reloads after attach/detach to show updated available penalties
- [ ] Duplicate validation prevents database errors
- [ ] Media type validation enforced (compatibility rules)
- [ ] Value validation enforced (0-100 range)
- [ ] Authorization prevents non-admin access
- [ ] Lazy loading improves initial page load time
- [ ] Works for album and song ranking configurations (not artist configs)
- [ ] Artist ranking configuration show pages do NOT have penalty applications section
- [ ] Generic controller reusable for future Books/Movies/Games configurations

## Implementation Notes

### Approach Taken
(To be filled during implementation)

### Challenges Encountered
(To be filled during implementation)

### Deviations from Plan
(To be filled during implementation)

## Issues Found & Fixed
(To be filled during implementation)

## Acceptance Results
(To be filled during implementation)

## Documentation Updated
- [ ] This spec file (implementation notes, deviations, results, issues found & fixed)
- [ ] `docs/todo.md` (marked as completed)
- [ ] Class documentation for PenaltyApplicationsController (`docs/controllers/admin/penalty_applications_controller.md`)
- [ ] Class documentation for Admin::AddPenaltyToConfigurationModalComponent (`docs/components/admin/add_penalty_to_configuration_modal_component.md`)

## Related Tasks
- **Prerequisite**: [Phase 11 - List Penalties](completed/082-custom-admin-phase-11-list-penalties.md) ✅
- **Prerequisite**: [Phase 10 - Global Penalties](completed/081-custom-admin-phase-10-global-penalties.md) ✅
- **Reference**: [Phase 11 - List Penalties](completed/082-custom-admin-phase-11-list-penalties.md) ✅ (primary pattern source)
- **Next**: TBD - Phase 13 (possible next features: Books/Movies/Games configurations, public ranking pages)

## Definition of Done

- [ ] All Acceptance Criteria demonstrably pass (tests/screenshots)
  - Target: 27+ controller tests, 9+ component tests passing ✅
- [ ] No N+1 on ranking configuration show pages
  - Show: Uses `.includes(penalty_applications: :penalty)` ✅
- [ ] Penalty applications list working
  - Lazy-loaded turbo frame ✅
  - Table displays all penalty data correctly (name, type, dynamic_type, value) ✅
  - Value displayed as percentage ✅
  - Empty state shows when no penalties ✅
- [ ] Add/Edit/Delete working
  - Add modal opens with available penalties dropdown and value input ✅
  - Edit modal opens with current value pre-filled and penalty name read-only ✅
  - Form validation works (duplicate prevention, media type compatibility, value range) ✅
  - Turbo Stream updates table without reload ✅
  - Modals close on success ✅
  - Add modal reloads after add/delete to show updated available penalties ✅
- [ ] Works for applicable ranking configuration types
  - Albums ranking configuration show page integration complete ✅
  - Songs ranking configuration show page integration complete ✅
  - Artists ranking configuration does NOT have penalty applications (verified) ✅
- [ ] Docs updated
  - Task file: This spec updated with implementation notes ✅
  - todo.md: Task marked as completed ✅
  - Controller docs: Created for PenaltyApplicationsController ✅
  - Component docs: Created for Admin::AddPenaltyToConfigurationModalComponent ✅
  - Component docs: Created for Admin::EditPenaltyApplicationModalComponent ✅
- [ ] Links to authoritative code present
  - All file paths referenced throughout spec ✅
  - No large code dumps (snippets kept to minimum) ✅
- [ ] Security/auth reviewed
  - Admin authentication enforced ✅
  - Strong parameters protect mass assignment ✅
- [ ] Performance constraints met
  - Lazy loading for penalty applications frame ✅
  - Eager loading prevents N+1 queries ✅
  - No pagination needed (small data set) ✅
- [ ] Generic and reusable
  - Controller works across all domains ✅
  - ViewComponent extracted for reusability ✅
  - Can be easily extended to Books/Movies/Games configurations in future ✅

## Key References

**Pattern Sources - Controllers:**
- List Penalties controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/list_penalties_controller.rb`
- Base admin controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/base_controller.rb`
- Music Ranking Configurations controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranking_configurations_controller.rb`

**Pattern Sources - Views:**
- List penalties index: `/home/shane/dev/the-greatest/web-app/app/views/admin/list_penalties/index.html.erb`
- Albums ranking configuration show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/ranking_configurations/show.html.erb`
- Songs ranking configuration show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/ranking_configurations/show.html.erb`
- Albums lists show (modal integration): `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb`

**Pattern Sources - Components:**
- Add penalty modal component (reference - list_penalties): `/home/shane/dev/the-greatest/web-app/app/components/admin/attach_penalty_modal_component.rb`
- Add penalty modal template (reference - list_penalties): `/home/shane/dev/the-greatest/web-app/app/components/admin/attach_penalty_modal_component/attach_penalty_modal_component.html.erb`

**Models:**
- PenaltyApplication: `/home/shane/dev/the-greatest/web-app/app/models/penalty_application.rb`
- ListPenalty (similar join model): `/home/shane/dev/the-greatest/web-app/app/models/list_penalty.rb`
- Penalty: `/home/shane/dev/the-greatest/web-app/app/models/penalty.rb`
- RankingConfiguration: `/home/shane/dev/the-greatest/web-app/app/models/ranking_configuration.rb`

**Documentation:**
- PenaltyApplication docs: `/home/shane/dev/the-greatest/docs/models/penalty_application.md`
- ListPenalty docs (similar pattern): `/home/shane/dev/the-greatest/docs/models/list_penalty.md`
- Todo guide: `/home/shane/dev/the-greatest/docs/todo-guide.md`
- Sub-agents: `/home/shane/dev/the-greatest/docs/sub-agents.md`

**JavaScript:**
- Modal form controller: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/modal_form_controller.js`

**Tests:**
- List Penalties controller test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/list_penalties_controller_test.rb`
- Attach penalty modal component test: `/home/shane/dev/the-greatest/web-app/test/components/admin/attach_penalty_modal_component_test.rb`
