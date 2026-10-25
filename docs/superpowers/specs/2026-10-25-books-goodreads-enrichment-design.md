# Goodreads enrichment for new books

**Status:** draft for Shane's review · **Date:** 2026-10-25
**Builds on:** `docs/superpowers/specs/2026-10-20-books-enrichment-workflows-design.md` (§9 describes
this step's shape), `docs/features/enrichment-workflows.md` ("Adding a step to a workflow"),
`docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (page fetching, politeness, HTML storage).

## 1. Intent

When a book enters the catalog, look it up on Goodreads. If we are sure we found **the book**, take
its first-publication year, page count, genres and identifiers, and hand its description to the book
AI step as source material for our own house-style description.

The reason is year-end "best of" lists. They are full of books published this year, which the AI
model has never heard of. Today such a book costs a 15¢ web-search research run and still often
comes out thin. Goodreads has the facts for nearly every one of them.

## 2. Goals, non-goals, anti-goals

**Goals**

- Every new book gets a Goodreads step automatically, in the book workflow, before book AI.
- A confirmed match fills blank year and page count, links existing categories, and saves every
  valid identifier on the page.
- Book AI writes the description from the Goodreads text, in house style, and **skips the research
  run** when Goodreads found the book.
- Amazon can search by the ISBN Goodreads supplied.
- Every search page and book page fetched is cached whole, so later work can re-read it without
  fetching again.

**Non-goals (later specs)**

- Backfilling existing books (a rake task that spawns runs). This spec only has to leave room for it.
- A genre-mapping UI that adds Goodreads genres we lack, or maps them onto ours. This spec stores
  every genre name so that UI can work from the cache.
- Ratings, reviews, covers, series, and author data from Goodreads.

**Anti-goals: these would make it a failure even if it works**

- **Attaching the wrong book.** An omnibus, box set, study guide, summary, single volume of a
  multi-volume work, abridged edition, or adaptation (graphic novel, screenplay) is a miss, not a
  match. "We want the BOOK."
- **Writing an invalid or wrong-book ISBN.** That is how the legacy catalog filled with bad data. A
  value that fails its checksum, or one a verified source already gives to another book, is never
  written.
- **Using Goodreads' description text on the site.** It is publisher copy. It is never written to
  the `descriptions` table and never shown. It only reaches the site rewritten.
- **Creating categories.** Only existing ones are linked.
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
search (cache or fetch) ─► candidate rows ─► free filters ─► cheap AI picks one or none
                                                   │ picked
                                                   ▼
                                         book page (cache or fetch)
                                                   │
                                     page re-check (free filters on page facts)
                                                   │ passes
                                                   ▼
                       write year, page count, categories, identifiers · one ledger row
                       result: {matched, goodreads_book_id, description, …} for book_facts
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

- The query is the title plus the primary author name, in Goodreads search (`/search?q=`).
- The search page is fetched through `PageFetcher::Client`, inside a gate turn (§4.1a). The fetcher
  error mapping is `FetchPage`'s (`FETCHER_DOWN` versus `:unavailable`).
- The builder must capture real search pages as test fixtures before writing the parser:
  - a famous book;
  - a this-year book;
  - a title that returns a study guide above the real book;
  - a no-results query.
- **Search cache (new table).** One row per normalized query. It holds:
  - the outcome (`found`, `no_results`, `blocked`, `unparseable`);
  - the HTTP status, the parser version and the fetch time;
  - the parsed candidate rows (jsonb);
  - the gzipped HTML as a `private_imports` attachment, like `Books::GoodreadsPage`.
- A cached search younger than 30 days is reused (my call). Older ones, and blocked or unparseable
  ones, are fetched again.
- Each candidate row holds the Goodreads book id, title, author names, the published year as listed,
  and the rating count. The search parser reads rows only; it follows no links.

### 4.3 Free filters, then the cheap model

1. **Free filters** drop candidates that clearly are not the book. Reuse the blocks
   `AmazonBookCheck` is built from:
   - `Verification::EditionCheck.title_agrees?`;
   - `Verification::Check.authors_agree?`;
   - the set and derivative word lists (`EditionCheck::SET_WORDS` and `AmazonBookCheck.derivative?`'s
     words), applied to the candidate's title.
   - A candidate whose listed year is earlier than the book's `first_published_year` is not
     dropped: Goodreads lists an edition's year.
2. If no candidate survives, the outcome is `no_match`, with no AI call.
3. **The cheap model** gets the book and the surviving rows, at most 5, and picks one or none. Use
   `Services::Ai::Tasks::Matching::SelectCandidateTask` (role `fast`) if its "same entity" framing
   fits. Otherwise write a Goodreads task beside `AmazonBookMatchTask`, carrying the same non-match
   criteria. In both cases:
   - "none" is the right answer when unsure;
   - a pick below `high` confidence is treated as none (my call; wrong-book costs more than a miss).

### 4.4 Book page and re-check

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
- `format` (`details.format`, e.g. Hardcover, Kindle, Audiobook).

Store them on `books_goodreads_pages` as new columns: `description` text, `genres` jsonb array,
`page_count` integer and `format` string.

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

- one row per run, skips and failures included;
- `citations` holds the page URL;
- `facts` holds one entry per field with `value`, `applied` and `reason`, using the reasons
  `ApplyBookFacts` uses (`filled`, `already_set`, `human_cleared`, `invalid`, `no_match`).

Outcomes:

| outcome | meaning |
|---|---|
| `applied` | a matched page wrote at least one field |
| `nothing_to_apply` | matched, all fields already set |
| `unrecognized` | `no_match` or `rejected` |
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
    another book, write no identifiers. Flag both books with
    `Services::DuplicateCandidates::Flag` (`source: :identifier_collision`), as Amazon does.
  - If any other book holds the same Goodreads id, from any source, treat it the same way. A
    Goodreads id is strong duplicate evidence.
- Extract the shared collision and write logic from `AmazonBookIdentifiers` into one writer that
  takes `source:` and the value pairs. Amazon then calls it, and Amazon's behavior does not change:
  Amazon keeps building its own pairs, with no ASIN check and no second ISBN form.
- The new `Identifier` source is `goodreads`. It is separate from the existing `goodreads_import`, which
  stays the source for user-import data.
- `find_or_initialize_by`, never `build`.

A collision blocks only identifiers. Year, page count and categories are still written. The match
passed the AI and the re-check; the collision says "possible duplicate book", which review settles.

### 5.4 The step's result

The step's `result` is what `book_facts` reads:

```json
{"matched": true, "goodreads_book_id": 123, "page_id": 456, "description": "…",
 "year": 2026, "page_count": 352, "genres": ["Fiction", "Literary Fiction"]}
```

`matched: false` (with no other keys) on `no_match`, `rejected` or a skip.

## 6. Book AI with Goodreads source material

`book_facts` reads `run.steps.find_by(key: "goodreads")&.result`. When `matched` is true and the
book needs a description or facts:

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
5. A page ISBN that Open Library gives to another book. No identifiers are written, both books are
   flagged, and year and categories are still written.
6. The gate's daily cap is reached. The step waits until the next UTC midnight with no attempt
   used, and `book_facts` waits with it.
7. The fetcher is down for good. Three attempts fail, the step fails, and `book_facts` and `amazon`
   proceed as today.
8. A version-1 run is still in flight at deploy. `book_facts` and `amazon` find no `goodreads` step
   and run as before.
9. A book with a human-cleared `page_range`. It stays blank, and the ledger says `human_cleared`.
10. A Goodreads genre "Literary Fiction" whose category was merged into "Literary". The book links to
    "Literary".

## 10. Left to the builder

- The search URL details, the candidate parser, and the exact study-aid shelf names (from the
  fixtures).
- Whether `SelectCandidateTask` fits or a Goodreads match task is cleaner.
- The names of the search cache table and model, and of the new services.
- How the `sourced` mode is threaded through `EnrichBook`, `BookFactsTask` and `ApplyBookFacts`,
  within §6's rules.
- The docs to update: `docs/features/enrichment-workflows.md`, `docs/features/books_enrichment.md`,
  `docs/features/goodreads-import.md` (the parser and the shared gate), and
  `docs/features/data_importers.md`.
