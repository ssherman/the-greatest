# Admin MCP: duplicate review — design

Date: 2026-11-09. Status: draft for Shane's approval.
Builds on `2026-11-02-mcp-server-design.md` (tools generated from `admin_openapi.yaml` `x-mcp` blocks,
dispatched in-process to the real API controllers) and `2026-11-02-mcp-oauth-design.md` (sign-in).

## Why

Shane wants to hand the duplicate queue (`/admin/books/duplicate_candidates`) to an AI agent — Codex,
ChatGPT or Claude — and say "research these and merge or reject them". Pre-launch, this is the priority:
match decisions and corrections follow as their own specs, in that order, with the same shape.

The admin MCP endpoint (`/api/mcp/admin`) can already search books and authors and merge them, but an
agent cannot see the queue, cannot dismiss a pair, and a merge through `merge_book` leaves no trace of
who decided or why. ChatGPT is confirmed working against `/api/mcp/admin` (OAuth sign-in, a read, and a
`merge_book` dry run, 2026-11-09).

## How Shane will use it

1. On the duplicates admin page he clicks **Copy prompt**.
2. He pastes it into his agent, trims or adjusts it, and sends it.
3. The agent lists pending pairs with the MCP tools, researches each one (its own web search plus the
   tools), and merges or dismisses it with a note, without asking per pair.
4. Afterwards he reviews the resolved pairs, with their notes, on the same admin page.

## Goals

- Four admin MCP tools over the duplicate queue: list, get, merge, dismiss.
- Every resolution the agent makes records **who** (the token's user), **why** (an optional note) and that
  it came **through the API**.
- A **Copy prompt** button on the duplicates admin page that copies a ready-made starting prompt.

## Non-goals

- Match decisions and corrections (next specs).
- Editing book or author fields (titles, subtitles, country, …). That belongs to the corrections spec.
- Any agent running on our servers. The agent is Shane's client; the server only offers tools.
- Workflow logic on the server (batching, auto-deciding, scoring). The workflow lives in the prompt.
- Music and games queues. The API and MCP are books-only today; the design must not block adding them.

## Anti-goals

- A merge the agent did not see: merging must be tied to the pair and refuse if the pair changed.
- Server-side rules about how the agent should behave. Shane: "these are raw endpoints with not many
  rules." The endpoints only refuse what would be wrong data (a resolved pair, a survivor that is not in
  the pair, a missing record, no permission); the workflow and judgement live in the prompt.
- House rules baked into server text Shane cannot trim. Rules belong in the copyable prompt.

## Design

### REST endpoints (admin API, books domain)

All under `/api/v1/admin/duplicate_candidates`, each with an `x-mcp` block so the MCP tool is generated
the same way as every other admin tool. Scope is the queue's `item_type` for the books domain
(`Books::Book`, `Books::Author`), as the admin page does via `DataImporters::FinderRegistry`.

| Tool | Endpoint | Scope | What it does |
|---|---|---|---|
| `list_duplicate_candidates` | `GET /api/v1/admin/duplicate_candidates` | `books:admin:read` | Paged list. Filters: `status` (default `pending`), `item_type` (`book`/`author`, default both). Each pair: id, item type, source (why it was raised), created_at, status, resolution (note, resolved_at, resolved_by email) when resolved, and both records' summaries. |
| `get_duplicate_candidate` | `GET /api/v1/admin/duplicate_candidates/{id}` | `books:admin:read` | One pair with fuller evidence for each side: the summary plus, for books, description (truncated), subtitle, alternate titles and the lists the book is on; for authors, their own equivalents (description, alternate names, books with ranks). Plus the linked match decision's reasoning if there is one. |
| `merge_duplicate_candidate` | `POST /api/v1/admin/duplicate_candidates/{id}/merge` | `books:admin:merge` | Body: `target_id` (which of the pair survives), `source_id` (the one deleted), `note` (optional), `dry_run` (default false, as the other merges). Refuses unless the pair is pending and `{source_id, target_id}` are exactly the pair's two ids (amended in build: `target_id` alone let a pair re-keyed by an earlier merge delete a record the agent never judged). Runs the same `Services::Books::AdminMerge` and delete-permission check as `merge_book`/`merge_author`, then stamps the pair. Returns what `merge_book` returns plus the pair. |
| `dismiss_duplicate_candidate` | `POST /api/v1/admin/duplicate_candidates/{id}/dismiss` | `books:admin:write` | Body: `record_ids` (the pair's two ids, as last seen), `note` (optional). Refuses unless pending and `record_ids` match the pair. Sets `not_duplicate`, `resolved_at`, `resolved_by`, `resolution_note`. |

Notes:

- **Summaries reuse `FinderBase#summarize_all`**, the same evidence the admin page shows (title, creators,
  year, ranked position, list count, identifiers). One query per type, not per pair.
- **A pair whose record was deleted** (merged away elsewhere) is listed with that side marked missing.
  Merge refuses it; dismiss is allowed.
- **Staleness.** The merger's `RecordMerge` hook re-keys other pending pairs onto the survivor, so a pair's
  ids can change between list and merge. Merge takes the pair id plus `target_id`, and refuses if
  `target_id` is no longer one of the pair's ids. The agent re-fetches and decides again. This is the API
  form of the admin page's "only the records the form showed" check.
- **Recording.** `RecordMerge` already marks the pair merged. The endpoint additionally sets `resolved_by`
  and `resolution_note` on it. Both writes log `event=api_admin_duplicate ...` like `api_admin_merge`.
- **Through the API.** Add `resolved_via` to `duplicate_candidates` (enum: `admin_ui`, `api`; nullable for
  old rows). The admin page's merged/not-duplicate tabs show it, and gain a filter for it, so Shane can
  review exactly what an agent did.
- **Every resolution is stamped, whatever the path** (my call): `resolved_by` and `resolved_via` are set on
  every merge and dismiss — the queue page (`admin_ui`), a book's or author's own admin page merge
  (`admin_ui`), `merge_book`/`merge_author` (`api`, no note) and the new tools (`api`, with note). Today the
  admin page's merge sets neither. Since `RecordMerge` is the one place every merger marks the pair, the
  stamp belongs there (or in whatever carries who/how down to it); the builder picks the mechanism. An
  agent that uses `merge_book` instead of the new tool must still show up under the `api` filter.
- **Pair gone.** `RecordMerge` can destroy a pending pair row (re-keyed onto an existing pair, or
  collapsed onto the survivor). `get`/`merge`/`dismiss` on a missing pair return 404 with a detail telling
  the agent to re-list; no attempt to find where it went (my call).
- **Dismiss permission** (my call): the scope `books:admin:write` plus the same domain-write check the admin
  page uses (`require_domain_write!` semantics) on the token's user.

### Server-side MCP text

Server text describes what tools do and their hard limits, nothing more.

- Each new tool's `x-mcp` description says what it does, that `merge` deletes the source permanently,
  that `note` is optional and shown to the admin, and that a refusal for a changed pair means re-fetch.
- **The queue tools are for agents deciding on their own — Shane's decision.** "The whole point of this
  endpoint is I want the agent to make a decision on the decisions the AI left for me. The endpoints
  should be final real merges." So `merge_duplicate_candidate` and `dismiss_duplicate_candidate` are
  final: a call with `dry_run` omitted or false merges for real, and no server text tells the agent to
  ask the user first. `dry_run: true` stays available but is optional.
- **`config/mcp/books/admin_usage.md` conflicts with this today.** It says to run every merge "only after
  the user agrees … agreement to one merge is not agreement to the next". Add a section for the queue
  tools saying they are the exception: the agent decides each pair itself. One short paragraph, no more rules.
  The existing ask-first rule stays for `merge_book`, `merge_author`, `merge_categories`,
  `delete_admin_category` and untagging, which are for ad-hoc chat use, and their descriptions do not
  change.

### Copy prompt

- A **Copy prompt** button on the duplicates admin page (books), using the existing
  `clipboard_copy_controller`. It copies the text; it does not open anything or call an agent.
- The text lives in a Markdown file in the repo, e.g. `config/mcp/books/prompts/duplicates.md`, rendered
  into the page when it loads (the clipboard controller copies text already on the page) with the admin
  MCP URL (from `Api::Host.base_url`) and the pending counts for books and authors (already in `@counts`).
- Starting content (Shane trims it per run):
  - The job: work through the pending duplicate pairs, books and authors, using
    `list_duplicate_candidates`/`get_duplicate_candidate`, plus web research where the records alone
    don't settle it.
  - The method per pair: get it, research if unclear, decide; merge it (choosing the survivor) or
    dismiss it, always with a note. You are authorised to merge and dismiss without asking me. If you
    genuinely cannot tell, skip it and say why.
  - House rules (from the project's past decisions):
    - The English edition is the canonical book and should survive a merge.
    - "Unknown", "Anonymous", "Various" and place-named authors (e.g. "China") are deliberate
      placeholders, not people. Never merge a person into them or treat them as wrong.
    - A collection, omnibus or poetry umbrella book is not a duplicate of the works inside it.
    - Translations of the same work are one book. A translator credited as author is a data problem,
      not a reason to keep two books.
    - Prefer the survivor with the better rank, more lists and better identifiers, unless the rules
      above say otherwise.
  - Notes: one or two sentences per pair, with the evidence (e.g. a URL or identifier).
  - Report at the end: merged, dismissed, skipped — each with the pair id and one line of reasoning;
    include any merge `warnings` verbatim.

### Tests

- Request tests for the four endpoints: scopes, refusals (not pending, wrong `target_id`, missing record,
  no permission), dry run changes nothing, real merge stamps `resolved_by`/note/`resolved_via`.
- MCP catalogue/tool-directory pin tests bumped for the four new admin tools; contract coverage.
- Admin page: controller test for the `resolved_via` filter (behaviour only); a Playwright E2E for
  **Copy prompt** (button present, clipboard gets text containing the MCP URL).
- Changing `admin_usage.md`: update any test that pins that text.

### Docs

- `docs/features/mcp-server.md`: the four tools and the copy-prompt workflow.
- `docs/features/import-finder.md` (the duplicate queue's doc): `resolved_via` and the API path.

## Left to the builder

- Exact JSON shape of a pair (follow the existing admin resources' style).
- Page size (match the other admin list endpoints).
- How much description to include in `get` (truncate; a few hundred characters is enough).
- Whether the prompt file is ERB or a template with named placeholders.
