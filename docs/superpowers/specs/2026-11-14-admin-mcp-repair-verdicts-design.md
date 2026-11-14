# Admin MCP: repair verdicts — design

## Intent

Production holds 6,251 proposed `Books::RepairVerdict` rows, all `reimport_match`. Each is an AI decision the
Goodreads re-import was not sure enough to apply on its own:
- 3,875 high confidence, 2,367 medium and 9 low;
- about half say "this Goodreads edition is book #X", and half say "create a new book".

Reviewing them by hand on the admin page is the bottleneck. As with duplicates (#481) and match decisions (#484),
Shane wants an agent to work the queue with raw, admin-only tools. The judgement goes in a copyable prompt he can
edit, not in the endpoints.

The third action, "correct", landed in #501 as `Services::Books::GoodreadsReimport::CorrectMatch`. These tools
expose it alongside approve and reject.

## Goals

- **Same actions as the page.** An agent can list, read, approve, reject and correct verdicts, with the same
  permissions as the admin repair-verdicts page.
- **Both REST and MCP.** Each tool is an `/api/v1/admin/...` endpoint, and its MCP tool is generated from an
  `x-mcp` block.
- **One review path.** The page and the API share it, and each review records who reviewed it and how
  (`admin_ui` or `api`).
- **A Copy prompt button** on the repair-verdicts page, as on the duplicates and match-decisions pages.

## Non-goals

- **Running the apply job.** Approving or correcting never applies anything. `books:goodreads_reimport:apply`
  (re-import) and `books:goodreads_replay:apply` (replay) do that later, as today.
- **API parity for "approve everything matching this filter".** One wrong filter across 6,000 rows is too easy.
  Bulk approve over the API takes an explicit list of ids.
- **New verdict kinds or changes to `CorrectMatch`'s rules.**

## Approaches

The only real choice was which actions to offer. Approve and reject alone were ruled out: a rejected
`reimport_match` strands its readers. #501 settled that by adding correct. Everything else follows the existing
match-decisions pattern.

## Design

### Tools

| Endpoint | Tool | Scope |
|---|---|---|
| `GET /api/v1/admin/repair_verdicts` | `list_repair_verdicts` | read |
| `GET /api/v1/admin/repair_verdicts/{id}` | `get_repair_verdict` | read |
| `POST /api/v1/admin/repair_verdicts/{id}/approve` | `approve_repair_verdict` | merge |
| `POST /api/v1/admin/repair_verdicts/{id}/reject` | `reject_repair_verdict` | write |
| `POST /api/v1/admin/repair_verdicts/{id}/correct` | `correct_repair_verdict` | write |
| `POST /api/v1/admin/repair_verdicts/bulk_approve` | `bulk_approve_repair_verdicts` | merge |

The scopes mirror the page's gates. Approve takes the delete gate, because an approved merge destroys a record on
the next apply. Reject and correct take the write gate.

**List**
- Filters are the page's: `kind`, `status` (default `proposed`), `decided_by`, `confidence` and `guess`.
- Superseded verdicts are excluded, as on the page.
- Results are newest first and paginated like `list_match_decisions`.
- A row holds:
  - `id`, `kind`, `status`, `decided_by`, `confidence`;
  - `summary` and `reason`;
  - `guess`;
  - `reviewed_at`, `applied_at`, `created_at`.

**Get**
- Everything in a list row.
- `payload`, in full, and `ai_chat_id`.
- `books`: the books the verdict names, each with its id, slug, title, authors and first published year.
- `authors`: the authors it names.
- `candidate_books`: for a `reimport_match`, the books in `payload["candidate_book_ids"]`, in the same shape.
- `match_decision`: the linked match decision's id and outcome, or null.
- `source_rows`: the import rows the finding came from.
- `reviewed_by` and `reviewed_via`.
- `superseded_at`.

**Approve**
- Refused (422) unless the verdict is `proposed`, as the page refuses.
- Also refused (422) on a superseded verdict. My call: approving a retired proposal does nothing useful.

**Reject**
- Refused (422) on an already-rejected verdict or a superseded one.
- Rejecting an applied `mark_provisional` reverts it and requests the ranking refresh, as the page does today.
- The tool description says that rejecting a `reimport_match` strands its readers, and that the agent should
  correct it instead.

**Correct**
- Calls `CorrectMatch` with `book_id`, or with `create: true`.
- A refusal from the service is a 422 that carries the service's message.

**Bulk approve**
- Takes `ids`, an array of 1 to 100 verdict ids.
- It approves the ones that are proposed and current.
- It returns the ids it approved and the ids it skipped.

**Failures:** a missing verdict is 404.

### Shared review logic

- **The service:** `Services::Books::RepairVerdicts::Review` gets `approve`, `reject` and `bulk_approve(ids:)`.
  Each takes `user:` and `via:`, and the page's logic moves into it. The page and the API both call it; the page
  passes `via: "admin_ui"`.
- **Correct:** the page and the API call `CorrectMatch`. `CorrectMatch` also records `reviewed_via` when it's
  given one; it defaults to `admin_ui`.
- **The filter:** `Services::Books::RepairVerdicts::Filter` holds the page's `filtered_scope` and is shared too.
- **Migration:** `reviewed_via` on `books_repair_verdicts` is an integer enum `{admin_ui: 0, api: 1}`, nullable.
  Rows reviewed before this change stay null.

### Copy prompt

- A new queue, `repair_verdicts`, in `Services::AgentPrompts`, with the template
  `config/mcp/books/prompts/repair_verdicts.md.erb`.
- The template's counts are the pending re-import matches by confidence.
- The template tells the agent:
  - approve and correct take effect on the next apply run, not immediately;
  - for a wrong match, correct it to the right book or to `create`; never reject a `reimport_match`;
  - check the candidates and the CSV facts before deciding.
- The repair-verdicts index page shows the button, the same way the match-decisions page does.
- An E2E test copies the prompt.

### Ask-first exemption

`admin_usage.md` exempts these tools from the ask-first rule, like the other queue tools.

## Constraints

- Follow the #484 and #497 patterns: contract coverage for every documented status, catalogue pins (40 → 46),
  controller tests that assert behaviour only, and `::`-anchored constants.
- The migration runs annotaterb. It only adds a nullable column, so it is safe on production data.

## Left to the builder

- Resource naming and file layout, and how many source rows to inline in `get` (a cap is fine).
