# Open Library key backfill

Checks or adds an Open Library work key on every book, ranked books first, and gives authors keys
along the way. Spec: `docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md`.

## Running it

```bash
bin/rails "books:ol_backfill[100]"                 # one run of 100 books, ranked first
bin/rails "books:ol_backfill[all]"                 # everything not yet done (weeks; see "How long it takes")
bin/rails "books:ol_backfill[100,retry_unsure]"    # also retry unsure books from an older OL version
bin/rails books:ol_backfill_report                 # outcome counts, ranked coverage, latest run, recent swaps
bin/rails "books:ol_backfill_revert[123]"          # put book 123's keys back
```

Each run is one `Books::OpenLibraryBackfillJob` on the `low` queue. It holds one of Sidekiq's five
threads for as long as it runs, which is days for `[all]`. It works through books one at a time:
ranked books by rank, then by how many lists a book is on, then by id. A book with a log row is never
taken again, except a `failed` one (and an `unsure` one under `retry_unsure`). Books with a `failed`
row are retried after books never tried, and one run never takes the same book twice. A deploy
stops the run (the worker is killed before Sidekiq would requeue the job). Run the rake task again
afterwards and it carries on; logged books are skipped.

Only one run runs at a time, enforced by a PostgreSQL session advisory lock (`Run::LOCK_KEY`). A run
started while another is in progress exits immediately with `stopped` and an error; queue it again
later. The unique `book_id` on the log row is only a backstop.

After each book that went through `/resolve`, the run waits 4 seconds (`Run::RESOLVE_PAUSE`). The
service runs one `/resolve` at a time, and the pause lets other callers (the wizard, the Goodreads
replay, legacy imports) take the slot. A book settled by the fast pass is not followed by a pause.

Errors are handled by what they are about:

- An error about one book (HTTP 400 or 422, or a response that cannot be parsed) logs that book
  `failed` at once, and the run continues.
- Any other Open Library error (network, timeout, 5xx, busy, 401/403/429, breaker open) waits and
  retries for about 13 minutes. If it is still failing, that book is logged `failed` and the run
  stops. Run the task again later.

## One book

1. **Fast pass:** look up the book's ISBNs and Goodreads ids (`GET /identifiers`, 0.2-0.6 s each over
   the tunnel), at most five (`Lookup::MAX_FAST_LOOKUPS`), all at once in one thread each. An error
   from any of them is raised as before. If they all point at one work, and its title and an author agree with ours, that is the answer.
   An identifier the service rejects (400/422) or does not know (404) counts as no hit.
2. **Full match:** otherwise one `POST /resolve` (12-13 s) with title, authors, year, ISBNs and the
   stored key as a hint. Acted on only for an `accept` that passes the same check.

Titles agree when equal after normalizing, or once a subtitle is dropped from one side (never both).
Authors agree when any of these holds: a name (or alternate name) of ours equals one on the work
after normalizing; the two names are equal once reduced to letters only, with diacritics stripped
("J.R.R. Tolkien" and "J. R. R. Tolkien"; a reduced name under four letters is ignored); one of our
authors holds an Open Library author key the work lists; or one of our names equals the name or an
alternate name on the work's Open Library author records. Those records (`/authors/batch`, the first
five author keys) are fetched only when the title agrees and the plain comparison failed. No AI is
involved.

`/resolve` is sent at most three ISBN-13s, three ISBN-10s and three Goodreads ids
(`Lookup::RESOLVE_IDENTIFIERS_PER_TYPE`).

When `/resolve` does not accept (it abstains on margin, which famous books with many near-identical
Open Library records do) but its top candidate is a work key the book already holds and that
candidate passes the check, the book is `confirmed` with no change at all: no key added, swapped or
removed, no duplicates saved, no author keys. The row has `confirmed_on_abstain` set, and the report
counts these. Any other non-accept stays `unsure`. A confirmed-on-abstain book flags no pair either.

| Outcome | Meaning |
|---|---|
| `confirmed` | the stored key was right |
| `updated` | the stored key redirects to the answer; moved to the current key |
| `replaced` | the stored key was another work, or dead; swapped (old key in the log). An old key whose own record agrees with the book on title and author is kept as a duplicate key |
| `keyed` | the book had no key; added |
| `duplicate_pair` | another book holds the answer; nothing saved, pair in Books → Duplicates |
| `unsure` | no confident, agreeing answer; nothing changed |
| `removed` | no confident answer, and a stored key's record is clearly another book; that key was removed (see below) |
| `failed` | Open Library failing, or an error about this book; retried by a later run |
| `reverted` | undone by `books:ol_backfill_revert`; never redone |

**removed.** A book with no trusted answer would stay `unsure` and keep its stored key, so a key the
old code gave to the wrong book (a generic title holding a famous book's key) would stay for good.
Instead, the book's stored keys are fetched in one `works_batch` call. A key is clearly another book
when its record exists, its title does not agree with the book's, and no author agrees either (missing authors, on the book or on the record, count as unknown, not as disagreement; the key Open Library itself accepted or ranked top is never removed) (the
record's Open Library author records are fetched only when the plain comparison fails). Every such key
is removed and the outcome is `removed`, with `old_keys` holding all keys from before and no new key.
A dead key (no record) is kept, as is a key whose record agrees on the title or on an author. A
`removed` row is settled and can be reverted. No author keys, duplicates or pairs come from it.

**Pairs need a real holder.** Another book holding the answer as its work key counts as a holder only
if its title agrees with the matched work (title only: its authors can be missing in legacy data).
A book holding the key wrongly ("The Collection" holding *Little Women*'s key) is no holder: it does
not make the book a `duplicate_pair`, is not flagged, and does not stop a duplicate key from being
saved. With several holders, the lowest-id real one is the pair. The same test applies to a work key
given while another book holds it as a duplicate key.

A book that already holds Open Library's answer stays `confirmed` even when another book holds the
same key. The pair is still flagged and `pair_book_id` is set, so `pair_book_id` can appear on a
`confirmed` row, not only on `duplicate_pair`.

A row that holds a result (anything but `failed` or `unsure`) is never overwritten: a second run, or
a run that settled the book while another was looking it up, skips it, and so does a failure record.

When the key a book is given is held by another book as a duplicate key, the pair is flagged; the key
is still saved.

A full match also saves Open Library's duplicate works as `books_work_openlibrary_duplicate_id`. The
book finder treats a book holding the accepted work under that type as a candidate with no verdict. In
the list wizard, a row's Import re-check prefers a book holding the key as its work key over one
holding it as a duplicate key.

Authors of a book that ends with a trusted key take the work's author keys: an author with no key
gets one; an author whose key another author holds becomes an author pair; an author with a different
key is left alone and counted as a conflict.

## How long it takes

Measured on 200 top-ranked books: about 4 books a minute before the fast pass was cut to five
concurrent lookups. Most of the time went to identifier lookups and full matches. The full run is
likely 2-4 weeks, and the top few thousand ranked books finish in the first days. Unranked books
probably have fewer identifiers, so they may go faster, but that is not measured.

## The log

`books_open_library_backfills` (`Books::OpenLibraryBackfill`), one row per book: outcome, lookup
(`identifiers` or `resolve`), old and new keys, duplicate keys saved, pair book, author changes, the
Open Library dump date and matcher version, run id, attempts and error.

## Reverting

`books:ol_backfill_revert` removes only the work key the backfill gave the book, restores its old
keys, and removes the duplicate keys the run saved. A work key that arrived afterwards (a merge, an
admin) stays. It also removes the author keys the backfill added for that book; another book
processed later may have relied on the same author key, so check those books. Pairs the run flagged
stay in the Duplicates queue.

## Reading the report

Check the `replaced`, `duplicate_pair` and `removed` lines: every replacement or removal is a key the
old code assigned and Open Library contradicted. A wrong one is undone with the revert task. Pairs are reviewed in the
Duplicates queue like any other.
