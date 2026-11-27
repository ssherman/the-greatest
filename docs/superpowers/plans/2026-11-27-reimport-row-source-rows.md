# Source Rows and a Row-Move Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the Goodreads CSV row on `reimport_row` and `reimport_mixed` repair verdicts (API, MCP, admin page) and give the admin page a copy prompt for reviewing proposed row moves.

**Architecture:** `Services::Books::RepairVerdicts::SourceRows` learns to read re-import row keys (our own import id plus row number) beside the old `payload["rows"]` legacy pairs; the API resource and admin page already render whatever it returns. A new `row_moves` queue in `Services::AgentPrompts` renders `config/mcp/books/prompts/row_moves.md.erb`, which the repair-verdicts index copies when filtered to `kind=reimport_row`.

**Tech Stack:** Rails 8, Minitest + fixtures, ERB prompt templates, OpenAPI YAML.

**Spec:** `docs/superpowers/specs/2026-11-27-reimport-row-source-rows-design.md`

## Global Constraints

- Run Rails commands from `web-app/`; docs are in `docs/` at the project root.
- The API response shape does not change: `source_rows[]` keeps `import_id, row_number, title, author, isbn13, goodreads_book_id`, and `import_id` stays the old site's import id (`row.import.legacy_import_id`).
- `reimport_guess` is not touched: its `source_rows` stays empty by design.
- `correct_repair_verdict` stays `reimport_match`-only.
- Review rule, word for word in substance in the prompt and the doc: approve when the CSV row's title and author name the to-book and clearly not the from-book; reject when the CSV row actually is the from-book, or when it is unclear. A "move" (not a "copy") means no other CSV row of that reader lands on the from-book. Rejecting a wrong move leaves the reader where they are.
- Lint with `bundle exec standardrb`, never `bin/rubocop`. Minitest 6: use `assert_nil`, not `assert_equal nil`.

## Review Focus

- A `reimport_row` verdict whose payload lacks `import_id` or `row_number` → `source_rows` is `[]` and `source_row_count` is 0 (not a `[nil, nil]` key counted as 1). Test in Task 1.
- A re-import key naming an import or row that no longer exists → dropped from `source_rows`, still counted in `source_row_count` (same as legacy pairs today). Test in Task 1.
- A `reimport_mixed` verdict with more than 20 `row_keys` → `limit:` caps the rows, the count is the full number. Test in Task 1.
- Re-import keys must not be looked up as legacy ids: an import whose `legacy_import_id` happens to equal our import id must not be returned. Test in Task 1.
- The default (unfiltered) and `reimport_author` pages keep their prompts. Existing controller tests cover them; Task 2 must keep them green.

---

### Task 1: SourceRows reads re-import row keys

**Files:**
- Modify: `web-app/app/lib/services/books/repair_verdicts/source_rows.rb`
- Create: `web-app/test/lib/services/books/repair_verdicts/source_rows_test.rb`
- Modify: `web-app/test/controllers/api/v1/admin/books/repair_verdicts_controller_test.rb`
- Modify: `web-app/config/api/v1/admin_openapi.yaml` (the `source_rows` description, ~line 6462)
- Modify: `docs/features/mcp-server.md` (the `get_repair_verdict` line in "Repair verdicts", ~line 220)

**Interfaces:**
- Produces: `SourceRows.pairs(verdict) -> Array<[Integer, Integer]>` (unchanged name; now kind-aware) and `SourceRows.call(verdict, limit: nil) -> Array<Books::GoodreadsImportRow>` (rows with `:import` and `:goodreads_edition` loaded, in key order).

- [ ] **Step 1: Write the failing unit tests** in `source_rows_test.rb` (`module Services; module Books; module RepairVerdicts; class SourceRowsTest < ActiveSupport::TestCase`), with a local `verdict(key, kind:, payload:)` helper like `filter_test.rb`'s. Setup: an import `::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 4242)` with rows 1..25 (`raw: {"Title" => "Title N", "Author" => "Author N"}`).

```ruby
test "a reimport_row verdict resolves its own import id and row number" do
  v = verdict("reimport:row:#{@import.id}:3", kind: :reimport_row, payload: {"import_id" => @import.id, "row_number" => 3})
  assert_equal [[@import.id, 3]], SourceRows.pairs(v)
  assert_equal [@import.rows.find_by(row_number: 3)], SourceRows.call(v)
end

test "a reimport_row verdict without its import id or row number has no rows" do
  v = verdict("t:bare", kind: :reimport_row, payload: {"row_number" => 3})
  assert_equal [], SourceRows.pairs(v)
  assert_equal [], SourceRows.call(v)
end

test "a reimport_mixed verdict resolves its row_keys, capped by limit, dropping keys that name no row" do
  keys = (1..25).map { |n| [@import.id, n] } + [[@import.id, 999]]
  v = verdict("t:mixed", kind: :reimport_mixed, payload: {"row_keys" => keys})
  assert_equal 26, SourceRows.pairs(v).size
  assert_equal (1..20).to_a, SourceRows.call(v, limit: 20).map(&:row_number)
  assert_equal (1..25).to_a, SourceRows.call(v).map(&:row_number)
end

test "re-import keys are our import ids, never legacy ids" do
  decoy = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: @import.id + 1_000_000)
  decoy.rows.create!(row_number: 1, raw: {"Title" => "Decoy"})
  v = verdict("t:ours", kind: :reimport_row, payload: {"import_id" => decoy.legacy_import_id, "row_number" => 1})
  assert_equal [], SourceRows.call(v)
end

test "a verdict with legacy rows pairs still resolves them through legacy_import_id" do
  v = verdict("t:legacy", kind: :fix_identity, payload: {"rows" => [[4242, 2]]})
  assert_equal [@import.rows.find_by(row_number: 2)], SourceRows.call(v)
end
```

- [ ] **Step 2: Run them and see the re-import ones fail**

Run: `bin/rails test test/lib/services/books/repair_verdicts/source_rows_test.rb`
Expected: the reimport_row and reimport_mixed tests FAIL (empty results); the legacy and "never legacy ids" tests pass.

- [ ] **Step 3: Implement** in `source_rows.rb`. `pairs` dispatches on kind: `reimport_row?` → `[[import_id, row_number]]` when both are present, else `[]`; `reimport_mixed?` → `Array(payload["row_keys"])`; otherwise `Array(payload["rows"])` as today. `call` skips the `legacy_import_id` lookup for the two re-import kinds (their keys are already `[import_id, row_number]`) and runs the existing rows query from there. Update the class comment to say which key form each kind stores.

- [ ] **Step 4: Run the unit tests**

Run: `bin/rails test test/lib/services/books/repair_verdicts/source_rows_test.rb`
Expected: PASS.

- [ ] **Step 5: Add the API request test** in `repair_verdicts_controller_test.rb`, beside "source rows come from the payload pairs":

```ruby
test "get a reimport_row verdict returns its CSV row and both books" do
  import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 5151)
  edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 888, signature: "sig-888", title: "T", primary_author: "A", isbn13: "9780307387899")
  import.rows.create!(row_number: 4, raw: {"Title" => "The Wager", "Author" => "David Grann"}, goodreads_edition: edition)
  move = verdict("reimport:row:#{import.id}:4", kind: :reimport_row,
    payload: {"import_id" => import.id, "row_number" => 4, "user_id" => users(:regular_user).id, "action" => "move",
              "from_book_id" => @crime.id, "to_book_id" => @war.id, "review" => false, "superseded_by" => nil})

  fetch(move.id)
  assert_api_response_conform(status: 200, api: :admin)

  data = json[:data]
  assert_equal [{import_id: 5151, row_number: 4, title: "The Wager", author: "David Grann", isbn13: "9780307387899", goodreads_book_id: 888}],
    data[:source_rows]
  assert_equal 1, data[:source_row_count]
  assert_equal [@crime.id, @war.id].sort, data[:books].map { |book| book[:id] }.sort
end
```

- [ ] **Step 6: Run the API controller test file**

Run: `bin/rails test test/controllers/api/v1/admin/books/repair_verdicts_controller_test.rb`
Expected: PASS (the resource needs no change; if it fails, the fault is in `SourceRows`).

- [ ] **Step 7: Document the id.** In `admin_openapi.yaml`, extend the `source_rows` description: `import_id` is the old site's import id; a re-import verdict's `payload.import_id` is our own import id, so the two differ. Rows are shown for verdicts that carry rows: legacy replay findings, `reimport_row` and `reimport_mixed`. In `docs/features/mcp-server.md`, the `get_repair_verdict` line gets the same two facts in one sentence.

- [ ] **Step 8: Lint and commit**

Run: `bundle exec standardrb app/lib/services/books/repair_verdicts test/lib/services/books/repair_verdicts test/controllers/api/v1/admin/books` → no offenses.

```bash
git add web-app/app/lib/services/books/repair_verdicts/source_rows.rb web-app/test/lib/services/books/repair_verdicts/source_rows_test.rb \
  web-app/test/controllers/api/v1/admin/books/repair_verdicts_controller_test.rb web-app/config/api/v1/admin_openapi.yaml docs/features/mcp-server.md
git commit -m "Source rows for re-import row and mixed verdicts"
```

---

### Task 2: Row-move prompt and review docs

**Files:**
- Create: `web-app/config/mcp/books/prompts/row_moves.md.erb`
- Modify: `web-app/app/lib/services/agent_prompts.rb` (`QUEUES`, `counts`)
- Modify: `web-app/app/controllers/admin/books/repair_verdicts_controller.rb:25-26`
- Modify: `web-app/test/lib/services/agent_prompts_test.rb`
- Modify: `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`
- Modify: `docs/features/goodreads-reimport.md` (new section after "Reviewing proposed matches")

**Interfaces:**
- Consumes: Task 1's populated `source_rows` (the prompt tells the agent to read it).
- Produces: `AgentPrompts.call(domain: :books, queue: :row_moves) -> String`; template local `pending_row_moves` (Integer).

- [ ] **Step 1: Write the failing tests.** In `agent_prompts_test.rb`, mirroring the two author-verdict tests:

```ruby
test "row moves renders the admin MCP url, the proposed row move count, the tools and the rule" do
  count = ::Books::RepairVerdict.reimport_row.proposed.current.count
  prompt = AgentPrompts.call(domain: :books, queue: :row_moves)

  assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
  assert_includes prompt, "#{count} proposed reimport_row"
  assert_includes prompt, "kind=reimport_row"
  assert_includes prompt, "source_rows"
  %w[list_repair_verdicts get_repair_verdict approve_repair_verdict reject_repair_verdict bulk_approve_repair_verdicts].each do |tool|
    assert_includes prompt, tool
  end
end

test "row moves counts only proposed, current reimport_row verdicts" do
  # same shape as the author-verdicts count test: approved, superseded and a reimport_match leave the count alone;
  # one proposed reimport_row adds one. Regex: /(\d+) proposed reimport_row/
end
```

In the admin `repair_verdicts_controller_test.rb`, beside the author-verdicts prompt test:

```ruby
test "index filtered to row verdicts assigns the row moves prompt" do
  sign_in_as(@admin, stub_auth: true)
  get admin_books_repair_verdicts_path(kind: "reimport_row")
  assert_response :success
  assert_equal Services::AgentPrompts.call(domain: :books, queue: :row_moves), @controller.view_assigns["agent_prompt"]
end
```

- [ ] **Step 2: Run them and see them fail**

Run: `bin/rails test test/lib/services/agent_prompts_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb`
Expected: FAIL (`ArgumentError: unknown queue :row_moves`).

- [ ] **Step 3: Implement.** Add `row_moves` to `QUEUES`; in `counts`, `when :row_moves then {pending_row_moves: ::Books::RepairVerdict.current.reimport_row.proposed.count}`. In the controller, pick `:author_verdicts` for `reimport_author`, `:row_moves` for `reimport_row`, else `:repair_verdicts`, and update the comment above it.

- [ ] **Step 4: Write `row_moves.md.erb`** in the voice and layout of `author_verdicts.md.erb`. It must say, in this order:
  1. What these are: a reimport_row proposes moving a reader's Goodreads row from one book to another; it is proposed (not automatic) only because the move takes the entry off a trusted book (one on a curated list). The usual cause is the old site's importer guessing the trusted book and stamping this edition's Goodreads id onto it; the risk is a reader who genuinely has it. The queue holds `<%= pending_row_moves %> proposed reimport_row verdicts`. Work through all of them.
  2. List with `list_repair_verdicts` with `kind=reimport_row`, paging through.
  3. Reading one (`get_repair_verdict`): `payload.from_book_id` and `payload.to_book_id` are both in `books`; `source_rows` is the reader's CSV row (title and author as the reader's Goodreads export gave them, plus ISBN-13 and Goodreads id).
  4. The rule from Global Constraints, and that approving moves the entry while rejecting leaves the reader where they are.
  5. There is no correct for a row move (`correct_repair_verdict` takes only matches); do not change books, matches or authors from this queue.
  6. `bulk_approve_repair_verdicts` only for verdicts read with `get_repair_verdict`; nothing changes until the next `books:goodreads_reimport:apply`; act without asking; if `source_rows` is empty, skip and say so.
  7. Report each verdict's id, approved/rejected/skipped and one line of reasoning.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/services/agent_prompts_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Docs.** Add `## Reviewing proposed row moves` to `docs/features/goodreads-reimport.md` after "Reviewing proposed matches": why a row move is proposed (trusted from-book, `DecideRow#settle`, `Cohort.trusted?`) and the usual cause; where to review (Admin, Repair verdicts, filtered to `reimport_row`; the CSV row is under "Source rows"); the rule; approve vs reject outcomes and that there is no correct; and that the page's Copy prompt, filtered to `reimport_row`, gives an agent the row-move prompt.

- [ ] **Step 7: Lint and commit**

Run: `bundle exec standardrb app/lib/services/agent_prompts.rb app/controllers/admin/books test/lib/services/agent_prompts_test.rb test/controllers/admin/books` → no offenses.

```bash
git add web-app/config/mcp/books/prompts/row_moves.md.erb web-app/app/lib/services/agent_prompts.rb \
  web-app/app/controllers/admin/books/repair_verdicts_controller.rb web-app/test/lib/services/agent_prompts_test.rb \
  web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb docs/features/goodreads-reimport.md
git commit -m "Row-move agent prompt and review docs for proposed reimport_row verdicts"
```

---

### Task 3: Whole-suite check

- [ ] **Step 1:** `bin/rails test` → 0 failures, 0 errors, and no new warning lines.
- [ ] **Step 2:** `bundle exec standardrb` → no offenses.
