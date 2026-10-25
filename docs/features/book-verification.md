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
bin/rails "books:verify[all,second_chance]"        # once: give done unsure and removed books another try (see Second chance)
bin/rails "books:verify[all,recheck]"              # redo stages 2-4 for books with new legacy identifiers
bin/rails "books:verify[500,reharvest]"            # once: redo stages 2-4 for the books done before duplicate works were harvested
bin/rails books:verify_report                      # counts, coverage, signals, latest run, samples
bin/rails "books:verify_revert[123]"               # put book 123's keys and sources back
bin/rails "books:verify_revert_route[held_key]"    # undo every book one second-chance route settled
```

Flags go after the count, in any order: `post_import`, `unranked`, `retry_unsure`, `recheck`,
`reharvest`, `second_chance`. An
unknown flag or count aborts with a usage line.

Each run is one `Books::VerificationJob` on the `low` queue. It holds one of Sidekiq's five threads
for as long as it runs. It works through books one at a time: ranked books by rank, then (with
`unranked`) the rest by how many lists a book is on, then by id. The default scope is ranked
`pre_import` books, and it also applies to `retry_unsure`, `recheck`, `reharvest` and `second_chance`: add `unranked` or
`post_import` to widen them.

A book is taken when it has no log row, when its row stopped at a stage (`stage` is not `done`), or
when its stage 1 `failed`. Books with a `failed` row come after books never tried, and one run
never takes the same book twice. `retry_unsure` also takes `unsure` rows from an older Open Library
dump or matcher version, and starts them over at stage 1. `recheck` takes `done` books that hold a
`legacy` identifier created after the row's `checked_at` (the weekly sync keeps adding them) and
re-runs stages 2-4: from the editions if stage 1 settled a work, from WorldCat if not. `recheck`
never takes a reverted book. `reharvest` takes `done` books with a settled work that hold a
`books_work_openlibrary_duplicate_id` from Open Library, and re-runs stages 2-4 from the editions. It
exists for books verified before stage 2 harvested duplicate works (the first production 500, run
2026-10-17): run `books:verify[500,reharvest]` once, then plain runs. Like `recheck`, it also takes
never-verified books after the redone ones, up to the count. A book the same run already finished
is not taken again, so a re-queued run does not redo it, but any later `reharvest` run redoes every
such book again (every stage is idempotent, so that costs only time): do not add it to routine runs.

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
- A WorldCat 504 (the service's 25 s deadline) on one ISBN counts as no answer for that ISBN; the
  book completes stage 3.
- Any other error (network, timeout, 5xx, busy, 401/403/429, breaker open) waits and retries after
  15, 30, 60, 120, 240 and 300 seconds. If it is still failing, the book stops at its stage and the
  run stops. Run the task again later.
- Any error that is not from either service (a bug, or bad data such as "Twelfth Night" held as an
  ISBN-13) is logged with its backtrace and recorded on that book's row like a book-specific error,
  and the run continues. Three such errors in a row (`Run::UNEXPECTED_ERROR_LIMIT`; any other outcome resets the count) are not one
  book's data, so the run stops with the last one. The job has `retry: false`, so an error that
  escapes it never reaches Sidekiq's Retries or Dead lists: before this rule, one book's bad value
  ended a days-long run with nothing in the report. A book stopped this way is taken again by the
  next run (once per run).

Stage 4 looks up only values that are valid for their type (an ISBN that normalizes, a Goodreads id with
leading digits, slug forms included); the Open Library client also escapes every identifier value it puts in a URL.

## Stage 1: the work

1. **Fast pass:** look up the book's ISBNs and Goodreads ids (`GET /identifiers`, 0.2-0.6 s each over
   the tunnel), at most five (`Lookup::MAX_FAST_LOOKUPS`), all at once in one thread each. An error
   from any of them is raised as before. If they all point at one work, and its title and an author agree with ours, that is the answer.
   An identifier the service rejects (400/422) or does not know (404) counts as no hit.
2. **Full match:** otherwise one `POST /resolve` (12-13 s) with title, authors, year, ISBNs and the
   stored key as a hint. Acted on only for an `accept` that passes the same check.

Titles agree when their comparison keys are equal, or once a subtitle or a trailing edition
parenthetical is dropped from one side (never both). The key is the normalized title with letters
folded (diacritics, and `ø æ œ ß đ ł þ` to `o ae oe ss d l th`; the same folding applies to the
letters-only author comparison, `Check.compact`, on names of four or more letters, not to every author
comparison), punctuation gone, and one leading article dropped, never leaving the key empty ("The"
keys to "the"; non-Latin titles keep their letters). The articles are `the a an le la les l el los
las il lo gli os der das`. "i", "as", "die" and "o" are not dropped because they are English words
("I, Claudius"). A trailing parenthetical ("Dune (Special Edition)") is dropped as an edition note
unless it names a volume. The dropped text names a volume when it holds a whole volume word
(`vol`, `vols`, `volume`, `volumes`, `book`, `books`, `part`, `tome`, `teil`, `band`, `livre`, `tomo`,
`parte`, `libro`, `buch`, `tom`, `livro`, any case) or a "#"; is only digits or only a Roman numeral
("(II)", "Dune: 2", "Dune (2008)"); ends in a standalone number ("In Search of Lost Time 1"); or
holds a set word (`EditionCheck::SET_WORDS`). A digit anywhere else is not enough: "War and Peace:
150th Anniversary Edition", "(2nd Edition)" and "1984 Printing" are dropped, and agree with "War and
Peace". A volume parenthetical is never dropped, on our title or theirs, so "In Search of
Lost Time (Volume 1)" agrees only with the same volume. The same rule holds for a subtitle after the
first colon and for an Open Library subtitle field: one that names a volume is never dropped, so "Le
Comte de Monte-Cristo: Tome 2", "In Search of Lost Time: Volume 1", "Faust: Part One" and a work with
the subtitle field "Volume 1" or "Tome II" do not agree with the plain title, while "Dune: Messiah"
still agrees with "Dune". The cost is recall: "Dune: Book One of the Dune Chronicles" no longer
agrees with "Dune". Two more accepted costs: "Tom" (an English name) in a subtitle blocks it, and a
volume named only by its own title ("The Lord of the Rings: The Two Towers") still agrees with the
whole book. Stage 2's edition check and the Amazon check inherit this rule.
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
counts these. Any other non-accept goes to the second-chance routes below, and stays `unsure` if none
settles it. A confirmed-on-abstain book flags no pair either. This confirm-only path sits behind the
same guards as the routes: it never confirms when the decision is `reject`, when the reason starts
with "identifier conflict", when a volume guard tripped, or when the top candidate has conflicting
features.

### Second chance: four routes after `/resolve`

Open Library's matcher is cautious, so a non-accept (or an accept whose work fails our check) often
leaves a right answer on the table. Before a book is left `unsure`, `Lookup` tries four routes in
order, after the guards below. They run on every stage 1 pass, not only under the flag. Each ends in `Check.verified?` (title
and an author agree); nothing settles on score alone. The row's `lookup` records the route.

**Guards.** There is no second chance at all when the matcher's decision is `reject`, when its reason starts with
"identifier conflict", or when a volume guard tripped (`volume_guards_tripped` not empty). A
candidate with conflicting features is never taken, and a work that appears among the conflicted
candidates is skipped by routes 4 and 5.

**Second-chance duplicates are exact-title only.** A duplicate key (`books_work_openlibrary_duplicate_id`) is an
identity lookup: the list wizard and the Open Library importer find a book by it. So a route saves a
passing work as a duplicate only when its full title key, subtitle included, equals the key of the
book's own title. A work that passes only by dropping a subtitle, or only through an alternate title,
is not saved (alternate titles do not count, as in stage 2's duplicate harvest: legacy data gives some
volumes their series' name). The `replaced` path of an ordinary accept is the exception: it still keeps
every old key whose record passes the check (`ApplyBook#agreeing_old_keys`), exact title or not.

2. **`resolve_candidate`.** The resolution's candidates that are not reject-banded, in score order;
   the first that passes the check, preferring one whose full title key equals ours (or an alternate
   title's) over one that passes only by dropping a subtitle. The other passing candidates with our
   exact title are saved as duplicate works.
3. **`exact_title`.** The highest-scoring reject-band candidate whose full title key equals our title's
   (not an alternate title, not by dropping a subtitle) and that passes the check, so an author
   agrees. This is the English-titled work that Open Library ranks below the original-language one
   (*The Trial*, *Demons*, *We*).
4. **`held_key`.** A work key the book already holds whose live record passes the check, preferring an
   exact title key. The other passing held keys with our exact title are kept as duplicate keys.
5. **`worldcat_isbns`.** Up to five of the book's WorldCat-confirmed ISBNs (source `worldcat`) looked
   up in Open Library as ISBN-13s (ISBN-10s are converted first); the work most of them lead to, if it
   passes the check. Other passing works with our exact title become duplicate keys. A book stage 3 has not yet run on has no
   such ISBNs and skips this route.

**`held_key` runs first**, then `resolve_candidate`, `exact_title` and `worldcat_isbns`. A candidate
passing the same check is no reason to move a book off a key it holds. In the 2026-10-24 dev
rehearsal, with candidates first, *One Hundred Years of Solitude* traded its held work (Spanish title,
208 editions) for an English-titled stub with 2, and *A Hero of Our Time* its 26-edition work for one
with a single edition. So a candidate pick is never a key the book holds, and a held key that is also a
candidate settles as `held_key`. (A `replaced` book keeps its agreeing old keys without the exact-title
rule.)

(The route numbers follow the design's steps, where step 1 is the comparison key above, not the order
they run in.) A route settle is applied
like an accept, with two differences: it writes **no Open Library author keys** (a weaker answer must
not spread keys to authors), and it keeps the rest of the guards. A work another book holds still makes
the book a `duplicate_pair`, and the route's work is not saved. A `removed` row that is reprocessed and
still settles nothing stays `removed`, so its removed keys can still be restored by a revert.

| Outcome | Meaning |
|---|---|
| `confirmed` | the stored key was right |
| `updated` | the stored key redirects to the answer; moved to the current key |
| `replaced` | the stored key was another work, or dead; swapped (old key in the log). An old key whose own record agrees with the book on title and author is kept as a duplicate key |
| `keyed` | the book had no key; added |
| `duplicate_pair` | another book holds the answer; nothing saved, pair in Books → Duplicates |
| `unsure` | no confident, agreeing answer; nothing changed (a `second_chance` run may still settle it) |
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
  collection, omnibus, trilogy, volumes, books 1, complete series, a run of books ("books 2-4",
  "book 1 to 3") or a count of them ("7-book") (`EditionCheck::SET_WORDS`, whole words, case
  folded). One numbered book ("Book 1 of the Dark Tower") is not a set, but it is a volume: a subtitle
naming a volume is never dropped (see the title rule in stage 1), so such an edition does not agree
with the plain title either. Stage 3 uses this same rule on the WorldCat record's title, with its " : subtitle" as the
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

**Duplicate works.** Open Library often keeps one book as several works, and the settled work can
be a translation's (One Flew Over the Cuckoo's Nest settled on "Alguien voló sobre el nido del
cuco"). So stage 2 also harvests the book's `books_work_openlibrary_duplicate_id` keys whose source is
`open_library` (at most 5, `MAX_DUPLICATE_WORKS`, oldest first). A duplicate is harvested only when
its full title, subtitle included, is the book's own title (a leading "the", "a" or "an" aside;
alternate titles do not count) and an author agrees, and no other book holds it as its work key. The
title-and-author check alone is too loose here: it drops a subtitle from one side, so "The Lord of the
Rings: The Two Towers" would pass for "The Lord of the Rings", and the edition rule then trusts every
edition titled like the work. Keys that redirect to one live work (or to the settled one) are
harvested once, under the live key. A duplicate Open Library no longer has (404) is skipped. Their
editions go through the same edition rule, and the ones that do not agree become candidates under
the duplicate's work key.

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
  Two rules keep this signal quiet (they change only what is recorded, never what is trusted):
  an ISBN that Open Library lists on any one non-set edition candidate of this book (ISBN-13 or
  ISBN-10, compared as ISBN-13) is not recorded; a candidate whose title or subtitle names a set
  does not count; and a record's title does not count as disagreeing when its full title (the
  " / creator" part dropped) contains one of our titles on word boundaries and every other word is
  an edition word or a number (complete, collected, all, volume(s), vol(s), works, edition,
  unabridged, annotated, illustrated, selected, the, a, an, and, of, in). Our titles are tried
  with and without a leading "the", "a" or "an". "Complete Essays" holds "Essays" and "Brothers
  Karamazov" holds "The Brothers Karamazov"; "Make it stick" does not hold "It", and "Life : a user's manual" does not hold "Life of Pi".
- **Anything else** (no record, or records agreeing on only one of title and creator): nothing.
  Garbled records fail the check and never confirm. A garbled record (mojibake in its title or
  creator) is never `wrong_identifier` either: it may be the right book, so it counts as unknown.
- **A WorldCat 504** (the service's 25 s deadline) on one ISBN counts as no answer for that ISBN; the
  book completes stage 3.

### Stage 4: signals

Recorded, never acted on. The book's held ISBNs and Goodreads ids still not verified (at most 20,
`MAX_SIGNAL_LOOKUPS`, five at a time) are looked up in Open Library. A hit on a work that is not the
stage 1 work, not one of its duplicate keys and not a redirect of it is fetched, and if its title
disagrees with ours the identifier gets a `foreign_work` finding. A work whose title agrees is an
unmerged Open Library duplicate of the same book and is ignored. Two more rules keep the signal
quiet: a work whose title equals the title (or "title: subtitle") of one of the book's own edition
candidates is a known translation and is ignored, and a leading "the ", "a " or "an " is dropped
from both sides of the title comparison, so "Bible" agrees with "The Bible". When stage 1 settled no work,
every hit is judged by the title rule alone. The fast pass's answers are not reused, because a
resumed book runs stage 4 in a later run.

There is one `foreign_work` finding per identifier. Its `work_key` is the lowest foreign work key,
and `evidence["works"]` lists every foreign work it hits as `{key, title}`. A re-run deletes the
row's `foreign_work` findings and computes them again, so stale ones do not stay. A book whose
findings name **two or more distinct foreign works** is a **lump suspect** (`lump_suspect` on its
row): the shape of "X Men" holding several volumes' identifiers, or an omnibus holding its novellas'
ISBNs. Telling a lump from an omnibus is later work. Lump suspects are a candidate list for a later
AI check, not a verdict: Open Library keeps some translations as separate works, which the known-translation
rule above only partly catches.

## The `second_chance` flag

`second_chance` takes `done` rows whose outcome is `unsure` or `removed`, from any earlier run (a row
the same run id already finished is skipped, so a re-queued run does not redo it), and starts them
over at stage 1 so the routes above can look at them. It wins over `retry_unsure` and `recheck` when
combined with them, since its reset covers what they would do. Before the reset the row records
`second_chance_at`, `prior_outcome` and `prior_keys` (the work keys the book held). The record is made
once: a row taken a second time keeps its earliest values until a revert clears them. Rows still
`unsure` afterwards are logged as such and are retaken by any later `second_chance` run, which repeats
the lookups, so run it once and leave it off routine runs. The scope is the usual one: ranked
`pre_import` unless `unranked` or `post_import` is added. In production the existing unsure and
removed rows should all be ranked `pre_import`, so `books:verify[all,second_chance]` with no other
flags covers them; verify that with a count before relying on it (see `docs/launch-todo.md`).

A book a route settles carries on through stages 2-4 like any settled book: more Open Library calls
and writes, and a longer run than the stage 1 lookups alone. Because the title-key fix also lets Open
Library's own matcher (`identifiers` or `resolve`) pass some of these books, a `second_chance` run can
settle a book through the matcher too, and those settles write author keys like any matcher answer.
They are reverted as the pseudo-route `second_chance_matcher` (see Reverting).

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
- "Settled via route": how many books each second-chance route settled (`resolve_candidate`,
  `exact_title`, `held_key`, `worldcat_isbns`; settled outcomes only, so reverted or unsure rows
  are not counted), and a `second_chance_matcher` line: books a `second_chance` run settled through
  the matcher (`identifiers` or `resolve`);
- recent risky changes: the latest `replaced`, `removed` and `duplicate_pair` books;
- random samples: 10 books per work outcome (with Open Library's title when it can be reached), 10
  per route and outcome ("via held_key (replaced):", with Open Library's title beside ours), 10
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

A book whose row a `second_chance` run settled (it has `second_chance_at` and a settled outcome) is
dispatched to the second-chance revert instead (below): it goes back to `unsure` or `removed`, not to
`reverted`, and the task says "reverted the second chance on book ...".

Findings that agreed only through an alternate title the AI review later removed are undone by a
separate step, `books:alternate_titles:undo_findings`, not by this task
(`docs/features/books-alternate-titles.md`).

A work key that arrived afterwards (a merge, an admin) stays. Another book processed later may have
relied on an author key the pass added, so check those books. Pairs the run flagged stay in the
Duplicates queue.

### Reverting a route

`bin/rails "books:verify_revert_route[<route>]"` (`resolve_candidate`, `exact_title`, `held_key`,
`worldcat_isbns`, or the pseudo-route `second_chance_matcher`) reverts every book that route settled,
for the production spot-check: if a route's samples are wrong, undo that route and leave the others.
It prints the reverted and failed counts. An unknown route name aborts with a usage line.
`second_chance_matcher` is not a lookup value: it selects rows with `second_chance_at`, lookup
`identifiers` or `resolve`, and a settled outcome.

- A book a `second_chance` run settled (outcome `keyed`, `updated`, `replaced`, `confirmed` or
  `duplicate_pair`) goes back to what it was: `prior_outcome` (`unsure` or `removed`) and
  `prior_keys`. The key the route added is deleted, a prior key it confirmed returns to `legacy`
  (a removed key stays removed), duplicate keys it saved go, and only the findings written and edition
  candidates created at or after `second_chance_at` are undone. Findings go by `updated_at`: a
  finding is one row per verification, kind, type and value, so one the alternate-titles cleanup
  undid and the second chance found again keeps its first-pass `created_at` (*Death in Venice* in
  the 2026-10-24 rehearsal). Reverting it deletes the row, with the cleanup's undo record on it. The row clears its second-chance
  record, so a later `second_chance` run can take it fresh. Author keys it added (only a matcher
  settle adds them) are deleted, as the full revert does.
- It does not bring back the first pass's `foreign_work` findings or its lump flag. Those are
  recorded signals, not keys, and stage 4 recomputes them on the next pass over the book, so they
  are not stored for the revert.
- A book settled by a route on a first pass has no `second_chance_at`, so it goes through the full
  `books:verify_revert` and ends `reverted`, never redone.
- A reverted second-chance row keeps its `run_id`, so a re-queue of the same run will not retake it;
  only a new run does.

## How long it takes

Estimated, not yet measured: stage 1 about 4-12 s per book, editions 4-5 s, WorldCat about 7 s (two
or three unconfirmed ISBNs at 2.7 s each), signals about 2 s, so 20-28 s a book. That puts the ranked
`pre_import` books at 3-4 days, the whole ranking with `post_import` at about a week, and the
unranked catalogue at 6-7 weeks. The before-merge run of `books:verify[200]` replaces these with
measured per-stage timings. Stage 1 alone measured about 4 books a minute on 200 top-ranked books.
