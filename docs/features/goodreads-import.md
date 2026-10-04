# Goodreads import

Members will upload their Goodreads library export and get their shelves, dates, ratings and
reviews on the books site. The legacy app had this feature and it produced most of the legacy
catalog's bad data; this one is built so that it cannot. Spec:
`docs/superpowers/specs/2026-10-03-goodreads-import-design.md`.

## Status

| Increment | What | State |
|---|---|---|
| 1 | Optional review ratings | shipped |
| 2 | Provisional books and authors (`docs/features/books-provisional-records.md`) | shipped |
| 3 | Resolver core: parsing, tables, edition resolution, dry run | this doc |
| 4 | Goodreads page fetcher and verification | not started |
| 5 | Legacy replay | not started |
| 6 | Member upload, library write, admin approval | not started |
| 7 | Finishing failed legacy imports | not started |

Nothing in production calls the resolver yet. The only entry point is the dry-run rake.

## Parsing

`Books::Goodreads::ExportFile.parse(bytes)` decodes the file (BOM stripped; Windows-1252 when the
bytes are not UTF-8; scrubbed when they are neither), parses it with liberal quoting, and refuses
it unless the `Book Id`, `Title`, `Author` and `Exclusive Shelf` headers are present. It never
refuses a row.

`Books::Goodreads::ExportRow` reads one row by header name:

- The Goodreads id is the leading digits of whatever form it arrives in (`Books::GoodreadsId`).
- ISBNs are checksum-validated and converted both ways (`Books::Isbn`, the Rails twin of
  `data-sources/src/common/normalize.py`). An invalid ISBN is dropped.
- The title is kept whole. Only a trailing `(Series Name, #N)` is split off into
  `series_name`/`series_number`.
- Only the primary `Author` is an author. `Additional Authors` is passed to the matching AI as
  context, because Goodreads mixes translators and illustrators into it.
- A value that does not parse is dropped and recorded in the row's `notes`.
- `Private Notes` is never stored.

## Data model

- `books_goodreads_imports`: one per upload. A partial unique index allows one import in progress
  per user.
- `books_goodreads_editions`: the unit that is resolved, keyed by Goodreads id plus signature
  (digest of the normalized, series-stripped title and primary author). An edition is shared by
  every import that names it. A row claiming a real id under another title gets its own edition.
  `book_id` is nullified if the book is deleted; the book merger moves editions. Goodreads'
  "Binding" is stored as `book_format` (`binding` collides with `Kernel#binding`).
- `books_goodreads_import_rows`: one per CSV row, with the user's fields, `notes`, and later the
  ids it wrote.
- `books_goodreads_import_records`: provenance. Every book, author, book_author and identifier an
  import created.

Editions reference `books_books`, so truncating books for a migration pass empties them too. That
is intended: the replay rebuilds them.

## Resolution

`Services::Books::GoodreadsImports::ResolveImport` resolves each distinct edition once, through
`ResolveEdition`:

1. **Cache.** An edition already resolved to a book that exists is reused.
2. **Finder.** The full books finder (identifiers, exact, OpenSearch, Open Library, AI), with the
   edition as the match decision's subject. The finder does not filter provisional books, so a
   later import links to an earlier import's provisional book instead of making another.
3. **Outcome.** A match links. The finder flags medium, low and fallback decisions. No match
   creates a provisional book through `CreateBook`. An AI "none of these" creates too, and is
   flagged. Nothing falls back to the top search hit.

`CreateBook` holds `pg_advisory_xact_lock` on the edition's signature, re-reads the edition, adopts
a book that a same-signature edition created since the finder looked (never one the finder already
considered), and otherwise creates through `DataImporters::Books::Book::Importer` with:

- `match:` the finder's match, so the finder and the AI run once;
- `provisional: true`, for the book and any author it creates;
- `stamp_identifiers: true`, so the edition's Goodreads id and ISBNs are on the book even when Open
  Library is down;
- `enrich: false`, because enrichment runs on admin approval (increment 6).

Every creation is `verification: unverified` until increment 4 adds the Goodreads fetch.

Counters (`matched`, `created`, `flagged`, `parked`) are recomputed from state after each run, so a
retry is safe. `ai_calls_count` counts calls as they happen. Matching AI is not capped. A failing
edition records its error on its rows and stays unresolved for the next run; Postgres errors
re-raise.

## Dry run

    bin/rails "books:goodreads:resolve_file[/path/to/goodreads_library_export.csv]"
    bin/rails "books:goodreads:resolve_file[/path/to/export.csv,USER_ID]"

Parses and resolves the file exactly as an import would, prints one line per edition (matched book,
created book, flagged reason, failed sources) and rolls everything back. Open Library requests and
matching AI calls are real and are paid for. To reach the deployed Open Library service,
`web-app/.env` needs `OPEN_LIBRARY_SERVICE_URL` and the Cloudflare Access pair
(`CLOUDFLARE_ACCESS_CLIENT_ID`, `CLOUDFLARE_ACCESS_CLIENT_SECRET`); without them every decision
carries "sources failed: open_library" and is capped at medium confidence.
