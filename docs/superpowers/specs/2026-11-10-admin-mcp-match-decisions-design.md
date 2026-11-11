# Admin MCP: match decisions and identifiers — design

Date: 2026-11-10. Status: draft for Shane's approval.
Follows `2026-11-09-admin-mcp-duplicates-design.md` (merged as #481) and reuses its shape: raw admin API
endpoints with `x-mcp` blocks, final writes, who/how recorded, a Copy prompt button.

## Why

Shane's end goal: "ultimately I want the MCP server to be able to do exactly what an admin user can do, so I
can automate a lot of the manual admin stuff I need to do. But let's stick to one thing at a time."

This round is the match-decisions queue (`/admin/books/match_decisions`): decisions the importers and the
Wikidata/VIAF resolvers made with less than full confidence and flagged for a person. Shane wants an agent to
work through them the way it works through duplicates. Most of the fixes are identifier fixes (a wrong
Wikidata/VIAF link, or a missing one), and the agent cannot see identifiers today, so identifier tools are part
of this round.

Queue on dev (pending, excluding the 590 hidden "verify" book decisions): Wikidata link 212 (58 matched,
154 unmatched), VIAF link 38 (5 matched, 33 unmatched), author import matching 81 (23 matched, 58 unmatched).

## Goals

- Admin MCP tools to list and read match decisions, mark them reviewed with a verdict, and reject a bad
  Wikidata/VIAF link.
- Admin MCP tools to read all identifiers on a book (including its editions) or an author, look a record up by
  identifier, and add or remove identifiers on a book or author.
- Every write records who and how (admin page vs API), as the duplicate queue now does.
- A Copy prompt button on the match decisions page.

## Non-goals

- Moving a book's credit from a wrongly matched author to the right one. That edits a record; it belongs to the
  corrections round.
- Re-running a finder ("recheck") over the API.
- Edition-level identifier writes (read only in this round), series identifiers, music and games.
- Workflow logic on the server. As with duplicates, the workflow and house rules live in the copyable prompt.

## Anti-goals

- Server text that makes the agent ask the user before each write. These are admin-only raw endpoints; the
  agent decides.
- A second code path for rejecting a link. The API calls the same `Services::Books::Authors::RejectExternalLink`
  the admin page uses, so its side effects (identifier removal, reverted facts, rejected-key record, enrichment
  re-run) stay identical.

## Design

### Match decisions (books domain finders from `DataImporters::FinderRegistry.for_domain(:books)`)

| Tool | Endpoint | Scope | What it does |
|---|---|---|---|
| `list_match_decisions` | `GET /api/v1/admin/match_decisions` | `books:admin:read` | Paged, newest first with id tiebreak. Filters mirror the admin page: `entity` (`book`, `author`, `wikidata-link`, `viaf-link` — the registry labels parameterized, as the page builds them), `outcome`, `confidence`, `decided_by`, `reviewed` (`pending` default / `reviewed` / `all`), `verify` (`hide` default / `include`). Each row: id, kind, outcome, confidence, decided_by, reason, created_at, the subject (id, type, name/title), the chosen record (id, type, name/title) or null, review state (reviewed_at, reviewed_by email, review_note, verdict, reviewed_via). |
| `get_match_decision` | `GET /api/v1/admin/match_decisions/{id}` | `books:admin:read` | The row plus the query snapshot (what was searched for) and every candidate snapshot (scores, sources, evidence, record id/type, external key/source), with the current record summary for candidates that are our records. |
| `review_match_decision` | `POST /api/v1/admin/match_decisions/{id}/review` | `books:admin:write` | Body: `verdict` (`confirmed` or `rejected`, optional), `note` (optional). Marks it reviewed. Refuses (422) if already reviewed. On a **matched Wikidata/VIAF** decision, `verdict: rejected` is refused (422) with a pointer to `reject_match_decision_link` (my call): a bare rejected verdict there makes `RejectedRecords` ban the record while the identifier and facts stay, and the reject service then refuses as "already rejected" — a stuck state. On other decisions `rejected` records the verdict only. |
| `reject_match_decision_link` | `POST /api/v1/admin/match_decisions/{id}/reject_link` | `books:admin:merge` | Runs `RejectExternalLink` exactly as the admin page's reject does. Only for Wikidata/VIAF decisions that matched; refusals from the service come back as 422 with its message. The service already marks this decision and the sibling decisions it cascades to as reviewed `rejected` with the note "Link rejected."; an optional API `note` is appended to that note ("Link rejected. — <note>") on this decision (my call). No extra already-reviewed check beyond the service's own "already rejected" refusal, so the API behaves exactly like the page. |

Notes:

- **Who/how.** Add `reviewed_via` to `match_decisions` (enum `admin_ui`, `api`, nullable). The admin page's
  review and reject set `admin_ui`; the API sets `api`; use `Current.acting_user`/`acting_via` from #481 where
  the write happens inside a shared service — `MatchDecision#review!` reads `Current.acting_via` so the reject service's cascaded reviews are stamped too. The admin match decisions page gains the same "All / Admin page /
  API" filter on reviewed decisions and shows "via …" on each reviewed row.
- **Scope for reject.** `books:admin:merge`, because rejecting deletes an identifier, reverts AI facts and
  re-runs enrichment (the admin page gates it behind delete permission). Policy: the token's user must be
  allowed to delete in the books domain (`require_domain_delete!` semantics).
- **Staleness.** Review and reject act on one decision id; the decision does not change shape under the agent
  the way a duplicate pair does, so no extra ids are required. Review of an already-reviewed decision → 422.

### Identifiers (Books::Book, Books::Author)

| Tool | Endpoint | Scope | What it does |
|---|---|---|---|
| `get_book_identifiers` | `GET /api/v1/admin/books/{id}/identifiers` | `books:admin:read` | Paged with the standard envelope (some books hold thousands of edition identifiers): a flat list of the book's own identifiers first, then its editions', each `{id, identifier_type, value, source, created_at, edition}` where `edition` is null for the book's own rows or `{id, title, format, year}`. Optional `scope=work` returns only the book's own rows (my call). |
| `get_author_identifiers` | `GET /api/v1/admin/authors/{id}/identifiers` | `books:admin:read` | The author's identifiers, same shape. |
| `find_by_identifier` | `GET /api/v1/admin/identifiers?type=…&value=…` | `books:admin:read` | Every book, edition (with its book) or author holding that identifier type and value. Answers "which record has this ISBN / Q-number / VIAF id", including several. `type` must be one of the `books_*` identifier types (work, edition, author, series — read-only for edition/series); 400 otherwise. |
| `add_book_identifier` / `add_author_identifier` | `POST /api/v1/admin/{books|authors}/{id}/identifiers` | `books:admin:write` | Body: `identifier_type`, `value`. Only types valid for that record kind (`books_work_*` on a book, `books_author_*` on an author); 400 otherwise. Stores `source: admin` (new enum value). Already present on this record → 200 with the existing row, no change. For `books_author_wikidata_qid` and `books_author_viaf`: 422 if the author already holds a different value of that type (remove it first), and 422 if `RejectedRecords` lists that value as rejected for this author (my calls). The response also lists any **other** record holding the same type and value, so the agent sees a likely duplicate. |
| `remove_book_identifier` / `remove_author_identifier` | `DELETE /api/v1/admin/{books|authors}/{id}/identifiers/{identifier_id}` | `books:admin:merge` | Deletes that identifier row, whatever its source; 404 if it is not this record's. `destructive: true`. The description warns that `open_library`/`worldcat` rows are verified evidence the Goodreads matcher reads. |

Notes:

- **Value checks.** Normalise and validate the formats we can check cheaply: Wikidata `Q\d+`, VIAF digits,
  ISBN-10/13 checksum, ISNI 16 characters. Anything else: stripped, non-blank, ≤255 (the model's rule). A bad
  format is a 400 naming the expected form.
- **Adding an author Wikidata/VIAF link** (my call): an identifier with `source: admin` is authoritative. The
  resolvers' held-id stage (`ResolveWikidata#held_stage`, and VIAF's equivalent) accepts an admin-sourced id
  without the name/years corroboration it applies to other held ids, so a re-run cannot ignore it or stamp a
  second id beside it. After the add, start the same author enrichment re-run the reject service starts
  (`Workflows::Books::AuthorEnrichment.start(..., refresh: true, supersede: true)`), so facts follow the new
  link. Removing one does the same. Book identifiers trigger nothing.
- **Who/how for identifier writes.** There is no admin page that writes identifiers (the identifiers screen is
  read-only), so there is no `admin_ui` counterpart. Added rows carry `source: admin`; every add/remove logs
  `event=api_admin_identifier action=<add|remove> ... user_id=... token_id=...`.
- **Search index.** If identifiers feed a search index or the import finder's lookup, the add/remove goes through
  whatever already keeps that in sync (callbacks); the builder checks and does not add a new path.
- The duplicate tools' summaries already list identifiers; no change there.

### Server-side MCP text

Tool descriptions say what each does, what is permanent (`remove_*_identifier`, `reject_match_decision_link`) and
what a refusal means. `config/mcp/books/admin_usage.md` gets one short section: the match-decision and
identifier tools are, like the duplicate queue tools, for an agent deciding itself; the ask-first rule does not
apply to them.

### Copy prompt

Same mechanism as duplicates (`Services::DuplicateCandidates::AgentPrompt` pattern, a template under
`config/mcp/books/prompts/`). Starting content, for Shane to trim:

- The job: work through pending match decisions (Wikidata links, VIAF links, author matches), using the tools
  plus web research.
- Per kind:
  - **Wikidata/VIAF matched:** check the linked entity is this author (dates, works, nationality). Right →
    review `confirmed`. Wrong → `reject_match_decision_link`, then if the right entity is findable, add it with
    `add_author_identifier`.
  - **Wikidata/VIAF unmatched:** find the right entity if one exists; add it, then review `confirmed` with a
    note naming it. None exists → review with a note.
  - **Author matched:** check the incoming author really is this author. Wrong → review `rejected` with a note
    (fixing the credit is not possible yet).
  - **Author unmatched (a new author was created):** look for an existing author who is the same person
    (`find_by_identifier`, `search_admin_authors`). Found → merge with `merge_author` (new into existing), then
    review `confirmed`. Otherwise review `confirmed`.
- House rules: the placeholder/place author rule from the duplicates prompt; translators are not authors;
  never link a person to an entity for a different person with the same name.
- Authorised to act without asking; skip with a note if genuinely unsure.
- Report at the end: per decision, what was done.

### Tests

- Request tests for every endpoint: scopes, policy refusals, filters, 404 outside the books domain, already
  reviewed → 422, reject refusals passed through, add with a wrong type for the record kind → 400, bad formats →
  400, add is idempotent, add reports other holders, remove of another record's identifier → 404, who/how
  stamped.
- MCP catalogue pins (18 → 29 admin tools), contract coverage for every status, admin page `via` filter
  (behaviour only), the prompt service unit test, a Playwright test for the Copy prompt button.

### Docs

`docs/features/mcp-server.md` (tools, workflow), `docs/features/import-finder.md` (`reviewed_via`, API path).

## Left to the builder

- JSON shapes, following the duplicate-candidate resource.
- Which edition fields to show next to each edition's identifiers (title/format/year is enough).
- Whether the format checks live on the model or a small service (one place either way).
