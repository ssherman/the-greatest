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

Only the foundation (below) is built so far. Production steps are in `docs/launch-todo.md` §11.

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
`strip_identifier` verdict rejected, and stamps `superseded_at`. Approved and applied verdicts, and other
kinds, are untouched.

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

## Later increments

- **Stage one:** identity repair, lump splits, and the WorldCat timing.
- **Verification scope:** for repaired books.
- **Stage two:** moves, `create_book`, `add_item`, dedupe, and the member-import guards.
- **The sweep and the weekly catch-up.**
