# User Lists — Part 2 (Phase A): My Lists Dashboard & List Show (read-only)

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-04-20
- **Updated**: 2026-06-10
- **Completed**: 2026-06-10
- **Developer**: Shane Sherman (with Claude Code)

## Overview
Ship the **read-only** signed-in surface for user lists: a per-domain **`/my/lists` dashboard** and a **per-list show page** with three view modes (default / table / grid), position-vs-ranking sorting, CSV download, and a client-injected **"My Lists" nav link**. Completion dates (`completed_on`) are *displayed* read-only where present; *editing* them is Phase B.

Modeled on the user-lists UI in The Greatest Books app (`docs/old_site/user-lists-feature.md`), adapted to this stack (DaisyUI 5 / Tailwind 4, Pagy, per-domain layouts, CloudFlare CDN caching) and its multi-domain / multi-listable reality (the music domain has **both** album lists and song lists).

This is **Phase A** of the My Lists surface. **Phase B** (create / edit / drag-and-drop reorder / remove items / delete list / `completed_on` editing) is `docs/specs/user-lists-02f-list-management-and-editing.md`. The two were split to land safely in two PRs; Phase A delivers a useful, testable feature (users can browse their lists) with no SortableJS.

### Non-goals (Phase A)
- All write/management actions (create, edit, reorder, remove, delete, `completed_on` editing) → **Phase B** (`user-lists-02f`).
- Adding an item from within a list page (autocomplete) → `user-lists-02e`.
- Public discovery & viewing *other* users' public lists, "consumed" badge upgrades → `user-lists-02d` (future).
- Books domain (no `Books::Book` model yet) — the data layer works automatically once `Books::UserList` lands.

## Context & Links
- Predecessors:
  - `docs/specs/completed/user-lists-01-data-model.md` (data model + `reorder_items!`)
  - `docs/specs/completed/user-lists-02a-add-to-list-widget.md` (widget, JSON state/mutation endpoints, Stimulus state controller, icons, `UserLists::*` namespace)
- Successor (write surface): `docs/specs/user-lists-02f-list-management-and-editing.md`
- Feature doc (keep current): `docs/features/user-lists.md`
- Old-site reference (different stack, same UX intent): `docs/old_site/user-lists-feature.md`

### Authoritative source files to mirror
- Models: `web-app/app/models/user_list.rb`, `web-app/app/models/user_list_item.rb`, STI subclasses under `web-app/app/models/{music/albums,music/songs,games,movies}/user_list.rb`
- Existing controllers (pattern + refactor target): `web-app/app/controllers/user_list_state_controller.rb`, `web-app/app/controllers/user_lists_controller.rb`
- Concerns: `web-app/app/controllers/concerns/cacheable.rb`, `web-app/app/controllers/concerns/json_error_responses.rb`
- Auth helpers: `web-app/app/controllers/application_controller.rb` (`require_signed_in!`, `current_user`, `signed_in?`, `set_current_domain`, `user_not_authorized`)
- Pagy pattern: `web-app/app/controllers/music/albums/ranked_items_controller.rb`, `web-app/app/views/music/albums/lists/show.html.erb`
- Ranking config: `web-app/app/models/ranking_configuration.rb` (`default_primary`)
- Domain card components to reuse for views: `web-app/app/components/music/albums/card_component.rb` (`album:`), `web-app/app/components/music/songs/list_item_component.rb` (`song:`), `web-app/app/components/games/card_component.rb` (`game:`)
- Client state + nav-toggle precedent: `web-app/app/javascript/controllers/user_list_state_controller.js`, `web-app/app/javascript/controllers/authentication_controller.js` (`updateNavbarButton`)

## Pre-agreed design decisions (apply to Phase A **and** Phase B)
1. **Per-domain dashboard.** `/my/lists` is scoped to `Current.domain`. On `thegreatestmusic.org` it shows **both** album lists and song lists; games/movies show that domain's lists. Same domain→subclass resolution `UserListStateController` already uses.
2. **Global routes + `Current.domain` + dynamic layout.** A single `MyListsController` is routed globally (outside any `DomainConstraint`, alongside the 02a routes). It resolves `Current.domain` to the relevant `UserList` STI subclasses and selects the per-domain layout dynamically. Mirrors how all existing user-list endpoints work.
3. **Never cached.** Every action calls `prevent_caching` and renders an authenticated layout. Because the page is uncached and rendered for the signed-in user, the **standard `<meta name="csrf-token">` flow works** here (unlike the cached-page widget in 02a).
4. **Owner-only.** All `/my/lists` pages require sign-in and operate only on `current_user`'s lists. Non-owner access is 404 (controller scopes through `current_user.user_lists`). Viewing *other* users' public lists is `02d`.
5. **Three view modes**, persisted per-list via the existing `view_mode` enum (`default_view` / `table_view` / `grid_view`), changed by a query param on the show page and saved server-side when the owner switches (old-app pattern).
6. **`completed_on` is per-subclass.** Each STI subclass declares which `list_type`s support a completion date via `self.completed_on_list_types`, mirroring the `list_type_icons` pattern. In Phase A this only decides whether the date is *displayed*; editing is Phase B.

### Additional clarifications (resolved in spec review)
- **Duplicate custom-list names are permitted.** No uniqueness constraint on `name`; only `one_default_per_type_per_user` applies.
- **Dashboard always renders the default lists** (auto-created at signup), so there is no zero-lists empty state; individual lists may show "no items yet".
- **Widget state staleness is self-healing.** Nothing in Phase A mutates lists, so the 02a localStorage widget state is unaffected. (Phase B mutations rely on `after_commit :touch_user` + the next `/user_list_state` fetch — see 02f.)

---

## Interfaces & Contracts

### Domain Model (diffs only)

No migration (`view_mode`, `completed_on`, `position` already exist).

**`UserList` (base) — DRY domain→subclass resolver** (extract the mapping currently inline in `UserListStateController#list_subclasses_for` so both controllers share it):

```ruby
# reference only — web-app/app/models/user_list.rb
DOMAIN_SUBCLASSES = {
  "music"  => %w[Music::Albums::UserList Music::Songs::UserList],
  "games"  => %w[Games::UserList],
  "movies" => %w[Movies::UserList]
  # "books" => %w[Books::UserList]  # when it lands
}.freeze

def self.subclasses_for(domain)
  (DOMAIN_SUBCLASSES[domain.to_s] || []).map(&:constantize)
end
```
`Current.domain` is a **symbol** app-wide, hence the `.to_s` lookup.

**`UserList` (base) — completion-date capability (abstract; used Phase A for display, Phase B for editing)**

```ruby
# reference only — base returns [], subclasses override
def self.completed_on_list_types = []

def completed_on_enabled?
  self.class.completed_on_list_types.include?(list_type.to_sym)
end
```

| Subclass | `completed_on_list_types` |
|---|---|
| `Music::Albums::UserList` | `[:listened]` |
| `Music::Songs::UserList`  | `[]` |
| `Games::UserList`         | `[:played, :beaten]` |
| `Movies::UserList`        | `[:watched]` |
| `Books::UserList` (future)| `[:read]` |

**`UserList` — ranking-config resolution for the "sort by ranking" mode.** Each subclass that supports ranking declares its `RankingConfiguration` subclass; the base returns `nil` (no ranking sort). Resolve the primary config via `RankingConfiguration.default_primary` (`global.primary.first`, STI-scoped to the subclass).

```ruby
# reference only — base returns nil; subclasses override
def self.ranking_configuration_class = nil   # base
# Music::Albums::UserList -> Music::Albums::RankingConfiguration
# Music::Songs::UserList  -> Music::Songs::RankingConfiguration
# Games::UserList         -> Games::RankingConfiguration
# Movies::UserList        -> Movies::RankingConfiguration
```

**Required query shape (not "just mirror RankedItemsController").** `RankedItemsController` orders the *whole* table; a user list must order only the items it contains, with unranked items last:

```ruby
# reference only — show#ranking_sorted
config = list.class.ranking_configuration_class&.default_primary
return position_sorted_items if config.nil?            # graceful degrade
ids   = items.map(&:listable_id)
ranks = config.ranked_items.where(item_id: ids).pluck(:item_id, :rank).to_h
items.sort_by { |i| [ranks[i.listable_id] ? 0 : 1, ranks[i.listable_id] || 0] }
```
If `ranking_configuration_class` is `nil` **or** `default_primary` is `nil` (e.g. unseeded env/CI), the `?sort=ranking` option is hidden and the request degrades to `position` sort — never a 500.

### Endpoints

Global routes (outside any `DomainConstraint`), alongside the 02a routes in `web-app/config/routes.rb`.

| Verb | Path | Controller#Action | Purpose | Auth |
|------|------|-------------------|---------|------|
| GET | `/my/lists`     | `my_lists#index` | Per-domain dashboard of the user's lists | signed-in |
| GET | `/my/lists/:id` | `my_lists#show`  | Read-only list view (view modes, sort, `.csv`) | owner |
| GET | `/user_lists/:id` | `my_lists#show` | Compat alias for legacy books URLs (same owner-only show) | owner |

Route helpers: `my_lists_path`, `my_list_path(list)`, and the alias `user_list_path(list)`. CSV: `my_list_path(list, format: :csv, sort: ...)`. (Phase B adds `edit`/create/update/destroy + the item PATCH.) Both show entrypoints scope the lookup to **owner + current domain** (cross-domain id → 404).

**CSRF**: standard Rails `<meta name="csrf-token">` (pages are uncached).
**Caching**: every action calls `prevent_caching`.

### Schemas
Phase A has no JSON endpoints (HTML pages + CSV only). All JSON contracts are in Phase B (`02f`).

### Authorization (Pundit)

**`UserListPolicy`** (extend — 02a left these unimplemented):

| Action | Rule |
|---|---|
| `show?`  | `owner?` (owner only; `record.public?` viewing → 02d) |
| `Scope`  | `scope.where(user_id: user.id)` |

`owner?` ⇒ `record.user_id == user&.id`. Pass `policy_class: UserListPolicy` explicitly (STI subclasses otherwise resolve to `Music::Albums::UserListPolicy`). `create?` already exists from 02a; `update?`/`destroy?` are added in Phase B.

### Controllers

**`MyListsController` (new) — `web-app/app/controllers/my_lists_controller.rb`** (Phase A actions only)
- `< ApplicationController`; `include Pagy::Method`, `include Cacheable`.
- `layout :resolve_layout` → `"#{Current.domain}/application"` for `music`/`games`/`movies`. **Guard:** unrecognized hosts default `Current.domain` to `:books` (no layout yet) — fall back to `"music/application"` (or reject unsupported domains in a `before_action`) so it never references a nonexistent `books/application`.
- `before_action :require_signed_in!`, `before_action :prevent_caching`.
- `index`: `current_user.user_lists.where(type: UserList.subclasses_for(Current.domain).map(&:name))`, ordered defaults-first then custom; counts via a single grouped query (`group(...).count`), **not** `list.user_list_items.count` per row. Always renders default lists (no zero-state).
- `show`: load via `current_user.user_lists.find(params[:id])` (404 for non-owner); resolve `@sort` (`position` default | `ranking`) and `@view_mode` (param → persist when changed, old-app pattern); load `@list.user_list_items.ordered.includes(:listable)` with each listable's display associations eager-loaded; paginate with Pagy (`limit: 100`). `ranking` sort uses the query shape above (filtered to the list's `listable_id`s, unranked last; degrades to `position`). `respond_to` adds `:csv` (unpaginated).

**`UserListStateController` + `UserListsController` (refactor — in scope).** Both hold their own copy of the domain→subclass mapping (`UserListStateController#list_subclasses_for`, `UserListsController::ALLOWED_TYPES`). Replace both with the shared `UserList.subclasses_for` / `UserList::DOMAIN_SUBCLASSES` so validation can't drift. Update their existing (green) tests.

**CSV export (`show.csv`).** UTF-8 with a BOM prepended for Excel; filename `"#{list.name.parameterize}-#{Date.current.iso8601}.csv"`. Columns per listable type (the `Completed On` column appears only when `completed_on_enabled?`):

| Listable | Columns |
|---|---|
| `Music::Album` | Position, Title, Artists, Year, Completed On |
| `Music::Song`  | Position, Title, Artists, Year |
| `Games::Game`  | Position, Title, Year, Completed On |
| `Movies::Movie`| Position, Title, Year, Completed On |

### ViewComponents

Follow the sidecar convention + the **plural `UserLists::*` namespace** from 02a.

- **`UserLists::Dashboard::ListCardComponent`** — one card/row per list: name, item count, default-type icon (via `list_type_icons`) or "Custom" tag, public/private indicator, link to show. Args: `user_list:`, `item_count:`.
- **`UserLists::Show::ItemComponent`** — renders a single item for a given `view_mode` by **unwrapping `item.listable`** and passing it to the existing domain card component via that component's own kwarg (verified to exist): `Music::Albums::CardComponent.new(album: item.listable)`, `Music::Songs::ListItemComponent.new(song: item.listable)`, `Games::CardComponent.new(game: item.listable)`. (`ranked_item:`/`ranking_configuration:` are optional; omit — no rank display.)
  - `default_view` → the domain card/row in a single column.
  - `grid_view` → the domain card in a responsive grid.
  - `table_view` → a single generic DaisyUI `<table>` row shared across listables (columns per the CSV table: `#`, Title, By, Year, Completed (if `completed_on_enabled?`), actions slot). The show view renders the `<table>`/`<thead>` wrapper; rows come from this component.
  - **Phase A renders `completed_on` read-only** (a date/badge) where `completed_on_enabled?` and a value is present. **Phase B** adds the inline editor into this same component (default + table views; read-only badge in grid). Build the component so Phase B can drop the editor in without restructuring.
  Args: `item:`, `view_mode:`, `position:`.

### Stimulus Controllers (JavaScript)

No new dependency in Phase A (no SortableJS). Update the manifest with `bin/rails stimulus:manifest:update` if any controller is added.

**`user_list_state_controller.js` (extend)** — reveal the "My Lists" nav link. On connect/hydrate when signed in (`cookieUid()` present), unhide `#navbar_my_lists` (mobile + desktop menus); on `user-list-state:cleared` / `auth:signout`, hide it again. Keeps the navbar CDN-cacheable (link ships hidden, revealed client-side — exactly like the existing Login/Logout toggle).

### View / Layout changes

- **Each domain layout** (`web-app/app/views/layouts/{music,games,movies}/application.html.erb`): add `<li id="navbar_my_lists" class="hidden"><a href="/my/lists">My Lists</a></li>` to both the mobile dropdown and the desktop menu. No server-side `signed_in?` branch (ships hidden, revealed by the state controller). Note: `data-controller="user-list-state"`, `data-domain`, and the icon template are already present from 02a — only the `<li>` is new.
- **New views** under `web-app/app/views/my_lists/`: `index.html.erb`, `show.html.erb`, plus `show.csv` handling. Use the dynamic per-domain layout. Pagination uses the existing Pagy pattern (`<%== @pagy.series_nav %>`, guarded by `@pagy.pages > 1`, `querify:` carrying `sort`/`view_mode`).
- **Show toolbar (Phase A):** Download (CSV) only. Edit / Delete buttons and the Add-item slot are added in Phase B.

### Behaviors (pre/postconditions)

**Dashboard load**
- Pre: signed-in user visits `/my/lists` on a domain.
- Post: their lists for that domain render (defaults first w/ icons, then custom), each linking to its show page with an accurate count. Anonymous → redirected to `/` by `require_signed_in!`.

**View list / switch view mode / sort**
- Pre: owner opens `/my/lists/:id`.
- Post: items render in the saved `view_mode`, ordered by `position` (default) or by ranking when `?sort=ranking`. Switching view mode via the dropdown reloads with `?view_mode=...` and **persists** it on the list. Edge: empty list shows an empty state; `?sort=ranking` with no config degrades to `position` (option hidden); non-owner → 404.

**CSV download**
- Pre: owner clicks Download.
- Post: a BOM-prefixed CSV of the items (in the current sort) downloads with a sanitized filename.

**Nav link**
- Pre: signed-in user on any cached page.
- Post: the "My Lists" link appears once `user-list-state` detects sign-in (cookie); anonymous visitors never see it; cached HTML is identical for everyone.

### Non-Functionals
- **Auth/roles**: all `/my/lists` pages require sign-in; owner-only via `current_user.user_lists` scoping (404 for others).
- **Caching**: every action sets `Cache-Control: no-store, ... private` via `prevent_caching`. Navbar stays cacheable (link revealed client-side).
- **Performance / N+1**: dashboard counts via a single grouped query; show eager-loads `:listable` + each listable's display associations (e.g. albums → `:artists`, `:primary_image`) — verify zero N+1 on a 100-item list. Ranking sort resolves the config once. Pagy `limit: 100`; CSV unpaginated.
- **CSRF**: standard meta-token flow (uncached pages).

## Acceptance Criteria
- [ ] `GET /my/lists` (signed-in) lists only the current user's lists for `Current.domain` (music shows album **and** song lists), defaults-first then custom, with correct counts and no N+1.
- [ ] `GET /my/lists` (anonymous) redirects to `/` via `require_signed_in!`.
- [ ] `MyListsController` selects the correct per-domain layout from `Current.domain`, with a safe fallback for the books default.
- [ ] `GET /my/lists/:id` renders items in the saved `view_mode`; switching `?view_mode=` persists it and re-renders; all three modes (default/table/grid) render for albums, songs, and games.
- [ ] `?sort=ranking` orders items by the listable's primary ranking configuration (unranked last); `?sort=position` (default) orders by `position`; ranking degrades to position (and the option is hidden) when no config/primary exists.
- [ ] `GET /my/lists/:id` for a non-owner returns 404.
- [ ] `GET /my/lists/:id` (and the `/user_lists/:id` alias) for a list belonging to **another domain** returns 404 (scoped to owner + `Current.domain` subclasses) rather than rendering in the wrong layout.
- [ ] `completed_on` displays read-only on items of `completed_on_enabled?` lists; each STI subclass declares `self.completed_on_list_types` per the table.
- [ ] `UserList.subclasses_for(domain)` resolves domains→subclasses and is used by both `MyListsController`, the refactored `UserListStateController`, and `UserListsController` (replacing `ALLOWED_TYPES`); their existing tests still pass.
- [ ] Pundit: `UserListPolicy#show?` + `Scope` enforce owner-only (covered by policy tests).
- [ ] CSV download returns a BOM-prefixed file with per-listable columns and a `parameterize-date` filename.
- [ ] The "My Lists" nav link is hidden in cached HTML and revealed client-side when signed-in; hidden again on signout.
- [ ] All `/my/lists` responses carry `Cache-Control: no-store, ... private`.
- [ ] Existing suite green; new controller, policy, and model tests cover every server-side criterion above.

### Golden Examples

**Example 1 — music dashboard (two listables)**
```
1. Signed-in user visits https://thegreatestmusic.org/my/lists
2. index resolves Current.domain="music" → [Music::Albums::UserList, Music::Songs::UserList]
3. Renders "Favorite Albums" (heart), "Albums I've Listened To" (headphones),
   "Favorite Songs" (heart), then custom lists, each with a count.
4. Anonymous visiting the same URL is redirected to "/".
```

**Example 2 — view-mode persistence + ranking sort**
```
1. Owner opens /my/lists/42?view_mode=grid_view → list.view_mode saved as grid_view
2. Later opens /my/lists/42 (no param) → renders grid_view (persisted)
3. Clicks "Sort: Ranking" → /my/lists/42?sort=ranking&view_mode=grid_view
4. Items reorder by Music::Albums::RankingConfiguration.default_primary; unranked last
5. On a list whose subclass has no primary config, the Ranking option isn't shown;
   a direct ?sort=ranking falls back to position order (no error).
```

---

## Agent Hand-Off

### Constraints
- Mirror existing patterns: ViewComponents sidecar + `UserLists::*` namespace; Stimulus registered via `bin/rails stimulus:manifest:update`; Pundit per `application_policy.rb`; Pagy per `RankedItemsController` / `lists/show.html.erb`.
- No new gems or JS libraries in Phase A (SortableJS is Phase B).
- Do not build any write actions (create/edit/reorder/remove/delete/`completed_on` editing) — those are `02f`. `show?` stays owner-only (public viewing is `02d`).
- Reuse existing domain card components for default/grid; build the generic table once.
- Snippet budget ≤40 lines; no schema migration.

### Required Outputs
- New/modified files in "Key Files Touched".
- Minitest coverage for every server-side acceptance bullet (controller, policy, model, CSV, ranking sort + degrade, view-mode persistence, subclasses_for refactor).
- Manual visual verification of dashboard + all three view modes on music (albums **and** songs) and games on dev subdomains.
- Updated `docs/features/user-lists.md` (replace the `02c` references; document the dashboard/show read surface).
- Filled-in "Implementation Notes" and "Deviations" below.

### Sub-Agent Plan
1. `codebase-pattern-finder` → confirm Pagy usage, ViewComponent/Stimulus/Pundit patterns, the domain card components' public args.
2. `codebase-analyzer` → verify ranking-configuration resolution per listable + the domain→subclass mapping before wiring `subclasses_for` + sort-by-ranking.
3. `technical-writer` → update `docs/features/user-lists.md` and class docs post-implementation.

### Test Seed / Fixtures
- Reuse `web-app/test/fixtures/user_lists.yml` + `user_list_items.yml` (already include a `completed_on` example). Add fixtures only if a view-mode/ranking-sort case needs them; keep minimal.

---

## Implementation Notes (living)
- **Approach taken**: Followed the spec's prescribed architecture directly (it already fixed the file list, contracts, and pre-agreed decisions). Added the model-level capability methods to the `UserList` base + subclasses, extracted the shared `DOMAIN_SUBCLASSES`/`subclasses_for` resolver (collapsing the two duplicate maps in `UserListStateController` and `UserListsController`), added `MyListsController` (`index`/`show` + CSV), two `UserLists::*` ViewComponents, the two views, the policy `show?`/`Scope`, the nav-link reveal in the Stimulus state controller, and the hidden `<li>` in the music + games layouts.
- **Important decisions**:
  - **Movies/books UI deferred** per product-owner direction (only music + games are live). The cheap model-level methods for movies (`completed_on_list_types`, `ranking_configuration_class`) were still added (they're in the spec tables and the resolver references them), but no movies card/view work was done. `ItemComponent` falls back to the generic table row for any listable without a dedicated card, so movies/books render safely if ever routed.
  - **Per-listable layout via `ItemComponent.table_layout?`**: lists are homogeneous (one listable type), so the show view computes the wrapper (`<table>` vs grid `<div>`) once. Songs have only a `<tr>` component (no card), so song lists are always tabular; `default_view`/`grid_view` use the rich `Music::Songs::ListItemComponent` (with `show_index`), `table_view` uses the shared generic row.
  - **Pagy 43** auto-detects array vs relation in `pagy(collection, limit: 100)` and preserves `request.GET` params in page links, so position sort paginates the AR relation and ranking sort paginates the Ruby-sorted array with no `querify:` needed.
  - **`inverse_of`** added on `UserList#user_list_items` / `UserListItem#user_list` (the `order(:position)` scope disables Rails' automatic inverse detection) so the per-item `completed_on_enabled?` check in `ItemComponent` doesn't trigger an N+1.
  - **`csv` gem** added to the Gemfile — CSV left Ruby's default gems in 3.4, and `CSV.generate` is used for the export.
  - **`completed_on` display scope**: Phase A renders the read-only `completed_on` value in the generic table row + CSV column (gated by `completed_on_enabled?`). The reused domain card components (default/grid) are unmodified, so they don't show `completed_on` yet — Phase B adds the badge + inline editor there. See Deviations.
  - **E2E tests deferred**: per product-owner direction, Phase A ships Minitest + manual verification only (these pages are behind Firebase sign-in); Playwright E2E is a follow-up.

### Key Files Touched (paths only)
- `web-app/config/routes.rb` (`/my/lists`, `/my/lists/:id`, + `/user_lists/:id` alias)
- `web-app/app/controllers/my_lists_controller.rb` (new — `index`, `show`; show scoped to owner + domain)
- `web-app/app/controllers/user_list_state_controller.rb` (use `UserList.subclasses_for`)
- `web-app/app/controllers/user_lists_controller.rb` (replace `ALLOWED_TYPES` with the shared mapping)
- `web-app/app/models/user_list.rb` (`DOMAIN_SUBCLASSES`, `subclasses_for`, `completed_on_list_types`, `completed_on_enabled?`, `ranking_configuration_class`)
- `web-app/app/models/{music/albums,music/songs,games,movies}/user_list.rb` (overrides)
- `web-app/app/policies/user_list_policy.rb` (`show?`, `Scope`)
- `web-app/app/components/user_lists/dashboard/list_card_component.{rb,html.erb}`
- `web-app/app/components/user_lists/show/item_component.{rb,html.erb}`
- `web-app/app/views/my_lists/{index,show}.html.erb` (+ csv)
- `web-app/app/javascript/controllers/user_list_state_controller.js` (reveal nav link)
- `web-app/app/views/layouts/{music,games,movies}/application.html.erb` (hidden nav link)
- Tests under `web-app/test/{controllers,policies,models}/`

### Challenges & Resolutions
- **Pruned icon set**: the project only ships the Lucide icons it uses (`heart`, `headphones`, `bookmark`, `check`, `trophy`, `gamepad-2`, `eye`, `plus`). The dashboard card's original `"list"` fallback icon for custom lists wasn't in the set and raised "Icon not found". Resolved by omitting the icon for custom lists (they already carry a "Custom" badge); all default `list_type_icons` values are in the shipped set.
- **`csv` LoadError under Bundler**: `require "csv"` failed in the bundled test context because CSV is no longer a Ruby 3.4 default gem. Resolved by adding `gem "csv"` to the Gemfile.
- **HTML-escaped apostrophe in tests**: "Albums I've Listened To" renders as `I&#39;ve`, so the dashboard-order assertion matches on apostrophe-free fragments.
- **Post-implementation UI revision** (visual review): the original `default_view` reused the large domain cards in a single column, which blew up the cover images (full-width, especially portrait game art). Replaced it with a dedicated compact **list row** (small thumbnail + number/title-by heading + **description** + year/completed + widget), modeled on the old Greatest Books list view. `grid_view` keeps the cards. Songs have no covers and 0/72k have descriptions, so songs are now **table-only** — the view-mode switcher is hidden for them (`ItemComponent.card_capable?`). `ItemComponent` gained `include Music::DefaultHelper`/`Games::DefaultHelper` for the title links.
- **Code review** moved the per-listable eager-load map off the controller and onto each STI subclass as `self.listable_display_includes` (alongside `listable_class`/`ranking_configuration_class`), keeping `MyListsController` ignorant of per-domain associations (§5 skinny models). Declined two other suggestions: pre-existing `serialize_list` duplication (out of scope, untouched) and collapsing `DEFAULT_SUBCLASSES` into `DOMAIN_SUBCLASSES` (semantically distinct — defaults-at-signup vs domain-UI-routing — and will diverge when the books data layer precedes its layout).

#### Post-completion follow-ups (2026-06-10)
- **Show toolbar contrast (visual review)**: the sort (`Position/Ranking`) and view (`List/Table/Grid`) `join` groups were dark-on-dark and read as one undifferentiated bar, with the active item barely distinguishable. Reworked `my_lists/show.html.erb`: added `Sort`/`View` section labels, the selected button is now solid `btn-primary` (was a faint `btn-active`), unselected buttons are `btn-outline` so each reads as a button on the dark base, and `gap-x-6` separates the groups. Presentational only.
- **`/user_lists/:id` compatibility alias**: added a global `GET /user_lists/:id` route (`user_list_path`) pointing at the same owner-only `my_lists#show` action. The legacy Greatest Books site (and earlier Greatest sites) link to lists at `/user_lists/:id`; this keeps those URLs working once books migrates onto this app, with **no redirect** and no SEO loss. Distinct verb/path from the 02a `POST /user_lists` create and the nested `…/items` routes, so no conflict (verified via `recognize_path`). Preserving book PKs to make this safe is specced separately in `docs/specs/books-migration-01-id-range-reservation.md`.
- **Cross-domain leak fix (bug)**: `show` loaded the list scoped to the owner but **not** the domain, so manually entering a games list's id on the music host rendered it in the music layout. Fixed by scoping the lookup to the current domain's STI subclasses (`current_user.user_lists.where(type: UserList.subclasses_for(Current.domain).map(&:name)).find`); a cross-domain id now 404s, identical to the non-owner existence-hiding 404 (chosen over a cross-subdomain redirect for simplicity). Also protects the CSV path and the new alias, which share the same `@list` lookup.

### Deviations From Plan
| Planned | Delivered | Reason |
|---|---|---|
| Movies layout gets the hidden `My Lists` `<li>`; all three view modes verified for movies | Music + games only | Product owner: only music (albums/songs) + games are live; movies/books have no public UI. Model-level methods for movies were still added per the spec tables. |
| `completed_on` displayed read-only in default **and** table views | Displayed in the generic table row + CSV only | Default/grid reuse the unmodified domain card components, which have no `completed_on` slot. Adding one risks the public album/game pages and belongs with Phase B's inline editor. The read-only value still surfaces in table view + CSV, satisfying the acceptance bullet. |
| `MyListsController` may reject unsupported domains in a `before_action` | Falls back to `music/application` for unknown hosts | Simpler and matches the spec's primary suggestion; books has no layout, and the dashboard simply shows no lists there (`subclasses_for` returns `[]`). |
| E2E tests for the new pages (core-values §8.5) | Minitest + manual verification only | Product owner: pages are behind Firebase sign-in; Playwright E2E deferred to a follow-up. |

## Acceptance Results
- **Date**: 2026-06-10
- **Verifier**: Shane Sherman (with Claude Code)
- **Artifacts**:
  - Full suite: **4182 runs, 10930 assertions, 0 failures, 0 errors** (`bin/rails test`)
  - New coverage: `MyListsControllerTest` (26 — incl. the `/user_lists/:id` alias owner/non-owner cases and the cross-domain 404 + same-domain games render), `UserListPolicyTest` (+5), `UserListTest` (+6 for `subclasses_for`/`completed_on`/`ranking_configuration_class`), `UserLists::Show::ItemComponentTest` (6), `UserLists::Dashboard::ListCardComponentTest` (2); existing `UserListStateController`/`UserListsController` tests still green after the resolver refactor.
  - Linter: `bundle exec standardrb` clean on all changed files.
  - Every server-side acceptance bullet below is covered by a named test (dashboard scoping/order/counts/no-N+1, anon redirect, per-domain layout + books fallback, view-mode persistence, all three modes for albums/songs/games, ranking sort + unranked-last + degrade, non-owner 404, cross-domain 404, `/user_lists/:id` alias, `completed_on` display, `subclasses_for` refactor, policy `show?`/`Scope`, CSV BOM/columns/filename, `Cache-Control: no-store … private`).
  - CSS rebuilt (`yarn build:css:music`/`:games`) for the toolbar contrast utilities.
- **Manual visual verification**: pending on dev subdomains (requires rebuilding JS assets `yarn build` so the nav-link reveal is live).

## Future Improvements
- See `02f` (write surface), `02e` (add item from list page), `02d` (public discovery / badges).
- List-level drag reordering of the dashboard (uses `user_lists.position`).
- **Books migration prep** — reserve the low PK range on `users`/`user_lists` before importing the legacy books site so the `/user_lists/:id` alias resolves preserved book IDs without collision: `docs/specs/books-migration-01-id-range-reservation.md`.

## Related PRs
- _to be filled when the PR is opened_

## Documentation Updated
- [x] `docs/features/user-lists.md` — added the "My Lists Read Surface (02 Phase A)" section; replaced stale `02c` references with `02f`/`02d`/`02e`
- [x] Class docs — class-level comments on `MyListsController`, `UserLists::Dashboard::ListCardComponent`, `UserLists::Show::ItemComponent`, and the new `UserList`/policy methods (project convention is feature-level docs, not per-class files)
- [x] This spec — Implementation Notes, Deviations, Acceptance Results
