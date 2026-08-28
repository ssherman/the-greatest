# User Lists

## Overview
User Lists are personal, ordered collections that logged-in users use to organize items they care about across the four media domains (music albums, music songs, games, movies, books). Each user automatically receives a predefined set of default lists (e.g. "Favorite Albums", "Games I've Played") on signup and can create an unlimited number of additional custom lists.

This feature corresponds to the `user-lists-01` spec (data model and core backend), the `user-lists-02a` spec (Add-to-List widget), and `user-lists-02` Phase A (the read-only `/my/lists` dashboard and per-list show page). Write/management actions (create, edit, drag-and-drop reorder, remove items, delete list, `completed_on` editing) are Phase B (`user-lists-02f`); public discovery of other users' lists is `user-lists-02d`.

## Architecture

### Class Hierarchy (STI)
```
UserList                                 (base class, abstract)
├── Music::Albums::UserList              list_type: favorites, listened, want_to_listen, custom
├── Music::Songs::UserList               list_type: favorites, custom
├── Games::UserList                      list_type: favorites, played, beaten, want_to_play, currently_playing, custom
├── Movies::UserList                     list_type: favorites, watched, want_to_watch, custom
└── Books::UserList                      list_type: favorites, read, reading, want_to_read, custom

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
On `User.create`, an `after_create :create_default_user_lists` callback iterates over `UserList::DEFAULT_SUBCLASSES` and calls `find_or_create_by!` for every subclass's `default_list_types`. The result is **16 default lists** per new user:

| Subclass                   | Count | Types |
|----------------------------|-------|-------|
| `Music::Albums::UserList`  | 3     | favorites, listened, want_to_listen |
| `Music::Songs::UserList`   | 1     | favorites |
| `Games::UserList`          | 5     | favorites, played, beaten, want_to_play, currently_playing |
| `Movies::UserList`         | 3     | favorites, watched, want_to_watch |
| `Books::UserList`          | 4     | favorites, read, reading, want_to_read |

The callback only fires on signup, so `Services::UserLists::EnsureDefaults` fills the gap for
users created before a subclass joined `DEFAULT_SUBCLASSES`. `MyListsController#index` and
`UserListStateController#show` both pass it the lists they already loaded; it diffs against the
domain's `default_list_types`, creates only what's missing, and costs zero queries and zero writes
when the set is complete. It also repairs the ~145 missing default lists (19 `read` + 36 `reading`
+ 59 `want_to_read` + 31 `favorites`, some users missing more than one) that the migration
deliberately left short (`D-verbatim-defaults`).

Because fixture loading bypasses ActiveRecord callbacks, fixture users do NOT receive default lists automatically. Tests that rely on the callback must build users via `User.create!`.

### Position Management on `UserListItem`
- `before_create :set_position` — appends new items at the end (`max(position) + 1`).
- `after_destroy_commit :shift_positions_up` — decrements position for all siblings with a higher position, in a single SQL UPDATE, so positions stay contiguous.
- `scope :ordered, -> { order(:position) }` — explicit ordering scope; no `default_scope`.

Reordering is implemented via `UserList#reorder_items!(ordered_listable_ids)`, which requires the caller to pass **exactly** the current set of listable IDs (no additions, no removals) and applies the new positions inside a transaction.

### `manually_ordered` — does `position` mean anything?
`user_lists.manually_ordered` is a boolean (`default: false, null: false`, added by
`db/migrate/20260827060025_add_manually_ordered_to_user_lists.rb`). Every list has positions,
because `set_position` assigns them on create — but on most lists those positions record nothing
except the order the user happened to add things in. The flag separates the two cases:

- `false` — the positions are insertion order. Treat the list as an **unordered set**.
- `true` — the user actually arranged the list. The positions are a **ranking**.

The only consumer today is `Services::Lists::UserFavoritesTally` (see Generated Community Lists
below), which splits a ballot's weight evenly across an unordered list and positionally down a
manually ordered one. Nothing else reads it, and no UI writes it yet — Phase B's drag-and-drop
reorder is what will set it directly.

`Services::UserLists::BackfillManuallyOrdered` (`rake user_favorites_lists:backfill_manually_ordered`)
recovers the flag for legacy-imported favorites lists by comparing each list's position order
against its insertion order in one SQL statement. It only flips `false → true`, so it is safe to
re-run. Detection is deliberately one-directional: a user who added items in preference order and
never had to move anything is indistinguishable from one who appended carelessly, so the backfill
under-claims rather than inventing a ranking.

### Uniqueness Constraints
- **One copy of a given item per list** — DB-level `UNIQUE(user_list_id, listable_type, listable_id)` plus a model-level `validates :listable_id, uniqueness:`.
- **One default list per (user, type)** — enforced at the model level only (`one_default_per_type_per_user`), with no DB partial unique index. A plain `UNIQUE(user_id, type, list_type)` is not usable here because `custom` lists legitimately repeat, and each STI subclass assigns `custom` a different integer, so excluding them would mean hardcoding per-subclass enum values in SQL and migrating every time a domain is added.
  Since `Services::UserLists::EnsureDefaults` creates defaults on ordinary page views — not just at signup — the model validation alone cannot stop two concurrent first-visit requests from both inserting. It therefore takes a row lock on the owning user (`user.with_lock`) and re-derives what is missing inside that lock. The lock is only reached on the backfill path; once a user's set is complete the service returns before locking.

### Public vs Private
Each `UserList` has a `public` boolean (default false). Individual list visibility is per-list. Public-list queries use the `public_lists` scope, backed by a `WHERE public = true` partial index.

## Key Files

| File | Purpose |
|------|---------|
| `db/migrate/20260422002612_create_user_lists_and_user_list_items.rb` | Schema |
| `db/migrate/20260827060025_add_manually_ordered_to_user_lists.rb` | `user_lists.manually_ordered` |
| `app/lib/services/user_lists/backfill_manually_ordered.rb` | One-time backfill of `manually_ordered` from legacy item order |
| `app/models/user_list.rb` | Base STI class, shared behavior, `DEFAULT_SUBCLASSES`, abstract class methods |
| `app/models/music/albums/user_list.rb` | Music albums subclass |
| `app/models/music/songs/user_list.rb` | Music songs subclass |
| `app/models/games/user_list.rb` | Games subclass |
| `app/models/movies/user_list.rb` | Movies subclass |
| `app/models/books/user_list.rb` | Books subclass |
| `app/models/user_list_item.rb` | Polymorphic join with position callbacks + type-compatibility validation |
| `app/models/user.rb` | `has_many :user_lists`, `after_create :create_default_user_lists`, `default_user_list_for` |
| `app/lib/services/user_lists/ensure_defaults.rb` | Lazily backfills missing default lists for pre-existing users (see Default-List Bootstrap above) |
| `app/models/music/album.rb`, `music/song.rb`, `games/game.rb`, `movies/movie.rb`, `books/book.rb` | Each declares `has_many :user_list_items, as: :listable` |

## Usage Examples

```ruby
# Every user gets defaults automatically on signup
user = User.create!(email: "new@example.com")
user.user_lists.count                         # => 16
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

**Landmine:** `user_list_modal_controller.js` carries two hand-maintained per-domain maps,
`_matchesListable` and `_listClassFor`, that translate a listable's class name into modal-rendering
logic. Adding a new domain to `UserList::DOMAIN_SUBCLASSES` does **not** automatically teach the
modal about it — both maps need a new entry too. When books was wired in, they were left out; the
add-to-list modal silently rendered "No lists yet" for every books item, and nothing server-side
caught it (only an E2E spec did). Check both maps whenever a domain is added.

### Icons

This spec adopts the [`rails_icons`](https://github.com/Rails-Designer/rails_icons) gem with the [Lucide](https://lucide.dev/) library project-wide. Server-side: `helpers.icon "heart", library: "lucide", class: "size-4"` (use `helpers.icon` inside ViewComponents). Client-side: each domain layout includes a hidden `<template id="user-list-icons">` (rendered by `app/views/shared/_user_list_icon_template.html.erb`) holding the union of icons used by every `list_type_icons` map (`heart`, `headphones`, `bookmark`, `check`, `trophy`, `gamepad-2`, `eye`, `plus`, `book-open`). The widget Stimulus controller clones nodes from this template by `data-icon` name, keeping the JS bundle small and reusing the exact same SVG output everywhere.

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

The `/user_lists/:id` route is a **compatibility alias** (`user_list_path`) for the same show action (owner, or any viewer when the list is public, per `UserList.visible_to`). The legacy Greatest Books site (and earlier Greatest sites) link to user lists at `/user_lists/:id`; this alias keeps those URLs working once books migrates onto this app. It's a distinct verb/path from the 02a `POST /user_lists` create and the nested `…/items` mutation routes, so there's no conflict. The canonical path remains `/my/lists/:id`; the show page renders its internal links with `my_list_path`.

It resolves `Current.domain` to the relevant STI subclasses via the shared `UserList.subclasses_for(domain)` and selects the per-domain layout dynamically (`layout :resolve_layout`). Music, games, movies, and books each resolve to their own layout; an unrecognized host falls back to `music/application`. Every action calls `prevent_caching`; because the pages are uncached and rendered for the signed-in user, the standard `<meta name="csrf-token">` flow works here (unlike the cached-page widget).

### Reserved ID Ranges (Books Migration)

The `/user_lists/:id` alias above resolves a list by its **raw primary key**, so the legacy Greatest Books URLs only keep working if book lists are imported with their **original IDs preserved**. To guarantee that without PK collisions, the low ID range on `users` and `user_lists` is reserved for the future books import:

| Table | Reserved for books (preserved IDs) | New-app rows (relocated + future) |
|---|---|---|
| `users` | `[1, 150_000)` | `>= 150_000` |
| `user_lists` | `[1, 1_000_000)` | `>= 1_000_000` |
| `lists` | `[1, 10_000)` | `>= 10_000` |

`lists` was reserved in a later migration (`db/migrate/*_reserve_lists_id_range.rb`) so legacy `/lists/:id` URLs keep resolving after import. Its ceiling (`10_000`) must exceed the **new-app** `lists` `MAX(id)` at run time (the relocation is an additive shift, collision-free only when all rows are below the ceiling) — re-confirm before running in production. The reservation also remaps the one **polymorphic** reference to lists, `ai_chats.parent` (`parent_type = 'List'`), which has no FK. See `docs/superpowers/plans/2026-07-03-lists-id-range-reservation.md`.

The **per-table** ceilings live in `Services::BooksMigration::RESERVED_CEILINGS` (`app/lib/services/books_migration.rb`), reused by the migration and any future books ETL. The migration `db/migrate/20260612235510_reserve_books_id_ranges.rb` calls `Services::BooksMigration::IdRangeReservationService`, which (in one transaction) relocates any existing new-app rows up by their table's ceiling — remapping every FK that references `users`/`user_lists` (see `FOREIGN_KEYS` in the same file) — then bumps both sequences above their ceiling. It is idempotent (safe to re-run) and irreversible by design (restore from a snapshot to undo).

> **Tight ceilings:** these are only ~1.65–2.2× over the legacy books site's current `MAX(id)` (`user_lists` ~604k, `users` ~69k as of 2026-06). Books rows keep their original sub-ceiling IDs and the books site keeps growing, so **re-confirm both legacy `MAX(id)` values are still well under their ceiling immediately before the books import** and raise a ceiling if needed (zero cost on a bigint PK).

> **Schema-dump caveat:** `db/schema.rb` does **not** capture sequence `RESTART` values, so `db:schema:load` (CI, fresh dev DBs) starts the sequences at `1` again. This is acceptable — the reservation only needs to hold in **production** (and any environment that will receive the books import). Do not switch to `structure.sql` for this alone.

See `docs/specs/completed/books-migration-01-id-range-reservation.md` for the full rationale and acceptance criteria.

### Shared domain→subclass resolver

`UserList::DOMAIN_SUBCLASSES` + `UserList.subclasses_for(domain)` are the single source of truth for the domain→subclass mapping. `MyListsController`, `UserListStateController`, and `UserListsController` (`ALLOWED_TYPES`) all derive from it so the mapping can't drift. `Current.domain` is a Symbol app-wide, so the resolver does a `.to_s` lookup. `UserList::DOMAIN_SUBCLASSES` covers all four domains; `subclasses_for` returns `[]` only for an unrecognized host.

### Dashboard (`index`)

Lists the current user's lists for `Current.domain` (music shows **both** album and song lists), **defaults first** (in subclass then `list_type` order) then custom lists. Item counts come from a single grouped query (`UserListItem.where(...).group(:user_list_id).count`), never a per-row count. Default lists are auto-created at signup, so there is no zero-state. Each list renders as a `UserLists::Dashboard::ListCardComponent` (name, count, `list_type_icons` icon or "Custom" tag, public/private badge).

### Show (`show`)

Loads the list via `UserList.where(type: UserList.subclasses_for(Current.domain).map(&:name)).visible_to(current_user).find` — scoped to the current domain's STI subclasses, with visibility (owner or public) delegated to `visible_to` (see "Public list viewing (direct link)" below). A list belonging to another domain (e.g. a games list opened on the music host) 404s rather than rendering in the wrong layout; a private list belonging to someone else 404s the same way, hiding existence either way. It then renders the list's items in the persisted `view_mode`:

- **`grid_view`** — the existing domain card (`Music::Albums::CardComponent`, `Games::CardComponent`, `Books::CardComponent`) in a responsive grid. This is the default for new lists.
- **`list_view`** ("List") — a compact, full-width row per item: number + title-by-author heading, a small cover thumbnail, the item's **description**, a year/completed line, and the Add-to-list widget. Only for listables with covers/descriptions (albums, games, books).
- **`table_view`** — a single generic DaisyUI `<table>` row shared across listables.

`UserLists::Show::ItemComponent` unwraps `item.listable` and dispatches: card-capable listables render the list row (default) or the domain card (grid); songs render the rich `Music::Songs::ListItemComponent` row inside a table; anything else renders the generic table row. Its `self.table_layout?(listable_class:, view_mode:)` class method tells the show view which wrapper (`<table>` vs stacked `<div>` vs grid) to render — lists are homogeneous, so it's computed once.

**Songs are table-only.** Songs have no covers and (in practice) no descriptions, so they have no list/grid view; the view-mode switcher is hidden for them (`ItemComponent.card_capable?` is false) and they always render the song table. Sorting and CSV still apply.

Switching `?view_mode=` persists the choice on the list (`update!`). Items eager-load each listable's display associations (e.g. albums → `:artists, :categories, :primary_image`) to stay N+1-free; `belongs_to :user_list` sets `inverse_of` so per-item `completed_on_enabled?` checks don't re-query. Pagy paginates at `limit: 100` (Pagy 43 auto-detects array vs relation and preserves `sort`/`view_mode` in page links). New lists default to `grid_view`; the 2026-08-02 migration moved every list still holding the old list-view default onto it.

### Sorting (position vs ranking)

`?sort=position` (default) orders by `UserListItem#position`. `?sort=ranking` orders by the listable's primary ranking configuration, resolved once via `list.class.ranking_configuration_class&.default_primary`. Only the list's own `listable_id`s are looked up against `RankedItem` (`item_id`/`rank`); unranked items sort last. If the subclass has no `ranking_configuration_class` **or** no primary config exists (unseeded env), the Ranking option is hidden and a direct `?sort=ranking` degrades to `position` — never a 500.

### `completed_on` (read-only in Phase A)

Each STI subclass declares which `list_type`s support a completion date via `self.completed_on_list_types` (albums `[:listened]`, games `[:played, :beaten]`, movies `[:watched]`, songs `[]`, books `[:read]`), mirroring the `list_type_icons` pattern. `completed_on_enabled?` gates display. In Phase A the date renders read-only in the generic table row and the CSV `Completed On` column; the inline editor is Phase B.

### CSV export

`show.csv` streams a UTF-8 CSV with a BOM prefix (Excel-friendly) via `send_data`, filename `"#{list.name.parameterize}-#{Date.current.iso8601}.csv"`. Columns vary per listable (albums/songs: Position, Title, Artists, Year; books: Position, Title, Authors, Year, via `Books::Book#first_published_year`; games/movies: Position, Title, Year), with a `Completed On` column only when `completed_on_enabled?`. The CSV is unpaginated and follows the current sort.

### "My Lists" nav link

Each domain layout (music, games) ships a hidden `<li id="navbar_my_lists" class="hidden">` in both the mobile and desktop menus. The `user-list-state` Stimulus controller reveals it (and re-hides it on signout/401) at the same hook points where it detects sign-in — exactly like the Login/Logout toggle — so the navbar HTML stays identical for every visitor and CDN-cacheable.

### Naming Note

The ViewComponents live under `UserLists::*` (plural namespace) because `UserList` is itself a class — making it a module would conflict with the model. Stimulus controllers and Rails controllers keep the singular `user_list_*` naming.

### Public list viewing (direct link)

`MyListsController#show` is viewer-aware. `UserList.visible_to(current_user)` returns the viewer's
own lists plus anyone's public lists; anything else falls out of the scope and 404s, which hides
existence. (Pundit's `NotAuthorizedError` rescue redirects with a flash, so the check cannot live in
the policy alone — `UserListPolicy#show?` mirrors the rule as defense in depth.) `require_signed_in!`
applies to `index` only.

Owner-gated on `@owner`: the add-item box, the "My Lists" backlink, and `view_mode` persistence — a
non-owner's `?view_mode=` changes only their own render. Sorting, pagination, CSV, and the per-item
Add-to-list widget are available to everyone.

Non-owners see "A list by <display_name>" when the owner has one, and nothing when they don't (only
12 of 88 public-list owners do, as of this writing). `email` and `name` are never rendered. Pages set `@indexable = false`
(`noindex, follow` via the books layout) and keep `prevent_caching` — the HTML is owner-aware, so
edge-caching it would serve one viewer's toolbar to another.

Legacy `GET /user_lists`, `/user_lists/new`, and `/user_lists/:id/edit` 301 to the read pages.

Still unbuilt: a public-list **discovery** index and "consumed" badges.

### Stimulus Property Naming Hazard

The framework's `Controller` base class uses `this.context` internally for scope/targets resolution — every target getter ends up at `this.context.scope.targets`. Custom controllers must NOT assign `this.context = ...` (a 02a near-miss). Use any other property name (`this.openContext` here).

## Generated Community Lists (`user-lists-03`)

Every night, each domain's favorites `UserList`s are tallied into a single editorial `List` that
feeds the ranking engine exactly like a hand-curated list. Users vote by keeping a favorites list;
they never edit the generated list.

**Scoring.** `Services::Lists::UserFavoritesTally` treats each user's favorites list as one ballot
worth `√N` points in total (N = its item count), so a 250-item list counts for more than a 5-item
one without counting 50× more. That mass is then split across the ballot's items: evenly when
`manually_ordered` is false, and by position (`(N − index) ** decay_exponent`, normalised) when it
is true. Both branches sum to the same total, so curating a list changes *where* a user's influence
lands and never *how much* they get. Items below `min_voters` distinct voters are dropped and the
result is truncated to `max_items`; both come from `Rails.application.config.x.user_favorites_list`
and are tuned in Rails config, not in an admin screen. Voters are counted as a set of user ids, not
a ballot count, because a user can end up holding two favorites lists.

**Persistence.** `Services::Lists::GenerateUserFavorites` writes the tally into the domain's
generated `List` with `delete_all` + `insert_all`, and sets `number_of_voters` to the real ballot
count. It finds the list by `(type, auto_generated_kind)` — never by name, which is what broke the
legacy implementation the first time someone renamed one.

**Self-wiring on create.** A domain's list is created `active`, and on **create only** is joined to
its domain's `ranking_configuration_class.default_primary` via a `RankedList` and given the global
penalty named `"Voters: not critics, authors, or experts"` (looked up by name — the id differs per
environment). It is created active because a domain with no favorites data produces an *empty* list,
which contributes nothing to rankings whatever its status; there was nothing to protect against by
starting it switched off, and the manual flip had to be redone after every environment rebuild.

The penalty is load-bearing, not cosmetic: without it the list computes at roughly weight 100, which
would make a list of user votes one of the heaviest in a corpus of critic-authored lists. It only
carries a value if the penalty has a `PenaltyApplication` for that ranking configuration —
`Rankings::WeightCalculatorV1#calculate_static_penalties_with_details` skips a penalty with no
application — and creating that application is an editorial decision the generator deliberately
leaves alone. A newly created `RankedList` has `weight: nil` until a weight calculation runs, so the
generator queues `BulkCalculateWeightsJob` for the configuration it just joined.

Both wiring steps degrade to a logged no-op rather than raising: a domain with no primary ranking
configuration is a legitimate not-yet-configured state, and a missing penalty logs a warning naming
the weight consequence. Wiring is create-only (`previously_new_record?`), so an admin who
deliberately detaches the list or drops its penalty does not have that undone on the next nightly run.

**Identity and ownership.** `lists.auto_generated_kind` is a nullable integer enum
(`enum :auto_generated_kind, {user_favorites: 0}, prefix: :generated`) with a partial unique index
on `(type, auto_generated_kind) WHERE auto_generated_kind IS NOT NULL` — one generated list per
domain. `List#auto_generated?` is the predicate everything else gates on.

**Hand edits are refused,** because the generator rewrites these rows nightly and anything typed in
would vanish on the next run:

| Layer | Guard |
|---|---|
| `ListItem` create/update | `list_must_not_be_auto_generated` validation |
| `ListItem` destroy | `before_destroy :prevent_destroy_when_auto_generated`, raising `ListItem::AutoGeneratedListItemError` |
| `List` destroy | `before_destroy :prevent_destroy_when_auto_generated`, raising `List::AutoGeneratedListError` |
| Admin | items table hides edit/delete; show page hides Add / Delete All Items / Delete All Positions / Delete list, and badges the list "Auto-generated" |
| `Admin::ListItemsController#clear_positions` | explicit `auto_generated?` check — `update_all` skips callbacks and validations, so nothing else would stop it |
| Record mergers (games, albums, songs) | `merge_list_items` skips auto-generated lists; the merge has already moved the underlying user favorites |

Two deliberate exemptions: the generator itself writes through `delete_all` / `insert_all`, which
skip callbacks and validations, so it needs no escape hatch; and `ListItem#prevent_destroy_when_auto_generated`
returns early when `destroyed_by_association` is set, because `ListItem` is the dependent of **five**
owners (`List` plus `Books::Book`, `Music::Album`, `Music::Song`, `Games::Game` as `listable`) and
raising for all of them would make any record that appears on a generated list undeletable. The
generated list itself is protected one level up, on `List`.

Neither error subclasses `ActiveRecord::RecordNotDestroyed`: `ActiveRecord::Callbacks#destroy`
rescues that class specifically and converts it to a `false` return, which `#destroy` and
`Relation#destroy_all` then swallow silently.

`auto_generated_kind` is **not** in `Admin::ListsBaseController#permitted_params` — clearing the
flag is a console job on purpose.

**Jobs and tasks.**

| Entry point | Purpose |
|---|---|
| `GenerateUserFavoritesListsJob` | Nightly, from `config/schedule.yml`. Rebuilds every domain, collecting per-domain failures so one bad domain doesn't skip the rest. Deliberately does **not** recalculate rankings — that stays on the deliberate admin refresh. |
| `rake user_favorites_lists:generate[Books::UserList]` | Manual rebuild, one domain or all |
| `rake user_favorites_lists:backfill_manually_ordered` | One-time `manually_ordered` backfill |
| `rake user_favorites_lists:rebuild` | Everything, in the one order that works: backfill `manually_ordered`, delete any surviving legacy list, regenerate every domain. Idempotent, safe in any environment, and appended to `data_migration:all` so a books import leaves the generated lists correct with no follow-up commands. |

`rebuild` replaced a one-time `adopt_legacy_books_list` task that renamed the legacy books top-100
in place and flagged it as the generated list. Adoption failed twice in practice: it hit the
`(type, auto_generated_kind)` unique index whenever a generated list already existed, and its own
guard was single-use, because the first run destroyed the pre-rename name the guard looked itself up
by. `Services::BooksMigration::ListMigrator` now excludes the three superseded legacy lists
(`SUPERSEDED_LIST_NAMES`) from the import outright, so nothing is left to adopt. The three migrators
keyed to lists — `ListItemMigrator`, `RankedListMigrator`, `ListPenaltyMigrator` — **skip** a row
whose list was not imported rather than raising; each keeps a "you forgot `data_migration:lists`"
guard by failing loud when *no* `Books::List` exists at all.

`rebuild` scopes its deletion by `auto_generated_kind: nil`, never by excluding a remembered id.
One of the three retired names is exactly `::Books::UserList.generated_list_name`, so a name match
alone would take the generated list with it.

Design detail lives in `docs/superpowers/specs/2026-08-27-ranked-users-lists-design.md`.

## What's Not Yet Implemented
- Write/management UI — create, edit, drag-and-drop reorder, remove items, delete list, `completed_on` editing — Phase B (`user-lists-02f`).
- Adding an item from within a list page (autocomplete) — `user-lists-02e`.
- Public-list **discovery** (a browsable index of public lists) and "consumed" badge upgrades —
  the remainder of `user-lists-02d`. Direct-link viewing of a public list shipped with the books
  UI work; see `docs/superpowers/specs/2026-08-02-books-user-lists-ui-design.md`.

## Related Documentation
- `docs/specs/completed/user-lists-01-data-model.md` — data-model spec
- `docs/specs/completed/user-lists-02a-add-to-list-widget.md` — widget spec
- `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md` — My Lists read surface (Phase A, this implementation)
- `docs/specs/user-lists-02f-list-management-and-editing.md` — write surface (Phase B)
- `docs/features/domain-scoped-authorization.md` — admin/editor role model (admin bypass is relevant here)
- `docs/superpowers/specs/2026-08-02-books-user-lists-ui-design.md` — books UI wiring + public viewing
- `docs/superpowers/specs/2026-08-27-ranked-users-lists-design.md` — generated community lists (`user-lists-03`)
- `docs/features/rankings.md` — how the generated list is weighted once it reaches the ranking engine
