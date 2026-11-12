# Legacy sync duplicate-key fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `data_migration:sync` gets past the `users` step on legacy data whose `provider_data` repeats a key, and
the launch doc says what to run after a sync today.

**Architecture:** One keyword argument on the existing JSON parse in `UserMigrator`, a regression test beside the
existing `provider_data` tests, and doc edits.

**Tech Stack:** Rails 8, json gem 3.1, Minitest.

**Spec:** `docs/superpowers/specs/2026-11-12-sync-json-duplicate-keys-design.md`

## Global Constraints

- Last value wins on a duplicate key (json 2.x behaviour). A malformed string still raises.
- No other `JSON.parse` call changes.

## Review Focus

- A malformed (not merely duplicate-key) `provider_data` must still fail the run naming the legacy id: covered by
  Task 1's second test.

---

### Task 1: Tolerate duplicate keys in legacy provider_data

**Files:**
- Modify: `web-app/app/lib/services/books_migration/user_migrator.rb` (`parse_provider_data`)
- Test: `web-app/test/lib/services/books_migration/user_migrator_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
test "provider_data with a repeated key migrates, the last value winning" do
  raw = "{\"4\":{\"providerId\":\"password\",\"uid\":\"a\"},\"4\":{\"providerId\":\"password\",\"uid\":\"b\"}}"
  result = run_migrator([legacy_attrs("id" => 90012, "provider_data" => raw)])
  assert result[:success], result[:error]
  assert_equal({"4" => {"providerId" => "password", "uid" => "b"}}, User.find(90012).provider_data)
end

test "malformed provider_data still fails the run" do
  result = run_migrator([legacy_attrs("id" => 90013, "provider_data" => "{not json")])
  assert_not result[:success]
  assert_match "90013", result[:error]
end
```

- [ ] **Step 2: Run them; the first fails with `duplicate key "4"`**

Run: `bin/rails test test/lib/services/books_migration/user_migrator_test.rb`

- [ ] **Step 3: `JSON.parse(value, allow_duplicate_key: true)` in `parse_provider_data`**, with a comment naming
  json 3 and the 2,797 legacy rows.

- [ ] **Step 4: Run the file; all pass.** Then `bundle exec standardrb` on the two files.

- [ ] **Step 5: Commit** `Let the legacy sync parse provider_data with repeated keys`

### Task 2: Docs

**Files:**
- Modify: `docs/launch-todo.md` §4 and §12
- Modify: `docs/features/books-legacy-sync.md` ("Users' data")

- [ ] **Step 1: §4.** Step 3 (`firebase:backfill_v1_uids`) runs only once the V1 Firebase import has run (until
  then it would point uids at accounts that don't exist). Step 4 (`goodreads_replay:apply`) applies every approved
  verdict of any kind. Step 7 (`books:verify[all,recheck]`) waits while the Goodreads re-import runs. Add: while
  §12 is pending, `books:goodreads_replay:load` after the sync.
- [ ] **Step 2: §12.** Replace the "Do not run `data_migration:sync`" paragraph: a sync before the re-import
  moves any rows is fine (and brings over the books and imports the re-import should cover); after the first row
  moves, no sync until spec §3.9's change. List the pre-re-import sync steps.
- [ ] **Step 3: books-legacy-sync.md.** List items added in this app to a legacy-origin list are deleted when
  legacy lacks them; new-app lists are untouched.
- [ ] **Step 4: Commit** `Launch doc: what to run after a sync, from the 2026-11-12 rehearsal`

### Task 3: Verify

- [ ] `bin/rails test` (full suite) and `bundle exec standardrb` green.
