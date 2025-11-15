# 082 - Custom Admin Interface - Phase 11: List Penalties

## Status
- **Status**: In Progress
- **Priority**: High
- **Created**: 2025-11-15
- **Started**: 2025-11-15
- **Completed**: TBD
- **Developer**: Claude Code (AI Agent)

## Overview
Implement generic admin interface for managing the ListPenalty join table (connecting Lists to Penalties). This is a cross-domain feature that works for album lists, song lists, and eventually book/movie/game lists. Users can attach and detach penalties from list show pages via a modal interface. This follows the simpler pattern from Phase 5 (song_artists) but with a dropdown selector instead of autocomplete, and uses a generic non-namespaced controller.

## Context
- **Previous Phase Complete**: Global Penalties (Phase 10) - CRUD for penalties implemented
- **Join Table**: ListPenalty connects List → Penalty (simple many-to-many)
- **Generic Controller**: `Admin::ListPenaltiesController` (NOT namespaced under music/books/etc.)
- **Cross-Domain**: Works for all list types (Music::Songs::List, Music::Albums::List, Books::List, etc.)
- **Proven Pattern**: Phase 5 song_artists join table with modals (docs/todos/completed/076-custom-admin-phase-5-song-artists.md)
- **Simpler Interaction**: Dropdown selection (not autocomplete) since penalties are few in number
- **No Edit**: Only attach (create) and detach (destroy) - no need to edit once attached
- **Implementation Scope**: Album lists and song lists for now (Books/Movies/Games in future)

## Requirements

### Base List Penalty Management
- [ ] Generic controller: `Admin::ListPenaltiesController` (not namespaced)
- [ ] Modal-based interface for attach/detach operations
- [ ] Context-aware: works from any list show page
- [ ] Dropdown selection of available penalties (Global + matching media type)
- [ ] Validation preventing duplicate penalty assignments
- [ ] Media type compatibility validation (Music penalties only with Music lists, etc.)
- [ ] No pagination needed (small number of penalties per list)
- [ ] No sorting controls (always alphabetical by penalty name)

### List Show Page Integration
- [ ] New "Penalties" section on list show pages
- [ ] Lazy-loaded turbo frame for penalties list
- [ ] "Attach Penalty" button opens create modal
- [ ] Create modal: dropdown with available penalties (filtered by media type)
- [ ] Penalties table shows: name, type, dynamic_type, delete action
- [ ] Delete confirmation for detaching penalties
- [ ] Real-time updates via Turbo Streams
- [ ] Count badge showing number of attached penalties

### Display Requirements
- [ ] DaisyUI card with title "Penalties" and count badge
- [ ] Table columns: Name, Type, Dynamic Type, Actions
- [ ] Type badges with color coding (Global: blue, Music: purple)
- [ ] Dynamic type badges (Static vs specific dynamic type)
- [ ] Empty state when no penalties attached
- [ ] Delete button with confirmation

## API Endpoints

| Verb | Path | Purpose | Params/Body | Auth | Context |
|------|------|---------|-------------|------|---------|
| GET | `/admin/list/:list_id/list_penalties` | List penalties for a list | - | admin/editor | lazy-loaded frame |
| POST | `/admin/list/:list_id/list_penalties` | Attach penalty to list | `list_penalty[penalty_id]` | admin/editor | modal form |
| DELETE | `/admin/list_penalties/:id` | Detach penalty from list | - | admin/editor | table row |

**Route Helpers**:
- `admin_list_list_penalties_path(@list)` → GET index (lazy load)
- `admin_list_list_penalties_path(@list)` → POST create
- `admin_list_penalty_path(@list_penalty)` → DELETE destroy

**Note**: Routes are generic and work for all list types (not namespaced under music/books/etc.)

## Response Formats

### Success Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Penalty attached successfully." } })
turbo_stream.replace("list_penalties_list", partial: "admin/list_penalties/index",
  locals: { list: @list })
```

### Error Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { error: "Penalty is already attached to this list" } })
```

### Turbo Frame IDs
- Main frame: `"list_penalties_list"`
- Modal form targets this frame on success

## Behavioral Rules

### Preconditions
- User must have admin or editor role
- List must exist
- Penalty must exist
- Penalty media type must be compatible with list media type

### Postconditions (Attach)
- New ListPenalty record created linking list and penalty
- Turbo Stream updates penalties list without page reload
- Flash message confirms success
- Modal closes automatically

### Postconditions (Detach)
- ListPenalty record deleted
- Turbo Stream removes penalty from list
- Flash message confirms removal

### Invariants
- A list-penalty pair must be unique (database constraint + validation)
- Penalty media type must match list media type (or be Global)
- User must have appropriate authorization

### Edge Cases
- **Empty dropdown**: No available penalties shows "All compatible penalties already attached"
- **Duplicate attach**: Shows validation error, doesn't create
- **Media type mismatch**: Validation prevents Music penalty on Books list
- **Authorization failure**: Redirects to appropriate domain root

## Media Type Compatibility Rules

**From ListPenalty model validation** (`app/models/list_penalty.rb:58-87`):

- **Global::Penalty**: Works with ANY list type (Books, Music, Movies, Games)
- **Music::Penalty**: Only works with `Music::*::List` types (Albums::List, Songs::List)
- **Books::Penalty**: Only works with `Books::*::List` types
- **Movies::Penalty**: Only works with `Movies::*::List` types
- **Games::Penalty**: Only works with `Games::*::List` types

**Dropdown filtering logic**:
```ruby
# Reference only - implementation in controller/helper
def available_penalties(list)
  media_type = list.type.split("::").first # "Music", "Books", etc.

  Penalty
    .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
    .where.not(id: list.penalties.pluck(:id))
    .order(:name)
end
```

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load `list_penalties: :penalty` in list show controllers
- **Lazy Loading**: Use turbo frame with lazy loading for penalties list
- **No Pagination**: Small number of penalties per list (typically < 20)
- **Response Time**: < 500ms p95 for attach/detach

### Security
- **Authorization**: Enforce admin/editor role via BaseController
- **CSRF Protection**: Rails handles via form helpers
- **Parameter Filtering**: Strong params whitelist
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
- [ ] GET index renders penalties list (2 tests: with/without penalties)
- [ ] POST create attaches penalty (2 tests: success + turbo stream)
- [ ] Prevent duplicate penalty attachment (1 test)
- [ ] DELETE destroy detaches penalty (2 tests: success + turbo stream)
- [ ] Authorization enforcement (2 tests: create, destroy)
- [ ] Media type compatibility validation (3 tests: Global works, matching type works, mismatched type fails)

**Total Controller Tests**: ~12 tests

### Manual Acceptance Tests
- [ ] From album list show page: Attach penalty via dropdown, verify appears in table
- [ ] From album list show page: Detach penalty, verify disappears from table
- [ ] From song list show page: Attach penalty via dropdown, verify appears in table
- [ ] From song list show page: Detach penalty, verify disappears from table
- [ ] Verify dropdown only shows available penalties (not already attached)
- [ ] Verify dropdown filters by media type (Global + Music for music lists)
- [ ] Verify duplicate prevention shows error message
- [ ] Verify modals close automatically after successful submission
- [ ] Verify Turbo Stream updates work without page reload
- [ ] Verify lazy loading works (frame loads after page)
- [ ] Verify media type validation (can't attach Books penalty to Music list)

## Implementation Plan

### Step 1: Generate Controller & Routes
**Command**:
```bash
cd web-app
bin/rails generate controller Admin::ListPenalties index create destroy --no-helper --no-assets
```

**Files created**:
- `app/controllers/admin/list_penalties_controller.rb`
- `test/controllers/admin/list_penalties_controller_test.rb`

**Routes to add** (`config/routes.rb`):
```ruby
namespace :admin do
  # Existing routes...

  # Generic list penalties routes (cross-domain)
  scope "list/:list_id", as: "list" do
    resources :list_penalties, only: [:index, :create]
  end

  resources :list_penalties, only: [:destroy]
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb`

### Step 2: Implement Controller
**File**: `app/controllers/admin/list_penalties_controller.rb`

**Pattern**: Generic controller that works across all domains
- Inherit from `Admin::BaseController` (NOT music-specific base)
- `index` action: Load list_penalties with penalties, render without layout
- `create` action: Create new list_penalty with Turbo Stream response
- `destroy` action: Delete list_penalty with Turbo Stream response
- Strong params: whitelist `penalty_id`
- Helper method for available penalties filtering

**Key differences from song_artists**:
- No context detection (always from list show page)
- No position field (ListPenalty has no position)
- Generic controller (works for all media types)
- Simple dropdown (not autocomplete)

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/song_artists_controller.rb`

### Step 3: Create View Template for Index
**File**: `app/views/admin/list_penalties/index.html.erb`

**Pattern**: Turbo frame wrapping table
- Wrap in `turbo_frame_tag "list_penalties_list"`
- Table with columns: Name, Type, Dynamic Type, Actions
- Badge styling for type and dynamic_type
- Delete button with turbo_confirm
- Empty state when no penalties
- No layout (rendered in turbo frame)

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/ranked_items/index.html.erb:1-82`

### Step 4: Integrate into Album Lists Show Page
**File**: `app/views/admin/music/albums/lists/show.html.erb`

**Add Section** (after existing sections):
```erb
<!-- Penalties Section -->
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Penalties
        <span class="badge badge-ghost"><%= @list.list_penalties.count %></span>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="attach_penalty_modal.showModal()">
        + Attach Penalty
      </button>
    </div>
    <%= turbo_frame_tag "list_penalties_list", loading: :lazy,
        src: admin_list_list_penalties_path(@list) do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
</div>

<!-- Attach Penalty Modal -->
<dialog id="attach_penalty_modal" class="modal">
  <div class="modal-box">
    <h3 class="font-bold text-lg">Attach Penalty</h3>
    <%= form_with model: ListPenalty.new,
                  url: admin_list_list_penalties_path(@list),
                  method: :post,
                  class: "space-y-4",
                  data: {
                    controller: "modal-form",
                    modal_form_modal_id_value: "attach_penalty_modal",
                    turbo_frame: "list_penalties_list"
                  } do |f| %>

      <div class="form-control">
        <%= f.label :penalty_id, "Penalty", class: "label" %>
        <%= f.select :penalty_id,
            options_from_collection_for_select(available_penalties(@list), :id, :name),
            { prompt: "Select a penalty..." },
            { class: "select select-bordered w-full", required: true } %>
        <label class="label">
          <span class="label-text-alt">Only compatible penalties shown (Global + <%= @list.type.split("::").first %>)</span>
        </label>
      </div>

      <div class="modal-action">
        <button type="button" class="btn" onclick="attach_penalty_modal.close()">Cancel</button>
        <%= f.submit "Attach Penalty", class: "btn btn-primary" %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/show.html.erb:385-448`

### Step 5: Integrate into Song Lists Show Page
**File**: `app/views/admin/music/songs/lists/show.html.erb`

**Same pattern as Step 4** - add identical penalties section with modal

### Step 6: Update List Controllers for Eager Loading
**Files**:
- `app/controllers/admin/music/albums/lists_controller.rb`
- `app/controllers/admin/music/songs/lists_controller.rb`

**Update show action**:
```ruby
def show
  @list = list_class
    .includes(:list_items, list_penalties: :penalty) # Add list_penalties eager loading
    .find(params[:id])
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/albums/lists_controller.rb`

### Step 7: Create Helper for Available Penalties
**File**: `app/helpers/admin/list_penalties_helper.rb` or directly in controller

**Method**:
```ruby
def available_penalties(list)
  media_type = list.type.split("::").first # "Music", "Books", etc.

  Penalty
    .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
    .where.not(id: list.penalties.pluck(:id))
    .order(:name)
end
```

### Step 8: Write Controller Tests
**File**: `test/controllers/admin/list_penalties_controller_test.rb`

**Test structure**:
```ruby
require "test_helper"

module Admin
  class ListPenaltiesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @album_list = music_albums_lists(:rolling_stone_500)
      @song_list = music_songs_lists(:billboard_hot_100)
      @global_penalty = penalties(:global_low_voters)
      @music_penalty = penalties(:music_category_specific)

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    # Index tests (with/without penalties)
    # Create tests (success, duplicate prevention, media type validation)
    # Destroy tests (success)
    # Authorization tests (create, destroy)
  end
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/music/song_artists_controller_test.rb`

### Step 9: Manual Testing
**Prerequisites**:
- Album lists and song lists exist
- Penalties exist (Global and Music types)
- Admin user authenticated

**Test scenarios**:
1. Visit album list show page → See penalties section with count
2. Click "Attach Penalty" → Modal opens with dropdown
3. Select penalty → Submit → Penalty appears in table
4. Click "Detach" → Confirm → Penalty disappears
5. Try to attach same penalty twice → See error message
6. Verify dropdown only shows Global + Music penalties
7. Verify lazy loading works

## Golden Examples

### Example 1: Attaching Penalty to List (Happy Path)

**Action**: User visits album list show page, clicks "Attach Penalty", selects "Low Voter Count" global penalty, submits

**Request**:
```
POST /admin/list/123/list_penalties
Params: { list_penalty: { penalty_id: 456 } }
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Penalty attached successfully." } })
turbo_stream.replace("list_penalties_list",
  partial: "admin/list_penalties/index",
  locals: { list: @list })
```

**Result**:
- ListPenalty record created linking list 123 and penalty 456
- Flash shows "Penalty attached successfully."
- Penalties table updates to show "Low Voter Count | Global | Number of Voters"
- Modal closes automatically
- No page reload

### Example 2: Media Type Compatibility Validation

**Action**: User tries to attach Books::Penalty to Music::Albums::List

**Request**:
```
POST /admin/list/123/list_penalties
Params: { list_penalty: { penalty_id: 789 } }
```

**Validation fails**: `Penalty media type (Books) is not compatible with list media type (Music)`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "Penalty media type is not compatible with list media type" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can select compatible penalty

## Agent Hand-Off

### Constraints
- Follow existing song_artists pattern for modals - do not introduce new architecture
- Simpler than song_artists: dropdown selection, no autocomplete needed, no position field
- Generic controller (NOT namespaced under music/books/etc.)
- Keep code snippets ≤40 lines in documentation
- Link to reference files by path

### Required Outputs
- `app/controllers/admin/list_penalties_controller.rb` (new)
- `test/controllers/admin/list_penalties_controller_test.rb` (new)
- `app/views/admin/list_penalties/index.html.erb` (new)
- `app/helpers/admin/list_penalties_helper.rb` (new - for available_penalties method)
- `config/routes.rb` (update - add list_penalties routes)
- `app/views/admin/music/albums/lists/show.html.erb` (update - add penalties section)
- `app/views/admin/music/songs/lists/show.html.erb` (update - add penalties section)
- `app/controllers/admin/music/albums/lists_controller.rb` (update - eager loading)
- `app/controllers/admin/music/songs/lists_controller.rb` (update - eager loading)
- All tests passing (12+ controller tests)
- Updated sections in this spec: "Implementation Notes", "Deviations", "Acceptance Results"

### Sub-Agent Plan
1. **codebase-analyzer** → Verify list show page structure and integration points
2. **codebase-pattern-finder** → Collect song_artists modal patterns (COMPLETED above)
3. **general-purpose** → Implement controller, routes, views, tests following patterns
4. **technical-writer** → Update this spec with implementation notes and results

### Test Fixtures Required
Verify these fixtures exist and have proper data:
- `test/fixtures/penalties.yml` - Global and Music penalties
- `test/fixtures/music/albums/lists.yml` - Album lists for testing
- `test/fixtures/music/songs/lists.yml` - Song lists for testing
- `test/fixtures/list_penalties.yml` - Sample list-penalty associations
- `test/fixtures/users.yml` - admin_user, regular_user

## Key Files Touched

### New Files
- `app/controllers/admin/list_penalties_controller.rb`
- `test/controllers/admin/list_penalties_controller_test.rb`
- `app/views/admin/list_penalties/index.html.erb`
- `app/helpers/admin/list_penalties_helper.rb`

### Modified Files
- `config/routes.rb` (add list_penalties routes)
- `app/views/admin/music/albums/lists/show.html.erb` (add penalties section)
- `app/views/admin/music/songs/lists/show.html.erb` (add penalties section)
- `app/controllers/admin/music/albums/lists_controller.rb` (eager loading)
- `app/controllers/admin/music/songs/lists_controller.rb` (eager loading)

### Reference Files (NOT modified, used as pattern)
- `app/controllers/admin/music/song_artists_controller.rb` - Modal pattern
- `app/views/admin/music/songs/show.html.erb` - Modal integration
- `app/views/admin/music/ranked_items/index.html.erb` - Lazy-loaded turbo frame
- `app/javascript/controllers/modal_form_controller.js` - Auto-close logic
- `app/models/list_penalty.rb` - Join model and validation reference

## Dependencies
- **Phase 10 Complete**: Global Penalties CRUD provides penalty management
- **Phase 9 Complete**: Song Lists show page provides integration point
- **Phase 8 Complete**: Album Lists show page provides integration point
- **Existing Models**: ListPenalty, Penalty, List
- **Existing**: modal-form Stimulus controller for auto-close
- **Existing**: Turbo Streams for real-time updates

## Success Metrics
- [ ] All 12+ controller tests passing
- [ ] Zero N+1 queries on list show pages
- [ ] Turbo Stream updates work without page reload
- [ ] Modal auto-close works after submission
- [ ] Duplicate validation prevents database errors
- [ ] Media type validation enforced (compatibility rules)
- [ ] Authorization prevents non-admin access
- [ ] Lazy loading improves initial page load time
- [ ] Works for both album lists and song lists
- [ ] Generic controller reusable for future Books/Movies/Games lists

## Implementation Notes

### Approach Taken
_To be filled during implementation_

### Challenges Encountered
_To be filled during implementation_

### Deviations from Plan
_To be filled during implementation_

## Acceptance Results

### Automated Test Results
_To be filled after implementation_

### Manual Test Results
_To be filled after implementation_

### Files Created/Modified
See "Key Files Touched" section for complete list.

## Documentation Updated
- [ ] This spec file (implementation notes, deviations, results)
- [ ] `docs/todo.md` (marked as completed when done)
- [ ] Class documentation for ListPenaltiesController
- [ ] Update List controller docs if needed

## Related Tasks
- **Prerequisite**: [Phase 10 - Global Penalties](completed/081-custom-admin-phase-10-global-penalties.md) ✅
- **Prerequisite**: [Phase 9 - Song Lists](completed/080-custom-admin-phase-9-song-lists.md) ✅
- **Prerequisite**: [Phase 8 - Album Lists](completed/079-custom-admin-phase-8-album-lists.md) ✅
- **Reference**: [Phase 5 - Song Artists](completed/076-custom-admin-phase-5-song-artists.md) ✅
- **Next**: Phase 12 - Music Penalties (Music::Penalty CRUD with type-specific features)

## Definition of Done

- [ ] All Acceptance Criteria demonstrably pass (tests/screenshots)
  - Target: 12+ controller tests passing
- [ ] No N+1 on list show pages
  - Show: Uses `.includes(list_penalties: :penalty)`
- [ ] Penalties list working
  - Lazy-loaded turbo frame
  - Table displays all penalty data correctly
  - Empty state shows when no penalties
- [ ] Attach/Detach working
  - Modal opens with available penalties dropdown
  - Form validation works (duplicate prevention, media type compatibility)
  - Turbo Stream updates table without reload
  - Modal closes on success
- [ ] Works for both list types
  - Album lists show page integration complete
  - Song lists show page integration complete
- [ ] Docs updated
  - Task file: This spec updated with implementation notes
  - todo.md: Task marked as completed when done
  - Controller docs: Created for ListPenaltiesController
- [ ] Links to authoritative code present
  - All file paths referenced throughout spec
  - No large code dumps (snippets kept to minimum)
- [ ] Security/auth reviewed
  - Admin authentication enforced
  - Strong parameters protect mass assignment
- [ ] Performance constraints met
  - Lazy loading for penalties frame
  - Eager loading prevents N+1 queries
  - No pagination needed (small data set)
- [ ] Generic and reusable
  - Controller works across all domains
  - Can be easily extended to Books/Movies/Games lists in future

## Key References

**Pattern Sources - Controllers:**
- Song Artists controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/song_artists_controller.rb`
- Ranked Items controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/ranked_items_controller.rb`
- Base admin controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/base_controller.rb`

**Pattern Sources - Views:**
- Song show with artists: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/show.html.erb`
- Artists list partial: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/_artists_list.html.erb`
- Ranked items index: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/ranked_items/index.html.erb`
- Album lists show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb`
- Song lists show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/show.html.erb`

**Models:**
- ListPenalty: `/home/shane/dev/the-greatest/web-app/app/models/list_penalty.rb`
- Penalty: `/home/shane/dev/the-greatest/web-app/app/models/penalty.rb`
- List: `/home/shane/dev/the-greatest/web-app/app/models/list.rb`

**Documentation:**
- ListPenalty docs: `/home/shane/dev/the-greatest/docs/models/list_penalty.md`
- Todo guide: `/home/shane/dev/the-greatest/docs/todo-guide.md`
- Sub-agents: `/home/shane/dev/the-greatest/docs/sub-agents.md`

**JavaScript:**
- Modal form controller: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/modal_form_controller.js`

**Tests:**
- Song Artists test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/music/song_artists_controller_test.rb`
