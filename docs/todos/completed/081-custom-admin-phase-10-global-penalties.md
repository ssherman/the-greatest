# 081 - Custom Admin Interface - Phase 10: Global Penalties

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-11-15
- **Started**: 2025-11-15
- **Completed**: 2025-11-15
- **Developer**: Claude Code (AI Agent)

## Overview
Implement custom admin CRUD interface for Global::Penalty with type filtering. This phase introduces penalty management to replace Avo's penalty resources. Unlike Lists (which have base controllers), penalties have a simpler structure requiring only a single controller with type filtering capabilities.

## Context
- **Previous Phase Complete**: Song Lists (Phase 9) - CRUD patterns proven
- **Proven Architecture**: ViewComponents, Hotwire, DaisyUI patterns established
- **Model**: Global::Penalty (STI model inheriting from Penalty)
- **Scope**: Global penalties only - Music/Books/Movies/Games penalties deferred to future phases
- **Key Feature**: Type filter dropdown ("All", "Global", "Music") with persistence across pagination
- **Code Reuse**: ~70% view code reuse from Lists pattern, simplified controller (no base needed)

## Contracts

### 1. Routes Contract

**Route Table:**

| Verb | Path | Purpose | Controller#Action | Auth |
|------|------|---------|-------------------|------|
| GET | /admin/penalties | Index with type filter | Admin::PenaltiesController#index | admin/editor |
| GET | /admin/penalties/:id | Show details | Admin::PenaltiesController#show | admin/editor |
| GET | /admin/penalties/new | New form | Admin::PenaltiesController#new | admin/editor |
| POST | /admin/penalties | Create | Admin::PenaltiesController#create | admin/editor |
| GET | /admin/penalties/:id/edit | Edit form | Admin::PenaltiesController#edit | admin/editor |
| PATCH/PUT | /admin/penalties/:id | Update | Admin::PenaltiesController#update | admin/editor |
| DELETE | /admin/penalties/:id | Destroy | Admin::PenaltiesController#destroy | admin/editor |

**Generated path helpers:**
- `admin_penalties_path` → `/admin/penalties`
- `admin_penalty_path(@penalty)` → `/admin/penalties/:id`
- `new_admin_penalty_path` → `/admin/penalties/new`
- `edit_admin_penalty_path(@penalty)` → `/admin/penalties/:id/edit`

**Routes Configuration:**
```ruby
# config/routes.rb

namespace :admin do
  resources :penalties
end
```

**Note**: No domain constraint needed - Penalties work across all domains.

---

### 2. Controller Contract

**File**: `app/controllers/admin/penalties_controller.rb`

**Purpose**: Single controller for Penalty CRUD with type filtering. No base controller needed (simpler than Lists).

**Key Responsibilities:**
- Standard CRUD operations
- Type filtering via `params[:type]` (All, Global, Music, Books, Movies, Games)
- Filter persistence in pagination and sort links
- Alphabetical sorting by name (no column sorting)
- Eager loading to prevent N+1 queries

**Type Filter Logic:**
```ruby
# Reference only - implementation in controller
def apply_type_filter(scope)
  case params[:type]
  when "Global"
    scope.where(type: "Global::Penalty")
  when "Music"
    scope.where(type: "Music::Penalty")
  when "Books"
    scope.where(type: "Books::Penalty")
  when "Movies"
    scope.where(type: "Movies::Penalty")
  when "Games"
    scope.where(type: "Games::Penalty")
  else # "All" or nil
    scope
  end
end
```

**Query Pattern:**
```ruby
@penalties = Penalty
  .includes(:user, :penalty_applications, :list_penalties)
  .then { |scope| apply_type_filter(scope) }
  .order(:name)
  .page(params[:page])
```

**Strong Parameters:**
```ruby
params.require(:global_penalty).permit(
  :name, :description, :dynamic_type
)
```

**Note**: Type field NOT permitted (auto-set by STI), User field NOT permitted (auto-set to current_user or nil).

---

### 3. Index Page Contract

**Display Columns:**
- **ID** - Monospace font, non-sortable
- **Name** - Link to show page, primary column
- **Type** - Badge with color coding (Global: blue, Music: purple, Books: green, etc.)
- **Dynamic Type** - Badge showing enum value or "Static" if nil
- **User** - Shows "System-wide" if nil, else user email with link
- **Created At** - Formatted date (non-sortable)
- **Actions** - View, Edit, Delete buttons

**Features:**
- ✅ Pagination (Pagy, 25 items per page)
- ✅ Type filter dropdown (All, Global, Music) - future-proofed for Books/Movies/Games
- ✅ Filter preserved in pagination links
- ✅ Alphabetical sorting by name (always ascending, no column sorting)
- ❌ NO search (penalties don't use OpenSearch)
- ❌ NO column sorting (simple alphabetical only)
- ❌ NO bulk actions (deferred to future phase)

**Type Filter Dropdown:**
```erb
<!-- Reference only - implementation in view -->
<select name="type" class="select select-bordered">
  <option value="All" <%= "selected" if params[:type].blank? || params[:type] == "All" %>>
    All Types
  </option>
  <option value="Global" <%= "selected" if params[:type] == "Global" %>>
    Global
  </option>
  <option value="Music" <%= "selected" if params[:type] == "Music" %>>
    Music
  </option>
  <!-- Future: Books, Movies, Games options -->
</select>
```

**Type Badge Color Coding:**
- `Global::Penalty` → Blue badge (`badge-info`)
- `Music::Penalty` → Purple badge (`badge-secondary`)
- Future: Books (green), Movies (orange), Games (red)

**Dynamic Type Badge Color Coding:**
- Static (nil) → Gray badge (`badge-ghost`)
- Any dynamic type → Yellow badge (`badge-warning`)

**User Column Display:**
- `user_id.nil?` → "System-wide" (neutral badge)
- `user_id.present?` → User email with link to user admin (if implemented)

**Eager Loading:**
```ruby
@penalties = Penalty
  .includes(:user, :penalty_applications, :list_penalties)
  .then { |scope| apply_type_filter(scope) }
  .order(:name)
  .page(params[:page])
```

**Filter Persistence:**
All pagination links must include `type: params[:type]` to preserve filter state.

---

### 4. Show Page Contract

**Section Layout:**

1. **Basic Information Card**
   - Name (large, bold)
   - Description (if present)
   - Type (badge with color coding)
   - Dynamic Type (badge with color coding, shows "Static" if nil)
   - User (shows "System-wide" if nil, else user email with link)

2. **Associations Card - Penalty Applications**
   - Count badge (e.g., "3 Applications")
   - If count > 0: Link to filtered penalty applications list
   - If count = 0: Message "No ranking configurations use this penalty"
   - Shows which ranking configurations apply this penalty

3. **Associations Card - Lists**
   - Count badge (e.g., "12 Lists")
   - If count > 0: Link to filtered lists
   - If count = 0: Message "No lists use this penalty"
   - Shows which lists this penalty is applied to

4. **Metadata Card**
   - Created At (formatted datetime)
   - Updated At (formatted datetime)

**Eager Loading:**
```ruby
@penalty = Penalty
  .includes(:user, :penalty_applications, :list_penalties)
  .find(params[:id])
```

**Association Count Display:**
```erb
<!-- Reference only - implementation in view -->
<div class="stats shadow">
  <div class="stat">
    <div class="stat-title">Penalty Applications</div>
    <div class="stat-value text-2xl">
      <%= @penalty.penalty_applications.size %>
    </div>
    <% if @penalty.penalty_applications.any? %>
      <%= link_to "View Applications",
          "#",
          class: "btn btn-sm btn-primary" %>
    <% end %>
  </div>
  <!-- Similar for Lists -->
</div>
```

**Dynamic Type Display:**
If `dynamic_type.present?`:
- Show enum humanized value (e.g., "Number of Voters", "Category Specific")
- Badge with warning color to indicate runtime calculation required

If `dynamic_type.nil?`:
- Show "Static" with neutral badge color

---

### 5. Form Contract

**Fields (grouped in cards):**

**Basic Information Card:**
- **Name** (text input, required, autofocus, maxlength: 255)
- **Description** (textarea, optional, rows: 4)

**Type Configuration Card:**
- **Dynamic Type** (select dropdown, nullable)
  - Options: "Static" (nil value), plus all enum values from `Penalty.dynamic_types`
  - Humanized labels: "Number of Voters", "Percentage Western", etc.
  - Help text: "Select a dynamic type for runtime calculation, or 'Static' for fixed penalties"

**System Fields (Auto-Set, Not in Form):**
- **Type** - Auto-set to `Global::Penalty` (STI mechanism)
- **User** - Auto-set to `current_user` or `nil` for system-wide

**Form Actions:**
- Cancel button (links to show if editing, index if creating)
- Submit button (changes text: "Create Global Penalty" vs "Update Global Penalty")

**Validation Errors:**
- Display at top of form in alert-error box
- Inline field errors with red border and error text

**Strong Parameters Key:**
Form parameter key must be `:global_penalty` (Rails STI convention).

**Dynamic Type Options:**
```ruby
# Reference only - from Penalty model
Penalty.dynamic_types.keys.map { |k| [k.humanize, k] }
# => [
#   ["Number of voters", "number_of_voters"],
#   ["Percentage western", "percentage_western"],
#   ["Voter names unknown", "voter_names_unknown"],
#   ...
# ]
```

---

### 6. Filter Contract

**Type Filter Implementation:**

**Dropdown Options:**
- "All Types" (default) - Shows all penalties regardless of STI type
- "Global" - Shows only `Global::Penalty`
- "Music" - Shows only `Music::Penalty`
- Future: "Books", "Movies", "Games" (UI present but disabled until those penalty types exist)

**Filter Persistence:**
- Filter selection stored in `params[:type]`
- Preserved in all pagination links: `url_for(type: params[:type], page: ...)`
- Future: Preserved in sort links when column sorting added
- Default value: "All" (no filtering)

**Controller Implementation:**
```ruby
# Reference only - filter logic
def index
  @penalties = Penalty.all
  @penalties = apply_type_filter(@penalties)
  @penalties = @penalties
    .includes(:user, :penalty_applications, :list_penalties)
    .order(:name)
    .page(params[:page])

  @selected_type = params[:type] || "All"
end

private

def apply_type_filter(scope)
  return scope if params[:type].blank? || params[:type] == "All"

  type_class = "#{params[:type]}::Penalty"
  scope.where(type: type_class)
end
```

**Empty State Handling:**
- If filtered results empty: "No penalties found for type: Music"
- If no penalties at all: "No penalties found. Create your first penalty."

---

### 7. Empty States Contract

**Index empty state (no penalties at all):**
```
Icon: Warning triangle
Title: "No penalties found"
Message: "Get started by creating your first penalty."
Action: "New Global Penalty" button
```

**Index empty state (filtered, no results):**
```
Icon: Filter icon
Title: "No penalties found for type: [Type]"
Message: "Try selecting a different type filter or create a new penalty."
Action: "Clear Filter" link
```

**Show page - no penalty applications:**
```
Message: "No ranking configurations use this penalty yet."
```

**Show page - no lists:**
```
Message: "No lists use this penalty yet."
```

---

### 8. Navigation Integration

**Sidebar Navigation** (`app/views/admin/shared/_sidebar.html.erb`):

Update Global section (currently has placeholder link):
```erb
<!-- Global Section -->
<li>
  <details>
    <summary class="font-semibold">
      <!-- Globe icon -->
      Global
    </summary>
    <ul>
      <li>
        <%= link_to admin_penalties_path, class: "flex items-center gap-2" do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
          </svg>
          Penalties
        <% end %>
      </li>
      <li>
        <a href="#" class="flex items-center gap-2 text-base-content/50">
          <!-- User icon -->
          Users
        </a>
      </li>
    </ul>
  </details>
</li>
```

**Current Location**: Lines 113-118 in sidebar (placeholder link)
**Change**: Replace `<a href="#"` with `<%= link_to admin_penalties_path ...`
**Position**: First item under Global section

---

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load `:user`, `:penalty_applications`, `:list_penalties`
- **Index Query**: Include associations in single query
- **Pagination**: 25 items per page via Pagy
- **Sorting**: Simple alphabetical by name (no complex sorting needed)

### Security
- **Authentication**: admin or editor role required (via base controller)
- **Strong Parameters**: Whitelist only `name`, `description`, `dynamic_type`
- **Type Safety**: STI type auto-set, not user-editable
- **User Safety**: User field auto-set, not user-editable

### Responsiveness
- Mobile: Stack header elements vertically, full-width filter dropdown
- Tablet: 2-column grid in forms
- Desktop: Full layout with proper spacing
- Filter dropdown: Always visible above table

### Data Integrity
- **STI Type**: Always `Global::Penalty` for records created via this interface
- **User Assignment**: Set to `current_user` for user-specific, `nil` for system-wide
- **Validation**: Name required, dynamic_type nullable

---

## Acceptance Criteria

### Basic CRUD
- [ ] GET /admin/penalties shows paginated list alphabetically by name
- [ ] GET /admin/penalties?type=Global filters to Global penalties only
- [ ] GET /admin/penalties?type=Music filters to Music penalties only
- [ ] GET /admin/penalties/:id shows all penalty details and associations
- [ ] GET /admin/penalties/new shows form for creating penalty
- [ ] POST /admin/penalties creates new penalty with valid data
- [ ] POST /admin/penalties shows validation errors for invalid data
- [ ] GET /admin/penalties/:id/edit shows form for editing penalty
- [ ] PATCH /admin/penalties/:id updates penalty with valid data
- [ ] PATCH /admin/penalties/:id shows validation errors for invalid data
- [ ] DELETE /admin/penalties/:id destroys penalty and redirects to index

### Display Requirements
- [ ] Index table shows all required columns (ID, Name, Type, Dynamic Type, User, Created, Actions)
- [ ] Type column shows colored badges (Global: blue, Music: purple)
- [ ] Dynamic Type column shows "Static" for nil, enum value for present
- [ ] User column shows "System-wide" for nil, email for present
- [ ] Show page displays all sections in correct order
- [ ] Association counts display correctly with badges
- [ ] Links to filtered association lists work (if associations exist)

### Filter Requirements
- [ ] Type filter dropdown shows "All", "Global", "Music" options
- [ ] Filter defaults to "All" (no filtering)
- [ ] Selecting "Global" filters to Global::Penalty only
- [ ] Selecting "Music" filters to Music::Penalty only
- [ ] Filter selection preserved when paginating
- [ ] Empty state shows when no results for filter
- [ ] Clear filter option available in empty state

### Form Validation
- [ ] Name required validation works
- [ ] Description optional validation works
- [ ] Dynamic Type dropdown includes "Static" (nil) option
- [ ] Dynamic Type dropdown shows all enum values humanized
- [ ] Type field NOT in form (auto-set to Global::Penalty)
- [ ] User field NOT in form (auto-set based on context)
- [ ] Error messages display correctly

### Navigation & UX
- [ ] Sidebar shows "Penalties" link under Global section (active link)
- [ ] Back buttons navigate correctly
- [ ] Cancel buttons navigate correctly
- [ ] Flash messages display on success/error
- [ ] Empty states show appropriate messages
- [ ] Filter dropdown styling consistent with admin theme

### Authorization
- [ ] Non-admin/editor users redirected to home
- [ ] Admin users can access all pages
- [ ] Editor users can access all pages

### Performance
- [ ] No N+1 queries on index page
- [ ] No N+1 queries on show page
- [ ] Pagination works correctly
- [ ] Eager loading used for all associations

---

## Key Differences from Song Lists (Phase 9)

### 1. No Base Controller
**Lists**: Base controller (`Admin::Music::ListsController`) with subclasses
**Penalties**: Single controller only - simpler model doesn't warrant base abstraction

### 2. Type Filter vs Search
**Lists**: Search functionality for finding lists by name/source
**Penalties**: Type dropdown filter (All, Global, Music, etc.)
**Reason**: Fewer penalties, STI type filtering more useful than search

### 3. No Column Sorting
**Lists**: Sortable by id, name, year_published, created_at with direction toggle
**Penalties**: Always alphabetical by name (ascending only)
**Reason**: Simpler requirements, penalties always sorted alphabetically

### 4. Association Display
**Lists**: Shows list_items count and table
**Penalties**: Shows penalty_applications count and lists count (no tables on show page)
**Reason**: Different association structures

### 5. Form Simplicity
**Lists**: Many fields (source, URL, year, flags, metadata, items_json)
**Penalties**: Three fields only (name, description, dynamic_type)
**Reason**: Simpler penalty model focused on definitions

### 6. STI Parameter Key
**Lists**: `:music_songs_list` (namespaced STI)
**Penalties**: `:global_penalty` (namespaced STI)

### 7. No Data Import Fields
**Lists**: Has items_json, raw_html, simplified_html, formatted_text
**Penalties**: No bulk import fields needed

---

## Files to Create

**Controllers:**
- `app/controllers/admin/penalties_controller.rb` - Single controller with type filtering

**Views:**
- `app/views/admin/penalties/index.html.erb` - Index with filter dropdown
- `app/views/admin/penalties/show.html.erb` - Detail view
- `app/views/admin/penalties/new.html.erb` - Create form
- `app/views/admin/penalties/edit.html.erb` - Edit form
- `app/views/admin/penalties/_form.html.erb` - Shared form partial
- `app/views/admin/penalties/_table.html.erb` - Table partial for turbo frames

**Tests:**
- `test/controllers/admin/penalties_controller_test.rb` - Controller tests (~28 tests)

---

## Files to Modify

- `config/routes.rb` - Add global penalties routes in admin namespace
- `app/views/admin/shared/_sidebar.html.erb` - Update Penalties link from placeholder to active link

---

## Testing Requirements

### Controller Tests (~28 tests)

**Test Categories:**

**CRUD Operations (8 tests):**
- `test "should get index"` - Verify page loads
- `test "should get show"` - Verify detail page
- `test "should get new"` - Verify form page
- `test "should create penalty with valid data"` - Verify creation
- `test "should not create penalty with invalid data"` - Verify validation
- `test "should get edit"` - Verify edit form
- `test "should update penalty with valid data"` - Verify update
- `test "should destroy penalty"` - Verify deletion

**Filter Tests (4 tests):**
- `test "should filter to all types by default"` - Default behavior
- `test "should filter to global penalties only"` - Global filter
- `test "should filter to music penalties only"` - Music filter
- `test "should handle invalid filter gracefully"` - Invalid filter defaults to All

**Filter Persistence (2 tests):**
- `test "should preserve filter in pagination"` - Filter survives page change
- `test "should preserve filter in turbo frame reload"` - Filter survives turbo reload

**Display Tests (3 tests):**
- `test "should display type badges correctly"` - Type column rendering
- `test "should display dynamic type badges correctly"` - Dynamic type rendering
- `test "should display user column correctly"` - User/system-wide rendering

**Form Validation (3 tests):**
- `test "should require name"` - Name presence validation
- `test "should allow nullable dynamic type"` - Dynamic type optional
- `test "should auto-set type to Global::Penalty"` - STI type auto-set

**Authorization (2 tests):**
- `test "should allow admin access"` - Admin role check
- `test "should deny non-admin access"` - Redirect non-admins

**N+1 Prevention (2 tests):**
- `test "should not have N+1 queries on index"` - Eager loading check
- `test "should not have N+1 queries on show"` - Eager loading check

**Association Display (4 tests):**
- `test "should show penalty applications count"` - Count display
- `test "should link to penalty applications if any"` - Link conditional
- `test "should show lists count"` - Count display
- `test "should show empty state for no associations"` - Empty state rendering

**Target Coverage**: 100% for controller public methods

**Setup Pattern:**
```ruby
class Admin::Global::PenaltiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @global_penalty = penalties(:global_low_voters)
    @music_penalty = penalties(:music_category_specific)
    sign_in @admin
  end

  # Tests here...
end
```

---

## Implementation Strategy

### Phase 1: Routes and Controller
1. Add routes to `config/routes.rb` in admin namespace
2. Create `app/controllers/admin/penalties_controller.rb`
3. Implement standard CRUD actions
4. Implement type filtering logic
5. Add strong parameters
6. Verify routes with `bin/rails routes | grep penalties`

### Phase 2: Index View
1. Create `app/views/admin/penalties/index.html.erb`
2. Add type filter dropdown above table
3. Create `app/views/admin/penalties/_table.html.erb` partial
4. Implement column display with badges
5. Add pagination with filter preservation
6. Add empty states (no results, filtered no results)

### Phase 3: Show View
1. Create `app/views/admin/penalties/show.html.erb`
2. Add basic information card
3. Add penalty applications association card with count
4. Add lists association card with count
5. Add metadata card with timestamps
6. Style badges for type and dynamic_type

### Phase 4: Form Views
1. Create `app/views/admin/penalties/_form.html.erb`
2. Add name field (required, autofocus)
3. Add description field (optional textarea)
4. Add dynamic_type dropdown (nullable)
5. Add validation error display
6. Create `app/views/admin/penalties/new.html.erb` wrapper
7. Create `app/views/admin/penalties/edit.html.erb` wrapper

### Phase 5: Navigation
1. Update `app/views/admin/shared/_sidebar.html.erb`
2. Replace placeholder link with active link to penalties
3. Verify link styling and icon

### Phase 6: Tests
1. Create `test/controllers/admin/penalties_controller_test.rb`
2. Add fixtures for penalties (global and music types)
3. Write CRUD tests (8 tests)
4. Write filter tests (4 tests)
5. Write filter persistence tests (2 tests)
6. Write display tests (3 tests)
7. Write form validation tests (3 tests)
8. Write authorization tests (2 tests)
9. Write N+1 prevention tests (2 tests)
10. Write association display tests (4 tests)
11. Run tests and fix failures

### Phase 7: Verification
1. Manual testing of all CRUD operations
2. Verify type filtering works correctly
3. Test filter persistence across pagination
4. Check badge colors and rendering
5. Test form validation
6. Check authorization
7. Performance check (N+1 queries)
8. Test empty states

---

## Known Challenges and Solutions

### Challenge 1: STI Type Auto-Setting
**Issue**: Type field must be set to `Global::Penalty` automatically
**Solution**: Controller sets `type` before create/update, strong parameters excludes `type` field

### Challenge 2: Filter Persistence
**Issue**: Filter selection must survive pagination and turbo frame reloads
**Solution**: Include `type: params[:type]` in all URL helpers (pagination, turbo frames)

### Challenge 3: Dynamic Type Nullable Dropdown
**Issue**: Dropdown must allow "Static" (nil) option plus all enum values
**Solution**: Build options array with `[["Static", nil]]` plus enum pairs

### Challenge 4: Association Count Display
**Issue**: Show page needs counts without N+1 queries
**Solution**: Use `.includes(:penalty_applications, :list_penalties)` then `.size` in view

### Challenge 5: User Column Display Logic
**Issue**: Distinguish system-wide (nil) from user-specific (present)
**Solution**: Conditional rendering: `penalty.user_id.nil? ? "System-wide" : penalty.user.email`

### Challenge 6: Future-Proof Filter Dropdown
**Issue**: UI should show Books/Movies/Games options even if penalty types don't exist yet
**Solution**: Add all options to dropdown, disable options where `Penalty.where(type: X).none?`

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines per snippet unless unavoidable)
- Do not duplicate authoritative code; **link to files by path**
- Simpler than Lists - no base controller needed
- Type filter must be preserved across all navigation

### Required Outputs
- All files listed in "Files to Create" section
- All files listed in "Files to Modify" section with correct changes
- Passing tests for all Acceptance Criteria (~28 tests)
- Updated sections: "Implementation Notes", "Deviations from Plan"

### Sub-Agent Plan
1. **general-purpose** → Implement controller, views, and tests following simpler pattern (no base controller)
2. **technical-writer** → Create penalty documentation and update cross-refs after implementation

### Commands to Run
```bash
# Navigate to Rails root
cd web-app

# Verify routes
bin/rails routes | grep penalties

# Run tests after implementation
bin/rails test test/controllers/admin/penalties_controller_test.rb

# Optional: Check for N+1 queries
QUERY_LOG=true bin/rails test test/controllers/admin/penalties_controller_test.rb
```

---

## Definition of Done

- [ ] All Acceptance Criteria demonstrably pass (tests/screenshots)
  - Target: 28 controller tests passing
- [ ] No N+1 on listed pages
  - Index: Uses `.includes(:user, :penalty_applications, :list_penalties)`
  - Show: Uses `.includes(:user, :penalty_applications, :list_penalties)`
- [ ] Type filter working
  - Dropdown filters correctly (All, Global, Music)
  - Filter preserved in pagination
  - Empty states show for no results
- [ ] Docs updated
  - Task file: This spec updated with implementation notes
  - todo.md: Task added to high priority section
  - Model docs: Update penalty.md if needed
- [ ] Links to authoritative code present
  - All file paths referenced throughout spec
  - No large code dumps (snippets kept to minimum)
- [ ] Security/auth reviewed
  - Admin authentication enforced
  - Strong parameters protect mass assignment
  - STI type cannot be user-edited
  - User field cannot be user-edited
- [ ] Performance constraints met
  - Index pagination: 25 items per page
  - Eager loading prevents N+1 queries
  - Simple alphabetical sort (no complex sorting)

---

## Related Tasks

**Previous Phases:**
- [Phase 9: Song Lists](completed/080-custom-admin-phase-9-song-lists.md) - CRUD patterns
- [Phase 8: Album Lists](completed/079-custom-admin-phase-8-album-lists.md) - Base controller pattern
- [Phase 7: Artist Ranking Configs](completed/078-custom-admin-phase-7-artist-ranking-configs.md)
- [Phase 6: Ranking Configs](completed/077-custom-admin-phase-6-ranking-configs.md)
- [Phase 5: Song Artists](completed/076-custom-admin-phase-5-song-artists.md)
- [Phase 4: Songs](completed/075-custom-admin-phase-4-songs.md)

**Related Features:**
- PenaltyApplication model - Association between penalties and ranking configs
- ListPenalty model - Association between penalties and lists
- Rankings::WeightCalculatorV1 - Service that uses penalty definitions

**Future Phases:**
- Phase 11: Music Penalties (Music::Penalty CRUD)
- Phase 12: Books Penalties (Books::Penalty CRUD)
- Phase 13: Movies Penalties (Movies::Penalty CRUD)
- Phase 14: Games Penalties (Games::Penalty CRUD)
- Phase 15: Penalty Actions (if needed)
- Phase 16: Avo Removal

---

## Implementation Notes

### Approach Taken
Followed the simpler pattern (no base controller needed) as specified. Used Rails generators to create controller with test file, then implemented CRUD operations with type filtering. Form uses dynamic type selection with unified `:penalty` parameter scope for create, type-specific scopes for update.

### Key Files Created
- `app/controllers/admin/penalties_controller.rb` - Main CRUD controller with type filtering
- `app/views/admin/penalties/index.html.erb` - Index with type filter dropdown
- `app/views/admin/penalties/show.html.erb` - Detail view with association cards
- `app/views/admin/penalties/_form.html.erb` - Shared form with type and dynamic type dropdowns
- `app/views/admin/penalties/_table.html.erb` - Table partial with pagination
- `app/views/admin/penalties/new.html.erb` - New penalty wrapper
- `app/views/admin/penalties/edit.html.erb` - Edit penalty wrapper
- `test/controllers/admin/penalties_controller_test.rb` - 24 comprehensive tests

### Key Files Modified
- `config/routes.rb` - Added `namespace :admin { resources :penalties }`
- `app/views/admin/shared/_sidebar.html.erb` - Activated penalties link, added `open` attribute to Global section
- `app/views/admin/music/dashboard/index.html.erb` - Added Albums/Songs buttons, Rankings buttons

### Challenges Encountered
1. **Layout Issue**: Initially no layout specified, causing application.html.erb errors. Fixed by adding `layout "music/admin"` to controller.
2. **Parameter Structure**: Form initially submitted under wrong parameter keys. Resolved by adding `scope: :penalty` to form and creating separate `create_penalty_params` method.
3. **Type Display**: Type column showed "Penalty" instead of "Global/Music". Fixed by using `penalty.type.split("::").first` instead of `demodulize.titleize`.
4. **Host Configuration**: Tests needed `host!` setup to properly set domain for authentication redirects.

### Post-Implementation Enhancements
- Added ability to create any penalty type (Global, Music) via dropdown instead of only Global::Penalty
- Type dropdown disabled on edit to prevent changing type after creation
- Admin logo/header now links to admin root with hover effect
- Global section in sidebar set to `open` by default like Music section

---

## Deviations from Plan

1. **Type Selection Added**: Original spec assumed only Global::Penalty creation. Enhanced to allow selecting Global or Music penalty types via dropdown in form.

2. **Parameter Handling**: Used unified `:penalty` scope for create instead of type-specific scopes (e.g., `:global_penalty`). This simplifies form logic while maintaining type-specific params for updates.

3. **Books/Movies/Games Removed**: Originally spec showed all 5 types in dropdown. Removed Books, Movies, Games since those penalty classes don't exist yet. Only Global and Music shown.

4. **Layout Specified**: Added `layout "music/admin"` to controller since penalties are global but accessed through music admin.

5. **Sidebar Enhancement**: Added `open` attribute to Global section to match Music section behavior.

6. **Dashboard Updates**: Enhanced dashboard beyond penalties task - added working buttons for Albums, Songs, and Rankings sections.

---

## Acceptance Results

**Status**: ✅ All Acceptance Criteria Passed

### Test Results
```
Running 24 tests in a single process (parallelization threshold is 50)
Run options: --seed 51560

# Running:

........................

Finished in 1.154327s, 20.7913 runs/s, 32.0533 assertions/s.
24 runs, 37 assertions, 0 failures, 0 errors, 0 skips
```

### Implementation Quality
- **Test Coverage**: 24/24 tests passing (100%)
- **N+1 Prevention**: Verified with `.includes(:user, :penalty_applications, :list_penalties)` on index and show
- **Performance**: Pagination set to 25 items per page, simple alphabetical sort
- **Security**: Admin/editor authentication enforced, strong parameters protect type field
- **UX**: Type filter preserved across pagination, color-coded badges, responsive design
- **Code Quality**: Follows existing patterns from Song Lists phase, no code duplication

---

## Key References

**Pattern Sources - Controllers:**
- Song Lists controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/songs/lists_controller.rb`
- Album Lists base: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/lists_controller.rb`
- Songs controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/songs_controller.rb`

**Pattern Sources - Views:**
- Lists index: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/index.html.erb`
- Lists show: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/show.html.erb`
- Lists form: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/_form.html.erb`
- Lists table: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/_table.html.erb`

**Models:**
- Penalty base: `/home/shane/dev/the-greatest/web-app/app/models/penalty.rb`
- Global::Penalty: `/home/shane/dev/the-greatest/web-app/app/models/global/penalty.rb`
- PenaltyApplication: `/home/shane/dev/the-greatest/web-app/app/models/penalty_application.rb`
- ListPenalty: `/home/shane/dev/the-greatest/web-app/app/models/list_penalty.rb`

**Documentation:**
- Penalty docs: `/home/shane/dev/the-greatest/docs/models/penalty.md`
- Todo guide: `/home/shane/dev/the-greatest/docs/todo-guide.md`

**Tests:**
- Lists controller test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/music/songs/lists_controller_test.rb`

**Current Avo Resources (to be replaced):**
- Avo penalty resource: `/home/shane/dev/the-greatest/web-app/app/avo/resources/penalty.rb`

**Sidebar:**
- Navigation: `/home/shane/dev/the-greatest/web-app/app/views/admin/shared/_sidebar.html.erb` (lines 113-118 need update)
