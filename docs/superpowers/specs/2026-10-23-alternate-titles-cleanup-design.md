# Alternate titles: a table with provenance, an AI review, and undoing what bad titles let in

Design, 2026-10-23. Agreed in conversation with Shane on 2026-10-22/23.

## Why

`Books::Book#alternate_titles` (a `string[]` column) holds titles that are not the book. Shane checked
two by hand:

- *The Book of the City of Ladies* lists "The Treasure of the City of Ladies" and "The Treasure of the
  City of Ladies: Or the Book of the Three Virtues". That is a separate work by the same author.
- *Catch-22* lists "Capítulo 22" and "Rozdział 22" ("Chapter 22"), plus "Pânico" and "Der Iks".

The verification dev rehearsal of the unsure-books second chance found more: *A Season in Hell*
holding "A Season in Hell & Illuminations" (a combined edition), *My Struggle* holding "My Struggle:
Book 1" (volume 1 of 6), *The Little World of Don Camillo* holding "The World of Don Camillo". In
every wrong settle of that rehearsal (5 of 111), the bad alternate title was the reason.

Most of the junk came from the old site's duplicate merges. Each merge folded the losing book's title
into the winner's alternate titles, so every wrong merge left a wrong title behind
(`docs/superpowers/specs/2026-06-29-books-object-model-design.md` §8.3). Our own merger
(`Books::Book::Merger#absorb_alternate_titles`) and AI enrichment (`ApplyBookFacts`, a case-insensitive
union) still add titles today.

Alternate titles are not only for matching. A bad one:

- shows on the public book page (`books/books/_details`) and in the public API
  (`Api::V1::Books::BookResource`);
- sends searches to the wrong book: search matches them with boost 7, nearly as heavily as the main
  title (`book_general.rb`, `book_by_title_and_authors.rb`);
- misleads the import finder (`FinderBase#titles_agree?`);
- misleads the verification pass, which trusted ISBNs through them. On the 12,143 verified ranked
  books, 47,842 stage 2 trusted writes matched only through an alternate title (on 1,186 books),
  against about 217,000 that matched through the main title. Most of the 47,842 are correct ("Oliver
  Twist" for *The Adventures of Oliver Twist*, translations like "Orgullo y prejuicio"). The wrong ones
  are mixed in with them.

Shane's priorities: data cleanup comes first, and no new books are being added for now. The weekly
legacy sync only adds books new on legacy and does not change existing books' alternate titles.

## Scale (dev, a production restore of 2026-10-21)

- 17,147 books have alternate titles, 40,301 titles in all.
- 4,271 of them are ranked, holding 15,712 titles.
- The longest lists: *War and Peace* 66, *Animal Farm* 51, *The Nero Wolfe Series* 45.

## Goals

- Every alternate title has a recorded source and a status. The status is kept, removed or waiting for
  review, and it holds the reason for the last decision.
- Every book's alternate titles are reviewed by AI. Titles that are not the same work are removed.
- A removed title is never shown, searched or matched, and no writer can add it back.
- Shane can check any decision: the verdict, its reason, and the AI call it came from. He can put a
  title back.
- Trusted identifiers that matched only through a removed title are undone, and nothing else is.

## Non-goals

- Adding new alternate titles (translations) by AI. The verification spec lists that as a later job.
- Changing how search ranks titles.
- Re-running the verification pass. That follows separately: the unsure-books second chance
  (branch `worktree-verification-unsure-second-chance`, unmerged, spec
  `2026-10-21-unsure-books-second-chance-design.md`) runs after this cleanup.

## Anti-goals

- Removing a real translation or variant. A wrong removal makes a book harder to find and match.
  Removals are reversible, but a reviewer has to notice them first.
- Losing the record. Removed titles are marked, never deleted.

## The design

### Part 1: the `books_alternate_titles` table

One row per alternate title of a book.

- **Columns:** the book, the title (as stored today), a source, a status, and the review fields
  (verdict, category, confidence, reason, the `AiChat` it came from, who decided, when). Plus
  timestamps.
- **Source:** `legacy` (everything that exists today), `merge`, `ai_enrichment`, `admin`, `correction`.
  More can be added later.
- **Status:** `kept`, `removed`, `review` (waiting for an admin). A new row is `kept`.
- **Uniqueness:** one row per book and normalized title. The normalization: NameNormalizer and
  QuoteNormalizer, then case-folded and whitespace-squeezed (`Services::Books::Verification::Check.normalize`
  is exactly this today). *(My call: the merger dedupes exactly and enrichment by `downcase`; one rule is
  needed and this is the existing one.)* Two spellings that collapse to one stay one row.

**The array stays, as a copy.** `books_books.alternate_titles` becomes a cached copy of the book's
`kept` rows, in a stable order. Whenever a book's rows change, the array is rewritten from the rows.
Every reader (search indexing, the book page, the API, verification, the finder, the author profile,
the eval export, the AI prompts) keeps working unchanged until Part 4.

**Every writer goes through the table:**

- `BooksMigration::BookTransformer` (the legacy migration and the weekly `data_migration:sync`):
  source `legacy`.
- `Books::Book::Merger#absorb_alternate_titles`: the source book's rows **move** to the target with
  their source, status and verdicts intact (a `removed` row stays `removed`). The source book's main
  title becomes a new `merge` row on the target unless the target has a `removed` row for it. Where both
  books hold the same title, the target's row wins and a `removed` on either side wins over `kept`.
  *(My call: removed titles are never lost and never come back through a merge.)*
- `Services::Books::ApplyBookFacts` (AI enrichment): source `ai_enrichment`.
- The admin book form: source `admin`. An admin removing a title from the form marks its row
  `removed`, with the reason "removed by admin". **The form changes from one comma-separated text box
  (`alternate_titles_string`, split on commas) to one input per title**, as the corrections review
  already has. Under the old box, saving a book whose title holds a comma ("Good Night, Mr. Tom") would
  split it into two titles and mark the real one removed. *(My call: the anti-goal forbids that; this
  needs a Playwright E2E test.)*
- Accepted corrections (`correctable_field :alternate_titles`): source `correction`. A title the
  accepted correction leaves out is marked `removed` ("removed by correction"), and a correction may
  reinstate a removed title, because an admin accepts every correction. *(My call: corrections are the
  public way to fix junk titles, so they must be able to remove one.)*
- `Services::Books::NormalizeStoredNames`: rewrites the row's title in place.

**A removed title cannot come back.** A writer that would add a title whose normalized form matches a
`removed` row of the same book skips it. The admin form and accepted corrections are the exceptions: an
admin may type a removed title back, and that reinstates the row (`kept`, source `admin` or
`correction`).

**Backfill:** a migration-time task creates one `legacy` row per existing array element, for every
book, and is idempotent. The array is unchanged by it.

### Part 2: the AI review

**One AI call per book**, on the `fast` role (`Services::Ai::Tasks` pattern, an `OpenAI::BaseModel`
response schema). The call sees:

- the book's title, subtitle, authors and first published year;
- the whole alternate-title list, numbered.

For each numbered title it returns:

- a verdict, `same_work` or `not_same_work`;
- a category:
  - for `same_work`: `translation`, `variant`, `fuller_title`, `short_title`;
  - for `not_same_work`: `other_work`, `volume_or_part`, `combined_edition`, `junk`;
- a confidence;
- a one-sentence reason.

Results are keyed by number, so a dropped or repeated entry is detected and the book is retried, as
`CategoryCleanup::BaseCleanupTask` does. Very long lists are split into chunks of the call's size,
always together with the book's own details.

**What a verdict does:**

- **`same_work`:** the row stays `kept`, and the verdict is recorded on it.
- **`not_same_work` at or above the auto-remove confidence:** the row becomes `removed`, and the
  verdict is recorded. The threshold is configured in `config/initializers` (start at 0.8), and the
  rehearsal decides it.
- **`not_same_work` below the threshold:** the row becomes `review` and waits for an admin. While in
  review the title stays in the array copy (it is not yet judged wrong).
- **Rows whose source is `admin`** are never removed automatically. A `not_same_work` verdict on them
  goes to `review` whatever the confidence.

**The review queue:** the existing admin review queue for `Books::RepairVerdict`
(`Admin::Books::RepairVerdictsController`) gets a new kind for alternate titles. Approve removes the
title; reject keeps it, and the decision is recorded on the row. *(My call: it reuses a queue Shane
already uses rather than adding a new page; the builder may choose otherwise if the queue does not
fit.)*

**Titles added later** (merges, enrichment, the legacy sync) arrive with no verdict. They are reviewed
when the rake task runs again: a book with any unjudged row is sent again, with its whole list as
context, and verdicts are applied only to the unjudged rows, so a recorded decision never flips. *(My
call: no new books are being added for now, so nothing needs reviewing on write; re-running the task
covers merges and the sync.)*

**Where Shane checks decisions:** an "Alternate titles" card on the admin book page lists every row
with its source, status, verdict, category, confidence, reason and a link to the AI chat, with a
"restore" button on removed rows. It is modelled on the Identifiers card (#407). The report task covers
the bulk view. *(My call: needs controller tests and a Playwright E2E test.)*

**Order and scope:**

- Ranked books first, by rank, then every other book with alternate titles.
- Resumable: a book whose rows all carry an AI verdict is not sent again.
- Run as Sidekiq jobs on the `low` queue, one per book, enqueued in bulk like
  `GoodreadsReplay::ResolveEditionJob`.
- A rake task queues a scope: `ranked`, `all`, or a count.
- A report task prints counts by verdict, category and source, plus samples per category.

**Putting a title back:** the card's restore button (or a rake task) sets a row back to `kept`, records
who and why, and rewrites the array.

### Part 3: undo what removed titles let in

After the review of the ranked books, for every verified book with a newly removed title:

- **Stage 2 and 3 trusted writes.** Take each verification finding that wrote or upgraded an identifier
  (`added`/`confirmed`, source `open_library` or `worldcat`). If its evidence title agrees with the book
  only through a removed title, undo it:
  - an `added` identifier is destroyed, if it is still held by this book with the same source;
  - a `confirmed` one goes back to its `previous_source`.

  Agreement is judged with the verification pass's own title rule (`Services::Books::Verification::Check`
  and `EditionCheck`), using the book's main title, its `kept` titles and the settled Open Library
  work's title. A finding that still agrees through any of those stays.
- **Stage 1 work keys.** A book whose settled Open Library work agrees with the book only through a
  removed title (City of Ladies settled on the *Treasure* work) is listed in the report and its work key
  is not changed: Shane decides what to do with the list. For these books the settled work's title does
  **not** count as agreeing in the rule above, so the edition ISBNs that agree only through that work are
  undone too. *(My call, precision first: otherwise every ISBN of a wrongly settled work survives through
  the work's own title.)*
- **Recording and dry run.** Every undo is recorded (the finding, the identifier, what was done) so it
  can be listed and reversed. The task has a dry run that prints counts and samples before it writes.
- **A repeating step.** Titles keep being removed after the first run: the review queue, the admin
  form, corrections, and the review of unranked books. Part 3 is idempotent and processes every
  `removed` row it has not processed before (a per-row marker), so it is simply run again after each of
  those. A title in `review` still counts as agreeing: it is not judged wrong yet. Its entry in
  `docs/launch-todo.md` says it repeats. *(My call.)*

### Part 4: drop the array

When Parts 1 to 3 are done and the second-chance branch is merged (both touch the verification
readers), move every reader to the table and drop `books_books.alternate_titles`:

- search indexing;
- the book page and the admin pages;
- the API;
- verification (`Check`, `EditionCheck`, `WorldCatCheck`, `Signals`);
- `AmazonBookCheck` and the import finder;
- the author profile;
- the eval export;
- the AI prompts (`BookFactsTask`, `AmazonBookMatchTask`);
- the corrections field.

Collection views and the finder must preload, not query per book. This part is its own plan.

## Proving it

1. Unit tests for every writer, the no-come-back rule, the array copy, the verdict application, and
   the Part 3 matching rule (an identifier that matched through both a removed and a kept title stays).
2. **Dev rehearsal of Part 2 on the ranked books** (dev is a production restore). Snapshot dev first.
   Hand-check:
   - the known cases: City of Ladies, Catch-22, A Season in Hell, My Struggle, Don Camillo,
     War and Peace's 66;
   - 50 random removals;
   - 50 random keeps;
   - every removal of a title from a non-Latin script.

   Success: no real translation or variant auto-removed in the sample. If one is, raise the
   threshold or move that category to review.
3. Part 3's dry run on dev, with its counts and samples checked by hand, before it writes.
4. Production in the same order: Part 1 (deploy, backfill), Part 2 (ranked, then all), Part 3
   (dry run, then apply). Each step goes in `docs/launch-todo.md`.

## Left to the builder

- Names of the model, the enums' integer values, the services, the jobs and the rake tasks.
- The exact prompt wording and the chunk size for long lists.
- How the array copy is refreshed (an explicit call after each write, not a callback on the row, is
  preferred: `after_commit` sees only the last save).
- Whether Part 3 runs as one task or per book jobs.
