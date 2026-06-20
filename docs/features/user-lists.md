# User Lists

## Overview
User Lists are personal, ordered collections that logged-in users use to organize items they care about across the four media domains (music albums, music songs, games, movies). Each user automatically receives a predefined set of default lists (e.g. "Favorite Albums", "Games I've Played") on signup and can create an unlimited number of additional custom lists.

This feature corresponds to the `user-lists-01` spec (data model and core backend), the `user-lists-02a` spec (Add-to-List widget), and `user-lists-02` Phase A (the read-only `/my/lists` dashboard and per-list show page). Write/management actions (create, edit, drag-and-drop reorder, remove items, delete list, `completed_on` editing) are Phase B (`user-lists-02f`); public discovery of other users' lists is `user-lists-02d`.

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

## My Lists Read Surface (02 Phase A)

A signed-in, per-domain surface for browsing your own lists: a `/my/lists` dashboard and a `/my/lists/:id` show page with three view modes, position-vs-ranking sorting, and CSV download. Everything here is **read-only**; the write surface is Phase B (`user-lists-02f`).

### Routing & Layout

`MyListsController` is routed **globally** (outside any `DomainConstraint`), alongside the 02a endpoints:

| Verb | Path | Action | Auth |
|------|------|--------|------|
| GET | `/my/lists` | `my_lists#index` | signed-in |
| GET | `/my/lists/:id(.csv)` | `my_lists#show` | owner |
| GET | `/user_lists/:id` | `my_lists#show` (compat alias) | owner |

The `/user_lists/:id` route is a **compatibility alias** (`user_list_path`) for the same owner-only show action. The legacy Greatest Books site (and earlier Greatest sites) link to user lists at `/user_lists/:id`; this alias keeps those URLs working once books migrates onto this app. It's a distinct verb/path from the 02a `POST /user_lists` create and the nested `…/items` mutation routes, so there's no conflict. The canonical path remains `/my/lists/:id`; the show page renders its internal links with `my_list_path`.

It resolves `Current.domain` to the relevant STI subclasses via the shared `UserList.subclasses_for(domain)` and selects the per-domain layout dynamically (`layout :resolve_layout`). Unknown hosts (`Current.domain == :books`, no layout yet) fall back to `music/application`. Every action calls `prevent_caching`; because the pages are uncached and rendered for the signed-in user, the standard `<meta name="csrf-token">` flow works here (unlike the cached-page widget).

### Reserved ID Ranges (Books Migration)

The `/user_lists/:id` alias above resolves a list by its **raw primary key**, so the legacy Greatest Books URLs only keep working if book lists are imported with their **original IDs preserved**. To guarantee that without PK collisions, the low ID range on `users` and `user_lists` is reserved for the future books import:

| Table | Reserved for books (preserved IDs) | New-app rows (relocated + future) |
|---|---|---|
| `users` | `[1, 150_000)` | `>= 150_000` |
| `user_lists` | `[1, 1_000_000)` | `>= 1_000_000` |

The **per-table** ceilings live in `Services::BooksMigration::RESERVED_CEILINGS` (`app/lib/services/books_migration.rb`), reused by the migration and any future books ETL. The migration `db/migrate/20260612235510_reserve_books_id_ranges.rb` calls `Services::BooksMigration::IdRangeReservationService`, which (in one transaction) relocates any existing new-app rows up by their table's ceiling — remapping every FK that references `users`/`user_lists` (see `FOREIGN_KEYS` in the same file) — then bumps both sequences above their ceiling. It is idempotent (safe to re-run) and irreversible by design (restore from a snapshot to undo).

> **Tight ceilings:** these are only ~1.65–2.2× over the legacy books site's current `MAX(id)` (`user_lists` ~604k, `users` ~69k as of 2026-06). Books rows keep their original sub-ceiling IDs and the books site keeps growing, so **re-confirm both legacy `MAX(id)` values are still well under their ceiling immediately before the books import** and raise a ceiling if needed (zero cost on a bigint PK).

> **Schema-dump caveat:** `db/schema.rb` does **not** capture sequence `RESTART` values, so `db:schema:load` (CI, fresh dev DBs) starts the sequences at `1` again. This is acceptable — the reservation only needs to hold in **production** (and any environment that will receive the books import). Do not switch to `structure.sql` for this alone.

See `docs/specs/completed/books-migration-01-id-range-reservation.md` for the full rationale and acceptance criteria.

### Shared domain→subclass resolver

`UserList::DOMAIN_SUBCLASSES` + `UserList.subclasses_for(domain)` are the single source of truth for the domain→subclass mapping. `MyListsController`, `UserListStateController`, and `UserListsController` (`ALLOWED_TYPES`) all derive from it so the mapping can't drift. `Current.domain` is a Symbol app-wide, so the resolver does a `.to_s` lookup.

### Dashboard (`index`)

Lists the current user's lists for `Current.domain` (music shows **both** album and song lists), **defaults first** (in subclass then `list_type` order) then custom lists. Item counts come from a single grouped query (`UserListItem.where(...).group(:user_list_id).count`), never a per-row count. Default lists are auto-created at signup, so there is no zero-state. Each list renders as a `UserLists::Dashboard::ListCardComponent` (name, count, `list_type_icons` icon or "Custom" tag, public/private badge).

### Show (`show`)

Loads the list via `current_user.user_lists.where(type: UserList.subclasses_for(Current.domain).map(&:name)).find` — scoped to **both** the owner and the current domain's STI subclasses. A list belonging to another domain (e.g. a games list opened on the music host) 404s rather than rendering in the wrong layout; non-owner and cross-domain both hide existence via 404. It then renders the list's items in the persisted `view_mode`:

- **`default_view`** ("List") — a compact, full-width row per item: number + title-by-author heading, a small cover thumbnail, the item's **description**, a year/completed line, and the Add-to-list widget. Only for listables with covers/descriptions (albums, games).
- **`grid_view`** — the existing domain card (`Music::Albums::CardComponent`, `Games::CardComponent`) in a responsive grid.
- **`table_view`** — a single generic DaisyUI `<table>` row shared across listables.

`UserLists::Show::ItemComponent` unwraps `item.listable` and dispatches: card-capable listables render the list row (default) or the domain card (grid); songs render the rich `Music::Songs::ListItemComponent` row inside a table; anything else renders the generic table row. Its `self.table_layout?(listable_class:, view_mode:)` class method tells the show view which wrapper (`<table>` vs stacked `<div>` vs grid) to render — lists are homogeneous, so it's computed once.

**Songs are table-only.** Songs have no covers and (in practice) no descriptions, so they have no list/grid view; the view-mode switcher is hidden for them (`ItemComponent.card_capable?` is false) and they always render the song table. Sorting and CSV still apply.

Switching `?view_mode=` persists the choice on the list (`update!`). Items eager-load each listable's display associations (e.g. albums → `:artists, :categories, :primary_image`) to stay N+1-free; `belongs_to :user_list` sets `inverse_of` so per-item `completed_on_enabled?` checks don't re-query. Pagy paginates at `limit: 100` (Pagy 43 auto-detects array vs relation and preserves `sort`/`view_mode` in page links).

### Sorting (position vs ranking)

`?sort=position` (default) orders by `UserListItem#position`. `?sort=ranking` orders by the listable's primary ranking configuration, resolved once via `list.class.ranking_configuration_class&.default_primary`. Only the list's own `listable_id`s are looked up against `RankedItem` (`item_id`/`rank`); unranked items sort last. If the subclass has no `ranking_configuration_class` **or** no primary config exists (unseeded env), the Ranking option is hidden and a direct `?sort=ranking` degrades to `position` — never a 500.

### `completed_on` (read-only in Phase A)

Each STI subclass declares which `list_type`s support a completion date via `self.completed_on_list_types` (albums `[:listened]`, games `[:played, :beaten]`, movies `[:watched]`, songs `[]`), mirroring the `list_type_icons` pattern. `completed_on_enabled?` gates display. In Phase A the date renders read-only in the generic table row and the CSV `Completed On` column; the inline editor is Phase B.

### CSV export

`show.csv` streams a UTF-8 CSV with a BOM prefix (Excel-friendly) via `send_data`, filename `"#{list.name.parameterize}-#{Date.current.iso8601}.csv"`. Columns vary per listable (albums/songs: Position, Title, Artists, Year; games/movies: Position, Title, Year), with a `Completed On` column only when `completed_on_enabled?`. The CSV is unpaginated and follows the current sort.

### "My Lists" nav link

Each domain layout (music, games) ships a hidden `<li id="navbar_my_lists" class="hidden">` in both the mobile and desktop menus. The `user-list-state` Stimulus controller reveals it (and re-hides it on signout/401) at the same hook points where it detects sign-in — exactly like the Login/Logout toggle — so the navbar HTML stays identical for every visitor and CDN-cacheable.

### Naming Note

The ViewComponents live under `UserLists::*` (plural namespace) because `UserList` is itself a class — making it a module would conflict with the model. Stimulus controllers and Rails controllers keep the singular `user_list_*` naming.

### Stimulus Property Naming Hazard

The framework's `Controller` base class uses `this.context` internally for scope/targets resolution — every target getter ends up at `this.context.scope.targets`. Custom controllers must NOT assign `this.context = ...` (a 02a near-miss). Use any other property name (`this.openContext` here).

## What's Not Yet Implemented
- Write/management UI — create, edit, drag-and-drop reorder, remove items, delete list, `completed_on` editing — Phase B (`user-lists-02f`).
- Adding an item from within a list page (autocomplete) — `user-lists-02e`.
- Public-list discovery, viewing other users' public lists, "consumed" badge upgrades — `user-lists-02d`.
- Dynamic community lists aggregated from user favorites — `user-lists-03`.
- `Books::UserList` and a books layout — books item model doesn't exist yet; the read surface works automatically once `Books::UserList` lands.

## Related Documentation
- `docs/specs/completed/user-lists-01-data-model.md` — data-model spec
- `docs/specs/completed/user-lists-02a-add-to-list-widget.md` — widget spec
- `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` — My Lists read surface (Phase A, this implementation)
- `docs/specs/user-lists-02f-list-management-and-editing.md` — write surface (Phase B)
- `docs/features/domain-scoped-authorization.md` — admin/editor role model (admin bypass is relevant here)
