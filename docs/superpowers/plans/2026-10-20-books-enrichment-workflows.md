# Books Enrichment Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chained Sidekiq jobs behind book and author enrichment with Postgres-recorded workflow runs, so book AI enrichment waits for every new author and the order of steps lives in one Ruby definition per workflow.

**Architecture:** Three tables (`workflow_runs`, `workflow_steps`, `workflow_dependencies`) hold each run's plan and progress. `Workflows::Coordinator` claims, finishes and advances steps; one job class, `WorkflowStepJob`, runs any step on that step's own queue; `WorkflowRecoveryJob` (sidekiq-cron, every minute) redispatches lost or due work. Each step's work is a small adapter around an existing service.

**Tech Stack:** Rails 8, PostgreSQL, Sidekiq 8.1 (open source), sidekiq-cron 2.4, Minitest + fixtures + Mocha, ERB + DaisyUI 5 for the admin card, Playwright for E2E.

**Spec:** `docs/superpowers/specs/2026-10-20-books-enrichment-workflows-design.md`. Read it first; this plan argues from it and does not repeat its reasoning.

## Where this plan refines the spec

- **Plan rows are written in the caller's transaction, not after commit** (spec §7.1 says after commit). Only dispatch waits for the commit. A rollback still plans nothing, and a crash between commit and plan can no longer lose a book's enrichment.
- **Attempts count failures and expired leases, not claims** (spec §7.3 says the claim counts). A rate-limit wait or a deploy push-back then never uses up an attempt, which is what the spec asks for elsewhere.
- **Step conditions are evaluated by the coordinator at advance time, never by dispatching the step.** Dispatching a step only to skip it would put it at the back of the `author_chain` backlog several times per author.
- **`Books::Authors::EnrichJob` stays unchanged during the transition** (spec §11 maps it to an `only: [author_facts]` run). It chains nothing but the legacy hand-off, so leaving it is equivalent and simpler. Task 14 removes it.

## Global Constraints

- All Rails commands run from `web-app/`. Lint is `bundle exec standardrb` (not rubocop). Do not run brakeman.
- Use generators: `bin/rails generate model ...`, `bin/rails generate sidekiq:job ...` (never `generate job`), `bin/rails generate controller ...`. Delete generated noise you do not use.
- Tables `workflow_runs`, `workflow_steps`, `workflow_dependencies`; models `WorkflowRun`, `WorkflowStep`, `WorkflowDependency` in the global namespace. Engine code in `app/lib/workflows/` (`Workflows::`), books definitions and adapters in `app/lib/workflows/books/` (`Workflows::Books::`).
- Polymorphic target is `enrichable` (`enrichable_type` stores the base class name: `"Books::Book"`, `"Books::Author"`).
- Workflow names: `books.author_enrichment`, `books.book_enrichment`. Both start at `definition_version` 1.
- One active run per (`workflow`, `enrichable`): partial unique index `WHERE status = 0` (`running`).
- Step queues: author steps `author_chain`; `book_facts` `low`; `amazon` `serial`. `WorkflowRecoveryJob` runs on `default`, cron `"0 * * * * *"` (every minute).
- `WorkflowStepJob` has `retry: 0`. The workflow owns retries. `Sidekiq::Shutdown` is re-raised.
- Redispatch window for a still-`ready` step: `min(10.minutes * 2**(dispatch_count - 1), 12.hours)`.
- Default `max_attempts` 3 for every step (today's `retry: 3`; Amazon's implicit 25 becomes 3). Failure backoff `30.seconds * 4**(attempts - 1)` (30 s, 2 min, 8 min).
- `CHAIN_PATIENCE = 600` seconds and `RESCHEDULE_JITTER = 0..30` carry over unchanged from `ViafJob`. `RejectExternalLink::RERUN_DELAY` (10 s) and `Backfill::SPACING` (6 s) carry over.
- A step adapter never enqueues another step or job. Coordination belongs to the coordinator. (The one transitional exception is Task 7's legacy hand-off hook, removed in Task 14.)
- **Never dispatch a `waiting` step from a finish.** Only the recovery sweep moves `waiting` → `ready`. `Sidekiq.testing!(:inline)` runs `perform_in`/`perform_at` immediately, so a finish-time scheduled dispatch would loop in tests.
- No `has_many :workflow_runs` on `Books::Book` or `Books::Author`: every new book association must be handled by the book merger (memory). Query `WorkflowRun.where(enrichable: record)` instead.
- Music and games code is not touched. Movies is out of scope.
- `assert_equal nil, x` is a hard failure in Minitest 6; use `assert_nil`. Check fixture names in the YAML (`books_authors(:tolstoy)`, `books_authors(:king)`, `books_books(:war_and_peace)`, …) before using them.
- After creating `app/lib/workflows/`, run `CI=1 bin/rails zeitwerk:check` (eager loading is off in test).
- Each PR must end with a clean `bin/rails test` (no new warning lines) and a clean `bundle exec standardrb`.

## Review Focus

1. **A rolled-back import must leave no run and dispatch nothing.** The list wizard and Goodreads `CreateBook` import inside `transaction(requires_new: true)` and roll back on `CreateFailed`. Plan rows are written in the caller's transaction; dispatch is after commit. Test in Task 11.
2. **A merged-away or deleted author whose run never got to execute must not hold its book forever.** Its blocked steps never run, so nothing notices at execution time. The recovery sweep cancels runs whose target is gone, which releases the book. Test in Task 6.
3. **A deploy must not burn attempts.** Sidekiq pushes a running job back with the same `jid`; the re-run must claim the step (token = jid) without counting an attempt. Test in Task 4.
4. **Two prerequisites finishing at the same moment must make the waiting step `ready` exactly once.** The dependent's row is locked and its transition is conditional. Test in Task 4 (sequential double-advance, asserting one dispatch).
5. **A long VIAF wait must not hold the author AI step, and a late QID must still be used.** Release passes through the blocked `wikidata_via_viaf`. Test in Task 7.

---

## PR 1: engine and author workflow

### Task 1: Tables, models, ledger link

**Files:**
- Create (generator): `db/migrate/*_create_workflow_runs.rb`, `*_create_workflow_steps.rb`, `*_create_workflow_dependencies.rb`, `*_add_workflow_step_to_enrichments.rb`
- Create (generator): `app/models/workflow_run.rb`, `app/models/workflow_step.rb`, `app/models/workflow_dependency.rb`
- Modify: `app/models/enrichment.rb`, `app/models/current.rb`
- Test: `test/models/workflow_run_test.rb`, `test/models/workflow_step_test.rb`, `test/models/workflow_dependency_test.rb`, `test/models/enrichment_test.rb`
- Fixtures: `test/fixtures/workflow_runs.yml`, `workflow_steps.yml`, `workflow_dependencies.yml` (generated; keep them minimal: one running author run on `tolstoy` with a `wikidata` step, used by later tests)

**Interfaces:**
- Produces:
  - `WorkflowRun`: columns per spec §5 (`workflow` string not null, `definition_version` int not null, `enrichable_type`/`enrichable_id` not null, `status` int default 0, `options` jsonb default `{}`, `initiated_by` string not null, `parent_run_id` bigint FK to `workflow_runs` nullable, `started_at`, `finished_at`, `error_summary` text). `belongs_to :enrichable, polymorphic: true, optional: true` (the target may be deleted later; validate `enrichable_type`/`enrichable_id` presence instead). `enum :status, {running: 0, completed: 1, completed_with_failures: 2, cancelled: 3}`. `has_many :steps, class_name: "WorkflowStep", dependent: :destroy`. `#step(key) -> WorkflowStep` (by string or symbol key, raises if absent).
  - `WorkflowStep`: columns per spec §5 plus `dispatch_count` int default 0, `lease_seconds` int not null, `max_attempts` int not null default 3, `result` jsonb default `{}`. `enum :state, {blocked: 0, ready: 1, running: 2, waiting: 3, succeeded: 4, skipped: 5, failed: 6}`. `TERMINAL_STATES = %w[succeeded skipped failed]`. `#terminal?`, `#released?` (`released_at.present?`). `belongs_to :run, class_name: "WorkflowRun", foreign_key: :workflow_run_id`. `has_many :dependencies, class_name: "WorkflowDependency", foreign_key: :step_id`, `has_many :dependent_edges, class_name: "WorkflowDependency", foreign_key: :prerequisite_step_id`. Unique index (`workflow_run_id`, `key`); index (`state`, `run_after`); index (`state`, `dispatched_at`); index (`state`, `lease_expires_at`).
  - `WorkflowDependency`: `step_id`, `prerequisite_step_id` (both FK to `workflow_steps`, `on_delete: :cascade`), `kind` int, `satisfied_at`. `enum :kind, {release: 0, finish: 1}`. Unique (`step_id`, `prerequisite_step_id`); index on `prerequisite_step_id`.
  - Partial unique index on `workflow_runs (workflow, enrichable_type, enrichable_id) WHERE status = 0`, named `index_workflow_runs_one_active`.
  - `enrichments.workflow_step_id` bigint, FK `on_delete: :nullify`, indexed. `Enrichment belongs_to :workflow_step, optional: true`; `before_create { self.workflow_step_id ||= Current.workflow_step_id }`.
  - `Current.workflow_step_id` (new attribute on the existing `Current`).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/workflow_run_test.rb
test "allows only one running run per workflow and target" do
  WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test")
  assert_raises(ActiveRecord::RecordNotUnique) do
    WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test")
  end
end

test "allows a new run once the earlier one is finished" do
  WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test", status: :completed)
  assert WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: books_authors(:king), initiated_by: "test").persisted?
end

test "can still be updated after its target is deleted" do
  run = workflow_runs(:tolstoy_author_run)
  run.update_columns(enrichable_id: 0)
  assert run.reload.update(status: :cancelled)
end

# test/models/workflow_step_test.rb
test "terminal? is true for succeeded, skipped and failed only" do
  step = workflow_steps(:tolstoy_wikidata)
  assert_equal [false, false, false, false, true, true, true],
    WorkflowStep.states.keys.map { |state| step.tap { it.state = state }.terminal? }
end

# test/models/enrichment_test.rb
test "stamps the current workflow step on create" do
  step = workflow_steps(:tolstoy_wikidata)
  row = Current.set(workflow_step_id: step.id) do
    books_authors(:tolstoy).enrichments.create!(kind: "books.author_facts", outcome: :skipped, reason: "test")
  end
  assert_equal step.id, row.workflow_step_id
end
```

- [ ] **Step 2: Run them, verify they fail**

Run: `bin/rails test test/models/workflow_run_test.rb test/models/workflow_step_test.rb test/models/enrichment_test.rb`
Expected: FAIL (`uninitialized constant WorkflowRun`, missing fixtures).

- [ ] **Step 3: Generate the models and migrations, add the columns, indexes, enums and associations listed above**

Run `bin/rails db:migrate` (development) and `bin/rails db:test:prepare`. The annotaterb hook runs on migrate; if the legacy DB is absent set `ANNOTATERB_SKIP_ON_DB_TASKS=1`.

- [ ] **Step 4: Run the tests, verify they pass**

Run: same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/ app/models/workflow_*.rb app/models/enrichment.rb app/models/current.rb test/models/ test/fixtures/workflow_*.yml
git commit -m "Workflow runs, steps and dependencies tables; ledger rows link to their step"
```

### Task 2: Definitions, steps and outcomes

**Files:**
- Create: `app/lib/workflows/step.rb`, `app/lib/workflows/outcome.rb`, `app/lib/workflows/definition.rb`, `app/lib/workflows/registry.rb`
- Create (test support): `test/support/workflows/test_definition.rb` (required from `test/test_helper.rb`)
- Test: `test/lib/workflows/outcome_test.rb`, `test/lib/workflows/registry_test.rb`

**Interfaces:**
- Produces:
  - `Workflows::Step = Data.define(:key, :queue, :waits_on, :max_attempts, :lease, :adapter, :skip_if, :on_terminal)`. `key` Symbol; `queue` Symbol; `waits_on` Hash `{step_key => :release | :finish}`; `lease` ActiveSupport::Duration; `adapter` an object responding to `call(step:, run:, target:) -> Workflows::Outcome`; `skip_if` optional callable `(run) -> String | nil` (a skip outcome, or nil to run); `on_terminal` optional callable `(step, target)`. Provide `Workflows::Step.build(key:, queue:, adapter:, waits_on: {}, max_attempts: 3, lease: 10.minutes, skip_if: nil, on_terminal: nil)`.
  - `Workflows::Outcome = Data.define(:kind, :outcome, :result, :run_after, :release)` with constructors `Outcome.succeeded(outcome, result = {})`, `Outcome.skipped(outcome)`, `Outcome.wait(until_time, release: false, result: {})`. `kind` is `:succeeded | :skipped | :wait`. An adapter signals failure by raising.
  - `Workflows::Definition` (base class, class-level API): `.workflow -> String`, `.version -> Integer`, `.target_class -> Class`, `.steps -> Array<Workflows::Step>`, `.step(key) -> Workflows::Step` (nil if absent).
  - `Workflows::Registry.fetch(workflow_name) -> Class` (raises `KeyError`); `Registry::DEFINITIONS` maps the two books workflow names to their classes (filled in Tasks 7 and 10). Tests register `Workflows::TestDefinition` with `Registry.register(name, klass)`, removed in teardown with `Registry.unregister(name)`.
  - `Workflows::TestDefinition` (test support only): workflow `"test.diamond"`, target `Books::Author`, all steps on queue `:author_chain`, steps `a` (no waits), `b` (no waits), `c` (waits `a: :finish, b: :release`, reads `a`'s `result`). Each adapter is a configurable stub: `TestDefinition.outcomes[key] = ->(step:, run:, target:) { ... }`, reset in teardown. This is the Goodreads-shaped definition spec §9 asks for.
  - Test helpers in the same support file: `plan(**planner_args)` plans a TestDefinition run on `books_authors(:king)`; `plan_other_run(**planner_args)` plans one on `books_authors(:tolstoy)` (cancelling the fixture run first); `run` memoizes `plan.data[:run]`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "wait carries its time, release flag and result" do
  outcome = Workflows::Outcome.wait(Time.zone.parse("2026-10-20 12:00"), release: true, result: {"in_line" => true})
  assert_equal [:wait, true, {"in_line" => true}], [outcome.kind, outcome.release, outcome.result]
end

test "registry resolves the test definition and refuses unknown names" do
  Workflows::Registry.register("test.diamond", Workflows::TestDefinition)
  assert_equal Workflows::TestDefinition, Workflows::Registry.fetch("test.diamond")
  assert_raises(KeyError) { Workflows::Registry.fetch("nope") }
ensure
  Workflows::Registry.unregister("test.diamond")
end
```

- [ ] **Step 2: Run, verify failure.** `bin/rails test test/lib/workflows/` → FAIL (uninitialized constant).
- [ ] **Step 3: Implement the four files and the test support definition.**
- [ ] **Step 4: Run, verify pass; then `CI=1 bin/rails zeitwerk:check`.** Expected: PASS and "All is good!".
- [ ] **Step 5: Commit.** `git commit -m "Workflow definitions, steps and outcomes"`

### Task 3: Planner

**Files:**
- Create: `app/lib/workflows/planner.rb`
- Test: `test/lib/workflows/planner_test.rb`

**Interfaces:**
- Consumes: Task 1 models, Task 2 `Definition`/`Step`/`Registry`.
- Produces: `Workflows::Planner.call(definition:, enrichable:, initiated_by:, options: {}, waits: {}, skips: {}, start_after: nil, parent_run: nil, supersede: false) -> Result` where `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` and `data` is `{run: WorkflowRun, reused: Boolean, ready_steps: Array<WorkflowStep>}`.
  - `options` (string keys after `deep_stringify_keys`) recognised by the engine: `"only"` (Array of step keys; every other step is planned `skipped` with outcome `not_requested`) and `"start_at"` (a step key; every step before it in definition order is planned `skipped` `not_requested`). Everything else is passed through for adapters.
  - `waits`: `{step_key => Array<WorkflowStep>}`, extra **cross-run** prerequisites, always `release` edges.
  - `skips`: `{step_key => outcome_string}`, steps planned `skipped` with that outcome (e.g. `amazon: "no_authors"`).
  - `start_after`: Time; steps with no unsatisfied prerequisites get `run_after = start_after` and state `waiting` instead of `ready`.
  - Behaviour: inside `ActiveRecord::Base.transaction(requires_new: true)`. If an active run exists for (workflow, enrichable): with `supersede: false` return it with `reused: true` and plan nothing; with `supersede: true` call `Coordinator.cancel(run, outcome: "superseded")` first. Creates the run (`definition_version` from the definition, `started_at` now), one step per definition step (copying `queue`, `max_attempts`, `lease_seconds`), and one dependency per `waits_on` entry and per `waits` entry. An edge whose prerequisite is already released is created with `satisfied_at` set. Planned-skipped steps are terminal and released at once, which satisfies edges on them. Then evaluates every non-terminal step: all edges satisfied → apply `skip_if` (skip) or move to `ready` (or `waiting` if `start_after`); not all satisfied but every prerequisite released → set `released_at` (pass-through). Returns the `ready` steps; **it does not dispatch** (the caller dispatches after commit, Task 5).

- [ ] **Step 1: Write the failing tests** (use `Workflows::TestDefinition`, target `books_authors(:king)`)

```ruby
test "plans every step, with a and b ready and c blocked on both" do
  run = plan.data[:run]
  assert_equal({"a" => "ready", "b" => "ready", "c" => "blocked"}, run.steps.pluck(:key, :state).to_h)
  assert_equal [["a", "finish"], ["b", "release"]], run.step(:c).dependencies.map { [it.prerequisite_step.key, it.kind] }.sort
end

test "returns the active run instead of planning a second one" do
  first = plan.data[:run]
  second = plan
  assert_equal [first.id, true], [second.data[:run].id, second.data[:reused]]
end

test "supersede cancels the active run and plans a new one" do
  first = plan.data[:run]
  second = plan(supersede: true).data[:run]
  assert_equal ["cancelled", "superseded"], [first.reload.status, first.step(:a).outcome]
  refute_equal first.id, second.id
end

test "only: skips the unrequested steps as not_requested, releasing them" do
  run = plan(options: {only: ["a"]}).data[:run]
  assert_equal ["skipped", "not_requested", true], [run.step(:b).state, run.step(:b).outcome, run.step(:b).released?]
end

test "start_at: skips the steps before it" do
  run = plan(options: {start_at: "b"}).data[:run]
  assert_equal %w[skipped ready], [run.step(:a).state, run.step(:b).state]
end

test "a cross-run wait on an already released step is satisfied at plan time" do
  other = workflow_steps(:tolstoy_wikidata).tap { it.update!(state: :succeeded, released_at: Time.current) }
  run = plan(waits: {a: [other]}).data[:run]
  assert_equal "ready", run.step(:a).state
end

test "start_after leaves the first steps waiting until then" do
  run = plan(start_after: 10.seconds.from_now).data[:run]
  assert_equal ["waiting", 10.seconds.from_now.to_i], [run.step(:a).state, run.step(:a).run_after.to_i]
end

test "a rolled-back caller transaction leaves no run" do
  ActiveRecord::Base.transaction do
    plan
    raise ActiveRecord::Rollback
  end
  assert_equal 0, WorkflowRun.where(workflow: "test.diamond").count
end
```

- [ ] **Step 2: Run, verify failure.** `bin/rails test test/lib/workflows/planner_test.rb`
- [ ] **Step 3: Implement `Workflows::Planner`.** The "evaluate a non-terminal step" logic is shared with Task 4; put it in `Workflows::Coordinator.evaluate(step) -> :ready | :waiting | :skipped | :released | :blocked` and have the planner call it (so write the minimal version of that method here, in `app/lib/workflows/coordinator.rb`, and Task 4 extends the file).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "Workflow planner"`

### Task 4: Coordinator: claim, finish, fail, advance, cancel

**Files:**
- Modify/Create: `app/lib/workflows/coordinator.rb`
- Test: `test/lib/workflows/coordinator_test.rb`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces (all class methods on `Workflows::Coordinator`; each returns the steps that became `ready`, for the caller to dispatch after commit, unless noted):
  - `claim(step_id, token:) -> WorkflowStep | nil`. One conditional `UPDATE … RETURNING`: allowed when `state = ready`, or `state = running AND lease_token = token` (a pushed-back job resuming). Sets `state = running`, `lease_token = token`, `lease_expires_at = now + lease_seconds`, `started_at = COALESCE(started_at, now)`. **Does not touch `attempts`.** Returns nil when the update matched no row.
  - `finish(step, token:, outcome:) -> Array<WorkflowStep>`. Applies only if `lease_token = token` still (conditional update; returns `[]` otherwise). `:succeeded`/`:skipped` → that state, `outcome`, `result` merged, `finished_at`, `released_at ||= now`, lease cleared; then `step.definition_step.on_terminal&.call(step, target)`; then `advance(step)`. `:wait` → `state = waiting`, `run_after`, `result` merged, lease cleared, and if `outcome.release` and not yet released, `released_at = now` and `advance(step)`.
  - `fail(step, token:, error:) -> Array<WorkflowStep>`. Token-guarded. `attempts += 1`, `error = "#{error.class}: #{error.message}"` (truncated to 1,000 chars). Below `max_attempts` → `waiting`, `run_after = now + 30.seconds * 4**(attempts - 1)`. At `max_attempts` → `failed`, `finished_at`, `released_at ||= now`, `on_terminal`, `advance`.
  - `advance(step) -> Array<WorkflowStep>`. In one transaction: for each edge where `prerequisite_step = step` (dependents locked `FOR UPDATE` in id order), set `satisfied_at` when satisfied (`release` edge: prerequisite released; `finish` edge: prerequisite terminal), then `evaluate(dependent)`. A dependent that becomes skipped or pass-through released is advanced in turn (iterate with a work list, not recursion). Then, for every run touched, if all its steps are terminal, set `status` (`completed_with_failures` when any step `failed`, else `completed`) and `finished_at`.
  - `evaluate(step)` (from Task 3) — only acts on `blocked` steps, with conditional updates (`WHERE state = 'blocked'`) so a second concurrent advance is a no-op.
  - `cancel(run, outcome:) -> Array<WorkflowStep>`. Every non-terminal step of the run → `skipped` with that outcome, released, lease cleared; advance each (dependents in **other** runs); run → `cancelled`, `finished_at`.
  - `WorkflowStep#definition_step -> Workflows::Step | nil` (looks the key up in `Registry.fetch(run.workflow)`); a key the current definition no longer has is finished `skipped` `unknown_step` by the job (Task 5).

- [ ] **Step 1: Write the failing tests** (TestDefinition)

```ruby
test "claim refuses a step another worker holds, and allows the same jid to resume" do
  step = run.step(:a)
  assert Workflows::Coordinator.claim(step.id, token: "jid-1")
  assert_nil Workflows::Coordinator.claim(step.id, token: "jid-2")
  assert Workflows::Coordinator.claim(step.id, token: "jid-1")
  assert_equal 0, step.reload.attempts
end

test "a stale worker cannot overwrite a newer attempt" do
  step = run.step(:a)
  Workflows::Coordinator.claim(step.id, token: "old")
  step.update_columns(state: WorkflowStep.states[:ready])          # lease reclaimed by recovery
  Workflows::Coordinator.claim(step.id, token: "new")
  assert_equal [], Workflows::Coordinator.finish(step, token: "old", outcome: Workflows::Outcome.succeeded("x"))
  assert_equal "running", step.reload.state
end

test "c becomes ready only when a has finished and b is released" do
  finish(:a, Workflows::Outcome.succeeded("matched", {"qid" => "Q1"}))
  assert_equal "blocked", run.step(:c).reload.state
  ready = finish(:b, Workflows::Outcome.succeeded("done"))
  assert_equal [run.step(:c).id], ready.map(&:id)
end

test "advancing twice makes c ready once" do
  finish(:a, Workflows::Outcome.succeeded("x"))
  finish(:b, Workflows::Outcome.succeeded("y"))
  assert_equal [], Workflows::Coordinator.advance(run.step(:b))
end

test "a release on wait frees release-edge dependents but not finish-edge ones" do
  finish(:a, Workflows::Outcome.succeeded("x"))
  finish(:b, Workflows::Outcome.wait(1.hour.from_now, release: true))
  assert_equal ["waiting", "ready"], [run.step(:b).reload.state, run.step(:c).reload.state]
end

test "release passes through a blocked finish-edge dependent" do
  finish(:b, Workflows::Outcome.succeeded("y"))
  finish(:a, Workflows::Outcome.wait(1.hour.from_now, release: true))
  assert_equal ["blocked", true], [run.step(:c).reload.state, run.step(:c).released?]
end

test "fail retries with backoff, then fails, releases and closes the run with failures" do
  step = run.step(:a)
  3.times do
    step.update_columns(state: WorkflowStep.states[:ready])
    Workflows::Coordinator.claim(step.id, token: "t")
    Workflows::Coordinator.fail(step.reload, token: "t", error: RuntimeError.new("boom"))
  end
  assert_equal ["failed", 3, true], [step.reload.state, step.attempts, step.released?]
end

test "a wait does not dispatch anything" do
  ready = finish(:a, Workflows::Outcome.wait(1.minute.from_now))
  assert_equal [], ready
end

test "cancel skips the rest with the outcome and releases dependents in other runs" do
  other = plan_other_run(waits: {a: [run.step(:c)]})
  ready = Workflows::Coordinator.cancel(run, outcome: "target_gone")
  assert_equal ["cancelled", "target_gone"], [run.reload.status, run.step(:c).outcome]
  assert_includes ready.map(&:id), other.step(:a).id
end
```

(`finish(key, outcome)` is a test helper that claims the step with a fixed token and calls `Coordinator.finish`.)

- [ ] **Step 2: Run, verify failure.** `bin/rails test test/lib/workflows/coordinator_test.rb`
- [ ] **Step 3: Implement the methods above.**
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "Workflow coordinator: claim, finish, fail, advance, cancel"`

### Task 5: Dispatcher and step job

**Files:**
- Create: `app/lib/workflows/dispatcher.rb`
- Create (generator `bin/rails generate sidekiq:job workflow_step`): `app/sidekiq/workflow_step_job.rb`, `test/sidekiq/workflow_step_job_test.rb`
- Create: `test/support/workflows/dispatch_helper.rb` (required from `test_helper.rb`)
- Test: `test/lib/workflows/dispatcher_test.rb`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `Workflows::Dispatcher.dispatch(steps)`: for each `ready` step, `WorkflowStepJob.set(queue: step.queue).perform_async(step.id)` then `update_columns(dispatched_at: now, dispatch_count: dispatch_count + 1)`. **The one seam tests stub.**
  - `Workflows::Dispatcher.after_commit(steps)`: `ActiveRecord.after_all_transactions_commit { dispatch(steps) }`. Every caller of Planner/Coordinator uses this.
  - `WorkflowStepJob#perform(step_id)`: `sidekiq_options queue: :default, retry: 0`. Claims with `token: jid`; returns if nil. Loads the target with `run.enrichable_type.constantize.find_by(id: run.enrichable_id)`; nil → `Coordinator.cancel(run, outcome: "target_gone")` and dispatch. No definition step for the key → finish `skipped` `unknown_step`. Otherwise `Current.set(workflow_step_id: step.id) { adapter.call(step:, run:, target:) }` **outside any transaction**, then `Coordinator.finish` and dispatch the returned steps. Rescues `Sidekiq::Shutdown` → re-raise. Rescues `StandardError` → `Coordinator.fail` and dispatch.
  - Test helper `stub_workflow_dispatch` → `Workflows::Dispatcher.stubs(:dispatch)` and returns the mocha expectation, for tests that should plan without running.

- [ ] **Step 1: Write the failing tests** (TestDefinition, with `Sidekiq::Testing.fake!` blocks where a single transition is observed)

```ruby
test "dispatch enqueues on the step's own queue and counts the dispatch" do
  Sidekiq::Testing.fake! do
    Workflows::Dispatcher.dispatch([run.step(:a)])
    assert_equal ["author_chain", 1], [WorkflowStepJob.jobs.last["queue"], run.step(:a).reload.dispatch_count]
  end
end

test "runs the adapter with Current.workflow_step_id set, finishes, and dispatches c" do
  Workflows::TestDefinition.outcomes[:a] = ->(step:, run:, target:) { Workflows::Outcome.succeeded("x", {"seen" => Current.workflow_step_id}) }
  ...
  assert_equal run.step(:a).id, run.step(:a).reload.result["seen"]
end

test "an adapter error is recorded as an attempt and the step waits" do
  Workflows::TestDefinition.outcomes[:a] = ->(**) { raise "boom" }
  WorkflowStepJob.new.tap { it.jid = "j" }.perform(run.step(:a).id)
  assert_equal ["waiting", 1, "RuntimeError: boom"], run.step(:a).reload.values_at(:state, :attempts, :error)
end

test "a missing target cancels the run as target_gone" do
  run.update_columns(enrichable_id: 0)
  WorkflowStepJob.new.tap { it.jid = "j" }.perform(run.step(:a).id)
  assert_equal "cancelled", run.reload.status
end

test "Sidekiq::Shutdown propagates and leaves the step claimable by the same jid" do
  Workflows::TestDefinition.outcomes[:a] = ->(**) { raise Sidekiq::Shutdown }
  job = WorkflowStepJob.new.tap { it.jid = "j" }
  assert_raises(Sidekiq::Shutdown) { job.perform(run.step(:a).id) }
  assert Workflows::Coordinator.claim(run.step(:a).id, token: "j")
end

test "a second message for a claimed step does nothing" do
  Workflows::Coordinator.claim(run.step(:a).id, token: "other")
  Workflows::TestDefinition.outcomes[:a] = ->(**) { flunk "ran twice" }
  WorkflowStepJob.new.tap { it.jid = "j" }.perform(run.step(:a).id)
end

test "the test definition's c reads a's result (Goodreads shape)" do
  Workflows::TestDefinition.outcomes[:c] = ->(step:, run:, target:) { Workflows::Outcome.succeeded(run.step(:a).result.fetch("qid")) }
  # run a (result qid Q1) and b inline, then c
  assert_equal "Q1", run.step(:c).reload.outcome
end
```

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement dispatcher, job and helper.**
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "Workflow dispatcher and step job"`

### Task 6: Recovery sweep

**Files:**
- Create: `app/lib/workflows/recovery.rb`
- Create (generator `bin/rails generate sidekiq:job workflow_recovery`): `app/sidekiq/workflow_recovery_job.rb`, `test/sidekiq/workflow_recovery_job_test.rb`
- Modify: `config/schedule.yml`
- Test: `test/lib/workflows/recovery_test.rb`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `Workflows::Recovery.call(now: Time.current, batch: 1_000) -> Hash` of counts `{redispatched:, woken:, reclaimed:, cancelled:, readvanced:}`. Passes, in this order, each limited to `batch` rows:
  1. **Cancel orphans:** running runs whose target row is gone (per `enrichable_type`, `LEFT JOIN` the target table) → `Coordinator.cancel(run, outcome: "target_gone")`.
  2. **Reclaim expired leases:** `running` steps with `lease_expires_at < now` → `attempts += 1`; at `max_attempts` → `failed` + advance, else `ready`.
  3. **Wake waiting steps:** `waiting` with `run_after <= now` → `ready` (conditional update).
  4. **Re-advance:** dependency edges with `satisfied_at IS NULL` whose prerequisite is released → `Coordinator.advance(prerequisite)`.
  5. **Redispatch:** `ready` steps with `dispatched_at IS NULL` or `dispatched_at < now - window(dispatch_count)` (Global Constraints) → `Dispatcher.dispatch`.
- `WorkflowRecoveryJob#perform`: `sidekiq_options queue: :default, retry: 0`; calls `Workflows::Recovery.call` and logs the counts when any is non-zero.
- `config/schedule.yml` entry `workflow_recovery`: class `WorkflowRecoveryJob`, cron `"0 * * * * *"`, description "Redispatch lost or due workflow steps".

- [ ] **Step 1: Write the failing tests**

```ruby
test "redispatches a ready step whose window lapsed, doubling the window each time" do
  step = run.step(:a).tap { it.update_columns(dispatched_at: 11.minutes.ago, dispatch_count: 1) }
  dispatch = stub_workflow_dispatch.with { |steps| steps.map(&:id) == [step.id] }
  Workflows::Recovery.call
  step.update_columns(dispatched_at: 11.minutes.ago, dispatch_count: 2)    # window now 20 min
  stub_workflow_dispatch.never
  Workflows::Recovery.call
end

test "wakes a waiting step whose time has come" do
  step = run.step(:a).tap { it.update_columns(state: WorkflowStep.states[:waiting], run_after: 1.second.ago) }
  stub_workflow_dispatch
  Workflows::Recovery.call
  assert_equal "ready", step.reload.state
end

test "reclaims an expired lease and counts the attempt" do
  step = run.step(:a).tap { it.update_columns(state: WorkflowStep.states[:running], lease_expires_at: 1.second.ago, lease_token: "dead") }
  stub_workflow_dispatch
  Workflows::Recovery.call
  assert_equal ["ready", 1], [step.reload.state, step.attempts]
end

test "cancels the run of a deleted author and releases the book step waiting on it" do
  book_run = plan_other_run(waits: {a: [run.step(:c)]})
  run.update_columns(enrichable_id: 0)
  stub_workflow_dispatch
  Workflows::Recovery.call
  assert_equal ["cancelled", "ready"], [run.reload.status, book_run.step(:a).reload.state]
end

test "re-advances an edge left unsatisfied by an interrupted advance" do
  run.step(:a).update_columns(state: WorkflowStep.states[:succeeded], released_at: Time.current)
  run.step(:b).update_columns(state: WorkflowStep.states[:succeeded], released_at: Time.current)
  stub_workflow_dispatch
  Workflows::Recovery.call
  assert_equal "ready", run.step(:c).reload.state
end

test "the cron schedule runs recovery every minute" do
  assert_equal "0 * * * * *", YAML.load_file(Rails.root.join("config/schedule.yml")).dig("workflow_recovery", "cron")
end
```

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "Workflow recovery sweep, every minute"`

### Task 7: Author enrichment workflow

**Files:**
- Create: `app/lib/workflows/books/author_enrichment.rb` (definition + `.start`)
- Create: `app/lib/workflows/books/steps/wikidata.rb`, `viaf.rb`, `author_facts.rb`
- Modify: `app/lib/workflows/registry.rb` (register `books.author_enrichment`)
- Modify: `app/lib/services/books/authors/ledger_run.rb` (add `LedgerRun.ai_step_ran_ids(ids) -> Set<Integer>`, moved from `Backfill#ai_step_ran`; Backfill calls it)
- Test: `test/lib/workflows/books/author_enrichment_test.rb`, `test/lib/workflows/books/steps/wikidata_test.rb`, `viaf_test.rb`, `author_facts_test.rb`, `test/lib/services/books/authors/ledger_run_test.rb`

**Interfaces:**
- Consumes: Tasks 1–6; `Services::Books::Authors::EnrichFromWikidata.call(author:, refresh:)` (data `{outcome: :matched|:unmatched|:skipped|:failed, …}`, raises `Wikimedia::Exceptions::RateLimited`), `EnrichFromViaf.call(author:, refresh:)` (data `{outcome:, wikidata_qid:, decision:}`, raises `Viaf::Exceptions::RateLimited` / `Paused`), `EnrichAuthor.call(author:, allow_research:)` (Result `success?`), `Viaf::Schedule`, `Books::Authors::EnrichJob.hand_off(author_id)`.
- Produces:
  - `Workflows::Books::AuthorEnrichment` (`< Workflows::Definition`), workflow `books.author_enrichment`, version 1, target `::Books::Author`. Steps, in order (spec §6.1 table):
    - `wikidata`: adapter `Steps::Wikidata.new(refresh_from: :options)`, lease 5 min.
    - `viaf`: waits `wikidata: :finish`; `skip_if` → `"not_needed"` unless `wikidata.outcome == "unmatched"` or `wikidata.outcome == "not_requested"` (the `start_at: "viaf"` case); adapter `Steps::Viaf`, lease 5 min.
    - `wikidata_via_viaf`: waits `viaf: :finish`; `skip_if` → `"not_needed"` unless `viaf.succeeded?` and `viaf.result["wikidata_qid"].present?` and not `viaf.result["needs_review"]`; adapter `Steps::Wikidata.new(refresh: true)`, lease 5 min.
    - `author_facts`: waits `wikidata: :release, viaf: :release, wikidata_via_viaf: :release`; `skip_if` → `"already_ran"` when `options["skip_ai_if_ran"]` and `LedgerRun.ai_step_ran_ids([id]).any?`; adapter `Steps::AuthorFacts`, lease 15 min; `on_terminal: ->(step, author) { ::Books::Authors::EnrichJob.hand_off(author.id) }` (transitional legacy hand-off; removed in Task 14).
    - `author_facts_late`: waits `wikidata_via_viaf: :finish, author_facts: :finish`; `skip_if` → `"not_needed"` unless `wikidata_via_viaf.succeeded?` and `author_facts.released_at < wikidata_via_viaf.finished_at`; adapter `Steps::AuthorFacts`, lease 15 min.
  - `Workflows::Books::AuthorEnrichment.start(author, initiated_by:, options: {}, start_after: nil, parent_run: nil, supersede: false) -> WorkflowRun`. Calls `Planner` and `Dispatcher.after_commit(result.data[:ready_steps])`. Engine options used by adapters: `"refresh"` (default false), `"allow_research"` (default true), `"skip_ai_if_ran"` (default false), plus `"start_at"`.
  - `Steps::Wikidata#call`: `EnrichFromWikidata.call(author:, refresh:)` → `Outcome.succeeded(data[:outcome].to_s)` (a `:failed` service outcome is a business outcome, not an exception, so the chain continues as today). Rescue `Wikimedia::Exceptions::RateLimited` → `Outcome.wait(now + retry_after.to_i + rand(RESCHEDULE_JITTER))`.
  - `Steps::Viaf#call`: moves `ViafJob`'s line logic here unchanged (`answerable_from_store?`, `take_turn`, `CHAIN_PATIENCE`, `RESCHEDULE_JITTER`). `in_line` lives in `step.result["in_line"]`.
    - Not in line, someone waiting (`schedule.horizon`), not answerable from store → `take_turn(not_before: 0)`.
    - Otherwise run `EnrichFromViaf`; → `Outcome.succeeded(outcome.to_s, {"wikidata_qid" => qid, "needs_review" => decision&.needs_review || false, "in_line" => in_line})`.
    - `RateLimited` in line and not `Paused` → `Outcome.wait(now + retry_after + jitter, result: {"in_line" => true})`. Otherwise `take_turn(not_before: retry_after, paused:)`.
    - `take_turn` → `wait = schedule.reserve(not_before:)`; `Outcome.wait(now + wait + jitter, release: paused || wait > CHAIN_PATIENCE, result: {"in_line" => true})`.
  - `Steps::AuthorFacts#call`: `EnrichAuthor.call(author:, allow_research: run.options.fetch("allow_research", true))`; raise `StandardError, "Author enrichment failed for author #{id}: …"` unless success (so the coordinator retries, as `EnrichJob` does); else `Outcome.succeeded("done")`.

- [ ] **Step 1: Write the failing tests.** Adapter tests stub the services (as `test/sidekiq/books/authors/*_job_test.rb` do today; reuse their `outcome` builders and the `Viaf::Schedule` + `Books::OpenLibrary::FakeRedis` setup with `freeze_time`). Workflow tests drive a whole author run with `stub_workflow_dispatch` and a helper `run_step(run, key)` that claims and executes one step through `WorkflowStepJob#perform`.

```ruby
# author_enrichment_test.rb
test "a Wikidata match skips VIAF and its follow-up, then runs the AI step" do
  stub_services(wikidata: :matched)
  run = start
  run_step(run, :wikidata)
  assert_equal %w[skipped skipped ready], %w[viaf wikidata_via_viaf author_facts].map { run.step(it).reload.state }
end

test "VIAF within patience: the follow-up finishes before the AI step, and the late step is skipped" do
  stub_services(wikidata: :unmatched, viaf: {outcome: :matched, wikidata_qid: "Q1"})
  run = start
  %i[wikidata viaf wikidata_via_viaf author_facts].each { run_step(run, it) }
  assert_equal ["succeeded", "skipped", "completed"], [run.step(:author_facts).state, run.step(:author_facts_late).state, run.reload.status]
end

test "VIAF beyond patience releases the AI step now; a late QID runs the follow-up and the late AI step" do
  stub_services(wikidata: :unmatched)
  @schedule.stubs(:reserve).returns(601)
  run = start
  run_step(run, :wikidata)
  run_step(run, :viaf)                                   # takes a far turn
  assert_equal ["waiting", true, "ready"], [run.step(:viaf).reload.state, run.step(:viaf).released?, run.step(:author_facts).reload.state]
  run_step(run, :author_facts)
  stub_services(viaf: {outcome: :matched, wikidata_qid: "Q1"})
  wake_and_run(run, :viaf)                               # in line now, VIAF answers
  run_step(run, :wikidata_via_viaf)
  assert_equal "ready", run.step(:author_facts_late).reload.state
end

test "start_at viaf runs VIAF for an author Wikidata already processed" do
  run = start(options: {start_at: "viaf"})
  assert_equal ["skipped", "ready"], [run.step(:wikidata).state, run.step(:viaf).state]
end

test "skip_ai_if_ran skips the AI step when it already ran this era" do
  Services::Books::Authors::LedgerRun.stubs(:ai_step_ran_ids).returns(Set[@author.id])
  stub_services(wikidata: :matched)
  run = start(options: {skip_ai_if_ran: true})
  run_step(run, :wikidata)
  assert_equal ["skipped", "already_ran"], [run.step(:author_facts).reload.state, run.step(:author_facts).outcome]
end

test "a Wikidata rate limit waits without counting an attempt" do
  Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(Wikimedia::Exceptions::RateLimited.new("busy", retry_after: 60))
  run = start
  run_step(run, :wikidata)
  assert_equal ["waiting", 0], [run.step(:wikidata).reload.state, run.step(:wikidata).attempts]
end

test "the AI step still releases after its retries are exhausted, and hands legacy books on" do
  Services::Books::Authors::EnrichAuthor.stubs(:call).returns(stub(success?: false, errors: ["x"]))
  Books::Authors::EnrichJob.expects(:hand_off).with(@author.id).once
  # three failed attempts via run_step + wake
  assert_equal ["failed", true], [run.step(:author_facts).state, run.step(:author_facts).released?]
end
```

- [ ] **Step 2: Run, verify failure.** `bin/rails test test/lib/workflows/books/ test/lib/services/books/authors/ledger_run_test.rb`
- [ ] **Step 3: Implement the definition, adapters, `LedgerRun.ai_step_ran_ids`, and register the workflow.**
- [ ] **Step 4: Run, verify pass; `CI=1 bin/rails zeitwerk:check`.**
- [ ] **Step 5: Commit.** `git commit -m "Author enrichment workflow"`

### Task 8: Author entry points and in-flight job shims

**Files:**
- Modify: `app/sidekiq/books/authors/wikidata_job.rb`, `app/sidekiq/books/authors/viaf_job.rb`
- Modify: `app/lib/data_importers/books/author/providers/enrichment.rb`
- Modify: `app/lib/services/books/authors/backfill.rb`
- Modify: `app/lib/services/books/authors/reject_external_link.rb`
- Test: `test/sidekiq/books/authors/wikidata_job_test.rb`, `viaf_job_test.rb` (rewrite), `test/lib/data_importers/books/author/providers/enrichment_test.rb`, `test/lib/services/books/authors/backfill_test.rb`, `test/lib/services/books/authors/reject_external_link_test.rb`

**Interfaces:**
- Consumes: `Workflows::Books::AuthorEnrichment.start` (Task 7).
- Produces:
  - `WikidataJob#perform(author_id, refresh = false, via_viaf = false, allow_research = true)` (signature kept for in-flight messages): no-op for a missing author; otherwise `AuthorEnrichment.start(author, initiated_by: "legacy_job", options: {refresh: refresh || via_viaf, allow_research:})`. If a run is active, `start` reuses it, which is the "does nothing" the spec asks for. No chaining, no rate-limit rescue. `EnrichJob` is **unchanged** (it ends the old chain and chains nothing but the legacy hand-off; leaving it as-is is simpler than the spec's `only:` mapping and equivalent).
  - `ViafJob#perform(author_id, refresh = false, enrich_queued = false, allow_research = true, in_line = false)`: `AuthorEnrichment.start(author, initiated_by: "legacy_job", options: {refresh:, allow_research:, start_at: "viaf", skip_ai_if_ran: enrich_queued})`. The line logic now lives in `Steps::Viaf`; delete it from the job.
  - Author importer `Providers::Enrichment#populate`: plans with `AuthorEnrichment.start(author, initiated_by: "author_importer")` (dispatch is after commit, a fix over today's immediate enqueue); returns `[:author_enrichment_planned]`.
  - `Backfill#call`: the waiting set is `QueuedChain.author_ids | active author run ids` (`WorkflowRun.running.where(workflow: "books.author_enrichment").pluck(:enrichable_id)`). Wikidata authors: `AuthorEnrichment.start(author, initiated_by: "backfill", options: {allow_research: false}, start_after: (index * SPACING).seconds.from_now)`. VIAF retries: `options: {allow_research: false, start_at: "viaf", skip_ai_if_ran: true}` (the ledger test inside `skip_if` replaces the precomputed `ran` set). Result data keys unchanged.
  - `RejectExternalLink#call`: inside its transaction, replace the `perform_in` with `AuthorEnrichment.start(author, initiated_by: "reject_external_link", options: {refresh: true}, start_after: RERUN_DELAY.seconds.from_now, supersede: true)`. Keep the `RedisClient::Error` rescue (dispatch still touches Redis after commit; a failed dispatch is recovered by the sweep, so it no longer rolls back — update the comment to say so).

- [ ] **Step 1: Write the failing tests**

```ruby
test "an in-flight WikidataJob plans an author run instead of chaining" do
  stub_workflow_dispatch
  Books::Authors::ViafJob.expects(:perform_async).never
  Books::Authors::WikidataJob.new.perform(@author.id, false, false, false)
  run = WorkflowRun.find_by!(enrichable: @author, workflow: "books.author_enrichment")
  assert_equal [false, "legacy_job"], [run.options["allow_research"], run.initiated_by]
end

test "an in-flight ViafJob plans a run starting at VIAF, skipping the AI step if it was queued" do
  stub_workflow_dispatch
  Books::Authors::ViafJob.new.perform(@author.id, false, true, true, true)
  run = WorkflowRun.find_by!(enrichable: @author)
  assert_equal ["viaf", true], run.options.values_at("start_at", "skip_ai_if_ran")
end

test "an in-flight job for an author with an active run plans nothing new" do
  stub_workflow_dispatch
  Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")
  assert_no_difference -> { WorkflowRun.count } { Books::Authors::WikidataJob.new.perform(@author.id) }
end

test "backfill spaces Wikidata starts by SPACING and leaves out authors with an active run" do ...
test "backfill retries VIAF with start_at viaf and skip_ai_if_ran" do ...

test "a reject supersedes the active run and plans a refresh run after RERUN_DELAY, in its transaction" do
  stub_workflow_dispatch
  active = Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")
  result = Services::Books::Authors::RejectExternalLink.call(decision: @decision, user: @admin)
  fresh = WorkflowRun.running.find_by!(enrichable: @author)
  assert_equal ["cancelled", true, RERUN_DELAY.seconds.from_now.to_i],
    [active.reload.status, fresh.options["refresh"], fresh.step(:wikidata).run_after.to_i]
end
```

(Reuse the decision/admin setup already in `reject_external_link_test.rb`; `freeze_time` for the `run_after` comparison.)

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement.** Update every existing test that stubbed `WikidataJob.perform_async`/`ViafJob.perform_async` to expect a planned run instead.
- [ ] **Step 4: Run the author-related suites, verify pass.** `bin/rails test test/sidekiq/books/authors test/lib/services/books/authors test/lib/data_importers/books`
- [ ] **Step 5: Commit.** `git commit -m "Author entry points plan workflow runs; old author jobs become shims"`

### Task 9: Admin panel, stuck-runs task, docs; PR 1 gate

**Files:**
- Create (generator `bin/rails generate controller admin/books/workflow_runs index --skip-routes`): `app/controllers/admin/books/workflow_runs_controller.rb`, `app/views/admin/books/workflow_runs/index.html.erb`
- Modify: `config/routes.rb` (books admin block: `resources :workflow_runs, only: [:index]` nested under `books` and `authors`)
- Modify: `app/views/admin/books/books/show.html.erb` (after the Categories card, ~line 164), `app/views/admin/books/authors/show.html.erb` (after Categories, ~line 131)
- Create: `lib/tasks/workflows.rake`, `app/lib/workflows/stuck.rb`
- Create: `docs/features/enrichment-workflows.md`; Modify: `docs/features/books-author-enrichment.md`
- Test: `test/controllers/admin/books/workflow_runs_controller_test.rb`, `test/lib/workflows/stuck_test.rb`
- E2E: `e2e/tests/books/admin/books.spec.ts`, `e2e/tests/books/admin/authors.spec.ts`

**Interfaces:**
- Consumes: Tasks 1–8.
- Produces:
  - `Admin::Books::WorkflowRunsController < Admin::Books::BaseController#index`: parent via `Admin::DomainRouting.parent_from_params(params, domain: current_domain)`, authorized as a `show` on the parent (same policy call the parent's show uses); `@runs = WorkflowRun.where(enrichable: @item).includes(steps: {dependencies: {prerequisite_step: :run}}).order(created_at: :desc).limit(20)`; `render layout: false`. The frame id is `workflow_runs_list`.
  - Show pages: a full-width `card bg-base-100 shadow` titled "Enrichment runs" holding `turbo_frame_tag "workflow_runs_list", loading: :lazy, src: admin_books_book_workflow_runs_path(@book)` (author: `admin_books_author_workflow_runs_path(@author)`), with the spinner placeholder the Categories card uses. The frame contains no off-page links except prerequisite links, which carry `data: {turbo_frame: "_top"}` (the `assert_no_frame_trapped_links` guard).
  - Index view: per run (newest first) the workflow, status, initiated_by, started/finished times; per step: key, state, outcome, attempts/max, `run_after` when waiting, error, and for a blocked step its unsatisfied prerequisites as links to the other record's admin page (`Admin::DomainRouting.path_for`). Ledger rows: `Enrichment.where(workflow_step_id: step_ids)` grouped by step, showing kind, mode and outcome. Empty state: "No enrichment runs." Use DaisyUI 5 classes only (`table`, `badge`); no removed v4 classes.
  - `Workflows::Stuck.call(older_than: 6.hours) -> Array<Hash>` rows `{run_id:, workflow:, target:, step:, state:, since:, error:}` for: `failed` steps in runs finished within the last 7 days; `waiting`/`blocked`/`ready` steps not updated for longer than `older_than`; `running` steps past their lease.
  - `bin/rails "workflows:stuck[hours]"` (default 6) prints one line per row.
  - Docs: `docs/features/enrichment-workflows.md` covers the tables, step states, edge kinds and release pass-through, the coordinator protocol, recovery, the admin panel and `workflows:stuck`, and how to add a step (cite the Goodreads shape). `books-author-enrichment.md`: replace the job-chain description with the author workflow, keep the VIAF patience explanation, mark the stuck-chain section as superseded by the sweep.

- [ ] **Step 1: Write the failing tests**

```ruby
# controller test
test "renders the runs frame for a book" do
  sign_in_as(@admin, stub_auth: true)
  get admin_books_book_workflow_runs_path(books_books(:war_and_peace)), headers: {"Host" => books_host}
  assert_response :success
  assert_no_frame_trapped_links
end

test "renders the runs frame for an author" do ...
test "refuses a signed-out visitor" do ... (assert the same redirect the books show test asserts)

# stuck_test.rb
test "lists a step waiting longer than the threshold and a running step past its lease" do
  run.step(:a).update_columns(state: WorkflowStep.states[:waiting], updated_at: 7.hours.ago)
  run.step(:b).update_columns(state: WorkflowStep.states[:running], lease_expires_at: 1.minute.ago)
  assert_equal %w[a b], Workflows::Stuck.call.map { it[:step] }.sort
end
```

(Check the existing admin books controller tests for the host helper and admin fixture names before writing these.)

E2E (both specs, as the admin account already used in these files):

```ts
test('shows the Enrichment runs card', async ({ page }) => {
  await page.goto(bookAdminUrl);                         // an existing book the spec already visits
  await expect(page.getByRole('heading', { name: 'Enrichment runs' })).toBeVisible();
  await expect(page.getByText('No enrichment runs.').or(page.getByRole('table'))).toBeVisible();
});
```

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement controller, routes, view, cards, rake task, `Workflows::Stuck`, docs.**
- [ ] **Step 4: Run, verify pass.** Then the PR 1 gate:
  - `bin/rails test` → green, no new warning lines
  - `bin/rails test:system` (UI touched) → green
  - `bundle exec standardrb` → no offenses
  - `CI=1 bin/rails zeitwerk:check` → "All is good!"
  - `yarn build:all && bin/rails server`, confirm port 3000 is this worktree's (AGENTS.md snippet), then `yarn test:e2e e2e/tests/books/admin/books.spec.ts e2e/tests/books/admin/authors.spec.ts` → pass
- [ ] **Step 5: Commit.** `git commit -m "Enrichment runs admin panel, workflows:stuck, engine docs"`

---

## PR 2: book workflow

### Task 10: Book enrichment workflow

**Files:**
- Create: `app/lib/workflows/books/book_enrichment.rb`, `app/lib/workflows/books/steps/book_facts.rb`, `app/lib/workflows/books/steps/amazon.rb`
- Modify: `app/lib/workflows/registry.rb`
- Test: `test/lib/workflows/books/book_enrichment_test.rb`, `test/lib/workflows/books/steps/book_facts_test.rb`, `amazon_test.rb`

**Interfaces:**
- Consumes: Tasks 1–7; `Services::Books::EnrichBook.call(book:, force_research:, author_names:)` (Result `success?`, `errors`), `Services::Books::AmazonProductService.call(book:)` (Hash `{success:, data:, errors:}`).
- Produces:
  - `Workflows::Books::BookEnrichment` (`< Workflows::Definition`), workflow `books.book_enrichment`, version 1, target `::Books::Book`. Steps:
    - `book_facts`: queue `low`, lease 15 min, no definition-level waits (its author waits are cross-run, passed at plan time). **This is the line Goodreads will edit to add `goodreads: :finish`.** Adapter `Steps::BookFacts`: `EnrichBook.call(book:, force_research: run.options.fetch("force_research", false), author_names: run.options.fetch("author_names", []))`; raise unless success; else `Outcome.succeeded("done")`.
    - `amazon`: queue `serial`, lease 10 min, no waits (Goodreads will add `goodreads: :finish`). Adapter `Steps::Amazon`: calls the service, then always `book.update_column(:amazon_enriched_at, Time.current)` (the job's sweep-coverage rule); raise `StandardError, "Amazon enrichment failed: …"` unless `result[:success]`; log per-product errors as the job does; `Outcome.succeeded("done")`.
  - `Workflows::Books::BookEnrichment.start(book, initiated_by:, new_author_ids: [], author_names: [], options: {}) -> WorkflowRun`:
    - waited-on authors = `new_author_ids & book.book_authors.pluck(:author_id)` (a created but unlinked author gets its own run but holds nothing, as today);
    - for **every** id in `new_author_ids`, `AuthorEnrichment.start(author, initiated_by:, parent_run: nil)` (reuses an active run); collect the waited-on authors' `author_facts` steps;
    - `skips`: `amazon: "no_authors"` when the book has no `book_authors` (Amazon's provider and `PromoteRecords` require one);
    - `Planner.call(definition: self, enrichable: book, initiated_by:, options: options.merge(author_names:), waits: {book_facts: author_facts_steps}, skips:)`, then `Dispatcher.after_commit(ready_steps)`;
    - sets each new author run's `parent_run_id` to the book run (display only) after planning.

- [ ] **Step 1: Write the failing tests**

```ruby
test "a book with no new authors makes book_facts and amazon ready at once" do
  stub_workflow_dispatch
  run = Workflows::Books::BookEnrichment.start(@book, initiated_by: "test")
  assert_equal %w[ready ready], %w[book_facts amazon].map { run.step(it).state }
end

test "book_facts waits for every new linked author, in either completion order" do
  stub_workflow_dispatch
  run = Workflows::Books::BookEnrichment.start(@book, initiated_by: "test", new_author_ids: [@a.id, @b.id])
  finish_author_facts(@b)
  assert_equal "blocked", run.step(:book_facts).reload.state
  finish_author_facts(@a)
  assert_equal "ready", run.step(:book_facts).reload.state
end

test "simultaneous author completion makes book_facts ready once" do
  # finish both authors' author_facts, then advance each again
  assert_equal [], Workflows::Coordinator.advance(author_run(@a).step(:author_facts))
end

test "a created author not linked to the book gets a run but holds nothing" do ...
test "joins an author's active run instead of planning another" do ...
test "a book with no book_authors plans amazon skipped as no_authors" do ...
test "book_facts still runs after an author's AI step failed" do ...
test "a deleted author releases the waiting book (via recovery)" do ...

# amazon_test.rb
test "stamps amazon_enriched_at even when the service fails, and raises" do
  Services::Books::AmazonProductService.stubs(:call).returns({success: false, errors: ["nope"]})
  assert_raises(StandardError) { Workflows::Books::Steps::Amazon.new.call(step:, run:, target: @book) }
  assert @book.reload.amazon_enriched_at.present?
end
```

(`finish_author_facts(author)` claims and finishes that author run's `author_facts` with `Outcome.succeeded("done")`; fixtures: two `books_authors` linked to `@book` through `books_book_authors` — pick or add fixtures after reading `test/fixtures/books/book_authors.yml`.)

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement and register.**
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "Book enrichment workflow: book AI waits for every new author"`

### Task 11: Book entry points

**Files:**
- Create: `app/lib/data_importers/books/book/providers/enrichment.rb`
- Delete: `app/lib/data_importers/books/book/providers/ai_enrichment.rb`, `author_enrichment.rb`, `amazon.rb` and their tests
- Modify: `app/lib/data_importers/books/book/importer.rb` (provider list and its comment)
- Modify: `app/lib/services/lists/wizard/books/adapter.rb` (`TEXT_PROVIDERS = %i[authors enrichment].freeze`)
- Modify: `app/lib/services/books/goodreads_imports/promote_records.rb`
- Modify: `docs/features/data_importers.md`, `docs/features/books_enrichment.md`
- Test: `test/lib/data_importers/books/book/providers/enrichment_test.rb`, `test/lib/data_importers/books/book/importer_test.rb`, `test/lib/services/lists/wizard/books/adapter_test.rb`, `test/lib/services/books/goodreads_imports/promote_records_test.rb`

**Interfaces:**
- Consumes: `Workflows::Books::BookEnrichment.start` (Task 10).
- Produces:
  - `Providers::Enrichment.new(new_author_ids:)#populate(book, query:, match: nil)`: same fail-fast checks and messages as the old AiEnrichment (title, author names from `book.authors` else the query's, persisted); then `BookEnrichment.start(book, initiated_by: "importer", new_author_ids: @new_author_ids, author_names:)` **immediately** (plan rows join the caller's transaction, so a rollback removes them; dispatch waits for the outermost commit). Returns `[:enrichment_planned]`. Provider symbol `:enrichment`.
  - `Importer#providers`: OpenLibrary, Authors, [QueryIdentifiers], then `Providers::Enrichment` when `enrich`. Update the comment to describe the workflow.
  - `PromoteRecords#call`: drop the `defer!` branch and the after-commit `WikidataJob`/`EnrichBookJob`/`AmazonProductEnrichmentJob` enqueues. Inside the transaction, after un-provisioning: `BookEnrichment.start(book, initiated_by: "goodreads_promote", new_author_ids: author_ids.to_a)` for each promoted book, and `AuthorEnrichment.start(author, initiated_by: "goodreads_promote")` for promoted authors credited to no promoted book. Keep the purge, goal-page and favorites jobs as they are.
  - Docs: `data_importers.md` Books providers become OpenLibrary, Authors, QueryIdentifiers, Enrichment (link to `enrichment-workflows.md`); `books_enrichment.md` trigger section names the workflow and its entry points.

- [ ] **Step 1: Write the failing tests**

```ruby
test "an import with enrich plans one book run and author runs for created authors" do
  stub_workflow_dispatch
  result = DataImporters::Books::Book::Importer.call(title: "New Book", author_names: ["Brand New Author"])
  run = WorkflowRun.find_by!(enrichable: result.item, workflow: "books.book_enrichment")
  assert_equal 1, run.step(:book_facts).dependencies.count
end

test "enrich: false plans nothing" do ...

test "a rolled-back wizard row leaves no run and dispatches nothing" do
  stub_workflow_dispatch.never
  assert_raises(Services::Lists::Wizard::Books::Adapter::CreateFailed) { ... a row whose import creates no author ... }
  assert_equal 0, WorkflowRun.count
end

test "a wizard text row runs authors and enrichment only" do ...
test "promoting a book with a promoted author plans a book run that waits on the author run" do ...
test "promoting an author with no promoted book plans only its author run" do ...
```

(Find the exact `CreateFailed` constant path and an existing failing-row setup in `adapter_test.rb`; reuse `GoodreadsImportHelper` for promotion fixtures.)

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement, delete the three providers and their tests, update docs.**
- [ ] **Step 4: Run, verify pass.** `bin/rails test test/lib/data_importers test/lib/services/lists test/lib/services/books/goodreads_imports`
- [ ] **Step 5: Commit.** `git commit -m "Book imports, the list wizard and Goodreads approval plan book workflow runs"`

### Task 12: Adopt deferred books, narrow enrich_missing; PR 2 gate

**Files:**
- Modify: `lib/tasks/books/enrich.rake` (`enrich_missing`), add `books:workflows:adopt_deferred` to `lib/tasks/workflows.rake`
- Create: `app/lib/workflows/books/adopt_deferred.rb`
- Modify: `docs/launch-todo.md` (add the one-off production step), `docs/features/enrichment-workflows.md`
- Test: `test/lib/workflows/books/adopt_deferred_test.rb`, `test/lib/tasks/books/enrich_rake_test.rb` (create if absent, following existing rake tests' style)

**Interfaces:**
- Consumes: Tasks 10–11, `Services::Books::DeferredEnrichment::REASON`.
- Produces:
  - `Workflows::Books::AdoptDeferred.call(limit: nil) -> Hash` `{planned:, skipped_active:}`: for each book whose latest `books.book_facts` row is `deferred_to_authors` (same `DISTINCT ON` query as `DeferredEnrichment.waiting_book_ids`, over all books) and that has no running book run: `BookEnrichment.start(book, initiated_by: "adopt_deferred", options: {only: ["book_facts"]}, new_author_ids: linked authors that have an active author run)`. Books whose authors have no active run get a `book_facts` that is ready at once. Idempotent: a second call plans nothing new.
  - `books:workflows:adopt_deferred[limit]` prints the counts.
  - `books:enrich_missing`: the first group (no ledger row, no description) now also excludes books with a running book run; the deferral group stays until Task 14.
  - `launch-todo.md`: "After PR 2 deploys: `bin/rails books:workflows:adopt_deferred`" in the books section.

- [ ] **Step 1: Write the failing tests**

```ruby
test "plans a book_facts-only run for a deferred book, waiting on its author's active run" do
  Services::Books::DeferredEnrichment.defer!(@book)
  author_run = Workflows::Books::AuthorEnrichment.start(@author, initiated_by: "test")
  stub_workflow_dispatch
  Workflows::Books::AdoptDeferred.call
  run = WorkflowRun.find_by!(enrichable: @book)
  assert_equal [["not_requested"], [author_run.step(:author_facts).id]],
    [[run.step(:amazon).outcome], run.step(:book_facts).dependencies.map(&:prerequisite_step_id)]
end

test "is idempotent" do ...
test "enrich_missing skips a book with a running book run" do ...
```

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, verify pass.** Then the PR 2 gate (same as Task 9's: full `bin/rails test`, `test:system`, `standardrb`, `zeitwerk:check`; E2E re-run of the two admin specs).
- [ ] **Step 5: Commit.** `git commit -m "Adopt books still deferred to their authors; enrich_missing skips running runs"`

### Task 13: Multi-author end-to-end runs

**Files:**
- Test: `test/integration/workflows/books_enrichment_flow_test.rb`

**Interfaces:**
- Consumes: everything above. Runs with the global inline Sidekiq mode (no dispatch stub): services are stubbed at the service boundary (`EnrichFromWikidata`, `EnrichFromViaf`, `EnrichAuthor`, `EnrichBook`, `AmazonProductService`), so whole runs execute inline through `WorkflowStepJob`.

- [ ] **Step 1: Write the tests** (they should pass if Tasks 1–12 are right; a failure here is a bug in an earlier task)

```ruby
test "an imported book with two new authors runs book AI once, after both authors' AI steps" do
  calls = []
  Services::Books::Authors::EnrichAuthor.stubs(:call).with { calls << [:author, it[:author].name]; true }.returns(success)
  Services::Books::EnrichBook.stubs(:call).with { calls << [:book]; true }.returns(success)
  DataImporters::Books::Book::Importer.call(title: "Two Hands", author_names: ["New One", "New Two"])
  assert_equal [:book], calls.last
  assert_equal 2, calls.count { it.first == :author }
  assert_equal 1, calls.count { it == [:book] }
end

test "a book whose author waits on a far VIAF turn gets its AI step after the author's, before VIAF finishes" do ...
test "a worker crash mid-step is recovered by the sweep" do
  # claim a step with token "dead", expire its lease, run Workflows::Recovery.call, assert the run completes
end
test "a committed advance whose dispatch failed is recovered" do
  # Dispatcher.dispatch raises RedisClient::CannotConnectError once; Recovery.call later completes the run
end
```

- [ ] **Step 2: Run.** `bin/rails test test/integration/workflows/` → PASS
- [ ] **Step 3: Commit.** `git commit -m "End-to-end tests: multi-author book enrichment and recovery"`

---

## PR 3 (separate, after production shows no old messages): retire the old hand-off

### Task 14: Remove the deferral machinery

**Precondition (Shane runs this on production before the PR is merged):**

```bash
bin/rails runner 'require "sidekiq/api"; jobs = %w[Books::Authors::WikidataJob Books::Authors::ViafJob Books::Authors::EnrichJob Books::EnrichBookJob]; sets = [Sidekiq::ScheduledSet.new, Sidekiq::RetrySet.new, Sidekiq::Queue.new("author_chain"), Sidekiq::Queue.new("low")]; p sets.sum { |s| s.count { |j| jobs.include?(j.klass) } }; p Enrichment.where(reason: "deferred_to_authors").where.not(enrichable_id: WorkflowRun.where(enrichable_type: "Books::Book").select(:enrichable_id)).count'
```

Expected: `0` then `0` (or only books whose newest ledger row is no longer the deferral).

**Files:**
- Delete: `app/lib/services/books/deferred_enrichment.rb`, `app/sidekiq/books/authors/wikidata_job.rb`, `viaf_job.rb`, `enrich_job.rb`, `app/lib/services/books/authors/queued_chain.rb`, `app/lib/workflows/books/adopt_deferred.rb` and their tests; remove `books:workflows:adopt_deferred`
- Modify: `app/lib/workflows/books/author_enrichment.rb` (remove `on_terminal` from `author_facts`; bump `version` to 2), `app/lib/services/books/authors/backfill.rb` (waiting set = active runs only), `lib/tasks/books/enrich.rake` (drop the deferral group and its comment), `test/sidekiq/books/authors/queue_config_test.rb` (delete or repoint to the workflow queues), docs (`books-author-enrichment.md`, `books_enrichment.md`, `enrichment-workflows.md`, `launch-todo.md` step removed)
- Keep: `Books::EnrichBookJob` (admin Enrich With AI) and `Books::AmazonProductEnrichmentJob` (`books:amazon_enrich*` rake tasks).

- [ ] **Step 1: `grep -rn "DeferredEnrichment\|WikidataJob\|ViafJob\|Authors::EnrichJob\|QueuedChain\|AdoptDeferred" app lib test config docs` and list every hit.**
- [ ] **Step 2: Remove or repoint each hit; delete the files above.**
- [ ] **Step 3: Run the gate** (full `bin/rails test`, `standardrb`, `zeitwerk:check`). Expected: green, and the grep from Step 1 returns only historical spec/plan files.
- [ ] **Step 4: Commit.** `git commit -m "Retire the deferral hand-off and the chained author jobs"`
