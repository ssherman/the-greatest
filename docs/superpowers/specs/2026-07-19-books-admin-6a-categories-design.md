# Books admin — increment 6a: Categories CRUD + category tagging + shared-controller domain-auth fix

**Status:** design approved 2026-07-19, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 6,
"Categories, Lists, Ranking configurations"; decisions D2/D3, the shared-admin de-fork table).
**Predecessors:** 4a (`Books::Book`), 5a (`Books::Author`) — both built the show pages this increment
tags; 4a's `Admin::Games::GamesController` and games categories are the direct mirrors.
**Split:** increment 6 is shipped as two PRs (owner call, 2026-07-19). **6a = Categories** (this doc).
**6b = Lists + Ranking configurations + the `calculate_books_year_range` fix (D8)** — its own design doc.

## Goal

A full `Books::Category` admin at `/admin/categories` on the books host, and category tagging wired
onto the **book and author** show pages. Plus — per owner's call — the cross-domain fix that lets a
domain-only editor (books/games/music alike) manage categories and images, closing the gap Codex
flagged on PR #169 and #172.

Categories were deliberately deferred out of 4a/5a because the shared `AddCategoryModalComponent`
silently falls back to the **music** category search for any domain whose `categories_search_path` is
unset — tagging a book with a music genre (STI `categories` table, no per-type validation). 6a closes
that path for books before lighting up the UI.

## Scope

**In:**
- **`Books::Category` CRUD** — thin subclass of `Admin::CategoriesBaseController` (mirrors
  `Admin::Games::CategoriesController`, ~15 lines). Index/show/new/create/edit/update/destroy + a JSON
  `search` collection action (all inherited from the base). The base already paginates (`pagy limit:
  25`) and filters (`search_by_name`), so 73,913 rows scale unchanged.
- **Category tagging on the book show page** — a categories card (the `category_items_list` frame +
  `AddCategoryModalComponent`) riding the already-de-forked shared `Admin::CategoryItemsController`.
- **Category tagging on the author show page** — same card; `Books::Author` also has a `categories`
  association (mirrors music's artist + album both carrying categories).
- **Two registry values that unblock safe tagging** — `ENTITIES[...][:category_items_path]` for
  `Books::Book`/`Books::Author` (fixes the modal `form_url`), and `CONFIGS[:books]
  [:categories_search_path]` (fixes the modal `search_url` — the music-genre bug).
- **Shared-controller domain-auth fix** — `Admin::CategoryItemsController` and `Admin::ImagesController`
  gain `Admin::DomainScopedAuth`, resolving the domain from their **parent record** so domain-only
  editors can manage them within their own domain (and are denied cross-domain). Cross-cutting: applies
  to all three domains at once.
- **`DomainNav` "Categories" item**, Minitest coverage, and a Playwright smoke spec.

**Out / not applicable:**
- **No lists, no ranking-configs, no `calculate_books_year_range` fix** — all 6b.
- **No `category_type` restriction** — the shared enum carries games-only values (`game_mode`,
  `player_perspective`); the form shows them exactly as games' form does. Restricting is gold-plating.
- **No category tree view** — the index is the flat, paginated, searchable table games/music use, even
  though `categories.parent_id` exists. Matches the base controller as-is.
- **No importer** — the admin remains the only editor of category assignments; nothing bulk-creates.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 6a-1 | Ship 6a (categories) separately from 6b (lists + RCs + year-range). | Categories is the meaty de-fork (two show-page sections, the modal, two registry tables, a nav-test re-point, plus the cross-domain auth fix). Lists and RCs are genuinely thin coupled subclasses. Splitting isolates the risk. |
| 6a-2 | Wire the categories card onto the **author** show page too, not just the book page. | `Books::Author` has the `categories` association (like music's `Music::Artist`). Including it is parity + near-zero cost; the section is simply empty until an author is curated. |
| 6a-3 | Fix the `AddCategoryModalComponent` music-fallback by setting `CONFIGS[:books][:categories_search_path]` and both `ENTITIES` `category_items_path`s — no component change. | The component already keys `search_url` off `DomainNav.config_for(domain_for(item))` and `form_url` off `DomainRouting.category_items_path_for(item)`. Both read registry values that are currently `nil` for books. Two data edits, not new code. |
| 6a-4 | Fix the shared-controller domain-auth gap **in 6a**, for all three domains, via a `domain_auth_parent` hook on the `DomainScopedAuth` concern. | Owner's call (2026-07-19). 6a is the increment that lights up books category tagging, so it is the natural home. The hook keeps every existing `DomainScopedAuth` consumer unchanged (they don't define `domain_auth_parent` → the concern falls back to `current_domain`). |
| 6a-5 | `domain_auth_parent` resolves the parent **independently of `set_parent`/`set_image`** — from `params[:id]`'s record on shallow actions, from `parent_from_params` on nested ones. | `authenticate_admin!` is a parent-class `before_action`; it runs **before** the subclass's `set_parent`/`set_image`, so `@parent`/`@image` are not yet set at auth time. |
| 6a-6 | Books category views are their own files under `admin/books/categories/`, copied from `admin/games/categories/`. | The base controller resolves views by the subclass's controller path (`admin/books/categories/index`). Games already keeps per-domain view copies; books mirrors that (no shared view exists to reuse). |

## The models (already exist — no schema changes)

- **`Books::Category < ::Category`** — STI on the `categories` table (`type` column). Shared columns:
  `name`* , `description`, `category_type` (enum `{genre:0, location:1, subject:2, theme:3, game_mode:4,
  player_perspective:5}`, default `genre`), `parent_id` (self-FK, optional), `alternative_names` (array),
  `item_count`, `slug`, `deleted` (soft-delete). Books subclass adds `has_many :books` and
  `has_many :authors` through `category_items` (`source_type`-scoped), plus `by_book_ids`/`by_author_ids`
  scopes. `active` scope (not `deleted`), `search_by_name`, `soft_delete!` all inherited.
- **`CategoryItem`** — polymorphic `belongs_to :item` + `belongs_to :category`. `Books::Book` and
  `Books::Author` each `has_many :category_items, as: :item` + `categories, through:`. Already present;
  1.8M rows exist on books.
- **`Books::CategoryPolicy`** — already exists (built in inc 3, trivial `ApplicationPolicy` subclass,
  `domain = "books"`).

## The de-fork mechanism (why two data values are enough)

`Admin::AddCategoryModalComponent`:

```ruby
def form_url
  Admin::DomainRouting.category_items_path_for(@item)          # reads ENTITIES[class][:category_items_path]
end

def search_url
  Admin::DomainNav.config_for(Admin::DomainRouting.domain_for(@item))&.dig(:categories_search_path) ||
    helpers.search_admin_categories_path                       # ← MUSIC fallback when books' is nil
end
```

The shared `Admin::CategoryItemsController` is **already** de-forked (inc 1): `set_item` uses
`Admin::DomainRouting.parent_from_params(params, domain: current_domain)` and `redirect_path` uses
`Admin::DomainRouting.path_for(@item)`. `NESTED_PARENTS[:books]` already maps `book_id`/`author_id`. So
tagging works end-to-end once the two registry values are set and the nested routes exist.

## Shared-controller domain-auth fix

Both `Admin::CategoryItemsController` and `Admin::ImagesController` currently inherit
`Admin::BaseController#authenticate_admin!` (global-admin/editor only). Fix:

1. **`Admin::DomainScopedAuth`** — teach `domain_for_auth` to consult a per-controller parent hook:

   ```ruby
   def domain_for_auth
     if respond_to?(:domain_auth_parent, true) && (parent = domain_auth_parent)
       Admin::DomainRouting.domain_for(parent)&.to_s
     else
       current_domain&.to_s
     end
   end
   ```

   Every current consumer (games/music/books entity controllers, the RC controllers) does **not**
   define `domain_auth_parent`, so they keep the exact `current_domain` behavior — behavior-neutral for
   them.

2. **`Admin::CategoryItemsController`** — `include Admin::DomainScopedAuth`; define
   `domain_auth_parent` = `params[:id].present? ? CategoryItem.find(params[:id]).item :
   Admin::DomainRouting.parent_from_params(params, domain: current_domain)`.

3. **`Admin::ImagesController`** — `include Admin::DomainScopedAuth`; define `domain_auth_parent` =
   `params[:id].present? ? Image.find(params[:id]).parent :
   Admin::DomainRouting.parent_from_params(params, domain: current_domain)`.

**Net effect:** a domain-only books editor may tag/upload on `Books::*` records, is denied on
`Games::*`/`Music::*` records (correct isolation via the parent's registered domain), and global
admins/editors are unchanged (they return early in `authenticate_admin!`). The images/category_items
shallow member routes live in the global `namespace :admin` block, reachable on any host — resolving
the domain from the parent record (not the hostname) is what makes that safe.

## Routes

Inside the books `DomainConstraint` (`namespace :admin, module: "admin/books", as: "admin_books"`):

```ruby
resources :categories do
  collection { get :search }
end

resources :books do
  # ... existing (editions, book_authors, credits, book_relationships, images, search) ...
  resources :category_items, only: [:index, :create], controller: "/admin/category_items"
end

resources :authors do
  # ... existing (images, author_relationships, search) ...
  resources :category_items, only: [:index, :create], controller: "/admin/category_items"
end
```

The shallow `category_items` member routes (`destroy`) and the `images` member routes already exist in
the global `namespace :admin` block — 6a adds no shallow routes, only the two nested `category_items`
collections and the `categories` resource.

Resulting helpers: `admin_books_categories_path` (index), `admin_books_category_path` (show/update/
destroy), `new_/edit_admin_books_category_path`, `search_admin_books_categories_path` (collection),
`admin_books_book_category_items_path(book)` and `admin_books_author_category_items_path(author)`
(nested index/create).

## Controllers

- **`Admin::Books::CategoriesController < Admin::CategoriesBaseController`** + `include
  Admin::DomainScopedAuth` — mirrors `Admin::Games::CategoriesController`:

  ```ruby
  def model_class = ::Books::Category
  def param_key = :books_category
  def category_path(c) = admin_books_category_path(c)
  def categories_path = admin_books_categories_path
  def new_category_path = new_admin_books_category_path
  def edit_category_path(c) = edit_admin_books_category_path(c)
  def domain_label = "Books"
  def subtitle = "Manage book genres, subjects, locations, and themes"
  def load_show_stats
    @stats = {"Books" => @category.books.count, "Authors" => @category.authors.count}
  end
  ```

  Everything else (index pagination/search, CRUD, JSON `search`, soft-delete) is inherited.

- **`Admin::CategoryItemsController`** and **`Admin::ImagesController`** — the domain-auth fix above. No
  change to their existing actions/params/redirects.

## Registry

- `ENTITIES["Books::Book"][:category_items_path]` → `->(r) { URL_HELPERS.admin_books_book_category_items_path(r) }` (was `nil`).
- `ENTITIES["Books::Author"][:category_items_path]` → `->(r) { URL_HELPERS.admin_books_author_category_items_path(r) }` (was `nil`).
- `DomainNav CONFIGS[:books][:categories_search_path]` → `-> { URL_HELPERS.search_admin_books_categories_path }` (was `nil`).
- `DomainNav CONFIGS[:books][:items]` `+ {label: "Categories", icon: :category, path: -> { URL_HELPERS.admin_books_categories_path }}` (the `:category` icon already exists).

## Views

Mirror `admin/games/categories/` + the music/games show-page categories card. DaisyUI-5 throughout.

- **`admin/books/categories/{index,show,new,edit}.html.erb` + `_form.html.erb` + `_table.html.erb`** —
  copied from games, re-pointed to `admin_books_*` helpers and "Books"/"Authors" show-stats. `_form`
  fields: `name`* , `description`, `category_type` (select), `parent_id` (optional). Row actions in the
  proven `flex items-center justify-end gap-1` + `btn btn-outline btn-xs whitespace-nowrap` pattern
  (Delete `+ btn-error`). Index uses `Admin::SearchComponent` + `pagy` nav.
- **Book show page (`admin/books/books/show.html.erb`)** — add a **Categories** card: header title +
  "+ Add" opening `add_category_modal` (`Admin::AddCategoryModalComponent.new(item: @book)`), and render
  `admin/category_items/index` (the `category_items_list` frame) **directly** — no outer
  `turbo_frame_tag` wrap (the 4c double-wrap landmine).
- **Author show page (`admin/books/authors/show.html.erb`)** — the identical card with `item: @author`.

## Testing

- **`admin/books/categories_controller_test.rb`** — index (with/without `q`, pagination present); CRUD
  (create/update params + redirect, `name`-required 422, `destroy` soft-deletes — assert `deleted`
  flips, not row removed); JSON `search` shape; auth (books writer allowed, regular user redirected,
  unauthenticated redirected).
- **Shared-controller auth tests** — extend `admin/category_items_controller_test.rb` and
  `admin/images_controller_test.rb` (or add focused tests): a **domain-only** editor for the parent's
  domain is **allowed** create/destroy; a domain-only editor for a **different** domain is **denied**;
  a global admin is allowed. Prove it for books **and** one other domain (games or music) so the fix is
  demonstrably not books-only, and so the existing games/music behavior is pinned as a regression guard.
- **`Admin::DomainRouting` unit** — `category_items_path_for(Books::Book.new(...))` and
  `...(Books::Author.new(...))` resolve to the nested paths (were `nil`).
- **`Admin::DomainNav` unit** — `config_for(:books)[:categories_search_path]` resolves; books `items`
  include "Categories". **Re-point** the existing `domain_nav_test` categories invariant that keyed off
  the nav label / `AddCategoryModalComponent#search_url` (it must now expect the books path, not a
  fallback).
- **Category-tag integration** — POST `admin_books_book_category_items_path(book)` with a
  `Books::Category` adds a `CategoryItem` (turbo_stream replaces `category_items_list` +
  `add_category_modal`); same for an author.
- **Playwright** `e2e/tests/books/admin/categories.spec.ts` — index lists + "New Category" → create →
  show; open a book show page, add a category via the live typeahead, assert it appears in the card and
  that the typeahead queried the **books** search endpoint (not music). The full 9-spec suite is inc 7.

## Landmines

- **The music-genre fallback is the whole reason categories was deferred** — verify in a test that a
  book's `AddCategoryModalComponent#search_url` resolves to `search_admin_books_categories_path`, never
  `search_admin_categories_path`. Set both `ENTITIES` `category_items_path`s **and**
  `categories_search_path` together; a half-fix (form path set, search path still `nil`) still tags via
  the music search.
- **Do not double-wrap the turbo frame** — the show-page card renders `admin/category_items/index`
  directly; that template opens `turbo_frame_tag "category_items_list"` once (4c landmine, caught by
  E2E not unit review).
- **Auth resolves the parent before `set_parent` runs** — `domain_auth_parent` must not depend on
  `@parent`/`@image` (parent-class `before_action` ordering). Resolve from `params` directly (6a-5).
- **`raise_on_missing_callback_actions` is on** (dev+test) — grow the categories controller's
  `before_action only: [...]` lists per task; never name a not-yet-defined action.
- **`category_type` enum leak** — the form's select includes `game_mode`/`player_perspective`. Accepted
  (6a-3 non-goal), but do not add a books `Category` that a public books view would choke on.
- **Ship the `DomainNav` "Categories" item + category-card "+ Add"/Remove affordances with the routes**
  — every prior increment that forgot the nav item shipped with a dead sidebar (4a).
- **DaisyUI-5 form pattern** — `<div class="form-control">` + `f.label class:"label"` + `w-full`
  inside a `card`; mirror `admin/games/categories/_form`.

## 6b preview (next increment, its own design doc)

Lists (thin `Admin::Books::ListsController`, no wizard hook; `Books::List` added to the `LISTS`
registry for the show-page book typeahead) + Ranking configurations (thin subclass; `Books::
RankingConfiguration` gains a real registry `path:`, which **gates auth** and intentionally flips the
`ranked_lists`/`ranked_items`/`penalty_applications` books-denial tests red — the signal to widen them)
+ the D8 `calculate_books_year_range` fix (real `Books::Book.first_published_year` min/max, mirroring
`calculate_music_year_range`).
