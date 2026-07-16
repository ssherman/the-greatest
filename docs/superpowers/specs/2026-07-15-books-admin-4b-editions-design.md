# Books admin — increment 4b: Editions

**Status:** design approved 2026-07-15, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; editions specified by decision D5 and the entity table).
**Predecessor:** increment 4a (`Books::Book` CRUD) — merged in PR #169.

## Goal

Add full admin management of `Books::Edition` under the books admin at
`new.thegreatestbooks.org/admin`, on top of the `Books::Book` CRUD shipped in 4a. An edition is
the second tier of the two-tier book model and `books.default_edition_id` drives the public
display (cover, publisher, page count), so — unlike `Music::Release`, which is read-only in the
music admin — editions need full CRUD here: there is no importer to fix bad edition data (D5).

## Scope

**In:**
- Nested `Books::Edition` CRUD under a book (no top-level index, no sidebar link — D5).
- A lazy turbo-frame **Editions** card on the book show page listing the book's editions.
- A dedicated edition show page carrying details, a read-only **Identifiers** card, and cover
  **Images**.
- `member { post :set_default }` writing `books.default_edition_id`.
- Edition cover images via the shared `Admin::ImagesController`.

**Out — deferred to 4c:** Credits on the edition show page, BookAuthors, BookRelationships, the
author-search endpoint.
**Out — not applicable:** categories on editions (editions have no categories); any edition
search/typeahead (editions are SQL-only per D10, and nothing in 4b needs to search them).

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 4b-1 | Editions list on the book show page **lazy-loads** via a `turbo_frame_tag` pointing at the nested `index` action, mirroring how the Images card loads. | Consistent with the existing image-card pattern; keeps the book show page fast. Books average ~1.2 editions each, so the list itself is tiny. |
| 4b-2 | Edition **create/edit are full pages** (mirroring the book form); each edition has its **own show page**. Not modals. | ~10 fields is cramped in a modal, and D5 explicitly calls for an edition show page because there is no importer to repair edition data. |
| 4b-3 | The form exposes **10 fields**: `title, subtitle, edition_type, book_binding, publication_year, publisher_name, page_count, volume_number, language_id, popularity`. `metadata` (jsonb) is hidden. | Owner call: `popularity` (a migration-derived signal that originally seeded `default_edition`) stays hand-editable even though nothing currently reads edition popularity for public display. `metadata` has no UI. |
| 4b-4 | `default_edition_id` is managed **only** via `set_default` on an edition — the book form does **not** get a default-edition picker. | Chicken-and-egg: no editions exist at book-create time. `set_default` is the single mechanism, matching 4a (the book form already omits `default_edition`). |
| 4b-5 | Editions use **default shallow routing** → member URLs at `/admin/editions/:id`. | Standard Rails shallow behavior; no custom `shallow_path` needed. |
| 4b-6 | Register `Books::Edition` in `DomainRouting::ENTITIES`. | Makes `Admin::ImagesController`'s HTML-fallback redirect (`path_for(parent)`) land on the edition instead of `admin_root`. Costs one line in the `domain_routing_test` path_for loop. |
| 4b-7 | **No** `DomainNav` entry for editions. | D5: no sidebar link. The 4a "every controller increment must add a nav item" landmine deliberately does **not** apply here. |

## Routes

Inside the books `DomainConstraint`, `namespace :admin, module: "admin/books", as: "admin_books"`:

```ruby
resources :books do
  resources :editions, shallow: true do
    member { post :set_default }
    resources :images, only: [:index, :create], controller: "/admin/images"
  end
  resources :images, only: [:index, :create], controller: "/admin/images"
  collection { get :search }
end
```

Resulting paths (all helpers keep the `admin_books_` name prefix):

| Action | URL | Helper |
|---|---|---|
| index (nested) | `GET /admin/books/:book_id/editions` | `admin_books_book_editions_path(book)` |
| new / create (nested) | `/admin/books/:book_id/editions/new`, `POST …/editions` | `new_admin_books_book_edition_path(book)` |
| show / edit / update / destroy (shallow) | `/admin/editions/:id` | `admin_books_edition_path(edition)` |
| set_default (member, shallow) | `POST /admin/editions/:id/set_default` | `set_default_admin_books_edition_path(edition)` |
| edition images (shallow) | `/admin/editions/:edition_id/images` | `admin_books_edition_images_path(edition)` |

## Registry changes — `Admin::DomainRouting`

- `NESTED_PARENTS[:books]` += `edition_id => "Books::Edition"` — **required**: edition images
  resolve their parent through `parent_from_params`, which iterates this map. (No collision with
  `book_id`: shallow edition-image requests carry only `edition_id`.)
- `ENTITIES` += `"Books::Edition" => { domain: :books, path: ->(r) { admin_books_edition_path(r) }, category_items_path: nil }` (decision 4b-6).

## Controller — `Admin::Books::EditionsController < Admin::Books::BaseController`

Actions: `index, show, new, create, edit, update, destroy, set_default`.

- `index, new, create` load the parent book from `params[:book_id]`; `show, edit, update,
  destroy, set_default` load `@edition` from `params[:id]`.
- Pundit: `authorize ::Books::Edition` on index/new; `authorize @edition` on the rest.
- `set_default`: `@edition.book.update!(default_edition_id: @edition.id)`, then redirect to the
  book show page with a notice. One-liner — no service object (not business logic warranting a
  Result).
- Strong params permit the 10 fields of decision 4b-3.
- **Callback-list landmine (from 4a, item b):** `raise_on_missing_callback_actions` validates the
  entire `before_action only: […]` list on every dispatch — grow those lists exactly as actions
  land; never name a not-yet-defined action.

## Views

- **Book show page** (`admin/books/books/show.html.erb`) gains:
  - a full-width **Editions** card: `turbo_frame_tag "book_editions", src: admin_books_book_editions_path(@book), loading: :lazy`;
  - a small "Default Edition" line linking to the current default edition (or "—").
- **`editions/index`** (`layout: false`, rendered into the `book_editions` frame): a table of the
  book's editions (type · year · binding · publisher), a `★ Default` badge on the current
  default, per-row Edit / Delete / **Set default** controls, and a **New Edition** link. Every
  action control carries `data: { turbo_frame: "_top" }` so it breaks out of the lazy display
  frame into full-page navigation.
- **`editions/_form`** — the 10 fields in the DaisyUI-5 `<div class="form-control">` + `w-full`
  card pattern copied from `books/_form` (4a landmine f). Enum `select`s for `edition_type` /
  `book_binding`; `collection_select` for `language_id`.
- **`editions/show`** — a details card, a **read-only Identifiers** card (identifiers stay
  display-only), and an **Images** card reusing the shared `images_list` frame + add-image modal
  exactly as the book show page does.
- **`editions/new` / `editions/edit`** — full pages mirroring `books/`.

Delete and Set-default controls are guarded by `current_user_can_delete?` /
`current_user_can_write?`, with `turbo_confirm` on delete, and ship **with** their actions (4a
landmine g — never ship a destroy with no UI).

## Behavior notes

- **Deleting the default edition:** the `default_edition_id` FK is `ON DELETE nullify`, so
  `books.default_edition_id` clears automatically. `book has_many :editions, dependent: :destroy`
  cascades when a book is deleted. No manual cleanup.
- **Model:** `Books::Edition` needs no changes — validations/associations already exist.

## Testing

- `test/controllers/admin/books/editions_controller_test.rb` — mirror the games nested-controller
  tests: every action; `set_default` writes `default_edition_id`; params; auth; domain isolation.
  Fixtures `books_editions(:wp_maude)` / `(:wp_volume_one)` already exist under `war_and_peace`.
- `test/lib/admin/domain_routing_test.rb` — add the `ENTITIES` path_for line
  (`books_editions(:wp_maude) => "/admin/editions"`) and a `parent_from_params` case for
  `edition_id`.
- No new policy test — `test/policies/books/edition_policy_test.rb` exists from increment 3.
- Playwright smoke `e2e/tests/books/admin/editions.spec.ts` — create an edition → set it default →
  verify (per CLAUDE.md's "every new user-facing page/flow needs an E2E test"; the full suite
  remains increment 7).

## Carried-over caveat (not fixed here)

The shared `Admin::ImagesController` inherits the base global-admin/editor `authenticate_admin!`
and does not include `Admin::DomainScopedAuth`, so domain-only book editors cannot manage edition
images — only global admins/editors can. This is the same pre-existing, cross-domain limitation
that already affects book images (4a) and music/games images; out of scope for 4b.
