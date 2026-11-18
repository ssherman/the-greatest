# Agent Enrichment Queue, Increment 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two more queue types (`books.book_facts`, `books.author_facts`), a switch that sends every would-be web search to the queue instead of the paid API, and a rake task that works a queue through the paid API.

**Architecture:** The "answer in, ledger row out" half of `EnrichBook` and `EnrichAuthor` is extracted (as increment 1 did for the two judges) so the paid path and the agent path share it. A small router, `Services::EnrichmentQueue::ResearchRoute`, reads `config.x.ai.research_via`; the four places that spend a web search ask it, and in `queue` mode record today's deferral and insert a `pending` queue row. The paid worker is one Sidekiq job per row: each job claims one row, runs the type's `research` (the existing research-mode run, forced) and closes the row.

**Tech Stack:** Rails 8, Postgres, Sidekiq, Minitest + fixtures + Mocha, `json_schemer`, Playwright. No migration.

**Spec:** `docs/superpowers/specs/2026-11-17-agent-enrichment-queue-design.md`, section 10 (and sections 2, 5, 7 and 12 for the rules every type follows). Increment 1 is merged (PR #513); read `docs/features/enrichment-queue.md` for what exists. Executors read both.

## Global Constraints

- Run Rails and yarn commands from `web-app/`. Docs live in `docs/` at the project root.
- Work on branch `agent-enrichment-queue-inc2` in the worktree `.claude/worktrees/agent-enrichment-queue`. Commit after every task. Never commit to `main`, never push or open a PR without Shane's say-so.
- Jobs come from the generator: `bin/rails generate sidekiq:job enrichment_queue/research` (never `generate job`). Jobs live in `app/sidekiq/`, services in `app/lib/services/`.
- No migration in this increment. If a task seems to need one, stop and report.
- Never run a destructive command against the development database. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
- Lint with `bundle exec standardrb` (not rubocop). Do not run brakeman.
- Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Namespace shadowing.** Inside `module Services`, a bare `Books::` is `Services::Books::` and a bare `EnrichmentQueue::` is `Services::EnrichmentQueue::`. Root-anchor models and jobs: `::Books::Book`, `::Books::Author`, `::EnrichmentRequest`, `::Enrichment`, `::EnrichmentQueue::ResearchJob`.
- **The paid paths must not change in `api` mode.** `config.x.ai.research_via` defaults to `"api"`. Every existing test in `enrich_book_test.rb`, `enrich_author_test.rb`, `origin/judge_test.rb`, `categories/judge_test.rb`, `research_budget_test.rb` and `backfill_test.rb` passes **unmodified**; this plan only adds tests to those files. If an existing test has to change, stop and report it.
- Tests switch mode with `Rails.application.config.x.ai.stubs(:research_via).returns("queue")` (the same way the files stub `research_daily_cap`).
- Minitest 6: `assert_nil`, never `assert_equal nil`. Stub every model call with Mocha. Sidekiq runs inline in tests; wrap in `Sidekiq::Testing.fake! { }` to stop a job running.
- Check fixture names before using them (`books_books(:war_and_peace)`, `books_authors(:tolstoy)`); the existing type tests create their own books with `::Books::Book.create!(title: ...)`.
- A clean `bin/rails test` prints no new warnings.
- Subagents: implement with `model: "sonnet"`, review with `model: "opus"`. Never Fable.

## Rulings (designer's calls beyond the spec)

Shane: these are the decisions the spec left open or that I am making differently from its wording. Each is one line to change if you disagree.

1. **In `queue` mode a low-confidence guess is held, not applied, while the record's research is still owed to the queue.** The spec says the switch "records the deferral it records today when the budget is gone". Today, with the budget gone, a low-confidence knowledge answer is applied because research will never run. In `queue` mode research will run (an agent does it), and the queue fills blanks only, so applying the guess first would leave the agent nothing to correct. The guess is applied as today only when the record's queue row is already resolved (it will not be researched again).
2. **A deferral inserts a queue row only when the type still needs the record.** A past-cutoff book whose knowledge answer was confident and was applied gets `deferred_research: true` as today and no queue row.
3. **A failed queue insert never fails the enrichment.** It is logged; the record is a candidate at the next fill.
4. **An agent's description is not dropped when the review model is down.** On the paid path a failed review call records `review_failed` and writes the other facts. For an agent answer the same failure raises before anything is written, so the apply job retries and the row ends `failed` with Retry apply available. Otherwise one outage would lose the agent's research for good, since a `done` row is never handed out again.
5. **An agent answer with overall `confidence` low is held** (recorded, nothing written), using the gate the knowledge path already has. This matches the origin and categories prompts ("a low one is recorded and held").
6. **Book facts candidates need at least one author** (as `EnrichBook`'s `missing_inputs` check), and "no description" means no description row that is not deprecated.
7. **The two new types carry their own version constant** (`VERSION = 1`): their tasks have no `PROMPT_VERSION`. Their ledger rows record `context` and `queue_request_id` in the fact-entry shape (`{"value" => ..., "applied" => false, "reason" => "input"}`), as `EnrichAuthor` already does for `sources`, because readers iterate these rows' facts as entries. They carry no `label`: no report reads one for these kinds.
8. **The paid worker is one job per row, and each job claims its own row when it runs.** Claiming 100 rows up front would outlast the 30-minute lease. Jobs do not retry; a failed run leaves the row `failed` with the error, and Re-queue returns it.
9. **The paid worker calls the enrichers and judges directly**, not the workflows, and judges from stored evidence only (as an agent does). Its rows carry context `queue` (and label `queue` on the judges' rows). With context `queue` the categories judge never removes a link, so the queue fills blanks whichever worker runs it.
10. **`enrichment_queue:work` takes the kind** (`books.origin`), as `fill` does, not the slug the spec's example shows.
11. **A skipped research row no longer counts toward `research_daily_cap`.** It made no web call. In `api` mode nothing changes (skips are only written once the cap is reached); in `queue` mode it stops `queued` skips from using up the day's budget.
12. **`Books::EnrichBookJob` no longer treats a skipped research row as "researched".** It told the judges not to research (or defer) after a budget refusal; `JudgeOptions#researched_in_run?` already ignores skips.
13. **In `queue` mode the paced backfill counts a deferred row as done whatever the backfill cap**, since the backfill will never be granted research.
14. **The admin page says which mode is on.** One line; not in the spec.

## Review Focus

1. **The switch is on and a record's queue row is already resolved.** The record must not be queued again, and its low-confidence guess must be applied, not lost. (Task 6.)
2. **An agent answers with values the catalogue cannot use:** a language name that matches no language, a page range of "about 300", an unknown nationality, a year in the future. The row ends `done` with those facts recorded and not written; nothing raises. (Tasks 2 and 4.)
3. **The review model is down when an agent's answer is applied.** Nothing is half-written, the job retries, and the row ends `failed` with the answer kept. (Tasks 1 to 4.)
4. **A field a human cleared.** A book whose only gap is a cleared field is not queued; a book queued for another gap never has the cleared field refilled. (Task 2.)
5. **The paid worker meets something it cannot run:** an empty queue, more jobs than rows, the categories judge switched off. No row is left `claimed`, a refused row is `failed` with a readable error, and none of its ledger rows count against `research_daily_cap`. (Task 8.)

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/services/books/record_book_facts.rb` (new) | Book facts answer → review → apply → ledger row (shared by `EnrichBook` and the agent) |
| `app/lib/services/books/authors/record_author_facts.rb` (new) | Author facts answer → review → apply → ledger row (shared) |
| `app/lib/services/books/enrich_book.rb`, `authors/enrich_author.rb` | Delegate to the above; ask `ResearchRoute`; take `context:` (and `force_research:` for authors) |
| `app/lib/services/books/queue_types/book_facts.rb`, `author_facts.rb` (new) | The two types |
| `app/lib/services/books/queue_types/author_scope.rb`, `research_skip.rb`, `ledger_entries.rb` (new) | Author candidates and priority; the "latest row is a research skip" SQL; fact-entry helpers |
| `app/lib/services/books/queue_types/book_scope.rb`, `origin.rb`, `categories.rb` | `priority_for`, `research` |
| `app/lib/services/books/human_cleared_fields.rb` | `not_cleared_sql` |
| `app/lib/services/enrichment_queue/type.rb`, `registry.rb`, `claim.rb` | `priority_for`, `paid_research?`, `research`, `ledger_result`; two more types; a claim with no user |
| `app/lib/services/enrichment_queue/research_route.rb` (new) | The switch: `queue?`, `open_for?`, `defer` |
| `app/lib/services/enrichment_queue/research.rb` (new) | Claim one row, run the type's `research`, close the row |
| `app/sidekiq/enrichment_queue/research_job.rb` (new), `lib/tasks/enrichment_queue.rake` | The paid worker |
| `app/lib/services/books/origin/judge.rb`, `categories/judge.rb`, `categorize/research_budget.rb`, `categorize/backfill.rb` | The switch in the judges |
| `app/models/enrichment.rb`, `app/sidekiq/books/enrich_book_job.rb`, `config/initializers/ai.rb` | Cap scope, the "researched" check, the setting |
| `app/lib/services/ai/tasks/books/book_facts_task.rb`, `author_facts_task.rb` | `FACT_RULES`, `DESCRIPTION_RULES` |
| `config/mcp/books/prompts/enrichment/book_facts.md.erb`, `author_facts.md.erb` (new) | Copy prompts |
| `app/controllers/admin/enrichment_queues_base_controller.rb`, `app/views/admin/enrichment_queues_base/index.html.erb` | The mode line |
| `docs/features/enrichment-queue.md`, `docs/features/books_enrichment.md`, `docs/launch-todo.md`, the spec | Documentation |

---

### Task 1: Extract `RecordBookFacts` from `EnrichBook`

A refactor plus two new options. `EnrichBook`'s behaviour does not change.

**Files:**
- Create: `app/lib/services/books/record_book_facts.rb`
- Modify: `app/lib/services/books/enrich_book.rb`
- Test: `test/lib/services/books/record_book_facts_test.rb` (new); `test/lib/services/books/enrich_book_test.rb` unmodified

**Interfaces:**
- Produces:

```ruby
Services::Books::RecordBookFacts::KIND          # "books.book_facts"; EnrichBook::KIND becomes RecordBookFacts::KIND
Services::Books::RecordBookFacts::ReviewFailed  # < StandardError
Services::Books::RecordBookFacts.call(
  book:, facts:, mode:,                 # facts: the BookFactsTask answer, Symbol keys at every level, :recognized present
  citations: [], ai_chat: nil, provider: nil, model: nil,
  author_names: nil,                    # falls back to book.authors.map(&:name), as EnrichBook does
  goodreads_page: nil,                  # the source for a :sourced run's DescriptionCheck
  hold_low_confidence: nil,             # a reason String: when the overall confidence is low, record every fact with this reason and apply nothing
  strict_review: false,                 # true: a description whose review call failed raises ReviewFailed before anything is written
  extra_facts: {}                       # merged into the row's facts last
) # => the Enrichment row it created. A raise propagates.
```

- [ ] **Step 1: Write the failing tests** in `record_book_facts_test.rb`. Reuse the helpers' shape from `enrich_book_test.rb` (`facts(overrides)`, `stub_review`). Each creates a book with one author and no year, language or description.
  - `"a recognized answer fills blanks and writes one applied row"`: `mode: :agent, provider: "agent", citations: ["https://example.org/a"]`, review stubbed clean. Row: `kind "books.book_facts"`, `mode "agent"`, `outcome "applied"`, `recognized true`, `provider "agent"`, `citations`; the book has the year; `row.facts["first_published_year"]["applied"]` is true.
  - `"an unrecognized answer applies nothing"`: `recognized: false` → `outcome "unrecognized"`, every fact `"applied" => false, "reason" => "unrecognized"`, book unchanged, `DescriptionReviewTask.expects(:new).never`.
  - `"a low overall confidence is held under the given reason"`: `hold_low_confidence: "low_confidence"`, answer `confidence: "low"` → `outcome "nothing_to_apply"`, facts carry `"reason" => "low_confidence"`, book unchanged, no review call.
  - `"a low overall confidence is applied when nothing holds it"`: same answer, `hold_low_confidence: nil` → `outcome "applied"`.
  - `"a held reason does not touch a medium answer"`: `hold_low_confidence: "deferred"`, `confidence: "medium"` → `outcome "applied"`.
  - `"strict review raises before anything is written when the review call fails"`: review stubbed `success: false`, `strict_review: true` → `assert_raises(RecordBookFacts::ReviewFailed)`, no new `Enrichment`, book unchanged.
  - `"without strict review a failed review records review_failed and the other facts apply"`: `row.facts["description"]["reason"] == "review_failed"`, year filled.
  - `"extra_facts are merged into every kind of row"`: `extra_facts: {"context" => {"value" => "agent", "applied" => false, "reason" => "input"}}` on an applied, an unrecognized and a held row.
  - `"an agent row that recognized the book makes the dossier research-backed"`: after an applied `mode: :agent` row, `Services::Books::Categorize::Dossier.build(book: book).research_backed?` is true.

- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/record_book_facts_test.rb` — FAIL, uninitialized constant.

- [ ] **Step 3: Implement `RecordBookFacts`.** Move, without rewording, from `EnrichBook`: the body of `run` after the `facts.key?(:recognized)` check (the unrecognized row, the low-confidence row, `description_for`, `ApplyBookFacts`, the final row), plus `description_for`, `review_description`, `review_verdict`, `unapplied_facts` and `confidence_for`. `row_attributes` is needed on both sides (`EnrichBook`'s rescue writes the failed row with it), so `EnrichBook` keeps its copy. The low-confidence branch's condition becomes `hold_low_confidence && confidence == "low"` and its reason is the given string. `strict_review` raises `ReviewFailed` where `description_for` would return a `review_failed` result.

- [ ] **Step 4: Make `EnrichBook#run` delegate.** After its two failure checks it calls `RecordBookFacts.call(book:, facts:, mode:, citations:, ai_chat: chat, provider: chat&.provider, model: chat&.model, author_names: author_names, goodreads_page: goodreads_page, hold_low_confidence: ("deferred" if mode == :knowledge && !budget_exhausted?))` inside the existing `rescue => e`, which still writes the one failed row. `failed_row` and `skip` stay in `EnrichBook`.

- [ ] **Step 5: Run.** `bin/rails test test/lib/services/books/record_book_facts_test.rb test/lib/services/books/enrich_book_test.rb test/lib/services/books/apply_book_facts_test.rb` — PASS, with `git diff --stat test/lib/services/books/enrich_book_test.rb` empty.

- [ ] **Step 6: Commit.** `git commit -m "Extract RecordBookFacts from EnrichBook"`

---

### Task 2: The `books.book_facts` type

**Files:**
- Create: `app/lib/services/books/queue_types/book_facts.rb`, `research_skip.rb`, `ledger_entries.rb`
- Modify: `app/lib/services/books/queue_types/book_scope.rb`, `app/lib/services/books/human_cleared_fields.rb`, `app/lib/services/enrichment_queue/type.rb`, `registry.rb`, `test/support/enrichment_queue_test_type.rb`
- Test: `test/lib/services/books/queue_types/book_facts_test.rb` (new); add to `origin_test.rb`, `human_cleared_fields_test.rb`, `registry_test.rb`

**Interfaces:**
- Consumes: `RecordBookFacts` (Task 1).
- Produces:

```ruby
# type.rb
def priority_for(record)   # Integer: the priority this one record would get in candidates. Raises NotImplementedError in the base.

# book_scope.rb (so Origin and Categories get it too)
def priority_for(book)     # the book's rank in the default primary ranking, else UNRANKED_PRIORITY. Must NOT go through
                           # base_relation: a book with a running run is excluded there and still needs a priority.

# human_cleared_fields.rb
Services::Books::HumanClearedFields.not_cleared_sql(field_name)
# SQL fragment correlated on books_books.id, true when no human cleared the field:
#   NOT EXISTS (cleared_fields row for this book and field_name)
#   AND NOT EXISTS (applied correction_fields row for this book and field_name whose new_value is
#                   SQL NULL, JSON null, or a string that is empty after btrim)
# field_name is bound, never interpolated.

# research_skip.rb
Services::Books::QueueTypes::ResearchSkip.latest_sql(record_class, kind)
# EXISTS fragment correlated on <record_class.table_name>.id: the record's newest enrichments row of `kind`
# has mode research and outcome skipped (use ::Enrichment.modes / .outcomes for the integers).

# ledger_entries.rb
Services::Books::QueueTypes::LedgerEntries.input(value)               # {"value" => value, "applied" => false, "reason" => "input"}
Services::Books::QueueTypes::LedgerEntries.for_request(request, context:)
# {"context" => input(context), "queue_request_id" => input(request.id)}

# book_facts.rb
Services::Books::QueueTypes::BookFacts   # kind "books.book_facts", label "Book facts", VERSION = 1, target_class ::Books::Book
```

The type, in full:

- `candidates(scope:)` = `base_relation(scope:)` where the book has at least one `books_book_authors` row (`::Books::BookAuthor.table_name`) and `need_sql` holds. `need_sql` is the OR of:
  - `books_books.first_published_year IS NULL AND not_cleared_sql("first_published_year")`
  - `books_books.original_language_id IS NULL AND not_cleared_sql("original_language_id")`
  - no `descriptions` row for the book with `rank <> ::Description.ranks[:deprecated]`, and no `ai_generated` description row of any rank (the applier keeps any AI description, even a deprecated one; amended during execution, 2026-11-18)
  - `ResearchSkip.latest_sql(::Books::Book, kind)`
- `still_needed?(book)` = the same author and need conditions for that one id, without `base_relation` (a running run does not make a book unneeded).
- `payload(book)`:

```ruby
{"book_id" => book.id,
 "record" => dossier.record,                                   # Categorize::Dossier.build(book:).record
 "missing" => [...],                                           # of "first_published_year", "original_language", "description": blank and not human-cleared
 "evidence" => dossier.to_ledger.slice("wikidata", "wikipedia", "worldcat", "goodreads"),
 "tried" => tried_facts(book)}                                  # nil, or {"mode", "outcome", "reason", "confidence", "facts"} from the newest
                                                               # books.book_facts row that is not skipped; "facts" is row.facts.slice(
                                                               # *%w[first_published_year original_language word_count page_range subtitle alternate_titles description])
```

- `reference` = `{"answer_schema" => answer_schema}`; `answer_schema` = `BookFactsTask::ResponseSchema.to_json_schema.deep_stringify_keys`.
- `apply(request)` calls `RecordBookFacts.call(book:, facts: request.answer.deep_symbolize_keys, mode: :agent, citations: request.sources.uniq, provider: "agent", model: nil, hold_low_confidence: "low_confidence", strict_review: true, extra_facts: LedgerEntries.for_request(request, context: "agent"))` and returns `Type::Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])`. A raise propagates to the apply job.
- Add `"Services::Books::QueueTypes::BookFacts"` to `Registry::TYPE_NAMES`. Give `EnrichmentQueueTestType` `def priority_for(record) = record.id`.

- [ ] **Step 1: Write the failing tests.** In `book_facts_test.rb` (helper: `book_with_author(title, **attrs)` creates a book and links `books_authors(:tolstoy)`; `complete(book)` gives it a year, a language and a normal description):
  - candidates: a book missing its year is in; a complete book is out; a book with no author is out; a book with a blank title is out; a book with a running `books.book_enrichment` run is out; a book whose only description is deprecated is in.
  - `"a field a human cleared is not a gap"`: complete except the year, with a `ClearedField` row for `first_published_year` → out. The same with an applied `CorrectionField` whose `new_value` is `""` → out. With the cleared field **and** no language → in.
  - `"a complete book whose newest book_facts row is a research skip is a candidate"`: `enrichments.create!(kind: "books.book_facts", mode: :research, outcome: :skipped, reason: "budget_exhausted")` → in; add a newer `applied` row → out; a `deferred_to_authors` skip (mode knowledge) → out.
  - `"ranked scope keeps only ranked books and priority is the rank"` (as in `origin_test.rb`).
  - `"still_needed? follows the data and ignores a running run"`.
  - `"payload names what is missing and what was tried"`: `payload["missing"] == %w[first_published_year original_language description]` for an empty book; a cleared year is not listed; `payload["tried"]["facts"]` has the newest non-skipped row's entries.
  - `"the answer schema accepts a full answer and rejects one with a key missing"` through `JSONSchemer.schema(Type.answer_schema)`.
  - `"apply writes an agent row and fills blanks"`: request with a valid answer and two sources (one repeated) → `mode "agent"`, `outcome "applied"`, `citations` deduplicated, `facts["context"]["value"] == "agent"`, `facts["queue_request_id"]["value"] == request.id`, year and language set, the reviewed description written.
  - `"apply never overwrites a held value"`: book with year 1869, answer says 1870 → year still 1869, `facts["first_published_year"]["reason"] == "already_set"`.
  - `"apply records what the catalogue cannot use"`: an answer whose only non-null facts are `original_language` `"Klingonese"` and `page_range` `"about 300"` → `outcome "nothing_to_apply"`, their reasons are `no_match` and `invalid`, the book is unchanged, no raise.
  - `"apply never refills a field a human cleared"`: cleared year, answer gives a year → year still nil, reason `human_cleared`.
  - `"an unrecognized answer ends unrecognized"` and `"a low overall confidence is held"` (reason `low_confidence`, nothing written).
  - `"a failed review call raises and writes nothing"`.
  - `"submit to done, end to end"`: fill, claim, `Submit.call` with Sidekiq inline → row `done`, outcome `applied`, `enrichment` set.
  - `"a done row is not queued again while the gap remains"`: after an apply that left the language blank, `Fill.call` inserts 0 and the row is still `done`.
  - In `origin_test.rb`: `"priority_for is the rank, or the unranked constant, and ignores a running run"`.
  - In `human_cleared_fields_test.rb`: `not_cleared_sql` agrees with `HumanClearedFields.for(book)` for a cleared field, an applied blank correction, an applied non-blank correction and a pending blank correction.
  - In `registry_test.rb`: `Registry.find(domain: "books", slug: "book_facts")` is the type.

- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run.** `bin/rails test test/lib/services/books/queue_types test/lib/services/books/human_cleared_fields_test.rb test/lib/services/enrichment_queue` — PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add the books.book_facts enrichment queue type"`

---

### Task 3: Extract `RecordAuthorFacts` from `EnrichAuthor`

The same refactor as Task 1, for authors.

**Files:**
- Create: `app/lib/services/books/authors/record_author_facts.rb`
- Modify: `app/lib/services/books/authors/enrich_author.rb`
- Test: `test/lib/services/books/authors/record_author_facts_test.rb` (new); `enrich_author_test.rb` unmodified

**Interfaces:**
- Produces:

```ruby
Services::Books::Authors::RecordAuthorFacts::KIND          # "books.author_facts"; EnrichAuthor::KIND becomes this
Services::Books::Authors::RecordAuthorFacts::ReviewFailed  # < StandardError
Services::Books::Authors::RecordAuthorFacts.sources_fact(records)
# {"sources" => {"value" => records.sources, "applied" => false, "reason" => "input"}}; EnrichAuthor's failed rows use it too
Services::Books::Authors::RecordAuthorFacts.call(
  author:, records:, facts:, mode:,     # records: a MatchedRecords; facts: the AuthorFactsTask answer, Symbol keys, :recognized present
  citations: [], ai_chat: nil, provider: nil, model: nil,
  hold_low_confidence: nil, strict_review: false, extra_facts: {}   # as in RecordBookFacts
) # => the Enrichment row. Every row's facts end with .merge(sources_fact).merge(extra_facts). A raise propagates.
```

- [ ] **Step 1: Write the failing tests** (reuse `enrich_author_test.rb`'s helpers' shape): applied row in `mode: :agent` with `provider "agent"` and the `sources` entry; unrecognized applies nothing; `hold_low_confidence: "low_confidence"` holds a low overall answer and skips the review call; `nil` applies it; a per-fact low confidence is recorded `low_confidence` and the other facts apply; `strict_review: true` with a failed review call raises `ReviewFailed` and writes nothing; without it `review_failed` is recorded; `extra_facts` merged on all three row kinds.
- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Implement.** Move, without rewording, from `EnrichAuthor`: the body of `run` after the `facts.key?(:recognized)` check, `description_for`, `review_description`, `exempt_titles`, `verdict`, `write`, `unapplied_facts`, `confidence_for`. `EnrichAuthor` keeps its own `row_attributes` for its failed rows and reads `sources_fact` from the new class. The low-confidence branch becomes `hold_low_confidence && confidence == "low"`.
- [ ] **Step 4: Make `EnrichAuthor#run` delegate** with `hold_low_confidence: ("deferred" if mode == :knowledge && research_allowed? && !budget_exhausted?)`, inside the existing `rescue => e`.
- [ ] **Step 5: Run.** `bin/rails test test/lib/services/books/authors` — PASS, `git diff --stat test/lib/services/books/authors/enrich_author_test.rb` empty.
- [ ] **Step 6: Commit.** `git commit -m "Extract RecordAuthorFacts from EnrichAuthor"`

---

### Task 4: The `books.author_facts` type

**Files:**
- Create: `app/lib/services/books/queue_types/author_scope.rb`, `author_facts.rb`
- Modify: `app/lib/services/enrichment_queue/registry.rb`
- Test: `test/lib/services/books/queue_types/author_facts_test.rb` (new); add to `registry_test.rb`

**Interfaces:**
- Consumes: `RecordAuthorFacts` (Task 3); `ResearchSkip`, `LedgerEntries`, `Type#priority_for` (Task 2).
- Produces:

```ruby
# author_scope.rb — `extend` it from an author type, as BookScope is used
UNRANKED_PRIORITY = 1_000_000
def ranked_join_sql          # LEFT JOIN ranked_items on item_type 'Books::Author', the id of ::Books::Authors::RankingConfiguration.default_primary
def base_relation(scope:)    # ::Books::Author where exclude_from_rankings is false and no running books.author_enrichment run
                             # (::Workflows::Books::AuthorEnrichment.workflow, enrichable_type "Books::Author"), joined to the rank;
                             # "ranked" keeps ranked authors; an unknown scope raises ArgumentError
def priority_sql             # "COALESCE(ranked_items.rank, 1000000)"
def priority_for(author)     # the author's rank, else UNRANKED_PRIORITY; not through base_relation

Services::Books::QueueTypes::AuthorFacts   # kind "books.author_facts", label "Author facts", VERSION = 1, target_class ::Books::Author
```

- `candidates(scope:)` = `base_relation(scope:).where(ResearchSkip.latest_sql(::Books::Author, kind))`. `still_needed?(author)` = not `exclude_from_rankings` and the same SQL for that id.
- `payload(author)`:

```ruby
{"author_id" => author.id,
 "record" => {"name", "alternate_names" (first 10), "birth_year", "death_year", "gender", "countries" (names, sorted),
              "books" => [{"title", "first_published_year"}, ...],   # AuthorProfile.new(author).ranked_books(10)
              "has_description" => true/false},                       # a description row that is not deprecated
 "tried" => ...}   # nil, or {"mode", "outcome", "confidence", "facts"} from the newest books.author_facts row that is not skipped;
                   # "facts" is row.facts.slice(*%w[birth_year death_year gender countries description])
```

- `answer_schema` = `AuthorFactsTask::ResponseSchema.to_json_schema.deep_stringify_keys`.
- `apply(request)` calls `RecordAuthorFacts.call(author:, records: MatchedRecords.new(author), facts: request.answer.deep_symbolize_keys, mode: :agent, citations: request.sources.uniq, provider: "agent", model: nil, hold_low_confidence: "low_confidence", strict_review: true, extra_facts: LedgerEntries.for_request(request, context: "agent"))`.
- Add `"Services::Books::QueueTypes::AuthorFacts"` to `Registry::TYPE_NAMES`.

- [ ] **Step 1: Write the failing tests.**
  - candidates: an author whose newest `books.author_facts` row is `mode research, outcome skipped` is in; one with a newer applied row is out; one with no rows is out; one whose newest row is a knowledge skip (`complete`) is out; a placeholder (`exclude_from_rankings: true`) with a research skip is out; one with a running `books.author_enrichment` run is out.
  - `"ranked scope keeps ranked authors and priority is the rank"`; `"priority_for is the rank or the unranked constant"`; `"still_needed? follows the ledger"`.
  - `"payload carries the author, their books and what was tried"`.
  - `"the answer schema accepts a full answer and rejects one with a key missing"`.
  - `"apply writes an agent row and fills blanks"` (birth year, gender, countries from `nationalities`, the reviewed description; `mode "agent"`, the `context`, `queue_request_id` and `sources` entries).
  - `"apply never overwrites a held value"` (birth year held → unchanged).
  - `"apply records what the catalogue cannot use"`: a birth year in the future, gender `"unknown"`, a nationality that matches no country → recorded, not written, no raise.
  - `"a low overall confidence is held"`; `"an unrecognized answer ends unrecognized"`; `"a failed review call raises and writes nothing"`.
  - `"submit to done, end to end"` with Sidekiq inline.
  - In `registry_test.rb`: `Registry.find(domain: "books", slug: "author_facts")` is the type.
- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** `bin/rails test test/lib/services/books/queue_types test/lib/services/enrichment_queue` — PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add the books.author_facts enrichment queue type"`

---

### Task 5: The two Copy prompts

**Files:**
- Modify: `app/lib/services/ai/tasks/books/book_facts_task.rb`, `author_facts_task.rb`, `app/lib/services/books/queue_types/book_facts.rb`, `author_facts.rb`
- Create: `config/mcp/books/prompts/enrichment/book_facts.md.erb`, `author_facts.md.erb`
- Test: `test/lib/services/ai/tasks/books/book_facts_task_test.rb`, `author_facts_task_test.rb`, `test/lib/services/agent_prompts_test.rb`

**Interfaces:**
- Produces: `BookFactsTask::FACT_RULES`, `BookFactsTask::DESCRIPTION_RULES`, `AuthorFactsTask::FACT_RULES`, `AuthorFactsTask::DESCRIPTION_RULES` (frozen Strings); `BookFacts.prompt_locals` and `AuthorFacts.prompt_locals` return `{fact_rules:, description_rules:}`.

- [ ] **Step 1: Pin the system messages before touching them.** In each task's test file add `"the system message sent to the model is byte-for-byte what it was"`, once for `mode: :knowledge` and once for `mode: :research`, in the form `book_origin_task_test.rb` uses (a provider stub whose `send_message!` raises, then `chat.messages.first.fetch("content")`, then `Digest::SHA256.hexdigest`). Run each with a wrong digest to read the real one, put the real one in, run green **on the unchanged task files**, and commit: `git commit -m "Pin the book and author facts system messages"`. This commit must contain test files only.

- [ ] **Step 2: Extract the constants.** In each task, `FACT_RULES` is the paragraph that starts `Facts. For every fact give a value` (one line), and `DESCRIPTION_RULES` is everything from the line `Description rules.` through the bullet `- No citations, URLs, footnotes, or bracketed references inside any text field.` Both are `<<~RULES.chomp.freeze` heredocs interpolated back into `system_message` (as `BookOriginTask::RULES` is); in `AuthorFactsTask` they are defined after `MIN_WORDS` and `MAX_WORDS`. Run the Step 1 tests: PASS with the digests unchanged.

- [ ] **Step 3: Write the failing prompt tests** in `agent_prompts_test.rb`:
  - `"the book facts prompt carries the task's rules"`: includes `BookFactsTask::FACT_RULES`, `BookFactsTask::DESCRIPTION_RULES`, the MCP URL, `"holds 1 pending"` (one pending `books.book_facts` row), the four tool names.
  - `"the author facts prompt carries the task's rules"`: the same for authors.
  - `"both facts prompts tell the agent when the queue is done and what each refusal means"`: for both, `` "`meta.remaining` is 0" ``, `"no longer yours"`, `"The lease lasts 30 minutes"`, `"fix the answer and submit again"`, `"If either call answers 404, the item is gone"`, `"give null rather than a guess"`, `"do not raise your confidence to get an answer through"`.
  - `"the book facts prompt says what is written"`: includes `"Submitting only fills blanks"`, `"is recorded and nothing is written"` and `"Book type, series and origin countries are recorded and not written"`.
  - `"the author facts prompt says what is written"`: includes `"A fact you mark low is recorded and not written"`.

- [ ] **Step 4: Write the prompt files.** `book_facts.md.erb`:

```erb
You are filling in missing facts and descriptions for books on The Greatest Books, using the admin MCP server at <%= mcp_url %>. The "<%= type %>" enrichment queue holds <%= pending %> pending books that lack a first published year, an original language or a description, or that our own model could not settle without a web search. Work through all of them.

How to work the queue:

1. Call get_enrichment_queue with type "<%= type %>" once. `reference.answer_schema` is the exact shape of an answer: each fact is an object with a `value` and a `confidence` of high, medium or low.
2. Call claim_enrichment_items with type "<%= type %>". Keep `meta.lease_token`. The lease lasts 30 minutes, so claim only as many items as you can finish in that time: a `limit` of 5 suits web research.
3. For each item, read its `payload`: `record` is the book as we hold it, `missing` says which of the first published year, the original language and the description it lacks, `evidence` is what Wikidata, Wikipedia, WorldCat and Goodreads said when we have it, and `tried` is what our own model already answered. Then research the book with your own web search.
4. Call submit_enrichment_item with the item's id, the lease token, your answer and the URLs you actually used as `sources`. Answer every key in the schema, with null (or an empty list) for a fact you did not find. Set `recognized` to true only when you are sure which book the item is; if you cannot identify the book, call skip_enrichment_item and say what you looked for.
5. Claim again. The queue is done only when a claim returns no items and `meta.remaining` is 0. If it returns no items but `meta.remaining` is above 0, claim again.

If submit_enrichment_item or skip_enrichment_item answers 409, the item is no longer yours (another worker took it, or your earlier call already went through). Drop it and move on.

If submit_enrichment_item answers 422, your answer did not match the schema. The item is still yours: fix the answer and submit again.

If either call answers 404, the item is gone: its book was deleted or merged into another. Drop it and move on.

Use sub-agents if you have them: each one runs steps 2 to 5 by itself. Two workers are never given the same book. A skipped item is never handed out again, so skip only after a real search.

The facts and the description, by the same rules our own model follows:

<%= fact_rules %>

<%= description_rules %>

What is written. Submitting only fills blanks: a value the book already holds is never overwritten, and your answer for it is only recorded. An answer whose overall `confidence` is low is recorded and nothing is written. Otherwise these are written when the book has none: the first published year, the original language (give the language's English name), the word count, the page range (as "300" or "250-350"), the subtitle and the description. Other titles the work is known by are added to the ones the book already holds. Book type, series and origin countries are recorded and not written, so do not spend research on them: give null, or an empty list. A field a person deliberately cleared stays empty. For a single fact you are unsure of, give null rather than a guess, and do not raise your confidence to get an answer through. A reviewer model checks the description before it is written: one that gives away how the book ends, or breaks the rules above, is rewritten or dropped. Write it in your own words and never copy a publisher's or a website's text. A book that already has a description written by our model keeps it.

You are authorised to act without asking me.

When you finish, call get_enrichment_queue once more and report its counts, then list the books you skipped with one line each.
```

`author_facts.md.erb` is the same file with these differences, and no others:

- First paragraph: `You are filling in missing facts and descriptions for authors on The Greatest Books, using the admin MCP server at <%= mcp_url %>. The "<%= type %>" enrichment queue holds <%= pending %> pending authors that our own model did not know well enough and that no Wikidata or library record was matched to. Work through all of them.`
- Step 3: `For each item, read its \`payload\`: \`record\` is the author as we hold them, with their best-known books in our catalogue, and \`tried\` is what our own model already answered. The name may belong to several people: research only the person who wrote the books listed. Then research the author with your own web search.`
- Step 4's last sentence: `Set \`recognized\` to true only when you are sure which person the item is; if you cannot tell who wrote these books, call skip_enrichment_item and say what you looked for.`
- The 404 paragraph says `its author was deleted or merged into another`; the sub-agents paragraph says `the same author`.
- Before the rules: `The facts and the description, by the same rules our own model follows. Where they mention sources given below, read what you found on the web: no record of ours was matched to these authors.`
- The "What is written" paragraph: `What is written. Submitting only fills blanks: a value the author already holds is never overwritten, and your answer for it is only recorded. An answer whose overall \`confidence\` is low is recorded and nothing is written. A fact you mark low is recorded and not written, so for a fact you are unsure of, give null rather than a guess, and do not raise your confidence to get an answer through. Nationalities are written only when the author has no country yet. A reviewer model checks the description before it is written: one that breaks the rules above is rewritten or dropped. Write it in your own words and never copy an encyclopedia's or a website's text. An author who already has a description written by our model keeps it.`
- The last line lists `the authors you skipped`.

- [ ] **Step 5: Add `prompt_locals`** to both types and run `bin/rails test test/lib/services/agent_prompts_test.rb test/lib/services/ai/tasks/books` — PASS.
- [ ] **Step 6: Commit.** `git commit -m "Add the book facts and author facts Copy prompts"`

---

### Task 6: The switch in `EnrichBook` and `EnrichAuthor`

**Files:**
- Create: `app/lib/services/enrichment_queue/research_route.rb`
- Modify: `config/initializers/ai.rb`, `app/lib/services/books/enrich_book.rb`, `app/lib/services/books/authors/enrich_author.rb`, `app/models/enrichment.rb`, `app/sidekiq/books/enrich_book_job.rb`
- Test: `test/lib/services/enrichment_queue/research_route_test.rb` (new); add to `enrich_book_test.rb`, `enrich_author_test.rb`, `test/models/enrichment_test.rb`, `test/sidekiq/books/enrich_book_job_test.rb`

**Interfaces:**
- Consumes: the two types and `priority_for` (Tasks 2 and 4).
- Produces:

```ruby
# config/initializers/ai.rb, with a comment in the file's style. ENV: AI_RESEARCH_VIA.
config.x.ai.research_via = (ENV["AI_RESEARCH_VIA"].to_s.strip.downcase == "queue") ? "queue" : "api"

Services::EnrichmentQueue::ResearchRoute.queue?                    # research_via == "queue"
Services::EnrichmentQueue::ResearchRoute.open_for?(kind:, record:) # true unless the record has a row of this kind in a status other than pending or claimed
Services::EnrichmentQueue::ResearchRoute.defer(kind:, record:)
# Inserts one pending row (reason "research_wanted", the type's version, type.priority_for(record), sources [])
# with insert_all on Fill::UNIQUE_INDEX, unless the type no longer needs the record (type.still_needed?).
# Returns true when a row was inserted. Never raises: a StandardError is logged
# ("event=enrichment_queue_defer_failed kind=... record_id=... error=...") and false is returned.
```

- `EnrichBook`, three sites, replacing the bare `budget_exhausted?` decisions:
  - `research_skip_reason` (private): `nil` when `force_research`; `"queued"` when `ResearchRoute.queue?`; `"budget_exhausted"` when the budget is gone; else `nil`. Both "research or skip" branches in `call` use it.
  - A skip with reason `"queued"` is followed by `ResearchRoute.defer(kind: KIND, record: book)` (the skip row is written first: the type's `still_needed?` reads it).
  - `hold_low_confidence:` becomes `"deferred"` when `mode == :knowledge` and research will follow: in `queue` mode `ResearchRoute.open_for?(kind: KIND, record: book)`, otherwise `!budget_exhausted?`.
- `EnrichAuthor`: the same three changes, with `research_allowed?` kept in the hold condition. (It has no force option yet; Task 8 adds one.)
- `Enrichment.against_research_cap` additionally excludes `outcome: :skipped`.
- `Books::EnrichBookJob`: `researched` is true only for a research-mode row that is not `skipped?`.

- [ ] **Step 1: Write the failing tests.**

  `research_route_test.rb` (stub `Registry.types` to `[EnrichmentQueueTestType]`, as the engine tests do):
  - `queue?` is false by default and true when `research_via` is stubbed to `"queue"`.
  - `open_for?`: true with no row, a `pending` row, a `claimed` row; false with `submitted`, `done`, `skipped`, `failed`.
  - `defer` inserts a pending row with reason `research_wanted`, the type's version and `priority_for`'s value, and returns true; returns false and changes nothing when a row of any status exists; returns false when `needed` is false; returns false and does not raise when `EnrichmentRequest.insert_all` raises.

  `enrich_book_test.rb`, all with `research_via` stubbed to `"queue"` unless said:
  - `"queue mode: an unrecognized knowledge run queues the research instead of running it"`: only the knowledge task runs; rows are `[unrecognized knowledge, skipped research "queued"]`; one pending `books.book_facts` request, reason `research_wanted`.
  - `"queue mode: a low-confidence guess is held for the agent"`: knowledge row `nothing_to_apply` with facts reason `deferred`, book unchanged, request inserted.
  - `"queue mode: a low-confidence guess is applied when the book's queue row is already resolved"`: a `done` `books.book_facts` request exists → knowledge row `applied`, skip row `queued`, still exactly one request and it is still `done`.
  - `"queue mode: a book at or past the cutoff is queued without a model call"`.
  - `"queue mode: force_research still researches and queues nothing"`.
  - `"queue mode: an existing pending row is left as it is"` (reason stays `missing`).
  - `"queue mode: a failed queue insert does not fail the run"` (`ResearchRoute.stubs(:defer).returns(false)` is not enough; stub `EnrichmentRequest.insert_all` to raise and assert `result.success?`).
  - `"api mode: an exhausted budget queues nothing"` (cap stubbed to 0, `EnrichmentRequest.count` unchanged, reason `budget_exhausted`).

  `enrich_author_test.rb`: the first three and the last of the above, for an unmatched author and kind `books.author_facts`; plus `"queue mode: a matched author is never queued"`.

  `enrichment_test.rb`: `"against_research_cap leaves out skipped research rows"`.

  `enrich_book_job_test.rb`: `"a skipped research row does not mark the book as researched"` (`EnrichBook.stubs(:call)` returns a result whose rows include a skipped research row; the `BookCategorize.start` options have no `book_facts_researched`).

- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** `bin/rails test test/lib/services/enrichment_queue test/lib/services/books/enrich_book_test.rb test/lib/services/books/authors/enrich_author_test.rb test/models/enrichment_test.rb test/sidekiq/books` — PASS; the two enricher test files' diffs are additions only.
- [ ] **Step 5: Commit.** `git commit -m "Send would-be book and author web searches to the queue when AI_RESEARCH_VIA=queue"`

---

### Task 7: The switch in the origin and categories judges

**Files:**
- Modify: `app/lib/services/books/categorize/research_budget.rb`, `app/lib/services/books/origin/judge.rb`, `app/lib/services/books/categories/judge.rb`, `app/lib/services/books/categorize/backfill.rb`
- Test: add to `research_budget_test.rb`, `origin/judge_test.rb`, `categories/judge_test.rb`, `backfill_test.rb`

**Interfaces:**
- Consumes: `ResearchRoute` (Task 6).
- Changes:
  - `ResearchBudget.permitted?(context:)` returns false in `queue` mode, for every context. (`force_research` never reaches it: both judges return true before calling it.)
  - In both judges' `judge`, where the row is marked today (`row.update!(facts: row.facts.merge("deferred_research" => true)) if deferred`): in `queue` mode the merge also sets `"deferred_reason" => "queued"`, and `ResearchRoute.defer(kind: KIND, record: book)` is called after the update. In `api` mode the row is exactly what it is today (no `deferred_reason` key).
  - `Backfill.done_rows`: the "a deferred row is not done" clause applies only when the backfill cap is above 0 **and** the mode is not `queue`.

- [ ] **Step 1: Write the failing tests** (`research_via` stubbed to `"queue"` unless said).

  `origin/judge_test.rb`:
  - `"queue mode: a weak knowledge answer is deferred to the queue, not researched"`: low-confidence answer, book with no real country → one knowledge row, `facts["deferred_research"] == true`, `facts["deferred_reason"] == "queued"`, one pending `books.origin` request with reason `research_wanted`; the research task is never built.
  - `"queue mode: force_research still researches and queues nothing"`.
  - `"queue mode: a past-cutoff book whose answer was applied is deferred but not queued"`: confident answer that sets a country → `deferred_research` true, no request.
  - `"queue mode: research not allowed means no deferral and no queue row"` (`research_allowed: false`).
  - `"api mode: a deferral carries no deferred_reason and queues nothing"` (import cap stubbed to 0).

  `categories/judge_test.rb` (`categories_judge_enabled` stubbed true, as the file does):
  - `"queue mode: an unrecognized book is deferred to the queue"`: book with no genre → deferred, `deferred_reason` `queued`, one pending `books.categories` request.
  - `"queue mode: an unrecognized book that already has a genre is deferred but not queued"`.
  - `"queue mode: force_research still researches"`.

  `research_budget_test.rb`: `"queue mode permits nothing"` for `"import"` and `"backfill"`, with both caps stubbed high.

  `backfill_test.rb`: `"queue mode: a deferred row counts as done even when the backfill cap is above 0"` (cap stubbed to 5; the same book is a candidate in `api` mode).

- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** `bin/rails test test/lib/services/books/origin test/lib/services/books/categories test/lib/services/books/categorize` — PASS; the four test files' diffs are additions only.
- [ ] **Step 5: Commit.** `git commit -m "Send would-be origin and categories web searches to the queue when AI_RESEARCH_VIA=queue"`

---

### Task 8: The paid worker

**Files:**
- Create: `app/lib/services/enrichment_queue/research.rb`, `app/sidekiq/enrichment_queue/research_job.rb` (generator)
- Modify: `app/lib/services/enrichment_queue/type.rb`, `claim.rb`, the four types, `app/lib/services/books/enrich_book.rb`, `authors/enrich_author.rb`, `categories/judge.rb`, `app/models/enrichment.rb`, `lib/tasks/enrichment_queue.rake`, `test/support/enrichment_queue_test_type.rb`
- Test: `test/lib/services/enrichment_queue/research_test.rb` (new), `test/sidekiq/enrichment_queue/research_job_test.rb` (generated); add to `claim_test.rb`, the four type tests, `enrich_book_test.rb`, `enrich_author_test.rb`, `categories/judge_test.rb`, `enrichment_test.rb`, `test/lib/tasks/enrichment_queue_rake_test.rb`

**Interfaces:**
- Produces:

```ruby
# type.rb
def paid_research? = false
def research(request)      # raises NotImplementedError in the base. Returns a Type::Result with data: {enrichment:, outcome:}.
def ledger_result(row)     # the Result for the ledger row a paid run ended on: a failure (errors [row.error] or
                           # ["skipped: #{row.reason}"], or ["no ledger row"]) when row is nil, failed or skipped;
                           # otherwise success with data: {enrichment: row, outcome: row.outcome}

# The four types define paid_research? = true and:
BookFacts.research(request)   # ledger_result(EnrichBook.call(book:, force_research: true, context: "queue").data[:enrichments].last)
AuthorFacts.research(request) # ledger_result(EnrichAuthor.call(author:, force_research: true, context: "queue").data[:enrichments].last)
Origin.research(request)      # ledger_result(Origin::Judge.call(book:, context: "queue", label: "queue", force_research: true).data[:enrichments].last)
Categories.research(request)  # ledger_result(Categories::Judge.call(book:, context: "queue", label: "queue", force_research: true).data[:enrichments].last)

# EnrichBook.call(book:, force_research: false, author_names: nil, goodreads_page: nil, context: nil)
#   context, when given, is recorded on every row the call writes that has facts or failed:
#   facts merged with {"context" => LedgerEntries.input(context)} (through RecordBookFacts' extra_facts, and on the failed rows).
# EnrichAuthor.call(author:, allow_research: true, force_research: false, context: nil)
#   force_research: after the placeholder skip, run(:research) at once (no knowledge call, no `complete?` skip, no budget or mode check).
#   context: as for EnrichBook.
# Categories::Judge: `rejudge:` is false for context "queue" as well as "import".

# enrichment.rb — against_research_cap also leaves out queue-worker rows, in either shape:
#   .where.not("COALESCE(facts #>> '{context,value}', facts->>'context', '') = 'queue'")

Services::EnrichmentQueue::Research.call(kind:)
# => Result. Fails (errors ["... has no paid research path"]) when the type's paid_research? is false.
# Claims one row (Claim.call(kind:, limit: 1, user: nil)); with none, success with data: {request: nil}.
# Runs type.research(row). On a successful Result: one guarded UPDATE (WHERE id, status claimed, lease_token = the claim's)
# to status done, outcome, enrichment_id, resolved_via paid_research, resolved_at now, lease cleared.
# On a failed Result or a raise: the same guard, to status failed, error (first Apply::MAX_ERROR characters),
# resolved_via paid_research, resolved_at now, lease cleared; returns a failure Result and does not raise.
# Logs "event=enrichment_queue_research kind=... request_id=... status=...".

EnrichmentQueue::ResearchJob   # sidekiq_options queue: :low, retry: 0;  perform(kind) calls Research.call(kind: kind)
```

- `Claim` accepts `user: nil` (`claimed_by_id` is then null).
- Rake, in `lib/tasks/enrichment_queue.rake`:

```
bin/rails "enrichment_queue:work[books.origin,100]"
```
  Aborts with a usage line unless the kind is registered, its type's `paid_research?` is true and the limit is a positive integer (the limit is required). Queues `[limit, claimable rows of that kind].min` `ResearchJob`s and prints: `Queued N paid research job(s) for <kind> (M claimable). Each can spend one web search.`

- [ ] **Step 1: Write the failing tests.**

  `research_test.rb` (with `EnrichmentQueueTestType`, given `attr_accessor :paid, :research_result`, `def paid_research? = paid`, `def research(request) = research_result.respond_to?(:call) ? research_result.call(request) : research_result`, both reset in `reset!`):
  - a successful research closes the row `done` with the outcome, `resolved_via "paid_research"`, `resolved_at` set, `resolved_by` nil, lease cleared, `attempts` 1.
  - a failed Result leaves the row `failed` with the error and returns a failure; a raise does the same and does not propagate.
  - an empty queue is a success with `data[:request]` nil and `research` is never called.
  - a type without a paid path is a failure and claims nothing.
  - `"a row taken over while the research ran is not overwritten"`: `research_result` is a lambda that sets the row's `lease_token` to another value → the row is still `claimed` afterwards.
  - a row whose gap closed is closed by the claim (`no_longer_needed`) and not researched.

  `claim_test.rb`: `"a claim with no user leaves claimed_by empty"`.

  Type tests, one pair per type:
  - `"research runs the forced paid path and maps its row"`: stub the enricher or judge (`Services::Books::EnrichBook.expects(:call).with(book: book, force_research: true, context: "queue")`, and the equivalents) to return a result ending on an applied row → success, `data[:outcome] == "applied"`; ending on a failed row → failure with its error; ending on a skipped row (`reason: "disabled"`) → failure `"skipped: disabled"`.
  - `"paid_research? is true"`.

  `enrich_book_test.rb`: `"context is recorded on the row and keeps it out of the import research cap"`: `EnrichBook.call(book:, force_research: true, context: "queue")` with the research task stubbed → `row.facts["context"] == {"value" => "queue", "applied" => false, "reason" => "input"}` and `Enrichment.against_research_cap` does not include the row; the same call without `context` is included. And `"a failed forced run carries the context"`.

  `enrich_author_test.rb`: `"force_research goes straight to research"` (no knowledge task built, works for a complete author and with the budget at 0 and in `queue` mode); `"a placeholder is still skipped under force_research"`; `"context is recorded on the row"`.

  `categories/judge_test.rb`: `"rejudge is false for queue"`, in the form of the file's existing `"rejudge is false for import and true for backfill and admin"`, which stays as it is.

  `enrichment_test.rb`: `"against_research_cap leaves out queue-worker rows in both shapes"`: research rows today with facts `{"context" => "queue"}` and `{"context" => {"value" => "queue"}}` are out; `{"context" => "admin"}`, `{"context" => {"value" => "agent"}}` and `{}` are in.

  `research_job_test.rb`: `perform` calls `Research.call(kind:)`; the job's options are queue `low`, retry `0`.

  `enrichment_queue_rake_test.rb` (follow the file's existing `fill` tests): queues `min(limit, claimable)` jobs inside `Sidekiq::Testing.fake!`; aborts on an unknown kind, a missing limit, a limit of 0, and a type without a paid path.

- [ ] **Step 2: Run them** — FAIL.
- [ ] **Step 3: Generate the job** (`bin/rails generate sidekiq:job enrichment_queue/research`) **and implement.**
- [ ] **Step 4: Run.** `bin/rails test test/lib/services/enrichment_queue test/sidekiq/enrichment_queue test/lib/services/books test/models/enrichment_test.rb test/lib/tasks/enrichment_queue_rake_test.rb` — PASS.
- [ ] **Step 5: Commit.** `git commit -m "Add the paid research worker for the enrichment queues"`

---

### Task 9: The mode line, the E2E test and the documentation

**Files:**
- Modify: `app/controllers/admin/enrichment_queues_base_controller.rb`, `app/views/admin/enrichment_queues_base/index.html.erb`, `e2e/tests/books/admin/enrichment-queues.spec.ts`, `docs/features/enrichment-queue.md`, `docs/features/books_enrichment.md`, `docs/features/mcp-server.md` (only if it names the queue types), `docs/launch-todo.md`, `docs/superpowers/specs/2026-11-17-agent-enrichment-queue-design.md`
- Test: the admin controller test for the page

- [ ] **Step 1: The mode line.** `index` sets `@research_via = Rails.application.config.x.ai.research_via`. Under the page's intro paragraph, one `<p class="text-sm" data-testid="research-via">`: in `queue` mode, "Web searches are sent to these queues, not run (AI_RESEARCH_VIA=queue)."; otherwise "Web searches still run through the paid API (AI_RESEARCH_VIA=api). Set AI_RESEARCH_VIA=queue to send them here instead." Controller test: the page answers 200 in both modes (no copy assertions).

- [ ] **Step 2: E2E.** In `enrichment-queues.spec.ts` add one test: the rows `queue-row-book_facts` and `queue-row-author_facts` are visible, and each row's Copy prompt source contains `claim_enrichment_items`. It reads only; it does not press Fill.

- [ ] **Step 3: `docs/features/enrichment-queue.md`.** Rename "The two types" to "The four types" and add the two new ones (candidates, payload, what is written, the strict review, the overall-low hold). Add a section "The web-search switch" (the setting, what each of the four places records, reason `queued` and `deferred_reason`, when a row is and is not inserted, the held guess and its exception, force research, the backfill rule) and a section "The paid worker" (the rake task, one job per row, `paid_research`, context `queue`, the caps, what a failure leaves). Extend "Adding a type" with `priority_for`, `paid_research?` and `research`. Update "Rake task" and "Not built yet" (only series review and reader corrections remain).

- [ ] **Step 4: `docs/features/books_enrichment.md`.** Where it describes `EnrichBook`, `EnrichAuthor` and the research caps: the shared record classes, the switch, that skipped research rows do not count toward the cap, and that queue-worker rows do not either.

- [ ] **Step 5: `docs/launch-todo.md` section 14.** After the step that turns the categories judge on, add a step: set `AI_RESEARCH_VIA=queue` in the production environment (worded as that step words `BOOKS_CATEGORIES_JUDGE_ENABLED`), and say what it does. Before the existing "Origins through the agent queue" step, add two steps in the same form: **book facts through the agent queue** first (an agent's book facts row counts as web-verified evidence for the origin and categories answers that follow), then **author facts through the agent queue** (the origin payload shows author nationalities). Renumber the later steps and fix every reference to a step number in the section. Add the paid worker as the fallback for what the agents skip: `bin/rails "enrichment_queue:work[books.origin,100]"`.

- [ ] **Step 6: The spec.** In section 10 mark each ruling of this plan that changes its wording with "(amended during planning, 2026-11-18)": the held guess (ruling 1), the row only when still needed (2), the strict review (4), the overall-low hold (5), one job per row (8), the judges called directly and rejudge off (9), the rake argument (10). In section 5, correct the sentence that still says `Backfill.done_rows` leaves out agent rows with outcome `nothing_to_apply`: it leaves out every agent row that is not `applied`.

- [ ] **Step 7: Run and commit.** `bin/rails test test/controllers/admin test/lint` — PASS. `git commit -m "Enrichment queue increment 2: mode line, E2E and documentation"`

---

### Task 10: Whole-branch verification

- [ ] `yarn build:all`
- [ ] `bin/rails test` — 0 failures, 0 errors, no new warnings. Save the summary line.
- [ ] `bundle exec standardrb`
- [ ] `CI=1 bin/rails zeitwerk:check`
- [ ] `git diff origin/main --stat -- web-app/db` is empty (no migration, no schema change).
- [ ] `git diff origin/main -- web-app/test/lib/services/books/enrich_book_test.rb web-app/test/lib/services/books/authors/enrich_author_test.rb web-app/test/lib/services/books/origin/judge_test.rb web-app/test/lib/services/books/categories/judge_test.rb | grep '^-[^-]'` prints nothing (additions only).
- [ ] Playwright. First check the port: `pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"`. If another checkout holds it: do not start a server, do not kill anything, do not use another port; report that the specs were not run and which checkout holds the port. If it is free: start `bin/rails server` in the background, run `yarn test:e2e e2e/tests/books/admin/enrichment-queues.spec.ts`, stop only the server you started.
