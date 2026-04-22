# User Lists — Part 1: Data Model & Core Backend

## Status
- **Status**: Completed (scope-reduced — see "Deviations From Plan")
- **Priority**: High
- **Created**: 2026-04-19
- **Started**: 2026-04-20
- **Completed**: 2026-04-21
- **Developer**: Shane Sherman (with Claude Code)

## Overview
Introduce user-owned lists (`UserList`) and a polymorphic join table (`UserListItem`) so logged-in users can organize items (albums, songs, games, movies, books) into personal, ordered collections. This spec covers only the backing data model, default-list bootstrapping on user signup, authorization, and CRUD endpoints — **no UI and no cached-page integration** (those are covered in later specs).

**Non-goals for this spec:**
- Public list show pages, list management UI, "Add to list" widgets on cached item pages (→ user-lists-02)
- Dynamic community lists aggregated from user favorites (→ user-lists-03)
- Import/export (Goodreads CSV, JSON), drag-and-drop JS, Stimulus controllers
- ViewComponents (beyond any needed internally by controller tests)

## Context & Links
- Old-site reference: `docs/old_site/user-lists-feature.md`
- Existing editorial `List` model: `web-app/app/models/list.rb` (UserList is a **separate** hierarchy — do not reuse)
- Existing polymorphic join pattern: `web-app/app/models/list_item.rb`
- Existing User model: `web-app/app/models/user.rb`
- Existing domain item models: `Music::Album`, `Music::Song`, `Games::Game`, `Movies::Movie`, `Books::Book`
- Existing Pundit setup: `web-app/app/controllers/application_controller.rb` includes `Pundit::Authorization`
- Cacheable concern (required reading for context): `web-app/app/controllers/concerns/cacheable.rb`

### Design Decisions (pre-agreed with product owner)
1. `UserList` is a **new STI hierarchy**, separate from the editorial `List`. The editorial `List` has approval workflow, wizard state, AI import, penalty applications — none apply to personal lists.
2. A `UserList` is always scoped to one item type (e.g. an albums list cannot contain songs). Enforced via subclass → `listable_type` compatibility check on `UserListItem`.
3. On user signup (`after_create`), create the complete set of default lists for **every domain**. Defaults are skeleton (empty) lists, cheap to create.
4. `Favorites` exists for every item type and is the only "always present" default. Other defaults vary by item type.
5. A user can create additional `custom`-type lists.
6. Public/private visibility is per-list (`public: boolean, default: false`).

## Interfaces & Contracts

### Domain Model

#### Tables to create

**`user_lists`**

| Column        | Type     | Constraints                         | Notes                                               |
|---------------|----------|-------------------------------------|-----------------------------------------------------|
| `id`          | bigint   | PK                                  |                                                     |
| `user_id`     | bigint   | NOT NULL, FK → `users.id`           |                                                     |
| `type`        | string   | NOT NULL                            | STI discriminator                                   |
| `name`        | string   | NOT NULL                            |                                                     |
| `description` | text     | NULL                                |                                                     |
| `list_type`   | integer  | NOT NULL                            | enum per-subclass (see below)                       |
| `view_mode`   | integer  | NULL                                | enum: `default_view: nil, table_view: 1, grid_view: 2` |
| `public`      | boolean  | NOT NULL, default: false            |                                                     |
| `position`    | integer  | NULL                                | Ordering among a user's own lists (manual, not auto) |
| `created_at`  | datetime | NOT NULL                            |                                                     |
| `updated_at`  | datetime | NOT NULL                            |                                                     |

**Indexes:**
- `(user_id, type)` — most common filter: "all of a user's music albums lists"
- `(user_id, type, list_type)` UNIQUE **partial** WHERE `list_type != custom_value` — enforces single default list per type per user. `custom` lists are exempt.
- `(public)` WHERE `public = true` — for future public-list queries
- `(user_id)` — general lookup

**`user_list_items`**

| Column           | Type     | Constraints                              | Notes                                                    |
|------------------|----------|------------------------------------------|----------------------------------------------------------|
| `id`             | bigint   | PK                                       |                                                          |
| `user_list_id`   | bigint   | NOT NULL, FK → `user_lists.id`           |                                                          |
| `listable_type`  | string   | NOT NULL                                 | Polymorphic: `Music::Album`, `Games::Game`, etc.         |
| `listable_id`    | bigint   | NOT NULL                                 | Polymorphic                                              |
| `position`       | integer  | NOT NULL                                 | 1-based, auto-managed on create                          |
| `completed_on`   | date     | NULL                                     | Date user read/watched/listened/played the item          |
| `created_at`     | datetime | NOT NULL                                 |                                                          |
| `updated_at`     | datetime | NOT NULL                                 |                                                          |

**Indexes:**
- `(user_list_id, listable_type, listable_id)` UNIQUE — prevents duplicates
- `(user_list_id, position)` — ordered iteration
- `(listable_type, listable_id)` — "which lists is this item in?" queries
- `(user_list_id, completed_on)` — future sort

**Migration file name:** `YYYYMMDDHHMMSS_create_user_lists_and_user_list_items.rb`

#### Model Class Hierarchy

```
UserList                                    (base, abstract for business purposes)
├── Music::Albums::UserList                 list_type: favorites, listened, want_to_listen, custom
├── Music::Songs::UserList                  list_type: favorites, custom
├── Games::UserList                         list_type: favorites, played, beaten, want_to_play, currently_playing, custom
├── Movies::UserList                        list_type: favorites, watched, want_to_watch, custom
└── Books::UserList                         list_type: favorites, read, reading, want_to_read, custom

UserListItem                                (single class, polymorphic via listable)
```

**File paths:**
- `web-app/app/models/user_list.rb` (base)
- `web-app/app/models/music/albums/user_list.rb`
- `web-app/app/models/music/songs/user_list.rb`
- `web-app/app/models/games/user_list.rb`
- `web-app/app/models/movies/user_list.rb`
- `web-app/app/models/books/user_list.rb`
- `web-app/app/models/user_list_item.rb`

#### `UserList` base class — responsibilities

All shared logic lives here:

- `belongs_to :user`
- `has_many :user_list_items, -> { order(:position) }, dependent: :destroy`
- `has_many :items, through: :user_list_items, source: :listable` (polymorphic through works via `source: :listable`; confirm at implementation)
- `enum :view_mode, { default_view: nil, table_view: 1, grid_view: 2 }`
- `validates :name, presence: true`
- `validates :list_type, presence: true`
- `validates :user, presence: true`
- Validation: one default list per `(user_id, type, list_type)` except `custom`. Implemented as a model validation **and** backed by the partial unique index.
- `scope :public_lists, -> { where(public: true) }`
- `scope :owned_by, ->(user) { where(user: user) }`
- Class method `self.default_list_types` — abstract, raises `NotImplementedError` in base. Each subclass overrides to return the array of `list_type` keys that are default for that item type (e.g. `[:favorites, :listened, :want_to_listen]`).
- Class method `self.listable_class` — abstract, returns the item class (e.g. `Music::Album`). Raises `NotImplementedError` in base. Used by `UserListItem` type-compatibility validation.
- Instance method `default?` — returns `list_type != :custom`.
- Instance method `reorder_items!(ordered_listable_ids)` — accepts an ordered array of listable IDs and updates `position` in a transaction. Raises on unknown IDs.

**Do not** include wizard state, AI parsing, penalty applications, `items_json`, `raw_content`, or any of the `List` editorial fields on `UserList`. `UserList` and `List` are intentionally separate tables and separate concerns.

#### Subclass responsibilities

Each subclass (`Music::Albums::UserList`, `Games::UserList`, etc.) must:

1. Declare its own `enum :list_type, { ... }` with `custom` **always** as the final value. Integer values must start at 0 per subclass (enum scoped by STI `type` via `enum :list_type, ..., prefix: false`). Because each subclass stores `list_type` as an integer in a shared column, the same integer can mean different symbols in different subclasses — this is fine because queries always scope by `type`.
2. Override `self.default_list_types` → array of default `list_type` keys.
3. Override `self.listable_class` → the polymorphic target class (e.g. `Music::Album`).
4. Override `self.default_list_name_for(list_type)` → user-facing display name. Examples:

| Subclass                   | list_type             | default_list_name_for         |
|----------------------------|-----------------------|-------------------------------|
| Music::Albums::UserList    | `:favorites`          | "Favorite Albums"             |
| Music::Albums::UserList    | `:listened`           | "Albums I've Listened To"     |
| Music::Albums::UserList    | `:want_to_listen`     | "Albums I Want to Listen To"  |
| Music::Songs::UserList     | `:favorites`          | "Favorite Songs"              |
| Games::UserList            | `:favorites`          | "Favorite Games"              |
| Games::UserList            | `:played`             | "Games I've Played"           |
| Games::UserList            | `:beaten`             | "Games I've Beaten"           |
| Games::UserList            | `:want_to_play`       | "Games I Want to Play"        |
| Games::UserList            | `:currently_playing`  | "Games I'm Currently Playing" |
| Movies::UserList           | `:favorites`          | "Favorite Movies"             |
| Movies::UserList           | `:watched`            | "Movies I've Watched"         |
| Movies::UserList           | `:want_to_watch`      | "Movies I Want to Watch"      |
| Books::UserList            | `:favorites`          | "Favorite Books"              |
| Books::UserList            | `:read`               | "Books I've Read"             |
| Books::UserList            | `:reading`            | "Books I'm Reading"           |
| Books::UserList            | `:want_to_read`       | "Books I Want to Read"        |

#### `UserListItem` — responsibilities

- `belongs_to :user_list, touch: true`
- `belongs_to :listable, polymorphic: true`
- `has_one :user, through: :user_list`
- `validates :position, numericality: { greater_than: 0 }, allow_blank: true` (blank during pre-create; set by callback)
- `validates :listable_id, uniqueness: { scope: [:user_list_id, :listable_type] }`
- Validation `listable_type_compatible_with_user_list_type` — compares `listable_type` against `user_list.class.listable_class.name`; errors if mismatch.
- `before_create :set_position` — appends to end (`max(position) + 1` within the list, or 1 if empty).
- `after_destroy_commit :shift_positions_up` — decrements `position` of all siblings with higher positions, in a single SQL update.
- `default_scope { order(:position) }` — matches existing `ListItem` convention only if the user-facing code always wants positional order. **Decision: do NOT use a default scope**; instead provide `scope :ordered, -> { order(:position) }` explicitly. Default scopes are hard to unset and lead to bugs.

#### User Model changes

In `web-app/app/models/user.rb`:

```ruby
has_many :user_lists, dependent: :destroy
has_many :user_list_items, through: :user_lists

after_create :create_default_user_lists

def default_user_list_for(user_list_class, list_type)
  user_lists.where(type: user_list_class.name, list_type: list_type).first
end

private

def create_default_user_lists
  UserList::DEFAULT_SUBCLASSES.each do |klass|
    klass.default_list_types.each do |list_type|
      next if list_type == :custom # safety — never a default
      klass.find_or_create_by!(user: self, list_type: list_type) do |list|
        list.name = klass.default_list_name_for(list_type)
      end
    end
  end
end
```

The `UserList::DEFAULT_SUBCLASSES` constant is defined in the base `UserList` class:

```ruby
DEFAULT_SUBCLASSES = [
  "Music::Albums::UserList",
  "Music::Songs::UserList",
  "Games::UserList",
  "Movies::UserList",
  "Books::UserList"
].freeze

def self.default_subclasses
  DEFAULT_SUBCLASSES.map(&:constantize)
end
```

(Using strings + `constantize` avoids STI autoload ordering headaches.)

### Endpoints

This spec delivers **JSON CRUD endpoints only**. UI (HTML views, turbo streams, Stimulus) comes in user-lists-02.

Routes live at the **global** (cross-domain) level under `/user_lists`. This matches the app's existing convention — flat, non-prefixed routes (see `auth/sign_in`, `auth/sign_out` for precedent). The app does **not** use an `/api/` namespace anywhere, and introducing one just for this feature would be inconsistent.

Responses are JSON. Controllers declare `respond_to :json` (Part 2 will add HTML formats on top of the same controllers for any endpoints that need UI).

| Verb   | Path                                      | Controller#Action            | Purpose                                          | Auth             |
|--------|-------------------------------------------|------------------------------|--------------------------------------------------|------------------|
| GET    | `/user_lists`                             | `user_lists#index`           | List current user's lists (optional type filter) | signed-in        |
| POST   | `/user_lists`                             | `user_lists#create`          | Create a custom list                             | signed-in        |
| GET    | `/user_lists/:id`                         | `user_lists#show`            | Fetch a single list + items                      | owner OR public  |
| PATCH  | `/user_lists/:id`                         | `user_lists#update`          | Update name/description/public/view_mode         | owner            |
| DELETE | `/user_lists/:id`                         | `user_lists#destroy`         | Delete a list (default lists cannot be deleted)  | owner            |
| POST   | `/user_lists/:id/reorder`                 | `user_lists#reorder`         | Reorder items (body: `ordered_listable_ids`)     | owner            |
| POST   | `/user_lists/:user_list_id/items`         | `user_list_items#create`     | Add item to list                                 | owner            |
| DELETE | `/user_lists/:user_list_id/items/:id`     | `user_list_items#destroy`    | Remove item from list                            | owner            |
| PATCH  | `/user_lists/:user_list_id/items/:id`     | `user_list_items#update`     | Update `completed_on`                            | owner            |

> Source of truth: `web-app/config/routes.rb`. Add **outside** of any `DomainConstraint` block so they work across all four domains with a single controller.

**CSRF**: These endpoints are called from signed-in user JS. Use standard Rails CSRF via the `X-CSRF-Token` header from `<meta name="csrf-token">`. Do **not** `skip_forgery_protection`.

**Caching**: All endpoints call `prevent_caching` (via the existing `Cacheable` concern). They must never be cached at CloudFlare.

### Schemas (JSON)

**Request — POST `/user_lists`** (create custom list)
```json
{
  "type": "object",
  "required": ["user_list"],
  "properties": {
    "user_list": {
      "type": "object",
      "required": ["type", "name"],
      "properties": {
        "type":        { "type": "string", "enum": [
          "Music::Albums::UserList",
          "Music::Songs::UserList",
          "Games::UserList",
          "Movies::UserList",
          "Books::UserList"
        ]},
        "name":        { "type": "string", "minLength": 1, "maxLength": 255 },
        "description": { "type": ["string", "null"] },
        "public":      { "type": "boolean" }
      },
      "additionalProperties": false
    }
  }
}
```
> `list_type` is always forced to `"custom"` server-side on create — clients cannot create a default list via this endpoint.

**Request — PATCH `/user_lists/:id`**
```json
{
  "type": "object",
  "required": ["user_list"],
  "properties": {
    "user_list": {
      "type": "object",
      "properties": {
        "name":        { "type": "string", "minLength": 1, "maxLength": 255 },
        "description": { "type": ["string", "null"] },
        "public":      { "type": "boolean" },
        "view_mode":   { "type": ["string", "null"], "enum": [null, "default_view", "table_view", "grid_view"] }
      },
      "additionalProperties": false
    }
  }
}
```

**Request — POST `/user_lists/:id/reorder`**
```json
{
  "type": "object",
  "required": ["ordered_listable_ids"],
  "properties": {
    "ordered_listable_ids": {
      "type": "array",
      "items": { "type": "integer" },
      "minItems": 1
    }
  }
}
```

**Request — POST `/user_lists/:user_list_id/items`**
```json
{
  "type": "object",
  "required": ["user_list_item"],
  "properties": {
    "user_list_item": {
      "type": "object",
      "required": ["listable_id"],
      "properties": {
        "listable_id":  { "type": "integer" },
        "completed_on": { "type": ["string", "null"], "format": "date" }
      },
      "additionalProperties": false
    }
  }
}
```
> `listable_type` is derived server-side from the `UserList` subclass (e.g. `Music::Albums::UserList` → `Music::Album`). Clients never pass it.

**Request — PATCH `/user_lists/:user_list_id/items/:id`**
```json
{
  "type": "object",
  "required": ["user_list_item"],
  "properties": {
    "user_list_item": {
      "type": "object",
      "properties": {
        "completed_on": { "type": ["string", "null"], "format": "date" }
      },
      "additionalProperties": false
    }
  }
}
```

**Response — `UserList` (single)**
```json
{
  "type": "object",
  "required": ["id", "type", "name", "list_type", "public", "view_mode", "items_count", "created_at", "updated_at"],
  "properties": {
    "id":          { "type": "integer" },
    "type":        { "type": "string" },
    "name":        { "type": "string" },
    "description": { "type": ["string", "null"] },
    "list_type":   { "type": "string" },
    "public":      { "type": "boolean" },
    "view_mode":   { "type": ["string", "null"] },
    "position":    { "type": ["integer", "null"] },
    "items_count": { "type": "integer" },
    "items":       { "type": "array", "items": { "$ref": "#/definitions/UserListItem" } },
    "created_at":  { "type": "string", "format": "date-time" },
    "updated_at":  { "type": "string", "format": "date-time" }
  }
}
```
> `items` is included only on `show`, not on `index`.

**Response — `UserListItem`**
```json
{
  "type": "object",
  "required": ["id", "listable_type", "listable_id", "position", "created_at"],
  "properties": {
    "id":            { "type": "integer" },
    "listable_type": { "type": "string" },
    "listable_id":   { "type": "integer" },
    "position":      { "type": "integer" },
    "completed_on":  { "type": ["string", "null"], "format": "date" },
    "created_at":    { "type": "string", "format": "date-time" },
    "updated_at":    { "type": "string", "format": "date-time" }
  }
}
```

**Error contract** (4xx responses)
```json
{
  "error": {
    "code":   "validation_failed",
    "message": "Name can't be blank",
    "details": { "name": ["can't be blank"] }
  }
}
```

Error `code` values: `unauthenticated`, `forbidden`, `not_found`, `validation_failed`, `conflict` (duplicate item), `default_list_not_deletable`.

### Behaviors (pre/postconditions)

**Signup**
- Pre: user record saved for the first time.
- Post: `user.user_lists.count == sum_of_all_subclass_default_list_types`. Exact count: Music::Albums=3, Music::Songs=1, Games=5, Movies=3, Books=4 = **16 default lists total**.
- Idempotency: calling `create_default_user_lists` again must not create duplicates (uses `find_or_create_by!`).

**Create custom list**
- Pre: signed in; valid `type` (a known subclass name).
- Post: new `UserList` with `list_type = :custom`, `user_id = current_user.id`.
- Edge cases:
  - Unknown `type` → 422 with `code: validation_failed`.
  - Client attempts to set `list_type` → ignored; always forced to `custom`.

**Add item to list**
- Pre: signed in; owner of `user_list`; `listable_id` exists and matches `user_list.class.listable_class`.
- Post: `UserListItem` exists; `position = max + 1`; `user_list.updated_at` touched.
- Edge cases:
  - Listable does not exist → 404.
  - Listable already in this list → 409 with `code: conflict`.
  - Listable class mismatch (e.g. trying to add a `Music::Song` to a `Music::Albums::UserList`) → 422 with `code: validation_failed`.

**Remove item**
- Post: `UserListItem` destroyed; sibling positions shifted up (single UPDATE).
- Edge case: item not in this list → 404.

**Reorder items**
- Pre: owner; `ordered_listable_ids` exactly matches the current set of `listable_id`s in the list (same length, same set of IDs — any difference is a client bug).
- Post: positions 1..N assigned in the given order, in a single transaction.
- Edge cases:
  - Mismatch in ID set (extras or missing) → 422 with `code: validation_failed` and a helpful message. Do not partially apply.

**Update list metadata**
- Post: fields updated. `list_type` is **immutable** (cannot be changed after creation, even on custom lists).

**Delete list**
- Default lists cannot be deleted → 422 with `code: default_list_not_deletable`. Only `custom` lists can be deleted.
- Cascades to `user_list_items` via `dependent: :destroy`.

### Non-Functionals

- **Auth**: All endpoints require `signed_in?`. Show endpoint additionally allows any authenticated user to view a `public: true` list owned by anyone.
- **Authorization**: Pundit policies — `UserListPolicy`, `UserListItemPolicy`. See below.
- **Caching**: All endpoints set `Cache-Control: no-store, private` via `prevent_caching`.
- **Performance**:
  - Signup must create 16 default lists in a single transaction. No N+1. Bulk insert via `UserList.insert_all` is acceptable but `find_or_create_by!` in a loop is fine at this scale — 16 rows is trivial.
  - Reorder must use a single transaction; a `UPDATE ... FROM (VALUES ...)` pattern is preferred if it fits naturally, otherwise per-row updates inside a transaction are acceptable for this scale (< 10k items).
  - Show endpoint on a 10k-item list: bounded by pagination. For v1, cap at first 500 items with no pagination; paginate properly in user-lists-02.
- **Concurrency**: Position reassignment on reorder happens within a transaction. Two concurrent reorders on the same list may produce last-writer-wins ordering; that's acceptable.
- **No external integrations** (no CloudFlare, OpenSearch, MusicBrainz, IGDB in this spec).

### Authorization — Pundit Policies

**`web-app/app/policies/user_list_policy.rb`**

| Action       | Rule                                               |
|--------------|----------------------------------------------------|
| `index?`     | `user.present?` (signed in)                        |
| `show?`      | `record.public? || record.user_id == user&.id` (also admin) |
| `create?`    | `user.present?`                                    |
| `update?`    | `record.user_id == user&.id` (also admin)          |
| `destroy?`   | `record.user_id == user&.id && !record.default?` (also admin; admin can delete defaults) |
| `reorder?`   | same as `update?`                                  |
| Scope         | Own lists ∪ public lists (admin sees all)          |

**`web-app/app/policies/user_list_item_policy.rb`**

| Action       | Rule                                                       |
|--------------|------------------------------------------------------------|
| All actions  | `record.user_list.user_id == user&.id` (also admin)        |

## Acceptance Criteria

### Delivered in this spec (models-only scope)
- [x] Migration creates `user_lists` and `user_list_items` tables with all listed columns, indexes, and FKs. Runs reversibly.
- [x] `UserList` base class + **4** STI subclasses exist and can be instantiated. (Books excluded — see Deviations.)
- [x] Each subclass declares `list_type` enum, `default_list_types`, `listable_class`, `default_list_name_for`.
- [x] `UserListItem` enforces type compatibility (e.g., cannot add `Music::Song` to `Music::Albums::UserList`).
- [x] Unique constraint prevents adding the same item twice to the same list (DB-level + model validation).
- [x] `User.create!` triggers creation of exactly **12** default lists across all subclasses. (16 → 12 because Books was excluded.)
- [x] `UserListItem#set_position` callback appends at end.
- [x] `UserListItem` destroy shifts sibling positions up.
- [x] `UserList#reorder_items!` updates positions atomically and rejects ID-set mismatches.
- [x] `list_type` cannot be changed after create (`list_type_immutable` validation).
- [x] Minitest coverage on new models: 48 model tests + 6 added to `user_test.rb`, all passing.
- [x] Existing test suite still passes (4092 runs, 0 failures, 0 errors).

### Deferred to user-lists-02 (UI + controllers)
- [ ] Default lists (`list_type != :custom`) cannot be deleted via the API. (`default?` instance method exists and is ready for the policy.)
- [ ] Partial unique index prevents a user having two default lists of the same `(type, list_type)`. (Intentionally not implemented — see Deviations.)
- [ ] All 9 JSON endpoints implemented, returning JSON responses matching the schemas.
- [ ] Pundit policies implemented and tested: non-owners cannot mutate; public lists are viewable via show.
- [ ] All endpoints return `Cache-Control: no-store, private`.
- [ ] Unknown/mismatched listable types produce 422, not 500.

### Golden Examples

**Example 1 — signup default lists**
```
Input:  User.create!(email: "a@b.com", ...)
Output: user.user_lists.count == 16
        user.user_lists.where(type: "Music::Albums::UserList").pluck(:list_type)
          → ["favorites", "listened", "want_to_listen"]  # order may vary
        user.user_lists.where(type: "Books::UserList", list_type: :favorites).first.name
          → "Favorite Books"
```

**Example 2 — add album to list**
```
Input:  POST /user_lists/42/items
        { "user_list_item": { "listable_id": 9876 } }
        where list 42 is current_user's Music::Albums::UserList (favorites)
        and 9876 is a valid Music::Album id not already in the list
Output: 201 Created
        { "id": 555, "listable_type": "Music::Album", "listable_id": 9876,
          "position": (previous_max + 1), ... }
```

**Example 3 — type mismatch**
```
Input:  POST /user_lists/42/items
        { "user_list_item": { "listable_id": 9876 } }
        where list 42 is a Music::Albums::UserList
        but 9876 is the id of a Music::Song
Output: 422 Unprocessable Entity
        { "error": { "code": "validation_failed",
                     "message": "Listable type Music::Song is not compatible...",
                     "details": { "listable_type": ["..."] } } }
```

**Example 4 — cannot delete default list**
```
Input:  DELETE /user_lists/42
        where list 42 is current_user's default favorites list
Output: 422 Unprocessable Entity
        { "error": { "code": "default_list_not_deletable",
                     "message": "Default lists cannot be deleted" } }
```

**Example 5 — reorder**
```
Given:  list 42 has items (position, listable_id): (1, 10), (2, 20), (3, 30)
Input:  POST /user_lists/42/reorder
        { "ordered_listable_ids": [30, 10, 20] }
Output: 200 OK; list now has (1, 30), (2, 10), (3, 20)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns. Mirror conventions from `List` / `ListItem` / `Music::Albums::List` where they apply; diverge where the editorial concerns don't fit (wizard state, AI parsing, penalties, etc.).
- `UserList` is a **separate** hierarchy from `List`. Do not reuse the `lists` table.
- Respect snippet budget (≤40 lines per snippet in this spec).
- Link to file paths, don't paste full controllers/models.
- Do not introduce new gems. Use existing Minitest + Mocha + fixtures stack.
- Do NOT build UI, Stimulus, ViewComponents, or cached-page integration — those belong to user-lists-02.
- Do NOT build the dynamic-favorites-aggregation job — that belongs to user-lists-03.

### Required Outputs
- New files listed under "Key Files Touched".
- Passing Minitest tests for every Acceptance Criteria bullet.
- Updated class documentation per `docs/documentation.md` conventions (class docs for each new model + policy + controller).
- Filled-in "Implementation Notes" and "Deviations" sections below.

### Sub-Agent Plan
1. `codebase-pattern-finder` → collect comparable patterns in `List`, `ListItem`, and existing STI subclasses so the new models feel consistent.
2. `codebase-analyzer` → verify integration points in `User`, Pundit setup, and the `Cacheable` concern before writing the migration and controllers.
3. `technical-writer` → after implementation, update class docs and cross-refs.

### Test Seed / Fixtures
- Extend `test/fixtures/users.yml` only if a new fixture is needed (prefer creating users in tests via `User.create!` to exercise the default-list callback).
- Reuse existing `music_albums`, `music_songs`, `games_games`, `movies_movies`, `books_books` fixtures as listables.
- Add `test/fixtures/user_lists.yml` with at least: one default favorites list per domain + one custom list.
- Add `test/fixtures/user_list_items.yml` with a handful of items across types.

---

## Implementation Notes (living)
- **Approach taken**: Scope was narrowed to models-only in Phase 3 per product-owner direction. Controllers, Pundit policies, routes, JSON schemas, and their tests were explicitly deferred to `user-lists-02` so we can build them together with the UI. The schema, STI hierarchy, polymorphic item model, signup-time default bootstrap, and position management all landed in this PR.
- **Important decisions**:
  - `Books::UserList` and `Books::Book` excluded entirely. `DEFAULT_SUBCLASSES` has 4 entries; per-user default count is 12, not 16.
  - Per-subclass enums (original spec shape) were kept over a flat enum on the base class after trade-off discussion. STI scoping means `UserList.where(list_type:)` is only safe within a subclass, which is the query pattern anyway.
  - The "one default list per (user, type)" partial unique index was dropped. Model-level validation only. Reason: default lists are created exclusively through the idempotent `after_create :create_default_user_lists` callback, and the API forces `list_type = :custom` for user-created lists. The DB index was belt-and-suspenders with messy SQL (different `custom` integer per subclass).
  - `has_many :items, through: :user_list_items, source: :listable` cannot live on the base class because polymorphic `has_many :through` requires an explicit `source_type:`. Each subclass declares it with its own `source_type:` instead.
  - `set_position` moved from `before_create` to `before_validation, on: :create` because `position` is `NOT NULL` at the DB and validated `numericality: { greater_than: 0 }`. It must be populated before validation runs.
  - `shift_positions_up` now guards with `return if user_list.destroyed?` to avoid N no-op UPDATEs when a parent list cascade-destroys its items.

### Key Files Touched (paths only)
**Migration**
- `web-app/db/migrate/20260422002612_create_user_lists_and_user_list_items.rb`

**Models (new)**
- `web-app/app/models/user_list.rb`
- `web-app/app/models/user_list_item.rb`
- `web-app/app/models/music/albums/user_list.rb`
- `web-app/app/models/music/songs/user_list.rb`
- `web-app/app/models/games/user_list.rb`
- `web-app/app/models/movies/user_list.rb`

**Models (modified)**
- `web-app/app/models/user.rb` — associations + `after_create :create_default_user_lists` + `default_user_list_for`
- `web-app/app/models/music/album.rb` — `has_many :user_list_items, as: :listable`
- `web-app/app/models/music/song.rb` — same
- `web-app/app/models/games/game.rb` — same
- `web-app/app/models/movies/movie.rb` — same

**Fixtures**
- `web-app/test/fixtures/user_lists.yml`
- `web-app/test/fixtures/user_list_items.yml`

**Tests**
- `web-app/test/models/user_list_test.rb` (17 tests)
- `web-app/test/models/user_list_item_test.rb` (11 tests)
- `web-app/test/models/music/albums/user_list_test.rb` (5 tests)
- `web-app/test/models/music/songs/user_list_test.rb` (4 tests)
- `web-app/test/models/games/user_list_test.rb` (4 tests)
- `web-app/test/models/movies/user_list_test.rb` (4 tests)
- `web-app/test/models/user_test.rb` (6 added tests)

**Generator side-effects** (untracked module files created by `rails g model`, harmless)
- `web-app/app/models/music/albums.rb`
- `web-app/app/models/music/songs.rb`

**Documentation**
- `docs/features/user-lists.md` (new)

### Challenges & Resolutions
- **Polymorphic `has_many :through` without `source_type`** raises `HasManyThroughAssociationPolymorphicSourceError`. The spec hinted at this ("confirm at implementation"). Resolved by moving `has_many :items` from the base class to each subclass with the correct `source_type:`.
- **Generators created `music/albums.rb` and `music/songs.rb` module files** with `table_name_prefix = "music_albums_"` / `"music_songs_"`. Since all models under those namespaces are STI children that use the base table, `table_name_prefix` doesn't actually change any resolved table name. Verified with `Music::Albums::List.table_name == "lists"`. Left the files in place because they're consistent with the existing convention (`music.rb`, `games.rb`, `movies.rb`).
- **`Books::Book` referenced by an existing fixture but doesn't exist** (`test/fixtures/list_items.yml` has `books_item: listable: one (Books::Book)`). This is pre-existing broken state; not fixed in this spec since books is out of scope.
- **Code review surfaced `reorder_items!` loading full AR objects just to validate ID set** — refactored to pluck IDs first, also added `.map(&:to_i)` coercion so future controller callers passing string IDs from params don't fail silently.

### Deviations From Plan
| Planned | Delivered | Reason |
|---|---|---|
| 5 STI subclasses including `Books::UserList` | 4 STI subclasses; books excluded | `Books::Book` model doesn't exist yet; owner chose to defer books to a future spec rather than build a minimal stub |
| 16 default lists per user | 12 default lists per user | Follows from books exclusion (Books::UserList would have contributed 4) |
| Partial unique index on `(user_id, type, list_type) WHERE list_type != custom` | Model-level `one_default_per_type_per_user` validation only | Default lists only originate from the idempotent signup callback; API forces `custom`. DB index added schema complexity (per-subclass `WHERE` clauses) without meaningful protection |
| JSON CRUD endpoints (9 endpoints), controllers, Pundit policies, routes, JSON schemas, controller/policy tests | Deferred to `user-lists-02` | Owner requested models-only so the UI and controllers are built together |
| Class-level docs per `docs/documentation.md` for each new model/policy/controller | Single feature doc at `docs/features/user-lists.md` | Project convention (`docs/documentation.md`) explicitly says "We do not document individual classes" — feature-level docs are the right surface |
| `has_many :items` on base `UserList` | `has_many :items` on each subclass with explicit `source_type:` | Polymorphic `has_many :through` requires `source_type:`; spec flagged this as "confirm at implementation" |
| `before_create :set_position` on `UserListItem` | `before_validation :set_position, on: :create` | `position` is `NOT NULL` + has a `numericality` validation; must be set before validation, not before insert |

## Acceptance Results
- **Date**: 2026-04-21
- **Verifier**: Shane Sherman (with Claude Code)
- **Artifacts**:
  - Full test suite: **4092 runs, 10665 assertions, 0 failures, 0 errors** (via `bin/rails test`)
  - Model tests specific to this feature: **68 runs, 127 assertions, 0 failures**
  - Linter: `bundle exec standardrb` — clean on all changed files
  - Migration: reversible, applied locally via `bin/rails db:migrate`
  - Smoke check: `UserList.default_subclasses`, `Music::Albums::UserList.default_list_types`, `Games::UserList.listable_class` all resolve correctly
- **Golden examples verified** (from spec):
  - Example 1 (signup default lists): 12 lists created, correct types and names
  - Example 2 (add album to list): position auto-incremented, `after_create` not needed since position is set in `before_validation`
  - Example 3 (type mismatch): validation fails with `listable_type` error when adding a `Music::Song` to `Music::Albums::UserList`
  - Example 4 (cannot delete default list): `default?` returns true; the deletability check will be enforced in the policy layer in `user-lists-02`
  - Example 5 (reorder): positions update atomically; `ArgumentError` on ID-set mismatch

## Future Improvements
- Pagination on list show (deferred; see user-lists-02).
- Soft-delete / archive state for lists.
- Sharing via signed URL (beyond simple public flag).
- Backfill default lists for existing users when new subclasses are added (e.g. `Books::UserList` when books lands). The idempotent `find_or_create_by!` in `create_default_user_lists` means a one-off rake task iterating over existing users would be sufficient.

## Related PRs
- _to be filled when the PR is opened_

## Documentation Updated
- [x] `docs/features/user-lists.md` (new feature doc)
- [x] Spec file (this document) — Status, Implementation Notes, Deviations, Acceptance Results
- [n/a] Class-level docs — project convention (`docs/documentation.md`) is no per-class documentation
