# Admin MCP Book and Author Field Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let an admin agent read and edit a book's and an author's own fields over REST and MCP, the same fields the admin edit pages edit, and make a field a human blanks on purpose stay blank against enrichment refills.

**Architecture:**
- A new shared `cleared_fields` table is written by two new shared save services, one for books and one for authors.
- The admin edit pages and four new admin API endpoints both call those services.
- The endpoints are documented with `x-mcp` blocks in `config/api/v1/admin_openapi.yaml`, so `Mcp::Catalog` generates the tools.
- The book and author enrichment paths read `cleared_fields` before they fill a blank.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, Alba resources, Pundit policies.

**Spec:** `docs/superpowers/specs/2026-11-13-admin-mcp-field-edits-design.md`

## Global Constraints

- **Running things:**
  - Run commands from `web-app/`.
  - Never run brakeman.
  - Lint with `bundle exec standardrb`.
  - Never run two test suites at once in one worktree.
  - `bin/rails db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. If the annotation diff shows columns this branch's `schema.rb` does not have, delete only those lines.
- **Tests:**
  - Use generators for the model and migration.
  - Controller tests assert behaviour only: status, JSON keys and values, DB state. They may assert API problem `detail` substrings and never assert HTML or copy.
  - Use `assert_nil` (Minitest 6).
  - Root-anchor `::Books::` inside `Api::V1::Admin::Books` and `Services::Books`.
- **Raw endpoints:** refuse only bad data or missing permission. `admin_usage.md` adds the four tools to the existing ask-first exemption line, the one the description tools are on.
- **Editable fields** (spec, exact):
  - Book: `title`, `subtitle`, `sort_title`, `first_published_year`, `book_kind`, `original_language_id`, `alternate_titles`.
  - Author: `name`, `sort_name`, `kind`, `birth_year`, `death_year`, `exclude_from_rankings`, `alternate_names`.
- **Clearable fields** (spec, exact):
  - Book: `subtitle`, `first_published_year`, `original_language_id`.
  - Author: `birth_year`, `death_year`.
- **Blank:** `nil`, or a string that is empty after `strip`. `0` is a value.
- **`cleared_via`** is the enum `{admin_ui: 0, api: 1}`, taken from `Current.acting_via`, with the user taken from `Current.acting_user`.
- **Patterns to copy:**
  - `app/controllers/api/v1/admin/books/descriptions_controller.rb`: `require_scopes`, `StrictIds`, `POLICIES`, `log_change`, `render_problem`.
  - `app/lib/services/descriptions/admin_write.rb`: the Result and `data[:code]` shape.
- **Admin tool-count pins** (36 → 40) live in:
  - `test/lib/mcp/admin_catalog_test.rb`
  - `test/lib/mcp/tool_directory_test.rb`
  - `test/controllers/api/mcp_admin_controller_test.rb`
  - `test/controllers/api/v1/admin/openapi_controller_test.rb`
  - `test/integration/api/v1/admin_contract_coverage_test.rb`

## Rulings (Claude's calls; the spec leaves these to the builder)

- **Model:** `ClearedField` is a global model, like `Correction`, with these fields:
  - `clearable` (polymorphic)
  - `field_name`
  - `cleared_by` (`belongs_to :cleared_by, class_name: "User", optional: true`, FK `on_delete: :nullify`)
  - `cleared_via`
  - a unique index on `[clearable_type, clearable_id, field_name]`

  Books and authors get `has_many :cleared_fields, as: :clearable, dependent: :delete_all`.
- **Year bounds:** the API takes years as integers in −3000..3000, matching the author form's min and max. Anything else is a 400. The model gains no new validation.
- **Status codes:**
  - wrong JSON type: 400
  - unknown key, or unknown `original_language_id`: 422
  - model validation failure: 422, with `errors`
  - missing record: 404
  - non-admin: 403
  - empty body: 400
- **Enums:** they take and return their string names. An unknown enum name is 422.
- **Alternate lists:** `alternate_titles` and `alternate_names` are arrays of strings, stripped, with blanks dropped. When the key is absent, the list is left alone.

## Review Focus

1. **PATCH `{"first_published_year": null}` on a book that has a year.**
   - The year becomes nil, a `cleared_fields` row is written with `cleared_via: "api"`, and the response's `cleared_fields` includes it.
   - A following `ApplyBookFacts` or Goodreads `Apply` run with a year fact records `human_cleared` and does not fill it. (Task 1 tests the readers; Task 4 tests the end-to-end.)
2. **A partial PATCH changes only what it sends.**
   - Sending only `subtitle` leaves the title, the year, alternate titles and every existing cleared row untouched.
3. **Already-blank fields.**
   - API `null` on an already-blank clearable field writes a row.
   - An edit-page save that leaves a blank field blank writes none.
   - Setting a value deletes the row.
4. **A failed save writes nothing.**
   - For example `{"title": "", "first_published_year": null}`: 422, the year is unchanged, no row is written, and alternate titles are unchanged.
5. **Merges.**
   - A source's cleared row moves to the target when the target's field is blank, and is dropped otherwise.
   - No `cleared_fields` row ever points at a deleted record.

---

### Task 1: `cleared_fields` table and the enrichment readers

**Files:**
- **Generate:** the `ClearedField` model and migration (`bin/rails g model ClearedField clearable:references{polymorphic} field_name:string cleared_by:references cleared_via:integer`, then edit the migration for the null constraints, the unique index and the nullify FK to `users`).
- **Modify:**
  - `app/models/books/book.rb` and `app/models/books/author.rb` (the association)
  - `app/lib/services/books/human_cleared_fields.rb`
  - `app/lib/services/books/apply_book_facts.rb` (`apply_original_language`)
  - `app/lib/services/books/authors/fact_sheet.rb` (`#year`)
  - `app/lib/books/book/merger.rb` and `app/lib/books/author/merger.rb`
- **Test:**
  - `test/models/cleared_field_test.rb`
  - `test/lib/services/books/human_cleared_fields_test.rb`, which exists, or create it
  - the existing `apply_book_facts`, `fact_sheet` (or `apply_author_facts`) and both merger tests

**Interfaces:**
- **Produces:**
  - `ClearedField` with `enum :cleared_via, {admin_ui: 0, api: 1}` and the constant `ClearedField::CLEARABLE = {"Books::Book" => %w[subtitle first_published_year original_language_id], "Books::Author" => %w[birth_year death_year]}.freeze`
  - `Services::Books::HumanClearedFields.for(book) → Set<String>`, now the corrections set ∪ `book.cleared_fields.pluck(:field_name)`
- **Behaviour:**
  - `FactSheet#year(name, value)`: when `author.cleared_fields` has `name`, it records `applied: false, reason: "human_cleared"` and leaves the value nil.
  - `ApplyBookFacts#apply_original_language`: `human_cleared?(:original_language_id)` gives the reason `"human_cleared"`.

- [ ] **Write the failing tests:**
  - the model: uniqueness per record and field, and the enum
  - `HumanClearedFields` includes a `cleared_fields` row and still includes a correction clear
  - `ApplyBookFacts` with a cleared `original_language_id` and a language fact: not applied, reason `human_cleared`
  - `ApplyBookFacts` and Goodreads `Apply` with a cleared `first_published_year`: not applied
  - `FactSheet#year` with a cleared `birth_year`: author unchanged, reason `human_cleared`
  - the book and author mergers: a source row moves to a target whose field is blank, and is dropped when the target's field is present (Review Focus 5)
  - destroying a book deletes its rows
- [ ] **Run them:** they FAIL.
- [ ] **Implement:** run the migration, check the annotation diff, implement.
- [ ] **Run them again,** plus `test/lib/services/books` and `test/lib/books`: they PASS. Then commit.

### Task 2: Shared save services; the edit pages use them

**Files:**
- **Create:**
  - `app/lib/services/books/admin_update.rb`
  - `app/lib/services/books/authors/admin_update.rb`
- **Modify:**
  - `app/controllers/admin/books/books_controller.rb` (`create` stays as is; `update` calls the service, passing `alternate_titles` only when the form posted the key, as `submitted_alternate_titles` does today)
  - `app/controllers/admin/books/authors_controller.rb` (`update` calls the service; it splits `alternate_names_string` on commas into an array first, and passes it only when posted)
- **Test:**
  - `test/lib/services/books/admin_update_test.rb`
  - `test/lib/services/books/authors/admin_update_test.rb`
  - the existing `test/controllers/admin/books/books_controller_test.rb` and `authors_controller_test.rb` stay green, plus a page test for Review Focus 3

**Interfaces:**
- **Consumes:** `ClearedField`, `ClearedField::CLEARABLE`.
- **Produces:**
  - `Services::Books::AdminUpdate.call(book:, attrs:, user:, via:) → Result`
  - `Services::Books::Authors::AdminUpdate.call(author:, attrs:, user:, via:) → Result`
- **Contract:**
  - `attrs` is a string-keyed Hash containing only editable-field keys, already typed. `via` is `"admin_ui"` or `"api"`, and `user` may be nil.
  - The service also takes `explicit_nulls: [field names]`, default `[]`. These are clearable fields the caller asked to blank even if they are already blank; the API passes the keys it received as `null`, and the page passes `[]`.
  - It runs in one transaction:
    1. assign the attributes;
    2. write `alternate_titles` through `Services::AlternateTitles::Writer.replace(record:, titles:, source: :admin, user:)`, or assign `alternate_names`;
    3. save;
    4. for each clearable field, upsert a row (`cleared_by: user`, `cleared_via: via`) when it went from present to blank, or is in `explicit_nulls` and is blank, and delete the row when it is now present.
  - Any failure rolls everything back.
  - On success: `Result(success?: true, data: {record:, changed: [field names]})`.
  - On a validation failure: `Result(success?: false, data: {code: :invalid}, errors: record.errors.full_messages)`, with nothing written.

- [ ] **Write the failing service tests**, each for both services where it applies:
  - present → blank writes a row stamped with the user and via
  - blank → value deletes the row
  - blank → blank writes no row without `explicit_nulls`, and writes one with it
  - a non-clearable field blanked (`sort_title`) writes no row
  - a partial `attrs` leaves the other fields and alternate titles alone (Review Focus 2)
  - a validation failure writes nothing (Review Focus 4)
  - alternate titles replace through the Writer with source `admin`
- [ ] **Write the failing page test:** an edit-page update that blanks `first_published_year` writes a row with `cleared_via: "admin_ui"`, and a save that leaves an already-blank year blank writes none.
- [ ] **Implement both services and switch the two `update` actions.** The existing page tests pass unchanged.
- [ ] **Run** the new tests and `test/controllers/admin/books`: they PASS. Then commit.

### Task 3: Read endpoints

**Files:**
- **Create:**
  - `app/lib/api/v1/admin/books/book_detail_resource.rb`
  - `app/lib/api/v1/admin/books/author_detail_resource.rb`
- **Modify:**
  - `app/controllers/api/v1/admin/books/books_controller.rb` (`show`)
  - `app/controllers/api/v1/admin/books/authors_controller.rb` (`show`)
  - `config/routes.rb`
  - `config/api/v1/admin_openapi.yaml`
  - the pins (36 → 38)
- **Test:**
  - `test/controllers/api/v1/admin/books/books_controller_test.rb`
  - `test/controllers/api/v1/admin/books/authors_controller_test.rb`
  - contract coverage

**Interfaces:**
- **Routes and tools** (scope `books:admin:read`):
  - `GET /api/v1/admin/books/{id}` → `get_admin_book`
  - `GET /api/v1/admin/authors/{id}` → `get_admin_author`
  - both with `constraints: {id: /\d+/}`
- **Book response** (`{data: {...}}`, in this key order): `id, slug, title, subtitle, sort_title, first_published_year, book_kind, original_language ({id, name} | null), alternate_titles, provisional, authors (AuthorSummaryResource), cleared_fields`.
- **Author response** (same envelope, in this key order): `id, slug, name, sort_name, kind, birth_year, death_year, exclude_from_rankings, alternate_names, provisional, cleared_fields`.
- **`cleared_fields`** is a sorted array of field names.
- **Tool descriptions** say these return exactly the fields `update_book` and `update_author` take.

- [ ] **Write the failing tests:**
  - 200 with every key for a fixture book and author, `cleared_fields` included after creating a row
  - 404 for an unknown id
  - 403 for a non-admin
  - the read scope is sufficient
- [ ] **Implement:** the endpoints, the OpenAPI entries with `x-mcp`, and the pins 36 → 38.
- [ ] **Run** the new tests, `test/lib/mcp`, `test/controllers/api` and `test/integration/api`: they PASS. Then commit.

### Task 4: Update endpoints and docs

**Files:**
- **Modify:**
  - the Task 3 controllers (`update`)
  - `config/routes.rb`
  - `config/api/v1/admin_openapi.yaml`
  - the pins (38 → 40)
  - `config/mcp/books/admin_usage.md`
  - `docs/features/mcp-server.md`
  - the feature doc under `docs/features/` that covers enrichment's `human_cleared` rule, if one exists (grep for `human_cleared`)
- **Test:** the Task 3 controller tests and contract coverage.

**Interfaces:**
- **Consumes:** `Services::Books::AdminUpdate`, `Services::Books::Authors::AdminUpdate` (Task 2), and the Task 3 resources.
- **Routes and tools:**
  - `PATCH /api/v1/admin/books/{id}` → `update_book`
  - `PATCH /api/v1/admin/authors/{id}` → `update_author`
  - scope `books:admin:write` plus the policy's `update?`
- **Request:** a flat JSON object holding any subset of the editable fields.
- **Response:** 200 with the Task 3 detail shape, plus `changed: [field names]`.
- **Call:** `via: Current.acting_via`, `user: Current.acting_user`, and `explicit_nulls` set to the clearable keys sent as `null` or `""`.
- **Logging:** `log_change`, as descriptions do.

- [ ] **Write the failing tests:**
  - the status codes in Rulings:
    - an unknown key → 422 naming the key
    - `first_published_year: "abc"` → 400
    - year 5000 → 400
    - an unknown `original_language_id` → 422
    - an unknown `book_kind` → 422
    - `title: ""` → 422 with nothing written (Review Focus 4)
    - an empty body → 400
    - a non-admin → 403
    - the read scope only → 403
  - Review Focus 1, end to end:
    - PATCH a year to null → the row is written with `api`, and the response lists the field in `cleared_fields`
    - a following `Services::Books::ApplyBookFacts.call` with a year fact leaves it nil
  - Review Focus 2: a PATCH of only `subtitle` → only the subtitle changes, and `changed == ["subtitle"]`
  - Review Focus 3: `null` on an already-blank year writes a row
  - the author equivalents: `birth_year` null, `alternate_names` replaced, an unknown `kind` → 422
- [ ] **Implement:**
  - the endpoints, the OpenAPI entries with `x-mcp`, and the pins 38 → 40
  - the `update_book` description says that blanking a year, subtitle or language stops enrichment refilling it, and that setting a value lifts that
  - the `admin_usage.md` exemption line
  - the docs
- [ ] **Run** the new tests, then the full `bin/rails test` and `bundle exec standardrb`. Both are clean, with no new warnings. Commit.
