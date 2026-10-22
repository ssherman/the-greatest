# Unsure Books Second Chance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settle as many of the 4,011 `unsure` (and 126 `removed`) verification rows as possible on the right Open Library work, without ever settling one on a wrong work.

**Architecture:** A forgiving title comparison key in `Check`, used by every title comparison. Four new stage-1 routes in `Lookup` that run only after `/resolve` fails to settle the book, each ending in our title-and-author check. A one-off `second_chance` run flag, a route-level revert that puts a book back to its pre-second-chance state, and per-route report lines for the hand check.

**Tech Stack:** Rails 8, Minitest 6 + fixtures + Mocha, `OlBackfillHelper` fakes (`FakeOlClient`, `ol_work`, `ol_resolution`).

**Spec:** `docs/superpowers/specs/2026-10-21-unsure-books-second-chance-design.md`

## Global Constraints

- No change to the Open Library service or matcher (`data-sources/`).
- Every new route ends in `Check.verified?` (title and an author). Nothing settles on score alone.
- The matcher's guards hold: no second chance when `resolution.decision.reason` starts with `"identifier conflict"` or `resolution.volume_guards_tripped` is not empty; never take a candidate whose `conflicting_features` is not empty.
- New routes write **no** Open Library author keys (`AuthorKeys` is skipped). Duplicate-pair flagging and the `duplicate_pair` guard stay.
- A trailing parenthetical is never dropped when it contains a digit, `#`, a whole word `vol|vols|volume|volumes|book|books|part|tome`, or matches `EditionCheck::SET_WORDS`.
- Leading articles dropped (one, first word only, never leaving an empty key): `the a an le la les l el los las il lo i gli o os as der die das`.
- Letters folded beyond NFKD: `ø→o æ→ae œ→oe ß→ss đ→d ł→l þ→th` (lower and upper case), in the title key and in `Check.compact`.
- Use the `::Books::Verification` form inside `Services::Books::Verification` (the module shadows the model).
- Migrations via `bin/rails generate migration`; additive and nullable only.
- Tests touch only the worktree's test DB. Never write to development from a test or a task.
- Run `bin/rails test test/lib/services/books/verification/` per task, the full `bin/rails test` and `bundle exec standardrb` before each commit. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A title that is only an article, or one word ("The", "A", "It"): the key must never become empty ("The" keys to "the"). Pinned in Task 1.
2. Non-Latin titles (Cyrillic, Greek, CJK) keep their letters: "Мы" keys to "мы", not to "". Pinned in Task 1.
3. Our own title carrying a volume parenthetical ("In Search of Lost Time (Volume 1)") agrees only with the same volume, symmetric to theirs. Pinned in Task 2.
4. WorldCat-confirmed ISBN-10s with no ISBN-13 form held: route 5 normalizes them to ISBN-13 before the lookup. Pinned in Task 4.
5. A re-queued `second_chance` run (same run id) does not redo books it already finished; a `removed` row's `old_keys` survive the re-run. Pinned in Task 6.

---

### Task 1: The title comparison key in `Check`

**Files:**
- Modify: `web-app/app/lib/services/books/verification/check.rb`
- Test: `web-app/test/lib/services/books/verification/check_test.rb`

**Interfaces:**
- Produces: `Check.title_key(text) -> String | nil`; `Check.title_forms(text) -> [full_key, short_key_or_nil]`; `Check.their_title_keys(work) -> [full_key, short_key_or_nil]` (the work's subtitle field joined with ": " before keying when present, else `title_forms(work.title)`); `Check.titles_agree?` compares keys with the existing one-side subtitle rule; `Check::VOLUME_PARENTHETICAL` regex. `Check.their_titles` and `Check.normalize` are unchanged here so every other caller stays green; Task 2 moves the callers and deletes `their_titles`.

- [ ] **Step 1: Write the failing tests** in `check_test.rb`:
  - `title_key`: `"From Russia, with love"` == `title_key("From Russia with Love")`; `"The Metamorphosis"` == `"Metamorphosis"`; `"Le Mariage De Figaro"` == `"Mariage de Figaro"`; `"L' huile sur le feu"` == `"L'huile sur le feu"`; `"Émile"` == `"Emile"`; `"Søren"` == `"Soren"`; `"Мы"` keys to `"мы"`; `title_key("The")` == `"the"` (never empty); `title_key("It")` == `"it"`.
  - `title_forms("Atlas Shrugged (Centennial Ed. HC)")` == `["atlas shrugged centennial ed hc", "atlas shrugged"]`.
  - `title_forms("In Search of Lost Time (In Search of Lost Time 1)")[1]` is nil; same for `"(Discworld, #4)"`, `"(Volume 2)"`, `"(Box Set)"`, `"(Book Two)"`.
  - `title_forms("Dune: Messiah")` == `["dune messiah", "dune"]`.
  - `titles_agree?`: our "The Metamorphosis" vs work "Metamorphosis" agrees; our "Atlas Shrugged" vs work "Atlas Shrugged (Centennial Ed. HC)" agrees; our "In Search of Lost Time" vs work "In Search of Lost Time (In Search of Lost Time 1)" does not; "Dune: Messiah" vs "Dune: Part One" still does not (one side only).
  - `compact("Søren Kierkegaard") == compact("Soren Kierkegaard")`.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/verification/check_test.rb` — Expected: the new tests FAIL (undefined `title_key` / disagreements).
- [ ] **Step 3: Implement** in `check.rb`: `FOLD` table, `LEADING_ARTICLES`, `VOLUME_PARENTHETICAL = /\d|#|\b(vols?|volumes?|books?|part|tome)\b/i`. `title_key`: `normalize`, apply `FOLD`, NFKD and drop `\p{Mn}`, replace `[^\p{L}\p{N} ]` with a space, squeeze, strip, drop the first word when it is in `LEADING_ARTICLES` and another word follows. `title_forms`: split **before** keying — a trailing `(...)` whose inside does not match `VOLUME_PARENTHETICAL` or `EditionCheck::SET_WORDS` gives the short form; otherwise the existing first-":" split. `titles_agree?` keys our titles (and alternate titles) through `title_forms` and theirs through `their_title_keys`. `compact` applies `FOLD` before NFKD. `normalize` itself is unchanged (authors use it).
- [ ] **Step 4: Run** the check tests, then `bin/rails test test/lib/services/books/verification/` — Expected: PASS, every pre-existing test included.
- [ ] **Step 5: Commit** `Verification: a forgiving title comparison key in Check`.

### Task 2: Every title comparison uses the key

**Files:**
- Modify: `web-app/app/lib/services/books/verification/edition_check.rb`, `world_cat_check.rb`, `signals.rb`, `harvest_editions.rb`
- Test: `edition_check_test.rb`, `world_cat_check_test.rb`, `signals_test.rb`, `harvest_editions_test.rb` (same directory under `web-app/test/lib/services/books/verification/`)

**Interfaces:**
- Consumes: Task 1's `Check.title_key`, `Check.title_forms`, `Check.their_title_keys`. After this task `Check.their_titles` has no callers: delete it.
- Produces: no new public names. `EditionCheck::SET_WORDS` matches keyed text (punctuation already spaces).

- [ ] **Step 1: Write the failing tests:**
  - `EditionCheck`: edition "Atlas Shrugged (Centennial Ed. HC)" agrees with book "Atlas Shrugged"; edition "War and Peace: Books 2-4" still does not agree (keyed "books 2 4" must still match `SET_WORDS`); edition "In Search of Lost Time (In Search of Lost Time 1)" does not agree with book "In Search of Lost Time"; book "In Search of Lost Time (Volume 1)" agrees only with an edition "In Search of Lost Time (Volume 1)" (Review Focus 3).
  - `WorldCatCheck.clearly_different?`: record "From Russia, with love / Ian Fleming" is not clearly different from book "From Russia with Love" by another author name form.
  - `Signals`: a foreign work titled "Bible" against book "The Bible" is still not foreign (existing test keeps passing after removing `Signals`' own article handling); a candidate titled "L' huile sur le feu" makes a foreign work "L'huile sur le feu" a known translation.
  - `HarvestEditions`: a duplicate work "Metamorphosis" passes the strict gate for book "The Metamorphosis"; "Metamorphosis: Volume 2" still does not.
- [ ] **Step 2: Run** the four test files — Expected: the new tests FAIL.
- [ ] **Step 3: Implement:** `EditionCheck#our_titles` keys through `Check.title_forms` (the work's full title through `Check.their_title_keys`); `title_agrees?` uses `Check.their_title_keys(edition)` and checks `SET_WORDS` on `full.delete_prefix(short)`; widen the run-of-books alternative in `SET_WORDS` to accept a bare space between the numbers (`(-|–|to|through|\s)`). `WorldCatCheck#title_contained?` keys with `Check.title_key` after the " / creator" strip and drops its own `LEADING_ARTICLE`. `Signals` drops its `LEADING_ARTICLE`/`drop_article`/`TitleLike` and calls `Check.titles_agree?`; `candidate_titles` keys with `Check.title_key`. `HarvestEditions#same_title?` compares `Check.their_title_keys(work).first` with `Check.title_key(@book.title)` and drops its own `LEADING_ARTICLE`.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS, every pre-existing test included.
- [ ] **Step 5: Commit** `Verification: every title comparison uses the comparison key`.

### Task 3: Second-chance routes from `/resolve`'s own candidates (spec steps 2-3)

**Files:**
- Modify: `web-app/app/lib/services/books/verification/lookup.rb`, `web-app/app/models/books/verification.rb`
- Modify: `web-app/test/support/ol_backfill_helper.rb`
- Test: `web-app/test/lib/services/books/verification/lookup_test.rb`

**Interfaces:**
- Consumes: Task 1's `Check.title_key`, `Check.verified?`, `Check.authors_agree?`.
- Produces: `Books::Verification` `lookup` enum gains `resolve_candidate: 2, exact_title: 3, held_key: 4, worldcat_isbns: 5` (prefix `:via` unchanged). `Lookup::Answer#lookup` may be any of these symbols; `Answer#duplicates` carries the other passing candidates' keys. Test helper `ol_resolution_with(verdict:, candidates:, reason: "test", volume_guards_tripped: [])` where each candidate is `{work:, verdict:, score:, conflicts: []}`.

- [ ] **Step 1: Write the failing tests** (`lookup_test.rb`, using `ol_resolution_with`):
  - Iliad: abstain; candidates [Odyssey (`abstain`, 0.877, title "Ὀδύσσεια"), Iliad (`abstain`, 0.876, title "The Iliad", same author)] → `answer.work.key` is the Iliad's, `answer.lookup == :resolve_candidate`.
  - Two passing candidates → the second's key is in `answer.duplicates`.
  - Exact-title preference: two passing candidates, the first passing only by dropping a subtitle, the second an exact title → the second is chosen.
  - Accept whose work fails our check, with a passing `abstain` candidate behind it → settles on the passing one.
  - Demons: abstain; abstain-band candidates all fail; a `reject` candidate titled exactly "Demons" with the author → settles, `lookup == :exact_title`.
  - A `reject` candidate matching only an alternate title → no answer (`work` nil).
  - Guards: reason `"identifier conflict on the best candidate: isbn13"` → no answer even with a passing candidate; `volume_guards_tripped: ["author_shelf"]` → no answer; a passing candidate with `conflicts: ["isbn13"]` is skipped.
  - The existing confirm-only case (top candidate is a held key and passes) still returns `confirm_only: true`, `lookup: :resolve`.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/verification/lookup_test.rb` — Expected: new tests FAIL.
- [ ] **Step 3: Implement** in `Lookup#full`, after the existing accept and `confirmable_stored_key` checks: `second_chance(resolution)` returns an `Answer` or nil. Guard first (reason / volume guards). Candidates: `resolution.candidates` with `conflicting_features.empty?` and a `record`. Step 2: those with `verdict != "reject"`, keep the ones passing `Check.verified?`, prefer one whose `Check.their_title_keys(record).first` equals `Check.title_key` of `book.title` or an alternate title, else the first; others passing go in `duplicates`. Step 3 (only when step 2 found none): the first `verdict == "reject"` candidate whose full title key equals `Check.title_key(book.title)` and whose authors agree (`Check.verified?`). `ol_pick` keeps today's meaning. Add the enum values to `Books::Verification`.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS.
- [ ] **Step 5: Commit** `Verification: second chance from /resolve's own candidates`.

### Task 4: Second-chance routes from held keys and WorldCat ISBNs (spec steps 4-5)

**Files:**
- Modify: `web-app/app/lib/services/books/verification/lookup.rb`
- Test: `web-app/test/lib/services/books/verification/lookup_test.rb`

**Interfaces:**
- Consumes: Task 3's `second_chance` hook and enum values.
- Produces: `Lookup::MAX_WORLDCAT_LOOKUPS = 5`. Answers with `lookup: :held_key` or `:worldcat_isbns`.

- [ ] **Step 1: Write the failing tests:**
  - Held key: abstain with no passing candidate; book holds `OL9W` (legacy) whose work passes → `answer.work.key == "OL9W"`, `lookup == :held_key`. Two passing held keys, the second an exact title → the second.
  - Held key whose work fails → falls through to route 5.
  - WorldCat: book holds ISBN-13 `9780199232765` and ISBN-10 `0140447938` (source `worldcat`); hits point at `OL5W` (2 hits) and `OL6W` (1 hit), both passing → `OL5W` settles, `OL6W` in `duplicates`, `lookup == :worldcat_isbns`. The ISBN-10 is looked up as `["isbn13", "9780140447934"]` (Review Focus 4).
  - Legacy-source ISBNs are never looked up by route 5; at most `MAX_WORLDCAT_LOOKUPS` lookups.
  - Guards from Task 3 also stop routes 4 and 5.
- [ ] **Step 2: Run** the lookup tests — Expected: new tests FAIL.
- [ ] **Step 3: Implement** routes 4 and 5 in `second_chance`, in that order after steps 2-3. Route 4: `works_batch(stored_keys)`, live works passing `Check.verified?`, exact title key first, then stored order. Route 5: the book's `worldcat` ISBN-13/ISBN-10 values normalized with `::Books::Isbn.normalize(value)&.isbn13`, unique, first 5, looked up with the existing `hits_for` / thread pattern of `fast_hits`; tally `work_key`, `works_batch` the keys, first passing by tally order, other passing keys as duplicates.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS.
- [ ] **Step 5: Commit** `Verification: second chance from held keys and WorldCat ISBNs`.

### Task 5: Applying a second-chance answer

**Files:**
- Modify: `web-app/app/lib/services/books/verification/apply_book.rb`, `verify_book.rb`
- Test: `apply_book_test.rb`, `verify_book_test.rb`

**Interfaces:**
- Consumes: Tasks 3-4's answers.
- Produces: `ApplyBook::MATCHER_LOOKUPS = %w[identifiers resolve]` (the routes that may write author keys). `ApplyBook.settled?(row)` is false for a `removed` row at `stage: :work`. For a reprocessed row, `old_keys` is the union of the row's previous `old_keys` and the keys held now.

- [ ] **Step 1: Write the failing tests:**
  - A `:resolve_candidate` answer settles the book (`keyed` or `replaced` as today) and writes **no** author key (`author_changes` empty) even when `AuthorKeys` would add one; a `:resolve` accept still writes one.
  - A `:held_key` answer for a held key gives `confirmed` and the key's source becomes `open_library`.
  - A `removed` row reset to `stage: :work` with `old_keys: ["OL3W"]` is reprocessed, and after settling its `old_keys` still include `"OL3W"`.
  - A `removed` row at `stage: :done` is still settled (skipped).
  - `VerifyBook` reports `via_resolve: true` for every lookup but `identifiers`.
- [ ] **Step 2: Run** the two test files — Expected: new tests FAIL.
- [ ] **Step 3: Implement:** in `decide`, `author_changes: MATCHER_LOOKUPS.include?(answer.lookup.to_s) ? AuthorKeys.call(...) : {}`; `settled?` exempts `removed` at `stage_work`; merge `old_keys` when the row is not new; `VerifyBook` uses `!row.via_identifiers?`.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS.
- [ ] **Step 5: Commit** `Verification: apply second-chance answers without author keys; removed rows can be reprocessed`.

### Task 6: The `second_chance` run flag

**Files:**
- Create: migration via `bin/rails generate migration AddSecondChanceToBooksVerifications second_chance_at:datetime prior_outcome:integer prior_keys:string` (edit `prior_keys` to `array: true, default: [], null: false`)
- Modify: `web-app/app/lib/services/books/verification/run.rb`, `web-app/lib/tasks/books/verify.rake` (desc only)
- Test: `run_test.rb`

**Interfaces:**
- Consumes: Task 5's reprocessable `removed` rows.
- Produces: `Run::FLAGS` includes `"second_chance"`. On taking a row: `stage: :work`, `second_chance_at: Time.current`, `prior_outcome:` the row's outcome, `prior_keys:` the book's `books_work_openlibrary_id` values now.

- [ ] **Step 1: Write the failing tests:**
  - With `second_chance`, done `unsure` and `removed` rows from another run are taken, reset to `stage: :work`, and get `second_chance_at`, `prior_outcome`, `prior_keys`; `keyed` and `reverted` rows are not taken.
  - A row this run already finished (same `run_id`) is not taken again (Review Focus 5).
  - Without the flag, an `unsure` done row is not taken.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/verification/run_test.rb` — Expected: FAIL (unknown flag).
- [ ] **Step 3: Implement** like `reharvest`: `second_chanceable` scope (`stage_done`, `work_outcome` in `unsure`/`removed`, `run_id != @run_id`), excluded from `finished` in `next_ids`, handled in `prepare`. Run the migration (`bin/rails db:migrate` updates `schema.rb`; `RAILS_ENV=test bin/rails db:test:prepare`).
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS.
- [ ] **Step 5: Commit** `Verification: second_chance run flag`.

### Task 7: Route revert and report lines

**Files:**
- Create: `web-app/app/lib/services/books/verification/revert_second_chance.rb`
- Modify: `web-app/app/lib/services/books/verification/report.rb`, `web-app/lib/tasks/books/verify.rake`
- Test: `revert_second_chance_test.rb` (new), `report_test.rb`

**Interfaces:**
- Consumes: Task 6's `second_chance_at`, `prior_outcome`, `prior_keys`; Task 3's lookup values.
- Produces: `RevertSecondChance.call(book:) -> Result` and `RevertSecondChance.route(lookup) -> {reverted: Integer, failed: Integer}`; rake `books:verify_revert_route[<lookup value>]`.

- [ ] **Step 1: Write the failing tests:**
  - A book settled by `:resolve_candidate` after a second chance: revert removes the work key and duplicate keys it added, restores `prior_keys` as `legacy` (a held key it confirmed goes back to `legacy`), undoes findings and edition candidates created at or after `second_chance_at`, keeps findings from before it, and leaves the row `prior_outcome` (`unsure`), `lookup: :resolve`, `new_key: nil`, `stage: :done`, eligible for a later `second_chance` run.
  - A `removed` prior row reverts to `removed` and its removed key is **not** recreated.
  - A row with no `second_chance_at` fails with a message; `route(:resolve_candidate)` reverts only that route's rows.
  - Report: for each of the four new lookup values, a count line and up to `Report::SAMPLE` samples in the existing sample format.
- [ ] **Step 2: Run** the two test files — Expected: FAIL.
- [ ] **Step 3: Implement** `RevertSecondChance` reusing `Revert`'s finding logic (extract a shared private helper into `Revert` only if it stays small), `Counts.call(row)` at the end, `lump_suspect: false`. Report lines after the outcome samples. Rake task with a usage line listing the four values.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/verification/` — Expected: PASS.
- [ ] **Step 5: Commit** `Verification: revert a second chance by route; report per route`.

### Task 8: Docs

**Files:**
- Modify: `docs/features/book-verification.md`, `docs/launch-todo.md` (verification section), `docs/todos/goodreads-import-accuracy.md` ("Available now" section)

- [ ] **Step 1:** Feature doc: the comparison key (what it ignores, the volume-parenthetical rule), the four routes and their guards, no author keys from them, the `second_chance` flag (run once; reruns repeat work), `books:verify_revert_route`, the report lines. Launch todo: production order — deploy, `books:verify[all,second_chance]`, `books:verify_report`, spot-check per route, revert a route if needed. Goodreads todo: one line that unsure books got a second chance.
- [ ] **Step 2: Run** the full `bin/rails test` and `bundle exec standardrb` — Expected: 0 failures, no offenses, no new warning lines.
- [ ] **Step 3: Commit** `Docs: unsure books second chance`.

---

## After the tasks (not part of the build)

1. Final whole-branch review.
2. **Dev rehearsal, with Shane's go-ahead:** snapshot dev (`bin/snapshot-dev-db.sh --label pre-second-chance`), run `Services::Books::Verification::Run.call(limit: nil, run_id: "rehearsal-second-chance-…", flags: %w[second_chance])` from a runner script in the scratchpad, then hand-check per the spec: at least 30 per route, all of the top 100 by Goodreads rows, and every settled work whose title key differs from ours. Any wrong work tightens or drops its route before production.
3. PR (ask first), merge, production run per the launch todo.
