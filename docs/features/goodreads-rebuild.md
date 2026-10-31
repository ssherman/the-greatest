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

## Fixes (increment 2b)

Fixes the import-made books whose title or authors disagree with the Goodreads export. On dev
(2026-10-29) that was about 47,400 books, of which about 1,000 are lumps and are now skipped (below), so
about 46,400 are decided. They are taken
from the survey rows, most-listed first, so a stop part way leaves the least important ones undone. A
trusted book (on a real list before the rebuild) is never touched.

**Lump records are skipped (2026-10-30).** A lump is one record that holds Goodreads rows of several
different books: record 18026 "Carol" has 57 rows of *The Psychology of Money* and 19 of *The Price of
Salt* (Highsmith's *Carol*). Deciding it from its biggest group would move all 76 readers onto
*Psychology of Money* (a merge) or rename the record out from under the 19 (a fix). Each reader has to
end on the book their own row names, which needs a per-reader split step that does not exist yet. Until
it does, `DecideFix` and `DecideFixes` leave lumps alone (no verdict, no finder or AI call), and
`books:goodreads_rebuild:retire_lump_verdicts` retires any unapplied lump verdicts the earlier runs
recorded (rejected and superseded; a dry run unless `[apply]`; verdicts already applied are never
touched, only counted; a verdict an admin already rejected is left as it is).

Each book gets one of two verdicts, stored as a repair verdict (`subject_key` `rebuild:<book id>`) that
you review in Admin, Repair verdicts:

- **Merge** (`merge_books`): the right book already exists in the catalog, so this one is merged into
  it. The merge also clears the leftover wrong data from the book being merged away.
- **Fix** (`fix_identity`): no right book exists, so this book is reset and imported again in place
  with the export's title, authors and identifiers. It keeps its id, slug, and everything members hung
  on it (list items, reviews, Goodreads editions).

  How much a fix changes depends on `FixScope`, worked out at apply time from the book's survey and the
  verdict (the scope used is recorded as `fix_scope` in the verdict payload):
  - **none**: the export's title equals our title, or our "title: subtitle" (only Goodreads series or
    edition noise differs). Nothing changes. `retire_unneeded_fixes` retires these
    verdicts before apply.
  - **title only**: the authors agree and one title is a whole-word prefix of the other (ours lacks the
    export's subtitle, or carries junk the export lacks, like "Silo 1" for "Silo"). Only the title and
    subtitle are rewritten; the book keeps everything else and is not queued for enrichment.
  - **full**: the author differs, the title really differs, or there is no survey. The reset described
    above, then enrichment.

Deciding (`DecideFix`) changes no book. It writes one match decision per book and can add pairs to the
admin Duplicates queue. To find an existing book it runs the
normal book finder **blinded**: no Open Library, no legacy evidence, and a book that is itself waiting
for a fix is never a target. The search is built from the export's facts for the book's main work
(`ExportFacts`: title, authors, year, identifiers and Open Library hints from the biggest edition group).

**An adaptation or a guide is never the book it is based on.** The book finder drops (before the rules or the AI see it, in every mode, member imports included) a local candidate when exactly one side's title and subtitle carries a derivative marker the other lacks: graphic novel, manga, pop-up, stage adaptation, the play, screenplay, retelling, adapted, study or literature guide, summary, analysis, commentary, companion, workbook, and the German, Spanish and French forms (`DataImporters::Books::Book::DerivativeWork`). Annotated, illustrated, translation and edition are not markers. The first rebuild run proposed 28 such wrong merges ("Watership Down: The Graphic Novel" into *Watership Down*). The volume check in `DecideFix` knows volume words in several languages (Книга 1, Band, Tome, Tomo, Libro, Deel...), so "1Q84. Книга 1" is not merged into *1Q84*.

**Titles are cleaned.** On Goodreads a parenthetical at the end of a title is series or edition noise ("(Little Golden Book)", "(Spanish Edition)", "(Saddlewire) (Books of American Wisdom)"). `ExportFacts.clean_title` strips every trailing one (never a mid-title one, never to blank) from the facts, and `Apply::FixIdentity` and the `reset_source` path of `Apply::MergeBooks` run it again on the payload before writing, so verdicts recorded before the cleaning still land clean.

The rebuild merges only into a book on a real list or one with exactly the export's title; a translated duplicate is left for stage two, and stage two's dedupe must keep the English page when an English edition exists (Shane, 2026-10-29).

**When each is automatic.** The bar is zero wrong merges.

- A merge is applied by itself only when the target carries a verified Open Library work that the
  export's evidence names, the target's title equals one of the export titles exactly, and the work has
  no volume number. A pair an admin already marked "not a duplicate" is never merged automatically. Every other merge is proposed and waits for an admin. (A proposed target is still
  only a trusted book or a book whose own survey agrees with its export.)
- A fix is applied by itself only when WorldCat confirmed the export. Otherwise it is proposed.
- A merge an admin rejected is never proposed again; the book is given a fix instead (applied by itself
  or proposed, by the fix rule above).

**Same person, different spelling.** For every book that reaches the fix or merge decision, `MatchAuthors` first checks each export author name against the book's current authors by the finder's name key (initials folded), and asks the AI (`MatchExportAuthorsTask`, which sees each author's other books, never the surname alone) about the rest; only a "high" answer counts. When the title agrees and every export name is one of the book's own authors ("Kurt Vonnegut" for "Kurt Vonnegut Jr."), nothing is reset: the export spelling is added to the author's alternate names and the book is counted as `same_author`.

When the book is fixed anyway, the matched authors travel in the verdict as `author_links`, and the apply links those existing authors instead of importing duplicates ("Daniel C. Dennett" beside "Daniel Dennett"); only the unmatched names are imported. A failed AI call decides nothing (`retry`), like a failed finder run.

**A failed finder run decides nothing.** If the finder fell back or lost one of its sources, "found
nothing" would be a guess, so the book stays undecided (counted as `retry` in the run log) and the next
`decide_fixes` run tries it again. A book that already has a live verdict is left as it is (`kept`).

**What a reset clears and keeps** (`ResetBook`). It clears the description, subtitle, sort title,
original year, language, length figures, alternate titles and the Amazon-enriched mark, and deletes the
book's authors, credits, descriptions, categories, images, editions, identifiers, alternate-title rows,
series links, countries and external links. It keeps the book row, its id and slug, and everything
members hung on it (list items, reviews, Goodreads editions).

**It saves a copy of what it removed.** Before deleting, the reset stores the old title and authors,
every identifier, every edition with its identifiers, and every link (Amazon ASINs and product links
included) on the verdict as `payload["removed"]`. The first copy is kept for good: a retry of a failed
apply finds nothing left to copy, and it never overwrites the saved one.

**Applying.** `books:goodreads_replay:apply` re-runs every pass, but a fix is applied only once
(`applied_at` is set). A book put on a real list since the verdict was recorded is left alone. The
reset and the new title commit together; the author and identifier import runs after, so a failed
author import leaves the right title with no authors and the next pass finishes it.

**Enrichment.** Once a fix is applied, the book needs its Goodreads page, authors and the rest. The job
`Books::GoodreadsRebuild::QueueEnrichmentJob` runs every 10 minutes (`config/schedule.yml`,
`goodreads_rebuild_enrichment`) and starts the normal new-book enrichment for fixed books, most-listed
first. At most `GOODREADS_REBUILD_IN_FLIGHT` (default 300) books wait for their Goodreads fetch at
once, so other books keep their share of fetches. While Goodreads has blocked us, no new book starts. A
book with any enrichment run since its fix was applied is done.

The speed is set by the Goodreads fetch cap, not by this job: `GOODREADS_DAILY_FETCH_CAP` (default
1,500 a day) and `GOODREADS_FETCH_INTERVAL` (default 15 seconds). To go faster, raise the cap in the
production env (SOPS) and restart the worker, after a day or two with no failures and no blocks (read
`fixes_report`'s enrichment section). Above 5,760 a day, 15 seconds apart cannot fit the cap, so lower
`GOODREADS_FETCH_INTERVAL` too.

Commands:

- `bin/rails "books:goodreads_rebuild:decide_fixes[<count>|all]"` queues the decide run
  (`DecideFixesJob`, `low` queue, 100 books a batch) over the most-listed books that need a fix. It
  calls the AI for books it cannot settle by rule. Run it again to pick up `retry` books.
- `bin/rails books:goodreads_rebuild:fixes_report`: read-only. Counts of merges and fixes by status and
  confidence, how many applied or failed, 10 samples of each with our title beside the export's, and an
  enrichment section (runs, Goodreads pages found, missed and failed, fetches used against the cap, and
  whether the gate is blocked).
- `bin/rails books:goodreads_rebuild:queue_enrichment`: one top-up now; the cron job does this alone.

## Later increments

- **Verification scope:** for repaired books.
- **Stage two:** moves, `create_book`, `add_item`, dedupe, and the member-import guards.
- **The sweep and the weekly catch-up.**
