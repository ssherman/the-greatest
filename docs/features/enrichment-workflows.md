# Enrichment workflows

A small Postgres-backed workflow engine that runs book and author enrichment. A **run** is one
execution of a fixed set of **steps** against one record; the rows in Postgres decide what runs
next, and Sidekiq only executes a step when told to. It replaced a set of Sidekiq jobs that each
enqueued the next one, which lost work whenever a message disappeared and could not express "the
book waits for its author" without a database flag and a rake task to rescue strays.

Spec: `docs/superpowers/specs/2026-10-20-books-enrichment-workflows-design.md`. The engine runs two
workflows: `books.author_enrichment` and `books.book_enrichment`. The author steps themselves (what Wikidata, VIAF and the AI step do) are in
`docs/features/books-author-enrichment.md`.

## Where the code lives

| What | Where |
|---|---|
| Tables' models | `app/models/workflow_run.rb`, `workflow_step.rb`, `workflow_dependency.rb` |
| Engine | `app/lib/workflows/` (`Planner`, `Coordinator`, `Dispatcher`, `Recovery`, `Registry`, `Definition`, `Step`, `Outcome`, `Stuck`) |
| Definitions | `app/lib/workflows/books/author_enrichment.rb`, `book_enrichment.rb` |
| Step adapters | `app/lib/workflows/books/steps/` (`Wikidata`, `Viaf`, `AuthorFacts`, `BookFacts`, `Amazon`) |
| Jobs | `app/sidekiq/workflow_step_job.rb`, `app/sidekiq/workflow_recovery_job.rb` (cron, every minute, `config/schedule.yml`) |
| Admin panel | `Admin::Books::WorkflowRunsController`, `app/views/admin/books/workflow_runs/` |
| Test support | `test/support/workflows/` (`TestDefinition`, a Goodreads-shaped diamond; `DispatchHelper`) |

## Tables

- **`workflow_runs`** -- one row per execution. `workflow` (name, e.g. `books.author_enrichment`),
  `definition_version`, polymorphic `enrichable` (`"Books::Author"` / `"Books::Book"`), `status`
  (`running`, `completed`, `completed_with_failures`, `cancelled`), `initiated_by` (who asked:
  `author_importer`, `backfill`, `reject_external_link`, `legacy_job`, ...), `options` (jsonb),
  `parent_run_id`, `started_at`, `finished_at`, `error_summary`. A partial unique index allows
  **one `running` run per (workflow, enrichable)**. The target association is optional on purpose:
  a merged or deleted record must not stop its run from being updated and cancelled. There is no
  `has_many :workflow_runs` on `Books::Book` or `Books::Author` (a new book association needs a
  merger rule); query `WorkflowRun.where(enrichable: record)`.
- **`workflow_steps`** -- one row per step per run. `key`, `queue`, `state`, `attempts` /
  `max_attempts`, `run_after`, `released_at`, `started_at` / `finished_at`, `outcome` (a short
  label), `result` (jsonb the step wrote and later steps may read), `error`, and the coordination
  fields `lease_token`, `lease_expires_at`, `lease_seconds`, `dispatched_at`, `dispatch_count`.
  `(workflow_run_id, key)` is unique.
- **`workflow_dependencies`** -- the edges: `step` waits on `prerequisite_step`, which may belong to
  **another run** (that is how a book will wait for its author). `kind` is `release` or `finish`;
  `satisfied_at` is stamped once and never un-stamped.
- **Ledger link.** `enrichments.workflow_step_id` ties every ledger row written while a step ran to
  that step, whichever provider wrote it (`Current.workflow_step_id`, set around the adapter call).
  It nulls if the step is deleted.

## Step states

`blocked` (waiting on edges) -> `ready` (may be dispatched) -> `running` (a worker holds the lease)
-> `succeeded`, `skipped`, or `failed`. A step can also be `waiting`: it is
held until `run_after` and only the sweep wakes it. The reasons are a rate limit, a place in the VIAF
line, a run planned with `start_after` (the backfill's pacing), and **a failed attempt's backoff**.
`succeeded`, `skipped` and `failed` are terminal.

## Edges and release

A **`finish`** edge is satisfied when the prerequisite is terminal. A **`release`** edge is
satisfied as soon as the prerequisite is **released**: terminal, or earlier, when a step hands off
while it keeps working (`Outcome.wait(time, release: true)`). The VIAF step does this when VIAF is
paused or its turn is more than `CHAIN_PATIENCE` away, so the AI step proceeds now and VIAF's
facts arrive as fills later.

**Pass-through release (Ruling 5).** A step that is still `blocked` becomes released without ever
running when **every** prerequisite is released but its own edges are not all satisfied. That keeps
a chain of waits from holding a dependent hostage behind a step that is itself only waiting. A
step with a mix (one prerequisite still unreleased) keeps waiting.

## Definitions, conditions, options

A definition (`Workflows::Definition` subclass) declares `workflow` name, `version`,
`target_class`, and ordered steps through `add_step`:

| Argument | Meaning |
|---|---|
| `key`, `queue` | The step's name and the Sidekiq queue it dispatches onto |
| `adapter` | Anything responding to `call(step:, run:, target:)`; returns a `Workflows::Outcome` or raises |
| `waits_on` | `{prerequisite_key => :finish \| :release}` |
| `max_attempts` | Default 3 |
| `lease` | How long a worker may hold the step before the sweep reclaims it (default 10 minutes) |
| `skip_if` | `->(run) { "reason" or nil }`; a string skips the step with that outcome |
| `on_terminal` | `->(step, target) { ... }`, a side effect run when a worker finishes or fails the step |

An adapter returns `Outcome.succeeded(label, result)`, `Outcome.skipped(label)`, or
`Outcome.wait(time, release: false, result: {})`. **Failure is a raise**, so retry and backoff have
exactly one path. `Outcome.wait` requires a time: a nil one would wait forever, since only the sweep
wakes a waiting step.

Run `options` are plain data on the run (`refresh`, `allow_research`, `skip_ai_if_ran`) plus two the
engine reads itself: `start_at` (every step before the named one) and `only` (every step not
listed) are planned already `skipped`, outcome `not_requested`, and released, so edges on them are
satisfied at once. Adapters and `skip_if` read the rest from `run.options`. `start_after:` on the
planner holds the run's first steps in `waiting` until that time (the backfill's pacing, the
reject's 10-second delay).

**Conditions are evaluated by the coordinator at advance time**, when a step's edges are all
satisfied, and never by dispatching the step. Dispatching only to skip would put the step at the
back of a queue that may hold tens of thousands of jobs, several times per author.

**`on_terminal` fires only when a worker finishes or fails the step.** A step skipped by
`skip_if`, cancelled, or reclaimed by the sweep never calls it, and a raise from it is logged and
swallowed so dependents still advance. It is a side effect, never a gate. The author workflow uses
it for the transitional legacy hand-off (see below).

## The coordinator protocol

1. **Plan** (`Workflows::Planner.call`, usually through `Definition.start`). One transaction writes
   the run, all steps (`ready` if they have no prerequisites, else `blocked`) and the edges, applies
   `start_at`, and resolves anything already known. **The plan rows are written in the caller's
   transaction**, so a rollback plans nothing, and a crash between commit and plan cannot lose a
   book's enrichment. If the target already has a `running` run for this workflow, `start` returns
   that one (a unique violation from a concurrent planner is treated the same way). `supersede: true`
   cancels the active run first (outcome `superseded`).
2. **Dispatch** (`Workflows::Dispatcher`). `Dispatcher.after_commit(steps)` enqueues
   `WorkflowStepJob` onto each step's queue **after the surrounding transaction commits**, so a
   worker never finds a step still blocked. Redis errors are rescued and logged per step; the step
   stays `ready` with its `dispatched_at` untouched, which is exactly what the sweep looks for. A
   dispatch is a nudge, not a guarantee.
3. **Claim** (`Coordinator.claim`). One conditional UPDATE from `ready` to `running`, setting the
   lease. The **token is the Sidekiq jid**, so a job pushed back by a deploy claims its own step
   again immediately, without waiting out the lease and **without burning an attempt**. A duplicate
   message cannot claim and returns.
4. **Execute.** The adapter runs outside any transaction. `WorkflowStepJob` has `retry: 0`: the
   workflow owns retries. `Sidekiq::Shutdown` is re-raised.
5. **Finish** (`Coordinator.finish` / `fail`). Token-guarded: a worker whose lease was lost writes
   nothing. A raise puts the step in `waiting` with `run_after` set to the backoff, `30 s x 4^(n-1)`
   (30 s, 2 min, 8 min), and the next sweep after that wakes it; at `max_attempts` it is `failed`
   and released instead. **Attempts count failures and expired leases,
   not claims**, so a rate-limit wait or a deploy push-back never uses one up.
6. **Advance** (`Coordinator.advance`). For each edge on a step that finished or was released:
   record it satisfied, lock the dependent `FOR UPDATE` (in id order), and evaluate it: `ready`,
   `waiting` (run_after in the future), `skipped` (its condition), or released through. A dependent
   that comes out skipped or released is advanced in turn. The conditional transitions make the
   advance exactly-once even when two prerequisites finish at the same moment. Every touched run with
   no open step left is closed (`completed`, or `completed_with_failures` if any step failed).
   **A `waiting` step is never dispatched from a finish**: only the sweep moves `waiting` to `ready`.
7. **Cancel** (`Coordinator.cancel(run, outcome:)`). Skips every unfinished step with the outcome,
   releases each so nothing downstream waits on it, advances dependents in other runs, and marks the
   run `cancelled`. A deleted target does this with outcome `target_gone`.

## Recovery

`WorkflowRecoveryJob` runs `Workflows::Recovery` **every minute** (queue `default`). Nothing else in
the engine has to survive a crash. Passes, in order, each independent (one that raises is logged and
the next still runs) and each a conditional update or a call through the coordinator, so it can
overlap a worker or another sweep:

1. **cancel** runs whose target row is gone (`target_gone`);
2. **reclaim** `running` steps whose lease expired (the expiry counts as the attempt: back to
   `ready`, or `failed` at `max_attempts`);
3. **wake** `waiting` steps whose `run_after` has passed (back to `ready`, dispatch bookkeeping reset);
4. **re-advance** edges that are satisfiable but were never recorded (an interrupted advance, a raised
   `on_terminal`, a deadlock abort);
5. **close** `running` runs whose steps are all terminal (a leaf whose advance was interrupted would
   otherwise block its target's one-active-run slot for good);
6. **redispatch** `ready` steps never dispatched, or dispatched longer ago than a window that doubles
   with every dispatch: `min(10 min x 2^(dispatch_count - 1), 12 h)`. The doubling keeps a step stuck
   behind a deep queue (the `author_chain` backlog during a backfill) from being re-sent forever;
   a lost message is still recovered at worst after 12 hours. The window resets on wake and reclaim.

## The author workflow

`books.author_enrichment` (definition version 1) wraps the existing services; no adapter enqueues
another step.

| Step | Queue | Waits on | Runs when |
|---|---|---|---|
| `wikidata` | `author_chain` | - | Always (`refresh` from options) |
| `viaf` | `author_chain` | `wikidata` (finish) | Wikidata was `unmatched`, or the run starts here (`start_at: "viaf"`) |
| `wikidata_via_viaf` | `author_chain` | `viaf` (finish) | VIAF returned a QID and the decision does not need review; forced refresh |
| `author_facts` | `author_chain` | `wikidata`, `viaf`, `wikidata_via_viaf` (all **release**) | Always, unless `skip_ai_if_ran` and the ledger shows the AI step ran |
| `author_facts_late` | `author_chain` | `wikidata_via_viaf`, `author_facts` (both finish) | The follow-up Wikidata run finished after `author_facts` **started** |

`author_facts` waits on releases so a VIAF step that waits far off (VIAF patience, 600 s) does not
hold the AI step. `author_facts_late` compares `author_facts.started_at`, not its finish: a
follow-up that lands while the AI step is still running missed it too.

`start` is `Workflows::Books::AuthorEnrichment.start(author, initiated_by:, options:, start_after:,
parent_run:, supersede:)`. Callers: the author importer's `Providers::Enrichment`, `Backfill`, and
`RejectExternalLink` (which supersedes any active run, inside its own transaction, with
`refresh: true`). The old `WikidataJob` and `ViafJob` are shims that plan a run for messages already
in Sidekiq.

`author_facts`' `on_terminal` calls `Books::Authors::EnrichJob.hand_off`, the **transitional
legacy hand-off** that queues `EnrichBookJob` for books whose latest ledger row is the
`deferred_to_authors` deferral. A later PR removes it: the book workflow now waits on the author
step directly, and nothing in the import path writes that deferral any more.

## The book workflow

`books.book_enrichment` (definition version 1) has two steps, each wrapping an existing service:

| Step | Queue | Waits on | Runs when |
|---|---|---|---|
| `book_facts` | `low` | the `author_facts` step of the runs of authors **linked to the book** that the import created (**release**) | Always |
| `amazon` | `serial` | - | The book has at least one `book_authors` row; otherwise it is skipped `no_authors` at plan time |

The waits cross runs, so they are passed at plan time rather than declared in the definition. The
Goodreads project will add its edges to this file. `start` is
`Workflows::Books::BookEnrichment.start(book, initiated_by:, new_author_ids:, author_names:, options:)`.
It starts an author run (or joins the active one) for each id in `new_author_ids`, whether or not the
book is linked to it, and makes `book_facts` wait on those linked to the book. If the book already has
an active run, that run is returned untouched and the event is logged. Dispatch happens after the
outermost commit; the plan rows are written in the caller's transaction.

Callers: `DataImporters::Books::Book::Providers::Enrichment` (importer with `enrich: true`, and the
list wizard's text rows) and `Services::Books::GoodreadsImports::PromoteRecords` (admin approval of a
Goodreads import). Member Goodreads imports run with `enrich: false` and plan nothing until approval.
The admin **Enrich With AI** button still queues `EnrichBookJob`, `books:enrich_missing` enqueues
`EnrichBookJob`, and `books:amazon_enrich*` queue or run `AmazonProductEnrichmentJob`; `books:enrich[id]`
runs `Services::Books::EnrichBook` inline. None of them creates a run. `books:enrich_missing` does
skip a book that has a running book run.

### Adopting deferred books

Before the book workflow, an import with new authors wrote a skipped `books.book_facts` ledger row
with reason `deferred_to_authors`, and the author chain's last step handed the book on. A book whose
latest row is still that deferral has no run, and nothing will release it if its author finished long
ago. `bin/rails books:workflows:adopt_deferred[limit]` (`Workflows::Books::AdoptDeferred`, a one-off
after PR 2 deploys) plans one for each: `initiated_by: "adopt_deferred"`, `only: [book_facts]` so
Amazon is `not_requested`, and `book_facts` waits on the `author_facts` step of every linked author
that has a **running** author run. It never starts an author run: a deferred book whose authors have
none gets a `book_facts` that is ready at once. A book that already has a running book run is counted
as `skipped_active` and left alone, so a second call plans nothing new; once a book's `book_facts` has
run, its newer ledger row takes it out of the deferred set. The limit caps the books planned, lowest
id first.

## Admin panel

The books admin **book** and **author** show pages have a full-width "Enrichment runs" card, a lazy
Turbo frame (`workflow_runs_list`) served by `Admin::Books::WorkflowRunsController#index`
(`/admin/books/:book_id/workflow_runs`, `/admin/authors/:author_id/workflow_runs`). It shows the
20 newest runs; per run the workflow, status, who started it and when; per step the key, state,
outcome, attempts, the wake time of a waiting step, the error, and for a `blocked` step its
unsatisfied prerequisites, linked to the other record's admin page (the book -> author wait).
Ledger rows (`Enrichment` rows with that `workflow_step_id`) are listed under their step. Access
follows the parent record's `show` policy, so a books-domain viewer can read it.

## `workflows:stuck`

```bash
bin/rails workflows:stuck        # grace period 6 hours
bin/rails "workflows:stuck[2]"   # 2 hours
```

Prints one line per step that needs a person. It lists **overdue** work, not old work: a backfill
plans tens of thousands of runs seconds apart and a VIAF step can wait weeks for its turn, so age
alone would list a healthy queue. Per state:

- `failed`: finished in the last 7 days, whatever its run's status (a book run can sit behind a failed
  author step);
- `waiting`: `run_after` passed more than the grace period ago, so the sweep did not wake it (a far-future
  `run_after` is not listed);
- `blocked`: every unsatisfied prerequisite is already released (release edge) or terminal (finish
  edge), so it should have advanced; a step behind a prerequisite that is legitimately still open is not
  listed;
- `ready`: not dispatched for longer than the longest redispatch window (12 hours) plus the grace period;
- `running`: past its lease (the sweep reclaims these within a minute, so one that stays here means the
  sweep is not running).

The same rows come from `Workflows::Stuck.call(older_than:)`. The recovery sweep handles the common
failures itself; a row here is an exhausted step or one even the sweep cannot move.

## Adding a step to a workflow

The shape the Goodreads work needs, and the one `Workflows::TestDefinition` keeps under test:
independent steps `a` and `b`, and `c` waiting for `a` to finish and `b` to release, reading `a`'s
result. For example, a `goodreads` step in the book workflow (the same applies to the author workflow):

1. Write an adapter under `app/lib/workflows/books/steps/`: a class with
   `call(step:, run:, target:)` that wraps an existing service and returns an `Outcome`. A rate
   limit returns `Outcome.wait(time)` (add `release: true` if dependents should not wait); a real
   failure raises. Put anything later steps need into `result` (jsonb, string keys).
2. Declare it in the definition with `add_step key: :goodreads, queue: :goodreads_fetch,
   lease: 5.minutes, adapter: Steps::Goodreads.new`. Add the queue to `config/sidekiq.yml` if it is
   new.
3. Make dependents wait: `waits_on: {goodreads: :finish}` (or `:release`). A dependent reads the
   prerequisite with `run.step(:goodreads).result`.
4. Use `skip_if: ->(run) { "reason" if ... }` for a step that should not run; it is evaluated at
   advance time, never by dispatch.
5. **Bump `version`** on the definition when the step set changes, so in-flight runs keep the shape
   they were planned with. A step key missing from the current definition is finished as
   `unknown_step`, never wedged.
6. Test with `Workflows::TestDefinitionHelpers` and `stub_workflow_dispatch` (Sidekiq runs inline in
   tests, so an unstubbed dispatch runs the whole workflow). The helper `workflow_run` is the
   memoized run; `plan_other_run` plants a second one for cross-run waits.

Rules to keep: an adapter never enqueues another step or job; side effects that must not block
dependents go in `on_terminal`; and a cross-run wait is expressed as an edge to the other run's
step, not a flag on a record.
