# Goodreads rebuild: repair the catalog from the export rows

Brainstormed with Shane on 2026-10-14/15 (sections 1–2) and 2026-10-27 (sections 3–8). Numbers are
from the development database, a copy of production, unless a line says otherwise. Re-measure them
before acting on them.

## 1. Why

The legacy site's Goodreads import created about 135k of our ~160k books and attached rows to them
with a buggy algorithm. Its parser searched with a stripped title: everything in parentheses and
everything after the first colon was dropped (`goodreads_library_parser.rb:96-98` in the legacy app).
After that, it **always** stamped the row's Goodreads id and ISBNs onto whatever book it chose, so a
wrong choice became permanent and every later import of that id followed it. Legacy's Amazon matching
then added wrong ISBNs on top.

The replay (`docs/features/goodreads-import.md`, spec §12) tried to repair this pair by pair. It
graded legacy with legacy's own evidence: stored titles legacy had stripped, and identifiers legacy
had stamped. Agreement came out at 96% in every era, and 10 of its 58 rule-made book merges were
wrong (comic volumes merged on a shared Open Library work id or ASIN, verdicts 9744, 9758, 9760 and
9778–9781). Shane's conclusion (2026-10-14): "We can NOT trust any data from the Goodreads imports."

The admin Duplicates queue shows the same problem. Of 4,149 pending book pairs, the 196 raised from
a shared identifier are mostly wrong. They include *Winnie the Pooh* / Alan Watts' *The Book*,
*The Elements of Style* / *JR*, and *Sustainable Energy* / *The Wager*. *The City and the Stars*
holds Goodreads id 23129659, which is *Adult Children of Emotionally Immature Parents*. Only 1 of
the 4,149 pairs shares an identifier a trusted source checked.

**Launch waits on this.** Shane is ready to launch the new books site and wants this cleanup done
first. Elapsed time matters more than build elegance: long-running steps start as early as possible
and run in parallel.

### Goals (Shane's words, 2026-10-14)

- Every Goodreads import is 100% accurate.
- Remove all the bad data the legacy Goodreads import feature left behind.
- Prevent the import from adding bad data in the future.
- Omnibus titles never "split" into their individual books.

"Accurate" means three things:

1. Every user's list item and review points at the work they had on Goodreads.
2. Every book an import touched has the right title and authors.
3. Every identifier on a book belongs to it.

### Non-goals

- Books no import touched. The verification pass (`docs/features/book-verification.md`) owns those.
- A Goodreads enrichment backfill over existing books. That is a later spec, and it must wait for
  this one (see §9).
- Porting the legacy add-book modal, or the admin add-book-from-Goodreads-URL path.
- Changes to the legacy app. Imports stay on there until cutover (Shane, 2026-10-27).

### Anti-goals: this is a failure even if it runs

- **A wrong merge.** A merge is a redirect, and rejecting one later undoes nothing. Zero is the bar.
- **Splitting an omnibus**, or merging a collection with one of its parts (*Aelita* is a different
  book from *Aelita + Hyperboloid*).
- **Judging anything on legacy's evidence**, which is how the replay reached 96% agreement while
  wrong.
- **Applying an AI decision without a human**, unless a non-AI source backs it.

## 2. Constraints

- **The weekly legacy sync.** Production ran `data_migration:sync_init` on 2026-10-10. Every week,
  `data_migration:sync` adds new legacy books, authors and identifiers, and puts legacy users' list
  items and reviews back where legacy has them. Shane chose to rebuild **before** cutover (2026-10-14,
  confirmed 2026-10-27). So every change must take one of three shapes that survive a sync:
  - a merge, which is a redirect and sticks;
  - an in-place catalog edit (title, authors, identifiers), which the sync never overwrites after
    `sync_init`;
  - a ledger verdict that `apply` re-applies after each sync, for moves and splits.

  Everything must be idempotent, and the rehearsal must exercise that.
- **Legacy imports keep arriving**, about 30 a month (7 a week) over the last year, the latest on
  2026-10-24. Shane chose to leave them on.
- **Shared services.**
  - Open Library `/resolve` has one slot, at about 30 s a book.
  - The Goodreads page fetcher is capped at 1,500 pages a day (`FetchGate`, 15 s spacing), shared
    with member imports and the #419 enrichment step.
  - The home-server WorldCat service is a frozen 2025-09 dump.
  - Dev and production share the Open Library and WorldCat services, so dev load slows production
    runs.
- **Production runs are Shane's.** Every production step is a rake task with a dry run where that
  makes sense, and goes into `docs/launch-todo.md`.
- **Identifier provenance exists** (`identifiers.source`, PR #395). Every pre-existing books row is
  `legacy`. `Identifier::VERIFIED_SOURCES` marks the trusted ones. The verification pass has filled
  in trusted identifiers for about 9,500 ranked pre-import books, and a post-import batch is running
  in production now.

## 3. Trust model

- **The unit of truth is the Goodreads edition** as the export row describes it: Book Id, exact
  Title, Author, Additional Authors, ISBN, ISBN13, Original Publication Year. These live on
  `books_goodreads_editions` (210,121 rows) and `books_goodreads_import_rows` (498,570 rows from 803
  legacy imports). The catalog unit is the work.
- **Evidence tiers:**
  - **Primary:** the export row.
  - **Corroborating, independent of legacy:**
    - WorldCat by ISBN;
    - Open Library, by ISBN, or `/resolve`;
    - a Goodreads page;
    - identifiers whose `source` is in `VERIFIED_SOURCES`.
  - **Never evidence:**
    - an identifier whose source is `legacy`;
    - a legacy-stored title;
    - a legacy-assigned author.
- **The two-source rule decides auto-apply.** A change lands without a human only when a rule made
  it and the export row and at least one corroborating source agree on it. An AI decision on its own
  is always proposed, bulk-approvable. This replaces the replay's shared-identifier merge rule.
- **Provenance splits the catalog in two.**
  - *Trusted core:* legacy books created before 2024-09-09 03:22:31 UTC (12,493), plus books the new
    pipeline created or verified. Their identity is kept, and only the rows attached to them are
    checked.
  - *Derived:* legacy books created inside an import window (about 148k). Their identity is rebuilt
    from their rows.

  Legacy `books.created_at` lives in the legacy database. The new app's timestamps are migration
  times, so the cohort is recorded per book once, and again for each week's new books.

## 4. Stage one: identity repair, book by book

Stage one runs over the derived books, one book at a time, in a Sidekiq job on the `low` queue
with a report at the end. It gathers the editions whose rows name the book, then checks each edition
by ISBN against WorldCat and Open Library. It reads a cached Goodreads page when one exists. **It
fetches nothing.**

- **Each book gets one of three classes:**
  - *Coherent:* every edition agrees on author key and original year. Translations count as
    agreeing.
  - *Lump:* the editions split into two or more groups, by author key, original year, Open Library
    work, or the page's work reference (`best_book_id`).
  - *Unsupported:* no row names it any more.
- **A coherent book gets its identity fixed in place** (a `fix_identity` verdict):
  - **Title and subtitle** come from the export title of the edition in the book's language, split
    at the first colon. Casing comes from the export, not legacy's titleize.
  - **A series suffix** such as "(Saga, #3)" moves into `Books::Series`, which is empty today. Reuse
    #419's series code, which finds or creates a series by Goodreads series id, never by title, when
    a page gives the id. Otherwise record the series name on the verdict for a later pass.
  - **Authors** are re-derived through the author finder from the export's Author and Additional
    Authors. When a page exists, its roles drop translators and illustrators.
  - **Identifiers** no row supports and no trusted source gave are stripped. The rows' Goodreads ids
    and ISBNs stay.
  - **Auto** when WorldCat or Open Library agrees with the export on title and creator. Otherwise it
    is proposed.
- **A lump gets a `split` verdict.**
  - **Which group stays:** the book keeps the group with the most rows. If a trusted source names
    the book (a curated list, a verified identifier), it keeps the group that source backs instead.
  - **The other groups:** each is a sub-decision. Stage two finds a book for the group through the
    blinded finder, or creates one. That group's rows, list items, reviews and identifiers move.
  - **Auto** only when two sources separate the groups, for example different original years in
    both the export and WorldCat.
  - **Same-author, same-year groups** (comic volumes, numbered series) go to the AI and are
    proposed.
  - The ten wrong merges are lumps now, and they must come out split.
- **An unsupported book is flagged provisional**, as the replay's `mark_provisional` does, unless a
  curated list holds it.
- **A trusted-core book gets only a row check.** A row whose export title and author both contradict
  the book becomes a move candidate for stage two. Its identity never changes.

Measured: 2,576 books are lump suspects on year or author alone. Same-year lumps found through the
work reference add to that.

## 4a. Between the stages: verify the repaired books

Shane, 2026-10-27: the replay comes last, and trusted, non-legacy identifiers come first. The
trusted core is close to done already:

- about 12,100 of the 12,493 pre-import books were verified in the ranked runs;
- the 7,792 list-created post-import books are in the current production run.

Derived books can't be verified before stage one. The verification pass finds a book's Open Library
work by title and author, and legacy's stripped titles and guessed authors would hand "trusted"
identifiers to the wrong books. That is why `docs/features/book-verification.md` holds the
`post_import` cohort back.

So the order is:

1. stage one;
2. the existing verification pass (`books:verify`) over the derived books stage one fixed;
3. stage two.

After step 2, most of stage two's matches become verified-identifier hits, needing less AI and fewer
`/resolve` calls.

- **Scope.** Derived books whose `fix_identity` has been applied, plus the volume books `split`
  created. Lumps still awaiting a split decision wait. The verification pass needs a cohort, or
  scope, for "derived and repaired". The builder adds it alongside the existing `post_import` and
  `unranked` flags.
- **Speed is the risk.** A book that needs `/resolve` costs about 30 s, and 148k books at that rate
  would take weeks. Measure the share that settles in the fast identifier pass on a dev sample of a
  few hundred repaired books. If `/resolve` would take more than a few days, run the fast pass only
  (identifier pass, editions, WorldCat confirm). Books that would need `/resolve` stay unverified,
  and stage two falls back to title matching for them.
- **Ranked first.** Ranked derived books go before unranked ones, as the verification pass already
  orders its work.

## 5. Stage two: put every edition on the right book

Stage two runs after stage one and the verification run in §4a, over every distinct Goodreads edition
in the rows (210,121). That includes the 51,837 rows where legacy chose no book. It is the last
step, and the only one that writes to users' lists.

1. **The blinded finder searches our catalog.** In order:
   1. identifiers from a verified source (a legacy identifier counts for nothing);
   2. exact title and author, against the repaired titles;
   3. OpenSearch;
   4. Open Library `/resolve` to break a tie;
   5. AI last, given the full export title and the facts every other source returned.

   The finder already exists for member imports. This adds a mode that ignores legacy-source
   identifiers both as hits and as corroboration.
2. **Compare with the book the rows point at now:**
   - Same book: nothing to do.
   - Different book: a `relink` verdict.
   - Nothing found: a `create_book` verdict. The book is created through the member-import pipeline
     with a Goodreads page check. It is provisional until approved, and #419's enrichment runs on
     approval.
3. **Dedupe comes last.** The inputs are:
   - the pending `DuplicateCandidate` book pairs (4,149);
   - any two derived books whose editions land on the same Open Library work or the same page work
     reference.

   Every pair is judged fresh on titles, authors, years and outside sources. **A shared legacy
   identifier counts for nothing either way.** Example outcomes: *Nine Stories* / *For Esmé with Love
   and Squalor* is a real duplicate (the UK title). *The Eyes of Darkness* by "Beverley Nichols" is a
   wrong author, so the author is fixed first, then the books merge with Koontz's. *Winnie the Pooh* /
   *The Book* is not a duplicate.
   - Merge automatically only under §12 call 4. Otherwise the AI proposes.
   - A pair that isn't a duplicate gets a `close_pair` verdict, and the queue row is marked
     `not_duplicate`. A legacy identifier the two share goes to the identifier check, and the book
     the rows contradict loses it.

Shane will not work the Duplicates queue by hand (2026-10-27). This stage owns it.

## 6. Verdicts and apply

Reuse `Books::RepairVerdict` (unique per `kind` + `subject_key`), the admin review pages, and
`books:goodreads_replay:apply`.

- **New kinds:** `fix_identity`, `split`, `create_book`, `close_pair`, `add_item` (§12 call 8). They join `relink`,
  `merge_books`, `merge_authors`, `strip_identifier` and `mark_provisional`.
- **Retire the old replay proposals first.** 2,691 relinks and 2,091 identifier strips are still
  `proposed`, decided on stripped titles. The rebuild marks them rejected, with a note saying the
  rebuild replaced them, before it records its own (Shane, 2026-10-27). The rebuild then reuses those
  rows when it reaches the same subject, which the unique index requires anyway. The review page
  hides replaced decisions.
- **What already happened stays:**
  - the 4,418 author merges;
  - the 518 slug fixes;
  - the 24 provisional flags;
  - the 48 correct book merges.
- **Apply order within a pass:**
  1. `fix_identity`
  2. `split`
  3. `strip_identifier`
  4. `relink` / `create_book`
  5. `add_item`
  6. `merge_books`
  7. `close_pair`
  8. `mark_provisional`

  `repair_ratings` runs after every `apply`, as now.
- **Keys survive the sync.** Subject keys use preserved ids: the Goodreads edition id, legacy list
  item and review ids, and legacy book ids. Applying twice changes nothing.
- **Review page:** bulk approve by kind and confidence. It shows the full export title beside the
  book, never only legacy's stored title.

## 6a. Final sweep: remove the import-made books nothing needs

Shane, 2026-10-27: the invalid books the imports created have to go. Stage two empties most of them,
because it moves every list item onto the book its row really names. So the sweep runs after stage
two's `apply`.

- **What qualifies.** A derived book that, after stage two, has none of these:
  - user list items, reviews or reading goals;
  - curated list items;
  - a ranking.

  Books the rebuild created don't qualify, and trusted-core books never do, even when empty.
- **Merge when there's a destination, otherwise delete.** If all the book's former rows moved to one
  book, the sweep merges it into that book with the existing book merger. The URL then redirects,
  which matters for pages search engines already know. Otherwise the book is deleted. A book whose
  only fault was its title or authors is never swept: stage one fixed it, and its items still point
  at it.
- **It sticks across the sync.** The legacy sync already records merges and deletes in
  `record_redirects` and routes legacy data through them. *The builder confirms* in the dev rehearsal
  that a swept book isn't re-added by the next `data_migration:sync`, and that a legacy user's item
  on a merged book follows the redirect.
- **Dry run first.** `books:goodreads_rebuild:sweep` prints counts to merge and to delete, with a
  sample. `[apply]` does it, and is Shane's to run. It reruns after each weekly catch-up for that
  week's books, and once at cutover.

## 7. Evidence services

| Source | Gives | Limits | Use |
|---|---|---|---|
| WorldCat, by ISBN | library title, creator, year, language | frozen 2025-09; no work grouping; MARC-style titles ("The witch… /"); batch route `POST /lookup` returns no title or creator | stage one: confirm editions. 85% of editions have an ISBN; 88.5% of sampled ISBN-13s resolve |
| Open Library, by ISBN | edition → work key, `edition_count` | — | stage one: grouping editions into works |
| Open Library `/resolve` | a work for a title and author | one slot, ~30 s | stage two tie-breaks only; never in bulk (all editions would take ~70 days) |
| Goodreads page, fetched | Goodreads title, author roles, series ids, original year, `best_book_id` | 1,500 a day, shared | stage two: books nothing else settled, and every `create_book` |
| Goodreads page, legacy-seeded (all 39,358 cached) | title, authors | no HTML, no `best_book_id`; ISBNs and series came from legacy | title and authors only |
| AI, cheap model | a judgement over the full export titles plus the other facts | — | one call per unclear group, not per edition; always proposed |

**WorldCat speed.** Stage one needs a title and creator per ISBN. The batch route doesn't return
them, and the single route `GET /isbns/{isbn}` takes seconds for popular ISBNs. Time the single
route on 1,000 export ISBNs. If stage one would take more than about a day, add `title`, `creator`
and `year` to the batch route's slim table on the home server. That is a data-sources change and an
artifact rebuild.

**Google Books** (Shane's suggestion, 2026-10-27) is not in the first build. Its value is books newer
than WorldCat's 2025-09 freeze. But it has no work grouping, gives edition dates rather than
original ones, and the default quota is about 1,000 requests a day. Stage one's report counts
editions that had no corroborating source. If that number is large and mostly recent books, Google
Books gets added as a fallback for just those.

## 8. New data: weekly catch-up and member-import guards

**Weekly catch-up**, until cutover:

1. `data_migration:sync`, as now.
2. `books:goodreads_replay:load` picks up the week's new legacy imports. It is already repeatable.
3. Stage one runs over the books legacy created that week, which are derived.
4. The §4a verification run covers those books (fast pass only).
5. Stage two runs over the new editions.
6. `apply` re-applies everything, including the moves and splits the sync undid.
7. The §6a sweep over that week's books.

At cutover: the old site goes offline, then `FINAL=1 data_migration:sync`, one last catch-up, and
`finish_legacy` (already planned for the final pass only).

**Member-import guards.** No one uses the new site's member import yet, but it is the only path
after launch.

1. **A legacy identifier is a hint, not a match.** An identifier hit counts as a match only when the
   identifier's source is verified. A hit on a `legacy` identifier makes the book a candidate, and
   the title and author still have to agree.
2. **No stamping onto an existing book without a solid match.** A matched book gets the row's
   Goodreads id and ISBNs only when the match came from a verified identifier, or the row and a
   corroborating source agree. Otherwise they stay on the import row. *The builder confirms in code
   when the member import stamps existing books today* (`QueryIdentifiers`, `CreateBook`,
   `SettleEdition`).
3. **A lump check at match time.** A row whose original year or author disagrees with the editions
   the book already holds is not a certain match.
4. **Duplicate pairs need real evidence.** Imports stop raising `DuplicateCandidate` pairs from a
   shared legacy identifier alone.

## 9. Interplay with #419 (Goodreads enrichment)

#419's step treats a Goodreads id a book already holds as a reliable match: import-created books
"carry their Goodreads id + cached page". On derived books that id is legacy-stamped. So:

- The #419 backfill spec waits for this rebuild, or reads only verified-source Goodreads ids.
- This rebuild's `create_book` relies on #419 for enrichment after approval. Books it creates hold
  the Goodreads id with `goodreads_import` source and a fetched page, so #419 needs no search.
- A `fix_identity` page check and #419's PageCheck should agree on what "the same book" means. Reuse
  PageCheck's strict title agreement (the *Dune* / *Dune Messiah* fix) rather than writing a second
  rule.

## 10. Acceptance

- **Labeled sample, before any auto-apply:**
  - about 300 editions, weighted toward the pre-AI era (imports before 2025-11-16 21:14 UTC, 464
    imports), lump suspects, comics and numbered series, translations, unmatched rows, and all 196
    shared-identifier duplicate pairs;
  - an agent labels each with the correct work and cites sources, and Shane spot-checks 50.
- **The bar:** auto-applied verdicts at least 99% correct on the sample, and **zero wrong merges**.
  Proposed verdicts may be wrong.
- **Known cases that must come out right:**
  - *The City and the Stars* loses Goodreads 23129659.
  - *Sustainable Energy* / *The Wager*, *Humans of New York* / *Humans*, *Metaphysics* / *Physics*,
    *Winnie the Pooh* / *The Book* and *The Elements of Style* / *JR* are closed as not duplicates,
    with the wrong identifiers stripped.
  - *Nine Stories* / *For Esmé with Love and Squalor* merge.
  - *The Eyes of Darkness* (wrong author Beverley Nichols) gets Koontz and merges.
  - *Aelita* stays apart from *Aelita + Hyperboloid*.
  - *V for Vendetta* #1–#10 and *Saga* volumes stay separate books.
  - *Hothouse* loses its Hardy Boys editions.
  - The ten wrong comic merges split back into volumes.

  Shane may add cases in a text file in the repo root. Each becomes a known case.
- **Checks after every pass:**
  - no book holds editions with conflicting original years or authors without a verdict;
  - no two books share a verified identifier;
  - no list item points at a provisional book;
  - no trusted-core book's title or authors changed (§12 call 2).
- **Order:**
  1. a dev rehearsal on a production copy, over a few imports (pre-AI and post-AI);
  2. all imports in dev;
  3. production.
- **Idempotence test:** `apply`, `apply` again, `data_migration:sync`, `apply`. The state ends up
  identical.

## 11. Build order

Ordered by what is slow, not by what is easy.

1. **Start fetching Goodreads pages now**, as a small separate PR ahead of the rest. 11,811 replay
   rows are unmatched, across 6,418 distinct editions, and only 95 have a cached page. Fetching the
   other ~6,300 takes about 4–5 days at 1,500 a day. They're needed in stage two whatever else
   changes. Use the existing `GoodreadsPages::FetchPage` through `FetchGate`.
2. **Time WorldCat**, and if needed add title, creator and year to its batch route (§7).
3. **The small pieces:**
   - retire the old proposals;
   - the new verdict kinds and their apply steps;
   - the blinded finder mode;
   - the member-import guards.
4. **Stage one.** Dev rehearsal, the labeled sample, then all imports.
5. **The verification run over repaired books (§4a).** Measure the fast-pass share in dev first,
   then run it in production after the current production verification run frees `/resolve`.
6. **Stage two, last.** Dev rehearsal, the labeled sample, then production. It must not share
   `/resolve` with another long run.
7. **The final sweep (§6a)**, with a dry run.
8. **The weekly catch-up rake task**, and the `docs/launch-todo.md` steps for every production run.

## 12. Calls made after the builder check

These are my calls (Claude's), not Shane's. Each says what it costs if it's wrong.

1. **"Derived" means import-created, not just "created in an import window".** A book that came in
   with a list counts as trusted core: its first legacy list item is within a day of its legacy
   `created_at` (7,792 of 9,247 ranked post-import books). The production verification run over
   those books therefore counts as verified. Post-import books that didn't come in with a list stay
   derived, and the verification pass skips them until this rebuild is done (1,455 ranked, as
   already planned). *If wrong:* a list-created book with an import lump keeps its identity. The row
   check in §4 still catches its wrong rows.
2. **The trusted core is protected.** The rebuild never changes a trusted-core book's title or
   authors. It adds an identifier from a row to a trusted-core book only when a corroborating
   source ties that identifier to the book. It never merges a trusted-core book into a derived one;
   the trusted book always survives. Its only automatic changes are moving rows onto or off it, and
   closing pairs. *If wrong:* some correct Goodreads ids miss ranked books until a later pass.
3. **Undoing the ten wrong comic merges** (verdicts 9744, 9758, 9760, 9778–9781):
   - mark those verdicts rejected, so `apply` never re-runs them;
   - create the volume books;
   - **re-point each merged-away legacy book's redirect to its volume book**, so the sync routes that
     book's legacy items to the volume on its own;
   - move the rows already on the survivor with `split` sub-verdicts.

   *If wrong:* the redirect re-point is the one irreversible-looking step. It is a row update and
   can be pointed back.
4. **WorldCat alone never auto-merges.** An automatic merge needs Open Library to put both books on
   one work, or a fetched page's `best_book_id` to match, **and** the titles to agree after
   normalisation, or be a known translation pair from Open Library. A differing series number blocks
   it. Everything else is proposed. WorldCat years are edition years, so WorldCat only corroborates
   identity in stage one. *If wrong:* more proposals to approve, and no wrong merges.
5. **`create_book` books are made by `apply`**, after approval (automatic or human). In the same
   pass, the relinks onto them follow. They aren't provisional, because the verdict was the
   approval, and #419 enrichment queues on creation. The §10 check becomes "no list item points at a
   provisional book".
6. **Already-applied replay verdicts stay, and keep re-applying.** These are the 543 rule strips
   (518 of them slug fixes), the 24 provisional flags and the author merges. All were rule-certain
   and none re-adds data. The rebuild never records a verdict that reverses one. Approved relinks:
   there are none (all 2,691 are proposed, and get retired).
7. **Subject keys:**
   - per edition: the Goodreads edition id;
   - a split group: the legacy book id plus the group's lowest Goodreads book id;
   - `create_book`: the Goodreads book id of the group's anchor edition.

   The lowest id is stable when editions join a group later. An edition that changes groups gets a
   new relink, keyed by the edition. *If wrong:* a duplicate created book, which the next dedupe
   catches.
8. **Rows legacy skipped get written to users' lists** (Shane, 2026-10-27: "when we replay all the
   goodreads_imports we should fix everyone's lists").
   - **Rows from imports legacy completed** (21,446 rows) get an `add_item` verdict, keyed by the
     import row id. On apply, it writes the shelf item, rating, review and dates the way the member
     import's `WriteLibrary` does.
   - **Re-applied after every sync.** The weekly sync reconciles each list with legacy, so it can
     remove an item legacy never had. *The builder confirms* whether `data_migration:sync` deletes
     such items, and verifies in the idempotence test that the item is back after `apply`.
   - **Rows from failed legacy imports** (30,391) stay with `finish_legacy` at cutover, which writes
     them through the member pipeline. The rebuild resolves their editions, so `finish_legacy` finds
     honest books, but writes nothing for them itself.
   - Note: the replay's `legacy_replay` imports never run `WriteLibrary`. That is deliberate in the
     replay, and `add_item` must not switch it on for whole imports.

## 13. Left to the builder

- Class and table names, job shapes and batch sizes.
- How stage one stores its per-book classification. A column on an existing table or a new table
  both work, as long as the classification can be re-run and reported.
- The exact author-key and title normalisation, as long as it uses the existing `Check.title_key`
  and author key code rather than new ones.
- Report formats, as long as each rake task prints counts per outcome and a sample Shane can read.
