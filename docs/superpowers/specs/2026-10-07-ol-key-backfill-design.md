# Open Library key backfill for books and authors

**Status:** design, approved in conversation 2026-10-07 · **Branch:** `worktree-ol-key-backfill`

This is spec 3 of 3 for the books list importer:

1. OL matcher v3 (#354).
2. The books list wizard on a shared wizard core (#357, then #361 and #362).
3. **This spec:** check or add an Open Library work key on every book, and give authors keys along the way.

It is built now. Shane runs it in production only after the cutover. The books data migration is re-run before launch, so the backfill is re-run after every migration pass.

## Why

The wizard, the Goodreads import and the duplicate sweep all find our existing book partly through its Open Library work key. Today:

- 31,663 of 160,587 books carry a key (dev, 2026-10-06), and those keys were assigned by very old matching code. The Open Library service's own notes put dead stored keys at 9.9%, and 380 keys sit on more than one book. The v3 replay found 2 of 79 stored keys pointing at a different book (*Rosewater* holds its sequel's key).
- About 129k books have no key. A list row naming one of them can only be matched by title and author.
- 16,585 of 71,812 authors carry a key.

A key we trust stops the importers from creating duplicates. A key two of our books both hold exposes a duplicate pair.

## Decisions (from Shane)

- Stored keys are **checked, not trusted**.
- When Open Library confidently names a different work, and our title-and-author check agrees, the key is **replaced automatically**. The old key goes in the log so the change can be looked up or reverted.
- Open Library's duplicate works are saved as a **separate identifier type** and are never treated as certain.
- Duplicate pairs go to the existing review queue. They are **never merged automatically**.
- Authors get keys **only from confident book matches**. There is no separate author pass.
- It runs as a **rake task with a count or `all`**. A re-run never repeats a book already handled.
- **Ranked books go first.**
- Open Library stays at **one `/resolve` at a time** (about 12-13 s each on the home server).
- **No AI calls.** Open Library's confident answer plus our own check decides.

## 1. One book

### The title-and-author check

Used by both passes:

- **Title agrees:** the two titles are equal after the finder's normalization, or equal once a subtitle (text after the first ":") is dropped from either side, or Open Library's title equals one of our `alternate_titles`.
- **Author agrees:** at least one of our book's authors (name or alternate name, normalized) equals one of the work's author names.

**Amended 2026-10-08.** The author check is wider than "a name equals a name": names also match once reduced to letters only (diacritics stripped; under four letters ignored), an author of ours holding an Open Library author key the work lists agrees, and so does a name of ours equal to a name or alternate name on the work's Open Library author records (`/authors/batch`, first five keys, fetched only when the title agrees and the plain comparison fails).

### Pass 1: the fast lookup

- Look up each of the book's ISBN-13s, ISBN-10s and Goodreads ids with `Client#identifier`. *Amended 2026-10-08:* at most five lookups, run concurrently, 0.2-0.6 s each over the tunnel. Then fetch every work they point to in one `Client#works_batch` call.
- **Settled here** only when every hit points at the same single work and that work passes the title-and-author check.
- **Anything else goes to pass 2:** no hits, hits on more than one work, or a failed check.

### Pass 2: the full match

- `Client#resolve` with title, author names, year, ISBNs and `existing_ol_key` (the stored key, which the matcher treats as a hint).
- Acted on only when the decision is `accept` **and** the accepted work passes the title-and-author check. Otherwise the outcome is `unsure`.

### Outcomes

| Outcome | When | Change |
|---|---|---|
| `confirmed` | the answer equals the stored key | none |
| `updated` | the stored key resolves through Open Library's redirects to the answer | stored key replaced by the answer |
| `replaced` | the stored key is a different work, or dead | stored key replaced by the answer; old key logged |
| `keyed` | the book had no key | key added |
| `duplicate_pair` | another of our books already holds the answer as its work key | no key saved; the pair is flagged |
| `unsure` | `abstain`, no candidates, or the check disagreed | none; the stored key stays |
| `failed` | Open Library down or erroring after the retries | none; retried on the next run |
| `reverted` | an admin ran the revert task | the backfill's changes undone; never redone |
| `removed` | *Amended 2026-10-08.* no trusted answer, and a stored key's record is clearly another book (title and author both disagree) | that key removed; old keys logged; revertible |

**Amended 2026-10-08, rulings from the 200-book measurement:**

- **Confirm on abstain (Shane).** When `/resolve` abstains but its top candidate is a key the book holds and passes the check, the book is `confirmed` with no change at all (no key, duplicate, author or pair changes), flagged `confirmed_on_abstain`.
- **`removed` (Shane).** For a book that would end `unsure`, one `works_batch` fetches its stored keys' records; a key whose record exists and fails both the title and the author check is removed. A dead key, or a record agreeing on either, is kept. Missing authors (on the book, or on the record) are unknown, not disagreement. The key Open Library accepted or ranked top is never removed.
- **Real holder for pairs.** Another book holding the answer as its work key is a holder only if its title agrees with the matched work. A non-real holder is ignored: no `duplicate_pair`, no flag, and it does not block saving a duplicate key. The lowest-id real holder is the pair.
- **Replaced keys that agree.** A replaced old key whose own record also passes the check is kept as a duplicate key (or flagged, if another book holds it as a work key).
- **Errors.** An error about one book (400, 422, unparseable response) logs `failed` and the run continues; any other error retries, then logs `failed` and stops the run.
- **Pause.** After a book that went through `/resolve`, the run waits 4 s so other callers can take the single slot.

- A book with several stored work keys (rare) is `confirmed` only if one of them is the answer. The others are removed and logged.
- **Redirect check.** To tell `updated` from `replaced`, the stored key is looked up with `works_batch`. A record whose key is the answer, or whose `redirected_from` lists the stored key, means `updated`.
- **Duplicate pairs** go through `Services::DuplicateCandidates::Flag`. The flag uses a new source, `ol_backfill`, and lists the key in its evidence.

### Open Library's duplicate works

When pass 2 ran, every key in `decision.duplicates` is saved on the book as a new identifier type, `books_work_openlibrary_duplicate_id` (enum value 9).

- A key another of our books holds as its work key is not saved. That pair is flagged instead. *Amended 2026-10-08:* only when that book really looks like the matched work (its title agrees); otherwise the duplicate key is saved and nothing is flagged.
- Pass 1 does not return duplicates, so books settled there get none.

## 2. Authors

Only for books that end `confirmed`, `updated`, `replaced` or `keyed`:

- **Pairing.** The matched work's authors come with keys and names. Each of our book's authors is paired with the one work author whose name agrees, comparing normalized names and alternate names. No pairing, or several, means that author is left alone.
- **What happens to a paired author:**
  - **No key, and no other author of ours holds it:** the key is added.
  - **Another author of ours holds it:** an author pair is flagged (`Books::Author` is already in the books review queue), and no key is saved.
  - **Holds the same key:** nothing changes.
  - **Holds a different key:** left alone and counted as an author conflict. Open Library has many duplicate author records, so a different key is often a duplicate rather than a mistake.
- The author changes are recorded on the book's log row.

## 3. The log

`books_open_library_backfills`, model `Books::OpenLibraryBackfill`. One row per book:

| Column | Notes |
|---|---|
| `book_id` | unique, foreign key |
| `outcome` | enum: the outcomes in section 1 |
| `method` | enum: `identifiers`, `resolve` |
| `old_keys`, `new_key` | work keys before and after |
| `duplicate_keys` | duplicate-type keys this run saved |
| `pair_book_id` | the other book of a `duplicate_pair` |
| `author_changes` | jsonb: keys added, pairs flagged, conflicts |
| `dump_date`, `matcher_version` | from the Open Library response's `source_version` |
| `run_id` | the run that wrote the row |
| `attempts`, `error` | how often a `failed` row was tried, and the last error |
| timestamps | |

*Amended 2026-10-08:* only one run runs at a time, enforced by a PostgreSQL advisory lock; a second run exits at once. The unique `book_id` is a backstop: an insert that loses the race is skipped only if the backfill row now exists, any other uniqueness failure propagates.

## 4. Running it

### The rake tasks

- `bin/rails books:ol_backfill[100]` (or `[all]`) queues one `Books::OpenLibraryBackfillJob` and prints its run id.
- `books:ol_backfill[100,retry_unsure]` also takes `unsure` rows whose `dump_date` or `matcher_version` is older than the service's current `/version`. Without the flag, `unsure` rows are never retried.
- `books:ol_backfill_report` prints:
  - counts by outcome;
  - ranked books checked out of ranked books total;
  - the latest run's progress;
  - author keys added, author pairs and author conflicts;
  - the 20 most recent `replaced`, `duplicate_pair` and `removed` books and `confirmed` books with a pair (*amended 2026-10-08*), with titles and keys, for spot checks.
- `books:ol_backfill_revert[<book_id>]` restores the old keys, removes the new key and any duplicate keys the backfill added, removes author keys it added, and marks the row `reverted`.

### The job

- `Books::OpenLibraryBackfillJob`, queue `low`, `retry: false`. Arguments: limit (nil for all), run id, retry_unsure.
- **Order:** ranked books (the default primary `Books::RankingConfiguration`) by rank, then the rest by how many lists they are on (descending), then id.
- **Skips** books with a log row, except `failed` rows, which are taken again (and `unsure` rows under `retry_unsure`).
- **Works one book at a time** and stops after `limit` books. Log rows with its run id count toward the limit, so a re-queued run (same run id) carries on rather than starting a fresh count.
- **Open Library failing:** the book is retried in place after waits of 15, 30, 60, 120, 240 and 300 s, as the wizard's Match does. If it still fails, the book is logged `failed` and the run stops, so an outage does not use up the batch. The circuit breaker's open state counts as failing.
- If the job dies outright, running the rake task again picks up where it stopped.

### Speed

- Pass 2 takes 12-13 s. *Amended 2026-10-08:* pass 1 measured 4-5 s per famous book (0.2-0.6 s per lookup, ten lookups in series), about 4 books a minute overall; the cap of five concurrent lookups is meant to cut that. The "about a week" below was an estimate; expect 2-4 weeks.
- About 76% of books carry an identifier that reaches an Open Library work (`docs/data-quality/books-identifier-coverage.md`). If most of those settle in pass 1, `all` takes about a week rather than the roughly 24 days pass 2 alone would.
- The top few thousand ranked books finish on the first day.
- **Sharing Open Library with the wizard:** each waits its turn for the single slot, so the wizard gets slower while the backfill runs.

## 5. Duplicate keys in the finder

- **`OpenLibrarySource`:** looks up books holding an accepted or returned key as `books_work_openlibrary_duplicate_id`. Such a book is a candidate with no verdict, as duplicate holders are today. It blocks rule 5 (no create from that work) and is flagged with the key's holders as an `external_key_collision`. Rule 4 or the AI decides; it is never certain.
- **The wizard's Import re-check** (`Books::Adapter#recheck` → `book_holding`) also matches duplicate-type keys.
- **The Identifiers source** is unchanged. A query never carries a duplicate key.

## 6. Testing

Minitest, with the Open Library client stubbed:

- **One book:**
  - each outcome;
  - pass 1 settling, and handing over on several works or a failed check;
  - the subtitle-tolerant title check;
  - duplicates saved only from pass 2;
  - a duplicate key held elsewhere becoming a pair;
  - author keys added, author pairs, author conflicts;
  - several stored keys.
- **The job:**
  - ordering;
  - skipping logged books and taking `failed` ones;
  - the limit, including across a requeue with the same run id;
  - stopping on an outage after the retries;
  - `retry_unsure` taking only older-version rows;
  - the unique-row race.
- **Finder:** a duplicate-type holder is a candidate with no verdict and blocks a create. The Import re-check finds it.
- **Rake tasks:** argument parsing; the report's counts; revert.

No E2E: there is no new page.

**Before merge,** on a snapshot of the dev database (`bin/snapshot-dev-db.sh --label pre-ol-backfill`):

1. Run `books:ol_backfill[200]` against the live Open Library service.
2. Run the report.
3. Hand-check every `replaced` and `duplicate_pair` book.
4. Put the outcome mix, the time taken and the hand-check in the PR. If replacements are wrong more than rarely, stop and revisit the check before merging.

## 7. Docs

- `docs/features/open-library-backfill.md`: what it does, the outcomes, the tasks, and how to read the report.
- `docs/launch-todo.md`: run `books:ol_backfill[all]` in production after the cutover data migration, and again after any re-run of it.
- `docs/features/open-library-data-service.md`: the duplicate-type holder rule.

## Out of scope

- A separate author pass for authors with no matched books.
- Replacing an author's existing key.
- Any admin page for the backfill. The report task covers it.
- Changing Open Library's concurrency.
