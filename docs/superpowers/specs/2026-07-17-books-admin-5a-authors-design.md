# Books admin — increment 5a: Authors CRUD + inline AuthorRelationships + images

**Status:** design approved 2026-07-17, pending plan.
**Parent design:** `docs/superpowers/specs/2026-07-13-books-admin-ui-design.md` (umbrella; increment 5,
"Authors + Series", and the entity table).
**Predecessors:** 4a (`Books::Book` CRUD — PR #169), 4b (`Books::Edition` CRUD — PR #170), 4c (inline
associations + author-search endpoint — PR #171), all merged.

## Goal

Grow the `#search`-only `Admin::Books::AuthorsController` (built in 4c) into a full `Books::Author`
admin at `/admin/authors` on the books host: an OpenSearch-backed index, full CRUD, and a show page
that manages the author's relationships and images in place. There is no importer for this data — the
admin is the only way to curate it.

## Scope

**In:**
- **Author CRUD** — index backed by `Search::Books::Search::AuthorGeneral` (OpenSearch) with sort +
  pagination, mirroring 4a's `BooksController#load_books_for_index`; `show`/`new`/`create`/`edit`/
  `update`/`destroy`. Fields: `name`, `sort_name`, `alternate_names` (array), `kind`
  (person/organization/pseudonym/collective), `birth_year`, `death_year`, `description`.
- **Inline AuthorRelationships** — on the author show page: an editable **from-side** card
  (this author `pseudonym_of` / `member_of` another) plus a **read-only inverse** card (authors whose
  relationship points *at* this one). Mirrors 4c's `BookRelationships`.
- **Author images** — nested `resources :images` riding the shared `Admin::ImagesController`, exactly
  as books/editions do.
- **`DomainNav` "Authors" item**, **`DomainRouting` `ENTITIES` + `NESTED_PARENTS[:books][:author_id]`**,
  and an **`exclude_id`** param on the author search (so the relationship picker can't offer the
  author itself).
- Minitest controller/registry/nav coverage + a Playwright smoke spec.

**Out:**
- **Series** (increment 5b) — its own design/plan/PR.
- **Categories** (increment 6) — the author show page renders **no** categories section and **no**
  `AddCategoryModalComponent` (see landmine below). `ENTITIES` `category_items_path: nil`.
- Any list / ranking-configuration work.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 5a-1 | **Split increment 5 into 5a (authors) / 5b (series)**, each its own design/plan/PR. | Owner call. Authors and series are independent subsystems sharing no code beyond the mirror pattern; each is ~8–9 tasks (about the size of 4a). Mirrors how increment 4 split into 4a/4b/4c once it grew large. |
| 5a-2 | Author CRUD is an **exact mirror of 4a's `BooksController`**, including the `alternate_names_string` comma-split virtual field (D9) with the `unless raw.nil?` guard. | The two entities are structurally identical (a slugged, OpenSearch-indexed record with one pg-array field). Reusing the proven 4a shape — sort allowlist, `AuthorGeneral` index / `AuthorAutocomplete` typeahead split, pagy 25 — costs nothing new. |
| 5a-3 | Inline `AuthorRelationships` **mirror 4c's `BookRelationshipsController`**: nested `create`, top-level `update`/`destroy`, all authorizing the **parent** `@author` via `authorize @author, :update?, policy_class: ::Books::AuthorPolicy`, rendering turbo_stream (replace `flash` + replace the frame). | This is the established inline-association UX. Authorizing the parent explicitly with `:update?` is exactly what avoids the 4b `set_default?` inferred-predicate `NoMethodError`. |
| 5a-4 | The author show page adds a **read-only inverse-relationships card** alongside the editable one. | Owner call. For the `pseudonym_of` / `member_of` relations, seeing who points *at* an author (its pseudonyms; a collective's members) is materially useful, and the relation is edited from the *other* author's page, so read-only is correct. Uses the existing `inverse_author_relationships` association — no new controller, route, or policy. |
| 5a-5 | `AuthorsController#search` gains an optional **`exclude_id`**, mirroring 4c's `BooksController#search`. | The from-side relationship picker must not offer the author being edited (the model's `no_self_reference` validation would reject it anyway; excluding it up front is the better UX). |
| 5a-6 | **No categories** on the author show page in 5a. `ENTITIES["Books::Author"]` registers `category_items_path: nil`; no `category_items` route; no `AddCategoryModalComponent`. | Same landmine 4a proved: `AddCategoryModalComponent#search_url` falls back to the **music** categories path when the books path is nil, and category items are STI with no type-mismatch validation — so a stray render could tag an author with a music genre. Deferred wholesale to increment 6. |

## The models (already exist — no schema changes)

- **`Books::Author`** — `name` (required), `sort_name`, `alternate_names` (pg `string[]`, default `[]`),
  `kind` (`enum {person:0, organization:1, pseudonym:2, collective:3}`, required), `birth_year`,
  `death_year`, `description`, `slug` (`friendly_id :name`). `include SearchIndexable`;
  `as_indexed_json` → `{name, alternate_names, category_ids}`. Associations already present:
  `author_relationships` (`foreign_key: from_author_id`, `dependent: :destroy`),
  `inverse_author_relationships` (`foreign_key: to_author_id`), `images`/`primary_image`,
  `external_links`, `categories`, `ranked_items`. Validates `name`, `kind` presence.
- **`Books::AuthorRelationship`** — `belongs_to :from_author, :to_author` (both `Books::Author`);
  `enum relation_type {pseudonym_of:0, member_of:1}, prefix: true`; unique
  `(from_author_id, to_author_id, relation_type)`; `no_self_reference` validation. No position.

## Routes

Grow 4c's `resources :authors, only: []` inside the books `DomainConstraint`
(`namespace :admin, module: "admin/books", as: "admin_books"`):

```ruby
resources :authors do
  resources :images, only: [:index, :create], controller: "/admin/images"
  resources :author_relationships, only: [:create]
  collection { get :search }
end

resources :author_relationships, only: [:update, :destroy]
```

Resulting helpers: `admin_books_authors_path` (index), `admin_books_author_path` (show/update/
destroy), `new_admin_books_author_path`, `edit_admin_books_author_path`, `admin_books_author_images_path`
(images), `admin_books_author_author_relationships_path(author)` (relationship create),
`admin_books_author_relationship_path(rel)` (relationship update/destroy),
`search_admin_books_authors_path` (unchanged from 4c).

## Controllers

- **`Admin::Books::AuthorsController`** — grown from `#search`-only to full CRUD:
  - `index` — `authorize ::Books::Author`; `AuthorGeneral.call(q, size: 1000)` → ids → `where(id:).in_order_of`
    when `q` present, else `::Books::Author.all.order(sortable_column(params[:sort]))`; `pagy(..., limit: 25)`.
    Sort allowlist keyed to `books_authors.{id,name,sort_name,kind,birth_year,death_year,created_at}`
    (SQL-injection guarded via `fetch` default), mirroring 4a.
  - `search` — add `book_ids.delete(params[:exclude_id].to_i) if params[:exclude_id].present?` guard
    (renamed to author ids), exactly like 4c's `BooksController#search`. Still **no `authorize`** (a
    search endpoint infers a nonexistent `search?` predicate and would raise; it relies on
    `authenticate_admin!`).
  - `show`/`new`/`create`/`edit`/`update`/`destroy` — mirror `BooksController`.
  - `author_params` → `permit(:name, :sort_name, :kind, :birth_year, :death_year, :description)`
    (**not** `alternate_names`). `assign_author_attributes(record)` assigns `author_params` then
    splits `params.dig(:books_author, :alternate_names_string)` on commas with the `unless raw.nil?`
    guard (absent field no-ops on update; empty string clears).
  - `before_action :set_author, :authorize_author, only: [:show, :edit, :update, :destroy]` — grown
    incrementally per task (`raise_on_missing_callback_actions` is on; never name an action before it
    exists).

- **`Admin::Books::AuthorRelationshipsController`** — inline, mirroring `BookRelationshipsController`:
  - `create` — `@author = ::Books::Author.find(params[:author_id])`;
    `authorize @author, :update?, policy_class: ::Books::AuthorPolicy`;
    `@author.author_relationships.build(author_relationship_params)`.
  - `update`/`destroy` — `set_author_relationship` (`before_action only: [:update, :destroy]`);
    `@author = @author_relationship.from_author`; authorize the parent `:update?`.
  - `author_relationship_params` → `permit(:to_author_id, :relation_type)`.
  - turbo_stream: replace `flash` (partial `admin/shared/flash`) + replace `author_relationships_list`
    (partial `admin/books/authors/author_relationships_list`, locals `{author: @author}`); html
    fallback redirects to `admin_books_author_path(@author)`. Error path replaces `flash` with the
    record's `full_messages`, `status: :unprocessable_entity`.

## Registry

- **`Admin::DomainRouting`**
  - `ENTITIES["Books::Author"] = {domain: :books, path: ->(r) { admin_books_author_path(r) }, category_items_path: nil}`.
  - `NESTED_PARENTS[:books][:author_id] = "Books::Author"` (author images resolve their parent here).
- **`Admin::DomainNav`** — append to `CONFIGS[:books][:items]`:
  `{label: "Authors", icon: :artist, path: -> { URL_HELPERS.admin_books_authors_path }}` (the `:artist`
  icon already exists). This is the load-bearing sidebar link (the sidebar skips empty sections, so
  the nav item must ship with the routes — the mistake 4a shipped without).

## Views

Mirror 4a's book views + 4c's relationship partials; DaisyUI-5 throughout.

- **`index.html.erb` + `_table.html.erb`** — `Admin::SearchComponent` (placeholder "Search authors by
  name…", `turbo_frame: "authors_table"`); sortable columns Name / Sort Name / Kind / Birth–Death;
  row actions `View` / `Edit` / `Delete` in the 4b `flex … btn-outline btn-xs` pattern; `pagy.series_nav`.
- **`_form.html.erb`** — the **DaisyUI-5 `<div class="form-control">` + `f.label class:"label"` +
  `w-full` card pattern** (mirror `books/_form`, **not** `<label class="form-control">`): `name`* (text,
  autofocus), `sort_name` (text), `kind` (`f.select` over `::Books::Author.kinds.keys`), `birth_year` /
  `death_year` (number), `alternate_names_string` (`text_field_tag`, comma-separated, seeded from
  `@author.alternate_names.join(", ")`), `description` (textarea). `new.html.erb` / `edit.html.erb`
  render it.
- **`show.html.erb`** — header (Back / Edit-if-write / Delete-if-delete, `turbo_confirm`); Basic
  Information card (Kind, Birth Year, Death Year, Sort Name, Alternate Names, Description); Metadata
  card (id / slug / created / updated); **Images** card (lazy `turbo_frame_tag "images_list"` →
  `admin_books_author_images_path`, upload modal); **Relationships** card (count + "+ Add" →
  `add_author_relationship_modal`, renders `author_relationships_list` **directly**); **Inbound
  Relationships** read-only card. **No categories section.**
- **`_author_relationships_list.html.erb`** — `turbo_frame_tag "author_relationships_list"`; table
  (Relation badge, Related Author link `data: {turbo_frame: "_top"}`, Edit/Remove actions gated on
  `current_user_can_write?`); per-row edit modal (relation_type select); empty state. **The show-page
  card renders this partial directly — no outer `turbo_frame_tag` wrap** (the 4c dup-id landmine).
- **Add modal** `add_author_relationship_modal` — `AutocompleteComponent(name: "books_author_relationship[to_author_id]",
  url: search_admin_books_authors_path(exclude_id: @author.id))` + relation_type select, `modal-form`
  Stimulus controller, `turbo_frame: "author_relationships_list"`.
- **Inbound (read-only) card** — iterate `@author.inverse_author_relationships.includes(:from_author)`:
  each row shows the `from_author` (link, `turbo_frame: "_top"`) and its `relation_type` badge; empty
  state "No inbound relationships." No frame, no add/edit/remove.
- Author picker autocomplete results are `<li class="cursor-pointer">` (not `role=option`) — the
  established `AutocompleteComponent` markup.

## Reindex / dev prereq

The author OpenSearch index is empty in dev by default. **Reindexed 2026-07-16 via
`bin/rails search:books:recreate_authors`** (58,193 authors; `AuthorGeneral("Tolstoy")` /
`AuthorAutocomplete("tol")` verified returning hits). Reviewers/testers who exercise the live index or
typeahead re-run the same task; unit tests stub `AuthorGeneral` / `AuthorAutocomplete`.

## Testing

- **`authors_controller_test.rb`** (extends 4c's search tests): `index` with and without `q` (stub
  `AuthorGeneral`; assert 200 + pagy); `search` JSON shape + `exclude_id` filtering (stub
  `AuthorAutocomplete`); `create`/`update`/`destroy` (params, redirect, `alternate_names` comma-split,
  empty-string-clears, `kind` set); auth (writer allowed, regular user redirected).
- **`author_relationships_controller_test.rb`**: `create`/`update`/`destroy` (turbo_stream format +
  record created/updated/removed); parent-policy auth (writer allowed, regular user redirected);
  `no_self_reference` rejection (create with `to_author_id == author_id` → 422 / error flash); image
  upload not in scope here.
- **Image upload** — `fixture_file_upload` integration assertion (`Image.count` +1, attaches to the
  author), mirroring 4a.
- **Registry / nav** — `ENTITIES["Books::Author"]` + `NESTED_PARENTS[:books][:author_id]` resolve;
  `DomainNav` books items include "Authors".
- **Playwright** `e2e/tests/books/admin/authors.spec.ts` — index lists + "New Author" link; create →
  show happy path; add an AuthorRelationship via the live typeahead (assert it appears in the frame).
  Use name-based input selectors where `getByLabel` is ambiguous (the 4a lesson).

## Landmines (carried, verified against current code 2026-07-17)

- **No categories section** on the author show page (STI + music-path fallback; deferred to inc 6).
- **Ship the `DomainNav` "Authors" item with the routes** (sidebar skips empty sections) and **ship
  Delete/Remove buttons with the destroy actions** (both were missed in 4a and needed follow-ups).
- **DaisyUI-5 form pattern** = `<div class="form-control">` + `f.label class:"label"` + `w-full`
  inputs in a `card` (mirror `books/_form`), **not** `<label class="form-control">`.
- **Do not double-wrap the turbo frame** — the show-page card renders `_author_relationships_list`
  directly; the partial opens `turbo_frame_tag "author_relationships_list"`. Wrapping both = duplicate
  DOM id (invalid HTML, breaks strict Playwright).
- **Typeaheads use `AuthorAutocomplete`** (edge-ngram `name.autocomplete`); the index page uses
  `AuthorGeneral`. Do not swap them (the 4c Codex fix).
- **`raise_on_missing_callback_actions` is on** — grow `before_action only: […]` lists only as actions
  land.
- **Search endpoints do not call `authorize`** — they rely on `authenticate_admin!`.
- **Inline controllers authorize the parent explicitly** (`authorize @author, :update?`), never a bare
  `authorize @author` (which would infer a nonexistent predicate).

## Carried-over caveats (unchanged from 4a–4c)

- The shared `Admin::ImagesController` still lacks `DomainScopedAuth`, so only global admins/editors
  (not domain-only editors) can manage images — true for all domains equally, a separate follow-up.
- Books curators are global admins in practice.
