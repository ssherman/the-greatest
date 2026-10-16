# Book verification pass

One pass per book that settles which Open Library work it is, takes the identifiers that work's
editions tie to the book, confirms the ISBNs we hold against WorldCat, and records signals (wrong
identifiers, lumps, omnibuses) for later work to act on. It replaced the Open Library key backfill,
whose logic is now stage 1. By default it takes ranked books created before the Goodreads imports
feature (`pre_import`). Spec: `docs/superpowers/specs/2026-10-16-book-verification-design.md`.

Four stages, each committing on its own:

1. **Work.** Find the book's Open Library work and fix its key.
2. **Identifiers from editions.** Write the identifiers of the work's agreeing editions.
3. **WorldCat.** Confirm held ISBNs one at a time.
4. **Signals.** Record held identifiers that point at other works.

Every identifier the pass writes or confirms carries a source (`open_library` or `worldcat`), which
is what `Identifier.verified` reads. See `docs/features/identifier-provenance.md`.

## Running it

```bash
bin/rails "books:verify[200]"                      # one run of 200 books: ranked, pre_import
bin/rails "books:verify[all]"                      # everything not yet done (days to weeks)
bin/rails "books:verify[all,post_import]"          # also the post_import cohort
bin/rails "books:verify[all,unranked]"             # continue past the ranking into the rest
bin/rails "books:verify[200,retry_unsure]"         # also retry unsure books from an older OL version
bin/rails "books:verify[all,recheck]"              # redo stages 2-4 for books with new legacy identifiers
bin/rails books:verify_report                      # counts, coverage, signals, latest run, samples
bin/rails "books:verify_revert[123]"               # put book 123's keys and sources back
```

Flags go after the count, in any order: `post_import`, `unranked`, `retry_unsure`, `recheck`. An
unknown flag or count aborts with a usage line.

Each run is one `Books::VerificationJob` on the `low` queue. It holds one of Sidekiq's five threads
for as long as it runs. It works through books one at a time: ranked books by rank, then (with
`unranked`) the rest by how many lists a book is on, then by id. The default scope is ranked
`pre_import` books, and it also applies to `retry_unsure` and `recheck`: add `unranked` or
`post_import` to widen them.

A book is taken when it has no log row, when its row stopped at a stage (`stage` is not `done`), or
when its stage 1 `failed`. Books with a `failed` row come after books never tried, and one run
never takes the same book twice. `retry_unsure` also takes `unsure` rows from an older Open Library
dump or matcher version, and starts them over at stage 1. `recheck` takes `done` books that hold a
`legacy` identifier created after the row's `checked_at` (the weekly sync keeps adding them) and
re-runs stages 2-4: from the editions if stage 1 settled a work, from WorldCat if not. `recheck`
never takes a reverted book.

A book resumes at the stage it stopped at and never repeats an earlier one. A deploy puts the run
back on the queue (the worker's 30 s stop grace period outlasts Sidekiq's 25 s shutdown timeout).
It starts again with the same run id, so its earlier books still count toward the limit. The book in
progress is redone from its stored stage. A worker crash loses the run instead: run the rake task
again and it carries on under a new run id.

Only one run runs at a time, enforced by a PostgreSQL session advisory lock (`Run::LOCK_KEY`). A run
started while another is in progress exits immediately with `stopped` and an error; queue it again
later. The unique `book_id` on the log row is only a backstop.

After each book that went through `/resolve`, the run waits 4 seconds (`Run::RESOLVE_PAUSE`). The
Open Library service runs one `/resolve` at a time, and the pause lets other callers (the wizard,
the Goodreads replay, legacy imports) take the slot. Stages 2-4 never call `/resolve`. WorldCat gets
no pause.

Errors are handled by what they are about:

- An error about one book stops that book at its stage with `stage_error` and the run continues.
  That is a 404 from either service (Open Library 404s a work's editions when a dump refresh removed
  the key), a 400 or 422, or a response that cannot be parsed. In stage 1 the book is logged
  `failed`.
- A WorldCat 504 (the service's 5 s deadline) on one ISBN counts as no answer for that ISBN; the
  book completes stage 3.
- Any other error (network, timeout, 5xx, busy, 401/403/429, breaker open) waits and retries after
  15, 30, 60, 120, 240 and 300 seconds. If it is still failing, the book stops at its stage and the
  run stops. Run the task again later.

## Stage 1: the work

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
| `reverted` | undone by `books:verify_revert`; never redone |

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

## Stages 2-4

### Stage 2: identifiers from editions

Runs when stage 1 settled a work (`confirmed`, including on abstain, `updated`, `replaced` or
`keyed`). It fetches the work's editions from Open Library. An edition **agrees** when:

- **Title.** Its title, with its subtitle, agrees with one of our titles or the Open Library work's
  full title. Titles agree when equal after normalizing, or once a subtitle is dropped from one side,
  never both. A subtitle dropped from the edition must not name a set: box set, boxed set (hyphenated and closed forms too: `box(ed)[ -]?set`),
  collection, omnibus, trilogy, volumes, books 1 (`EditionCheck::SET_WORDS`, whole words, case
  folded). Stage 3 uses this same rule on the WorldCat record's title, with its " : subtitle" as the
  subtitle. The list is narrow on purpose: "complete" or "series" would reject every "Complete and
  Unabridged" edition.
- **Year.** Its publish year is absent, or at least the book's first published year minus one. A book
  with no first published year skips the rule.

From agreeing editions, ISBN-13s, ISBN-10s, OCLC numbers and Goodreads ids are written at work level
(`books_work_isbn13`, `books_work_isbn10`, `books_work_oclc_id`, `books_work_goodreads_id`), with
invalid ISBNs dropped. For each value:

- This book holds it as `legacy`, unset or `goodreads_import`: its source becomes `open_library`
  (finding `confirmed`, with the previous source).
- This book already holds it as `open_library` or `worldcat`: nothing.
- Another book holds it as verified: not written (finding `conflict`, with that book).
- Another book holds it, not verified: written here as `open_library` (finding `added`) plus an
  `also_held` finding naming the other book. The other book is not touched.
- Nobody holds it: written as `open_library` (finding `added`).

Every edition that does not agree (translations, box sets, odd titles) is kept as a row in
`books_edition_candidates`, outside `identifiers`, for a later step to sort. Held ASINs and EAN-13s
are never confirmed by the pass and stay `legacy`.

### Stage 3: WorldCat

Runs for every processed book whatever stage 1 decided, `unsure` included, because our own title and
authors are what WorldCat is checked against. It takes the book's ISBN-13s and ISBN-10s still not
verified after stage 2, normalizes them to ISBN-13, drops invalid ones, deduplicates, and looks up at
most 50 (`MAX_WORLDCAT_ISBNS`), one `GET /isbns/{isbn}` each (about 2.7 s on the home server). A
record **agrees** when all three hold:

- **Title.** Agrees by the title rule, after dropping WorldCat's " : subtitle" form.
- **Creator.** Its creator or one of its contributors agrees with one of our authors by the
  letters-only author rule, "Last, First" order accepted.
- **Year.** Absent, or at least our first published year minus one.

Outcomes for one ISBN:

- **At least one record agrees.** Every held row of that ISBN (its ISBN-13 and ISBN-10 forms)
  becomes `worldcat` (finding `confirmed`), and the agreeing records' OCLC numbers are added as
  `books_work_oclc_id` with source `worldcat` (finding `added`). The pass never writes the other
  ISBNs a record lists, so a box set's ISBNs cannot spread.
- **Records exist and every one disagrees on both title and creator.** Finding `wrong_identifier`,
  with the records' OCLC numbers, titles, creators and years in `evidence`. Nothing is removed.
- **Anything else** (no record, or records agreeing on only one of title and creator): nothing.
  Garbled records fail the check and never confirm. A garbled record (mojibake in its title or
  creator) is never `wrong_identifier` either: it may be the right book, so it counts as unknown.
- **A WorldCat 504** (the service's 5 s deadline) on one ISBN counts as no answer for that ISBN; the
  book completes stage 3.

### Stage 4: signals

Recorded, never acted on. The book's held ISBNs and Goodreads ids still not verified (at most 20,
`MAX_SIGNAL_LOOKUPS`, five at a time) are looked up in Open Library. A hit on a work that is not the
stage 1 work, not one of its duplicate keys and not a redirect of it is fetched, and if its title
disagrees with ours the identifier gets a `foreign_work` finding. A work whose title agrees is an
unmerged Open Library duplicate of the same book and is ignored. When stage 1 settled no work,
every hit is judged by the title rule alone. The fast pass's answers are not reused, because a
resumed book runs stage 4 in a later run.

There is one `foreign_work` finding per identifier. Its `work_key` is the lowest foreign work key,
and `evidence["works"]` lists every foreign work it hits as `{key, title}`. A re-run deletes the
row's `foreign_work` findings and computes them again, so stale ones do not stay. A book whose
findings name **two or more distinct foreign works** is a **lump suspect** (`lump_suspect` on its
row): the shape of "X Men" holding several volumes' identifiers, or an omnibus holding its novellas'
ISBNs. Telling a lump from an omnibus is later work.

## Cohorts

A book's cohort comes from its id. `post_import` is the id range `16_572...250_000`; everything else
is `pre_import` (`Cohort`). Legacy book ids are strictly monotonic with legacy `created_at`, and the
first book created on or after the Goodreads imports feature (2024-09-09 03:22:31 UTC) is id 16,572,
with no exceptions either side (measured on the legacy database 2026-10-16). Ids are preserved by the
migration, and books created in the new app start at the reserved ceiling of 250,000 and count as
`pre_import`. So the cohort needs no legacy query. The default run skips `post_import` books until
the Goodreads rebuild has repaired their titles and authors; the `post_import` flag includes them.

## The log

- `books_verifications` (`Books::Verification`), one row per book (unique `book_id`): `work_outcome`
  (the stage 1 outcome), lookup (`identifiers` or `resolve`), old and new keys, duplicate keys saved,
  pair book, author changes, the Open Library dump date and matcher version, `cohort`, `stage` (the
  next stage to run), `stage_error`, `added_count`, `confirmed_count`, `candidate_count`,
  `wrong_count`, `lump_suspect`, `worldcat_dump_date`, `checked_at` (when stages 2-4 last ran), run
  id, attempts and error.
- `books_verification_findings`, one row per identifier the pass wrote, changed or flagged: `kind`
  (`added`, `confirmed`, `conflict`, `also_held`, `wrong_identifier`, `foreign_work`), the
  identifier, the `source` set and the `previous_source`, `other_book_id`, `work_key`, and
  `evidence`. Unique per verification, kind, type and value.
- `books_edition_candidates` (`Books::EditionCandidate`), one row per non-agreeing Open Library
  edition: edition key, work key, title, subtitle, language, publish year and its identifiers. Unique
  per book and edition key.

## Reading the report

`bin/rails books:verify_report` prints "Book verification pass" and then:

- book counts by cohort and stage, and by work outcome;
- ranked identifier coverage by type and source, verified against `legacy`;
- findings by kind, lump suspects and candidates;
- the latest run, its failure and the last stage error;
- recent risky changes: the latest `replaced`, `removed` and `duplicate_pair` books;
- random samples: 10 books per work outcome (with Open Library's title when it can be reached), 10
  Open Library trusted writes (stage 2's `added` and `confirmed` findings, with the edition they
  came from), 10 WorldCat confirmations and 10 `wrong_identifier` findings.

Check the `replaced`, `duplicate_pair` and `removed` lines: every replacement or removal is a key
the old code assigned and Open Library contradicted. The samples are how the quiet outcomes get
checked too; read them. Pairs are reviewed in the Duplicates queue like any other.

## Reverting

`bin/rails "books:verify_revert[<book id>]"` undoes one book:

- It restores stage 1's keys from the row (old keys come back as `legacy`), but only for `confirmed`, `updated`, `replaced`, `keyed`
  and `removed` rows.
- It deletes the identifiers the pass added and restores the previous source of the ones it
  confirmed, only while the identifier is still on this book. One that moved (a merge) or was deleted
  is skipped and counted; the task prints the count.
- It deletes the book's findings and candidates, and marks the row `reverted`. A reverted book is
  never redone, and `recheck` skips it.

A work key that arrived afterwards (a merge, an admin) stays. Another book processed later may have
relied on an author key the pass added, so check those books. Pairs the run flagged stay in the
Duplicates queue.

## How long it takes

Estimated, not yet measured: stage 1 about 4-12 s per book, editions 4-5 s, WorldCat about 7 s (two
or three unconfirmed ISBNs at 2.7 s each), signals about 2 s, so 20-28 s a book. That puts the ranked
`pre_import` books at 3-4 days, the whole ranking with `post_import` at about a week, and the
unranked catalogue at 6-7 weeks. The before-merge run of `books:verify[200]` replaces these with
measured per-stage timings. Stage 1 alone measured about 4 books a minute on 200 top-ranked books.
