# Test Warning Cleanup & Minitest 6 Upgrade

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-08-23
- **Started**:
- **Completed**: 2026-08-23
- **Developer**: Shane Sherman

## Overview

A full `bin/rails test` run emits roughly **190 lines of warning noise** around an otherwise clean
`7362 runs, 161787 assertions, 0 failures`. This spec removes every source we control and upgrades
minitest 5.27 → 6.0.6, which is already compatible with Rails 8.1.3.1.

**Non-goals:** the `weighted_list_rank` `puts` (owner fixes it in that gem) and the npm/yarn build
noise (environment-level; suppressing it would risk stale assets for system/E2E tests).

## Context & Links

### Warning inventory (measured, one full parallel run, 24 workers)

| Warning | Lines | Source | In scope |
|---|---|---|---|
| `[DEPRECATION] ruby_llm-schema is now schematist` | 8 | `web-app/Gemfile:53` | ✅ Inc 1 |
| `MultiJSON.load` / `.dump` / `MultiJson` constant deprecated | 96 | `opensearch-ruby 3.4.0` → `multi_json 1.21.1` | ✅ Inc 5 |
| `Warning: Item position (10/11) is higher than…` | 34 | `weighted_list_rank 0.6.0` raw `puts` | ❌ out |
| Sidekiq `INFO … connecting to Redis` | 27 | Sidekiq client logger at INFO in test | ✅ Inc 4 |
| `DEPRECATED: Use assert_nil if expecting nil` | 7 | 7 assertion sites, 2 files | ✅ Inc 2 |
| `Test is missing assertions:` | 6 | 6 untouched ViewComponent generator stubs | ✅ Inc 6 |
| npm/yarn (`Unknown env config`, `package-lock.json found`) | ~13 | `jsbundling`/`cssbundling` enhance `test:prepare` | ❌ out |
| `⛔️ require "sidekiq/testing"` deprecated | 1 | `web-app/test/test_helper.rb:5` | ✅ Inc 4 |

Target: **~190 → ~47 lines**, the remainder being only the two excluded sources.

### Source files (authoritative)
- `web-app/Gemfile` — gem list and the minitest pin (line 99–100)
- `web-app/test/test_helper.rb` — Sidekiq test mode
- `web-app/app/lib/services/ai/tasks/base_task.rb` — `schema_to_json`, stale RubyLLM comments
- `web-app/app/lib/services/ai/capable.rb` — `user_prompt_with_fallbacks`
- `web-app/app/lib/search/shared/client.rb`, `search/base/index.rb`, `search/base/search.rb`
- `web-app/test/models/music/artist_test.rb`, `web-app/test/lib/categories/updater_test.rb`
- `web-app/test/components/**` — the six stub tests

### External docs
- [rails/rails#56434](https://github.com/rails/rails/pull/56434) — Minitest 6 compatibility, shipped in Rails 8.1.2
- [Minitest 6.0.0 History](https://github.com/minitest/minitest/blob/master/History.rdoc) — the removals
- [Sidekiq testing (new API)](https://sidekiq.org/wiki/Testing#new-api)

## Prior investigation (do not re-derive)

The Gemfile comment *"version 6.0 is incompatible with Rails 8.x"* was true when written and is
**now stale**. Rails 8.1.2 fixed it; this app runs 8.1.3.1.

Verified empirically in-session: pin relaxed to `~> 6.0`, `minitest 6.0.6` installed, full suite run →
**7362 runs, 162598 assertions, 3 failures, 0 errors**. The 3 failures are the same 7 `assert_equal nil`
assertions already warning under 5.27. Mocha 3.1.0, WebMock, 24-worker parallelization,
`bin/rails test <file>:<line>`, and `-n /regex/` all work. Gemfile/Gemfile.lock were restored.

Three theorized blockers were **disproven** — do not resurrect them:
1. `require "minitest/mock"` at `active_support/testing/method_call_assertions.rb:3` — nothing in any
   Rails 8.1.3.1 gem requires that file. It is never loaded by an app test boot. **No `minitest-mock`
   gem is needed.**
2. Plugin loading being opt-in — handled by `active_support/testing/autorun.rb:9`,
   `Minitest.load :rails if Minitest.respond_to? :load`.
3. Marshal removal breaking `ActiveSupport::Testing::Parallelization` — it does not.

## Increments

### Inc 1 — Remove the unused `ruby_llm-schema` gem

The gem is **entirely unused**. No class subclasses `RubyLLM::Schema`; all 15 concrete `response_schema`
implementations return `OpenAI::BaseModel` subclasses (26 such classes counting nested item schemas), and
the 16th `def response_schema` is the base at `base_task.rb:73`, which returns nil. The only repo
references to RubyLLM are two stale *comments*. `schematist` is
pulled in solely by `ruby_llm-schema`, so both leave the lockfile. The migration guide in the
deprecation text (`strict`, `to_json_schema` envelopes) is **moot** — nothing to migrate.

- Delete `gem "ruby_llm-schema"` (`Gemfile:53`); `bundle install`.
- Fix stale comments at `base_task.rb:101` and `:136`.
- Collapse the dead RubyLLM branch in `base_task.rb#schema_to_json` (:132–138). The `else` branch calls
  `schema.new.to_json_schema`; `OpenAI::BaseModel` defines `to_json_schema` on the **class only**, so
  the branch would `NoMethodError` if reached.
- Fix `capable.rb:11`, same instance-vs-class mistake. **This one is a live latent bug, not dead code**:
  `user_prompt_with_fallbacks` runs only when a provider lacks `:json_schema`. OpenAI is the sole live
  provider, so it never fires today — but uncommenting the Anthropic or Gemini strategy at
  `base_task.rb:90–94` arms it.
- Update the `ruby_llm-schema` mention in `docs/specs/completed/013-ai-chat-service.md`.

**Invariant:** `bin/rails test test/lib/services/ai/` stays green; `AiChat#response_schema` payloads
are unchanged (`schema_to_json` returns the same string for every existing task).

### Inc 2 — Fix the 7 nil-expected assertions

| File | Lines |
|---|---|
| `web-app/test/models/music/artist_test.rb` | 236–238, 264–266 |
| `web-app/test/lib/categories/updater_test.rb` | 96 |

All are "assert nothing changed" checks where the fixture column happens to be nil, so they read
`assert_equal nil, nil` at runtime — vacuous as well as deprecated. `assert_nil` would satisfy minitest
but discard the intent. Compare tuples instead: the expected side is an `Array`, never nil, and one
readable diff replaces five assertions while actually asserting unchanged-ness.

```ruby
# reference only — web-app/test/models/music/artist_test.rb
assert_equal [original_description, original_born_on, original_year_died,
              original_country, original_kind],
             [@person.description, @person.born_on, @person.year_died,
              @person.country, @person.kind]
```

**Required:** for each rewritten assertion, break the code under test and confirm the test goes red
before trusting it. Vacuous assertions are a repeat failure mode in this codebase.

### Inc 3 — Upgrade to minitest `~> 6.0`

Ordered **after** Inc 2 so no commit is ever red.

- `Gemfile:99–100` → `gem "minitest", "~> 6.0"`, delete the stale incompatibility comment.
- `bundle update minitest` (resolves 6.0.6).

**Do not** add `gem "minitest-mock"` — see Prior investigation.

### Inc 4 — Sidekiq

- `test_helper.rb:5,11`: replace `require "sidekiq/testing"` + `Sidekiq::Testing.inline!` with
  `Sidekiq.testing!(:inline)`.
- The ~30 `Sidekiq::Testing.fake! { }` blocks across the controller tests **need no change** — that API
  lives on in `sidekiq/test_api.rb`; only the old `require` is deprecated.
- Drop the Sidekiq client logger to `:warn` **for the test environment only**, so 24 workers stop each
  announcing their Redis connection. Must not affect development or production logging.

### Inc 5 — OpenSearch serializer + single client

`opensearch-ruby`'s default serializer calls the deprecated `MultiJson.load`/`dump`. Supply a
`serializer_class:` using `MultiJSON.parse`/`generate` — same gem, same adapter, same behavior, current
method names (both verified present in `multi_json 1.21.1`).

Also consolidate the three duplicate constructions (`search/base/index.rb:7`, `search/base/search.rb:7`,
`search/shared/client.rb:8`) onto `Search::Shared::Client`, so the serializer is configured once.

**Decision — `log:`/`trace:` stay off.** `Search::Shared::Client` currently sets both to
`Rails.env.development?`, but it only serves `health`/`cluster_info`/`ping`. `Index` and `Search` carry
all real traffic with logging off. Consolidating onto the shared client's current settings would log
every OpenSearch request in development — adding noise inside a noise-reduction change.

**Invariant:** serialization round-trips identically. The search tests hit a real local OpenSearch, so a
regression fails loudly.

### Inc 6 — Real tests for six ViewComponent stubs

Six generator stubs are untouched: a single method with the example commented out, asserting nothing.

- `test/components/games/card_component_test.rb`
- `test/components/games/filter_tabs_component_test.rb`
- `test/components/music/albums/card_component_test.rb`
- `test/components/music/artists/card_component_test.rb`
- `test/components/music/songs/list_item_component_test.rb`
- `test/components/admin/music/songs/wizard/shared_modal_component_test.rb`

Real render assertions against existing fixtures, per the 100%-of-public-methods rule.

**Required:** Capybara's `text:` is a **substring** match and `default_normalize_ws` is **false**, so
component assertions pass against broken code with ease. Break each component and watch the test fail
before trusting it.

## Documentation deliverables

### `CLAUDE.md` — Testing section
- `assert_equal nil, x` is a **hard failure** under minitest 6 — use `assert_nil`, or compare tuples when
  the intent is "unchanged". Also gone: `assert_send`, `minitest/mock` (extracted to its own gem), the
  `MiniTest` namespace, and spec expectations on `Object`.
- Sidekiq test mode is `Sidekiq.testing!(:inline)`; never `require "sidekiq/testing"` (removed in
  Sidekiq 9). `Sidekiq::Testing.fake! { }` blocks are unaffected.
- A clean `bin/rails test` emits **no warnings**; a new warning line is a regression.

### `CLAUDE.md` — Conventions section
- Build OpenSearch clients through `Search::Shared::Client`, never `OpenSearch::Client.new` directly.
- AI response schemas are `OpenAI::BaseModel`; `to_json_schema` is a **class** method. `schema.new.to_json_schema`
  raises `NoMethodError`.

### `docs/testing.md`
Currently carries **no** minitest-version or Sidekiq guidance, so these are additions, not corrections
— nothing in the file is stale. Place them at existing headings:

- **"Testing Standards"** (~line 96) — a "Minitest 6 assertion rules" subsection: the `assert_equal nil`
  removal with the tuple-comparison pattern from Inc 2 as the worked example, plus `assert_send`,
  `minitest/mock`, the `MiniTest` namespace, and `Object` spec expectations. Cross-reference the existing
  "What NOT to Test" material, since a nil-expected `assert_equal` is a vacuous assertion as much as a
  deprecated one.
- **"Mocking with Mocha"** (~line 187) — a short Sidekiq test-mode note: `Sidekiq.testing!(:inline)` is set
  globally in `test_helper.rb`; use `Sidekiq::Testing.fake! { }` to stop a job running inline; never
  `require "sidekiq/testing"`.

### Other
- `docs/specs/completed/013-ai-chat-service.md` — drop the `ruby_llm-schema` reference.

## Acceptance Criteria

- [ ] `bin/rails test` → 7362+ runs, **0 failures, 0 errors** on minitest 6.0.6
- [ ] `bundle exec standardrb` clean
- [ ] `Gemfile.lock` shows `minitest (6.0.6)`, and no `ruby_llm-schema` or `schematist`
- [ ] Warning lines per full run drop from ~190 to ~47, and every remaining line is either
      `weighted_list_rank` or npm/yarn
- [ ] Zero `[DEPRECATION] ruby_llm-schema`, `MultiJSON`, `Sidekiq … connecting to Redis`,
      `Use assert_nil`, `require "sidekiq/testing"`, or `Test is missing assertions` lines
- [ ] Each rewritten and each new test verified red-when-broken
- [ ] `CLAUDE.md` and `docs/testing.md` updated as above

### Golden example

```text
Before: 7362 runs, 161787 assertions, 0 failures, 0 errors  (~190 warning lines, minitest 5.27.0)
After:  7362+ runs, 0 failures, 0 errors                    (~47 warning lines, minitest 6.0.6)
```

## Agent Hand-Off

### Constraints
- Increments land in order. Inc 2 **must** precede Inc 3 or the suite is red at that commit.
- The suite gates every deploy (`ci.yml` blocks the merge and the image build). No increment may land red.
- No production behavior change. The Sidekiq log level is test-only.
- Do not run destructive DB commands against development.
- No E2E test needed — nothing user-facing changes.

### Test Seed / Fixtures
No new fixtures. `test/fixtures/list_items.yml` is deliberately **untouched** — its positions 10/11 feed
the excluded `weighted_list_rank` warning, and that file carries a load-bearing comment about
`books_item` and `percentage_western`.

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `web-app/Gemfile`, `web-app/Gemfile.lock`
- `web-app/test/test_helper.rb`
- `web-app/app/lib/services/ai/tasks/base_task.rb`, `web-app/app/lib/services/ai/capable.rb`
- `web-app/app/lib/search/shared/client.rb`, `.../search/base/index.rb`, `.../search/base/search.rb`
- `web-app/test/models/music/artist_test.rb`, `web-app/test/lib/categories/updater_test.rb`
- `web-app/test/components/**` (6 files)
- `CLAUDE.md`, `docs/testing.md`, `docs/specs/completed/013-ai-chat-service.md`

### Challenges & Resolutions
- …

### Deviations From Plan
- …

## Acceptance Results
- Date: 2026-08-23. Verifier: Task 9 (full verification), branch `warning-cleanup-minitest-6`.
- **Before** (measured prior to this work): `7362 runs, 161787 assertions, 0 failures, 0 errors`,
  minitest 5.27.0, ~190 warning lines in a full `bin/rails test` run.
- **After** (measured in Task 9, Steps 1-3): `7400 runs, 162678 assertions, 0 failures, 0 errors, 0 skips`,
  minitest 6.0.6. The run count is higher than the original 7362 baseline because Tasks 6-8 added real
  assertions to six previously-empty ViewComponent stub tests.
- All seven targeted warning patterns (`ruby_llm-schema`, `MultiJSON`, `MultiJson`,
  `connecting to Redis`, `Use assert_nil`, `sidekiq/testing`, `Test is missing assertions`) confirmed
  at **0** occurrences.
- Residual output after filtering the Minitest run/summary lines: 102 lines total, all attributable to
  the two excluded sources — 34 `weighted_list_rank` "Item position … is higher than" lines and 68
  npm/yarn/rollup/tailwindcss build lines from `test:prepare`. No other warning source remains.
- `bundle exec standardrb`: no offenses.

## Future Improvements
- `weighted_list_rank` 0.6.1: replace the raw `puts` at `lib/weighted_list_rank/strategies/exponential.rb:69`
  with a logger. It writes to stdout on **every production ranking run**, not just tests. Owner-scheduled.
- npm/yarn noise: `jsbundling`/`cssbundling` enhance `test:prepare` with a full `yarn install` + asset
  build on every `bin/rails test`. Deliberately left alone — changing it risks stale assets for
  system/E2E tests.

## Related PRs
- #…

## Documentation Updated
- [x] `CLAUDE.md`
- [x] `docs/testing.md`
- [x] `docs/specs/completed/013-ai-chat-service.md`
