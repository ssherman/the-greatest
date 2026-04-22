# User Lists Feature - Complete Technical Documentation

**Purpose**: This document describes the complete implementation of the User Lists feature on TheGreatestBooks.org. It is intended as a reference for an AI agent rebuilding this feature in a new codebase.

**Last Updated**: 2026-04-11

---

## Table of Contents

1. [Feature Overview](#feature-overview)
2. [Data Model](#data-model)
3. [Database Schema](#database-schema)
4. [Routes](#routes)
5. [Controllers](#controllers)
6. [Authorization (Pundit Policies)](#authorization-pundit-policies)
7. [ViewComponents](#viewcomponents)
8. [Views and Templates](#views-and-templates)
9. [Turbo Streams and Turbo Frames](#turbo-streams-and-turbo-frames)
10. [Stimulus Controllers (JavaScript)](#stimulus-controllers-javascript)
11. [Global Bootstrapping Pattern](#global-bootstrapping-pattern)
12. [Caching Strategy](#caching-strategy)
13. [Background Jobs](#background-jobs)
14. [Service Integrations](#service-integrations)
15. [Community Ranked List Algorithm](#community-ranked-list-algorithm)
16. [Import/Export](#importexport)
17. [End-to-End Flows](#end-to-end-flows)
18. [File Reference](#file-reference)

---

## Feature Overview

The User Lists feature allows authenticated users to organize books into personal lists. There are **four system-defined list types** created automatically on signup, plus unlimited user-created **custom lists**.

### List Types

| Type | Name | Purpose |
|------|------|---------|
| `read` | "Books I've Read" | Tracks completed books with optional `read_date` |
| `reading` | "Books I'm Reading" | Currently reading |
| `want_to_read` | "Books I Want to Read" | Wishlist / to-be-read |
| `favorite` | "My Favorite Books" | User's all-time favorites; **feeds the community ranking algorithm** |
| `custom` | (User-defined) | Any custom list the user creates |

### Key Capabilities

- Add/remove books from any list via a dropdown on every book listing page
- Drag-and-drop reordering of books within a list (SortableJS)
- Server-side reordering via move up/down/top/bottom buttons
- Three view modes: Default (list), Table, Grid
- Sort by position or by global ranking
- CSV export of any list
- JSON export/import (data migration)
- Goodreads CSV import (maps shelves to list types)
- Public/private list visibility
- Reading statistics (percentage of top N books read)
- Automatic reading-to-read transition (moving book from "reading" to "read" list)
- Reading goals sync (books with `read_date` are linked to date-ranged goals)
- Community ranking: all users' favorite lists are aggregated into a site-wide "Top 100" list

---

## Data Model

### UserList

**File**: `admin/app/models/user_list.rb`

```ruby
class UserList < ApplicationRecord
  belongs_to :user
  has_many :user_list_books, -> { order(position: :asc) }, dependent: :destroy
  has_many :books, through: :user_list_books

  enum :list_type, [:read, :reading, :want_to_read, :favorite, :custom]
  enum :view_mode, { default_view: nil, table_view: 1, grid_view: 2 }

  validates_presence_of :name
end
```

**Key Attributes**:
- `list_type` (integer enum): Determines the list's role and behavior
- `view_mode` (integer enum): Persisted display preference per list (default/table/grid)
- `public` (boolean, default: false): When true, other users can view the list
- `best_ranked` (boolean): Legacy flag for ranked lists
- `greatest_books_list` (boolean): Flags lists that feed the community ranking
- `date_read` (date): List-level date field (largely unused in current code)
- `position` (integer): Ordering among a user's lists (not auto-managed)
- `name` (string, required): Display name
- `description` (text): Optional description

**Key Methods**:

| Method | Description |
|--------|-------------|
| `reorder_books(new_order)` | Accepts an array of book IDs, updates positions in a transaction |
| `fix_positions` | Re-sequences all book positions sequentially starting from 1 |
| `export_to_json` | Serializes the list and all books to a JSON file |
| `UserList.import_from_json(user_id, filename)` | Deserializes a JSON file into a new list for the given user |
| `UserList.populate_list_type` | Backfills `list_type` from list names (data migration) |
| `UserList.fix_positions(background_job:)` | Fixes positions for ALL lists, optionally via background jobs |

**Callbacks**:
- `after_destroy_commit -> { broadcast_remove }` - Fires a Turbo Stream broadcast on destruction

### UserListBook

**File**: `admin/app/models/user_list_book.rb`

```ruby
class UserListBook < ApplicationRecord
  belongs_to :user_list, touch: true
  belongs_to :book
  has_one :user, through: :user_list, touch: true

  default_scope { order(position: :asc) }
end
```

**Key Attributes**:
- `position` (integer): Ordinal rank within the list (1-based)
- `read_date` (date): When the user finished the book (relevant for `read` lists)
- Unique index on `(user_list_id, book_id)` prevents duplicates

**Custom Setter**:
```ruby
# Parses M-DD-YYYY format from frontend date pickers
def read_date=(value)
  if value.is_a?(String) && value.match?(/\A\d{1,2}-\d{2}-\d{4}\z/)
    super(Date.strptime(value, "%m-%d-%Y"))
  else
    super
  end
end
```

**Callback Chain** (in execution order):

| Callback | When | What It Does |
|----------|------|-------------|
| `before_create :handle_reading_to_read_transition` | Adding to `read` list | Auto-removes book from `reading` list; sets `read_date = Date.current` if not provided |
| `before_create :set_position` | Creating | Sets `position = max_existing + 1` (appends to end) |
| `before_save :invalidate_user_cache` | Any save | Calls `user.touch` to bust all cache keys |
| `before_destroy :invalidate_user_cache` | Destroying | Same cache invalidation |
| `after_create :generate_ranked_list_if_required` | Creating | If parent list is `favorite`, enqueues `GenerateRankedUsersListJob` |
| `after_destroy :generate_ranked_list_if_required` | Destroying | Same ranked list regeneration |
| `after_update :generate_ranked_list_if_position_changed` | Updating | If `position` changed AND parent is `favorite`, regenerates ranked list |
| `after_destroy_commit :shift_positions_up` | After destroy committed | Decrements position of all books with higher position |

**Position Manipulation Methods**:

| Method | Behavior |
|--------|----------|
| `move_up` | Swaps position with the previous book |
| `move_down` | Swaps position with the next book |
| `move_top` | Sets position to 1, increments all others |
| `move_bottom` | Sets position to count, decrements all higher |

### User Model Integration

**File**: `admin/app/models/user.rb`

**Associations**:
```ruby
has_many :user_lists, dependent: :destroy
has_many :user_list_books, through: :user_lists
has_many :books, through: :user_lists
```

**List Lifecycle**:
- `after_create :create_default_user_lists` creates all 4 default list types on signup
- `ensure_list_type_exists(list_type)` is idempotent -- finds existing or creates new
- `User.fix_default_user_lists` runs `create_default_user_lists` for all users (data repair)
- `merge_user_lists_to_user(target_user)` handles account merging by reassigning books

**Caching Methods** (see [Caching Strategy](#caching-strategy) for details):
- `cached_user_lists` - Array of UserList objects
- `cached_user_lists_with_books` - Array of hashes with `{id, name, list_type, book_ids}`
- `cached_user_list_books_by_book` - Hash keyed by `book_id` for O(1) lookups

**Reading Statistics**:
- `book_read_stats(top_1000_book_ids_param)` calculates what percentage of the top 100/250/500/1000 ranked books the user has read

**Recommendation Data**:
- Methods like `favorite_genres`, `read_subjects`, etc. extract category data from user lists
- `no_books_for_recommendations?` checks if both `favorite` and `read` lists are empty
- `recommended_books(algorithm:)` delegates to the recommendations engine

### Book Model Integration

**File**: `admin/app/models/book.rb`

```ruby
has_many :user_list_books, dependent: :destroy
has_many :user_lists, through: :user_list_books
```

The `merge_with(target_book)` method reassigns `user_list_books` to the target, skipping any where the target already has an entry for that `user_list_id` (prevents unique constraint violation).

---

## Database Schema

### user_lists

```sql
CREATE TABLE user_lists (
  id           bigint PRIMARY KEY,
  user_id      bigint NOT NULL REFERENCES users(id),
  name         varchar NOT NULL,
  description  text,
  list_type    integer,          -- enum: 0=read, 1=reading, 2=want_to_read, 3=favorite, 4=custom
  view_mode    integer,          -- enum: NULL=default, 1=table, 2=grid
  position     integer,
  public       boolean DEFAULT false,
  best_ranked  boolean DEFAULT false,
  greatest_books_list boolean DEFAULT false NOT NULL,
  date_read    date,
  created_at   datetime NOT NULL,
  updated_at   datetime NOT NULL
);

-- Indexes
CREATE INDEX index_user_lists_on_user_id   ON user_lists (user_id);
CREATE INDEX index_user_lists_on_list_type ON user_lists (list_type);
CREATE INDEX index_user_lists_on_date_read ON user_lists (date_read);
```

### user_list_books

```sql
CREATE TABLE user_list_books (
  id           bigint PRIMARY KEY,
  user_list_id bigint NOT NULL REFERENCES user_lists(id),
  book_id      bigint NOT NULL REFERENCES books(id),
  position     integer,
  read_date    date,
  created_at   datetime NOT NULL,
  updated_at   datetime NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX index_user_list_books_on_user_list_id_and_book_id ON user_list_books (user_list_id, book_id);
CREATE INDEX index_user_list_books_on_book_id                         ON user_list_books (book_id);
CREATE INDEX index_user_list_books_on_user_list_id_and_position       ON user_list_books (user_list_id, position);
CREATE INDEX index_user_list_books_on_read_date                       ON user_list_books (read_date);
```

---

## Routes

**File**: `admin/config/routes.rb` (lines 23, 286-302)

```ruby
# Bulk book-status loading (used on every page)
post "user_book_actions/index"

# User Lists CRUD + nested User List Books
resources :user_lists do
  collection do
    get :account_required
    get :show_survey
  end
  member do
    post :reorder
  end
  resources :user_list_books, only: [:create, :destroy, :show, :update, :edit] do
    member do
      post :move_up
      post :move_down
      post :move_top
      post :move_bottom
    end
  end
end

# Goodreads import (separate controller)
resources :goodreads_imports, only: [:index] do
  collection do
    post :upload
  end
end
```

### Route Summary

| Method | Path | Controller#Action | Purpose |
|--------|------|-------------------|---------|
| GET | `/user_lists` | `user_lists#index` | List all user's lists |
| GET | `/user_lists/account_required` | `user_lists#account_required` | Auth prompt for unauthenticated users |
| GET | `/user_lists/show_survey` | `user_lists#show_survey` | Onboarding survey (add favorites) |
| POST | `/user_lists` | `user_lists#create` | Create a new custom list |
| GET | `/user_lists/:id` | `user_lists#show` | View a list's books |
| GET | `/user_lists/:id/edit` | `user_lists#edit` | Edit page with drag-and-drop |
| PATCH | `/user_lists/:id` | `user_lists#update` | Update list metadata + reorder + delete books |
| DELETE | `/user_lists/:id` | `user_lists#destroy` | Delete a list |
| POST | `/user_lists/:id/reorder` | `user_lists#reorder` | Standalone reorder endpoint |
| POST | `/user_lists/:ul_id/user_list_books` | `user_list_books#create` | Add a book to a list |
| DELETE | `/user_lists/:ul_id/user_list_books/:id` | `user_list_books#destroy` | Remove a book from a list |
| GET | `/user_lists/:ul_id/user_list_books/:id/edit` | `user_list_books#edit` | Edit read_date form (lazy turbo frame) |
| PATCH | `/user_lists/:ul_id/user_list_books/:id` | `user_list_books#update` | Update read_date |
| POST | `/user_lists/:ul_id/user_list_books/:id/move_up` | `user_list_books#move_up` | Move book up one position |
| POST | `/user_lists/:ul_id/user_list_books/:id/move_down` | `user_list_books#move_down` | Move book down one position |
| POST | `/user_lists/:ul_id/user_list_books/:id/move_top` | `user_list_books#move_top` | Move book to position 1 |
| POST | `/user_lists/:ul_id/user_list_books/:id/move_bottom` | `user_list_books#move_bottom` | Move book to last position |
| POST | `/user_book_actions/index` | `user_book_actions#index` | Bulk load list-status for all books on page |

---

## Controllers

### UserListsController

**File**: `admin/app/controllers/user_lists_controller.rb`

**Important**: Uses `skip_forgery_protection` (CSRF disabled).

| Action | Behavior |
|--------|----------|
| `index` | If authenticated: loads all user lists, reading stats, latest Goodreads import. If not: renders `account_required` with `@reload_after_auth = true` |
| `show` | Loads list books with `includes(book: [:authors, :countries])`. Supports sort by `position` or `ranking`. Supports three view modes. Persists view_mode to DB when owner changes it. Paginates via Kaminari (100/page). Supports CSV export |
| `edit` | Loads list for drag-and-drop editing. Uses Pundit authorization |
| `update` | In a transaction: updates metadata (name/description/public), processes `new_order` (comma-separated book IDs for reorder), processes `deleted_books` (comma-separated book IDs to remove) |
| `create` | Builds a custom list. Optionally adds a single `book_id`. Responds with turbo_stream rendering `user_book_actions/index` template (refreshes all book dropdowns on the page) |
| `destroy` | Pundit-authorized deletion, redirects to index |
| `reorder` | Standalone POST endpoint accepting `params[:new_order]` array |
| `show_survey` | Loads/creates the user's favorite list for onboarding |
| `goodreads_import` | Synchronous Goodreads CSV import via `GoodreadsLibraryParser` |

**CSV Export** generates columns: Book Title, Authors, Published Date, Country, Original Language, Page Range, Word Count. Prepends UTF-8 BOM for Excel compatibility.

### UserListBooksController

**File**: `admin/app/controllers/user_list_books_controller.rb`

**Security boundary**: All actions scope through `current_user.user_lists.find(params[:user_list_id])` -- users can only manage their own lists.

| Action | Behavior |
|--------|----------|
| `create` | Checks for duplicates via `user_list.books.where(id:).exists?`. Saves. Calls `ReadingGoalsSync` if `read` list with `read_date`. Reloads cached data. Responds with turbo_stream |
| `destroy` | Calls `ReadingGoalsSync` with `operation: :remove` for `read` lists. Destroys record. Reloads cache. Responds with turbo_stream |
| `update` | Only permits `read_date`. Calls `ReadingGoalsSync`. Responds with turbo_stream replacing the book's list item |
| `edit` | Renders read_date form inside a lazy turbo frame |
| `move_up/down/top/bottom` | Delegates to model methods. Responds with turbo_stream replacing the `user-list-books-list-{id}` frame |

### UserBookActionsController

**File**: `admin/app/controllers/user_book_actions_controller.rb`

Handles `POST /user_book_actions/index`. This is the **bulk state loader** -- called on every page load to inject per-user list status for all books visible on the page.

```ruby
def index
  book_ids = params[:book_ids].split(",")
  @books = Book.find(book_ids)
  if signed_in?
    @user_lists = current_user.cached_user_lists_with_books
    @read_book_ids = find_read_book_ids
  else
    @user_lists = []
    @read_book_ids = []
  end
end
```

---

## Authorization (Pundit Policies)

### UserListPolicy

**File**: `admin/app/policies/user_list_policy.rb`

| Action | Rule |
|--------|------|
| `show?` | Admin OR public list OR list owner |
| `edit?` / `update?` / `destroy?` / `reorder?` | Admin OR list owner |
| `create?` / `index?` / `survey?` | Any authenticated user |
| **Scope** | Own lists + public lists (admins see all) |

### UserListBookPolicy

**File**: `admin/app/policies/user_list_book_policy.rb`

| Action | Rule |
|--------|------|
| All (`create?`, `move_*?`, `destroy?`) | `record.user == user` (via `has_one :user, through: :user_list`) |

---

## ViewComponents

### UserListsComponent

**Files**: `admin/app/components/user_lists_component.rb`, `admin/app/components/user_lists_component/user_lists_component.html.erb`

Top-level wrapper that renders either an **icon-style** or **button-style** "Add to a List" dropdown.

```ruby
def initialize(user:, book:, user_lists: nil, display_type: :button)
```

- `:button` display -- renders a full `btn btn-outline-primary btn-sm dropdown-toggle` button with "Add to a List" text. Used in book detail pages and default list view.
- `:icon` display -- renders a compact `bi-plus-circle-fill` icon button. Used in table and grid view modes.

Delegates to `UserListDropdownComponent` for the dropdown menu.

### UserListDropdownComponent

**Files**: `admin/app/components/user_list_dropdown_component.rb`, `admin/app/components/user_list_dropdown_component/user_list_dropdown_component.html.erb`

Renders the `<ul class="dropdown-menu">` with all user lists. Structure:

1. Default lists (read, want_to_read, reading, favorite) -- each rendered as a `UserListBookManageLinkComponent`
2. Divider
3. Custom lists -- each rendered as a `UserListBookManageLinkComponent`
4. Divider
5. "Create a New List" link (opens modal)
6. Divider
7. "Manage Lists" link (navigates to `/user_lists`)

For **unauthenticated users**: shows three static list names that trigger the auth modal (`#authModal`).

The entire dropdown is wrapped in `<turbo-frame id="user-lists-index">` so creating a new list refreshes the dropdown in place.

### UserListBookManageLinkComponent

**Files**: `admin/app/components/user_list_book_manage_link_component.rb`, `admin/app/components/user_list_book_manage_link_component/user_list_book_manage_link_component.html.erb`

The **atomic unit** of the dropdown -- one per list per book. Wrapped in its own turbo frame:

```
<turbo-frame id="user_list_book_{list_id}_{book_id}">
```

**State lookup** uses `user.cached_user_list_books_by_book[book.id]` for O(1) lookups (no DB query per render).

**Two states**:
- **Book IS in list**: renders a DELETE form with a checkmark icon (`fa-solid fa-check`) + list name in muted text
- **Book is NOT in list**: renders a POST form with the list name as a link

Both forms use `data-controller="user-list-books"` with a `submit` target. The Stimulus controller intercepts link clicks to call `requestSubmit()` on the parent form.

### UserListBookActionsComponent

**Files**: `admin/app/components/user_list_book_actions_component.rb`, `admin/app/components/user_list_book_actions_component/user_list_book_actions_component.html.erb`

Renders an ordered list of books in a list with **server-side reorder buttons** (move up/down/top/bottom) and a delete button. Used in the survey page and the sidebar view.

Each button is a `button_to` form POSTing to the corresponding move route. The `user-list-items-manager` Stimulus controller disables all action buttons after any click to prevent double-submission.

Each list item also has `turbo_stream_from user_list_book` for real-time updates via ActionCable.

### AddBookToUserListComponent

**Files**: `admin/app/components/add_book_to_user_list_component.rb`, `admin/app/components/add_book_to_user_list_component/add_book_to_user_list_component.html.erb`

Renders the "Add Book to List" modal on the list show page. Features:

1. **Autocomplete search**: Uses `@tarekraafat/autocomplete.js` to search existing books via `/autocomplete`
2. **Manual add form** (hidden by default): Two options:
   - Add from URL (Goodreads URL or Amazon URL)
   - Add manually (title + authors)
3. On book selection or manual submit, does a `fetch` POST to create the book (if needed) then add it to the list, then `window.location.reload()`

---

## Views and Templates

### User Lists Views

| File | Purpose |
|------|---------|
| `admin/app/views/user_lists/index.html.erb` | Dashboard: list of all user's lists + reading stats widget + Goodreads import widget. Renders the create-list modal |
| `admin/app/views/user_lists/show.html.erb` | List detail: sort controls (position/ranking), view mode dropdown (default/table/grid), pagination, edit/download/delete buttons. Renders `BookListComponent` and `AddBookToUserListComponent` |
| `admin/app/views/user_lists/edit.html.erb` | Drag-and-drop edit page. Uses `user-list-sort` Stimulus controller with SortableJS. Includes read-date modals for `read` lists (lazy-loaded turbo frames) |
| `admin/app/views/user_lists/_book_list_item.html.erb` | Individual book row in the edit form. Features: position badge, book title/authors, read date display, dropdown (Move to Top/Bottom), calendar button (read lists), remove button, drag handle |
| `admin/app/views/user_lists/account_required.html.erb` | Login prompt for unauthenticated users |
| `admin/app/views/user_lists/show_survey.html.erb` | Onboarding survey: autocomplete search + `UserListBookActionsComponent` for the favorites list |

### User List Books Views

| File | Purpose |
|------|---------|
| `admin/app/views/user_list_books/create.turbo_stream.erb` | After adding a book: replaces dropdown entry frame + books container + action container |
| `admin/app/views/user_list_books/destroy.turbo_stream.erb` | After removing: same pattern as create |
| `admin/app/views/user_list_books/move_*.turbo_stream.erb` | After position change: replaces entire `user-list-books-list-{id}` frame |
| `admin/app/views/user_list_books/edit.html.erb` | Read-date form inside a lazy turbo frame |
| `admin/app/views/user_list_books/_modal.html.erb` | "Create a New List" modal (embedded on all listing pages) |

### User Book Actions Views

| File | Purpose |
|------|---------|
| `admin/app/views/user_book_actions/index.turbo_stream.erb` | Bulk update: for each book, updates both `user-book-actions-container-{id}` and `user-lists-actions-container-{id}` |

---

## Turbo Streams and Turbo Frames

### Named Turbo Frames

| Frame ID | Location | Purpose |
|----------|----------|---------|
| `user-lists-index` | `UserListDropdownComponent` | Wraps all dropdown list items. Targeted when creating a new list to refresh the dropdown |
| `user_list_book_{list_id}_{book_id}` | `UserListBookManageLinkComponent` | Per-list-per-book frame. Replaced after add/remove to toggle checkmark state |
| `edit_read_date_{book_id}` | Edit page modals | Lazy-loaded read-date form (only fetches when modal opens) |
| `books_container_turbo` | Survey page | Wraps the `UserListBookActionsComponent` |

### Named DOM Targets (not frames, but turbo stream targets)

| Target ID | Purpose |
|-----------|---------|
| `user-book-actions-container-{book_id}` | Full action panel for a book (add-to-list button + review button + read badge). Updated on page load and after add/remove |
| `user-lists-actions-container-{book_id}` | Compact icon-style action container (used in table/grid views) |
| `books-container` | Survey page scrollable container |
| `user-list-books-list-{user_list_id}` | Server-side reorder list (replaced after move operations) |

### Turbo Stream Response Patterns

**After adding a book** (`create.turbo_stream.erb`):
1. `replace` the `user_list_book_{list_id}_{book_id}` frame (toggles to checkmark)
2. `replace` the `books-container` (refreshes survey list)
3. `update` the `user-book-actions-container-{book_id}` (refreshes the full action panel including `UserListsComponent`, `ReviewButtonComponent`, and read badge)

**After removing a book** (`destroy.turbo_stream.erb`):
Same pattern as create, plus `remove` the destroyed `user_list_book` element.

**After position change** (`move_*.turbo_stream.erb`):
`replace` the entire `user-list-books-list-{user_list_id}` by re-rendering `UserListBookActionsComponent`.

**Bulk page load** (`user_book_actions/index.turbo_stream.erb`):
For each book on the page: `update` both `user-book-actions-container-{id}` (with button-style component) and `user-lists-actions-container-{id}` (with icon-style component).

---

## Stimulus Controllers (JavaScript)

### user_list_books_controller.js

**File**: `admin/app/javascript/controllers/user_list_books_controller.js`
**Data attribute**: `data-controller="user-list-books"`

Handles add/remove clicks in the dropdown. When the `submit` target connects, adds a click listener that calls `e.target.parentNode.requestSubmit()` to programmatically submit the form. Shows Notiflix toasts on `turbo:submit-end`:
- `submitEndCreate` -- "Book successfully added to the list"
- `submitEndDestroy` -- "Book successfully removed from the list"

### user_list_sort_controller.js

**File**: `admin/app/javascript/controllers/user_list_sort_controller.js`
**Data attribute**: `data-controller="user-list-sort"`

Powers the drag-and-drop edit page using SortableJS.

**Targets**: `saveButton`, `form`, `bookList`, `deletedBooks`, `saveButtonText`, `saveButtonSpinner`
**Values**: `userListId` (String)

**Behaviors**:
- On connect: initializes `Sortable.create` on `bookListTarget` with 150ms animation and `sortable-ghost` CSS class
- `updateOrder()`: compares current DOM order vs `originalOrder`, enables/disables save button
- `updateNumbers()`: walks DOM and updates `.badge.bg-primary` rank badges live
- `removeBook(event)`: removes element from DOM, tracks in `deletedBooks` Set, syncs to hidden field
- `handleSubmit(event)`: intercepts form submit, does raw `fetch()` POST with `new_order` and `deleted_books`, redirects on success
- `moveToTop(event)` / `moveToBottom(event)`: DOM-level prepend/append for keyboard-accessible repositioning
- `handleBeforeUnload`: warns user about unsaved changes

### create_user_list_form_controller.js

**File**: `admin/app/javascript/controllers/create_user_list_form_controller.js`
**Data attribute**: `data-controller="create-user-list-form"`

Controls the "Create a New List" modal. On submit, populates hidden fields:
- `bookIdsInputTarget` from `window.currentPageBookIds` (all book IDs visible on page)
- `bookIdInputTarget` from `window.selectedBookId` (set when user clicks a `.new-custom-user-list-button`)

### user_list_items_manager_controller.js

**File**: `admin/app/javascript/controllers/user_list_items_manager_controller.js`
**Data attribute**: `data-controller="user-list-items-manager"`

Applied to `UserListBookActionsComponent`. On connect: initializes Bootstrap tooltips and adds click handlers that disable all `.user-list-book-action-form` buttons after any click (prevents double-submissions of move/delete actions).

### user_list_books_update_form_controller.js

**File**: `admin/app/javascript/controllers/user_list_books_update_form_controller.js`
**Data attribute**: `data-controller="user-list-books-update-form"`

Controls the read-date modal form. On `turbo:submit-end`: closes the Bootstrap modal and shows Notiflix success/failure notification.

### add_book_controller.js

**File**: `admin/app/javascript/controllers/add_book_controller.js`
**Data attribute**: `data-controller="add-book"`

Controls the "Add Book to List" modal on the list show page.

**Targets**: `urlInput`, `titleInput`, `authorsInput`, `submitButton`, `manualSection`, `urlSection`
**Values**: `userListId` (Number)

**Behaviors**:
- Initializes `@tarekraafat/autocomplete.js` on `#bookSearchAutocomplete`
- On book selection from autocomplete: `addBookToList(bookId)` does a `fetch` POST then `window.location.reload()`
- Manual form: creates book via POST `/books` (returns JSON), then chains to `addBookToList`
- `validateForm()`: mutually exclusive URL vs manual sections, enables submit when valid

---

## Global Bootstrapping Pattern

This is the most architecturally significant pattern. Since per-user list state cannot be cached at the page level, it is injected asynchronously on every page load.

### Flow

1. **Layout embeds a hidden form** (`admin/app/views/layouts/application.html.erb`, line 59-63):
```erb
<turbo-frame>
  <%= bootstrap_form_tag url: "/user_book_actions/index",
                         id: 'user-book-actions-form',
                         data: { turbo_method: "post" },
                         method: :post do |f| %>
    <%= f.hidden_field :book_ids %>
  <% end %>
</turbo-frame>
```

2. **On DOMContentLoaded**, `application.js` calls `initUserBookLists()` from `user_lists.js`

3. **`initUserBookLists()`** (`admin/app/javascript/user_lists.js`):
   - Scans all `.book-list-item` elements and collects their `data-book` attribute values
   - Stores them in `window.currentPageBookIds`
   - Sets `#book_ids` hidden field value to comma-joined IDs
   - Calls `requestSubmit()` on `#user-book-actions-form`

4. **`UserBookActionsController#index`** receives the POST, loads the books, fetches `cached_user_lists_with_books`

5. **`user_book_actions/index.turbo_stream.erb`** emits Turbo Stream `update` actions for each book, filling:
   - `user-book-actions-container-{book.id}` with button-style `UserListsComponent`
   - `user-lists-actions-container-{book.id}` with icon-style `UserListsComponent`

6. **Empty containers in book rows** (`BookListItemComponent`) are now populated with the user's list state

### Why This Pattern Exists

Book listing pages are often cached or served identically to all users. The user-specific "which books are in which lists" state must be loaded separately. This async POST pattern lets the page render quickly with empty containers, then fills them with per-user data via Turbo Streams.

---

## Caching Strategy

Three cache keys per user, all keyed on `user.cache_key_with_version`:

| Cache Key | Returns | Used By |
|-----------|---------|---------|
| `{ckwv}/user_lists` | Array of UserList objects with user_list_books | General list rendering |
| `{ckwv}/user_lists_with_books` | `[{id:, name:, list_type:, book_ids: []}]` sorted by type priority | Controllers, UserBookActionsController |
| `{ckwv}/user_list_books_by_book` | `{book_id => [{id:, user_list_id:, position:}]}` | UserListBookManageLinkComponent |

**TTL**: All caches expire in 1 hour.

**Invalidation**: `UserListBook#invalidate_user_cache` (a `before_save` and `before_destroy` callback) calls `user.touch`, which updates `updated_at` and changes `cache_key_with_version`, instantly busting all three caches.

**Sort order** in `cached_user_lists_with_books`: read=0, want_to_read=1, reading=2, favorite=3, custom=4 (ensures system lists appear before custom lists in dropdowns).

---

## Background Jobs

### GenerateRankedUsersListJob

**File**: `admin/app/sidekiq/generate_ranked_users_list_job.rb`

Zero-argument Sidekiq job. Delegates to `GenerateRankedUsersList.generate`. Triggered by `UserListBook` callbacks whenever a book is added/removed/repositioned in any user's `favorite` list.

**Note**: No Redis deduplication lock -- concurrent runs are possible under high write load.

### BasicMethodCallJob

**File**: `admin/app/sidekiq/basic_method_call_job.rb`

Generic job: `perform(id, class_name, method_to_call)`. Used by `UserList.fix_positions(background_job: true)` to schedule position-fixing for every list with a 2-second delay.

### GoodreadsImportJob

**File**: `admin/app/sidekiq/goodreads_import_job.rb`

Processes async Goodreads imports. Launched by `GoodreadsImport#after_commit` with a 1-minute delay. Calls `process_import` which runs `GoodreadsLibraryParser` + `ReadingGoalsSync#sync_unsynced_books`.

---

## Service Integrations

### ReadingGoalsSync

**File**: `admin/app/lib/reading_goals_sync.rb`

Synchronizes books from the user's `read` list into `ReadingGoal`/`ReadingGoalBook` records.

**Called from**:
- `UserListBooksController#create` -- when adding to `read` list with `read_date`
- `UserListBooksController#destroy` -- with `operation: :remove` when removing from `read` list
- `UserListBooksController#update` -- when updating `read_date`
- `GoodreadsImport#process_import` -- calls `sync_unsynced_books` after parsing

**Algorithm** (`sync_book`):
1. Remove the book from ALL reading goals for this user (clean slate)
2. If `operation == :add`, find all `ReadingGoal` records where `start_date <= read_date <= end_date`
3. Create `ReadingGoalBook` entries and call `update_progress` on each goal

**Additional methods**:
- `sync_all_books` -- re-syncs all books in the read list that have `read_date`
- `sync_unsynced_books` -- only syncs books not already tracked in any reading goals

### GoodreadsLibraryParser

**File**: `admin/app/lib/goodreads_library_parser.rb`

Parses Goodreads CSV exports and populates user lists.

**Shelf-to-list mapping**:
- `read` shelf -> `read` list
- `to-read` shelf -> `want_to_read` list
- `currently-reading` shelf -> `reading` list
- Other shelves -> `custom` lists (created on-demand by name)

Also creates `Review` records from Goodreads ratings. Calls `fix_positions` on all modified lists at the end.

### Recommendations Engine

**Files**: `admin/app/lib/recommendations/strategies/base.rb`, `admin/app/lib/recommendations/strategies/algorithm_1.rb`

The recommendation system reads heavily from user lists:
- `calculate_books_to_ignore` aggregates book IDs from all 4 default list types plus reviews
- Category extraction from `favorite`, `read`, and star-rating-based buckets
- Uses OpenSearch `find_recommendations` with weighted category boosts

---

## Community Ranked List Algorithm

**File**: `admin/app/lib/generate_ranked_users_list.rb`

This is a key business feature: user favorites are aggregated into a site-wide "Top 100" list.

### Algorithm

```
1. Query all UserLists where list_type = "favorite" and book count > 0
2. For each list:
   For each book at position P in a list with N books:
     score += N - P + 1
   (Books at position 1 get the highest score)
3. Sort all books by total accumulated score (descending)
4. Populate two List records:
   - "Our Users' Top 100 Favorite Books of All Time" (positions 1-100)
   - Honorable mention list (positions 101+)
5. Call refresh_book_rankings on both lists (propagates into the ranking system)
```

### Triggers

The algorithm runs asynchronously via `GenerateRankedUsersListJob` whenever:
- A book is **added to** a favorite list (`after_create`)
- A book is **removed from** a favorite list (`after_destroy`)
- A book's **position changes** in a favorite list (`after_update` if `position_changed?`)

---

## Import/Export

### JSON Export/Import (Data Migration)

**Export** (`UserList#export_to_json`):
- Writes a JSON file with list metadata and all books (book_id, position, read_date, timestamps)
- Filename: `user_list_{id}_{name_parameterized}_{timestamp}.json`

**Import** (`UserList.import_from_json(user_id, filename)`):
- Creates a new list under the given user from a JSON file
- Runs in a transaction

### CSV Export (User-Facing)

Available on the list show page via the "Download" button. Columns: Book Title, Authors, Published Date, Country, Original Language, Page Range, Word Count. UTF-8 BOM for Excel compatibility.

### Goodreads Import

**Two paths**:

1. **Synchronous** (`UserListsController#goodreads_import`): Parses CSV immediately in the request thread
2. **Asynchronous** (`GoodreadsImportsController#upload`): Saves file to S3 via Active Storage, creates a `GoodreadsImport` record, processes via `GoodreadsImportJob` with 1-minute delay

---

## End-to-End Flows

### Flow 1: Adding a Book to a List (from a Book Listing Page)

```
1. Page loads with book rows, each containing:
   <div class="book-list-item" data-book="{book_id}">
     <div id="user-book-actions-container-{book_id}"></div>  (empty)
   </div>

2. DOMContentLoaded -> initUserBookLists()
   - Collects all data-book IDs into window.currentPageBookIds
   - Sets #book_ids hidden field value
   - Submits #user-book-actions-form via Turbo POST

3. POST /user_book_actions/index
   - Loads books, fetches cached_user_lists_with_books
   - Returns turbo_stream updates for each book

4. Turbo Streams fill each user-book-actions-container with:
   - UserListsComponent (dropdown button "Add to a List")
   - ReviewButtonComponent
   - Read badge (if applicable)

5. User clicks "Add to a List" dropdown
   - UserListDropdownComponent renders all lists
   - Each list is a UserListBookManageLinkComponent in its own turbo-frame
   - State (in-list vs not) determined by cached_user_list_books_by_book

6. User clicks a list name (e.g., "Books I've Read")
   - user-list-books Stimulus controller intercepts click
   - Calls parentNode.requestSubmit() on the hidden form
   - POST /user_lists/{id}/user_list_books

7. UserListBooksController#create
   - Checks for duplicates
   - Saves UserListBook (triggers callback chain)
   - handle_reading_to_read_transition: if adding to "read", removes from "reading"
   - set_position: appends to end
   - invalidate_user_cache: user.touch busts all caches
   - generate_ranked_list_if_required: if favorite list, enqueues job
   - Calls ReadingGoalsSync if read list + read_date
   - Reloads cached data

8. Response: create.turbo_stream.erb
   - Replaces user_list_book_{list_id}_{book_id} frame (now shows checkmark)
   - Replaces books-container (survey context)
   - Updates user-book-actions-container-{book_id} (refreshes full panel)

9. Notiflix toast: "Book successfully added to the list"
```

### Flow 2: Drag-and-Drop Reordering (Edit Page)

```
1. GET /user_lists/{id}/edit
   - Renders edit.html.erb with data-controller="user-list-sort"
   - Each book rendered as _book_list_item with data-id="{book_id}"
   - SortableJS initialized on bookListTarget

2. User drags a book to a new position
   - SortableJS fires onEnd callback
   - updateOrder() compares current vs original order
   - updateNumbers() updates badge numbers in real-time
   - Save button enabled if changes detected

3. User clicks "Save Changes"
   - handleSubmit() intercepts form submit
   - Creates FormData with new_order (comma-joined IDs) + deleted_books
   - fetch() POST to /user_lists/{id} (update action)

4. UserListsController#update
   - Transaction: updates metadata, calls reorder_books(new_order), destroys deleted books
   - Redirects to show page

5. Alternative: "Move to Top"/"Move to Bottom" in item dropdown
   - data-action="user-list-sort#moveToTop"
   - Moves DOM element, calls updateOrder()
```

### Flow 3: User Signup Default Lists

```
1. User.create! triggers after_create :create_default_user_lists
2. create_default_user_lists calls ensure_list_type_exists for each type:
   - :want_to_read -> "Books I Want to Read"
   - :read -> "Books I've Read"
   - :reading -> "Books I'm Reading"
   - :favorite -> "My Favorite Books"
3. ensure_list_type_exists is idempotent: finds existing or creates new
```

### Flow 4: Goodreads Import (Async)

```
1. User uploads CSV file on user_lists index page
2. POST /goodreads_imports/upload
3. GoodreadsImportsController#upload
   - Creates GoodreadsImport with Active Storage attachment
   - after_commit fires GoodreadsImportJob.perform_in(1.minute, id)
4. GoodreadsImportJob calls GoodreadsImport#process_import
5. GoodreadsLibraryParser parses CSV:
   - Maps shelves to list types
   - Finds or creates books via BookFinder
   - Creates UserListBooks
   - Creates Reviews from ratings
   - Fixes positions on all modified lists
6. ReadingGoalsSync.sync_unsynced_books at the end
```

---

## File Reference

### Models
| File | Purpose |
|------|---------|
| `admin/app/models/user_list.rb` | Core UserList model |
| `admin/app/models/user_list_book.rb` | Join model with callbacks |
| `admin/app/models/user.rb` | User associations, caching, list creation |
| `admin/app/models/book.rb` | Book associations, merge_with |
| `admin/app/models/goodreads_import.rb` | Async import tracking |

### Controllers
| File | Purpose |
|------|---------|
| `admin/app/controllers/user_lists_controller.rb` | List CRUD, CSV export, survey |
| `admin/app/controllers/user_list_books_controller.rb` | Book-in-list management |
| `admin/app/controllers/user_book_actions_controller.rb` | Bulk state loader |
| `admin/app/controllers/goodreads_imports_controller.rb` | Async Goodreads upload |

### Policies
| File | Purpose |
|------|---------|
| `admin/app/policies/user_list_policy.rb` | List authorization |
| `admin/app/policies/user_list_book_policy.rb` | Book-in-list authorization |

### ViewComponents
| File | Purpose |
|------|---------|
| `admin/app/components/user_lists_component.rb` | Top-level add-to-list UI |
| `admin/app/components/user_lists_component/user_lists_component.html.erb` | Button/icon display template |
| `admin/app/components/user_list_dropdown_component.rb` | Dropdown menu |
| `admin/app/components/user_list_dropdown_component/user_list_dropdown_component.html.erb` | Dropdown menu template |
| `admin/app/components/user_list_book_manage_link_component.rb` | Per-list-per-book link |
| `admin/app/components/user_list_book_manage_link_component/user_list_book_manage_link_component.html.erb` | Add/remove form template |
| `admin/app/components/user_list_book_actions_component.rb` | Server-side reorder buttons |
| `admin/app/components/user_list_book_actions_component/user_list_book_actions_component.html.erb` | Reorder buttons template |
| `admin/app/components/add_book_to_user_list_component.rb` | Add book modal |
| `admin/app/components/add_book_to_user_list_component/add_book_to_user_list_component.html.erb` | Add book modal template |

### Views
| File | Purpose |
|------|---------|
| `admin/app/views/user_lists/index.html.erb` | Lists dashboard |
| `admin/app/views/user_lists/show.html.erb` | List detail with books |
| `admin/app/views/user_lists/edit.html.erb` | Drag-and-drop edit |
| `admin/app/views/user_lists/_book_list_item.html.erb` | Edit page book row |
| `admin/app/views/user_lists/account_required.html.erb` | Auth prompt |
| `admin/app/views/user_lists/show_survey.html.erb` | Onboarding survey |
| `admin/app/views/user_list_books/create.turbo_stream.erb` | Add book turbo stream |
| `admin/app/views/user_list_books/destroy.turbo_stream.erb` | Remove book turbo stream |
| `admin/app/views/user_list_books/edit.html.erb` | Read date form |
| `admin/app/views/user_list_books/_modal.html.erb` | Create list modal |
| `admin/app/views/user_book_actions/index.turbo_stream.erb` | Bulk state injection |
| `admin/app/views/layouts/application.html.erb` | Global hidden form (line 59-63) |

### JavaScript
| File | Purpose |
|------|---------|
| `admin/app/javascript/user_lists.js` | Global bootstrapping (initUserBookLists) |
| `admin/app/javascript/controllers/user_list_books_controller.js` | Dropdown add/remove |
| `admin/app/javascript/controllers/user_list_sort_controller.js` | Drag-and-drop with SortableJS |
| `admin/app/javascript/controllers/create_user_list_form_controller.js` | Create list modal |
| `admin/app/javascript/controllers/user_list_items_manager_controller.js` | Double-submit prevention |
| `admin/app/javascript/controllers/user_list_books_update_form_controller.js` | Read date modal |
| `admin/app/javascript/controllers/add_book_controller.js` | Add book modal with autocomplete |

### CSS
| File | Purpose |
|------|---------|
| `admin/app/assets/stylesheets/user_lists.scss` | Drag-and-drop styles, ghost class |

### Services & Libraries
| File | Purpose |
|------|---------|
| `admin/app/lib/reading_goals_sync.rb` | Read list <-> reading goals bridge |
| `admin/app/lib/generate_ranked_users_list.rb` | Community ranking algorithm |
| `admin/app/lib/goodreads_library_parser.rb` | Goodreads CSV parser |
| `admin/app/lib/recommendations/strategies/base.rb` | Books-to-ignore calculation |
| `admin/app/lib/recommendations/strategies/algorithm_1.rb` | Recommendation engine |

### Background Jobs
| File | Purpose |
|------|---------|
| `admin/app/sidekiq/generate_ranked_users_list_job.rb` | Community ranking regeneration |
| `admin/app/sidekiq/basic_method_call_job.rb` | Generic method call (fix_positions) |
| `admin/app/sidekiq/goodreads_import_job.rb` | Async Goodreads processing |

### Tests
| File | Purpose |
|------|---------|
| `admin/test/models/user_list_book_test.rb` | UserListBook model tests |
| `admin/test/controllers/user_lists_controller_test.rb` | Controller authorization tests |

---

## Design Decisions and Notes for Reimplementation

### Architecture Choices Worth Preserving

1. **Async bootstrapping pattern**: Loading user-specific list state via a POST after page render keeps pages cacheable and fast. This is the single most important architectural decision in the feature.

2. **Cache invalidation via `user.touch`**: Simple and effective. Every mutation to a UserListBook touches the user, which busts all three cache keys via `cache_key_with_version`.

3. **Turbo Frame per dropdown item**: Each `user_list_book_{list_id}_{book_id}` frame can be individually replaced without touching the rest of the dropdown, keeping the UI responsive.

4. **Idempotent list creation**: `ensure_list_type_exists` is safe to call repeatedly, making data repair trivial.

5. **Position gap management**: `shift_positions_up` on destroy + `set_position` on create keeps positions contiguous without explicit gaps.

### Known Issues / Areas for Improvement

1. **`skip_forgery_protection`**: Both controllers disable CSRF. This is a security concern worth addressing in a rebuild.

2. **N+1 in edit page**: `_book_list_item.html.erb` calls `user_list.user_list_books.find_by(book: book)` twice per book row (lines 12-13 and 14) for read date display.

3. **No deduplication on `GenerateRankedUsersListJob`**: Multiple concurrent runs are possible. Could benefit from a Redis mutex or debounce.

4. **`move_up`/`move_down` race conditions**: The swap-based position updates in `UserListBook` aren't protected by optimistic locking.

5. **Read date format**: The custom `read_date=` setter expects `M-DD-YYYY` which is US-centric. Consider ISO 8601 in a rebuild.

6. **Synchronous Goodreads import path**: The `goodreads_import` action in `UserListsController` runs synchronously, which can time out on large libraries.

7. **`window.currentPageBookIds` global**: The bootstrapping pattern uses window globals for inter-component communication. Consider a more structured approach in a rebuild.
