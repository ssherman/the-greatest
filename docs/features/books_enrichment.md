# Books AI Enrichment

Fills a `Books::Book`'s missing metadata and description from one background job, with a
web-search fallback for books the model does not know. Every run is recorded in the
`enrichments` table with per-field confidence.

Spec: `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md`.

## How a book gets enriched

1. **Trigger.** One of three entry points enqueues `Books::EnrichBookJob`:
   - `DataImporters::Books::Book::Providers::AiEnrichment`, last in the importer's provider
     chain, passing the query's author names because a new book has no `book_authors` yet.
   - The **Enrich With AI** button on the admin book page (`Actions::Admin::Books::EnrichBook`),
     with a checkbox that forces the web-search run.
   - `bin/rails books:enrich[id]` (runs inline and prints the ledger) and
     `bin/rails books:enrich_missing[limit]` (enqueues books with no ledger row and no description).
   There is deliberately no model callback: `data_migration:all` creates 157k books.
2. **Knowledge run.** `Services::Books::EnrichBook` runs
   `Services::Ai::Tasks::Books::BookFactsTask` in `knowledge` mode on the `standard` role. One
   call returns `recognized`, an overall confidence, the description, and every fact with its
   own confidence.
3. **Review.** If a description came back, `DescriptionReviewTask` (`fast` role) checks it for
   spoilers and style and rewrites it if needed; `Services::Books::DescriptionCheck` then
   strips pasted citations and rejects em dashes, URLs, the title, and runaway lengths. The
   reviewer's verdict is binding: a spoiler flag with no rewrite to fall back on is a
   `rejected` description, not a pass-through of the unreviewed text, and an empty review
   reply (no spoilers verdict at all) is `review_failed`, the same as a call that errored
   outright.
4. **Apply.** `Services::Books::ApplyBookFacts` fills blanks only: year, original language,
   word count, page range, subtitle, alternate titles (union), origin countries (only when the
   book has none), and the description as an `ai_generated` row. Book type and series are
   recorded but not applied. Nothing overwrites a value that is set, which is what protects
   human corrections. If `recognized` was false nothing is applied at all.
5. **Research fallback.** When `recognized` is false, or the overall confidence is `low`, or
   the book's year is at or past `config.x.ai.knowledge_cutoff_year` (in which case the
   knowledge call is skipped), the same task runs in `research` mode on the `research` role
   with the `web_search` tool forced. Citations land on the ledger row and the first becomes
   the description's `source_url`. `config.x.ai.research_daily_cap` bounds research runs per
   day, direct or fallback alike: a book past the knowledge cutoff with the cap already
   exhausted gets a `skipped` row and no call. Only the admin's force option bypasses the cap.

## The ledger

`Enrichment` (`enrichments`): polymorphic `enrichable`, `kind` (`books.book_facts`), `mode`
(knowledge/research), `outcome` (applied, nothing_to_apply, unrecognized, skipped, failed),
`recognized`, `confidence`, `facts` JSON, `citations`, `provider`, `model`, `ai_chat_id`,
`error`, `reason`. Each `facts` entry is `{value, confidence, applied, reason}`; reasons are
`filled`, `already_set`, `null`, `invalid`, `no_match`, `not_applied_yet`, `human_cleared`,
`unrecognized`, `rejected`, `review_failed`. `human_cleared` means the field was deliberately
blanked by an applied correction (the corrections flow accepts blanks on purpose) and the AI
value is never used to refill it. Useful queries:

```ruby
Enrichment.for_kind("books.book_facts").low_confidence_on(:word_count)
Enrichment.research.today.count                       # today's research spend, in runs
Enrichment.skipped.where(reason: "budget_exhausted")  # the research backlog
```

## Tuning

Everything is in `config/initializers/ai.rb`: the role-to-model map, the knowledge cutoff
year, and the daily research cap. The prompt rules live in `BookFactsTask#system_message`.

## Cost

Knowledge run on `gpt-6-sol`: under one cent. Review on `gpt-6-luna`: under a tenth of a cent.
Research run on `gpt-6-astra` with web search: about 15 cents (measured 2026-09-24).

## Not done here

Categories (genre, subject, location, and applying the recorded `book_type`), authors,
Goodreads, series, a ledger UI, and any catalog-wide backfill. See the spec's Non-goals.
