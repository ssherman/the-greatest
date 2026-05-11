# User Lists

## Overview
User Lists are personal, ordered collections that logged-in users use to organize items they care about across the four media domains (music albums, music songs, games, movies). Each user automatically receives a predefined set of default lists (e.g. "Favorite Albums", "Games I've Played") on signup and can create an unlimited number of additional custom lists.

This feature corresponds to the `user-lists-01` spec (data model and core backend) and `user-lists-02a` spec (Add-to-List widget). The `/my/lists` dashboard, list show pages, and drag-and-drop reordering UI are deferred to `user-lists-02c`.

## Architecture

### Class Hierarchy (STI)
```
UserList                                 (base class, abstract)
├── Music::Albums::UserList              list_type: favorites, listened, want_to_listen, custom
├── Music::Songs::UserList               list_type: favorites, custom
├── Games::UserList                      list_type: favorites, played, beaten, want_to_play, currently_playing, custom
└── Movies::UserList                     list_type: favorites, watched, want_to_watch, custom

UserListItem                             (single class, polymorphic via `listable`)
```

`UserList` is a **separate STI hierarchy** from the editorial `List` class. They share no fields, no approval workflow, and no tables. `UserList` lives in `user_lists` and holds no editorial concerns (no wizard state, AI parsing, penalties, etc.).

### Scoping by Item Type
Each `UserList` subclass is bound to one `listable` item type via a `self.listable_class` class method. `UserListItem#listable_type_compatible_with_user_list` enforces at the model level that you can only add, for example, a `Music::Album` to a `Music::Albums::UserList`.

### List Types
Each subclass declares its own `enum :list_type` with a subclass-specific set of keys and a shared `custom` key. Because each subclass scopes its own queries (e.g. `Music::Albums::UserList.favorites`), the fact that the underlying integer values collide across STI subclasses is harmless in practice.

- **Default lists** are the non-`custom` list_types. They are created automatically on user signup (see Default-List Bootstrap below).
- **Custom lists** are the only list type users can create through the API. They're for freeform grouping.

### Default-List Bootstrap
On `User.create`, an `after_create :create_default_user_lists` callback iterates over `UserList::DEFAULT_SUBCLASSES` and calls `find_or_create_by!` for every subclass's `default_list_types`. The result is **12 default lists** per new user:

| Subclass                   | Count | Types |
|----------------------------|-------|-------|
| `Music::Albums::UserList`  | 3     | favorites, listened, want_to_listen |
| `Music::Songs::UserList`   | 1     | favorites |
| `Games::UserList`          | 5     | favorites, played, beaten, want_to_play, currently_playing |
| `Movies::UserList`         | 3     | favorites, watched, want_to_watch |

Because fixture loading bypasses ActiveRecord callbacks, fixture users do NOT receive default lists automatically. Tests that rely on the callback must build users via `User.create!`.

### Position Management on `UserListItem`
- `before_create :set_position` — appends new items at the end (`max(position) + 1`).
- `after_destroy_commit :shift_positions_up` — decrements position for all siblings with a higher position, in a single SQL UPDATE, so positions stay contiguous.
- `scope :ordered, -> { order(:position) }` — explicit ordering scope; no `default_scope`.

Reordering is implemented via `UserList#reorder_items!(ordered_listable_ids)`, which requires the caller to pass **exactly** the current set of listable IDs (no additions, no removals) and applies the new positions inside a transaction.

### Uniqueness Constraints
- **One copy of a given item per list** — DB-level `UNIQUE(user_list_id, listable_type, listable_id)` plus a model-level `validates :listable_id, uniqueness:`.
- **One default list per (user, type)** — enforced at the model level only (`one_default_per_type_per_user`). There is no DB partial unique index: default lists are only ever created through the idempotent signup callback, so the model-level check is sufficient and keeps the schema simple.

### Public vs Private
Each `UserList` has a `public` boolean (default false). Individual list visibility is per-list. Public-list queries use the `public_lists` scope, backed by a `WHERE public = true` partial index.

## Key Files

| File | Purpose |
|------|---------|
| `db/migrate/20260422002612_create_user_lists_and_user_list_items.rb` | Schema |
| `app/models/user_list.rb` | Base STI class, shared behavior, `DEFAULT_SUBCLASSES`, abstract class methods |
| `app/models/music/albums/user_list.rb` | Music albums subclass |
| `app/models/music/songs/user_list.rb` | Music songs subclass |
| `app/models/games/user_list.rb` | Games subclass |
| `app/models/movies/user_list.rb` | Movies subclass |
| `app/models/user_list_item.rb` | Polymorphic join with position callbacks + type-compatibility validation |
| `app/models/user.rb` | `has_many :user_lists`, `after_create :create_default_user_lists`, `default_user_list_for` |
| `app/models/music/album.rb`, `music/song.rb`, `games/game.rb`, `movies/movie.rb` | Each declares `has_many :user_list_items, as: :listable` |

## Usage Examples

```ruby
# Every user gets defaults automatically on signup
user = User.create!(email: "new@example.com")
user.user_lists.count                         # => 12
user.default_user_list_for(Games::UserList, :favorites)
# => #<Games::UserList name: "Favorite Games" ...>

# Adding an item appends at the next position
fav_games = user.default_user_list_for(Games::UserList, :favorites)
fav_games.user_list_items.create!(listable: Games::Game.first)

# Type-compatibility is enforced
fav_games.user_list_items.create!(listable: Music::Album.first)
# => raises ActiveRecord::RecordInvalid: Listable type Music::Album is not compatible...

# Reordering
list = user.default_user_list_for(Music::Albums::UserList, :favorites)
list.reorder_items!([album3.id, album1.id, album2.id])

# Public lists
list.update!(public: true)
UserList.public_lists.where(user: user)
```

## Add-to-List Widget (02a)

The Add-to-List widget appears on every cached item index page (album / song / game cards) and item show page (album, song, game). It lets a signed-in user add or remove the item to/from any of their lists, and inline-create a new custom list, all without leaving the page.

### CloudFlare-Cache Safety

The cached HTML is identical for every visitor — the widget renders an anonymous-looking shell. All per-user state (and the CSRF token used for mutations) is loaded client-side from the uncached `/user_list_state` endpoint, then persisted in `localStorage` (CSRF token excepted — see below). Anonymous clicks open the existing `<dialog id="login_modal">`.

### Bulk State Endpoint

`GET /user_list_state` returns the signed-in user's lists + memberships scoped to `Current.domain`, plus a fresh per-session CSRF token:

```json
{
  "version": 1714234567,
  "domain": "music",
  "lists": [{ "id": 42, "type": "Music::Albums::UserList", "list_type": "favorites",
              "name": "Favorite Albums", "default": true, "icon": "heart" }],
  "memberships": { "Music::Album": { "101": [{ "list_id": 42, "item_id": 555 }] } },
  "csrf_token": "..."
}
```

- `version` is `current_user.updated_at.to_i`. `UserList` and `UserListItem` both `after_commit :touch_user`, so the version bumps whenever the user's list state changes.
- `memberships[type][id]` is an array of `{list_id, item_id}` tuples — the `item_id` is needed so the modal can DELETE a `UserListItem` on checkbox-uncheck without an extra round-trip.
- `csrf_token` is held in memory only by the `user-list-state` Stimulus controller. It is never written to localStorage. Mutations `await stateCtrl.ensureCsrf()` before firing, and concurrent callers share an in-flight refresh promise.

### CSRF Strategy (cache-safe)

The standard `<meta name="csrf-token">` flow is unsafe on CDN-cached HTML — every visitor sees the token belonging to whoever (or no one) rendered the cache. Instead:

1. `/user_list_state` is `Cache-Control: no-store, private` and returns `csrf_token: form_authenticity_token`.
2. The `user-list-state` controller stores the token in `this.csrf` (instance variable) — never persisted.
3. The modal's `_headers()` `await stateCtrl.ensureCsrf()`, which fetches once if no token is in memory.
4. `JsonErrorResponses` rescues `ActionController::InvalidAuthenticityToken` so a racey first-fire-before-fetch returns the standard `{error: {code: "forbidden", ...}}` JSON shape rather than a Rails HTML page.

### localStorage Schema Versioning

The `user-list-state` controller stamps every persisted shape with `_schema: <N>`. On hydrate, mismatched entries are discarded and a fresh `/user_list_state` fetch wins. Bump `STATE_SCHEMA` in `user_list_state_controller.js` whenever the persisted shape changes (e.g. memberships went from `[list_id]` to `[{list_id, item_id}]` for 02a → schema 2). The network response is always authoritative — `_doRefresh` always replaces the cache; the version field is for client-side optimistic-update bookkeeping only.

### Mutation Endpoints

| Verb | Path | Purpose |
|------|------|---------|
| `POST` | `/user_lists` | Create a custom list (server forces `list_type = :custom`); optional `listable_id` adds the item atomically. |
| `POST` | `/user_lists/:user_list_id/items` | Add an item to a list (owner-only). |
| `DELETE` | `/user_lists/:user_list_id/items/:id` | Remove an item from a list (owner-only). |

All four endpoints emit `Cache-Control: no-store, no-cache, must-revalidate, private` via the `Cacheable` concern. Errors use a uniform shape (`{error: {code, message, details?}}`) — codes: `unauthenticated`, `forbidden`, `not_found`, `validation_failed`, `conflict`. The `JsonErrorResponses` controller concern centralizes the rescues for `Pundit::NotAuthorizedError`, `ActiveRecord::RecordNotFound`, `ActiveRecord::RecordInvalid`, and `ActionController::InvalidAuthenticityToken`.

### Authorization

- `UserListPolicy#create?` → `user.present?`
- `UserListItemPolicy#create?` / `#destroy?` → `record.user_list.user_id == user.id`

`UserListItemsController` loads the parent list via `current_user.user_lists.find(...)` so non-owners get a 404 (existence-hiding) before any policy check.

### Stimulus Controllers

| Controller | Element | Responsibility |
|---|---|---|
| `user-list-state` | `<body>` (singleton) | Hydrates from `localStorage`, refreshes from `/user_list_state`, broadcasts `user-list-state:loaded` / `:updated` / `:cleared` events |
| `user-list-widget` | One per card | Renders icon strip and label from current state; opens login modal (anonymous) or dispatches `user-list-modal:open` (signed in) |
| `user-list-modal` | `<dialog id="user_list_modal">` (singleton) | Renders one row per list with checkbox; toggles call POST/DELETE endpoints; inline create form posts to `/user_lists` |
| `toast` | `#toast-region` (singleton) | Listens for `toast:show` events and appends transient alerts |

The state controller stores under `tg:user_list_state:<domain>` (per-domain bucket). Quota errors degrade to in-memory only.

### Icons

This spec adopts the [`rails_icons`](https://github.com/Rails-Designer/rails_icons) gem with the [Lucide](https://lucide.dev/) library project-wide. Server-side: `helpers.icon "heart", library: "lucide", class: "size-4"` (use `helpers.icon` inside ViewComponents). Client-side: each domain layout includes a hidden `<template id="user-list-icons">` (rendered by `app/views/shared/_user_list_icon_template.html.erb`) holding the union of icons used by every `list_type_icons` map (`heart`, `headphones`, `bookmark`, `check`, `trophy`, `gamepad-2`, `eye`, `plus`). The widget Stimulus controller clones nodes from this template by `data-icon` name, keeping the JS bundle small and reusing the exact same SVG output everywhere.

Per-subclass icon mapping lives in `self.list_type_icons` on each STI subclass. `:custom` is never in the icon map — custom lists collapse into a `+N` pill on the card.

### Naming Note

The ViewComponents live under `UserLists::*` (plural namespace) because `UserList` is itself a class — making it a module would conflict with the model. Stimulus controllers and Rails controllers keep the singular `user_list_*` naming.

### Stimulus Property Naming Hazard

The framework's `Controller` base class uses `this.context` internally for scope/targets resolution — every target getter ends up at `this.context.scope.targets`. Custom controllers must NOT assign `this.context = ...` (a 02a near-miss). Use any other property name (`this.openContext` here).

## What's Not In This Spec
- `/my/lists` dashboard, per-list show page, drag-and-drop, view modes, `completed_on` editing — all deferred to `user-lists-02c`.
- Public-list discovery, "consumed" badge upgrades — deferred to `user-lists-02d` (or folded into 02c).
- Dynamic community lists aggregated from user favorites — deferred to `user-lists-03`.
- `Books::UserList` — books item model doesn't exist yet; will be added when the books domain lands.

## Related Documentation
- `docs/specs/completed/user-lists-01-data-model.md` — originating spec
- `docs/specs/user-lists-02a-add-to-list-widget.md` — widget spec (this implementation)
- `docs/features/domain-scoped-authorization.md` — admin/editor role model (admin bypass is relevant here)
