# Goodreads enrichment for new books

**Status:** draft for Shane's review · **Date:** 2026-10-25
**Builds on:** `docs/superpowers/specs/2026-10-20-books-enrichment-workflows-design.md` (§9 describes
this step's shape), `docs/features/enrichment-workflows.md` ("Adding a step to a workflow"),
`docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (page fetching, politeness, HTML storage).

## 1. Intent

When a book enters the catalog, look it up on Goodreads. If we are sure we found **the book**, take
its first-publication year, page count, genres, series and identifiers, and hand its description to the book
AI step as source material for our own house-style description.

The reason is year-end "best of" lists. They are full of books published this year, which the AI
model has never heard of. Today such a book costs a 15¢ web-search research run and still often
comes out thin. Goodreads has the facts for nearly every one of them.

## 2. Goals, non-goals, anti-goals

**Goals**

- Every new book gets a Goodreads step automatically, in the book workflow, before book AI.
- A confirmed match fills blank year and page count, links existing categories, puts the book in its
  series (creating the series when it is new), and saves every valid identifier on the page.
- Book AI writes the description from the Goodreads text, in house style, and **skips the research
  run** when Goodreads found the book.
- Amazon can search by the ISBN Goodreads supplied.
- Every search page and book page fetched is cached whole, so later work can re-read it without
  fetching again.

**Non-goals (later specs)**

- Backfilling existing books (a rake task that spawns runs). Shane expects it, and expects to parse
  more out of Goodreads pages later. §10 lists what this spec must do so that later work is cheap.
- Public series pages. Only admin pages show series today; this spec fills the data.
- A genre-mapping UI that adds Goodreads genres we lack, or maps them onto ours. This spec stores
  every genre name so that UI can work from the cache.
- Ratings, reviews, covers, and author data from Goodreads.

**Anti-goals: these would make it a failure even if it works**

- **Attaching the wrong book.** An omnibus, box set, study guide, summary, single volume of a
  multi-volume work, abridged edition, or adaptation (graphic novel, screenplay) is a miss, not a
  match. "We want the BOOK."
- **Writing an invalid or wrong-book ISBN.** That is how the legacy catalog filled with bad data. A
  value that fails its checksum, or one a verified source already gives to another book, is never
  written.
- **Using Goodreads' description text on the site.** It is publisher copy. It is never written to
  the `descriptions` table and never shown. It only reaches the site rewritten.
- **Creating categories.** Only existing ones are linked. (Series are different: a series is a
  catalog record like an author, and a new one is created. See §5.4.)
- **Overwriting data.** Fill blanks only. A field a human cleared stays cleared.
- **Breaking Goodreads' patience.** Every fetch, search or book page, goes through the existing
  `FetchGate` (15 s between fetch starts, 1,500 a day, 6 h cooldown after a block), shared with the
  Goodreads import.

## 3. Where it sits

`books.book_enrichment` gains a `goodreads` step, and the definition goes to version 2.

| step | queue | waits on |
|---|---|---|
| `goodreads` (new) | `goodreads_fetch` | nothing |
| `book_facts` | `low` | `goodreads: :finish`, plus every new linked author's `author_facts` (unchanged) |
| `amazon` | `serial` | `goodreads: :finish` |

- Amazon still always runs. It waits only on Goodreads, not on authors or AI.
- `:finish` means a Goodreads step that failed, was skipped or found nothing still releases both
  dependents. They then behave exactly as they do today.
- Open Library runs inside the importer, before the run is planned, so it is already "first".
- Runs planned under version 1 have no `goodreads` step. Every adapter and `skip_if` that looks for
  it uses `run.steps.find_by(key: "goodreads")` and treats a missing step as "no Goodreads data".
  The engine doc requires this.
- Add the `add_step` validation the coordinator memory asked for: refuse duplicate keys and a
  `waits_on` key that names no step.

**Fetch budget: shared, no priority (Shane, 2026-10-25).** Enrichment and the Goodreads import draw
on the same 1,500-a-day gate, with no sub-cap. Hitting the cap is unlikely:

- Most list books are already in the catalog, so they plan no run.
- Books a user's Goodreads import creates are the largest source of new books. They arrive with their
  Goodreads id stamped (`CreateBook`, `stamp_identifiers: true`), and the import usually fetched their
  page already. They take the known-id path (§4.1) and usually cost **no fetch**. Only books the import
  left unverified (no page) cost one.

If the cap does run out, an import's waiting editions settle unverified, as they do today. That is
the accepted risk; the backfill spec can revisit it.

**Plan-time skips** (`BookEnrichment.start`):

- `goodreads` skips with `no_authors` when the book has no linked authors and no `author_names`.
  This is the same condition as Amazon's.
- `only:` behaves as for every step.

**Retries and waits.**

- A gate refusal returns `Outcome.wait(until:)`, which uses no attempt:
  - `spacing_wait` for the next fetch slot;
  - the next UTC midnight for the daily cap;
  - the block cooldown for a block.
- A fetcher that is down (`:fetcher_down`), or a page Goodreads could not serve (`:unavailable`), is
  raised, so the coordinator's backoff retries it. `max_attempts` stays at the default 3.
- After the last attempt the step fails and the book proceeds without Goodreads.
- There is no patience release (my call). The longest wait is the daily cap, under 24 h, and that
  is acceptable for a new book. The admin "Enrichment runs" card shows a book waiting on it.

## 4. The `goodreads` step

```
book has a Goodreads id already? ── yes ──► book page (cache or fetch)
        │ no                                       │
        ▼                                          ▼
title search (cache or fetch) ─► rows ─► free filters ─► rank by ratings ─► cheap AI picks one or none
  (none survive → one retry: title + author surname)            │ picked
                                                                ▼
                                                  book page (cache or fetch)
                                                                │
                                   not the work's main edition? ─► main edition's page (cache or fetch)
                                                                │
                                         page re-check (free filters on page facts)
                                                   │ passes
                                                   ▼
                       write year, page count, categories, identifiers · one ledger row
                       result: {matched, goodreads_book_id, page_id} for book_facts
```

### 4.1 Known id first

A book that already holds a `books_work_goodreads_id` (legacy data, the Goodreads import) skips the
search. It goes straight to the page and the re-check. Legacy ids are known to be unreliable
(`GoodreadsReplay::LegacyChoice`: legacy "stamped the id on whatever it picked"). So when a known
id's page fails the re-check, the step falls back to the search as if it had no id (my call). That
id's identifier row is not touched; review settles it.

### 4.1a Gate turns: one fetch per execution

`FetchPage` does no pacing: it fetches when called. The gate logic lives in `FetchPageJob`:

- reserve a turn;
- reschedule;
- check `spacing_wait`;
- call `started!` and fetch;
- call `block!` on `blocked` or `unparseable`.

Extract that sequence into one shared helper, which `FetchPageJob` and the step both call. The
gate's lock-free safety rests on the `goodreads_fetch` capsule's concurrency of 1, so the step stays
on that queue.

The step is resumable and makes **at most one fetch per execution**:

1. An execution takes a reservation.
2. If the reservation is in the future, the step returns `Outcome.wait(until:)`, with the granted
   reservation and the current phase (`search` or `page`) in `result`.
3. On re-entry, the step uses the stored reservation instead of reserving again. Reserving again
   would spend another slot from the daily cap and move the book to the back of the line.
4. After a search fetch and the pick, the step reserves the page fetch's turn and waits again.

So a no-cache match costs two turns, 15 s apart, as the gate intends.

The AI pick runs inside the step, on the concurrency-1 capsule. It takes a few seconds, which is
shorter than the 15 s spacing the next fetch has to wait anyway (my call).

### 4.2 Search

**What Goodreads search actually does.** Measured 2026-10-25, with the pages saved as fixtures under
`web-app/test/fixtures/files/goodreads/searches/` and `.../pages/`:

- `?q=catch-22+Joseph+Heller` ranks by how well each **title** matches the query text. Study guides and
  summaries carry the author's name in their titles ("Catch 22 by Joseph Heller", "Study Guide to
  Catch-22 by Joseph Heller"), so adding the author to the query lifts them.
  - The real book came third (907,547 ratings, 521 editions), behind a Novel Units guide (169
    ratings) and a Bright Summaries guide (27).
  - Rows 4-10 were all guides and summaries.
- The real book's row showed a **stray edition's** title and id: "(Catch-22) By Joseph Heller (Author)
  Paperback on (Dec , 2007)", `147719920`. The work's figures were attached to it. That edition's page
  has 0 pages and no ISBN.
- The row's author link said "Joseph Heller". Every guide's author link named the guide's maker
  (Novel Units, SparkNotes, Ray Moore, SuperSummary, …).
- `?q=catch-22` (title only) put the real book **first**, under its proper title and its main edition
  id `168668`. "Closing Time (Catch-22, #2)", by the same author, came second.
- The stray edition's page names the work's main edition in its Apollo state (`Work.bestBook` →
  `168668`). Genres and series sit on the work, so they were present on the stray page too.

So:

- **The query is the title alone**: the main title, before any ":".
- **If no row survives the free filters** (§4.3), one retry is allowed: the title plus the primary
  author's surname. This is for a common title whose real book falls below the first page of results.
  It costs a second search fetch, and only on a miss.
- Results are never trusted in their listed order (see ranking, §4.3).
- The search page is fetched through `PageFetcher::Client`, inside a gate turn (§4.1a). The fetcher
  error mapping is `FetchPage`'s (`FETCHER_DOWN` versus `:unavailable`).
- The builder adds fixtures beside the three already captured:
  - a this-year book;
  - a common title (for example "Beloved" or "The Road") that needs the surname retry;
  - a no-results query.
- **Search cache (new table).** One row per normalized query. It holds:
  - the outcome (`found`, `no_results`, `blocked`, `unparseable`);
  - the HTTP status, the parser version and the fetch time;
  - the parsed candidate rows (jsonb);
  - the gzipped HTML as a `private_imports` attachment, like `Books::GoodreadsPage`.
- A cached search younger than 30 days is reused (my call). Older ones, and blocked or unparseable
  ones, are fetched again.
- Each candidate row holds:
  - the Goodreads book id and the title as shown;
  - the author-link names;
  - the published year as listed (it is the work's first-publication year, when present);
  - the rating count and the edition count.

  The parser reads `tr[itemtype="http://schema.org/Book"]` rows (`a.bookTitle`, `a.authorName`, the
  grey "avg rating — N ratings — published Y — N editions" line). It follows no links.

### 4.3 Free filters, then the cheap model

1. **Free filters** drop candidates that clearly are not the book.
   - **The author link must agree** with one of the book's authors (`Verification::Check.authors_agree?`).
     This is the filter that removes guides and summaries: their author link names the guide's maker.
   - The derivative and set word lists (`AmazonBookCheck.derivative?`'s words, `EditionCheck::SET_WORDS`)
     drop a row whose title contains them.
   - The title check is loose. The shown title may be a stray edition's ("(Catch-22) By Joseph Heller
     (Author) Paperback…"), so the row passes when the book's normalized main title appears inside the
     row's normalized title. `title_agrees?` is too strict here. "Closing Time (Catch-22, #2)" fails,
     because "catch 22" appears there only in the series suffix; strip the trailing series
     parenthetical before comparing.
   - A listed year earlier than the book's `first_published_year` is not dropped.
2. If no candidate survives, retry the search once with the surname (§4.2). If none survives that
   either, the outcome is `no_match`, with no AI call.
3. **Rank** the survivors by rating count, then edition count. The real work dwarfs everything else
   (907,547 ratings against a few hundred).
4. **The cheap model** gets the book and the top surviving rows, at most 5, each with its rating and
   edition counts, and picks one or none. Use
   `Services::Ai::Tasks::Matching::SelectCandidateTask` (role `fast`) if its "same entity" framing
   fits. Otherwise write a Goodreads task beside `AmazonBookMatchTask`, carrying the same non-match
   criteria. In both cases:
   - "none" is the right answer when unsure;
   - a pick below `high` confidence is treated as none (my call; wrong-book costs more than a miss).

### 4.4 Book page and re-check

- **Use the work's main edition.** A search row's id can be a stray edition, with no page count, no
  ISBN and often no description.
  - The parser reads `Work.bestBook`'s `legacyId` as `best_book_id` (§4.5).
  - When the fetched page's id is not its work's `best_book_id`, the step fetches (or reuses) the
    main edition's page and uses that page from then on. A stray pick costs one more fetch.
  - Identifiers, page count and description come from the main edition.
  - The Goodreads id written (§5.3) is the main edition's id.
  - For a known id (§4.1) the same rule applies. A Goodreads-import book whose user shelved a
    particular edition gets the main edition's facts, because the book record is the work, not the
    user's copy.
- The step reuses a cached page itself, when the row exists, holds HTML and parses under version 2.
  `FetchPage` always fetches; reusing a cached page is the caller's job.
- Otherwise the step fetches through `Services::Books::GoodreadsPages::FetchPage`, inside a gate turn.
- `FetchPageJob` is not used. It only serves import editions awaiting an answer.
- **Pages with no HTML.**
  - Legacy-seeded rows (`source: legacy`) have no attachment.
  - `FetchPage#store` never replaces a conclusive row.
  - Give `FetchPage` a `refresh: true` mode, used only by this step, for a row with no HTML. It
    attaches the new HTML and fills the version 2 columns. It never turns `found` into `not_found`.
    For the import's readers the row's identity facts and outcome stay as they were.
- **Re-check.** The page facts (title, contributors, series, page title) go through the same free
  filters as §4.3, plus:
  - a page whose genres include a study-aid or summary shelf ("Study Guides", "Summaries", or what
    the fixtures show) is rejected;
  - a page whose series entry is a range ("1-3") or whose title names a box set is rejected;
  - a series *position* ("Book 1") is fine: that is the book.
- A failed re-check is outcome `rejected`, and nothing is written.

### 4.5 Parser additions (`Books::Goodreads::BookPage`, version 2)

Read these from the Apollo state, as the existing fields are:

- `description` (plain text, HTML stripped);
- `genres` (all genre names, in page order);
- `page_count` (`details.numPages`);
- `format` (`details.format`, e.g. Hardcover, Kindle, Audiobook);
- `best_book_id` (the work's `bestBook` → `legacyId`).

Store them on `books_goodreads_pages` as new columns: `description` text, `genres` jsonb array,
`page_count` integer, `format` string and `best_book_id` bigint. A `numPages` of 0 is stored as nil.

The fixture `catch_22_stray_edition_147719920.html.gz` holds every one of these (genres: Classics,
Fiction, Historical Fiction, War, …).

Remove the header comment that says descriptions and genres are never read. A version 1 page that
has HTML is re-parsed from its attachment when the step needs it, with no refetch. A page with no
HTML is refetched (§4.4). There is no bulk migration.

The markup fallback (pages without `__NEXT_DATA__`) yields no description, genres or page count.

A match that comes back without a description is still a match:

- year, genres and identifiers are written as usual;
- `book_facts` runs in `sourced` mode with no description text, so research is still skipped
  (Shane: no research when Goodreads found the book);
- the model writes a description only if it knows the book.

The Goodreads import's readers are unaffected: they read identity facts only.

## 5. What a match writes

All writes happen in one transaction, inside the step. They go in one ledger row: `Enrichment`, kind
`books.goodreads`, provider `goodreads`, linked to the step automatically. `mode` is NOT NULL and
defaults to `knowledge`. These rows carry that default; a cost report that counts research by mode
is unaffected. The row is shaped like the
VIAF ledger rows:

- one row per execution that decides something: a match, a `no_match` or a `rejected`. A plan-time skip never runs the step, and a failure is a raise the coordinator retries. Both are recorded on the workflow step (outcome, last error), which the admin "Enrichment runs" card shows;
- `citations` holds the page URL;
- `facts` holds one entry per field with `value`, `applied` and `reason`, using the reasons
  `ApplyBookFacts` uses (`filled`, `already_set`, `human_cleared`, `invalid`, `no_match`).

Outcomes:

| outcome | meaning |
|---|---|
| `applied` | a matched page wrote at least one field |
| `nothing_to_apply` | matched, all fields already set |
| `unrecognized` | `no_match`, `rejected`, or a second `blocked`/`unparseable` fetch in the same step (the step then gives up so the book proceeds; the first one blocks the gate and waits) |
| `skipped` | reason given |
| `failed` | error recorded |

### 5.1 Year and page count

- `first_published_year` is filled from the page's `original_publication_year` when blank. It is the
  work's first publication, not the edition's.
- `page_range` is filled with the page count as a string when blank and the format is not an
  audiobook or ebook.
  - This is the transitional work-level field; it drives `book_length`.
  - Also fill the default edition's `page_count` if the book has a default edition and it is blank.
- Human-cleared fields (the `CorrectionField` rule `ApplyBookFacts` uses) are left alone. Share that
  rule rather than copy it.

### 5.2 Categories

Every Goodreads genre name is matched against `Books::Category` rows of type `genre`, `subject` or
`audience`. Merged rows are included in the lookup, because a merged category is always
`deleted: true`; a lookup limited to active rows would never see one. The matching works like this:

- by name, case-insensitive;
- by alternative name;
- through the twin-key normalizer `Services::CategoryCleanup::NameNormalizer` uses. `NameIndex` itself
  is tied to cleanup runs, so extract the lookup or write a small sibling.

A name that resolves to a merged category follows `canonical` to its active target. Locations are
not matched (my call): Goodreads location shelves are noisy, and our location tree is unpruned.

- **Never create a category.** Unmatched names are recorded in the ledger facts (`unmatched`) and
  remain on the cached page for the mapping UI.
- Link with `CategoryItem.find_or_create_by!`. Add a `goodreads` value to `category_items.source` so
  these links stay identifiable (and reversible) later.
- Keep `WorldCat::ApplyCategories`' Fiction/Nonfiction rule: never link both. If the book already
  has one, the other is skipped as `type_conflict`. If the page lists both and the book has neither,
  both are skipped as `type_conflict` (my call). A wrong book type is worse than none.
- Only links are added. Existing links are never removed.

### 5.3 Identifiers

Save every identifier the page has, at the work level, with a new `Identifier` source `goodreads`:

- `books_work_goodreads_id`;
- ISBN-13 and ISBN-10 (both forms, from `Books::Isbn.normalize`);
- ASIN.

The checksum and collision rules come from `AmazonBookIdentifiers`. The ASIN rule and the
two-form rule are new and apply to Goodreads only:

- An ISBN must pass its checksum. A failing value is dropped and recorded as `invalid`.
- Both forms of an ISBN are written.
- An all-digit ASIN is treated as an ISBN-10 and checksummed. Any other ASIN must match
  `/\A[A-Z0-9]{10}\z/`.
- **Collision.**
  - If a verified source (Open Library, WorldCat) gives any equivalent form of an ISBN or ASIN to
    another book, write no ISBN or ASIN. Flag both books with
    `Services::DuplicateCandidates::Flag` (`source: :identifier_collision`), as Amazon does.
  - The Goodreads id is still written in that case. It is the durable record of which page belongs to
    which book, and the backfill and re-parse work in §10 depends on it.
  - If any other book holds the same Goodreads id, from any source, write no identifiers at all and
    flag both books. A Goodreads id is strong duplicate evidence.
- Extract the shared collision and write logic from `AmazonBookIdentifiers` into one writer that
  takes `source:` and the value pairs. Amazon then calls it, and Amazon's behavior does not change:
  Amazon keeps building its own pairs, with no ASIN check and no second ISBN form.
- The new `Identifier` source is `goodreads`. It is separate from the existing `goodreads_import`, which
  stays the source for user-import data.
- `find_or_initialize_by`, never `build`.

A collision blocks only identifiers. Year, page count, categories and series are still written. The match
passed the AI and the re-check; the collision says "possible duplicate book", which review settles.

### 5.4 Series

Goodreads gives each series entry as a Goodreads series id (from the series URL), a title and a
position as written ("1", "0.5", "3.5"). The parser already reads these and has stored them on 3,805
of the 39,358 cached pages (dev, 2026-10-25). `books_series` and `books_series_books` are empty.

- **Find or create the series by Goodreads series id.**
  - Add an `Identifier` type `books_series_goodreads_id` on `Books::Series`, with source `goodreads`.
  - Look the series up by that identifier. If none exists, create a `Books::Series` with the Goodreads
    title and the identifier, in the step's transaction.
  - Never match a series by title. Many series share names ("Foundation", "Dune"), so the Goodreads
    series id is the only key.
- **Link the book.** `Books::SeriesBook.find_or_initialize_by(series:, book:)`:
  - `position` is the decimal value when the label is a plain number;
  - `position_label` is the label as written;
  - `numbered` is false when the label is blank or not a number.
  - An existing link's position is never changed (fill blanks only).
- A book in several series (a sub-series within a larger one) gets every link.
- A range position ("1-3") never gets this far, because the re-check rejects it (§4.4).
- A series title or position Goodreads changes later is not re-applied. The cached page keeps it, and
  admin pages edit it.
- **Side effect to expect.** `Recommendations::Books::Adapter#series_predecessors` begins to see data.
  A numbered series book is then treated as having an earlier entry, which changes recommendations.
  That is the intended effect of having series data, but recheck the recommendations acceptance page
  (user 1141) after the first batch lands.
- The ledger facts record each series as `filled` (`created` or `linked`) or `already_set`.

### 5.5 The step's result

The step's `result` tells `book_facts` (and the admin panel) what happened. It names the page and
carries no page content:

```json
{"matched": true, "goodreads_book_id": 123, "page_id": 456}
```

`{"matched": false}` on `no_match`, `rejected` or a skip. `book_facts` reads the description and facts
from the `books_goodreads_pages` row that `page_id` names (§10).

## 6. Book AI with Goodreads source material

`book_facts` reads `run.steps.find_by(key: "goodreads")&.result`. When `matched` is true, it loads
the page row by `page_id`, and when the book needs a description or facts:

- **No research run (Shane's decision).** `EnrichBook` runs a new mode, `sourced`, in place of the
  knowledge run. A new `Enrichment.mode` value, `sourced: 2`, keeps cost reports honest.
  - The knowledge-cutoff rule and the low-confidence or unrecognized fallback to research do not
    apply in this mode.
  - `force_research` still forces research, for the admin's sake.
- **Prompt.** `BookFactsTask` gains an optional source block: the Goodreads title, authors, year, page
  count and genres, and the description labelled as "publisher copy: use it for the premise, write
  your own text, never copy it".
  - The model may rely on the source for a book it does not know. "Recognized" is about knowing
    the book, and a sourced run is not marked `unrecognized` for not knowing it.
  - Facts the source does not support (original language, origin countries, word count) stay
    subject to the model's confidence, as today.
- **Description.**
  - The house-style system message, `DescriptionReviewTask` and `DescriptionCheck` all apply unchanged.
  - `DescriptionCheck` gets the Goodreads text as `source_text`, so a run of 8 or more copied words
    is caught and the description is not written. Its `exempt_phrases` are the title and author
    names.
  - The result is written as `ai_generated`, as today.
  - The existing rule stays: a book that already has an `ai_generated` description gets no new one.
- When Goodreads did not match, or the step is missing, book AI behaves exactly as today, research
  included.

The admin **Enrich With AI** button stays outside workflows. It sees no Goodreads result and is
unchanged.

## 7. Amazon by ISBN

`AmazonProductService#search_param_sets` gains a first search when the book holds an ISBN-13 from a
verified source (Open Library, WorldCat) or from `goodreads`: `{keywords: isbn13, search_index:
"Books"}`, using one ISBN, the best by `Identifier.trust_rank`. Legacy ISBNs are not used; they are
known to be bad. The keyword searches follow
as today, and the AI match check is unchanged.

Because it reads the book's identifiers, not the step result, the `books:amazon_enrich*` sweeps and
`AmazonProductEnrichmentJob` benefit too, and the step and the job stay in step.

## 8. Edge cases

- **Two books, one Goodreads id.** This is caught by the §5.3 collision rule: flag, write no
  identifiers.
- **A book merged or deleted mid-run.** The recovery job already cancels the run.
- **A goodreads step from an older run definition.** It is missing, which means no data.
- **Goodreads redesign.** The book page parser returns `unparseable` (stored, retried later, and
  blocks the gate as today). A search parser that finds no rows on a page that has results must
  also say `unparseable`, not `no_results`, so a redesign never reads as "no such book".
  - The fixtures must include both.
- **An audiobook or Kindle page picked.** The year, genres and identifiers still apply. The page
  count is skipped (§5.1). The ASIN is kept.
- **A Goodreads-import book that is itself an omnibus or a study guide.** The user shelved that
  edition, so the import made a book of it. The re-check rejects the page. The search then finds the
  same kind of page and rejects it too. Nothing is written, and book AI runs as today. This is the
  right outcome: no data beats wrong-book data.
- **A title with a subtitle.** Search uses the main title (before ":"), the way `Agreement` compares.

## 9. Acceptance scenarios

1. A new 2026 novel with one new author. Goodreads matches. Year, page range, genres and identifiers
   are written, and the categories link to existing rows only. `book_facts` runs in `sourced` mode,
   with no research row. The description is written as `ai_generated` and passes `DescriptionCheck`
   against the Goodreads text.
2. The search returns a study guide above the real book. The guide is dropped by the free filter, or
   the AI picks the real book.
3. The only candidate is "The Lord of the Rings Box Set" for "The Fellowship of the Ring". The
   outcome is `no_match` or `rejected`, nothing is written, and book AI runs as today, research
   included.
4. A page with a bad ISBN-13 checksum. The ISBN is dropped as `invalid`, and the rest is written.
5. A page ISBN that Open Library gives to another book. No ISBN or ASIN is written, the Goodreads
   id is written (§5.3), both books are flagged, and year and categories are still written.
6. The gate's daily cap is reached. The step waits until the next UTC midnight with no attempt
   used, and `book_facts` waits with it.
7. The fetcher is down for good. Three attempts fail, the step fails, and `book_facts` and `amazon`
   proceed as today.
8. A version-1 run is still in flight at deploy. `book_facts` and `amazon` find no `goodreads` step
   and run as before.
9. A book with a human-cleared `page_range`. It stays blank, and the ledger says `human_cleared`.
10. A Goodreads genre "Literary Fiction" whose category was merged into "Literary". The book links to
    "Literary".
11. Two new books from the same new series, arriving one after the other. The first creates the
    `Books::Series` and its Goodreads-id identifier. The second links to it, with no duplicate series.
    Both have the right `position`.
12. A Goodreads page whose ISBN collides with a verified holder. The ISBN is not written, the
    Goodreads id is written, and both books are flagged.

## 10. Built for a later backfill and re-parse

Shane expects a backfill over existing books, and more fields parsed from Goodreads pages later. This
spec builds neither, but it must leave them cheap. Requirements:

- **Find and apply are separate services.**
  - *Find* is the search, the pick, the page fetch and the re-check. It costs fetches.
  - *Apply* takes a book and a cached page and writes year, page count, categories, series and
    identifiers. It costs nothing but the database.
  - The step calls both. A future rake task can call apply alone over books whose page is already
    cached and matched, with no fetch.
- **Apply is idempotent.** It fills blanks, uses `find_or_create` and links only. Running it twice, or
  again after a parser upgrade, writes only what is newly available, and the ledger records that
  run's facts. Test it by running apply twice on the same book and page and asserting that the second
  run changes nothing.
- **The match is durable.** The `books_work_goodreads_id` identifier with source `goodreads` records which
  page belongs to which book (§5.3). A backfill finds "matched and cached" books by joining that
  identifier to `books_goodreads_pages`.
- **Parse from the cache.** A parser version bump re-parses stored HTML. No field may be readable only
  at fetch time. The search cache keeps HTML for the same reason.
- **Book AI reads the page, not the step.** `book_facts` takes its source material from the cached page
  that the step's result names (`page_id`). A later re-enrichment run can then feed the same page
  without a Goodreads step in its run. The description is read from the page row and never copied
  into the step result.
- **The backfill spec still owns:** its pacing against the shared gate, the order books are processed
  in, and whether a book with an existing AI description gets a Goodreads-sourced rewrite.

## 11. Left to the builder

- The search URL details, the candidate parser, and the exact study-aid shelf names (from the
  fixtures).
- Whether `SelectCandidateTask` fits or a Goodreads match task is cleaner.
- The names of the search cache table and model, and of the new services.
- How the `sourced` mode is threaded through `EnrichBook`, `BookFactsTask` and `ApplyBookFacts`,
  within §6's rules.
- The docs to update: `docs/features/enrichment-workflows.md`, `docs/features/books_enrichment.md`,
  `docs/features/goodreads-import.md` (the parser and the shared gate), and
  `docs/features/data_importers.md`.
