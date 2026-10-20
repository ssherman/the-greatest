# Books enrichment workflows: design

**Date:** 2026-10-20
**Status:** Draft for Shane's review
**Origin:** Brainstorm on a Goodreads enrichment step (2026-10-19/20) plus Shane's proposal
`postgres-enrichment-workflow-proposal.md` (2026-10-20). The Goodreads step needs a join that today's
hand-off cannot express, so this coordinator comes first and Goodreads is built on it right after.

## 1. Intent

A new book's background enrichment is a chain of jobs that queue each other. Its order lives in four
places: the provider array, job arguments (`enrich_queued`, `via_viaf`, `in_line`), the latest
`enrichments` row (`deferred_to_authors`), and `sidekiq_retries_exhausted` hooks. That is now hard to
change safely, and it has one confirmed defect. With two new authors, the first author whose `EnrichJob`
finishes releases the book (`EnrichJob.hand_off` → `DeferredEnrichment.waiting_book_ids`). Book AI
enrichment then runs without the second author's nationality, and nothing ever re-runs it. No test
covers more than one author.

The next feature makes it worse. Goodreads enrichment (memory: `goodreads-enrichment-provider`) must
run before book AI enrichment and feed it, so book AI would wait on Goodreads **and** every new author,
finishing in any order.

This project moves that coordination into one place: **Postgres records each run, its steps and what
each step waits on. Sidekiq still runs the work.** Each workflow is defined in ordinary Ruby, as a short
list of steps and their dependencies. Changing the order, or adding a step (Goodreads), means editing
that definition.

What the database must be able to answer, for any book or author:

- Which steps belong to this run, and which have finished, with what outcome?
- What is each remaining step waiting for, and until when?
- Did a failure block the run or only one optional branch?
- After a crash, a deploy, or a lost Sidekiq message, what still has to happen? Recovery reads that
  from the tables, without anyone re-running a rake task.

## 2. Goals, non-goals, anti-goals

**Goals**

- Two workflows: **author enrichment** and **book enrichment**. A book run depends on the author runs
  of the authors its import created.
- Book AI enrichment waits for **every** new author to be ready, in any completion order.
- Cheapest steps first, the expensive AI step last. The order is written once, in the definition.
- Durable recovery: a dropped enqueue, a crashed worker or a deploy never strands a run.
- An admin panel on the book and author pages showing each run's steps, and a rake task listing stuck
  runs.
- The engine must carry the Goodreads step, which is added in the next project, without changes to the
  engine itself (§9).

**Non-goals**

- The Goodreads step itself. That is the next spec.
- Music and games importers, and their Amazon and cover-art jobs. They stay exactly as they are.
- A backfill of existing books or authors.
- Changing what any step *does*: matching, fill-blanks, identifier collision checks, the research cap,
  VIAF and Wikidata pacing. This project changes coordination only.
- Dashboards and alerting (observability initiative).

**Anti-goals (a failure even if it works)**

- A general workflow engine: a DSL, a graph language, event sourcing, a visual editor, Temporal, or
  Sidekiq Pro. The engine serves two workflow definitions, in plain Ruby.
- A run that waits forever with no record of why.
- A step that runs its external call or AI call while holding a database lock.
- Two parallel retry systems (Sidekiq retries and workflow retries) competing over the same step.
- Any loss of the protections the current steps have: fill-blanks only, provenance, identifier
  collision flags, `enrich: false` for Goodreads member imports.

## 3. Today, in brief (verified 2026-10-20)

- `Book::Importer` provider order: OpenLibrary, Authors, [QueryIdentifiers], then with `enrich:` true
  AiEnrichment, AuthorEnrichment, Amazon. The importer has no transaction of its own; async providers
  enqueue inside `ActiveRecord.after_all_transactions_commit`.
- AiEnrichment defers (a skipped `books.book_facts` row, reason `deferred_to_authors`) when the import
  created a linked author. Otherwise it queues `EnrichBookJob(book_id, false, author_names)` on `low`.
- AuthorEnrichment queues `Books::Authors::WikidataJob` for each created author. The chain:
  - `WikidataJob` → `ViafJob` on a first-pass miss, otherwise → `EnrichJob`.
  - `ViafJob` → `WikidataJob(refresh, via_viaf)` when VIAF returns a QID it does not need reviewed;
    otherwise → `EnrichJob` (unless `enrich_queued`). When VIAF is paused or its turn is more than
    `CHAIN_PATIENCE` (600 s) away, it queues `EnrichJob` now and keeps its own turn (`enrich_queued`).
  - `EnrichJob` → hands off waiting books, on success or when retries are exhausted.
  - All on `author_chain`, `retry: 3`. Wikidata and VIAF rate limits reschedule with `perform_in`,
    without limit.
- Amazon queues `AmazonProductEnrichmentJob` on `serial` (default 25 retries, `find_by!`).
- Other entry points: list wizard text rows (`TEXT_PROVIDERS = %i[authors ai_enrichment
  author_enrichment amazon]`), Goodreads `PromoteRecords` (defers books and queues author, book and
  Amazon jobs after commit), the admin **Enrich With AI** action (`force_research`), author `Backfill`,
  `RejectExternalLink` (Wikidata re-run after a delay), the author importer's own `Providers::Enrichment`
  (console and tests only).
- Repair: `books:enrich_missing` (it cannot tell a stranded book from one still waiting),
  `books:authors:enrich`.
- Merges: the book and author mergers move `enrichments` rows (deferrals included) to the survivor and
  queue no enrichment. Jobs for the merged-away record no-op, except Amazon's `find_by!`, which retries
  25 times.
- Infrastructure: Sidekiq 8.1, sidekiq-cron 2.4 (`config/schedule.yml`, 6-field cron works), strict
  queues `critical, default, low, author_chain`, capsules `serial` and `goodreads_fetch` (concurrency
  1). Deploys push running jobs back and re-run them from the start; a crash or OOM loses them.

## 4. Decisions

### 4.1 Shane's decisions (from the brainstorm)

- Refactor first, then build Goodreads on it.
- Authors get their own workflow. The book workflow does not wait for the whole author run, only for
  the author to be **ready**.
- Order is cheapest first, with the expensive AI step last. **Amazon always runs** (images, editions);
  it is never skipped as redundant.
- Book AI enrichment **keeps waiting** for the authors the import created. It needs their years and
  nationality, which feed the book's origin country. This must stay a one-line change in the
  definition.
- Amazon will wait on Goodreads (for an ISBN search) but **not** on book AI enrichment.
- Visibility: an "Enrichment runs" panel on the admin book and author pages, plus a rake task listing
  stuck runs. No dashboard.

### 4.2 Architectural direction (from Shane's proposal, settled)

Postgres-backed coordination, existing Sidekiq execution, application-owned Ruby workflow definitions.
Steps are claimed with a lease and an ownership token, and a periodic recovery job redispatches lost
work. Execution is at-least-once, and steps stay idempotent.

## 5. Data model

Three tables, global namespace (shared infrastructure, like `Enrichment`). The names are my call: they
avoid confusion with the existing `Enrichment` ledger, which stays and records *what facts* a step
produced.

### `workflow_runs`

| column | notes |
|---|---|
| `workflow` | string, e.g. `books.book_enrichment`, `books.author_enrichment` |
| `definition_version` | integer, set at plan time; a run keeps the plan it started with |
| `enrichable_type`, `enrichable_id` | polymorphic target (`_able` convention, same name as `enrichments`) |
| `status` | enum: `running`, `completed`, `completed_with_failures`, `cancelled` |
| `options` | jsonb, persisted at start: `force_research`, `allow_research`, `refresh`, `only` (step keys requested), `author_names` |
| `initiated_by` | string: `importer`, `list_wizard`, `goodreads_promote`, `admin`, `rake`, `reject_external_link`, … |
| `parent_run_id` | nullable; the book run that started an author run, for display only |
| `started_at`, `finished_at`, `error_summary` | |

Partial unique index: **one active run per (workflow, enrichable)** where `status = running`.

### `workflow_steps`

| column | notes |
|---|---|
| `workflow_run_id`, `key` | unique together; `key` is stable, e.g. `wikidata`, `viaf`, `book_facts` |
| `state` | enum: `blocked`, `ready`, `running`, `waiting`, `succeeded`, `skipped`, `failed` |
| `outcome` | string, the step's business result: `matched`, `unmatched`, `applied`, `no_match`, `not_needed`, `target_gone`, `not_requested`, … |
| `released_at` | when dependents may proceed; set on every terminal state, and earlier for a step that releases dependents while it keeps working (VIAF, §6.1) |
| `run_after` | earliest time it may run (retry backoff, rate-limit wait, delayed start) |
| `attempts`, `max_attempts` | business retries for unexpected errors only; rate-limit waits do not count |
| `lease_token`, `lease_expires_at`, `dispatched_at`, `dispatch_count` | claim and dispatch bookkeeping |
| `queue` | Sidekiq queue the step runs on (copied from the definition at plan time) |
| `result` | jsonb, the summary a dependent step may read (e.g. VIAF's QID; later Goodreads' facts) |
| `error` | last error message |
| `started_at`, `finished_at` | |

### `workflow_dependencies`

| column | notes |
|---|---|
| `step_id` | the waiting step |
| `prerequisite_step_id` | the step it waits on; **may belong to another run** (a book step waiting on an author run's step) |
| `kind` | enum: `release` (satisfied when the prerequisite is released) or `finish` (satisfied only when the prerequisite is terminal) |
| `satisfied_at` | set when the edge is satisfied |

Unique on (`step_id`, `prerequisite_step_id`). A step becomes `ready` when every dependency is
satisfied (and `run_after` has passed).

**Two edge kinds, and release passing through.** A `finish` edge means "I need its answer" (VIAF's
QID). A `release` edge means "I only need it out of my way". When a step is released early (§6.1), any
still-`blocked` step that waits on it by a `finish` edge, and whose other `finish` prerequisites are
all released, is **released too, without being evaluated**: its `released_at` is set but it stays
`blocked` until it can actually run or be skipped. Release passes along that way until it reaches
`release` edges. So `released_at` on a step that has not run means "nothing downstream should wait for
me", which is exactly what a long VIAF wait needs.

### Ledger link

`enrichments.workflow_step_id`, nullable, so the panel can show which ledger rows a step produced. A
step can produce several (knowledge plus research).

## 6. Workflow definitions

Plain Ruby classes under `app/lib/workflows/books/`. Each declares its steps (key, queue, max attempts,
lease length, dependencies, and a condition that decides between running the step and skipping it with
a reason). Each step's work is a small adapter around an **existing service**. The adapters never
enqueue a successor; that is the coordinator's job (§7).

### 6.1 `books.author_enrichment`

| step | queue | waits on | runs when | adapter |
|---|---|---|---|---|
| `wikidata` | `author_chain` | — | always | `EnrichFromWikidata` (with `refresh` from options) |
| `viaf` | `author_chain` | `wikidata` (finish) | `wikidata` outcome is `unmatched`, or the run starts here (below) | `EnrichFromViaf`, with `Viaf::Gate`/`Viaf::Schedule` waits |
| `wikidata_via_viaf` | `author_chain` | `viaf` (finish) | `viaf` returned a QID that does not need review | `EnrichFromWikidata` refresh, via_viaf |
| `author_facts` | `author_chain` | `wikidata`, `viaf`, `wikidata_via_viaf` (all release) | always, unless `skip_ai_if_ran` and the AI step already ran (below) | `EnrichAuthor` (`allow_research` from options) |
| `author_facts_late` | `author_chain` | `wikidata_via_viaf` (finish), `author_facts` (finish) | `wikidata_via_viaf` actually ran **and** `author_facts` started before it finished | `EnrichAuthor` again (fill-blanks; it skips a `complete` author) |

**The fast path is today's order.** When VIAF answers within patience, `viaf` finishes,
`wikidata_via_viaf` runs or is skipped, and only then is `author_facts` free, so the AI step sees the
VIAF-found Wikidata facts, as `ViafJob → WikidataJob → EnrichJob` does now. `author_facts_late` is
skipped `not_needed`.

**VIAF patience, preserved.** When the VIAF turn is more than `CHAIN_PATIENCE` away, or VIAF is
paused, the `viaf` step is released early and goes on `waiting` until its turn. Release passes through
the still-blocked `wikidata_via_viaf` (§5), so `author_facts` runs now. When `viaf` later finishes,
`wikidata_via_viaf` is evaluated for real: with a QID it runs, and `author_facts_late` then runs too.
That is today's "second EnrichJob", made explicit. A skipped conditional step (`viaf` after a match,
for example) is released with outcome `not_needed`.

**Starting mid-chain (my call, preserving today's backfill).** `Authors::Backfill` re-queues VIAF
for authors whose Wikidata step already missed, passing `enrich_queued` so the AI step is not paid for
twice. A new run would never reach VIAF for them, because `wikidata` returns `already_processed`. Two
run options keep that behavior:

- `start_at: :viaf` plans `wikidata` as skipped (`not_requested`, outcome treated as `unmatched`), so
  `viaf` runs unconditionally;
- `skip_ai_if_ran: true` skips `author_facts` (`already_ran`) when the backfill's existing "AI step
  ran" test (`Backfill#ai_step_ran`) is true. `author_facts_late` still runs after a late QID, as the
  second EnrichJob does today.

An old in-flight `ViafJob` message after deploy maps to the same options, `skip_ai_if_ran` set from its
`enrich_queued` argument.

**Author readiness** = `author_facts` released, whatever its outcome. That matches today's hand-off,
which happens on success **and** on exhausted retries. A book never waits on late VIAF work.

The `wikidata` step's re-entry quirk (an author already processed gets `skipped` and goes straight to
the AI step, never VIAF) is preserved as-is. Fixing it is out of scope.

### 6.2 `books.book_enrichment`

| step | queue | waits on | adapter |
|---|---|---|---|
| `book_facts` | `low` | `author_facts` of every author run this import started (cross-run) | `EnrichBook` (`force_research`, `author_names` from options) |
| `amazon` | `serial` | nothing today; `goodreads` once that step exists | `AmazonProductService` (stamps `amazon_enriched_at` as the job does) |

With no new authors, `book_facts` is ready at once. **Adding or removing the author wait is the single
`waits_on` line on `book_facts`.**

`only:` (from `options`) limits a run to the requested steps; the others are planned and immediately
skipped with outcome `not_requested`.

**The admin Enrich With AI button stays outside workflows (my call).** It keeps queuing
`EnrichBookJob(id, force_research)` directly. It is a manual action, fill-blanks and idempotent, so it
needs no coordination. Making it a run would collide with the one-active-run rule: a book's import run
stays active for hours while `amazon` waits in the `serial` line, and the button would do nothing. Its
ledger row still shows on the book page.

### 6.3 Author run reuse

When a book run needs an author that already has an active `books.author_enrichment` run, it depends on
that run's `author_facts` step instead of starting another. Only authors the import **created** start
or join an author run, as today. A refresh request (`RejectExternalLink`, `refresh: true`) never
attaches to an active run. It **supersedes** it (my call): in the same transaction as the reject, the
active run is cancelled (its unfinished steps skipped with outcome `superseded`, which releases them)
and a new run is planned. A book waiting on the old run's `author_facts` is released by that, and
proceeds without waiting for the refreshed author. Refusing instead would block a reject for as long as
a VIAF turn takes, which can be days during a backfill, and the reject cannot simply be retried later,
because a second reject is refused as "already rejected". The re-run is planned inside the reject's
transaction, as the `perform_in` is today.

## 7. Coordinator protocol

`Workflows::Coordinator` plus a single job, `WorkflowStepJob`, enqueued with
`.set(queue: step.queue).perform_async(step.id)` so each step keeps today's queue and capsule (`serial`
for Amazon, `author_chain` for authors, `low` for book AI).

1. **Plan.** In one transaction, create the run, all its steps (`blocked`, or `ready` if they have no
   dependencies) and dependency rows, and resolve conditions known at plan time (`only:`). Planning
   happens **after** the book and its `book_authors` are committed (`after_all_transactions_commit`,
   as the providers do now). A rolled-back import plans nothing.
2. **Dispatch.** After commit, enqueue every `ready` step whose `run_after` has passed, and stamp
   `dispatched_at` and `dispatch_count`. **Redispatch backs off exponentially (my call):** a step still
   `ready` is dispatched again only after a window that doubles with each dispatch (for example 10 min,
   20, 40, … capped at 12 h). A queue backlog (tens of thousands in `author_chain` during a backfill,
   or a long `serial` line) then produces only a handful of duplicate messages per step, each of which
   fails to claim and exits at once. A genuinely lost message is still recovered, at worst after the
   cap. Inspecting Sidekiq's queues instead was rejected: it is slow on big queues and cannot see
   running jobs.
3. **Claim.** The job atomically moves its step from `ready` to `running` with a conditional update,
   sets `lease_token` and `lease_expires_at`, and increments `attempts` (house style: compare-and-set,
   as `RankingConfigurations::RefreshJob` does). A duplicate message that cannot claim exits.
4. **Execute.** Run the adapter **outside** any transaction. The adapter returns one of:
   `succeeded(outcome, result)`, `skipped(outcome)`, `wait(until:, release:)` (rate limit or VIAF turn;
   not counted as an attempt), or it raises.
5. **Finish.** Record the result **only if the lease token still matches**. A stale worker's write is
   dropped. On an exception: back to `waiting` with exponential backoff until `max_attempts`, then
   `failed`.
6. **Advance.** In a short transaction holding a row lock on the prerequisite step:
   - mark its dependencies satisfied;
   - move dependents whose dependencies are now all satisfied to `ready`, or to `skipped` when their
     condition says so (which releases them in turn);
   - when every step in a run is terminal, set the run's status.

   Then dispatch the newly ready steps after commit. Two author runs finishing at the same moment both
   lock and advance; the book step becomes `ready` exactly once, because the transition is conditional.
7. **Recover.** `WorkflowRecoveryJob`, every minute via sidekiq-cron, on `default`:
   - dispatch `ready` steps whose dispatch window lapsed;
   - move `waiting` steps whose `run_after` has passed back to `ready`, and dispatch them;
   - reclaim `running` steps whose lease expired (back to `ready`, the attempt counted);
   - re-advance any released step whose dependents were not advanced (an interrupted step 6).

**Sidekiq retries.** `WorkflowStepJob` runs with `retry: 0`. The workflow owns business retries.
`Sidekiq::Shutdown` re-raises. The pushed-back message carries the same step id, and its claim is
allowed when the lease is expired **or** the token matches the job's `jid` (the token is the jid).
That lets a deploy-interrupted step resume at once without waiting out its lease.

**Lease lengths.** Per step in the definition, sized to the slowest normal run: a few minutes for
Wikidata and VIAF, longer for `book_facts` research (web search) and `author_facts`. The builder sets
them from measured durations.

**Rate-limit waits.** The Wikidata and VIAF adapters keep their current gate and schedule logic. Where
a job used to call `perform_in`, the adapter returns `wait(until:)`; the coordinator stores `run_after`
and the recovery sweep (or a `perform_at` at finish time) brings it back. Jitter is kept.

## 8. Edge cases

- **Target deleted or merged away.** The adapter finds no record, and the step finishes `skipped` with
  outcome `target_gone`. The coordinator cancels the rest of that run (each remaining step is skipped
  `target_gone`, so it is released). Dependents in other runs see the prerequisite released and
  proceed, so a book never waits on a merged-away author. This also fixes Amazon's 25 retries on a
  merged book.
- **Book merger.** Runs on the merged-away book are cancelled as above. The survivor gets no new run,
  matching today (the merger queues no enrichment). Deferral rows the merger moves are inert once
  nothing reads them.
- **Exhausted required step.** `failed`, released. The run ends `completed_with_failures` and shows in
  the stuck-runs task. Book AI still runs after an author's `author_facts` failed, as today.
- **Re-import of a matched book.** No run (providers do not run for a matched record without
  `force_providers`). With `force_providers`, a new run if none is active, otherwise none (logged).
- **Research cap, `amazon_enriched_at`, fill-blanks.** Untouched; they live in the services.
- **Goodreads member imports (`enrich: false`).** Still plan nothing. `PromoteRecords` plans runs on
  approval.

## 9. What the Goodreads project will need from this

It must be able to add, by editing only `books.book_enrichment`:

- a `goodreads` step (queue `goodreads_fetch`; its rate-limit gate returns `wait(until:)`);
- `book_facts` waits on `goodreads` and on the author steps;
- `amazon` waits on `goodreads`;
- `book_facts` and `amazon` read `goodreads`' `result` (identifiers, facts, description).

The engine supports this through cross-step `result` reads and multiple dependencies per step. The
builder should keep a test definition with that shape (two prerequisites, one result read) to prove it.

## 10. Entry points after the change

| entry point | today | after |
|---|---|---|
| `Book::Importer` with `enrich: true` | AiEnrichment, AuthorEnrichment, Amazon providers | one provider, `Providers::Enrichment`, that plans author runs for created authors and a book run, after commit. Provider symbol `:enrichment`. |
| List wizard text rows | `TEXT_PROVIDERS` with the three symbols | `%i[authors enrichment]` |
| Goodreads `PromoteRecords` | defer, then queue author, book and Amazon jobs | plans author runs for promoted authors and a book run per promoted book (`book_facts` waits on the promoted authors credited to it) |
| Admin **Enrich With AI** | `EnrichBookJob(id, force)` | unchanged (§6.2) |
| Author importer `Providers::Enrichment` (direct import) | `WikidataJob` immediately | plans an author run after commit |
| `Authors::Backfill`, `books:authors:enrich` | queues `WikidataJob`, or `ViafJob(id, false, ran, false)` for a Wikidata miss | plans author runs: from the start, or `start_at: :viaf, skip_ai_if_ran: ran` (§6.1); its "skip if queued" check reads active runs instead of Sidekiq queues |
| `RejectExternalLink` | `WikidataJob.perform_in(RERUN_DELAY, id, true)` inside the reject's transaction | supersedes any active run and plans one with `refresh: true`, `wikidata.run_after = now + RERUN_DELAY`, in the same transaction (§6.3) |
| `books:enrich[id]`, `books:amazon_enrich[id]` | run inline | unchanged (inline debugging tools, no run) |
| `books:amazon_enrich_ranked` | queues `AmazonProductEnrichmentJob` | unchanged (a sweep, not an import step) |
| `books:enrich_missing` | queues books with no ledger row, plus deferred ones | keeps the first group; the deferral group is replaced by workflow state and the rule about checking Sidekiq queues goes away |

`EnrichBookJob`, `AmazonProductEnrichmentJob` and the three author jobs stay as classes for the inline
rake tools and for messages already in flight at deploy (§11), but nothing in the import path enqueues
them.

## 11. Rollout

Books has not launched, but production does run book imports (list wizard, Goodreads approvals,
legacy replay apply) and author chains. Music and games are not touched.

1. **Engine plus author workflow.** Tables, coordinator, job, recovery cron, definitions, and the
   author entry points. The old author jobs, if a message for one arrives after deploy, plan an author
   run instead of chaining, so nothing runs both ways: an old `WikidataJob` plans a run from the start
   (with its `refresh` flag); an old `ViafJob` plans `start_at: :viaf, skip_ai_if_ran: enrich_queued`;
   an old `EnrichJob` plans a run with `only: [author_facts]` and still performs today's hand-off of
   waiting books, since those books have no run yet. If a run is already active for the author, the
   old message does nothing.
2. **Book workflow.** The single enrichment provider, wizard, `PromoteRecords`, admin action. Old
   deferred books: a one-off rake task plans a book run for every book whose latest `books.book_facts`
   row is still `deferred_to_authors`, depending on any active author runs for its authors.
3. **Retire the old hand-off.** Remove `DeferredEnrichment`, `EnrichJob.hand_off`, the deferral branch
   of `enrich_missing`, and the chaining code in the author jobs, once a production check shows no old
   messages are left in `author_chain`, Scheduled or Retry.

Each increment ships green on its own. Increments 1 and 2 may be one PR if the builder prefers; 3 is
separate.

## 12. Admin visibility

- **Book and author show pages:** a full-width "Enrichment runs" card after Categories, loaded as a
  lazy turbo frame (house style). Newest run first; each run lists its steps with state, outcome,
  attempts, `run_after` for a waiting step, error, and, for a blocked step, its unsatisfied
  prerequisites linked to the other run's record. Ledger rows linked by `workflow_step_id` are listed
  under their step.
- **`bin/rails workflows:stuck`:** runs with a `failed` step, steps `waiting` or `blocked` longer than a
  threshold, and `running` steps past their lease. One line each, with the target.

## 13. Acceptance scenarios

The builder's tests must cover:

- A book with two new authors waits for both, in either completion order; simultaneous completion
  makes `book_facts` ready once.
- A book with no new authors runs `book_facts` at once.
- A duplicate step message does not run the step twice; a stale worker cannot overwrite a newer
  attempt's result.
- A worker crash before, during and after execution recovers through the sweep; a committed advance
  followed by a failed enqueue is recovered.
- Wikidata `unmatched` runs VIAF; `matched` skips it. A Wikidata rate limit waits without counting an
  attempt.
- VIAF within patience: `wikidata_via_viaf` finishes before `author_facts` starts, and
  `author_facts_late` is skipped.
- VIAF beyond patience: release passes through `wikidata_via_viaf`, `author_facts` runs at once, and
  `viaf` finishes later; a late QID runs `wikidata_via_viaf` and then `author_facts_late`.
- `start_at: :viaf` runs VIAF for an already-processed author; `skip_ai_if_ran` skips `author_facts`
  when the AI step already ran.
- A reject supersedes an active author run, releases its waiting book, and plans the refresh run in the
  reject's transaction.
- A step's redispatch window doubles; a backlog yields a bounded number of duplicate messages.
- Required-step exhaustion gives `completed_with_failures`, and a book still proceeds after its author's
  `author_facts` failed.
- A deleted or merged author releases the waiting book; a deleted book cancels its run.
- `only:` skips the rest with `not_requested`; `enrich: false` plans nothing; a rolled-back wizard row
  plans nothing.
- The Goodreads-shaped test definition (two prerequisites, one result read) works (§9).
- An in-flight old `WikidataJob` message after deploy plans a run and does not chain.
- Plus everything the existing step services already test, unchanged.

Testing note: `Sidekiq.testing!(:inline)` is global, so dispatch runs steps inline and recursively in
tests. That is fine for end-to-end tests of a whole run; the coordinator's own unit tests should use
`Sidekiq::Testing.fake!` blocks to step through one transition at a time.

## 14. Left to the builder

- Exact class names inside `app/lib/workflows/`, and how a definition is expressed in Ruby (keep it
  plain: a frozen list of step structs is enough).
- Lease lengths, the dispatch window, backoff curve and the stuck threshold, set from measured
  durations.
- Whether `parent_run_id` earns its place in the panel.
- Docs: update `docs/features/data_importers.md`, `books_enrichment.md` and
  `books-author-enrichment.md`, and add `docs/features/enrichment-workflows.md` for the engine.
