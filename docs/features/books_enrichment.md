# Books AI Enrichment

Fills a `Books::Book`'s missing metadata and description from one background job, with a
web-search fallback for books the model does not know. Every run is recorded in the
`enrichments` table with per-field confidence.

Spec: `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md`.

## How a book gets enriched

1. **Trigger.** `Services::Books::EnrichBook` runs from the `book_facts` step of a
   `books.book_enrichment` workflow run (`Workflows::Books::Steps::BookFacts`; see
   `docs/features/enrichment-workflows.md`), or directly from the places that still call
   `Books::EnrichBookJob`. Entry points:
   - `DataImporters::Books::Book::Providers::Enrichment`, last in the importer's provider chain
     (after `OpenLibrary`, `Authors` and, when asked for, `QueryIdentifiers`), runs when `enrich:`
     is true. It plans one book run (`Workflows::Books::BookEnrichment.start`), passing the linked
     authors' names, and falling back to the query's author names only when the book still has
     none. When the import created one of the book's linked authors, `book_facts` waits for that
     author's `author_facts` step, so the book's origin country can come from the author's stored
     nationality. The list wizard's text rows plan the same run.
   - `Services::Books::GoodreadsImports::PromoteRecords`, when an admin approves a Goodreads
     import: a book run per promoted book, waiting on the author runs of the authors promoted with
     it. Member imports themselves run with `enrich: false` and plan nothing.
   - The **Enrich With AI** button on the admin book page (`Actions::Admin::Books::EnrichBook`),
     with a checkbox that forces the web-search run. It still queues `Books::EnrichBookJob`
     and creates no run.
   - `bin/rails books:enrich[id]` (runs inline and prints the ledger) and
     `bin/rails books:enrich_missing[limit]` (enqueues `EnrichBookJob` for books with no ledger
     row and no description, plus any book whose only rows are `deferred_to_authors` deferrals,
     described or not; those deferrals are no longer written by new imports).
   There is deliberately no model callback: `data_migration:all` creates 157k books.
2. **Knowledge run.** `Services::Books::EnrichBook` runs
   `Services::Ai::Tasks::Books::BookFactsTask` in `knowledge` mode on the `standard` role. One
   call returns `recognized`, an overall confidence, the description, and every fact with its
   own confidence. The prompt carries one line per stored author, from what we hold: `Author:
   Ernest Hemingway (1899–1961; American)`. An editor (`book_authors.role` `editor`) gets
   `Editor: <name>` with no years or countries, so an anthology's origin is never read from its
   editor.
3. **Review.** If a description came back, and the book does not already have an
   `ai_generated` description (123k of 158k production books carry a legacy one, and the
   applier would record `already_set` regardless, so the review call is skipped), then
   `DescriptionReviewTask` (`fast` role) checks it for spoilers and style and rewrites it if
   needed; `Services::Books::DescriptionCheck` then strips pasted citations and rejects em
   dashes, URLs, and runaway lengths. Whether the text names the title or author is left to the
   reviewer's judgment: a string match cannot tell the title *Emma* from the character Emma, and
   17k books have one-word titles. The reviewer's verdict is binding: a spoiler flag, or any
   style violation, with no rewrite to fall back on is a `rejected` description, not a
   pass-through of the text the reviewer objected to; an empty review reply (no spoilers
   verdict at all) is `review_failed`, the same as a call that errored outright.
4. **Apply.** `Services::Books::ApplyBookFacts` fills blanks only: year, original language,
   word count, page range, subtitle, alternate titles (union), and origin countries (only when
   the book has none). Book type and series are recorded but not applied. Nothing overwrites a
   value that is set, which is what protects human corrections. If `recognized` was false
   nothing is applied at all. If the knowledge run was recognized but `low` confidence and the
   research run is about to follow, nothing is applied either (facts recorded as `deferred`,
   no review call spent): applying the guess first would leave research able only to fill
   blanks. With the budget exhausted, the low-confidence facts are applied as the best
   available. The description is written as an `ai_generated` row when the book
   has none from that source. That row outranks Goodreads, Wikipedia and Open Library text in
   the display resolver, so it becomes the displayed description unless a `manual` or preferred
   row exists.
5. **Sourced mode (a Goodreads page).** When the `goodreads` step matched, `book_facts` runs the same
   task once in `sourced` mode on the `standard` role, with the cached `Books::GoodreadsPage` (named by
   the step's `page_id`) as source material, and it never runs research: no web search is spent on a
   book Goodreads already described, and a book past the knowledge cutoff gets the same path. A low
   confidence answer is applied rather than deferred, and an unrecognized one is recorded and ends the
   run. The page's description is publisher copy: it is shown to the model as material and never written
   to `descriptions`. The model writes its own words, and `DescriptionCheck` rejects any description
   that copies 8 consecutive words from the page (the title and author names are exempt). Without a
   page (a version 1 run, a miss, a skipped step, the admin button, the rake tasks) the run is the
   knowledge-then-research flow above. The admin force-research option still researches.
6. **Research fallback.** When `recognized` is false, or the overall confidence is `low`, or
   the book's year is at or past `config.x.ai.knowledge_cutoff_year` (in which case the
   knowledge call is skipped), the same task runs in `research` mode on the `research` role
   with the `web_search` tool forced. Citations land on the ledger row and the first becomes
   the description's `source_url`. `config.x.ai.research_daily_cap` bounds research runs per
   day, direct or fallback alike: a book past the knowledge cutoff with the cap already
   exhausted gets a `skipped` row and no call. Only the admin's force option bypasses the cap.

## The ledger

`Enrichment` (`enrichments`): polymorphic `enrichable`, `kind` (`books.book_facts` or `books.goodreads`), `mode`
(knowledge/research/sourced), `outcome` (applied, nothing_to_apply, unrecognized, skipped, failed),
`recognized`, `confidence`, `facts` JSON, `citations`, `provider`, `model`, `ai_chat_id`,
`error`, `reason`. Each `facts` entry is `{value, confidence, applied, reason}` (`origin_countries`
also carries `unmatched`, and `description` carries `review`); reasons are `filled`,
`already_set`, `null`, `invalid`, `no_match`, `not_applied_yet`, `human_cleared`, `unrecognized`,
`rejected`, `review_failed`, `deferred`. `deferred` means a low-confidence knowledge answer was
recorded but left for the research run to verify. `human_cleared` means the field was deliberately blanked by an
applied correction (the corrections flow accepts blanks on purpose) and the AI value is never
used to refill it. Useful queries:

```ruby
Enrichment.for_kind("books.book_facts").low_confidence_on(:word_count)
Enrichment.research.today.count  # research rows today, including budget skips; this is what the cap checks
Enrichment.research.today.where.not(outcome: :skipped).count  # research calls actually made today
Enrichment.skipped.where(reason: "budget_exhausted")  # the research backlog
```

### The `books.goodreads` kind

The `goodreads` step writes one row per run, from `Services::Books::GoodreadsEnrichment::Apply` (a match)
or `Ledger` (a miss). It has no mode, model or AI chat. `facts` has an entry per field, each
`{value, applied, reason}`: `first_published_year` and `page_range` (`filled`, `already_set`, `null`,
`human_cleared`, and `format_not_paged` for audio and e-book formats), `genres` (matched entries linked
as `CategoryItem`s with source `goodreads`, and `unmatched` names, since a category is never created),
the series (`created` or `linked`, found by the Goodreads series id), and the identifiers. A miss is an
`unrecognized` row with reason `no_match` or `rejected`. Applying the same page again records
`nothing_to_apply`, which is what lets a later backfill re-run it safely. The ISBN-13 it writes (source
`goodreads`, checksum-valid, and not held by another book from a verified source) is what the Amazon step
searches by first.

## Tuning

Everything is in `config/initializers/ai.rb`: the role-to-model map, the knowledge cutoff
year, and the daily research cap. The prompt rules live in `BookFactsTask#system_message`.

## Cost

Knowledge run on `gpt-6-sol`: under one cent. Review on `gpt-6-luna`: under a tenth of a cent.
Research run on `gpt-6-astra` with web search: about 15 cents (measured 2026-09-24).

## Not done here

Categories (genre, subject, location, and applying the recorded `book_type`), authors,
Goodreads, series, a ledger UI, and any catalog-wide backfill. See the spec's Non-goals.
