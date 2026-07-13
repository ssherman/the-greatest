# Books Admin Interface — Design

**Status:** Design approved by owner 2026-07-13. Spec pending owner review.
**Goal:** A full books admin at `new.thegreatestbooks.org/admin`, matching what music and games already have — CRUD for books, editions, authors, series, categories, lists, and ranking configurations — built on top of the 126K books already migrated from the legacy site.
**Why now:** The books domain resolves and serves a placeholder page (PR #167). The data is all there. The admin is the only way to curate it, and it is a prerequisite for any public books UI.

## Scope

**In:** a shared-admin de-forking refactor (domain registry, data-driven sidebar, dynamic layout); the books admin shell (layout, base controller, dashboard, policies); CRUD for `Books::Book`, `Books::Edition`, `Books::Author`, `Books::Series`; inline management of `Books::BookAuthor`, `Books::Credit`, `Books::BookRelationship`, `Books::AuthorRelationship`, `Books::SeriesBook`; books subclasses of the existing categories / lists / ranking-configuration base controllers; cover-image upload; a real `calculate_books_year_range`; Minitest + Playwright coverage.

**Out (deferred):** the 7-step list wizard; any external books data source (OpenLibrary / Goodreads / Google Books / Hardcover); a `DataImporters::Books` importer; an "Import from …" button; a books AI-chats admin; the public books UI; a books dedup pipeline. Identifiers stay read-only display, matching music and games.

**Why the wizard is out:** every wizard flow that exists (music, games) has an *enrich* step that matches parsed list rows against an external API (MusicBrainz, IGDB) and an *import* step that creates entities from what it found. Books has no such API client and no importer. Building one is a separate project of comparable size. Critically, it is **not** blocking: the 1,030 migrated books lists already carry 65,252 list items, **all of them linked** — zero unlinked. The existing lists are fully usable today, and manual add-via-typeahead (already built, domain-agnostic) covers editing.

## Current state (verified 2026-07-13)

### Books data actually present

| Table | Rows |
|---|---|
| `books_books` | 126,204 (0 with `book_kind: collection`) |
| `books_authors` | 58,193 |
| `books_editions` | 148,296 |
| `books_book_authors` | 126,869 |
| `lists` (`Books::List`) | 1,030 (761 have items) |
| `list_items` on books lists | 65,252 — **all linked**, 0 with a null `listable` |
| `ranking_configurations` (`Books::`) | 4 |
| `categories` (`Books::Category`) | 73,913 |
| `category_items` on books | 1,827,815 |
| `external_links` (parent `Books::Book`) | 13,404 |
| **`books_series` / `books_series_books`** | **0 / 0** |
| **`books_credits`** | **0** |
| **`books_book_relationships`** | **0** |
| **`books_author_relationships`** | **0** |
| **`images`** (any books parent) | **0** |

Identifiers exist in bulk (`books_work_goodreads_id` 154,541; `books_work_isbn10` 183,980; `books_work_isbn13` 133,915; `books_work_asin` 79,105; `books_work_ean13` 80,792; `books_work_openlibrary_id` 31,602; `books_author_openlibrary_id` 16,542; `books_edition_openlibrary_id` 18).

The five empty tables were created by the v2 object model but nothing has ever populated them — no importer, and the legacy migration didn't carry them. **The admin is the only thing that could ever create this data.** That is the argument for building their UI now rather than deferring on YAGNI grounds.

### What already works for books

- `DomainRole` enum already has `books: 2`. Domain-scoped auth needs no schema change.
- `Admin::BaseController#domain_root_path` already falls through to `books_root_path`.
- `Admin::ListsBaseController`, `Admin::CategoriesBaseController`, and `Admin::RankingConfigurationsController` are genuine abstract base classes with subclass hooks. Games' subclasses are ~30 lines each. Books' will be too.
- `ItemRankings::Books::Calculator` exists, and `RankingConfiguration#calculator_service` already dispatches `Books::RankingConfiguration` to it. **Refresh Rankings and Bulk Calculate Weights will work for books with no new code.**
- OpenSearch is wired: `Search::Books::BookIndex`, `AuthorIndex`, and the `BookGeneral` / `BookAutocomplete` / `AuthorGeneral` queries. There is **no** series index and **no** edition index — those must fall back to SQL `ILIKE`.

### What does not exist

- No `app/policies/books/` at all.
- No `layouts/books/admin.html.erb`.
- No books admin routes, controllers, or views.
- No `DataImporters::Books`, no external books API client, no `Services::Lists::Books::ListItemEnricher`.

### The shared admin layer is not actually shared

Despite the naming, the "domain-agnostic" admin controllers dispatch on hardcoded per-domain `case` statements. Every one needs a books arm:

| File | Hardcoded |
|---|---|
| `admin/images_controller.rb:139,163` | `set_parent` (which nested param?) + `redirect_path_for_parent` |
| `admin/category_items_controller.rb:88,109` | same two — and literally carries `# Future: elsif params[:book_id]` comments |
| `admin/list_items_controller.rb:191,199` | `expected_listable_type_for` + `redirect_path` |
| `admin/list_penalties_controller.rb:121` | `redirect_path` |
| `admin/penalty_applications_controller.rb:150` | `redirect_path` |
| `admin/ranked_items_controller.rb:10` | item-class resolution |
| `admin/ranked_lists_controller.rb` | `redirect_path` |
| `admin/penalties_controller.rb:69` | penalty-class resolution |
| `concerns/ranking_configuration_domain_auth.rb:20` | domain resolution |
| `components/admin/{add_category,add_item_to_list,add_list_to_configuration,edit_list_item}_modal_component.rb` | search/autocomplete path resolution |
| `views/admin/shared/_sidebar.html.erb` | one `if current_domain == :games / else` block |

Every `else` branch falls back to `music_root_path`.

**Live bug this exposes.** The global `namespace :admin` block (penalties, users, shallow images/list_items/category_items, ranked_lists) sits **outside** every domain constraint — it is reachable from any hostname. `Admin::PenaltiesController:2` and `Admin::UsersController:2` hardcode `layout "music/admin"`, as does `Admin::RankedListsController:4` for `#show`. So a **games** admin who clicks Penalties or Users in the sidebar is served the **music** layout: music logo, music CSS bundle, music sidebar. Books would inherit the same bug.

Separately, `Admin::Games::{Base,Lists,Categories,RankingConfigurations}Controller` each copy-paste the identical 8-line `authenticate_admin!` override.

### Verification

There is no test CI (`.github/workflows/` holds only the Docker build and the deploy; CLAUDE.md's claim is stale, and the owner does not use brakeman). Verification is local: `bin/rails test`, `bin/rails test:system`, `bundle exec standardrb`, and `yarn test:e2e`.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Admin CRUD first; no external data source, no list wizard | The wizard's enrich/import steps are meaningless without a books API client. The 1,030 migrated lists are already fully linked, so nothing is blocked. |
| D2 | Extract a domain registry **before** adding books, rather than adding a books arm to ~12 case statements | The dispatch points all answer one question ("given this record: what domain, what layout, what admin path?"). Making it data-driven once costs barely more than forking it a third time, and movies becomes a config entry instead of a fourth fork. |
| D3 | `Admin::DomainRouting.parent_from_params` keys by **domain first, then param name** | Books nests images under `series_id` and `author_id`. Keying on the param name alone risks a collision the day games' series gets images. The hostname has already pinned the domain, so scoping by it is collision-free by construction. |
| D4 | Fix the `layout "music/admin"` bug as part of the refactor | It is the same root cause (hardcoded domain dispatch in a global controller), it is a live bug for games today, and books would inherit it. `layout :admin_layout` → `"#{current_domain}/admin"`. |
| D5 | Editions get nested CRUD under a book + their own show page, but **no** top-level index | An edition is meaningless without its book, and `books.default_edition_id` drives the whole public display (cover, publisher, page count). `Music::Release` — the analogous second tier — is read-only in the music admin, which books cannot afford: there is no importer to fix bad edition data. |
| D6 | Build the UI for all five empty tables (series, series_books, credits, book relationships, author relationships) | They are empty *because* nothing can create them. The admin is that thing. Owner's call. |
| D7 | Include cover-image upload | `Admin::ImagesController` is already built and works for music and games; wiring books in is nested routes + views, not new machinery. Books currently has **zero** images of any kind. |
| D8 | Fix `calculate_books_year_range` in this project | It is a stub (`# For now, use a reasonable estimate until we have book models with data`) hardcoding a ~5,026-year range from 3000 BCE. Every books list therefore covers a near-zero fraction of the range and takes a near-maximum list-dates penalty. The books RC admin's "Refresh Rankings" button runs straight through it. ~10 lines, books-only blast radius, and books rankings are not public yet so changing the numbers is safe. |
| D9 | Array columns (`alternate_titles`, `alternate_names`) use a comma-separated text input, split in the controller | No new form machinery; matches how an admin thinks about the field. |
| D10 | Series and editions search via SQL `ILIKE`; books and authors via OpenSearch | Only `BookIndex` and `AuthorIndex` exist. Building series/edition indexes is not justified by the admin's needs. |
| D11 | Ship as six independent increments, each its own plan + PR | Increment 1 is a behavior-neutral refactor of *existing* code and deserves to be reviewed on its own, separate from new books code. |

## Architecture

### Part 1 — De-fork the shared admin layer

**`Admin::DomainRouting`** — `web-app/app/lib/admin/domain_routing.rb`. One registry, one question:

```ruby
Admin::DomainRouting.domain_for(record_or_class)   # => :music | :games | :books
Admin::DomainRouting.path_for(record)              # => admin show path
Admin::DomainRouting.list_config(list)             # => {listable_type:, path:, autocomplete_path:, item_label:}
Admin::DomainRouting.ranking_configuration_path(rc)
Admin::DomainRouting.parent_from_params(params, domain:)   # nested parent for images / category_items
```

Backed by class-name-keyed tables (entities, lists, ranking configurations, penalties) plus a domain-scoped nested-param table (D3). It `extend`s `Rails.application.routes.url_helpers` so the path lambdas resolve.

This replaces the case statements in all nine controllers/concerns and four modal components listed above.

**`Admin::DomainNav`** — per-domain sidebar config: an ordered list of `{label:, path:, icon:}`. `views/admin/shared/_sidebar.html.erb` renders from it. The `if games / else music` block is deleted; books is a new array.

**`Admin::DomainScopedAuth`** — a concern overriding `authenticate_admin!` to allow `current_user.can_access_domain?(domain_for_auth)`, where `domain_for_auth` defaults to `current_domain`. Replaces the four verbatim copies in the games controllers (and their music equivalents), and absorbs the existing `RankingConfigurationDomainAuth`. `Admin::ListItemsController` and `Admin::ListPenaltiesController` override `domain_for_auth` to derive the domain from the list, preserving today's behavior.

`Admin::BaseController#authenticate_admin!` keeps its current global-admin/editor-only semantics — the global controllers (penalties, users, cloudflare) must not be loosened.

**Dynamic layout.** `Admin::BaseController` gains `layout :admin_layout`, returning `"#{current_domain}/admin"`. The hardcoded `layout "music/admin"` comes out of `PenaltiesController`, `UsersController`, and `RankedListsController`. This is the D4 bug fix.

### Part 2 — The books admin

Routes live under `namespace :admin, module: "admin/books", as: "admin_books"` **inside** the books `DomainConstraint`, mirroring games.

| Entity | Surface |
|---|---|
| **Books** | Full CRUD. Index backed by `Search::Books::Search::BookGeneral` with sort + pagination (126K rows), mirroring `Admin::Games::GamesController#load_games_for_index`. `collection { get :search }` powers the list-item and relationship typeaheads. The show page hosts everything below. |
| **Editions** | Nested CRUD under a book (D5); shallow show/edit/update/destroy; own show page carrying identifiers, cover images, and credits; `member { post :set_default }` writes `books.default_edition_id`. No top-level index, no sidebar link. |
| **BookAuthors** | Inline on the book show page — author typeahead, `role` (author/editor), `position`, `credited_as`. Mirrors `Admin::Music::AlbumArtistsController` (nested `create`, shallow `update`/`destroy`). |
| **Credits** | Inline on the book **and** edition show pages (polymorphic `creditable`) — author typeahead, `role` (translator/illustrator/editor/introduction/foreword/afterword/narrator/cover_artist/contributor/ghostwriter), `position`. |
| **BookRelationships** | Inline on the book show page — related-book typeahead + `relation_type` (contains/abridgement_of/adaptation_of/revision_of/related_to). |
| **Authors** | Full CRUD; index backed by `Search::Books::Search::AuthorGeneral`. Fields: name, sort_name, alternate_names, `kind` (person/organization/pseudonym/collective), birth_year, death_year, description. Inline AuthorRelationships (pseudonym_of / member_of) and images. |
| **Series** | Full CRUD, SQL `ILIKE` search (D10). Show page manages SeriesBooks: book typeahead, `position` (decimal), `numbered`, `position_label`; plus `representative_book`. |
| **Categories** | Thin subclass of `Admin::CategoriesBaseController`. |
| **Lists** | Thin subclass of `Admin::ListsBaseController`, with **no wizard hook**. List items managed through the existing shared `Admin::ListItemsController` + a book typeahead. |
| **Ranking configs** | Thin subclass of `Admin::RankingConfigurationsController`. Ranked lists, penalty applications, and ranked items come free once the registry knows books. |

**Policies:** `Books::{Book,Edition,Author,Series,Category,List,RankingConfiguration}Policy`, each a trivial `ApplicationPolicy` subclass returning `domain = "books"`.

**Shell:** `layouts/books/admin.html.erb` (games' layout with the books CSS bundle and title), `Admin::Books::BaseController`, `Admin::Books::DashboardController` with entity counts.

## Increments

Each is an independent plan + PR. Each must leave the suite green.

**1 — Domain registry + layout fix.** `Admin::DomainRouting`, `Admin::DomainNav`, `Admin::DomainScopedAuth`, dynamic layout, data-driven sidebar. **Music and games only — no books code.** Behavior-neutral except that games finally gets the games layout on Penalties / Users / RankedList#show. The existing 4,500-test suite is the safety net: it must pass with no edits beyond the layout-bug assertions.

**2 — Books shell.** `layouts/books/admin.html.erb`, `Admin::Books::BaseController`, dashboard, the seven policies, books entries in `DomainRouting` + `DomainNav`, routes skeleton, books added to `test/controllers/admin/domain_isolation_test.rb`.

**3 — Books + Editions.** Book CRUD + OpenSearch index + typeahead; nested edition CRUD + `set_default`; inline BookAuthors, Credits, BookRelationships; images and category_items wired in.

**4 — Authors + Series.** Author CRUD + OpenSearch index + inline AuthorRelationships + images; Series CRUD + inline SeriesBooks + `representative_book` + images.

**5 — Categories, Lists, Ranking configurations.** Three thin base-class subclasses, plus the `calculate_books_year_range` fix (D8).

**6 — Playwright suite.** `e2e/tests/books/admin/` mirroring games' nine specs.

## Testing

- **Minitest controller tests** for every new controller, mirroring `test/controllers/admin/games/`. Assert behavior only — status codes, params, no errors — never HTML/CSS/copy.
- **Policy tests** for all seven books policies.
- **`Admin::DomainRouting` unit test** asserting every registered class resolves, and that every domain entity reachable from the admin is registered.
- **`test/controllers/admin/domain_isolation_test.rb`** extended for books.
- **Playwright** at `e2e/tests/books/admin/`: dashboard, sidebar-nav, and CRUD per entity (books, editions, authors, series, categories, lists, ranking-configurations), mirroring the nine games specs.
- **Regression:** the existing music and games admin tests are the contract for increment 1. Any change to them is a red flag, not a fix.

## Risks

| Risk | Mitigation |
|---|---|
| Increment 1 silently changes music/games admin behavior | It is behavior-neutral by design and covered by 4,500 existing tests. If a test needs editing, stop and ask why. |
| `Admin::AddCategoryModalComponent` may render a `<select>` of all categories — books has 73,913 | Verify during increment 5; if so, it must use the existing `search` autocomplete endpoint instead. This would be a latent bug for music/games too (they have far fewer categories, so it never hurt). |
| The books CSS bundle may not carry the DaisyUI admin components | Verify when building `layouts/books/admin.html.erb` in increment 2. Same Tailwind 4 + DaisyUI 5 setup as games, so expected to work. |
| `calculate_books_year_range` changes the weights of the 4 existing books RCs | Intended. Books rankings are not public yet. |
| Nested-param collision in `parent_from_params` | Prevented by construction — the lookup is scoped by domain (D3). |
