# Agent enrichment queue

A queue that lets an AI agent do enrichment research itself. The agent connects to the admin MCP server (`docs/features/mcp-server.md`), claims a batch of records that need an answer, researches each one with its own web search, and submits the answer. The server applies it by the same rules the paid pipeline uses and writes a ledger row.

Why it exists: the paid research path (`gpt-6-astra` with `web_search`) is capped per day, and the origin and categories backfill is paced at one book every 8 seconds (about 15 days for the catalog, `docs/launch-todo.md` section 14). An agent on a subscription Shane already pays for has its own web search, works in parallel and costs nothing per call. The paid path stays; the two share the data and the ledger and see each other's work (see "The queue and the paced backfill").

The table, the services and the base admin controller know nothing about books; the API controllers, routes and navigation entry are per domain, and today only books has them. A type is one class; books supplies two. Spec: `docs/superpowers/specs/2026-11-17-agent-enrichment-queue-design.md`. Plan and increments: `docs/superpowers/plans/2026-11-17-agent-enrichment-queue-increment-1.md`.

## The table

`enrichment_requests`, model `EnrichmentRequest`: one row per record and type (`enrichable` is polymorphic, `kind` is the type, for example `books.origin`). A unique index on `(enrichable_type, enrichable_id, kind)` makes that a database fact, and `(kind, status, priority, id)` serves the claim. The row says what is wanted and who holds it. It is not the history: every applied answer is in the `enrichments` ledger, and `enrichment_id` points at the one that closed the row.

Deleting a book or author deletes its rows. A merge moves the source's rows to the target (`Services::EnrichmentQueue::CarryOver`); where the target already has a row of that kind, the target's row stays and the source's is deleted.

| Status | Meaning | Leaves it by |
|---|---|---|
| `pending` | Waiting to be claimed | claim |
| `claimed` | Leased to an agent | submit, skip, or the lease expiring (it is then claimable again) |
| `submitted` | Answer stored, waiting for the apply job | the job: `done`, or `failed` after the retries |
| `done` | Closed | re-open (version bump at a fill) or re-queue |
| `skipped` | Closed without an answer | re-open or re-queue |
| `failed` | The apply job gave up; `error` says why | re-queue, or retry apply (keeps the answer) |

`reason` says why a row was queued or re-opened: `missing` (a fill found a candidate), `version` (a fill re-opened it), `manual` (re-queued by hand). `changed` and `research_wanted` are allowed values that nothing writes yet (they belong to later types).

`outcome` says how a row ended:

| Outcome | Written by |
|---|---|
| `applied`, `nothing_to_apply`, `unrecognized` | the apply job, copied from the ledger row |
| `skipped_by_agent` | an agent skip; the agent's reason is in `note` |
| `abandoned` | the claim, after three claims that never ended in a submit or skip |
| `no_longer_needed` | the claim, when the record's gap closed meanwhile |

`resolved_via` records who closed the row: `api` (an agent through the admin API), `admin_ui`, `system` (the claim closing a row itself) or `paid_research` (reserved for the paid worker, not built). `resolved_by_id` is the token's user, `resolved_at` the time.

## The life of a row

**Fill.** `Services::EnrichmentQueue::Fill` runs in `EnrichmentQueue::FillJob` (Sidekiq, no retry, because a fill is idempotent and can simply be run again). It takes a kind, a scope (`ranked`, the default, or `all`) and an optional limit, reads the type's candidates as `(id, priority)` pairs, and in batches of 5,000: inserts a `pending` row for every candidate that has none (reason `missing`; the unique index decides), re-opens `done` and `skipped` rows whose `version` is below the type's (reason `version`), and refreshes the priority of rows still `pending`, since ranks move. Running it twice changes nothing the second time. Priority is lower first: a ranked book's rank, 1,000,000 for the rest. `limit` caps the candidates considered, highest priority first, including ones already queued or finished, so a fill with the same limit run twice adds nothing the second time; raise the limit to reach further down. A book with a running `books.book_enrichment` or `books.book_categorize` run is not a candidate, and the paced backfill plans a run for every book up front, so run the queues before starting the paced backfill (`docs/launch-todo.md` section 14 gives that order): once it is planned, a fill finds none of those books until their runs finish.

**Claim.** `Services::EnrichmentQueue::Claim` hands out 1 to 25 rows (default 10) in `(priority, id)` order under one `lease_token`, with a lease of 30 minutes (`EnrichmentRequest::LEASE`). It selects with `FOR UPDATE SKIP LOCKED` and marks the rows claimed in the same transaction, so parallel sub-agents never get the same row. Claimable means `pending` or `claimed` with an expired lease; no sweeper is needed. Each claim increments `attempts`. Per row: a row already claimed three times (`MAX_ATTEMPTS`) is closed as `skipped` / `abandoned`, so one item an agent keeps choking on cannot stop a queue reaching empty; a record that no longer exists has its row deleted; a record whose gap is already filled (`still_needed?`) is closed as `done` / `no_longer_needed`. Each closed row leaves a hole, so up to three passes top the batch up.

**Submit.** `POST .../submit` with `lease_token`, `answer`, `sources` and an optional `note`. The request does not apply the answer: applying can call a model for several seconds, and several agents submit at once on web servers that also serve music and games. `Services::EnrichmentQueue::Submit` checks in a fixed order, so a wrong token is a conflict even when the answer is also bad (but an `answer` that is not an object is a 400 from the controller before the service checks the token), then stores the answer and sources and moves the row to `submitted` in one conditional update (two concurrent submits cannot both win), queues `EnrichmentQueue::ApplyJob` and answers 202. Limits: `answer` at most 50,000 bytes of JSON, validated against the type's `answer_schema`; `note` at most 1,000 characters; `sources` 1 to 20 `http(s)` URLs of at most 2,000 characters.

- **409**: the row is not claimed under that token (another batch re-claimed it, it was already closed, or the lease no longer matches). Nothing is written. The agent drops the item. An expired lease that nobody re-claimed is still accepted. A second submit with the same token on a row that is already `submitted` answers success and queues nothing, so a retry after a lost response is safe.
- **422**: the answer, sources or note failed validation. The row stays claimed; the agent fixes the answer and sends it again.
- **400**: the body is malformed (not a JSON object, `lease_token` not a string, `answer` not an object, `sources` not an array of strings, `note` not a string). On claim, a `limit` that is not an integer from 1 to 25 is also a 400.
- If queueing the job raises (Redis down), the row is put back to `claimed` and the error propagates, so the retry redoes the submit instead of being treated as a repeat.

**Apply.** `ApplyJob` (Sidekiq, queue `low`, 3 retries) calls `Services::EnrichmentQueue::Apply`, which calls the type's `apply`, then sets the row `done` with the ledger row and its outcome. A failed apply raises, so Sidekiq retries it and the row stays `submitted`. When the retries run out the row becomes `failed` with the error. A failed attempt may write a failed ledger row each time, not only the last. A row whose record was deleted meanwhile is removed. While the type runs, `Current.acting_user` and `acting_via` carry the submitter, so code that records who acted (the ledger, mergers) sees them.

**Skip.** `POST .../skip` with `lease_token` and a `reason` of 1 to 500 characters. The row becomes `skipped`, outcome `skipped_by_agent`, the reason in `note`. A skipped row is resolved and is not handed out again. Same 409 rules as submit; an empty or over-long reason is a 422.

**Re-queue.** `Services::EnrichmentQueue::Requeue` puts a `done`, `skipped` or `failed` row back to `pending` (reason `manual`, attempts and answer cleared, via `EnrichmentRequest::REOPEN_RESET`, the one definition the version re-open shares). A `pending`, `claimed` or `submitted` row is refused with a conflict, because re-queueing it would race the agent or the job holding it. The admin page's Re-queue button calls it.

**Retry apply.** `Services::EnrichmentQueue::RetryApply` runs the apply job again without redoing the research, because Re-queue clears the answer. It takes a `failed` row that still holds its answer (a transient failure such as a model outage inside the categories chooser call) and puts it back to `submitted` with `error` cleared, keeping the answer, sources, note and submitter, then queues `ApplyJob`. It also takes a `submitted` row whose `resolved_at` is more than 15 minutes old (`RetryApply::STALE_AFTER`), which is a job lost to a Redis flush: it only moves `resolved_at` to now, so a second click inside 15 minutes is refused, and queues the job. Every other row is a conflict (a fresh `submitted` row is still being applied). Both transitions are one conditional UPDATE, so a double click cannot queue twice; if queueing raises, a row that was `failed` goes back to `failed` with its old error. The admin page offers a **Retry apply** button on exactly those rows.

## What re-opens a resolved row

Two things, and nothing else:

1. **A type version bump, at the next fill.** A `done` or `skipped` row whose `version` is below the type's current one goes back to `pending` (reason `version`), but only when its record is still a candidate: a record whose gap is closed is never re-opened, whatever the version. For both books types the version is the task's `PROMPT_VERSION`, so a prompt change re-opens the queue and the paid pipeline together, and in the queue only for books that still have the gap.
2. **A manual re-queue** from the admin page.

That is what prevents repeated work: a second agent run after more records arrive claims only the new ones. The `fingerprint` column (what a record looked like when resolved) exists and nothing reads it yet. It is for a later series-review type, which re-opens a reviewed record when its content changes.

## The stop signal

The agent claims until done. A claim can return no items while `meta.remaining` is above 0: all three passes closed every row they picked (abandoned, or no longer needed), or a concurrent claim had other rows locked (`SKIP LOCKED`) while `remaining` was counted, so they still read as pending. Rows under an unexpired lease are not claimable and are not counted. So the agent stops only when a claim returns no items and `remaining` is 0, and claims again otherwise. `remaining` counts claimable rows (pending, plus claimed with an expired lease). `submitted` rows are on their way to `done` and do not count.

## How an answer is applied

The type hands the answer to the same code the paid judge uses: `Services::Books::Origin::RecordAnswer` and `Services::Books::Categories::RecordAnswer`. Each is the "answer in, ledger row out" half of the judge, extracted so the paid path and the agent path write rows of one shape. The rules are the judges' and are not loosened for agents:

- **Confidence tiers.** `high` is written. `medium` is written only when evidence the catalogue already holds supports it (for categories, `Categories::Support#addition_sources`: the category's name or alias appears in the stored Wikidata, Wikipedia, WorldCat or Goodreads evidence, the book already holds the category, the name appears in the description, Wikipedia lead or plot or WorldCat summary, or in a Goodreads shelf name; for origin, `Origin::Apply#supported?`: the stored Wikidata country, the Wikipedia infobox country, or web-verified book facts naming the same country). `low` is recorded and held. The prompt tells the agent to say `high` only when a source states the fact and to give `low` to a guess.
- **Blanks only.** Origin never overwrites a real country; a disagreeing high answer is recorded, not applied.
- **Categories are never removed** (`rejudge: false`) and **never created**: an answer names existing categories by id (genres, audience) or by name resolved through the mapper (subjects, locations). A name the mapper cannot match is held, and the agent's `unlisted_genres` feed the alias report.
- **`BOOKS_CATEGORIES_JUDGE_ENABLED` does not gate an agent's answer.** That switch gates the automatic judge. A submit is an explicit admin action and applies even while the judge is off.
- The mapper's cheap chooser call (`CategoryChoiceTask`) still runs for a name with candidates, inside the apply job.

An answer for a book the judge would call unrecognized (`recognized: false`, with no external or web-verified evidence) writes an `unrecognized` row and applies nothing.

## The ledger

An agent submit writes one `enrichments` row of the type's kind with:

- `mode` `agent` (a value of `Enrichment.mode` beside knowledge, research and sourced),
- `facts["context"]` and `facts["label"]` both `"agent"`,
- `facts["queue_request_id"]`, the `enrichment_requests` id,
- `citations` set to the submitted sources,
- `provider` `"agent"`, `model` nil, and the current `prompt_version` and `deferred_research: false` that the judges write.

Because the label is `agent`, the existing reports read these rows: `books:origin:report[agent]`, `books:categories:report[agent]` and `books:categories:add_aliases[agent]`. `restore_removals` has nothing to restore, since agent submissions remove nothing.

Where code asks "was this researched on the web?" an agent row counts (`Enrichment::WEB_VERIFIED_MODES`, used by `Dossier#research_backed?`). Where it asks "did we pay for a search?" (`Enrichment.research`, the research caps, the reports' research cost) an agent row does not, because `mode` is its own value.

## The queue and the paced backfill

The two pipelines see each other through the data, not through shared state:

- **Candidates and `still_needed?` read the data.** A book the cheap pipeline or the backfill already filled is not queued, and a queued one is closed at claim time as `no_longer_needed`. A book with a running `books.book_enrichment` or `books.book_categorize` run is not offered by a fill, because that run is still judging it and would otherwise judge it again after the agent.
- **An agent row is done for `Services::Books::Categorize::Backfill` only when its outcome is `applied`** (`Backfill.done_rows`). The agent has no stored evidence, and the backfill gathers it and can settle a book the agent could only half answer (the Wikidata shortcut, a supported `medium`). So a held answer closes the queue row (`done` / `nothing_to_apply`, no agent is handed the book again) but leaves the book to the backfill, if the backfill has not judged it already. A held agent row is ignored when `done_rows` looks for the latest row of a kind, so a book the paid pipeline already judged stays done and is not judged a second time.
- An applied agent row carries the current `prompt_version`, so the backfill skips the book and a book that owed research no longer does.

## The two types

Both live in `Services::Books::QueueTypes` and share `BookScope`: candidates are titled books with no running import or categorize run, left-joined to the default primary ranking; `ranked` keeps only ranked books; priority is the rank, 1,000,000 when unranked.

| | `books.origin` | `books.categories` |
|---|---|---|
| Candidate rule | no real country (`Backfill.no_real_country_sql`) | no direct genre beyond Fiction and Nonfiction (`Backfill.no_genre_sql`) |
| Version | `BookOriginTask::PROMPT_VERSION` | `BookCategoriesTask::PROMPT_VERSION` |
| Answer schema | the origin task's `ResponseSchema` (`recognized`, `nationality`, `confidence`, `reason`, `original_language`) | the categories task's `ResponseSchema` (book type, genres and audience by id, subjects and locations by name, `unlisted_genres`) |
| Reference (sent once) | the answer schema | the answer schema, the closed genre and audience lists with `id`, `name` and definition, and the caps (genre, subject, location) |
| Apply | `Origin::RecordAnswer` | `Categories::RecordAnswer`, `rejudge: false` |

The payload for one item is the same for both: `book_id`, `record` (the dossier's view of the book: title, year, language, authors with years and nationalities, held countries, a trimmed description, and the categories the book holds now with their sources), `evidence` (the stored Wikidata, Wikipedia, WorldCat, Goodreads and book-facts evidence when the book has it; nothing waits for evidence to be gathered) and `tried` (the latest ledger row of this kind, whatever its mode: mode, outcome, reason, confidence, answer).

Run categories only after the genre and audience definitions are written (`books:categories:write_definitions`, launch-todo section 14 step 2), since the reference list sends them.

## The tools and routes

Five admin API operations in `config/api/v1/admin_openapi.yaml`, each also an MCP tool. The type is addressed by the part of its kind after the domain (`origin` for `books.origin`); the domain comes from the host. Controllers are `Api::V1::Admin::Books::EnrichmentQueuesController` and `EnrichmentItemsController`; the services and resources they call are generic.

| Tool | Route | Scope |
|---|---|---|
| `list_enrichment_queues` | `GET /api/v1/admin/enrichment_queues` | `books:admin:read` |
| `get_enrichment_queue` | `GET /api/v1/admin/enrichment_queues/{type}` | `books:admin:read` |
| `claim_enrichment_items` | `POST /api/v1/admin/enrichment_queues/{type}/claims` | `books:admin:write` |
| `submit_enrichment_item` | `POST /api/v1/admin/enrichment_items/{id}/submit` | `books:admin:write` |
| `skip_enrichment_item` | `POST /api/v1/admin/enrichment_items/{id}/skip` | `books:admin:write` |

- `list` returns each type with its count per status. `get` adds the outcome counts of `done` rows and the type's `reference`. It is separate from claim because the genre list is large and an agent needs it once, not with every batch. Because submit answers 202 and the agent never sees the apply result, these outcome counts are what the agent reports at the end of a run.
- `claim` takes an optional `limit` (1 to 25, default 10) and returns the items (`id`, `kind`, `reason`, `attempts`, `payload`) with `meta.lease_token`, `meta.lease_expires_at` and `meta.remaining`.
- Claim, submit and skip also require that the token's owner may change books (`Books::BookPolicy#update?`).
- A row of another domain, or of a type no longer registered, is a 404.
- The queue tools are exempt from "dry run, then ask": none is destructive, and the agent decides each item itself (`config/mcp/books/admin_usage.md`, "The enrichment queues"). See `docs/features/mcp-server.md`.

## The Copy prompts

A type's prompt is `config/mcp/<domain>/prompts/enrichment/<slug>.md.erb` (`origin.md.erb` and `categories.md.erb` for books), rendered by `Services::AgentPrompts.for_enrichment` with the MCP URL, the queue type and the pending count. A type with no file gets no button. Each prompt holds the loop (get the queue once, claim, research, submit or skip, claim again until a claim is empty with `remaining` 0, sub-agents each run the same loop), the 409 and 422 handling, the confidence guidance, and what to report at the end.

The judgment rules are not copied into the prompt file. Each type exposes its task's `RULES` constant through `prompt_locals`, and both the task's system message and the prompt file read it, so the paid model and the agent follow one text. The rules are in the pasted prompt, not in server instructions, so the owner can trim or edit the prompt per run.

## The admin page

`/admin/enrichment_queues` on the books host (navigation: "Enrichment Queues"), built on `Admin::EnrichmentQueuesBaseController` with `Admin::Books::EnrichmentQueuesController` supplying the domain. The types come from the registry, so a new type needs no change here.

- The index shows one row per type with its count per status, a **Copy prompt** button, and a **Fill** form (scope ranked or all, optional limit). Fill only queues `EnrichmentQueue::FillJob`; reload the page to see the counts move.
- A type's page has a tab per status, a "via" filter on the resolved tabs, and the items with the record link, reason, outcome, note, sources, who and when, 50 to a page. Resolved tabs sort newest first; open tabs by priority.
- A done, skipped or failed row has a **Re-queue** button (`POST /admin/enrichment_requests/:id/requeue`). A failed row that holds an answer, and a submitted row older than 15 minutes, have a **Retry apply** button (`POST /admin/enrichment_requests/:id/retry_apply`), which keeps the answer (see "Retry apply" above).
- Tabs with outcomes also have an outcome filter (the outcomes present in that tab, with counts, and All), beside the "via" filter.
- Fill, Re-queue and Retry apply need write permission on the domain, and a read-only viewer is not shown them.
- Under the Fill form: Limit takes the highest-priority records that need this enrichment, whether or not they are already queued, so repeating a fill with the same limit adds nothing.

E2E: `web-app/e2e/tests/books/admin/enrichment-queues.spec.ts` (page loads, Copy prompt copies, a queue opens). It does not press Fill.

## Rake task

`bin/rails "enrichment_queue:fill[kind,scope,limit]"` queues `FillJob` for a kind (`books.origin`, `books.categories`), scope `ranked` (default) or `all`, and an optional positive limit (the limit counts the highest-priority candidates whether or not they are already queued, so repeating a fill with the same limit adds nothing). It enqueues and returns; progress is in the worker log. Example: `bin/rails "enrichment_queue:fill[books.origin,ranked]"`. The admin page's Fill does the same.

## Adding a type

1. Subclass `Services::EnrichmentQueue::Type` and implement its class methods: `kind` (`books.origin` form, matching `Enrichment::KIND_FORMAT`), `label`, `version` (an Integer: it is compared with the row's integer `version`), `target_class`, `candidates(scope:)` (a relation), `priority_sql`, `still_needed?(record)`, `payload(record)`, `reference` (a Hash that includes `"answer_schema"`), `answer_schema` and `apply(request)` (returns a Result with `data: {enrichment:, outcome:}`). `prompt_locals` is optional.
2. Add the class name to `Services::EnrichmentQueue::Registry::TYPE_NAMES`.
3. Add `config/mcp/<domain>/prompts/enrichment/<slug>.md.erb`.
4. Make `apply` call code the paid path also uses, so the two cannot drift, and write the ledger row with mode `agent`, context and label `"agent"`.
5. A type on a record class other than `Books::Book` or `Books::Author` needs `has_many :enrichment_requests, as: :enrichable, dependent: :delete_all` on that model and a `Services::EnrichmentQueue::CarryOver.call(source:, target:)` call in its merger. Only those two classes have them today.
6. A type in another domain also needs that domain's API controllers (`EnrichmentQueueSupport::DOMAIN` is `"books"`), routes, an admin page subclass of `Admin::EnrichmentQueuesBaseController` and a navigation entry.

Namespace warning: put books types in `Services::Books::QueueTypes`, not `Services::Books::EnrichmentQueue`. Inside `module Services::Books`, a bare `EnrichmentQueue::` would resolve to the wrong constant (and `Books::` inside `module Services` is `Services::Books::`). Root-anchor models and jobs: `::EnrichmentRequest`, `::EnrichmentQueue::ApplyJob`, `::Books::Book`.

## Not built yet

- Book facts and author facts types (first published year, original language, descriptions, author facts), spec section 10.
- The web-search switch (`AI_RESEARCH_VIA`) and the paid worker (`enrichment_queue:work`) that lets the same queue be worked through the paid path, spec section 10. `resolved_via: paid_research` is reserved for it.
- Series review, with `fingerprint` re-opening a reviewed series when its books change, spec section 11.
- Reader corrections (the pending `Correction` rows): a separate future spec, not this table.
- Blanks only is provisional (spec, non-goals): an answer that differs from a held value is recorded on the ledger row with `applied: false`, so nothing an agent finds is lost, but the queue never overwrites.
