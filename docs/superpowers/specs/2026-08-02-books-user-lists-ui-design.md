# Books User Lists UI — Design

**Date:** 2026-08-02
**Status:** Approved, not implemented
**Supersedes:** the "A books layout and books UI wiring" bullet in `docs/features/user-lists.md` ("What's Not Yet Implemented")

## Problem

`Books::UserList` exists and holds real migrated data — **282,922 lists across 69,458 users, with
3,096,597 items** — but it is deliberately unwired from the UI. Phase 3 of the books data migration
(`2026-07-12-books-user-lists-migration-design.md`, decision `D-data-only`) loaded the rows and
stopped, because the books domain had no public routes at the time.

Books now has a full public UI (ranked grid at `/`, `/book/:slug`, `/lists`, `/lists/:id`), so the
data can be surfaced. This spec wires books into the existing user-lists feature at parity with
music and games, and adds public viewing of shared lists.

## What already exists (do not rebuild)

`Books::UserList` is fully specified — `enum :list_type` (`favorites`/`read`/`reading`/
`want_to_read`/`custom`), `list_type_icons`, `completed_on_list_types [:read]`,
`ranking_configuration_class`, `listable_display_includes`. `Books::Book` declares
`has_many :user_list_items, as: :listable`. `Books::CardComponent` already emits
`data-listable-type` / `data-listable-id`. The `/user_lists/:id` legacy alias is already routed to
`my_lists#show`. `Search::Books::Search::BookAutocomplete` exists. The Playwright books project
already has `books-auth.setup.ts` and a `books-user.json` storage state.

## Increments

Two PRs. The seam is *"a books user manages their own lists"* vs *"anyone can view a shared list"* —
the second is the only one that changes authorization, and isolating an auth change is worth its own
review.

- **Increment 1 — Books My Lists at parity with games.** Constants, lazy default-list bootstrap,
  layout wiring, icon, CSV fix, item/card rendering, autocomplete config, widget sites.
- **Increment 2 — Public viewing + legacy 301s.** Viewer-aware `show`, `UserListPolicy#show?`,
  owner attribution, `noindex`, three redirects.

Not split three ways: a "backend enable" increment and a "books presentation" increment would both
rewrite `UserLists::Show::ItemComponent` and the show page, and the first would ship a deliberately
table-only books list that nobody wants.

---

# Increment 1 — Books My Lists

## A. Constant wiring

`app/models/user_list.rb`:

- Add `"books" => %w[Books::UserList]` to the frozen `DOMAIN_SUBCLASSES` hash literal. This one line
  makes `subclasses_for(:books)` stop returning `[]`, which lights up `MyListsController`,
  `UserListStateController`, and `UserListsController::ALLOWED_TYPES` simultaneously — they all
  derive from it.
- `DEFAULT_SUBCLASSES` gains `Books::UserList` → new signups get **16** default lists, not 12.
- Delete the "deliberately excluded pending UI work" comment on `DOMAIN_SUBCLASSES`.

Three existing tests assert the old numbers and must flip:

| File | Change |
|---|---|
| `test/models/user_test.rb` | `assert_equal 12` → `16`; `assert_difference "UserList.count", -12` → `-16` |
| `test/models/user_list_test.rb` | `default_subclasses` size 4 → 5, add `Books::UserList` |
| `test/models/books/user_list_test.rb` | "is deliberately excluded from DEFAULT_SUBCLASSES and DOMAIN_SUBCLASSES" inverts to assert inclusion |

## B. Lazy default-list bootstrap

**Problem:** `User#create_default_user_lists` is an `after_create` callback, so adding books to
`DEFAULT_SUBCLASSES` only affects *new* signups. Migrated legacy books users already have their
lists, but every existing new-app user (music/games signups) would land on the books `/my/lists`
dashboard with nothing at all and no way to get defaults — list creation through the UI only
produces `custom` lists.

**Decision:** lazy ensure-on-visit, not a one-time backfill task. It covers new signups, existing
new-app users, and the ~145 legacy users the migration left short (`D-verbatim-defaults`: 19 missing
`read`, 36 `reading`, 59 `want_to_read`, 31 `favorites`) — with no 70k-row batch job against
production. Legacy TheGreatestBooks had exactly this mechanism (`ensure_list_type_exists`).

**New service** `app/lib/services/user_lists/ensure_defaults.rb`:

```ruby
Services::UserLists::EnsureDefaults.call(user:, domain:, existing:) # => Array<UserList>
```

It takes the list array the caller **already loaded**, diffs it against
`UserList.subclasses_for(domain)` × each subclass's `default_list_types`, `find_or_create_by!`s only
the missing pairs, and returns the merged set.

- **Zero extra queries and zero writes in the common case.** This matters because one of its two
  callers runs on every signed-in page view.
- Returns a plain array, **not** a `Result` struct. It has no failure branch a caller can act on,
  matching `Services::RankedItemsFilterService` rather than `Services::DescriptionColumnBackfill`.
- Use `::UserList` explicitly inside `Services::UserLists` to avoid constant-resolution surprises
  (cf. the `Services::BooksMigration` / bare `Music::` landmine).

**Race handling.** `UserList#one_default_per_type_per_user` is a model-level validation with no
backing DB partial unique index (deliberate — see `docs/features/user-lists.md`). Two concurrent
requests from the same user could both pass validation. The service rescues
`ActiveRecord::RecordInvalid`, re-reads, and returns. No new index, no schema change.

**Callers.** Both already load exactly the array the service needs:

- `MyListsController#index` — after `lists = current_user.user_lists.where(type: types).to_a`
- `UserListStateController#show` — same pattern; re-sort by `id` after the merge

**Cross-domain side effect (flagged deliberately).** This repairs *every* domain, not just books — a
music user who signed up before `Movies::UserList` existed gets their movies defaults on next visit.
Additive and desirable, but it is a cross-domain behavior change riding in a books PR.

## C. Books layout

`app/views/layouts/books/application.html.erb` — five additions mirroring `games/application`:

1. `<body class="bg-base-200" data-controller="user-list-state" data-domain="<%= Current.domain %>"
   data-signed-in="<%= signed_in? %>">` (keep the existing class)
2. `<li id="navbar_my_lists" class="hidden"><a href="/my/lists">My Lists</a></li>` in the **mobile
   dropdown**
3. the same `<li>` in the **desktop menu** — both are required; `user_list_state_controller`
   reveals them client-side so the HTML stays identical for every visitor and CDN-cacheable
4. `<%= render UserLists::ModalComponent.new %>` and `<%= render Toast::RegionComponent.new %>`
5. `<%= render "shared/user_list_icon_template" %>`

## D. Icon

`Books::UserList.list_type_icons[:reading]` is `book-open`, which is not vendored and not in the
client-side template.

1. Add `app/assets/svg/icons/lucide/outline/book-open.svg` (single file — do **not** sync the whole
   Lucide library; see the curation policy in `app/assets/svg/icons/README.md`)
2. Add `book-open` to the `%w[...]` list in `app/views/shared/_user_list_icon_template.html.erb` —
   the modal clones icons from this template by `data-icon` name
3. Add the row to the README table

## E. `MyListsController` books support

- `resolve_layout` gains `when :books then "books/application"`; delete the stale "books never gets
  past the `UserList::DOMAIN_SUBCLASSES` guard" comment above it.
- `csv_headers` / `csv_row` gain an explicit `when "Books::Book"` branch →
  `["Position", "Title", "Authors", "Year"]`, using `book_authors.map { |ba| ba.author.name }` and
  `first_published_year`.

**Correction, found during implementation.** `docs/features/user-lists.md` and the Phase 3 migration
spec both warn that a naive wiring would **500** here, because `Books::Book` lacks `release_year`.
That was true when written and stopped being true on 2026-07-22, when commit `f0e9e75` (books admin
inc 6b) added `Books::Book#release_year` as a delegator to `first_published_year`.

So the real pre-fix defect is quieter than advertised: the `else` branch returns a correct year but
emits **no Authors column**, silently exporting books lists without their authors while music lists
get Artists. The books branch is still required — but for parity, not to avoid a crash. The stale
500 warning must be removed from `docs/features/user-lists.md` (see the docs task).

## F. `UserLists::Show::ItemComponent`

Add `Books::Book` to `CARD_LISTABLES` so books lists get all three view modes (list / grid / table)
instead of falling through to table-only like songs. Books have covers, descriptions, an author
byline and a year — exactly the shape the `default_view` row was designed for.

Per-listable branches to add:

| Method | Books behavior |
|---|---|
| `listable_card` | `Books::CardComponent.new(book: listable)` |
| `title_link` | `link_to listable.title, book_path(listable.slug)` |
| `by_line` | `listable.book_authors.map { |ba| ba.author.name }.join(", ")` |
| `year` | `listable.first_published_year` |
| `cover_aspect_class` | `aspect-[2/3]` (books are taller than games' `3/4`) |

`description` already works — `listable.try(:primary_description)&.content`, and `Books::Book` has
`primary_description` with `:descriptions` preloaded.

**No `link_to_book` helper.** Music and games use `link_to_album` / `link_to_game` because those
helpers are rc-aware. `MyListsController` is a global route with no rc context, so a `link_to_book`
helper would wrap a single `link_to` for one caller. `Books::CardComponent` already calls
`book_path(book.slug)` directly; `ItemComponent` follows suit.

## G. N+1: the `book_authors` preload

`Books::UserList.listable_display_includes` currently preloads `:authors`, but
`Books::CardComponent#author_names` reads `book_authors` — a *different* association. Rendering a
100-item books list in grid view would fire 100 queries.

**Fix:** change the preload to `[{book_authors: :author}, :categories, :primary_image, :descriptions]`
and have `ItemComponent#by_line` read `book_authors` too, so the card and the row read the same
preloaded association. `Books::Book` declares
`has_many :book_authors, -> { order(:position) }`, so ordering is preserved and `authors` (a
`has_many :through` over it) inherits that order — nothing else depends on the old preload.

Pinned with `assert_queries_count` (already used in four existing tests).

## H. `Books::CardComponent`

- Signature becomes `initialize(book:, rank: nil, index: 0)`. The My Lists grid view has no rank to
  pass; the two existing call sites (`books/ranked_items/index`, `books/lists/show`) pass both and
  are unchanged.
- Render `UserLists::CardWidgetComponent.new(listable: book)` in the card body, wrapped in a
  `relative z-10` container.

**Stretched-link landmine.** `Books::CardComponent`'s title link carries
`after:absolute after:inset-0` inside a `position: relative` DaisyUI card. The `::after` overlay is a
positioned element with no `z-index`, so it paints above any *non*-positioned later sibling —
dropping the widget button in unwrapped makes it **silently unclickable**. Music and games cards
have no stretched link, so copying their markup will not surface this. A unit test cannot catch it
either; the `add-to-list` E2E spec is the real guard.

## I. Widget render sites

`Books::CardComponent` covers three surfaces in one place: the ranked homepage grid, `/lists/:id`,
and the My Lists grid view. Plus one more:

- `app/views/books/books/show.html.erb` — `UserLists::CardWidgetComponent.new(listable: @book)` in
  the right-hand column, near the title / rank line.

## J. `Search::ListableAutocomplete`

Add to `CONFIGS`:

```ruby
"Books::Book" => {
  service: ::Search::Books::Search::BookAutocomplete,
  model: ::Books::Book,
  includes: [{book_authors: :author}]
}
```

`label_for` gains a books branch → `"Title — Authors"` (matching music's format). `item_noun`
already derives `"book"` from `"Books::Book"`, so the placeholder reads "Search for a book to add…"
with no change. `BookAutocomplete` defaults to `book_kind: "standalone"`, which is the correct filter
here.

This turns on `UserLists::Show::AddItemComponent` for books lists — it has a `render?` predicate
gated on `Search::ListableAutocomplete.searchable?`, so no view change is needed.

---

# Increment 2 — Public list viewing + legacy 301s

## K. Why visibility lives in the query, not the policy

`ApplicationController` rescues `Pundit::NotAuthorizedError` with `redirect_back` + a flash. A
redirect leaks that a private list exists. Today `MyListsController#show` never reaches that rescue
because the `current_user.user_lists` pre-scope turns non-owners into `RecordNotFound` → 404.
Increment 2 must preserve that property.

**New model scope** (`app/models/user_list.rb`):

```ruby
scope :visible_to, ->(user) { user ? public_lists.or(owned_by(user)) : public_lists }
```

`public_lists` and `owned_by` already exist and both compose off the same relation, so `.or` is
structurally compatible with the caller's `where(type: types)`.

## L. Viewer-aware `MyListsController#show`

```ruby
types = UserList.subclasses_for(Current.domain).map(&:name)
@list = UserList.where(type: types).visible_to(current_user).find(params[:id])
authorize @list, :show?, policy_class: UserListPolicy
@owner = @list.user_id == current_user&.id
```

- Private + non-owner falls out of the scope → `RecordNotFound` → **404**, existence hidden.
- Cross-domain still 404s (the `types` filter is unchanged).
- `authorize` can no longer fail given that scope. It is kept deliberately as defense-in-depth and so
  `UserListPolicy#show?` remains the readable statement of the rule.
- `before_action :require_signed_in!` narrows to `only: [:index]` so anonymous visitors can reach a
  public list.

`UserListPolicy#show?` becomes `owner? || record.public?`. `Scope` is left alone (owner-only) — it
models "my lists", not "lists I may view".

## M. Owner-gated UI

Gated on `@owner` in `app/views/my_lists/show.html.erb`:

- `UserLists::Show::AddItemComponent` (its own comment already anticipates this: *"If public list
  viewing lands (02d), gate on ownership"*)
- the "← My Lists" backlink

`persist_view_mode` returns early unless `@owner`, so a non-owner never writes to someone else's
list. They can still switch view for their own render, which means `@view_mode` resolution splits:

```ruby
@view_mode = if @owner
  @list.view_mode                       # persist_view_mode already applied any param
else
  params[:view_mode].presence_in(UserList.view_modes.keys) || @list.view_mode
end
```

Available to **everyone**: sorting, pagination, CSV download, and the per-item
`UserLists::CardWidgetComponent`. The widget on someone else's public list is the point of the
feature; anonymous clicks already open the login modal.

## N. Attribution

Only **22 of 88** public-list owners have a `display_name`. Show `by <display_name>` when present;
show nothing when absent, rather than inventing "Anonymous". Never render `email` or `name`.

## O. Indexing and caching

- `MyListsController` sets `@indexable = false`. The books layout's `books_robots_content` already
  emits `noindex, follow` when `@indexable` is falsy, so books needs no layout change.
- **Latent gap, flagged not fixed:** the *music* layout has no `<meta name="robots">` tag at all, so
  a public music list would be indexable. There are zero public music lists today (all 115 public
  `UserList` rows are `Books::UserList`), so this stays out of scope.
- `prevent_caching` stays on **every** action. The HTML is owner-aware; edge-caching it would serve
  one viewer's toolbar to another. 115 lists total — there is no perf argument on the other side.

## P. Legacy 301s

The legacy books site had `resources :user_lists`. Add, next to the existing `/user_lists/:id` alias
in the global (non-domain-constrained) routes block:

```ruby
get "user_lists",          to: redirect("/my/lists", status: 301)
get "user_lists/new",      to: redirect("/my/lists", status: 301)
get "user_lists/:id/edit", to: redirect("/my/lists/%{id}", status: 301), constraints: {id: /\d+/}
```

- **Ordering is load-bearing:** `user_lists/new` must be declared **before** `get "user_lists/:id"`
  or `:id` swallows `"new"`.
- `GET /user_lists` and the existing `POST /user_lists` (create) are different verbs and coexist.
- `/user_lists/:id/edit` targets a write surface that does not exist in any domain yet (Phase B,
  `user-lists-02f`), so the read page is the honest landing spot.

---

# Testing

## Fixtures

Books rows go into the **existing** `test/fixtures/user_lists.yml` with `type: Books::UserList`, and
`test/fixtures/user_list_items.yml` with `listable: <book> (Books::Book)`.

**Never create a separate `test/fixtures/books/user_lists.yml`** — an STI-subclass fixture file for
`user_lists` kills the entire suite (landmine recorded in the Phase 3 migration work). Never run
`ActiveRecord::FixtureSet.create_fixtures` against development; it truncates.

## Increment 1 — Minitest

Flipped: `user_test.rb`, `user_list_test.rb`, `books/user_list_test.rb` (see §A).

New / extended:

- `test/lib/services/user_lists/ensure_defaults_test.rb` — creates only what is missing; idempotent
  on a second call; **zero queries and zero writes when the set is already complete**; scoped to the
  passed domain only; survives the concurrent `RecordInvalid` race
- `test/controllers/my_lists_controller_test.rb` — on the books host: index renders in
  `books/application`; show renders; **CSV returns 200 with an Authors column and
  `first_published_year`** (direct regression test for §E); a books list still 404s on the music host
- `test/controllers/user_list_state_controller_test.rb` — books domain serializes `Books::UserList`
  and backfills missing defaults
- `test/controllers/user_lists_controller_test.rb` — `Books::UserList` accepted by `ALLOWED_TYPES`
- `test/components/user_lists/show/item_component_test.rb` — books renders the card in `grid_view`,
  the list row in `default_view`, the table row in `table_view`; `by_line` is authors; `year` is
  `first_published_year`
- `test/components/user_lists/show/add_item_component_test.rb` — now renders for `Books::Book`
- `test/components/books/card_component_test.rb` (exists) — renders without `rank:` / `index:`;
  emits the widget
- `test/lib/search/listable_autocomplete_test.rb` — books `searchable?`, `"Title — Authors"` label,
  OpenSearch stubbed with Mocha
- **N+1 pin:** `assert_queries_count` on a multi-item books list in grid view, guarding §G

Controller tests assert status codes and behavior only — never HTML, CSS, or copy.

## Increment 2 — Minitest

- `test/policies/user_list_policy_test.rb` — `show?`: owner ✓, non-owner + public ✓, non-owner +
  private ✗, anonymous + public ✓
- `test/models/user_list_test.rb` — the `visible_to` scope, both branches
- `test/controllers/my_lists_controller_test.rb` — anonymous + public → 200; anonymous + private →
  **404**; non-owner + public → 200 with no add box and no backlink; non-owner `?view_mode=` does
  **not** persist; CSV works for a public list
- route tests for the three 301s, including that `/user_lists/new` is not swallowed by `:id`

## E2E (Playwright)

These are the **first** user-list E2E specs in the repo — there are none for music or games. The
books project already has `books-auth.setup.ts` and a `books-user.json` storage state, so signed-in
specs are cheap.

- `e2e/tests/books/my-lists.spec.ts` — the "My Lists" nav link appears when signed in → dashboard
  shows the 4 defaults → open one → switch view mode → download CSV
- `e2e/tests/books/add-to-list.spec.ts` — open the widget modal from a homepage card, tick a list,
  reload, confirm the icon strip reflects it, untick. **This is the only guard on the §H
  stretched-link fix** — a unit test cannot detect an unclickable button.
- Increment 2: `e2e/tests/books/public-list.spec.ts` — anonymous
  (`test.use({ storageState: { cookies: [], origins: [] } })`) loads a public list and sees items but
  no add box; a private list 404s

Add `data-testid` (kebab-case) only where role/text/label cannot target an element.

**Seed dependency.** A public books list **cannot be created through any UI** — the modal's inline
create makes a private `custom` list, and the public toggle is Phase B (`user-lists-02f`). Extend
`lib/tasks/e2e.rake` with a task that ensures a known public books list with a few items exists for
the Playwright account, following the existing `e2e:admin` pattern.

---

# Out of scope

- **Write/management surface** (create, rename, delete, drag-reorder, remove item, `completed_on`
  editing) — Phase B, `docs/specs/user-lists-02f-list-management-and-editing.md`, unbuilt for every
  domain.
- **Public-list discovery index** and **"consumed" badges** — the rest of `user-lists-02d`. This spec
  ships direct-link public viewing only.
- **Movies** — unimplemented and out of scope project-wide.
- **The music layout's missing robots meta tag** — see §O.

# Verification before claiming done

`bin/rails test` and `bundle exec standardrb` from `web-app/`, plus the new Playwright specs
(`yarn test:e2e`, which needs a local dev server and `e2e/.env`). CI runs `bin/rails test` and
`standardrb` and eager-loads (`CI=true`), so it is stricter than a local run.

# Docs to update on completion

- `docs/features/user-lists.md` — the STI table, the 12→16 default-list count, the domain→subclass
  table, and the "What's Not Yet Implemented" section (the books bullet is resolved; 02d narrows to
  discovery + badges)
- `app/assets/svg/icons/README.md` — the `book-open` row
