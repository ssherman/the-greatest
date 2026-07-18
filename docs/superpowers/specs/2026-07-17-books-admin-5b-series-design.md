# Books admin — increment 5b: Series CRUD + inline SeriesBooks + representative_book + images

**Status:** design approved 2026-07-17, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 5,
"Authors + Series"; the entity table and decision D10).
**Predecessors:** 4a/4b/4c and **5a (`Books::Author` — PR #172, merged `8c6cf69`)**, the direct mirror.

## Goal

A full `Books::Series` admin at `/admin/series` on the books host: an SQL-`ILIKE`-backed index, full
CRUD, and a show page that manages the series' books (`Books::SeriesBook`) in place — a book typeahead,
`position`/`numbered`/`position_label`, and a per-row "Make representative" that sets the series'
`representative_book`. Plus series images. There is no importer for this data — the admin is the only
way to create it (`books_series` / `books_series_books` are currently empty tables).

## Scope

**In:**
- **Series CRUD** — index backed by SQL `ILIKE` on `title` (D10 — there is **no** OpenSearch series
  index), with sort + pagination, mirroring 5a's `AuthorsController` minus its search. `show`/`new`/
  `create`/`edit`/`update`/`destroy`. Fields: `title`, `description`.
- **Inline `SeriesBooks`** on the series show page — a book typeahead (the existing `BookAutocomplete`),
  `position` (decimal), `numbered` (bool), `position_label`. Create/update/destroy mirror 5a's inline
  pattern.
- **Representative book** — a per-row **"Make representative"** action on the SeriesBooks list that sets
  `series.representative_book_id` to that row's book (mirrors editions' `set_default`). The current
  representative shows a ★ badge; the resolved representative is displayed inside the same turbo frame.
- **Series images** — nested `resources :images` riding the shared `Admin::ImagesController` via
  `NESTED_PARENTS[:books][:series_id]`.
- **`DomainNav` "Series" item**, **`DomainRouting` `ENTITIES` + `NESTED_PARENTS[:books][:series_id]`**,
  Minitest coverage, and a Playwright smoke spec.

**Out / not applicable:**
- **No JSON `#search` action** — nothing consumes a series typeahead (the SeriesBooks and
  representative pickers use the existing book typeahead). The index's own filter is server-side SQL.
- **No categories** — `Books::Series` has **no** categories association at all (not a deferral, simply
  absent). No categories card, no `AddCategoryModalComponent`.
- **No OpenSearch** — Series is not `SearchIndexable`.
- No inbound/directional relationships (unlike authors), no array-column virtual field (Series has none).

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 5b-1 | **One increment / one PR** (Series is a single entity + one inline association). | ~7 tasks, the size of 5a. No split needed. |
| 5b-2 | Series CRUD mirrors 5a's `AuthorsController` **minus search**; the index filters via SQL `ILIKE` on `title`, `sanitize_sql_like`-guarded. | Only `BookIndex`/`AuthorIndex` exist (D10). Building a series index isn't justified by the admin's needs, and the table is small relative to books. |
| 5b-3 | `representative_book` is set via a per-row **"Make representative"** button on the SeriesBooks list, not a form field. | Owner call. Keeps the whole workflow (add books + pick representative) on the show page, guarantees the representative is one of the series's books (matching the model's `resolved_representative_book` fallback to `series_books.first&.book`), and avoids an `AutocompleteComponent` edit-prefill problem. Mirrors the proven editions `set_default`. |
| 5b-4 | The "Representative: …" line and the ★ badges live **inside** the `series_books_list` turbo frame. | So `make_representative` / create / update / destroy all keep the representative display fresh via a single turbo_stream frame replace — and it sidesteps the stale-badge-outside-the-frame issue the 5a review noted. |
| 5b-5 | `SeriesBooksController` (incl. `make_representative`) authorizes the **parent series explicitly** — `authorize @series, :update?, policy_class: ::Books::SeriesPolicy` — in every action. | The 4b/4c/5a-proven inline pattern; a bare `authorize @series` would infer a nonexistent predicate (`make_representative?`) and raise (the 4b `set_default?` bug). |
| 5b-6 | Accept Rails' `series_index` route-helper naming (see landmine) rather than forcing a custom `as:`/`path:`. | `series` is uncountable; the default naming is standard and understood. Overriding it adds surface for no gain. |

## ⚠️ Landmine — `series` is a Rails *uncountable* noun (singular == plural)

`resources :series` resolves the index/show helper collision by naming the **index** route
`admin_books_series_index_path` (GET `/admin/series`), while show/create/update/destroy use
`admin_books_series_path(record)` (GET/PATCH/DELETE `/admin/series/:id`), `new_admin_books_series_path`,
`edit_admin_books_series_path(record)`. **The nav item, the index view's "New Series" link and search
form, the `_table` sort links, and every controller `redirect_to` to the collection must use
`admin_books_series_index_path`.** The plan's Task 1 verifies the exact helper names with
`bin/rails routes -g series` before wiring any view.

## The models (already exist — no schema changes)

- **`Books::Series`** — `title` (required), `description`, `slug` (`friendly_id :title`),
  `representative_book_id` (FK → `books_books`, `ON DELETE nullify`, optional). `belongs_to
  :representative_book`; `has_many :series_books, -> { order(:position) }`; `books` through; `images`/
  `primary_image`; `external_links`; `identifiers`; `ai_chats`. `resolved_representative_book` =
  `representative_book || series_books.first&.book`. **Not `SearchIndexable`; no categories.** Validates
  `title` presence.
- **`Books::SeriesBook`** — `belongs_to :series, :book`; `numbered` (bool, default true), `position`
  (`decimal(8,2)`), `position_label`; unique `(series_id, book_id)`. No validations beyond uniqueness.

## Routes

Inside the books `DomainConstraint` (`namespace :admin, module: "admin/books", as: "admin_books"`):

```ruby
resources :series do
  resources :images, only: [:index, :create], controller: "/admin/images"
  resources :series_books, only: [:create]
end
resources :series_books, only: [:update, :destroy] do
  member { post :make_representative }
end
```

Resulting helpers (verify in Task 1): `admin_books_series_index_path` (index),
`admin_books_series_path` (show/update/destroy), `new_admin_books_series_path`,
`edit_admin_books_series_path`, `admin_books_series_images_path(series)`,
`admin_books_series_series_books_path(series)` (create), `admin_books_series_book_path(sb)`
(update/destroy), `make_representative_admin_books_series_book_path(sb)`.

## Controllers

- **`Admin::Books::SeriesController`** (mirrors 5a `AuthorsController` minus `search`):
  - `index` — `authorize ::Books::Series`; when `params[:q]` present,
    `::Books::Series.where("title ILIKE ?", "%#{::Books::Series.sanitize_sql_like(params[:q])}%").order(:title)`;
    else `::Books::Series.all.order(sortable_column(params[:sort]))`; `pagy(..., limit: 25)`. Sort
    allowlist keyed to `books_series.{id, title, created_at}` with a safe `fetch` default.
  - `show`/`new`/`create`/`edit`/`update`/`destroy` — standard; `series_params` →
    `permit(:title, :description)`. `before_action :set_series, :authorize_series` grown per task.
- **`Admin::Books::SeriesBooksController`** (inline; mirrors 5a `AuthorRelationshipsController` +
  editions `set_default`):
  - `create` — `@series = ::Books::Series.find(params[:series_id])`;
    `authorize @series, :update?, policy_class: ::Books::SeriesPolicy`;
    `@series.series_books.build(series_book_params)`.
  - `update`/`destroy` — `set_series_book` (`before_action only: [:update, :destroy, :make_representative]`);
    `@series = @series_book.series`; authorize `:update?`.
  - `make_representative` — `@series = @series_book.series`; authorize `:update?`;
    `@series.update!(representative_book_id: @series_book.book_id)`.
  - `series_book_params` → `permit(:book_id, :position, :numbered, :position_label)`.
  - All render turbo_stream: replace `flash` (`admin/shared/flash`) + replace `series_books_list`
    (`admin/books/series/series_books_list`, locals `{series: @series}`); html fallback → the series
    show page. Error path replaces `flash`, `status: :unprocessable_entity`.

## Registry

- `ENTITIES["Books::Series"] = {domain: :books, path: ->(r) { admin_books_series_path(r) }, category_items_path: nil}`.
- `NESTED_PARENTS[:books][:series_id] = "Books::Series"`.
- `DomainNav` `CONFIGS[:books][:items]` `+ {label: "Series", icon: :series, path: -> { URL_HELPERS.admin_books_series_index_path }}`
  (the `:series` icon already exists; **note the `_index` helper**).

## Views

Mirror 5a authors + 4c/5a inline partials; DaisyUI-5 throughout.

- **`index.html.erb` + `_table.html.erb`** — `Admin::SearchComponent` (placeholder "Search series by
  title…", `turbo_frame: "series_table"`, url `admin_books_series_index_path`); sortable columns Title /
  Created; row actions View/Edit/Delete in the `flex … btn-outline btn-xs` pattern; `pagy.series_nav`.
- **`_form.html.erb`** — DaisyUI-5 `form-control` + `w-full` card: `title`* (text, autofocus),
  `description` (textarea). `new.html.erb` / `edit.html.erb` render it. (No representative field here.)
- **`show.html.erb`** — header (Back / Edit / Delete gated); Basic Information card (Description);
  Metadata card (id/slug/created/updated); **Images** card (lazy `images_list` frame → 
  `admin_books_series_images_path`, upload modal); **Books in Series** card (header title + "+ Add" → 
  `add_series_book_modal`, renders `series_books_list` **directly** — no outer frame wrap; no count
  badge in the header, so nothing goes stale after an inline turbo update — the frame owns all mutable
  content per 5b-4). No categories.
- **`_series_books_list.html.erb`** — `turbo_frame_tag "series_books_list"` containing: a
  "Representative: *[resolved_representative_book title or —]*" line, then the table (columns: Position,
  Book link `turbo_frame: "_top"`, Numbered, Label, Actions). The representative row shows a ★ badge; the
  others show a "★ Make representative" `button_to` → `make_representative_admin_books_series_book_path`.
  Edit (per-row modal: position/numbered/position_label) + Remove `button_to`, gated `current_user_can_write?`.
  Empty state "No books in this series yet."
- **Add modal** `add_series_book_modal` — `AutocompleteComponent(name: "books_series_book[book_id]",
  url: search_admin_books_books_path)` + `position` (number, default `@series.series_books.maximum(:position).to_i + 1`)
  + `numbered` (checkbox, default checked) + `position_label` (text), `modal-form` Stimulus,
  `turbo_frame: "series_books_list"`.

## Testing

- **`series_controller_test.rb`**: index with/without `q` (SQL `ILIKE` — a real match + a no-match, no
  stubbing needed since it's SQL); sort-injection tolerance; CRUD (create/update/destroy, params,
  redirect, title-required 422); auth (writer allowed, regular user redirected, unauthenticated
  redirected, books editor allowed).
- **`series_books_controller_test.rb`**: create/update/destroy (turbo_stream + record delta);
  `make_representative` (sets `series.representative_book_id`, redirects/renders); parent-policy auth
  (writer allowed, regular user redirected); uniqueness `(series_id, book_id)` rejection.
- **Image upload** — `fixture_file_upload` integration assertion (`Image.count` +1, attaches to the
  series), mirroring 5a.
- **Registry / nav** — `ENTITIES["Books::Series"]` + `NESTED_PARENTS[:books][:series_id]` resolve;
  `DomainNav` books items include "Series" pointing at `admin_books_series_index_path`.
- **Playwright** `e2e/tests/books/admin/series.spec.ts` — index lists + "New Series" link; create → show;
  add a book to the series via the live book typeahead; click "Make representative" and assert the ★ /
  representative line updates. Name-based selectors where `getByLabel` is ambiguous.

## Landmines (carried from 5a + the series-specific one)

- **`series_index` helper naming** (see the dedicated section) — the #1 5b-specific trap.
- **DaisyUI-5 form pattern** (`<div class="form-control">` + `w-full`, mirror `authors/_form`).
- **Row-actions** `flex items-center justify-end gap-1` + `btn btn-outline btn-xs whitespace-nowrap`
  (Remove/Delete `+ btn-error`).
- **Do not double-wrap the turbo frame** — the show-page card renders `_series_books_list` directly; the
  partial opens `turbo_frame_tag "series_books_list"` once.
- **`raise_on_missing_callback_actions` is on** — grow `before_action only: […]` per task.
- **Inline controller authorizes the parent explicitly** (`authorize @series, :update?`), incl.
  `make_representative` — never a bare `authorize @series`.
- **Ship the `DomainNav` "Series" item + Delete/Remove buttons with the routes/actions.**
- Book typeahead uses the existing `BookAutocomplete` (`search_admin_books_books_path`) — no new search.

## Carried-over caveats (unchanged, cross-domain, out of scope)

- The shared `Admin::ImagesController` still lacks `DomainScopedAuth` (only global admins/editors manage
  images) — true for all domains and now flagged by Codex on 5a (PR #172), tracked as a separate
  cross-domain follow-up. Series images ride the identical shared path.
