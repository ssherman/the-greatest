# Library API: a member's book lists over REST and MCP

**Status:** for approval · **Date:** 2026-11-16 · **Domain:** books only

## Why

Members with API or MCP access should be able to manage their own book lists by talking to an
agent: "mark *Middlemarch* as read", "create a list called *Summer 2027* and add these six books",
"what's on my want-to-read list?". Today the public API and the public MCP (`/api/mcp`) are
read-only catalogue tools. Every tool in this project is both a REST endpoint and an MCP tool,
generated from the `x-mcp` blocks in `config/api/v1/openapi.yaml`, and this feature follows that
rule.

The risk Shane raised is a careless or runaway agent: "add every single book on the site to this
list". The design answers it with three guards, agreed in conversation:

1. **No tool adds a search's results.** Every write names its books by slug, at most **50 per
   call**. Filling a list from a search means paging the search and sending the slugs back yourself.
2. **A daily budget of book changes, not of requests:** **1,000 book changes per member per UTC
   day** through the API. The request limit alone (60/minute, 5,000/day for members) would let 50
   books per call reach 250,000 books a day.
3. **Mistakes are cheap to undo.** Removal is batched like adding. Deleting a custom list, the one
   change that cannot be undone, is a destructive tool that MCP clients confirm with the user.

Plus a cap of **500 custom lists** per member, enforced on API creation (the largest member today
has 411). There is **no cap on the books a list may hold**: Goodreads imports already produced 47
lists over 2,000 books and one of 24,563, and a size cap would lock those members out of adding even
one book. The daily budget bounds how fast any list can grow.

## Goals

- A member can read their lists, see which of their lists a book is on, add and remove books,
  mark books read (with the date they finished), set a book's position, and create, edit and delete
  custom lists, over REST and MCP.
- The three guards above, enforced server-side and stated in the tool descriptions.
- The web UI and the API change lists through the same services, so the two can never disagree
  about what adding a book to *Read* does.

## Non-goals

- Other users' public lists (that is `user-lists-02d`'s public discovery).
- Music, games and movies lists. Books scopes only.
- Ratings, reviews, reading goals and saved searches. Later, separately.
- A web UI for the things the web UI lacks today (renaming, deleting and reordering lists). The API
  gets them first; the web UI is Phase B of user lists (`user-lists-02f`).
- Letting a member untick individual scopes on the OAuth consent screen.

## Anti-goals

- Any endpoint that changes books selected by a query rather than by name.
- A partially applied batch. A call either applies to every book it names or changes nothing.
- An API write that skips something the web write does (the *Reading* → *Read* move, reading-goal
  cache purges).

## Approaches considered

- **A. REST endpoints under `/api/v1/my/…`, with MCP tools generated from their `x-mcp` blocks
  (chosen).** Keeps the one-contract rule: the OpenAPI document is the API, the MCP is generated from
  it, and `Mcp::Dispatcher` runs the real controller.
- **B. MCP-only tools.** Faster to write, but breaks REST parity, and members who script against the
  REST API would not get it. Rejected.
- **C. A server-side "add these search results" tool.** The most convenient for an agent and the
  exact abuse vector Shane named. Rejected.

For the abuse guard, a request-only limit (not enough, see Why) and a per-list size cap (locks out
real members with imported lists) were rejected in favour of the daily book-change budget.

## Scopes and access

Two new scopes in `Api::Scopes::ALL`, both `admin: false`, both eligible on the same rule as
`books:read` (`READER`: a member, or a service account):

| Scope | Description (shown on the consent screen and the token page) | Implies |
|---|---|---|
| `books:library:read` | Read your book lists on The Greatest Books | — |
| `books:library:write` | Add, move and remove books on your lists, and create, edit and delete your custom lists | `books:library:read` |

- **OAuth:** the member resource (`mcp`, `/api/mcp`) offers `books:read`, `books:library:read` and
  `books:library:write` (`Oauth::Resources::Resource#scopes`). Connecting still requires
  `books:read`. **Existing connections keep only what they were granted**, so a member who
  connected before this ships reconnects to get the library tools; the docs say so.
- **Personal tokens:** the new scopes appear on the token page through `Api::Scopes.mintable_by`.
- **Admin scopes do not imply the library scopes.** A library is personal; an admin who is also a
  member mints or grants them like anyone else.
- **MCP:** library tools are listed only to a principal holding their scope
  (`Mcp::Catalog#tools_for`, unchanged). A lapsed member's token shrinks through
  `Api::Scopes.effective`, as today.

## Endpoints and tools (public catalogue 29 → 38)

All paths are `x-domain: books`. Lists are addressed by `{list}`, which is either a list id or one
of the four default list names: `favorites`, `read`, `reading`, `want_to_read`. That lets an agent
"mark as read" without first looking up an id. A list the caller does not own is a 404, never a
403, as on the web (`current_user.user_lists.find`). Books are addressed by catalogue slug, exactly
as `get_book` resolves them (`Books::Book.catalog.find_by!(slug:)`); a provisional book is unknown.

| Method and path | Tool | Scope | Notes |
|---|---|---|---|
| `GET /api/v1/my/lists` | `list_my_lists` | library:read | Default lists first, then custom ones, in the `/my/lists` order. Creates any missing default list first (`Services::UserLists::EnsureDefaults`). |
| `GET /api/v1/my/lists/{list}/books` | `list_my_list_books` | library:read | Paged like every collection. `sort`: `position` (default), `added` (newest first), `completed_on` (newest first, undated last; `read` list only, a 400 elsewhere). |
| `GET /api/v1/my/books/{slug}/lists` | `list_my_book_lists` | library:read | Which of my lists hold this book, with its position and completion date on each. Answers "have I read X?". |
| `POST /api/v1/my/lists` | `create_my_list` | library:write | Body: `name` (required), `description`, `public` (default false), `books` (optional slugs, at most 50). Always a custom list. |
| `PATCH /api/v1/my/lists/{list}` | `update_my_list` | library:write | Body: any of `name`, `description`, `public`. A default list's name is fixed (422); its description and `public` may change. |
| `DELETE /api/v1/my/lists/{list}` | `delete_my_list` | library:write | **`destructive: true`.** Custom lists only; a default list is a 422. |
| `POST /api/v1/my/lists/{list}/books` | `add_my_list_books` | library:write | Body: `books` (1–50 slugs), optional `completed_on` (`read` list only). |
| `PATCH /api/v1/my/lists/{list}/books/{slug}` | `update_my_list_book` | library:write | Body: any of `completed_on` (date or null; `read` list only) and `position` (1…item count). |
| `DELETE /api/v1/my/lists/{list}/books` | `remove_my_list_books` | library:write | Query: `books` (1–50 slugs). **`destructive: true`**: a removal loses the book's completion date and position. |

### Response shapes

- **List:** `id`, `name`, `list_type` (`favorites`, `read`, `reading`, `want_to_read`, `custom`),
  `default` (bool), `description`, `public`, `book_count`, `created_at`, `updated_at`, `url` (the web
  page, `/my/lists/{id}`), `api_url`, `books_api_url`.
- **List book:** `{position, added_at, completed_on, book}`, where `completed_on` is an ISO date or
  null and `book` is the public `Book` shape (rank = primary rank, or null), embedded the way
  `list_list_items` embeds it.
- **Write results:** one entry per named book, in request order: `{book: slug, outcome}`, where
  `outcome` is `added`, `moved` (taken off *Reading* by adding to *Read*), `already_present`,
  `updated` (an already-present book whose completion date changed), `removed` or `not_present` (a
  catalogue book that `remove_my_list_books` named but the list doesn't hold: a no-op, so a retried
  removal is safe; it still counts against the budget). The enum is public and only grows. Plus `meta.list`
  (the List shape) and `meta.library_changes_remaining` (today's remaining budget).
- `create_my_list` returns 201 with the List shape and, when `books` was sent, the same per-book
  results.

### Rules that carry over from the web

- **Adding to *Read* takes the book off *Reading*** and sets its completion date to today when it
  had none (`Services::UserLists::AddItem`'s transition). Adding to *Reading* or *Want to read*
  leaves *Read* alone. This is today's web behaviour, and the tool descriptions say so.
- **`completed_on`:**
  - It is accepted only for the `read` list (422 elsewhere), as an ISO date no later than today
    (400 otherwise; my call, to stop an agent writing a guessed future date).
  - On `add_my_list_books` it applies to every named book, including ones already on the list
    (outcome `updated`), so "I finished these in March" works whether or not they were there.
  - Without it, a book added to *Read* has no completion date, as on the web (it doesn't count
    toward reading goals until dated), unless the *Reading* → *Read* move dates it.
- **Positions are the stored ones (my call).** Hidden provisional books keep their places, so a
  list's visible positions can skip numbers (1, 2, 5). `position` on `update_my_list_book` may run
  from 1 to the list's total item count, hidden items included. Translating to dense visible
  positions would mean rewriting positions the member can't see.
- **Position:** setting a position moves the book there and renumbers the rest. It also sets the
  list's `manually_ordered`, because that is what the flag means, so a reordered favorites list is
  scored by position in the users' favorites ranking. Each ballot's total weight is unchanged
  (`Services::Lists::UserFavoritesTally`'s √N rule), so this cannot be used to gain influence.

## The guards

- **Batch size:** `books` holds 1–50 slugs (400 above or below). Duplicates in one request are
  collapsed before counting.
- **Unknown books:** any slug that is not a catalogue book makes the whole call a 404 that names
  every unknown slug. Nothing is changed.
- **All or nothing:**
  - Each write runs in one transaction under the owner's row lock, the lock the web path already
    takes for reading goals.
  - The per-book work goes through the existing services (`AddItem`, `RemoveItem`,
    `UpdateCompletion`).
  - A failure on any book rolls the call back.
- **Daily budget:**
  - `config.x.api.library_changes_per_day = 1_000`, the same for every tier. It lives on
    `config.x.rate_limit_store`, keyed by user (never by token), with a UTC-day window like
    `Services::Api::RateLimiter`'s day window.
  - Every book a call names counts once: added, moved, already present, updated or removed. The
    books sent with `create_my_list` count too. Creating, editing and deleting a list costs nothing,
    and neither do reads.
  - The call reserves its whole count before writing. If that would exceed the budget, the reserve
    is released and the call gets a **429 `rate_limited`** naming the remaining budget, with
    `Retry-After` set to the next UTC midnight, and nothing changes. A call that then fails for any
    other reason releases its reserve.
  - The web UI and Goodreads imports do not count.
- **Custom lists:** `config.x.api.max_custom_lists = 500`. A `create_my_list` that would exceed it
  is a 422. This applies to API creation only; the web's create is unchanged.
- **Field limits (my call):** `name` 1–100 characters and `description` up to 1,000, trimmed. The
  `text_param!` helpers already in `Api::V1::BaseController` apply.

## Errors

They follow the admin write endpoints' conventions, with existing `Api::Problem` codes only:

- **400:** malformed body or query, a wrong type, a bad date, or a batch outside 1–50.
- **404:** an unknown list (including another user's), or unknown book slugs.
- **422:** an unknown body key; a rule the request breaks (renaming or deleting a default list,
  `completed_on` off the *Read* list, a position past the end, the custom-list cap); or
  `update_my_list_book` on a book that isn't on the list.
- **429:** the request limit or the library budget, told apart by `detail`.

The public document has no 409 and gains none.

## Shared write path (constraint for the builder)

`UserListItemsController#mutate_with_books_goal_invalidation` holds the owner lock and the
reading-goal invalidation (`Services::Books::ReadingGoals::CompletionChangeInvalidator`, purge
enqueued after commit). The API must run exactly this, so it moves into a service that both
controllers call. A batch collects every completion-date change and enqueues one purge after
commit. The web controller's behaviour must not change; its existing tests are the check.

The JSON body helpers repeated in the admin controllers (`json_body`, `bad_body`, `unknown_fields`)
move to a concern that the public write controllers also include. The builder chooses the shape.

## MCP instructions

`config/mcp/books/instructions.md` gains a library paragraph:

- Library tools change the member's own lists.
- Confirm with the user before changing more than 25 books in one request, or before deleting a list
  or removing books.
- Never fill a list from search results unless the user asked for exactly that.
- Use the default list names (`read`, `reading`, `want_to_read`, `favorites`) rather than looking up
  ids.
- Pass `completed_on` when the user says when they finished a book.
- Adding to `read` takes the book off `reading`.
- `meta.library_changes_remaining` is the day's remaining budget.

## Known gaps (accepted)

- **The browser's cached list state lags API writes.** The book buttons on edge-cached pages read
  per-user state cached in the browser and re-checked hourly (`/user_list_state`, cached-user-state
  design). A write through the API sets no `tg_state_mark` cookie in the member's browser, so those
  buttons can show the old state for up to an hour. `/my/lists` is uncached and is right at once.
- **Provisional books are hidden.** Books from a Goodreads import that are not yet in the catalogue
  are left out of `list_my_list_books` and `book_count`, since the public API has no shape for them.
- **The legacy sync reverts writes until the cutover.** Until the books cutover, the weekly
  `data_migration:sync` puts lists that came from legacy back to match legacy
  (`docs/features/books-legacy-sync.md`, "Users' data"). Shane expects the cutover within a week of
  this spec, so no guard is built.
- **The API arrives before the web UI.** Renaming, deleting and reordering through the API come
  before the web UI can do them.

## Testing and docs

- **Controller tests** for every endpoint, covering every status above: the all-or-nothing
  rollback, the budget's reserve and release, the 429's `Retry-After`, the *Reading* → *Read* move,
  a default list addressed by name, another user's list as a 404, and the scope gates.
- **Unit tests** for the extracted write service, and for the scopes and the OAuth resource's offer.
- **Contract coverage** for every documented status of every new operation. **MCP tests** list the
  library tools only to a holder of the scope, and run `add_my_list_books` end to end.
- **Pins:** the tool directory, the developers page and the OpenAPI path lists are updated.
- **No E2E,** since there is no new page.
- **Docs:** `docs/features/public-api.md`, `mcp-server.md` and `user-lists.md` (API section, and
  the Phase B note).

## Left to the builder

Class and file names, the write service's shape, how `{list}` resolution is shared, the order of
custom lists within `list_my_lists` (match `/my/lists`), and the exact OpenAPI schema names.
