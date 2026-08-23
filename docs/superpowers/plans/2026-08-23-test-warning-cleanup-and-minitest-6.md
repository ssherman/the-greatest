# Test Warning Cleanup & Minitest 6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every warning source we control from `bin/rails test` (~190 lines → ~47) and upgrade minitest 5.27 → 6.0.6.

**Architecture:** Nine sequential tasks, each independently testable and committable. Task 2 **must** land before Task 3 — the minitest 6 bump turns three currently-warning assertions into hard failures, so reversing the order leaves a red commit on a branch whose CI gates every deploy. Documentation lands with the change it documents rather than in one lump at the end.

**Tech Stack:** Rails 8.1.3.1, Ruby 4.0.6, Minitest, Mocha, ViewComponent, Sidekiq 8.1.7, opensearch-ruby 3.4.0.

**Spec:** `docs/specs/test-warning-cleanup-and-minitest-6.md`

## Global Constraints

- **Working directory is `web-app/`** for every Rails/yarn command. Docs live in `docs/` at the **project root**. `pwd` if unsure.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. Do not run brakeman.
- **Never run a destructive DB command against development.** A `PreToolUse` hook blocks `create_fixtures`, `db:drop`, `db:reset`, `db:schema:load`, bulk `delete_all`/`destroy_all`/`update_all`, and raw `DROP`/`TRUNCATE`/`DELETE FROM` unless `RAILS_ENV=test` is explicit. To inspect a fixture, read the YAML.
- **Never run two `bin/rails test` processes at once.** They share `the_greatest_test`; a concurrent run produces phantom failures (this cost real time during planning — a stray background run manufactured 33 failures in a green suite).
- **No commit may be red.** CI (`bin/rails test` + `standardrb`) blocks the merge and gates the image build.
- **Baseline to preserve:** `7362 runs, 161787 assertions, 0 failures, 0 errors, 0 skips`.
- **Every new or rewritten test must be verified red-when-broken** before it is trusted. Break the code under test, watch it fail, restore. This codebase has a documented history of vacuous assertions passing against deleted code.
- Minitest is pinned at `~> 5.0` until Task 3. Do **not** add a `minitest-mock` gem at any point — it is not needed.
- No production behavior change. The Sidekiq log-level change is test-environment only.

---

### Task 1: Remove the unused `ruby_llm-schema` gem

The gem is entirely unused: nothing subclasses `RubyLLM::Schema`, and all 15 concrete `response_schema` implementations return `OpenAI::BaseModel` subclasses. Removing it also strands two branches that only existed for RubyLLM, one of which is a live latent bug.

**Files:**
- Modify: `web-app/Gemfile:53` (delete `gem "ruby_llm-schema"`)
- Modify: `web-app/Gemfile.lock` (via bundler)
- Modify: `web-app/app/lib/services/ai/tasks/base_task.rb:101, 130-138`
- Modify: `web-app/app/lib/services/ai/capable.rb:8-14`
- Modify: `CLAUDE.md` (conventions)
- Modify: `docs/specs/completed/013-ai-chat-service.md`
- Test: `web-app/test/lib/services/ai/tasks/base_task_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::Ai::Tasks::BaseTask#schema_to_json(schema)` → `String` (JSON). `Services::Ai::Capable#user_prompt_with_fallbacks` → `String`.

- [ ] **Step 1: Confirm the gem is genuinely unused**

Run from `web-app/`:
```bash
grep -rn "RubyLLM\|ruby_llm\|Schematist" --include="*.rb" --include="*.rake" --include="*.erb" app lib test config
```
Expected: exactly two hits, both *comments*, at `app/lib/services/ai/tasks/base_task.rb:101` and `:136`. If any hit is real code, **stop and report** — the rest of this task is invalid.

- [ ] **Step 2: Write the failing test for the `capable.rb` latent bug**

`Services::Ai::Capable#user_prompt_with_fallbacks` only runs when the provider lacks `:json_schema`. OpenAI is the sole live provider and supports it, so this path never fires today — but the Anthropic and Gemini strategies are commented out at `base_task.rb:90-94` and uncommenting either arms a `NoMethodError`. `OpenAI::BaseModel` defines `to_json_schema` on the **class**, not the instance.

Add to `web-app/test/lib/services/ai/tasks/base_task_test.rb`, inside `class BaseTaskTest`:

```ruby
test "inlines the JSON schema when the provider cannot enforce one" do
  # OpenAI advertises :json_schema, so this fallback is dead today. It becomes
  # live the moment a provider without that capability is wired up (the
  # Anthropic and Gemini strategies are commented out in base_task.rb).
  @mock_strategy.stubs(:capabilities).returns([:json_mode])
  task = Music::ArtistDescriptionTask.new(parent: @artist)

  prompt = task.send(:user_prompt_with_fallbacks)

  assert_includes prompt, "IMPORTANT: respond with JSON that validates against:"
  assert_includes prompt, Music::ArtistDescriptionTask::ResponseSchema.to_json_schema.to_json
  assert_includes prompt, task.send(:user_prompt)
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/ai/tasks/base_task_test.rb -n "/cannot enforce one/"
```
Expected: **FAIL** with `NoMethodError: undefined method 'to_json_schema' for an instance of Class` (or similar), raised from `capable.rb:11`. This failure is the proof the bug is real — do not skip it.

- [ ] **Step 4: Fix `capable.rb`**

In `web-app/app/lib/services/ai/capable.rb`, change line 11 from `#{response_schema.new.to_json_schema.to_json}` to:

```ruby
            #{response_schema.to_json_schema.to_json}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/ai/tasks/base_task_test.rb -n "/cannot enforce one/"
```
Expected: **PASS**, 1 run, 3 assertions.

- [ ] **Step 6: Collapse the dead RubyLLM branch in `base_task.rb`**

Replace the whole `schema_to_json` method (`base_task.rb:130-138`) with:

```ruby
        def schema_to_json(schema)
          schema.to_json_schema.to_json
        end
```

The deleted `else` branch called `schema.new.to_json_schema`, which was the RubyLLM instance-level API. It is unreachable — every `response_schema` is an `OpenAI::BaseModel` — and would have raised `NoMethodError` if it ever ran.

- [ ] **Step 7: Fix the stale comment at `base_task.rb:101`**

Change `# All providers now use RubyLLM schema validation` to:

```ruby
          # Schemas are OpenAI::BaseModel subclasses; validate! is an instance method.
```

- [ ] **Step 8: Run the AI service tests**

```bash
bin/rails test test/lib/services/ai/
```
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 9: Delete the gem and reinstall**

Delete line 53 of `web-app/Gemfile` (`gem "ruby_llm-schema"`), then:
```bash
bundle install
grep -c "ruby_llm-schema\|schematist" Gemfile.lock
```
Expected: `0`. Both leave the lockfile — `schematist` was pulled in solely by `ruby_llm-schema`.

- [ ] **Step 10: Verify the deprecation banner is gone**

```bash
bin/rails test test/models/user_test.rb 2>&1 | grep -c "ruby_llm-schema"
```
Expected: `0` (it was 1 banner of 8 lines on every process boot).

- [ ] **Step 11: Update the docs**

In `CLAUDE.md`, under **Non-negotiable conventions**, add:

```markdown
- **AI response schemas are `OpenAI::BaseModel` subclasses.** `to_json_schema` is a **class** method —
  `schema.new.to_json_schema` raises `NoMethodError`. There is no `RubyLLM::Schema` in this app.
```

In `docs/specs/completed/013-ai-chat-service.md`, replace the `- ruby_llm-schema gem for JSON schema definitions` line with:

```markdown
- `OpenAI::BaseModel` for JSON schema definitions (the original `ruby_llm-schema` gem was removed 2026-08-23; it was never used)
```

- [ ] **Step 12: Lint and commit**

```bash
bundle exec standardrb
git add web-app/Gemfile web-app/Gemfile.lock web-app/app/lib/services/ai/ web-app/test/lib/services/ai/ CLAUDE.md docs/specs/completed/013-ai-chat-service.md
git commit -m "chore: drop the unused ruby_llm-schema gem

The gem was never used -- nothing subclassed RubyLLM::Schema and all 15
response_schema implementations return OpenAI::BaseModel subclasses. It
printed an 8-line deprecation banner on every process boot.

Removing it strands two RubyLLM-era branches. base_task#schema_to_json's
else branch was unreachable. capable.rb's was a live latent bug: it called
to_json_schema on an instance, which OpenAI::BaseModel defines on the class,
so wiring up any provider without :json_schema would have raised NoMethodError."
```

---

### Task 2: Fix the seven nil-expected assertions

Seven `assert_equal` calls receive nil as the expected value at runtime, so they read `assert_equal nil, nil` — deprecated under minitest 5.27 and a hard failure under 6. They are also vacuous: proving `nil == nil` says nothing about whether the value was preserved.

**Files:**
- Modify: `web-app/test/models/music/artist_test.rb:236-238, 264-266`
- Modify: `web-app/test/lib/categories/updater_test.rb:96`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. Task 3 depends on these three tests passing under minitest 6.

- [ ] **Step 1: Confirm the current warnings and their exact sites**

```bash
bin/rails test test/models/music/artist_test.rb test/lib/categories/updater_test.rb 2>&1 | grep -c "Use assert_nil"
```
Expected: `7`.

- [ ] **Step 2: Rewrite the first artist_test group**

In `web-app/test/models/music/artist_test.rb`, in `test "should handle AI task failure gracefully"`, replace these five lines (currently 234-238):

```ruby
      assert_equal original_description, @person.description
      assert_equal original_born_on, @person.born_on
      assert_equal original_year_died, @person.year_died
      assert_equal original_country, @person.country
      assert_equal original_kind, @person.kind
```

with:

```ruby
      # Compared as a tuple, not five separate assert_equal calls: three of these
      # fixture columns are nil, so `assert_equal nil, nil` is both vacuous and a
      # hard failure under Minitest 6. An Array expectation is never nil, and one
      # diff names whichever attribute actually moved.
      assert_equal [original_description, original_born_on, original_year_died,
        original_country, original_kind],
        [@person.description, @person.born_on, @person.year_died,
          @person.country, @person.kind]
```

- [ ] **Step 3: Rewrite the second artist_test group**

In the same file, in `test "should handle AI task exceptions gracefully"`, replace the identical five lines (currently 262-266) with the same tuple comparison, but **without** repeating the comment (one explanation in the file is enough):

```ruby
      assert_equal [original_description, original_born_on, original_year_died,
        original_country, original_kind],
        [@person.description, @person.born_on, @person.year_died,
          @person.country, @person.kind]
```

- [ ] **Step 4: Rewrite the updater_test group**

In `web-app/test/lib/categories/updater_test.rb`, in `test "should preserve other attributes when creating renamed category"`, replace lines 92-96:

```ruby
      assert_equal "Updated description", result.description
      assert_equal @test_category.category_type, result.category_type
      assert_equal @test_category.import_source, result.import_source
      assert_equal @test_category.parent, result.parent
```

with:

```ruby
      # Tuple comparison: @test_category.parent is nil, so a bare
      # `assert_equal @test_category.parent, result.parent` is vacuous and fails
      # outright under Minitest 6.
      assert_equal ["Updated description", @test_category.category_type,
        @test_category.import_source, @test_category.parent],
        [result.description, result.category_type,
          result.import_source, result.parent]
```

- [ ] **Step 5: Run the three tests**

```bash
bin/rails test test/models/music/artist_test.rb test/lib/categories/updater_test.rb
```
Expected: PASS, 0 failures. And:
```bash
bin/rails test test/models/music/artist_test.rb test/lib/categories/updater_test.rb 2>&1 | grep -c "Use assert_nil"
```
Expected: `0`.

- [ ] **Step 6: Verify red-when-broken (mandatory)**

The old assertions passed against nil-vs-nil; the new ones must actually detect a change. Temporarily add `@person.update!(country: "Narnia")` immediately before the tuple assertion in `test "should handle AI task exceptions gracefully"`, then:

```bash
bin/rails test test/models/music/artist_test.rb -n "/exceptions gracefully/"
```
Expected: **FAIL**, with a diff naming `"Narnia"`. Remove the line and re-run to confirm PASS. Repeat the same break/restore for `updater_test.rb` (e.g. change the expected `"Updated description"` to `"Wrong"`).

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add web-app/test/models/music/artist_test.rb web-app/test/lib/categories/updater_test.rb
git commit -m "test: compare preserved attributes as tuples, not nil-vs-nil

Seven assert_equal calls received nil as the expected value at runtime,
which Minitest 5.27 deprecates and Minitest 6 rejects outright. They were
also vacuous -- asserting nil == nil proves nothing about preservation.

Tuple expectations are never nil and produce one diff naming whichever
attribute actually moved."
```

---

### Task 3: Upgrade to minitest `~> 6.0`

Must land **after** Task 2. Verified during planning: minitest 6.0.6 runs this suite at `7362 runs, 162598 assertions, 0 errors`, with the only failures being the assertions Task 2 fixed. Mocha 3.1.0, WebMock, 24-worker parallelization, `bin/rails test <file>:<line>`, and `-n /regex/` all work.

**Files:**
- Modify: `web-app/Gemfile:99-100`
- Modify: `web-app/Gemfile.lock` (via bundler)
- Modify: `CLAUDE.md` (testing section)
- Modify: `docs/testing.md` (~line 96, "Testing Standards")

**Interfaces:**
- Consumes: Task 2's fixed assertions.
- Produces: nothing.

- [ ] **Step 1: Bump the pin and drop the stale comment**

In `web-app/Gemfile`, replace lines 99-100:

```ruby
  # Pin minitest to 5.x - version 6.0 is incompatible with Rails 8.x
  gem "minitest", "~> 5.0"
```

with:

```ruby
  gem "minitest", "~> 6.0"
```

The old comment was true when written (Rails ≤ 8.1.1) and became stale when [rails/rails#56434](https://github.com/rails/rails/pull/56434) shipped in Rails 8.1.2. This app runs 8.1.3.1.

- [ ] **Step 2: Install**

```bash
bundle update minitest
grep -n "^    minitest " Gemfile.lock
```
Expected: `minitest (6.0.6)`. **Do not** add `gem "minitest-mock"` — Rails 8.1.3.1 never requires `minitest/mock` (the only file that does, `active_support/testing/method_call_assertions.rb`, is not required by anything).

- [ ] **Step 3: Run the full suite**

```bash
bin/rails test
```
Expected: `7362 runs, 0 failures, 0 errors, 0 skips`. If you see failures mentioning `assert_nil`, Task 2 was not completed — go back, do not work around it here.

- [ ] **Step 4: Verify the runner integrations still work**

```bash
bin/rails test test/lib/categories/updater_test.rb:81
bin/rails test test/models/user_test.rb -n "/valid/"
```
Expected: both run a filtered subset (1 run and 3 runs respectively), 0 failures. These exercise `rails/test_unit/line_filtering.rb`, which the Rails fix rewrote for the MT5/MT6 API split.

- [ ] **Step 5: Confirm the deprecation lines are gone**

```bash
bin/rails test 2>&1 | grep -c "Use assert_nil"
```
Expected: `0`.

- [ ] **Step 6: Document the assertion rules**

In `CLAUDE.md`, under **Testing (Minitest + fixtures + Mocha)**, add:

```markdown
- **Minitest is 6.x.** `assert_equal nil, x` is a **hard failure**, not a warning — use `assert_nil`, or
  compare tuples (`assert_equal [a, b], [x, y]`) when the intent is "these did not change" and one of
  them may be nil. Also gone in 6: `assert_send`, `minitest/mock` (its own gem now — we don't use it),
  the `MiniTest` namespace, and spec expectations on `Object`.
```

In `docs/testing.md`, under **Testing Standards** (~line 96), add a subsection:

```markdown
### Minitest 6 Assertion Rules

Minitest 6 removed several APIs that fail loudly rather than silently:

| Removed | Use instead |
|---|---|
| `assert_equal nil, x` | `assert_nil x`, or a tuple comparison |
| `assert_send` | `assert_predicate` / `assert_operator` |
| `require "minitest/mock"` | Mocha (already the project standard) |
| `MiniTest::...` | `Minitest::...` |
| spec expectations on `Object` | `_(value).must_equal` |

The tuple form matters for "nothing changed" assertions, where the expected value is a variable that
may hold nil:

```ruby
# Fails under Minitest 6 when original_country is nil -- and proved nothing anyway
assert_equal original_country, @person.country

# Expectation is an Array, never nil, and the diff names whichever attribute moved
assert_equal [original_country, original_kind], [@person.country, @person.kind]
```

A nil-expected `assert_equal` is a vacuous assertion as much as a deprecated one — see
"What NOT to Test" above.
```

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add web-app/Gemfile web-app/Gemfile.lock CLAUDE.md docs/testing.md
git commit -m "chore: upgrade minitest to 6.0.6

Rails fixed Minitest 6 compatibility in rails/rails#56434, shipped in
8.1.2; this app runs 8.1.3.1. The Gemfile's incompatibility comment was
stale. Full suite verified green across 24 parallel workers, with line
and name filtering intact."
```

---

### Task 4: Migrate the Sidekiq testing API and quiet its test logging

Two separate warnings from one library: the deprecated `require "sidekiq/testing"` (removed in Sidekiq 9), and 27 `connecting to Redis` INFO lines — one per parallel worker.

**Files:**
- Modify: `web-app/test/test_helper.rb:5, 11`
- Modify: `web-app/config/initializers/sidekiq.rb`
- Modify: `CLAUDE.md` (testing section)
- Modify: `docs/testing.md` (~line 187, "Mocking with Mocha")

**Interfaces:**
- Consumes: nothing.
- Produces: `Sidekiq::Testing.fake!` and `Sidekiq::Testing.inline!` remain available to all tests — the ~30 existing `Sidekiq::Testing.fake! { }` blocks are untouched.

- [ ] **Step 1: Confirm the baseline**

```bash
bin/rails test test/controllers/reviews_controller_test.rb 2>&1 | grep -c "connecting to Redis"
bin/rails test test/models/user_test.rb 2>&1 | grep -c 'sidekiq/testing.*deprecated'
```
Expected: `1` and `1`.

- [ ] **Step 2: Switch to the new test-mode API**

In `web-app/test/test_helper.rb`, delete line 5 (`require "sidekiq/testing"`) and replace line 11:

```ruby
Sidekiq::Testing.inline!
```

with:

```ruby
# Sidekiq 9 removes `require "sidekiq/testing"`. Sidekiq.testing! loads sidekiq/test_api
# itself, which still defines Sidekiq::Testing.fake!/inline! for per-test overrides.
Sidekiq.testing!(:inline)
```

Leave the `# Configure Sidekiq to run jobs inline during tests` comment above it in place.

- [ ] **Step 3: Verify the deprecation is gone and `fake!` blocks still work**

```bash
bin/rails test test/models/user_test.rb 2>&1 | grep -c 'sidekiq/testing.*deprecated'
bin/rails test test/controllers/webhooks/stripe_controller_test.rb test/controllers/reviews_controller_test.rb
```
Expected: `0`, then PASS with 0 failures. Those two files hold most of the ~30 `Sidekiq::Testing.fake! { }` blocks; they are the real check that the old API survived the migration.

- [ ] **Step 4: Quiet the Redis connection logging in test**

Append to `web-app/config/initializers/sidekiq.rb`:

```ruby
if Rails.env.test?
  # Sidekiq logs "connecting to Redis" at INFO on every client connection, which in
  # the test environment means one line per parallel worker (24+) on every run.
  Sidekiq.configure_client do |config|
    config.logger.level = Logger::WARN
  end
end
```

Test-environment only — development and production logging are unchanged.

- [ ] **Step 5: Verify**

```bash
bin/rails test test/controllers/reviews_controller_test.rb 2>&1 | grep -c "connecting to Redis"
bin/rails test test/controllers/reviews_controller_test.rb 2>&1 | tail -3
```
Expected: `0`, and 20 runs / 0 failures.

- [ ] **Step 6: Document**

In `CLAUDE.md`, under **Testing (Minitest + fixtures + Mocha)**, add:

```markdown
- **Sidekiq test mode is `Sidekiq.testing!(:inline)`** (set globally in `test_helper.rb`); never
  `require "sidekiq/testing"`, which Sidekiq 9 removes. `Sidekiq::Testing.fake! { }` blocks still work
  and are how you stop a job from running inline inside one test.
```

In `docs/testing.md`, under **Mocking with Mocha** (~line 187), add:

```markdown
### Sidekiq in Tests

`test_helper.rb` sets `Sidekiq.testing!(:inline)`, so every enqueued job runs immediately. To assert a
job was *enqueued* rather than let it execute, wrap the call:

```ruby
Sidekiq::Testing.fake! do
  post reviews_path, params: {...}
  assert_equal 1, SomeJob.jobs.size
end
```

Never `require "sidekiq/testing"` — Sidekiq 9 removes it. `Sidekiq.testing!` loads the test API itself.
```

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add web-app/test/test_helper.rb web-app/config/initializers/sidekiq.rb CLAUDE.md docs/testing.md
git commit -m "test: migrate to the Sidekiq test-mode API and quiet its Redis logging

require \"sidekiq/testing\" is deprecated and removed in Sidekiq 9;
Sidekiq.testing!(:inline) loads the same test API. Separately, the client
logger sat at INFO in test, so all 24 parallel workers announced their
Redis connection on every run."
```

---

### Task 5: OpenSearch serializer and a single client

`opensearch-ruby`'s default serializer calls `MultiJson.load`/`dump`, all three of which `multi_json 1.21.1` deprecates — 96 lines per run, the single largest source. Supplying a serializer that uses the current method names removes them with no behavior change: same gem, same adapter.

**Files:**
- Create: `web-app/app/lib/search/shared/serializer.rb`
- Modify: `web-app/app/lib/search/shared/client.rb:8-12`
- Modify: `web-app/app/lib/search/base/index.rb:6-8`
- Modify: `web-app/app/lib/search/base/search.rb:6-8`
- Modify: `CLAUDE.md` (conventions)
- Test: `web-app/test/lib/search/shared/serializer_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Search::Shared::Serializer#load(String, Hash) → Object`, `#dump(Object, Hash) → String`. `Search::Shared::Client.instance → OpenSearch::Client`, used by `Search::Base::Index.client` and `Search::Base::Search.client`.

- [ ] **Step 1: Write the failing serializer test**

Create `web-app/test/lib/search/shared/serializer_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Shared
    class SerializerTest < ActiveSupport::TestCase
      setup { @serializer = Search::Shared::Serializer.new }

      test "round-trips a nested document" do
        doc = {"title" => "Kid A", "artists" => ["Radiohead"], "year" => 2000}

        assert_equal doc, @serializer.load(@serializer.dump(doc))
      end

      test "parses to string keys, matching the serializer it replaces" do
        assert_equal({"a" => 1}, @serializer.load(%({"a":1})))
      end

      test "never touches the deprecated MultiJSON aliases" do
        # The entire point of this class. Note this CANNOT be written as
        # `MultiJSON.expects(:generate)` -- the deprecated `MultiJson.dump`
        # forwards to `generate`, so that expectation is satisfied either way
        # and passes against the very code it is meant to reject (confirmed
        # during planning). Guarding the deprecated names with `.never` is what
        # actually discriminates.
        ::MultiJSON.expects(:dump).never
        ::MultiJSON.expects(:load).never

        assert_equal({"a" => 1}, @serializer.load(@serializer.dump({"a" => 1})))
      end
    end
  end
end
```

Do **not** try to assert this by capturing warnings: multi_json warns only once per method per process, so whichever test happens to run first spends the warning and every later assertion passes vacuously.

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/lib/search/shared/serializer_test.rb
```
Expected: **FAIL/ERROR** with `NameError: uninitialized constant Search::Shared::Serializer`.

- [ ] **Step 3: Write the serializer**

Create `web-app/app/lib/search/shared/serializer.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Shared
    # opensearch-ruby's bundled serializer calls MultiJson.load/dump, which
    # multi_json 1.21.1 deprecates in favour of MultiJSON.parse/generate. Same
    # gem and same adapter -- only the method names differ -- so this is a
    # drop-in that stops ~96 deprecation lines per test run.
    class Serializer
      include OpenSearch::Transport::Transport::Serializer::Base

      def load(string, options = {})
        ::MultiJSON.parse(string, options)
      end

      def dump(object, options = {})
        ::MultiJSON.generate(object, options)
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rails test test/lib/search/shared/serializer_test.rb
```
Expected: PASS, 3 runs.

- [ ] **Step 5: Verify red-when-broken (mandatory)**

Temporarily change `::MultiJSON.parse` back to `::MultiJson.load` and `::MultiJSON.generate` to `::MultiJson.dump`, then re-run.

Expected: the "never touches the deprecated MultiJSON aliases" test **FAILS** with `unexpected invocation: MultiJSON.dump(...)`. Restore both lines and confirm PASS.

This step is not a formality — an earlier draft of this test asserted `MultiJSON.expects(:generate)` and passed against the deprecated implementation, because `MultiJson.dump` forwards to `generate`.

- [ ] **Step 6: Wire the serializer into the shared client**

Replace the `instance` method in `web-app/app/lib/search/shared/client.rb`:

```ruby
        def instance
          @instance ||= OpenSearch::Client.new(
            host: ENV.fetch("OPENSEARCH_URL"),
            serializer_class: Search::Shared::Serializer
          )
        end
```

The `log:`/`trace:` options are **deliberately dropped**. They were `Rails.env.development?`, but this client previously served only `health`/`cluster_info`/`ping`. The next step routes all real search traffic through it, and keeping them would log every OpenSearch request in development — noise, inside a change whose purpose is removing noise.

- [ ] **Step 7: Point the two duplicate clients at the shared one**

In `web-app/app/lib/search/base/index.rb`, replace lines 6-8:

```ruby
      def self.client
        Search::Shared::Client.instance
      end
```

Make the identical change in `web-app/app/lib/search/base/search.rb`. Both previously built their own `OpenSearch::Client`, so the app held three separate clients with three connection pools and three places to configure.

- [ ] **Step 8: Run the search tests**

```bash
bin/rails test test/lib/search/
```
Expected: PASS, 0 failures. These hit a real local OpenSearch, so a serialization regression fails loudly rather than silently. If OpenSearch is not running, start it before continuing — do not skip this step.

- [ ] **Step 9: Verify the MultiJSON lines are gone**

```bash
bin/rails test 2>&1 | grep -c "MultiJSON\|MultiJson"
```
Expected: `0` (was 96).

- [ ] **Step 10: Document and commit**

In `CLAUDE.md`, under **Non-negotiable conventions**, add:

```markdown
- **Build OpenSearch clients through `Search::Shared::Client.instance`**, never `OpenSearch::Client.new`.
  It carries the serializer that avoids multi_json's deprecated API; three drifted copies are how that
  warning got three times louder than it needed to be.
```

```bash
bundle exec standardrb
git add web-app/app/lib/search/ web-app/test/lib/search/shared/serializer_test.rb CLAUDE.md
git commit -m "perf: single OpenSearch client with a non-deprecated serializer

opensearch-ruby's bundled serializer calls MultiJson.load/dump, which
multi_json 1.21.1 deprecates -- 96 warning lines per test run. Same gem
and adapter, current method names.

Also collapses three separately-constructed clients (Index, Search, and
the shared one) into Search::Shared::Client, so there is one place to
configure. log:/trace: are dropped: the shared client previously served
only health checks, and enabling them for all search traffic would log
every request in development."
```

---

### Task 6: Test the admin songs wizard modal

The simplest of the six stubs. `Admin::Music::Songs::Wizard::SharedModalComponent` is an empty subclass of `Admin::Music::Wizard::SharedModalComponent` that exists only to namespace inherited constants — and its **albums sibling already has a full test**, which this mirrors exactly.

**Files:**
- Modify: `web-app/test/components/admin/music/songs/wizard/shared_modal_component_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Replace the stub with real tests**

Replace the entire contents of `web-app/test/components/admin/music/songs/wizard/shared_modal_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::SharedModalComponentTest < ViewComponent::TestCase
  test "renders dialog element with correct id" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog##{Admin::Music::Songs::Wizard::SharedModalComponent::DIALOG_ID}"
  end

  test "renders turbo frame with correct id" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "turbo-frame##{Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID}"
  end

  test "renders with shared-modal stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog[data-controller='shared-modal']"
  end

  test "opens the dialog when the turbo frame loads" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog[data-action='turbo:frame-load->shared-modal#open']"
  end

  test "renders loading spinner" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector ".loading.loading-spinner"
  end

  test "renders backdrop form for closing" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "form.modal-backdrop[method='dialog']"
  end

  test "constants are defined correctly" do
    assert_equal "shared_modal_dialog", Admin::Music::Songs::Wizard::SharedModalComponent::DIALOG_ID
    assert_equal "shared_modal_content", Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID
    assert_equal "shared_modal_error", Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID
  end
end
```

- [ ] **Step 2: Run**

```bash
bin/rails test test/components/admin/music/songs/wizard/shared_modal_component_test.rb
```
Expected: PASS, 7 runs, and **no** `Test is missing assertions` line.

- [ ] **Step 3: Verify red-when-broken (mandatory)**

In `web-app/app/components/admin/music/wizard/shared_modal_component.html.erb`, temporarily change `class="modal"` on the `<dialog>` to `class="modal-x"` and delete the `<span class="loading loading-spinner loading-lg">` line. Re-run.
Expected: **FAIL** on "renders loading spinner". Restore both and confirm PASS.

- [ ] **Step 4: Lint and commit**

```bash
bundle exec standardrb
git add web-app/test/components/admin/music/songs/wizard/shared_modal_component_test.rb
git commit -m "test: cover the songs wizard shared modal component

Was an untouched generator stub asserting nothing. Mirrors the existing
albums sibling test."
```

---

### Task 7: Test the two games components

**Files:**
- Modify: `web-app/test/components/games/card_component_test.rb`
- Modify: `web-app/test/components/games/filter_tabs_component_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

Fixture facts verified during planning: `games_games(:breath_of_the_wild)` has title `"The Legend of Zelda: Breath of the Wild"`, slug `the-legend-of-zelda-breath-of-the-wild`, `release_year: 2017`, no attached image, and one developer (`Nintendo`, via `games_game_companies(:botw_nintendo_dev)`). `ranked_items(:games_ranked_botw)` has `rank: 1`.

- [ ] **Step 1: Replace the card stub**

Replace the entire contents of `web-app/test/components/games/card_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Games::CardComponentTest < ViewComponent::TestCase
  setup do
    @game = games_games(:breath_of_the_wild)
  end

  test "requires one of game, ranked_item or list_item" do
    error = assert_raises(ArgumentError) { Games::CardComponent.new }

    assert_equal "Must provide either game:, ranked_item:, or list_item:", error.message
  end

  test "carries the polymorphic pair the list widget needs" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "[data-listable-type='Games::Game'][data-listable-id='#{@game.id}']"
  end

  test "links to the game and breaks out of any enclosing turbo frame" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "a[href='/game/#{@game.slug}'][data-turbo-frame='_top']"
  end

  test "renders the title and release year" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "h2.card-title", text: @game.title
    assert_selector ".card-body", text: /\b2017\b/
  end

  test "names the developer, not every associated company" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "p", text: "by Nintendo"
  end

  test "shows a placeholder when the game has no image" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_selector "figure", text: "No Image"
    assert_no_selector "figure img"
  end

  test "shows no rank badge when rendered from a bare game" do
    render_inline(Games::CardComponent.new(game: @game))

    assert_no_selector ".badge-primary"
  end

  test "shows the rank badge when rendered from a ranked item" do
    render_inline(Games::CardComponent.new(ranked_item: ranked_items(:games_ranked_botw)))

    # Anchored: a bare "#1" substring would also match a corrupted "#12".
    assert_selector ".badge-primary", text: /\A#1\z/
    assert_selector "h2.card-title", text: @game.title
  end

  test "uses the list item position as the rank when given one" do
    # list_items(:games_item) is breath_of_the_wild at position 1 (verified).
    render_inline(Games::CardComponent.new(list_item: list_items(:games_item)))

    assert_selector ".badge-primary", text: /\A#1\z/
  end
end
```

- [ ] **Step 2: Run**

```bash
bin/rails test test/components/games/card_component_test.rb
```
Expected: PASS, and no `Test is missing assertions` line.

- [ ] **Step 3: Replace the filter tabs stub**

`Games::FilterTabsComponent.new(base_path:, year_filter:)` takes a `Filters::YearFilter::Result` (or nil). Build them with `Filters::YearFilter.parse`.

Replace the entire contents of `web-app/test/components/games/filter_tabs_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Games::FilterTabsComponentTest < ViewComponent::TestCase
  test "renders All Time plus one tab per decade" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games", year_filter: nil))

    assert_selector "[role='tablist'] a", count: 6
    assert_selector "a[href='/games']", text: "All Time"
    Games::FilterTabsComponent::DECADES.each do |decade|
      assert_selector "a[href='/games/#{decade}']", text: decade
    end
  end

  test "marks All Time active when there is no year filter" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games", year_filter: nil))

    assert_selector "a.tab-active", text: "All Time"
    assert_selector "a.tab-active", count: 1
  end

  test "marks the matching decade active and All Time inactive" do
    render_inline(Games::FilterTabsComponent.new(
      base_path: "/games", year_filter: ::Filters::YearFilter.parse("1990s")
    ))

    assert_selector "a.tab-active", text: "1990s"
    assert_selector "a.tab-active", count: 1
    assert_no_selector "a.tab-active", text: "All Time"
  end

  test "marks Custom active for a range filter, which matches no decade tab" do
    render_inline(Games::FilterTabsComponent.new(
      base_path: "/games", year_filter: ::Filters::YearFilter.parse("1994-1997")
    ))

    assert_selector "button.tab-active", text: "Custom"
    assert_no_selector "a.tab-active"
  end

  test "passes the base path to the custom range modal controller" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games/best", year_filter: nil))

    assert_selector "[data-controller='year-range-modal'][data-year-range-modal-base-path-value='/games/best']"
  end
end
```

- [ ] **Step 4: Run**

```bash
bin/rails test test/components/games/filter_tabs_component_test.rb
```
Expected: PASS, 5 runs.

- [ ] **Step 5: Verify red-when-broken for both (mandatory)**

Capybara's `text:` is a **substring** match and `default_normalize_ws` is false, so these assertions can pass against broken markup. Prove they don't:

1. In `app/components/games/card_component.rb`, change `developer_names` to `.map { |gc| gc.company.name }` over **all** `game_companies` (drop the `select(&:developer?)`). Re-run the card test — expected **FAIL** on "names the developer".
2. In `app/components/games/filter_tabs_component.rb`, make `all_time_active?` return `true` unconditionally. Re-run the tabs test — expected **FAIL** on "marks the matching decade active" (the `count: 1` assertion).

Restore both and confirm PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add web-app/test/components/games/
git commit -m "test: cover the games card and filter tabs components

Both were untouched generator stubs asserting nothing."
```

---

### Task 8: Test the three music components

**Files:**
- Modify: `web-app/test/components/music/albums/card_component_test.rb`
- Modify: `web-app/test/components/music/artists/card_component_test.rb`
- Modify: `web-app/test/components/music/songs/list_item_component_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

Fixture facts verified during planning: `music_albums(:dark_side_of_the_moon)` renders `a[href='/album/the-dark-side-of-the-moon']` with `data-listable-type="Music::Album"`; `music_artists(:pink_floyd)` renders `a[href='/artists/pink-floyd']`; `music_songs(:time)` has title `"Time"` and `release_year: 1973`; `ranked_items(:music_songs_ranked_item)` has `rank: 42` on song `time`.

- [ ] **Step 1: Replace the album card stub**

```ruby
# frozen_string_literal: true

require "test_helper"

module Music
  module Albums
    class CardComponentTest < ViewComponent::TestCase
      setup do
        @album = music_albums(:dark_side_of_the_moon)
      end

      test "requires either an album or a ranked item" do
        error = assert_raises(ArgumentError) { Music::Albums::CardComponent.new }

        assert_equal "Must provide either album: or ranked_item:", error.message
      end

      test "carries the polymorphic pair the list widget needs" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "[data-listable-type='Music::Album'][data-listable-id='#{@album.id}']"
      end

      test "links to the album and breaks out of any enclosing turbo frame" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "a[href='/album/#{@album.slug}'][data-turbo-frame='_top']"
      end

      test "renders the title and the artist credit" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "h2.card-title", text: @album.title
        assert_selector "p", text: "by #{@album.artists.map(&:name).join(", ")}"
      end

      test "shows a placeholder when the album has no image" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "figure", text: "No Image"
        assert_no_selector "figure img"
      end

      test "shows no rank badge when rendered from a bare album" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_no_selector ".badge-primary"
      end

      test "renders the album from a ranked item" do
        # The only album ranked_item fixture is music_albums_unranked_item (item:
        # animals), which has a nil rank -- verified. Adding a ranked fixture is out
        # of scope; the populated rank-badge branch is covered by the games card and
        # song list item tests.
        #
        # The badge still renders here: show_rank? is `ranked_item.present?`, not
        # `ranked_item.rank.present?`, so a rankless ranked_item produces a badge
        # containing a bare "#". Asserted as-is rather than as desired behaviour --
        # changing the component is not part of this work.
        render_inline(Music::Albums::CardComponent.new(
          ranked_item: ranked_items(:music_albums_unranked_item)
        ))

        assert_selector "h2.card-title", text: music_albums(:animals).title
        assert_selector ".badge-primary"
      end
    end
  end
end
```

- [ ] **Step 2: Replace the artist card stub**

```ruby
# frozen_string_literal: true

require "test_helper"

module Music
  module Artists
    class CardComponentTest < ViewComponent::TestCase
      setup do
        @artist = music_artists(:pink_floyd)
      end

      test "links to the artist and breaks out of any enclosing turbo frame" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "a[href='/artists/#{@artist.slug}'][data-turbo-frame='_top']"
      end

      test "renders the artist name and titleized kind" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "h2.card-title", text: @artist.name
        assert_selector ".card-body", text: @artist.kind.titleize
      end

      test "shows a placeholder when the artist has no image" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "figure", text: "No Image"
        assert_no_selector "figure img"
      end

      test "shows no rank badge without a ranked item" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_no_selector ".badge-primary"
      end

      test "caps the category badges at three and counts the overflow" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_operator page.all(".badge-ghost").count, :<=, 4
      end
    end
  end
end
```

- [ ] **Step 3: Replace the song list item stub**

This component renders a bare `<tr>`, so wrap assertions around cells rather than a card.

```ruby
# frozen_string_literal: true

require "test_helper"

module Music
  module Songs
    class ListItemComponentTest < ViewComponent::TestCase
      setup do
        @song = music_songs(:time)
      end

      test "renders a table row linking to the song" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "tr td a[href='/song/#{@song.slug}']", text: @song.title
      end

      test "renders the release year" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "td", text: /\b1973\b/
      end

      test "carries the polymorphic pair the list widget needs" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "td[data-listable-type='Music::Song'][data-listable-id='#{@song.id}']"
      end

      test "renders no rank or index cell by default" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_no_selector ".badge-primary"
        assert_selector "tr td", count: 4
      end

      test "renders the rank badge when given a ranked item" do
        render_inline(Music::Songs::ListItemComponent.new(
          song: @song, ranked_item: ranked_items(:music_songs_ranked_item)
        ))

        # Anchored: "#42" as a substring would also match a corrupted "#420".
        assert_selector ".badge-primary", text: /\A#42\z/
        assert_selector "tr td", count: 5
      end

      test "renders a plain index cell when given show_index instead of a rank" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song, show_index: 7))

        assert_no_selector ".badge-primary"
        assert_selector "td", text: /\A7\z/
        assert_selector "tr td", count: 5
      end
    end
  end
end
```

- [ ] **Step 4: Run all three**

```bash
bin/rails test test/components/music/
```
Expected: PASS, and no `Test is missing assertions` lines.

- [ ] **Step 5: Verify red-when-broken (mandatory)**

1. In `app/components/music/albums/card_component/card_component.html.erb`, delete the `data-listable-id` attribute. Re-run the album test — expected **FAIL** on "carries the polymorphic pair".
2. In `app/components/music/songs/list_item_component/list_item_component.html.erb`, change `<%= show_index %>` to render nothing. Re-run the song test — expected **FAIL** on "renders a plain index cell".
3. In `app/components/music/artists/card_component.rb`, make `show_rank?` return `true` unconditionally. Re-run the artist test — expected **FAIL** on "shows no rank badge without a ranked item" (it will raise on the nil `ranked_item.rank`, which still counts as red).

Restore all three and confirm PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add web-app/test/components/music/
git commit -m "test: cover the music album, artist and song list components

All three were untouched generator stubs asserting nothing."
```

---

### Task 9: Full verification and the standing no-warnings rule

**Files:**
- Modify: `CLAUDE.md` (testing section)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: nothing.

- [ ] **Step 1: Run the full suite, clean**

Make sure no other `bin/rails test` process is running first:

```bash
ps aux | grep "[r]ails test"
```
Expected: no output. Then:
```bash
bin/rails test 2>&1 | tee /tmp/after.txt | tail -3
```
Expected: `7362 runs, 0 failures, 0 errors, 0 skips`. Assertion count will be slightly higher than the 161787 baseline — Task 6-8 added real assertions where there were none.

- [ ] **Step 2: Confirm every targeted warning is gone**

```bash
for p in "ruby_llm-schema" "MultiJSON" "MultiJson" "connecting to Redis" "Use assert_nil" "sidekiq/testing" "Test is missing assertions"; do
  echo "$p: $(grep -c "$p" /tmp/after.txt)"
done
```
Expected: **every one `0`**. If any is non-zero, the corresponding task is incomplete — fix it there, not here.

- [ ] **Step 3: Confirm what remains is only the two excluded sources**

```bash
sed 's/^\.*//; s/\.*$//' /tmp/after.txt | grep -v '^$' | grep -vE "^(Run options|# Running|Finished in|[0-9]+ runs)" | sort | uniq -c | sort -rn | head -20
```
Expected: only `Item position … is higher than` (weighted_list_rank, ~34) and npm/yarn lines (~13). Anything else is a new warning — report it rather than silencing it.

- [ ] **Step 4: Lint**

```bash
bundle exec standardrb
```
Expected: no offenses.

- [ ] **Step 5: Add the standing rule**

In `CLAUDE.md`, under **Testing (Minitest + fixtures + Mocha)**, add:

```markdown
- **A clean `bin/rails test` emits no warnings** beyond two known upstream sources (`weighted_list_rank`'s
  position `puts`, and npm/yarn during `test:prepare`). A new warning line is a regression — fix the
  cause, don't filter the output. ~190 lines of noise accumulated once because nobody was watching.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: make a warning-free test run a standing rule

~190 lines of warning noise accumulated because nothing treated a new
warning as a regression. Two upstream sources remain and are named."
```

- [ ] **Step 7: Update the spec's status**

In `docs/specs/test-warning-cleanup-and-minitest-6.md`, set **Status** to `Completed`, fill in **Completed** with the date, fill **Acceptance Results** with the before/after numbers from Steps 1-3, and tick the **Documentation Updated** boxes. Move the file to `docs/specs/completed/`.

```bash
git mv docs/specs/test-warning-cleanup-and-minitest-6.md docs/specs/completed/
git add docs/specs/completed/test-warning-cleanup-and-minitest-6.md
git commit -m "docs: close the test warning cleanup spec"
```

---

## Appendix: verified during planning

Do not re-derive these; they cost real time to establish.

- **Minitest 6.0.6 runs this suite.** Measured: `7362 runs, 162598 assertions, 3 failures, 0 errors`, the three failures being Task 2's assertions. Parallel testing across 24 workers, mocha 3.1.0, WebMock, `<file>:<line>` filtering and `-n /regex/` all work.
- **`minitest-mock` is not needed.** Nothing in any Rails 8.1.3.1 gem requires `active_support/testing/method_call_assertions.rb`, the only file that does `require "minitest/mock"`.
- **Plugin loading is handled** by `active_support/testing/autorun.rb:9` — `Minitest.load :rails if Minitest.respond_to? :load`.
- **The Sidekiq log-level fix works.** Measured 1 → 0 Redis INFO lines on `reviews_controller_test.rb`, suite still green.
- **The OpenSearch serializer works against a live cluster.** `ping`, `info`, and `cluster.health` all round-trip through `MultiJSON.parse`/`generate` with no deprecation output.
- **All five non-trivial components render in a bare `ViewComponent::TestCase`** with no host or ranking-configuration setup — the hostname-constrained routes resolve fine.
- **Never run two `bin/rails test` processes at once.** A stray background run manufactured 33 failures in a suite that was actually green.
