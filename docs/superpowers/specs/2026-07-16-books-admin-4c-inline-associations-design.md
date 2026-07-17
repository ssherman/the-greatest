# Books admin — increment 4c: Inline associations (BookAuthors, Credits, BookRelationships) + author search

**Status:** design approved 2026-07-16, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 4, decisions D5/D9 and the entity table).
**Predecessors:** 4a (`Books::Book` CRUD — PR #169) and 4b (`Books::Edition` CRUD — PR #170), both merged.

## Goal

Add inline management of a book's (and edition's) associations to the books admin: the people who
made the book (`Books::BookAuthor`, `Books::Credit`) and its relationships to other books
(`Books::BookRelationship`), plus the author-search endpoint those pickers need. Each association is
managed **in place on the parent's show page** — there is no importer to fix this data, so the admin
is the only way to curate it.

## Scope

**In:**
- **Author-search endpoint** — `Admin::Books::AuthorsController#search` returning typeahead JSON from
  `Search::Books::Search::AuthorGeneral`. A **partial controller: only `#search` now** (full author
  CRUD is increment 5).
- **BookAuthors** — inline on the book show page (author picker, `role` author/editor, `position`,
  `credited_as`).
- **Credits** — inline on **both** the book and edition show pages (polymorphic `creditable`; author
  picker, `role` [10 values], `position`).
- **BookRelationships** — inline on the book show page (related-book picker, `relation_type` [5]).
- A small `exclude_id` enhancement to 4a's `BooksController#search` (so the related-book picker
  can't offer the current book).

**Out:** full author CRUD + author index + author nav item (**increment 5**); categories
(**increment 6**); any list/RC work.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 4c-1 | **One increment / one PR** for all of 4c (author search + the three associations). | Owner call. The pieces share the author-search endpoint and the inline turbo_stream pattern; building them together establishes that pattern once and avoids 3× the design/plan/PR ceremony. ~9–11 tasks. |
| 4c-2 | The inline pattern **mirrors `Admin::Music::AlbumArtistsController`**: a card on the parent show page with a count + "+ Add" button opening a **modal** (add-form with `AutocompleteComponent` + selects), an eager `turbo_frame` rendering a list partial (rows + per-row **Edit** modal + **Remove** `button_to`), and controllers responding with **turbo_stream** (replace flash + replace the frame; html fallback to the parent show page). | This is the established, working inline-association UX in this admin. List-partial action columns use the **4b DaisyUI-5 row-actions pattern** (flex row + `btn-outline btn-xs`). |
| 4c-3 | **Three focused controllers** (`BookAuthorsController`, `CreditsController`, `BookRelationshipsController`), **not** a shared concern. | Music's `ArtistAssociationActions` concern exists because album/song artists are ~95% identical. Books' three associations are heterogeneous (Credits is polymorphic; BookRelationships has no author/position), so a shared concern would carry a large, leaky config surface. Three self-contained ~50–70-line controllers are each independently understandable/testable; the repeated turbo_stream block is boilerplate, not logic. |
| 4c-4 | Author search lives on a **`#search`-only `Admin::Books::AuthorsController`** (route `resources :authors, only: [] do collection { get :search } end`), which increment 5 later fills out with full CRUD + index + nav item. | Mirrors 4a's book `search` collection action; keeps the eventual authors controller in its natural home. No `DomainNav` item yet (author index is inc 5). |
| 4c-5 | Each association controller **authorizes the parent** (`BookPolicy`/`EditionPolicy` `:update?`); search authorizes `::Books::Author` via `AuthorPolicy`. **No new policies.** | Exactly how music authorizes album-artist changes via `AlbumPolicy` `:update?`. All four policies exist from increment 3. |
| 4c-6 | Credits' **polymorphic parent** resolves via `Admin::DomainRouting.parent_from_params` — `book_id` and `edition_id` are already registered in `NESTED_PARENTS[:books]` (4a + 4b). **No registry changes.** | The infrastructure already distinguishes the two creditable types by their nested param. |
| 4c-7 | 4a's `Admin::Books::BooksController#search` gains an optional **`exclude_id`** param. | The related-book picker must not offer the book being edited (mirrors music's `search_admin_albums_path(exclude_id:)`). |

## The models (already exist — no schema changes)

- **`Books::BookAuthor`** — `belongs_to :book, :author`; `enum role {author:0, editor:1}`; `position`,
  `credited_as`; unique `(book_id, author_id)`. **`after_commit` re-indexes the book** (`author_names`
  in the book index) — automatic; nothing to wire.
- **`Books::Credit`** — `belongs_to :author`, `belongs_to :creditable, polymorphic: true`;
  `enum role {translator…ghostwriter}` (10); `position`; `ordered` scope. Validates author,
  creditable, role presence. Does not index.
- **`Books::BookRelationship`** — `belongs_to :book, :related_book`;
  `enum relation_type {contains…related_to}` (5, `prefix: true`); unique
  `(book_id, related_book_id, relation_type)`; `no_self_reference` validation. No position. Does not
  index.

## Routes (mirror games' shallow join-model shape)

Nested `create` under the parent; top-level `update`/`destroy`; author `search` collection. Inside
the books `DomainConstraint`, `namespace :admin, module: "admin/books", as: "admin_books"`:

```ruby
resources :books do
  resources :editions, shallow: true do
    member { post :set_default }
    resources :images, only: [:index, :create], controller: "/admin/images"
    resources :credits, only: [:create]          # edition credits
  end
  resources :images, only: [:index, :create], controller: "/admin/images"
  resources :book_authors, only: [:create]
  resources :book_relationships, only: [:create]
  resources :credits, only: [:create]            # book credits
  collection { get :search }
end

resources :book_authors, only: [:update, :destroy]
resources :book_relationships, only: [:update, :destroy]
resources :credits, only: [:update, :destroy]
resources :authors, only: [] do
  collection { get :search }
end
```

Resulting helpers: `admin_books_book_book_authors_path(book)` (create),
`admin_books_book_author_path(ba)` (update/destroy), analogous for relationships; credits nested
under book (`admin_books_book_credits_path`) and edition (`admin_books_edition_credits_path`),
shallow `admin_books_credit_path`; `search_admin_books_authors_path`.

## Controllers

Each controller: nested `create`, top-level `update`/`destroy`, all rendering turbo_stream (replace
`flash` + replace the association's frame with its list partial), html fallback to the parent show
page. Authorize the parent via its policy `:update?`. **Grow `before_action only:[…]` lists per
action** (`raise_on_missing_callback_actions` is on).

- **`Admin::Books::BookAuthorsController`** — parent = book (`book_id`); params `author_id, role,
  position, credited_as`; frame `book_authors_list`, partial `admin/books/books/book_authors_list`.
- **`Admin::Books::CreditsController`** — parent = **polymorphic** creditable, resolved via
  `DomainRouting.parent_from_params(params, domain: :books)` (book **or** edition); params
  `author_id, role, position`; frame + partial + redirect branch on the creditable type
  (`book_credits_list` / `edition_credits_list`). This is the one controller with type branching.
- **`Admin::Books::BookRelationshipsController`** — parent = book (`book_id`); params
  `related_book_id, relation_type`; frame `book_relationships_list`.
- **`Admin::Books::AuthorsController`** — `#search` only: `AuthorGeneral.call(params[:q], size: 20)`
  → `[{value: id, text: name}]`. `authorize ::Books::Author`.

## Views

- **Book show page** (`admin/books/books/show.html.erb`) gains three cards — **Authors**, **Credits**,
  **Related Books** — each: header (count + "+ Add" button), an eager `turbo_frame` rendering the
  list partial, and an add-modal (`AutocompleteComponent` picker + selects → nested create,
  `turbo_frame: "<frame>"`). Per-row **Edit** modal (position/role/credited_as) + **Remove**
  `button_to`.
- **Edition show page** (`admin/books/editions/show.html.erb`) gains a **Credits** card (same
  `CreditsController`, edition creditable). (This is the credits section 4b deferred.)
- **Pickers:** author → `AutocompleteComponent(url: search_admin_books_authors_path)`; related book
  → `AutocompleteComponent(url: search_admin_books_books_path(exclude_id: @book.id))`.
- List-partial action columns follow the 4b DaisyUI-5 row-actions pattern.

## Reindex / dev prereq

- `BookAuthor` changes re-index the book automatically (`after_commit`; suppressed in migrations via
  `Services::BooksMigration.search_indexing_suppressed?`).
- **Author OpenSearch index:** empty in dev by default (like books). **Reindexed for this work on
  2026-07-16 via `bin/rails search:books:recreate_authors`** (58,193 authors; `AuthorGeneral("Tolstoy")`
  verified returning hits). Reviewers/testers who need the live author typeahead run the same task;
  unit tests stub `AuthorGeneral`.

## Testing

- **Controller tests** per controller (`book_authors`, `credits`, `book_relationships`, `authors#search`):
  create (turbo_stream + record created), update, destroy, parent-policy auth (writer allowed,
  regular user redirected), `#search` JSON shape. Stub `AuthorGeneral` in the search test.
  Credits tests cover **both** creditable types (book and edition).
- **No new policy tests** (parent policies exist; author policy exists).
- **Playwright smoke** `e2e/tests/books/admin/associations.spec.ts` — on a book: add an author
  (typeahead), add a credit, add a related book; on an edition: add a credit. The author/book
  typeaheads exercise the live indices (reindexed above).

## Carried-over caveats (unchanged from 4a/4b)

- The shared `Admin::ImagesController` still lacks `DomainScopedAuth` — unrelated to 4c.
- No `DomainNav` change (all inline; author index/nav is inc 5).
