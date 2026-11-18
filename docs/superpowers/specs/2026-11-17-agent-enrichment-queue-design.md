# Agent enrichment queue — design

## Intent

Shane wants to launch the books site and is blocked by slow backfills. Two things make them slow:

- **Web search is capped.** Research-mode enrichment (`gpt-6-astra` with `web_search`, about 15 cents a call) is
  held to `research_daily_cap` (50 a day), and the origin and categories backfill's own cap is 0. A book past the
  cap gets a `skipped` / `budget_exhausted` row or a `deferred_research` flag and is never researched. Dev held
  203 book and 308 author budget skips and 458 origin and 260 category deferrals on 2026-11-17.
- **The origin and categories backfill is paced.** `Services::Books::Categorize::Backfill` plans one book every 8
  seconds so evidence gathering stays inside Wikimedia's rate limit: about 15 days for the catalog (launch-todo
  section 14).

Shane has already had Codex work the duplicates queue (8,000 pairs) and the repair verdicts queue (7,000+) through
the admin MCP server. It is fast because it spawns sub-agents, accurate because it searches the web itself, and it
is covered by subscriptions he already pays for. He wants the same for enrichment: tell a local agent to read a
queue of one type, paste a prompt, and let it work until the queue is empty.

He also hit the failure this design must prevent. An agent reviewed every series, and nothing recorded which
ones it had looked at, so a second run after more series arrive would redo all of it.

Gaps on dev's 21,260 ranked books (2026-11-17, dev database refreshed 2026-11-11): 2,619 with no genre beyond
Fiction/Nonfiction, 2,409 with no real origin country, 544 with no original language, 300 with no first published
year, 166 with no description. Across all 161,304 books each gap is between 31,000 and 55,000. These are dev
numbers; production will differ.

## Goals

- **A queue per enrichment type** that an agent works through the admin MCP server: claim a batch, research,
  submit an answer, repeat until nothing is left.
- **Worst gaps first.** Ranked books in rank order, then the rest.
- **No repeated work.** A record an agent has answered, or looked at and found nothing for, is not handed out
  again unless something specific re-opens it.
- **Safe with parallel sub-agents.** Two agents never get the same item.
- **The existing apply rules decide what is written.** An agent's answer goes through the same deterministic
  appliers as the paid research run.
- **The paid web-search path stays**, behind a switch, and a rake task can work the same queue through it.
- **Copy prompt per type**, on an admin page that shows the queues and their counts.
- **Not books-specific.** The table, the engine, the tools and the admin page know nothing about books; a type is
  a small class. Books supplies the first types.

## Non-goals

- **Replacing the cheap model calls.** Knowledge-mode and sourced-mode runs (`gpt-6-sol`, `gpt-6-luna`) stay as
  they are for imports and backfills. They are fast and cost under a cent.
- **Removing the research code or the paced backfill.** Both stay and keep working.
- **Overwriting values.** The queue fills blanks. Corrections stay with the existing field-edit tools
  (`update_book`, `tag_book`, `add_book_description` and the rest). Shane is not sure blanks-only is right in the
  long run and accepted it for this spec (2026-11-17); revisit it once the first queues have run. An answer that
  differs from a held value is already recorded on the ledger row (value, `applied: false`), so nothing an agent
  finds is lost in the meantime.
- **Reader corrections.** Shane wants an agent to work the pending `Correction` rows (the legacy `changesets`,
  migrated by `Services::BooksMigration::CorrectionMigrator`), which are often "this value is wrong". That is its
  own future spec. `corrections` already has a status and a resolver, so it needs list, read and review tools and
  a Copy prompt in the pattern of the repair verdicts queue, not this queue table.
- **A review step for Shane.** Answers apply at once, as merges do on the duplicates queue.
- **Automatic filling on a schedule.** Filling a queue is a button or a rake task in increments 1 to 3.
- **Music, games and movies types.** Nothing is built for them; nothing in the engine stops them.
- **One claim covering several types for the same book.** A book missing both origin and genre is two items in
  two queues. Revisit only if the double research proves slow.

## Anti-goals

- An agent run that repeats work a previous run already did.
- A queue the paid pipeline cannot also see: after an agent answers for a book, the paced backfill must count
  that book as done, and the other way round.
- An agent creating categories, exceeding the category caps, or writing a description that skips the review and
  the description check.

## Constraints

- Production serves music and games from the same database. The migration must be additive and cheap.
- Services go in `app/lib/services/`, jobs in `app/sidekiq/`, models and jobs come from Rails generators, and
  annotaterb runs with the migration.
- Admin API operations live in `config/api/v1/admin_openapi.yaml`; MCP tools are generated from their `x-mcp`
  blocks (`docs/features/mcp-server.md`, "Adding a tool"). The pinned tool lists and counts in the catalogue tests
  change with every added operation.
- A new association on `Books::Book` or `Books::Author` needs a merger rule. A user foreign key needs a
  `has_many` on `User`.
- Long work runs in Sidekiq, not in a request or a foreground rake task.
- Admin rate limits are 600 requests a minute and 200,000 a day per token, which is enough for one call per item.

## Approaches

Three were considered.

**A. A queue the agent claims from and submits answers to; the server applies them (chosen).** A table holds one
row per record and type. `claim` hands out a leased batch with what we hold; `submit` takes the answer and the
sources, and the server runs the existing appliers and writes a ledger row. The paid research path can work the
same rows. Most to build, but the answer formats and apply rules already exist.

**B. A "books missing X" listing, with the agent editing records directly.** Least to build and no table. Parallel
agents collide on the same page of results, a book with no findable answer never leaves the list, nothing
enforces the caps or the description rules, and the paid path could not share it.

**C. The queue table from A with direct edits from B.** Gains leases and "work until empty". Still no rules and no
ledger, and the paid path stays separate.

Shane picked A. It is the only one where the agent and the paid API are interchangeable workers on one queue, and
it keeps the category rules he set after the old site's auto-created junk genres.

## What Shane decided

- Approach A.
- The cheap model calls stay. Web search is the expensive part; its code is kept, not removed.
- The agent must not duplicate work it has already done (the series case).
- He will work a queue by pasting a prompt into a local agent, per type, until it is empty.

Everything below that is not in this list is the designer's call and is marked as such where it matters.

## The design

### 1. The table

`enrichment_requests`, model `EnrichmentRequest` (global namespace, like `Enrichment`). One row per record and
type. Columns:

| Column | Meaning |
|---|---|
| `enrichable` (polymorphic) | The record: a `Books::Book`, `Books::Author`, later a `Books::Series` |
| `kind` | The type, in the ledger's format: `books.origin`, `books.categories`, ... (`Enrichment::KIND_FORMAT`) |
| `version` | The type's version when the row was queued or last re-opened |
| `status` | `pending`, `claimed`, `submitted`, `done`, `skipped`, `failed` |
| `priority` | Lower is handed out first. A ranked book's rank; a large constant for the rest |
| `reason` | Why it was queued: `missing`, `research_wanted`, `changed`, `version`, `manual` |
| `fingerprint` | Optional. What the record looked like when it was resolved; only review types set it |
| `outcome` | How it ended: `applied`, `nothing_to_apply`, `reviewed`, `no_longer_needed`, `abandoned`, or for an agent skip the literal `skipped_by_agent` (the agent's reason is in `note`) (amended during implementation, 2026-11-18) |
| `note` | The agent's note or skip explanation |
| `answer` | jsonb. The submitted answer, kept until it is applied and afterwards as the record of what was sent |
| `error` | Why a `failed` row failed |
| `sources` | jsonb list of URLs the agent cited |
| `enrichment_id` | The ledger row the submit wrote (nullify on delete) |
| `lease_token`, `lease_expires_at`, `attempts` | The claim |
| `claimed_by_id`, `resolved_by_id` | Users (nullify on delete; `has_many` on `User`) |
| `resolved_via` | `api`, `paid_research`, `admin_ui`, `system` |
| `resolved_at` | When it was submitted or skipped (amended during implementation, 2026-11-18) |

A unique index on `(enrichable_type, enrichable_id, kind)` makes "one row per record and type" a database fact.
A second index on `(kind, status, priority, id)` serves the claim. A re-opened row is the same row set back to
`pending`; what earlier answers said stays in the `enrichments` ledger.

Deleting a record deletes its rows. A merge moves the source's rows to the target; where the target already has a
row of that kind, the target's row is kept and the source's is deleted (designer's call: the survivor's history
wins, and the next fill re-queues the survivor if it still has a gap and no row). That rule is for records that
are really deleted when merged (books and authors). A series is soft-deleted (`deleted`, `merged_into_id`), so
its row stays and is closed instead; see section 11.

### 2. A type

A type is one class registered under its kind. The engine calls it and knows nothing else about the domain. It
declares:

| Member | Purpose |
|---|---|
| `kind`, `version`, `target_class` | Identity. Bumping `version` re-queues resolved rows at the next fill |
| `candidates(scope)` | A relation of records that need this enrichment now (`ranked` or `all`) |
| `priority_sql` | The priority for a candidate |
| `still_needed?(record)` | Checked at claim time, so an item whose gap closed meanwhile is closed, not handed out |
| `payload(record)` | What the agent sees for one item: the record, what the pipeline already tried, stored evidence |
| `reference` | Per-type data sent once, not per item: the answer's JSON schema and any closed vocabulary |
| `submit(request, answer:, sources:, actor:)` | Validate, apply by the existing rules, write the ledger row, return what happened |
| `research(request)` | Optional. Work the item through the paid web-search path |
| `fingerprint(record)` | Optional. Review types only |

Engine code goes in `app/lib/services/enrichment_queue/`, books types in
`app/lib/services/books/enrichment_queue/`. The exact class layout is the builder's.

### 3. Filling a queue

`Fill` takes a kind, a scope (`ranked`, the default, or `all`) and an optional limit, and runs in a Sidekiq job. It
is started from the admin page's Fill form or `bin/rails "enrichment_queue:fill[kind,scope,limit]"`. It:

1. inserts a `pending` row for every candidate that has no row of that kind;
2. re-opens a `done` or `skipped` row, **only when its record is still a candidate**, whose `version` is below
   the type's version (reason `version`), or whose stored `fingerprint` differs from the record's current one
   (reason `changed`). A record whose gap is closed is never re-opened, whatever the version;
3. refreshes the `priority` of rows still `pending`, since ranks move;
4. leaves every other row alone.

Running it twice changes nothing the second time. That is the whole of "no repeated work": a resolved row is
never re-queued by a fill unless its type's version or its fingerprint says so, or an admin re-queues it by hand
from the page (reason `manual`).

Books with a running `books.book_enrichment` or `books.book_categorize` run are left out of `candidates`: that
import or paced backfill run is still enriching them, and would otherwise judge the book again after the agent.

### 4. Claiming

`claim(kind, limit)` picks pending rows in `(priority, id)` order with `FOR UPDATE SKIP LOCKED`, plus `claimed`
rows whose lease has expired, and marks them `claimed` with one `lease_token` for the batch and
`lease_expires_at` 30 minutes out. Limit is 1 to 25, default 10.

- Each picked row is checked with `still_needed?`. One that no longer needs it is closed (`done`,
  `no_longer_needed`, `resolved_via: system`) and the batch is topped up.
- `attempts` counts claims. A row claimed three times without a submit or skip is closed as `skipped` with outcome
  `abandoned` instead of being handed out a fourth time, so one item an agent keeps choking on cannot keep a queue
  from ever reaching empty.
- An empty batch with `remaining: 0` is how an agent knows to stop. A batch can also be empty while `remaining` is above 0 (all passes closed every row they picked, or a concurrent claim had other rows locked and they still read as pending when `remaining` was counted), and the agent then claims again (amended during implementation, 2026-11-18).

No sweeper job is needed: an expired lease is simply claimable again.

### 5. Submitting and skipping

`submit` takes the item id, the `lease_token`, an `answer` object, `sources` (at least one URL) and an optional
`note`.

- The lease must match. A row that was re-claimed by another batch answers 409 and writes nothing. An expired
  lease that nobody re-claimed is still accepted.
- The answer is validated against the type's JSON schema (`json_schemer` is already in the bundle through
  `openapi_first`). A failure is a 422 naming the problems; the row stays claimed so the agent can fix and resend.
- **The request does not apply the answer** (designer's call). Applying can call a model: the categories mapper's
  chooser, and in increment 2 the description review. Those calls can take many seconds, and several sub-agents
  submit at once against web servers that also serve music and games. So `submit` stores the answer and sources
  on the row, sets it `submitted`, queues a Sidekiq job and answers 202.
- The job runs the type's `submit`: it applies the answer and writes one `enrichments` row with mode `agent` (a
  new value of `Enrichment.mode`), the sources as `citations`, `facts["context"] = "agent"`,
  `facts["label"] = "agent"` and the same `prompt_version` key the judges write. The row becomes `done` with the
  ledger row's outcome.
- If applying raises, the job retries (Sidekiq, three attempts). After the last one the row is `failed` with the
  error, and a failed ledger row is written as the judges do. A failed row is not handed out again by itself; the
  admin page lists failed rows and its Re-queue button returns one to `pending`.
- Because the agent never sees the apply result, `get_enrichment_queue` also returns the type's outcome counts
  (applied, nothing applied, failed), which is what the agent reports at the end of a run.

`skip` takes the item id, the lease token and a reason of at most 500 characters. The row becomes `skipped` with outcome `skipped_by_agent`, and the reason is stored in `note` (amended during implementation, 2026-11-18). A
skipped row is resolved: it is not handed out again.

Both stamp `resolved_by` (the token's user), `resolved_via: api` and `resolved_at`.

A queue is empty when it has no `pending` and no `claimed` row. `submitted` rows are on their way to `done`.

**An agent's answer goes through the existing confidence gates unchanged** (designer's call). A `high` answer is
written, a `medium` one only with stored evidence that supports it, a `low` one is held. The prompt tells the
agent to say `high` only when a source states the fact, to give `low` to a guess, and to skip when it
cannot get there (amended during implementation, 2026-11-18). Nothing in the appliers is loosened for agents.

**A held answer closes the queue row but not the book.** When a submit applies nothing because the answer was
held back, the queue row is still `done` (outcome `nothing_to_apply`), so no agent is handed that book again.
But most books have no stored evidence yet, and the paced backfill gathers it and can settle a book the agent
could only half answer (the Wikidata shortcut, a supported `medium`). So an agent ledger row that applied nothing
does not count as done for the paced backfill: `Backfill.done_rows` leaves out every agent row that is not
`applied` (amended during planning, 2026-11-18; it named only outcome `nothing_to_apply`, which missed
`unrecognized`). An agent row that applied something does count. Such a row is also invisible as a "newer row":
a held agent answer leaves the book to the backfill only if the backfill has not judged it already, so it never
displaces the paid pipeline's done row as the latest row and never makes the backfill repeat itself
(amended during implementation, 2026-11-18).

**Where the code asks "was this researched on the web?"**, an agent row counts as well as a research row. Today
that is `Dossier#research_backed?`, which lets a web-verified `books.book_facts` row support an origin or
category answer. Where the code asks "did we pay for a search?" (`Enrichment.research`, the research caps, the
reports' research cost) an agent row does not count. The builder checks each use of the research mode against
those two questions.

### 6. The admin API and MCP tools

Five operations in `admin_openapi.yaml`, each with an `x-mcp` block. The type is addressed by the part of its kind
after the domain (`origin` for `books.origin`); the domain comes from the host, as for every admin operation.

| Tool | Operation | Scope |
|---|---|---|
| `list_enrichment_queues` | `GET /api/v1/admin/enrichment_queues` | `books:admin:read` |
| `get_enrichment_queue` | `GET /api/v1/admin/enrichment_queues/{type}` | `books:admin:read` |
| `claim_enrichment_items` | `POST /api/v1/admin/enrichment_queues/{type}/claims` | `books:admin:write` |
| `submit_enrichment_item` | `POST /api/v1/admin/enrichment_items/{id}/submit` | `books:admin:write` |
| `skip_enrichment_item` | `POST /api/v1/admin/enrichment_items/{id}/skip` | `books:admin:write` |

- `list_enrichment_queues` returns each type with its count per status.
- `get_enrichment_queue` returns the counts per status and per outcome, plus the type's `reference`: the answer
  schema and any closed vocabulary. It is separate from claim because the genre list with definitions is large
  and an agent needs it once, not with every batch. (This is a fifth tool; the conversation with Shane named
  four.)
- `claim_enrichment_items` returns the items, the `lease_token`, when the lease ends and `remaining`.
- `submit_enrichment_item` answers 202 with the row's status; it does not report what was applied (section 5).
- None is `destructive`. The queue tools are exempt from "dry run, then ask", like the duplicates queue:
  `config/mcp/books/admin_usage.md` gets a short section saying the agent decides each item itself.

The answer is one open object property in the request body, validated per type on the server. The MCP catalogue
keeps the top-level input strict and passes a property's own schema through, so this needs no catalogue change;
the builder confirms that with a catalogue test.

### 7. The copy prompts

`Services::AgentPrompts` already renders `config/mcp/<domain>/prompts/<queue>.md.erb` for the Copy prompt
buttons. It gains the queue types: a type's prompt is `config/mcp/<domain>/prompts/enrichment/<type>.md.erb`,
rendered with the MCP URL and the type's pending count. A type with no file gets no button.

Each prompt holds:

- the loop: call `get_enrichment_queue` once, then claim, research each item with the agent's own web search,
  submit or skip, and claim again until a claim comes back empty; sub-agents each run the same loop;
- the judgment rules for that type;
- what to report at the end.

The judgment rules are not copied by hand into the prompt. Each AI task exposes its rule text (the origin task's
nationality rules, the categories task's genre, subject and location rules), and both the task's system message
and the prompt file read it, so the paid model and the agent follow one text. As with the other queues, the rules
are in the pasted prompt, not in server instructions, so Shane can trim them per run.

### 8. The admin page

A new page per domain, built on a base controller like the duplicates and match decisions pages
(`Admin::DuplicateCandidatesBaseController` is the pattern), linked from the books admin navigation.

```
Enrichment queues                                   [books]
Type               Pending  Claimed  Done    Skipped
Book origin          2,409       40     312      18   [Copy prompt] [Fill…]
Book categories      2,619        0       0       0   [Copy prompt] [Fill…]
```

- **Fill…** opens a small form (scope ranked or all, optional limit) and queues the fill job.
- Clicking a type lists its rows, newest resolved first, with filters for status, outcome and `resolved_via`.
  Each row links to the record's admin page and shows the outcome, the note, the sources, who resolved it and
  when. The ledger row holds the full answer and is already shown on the book and author pages.
- A resolved row has a **Re-queue** button (reason `manual`).

The page needs a Playwright test (page loads, Copy prompt copies, Fill queues a job).

### 9. Increment 1: the engine, origin and categories

Everything in sections 1 to 8, plus two types. These two replace the paced backfill for the books that block
launch.

**`books.origin`**

- Candidates: books with a title and no real country (`Backfill.no_real_country_sql`).
- Payload: the book (title, subtitle, year, language, authors with their years and nationalities, held placeholder
  countries, a trimmed description), what the pipeline already tried (the latest `books.origin` row's answer,
  confidence and reason, if any), and the stored evidence dossier when a `books.evidence` row exists. Nothing waits
  for evidence to be gathered.
- Answer: the origin task's response shape (`recognized`, `nationality`, `confidence`, `reason`,
  `original_language`).
- Submit: `Services::Books::Origin::Apply`, unchanged, and a `books.origin` ledger row.

**`books.categories`**

- Candidates: books with a title and no direct genre beyond Fiction/Nonfiction (`Backfill.no_genre_sql`).
- Reference: the closed genre and audience lists as `id`, `name`, definition, the same list the judge builds.
- Payload: as for origin, plus the categories the book holds now with their sources.
- Answer: the categories task's response shape (book type, genres and audience by id, subjects and locations by
  name, `unlisted_genres`).
- Submit: `Categories::Mapper` then `Categories::Apply`, and a `books.categories` ledger row. The mapper's cheap
  chooser call (`CategoryChoiceTask`) still runs for a name with candidates. Agent submissions never remove a
  link (`rejudge: false`), which is what "blanks only" means for categories (designer's call).
- The `BOOKS_CATEGORIES_JUDGE_ENABLED` switch gates the automatic judge only. A submit is an explicit admin
  action and applies regardless (designer's call).

**How the two pipelines see each other.** The ledger row an agent submit writes carries the current
`prompt_version` and `deferred_research: false`. When it applied something, `Backfill.done_rows` counts the book
as done and the paced backfill skips it, and a book that owed research no longer does. When it applied nothing,
the backfill still takes the book (section 5). In the other direction, `still_needed?` and `candidates` look at
the data, so a book the cheap pipeline filled is not queued or handed out.

**Versions.** For these two types `version` is the task's `PROMPT_VERSION` (`BookOriginTask`,
`BookCategoriesTask`), not a second number. A prompt change then re-opens both pipelines together, and in the
queue only for books that still have the gap.

**Labels and the follow-up steps.** Agent rows carry `facts["label"] = "agent"`, so the existing reports read
them: `books:origin:report[agent]`, `books:categories:report[agent]` and `books:categories:add_aliases[agent]`,
which is how the agents' `unlisted_genres` become alias suggestions. `restore_removals` has nothing to restore,
since agent submissions remove nothing.

The judges' "answer in, ledger row out" half is shared by the paid path and the agent path, not duplicated. How
to extract it from `Origin::Judge#run` and `Categories::Judge#run` is the builder's.

Also in this increment: `docs/features/enrichment-queue.md`, the MCP and enrichment docs, and launch-todo steps.
The launch-todo steps go in section 14 and say:

- run the queues only after the Goodreads re-import's apply (section 12) is finished, since it empties and
  deletes books, and after the author Wikidata enrichment (section 15 step 11), since the payload shows author
  nationalities;
- run categories only after the definitions are written (section 14 step 2), since the reference list sends
  them;
- fill origin for ranked books, paste the prompt, let it run to empty; then categories; then the reports and the
  alias step with label `agent`;
- section 14's paced backfill is then the path for whatever is left.

### 10. Increment 2: book facts, author facts, the switch and the paid worker

**`books.book_facts`**

- Candidates: books missing a first published year, an original language or any description, where the field
  was not deliberately cleared (`cleared_fields`), plus books whose latest `books.book_facts` row is a research
  skip. A book needs at least one author link to be a candidate, and "no description" means no description row
  that is not deprecated (amended during planning, 2026-11-18). A book with an `ai_generated` description of any
  rank also has no gap for this queue, and `still_needed?` does not require an author link, so a deferral for a
  book whose links do not exist yet is still queued (amended during implementation, 2026-11-18).
- Answer: the book facts task's response shape.
- Submit: the path a research run takes today: the description review call (cheap), `DescriptionCheck`, then
  `ApplyBookFacts`. Blanks only. For an agent answer a description whose review call failed raises before anything
  is written, so the apply job retries and the row ends `failed`; the paid path keeps recording `review_failed`
  (amended during planning, 2026-11-18). An answer with overall `confidence` low is held: recorded with reason
  `low_confidence`, nothing written (amended during planning, 2026-11-18). What an answer writes: year, original
  language, word count, page range, subtitle and the description fill blanks, alternate titles are added to the ones the book holds; book type, series
  and origin countries are only recorded (amended during implementation, 2026-11-18).

**`books.author_facts`**

- Candidates: authors whose latest `books.author_facts` row is a research skip.
- Answer and submit: the author facts task's shape and `EnrichAuthor`'s apply half, with the same strict review and
  overall-low hold as book facts (amended during planning, 2026-11-18).

**The switch.** `config.x.ai.research_via`, read from ENV `AI_RESEARCH_VIA`: `api` (today's behaviour, the default
so a deploy changes nothing) or `queue`. With `queue`, every place that would have spent a web search
(`EnrichBook`, `EnrichAuthor`, the origin and categories judges) instead records the deferral it records today
when the budget is gone, with reason `queued`, and inserts a `pending` queue row with reason `research_wanted`.
A record that already has a resolved row of that kind is not re-queued. The admin page's force-research checkbox
still researches. A deferral inserts a row only when the type still needs the record, and a failed insert is
logged and never fails the enrichment (amended during planning, 2026-11-18). A low-confidence guess for a record
whose research is still owed to the queue is held, not applied, and is applied as today only when the record's
queue row is already resolved (amended during planning, 2026-11-18). A skipped research row spent no search and
does not count toward `research_daily_cap`, and `Books::EnrichBookJob` does not treat it as "researched"; in
`queue` mode the paced backfill counts a deferred row as done whatever the backfill cap; the admin page says which
mode is on (amended during planning, 2026-11-18).

**The paid worker.** `bin/rails "enrichment_queue:work[kind,limit]"` (limit required; the kind, for example
`books.origin`, as `fill` takes it; amended during planning, 2026-11-18) runs one Sidekiq job per row, each job
claiming its own row when it runs, with no retry (amended during planning, 2026-11-18). Each job runs the type's
`research`: the enricher or judge called directly with `force_research` and context `queue` (label `queue` on the
judges' rows), from stored evidence only, and the categories judge never removes a link in that context (rejudge
off; amended during planning, 2026-11-18). Rows end `done`
with `resolved_via: paid_research`. The limit is the cap: these runs are not stopped by `research_daily_cap` or
the backfill cap, and their ledger rows must not count against either, or one `work[origin,100]` would stop web
search for imports for the rest of the day. How the rows are marked so `Enrichment.against_research_cap` leaves
them out is the builder's.

### 11. Increment 3: series review

A review type, `books.series_review`, on `Books::Series`.

- The agent makes its changes with the existing series tools, then submits `{"result": "kept" | "changed"}` and a
  note. Nothing is applied, so this type's row goes straight to `done`.
- Series are soft-deleted, so their rows are never moved or deleted. A series that is merged away or deleted has
  its row closed when that happens (`done`, `reviewed`, `resolved_via: system`), and `candidates` is live series
  only.
- `fingerprint` is a digest of the series' live book ids. At the next fill a reviewed series whose book list
  changed is re-opened with reason `changed`, and its payload says which books are new since the review.
- When it ships, a one-off rake task records every live series as `done` / `reviewed` with its current
  fingerprint, so the review Shane already ran is not repeated. That is a launch-todo step.
- The series page's Copy prompt becomes this type's prompt.

### 12. Testing

- Model and engine: one row per record and kind; fill is idempotent; version and fingerprint re-open; claim
  never hands the same row to two batches; an expired lease is claimable; a stale token is 409; the third
  abandoned claim closes the row.
- Types: each `candidates` against fixtures that include books that must not be queued (a held country, a cleared
  field, a running import); submit writes what the paid research path would write for the same answer.
- API: the five operations, scopes, problems; the catalogue pins. Submit stores and queues; the job applies; a
  job that keeps failing leaves a `failed` row.
- The paced backfill skips a book an agent answered and applied to, and still takes one where the agent's answer
  was held.
- E2E for the admin page.

## Left to the builder

- Class and file layout inside the two service directories, and how the registry is populated.
- How the judges are split so the paid and agent paths share the apply half.
- Exact payload field names, kept close to what `Categorize::Dossier#to_ledger` already produces.
- The bulk insert in `Fill` (batch size, `insert_all`).
- What `provider` and `model` hold on an agent ledger row (the OAuth connection's client name if it is at hand).
- The admin page's markup, following the existing queue pages.
