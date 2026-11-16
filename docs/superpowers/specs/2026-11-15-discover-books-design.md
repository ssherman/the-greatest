# Discover books: advanced book search on the public API and MCP

## Why

Shane's marketing agent builds social media content and needs to find books to feature with
queries like "a random 10 long Russian novels ranked 200–1,000, published 1850–1900". Paid members
with API or MCP access should be able to run the same queries.

Today the public MCP (`/api/mcp`) can't do that:

- `list_books` filters by categories (all of them, at most 6), country, a published year or range
  and a collection.
  - It returns ranked books only, best first.
  - It has no length, language or exclusion filters and no other order.
- `search_books` is text only.

The admin MCP is a separate endpoint that serves only the admin document. An admin token also
holds `books:read`, so the marketing agent connects to `/api/mcp` as well. This feature belongs
there, on the public side.

The saved-search engine already does nearly all of this. `Books::SavedSearchQuery`,
`Search::Books::Search::BookAdvanced` and `CriteriaClauses` cover:

- categories to include or exclude, matching any or all of them;
- countries and original languages, to include or exclude;
- length;
- a first-published range;
- ranked only or unranked only;
- a rank ceiling;
- hiding the books a user has read.

None of it saves anything: `SavedSearchQuery.call(criteria:, owner:)` takes a plain criteria hash.

## Goals

- **One endpoint and tool:** `GET /api/v1/books/discover`, MCP tool `discover_books`, scope
  `books:read`. It exposes every filter above plus:
  - an `order` of `rank` (the default) or `random`;
  - a rank range (`rank_min`, `rank_max`).
- **A language lookup:** `GET /api/v1/languages`, MCP tool `list_languages`, so a model never
  guesses a language slug. It mirrors `list_countries`.
- **One engine:** the API and the saved searches run the same engine, so a criterion means the same
  thing in both.

## Non-goals

- **No saving.** The API never creates or reads `saved_searches` rows.
- **No change to `list_books`, `search_books`, saved searches or the site's pages.** `list_books`'
  description gains one pointer to `discover_books`.
- **No ISO codes.** `languages.iso_639_1` and `iso_639_3` are empty on all 220 rows, and
  `books_countries` has no ISO column. Languages are addressed by slug (`russian`,
  `ancient-greek`), like countries and categories. Filling the ISO codes is separate work.
- **No other ranking configurations.** The index carries only the default primary's
  `ranked_position`, so ranks and rank filters are the primary ranking's, as on saved searches.
- **No admin version.** The engine always excludes provisional books.
- **No ordering by publication year.**

## Anti-goals

- **A filter that is sent but can't be resolved must never widen the result.** An unknown slug is
  an error, never "unfiltered". This rule already holds for `list_books` and for the saved-search
  criteria.
- **A random page must not repeat or skip books** while the client pages through one shuffle.
- **The page and its count must agree.** Every filter runs in OpenSearch; nothing removes rows from
  a page after the count.

## Approaches considered

- **A. A new endpoint and tool on the existing engine (chosen).**
  - It takes every saved-search filter, plus `order`, `rank_min`, `rank_max` and `seed`.
  - Slugs for categories, countries and languages.
  - Results in the same book shape `list_books` returns.
  - `list_books` is untouched.
- **B. Grow `list_books`.**
  - `list_books` reads ranked books from the database, so it can't return unranked books.
  - It would need moving onto OpenSearch, or two engines behind one tool.
  - It would change how a tool people already use behaves.
- **C. A saved-searches API** (create, then run).
  - Shane ruled out the saving step.
  - It takes two calls where one would do.

Shane picked A, with `order` = `rank` | `random`, and a rank range as a filter that combines with
either order.

## Design

### `GET /api/v1/books/discover` (`discoverBooks`, tool `discover_books`)

**Parameters.** Every one is optional, and with none the endpoint returns the whole catalogue in
rank order.

| Parameter | Meaning |
|---|---|
| `category_id` | Comma-separated category slugs, up to 6. Merged and renamed slugs resolve, as in `list_books` (`Books::CategorySlugResolver` / `Books::FilterParams`). |
| `category_match` | `all` (default: a book must carry every category) or `any`. Only valid when `category_id` is sent. |
| `exclude_category_id` | Comma-separated slugs, up to 6. A book carrying any of them is left out. |
| `country_id` | Comma-separated country slugs, up to 10. A book from any of them matches. |
| `exclude_country_id` | Comma-separated country slugs, up to 10. |
| `language` | Comma-separated language slugs, up to 10, matched against the book's original language. A book in any of them matches. |
| `exclude_language` | Comma-separated language slugs, up to 10. |
| `length` | Comma-separated values from `very_short, short, medium, moderate, long, very_long`. A book of any of them matches. A book with no length never matches a `length` filter. |
| `year` | First published in this year. It can't be combined with `published_start` / `published_end`. |
| `published_start`, `published_end` | First published in or after / in or before this year (inclusive). Same rules and bounds as `list_books`. |
| `ranked` | `all` (default), `ranked` or `unranked`. |
| `rank_min`, `rank_max` | Positive integers on the primary ranking, inclusive. Either one implies ranked only. |
| `order` | `rank` (default) or `random`. |
| `seed` | A positive integer, valid only with `order=random`. The same seed gives the same shuffle. |
| `hide_read` | `true` leaves out the books the token's user has on their read list (the saved searches' `hide_read`). Default false. |
| `page`, `per_page` | The standard paging parameters. |

**Defaults deliberately differ from saved searches.** `category_match` defaults to `all`, matching
`list_books`; the saved-search form defaults to `any`. The API translator always writes
`genre_match_mode` explicitly, so the engine's default never applies.

**400s** (`Api::Page::InvalidParameter`). Any of these is a 400:

- a blank value, or an array or hash where a single value is expected, as `Api::RankedBookFilters`
  enforces;
- more slugs than the limit;
- an unknown `length`, `ranked`, `order` or `category_match` value;
- `category_match` without `category_id`;
- `year` together with a range;
- `rank_min` greater than `rank_max`;
- `rank_min` or `rank_max` with `ranked=unranked`;
- `seed` without `order=random`, or a `seed` that isn't a positive integer;
- a `hide_read` that isn't `true` or `false`;
- a slug that is both included and excluded.

**Unknown slugs.** A category, country or language slug that names nothing raises
`Api::UnknownFilter`, which renders the same problem response `list_books` already gives.

**Order.**

- `rank`: `BookAdvanced::SORT`. Ranked books in rank order first, then unranked books by
  publication year, then title, then `_id`.
- `random`: the bool query is wrapped in a `function_score` with
  `random_score: {seed:, field: "_seq_no"}` and `boost_mode: replace`, sorted by `_score`, then
  `_id`.
  - **No seed sent:** the server picks one (`SecureRandom.random_number(2**31 - 1) + 1`).
  - **Seed in the reply:** it is returned in `meta.seed` and carried in every `links` URL, so
    page 2 continues the same shuffle.
  - **Known limit:** a book reindexed between two pages gets a new `_seq_no`, so its place in
    the shuffle changes. That can happen after the ranked-fields reindex that follows a ranking
    refresh, and it is accepted.

**Paging and counts.**

- **The 10,000-result window:** OpenSearch serves at most 10,000 results deep
  (`BookAdvanced::MAX_RESULT_WINDOW`). Claude's call, from the builder check:
  - **`meta.total_count` stays exact.**
  - **`meta.total_pages`, `links.last` and `links.next` stop at the last reachable page,**
    `ceil(10,000 / per_page)`. A client following `next` never reaches a page the server
    refuses.
  - **How it's built:** `Api::Page` gains an optional `max_page:`, default nil, so every other
    endpoint is unchanged.
  - **The last reachable page can be short.** When `per_page` doesn't divide 10,000, that page
    is clamped short, as `BookAdvanced` already does. Its metadata says it is the last page, so
    page and count still agree.
  - **Any page after it is a 400** telling the client to narrow its filters. That's better than
    an empty 200, which would look like the end of the results.
- **Exact counts:** the query sets `track_total_hits: true`, so `meta.total_count` is exact and
  never the lower bound that saved searches show as "10,000+".
- **Built from the engine's result:** the paging metadata and `links` come from that total, the
  page and `per_page`, not from a relation `count`. The engine returns an array, hydrated in
  OpenSearch's order.

**Response.**

- **Shape:** the public `BookCollection` with the `Book` shape (`rank` is the primary rank, or null).
  Each book is built with `BookResource.new(book, params: {rank: book.ranked_position})` from
  `SavedSearchQuery`'s hydrated rows.
- **`meta.filters`:** echoes the canonical filters that were applied (sorted slugs), as
  `list_books` does.
- **`meta.order`** and, for random, **`meta.seed`**.

**Errors from the index.** The controller includes `Api::SearchBacked`, so an OpenSearch outage is
the documented 503 `search_unavailable`.

**Description for the model (`x-mcp`).** It says:

- when to use it instead of `list_books` (any length, language or exclusion filter, unranked
  books, a rank range, random order);
- to find slugs with `search_categories`, `list_countries` and `list_languages`;
- to pass `meta.seed` back when paging a random order;
- that `rank` null means unranked.

### `GET /api/v1/languages` (`listLanguages`, tool `list_languages`)

- **What it lists:** every language that is the original language of at least one catalogue book
  (`Books::Book.catalog`), with `id`, `slug`, `name` and `book_count` (catalogue books in that
  language).
- **`sort`:** `book_count` (most first, the default) or `name`; any other value is a 400.
- **Paging:** standard, as `list_countries` does it. 220 rows fit in 3 pages at 100.
- **Response schema:** `LanguageCollection`, with `Language` (`id, slug, name, book_count`).
- **Description for the model:** "use it to find the slugs `language` and `exclude_language`
  accept in discover_books".

### The engine

The engine stays where it is.

- **No renames.** `Books::SavedSearchCriteria`, `Books::SavedSearchQuery` and `BookAdvanced` already
  take a plain hash and save nothing. Renaming them would touch saved searches and the recommender
  for no behaviour change. This is Claude's call.
- **New in the engine:**
  - `SavedSearchCriteria#min_ranked_position`. `CriteriaClauses.filter_clauses` turns it into a
    `gte` on `ranked_position`, next to the existing `max_ranked_position` `lte`. With either set
    the clause is a range on that field, so unranked books (no `ranked_position`) are excluded.
  - `BookAdvanced.call` and `build_query_definition` gain `order: :rank` and `seed: nil`, plus a
    `track_total_hits:` flag (default false, so saved searches are unchanged).
  - `SavedSearchQuery.call` passes all three through.
- **The translator:** `Api::DiscoverBookFilters`, under `app/lib/api/` next to
  `Api::RankedBookFilters`. It turns the API parameters into the criteria hash: ids,
  `genre_match_mode`, the year bounds, `ranked`, the rank bounds, `book_length` integers and
  `hide_read`. It returns that hash with `applied`, `order` and `seed`.
  - It reuses `Books::FilterParams` for category and country slug resolution, so merged and
    renamed slugs behave as in `list_books`.
  - Language slugs resolve with `Language.find_by(slug:)`.
- **`hide_read`:** the owner passed to `SavedSearchQuery` is the token's user
  (`current_principal.user`, from `Api::Authentication`), so a member hides what they have read.

### Documentation and pins

- **Feature docs:** `docs/features/public-api.md` and `docs/features/mcp-server.md` describe both
  tools. `docs/features/saved_searches.md` notes that the API shares the engine and adds
  `min_ranked_position`, `order` and `track_total_hits`.
- **`config/mcp/books/instructions.md`:** add `discover_books` to the order rules (rank order, or
  random), and `list_languages` next to `list_countries` for slugs.
- **`/developers`:** it lists the new tools by itself, through `Mcp::ToolDirectory`.
- **Count and path pins:** update the tool directory's public count, the public catalogue test, the
  OpenAPI paths list, `contract_coverage_test.rb` (every documented status of both operations)
  and `operation_scope_contract_test`.

## Testing

- **Unit tests:**
  - `Api::DiscoverBookFilters`: every 400 above; unknown slugs; merged category slugs; the
    applied echo.
  - `CriteriaClauses` for `min_ranked_position`.
  - `BookAdvanced.build_query_definition` for random order (the `function_score` shape, the seed,
    `_score` then `_id` sort) and `track_total_hits`.
- **Controller tests:**
  - Status codes, paging metadata and links carrying the seed.
  - The same seed returns the same page twice.
  - `hide_read` drops a book on the user's read list.
  - The 503.

  OpenSearch is stubbed where the existing search controller tests stub it.
- **Language list:** controller tests for sort and paging.
- **MCP:** a test calls `discover_books` through `/api/mcp`.
- **No E2E:** there is no new page.

## Collections

`discover_books` adds no `book_kind` filter, so it returns whatever the saved-search engine does,
collections included. `search_books` returns standalone books only. Claude's call, from the builder
check, for two reasons:

- **There are none today.** The catalogue (`Books::Book.catalog`, measured on the dev DB on
  2026-11-15) holds 161,280 books and 0 collections.
- **Saved searches would change.** A `book_kind` clause in the engine would change them unless it
  were made API-only.

If collections get marked later and turn out to crowd the results, an API-only `book_kind`
parameter can be added then. `list_languages`' `book_count` counts the same `catalog` rows.

## Left to the builder

- Exact problem-detail wording, provided each 400 names the parameter.
- Whether the seed-in-links handling lives in the translator's `applied` hash or in the controller.

## Known gaps

- **`list_countries` lists only countries with ranked books.** A country whose books are all
  unranked has no listed slug, though `discover_books` accepts its slug. Its slug is its
  lowercased, hyphenated name.
- **Rank filters and `rank` are the default primary ranking's only.**
