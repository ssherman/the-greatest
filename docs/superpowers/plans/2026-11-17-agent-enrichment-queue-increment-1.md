# Agent Enrichment Queue, Increment 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generic enrichment queue an agent works through the admin MCP server (claim, submit, skip), with an admin page and Copy prompt per type, and the first two types: `books.origin` and `books.categories`.

**Architecture:** One table, `enrichment_requests`, holds one row per record and type. A small engine (`Services::EnrichmentQueue::*`) fills, claims, submits, skips and applies; it calls a type class and knows nothing about books. Each books type reuses the existing judge's "answer in, ledger row out" half, extracted so the paid path and the agent path share it. Submit stores the answer and a Sidekiq job applies it.

**Tech Stack:** Rails 8, Postgres, Sidekiq, Minitest + fixtures + Mocha, `json_schemer` (already bundled through `openapi_first`), the `mcp` gem via the OpenAPI-generated catalogue, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-agent-enrichment-queue-design.md` (sections 1 to 9 and 12; sections 10 and 11 are later increments). Executors read both.

## Global Constraints

- Run Rails and yarn commands from `web-app/`. Docs live in `docs/` at the project root.
- Models and jobs come from generators: `bin/rails generate model ...`, `bin/rails generate sidekiq:job ...` (never `generate job`). Jobs live in `app/sidekiq/`, services in `app/lib/services/`.
- `bin/rails db:migrate` runs annotaterb; the annotation ships in the same commit. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. The dev database is shared between worktrees: if `schema.rb` or an annotation picks up another branch's columns, delete only those lines.
- Never run a destructive command against the development database. Tests run with the per-checkout test database.
- Lint with `bundle exec standardrb` (not rubocop). Do not run brakeman.
- Rails 8 enum syntax: `enum :status, {pending: 0}`. Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Namespace shadowing.** Inside `module Services`, a bare `Books::` is `Services::Books::` and a bare `EnrichmentQueue::` is `Services::EnrichmentQueue::`. Root-anchor models and jobs: `::Books::Book`, `::EnrichmentRequest`, `::EnrichmentQueue::ApplyJob`. The books types live in `Services::Books::QueueTypes` (not `Services::Books::EnrichmentQueue`, which would shadow the engine).
- Minitest 6: `assert_nil`, never `assert_equal nil`. Stub every external API with Mocha. Sidekiq runs inline in tests; wrap in `Sidekiq::Testing.fake! { }` to stop a job running.
- Controller tests assert behaviour (status, JSON, records), never HTML or copy. Check fixture names before using them (`books_books(:war_and_peace)`, `books_authors(:tolstoy)`).
- DaisyUI 5 on Tailwind 4: no `form-control`, `label-text`, `input-bordered`, `select-bordered`, `table-hover`, `tabs-boxed`. Use `fieldset`, `label`, bare `input`/`select`.
- A clean `bin/rails test` prints no new warnings.
- Commit after every task, on branch `worktree-agent-enrichment-queue`. Never commit to `main`, never push or open a PR without Shane's say-so.
- Subagents: implement with `model: "sonnet"`, review with `model: "opus"`. Never Fable.

## Rulings (designer's calls beyond the spec)

1. **The fingerprint re-open pass is increment 3.** The `fingerprint` column is created now; `Fill` does not read it yet.
2. **A failed apply attempt may write a failed ledger row each time**, as a workflow step's retries do, not only on the last attempt.
3. **Submitting twice is safe.** A second submit with the same lease token on a row already `submitted` answers 202 and queues nothing.
4. **Bounds on what an agent sends:** `answer` at most 50,000 bytes of JSON, `note` at most 1,000 characters, `sources` 1 to 20 `http(s)` URLs of at most 2,000 characters, skip `reason` 1 to 500 characters.
5. **An agent ledger row counts as done for the paced backfill only when its outcome is `applied`** (the spec says "applied nothing does not count"; `unrecognized` is treated the same as `nothing_to_apply`).
6. **The API controllers sit in the books module** like every other admin operation; the services and resources they call are generic and take the domain.
7. **The Playwright spec does not press Fill.** The spec asks for "Fill queues a job" in the E2E test; that would queue a job against the shared development database, so the controller test covers it instead.

## Review Focus

1. **Two sub-agents claim at once.** Each must get different items. (Task 4: sequential claims never overlap; the claim query locks with `FOR UPDATE SKIP LOCKED`.)
2. **An answer the catalogue cannot use:** a nationality that matches no country, a genre id not on the list. The row must end `done` with nothing applied, never raise. (Tasks 7 and 8.)
3. **The record changes between claim and apply:** the book is deleted (row gone: submit is 404, the job is a no-op) or merged (row follows the survivor, or is dropped when the survivor has one). (Tasks 1, 5 and 9.)
4. **An agent retries a submit, or submits after its lease was taken over.** Same token twice is 202 once applied once; a taken-over lease is 409 and writes nothing. (Task 5.)
5. **Oversized or malformed input:** a huge answer, a non-URL source, a missing lease token. A 400 or 422 with a named problem, nothing stored. (Tasks 5 and 9.)

## File Structure

| File | Responsibility |
|---|---|
| `app/models/enrichment_request.rb` (+ migration) | The row: statuses, lease, scopes, `carry_over` for mergers |
| `app/lib/services/enrichment_queue/type.rb` | The interface a type implements |
| `app/lib/services/enrichment_queue/registry.rb` | Kind → type lookup, per-domain listing |
| `app/lib/services/enrichment_queue/fill.rb` | Insert candidates, re-open old versions, refresh priorities |
| `app/lib/services/enrichment_queue/claim.rb` | Lease a batch |
| `app/lib/services/enrichment_queue/submit.rb`, `skip.rb`, `requeue.rb` | The three row transitions an actor triggers |
| `app/lib/services/enrichment_queue/apply.rb` | Run the type's apply for a submitted row |
| `app/lib/services/enrichment_queue/counts.rb` | Status and outcome counts per kind |
| `app/sidekiq/enrichment_queue/fill_job.rb`, `apply_job.rb` | Sidekiq wrappers |
| `lib/tasks/enrichment_queue.rake` | `enrichment_queue:fill` |
| `app/lib/services/books/origin/record_answer.rb` | Origin answer → apply → ledger row (shared by judge and agent) |
| `app/lib/services/books/categories/record_answer.rb` | Categories answer → map → apply → ledger row (shared) |
| `app/lib/services/books/queue_types/book_scope.rb` | Shared SQL for book types: ranked join, running-run exclusion, priority |
| `app/lib/services/books/queue_types/origin.rb`, `categories.rb` | The two types |
| `app/controllers/api/v1/admin/books/enrichment_queues_controller.rb`, `enrichment_items_controller.rb` | The five operations |
| `app/lib/api/v1/admin/enrichment_queue_resource.rb`, `enrichment_item_resource.rb` | JSON shapes |
| `config/api/v1/admin_openapi.yaml` | Five operations with `x-mcp` |
| `config/mcp/books/prompts/enrichment/origin.md.erb`, `categories.md.erb` | Copy prompts |
| `app/controllers/admin/enrichment_queues_base_controller.rb`, `admin/books/enrichment_queues_controller.rb` | Admin page |
| `app/views/admin/enrichment_queues_base/index.html.erb`, `show.html.erb` | Admin page views |
| `docs/features/enrichment-queue.md` | Feature doc |

---

### Task 1: The `EnrichmentRequest` model

**Files:**
- Create: `app/models/enrichment_request.rb`, its migration, `test/models/enrichment_request_test.rb`, `test/fixtures/enrichment_requests.yml` (empty: `{}`)
- Modify: `app/models/books/book.rb`, `app/models/books/author.rb`, `app/models/user.rb`, `app/lib/books/book/merger.rb`, `app/lib/books/author/merger.rb`
- Test: `test/models/enrichment_request_test.rb`, `test/lib/books/book/merger_test.rb`, `test/lib/books/author/merger_test.rb`

**Interfaces:**
- Produces:
  - `EnrichmentRequest` with enums `status` `{pending: 0, claimed: 1, submitted: 2, done: 3, skipped: 4, failed: 5}` and `resolved_via` `{api: 0, paid_research: 1, admin_ui: 2, system: 3}` (the mapping is `EnrichmentRequest.resolved_via`: "via" is uncountable).
  - Constants `LEASE = 30.minutes`, `MAX_ATTEMPTS = 3`, `REASONS = %w[missing research_wanted changed version manual]`.
  - Scopes `for_kind(kind)`, `claimable` (pending, or claimed with `lease_expires_at < now`), `open` (pending or claimed), `resolved` (done or skipped).
  - `EnrichmentRequest.carry_over(source:, target:) → Integer` (rows moved).
  - `has_many :enrichment_requests, as: :enrichable, dependent: :delete_all` on `Books::Book` and `Books::Author`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model EnrichmentRequest enrichable:references{polymorphic} kind:string version:integer \
  status:integer priority:integer reason:string fingerprint:string outcome:string note:text answer:jsonb \
  error:text sources:jsonb enrichment:references lease_token:string lease_expires_at:datetime attempts:integer \
  claimed_by:references resolved_by:references resolved_via:integer resolved_at:datetime
```

- [ ] **Step 2: Edit the migration before running it**

`null: false` on `kind`, `version` (default 1), `status` (default 0), `priority` (default 1_000_000), `reason`, `attempts` (default 0), `sources` (default `[]`). `enrichment`, `claimed_by`, `resolved_by` are nullable; foreign keys `enrichment_id → enrichments` and `claimed_by_id`/`resolved_by_id → users`, all `on_delete: :nullify`. Indexes: unique `[:enrichable_type, :enrichable_id, :kind]` named `index_enrichment_requests_one_per_record_and_kind`; `[:kind, :status, :priority, :id]`. Drop the generator's separate polymorphic index (the unique one covers it). Run `bin/rails db:migrate`.

- [ ] **Step 3: Write the failing model tests**

```ruby
test "one row per record and kind" do
  book = books_books(:war_and_peace)
  EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
  assert_raises(ActiveRecord::RecordNotUnique) do
    EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
  end
end

test "kind must look like a ledger kind and reason must be known" do
  row = EnrichmentRequest.new(enrichable: books_books(:war_and_peace), kind: "Origin", reason: "because")
  assert_not row.valid?
  assert row.errors[:kind].any?
  assert row.errors[:reason].any?
end

test "claimable is pending rows and claimed rows whose lease ran out" do
  book, other, third = books_books(:war_and_peace), books_books(:crime_and_punishment), books_books(:got)
  pending = EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
  expired = EnrichmentRequest.create!(enrichable: other, kind: "books.origin", reason: "missing", status: :claimed, lease_expires_at: 1.minute.ago)
  held = EnrichmentRequest.create!(enrichable: third, kind: "books.origin", reason: "missing", status: :claimed, lease_expires_at: 10.minutes.from_now)
  assert_equal [pending.id, expired.id].sort, EnrichmentRequest.claimable.pluck(:id).sort
  assert_not_includes EnrichmentRequest.claimable, held
end

test "deleting the book deletes its rows" do
  book = ::Books::Book.create!(title: "Gone")
  EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
  assert_difference -> { EnrichmentRequest.count }, -1 do
    book.destroy!
  end
end

test "carry_over moves the source's rows and drops one the target already has" do
  source, target = books_books(:war_and_peace), books_books(:crime_and_punishment)
  moved = EnrichmentRequest.create!(enrichable: source, kind: "books.origin", reason: "missing")
  EnrichmentRequest.create!(enrichable: source, kind: "books.categories", reason: "missing")
  kept = EnrichmentRequest.create!(enrichable: target, kind: "books.categories", reason: "missing", status: :done)
  assert_equal 1, EnrichmentRequest.carry_over(source: source, target: target)
  assert_equal target, moved.reload.enrichable
  assert_equal [kept.id], EnrichmentRequest.where(enrichable: target, kind: "books.categories").pluck(:id)
  assert_empty EnrichmentRequest.where(enrichable: source).to_a
end
```

- [ ] **Step 4: Run them, expect failures**

Run: `bin/rails test test/models/enrichment_request_test.rb`
Expected: FAIL (no validations, scopes or `carry_over`).

- [ ] **Step 5: Implement the model, the associations and the merger rule**

`kind` validates with `Enrichment::KIND_FORMAT`; `reason` inclusion in `REASONS`. `belongs_to :enrichment, optional: true`, `belongs_to :claimed_by, class_name: "User", optional: true`, the same for `resolved_by`. On `User`: `has_many :claimed_enrichment_requests` and `:resolved_enrichment_requests` (`class_name: "EnrichmentRequest"`, `foreign_key:`, `dependent: :nullify`). In both mergers add `merge_enrichment_requests` beside `merge_enrichments`, storing `@stats[:enrichment_requests] = ::EnrichmentRequest.carry_over(source: ..., target: ...)`. Add a class-header comment on the model saying what a row is and that the ledger holds the answer history.

- [ ] **Step 6: Add one merger test per merger**

In each merger test file: a source with a `books.origin` row and a target with none; after the merge the row belongs to the target.

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/models/enrichment_request_test.rb test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb test/models/user_test.rb test/models/books/book_test.rb`
Expected: PASS (the last two hold the guards that every user FK and every book association is accounted for).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Add EnrichmentRequest: one queue row per record and type"
```

---

### Task 2: The type interface and the registry

**Files:**
- Create: `app/lib/services/enrichment_queue/type.rb`, `app/lib/services/enrichment_queue/registry.rb`, `test/support/enrichment_queue_test_type.rb`
- Test: `test/lib/services/enrichment_queue/registry_test.rb`

**Interfaces:**
- Produces `Services::EnrichmentQueue::Type`, a base class whose subclasses define **class methods**:

  | Method | Returns |
  |---|---|
  | `kind` | `"books.origin"` |
  | `label` | `"Book origin"` (admin page) |
  | `version` | Integer |
  | `target_class` | e.g. `::Books::Book` |
  | `candidates(scope:)` | Relation on `target_class`; `scope` is `"ranked"` or `"all"` |
  | `priority_sql` | SQL expression valid inside `candidates`, lower first |
  | `still_needed?(record)` | Boolean |
  | `payload(record)` | JSON-able Hash for one item |
  | `reference` | JSON-able Hash sent once per agent; includes `"answer_schema"` |
  | `answer_schema` | JSON Schema Hash |
  | `apply(request)` | `Result(success?, data: {enrichment:, outcome:}, errors:)` |
  | `prompt_locals` | Hash of extra ERB locals for the Copy prompt (default `{}`) |

  The base class implements `domain` (`kind` before the dot), `slug` (after the dot), `SCOPES = %w[ranked all]`, `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` (the Result every type's `apply` returns; the tests below write it as `Services::EnrichmentQueue::Type::Result`), and raises `NotImplementedError` for the rest.
- Produces `Services::EnrichmentQueue::Registry`: `TYPE_NAMES` (array of class-name strings, empty in this task), `.types → [Type]`, `.fetch(kind) → Type` (raises `Registry::UnknownKind`), `.for_domain(domain) → [Type]`, `.find(domain:, slug:) → Type or nil`.
- Produces `EnrichmentQueueTestType` (test support): a `Type` on `::Books::Book` with kind `"books.test_type"`, `version` 1, settable class attributes `candidate_ids` (array; `candidates` is `::Books::Book.where(id: candidate_ids)`), `needed` (default `true`) and `apply_result` (default: a success `Result` with `data: {enrichment: nil, outcome: "applied"}`), `priority_sql` `"books_books.id"`, and `answer_schema` `{"type" => "object", "required" => ["value"], "properties" => {"value" => {"type" => "string"}}, "additionalProperties" => false}`. A `reset!` class method restores the defaults. Tests stub `Registry.stubs(:types).returns([EnrichmentQueueTestType])`.

- [ ] **Step 1: Write the failing registry tests**

```ruby
test "fetch finds a type by kind and raises on an unknown one" do
  Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  assert_equal EnrichmentQueueTestType, Services::EnrichmentQueue::Registry.fetch("books.test_type")
  assert_raises(Services::EnrichmentQueue::Registry::UnknownKind) { Services::EnrichmentQueue::Registry.fetch("books.nope") }
end

test "for_domain and find scope by domain and slug" do
  Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  assert_equal [EnrichmentQueueTestType], Services::EnrichmentQueue::Registry.for_domain("books")
  assert_empty Services::EnrichmentQueue::Registry.for_domain("music")
  assert_equal EnrichmentQueueTestType, Services::EnrichmentQueue::Registry.find(domain: "books", slug: "test_type")
  assert_nil Services::EnrichmentQueue::Registry.find(domain: "books", slug: "nope")
end

test "every registered type answers the whole interface" do
  Services::EnrichmentQueue::Registry.types.each do |type|
    assert_match Enrichment::KIND_FORMAT, type.kind
    assert_kind_of Integer, type.version
    assert type.label.present?
    assert_kind_of Hash, type.answer_schema
  end
end
```

- [ ] **Step 2: Run, expect failure** — `bin/rails test test/lib/services/enrichment_queue/registry_test.rb` → FAIL (constants missing).

- [ ] **Step 3: Implement `Type`, `Registry` and the test type.** `Registry.types` constantizes `TYPE_NAMES` on each call in development and memoizes elsewhere (the pattern `Mcp::Catalog` uses). Require the test type from `test_helper.rb` with the other `test/support` files.

- [ ] **Step 4: Run, expect PASS**, plus `CI=1 bin/rails zeitwerk:check`.

- [ ] **Step 5: Commit** — `git commit -m "Enrichment queue: type interface and registry"`

---

### Task 3: Filling a queue

**Files:**
- Create: `app/lib/services/enrichment_queue/fill.rb`, `app/sidekiq/enrichment_queue/fill_job.rb` (generator: `bin/rails generate sidekiq:job enrichment_queue/fill`), `lib/tasks/enrichment_queue.rake`
- Test: `test/lib/services/enrichment_queue/fill_test.rb`, `test/sidekiq/enrichment_queue/fill_job_test.rb`

**Interfaces:**
- Consumes: `Registry.fetch`, `Type.candidates/priority_sql/version`, `EnrichmentRequest`.
- Produces:
  - `Services::EnrichmentQueue::Fill.call(kind:, scope: "ranked", limit: nil) → Result(success?, data: {inserted:, reopened:, reprioritized:}, errors:)`. An unknown kind or scope is a failure Result, not a raise.
  - `::EnrichmentQueue::FillJob#perform(kind, scope, limit)` on queue `default`.
  - `bin/rails "enrichment_queue:fill[kind,scope,limit]"`: queues the job and prints the kind; aborts with the usage line when `kind` is blank or unknown. Scope defaults to `ranked`.

- [ ] **Step 1: Write the failing tests**

```ruby
setup do
  Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  @war, @crime = books_books(:war_and_peace), books_books(:crime_and_punishment)
  EnrichmentQueueTestType.candidate_ids = [@war.id, @crime.id]
end
teardown { EnrichmentQueueTestType.reset! }

def fill(**options) = Services::EnrichmentQueue::Fill.call(kind: "books.test_type", **options)

test "inserts a pending row per candidate with the type's version and priority" do
  result = fill
  assert_equal 2, result.data[:inserted]
  row = EnrichmentRequest.find_by!(enrichable: @war, kind: "books.test_type")
  assert_equal ["pending", "missing", 1, @war.id], [row.status, row.reason, row.version, row.priority]
end

test "a second fill inserts nothing and re-opens nothing" do
  fill
  EnrichmentRequest.where(enrichable: @war).update!(status: :done, outcome: "applied", resolved_at: Time.current)
  result = fill
  assert_equal [0, 0], result.data.values_at(:inserted, :reopened)
  assert EnrichmentRequest.find_by!(enrichable: @war).done?
end

test "a resolved row below the type's version is re-opened when its record is still a candidate" do
  fill
  EnrichmentRequest.where(enrichable: [@war, @crime]).update!(status: :skipped, outcome: "nothing found", note: "n", resolved_at: Time.current)
  EnrichmentQueueTestType.stubs(:version).returns(2)
  EnrichmentQueueTestType.candidate_ids = [@war.id]
  result = fill
  assert_equal 1, result.data[:reopened]
  war = EnrichmentRequest.find_by!(enrichable: @war)
  assert_equal ["pending", "version", 2, 0], [war.status, war.reason, war.version, war.attempts]
  assert_nil war.outcome
  assert_nil war.resolved_at
  assert EnrichmentRequest.find_by!(enrichable: @crime).skipped?
end

test "claimed, submitted and failed rows are left alone" do
  fill
  EnrichmentRequest.where(enrichable: @war).update!(status: :claimed, lease_expires_at: 5.minutes.from_now, lease_token: "t")
  EnrichmentQueueTestType.stubs(:version).returns(2)
  fill
  assert EnrichmentRequest.find_by!(enrichable: @war).claimed?
end

test "a pending row's priority follows the type's priority" do
  fill
  EnrichmentRequest.where(enrichable: @war).update!(priority: 999)
  assert_equal 1, fill.data[:reprioritized]
  assert_equal @war.id, EnrichmentRequest.find_by!(enrichable: @war).priority
end

test "limit caps the candidates taken, lowest priority value first" do
  assert_equal 1, fill(limit: 1).data[:inserted]
  assert EnrichmentRequest.exists?(enrichable: [@war, @crime].min_by(&:id))
end

test "an unknown kind or scope is a failure" do
  assert_not Services::EnrichmentQueue::Fill.call(kind: "books.nope").success?
  assert_not fill(scope: "everything").success?
end
```

Job test: `::EnrichmentQueue::FillJob.new.perform("books.test_type", "all", nil)` calls `Fill` with `kind: "books.test_type", scope: "all", limit: nil` (Mocha `expects`).

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement `Fill`.** Read candidates as `(id, priority)` pairs ordered by priority then id, in batches of 5,000. Insert with `insert_all` and `unique_by: :index_enrichment_requests_one_per_record_and_kind` (ON CONFLICT DO NOTHING), counting the returned ids. Re-open only `done`/`skipped` rows among the candidates whose `version < type.version`: back to `pending`, reason `version`, `version` set to the type's, `attempts` 0, and `outcome`, `note`, `answer`, `error`, `sources`, `enrichment_id`, the lease and the `resolved_*` columns cleared. Then update the priority of `pending` rows that differ.

- [ ] **Step 4: Implement the job and the rake task.**

- [ ] **Step 5: Run, expect PASS** — `bin/rails test test/lib/services/enrichment_queue test/sidekiq/enrichment_queue`

- [ ] **Step 6: Commit** — `git commit -m "Enrichment queue: fill, its job and rake task"`

---

### Task 4: Claiming

**Files:**
- Create: `app/lib/services/enrichment_queue/claim.rb`, `app/lib/services/enrichment_queue/counts.rb`
- Test: `test/lib/services/enrichment_queue/claim_test.rb`, `test/lib/services/enrichment_queue/counts_test.rb`

**Interfaces:**
- Produces:
  - `Services::EnrichmentQueue::Claim.call(kind:, limit: 10, user:) → Result(success?, data: {items: [EnrichmentRequest], lease_token:, lease_expires_at:, remaining:}, errors:)`. `limit` outside 1..25 is a failure Result. With nothing to hand out, `items` is `[]` and `lease_token` is nil.
  - `Claim::MAX_LIMIT = 25`, `Claim::DEFAULT_LIMIT = 10`.
  - `Services::EnrichmentQueue::Counts.call(kind:) → {statuses: {"pending" => n, ...all six keys...}, outcomes: {"applied" => n, ...}}` (`outcomes` counts `done` rows by `outcome`).

- [ ] **Step 1: Write the failing tests**

```ruby
setup do
  Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  @user = users(:admin_user)
  @books = [books_books(:war_and_peace), books_books(:crime_and_punishment), books_books(:got)]
  @rows = @books.each_with_index.map { |book, i| EnrichmentRequest.create!(enrichable: book, kind: "books.test_type", reason: "missing", priority: i) }
end
teardown { EnrichmentQueueTestType.reset! }

def claim(limit: 2) = Services::EnrichmentQueue::Claim.call(kind: "books.test_type", limit: limit, user: @user)

test "hands out the lowest priorities first under one lease token" do
  travel_to Time.zone.parse("2026-11-17 12:00") do
    data = claim.data
    assert_equal @rows.first(2).map(&:id), data[:items].map(&:id)
    assert data[:lease_token].present?
    assert_equal Time.zone.parse("2026-11-17 12:30"), data[:lease_expires_at]
    assert_equal 1, data[:remaining]
    row = @rows.first.reload
    assert_equal ["claimed", data[:lease_token], 1, @user.id], [row.status, row.lease_token, row.attempts, row.claimed_by_id]
  end
end

test "two claims never share an item" do
  first, second = claim.data, claim.data
  assert_empty first[:items].map(&:id) & second[:items].map(&:id)
  assert_not_equal first[:lease_token], second[:lease_token]
end

test "the claim query skips rows another transaction has locked" do
  queries = []
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }
  claim
  assert queries.any? { |sql| sql.include?("FOR UPDATE SKIP LOCKED") }
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber)
end

test "an expired lease is claimable again and counts as an attempt" do
  token = claim(limit: 1).data[:lease_token]
  travel 31.minutes do
    data = claim(limit: 1).data
    assert_equal [@rows.first.id], data[:items].map(&:id)
    assert_not_equal token, data[:lease_token]
    assert_equal 2, @rows.first.reload.attempts
  end
end

test "a row abandoned three times is closed, not handed out a fourth time" do
  @rows.first.update!(status: :claimed, attempts: 3, lease_expires_at: 1.minute.ago)
  ids = claim(limit: 3).data[:items].map(&:id)
  assert_not_includes ids, @rows.first.id
  row = @rows.first.reload
  assert_equal ["skipped", "abandoned", "system"], [row.status, row.outcome, row.resolved_via]
end

test "an item whose gap closed is closed and the batch is topped up" do
  EnrichmentQueueTestType.stubs(:still_needed?).returns(false, true, true)
  data = claim(limit: 2).data
  assert_equal @rows.last(2).map(&:id), data[:items].map(&:id)
  row = @rows.first.reload
  assert_equal ["done", "no_longer_needed", "system"], [row.status, row.outcome, row.resolved_via]
end

test "an empty queue answers no items, no token and nothing remaining" do
  EnrichmentRequest.where(kind: "books.test_type").delete_all
  data = claim.data
  assert_equal [[], nil, 0], data.values_at(:items, :lease_token, :remaining)
end

test "limit must be 1 to 25" do
  assert_not claim(limit: 0).success?
  assert_not claim(limit: 26).success?
end
```

Counts test: three rows (pending, done/applied, done/nothing_to_apply) → `statuses` has all six keys with `"pending" => 1, "done" => 2`, `outcomes == {"applied" => 1, "nothing_to_apply" => 1}`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement `Claim` and `Counts`.** The algorithm, since the tests do not fix it:

```ruby
# Inside one transaction per pass, at most three passes:
ids = ::EnrichmentRequest.for_kind(kind).claimable.order(:priority, :id).limit(needed)
  .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
# 1. rows with attempts >= MAX_ATTEMPTS -> skipped / "abandoned" / system, not handed out
# 2. the rest -> claimed, lease_token (one SecureRandom.uuid per call), lease_expires_at, attempts + 1, claimed_by
# 3. each claimed row: type.still_needed?(row.enrichable) or close it done / "no_longer_needed" / system
# needed = how many were closed in steps 1 and 3; stop when 0 or nothing was picked
```

`remaining` is the count of `claimable` rows after the last pass. A claimed row whose `enrichable` is nil (deleted without the row) is deleted.

- [ ] **Step 4: Run, expect PASS.**

- [ ] **Step 5: Commit** — `git commit -m "Enrichment queue: leased claims and counts"`

---

### Task 5: Submit, skip, apply and re-queue

**Files:**
- Create: `app/lib/services/enrichment_queue/submit.rb`, `skip.rb`, `apply.rb`, `requeue.rb`, `app/sidekiq/enrichment_queue/apply_job.rb` (generator)
- Test: `test/lib/services/enrichment_queue/submit_test.rb`, `skip_test.rb`, `apply_test.rb`, `requeue_test.rb`, `test/sidekiq/enrichment_queue/apply_job_test.rb`

**Interfaces:**
- Consumes: `Type.answer_schema`, `Type.apply(request)`.
- Produces:
  - `Submit.call(request:, lease_token:, answer:, sources:, note: nil, user:, via: "api") → Result`. Failure `errors` is `[{code: :conflict | :invalid, detail: String}]`. Success `data` is `{request:}`.
  - `Skip.call(request:, lease_token:, reason:, user:, via: "api") → Result` with the same error shape.
  - `Apply.call(request_id:) → Result`; raises `Apply::Failed` when the type's apply fails. `Apply.fail!(request_id:, error:)` marks the row `failed`.
  - `Requeue.call(request:, user:) → Result`: any non-open row → `pending`, reason `manual`, cleared as in `Fill`'s re-open.
  - `::EnrichmentQueue::ApplyJob#perform(request_id)`, `sidekiq_options queue: :low, retry: 3`, with `sidekiq_retries_exhausted` calling `Apply.fail!`.
  - `Submit::MAX_ANSWER_BYTES = 50_000`, `MAX_NOTE = 1_000`, `MAX_SOURCES = 20`, `MAX_URL = 2_000`; `Skip::MAX_REASON = 500`.

- [ ] **Step 1: Write the failing tests**

```ruby
# submit_test.rb
setup do
  Services::EnrichmentQueue::Registry.stubs(:types).returns([EnrichmentQueueTestType])
  @user = users(:admin_user)
  @row = EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: "books.test_type", reason: "missing",
    status: :claimed, lease_token: "lease-1", lease_expires_at: 10.minutes.from_now)
end

def submit(**overrides)
  Services::EnrichmentQueue::Submit.call(**{request: @row, lease_token: "lease-1", answer: {"value" => "x"},
    sources: ["https://example.org/a"], note: "found it", user: @user}.merge(overrides))
end

test "stores the answer, marks the row submitted and queues the apply job" do
  Sidekiq::Testing.fake! do
    assert_difference -> { ::EnrichmentQueue::ApplyJob.jobs.size }, 1 do
      assert submit.success?
    end
  end
  @row.reload
  assert_equal ["submitted", {"value" => "x"}, ["https://example.org/a"], "found it", @user.id, "api"],
    [@row.status, @row.answer, @row.sources, @row.note, @row.resolved_by_id, @row.resolved_via]
  assert @row.resolved_at.present?
end

test "a lease taken over by another batch is a conflict and writes nothing" do
  @row.update!(lease_token: "lease-2")
  result = submit
  assert_equal :conflict, result.errors.first[:code]
  assert @row.reload.claimed?
  assert_nil @row.answer
end

test "an expired lease nobody took over is still accepted" do
  @row.update!(lease_expires_at: 1.minute.ago)
  Sidekiq::Testing.fake! { assert submit.success? }
end

test "the same submit twice is accepted once and queues one job" do
  Sidekiq::Testing.fake! do
    submit
    assert_no_difference -> { ::EnrichmentQueue::ApplyJob.jobs.size } do
      assert submit.success?
    end
  end
end

test "a pending, done or skipped row is a conflict" do
  %i[pending done skipped].each do |status|
    @row.update!(status: status)
    assert_equal :conflict, submit.errors.first[:code], status
  end
end

test "an answer that does not match the type's schema is invalid and leaves the row claimed" do
  result = submit(answer: {"value" => 3, "extra" => true})
  assert_equal :invalid, result.errors.first[:code]
  assert @row.reload.claimed?
end

test "sources must be 1 to 20 http or https urls" do
  [[], ["ftp://x"], ["not a url"], ["https://example.org/" + "a" * 2000], Array.new(21) { "https://example.org/#{it}" }].each do |sources|
    assert_equal :invalid, submit(sources: sources).errors.first[:code], sources.inspect.first(40)
  end
end

test "an oversized answer or note is invalid" do
  assert_equal :invalid, submit(answer: {"value" => "x" * 50_001}).errors.first[:code]
  assert_equal :invalid, submit(note: "n" * 1_001).errors.first[:code]
end
```

```ruby
# apply_test.rb (row is submitted, answer {"value" => "x"}; Result = Services::EnrichmentQueue::Type::Result)
test "a successful apply closes the row with the ledger row and its outcome" do
  ledger = Enrichment.create!(enrichable: @row.enrichable, kind: "books.test_type", mode: :knowledge, outcome: :applied, facts: {})
  EnrichmentQueueTestType.apply_result = Result.new(success?: true, data: {enrichment: ledger, outcome: "applied"}, errors: [])
  Services::EnrichmentQueue::Apply.call(request_id: @row.id)
  assert_equal ["done", "applied", ledger.id], @row.reload.then { [it.status, it.outcome, it.enrichment_id] }
end

test "a failing apply raises so the job retries, and the row stays submitted" do
  EnrichmentQueueTestType.apply_result = Result.new(success?: false, data: nil, errors: ["chooser failed"])
  error = assert_raises(Services::EnrichmentQueue::Apply::Failed) { Services::EnrichmentQueue::Apply.call(request_id: @row.id) }
  assert_includes error.message, "chooser failed"
  assert @row.reload.submitted?
end

test "a missing row, or one that is not submitted, is a no-op" do
  assert Services::EnrichmentQueue::Apply.call(request_id: 0).success?
  @row.update!(status: :done)
  EnrichmentQueueTestType.expects(:apply).never
  assert Services::EnrichmentQueue::Apply.call(request_id: @row.id).success?
end

test "fail! marks the row failed with the error, cut to 1,000 characters" do
  Services::EnrichmentQueue::Apply.fail!(request_id: @row.id, error: "x" * 2_000)
  assert_equal ["failed", 1_000], @row.reload.then { [it.status, it.error.length] }
end

test "the acting user and via are set while the type applies" do
  seen = nil
  EnrichmentQueueTestType.stubs(:apply).with { seen = [Current.acting_user, Current.acting_via] }.returns(
    Result.new(success?: true, data: {enrichment: nil, outcome: "applied"}, errors: []))
  Services::EnrichmentQueue::Apply.call(request_id: @row.id)
  assert_equal [@row.resolved_by, "api"], seen
end
```

Skip tests: the right token on a claimed row → `skipped`, `outcome` and `note` are the reason, `resolved_via` `api`; a wrong token → `:conflict`; a blank reason or one over 500 characters → `:invalid`. Requeue tests: a `done`, `skipped` and `failed` row each become `pending` / `manual` with `outcome`, `answer`, `error` cleared; a `claimed` row is a failure. Job tests: `perform` calls `Apply.call(request_id:)`; `::EnrichmentQueue::ApplyJob.sidekiq_retries_exhausted_block.call({"args" => [@row.id]}, StandardError.new("boom"))` leaves the row `failed` with error `"boom"`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement the four services and the job.** `Submit` validates with `JSONSchemer.schema(type.answer_schema)` and reports the first five error messages in `detail`. It updates the row with a guarded `UPDATE ... WHERE id = ? AND status = claimed AND lease_token = ?` so two concurrent submits cannot both queue a job, and queues `::EnrichmentQueue::ApplyJob.perform_async(id)` after the update. `Apply` sets `Current.acting_user` and `Current.acting_via` around the type call and restores them.

- [ ] **Step 4: Run, expect PASS** — `bin/rails test test/lib/services/enrichment_queue test/sidekiq/enrichment_queue`

- [ ] **Step 5: Commit** — `git commit -m "Enrichment queue: submit, skip, apply and re-queue"`

---

### Task 6: The `agent` ledger mode and what counts as done

**Files:**
- Modify: `app/models/enrichment.rb`, `app/lib/services/books/categorize/backfill.rb` (`done_rows`), `app/lib/services/books/categorize/dossier.rb` (`research_backed?`)
- Test: `test/models/enrichment_test.rb`, `test/lib/services/books/categorize/backfill_test.rb`, `test/lib/services/books/categorize/dossier_test.rb`

**Interfaces:**
- Produces: `Enrichment.modes["agent"] == 3`; `Enrichment::WEB_VERIFIED_MODES = %w[research agent]`.

- [ ] **Step 1: Write the failing tests**

```ruby
# backfill_test.rb -- follow the file's existing helper for a done books.origin row
test "an agent row that applied counts as done" do
  book = books_books(:war_and_peace)
  book.enrichments.create!(kind: "books.origin", mode: :agent, outcome: :applied,
    facts: {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "deferred_research" => false})
  assert_not_includes Services::Books::Categorize::Backfill.candidates(scope: "origin_only", book_ids: [book.id]), book
end

test "an agent row that applied nothing does not count as done" do
  book = books_books(:war_and_peace)
  %i[nothing_to_apply unrecognized].each do |outcome|
    book.enrichments.where(kind: "books.origin").delete_all
    book.enrichments.create!(kind: "books.origin", mode: :agent, outcome: outcome,
      facts: {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "deferred_research" => false})
    assert_includes Services::Books::Categorize::Backfill.candidates(scope: "origin_only", book_ids: [book.id]), book, outcome
  end
end

test "a knowledge row that applied nothing still counts as done" do
  # the existing behaviour: guards against the agent rule leaking to other modes
  book = books_books(:war_and_peace)
  book.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply,
    facts: {"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, "deferred_research" => false})
  assert_not_includes Services::Books::Categorize::Backfill.candidates(scope: "origin_only", book_ids: [book.id]), book
end
```

Dossier test: a book whose latest `books.book_facts` row has mode `agent` and `recognized: true` is `research_backed?`; with mode `knowledge` it is not. Enrichment test: an `agent` row is not in `Enrichment.research` and not in `Enrichment.against_research_cap`.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement.** Add `agent: 3` to the mode enum. In `done_rows` add the condition "mode is not agent, or outcome is applied". In `research_backed?` test `WEB_VERIFIED_MODES`. Then `grep -rn "research" app lib --include=*.rb` for every other read of the research mode and confirm each asks "did we pay for a search?" (leave it) rather than "was this web-verified?" (use the constant). List the ones you checked in the commit message.

- [ ] **Step 4: Run, expect PASS** — the three test files plus `bin/rails test test/lib/services/books/categorize test/lib/services/books/origin test/lib/services/books/categories`

- [ ] **Step 5: Commit** — `git commit -m "Enrichment: agent mode; a held agent answer is not done for the paced backfill"`

---

### Task 7: The `books.origin` type

**Files:**
- Create: `app/lib/services/books/origin/record_answer.rb`, `app/lib/services/books/queue_types/book_scope.rb`, `app/lib/services/books/queue_types/origin.rb`
- Modify: `app/lib/services/books/origin/judge.rb` (delegate), `app/lib/services/enrichment_queue/registry.rb` (`TYPE_NAMES`)
- Test: `test/lib/services/books/origin/record_answer_test.rb`, `test/lib/services/books/queue_types/origin_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::Origin::RecordAnswer.call(book:, dossier:, answer:, mode:, context:, label:, citations: [], ai_chat: nil, provider: nil, model: nil, extra_facts: {}) → Enrichment`. `answer` is a symbol-keyed Hash with `:recognized, :original_language, :nationality, :confidence, :reason`. It decides `unrecognized`, calls `Origin::Apply`, and creates the `books.origin` row exactly as `Judge#run` does today (same `facts` keys, same outcome and reason).
  - `Services::Books::QueueTypes::BookScope` (module, `extend`ed by the types): `ranked_join_sql` (the LEFT JOIN on `ranked_items` for `::Books::RankingConfiguration.default_primary`, as in `Backfill.candidates`), `base_relation(scope:)` (books with a non-blank title, no running `books.book_enrichment` or `books.book_categorize` run, joined to the rank; `scope: "ranked"` keeps only ranked books), `priority_sql` (`"COALESCE(ranked_items.rank, 1000000)"`), `tried(book, kind)` (the latest ledger row of that kind as `{"mode", "outcome", "reason", "confidence", "answer"}`, or nil).
  - `Services::Books::QueueTypes::Origin < Services::EnrichmentQueue::Type`: `kind "books.origin"`, `label "Book origin"`, `version` = `BookOriginTask::PROMPT_VERSION`.

- [ ] **Step 1: Write the failing `RecordAnswer` tests**

```ruby
setup do
  @book = ::Books::Book.create!(title: "Untitled Origin Test")
  @dossier = Services::Books::Categorize::Dossier.build(book: @book)
end

def record(answer, mode: :agent)
  Services::Books::Origin::RecordAnswer.call(book: @book, dossier: @dossier, answer: answer, mode: mode,
    context: "agent", label: "agent", citations: [{"url" => "https://example.org/a"}], provider: "agent")
end

test "a high answer is written and recorded" do
  row = record({recognized: true, original_language: "Japanese", nationality: "Japanese", confidence: "high", reason: "r"})
  assert_equal ["agent", "applied", "filled", "high"], [row.mode, row.outcome, row.reason, row.confidence]
  assert_equal ["Japanese"], @book.countries.reload.pluck(:name)
  assert_equal ["agent", "agent", "judge", false], row.facts.values_at("context", "label", "path", "deferred_research")
  assert_equal Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION, row.facts["prompt_version"]
  assert_equal [{"url" => "https://example.org/a"}], row.citations
end

test "a medium answer with no stored evidence is held" do
  row = record({recognized: true, original_language: nil, nationality: "Japanese", confidence: "medium", reason: "r"})
  assert_equal ["nothing_to_apply", "unsupported"], [row.outcome, row.reason]
  assert_empty @book.countries.reload
end

test "a nationality that matches no country applies nothing and does not raise" do
  row = record({recognized: true, original_language: nil, nationality: "Atlantean", confidence: "high", reason: "r"})
  assert_equal ["nothing_to_apply", "no_match"], [row.outcome, row.reason]
end

test "a held country is never overwritten" do
  @book.book_countries.create!(country: ::Books::Country.find_by!(name: "French"))
  dossier = Services::Books::Categorize::Dossier.build(book: @book)
  row = Services::Books::Origin::RecordAnswer.call(book: @book, dossier: dossier,
    answer: {recognized: true, original_language: nil, nationality: "Japanese", confidence: "high", reason: "r"},
    mode: :agent, context: "agent", label: "agent")
  assert_equal "already_set", row.reason
  assert_equal ["French"], @book.countries.reload.pluck(:name)
end

test "not recognized with no evidence is an unrecognized row" do
  row = record({recognized: false, original_language: nil, nationality: "Unknown", confidence: "low", reason: "r"})
  assert_equal "unrecognized", row.outcome
end
```

(A `Books::Country` is named by its nationality adjective: the fixtures hold "French", "Japanese", "Algerian" and the placeholder "Unknown".)

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Extract `RecordAnswer` from `Origin::Judge#run`** and make `run` call it with the task's answer, citations and chat. `Judge` keeps the task call, the empty-response and failed rows, and `row_needs_research?`.

- [ ] **Step 4: Run the judge's existing tests unmodified, plus the new ones**

Run: `bin/rails test test/lib/services/books/origin`
Expected: PASS with no change to `judge_test.rb`. That file is the proof the paid path did not move.

- [ ] **Step 5: Write the failing type tests**

```ruby
Type = Services::Books::QueueTypes::Origin

setup do
  @blank = ::Books::Book.create!(title: "No Country Yet")
  @placed = ::Books::Book.create!(title: "Has A Country")
  @placed.book_countries.create!(country: ::Books::Country.find_by!(name: "French"))
end

test "candidates are titled books with no real country" do
  ids = Type.candidates(scope: "all").pluck(:id)
  assert_includes ids, @blank.id
  assert_not_includes ids, @placed.id
end

test "a book holding only a placeholder country is still a candidate" do
  @blank.book_countries.create!(country: ::Books::Country.find_or_create_by!(name: "Unknown"))
  assert_includes Type.candidates(scope: "all").pluck(:id), @blank.id
end

test "a book with a running enrichment or categorize run is left out" do
  [::Workflows::Books::BookEnrichment.workflow, ::Workflows::Books::BookCategorize.workflow].each do |workflow|
    run = WorkflowRun.create!(workflow: workflow, definition_version: 1, enrichable: @blank, status: :running, initiated_by: "test")
    assert_not_includes Type.candidates(scope: "all").pluck(:id), @blank.id, workflow
    run.destroy!
  end
end

test "ranked scope keeps only ranked books and priority is the rank" do
  ranked = RankedItem.where(item_type: "Books::Book", ranking_configuration: ::Books::RankingConfiguration.default_primary).first!
  ranked.item.book_countries.destroy_all
  rows = Type.candidates(scope: "ranked").pluck(Arel.sql("books_books.id"), Arel.sql(Type.priority_sql))
  assert_includes rows, [ranked.item_id, ranked.rank]
  assert_not_includes rows.map(&:first), @blank.id
end

test "still_needed? follows the data" do
  assert Type.still_needed?(@blank)
  assert_not Type.still_needed?(@placed)
end

test "payload carries the record, the stored evidence and what was tried" do
  @blank.enrichments.create!(kind: "books.origin", mode: :knowledge, outcome: :nothing_to_apply, reason: "low_confidence",
    confidence: :low, facts: {"answer" => {"nationality" => "Japanese", "confidence" => "low"}})
  payload = Type.payload(@blank)
  assert_equal @blank.id, payload["book_id"]
  assert_equal "No Country Yet", payload["record"]["title"]
  assert_equal %w[book_facts goodreads wikidata wikipedia worldcat], payload["evidence"].keys.sort
  assert_equal ["knowledge", "nothing_to_apply", "low_confidence"], payload["tried"].values_at("mode", "outcome", "reason")
end

test "reference carries the answer schema and it accepts a well-formed answer" do
  schema = JSONSchemer.schema(Type.reference["answer_schema"])
  assert schema.valid?({"recognized" => true, "original_language" => nil, "nationality" => "Japanese", "confidence" => "high", "reason" => "r"})
  assert_not schema.valid?({"nationality" => "Japanese"})
end

test "apply writes the country and an agent ledger row from the request" do
  request = EnrichmentRequest.create!(enrichable: @blank, kind: "books.origin", reason: "missing", status: :submitted,
    answer: {"recognized" => true, "original_language" => "Japanese", "nationality" => "Japanese", "confidence" => "high", "reason" => "r"},
    sources: ["https://example.org/a"], resolved_by: users(:admin_user))
  result = Type.apply(request)
  assert result.success?
  assert_equal "applied", result.data[:outcome]
  row = result.data[:enrichment]
  assert_equal ["books.origin", "agent", "agent", request.id], [row.kind, row.mode, row.provider, row.facts["queue_request_id"]]
  assert_equal ["https://example.org/a"], row.citations.map { it["url"] }
end

test "is registered" do
  assert_equal Type, Services::EnrichmentQueue::Registry.fetch("books.origin")
end
```

- [ ] **Step 6: Run, expect FAIL.**

- [ ] **Step 7: Implement `BookScope` and `Origin`.** `candidates` is `base_relation(scope:).where(Backfill.no_real_country_sql)`. `still_needed?` runs the same SQL for one id, so the two can never disagree. `payload` is `{"book_id", "record" => dossier.record, "evidence" => dossier.to_ledger.slice("book_facts", "wikidata", "wikipedia", "worldcat", "goodreads"), "tried" => tried(book, kind)}`. `answer_schema` is `BookOriginTask::ResponseSchema.to_json_schema` (a **class** method). `apply` builds the dossier, calls `RecordAnswer` with mode `:agent`, context and label `"agent"`, citations in the shape `OpenaiStrategy#extract_citations` returns, `provider: "agent"`, `extra_facts: {"queue_request_id" => request.id}`, and returns the row and `row.outcome`; a failed row is a failure Result. Add the class name to `Registry::TYPE_NAMES`.

- [ ] **Step 8: Run, expect PASS** — `bin/rails test test/lib/services/books/origin test/lib/services/books/queue_types test/lib/services/enrichment_queue`

- [ ] **Step 9: Commit** — `git commit -m "Enrichment queue: books.origin type on the shared origin answer path"`

---

### Task 8: The `books.categories` type

**Files:**
- Create: `app/lib/services/books/categories/record_answer.rb`, `app/lib/services/books/queue_types/categories.rb`
- Modify: `app/lib/services/books/categories/judge.rb` (delegate; expose the vocabulary), `registry.rb`
- Test: `test/lib/services/books/categories/record_answer_test.rb`, `test/lib/services/books/queue_types/categories_test.rb`

**Interfaces:**
- Consumes: `BookScope`, `Categories::Mapper.call(book:, answer:, vocabulary:)`, `Categories::Apply.call(book:, dossier:, answer:, resolved:, rejudge:, unmatched:)`.
- Produces:
  - `Services::Books::Categories::Judge.vocabulary → [::Books::Category]` (public class method holding the query now in `Judge#call`).
  - `Services::Books::Categories::RecordAnswer.call(book:, dossier:, answer:, vocabulary:, mode:, context:, label:, rejudge:, citations: [], ai_chat: nil, provider: nil, model: nil, extra_facts: {}) → Enrichment`. Normalises confidences, decides `unrecognized`, maps, applies and creates the `books.categories` row with today's `facts` keys. A mapper failure or a raise yields a `failed` row that still carries any `mapping`/`apply` already committed.
  - `Services::Books::QueueTypes::Categories`: `kind "books.categories"`, `label "Book categories"`, `version` = `BookCategoriesTask::PROMPT_VERSION`.

- [ ] **Step 1: Write the failing `RecordAnswer` tests.** Build the answer with a helper that fills every required key (`recognized`, `confidence`, `book_type`, `genres`, `audience`, `subjects`, `locations`, `unlisted_genres`). Stub `Services::Ai::Tasks::Books::CategoryChoiceTask` so no chooser call leaves the test. Cases, each asserting the row's `mode`, `outcome` and the book's direct `CategoryItem`s:
  - a `high` genre id from the vocabulary → linked with source `ai`, outcome `applied`, `facts["label"] == "agent"`;
  - a genre id not in the vocabulary → nothing linked, the entry is in `facts["mapping"]["unmatched"]` with reason `invalid_id`, outcome `nothing_to_apply`, no raise;
  - a sixth genre when the book already holds five → held back `cap`;
  - with `rejudge: false`, a `legacy` genre link the answer did not pick is still there afterwards;
  - `unlisted_genres` are stored under `facts["answer"]`;
  - a mapper failure (`Mapper.stubs(:call).returns(Mapper::Result.new(success?: false, errors: ["x"]))`) → a `failed` row.

- [ ] **Step 2: Run, expect FAIL. Step 3: Extract `RecordAnswer` and `Judge.vocabulary`**; `Judge#run` keeps the task call and passes `rejudge: context != "import"`. **Step 4: Run** `bin/rails test test/lib/services/books/categories` — PASS with `judge_test.rb` unmodified.

- [ ] **Step 5: Write the failing type tests**, mirroring Task 7's:
  - candidates are titled books with no direct genre beyond Fiction/Nonfiction (a book holding only Fiction is a candidate; a book holding a real genre is not; an `inherited` genre link does not count as holding one);
  - the running-run exclusion and the ranked scope;
  - `still_needed?`;
  - `payload` has `"record"` with the held `"categories"` and their sources;
  - `reference` has `"answer_schema"`, `"genres"` and `"audiences"` as `[{"id", "name", "definition"}]` from `Judge.vocabulary`, with Fiction and Nonfiction absent, and `"caps" => {"genres" => 5, "subjects" => 8, "locations" => 5}`;
  - `apply` on a submitted request links a `high` genre, writes an `agent` ledger row with `queue_request_id`, and removes nothing;
  - `apply` works with `Rails.application.config.x.ai.categories_judge_enabled` false (stub it): the switch gates only the automatic judge;
  - `apply` returns a failure Result when the row is `failed`;
  - the type is registered.

- [ ] **Step 6: Implement the type.** `candidates` is `base_relation(scope:).where(Backfill.no_genre_sql)`. `apply` always passes `rejudge: false`.

- [ ] **Step 7: Run, expect PASS** — `bin/rails test test/lib/services/books/categories test/lib/services/books/queue_types`

- [ ] **Step 8: Commit** — `git commit -m "Enrichment queue: books.categories type on the shared categories answer path"`

---

### Task 9: The admin API and the MCP tools

**Files:**
- Create: `app/controllers/api/v1/admin/books/enrichment_queues_controller.rb`, `enrichment_items_controller.rb`, `app/lib/api/v1/admin/enrichment_queue_resource.rb`, `enrichment_item_resource.rb`
- Modify: `config/routes.rb` (the admin API block, after the repair verdict routes), `config/api/v1/admin_openapi.yaml`, `config/mcp/books/admin_usage.md`
- Test: `test/controllers/api/v1/admin/books/enrichment_queues_controller_test.rb`, `enrichment_items_controller_test.rb`; modify `test/lib/mcp/admin_catalog_test.rb`, `test/lib/mcp/tool_directory_test.rb`, `test/integration/api/v1/admin_contract_coverage_test.rb`, `test/lib/mcp/sites/books_test.rb`

**Interfaces:**
- Consumes: `Registry.for_domain/find`, `Counts`, `Claim`, `Submit`, `Skip`.
- Produces these routes and JSON:

| Operation | Route | Scope | Success |
|---|---|---|---|
| `listEnrichmentQueues` | `GET /api/v1/admin/enrichment_queues` | `books:admin:read` | 200 `{data: [{type, kind, label, version, counts}]}` |
| `getEnrichmentQueue` | `GET /api/v1/admin/enrichment_queues/{type}` | `books:admin:read` | 200 `{data: {type, kind, label, version, counts, outcomes, reference}}` |
| `claimEnrichmentItems` | `POST /api/v1/admin/enrichment_queues/{type}/claims` body `{limit}` | `books:admin:write` | 200 `{data: [{id, kind, reason, attempts, payload}], meta: {lease_token, lease_expires_at, remaining}}` |
| `submitEnrichmentItem` | `POST /api/v1/admin/enrichment_items/{id}/submit` body `{lease_token, answer, sources, note}` | `books:admin:write` | 202 `{data: {id, status}}` |
| `skipEnrichmentItem` | `POST /api/v1/admin/enrichment_items/{id}/skip` body `{lease_token, reason}` | `books:admin:write` | 200 `{data: {id, status}}` |

  `{type}` is the kind's slug, constrained to `/[a-z_]+/`. `counts` has all six status keys. Errors: unknown type or id 404; `limit` not an integer 1..25, `lease_token` missing or not a string, `answer` not an object, `sources` not an array of strings → 400; `:conflict` → 409; `:invalid` → 422; an account that may not change books (`::Books::BookPolicy#update?`, as the repair verdicts controller checks) → 403. Each write logs `event=api_admin_enrichment_<claim|submit|skip>` with the item or type, `user_id` and `token_id`.

- [ ] **Step 1: Write the failing controller tests.** Follow `repair_verdicts_controller_test.rb` (`host! "dev-new.thegreatestbooks.org"`, `bearer(ApiTokenSecrets::ADMIN)` for writes, `ADMIN_READ` for reads, `assert_api_response_conform(status:, api: :admin)`). Use the real `books.origin` type with a countryless book. Cases:
  - list → both types, six count keys each, conforms;
  - show `origin` → `reference.answer_schema` present; show `nope` → 404;
  - claim with `ADMIN_READ` → 403; with `ADMIN` → 200, one item whose `payload.record.title` is the book's, `meta.lease_token` present, `meta.remaining` 0;
  - claim on an empty queue → 200, `data: []`, `meta.lease_token` null;
  - claim `limit: 26`, `limit: "5"` → 400;
  - submit a valid answer → 202, `status: "submitted"`, and (Sidekiq inline) the book now has the country and the row is `done`;
  - submit with a wrong token → 409 and the book has no country;
  - submit an answer missing `nationality` → 422 and the row is still `claimed`;
  - submit with `sources: []` → 422; with `answer: "x"` or no `lease_token` → 400;
  - submit an answer over 50,000 bytes → 422 and nothing stored;
  - submit after the book was destroyed → 404;
  - skip → 200 `status: "skipped"`; skip with a blank reason → 422;
  - every write with `MEMBER` → 403 and without a token → 401.

- [ ] **Step 2: Run, expect FAIL (routing errors).**

- [ ] **Step 3: Add the routes, controllers and resources.** `require_scopes` per action as in the table. The controllers hold no queue logic: they parse, call the service, map the Result.

- [ ] **Step 4: Add the five operations to `admin_openapi.yaml`** under `x-domain: books`, with schemas `AdminEnrichmentQueueCollection`, `AdminEnrichmentQueueDetail`, `AdminEnrichmentClaim`, `AdminEnrichmentItemStatus` and request bodies `AdminEnrichmentClaimRequest`, `AdminEnrichmentSubmitRequest`, `AdminEnrichmentSkipRequest`. `answer`, `payload` and `reference` are `type: object` with `additionalProperties: true`. No operation is `destructive`. The `x-mcp` descriptions:

  - `list_enrichment_queues`: "Lists the enrichment queues: each type with how many items are pending, claimed, submitted, done, skipped and failed. A queue is empty when pending and claimed are both 0. Use the `type` value with the other enrichment tools."
  - `get_enrichment_queue`: "Returns one queue `type` with its counts, the outcome counts of finished items, and `reference`: the JSON schema an answer must match (`answer_schema`) and any closed list the answer must choose from. Call it once before working a queue, and again at the end to report the counts."
  - `claim_enrichment_items`: "Claims up to `limit` (1 to 25, default 10) pending items of queue `type` for 30 minutes and returns them, highest priority first. Each item has an integer `id` and a `payload`: the record as we hold it, any stored evidence, and what the pipeline already tried. `meta.lease_token` must be sent with every submit or skip for these items. Nobody else is given these items while the lease lasts; an item neither submitted nor skipped returns to the queue afterwards. An empty `data` with `meta.remaining` 0 means the queue is done. Research each item, then call submit_enrichment_item or skip_enrichment_item."
  - `submit_enrichment_item`: "Submits the answer for claimed item `id`: `lease_token` from the claim, `answer` matching the queue's `answer_schema`, `sources` (1 to 20 URLs you actually used) and an optional `note`. The answer is applied in the background by the catalogue's own rules: it fills blanks only, never overwrites, and holds back anything below high confidence, so say high only when a source states the fact. A 422 names what is wrong with the answer; fix it and submit again. A 409 means the lease was lost to another worker: drop the item. Returns the item's status, not what was applied."
  - `skip_enrichment_item`: "Closes claimed item `id` without an answer: `lease_token` and a `reason` (up to 500 characters) saying what you looked for and why nothing could be settled. A skipped item is not handed out again, so skip only after a real search."

- [ ] **Step 5: Update the pins.** `admin_catalog_test.rb`: tool count 59 → 64, add the five names, `DESTRUCTIVE` unchanged; add a test that `submit_enrichment_item`'s input schema has `answer` as an object property and `additionalProperties: false` at the top level only. `tool_directory_test.rb`: admin 59 → 64. `admin_contract_coverage_test.rb`: one `EXERCISES` entry per documented response of the five operations.

- [ ] **Step 6: Add "The enrichment queues" to `config/mcp/books/admin_usage.md`** and assert its key sentence in `test/lib/mcp/sites/books_test.rb`:

  > ## The enrichment queues
  >
  > `list_enrichment_queues`, `get_enrichment_queue`, `claim_enrichment_items`, `submit_enrichment_item` and `skip_enrichment_item` work a queue of records that need research. You decide each item yourself; do not ask before submitting or skipping. Submitting never overwrites a value the catalogue holds. Work only the items you claimed, and send their `lease_token` back.

- [ ] **Step 7: Run** — `bin/rails test test/controllers/api test/lib/mcp test/integration/api` → PASS.

- [ ] **Step 8: Commit** — `git commit -m "Admin API and MCP tools for the enrichment queues"`

---

### Task 10: The copy prompts

**Files:**
- Create: `config/mcp/books/prompts/enrichment/origin.md.erb`, `config/mcp/books/prompts/enrichment/categories.md.erb`
- Modify: `app/lib/services/agent_prompts.rb`, `app/lib/services/ai/tasks/books/book_origin_task.rb`, `book_categories_task.rb`, both queue types (`prompt_locals`)
- Test: `test/lib/services/agent_prompts_test.rb`

**Interfaces:**
- Produces:
  - `Services::AgentPrompts.for_enrichment(type) → String or nil`: renders `config/mcp/<type.domain>/prompts/enrichment/<type.slug>.md.erb` with `mcp_url`, `type` (the slug), `label`, `pending` (the pending count) and `type.prompt_locals`; nil when the file is missing.
  - `BookOriginTask::RULES` and `BookCategoriesTask::RULES`: frozen strings. Origin: from "Rules, in order:" through the last example line. Categories: the six "- " bullets under "Give:". Each task's system message interpolates its constant; **the rendered message must not change by a character and `PROMPT_VERSION` stays**.
  - `Origin.prompt_locals → {rules: BookOriginTask::RULES}`; `Categories.prompt_locals → {rules: BookCategoriesTask::RULES}`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "the origin enrichment prompt carries the url, the pending count, the loop and the task's rules" do
  book = ::Books::Book.create!(title: "Pending Origin")
  EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
  prompt = Services::AgentPrompts.for_enrichment(Services::Books::QueueTypes::Origin)
  assert_includes prompt, "/api/mcp/admin"
  assert_includes prompt, "1 pending"
  %w[get_enrichment_queue claim_enrichment_items submit_enrichment_item skip_enrichment_item].each { assert_includes prompt, it }
  assert_includes prompt, Services::Ai::Tasks::Books::BookOriginTask::RULES
end

test "the categories enrichment prompt carries the task's rules" do
  prompt = Services::AgentPrompts.for_enrichment(Services::Books::QueueTypes::Categories)
  assert_includes prompt, Services::Ai::Tasks::Books::BookCategoriesTask::RULES
  assert_includes prompt, "claim_enrichment_items"
end

test "a type with no prompt file has no prompt" do
  assert_nil Services::AgentPrompts.for_enrichment(EnrichmentQueueTestType)
end
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Extract the two `RULES` constants and run the task tests** (`bin/rails test test/lib/services/ai/tasks/books`) — they must pass unmodified.

- [ ] **Step 4: Implement `for_enrichment` and write the prompt files.** `origin.md.erb`:

```
You are filling in the country of origin for books on The Greatest Books, using the admin MCP server at <%= mcp_url %>. The "<%= type %>" enrichment queue holds <%= pending %> pending books that have no origin country. Work through all of them.

How to work the queue:

1. Call get_enrichment_queue with type "<%= type %>" once. `reference.answer_schema` is the exact shape of an answer.
2. Call claim_enrichment_items with type "<%= type %>". Keep `meta.lease_token`.
3. For each item, read its `payload`: `record` is the book as we hold it, `evidence` is what Wikidata, Wikipedia, WorldCat and Goodreads said when we have it, and `tried` is what our own model already answered. Then research the book with your own web search.
4. Call submit_enrichment_item with the item's id, the lease token, your answer and the URLs you actually used as `sources`. If you cannot settle it, call skip_enrichment_item and say what you looked for.
5. Claim again. Stop when a claim returns no items.

Use sub-agents if you have them: each one runs steps 2 to 5 by itself. Two workers are never given the same book.

Deciding the origin, the same rules our own model follows:

<%= rules %>

About confidence. Only a high-confidence answer is written; anything lower is recorded and held. Say high only when a source you found states the book's original language and the author's nationality. Do not say high to get an answer through. If the honest answer is "Unknown" or "Multiple", skip the item and say why.

Submitting never overwrites a country the book already has. You are authorised to act without asking me.

When you finish, call get_enrichment_queue once more and report its counts, then list the books you skipped with one line each.
```

`categories.md.erb` has the same structure with these differences: the opening sentence says "genres, audience, subjects and locations for books that have no genre"; step 1 adds "`reference.genres` and `reference.audiences` are the only genres and audiences that exist: answer with their ids, never a name of your own"; the rules block is `<%= rules %>`; the confidence paragraph says "each genre, subject and location carries its own confidence; only high ones are written, and a subject or place that matches nothing in the catalogue is recorded and not created"; and it ends with the same reporting paragraph. Keep the caps sentence: "At most 5 genres, 8 subjects and 5 locations".

- [ ] **Step 5: Run, expect PASS** — `bin/rails test test/lib/services/agent_prompts_test.rb test/lib/services/ai/tasks/books`

- [ ] **Step 6: Commit** — `git commit -m "Copy prompts for the origin and categories queues, sharing the tasks' rules"`

---

### Task 11: The admin page

**Files:**
- Create: `app/controllers/admin/enrichment_queues_base_controller.rb`, `app/controllers/admin/books/enrichment_queues_controller.rb`, `app/views/admin/enrichment_queues_base/index.html.erb`, `show.html.erb`, `e2e/tests/books/admin/enrichment-queues.spec.ts`
- Modify: `config/routes.rb` (the books admin namespace, after `repair_verdicts`), `app/lib/admin/domain_nav.rb`
- Test: `test/controllers/admin/books/enrichment_queues_controller_test.rb`

**Interfaces:**
- Consumes: `Registry.for_domain/find`, `Counts`, `AgentPrompts.for_enrichment`, `::EnrichmentQueue::FillJob`, `Requeue`.
- Produces routes (helpers prefixed `admin_books_`):

```ruby
resources :enrichment_queues, only: [:index, :show], param: :type do
  member { post :fill }
end
post "enrichment_requests/:id/requeue", to: "enrichment_queues#requeue", as: :requeue_enrichment_request, constraints: {id: /\d+/}
```

  The base controller follows `Admin::DuplicateCandidatesBaseController`: `include Admin::DomainScopedAuth`, the subclass supplies `domain` and `route_prefix`, and `fill` and `requeue` sit behind `require_domain_write!`.

- [ ] **Step 1: Write the failing controller tests** (follow an existing `test/controllers/admin/books/*_controller_test.rb` for host and `sign_in_as(@user, stub_auth: true)`):
  - index is 200 for an admin and lists without error when no rows exist;
  - show `origin` is 200; show `nope` is 404;
  - show with `status=done` and `via=api` filters is 200;
  - `POST fill` with `scope=ranked`, `limit=50` queues `::EnrichmentQueue::FillJob` with `["books.origin", "ranked", 50]` (assert inside `Sidekiq::Testing.fake!`) and redirects to the index; a blank limit queues `nil`; an unknown scope redirects with an alert and queues nothing;
  - `POST requeue` on a `done` row makes it `pending` and redirects back to the type's page; on a `claimed` row it redirects with an alert and changes nothing;
  - a viewer without write access gets the refusal the other admin write actions give for `fill` and `requeue`;
  - `assert_no_frame_trapped_links` on index and show.

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Implement the controllers, routes and nav entry** (`{label: "Enrichment Queues", icon: :list, path: -> { URL_HELPERS.admin_books_enrichment_queues_path }}` after Repair Verdicts in the books list).

- [ ] **Step 4: Write the views.**
  - **Index:** a `table` with one row per type: label (links to show), the six counts, a Copy prompt button built exactly like the repair verdicts page's (`data-controller="clipboard-copy"`, hidden textarea, `data-testid="copy-agent-prompt-<slug>"`), and a Fill form (`select` for scope ranked/all, a number `input` for limit, a submit button `data-testid="fill-<slug>"`). One line under the heading: "Filling adds records that need this enrichment and have never been queued. Finished items are not queued again."
  - **Show:** status tabs with counts, `via` filter, a paged table (50 a page; newest `resolved_at` first on resolved tabs, `priority` then `id` on pending): the record linked to its admin page, reason, status, outcome, note, sources as links, who and when, and a Re-queue button on done, skipped and failed rows. Failed rows show `error`. User text gets `overflow-wrap: anywhere`.
  - Preload `enrichable`, `resolved_by` and `claimed_by`; no query per row.

- [ ] **Step 5: Run the controller tests, expect PASS**, then `yarn build:all`.

- [ ] **Step 6: Write the E2E spec**

```ts
import { test, expect } from "@playwright/test";

test.describe("Books admin — enrichment queues", () => {
  test("lists the queues and copies the origin prompt", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/enrichment_queues");
    await expect(page.getByRole("heading", { name: "Enrichment queues" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Book origin" })).toBeVisible();

    await page.getByTestId("copy-agent-prompt-origin").click();
    await expect(page.getByTestId("copy-agent-prompt-origin")).toHaveText("Copied!");
    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("/api/mcp/admin");
    expect(text).toContain("claim_enrichment_items");
  });

  test("opens a queue's items", async ({ page }) => {
    await page.goto("/admin/enrichment_queues");
    await page.getByRole("link", { name: "Book categories" }).click();
    await expect(page.getByRole("heading", { name: "Book categories" })).toBeVisible();
  });
});
```

The spec does not press Fill: that would queue a job against the shared development database.

- [ ] **Step 7: Run the E2E spec.** First confirm port 3000 is this worktree's:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If it prints another checkout, stop and tell Shane; do not kill it or use another port. If free: `bin/rails server` in the background, then `yarn test:e2e e2e/tests/books/admin/enrichment-queues.spec.ts` → 2 passed.

- [ ] **Step 8: Commit** — `git commit -m "Admin page for the enrichment queues: counts, copy prompt, fill, re-queue"`

---

### Task 12: Documentation and the launch steps

**Files:**
- Create: `docs/features/enrichment-queue.md`
- Modify: `docs/features/mcp-server.md`, `docs/features/books_enrichment.md`, `docs/launch-todo.md` (section 14), `AGENTS.md` only if a convention changed (it did not)

- [ ] **Step 1: Write `docs/features/enrichment-queue.md`:** what the queue is and why, the table and statuses, how a row moves (fill, claim, submit, apply, skip, re-queue), what re-opens a row, how to add a type (the `Type` interface, `Registry::TYPE_NAMES`, a prompt file), the two books types and their candidate rules, the five tools, the admin page, the rake task, and how the queue and the paced backfill see each other. Plain prose, no per-class file.

- [ ] **Step 2: Update the other docs.** `mcp-server.md`: a section "The enrichment queues" (the five tools, the exemption from ask-first, tool count 64). `books_enrichment.md`: the `agent` mode in the ledger section, `facts["label"] = "agent"`, `queue_request_id`, and that an agent row that applied nothing is not done for the backfill.

- [ ] **Step 3: Add the steps to `docs/launch-todo.md` section 14**, before the paced backfill step, as the spec's section 9 lists them: after section 12's apply and section 15 step 11; categories only after the definitions (step 2); `bin/rails "enrichment_queue:fill[books.origin,ranked]"` (or the page's Fill), Copy prompt, paste into the agent, let it run to empty; the same for `books.categories`; then `books:origin:report[agent]`, `books:categories:report[agent]` and `books:categories:add_aliases[agent]`; then the paced backfill for what is left.

- [ ] **Step 4: Commit** — `git commit -m "Docs: enrichment queue feature doc, MCP and enrichment docs, launch steps"`

---

### Task 13: Whole-branch verification

- [ ] **Step 1:** `bin/rails test` → 0 failures, 0 errors, no new warning lines.
- [ ] **Step 2:** `bundle exec standardrb` → clean.
- [ ] **Step 3:** `CI=1 bin/rails zeitwerk:check` → "All is good!".
- [ ] **Step 4:** `bin/rails db:migrate:status | tail -5` → the new migration is `up`; `git diff main -- web-app/db/schema.rb` shows only `enrichment_requests` and its foreign keys.
- [ ] **Step 5:** Re-run the two E2E specs that touch what changed: `enrichment-queues.spec.ts` and `repair-verdicts-copy-prompt.spec.ts`.
- [ ] **Step 6:** Report to Shane: the branch is unpushed, what was built, the test counts, and anything a reviewer flagged that was left open. Do not push or open a PR without his say-so.
