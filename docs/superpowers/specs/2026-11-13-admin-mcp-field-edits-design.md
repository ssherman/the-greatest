# Admin MCP: book and author field edits — design

## Intent

The admin MCP server should eventually do anything an admin can. After duplicates (#481), match
decisions and identifiers (#484) and descriptions (#497), the next gap is a record's own
fields. The motivating case is book 120812, a 2012 Naruto fanfic stored with
`first_published_year` 1936. An agent found the error but had no tool to fix it.

As before, every tool is a real `/api/v1/admin/...` REST endpoint, and its MCP tool is generated
from the OpenAPI `x-mcp` block. The endpoints are raw and final. Judgement about what to change
belongs in the prompt Shane gives the agent, not in the endpoint.

## Goals

- Let an agent read and edit the same fields the admin edit pages edit, and nothing more.
  - **Book:** `title`, `subtitle`, `sort_title`, `first_published_year`, `book_kind`, `original_language_id`, and `alternate_titles`.
  - **Author:** `name`, `sort_name`, `kind`, `birth_year`, `death_year`, `exclude_from_rankings`, and `alternate_names`.
- Make one shared save path per record type, used by both the edit pages and the API, so the two
  cannot drift.
- Make a field a human blanks on purpose stay blank. Today only the corrections flow (books only)
  stops the AI, Goodreads and VIAF enrichment from refilling a blanked field. A field blanked on
  the edit page, or through this API, gets refilled on the next run.

## Non-goals

- **Fields not on the edit pages:** gender, provisional, book length, page range and word count.
  Each can be added later as one more permitted key.
- **Book–author links, editions, series and relationships** are separate pieces.
- **Purging the edge cache.** Public pages still take up to about 25 hours to show a change, the
  same as for descriptions.
- **Remembering removed alternate titles or names.** Enrichment unions these lists, so a name the
  agent removes can come back. This is recorded as a known gap, not built here.

## Approaches considered

1. **A new `cleared_fields` table** (chosen). It covers books and authors the same way, and a row is
   deleted when the field is filled again. It costs one migration.
2. **Write each clear as an already-resolved correction with a blank value.** This needs no
   migration, but corrections are book-only, and every admin blank would look like a user report in
   the corrections history.

Shane picked 1.

## Design

### Cleared fields

- **Table:** a `cleared_fields` table, created with the Rails generator, holds:
  - `clearable` (polymorphic: `Books::Book` or `Books::Author`)
  - `field_name` (string)
  - `cleared_by` (a user, optional)
  - `cleared_via`, an enum `{admin_ui: 0, api: 1}` like `resolved_via`
  - timestamps
  - a unique index on `(clearable_type, clearable_id, field_name)`
- **Which fields can be cleared:** only the fields some enrichment job can refill.
  - Books: `subtitle`, `first_published_year` and `original_language_id`.
  - Authors: `birth_year` and `death_year`.
  - Every other field either cannot be blank (`title`, `name`, the enums, the boolean) or is never
    refilled (`sort_title`, `sort_name`), so it gets no row. The alternate lists get none either;
    see Non-goals. My call.
- **What counts as blank:** `nil`, or a string that is empty after stripping. `0` is a value.
- **Writes happen in the shared save services, in the same transaction as the save:**
  - when a clearable field goes from present to blank, the service upserts a row;
  - when a field that has a row becomes present again, the service deletes the row;
  - through the API only, sending `null` for a clearable field that is already blank also writes a
    row. This is the only way to protect a blank that existed before this feature. The edit page
    posts every field on every save, so on the page only an actual change counts. My call.
- **Undoing a clear:** a mistaken clear is undone by entering a value. There is no "un-clear but
  leave blank" action, which is acceptable for an admin tool. My call.
- **Reading for books:** `Services::Books::HumanClearedFields.for(book)` returns the union of the
  corrections-derived set and the `cleared_fields` rows. `ApplyBookFacts#apply_original_language`
  also checks it under the name `original_language_id`. Today that path skips the check, so a
  language blanked through a correction can be refilled too.
- **Reading for authors:** `Authors::FactSheet#year`, the one path every author job uses to write
  years, records `applied: false, reason: "human_cleared"` for a cleared `birth_year` or
  `death_year`.
- **Merges:** the book and author mergers carry the source's rows to the target when the target's
  field is still blank, and otherwise drop them. Corrections are not moved; that is today's
  behaviour, and this design leaves it alone. My call.

### Shared save services

- **The services:** `Services::Books::AdminUpdate` and `Services::Books::Authors::AdminUpdate`, each
  `.call(record:, attrs:, user:, via:)` returning a Result. Each one:
  - permits only the fields listed above;
  - assigns them and saves;
  - writes alternate titles through `Services::AlternateTitles::Writer.replace(source: :admin)`, as
    the page does today, or sets alternate names directly, as the page does today;
  - takes both lists as arrays. When the key is absent, the list is left alone. The author page
    splits its comma-separated `alternate_names_string` into an array before calling the service;
  - maintains `cleared_fields` rows.
- **Atomicity:** each save runs in one transaction. A validation failure writes nothing and returns
  `data[:code] = :invalid` with the errors.
- **The edit pages call these services.** Their behaviour is unchanged, except that blanking a field
  there is now remembered too.
- **The API's `via` and `user`** come from `Current.acting_user` and `Current.acting_via`.

### Endpoints and MCP tools

| Endpoint | Tool | Scope / policy |
|---|---|---|
| `GET /api/v1/admin/books/{id}` | `get_admin_book` | read |
| `PATCH /api/v1/admin/books/{id}` | `update_book` | write + `update?` |
| `GET /api/v1/admin/authors/{id}` | `get_admin_author` | read |
| `PATCH /api/v1/admin/authors/{id}` | `update_author` | write + `update?` |

- **Response:** every response returns the record's editable fields, its id, slug and authors (for a
  book), and `cleared_fields`, a list of field names.
- **PATCH is partial.** Keys that are not sent are left alone. Sending `null` or `""` for a scalar
  blanks it, and alternate-titles or alternate-names arrays replace the whole list.
- **Responses for bad input:**
  - an unknown key is 422, not ignored silently, so an agent's typo is visible;
  - an unknown `original_language_id` is 422;
  - a missing record is 404.
- **Enums take their string names** (`book_kind`, `kind`).
- **`admin_usage.md`:** these tools join the exemption from the ask-first rule.
- **Catalogue pin:** the admin tool count moves from 36 to 40.

## Constraints

- Follow the #497 patterns: a contract test for every documented status, catalogue pins,
  controller tests that assert behaviour and never copy, and `::`-qualified constants.
- Run annotaterb for the migration and model.

## Left to the builder

- Response serialiser naming, the file layout under `api/v1/admin/books/`, and how the edit pages'
  error re-render reads the Result.
