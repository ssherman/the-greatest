# Goodreads re-import: every CSV row matched again, from scratch

Status: draft, 2026-11-02. Replaces stage two (§5) of `2026-10-27-goodreads-rebuild-design.md` and absorbs the
"lump split" and "mixed authors" follow-ups. Stage one of that spec (the fixes, 39,148 applied in production on
2026-11-01) and the merges since are the foundation this matches against.

## 1. Why

Shane, 2026-11-02: "a majority of the goodreads import data is just wrong and bad. wrong authors matched. wrong
books. it's a mess." And: "a user's imports should point to exactly what came in via their csv file."

Legacy's importer cut every title at the first colon or parenthesis and guessed authors, so readers landed on the
wrong books. Measured on a production copy (2026-11-02):

- **Mixed books.** 1,654 import-made book records each hold readers of about 2.4 different books.
  - Example: "The Lightning Thief" holds 131 readers of that novel plus 2 of *Percy Jackson: The Ultimate Guide*.
  - All 1,654 are import-made; none is on a curated list.
- **Readers on the wrong trusted book.** Trusted books are correct records on curated lists, so stage one never
  touched them, but legacy put other books' readers on them:
  - 58 readers of *The 48 Laws of Power* (Robert Greene) sit on Graham Greene's *The Power and the Glory*;
  - 68 readers of David Grann's *The Wager* sit on David MacKay's *Sustainable Energy*;
  - 42 readers of Jonathan Haidt's *The Anxious Generation* sit on *Gulliver's Travels*.
- **Books credited to the wrong person,** e.g. the historian Peter Clark's books under Roy Peter Clark.
- **Junk identifiers.** Import-made books carry 472,787 legacy-stamped identifiers. Every identifier on the mixed
  books is legacy's, apart from 3 written from CSV rows and 5 from Amazon.

So the replay stops repairing what legacy did to readers. Every CSV row is matched again as if it had just been
uploaded, and legacy's choices count for nothing.

Wiping every import-made book and re-ingesting was weighed and rejected (Shane agreed, 2026-11-02) for three reasons:
- **It would lose data.** 23,577 list entries (2,555 users) and 3,784 ratings on import-made books have no CSV row behind them.
- **It would take about 3 months of re-enrichment.**
- **It would throw away** the ~95,000 import-made books the survey found correct.

Wipe-and-re-ingest is the model for the 1,654 mixed books only.

## 2. Goals, non-goals, anti-goals

**Goals**
- **Exact rows.** Every CSV row of every legacy import (803 imports, 498,570 rows, 210,121 distinct Goodreads
  editions) ends on exactly the book that row names: the same work, title and author, with combo books as themselves.
- **The reader's data follows the row:** the list entries (shelves, read dates) and the rating or review.
- **Mixed books are gone,** and none of their junk can attract a row again.
- **Correct authors.** Every import-made book's credited author matches what its CSV rows say.
- **A complete audit record.** Every change is written down before it happens and can be reviewed and reversed.
- **AI double-checks every match.** Anything it doubts goes to Shane rather than being applied.

**Non-goals**
- Expanding combo books into their parts (later "collections" work).
- Deduplicating pen names, spellings and transliterations (569 authors whose alternate name is another author's
  name, e.g. J.D. Robb / Nora Roberts, Holderlin / Hölderlin). That is a separate author dedupe.
- Bulk-deleting the 472,787 legacy identifiers. They are ignored here and removed in the final sweep.
- Member imports uploaded in the new app. They already use the new pipeline.

**Anti-goals: these make it a failure even if it runs**
- A row moved to a book that is a different work, edition-volume or adaptation from what the CSV row names.
- A list entry, rating or review lost or duplicated.
- An entry that did not come from a CSV row moved without being flagged as a guess.
- A legacy identifier used as evidence for a match.
- A long step that only runs in a terminal, or that cannot be stopped and restarted safely.
- Enrichment run on the new books before the new enrichment steps (categories, origin) have landed.

## 3. Decisions Shane made (2026-11-02)

1. **Exact rows.** Every reader's row points at exactly the book in their CSV row. "Most popular" never decides what
   a book is.
2. **Mixed books are deleted and re-ingested.**
   - Each mixed record is deleted with its identifiers and editions, after everything on it is copied into the
     audit record.
   - Its CSV rows are then matched fresh. Order per record: archive, delete, re-match, so a row can never match back
     to the deleted record.
   - The old address redirects to the book most of its readers went to.
3. **Hand-added entries on a deleted mixed book go to that record's most-read book, flagged as a guess.** That's
   1,570 list entries from 683 users, plus 197 ratings. Shane chose this over an AI pick, because the evidence for
   an AI pick is too weak.
4. **Legacy identifiers.**
   - They never count as evidence; the blinded finder mode built for stage one already ignores them.
   - When a row brings its own real identifier (its Goodreads id or ISBN from the CSV) and another book holds that
     value as a legacy identifier, the legacy copy is removed from that other book, with an audit entry.
5. **Mixed authors are part of this, not a separate step.** Once every row is on its exact book, each import-made
   book's credited author is checked against its CSV rows and corrected. Wrong alternate names that are left
   attracting nothing are removed.
6. **AI is used liberally to double-check.** A powerful audit record is a hard requirement.
7. **Every long step runs as a Sidekiq job.** Each one is resumable and safe across deploys.
9. **The weekly legacy sync stays off until it has been checked** (Shane: "i would rather get all this finished first
   then double check what the weekly sync does and make sure it doesn't revert any of the work we have done").
   - This run applies when it is ready. It does not wait for launch.
   - Shane has not run `data_migration:sync` in a while. In sync mode it rewrites legacy users' lists to match legacy
     (`UserListItemMigrator`) and routes deleted books' items through `record_redirects`, so as it stands it would
     undo moved rows and send a deleted mixed book's readers to one book.
   - Before it runs again, a separate task reviews the sync and changes it so that it preserves:
     - every applied verdict of this run;
     - stage one's fixes;
     - the merges.
   - That is proven by a test that applies, then syncs, then checks that nothing reverted. This run's design does
     not depend on the sync.
8. **Enrichment gate.** Build and test now, including a dev rehearsal. Nothing runs the importer or enrichment in
   production until the other agent's new enrichment steps (categories, origin) have landed.

## 4. The run

### 4.1 Order
1. **Gate check.** The new enrichment steps are merged and deployed. The Goodreads search page fix (separate PR,
   in progress) is deployed.
2. **Mixed books** (§4.3): archive, then take them out of matching. The finder must never return one, even
   though each record is only deleted later, once it is empty (§8 call 1).
3. **Match every distinct Goodreads edition** (§4.4), once each, for all 210,121.
4. **Decide per row** (§4.5): keep, move, add or create. Each decision is written to the audit record.
5. **Apply** the approved decisions (§4.6).
6. **Author check** over import-made books (§4.7).
7. **Hand-added entries** from the deleted mixed books (§4.3, step 4).
8. **Report and spot-check** (§6).

The final sweep and the weekly catch-up from the rebuild spec follow, unchanged.

### 4.2 What "the row's book" means
The CSV row gives the full title (never cut at the colon), the author and additional authors, the Goodreads
edition id, ISBN/ISBN13, the original publication year and the binding. A row's book is the work that edition belongs
to:
- **Translations of a work:** the English book when one exists (rebuild spec, 2026-10-29).
- **Combo or omnibus:** itself.
- **Different volume, part, adaptation, guide or box set:** a different book.

### 4.3 Mixed books
1. **Archive.** For each mixed record, write into its audit entry:
   - title, subtitle and authors;
   - every identifier, edition and edition identifier;
   - external links and images;
   - every list item and review, with user, list, position and dates;
   - which CSV rows point at it.
2. **Delete the record** through a path that records a redirect (`RedirectRecorder`). The redirect target is set in
   step 4, once the rows have landed.
3. **Re-match its rows** in §4.4–§4.6, like any other row.
4. **Hand-added entries** are list items and reviews no CSV row accounts for. Each goes to the most-read destination
   of that record's rows, and is flagged `guess: true` in the audit record. Shane reviews the guesses from a filtered
   admin view.
   - "No CSV row accounts for it" means no row of that user's imports names this record (by `legacy_book_id`).

### 4.4 Matching an edition
For each distinct Goodreads edition in the rows:
- **Finder:** the existing book finder in blinded mode (`identifier_sources: TRUSTED_IDENTIFIER_SOURCES`, legacy and
  merge alternate titles ignored). The query is built from the CSV row's full title, authors, ISBNs, year and
  Goodreads id (`ExportFacts`).
- **Cached Goodreads page:** used when one exists. New page fetches go through `FetchGate`, like member imports.
- **Outcome:** a matched book, "none" (create), or "unsure".
- **AI double-check on every match**, including identifier hits:
  - The question: does this book (title, subtitle, authors, year, and a few edition titles) describe the same work
    as this CSV row's full title, authors and year, under the §4.2 rules?
  - "Yes" with high confidence: approved.
  - Anything else: proposed, for Shane.
  - A finder "none" also gets a check that no close candidate was the right book.
- **Reuse.** One result per edition, reused by every row naming it. The 210,121 editions are matched once, not
  498,570 times.

### 4.5 Deciding per row
Compare the edition's book with the book the user's data points at now (the row's `legacy_book_id`, followed through
merges with `Apply::MergedBook`):
- **Same book:** keep. The audit entry is "checked, unchanged".
- **Different book:** move. That user's list items and review go to the right book, with the semantics of the
  existing `Apply::Relink`. A list already holding the right book keeps its item, with blank dates filled. A review
  already on the right book wins. Another user's items are never touched.
- **Row legacy matched to nothing** (51,837 rows): add. The entries are written as `WriteLibrary` would write them,
  with the same shelf, date and position rules.
- **Edition matched "none":** create the book through the member-import path (`CreateBook`), provisional. Then move
  or add.

### 4.6 Applying
- **Approved decisions apply automatically.** Proposed ones wait for Shane in the admin repair-verdicts view.
- **Apply is a Sidekiq job.** It works in small batches that re-queue themselves, in order: creates, then moves and
  adds, then identifier clean-up. It is idempotent, so a deploy or restart only repeats a batch.
- **Deadlock retry** (#438) is part of every batch.
- **Follow-ups are batched:** ranking refreshes, favorites lists, search index, review summaries and goal pages.
  The replay apply already does this.

### 4.7 Author check
For every import-made book with CSV rows: compare its credited authors with the authors its rows name (name keys,
then the AI same-person check `MatchAuthors` already uses).
- **Agree:** nothing.
- **Disagree:**
  - correct the book's authors to the people its rows name, linking an existing author when the AI confirms the
    same person, and creating one otherwise;
  - audit entry; AI double-check; proposed when unsure.
- **Afterwards:** remove an alternate name from an author when that name belongs to another existing author and
  none of this author's books has a row naming it.

## 5. The audit record

Reuse `Books::RepairVerdict`: it already has statuses, a payload, an admin review UI, bulk approve and applied/error
tracking. New kinds, all keyed by `subject_key` so a re-run never duplicates an entry:
- `delete_mixed_book`: the full archive from §4.3.
- `match_edition`: the edition, the finder result, the AI check and its reasoning.
- `move_row`, `add_row`, `keep_row`: user, row, from book, to book, and what moved.
- `guess_move`: a hand-added entry, `guess: true`.
- `fix_book_author`: before and after.
- `strip_legacy_identifier`: which book, which value, and why.

**Every entry stores:** what was there before, what it changes to, the evidence, the AI's answer and who or what
approved it.

**Reversal:** an applied entry can be reversed from its payload. Building a one-click undo is left to the builder,
but nothing may be applied that its payload cannot reverse.

## 6. Checking it worked
- **Dev rehearsal on a fresh production copy:** the full run, then a report: counts per decision kind, AI agreement
  rate, proposed count, guesses.
- **Labeled sample:**
  - 300 random rows, plus every row on 20 random former mixed books, checked by an independent AI reviewer against
    the CSV row;
  - plus Shane's own spot-check of 50;
  - **target: zero wrong rows.** Any wrong row stops the run until its cause is fixed.
- **Production:** run in batches of imports, with the same report after each batch.
- **Acceptance queries**, each with expected zero:
  - rows whose book's title key differs from the CSV row's full title key and that no approved verdict explains;
  - list items or reviews lost: counted per user before and after;
  - remaining mixed-book records.

## 7. Constraints
- Every long step is a Sidekiq job: resumable, deploy-safe, visible in the dashboard. No inline rake runs for long
  work.
- The enrichment gate (§3.8).
- Production runs are Shane's. Nothing destructive runs against the development database outside a rehearsal on a
  restored copy.
- `/resolve` (Open Library) has capacity 1. This run must not share it with another long run.
- The book merger keeps title-bound fields only from same-titled sources (#443). The later dedupe step relies on it.

## 8. Calls made after the builder check (mine, for Shane to check)

1. **Mixed books are emptied before they are deleted, never deleted first.** A mixed record is handled only once
   every CSV row on it has an approved decision.
   - Its users' list items and reviews are moved or copied to their new books first, keeping list, position, dates,
     review text and timestamps. The empty record is deleted after that.
   - Deleting a book cascades to its list items (`dependent: :destroy`), so deleting first would destroy exactly the
     data this run exists to put right.
   - §4.1 step 2 changes accordingly: the archive is still written first, but the delete is the last step per record.
   - Readers with an "unsure" row keep their entry on the old record until Shane decides it.
2. **One legacy entry claimed by several rows that now go to different books** (a user had both *The Lightning
   Thief* and *The Ultimate Guide* on one record):
   - the item is copied to every destination, each copy dated from its own CSV row (Date Read, Date Added, shelves);
   - the rating and review go to the row whose CSV carries them (My Rating, My Review).
   - `Apply::Relink`'s copy-or-move test reads legacy-stamped Goodreads ids, so it is not reused for this. A new rule
     based on the rows replaces it.
3. **Which rows are in scope.** Rows of completed legacy imports only, the same scope as the rebuild spec's §12
   call 8.
   - Failed and stuck imports stay with `finish_legacy` at launch, with its skip rules.
   - When a user has the same edition in several imports, the newest import's row wins, as in `WriteLibrary`.
4. **Created books are not provisional,** as in the rebuild spec's §12 call 5. An approved `create` verdict is the
   approval.
   - Their enrichment is queued by the rebuild's enrichment top-up (`QueueEnrichment`), and only after the
     enrichment gate (§3.8).
   - `CreateBook` needs an import record; the builder passes the row's import.
5. **Dedupe is not in this run.** The rebuild spec's dedupe (its §5 step 3: pending pairs, `close_pair`, automatic
   merge rule) runs after this as its own step, unchanged. Remove "Merges done here rely on #443" from §7; it applies
   to that later step.
6. **The author check (§4.7) changes import-made books only.** On a trusted-core book (pre-import, or on a curated
   list), a disagreement is always proposed, never applied automatically. That matches the rebuild spec's §12 call 2.
7. **The mixed-book set** is recomputed by a fresh survey just before the run: import-made books whose rows name two
   or more different works (the survey's lump classification). The same rule runs in the dev rehearsal and in
   production. The 1,654 figure is from the 2026-11-02 copy.

## 9. Left to the builder
- How a deleted mixed record's redirect is recorded, given the existing `RedirectRecorder`.
- The AI check's exact prompt and schema (an `OpenAI::BaseModel` subclass), and its model, from the current lineup.
- Batch sizes, queue names and the job layout, within §7.
- The admin filters needed to review proposed entries and guesses by kind.
- Whether the one-click undo is built now or later, as long as every payload can reverse its change.
