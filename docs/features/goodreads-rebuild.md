# Goodreads rebuild

Repairs the books the legacy site's Goodreads imports made, using the export rows as the truth. Legacy's
importer searched with a stripped title, stamped each row's Goodreads id and ISBNs onto whatever book it
picked, and created about 138k books along the way. The replay (`docs/features/goodreads-import.md`,
"Legacy replay") graded that work with legacy's own evidence and is paused. Design:
`docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md`.

The rebuild runs in this order, and repeats after each weekly `data_migration:sync` until cutover:

1. Stage one: fix import-made books' titles and authors from the rows, and split lumps.
2. A verification run over the fixed books, so they hold trusted identifiers.
3. Stage two: put every edition on the right book, write users' skipped rows, create missing books,
   merge duplicates.
4. The sweep: merge or delete the import-made books nothing needs any more.

Built so far: the foundation (cohorts, retiring the replay's proposals) and the stage one survey, pass 1. Production steps are in `docs/launch-todo.md` §11.

## Cohorts: which books are trusted

`Services::Books::GoodreadsRebuild::Cohort` decides, live from `list_items`. Nothing is stored and
nothing is read from the legacy database:

- **Trusted by id:** pre-import books (legacy id below 16,572, created before the imports feature
  launched on 2024-09-09) and books created in the new app. The id ranges are
  `Services::Books::Verification::Cohort`'s.
- **Trusted by list:** a post-import book on any list except the generated user-favorites list ("Our
  Users' Favorite Books of All Time"). Shane put it there by hand and wouldn't have listed an invalid
  book. A book added to a real list later becomes trusted with nothing to re-run.
- **Derived:** every other post-import book. The rebuild rebuilds these from their rows. Legacy's three
  favorites lists were never migrated, so the books only they held are derived too.

Measured in dev on 2026-10-27, out of 147,625 post-import books:

| Cohort | Books |
|---|---|
| Trusted by list | 9,379 |
| Derived | 138,246 |
| ...of which only on the favorites list | 2 |

9,245 of the 9,247 ranked post-import books are trusted, so the verification pass can cover them now.

The rebuild never changes a trusted book's title or authors (spec §12 call 2).

`bin/rails books:goodreads_rebuild:cohorts` prints the counts. It is read-only.

## Retiring the replay's proposals

The replay left 2,691 relinks and 2,091 identifier strips proposed, decided on legacy's stripped titles.
`Services::Books::GoodreadsRebuild::RetireReplayProposals` marks every proposed `relink` and
`strip_identifier` verdict that was never applied rejected, and stamps `superseded_at`. Approved verdicts,
applied ones (even one `RecordVerdict` returned to proposed, which keeps `applied_at`) and other kinds are
untouched.

- The admin repair-verdict pages hide superseded rows (`RepairVerdict.current`). Bulk "approve all
  matching" can't reach them.
- `RecordVerdict` treats a superseded row as suppressed, like any rejected one, unless the caller passes
  `replace_superseded: true`. Only the rebuild passes it, and the row then starts fresh: new evidence,
  status from `auto`, no reviewer, not applied. A replay re-run can't bring a retired proposal back,
  and the rebuild can still record its own decision under the same `kind` and `subject_key`, which the
  unique index requires.

Commands:

- `bin/rails books:goodreads_rebuild:retire_replay_proposals`: a dry run printing counts per kind.
- `bin/rails "books:goodreads_rebuild:retire_replay_proposals[apply]"`: retires them. A second run prints
  0s.

## Stage one survey, pass 1

A read-only look at every derived book, before anything changes one. It uses only our own database:
the export rows and the catalog, with no Open Library, WorldCat or AI calls. So it can run alongside
a verification run.

For each book it records a `Books::RebuildBookSurvey` row (`books_rebuild_book_surveys`).

1. **Gather editions.** These are the Goodreads editions the book's export rows name.
   - A row names a book through `legacy_book_id`, which is legacy's choice.
   - Rows on a legacy book that was later merged away count for the book it was merged into
     (`LegacyBookMap`, through the replay's `MergedBook`).
2. **Group them into works** (`GroupEditions`). Editions are one work when they share:
   - an author, compared on letters only, so "J.D." and "J. D." agree;
   - an original publication year;
   - a series volume.

   Translations agree on author and year whatever their titles. An edition with no author, year or
   volume (most books have no volume) joins the biggest group it doesn't contradict, so "Hunter x
   Hunter, Vol. 13" and its unnumbered printing are one work. One group makes the book `coherent`,
   two or more a `lump`, and no editions `unsupported`. The lump count is an upper bound: an author
   written two ways ("Mark R. Leary" and "Mark Leary") or a translation dated by its own year still
   splits. Pass 2 and increment 2b's checks settle those.
3. **Compare our identity** with the main group, the one with the most rows (`CompareIdentity`):
   - `title_agrees`: our full title, with subtitle, equals one of the group's export titles,
     normalized. It is exact on purpose. Legacy stored "X Men" for "X-Men: The Age of Apocalypse,
     Vol. 2", and the verification pass's looser title check would let that agree.
   - `authors_agree`: one of our authors is one of the export authors. A book with no authors
     disagrees.
   - `wrong_book`: no group agrees with us, even loosely, on title or on authors. The record is a
     different book from everything imported onto it.

Pass 1 can't tell a translation from another book when Goodreads spells the author differently
("Lev" against "Leo" Tolstoy), so its lump count includes some of those. **Pass 2**, after the
production verification run frees the shared services, looks up each edition's ISBN:
- in Open Library, to join editions on one work;
- in WorldCat, to confirm the export.

Increment 2b then fixes titles, authors and lumps from these rows.

Commands:

- `bin/rails "books:goodreads_rebuild:survey[all]"` queues the run (`Books::GoodreadsRebuild::SurveyJob`,
  `low` queue). It takes only books with no survey yet, so if it stops, run it again. `survey[200]`
  takes the first 200. `survey[all,redo]` re-surveys every derived book in place, for use after
  catalog changes. One run at a time.
- `bin/rails books:goodreads_rebuild:survey_report` prints counts by classification, how many books
  disagree on title or authors or are the wrong book, and 10 samples of each with our title and
  authors beside the export's.

## Later increments

- **Survey pass 2:** WorldCat and Open Library per ISBN.
- **Stage one fixes (2b):** identity repair and lump splits.
- **Verification scope:** for repaired books.
- **Stage two:** moves, `create_book`, `add_item`, dedupe, and the member-import guards.
- **The sweep and the weekly catch-up.**
