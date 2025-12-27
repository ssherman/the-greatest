# 085 - Custom Admin Interface - Phase 14: List Items

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-11-18
- **Started**:
- **Completed**:
- **Developer**: Claude Code (AI Agent)

## Overview
Implement generic admin interface for managing ListItem records (connecting Lists to their content items via polymorphic association). This is a cross-domain feature that works for all list types (Music::Albums::List, Music::Songs::List, Books::List, Movies::List, Games::List). Users can add and remove items from list show pages via a modal interface with autocomplete search. Unlike ranked_lists which is read-only, list_items supports full CRUD operations including position management and metadata editing.

## Context
- **Previous Phase Complete**: Ranked Lists (Phase 13) - CRUD for ranking configuration list associations implemented
- **Join Table**: ListItem connects List → polymorphic listable (Album, Song, Book, Movie, Game) with position and metadata
- **Generic Controller**: `Admin::ListItemsController` (NOT namespaced under music/books/etc.)
- **Cross-Domain**: Works for all list types across all media domains
- **Proven Pattern**: Phase 13 ranked_lists and Phase 12 penalty_applications join table with modals
- **Type-Specific Forms**: Modal content adapts based on list type (albums show album autocomplete, songs show song autocomplete, etc.)
- **Dual Mode**: Supports both verified items (with listable association) and unverified items (metadata only)
- **Current State**: List show pages display list_items inline with TODO comment for future lazy loading and CRUD operations

## Requirements

### Base List Item Management
- [ ] Generic controller: `Admin::ListItemsController` (not namespaced)
- [ ] Modal-based interface for add/edit/delete operations
- [ ] Context-aware: works from any list show page
- [ ] Type-specific autocomplete (albums list uses album search, songs list uses song search)
- [ ] Position input for manual ordering (integer > 0)
- [ ] Metadata input for unverified items (JSONB field, optional)
- [ ] Verified checkbox to mark items as manually verified
- [ ] Edit modal to update position, metadata, and verified status
- [ ] Validation preventing duplicate item assignments
- [ ] Media type compatibility (album lists can't have song items)
- [ ] No pagination (show all items - can add later if needed)
- [ ] Sorting: position ascending (1, 2, 3...)

### List Show Page Integration
- [ ] Existing "Albums/Songs" section on list show pages (needs enhancement)
- [ ] Lazy-loaded turbo frame for list items (currently inline - needs refactor)
- [ ] **Add "Add Album/Song" button** to existing card header
- [ ] Create modal: autocomplete with available items (filtered by type) + position + metadata + verified inputs
- [ ] Items table shows: position, title, artists (for music), year, verified status, edit action, delete action
- [ ] Edit button/icon opens edit modal with current values pre-filled
- [ ] Edit modal: item name (read-only), position input (editable), metadata input (editable), verified checkbox
- [ ] Delete confirmation for removing items
- [ ] Real-time updates via Turbo Streams
- [ ] Count badge showing number of list items

### Display Requirements
- [ ] DaisyUI card with title "Albums" or "Songs" (dynamic based on list type) and count badge
- [ ] Table columns: Position, Title, Artists (music only), Year (music only), Verified, Actions
- [ ] Position displayed as integer (e.g., "1", "2", "3")
- [ ] Verified badge with color coding (verified: success, unverified: warning)
- [ ] Empty state when no items
- [ ] Edit button/icon for each list item
- [ ] Delete button with confirmation
- [ ] Metadata display in edit modal (JSON editor or structured fields)

### Type-Specific Autocomplete
- [ ] **Albums List**: Use existing `/admin/albums/search` endpoint
- [ ] **Songs List**: Use existing `/admin/songs/search` endpoint (needs verification)
- [ ] **Books/Movies/Games Lists**: Future implementation (out of scope for this phase)
- [ ] Autocomplete shows: title + artists/authors + year
- [ ] Reuse existing `AutocompleteComponent` from album_artists pattern

## API Endpoints

| Verb | Path | Purpose | Params/Body | Auth | Context |
|------|------|---------|-------------|------|---------|
| GET | `/admin/list/:list_id/list_items` | List items for a list | - | admin/editor | lazy-loaded frame |
| POST | `/admin/list/:list_id/list_items` | Add item to list | `list_item[listable_id, listable_type, position, metadata, verified]` | admin/editor | create modal form |
| GET | `/admin/list_items/:id/edit` | Get edit form for list item | - | admin/editor | edit modal request |
| PATCH | `/admin/list_items/:id` | Update list item | `list_item[position, metadata, verified]` | admin/editor | edit modal form |
| DELETE | `/admin/list_items/:id` | Remove item from list | - | admin/editor | table row |

**Route Helpers**:
- `admin_list_list_items_path(@list)` → GET index (lazy load)
- `admin_list_list_items_path(@list)` → POST create
- `edit_admin_list_item_path(@list_item)` → GET edit (modal)
- `admin_list_item_path(@list_item)` → PATCH update
- `admin_list_item_path(@list_item)` → DELETE destroy

**Note**: Routes are generic and work for all list types (not namespaced under music/books/etc.)

## Response Formats

### Success Response - Create (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Item added successfully." } })
turbo_stream.replace("list_items_list", template: "admin/list_items/index",
  locals: { list: @list,
            list_items: @list.list_items.includes(:listable).order(:position) })
turbo_stream.replace("add_item_to_list_modal",
  Admin::AddItemToListModalComponent.new(list: @list))
```

### Success Response - Update (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Item updated successfully." } })
turbo_stream.replace("list_items_list", template: "admin/list_items/index",
  locals: { list: @list,
            list_items: @list.list_items.includes(:listable).order(:position) })
```

### Success Response - Destroy (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { notice: "Item removed successfully." } })
turbo_stream.replace("list_items_list", template: "admin/list_items/index",
  locals: { list: @list,
            list_items: @list.list_items.includes(:listable).order(:position) })
turbo_stream.replace("add_item_to_list_modal",
  Admin::AddItemToListModalComponent.new(list: @list))
```

### Error Response (Turbo Stream)
```ruby
turbo_stream.replace("flash", partial: "admin/shared/flash",
  locals: { flash: { error: "Item is already in this list" } })
```

### Turbo Frame IDs
- Main frame: `"list_items_list"`
- Add modal ID: `"add_item_to_list_modal"`
- Add dialog ID: `"add_item_to_list_modal_dialog"`
- Edit modal ID: `"edit_list_item_modal"`
- Edit dialog ID: `"edit_list_item_modal_dialog"`
- Modal forms target main frame on success

## Behavioral Rules

### Preconditions
- User must have admin or editor role
- List must exist
- Listable item must exist (for verified items)
- Listable type must match list type (Music::Album for Music::Albums::List, etc.)

### Postconditions (Add)
- New ListItem record created linking list and item with position/metadata/verified
- Turbo Stream updates list items without page reload
- Flash message confirms success
- Modal closes automatically
- Add modal reloads with updated available items (excluding newly added one)

### Postconditions (Edit)
- ListItem record updated with new position/metadata/verified values
- Turbo Stream updates list items without page reload
- Flash message confirms update
- Edit modal closes automatically

### Postconditions (Delete)
- ListItem record deleted
- Turbo Stream removes item from table
- Flash message confirms removal
- Add modal reloads with updated available items (including newly removed one)

### Invariants
- A list-item pair must be unique (database constraint + validation)
- Listable type must match list type (Music::Album for Music::Albums::List)
- Position must be > 0 if provided
- User must have appropriate authorization

### Edge Cases
- **Empty autocomplete**: No available items shows "All items already added or no items exist"
- **Duplicate add**: Shows validation error, doesn't create
- **Type mismatch**: Validation prevents Music::Song on Music::Albums::List
- **Position out of range**: Shows validation error (must be > 0)
- **Invalid metadata JSON**: Shows validation error
- **Authorization failure**: Redirects to appropriate domain root
- **Edit deleted record**: Shows 404 error
- **Unverified item without metadata**: Allowed (metadata is optional)

## Media Type Compatibility Rules

**From ListItem model validation and List STI structure**

- **Music::Albums::List**: Only works with `Music::Album` listable type
- **Music::Songs::List**: Only works with `Music::Song` listable type
- **Books::List**: Only works with `Books::Book` listable type (future)
- **Movies::List**: Only works with `Movies::Movie` listable type (future)
- **Games::List**: Only works with `Games::Game` listable type (future)

**Autocomplete endpoint mapping**:
```ruby
# Reference only - implementation in component
def autocomplete_url(list)
  case list.class.name
  when "Music::Albums::List"
    Rails.application.routes.url_helpers.search_admin_albums_path
  when "Music::Songs::List"
    Rails.application.routes.url_helpers.search_admin_songs_path
  when "Books::List"
    Rails.application.routes.url_helpers.search_admin_books_path # Future
  when "Movies::List"
    Rails.application.routes.url_helpers.search_admin_movies_path # Future
  when "Games::List"
    Rails.application.routes.url_helpers.search_admin_games_path # Future
  else
    nil
  end
end
```

**Expected listable type mapping**:
```ruby
# Reference only - implementation in controller/component
def expected_listable_type(list)
  case list.class.name
  when "Music::Albums::List"
    "Music::Album"
  when "Music::Songs::List"
    "Music::Song"
  when "Books::List"
    "Books::Book"
  when "Movies::List"
    "Movies::Movie"
  when "Games::List"
    "Games::Game"
  else
    nil
  end
end
```

## Non-Functional Requirements

### Performance
- **N+1 Prevention**: Eager load `list_items: :listable` in list show controllers
- **Lazy Loading**: Use turbo frame with lazy loading for list items (refactor from inline display)
- **No Pagination**: Show all items (lists typically have < 100 items, can add pagination later if needed)
- **Response Time**: < 500ms p95 for add/edit/delete

### Security
- **Authorization**: Enforce admin/editor role via BaseController
- **CSRF Protection**: Rails handles via form helpers
- **Parameter Filtering**: Strong params whitelist (listable_id, listable_type, position, metadata, verified)
- **SQL Injection**: ActiveRecord parameterization

### Accessibility
- **Keyboard Navigation**: Tab through form fields
- **Screen Readers**: Labels on all inputs
- **Modals**: Native `<dialog>` element
- **Delete Confirmation**: Clear confirmation messages
- **Position Input**: Number input with min attribute

### Responsiveness
- **Mobile**: DaisyUI responsive utilities
- **Tablet**: Card layout adapts
- **Desktop**: Full-width tables

## Acceptance Criteria

### Controller Tests (Required)
- [ ] GET index renders list items (2 tests: with/without items)
- [ ] POST create adds item (2 tests: success + turbo stream)
- [ ] POST create validates position range (1 test: position must be > 0)
- [ ] Prevent duplicate item addition (1 test)
- [ ] GET edit renders edit form (1 test)
- [ ] PATCH update updates position/metadata/verified successfully (2 tests: success + turbo stream)
- [ ] PATCH update validates position range (1 test: position must be > 0)
- [ ] DELETE destroy removes item (2 tests: success + turbo stream)
- [ ] Authorization enforcement (3 tests: create, update, destroy)
- [ ] Media type compatibility validation (2 tests: matching type works, mismatched type fails)
- [ ] Turbo stream replacements for create (3 tests: flash, list, add modal)
- [ ] Turbo stream replacements for update (2 tests: flash, list)
- [ ] Turbo stream replacements for destroy (3 tests: flash, list, add modal)
- [ ] Cross-list type support (2 tests: works for both album and song lists)

**Total Controller Tests**: ~27 tests

### Component Tests (Required)
- [ ] Add modal component renders with form (1 test)
- [ ] Add modal autocomplete_url returns correct endpoint for list type (2 tests: albums, songs)
- [ ] Add modal expected_listable_type returns correct type (2 tests: albums, songs)
- [ ] Add modal excludes already added items from autocomplete (1 test)
- [ ] Add modal includes position, metadata, verified inputs (1 test)
- [ ] Edit modal component renders with form (1 test)
- [ ] Edit modal shows item name as read-only (1 test)
- [ ] Edit modal pre-fills current position/metadata/verified values (1 test)
- [ ] Edit modal includes position, metadata, verified inputs with correct attributes (1 test)

**Total Component Tests**: ~11 tests

### Manual Acceptance Tests
- [ ] From album list show page: Click "Add Album", modal opens with album autocomplete
- [ ] Autocomplete shows albums with title + artists + year
- [ ] Select album, enter position 1, check verified, submit, album appears in table
- [ ] From album list show page: Click edit icon, modal opens with current values pre-filled
- [ ] Edit position to 2, add metadata JSON, submit, verify updates in table
- [ ] From album list show page: Delete item, verify disappears from table
- [ ] From song list show page: Click "Add Song", modal opens with song autocomplete
- [ ] Select song, enter position, submit, song appears in table
- [ ] From song list show page: Edit item, update position/metadata/verified, verify updates
- [ ] From song list show page: Delete item, verify disappears from table
- [ ] Verify autocomplete only shows items not already in list
- [ ] Verify duplicate prevention shows error message
- [ ] Verify position validation (must be > 0)
- [ ] Verify type mismatch validation (can't add song to album list)
- [ ] Verify modals close automatically after successful submission
- [ ] Verify add modal reloads after add/delete to show updated available items
- [ ] Verify edit modal shows item name as read-only
- [ ] Verify Turbo Stream updates work without page reload
- [ ] Verify lazy loading works (frame loads after page)
- [ ] Verify metadata can be entered as JSON
- [ ] Verify verified badge displays correctly (green for verified, yellow for unverified)

## Implementation Plan

### Step 1: Update Routes
**File**: `config/routes.rb`

**Add routes** (in admin namespace):
```ruby
namespace :admin do
  # Existing routes...

  # Generic list items routes (cross-domain)
  scope "list/:list_id", as: "list" do
    resources :list_items, only: [:index, :create]
  end

  resources :list_items, only: [:edit, :update, :destroy]
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/config/routes.rb:152-158`

### Step 2: Implement Controller
**File**: `app/controllers/admin/list_items_controller.rb`

**Actions to implement**:
- `index` action: Load list_items with listable, render without layout
- `create` action: Create new list_item with Turbo Stream response (3 replacements: flash, list, add modal)
- `edit` action: Render edit modal form (turbo stream or HTML)
- `update` action: Update list_item with Turbo Stream response (2 replacements: flash, list)
- `destroy` action: Delete list_item with Turbo Stream response (3 replacements: flash, list, add modal)
- Strong params (create): whitelist `listable_id, listable_type, position, metadata, verified`
- Strong params (update): whitelist `position, metadata, verified` (listable cannot be changed)
- Dynamic redirect path based on list STI type

**Pattern**: Generic controller that works across all domains
- Inherit from `Admin::BaseController` (NOT music-specific base)
- Similar to `Admin::PenaltyApplicationsController` and `Admin::RankedListsController`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/penalty_applications_controller.rb`

### Step 3: Create Index View Template
**File**: `app/views/admin/list_items/index.html.erb`

**Pattern**: Turbo frame wrapping table
- Wrap in `turbo_frame_tag "list_items_list"`
- Table with columns: Position, Title, Artists (music only), Year (music only), Verified, Actions
- Verified badge with color coding
- Edit button/icon opens edit modal via `data-turbo-frame="_top"` link to edit path
- Delete button with turbo_confirm
- Empty state when no items
- No layout (rendered in turbo frame)
- Use `local_assigns.fetch` pattern for both instance vars and locals
- Type-specific display (show artists/year for music, different fields for books/movies/games)
- **No pagination**: Show all items (typically < 100 items per list)

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/penalty_applications/index.html.erb`

### Step 4: Create Add Modal Component
**Files to create manually**:
- `app/components/admin/add_item_to_list_modal_component.rb`
- `app/components/admin/add_item_to_list_modal_component/add_item_to_list_modal_component.html.erb`
- `test/components/admin/add_item_to_list_modal_component_test.rb`

**Component implementation**:
```ruby
class Admin::AddItemToListModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def autocomplete_url
    case @list.class.name
    when "Music::Albums::List"
      Rails.application.routes.url_helpers.search_admin_albums_path
    when "Music::Songs::List"
      Rails.application.routes.url_helpers.search_admin_songs_path
    # Future: Books, Movies, Games
    else
      nil
    end
  end

  def expected_listable_type
    case @list.class.name
    when "Music::Albums::List"
      "Music::Album"
    when "Music::Songs::List"
      "Music::Song"
    # Future: Books, Movies, Games
    else
      nil
    end
  end

  def item_label
    case @list.class.name
    when "Music::Albums::List"
      "Album"
    when "Music::Songs::List"
      "Song"
    else
      "Item"
    end
  end
end
```

**Template implementation**:
- DaisyUI dialog modal with ID `add_item_to_list_modal_dialog`
- Form posts to `admin_list_list_items_path(@list)`
- Hidden field for `listable_type` (pre-filled based on list type)
- Autocomplete component for selecting item (using AutocompleteComponent)
- Position input: `<input type="number" min="1" required>`
- Metadata input: `<textarea>` for JSON (optional)
- Verified checkbox: `<input type="checkbox">`
- Stimulus controller: `modal-form` for auto-close behavior
- Turbo frame target: `list_items_list`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component.rb`

### Step 5: Create Edit Modal Component
**Files to create manually**:
- `app/components/admin/edit_list_item_modal_component.rb`
- `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb`
- `test/components/admin/edit_list_item_modal_component_test.rb`

**Component implementation**:
```ruby
class Admin::EditListItemModalComponent < ViewComponent::Base
  def initialize(list_item:)
    @list_item = list_item
    @list = list_item.list
  end

  def item_display_name
    if @list_item.listable.respond_to?(:title)
      @list_item.listable.title
    elsif @list_item.listable.respond_to?(:name)
      @list_item.listable.name
    else
      "#{@list_item.listable.class.name} ##{@list_item.listable.id}"
    end
  end
end
```

**Template implementation**:
- DaisyUI dialog modal with ID `edit_list_item_modal_dialog`
- Form patches to `admin_list_item_path(@list_item)`
- Item name shown as read-only text (not editable)
- Position input: `<input type="number" min="1" required>` pre-filled with current value
- Metadata input: `<textarea>` pre-filled with JSON.pretty_generate (optional)
- Verified checkbox: `<input type="checkbox">` pre-filled with current value
- Stimulus controller: `modal-form` for auto-close behavior
- Turbo frame target: `list_items_list`

**Reference**: `/home/shane/dev/the-greatest/web-app/app/components/admin/edit_penalty_application_modal_component.rb`

### Step 6: Update Album List Show Page
**File**: `app/views/admin/music/albums/lists/show.html.erb`

**Refactor existing section** (around lines 200-252):
```erb
<div class="card bg-base-100 shadow-xl">
  <div class="card-body">
    <div class="flex justify-between items-center mb-4">
      <h2 class="card-title">
        Albums
        <span class="badge badge-ghost"><%= @list.list_items.count %></span>
      </h2>
      <button class="btn btn-primary btn-sm" onclick="add_item_to_list_modal_dialog.showModal()">
        + Add Album
      </button>
    </div>
    <%= turbo_frame_tag "list_items_list", loading: :lazy,
        src: admin_list_list_items_path(@list) do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-lg"></span>
      </div>
    <% end %>
  </div>
</div>

<!-- Modal rendered at bottom of page (add after existing modals) -->
<%= render Admin::AddItemToListModalComponent.new(list: @list) %>
```

**Changes from existing**:
- Add button in header: `+ Add Album` (NEW)
- Refactor inline table to lazy-loaded turbo frame (REFACTOR)
- Add modal component at bottom (NEW)

**Reference**: `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/ranking_configurations/show.html.erb:287-299,492`

### Step 7: Update Song List Show Page
**File**: `app/views/admin/music/songs/lists/show.html.erb`

**Same pattern as Step 6** - refactor inline display to lazy-loaded frame with add button and modal

### Step 8: Update List Controllers for Eager Loading
**File**: `app/controllers/admin/music/lists_controller.rb`

**Update show action**:
```ruby
def show
  @list = list_class
    .includes(:submitted_by, list_penalties: :penalty,
              list_items: {listable: listable_includes}) # Update this line
    .find(params[:id])
end
```

**Already has**: `list_items: {listable: listable_includes}` eager loading
**No changes needed** - controller already optimized

**Reference**: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/lists_controller.rb:8-12`

### Step 9: Write Controller Tests
**File**: `test/controllers/admin/list_items_controller_test.rb`

**Test structure**:
```ruby
require "test_helper"

module Admin
  class ListItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_list = music_albums_lists(:approved_list)
      @song_list = music_songs_lists(:approved_list)
      @album = music_albums(:dark_side_moon)
      @song = music_songs(:bohemian_rhapsody)

      @album_list.list_items.destroy_all
      @song_list.list_items.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    # Index tests (with/without items)
    # Create tests (success, duplicate prevention, type validation, position validation, turbo streams)
    # Edit tests (renders form)
    # Update tests (success, position validation, turbo streams)
    # Destroy tests (success, turbo streams)
    # Cross-list type tests (works for both album and song lists)
  end
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/penalty_applications_controller_test.rb`

### Step 10: Write Component Tests
**File**: `test/components/admin/add_item_to_list_modal_component_test.rb`

**Test structure**:
```ruby
require "test_helper"

class Admin::AddItemToListModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @album_list = music_albums_lists(:approved_list)
    @song_list = music_songs_lists(:approved_list)
    @album = music_albums(:dark_side_moon)
    @song = music_songs(:bohemian_rhapsody)

    @album_list.list_items.destroy_all
    @song_list.list_items.destroy_all
  end

  # Test modal renders with form and autocomplete
  # Test autocomplete_url returns correct endpoint for list type
  # Test expected_listable_type returns correct type
  # Test item_label returns correct label
end
```

**Reference**: `/home/shane/dev/the-greatest/web-app/test/components/admin/add_penalty_to_configuration_modal_component_test.rb`

### Step 11: Manual Testing
**Prerequisites**:
- Lists exist (Music::Albums::List and Music::Songs::List)
- Albums and songs exist in database
- Admin user authenticated

**Test scenarios**:
1. Visit album list show page → See "Add Album" button
2. Click "Add Album" → Modal opens with album autocomplete
3. Type album name → Autocomplete shows matching albums
4. Select album, enter position 1, check verified → Submit → Album appears in table
5. Click edit icon → Modal opens with current values pre-filled
6. Change position to 2, add metadata JSON → Submit → Table updates
7. Click delete → Confirm → Album disappears from table
8. Repeat for song list
9. Try to add same item twice → See error message
10. Try to add song to album list (via API manipulation) → See error message
11. Verify lazy loading works
12. Verify Turbo Stream updates work without page reload

## Golden Examples

### Example 1: Adding Item to List (Happy Path)

**Action**: User visits album list show page, clicks "Add Album", searches for "Dark Side of the Moon", selects it, enters position 1, checks verified, submits

**Request**:
```
POST /admin/list/123/list_items
Params: {
  list_item: {
    listable_id: 456,
    listable_type: "Music::Album",
    position: 1,
    verified: true
  }
}
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Item added successfully." } })
turbo_stream.replace("list_items_list",
  template: "admin/list_items/index",
  locals: { list: @list,
            list_items: @list.list_items.includes(:listable).order(:position) })
turbo_stream.replace("add_item_to_list_modal",
  Admin::AddItemToListModalComponent.new(list: @list))
```

**Result**:
- ListItem record created linking list 123 and album 456 with position 1, verified true
- Flash shows "Item added successfully."
- Items table updates to show new item at position 1
- Modal closes automatically
- Add modal reloads to exclude newly added item from autocomplete
- No page reload

### Example 2: Type Mismatch Validation

**Action**: User tries to add Music::Song to Music::Albums::List (via API manipulation)

**Request**:
```
POST /admin/list/123/list_items
Params: {
  list_item: {
    listable_id: 789,
    listable_type: "Music::Song",
    position: 1
  }
}
```

**Validation fails**: `Listable type Music::Song is not compatible with list type Music::Albums::List`

**Response** (Turbo Stream, status 422):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { error: "Listable type Music::Song is not compatible with list type Music::Albums::List" } })
```

**Result**:
- No new record created
- Flash shows error message
- Modal stays open
- User can select compatible item

### Example 3: Editing List Item (Happy Path)

**Action**: User clicks edit icon for existing list item at position 1, changes position to 2, adds metadata JSON, submits

**Request**:
```
PATCH /admin/list_items/999
Params: {
  list_item: {
    position: 2,
    metadata: { "custom_field": "custom_value" },
    verified: true
  }
}
```

**Response** (Turbo Stream):
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: { flash: { notice: "Item updated successfully." } })
turbo_stream.replace("list_items_list",
  template: "admin/list_items/index",
  locals: { list: @list,
            list_items: @list.list_items.includes(:listable).order(:position) })
```

**Result**:
- ListItem record updated with position 2, metadata, verified true
- Flash shows "Item updated successfully."
- Items table updates to show item at new position 2
- Edit modal closes automatically
- No page reload

## Agent Hand-Off

### Constraints
- Follow existing penalty_applications and ranked_lists patterns - do not introduce new architecture
- Keep code snippets ≤40 lines in documentation
- Link to reference files by path
- Reuse existing AutocompleteComponent from album_artists pattern
- Type-specific modal content (albums vs songs autocomplete) handled via component logic

### Required Outputs
- `app/controllers/admin/list_items_controller.rb` (new)
- `test/controllers/admin/list_items_controller_test.rb` (new)
- `app/views/admin/list_items/index.html.erb` (new)
- `app/views/admin/list_items/edit.html.erb` (new - edit modal rendered via turbo)
- `app/components/admin/add_item_to_list_modal_component.rb` (new)
- `app/components/admin/add_item_to_list_modal_component/add_item_to_list_modal_component.html.erb` (new)
- `test/components/admin/add_item_to_list_modal_component_test.rb` (new)
- `app/components/admin/edit_list_item_modal_component.rb` (new)
- `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb` (new)
- `test/components/admin/edit_list_item_modal_component_test.rb` (new)
- `config/routes.rb` (update - add list_items routes)
- `app/views/admin/music/albums/lists/show.html.erb` (update - refactor inline table to lazy-loaded frame with add button and modal)
- `app/views/admin/music/songs/lists/show.html.erb` (update - refactor inline table to lazy-loaded frame with add button and modal)
- All tests passing (27+ controller tests, 11+ component tests)
- Updated sections in this spec: "Implementation Notes", "Deviations", "Acceptance Results"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Collect penalty_applications, ranked_lists, and autocomplete patterns ✅ (COMPLETED above)
2. **codebase-analyzer** → Verify ListItem model structure ✅ (COMPLETED above)
3. **codebase-locator** → Find list show pages and autocomplete implementation ✅ (COMPLETED above)
4. **general-purpose** → Implement controller, routes, views, components, tests following patterns
5. **technical-writer** → Update this spec with implementation notes, create class documentation

### Test Fixtures Required
Verify these fixtures exist and have proper data:
- `test/fixtures/music/albums/lists.yml` - Album lists for testing
- `test/fixtures/music/songs/lists.yml` - Song lists for testing
- `test/fixtures/music/albums.yml` - Albums for testing
- `test/fixtures/music/songs.yml` - Songs for testing
- `test/fixtures/list_items.yml` - Sample list-item associations
- `test/fixtures/users.yml` - admin_user, regular_user

## Key Files Touched

### New Files
- `app/controllers/admin/list_items_controller.rb`
- `test/controllers/admin/list_items_controller_test.rb`
- `app/views/admin/list_items/index.html.erb`
- `app/views/admin/list_items/edit.html.erb`
- `app/components/admin/add_item_to_list_modal_component.rb`
- `app/components/admin/add_item_to_list_modal_component/add_item_to_list_modal_component.html.erb`
- `test/components/admin/add_item_to_list_modal_component_test.rb`
- `app/components/admin/edit_list_item_modal_component.rb`
- `app/components/admin/edit_list_item_modal_component/edit_list_item_modal_component.html.erb`
- `test/components/admin/edit_list_item_modal_component_test.rb`

### Modified Files
- `config/routes.rb` (add list_items routes)
- `app/views/admin/music/albums/lists/show.html.erb` (refactor to lazy-loaded frame, add button, modal)
- `app/views/admin/music/songs/lists/show.html.erb` (refactor to lazy-loaded frame, add button, modal)

### Files NOT Modified (Verified)
- `app/controllers/admin/music/lists_controller.rb` (already has list_items eager loading)

### Reference Files (NOT modified, used as pattern)
- `app/controllers/admin/penalty_applications_controller.rb` - Modal pattern
- `app/controllers/admin/ranked_lists_controller.rb` - Generic cross-domain controller
- `app/views/admin/penalty_applications/index.html.erb` - Lazy-loaded turbo frame
- `app/views/admin/ranked_lists/index.html.erb` - Table with actions
- `app/components/admin/add_penalty_to_configuration_modal_component.rb` - Component pattern
- `app/components/admin/edit_penalty_application_modal_component.rb` - Edit modal pattern
- `app/components/autocomplete_component.rb` - Reusable autocomplete
- `app/javascript/controllers/autocomplete_controller.js` - Autocomplete Stimulus controller
- `app/javascript/controllers/modal_form_controller.js` - Auto-close logic
- `app/models/list_item.rb` - Model and validation reference
- `test/controllers/admin/penalty_applications_controller_test.rb` - Test patterns
- `test/components/admin/add_penalty_to_configuration_modal_component_test.rb` - Component test patterns

## Dependencies
- **Phase 13 Complete**: Ranked Lists CRUD provides proven pattern
- **Phase 12 Complete**: Penalty Applications CRUD provides proven pattern
- **Existing Models**: ListItem, List (with STI types), Music::Album, Music::Song
- **Existing Components**: AutocompleteComponent with Stimulus controller
- **Existing**: modal-form Stimulus controller for auto-close
- **Existing**: Turbo Streams for real-time updates
- **Existing**: Album and song autocomplete endpoints

## Success Metrics
- [ ] All 27+ controller tests passing
- [ ] All 11+ component tests passing
- [ ] Zero N+1 queries on list show pages
- [ ] Turbo Stream updates work without page reload
- [ ] Modal auto-close works after submission
- [ ] Modal reloads after add/delete to show updated available items
- [ ] Duplicate validation prevents database errors
- [ ] Type validation enforced (compatibility rules)
- [ ] Position validation enforced (> 0)
- [ ] Authorization prevents non-admin access
- [ ] Lazy loading improves initial page load time
- [ ] Works for album and song lists (books/movies/games in future)
- [ ] Generic controller reusable for future Books/Movies/Games lists
- [ ] Autocomplete correctly filtered based on list type
- [ ] Metadata can be entered and edited as JSON
- [ ] Verified badge displays correctly

## Implementation Notes

(To be filled during implementation)

## Deviations from Plan

(To be filled during implementation)

## Acceptance Results

(To be filled after implementation)

## Documentation Updated
- [ ] This spec file (implementation notes, deviations, results)
- [ ] Class documentation for ListItemsController (`docs/controllers/admin/list_items_controller.md`)
- [ ] Class documentation for Admin::AddItemToListModalComponent (`docs/components/admin/add_item_to_list_modal_component.md`)
- [ ] Class documentation for Admin::EditListItemModalComponent (`docs/components/admin/edit_list_item_modal_component.md`)

## Related Tasks
- **Prerequisite**: [Phase 13 - Ranked Lists](completed/084-custom-admin-phase-13-ranked-lists.md) ✅
- **Prerequisite**: [Phase 12 - Penalty Applications](completed/083-custom-admin-phase-12-penalty-applications.md) ✅
- **Reference**: [Phase 13 - Ranked Lists](completed/084-custom-admin-phase-13-ranked-lists.md) ✅ (modal and turbo stream patterns)
- **Reference**: [Phase 12 - Penalty Applications](completed/083-custom-admin-phase-12-penalty-applications.md) ✅ (edit modal pattern)
- **Next**: TBD - Phase 15 (possible next features: Books/Movies/Games list item support, bulk import enhancements)

## Key References

**Pattern Sources - Controllers:**
- Penalty Applications controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/penalty_applications_controller.rb`
- Ranked Lists controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/ranked_lists_controller.rb`
- Base admin controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/base_controller.rb`
- Music Lists controller: `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/lists_controller.rb`
- Albums controller (autocomplete): `/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/albums_controller.rb`

**Pattern Sources - Views:**
- Penalty applications index: `/home/shane/dev/the-greatest/web-app/app/views/admin/penalty_applications/index.html.erb`
- Ranked lists index: `/home/shane/dev/the-greatest/web-app/app/views/admin/ranked_lists/index.html.erb`
- Albums list show (current inline display): `/home/shane/dev/the-greatest/web-app/app/views/admin/music/albums/lists/show.html.erb`
- Songs list show (current inline display): `/home/shane/dev/the-greatest/web-app/app/views/admin/music/songs/lists/show.html.erb`

**Pattern Sources - Components:**
- Add penalty modal component: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component.rb`
- Add penalty modal template: `/home/shane/dev/the-greatest/web-app/app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb`
- Edit penalty modal component: `/home/shane/dev/the-greatest/web-app/app/components/admin/edit_penalty_application_modal_component.rb`
- Edit penalty modal template: `/home/shane/dev/the-greatest/web-app/app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb`
- Autocomplete component: `/home/shane/dev/the-greatest/web-app/app/components/autocomplete_component.rb`
- Autocomplete component template: `/home/shane/dev/the-greatest/web-app/app/components/autocomplete_component.html.erb`

**Models:**
- ListItem: `/home/shane/dev/the-greatest/web-app/app/models/list_item.rb`
- List: `/home/shane/dev/the-greatest/web-app/app/models/list.rb`
- Music::Albums::List: `/home/shane/dev/the-greatest/web-app/app/models/music/albums/list.rb`
- Music::Songs::List: `/home/shane/dev/the-greatest/web-app/app/models/music/songs/list.rb`
- Music::Album: `/home/shane/dev/the-greatest/web-app/app/models/music/album.rb`
- Music::Song: `/home/shane/dev/the-greatest/web-app/app/models/music/song.rb`

**Documentation:**
- ListItem docs: `/home/shane/dev/the-greatest/docs/models/list_item.md`
- List docs: `/home/shane/dev/the-greatest/docs/models/list.md`
- Todo guide: `/home/shane/dev/the-greatest/docs/todo-guide.md`
- Sub-agents: `/home/shane/dev/the-greatest/docs/sub-agents.md`

**JavaScript:**
- Autocomplete controller: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/autocomplete_controller.js`
- Modal form controller: `/home/shane/dev/the-greatest/web-app/app/javascript/controllers/modal_form_controller.js`

**Tests:**
- Penalty Applications controller test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/penalty_applications_controller_test.rb`
- Ranked Lists controller test: `/home/shane/dev/the-greatest/web-app/test/controllers/admin/ranked_lists_controller_test.rb`
- Add penalty modal component test: `/home/shane/dev/the-greatest/web-app/test/components/admin/add_penalty_to_configuration_modal_component_test.rb`
- Edit penalty modal component test: `/home/shane/dev/the-greatest/web-app/test/components/admin/edit_penalty_application_modal_component_test.rb`
- ListItem model test: `/home/shane/dev/the-greatest/web-app/test/models/list_item_test.rb`
