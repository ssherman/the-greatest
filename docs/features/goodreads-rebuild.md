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

## Survey pass 2: WorldCat and Open Library evidence

For every derived book's Goodreads editions (152,640 on dev, 129,935 of them with an ISBN), pass 2
asks two services about the ISBN, and records the answers in `Books::RebuildEditionEvidence`
(`books_rebuild_edition_evidences`):

- **WorldCat** (`GET /isbns/{isbn}`): does a library record agree with the export on title and
  creator? The column is `world_cat`: `agrees`, `disagrees` (neither agrees), `unclear`, `no_record`
  or `no_isbn`.
- **Open Library** (`GET /identifiers/isbn13/{isbn}`): which work keys the ISBN belongs to.

The table is keyed by the edition's natural key, Goodreads id plus signature, and has no foreign key,
because it's gathered on Shane's PC and copied to production. The survey then groups with it: two
editions on one Open Library work join, whatever their author strings say.

**It runs locally, never against the home-server services.** Their answers don't depend on our
catalog, and the production runs need the home server. `EvidenceRun` refuses unless both service
URLs are `localhost` or `127.0.0.1`. On this PC, WorldCat's single-ISBN route is the bottleneck (about
1.4 s each at 16 DuckDB threads; Open Library answers in about 25 ms), so 8 Rails threads give about
1.6 editions a second, and the full run takes about 22 hours. At 16 threads WorldCat exceeds its own
25 s deadline and answers 504.

A failed lookup is retried after 65, 120 and 240 seconds before the run stops (each pause outlasts the clients' 60-second circuit breaker). Any other error stops the whole run cleanly. Evidence already written
stays, and a re-run picks up the rest.

### The local recipe (Shane's PC)

1. **Data, once.** The local services must serve the home server's versions.
   - Open Library: `scp -r debian@<ol-vm>:/srv/ol-data/versions/2026-09-30 /home/shane/ol-data/versions/`
     (about 14 GB). The VM has no `rsync`.
   - WorldCat `2025-09-04` is already in `/home/shane/wc-data/versions/`.
2. **Start both services** from `data-sources/`.
   - Use **one process each**: uvicorn `--workers` processes share DuckDB's spill directory and corrupt
     each other's temp files (500s with "Could not read enough bytes").
   - Requests already run on the process's thread pool.

   ```
   OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-09-30 OL_API_TEMP_DIR=/tmp/duck_ol OL_API_MEMORY_LIMIT=12GB \
     OL_API_THREADS=16 uv run --locked uvicorn --factory openlibrary.api.main:factory --port 8101
   WC_DATA_ROOT=/home/shane/wc-data WC_DATA_VERSION=2025-09-04 WC_API_TEMP_DIR=/tmp/duck_wc WC_API_MEMORY_LIMIT=12GB \
     WC_API_THREADS=16 uv run --locked uvicorn --factory worldcat.api.main:factory --port 8102
   ```

   `WC_API_THREADS` defaults to 2, sized for the home server's small WorldCat VM. 16 roughly
   doubles throughput here.
3. **Gather**, from `web-app/`:
   `OPEN_LIBRARY_SERVICE_URL=http://localhost:8101 WORLDCAT_SERVICE_URL=http://localhost:8102 bin/rails "books:goodreads_rebuild:gather_evidence[8]"`
4. **Export:** `bin/rails books:goodreads_rebuild:export_evidence` writes
   `tmp/rebuild_edition_evidence.jsonl.gz`. Copy it into the production container.
5. **In production:** `bin/rails "books:goodreads_rebuild:import_evidence[<path>]"`, then
   `bin/rails "books:goodreads_rebuild:survey[all,redo]"`, then `survey_report`.
   - The import upserts, so it can be repeated.
   - It counts rows for editions production doesn't hold (`no_edition_here`), and keeps them.
   - The report gains a line of evidence counts.

## Later increments

- **Stage one fixes (2b):** the existence check, then reset and re-import in place (spec §4.1).
- **Verification scope:** for repaired books.
- **Stage two:** moves, `create_book`, `add_item`, dedupe, and the member-import guards.
- **The sweep and the weekly catch-up.**
