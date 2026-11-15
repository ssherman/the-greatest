# Admin MCP: book authors — design

Status: approved 2026-11-14. Short design (small change).

## Intent

Part of making the admin MCP able to do what an admin can do in the admin UI. An admin can add,
edit and remove a book's authors on the book page (`Admin::Books::BookAuthorsController`); the
admin MCP cannot. Fixing who wrote a book is the most common hand correction, and the
match-decision and repair-verdict work keeps surfacing wrong author links.

## Goals

- Three admin endpoints, each also an MCP tool generated from its x-mcp block (catalogue 46 → 49):

  | Endpoint | Tool |
  |---|---|
  | `POST /api/v1/admin/books/{id}/authors` | `add_book_author` |
  | `PATCH /api/v1/admin/books/{id}/authors/{author_id}` | `update_book_author` |
  | `DELETE /api/v1/admin/books/{id}/authors/{author_id}` | `remove_book_author` |

- Rows are addressed by **author id**, not the `books_book_authors` row id. The agent already has
  author ids from `get_admin_book` and `search_admin_authors`.
- **Add** takes `author_id` (required) plus optional `role`, `position`, `credited_as`.
  - `position` defaults to one past the book's current highest position (1 for a book with none).
  - An author already on the book is refused with 422, and the message points to update. A silent
    no-op would hide a different role or credit.
  - An author id that doesn't exist is 422.
- **Update** is partial like `update_book`: fields not sent are left alone; `null` clears
  `credited_as` (and `position`). Unknown key or unknown role is 422, a wrong type is 400, an
  empty body is 400. A book that does not have that author is 404.
- **Remove** deletes the row. Removing the last author is allowed, because the page allows it. A
  book that does not have that author is 404.
- Every call returns the book's full author list, ordered by position then id. Each entry has the
  author summary plus `role`, `position` and `credited_as`.
- `get_admin_book`'s `authors` entries gain the same `role`, `position` and `credited_as` fields
  (additive).
- Scope `books:admin:write` plus `BookPolicy#update?` on the book, the same gate as the page.
- The page and the API call one shared service, so their rules cannot drift. The page keeps its
  current behaviour, except that an add without a position now goes to the end of the list
  instead of being stored with no position.
- Search reindex keeps happening through `BookAuthor`'s existing `after_commit`.

## Non-goals

- Who/how stamping (`*_via`). `books_book_authors` has no such column, and categories and
  descriptions don't stamp either.
- A Copy prompt: there is no queue to work.
- Credits, book relationships, author relationships, series, editions: later pieces.
- Renumbering other rows when a position changes. The page doesn't, and the list order is
  position then id either way.
- A "replace the whole author list" tool, rejected because one bad call wipes every author.

## Approaches considered

1. **Per-row add, update and remove keyed by author id (chosen).** Mirrors the page and the
   `tag_book`/`untag_book` shape; each call changes one row.
2. **Replace the whole list in one call.** Fewer calls for a reorder, but one malformed call
   removes every author, and it does not match the page.
3. **Key rows by the `book_authors` row id.** It matches the page's routes, but the agent would
   need an extra lookup to find the row id, and nothing else in the admin API exposes it.

## Known gap

The Goodreads replay's `FixIdentity.link_authors` can re-link an author from the export to a
book an admin removed it from. The importers' author step does not, because it skips books that
already have authors. No "cleared" record is added for this piece.

## Left to the builder

- The service name and file (under `app/lib/services/books/`), its Result shape, and how its
  errors map to status codes.
- Whether the API controller reuses `FieldUpdate`'s raw-body parsing (it should, for the same
  `null` handling and ParamsWrapper reasons as `update_book`).
- Test, OpenAPI, contract-coverage and catalogue-pin updates, following the field-edits PR (#500).
- Docs: `docs/features/mcp-server.md` and the `admin_usage.md` ask-first exemption line.
