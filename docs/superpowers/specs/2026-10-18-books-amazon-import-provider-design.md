# Books Amazon Import Provider — Design

**Date:** 2026-10-18
**Branch:** `worktree-books-amazon-import-provider`
**Status:** draft for review

## Intent

Every new book the importer creates should be enriched from Amazon automatically: editions, covers,
affiliate links and identifiers. Today that only happens when someone runs a rake task by hand.

The Amazon pipeline itself already exists (PR #261,
`docs/superpowers/specs/2026-08-24-books-amazon-product-service-design.md`). This work does three
things:

1. wires it into the books importer, so it runs on import;
2. queues it when Goodreads-imported books are promoted;
3. adds **book-level** identifiers from Amazon, under a strict "this product is that book" rule.

**Why book-level identifiers.** The ongoing duplicate-reduction and identifier-accuracy work reads
`book.identifiers` (`books_work_*`). That covers the import finder, `Services::Books::FindDuplicates`,
the verification pass, WorldCat confirmation and the Goodreads replay. Amazon writes only
edition-level identifiers today, so none of that work can see them. The owner considers the current
editions and their identifiers unreliable legacy data; a separate, later ticket will make editions
accurate. This design does not try to fix editions.

**Why the strict rule.** Every identifier on a book is trusted by the duplicate finder and the
data-correction code. A box set's or omnibus's ISBN on a single book creates false duplicate pairs and
false merges. The owner's rule: add an identifier to the book only if the product **is that book**, and
never from a combo or omnibus edition. That is the rule the duplicate and verification code already
applies.

## Goals

- A book created through `DataImporters::Books::Book::Importer` with enrichment on gets
  `Books::AmazonProductEnrichmentJob` queued, with no human step. This includes the list wizard, so
  large end-of-year list imports enrich without per-book approval.
- A Goodreads-imported (provisional) book gets the job queued when it is promoted, the same moment it
  gets AI enrichment.
- An accepted Amazon product that passes the "is this book" check adds its ISBN-13, ISBN-10 and ASIN
  to the book, with source `amazon`.

## Non-goals

- Making editions accurate, merging the duplicate-ASIN edition groups, or changing how editions are
  written. Editions keep being written exactly as today.
- Enriching books the legacy sync created. Dev holds 1,055 books from 2026-10-02 with no enrichment of
  any kind; whether the sync goes through the importer was not checked. Separate question.
- A periodic price-refresh job like legacy's `RefreshAmazonEditionsJob`. It was never ported.
- Changing the `serial` queue, or running a backfill sweep over existing books.

## Anti-goals

These would make the work a failure even if it technically runs:

- A wrong ISBN on a book. One bad identifier is worse than a missing one, because the duplicate finder
  trusts it.
- A set, omnibus or box-set ISBN on a single book.
- Requiring approval for list-wizard books.
- Spending Amazon calls on Goodreads books that are never promoted.

## Current state (verified 2026-10-18)

- `Services::Books::AmazonProductService` runs:
  - two searches, Books and then Audible;
  - one `fast`-role AI match (`AmazonBookMatchTask`);
  - then, per accepted product, `AmazonEditionUpserter`, which writes the edition, its edition-level
    identifiers with source `amazon`, an edition `ExternalLink`, and an edition cover.
  - `after_persist` sets the book cover from the best-selling physical edition, only if the book has
    none, plus a book-level affiliate link.
- `Books::AmazonProductEnrichmentJob(book_id)` runs on `queue: :serial`, raises on failure, and stamps
  `amazon_enriched_at`.
- The importer's providers are, in order: `OpenLibrary`, `Authors`, `QueryIdentifiers` (only with
  `stamp_identifiers:`), then `AiEnrichment` and `AuthorEnrichment` (only with `enrich: true`). There
  is no Amazon provider.
- The list wizard (`Services::Lists::Wizard::Books::Adapter#create`) creates normal books:
  `provisional: false`, `enrich: true`.
  - Text rows pass `providers: TEXT_PROVIDERS = %i[authors ai_enrichment author_enrichment]`.
  - Work-key rows pass no `providers:`, so they run all providers.
- Goodreads import (`GoodreadsImports::CreateBook`) creates `provisional: true, enrich: false` books.
  `GoodreadsImports::PromoteRecords` queues `Books::EnrichBookJob` (or defers it to the author chain)
  after commit, when books are promoted.
- Enrichment from the importer was confirmed end to end on 2026-10-18 with a throwaway test running
  the wizard's `create` against the real importer:
  - a book with an existing author queues `Books::EnrichBookJob`;
  - a book with a new author records `deferred_to_authors` and queues `Books::Authors::WikidataJob`.

  The owner's earlier impression that enrichment never ran came from a local server with no Sidekiq
  process running.
- `Identifier::VERIFIED_SOURCES` is `open_library` and `worldcat`. `amazon` counts as unverified
  (`trust_rank` 2). The verification pass's `Stamp` upgrades an unverified held identifier to a
  verified source on confirmation, and never deletes one.

## Design

### 1. Importer provider

New `DataImporters::Books::Book::Providers::Amazon`, modelled on the music and games Amazon providers
and on the books `AiEnrichment` provider:

- It fails, and queues nothing, if the book has no title or is not persisted.
- It queues `::Books::AmazonProductEnrichmentJob.perform_async(book.id)` inside
  `ActiveRecord.after_all_transactions_commit`, exactly as `AiEnrichment` does. The wizard runs the
  importer inside its own transaction and rolls back authorless books, so a job queued before the
  outermost commit could run against a book that is not there yet or never will be.
- It returns `success_result(data_populated: [:amazon_enrichment_queued])`.
- It does **not** wait for the author chain. The Amazon search needs only a title and author names,
  not author facts.

**Importer wiring.** Add it to the `if @enrich` group, so `enrich: false` (Goodreads import) skips it.

**List wizard.** Add `:amazon` to `Adapter::TEXT_PROVIDERS`. Without it, text rows, the common case,
would filter the new provider out. Work-key rows get it automatically.

### 2. Goodreads promotion

In `GoodreadsImports::PromoteRecords`, queue `::Books::AmazonProductEnrichmentJob` in the existing
`after_all_transactions_commit` block for **every** promoted book. This includes books whose AI
enrichment is deferred to the author chain, for the same reason as above.

### 3. Book-level identifiers

In `Services::Books::AmazonProductService#persist_match`, after the upserter returns, write book-level
identifiers from the product, but only when the product **is this book**.

**The "is this book" check.** All of these must hold:

1. **Title.** `Services::Books::Verification::EditionCheck.title_agrees?(book, nil, amazon_edition)`
   passes. This is the verification pass's rule: equal to the book's title or an alternate title, or
   equal after dropping a subtitle from one side only, where the dropped part must not match
   `EditionCheck::SET_WORDS` (box set, collection, omnibus, trilogy, volumes, "books 1-3", "complete
   series", "7-book", …). `amazon_edition` is any object answering `title` and `subtitle`; feed it the
   **cleaned** title (the upserter's `split_title`, which strips parenthesised and bracketed packaging
   such as "(Penguin Classics)" and splits on the first colon). Do not use the edition record's
   columns: they are write-if-blank and may hold an older value.
2. **Not before the work.** `EditionCheck.year_ok?(book, amazon_publication_year)`.
2a. **No set in the brackets** *(my call; review finding)*. `split_title` strips every bracketed part,
   so "A Song of Ice and Fire (4-Book Boxed Set)" and "The Lord of the Rings (Boxed Set)" clean to
   exactly the book's title and would pass check 1. `AmazonBookMatchTask` does not exclude box sets
   either. So, before cleaning, look at each bracketed part of the **raw** Amazon title. If any part
   matches `EditionCheck::SET_WORDS`, the product fails. The exception is a part that names one
   numbered book: `Book 3`, `#3`, `Vol. 3`, `Volume 3`, a single number with no range after it. That
   exception is needed because Amazon writes series markers like "(Hunger Games Trilogy, Book 1)",
   where "Trilogy" names the series, not the edition. The product also fails when its binding display
   value contains "box" (Boxed Set / Box Set). This is the same idea as
   `ConfirmWithWorldCat#listed_by_open_library?`, which applies `SET_WORDS` to the whole title rather
   than only to a dropped subtitle.
3. **Author** *(my call; `EditionCheck` itself has no author test)*. At least one of the product's
   `byLineInfo.contributors` whose role is `Author` agrees with one of the book's authors, compared the
   way `Services::Books::Verification::Check.authors_agree?` compares names: shared normalized name, or
   shared compact name, against the authors' names and alternate names. No author contributor on the
   product means the check fails. This closes the known residual where two different same-titled works
   ("Selected Poems") pass on title alone. A false failure only costs a missing identifier.

`Check.authors_agree?` takes a work object. Calling it with a small adapter (`author_names:`,
`author_keys: []`) is fine, as is extracting its name comparison. Builder's choice, as long as there is
one comparison, not a copy.

**What gets written**, all with `source: :amazon`, through `book.identifiers.find_or_initialize_by`
(never `build`). The source is set only on a new row and never changes an existing row's source:

| Amazon field | Book identifier |
| --- | --- |
| `asin` | `books_work_asin` |
| `externalIds.isbns`, 13 digits | `books_work_isbn13` |
| `externalIds.isbns`, 10 digits | `books_work_isbn10` |
| `externalIds.eans` starting 978/979 | `books_work_isbn13` (an EAN with that prefix *is* the ISBN-13) |
| any other EAN | not written to the book (*my call*; non-ISBN EANs on books are rare and nothing reads `books_work_ean13`) |

Normalize ISBNs through `Books::Isbn` (`app/lib/books/isbn.rb`) before writing.

**Another book already holds a value** *(my call, following `Verification::Stamp`)*:

- If **any** of the product's values is held by another book with a **verified** source
  (`open_library`/`worldcat`), write **none** of that product's values to this book. A verified
  holder elsewhere is strong evidence of one of two things: the product is the other book (a
  same-titled work that got past the checks), or this book is a duplicate of the other one. The
  decision is per product, not per value.
- **Record the pair as a suspected duplicate** *(the owner's ask)*. Call
  `Services::DuplicateCandidates::Flag` with `item_type: "Books::Book"`, `ids: [book.id, holder.id]`
  and `source: :identifier_collision`. The evidence should name the Amazon ASIN, the product title,
  and each conflicting `identifier_type`/`value` with its holder and the holder's source. That puts the
  pair on the existing admin duplicates page. `Flag` already orders the ids, never reopens a pair a
  human dismissed or merged, and adds an occurrence and evidence to a pair that is still pending, so a
  re-run is safe. Flag once per holder book. Flagging only skips the identifier write; the edition,
  cover and links for the product are written as usual. A `Flag` failure is logged and appended to
  `@errors`, like any other book-level failure.
- If the other holders' rows are unverified (`legacy`, `amazon`, `goodreads_import`, nil), write
  anyway, so `FindDuplicates` can surface the pair.

**Timing against AI enrichment** *(my call; review finding)*. The Amazon job is queued at the same
moment as `EnrichBookJob`, and for a book deferred to new authors, well before AI enrichment runs. Two
inputs to the check, `first_published_year` and `alternate_titles`, are often filled by AI enrichment.
For a text-row wizard book they may still be blank when Amazon runs. The effects:

- a nil year makes `year_ok?` pass, so the year guard does nothing for that run;
- an alternate-title match (a translation) is missed, which only costs an identifier.

This is accepted rather than chaining Amazon behind AI enrichment and the author chain. The title,
set-word and author checks still apply, and they carry the precision. A later re-run of
`books:amazon_enrich` picks up the filled year and alternate titles.

**Failure isolation.** A failure writing a book-level identifier is logged and appended to the
service's `@errors`, like `attach_book_affiliate_link`. It must not fail the run or roll back the
edition.

Because this sits in the service, the existing rake entry points (`books:amazon_enrich`,
`books:amazon_enrich_ranked`) also write book-level identifiers from now on. That is intended.

### 4. Docs

- `docs/features/data_importers.md`: add Amazon to the Books row of the providers table, and add a
  "Books Providers → Amazon (Async)" section covering queue-after-commit, the `enrich:` gate, and the
  wizard's `TEXT_PROVIDERS`.
- `docs/features/goodreads-import.md`: promotion now queues Amazon.
- Wherever the books Amazon service is described (the 2026-08-24 spec is archived history; put the
  living description in `data_importers.md` or a books feature doc): add the book-level identifier
  rule.

## Testing

- **Provider:**
  - queues after commit;
  - queues nothing when the surrounding transaction rolls back;
  - fails without a title or when not persisted.
- **Importer:**
  - runs the provider with `enrich: true`;
  - leaves it out with `enrich: false`;
  - `providers: [:amazon]` selects it.
- **Wizard:** `TEXT_PROVIDERS` includes `:amazon`. One test runs `Adapter#create` for a text row
  against the **real** importer under `Sidekiq::Testing.fake!` and asserts both `EnrichBookJob` and
  `AmazonProductEnrichmentJob` are queued. Nothing today proves the wizard queues anything; the
  existing test only checks the `enrich: true` keyword against a mocked importer.
- **Promotion:** every promoted book queues the Amazon job, including a book deferred to its authors.
- **Book-level identifiers:** each rule gets a paired test, one where it writes and one where it
  doesn't. Delete each guard and confirm its test goes red (see the 2026-08-24 spec on fill-if-blank
  tests passing against deleted code). Cases:
  - exact title;
  - "Title: A Novel" against book "Title";
  - "Title (Penguin Classics)";
  - a set-word subtitle ("Books 1-7 Box Set");
  - a set word only inside brackets ("The Lord of the Rings (Boxed Set)", "(4-Book Boxed Set)"),
    not written;
  - a single-book series marker ("(Hunger Games Trilogy, Book 1)"), written;
  - a "Boxed Set" binding, not written;
  - one value held verified elsewhere, so none of the product's values is written and a pending
    `identifier_collision` `DuplicateCandidate` is raised for the pair; a re-run adds an occurrence,
    not a second row; a pair already marked `not_duplicate` is left alone;
  - an omnibus whose full title differs;
  - a year before first publication;
  - author mismatch;
  - no Author contributor;
  - an alternate-title match;
  - an EAN 978 folding into isbn13;
  - a non-978 EAN not written;
  - ISBN-10 kept as isbn10;
  - another book holding the value with a verified source (not written);
  - another book holding it with an unverified source (written);
  - re-running the same product (no duplicate rows, existing source unchanged);
  - an identifier write failure (run still succeeds, error reported).
- Stub `Services::Amazon::Client.search_items` and the AI task with Mocha; never hit the network.
- Root-anchor `::Books::…` inside `Services::Books` and its tests (nested-namespace shadowing).
- No new user-facing page, so no Playwright test.
- Full gate: `bin/rails test`, `bundle exec standardrb`.

## Operational notes

- A large list import queues one Amazon job per new book onto the shared `serial` queue: two Amazon
  calls, one `fast` AI call and several image downloads each, roughly 5–15 seconds. That was accepted
  in the 2026-08-24 design and is not changed here.
- **Bulk Goodreads approvals queue Amazon too** (owner, 2026-10-18). This covers the admin's
  `bulk_approve` and the legacy replay's final pass. They can put thousands of jobs on `serial` at
  once, and each one holds the queue for its 5–15 seconds. That delays cover-art and music jobs for
  hours or days but corrupts nothing. There is no special case, flag or throttle for bulk paths.
- **Follow-up ticket, not this one: take Amazon off `serial`.** The owner questions whether Amazon
  belongs on the one-at-a-time queue at all. The preferred direction is to catch Amazon's rate-limit
  errors and reschedule the job with backoff, instead of serializing everything. Two things that
  ticket must do first:
  - Add a per-book lock (for example a transaction-scoped `pg_advisory_xact_lock` on the book id, as
    `Books::MigrateCoverImageJob` does) around the Amazon service. `AmazonEditionUpserter#find_edition`
    takes no lock, and the `identifiers` unique index is per identifiable, so today `serial` is the
    only thing stopping two concurrent jobs for one book from both creating the same edition, and
    from both writing the same book-level identifier.
  - Find out what the Creators API actually returns when a request is throttled, so the reschedule
    catches that response and not every error.
- Locally, Amazon and AI enrichment only happen with a Sidekiq process running. `bin/rails server`
  alone queues jobs into Redis and nothing runs them.
- Production: nothing to run. The change applies to books created after deploy.

## Left to the builder

- Provider position inside the `@enrich` group. All three async providers only queue, so order does
  not change behavior.
- Whether the "is this book" check lives in its own small module (for example
  `Services::Books::AmazonBookCheck`) or as private methods on the service. A module is easier to test
  in isolation.
- The exact log wording.
