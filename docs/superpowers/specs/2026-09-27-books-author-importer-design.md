# Books author importer and enrichment — design

**Date:** 2026-09-27 · **Branch:** `worktree-books-author-importer`
**Status:** approved in brainstorming section by section; awaiting review of this written spec
**Related:** `docs/superpowers/specs/2026-09-22-import-finder-redesign-design.md` (§9 Authors is
increment 1 here), `docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md`,
`docs/superpowers/specs/2026-08-30-viaf-api-client-design.md`,
`docs/features/data_importers.md`, `docs/features/open-library-data-service.md`,
`docs/features/import-finder.md`, `docs/features/books_enrichment.md`

## Goal

Build the books author importer so the book importer can create and reuse authors, and give a
newly imported author the data a person would look up by hand: birth and death years, gender,
nationality, a description, and the identifiers that tie it to the rest of the world's catalogs.
Do it with sources that are trustworthy about identity, and never repeat the legacy app's habit of
attaching the wrong Wikipedia page.

Success:

- A book import creates or reuses the right `Books::Author` rows and links them through
  `book_authors`, so a title-plus-author re-import is idempotent.
- A newly created author is resolved to a Wikidata person (or explicitly to none), and ends up with
  identifiers (Wikidata, VIAF, ISNI, LC, Open Library, Goodreads, LibraryThing), years, gender,
  countries, alternate names, a Wikipedia link, and a house-style AI description, with no human in
  the loop. Every value is traceable to the run that wrote it.
- No text search of Wikipedia anywhere. A Wikipedia article is used only when it is the English
  article of a Wikidata item already confirmed to be this author.
- Every choice of an external record is a recorded decision, visible in the existing audit pages,
  and a person can reject a wrong one; a rejected link is undone and never re-created.
- The full response from every external call is kept, so later work can use more of it without
  calling the API again.
- A book whose authors were created by the same import gets its origin country from those authors'
  stored nationalities, not from the model's memory alone.

## Problem

### What exists

- **No author importer.** `app/lib/data_importers/books/` holds only `book/`, and
  `DataImporters::FinderRegistry` has no `Books::Author` entry. The import-finder redesign designed
  one (its §9, increment 4) and it was never built.
- **The book importer never creates authors.** Its Open Library provider deliberately leaves
  authors alone; the AI enrichment passes `author_names` through the job for that reason.
- **Open Library is thin on authors, and not in production.** The distilled artifact keeps only
  name, alternate names and integer years (`data-sources/src/openlibrary/pipeline/authors.py`); the
  API has no author name search. The service is not deployed to production (decided 2026-09-23),
  so in production the Open Library provider fails through its circuit breaker and does nothing.
- **A VIAF client exists** (`app/lib/viaf/`, PR #283) with nothing calling it: `AutoSuggest`,
  `PersonSearch`, `Cluster` (cached in `external_records`), `Viaf::Person`.
- **The AI enrichment framework is generic.** `enrichments` is polymorphic; `EnrichmentTask`,
  `BaseTask`, the model roles and the web-search tool are reusable. Only the book prompt, applier,
  runner and job are book-specific.

### What the data looks like

Measured on the development database on 2026-09-26 (read-only counts), 71,083 authors:

| Field | Filled | Note |
|---|---|---|
| `birth_year` | 25,287 (36%) | ranked authors 69%, top 1,000 99% |
| `death_year` | 12,741 (18%) | |
| `gender` | 65,684 (92%) | from the legacy AI |
| a description | 42,408 (60%) | 42,327 `ai_generated` rows, 8,218 `wikipedia`, 452 `other` |
| Open Library key | 16,542 (23%) | the only identifier type present |
| images, external links, countries, any other identifier | 0 | |

The top 1,000 ranked authors are nearly complete. The gap is the long tail and every author an
import will create.

Of our 16,542 Open Library keys, measured against the `2026-07-31` raw authors dump:
15,282 are still in the dump; 5,270 (32%) carry a Wikidata id in Open Library's own `remote_ids`
(ranked 42%, top 1,000 78%); 5,184 a VIAF id; 2,675 a bio; 3,130 a photo. A sample of 300 ranked
keys *without* an Open Library Wikidata link found 46 more through Wikidata's own P648 back-link
(unranked sample: 39 of 300).

**The legacy Wikipedia descriptions are frequently the wrong page.** All 8,218 authors that have
one also have a higher-priority description, so none is displayed today. But at least 1,421 (17%)
point at a page whose title does not contain the author's surname, and a random sample of 12 had
six wrong: Michael Harriot → Ainsley Harriott (a TV chef), Stacy Willingham → a list of 2024
campaign endorsements, John Crowe Ransom → the New Criticism movement, Bill Clinton → an article
about allegations against him, Arnaldur Indriðason → a book series, Zhou Haohui → a novel.

Wikidata entity sizes, measured 2026-09-27: famous authors 280–440 KB of JSON (50–76 KB gzipped),
mid-list 25–130 KB. Statements dominate; labels in other languages barely register.

### What the legacy app did

- `DataImporters::Authors::Sources::Wikipedia` searched Wikipedia for `"#{name} Author"`, took the
  first hit, and guessed gender by counting pronouns. That search is the source of the wrong pages.
- `Author#populate_from_chatgpt` (on create) asked `Openai::Chats::AuthorInfo` for full name, years,
  gender, nationality and a description, and read the answer with `Hash#fetch` and no schema.
- `nationality_text` held a free string for 33,678 of 71,083 authors (655 distinct values: mostly
  clean demonyms, plus "English" next to "British" and compounds like "Russian-American"). It was
  never displayed on author pages. Its job was to feed `Openai::Chats::BookNationality`, which chose
  one country per book from the author's nationality and the original language, then ran
  `Country.find_or_create_by!(name:)`. It was never migrated.

### Sources considered

| Source | Verdict |
|---|---|
| Wikidata | **Used.** CC0, no key, typed items (a human is distinguishable from a book), dates with precision, and links to VIAF (P214), ISNI (P213), LC (P244), Open Library (P648), Goodreads (P2963), LibraryThing (P7400). The identity hub. |
| Wikipedia | **Used, through Wikidata only.** Text is CC BY-SA 4.0: evidence for the AI description, never displayed. The article URL becomes a link. |
| VIAF | **Used, after Wikidata misses.** Long-tail coverage (any author a national library catalogued) and name variants; budget-limited. |
| Open Library | **Used** (the approved core provider), by key only. |
| OpenAI | **Used, last.** Description plus gap-filling, grounded on the above. |
| Library of Congress, ISNI directly | Not now: Wikidata already supplies the LC and ISNI ids for most authors. |
| Goodreads | API shut down in December 2020. |
| Google Books | Has no author entities. |
| Wikimedia Commons photos | Deferred to its own spec (licence per file, attribution on the author page). |

## Prior art

- **Select one or none.** Wang et al., "Match, Compare, or Select?" (arXiv:2405.16884), already
  cited by the finder redesign: presenting several candidates and asking the model to pick one or
  none beats a yes/no question about a single candidate. This design uses it for external records
  too, which is why it never asks the model to "confirm" a single Wikipedia hit.
- **Wikidata as the authority hub.** Open Library's own Wikidata integration and the library
  community's use of Wikidata to bridge VIAF, ISNI and LCNAF
  (https://www.wikidata.org/wiki/Wikidata:WikiProject_Authority_control). Wikidata permits at most
  one article per item per wiki, so an item's English sitelink is by construction about that item.
- **Reuse etiquette.** A descriptive User-Agent with a contact, `maxlag`, honouring `Retry-After`
  (https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_API_Usage_Guidelines,
  https://www.mediawiki.org/wiki/API:Etiquette).
- **LLM text from CC BY-SA sources.** `Wikipedia:Large_language_models_and_copyright` warns that
  an LLM can produce an excessively close paraphrase that is still a derivative work; hence the
  copy check in §9.

## Design

### 1. Shape and the chain

For one author:

```
Importer (sync)
  ├─ Providers::OpenLibrary        by key, fills blanks                       (increment 1)
  └─ Providers::Enrichment         enqueues WikidataJob, returns at once
WikidataJob     ResolveWikidata → ApplyWikidata (+ Wikipedia lead, link, legacy cleanup)
  ├─ matched            → EnrichJob
  ├─ no match           → ViafJob
  └─ failed             → EnrichJob   (skips VIAF: the author may be one Wikidata covers)
ViafJob         ResolveViaf → ApplyViaf → EnrichJob
                (paused / out of budget: enqueue EnrichJob now, reschedule itself)
EnrichJob       EnrichAuthor (AI) → ApplyAuthorFacts → enqueue deferred book enrichments
```

Each job enqueues the next; the order is guaranteed because nothing is enqueued in parallel.

**Rules shared by every step:**

- **Fills blanks only.** Nothing overwrites a populated field. `name` and `kind` are never written.
  A disagreement with a stored value is recorded as a conflict.
- **One ledger row per run** in `enrichments`, with a per-fact entry saying what the source said,
  whether it was applied, and why not (kinds `books.author_wikidata`, `books.author_viaf`,
  `books.author_facts`). Non-AI runs use the default `mode` and leave `model` blank; `provider`
  names the source. Values that have no column yet (a VIAF occupation, an unmatched country) live
  here, so a later spec can apply them without refetching.
- **Every choice of an external record is a `MatchDecision`** (§5.3), including the ones decided by
  rule.
- **Every external response is kept** in `external_records` (§3).
- **Namespaces are root-anchored.** Services live under `Services::Books::Authors::`; inside it,
  `Books` resolves to `Services::Books`, so model references are written `::Books::Author`.

### 2. The core importer (increment 1)

Built exactly as the import-finder redesign's §9 specifies:
`DataImporters::Books::Author::{ImportQuery, Finder, Importer, Providers::OpenLibrary}`, the
`AuthorByName` OpenSearch query, rule 4 for authors (equal normalized name, no year conflict), and
the book provider's author step (on an Open Library accept, each author on the work goes through the
author importer by key and is linked in Open Library's order; on abstain or reject, the query's
`author_names` go through by name; a book that already has authors is left alone).

Additions to that section:

- **`FinderRegistry` entry** for the authors finder (label, `MergeAuthor`, `source_author_id`,
  `execute_action_admin_books_author_path`, preloads), or the finder appears on no audit page and
  the registry test fails.
- **A second provider, `Providers::Enrichment`** (async), enqueues `WikidataJob` and returns
  `[:author_enrichment_queued]`. It lands in increment 2 with `WikidataJob`; a provider enqueuing a job
  that does not exist yet would be dead code.
- **The importer reports whether it created the author** (the finder's outcome was `unmatched`),
  so the book provider knows which of a book's authors are new (§10).
- **Declared while planning increment 1:** the author importer saves a new author before providers run
  (`ImporterBase#save_before_providers?`), and the book importer's name path is its own provider
  (`DataImporters::Books::Book::Providers::Authors`, after Open Library). Both exist because the Open
  Library service is not deployed to production: without them an author import by Open Library key
  would persist nothing while the service is unreachable, a later async provider would have no id
  to enqueue with, and a production book import would link no authors (the redesign's §8 only
  reached the name path on an abstain or reject, not on an unreachable service). Implementation
  added a third:
  `Books::Author` normalizes `alternate_names` on save the way it normalizes `name`, since the authors
  finder's exact source compares against stored alternate names; rows stored before that change are
  covered by the pending `books:normalize_names:apply` one-off.

### 3. `external_records`: new sources and the raw response

- `source` gains `wikidata` and `wikipedia`.
  - Wikidata rows: `source_id` is the item id (`Q7243`).
  - Wikipedia rows: `source_id` is `<language>:<page id>` (`en:12345`); page ids survive renames.
- **New nullable column `raw` (`bytea`)**: the complete response body, gzipped. `payload` (jsonb)
  stays the small distilled view the code reads, the same split `Viaf::Cluster` already uses.
  Gzipped, the whole author set costs roughly 0.5–1 GB; stored as jsonb it would be several GB (the
  VIAF work measured jsonb as the worst format for large payloads).
- Every provider reads through this table before calling out, and fetches again only with
  `refresh: true` or when `schema_version` is behind the distiller's.
- Only the chosen record is stored, not every candidate considered; the candidates' evidence lives
  on the `MatchDecision`.

### 4. Clients

- **`Wikidata::Client`** in `app/lib/wikidata/`, plain Faraday like `Viaf::`. Operations:
  - `entities(ids)`: `wbgetentities`, up to 50 per call.
  - `search(name)`: `wbsearchentities`, English, items, limit 10.
  - `by_statements(pairs)`: CirrusSearch `haswbstatement:P648=…|P214=…` in one query.
  - `works(item_ids)`: one SPARQL query returning, per item, up to 50 English work titles from
    `P50` (author of) and `P800` (notable work).
  - `country_codes(item_ids)`: one SPARQL query for `P297` and the English label, cached in
    `Rails.cache` by item for 30 days. Country entities are never fetched whole; the United
    States item alone is megabytes.
- **`Wikipedia::Client`** in `app/lib/wikipedia/`: `lead(language:, title:)` via `action=query&
  prop=extracts|pageprops&exintro&explaintext&redirects`, returning the plain-text lead, page id,
  resolved title, `wikibase_item` and the disambiguation flag. There is no search method, on purpose.
- **Etiquette and pacing.** User-Agent `TheGreatest/<version> (<contact>)`, with the contact from the
  `WIKIMEDIA_CONTACT` environment variable (SOPS, never credentials). `maxlag=5` on Action API calls.
  One request per second across both clients, via `DistributedRateLimiter` in `:immediate` mode
  (key `wikimedia:api`). A 429, a `maxlag` error, or an exceeded limiter raises a typed error that
  carries the wait; the job reschedules itself for that long plus jitter.
- **Verify the limits first.** The 2026 Wikimedia rate-limit changes are documented for
  `api.wikimedia.org`; whether `www.wikidata.org/w/api.php` and `query.wikidata.org` adopted the same
  caps was not confirmed. The Wikidata plan's first task checks this live and sets the pace in config.
- **Zeitwerk.** Two new `app/lib` directories: run `CI=1 bin/rails zeitwerk:check`, since eager
  loading is off in test.

### 5. The Wikidata identity step

`Services::Books::Authors::ResolveWikidata.call(author:, refresh: false)` answers one question: which
Wikidata person is this author, or none.

#### 5.1 Candidates

1. **Held id.** An author that already holds `books_author_wikidata_qid` starts with that item. It is
   still checked (identifiers are evidence, not verdicts).
2. **Id bridge.** One `by_statements` query over every id the author holds: Open Library keys (P648),
   VIAF (P214), ISNI (P213), LC (P244). Hits are marked "shares <identifier>".
3. **Name search.** `search` on the name and up to two alternate names, top 10 each.
4. **Fetch** every distinct candidate with `entities`, not counting rejected ones (§12).
5. **Type filter.** Keep items whose P31 includes human (Q5), pseudonym (Q61002) or collective
   pseudonym (Q16017119). Everything else is dropped and logged with its P31: books, series, films,
   lists, movements, fictional characters, schools, category pages.
6. **Works.** One `works` query over the survivors. A survivor's works are compared with our titles
   for this author (up to 50: the author's books, ranked first, plus their `alternate_titles`), with
   the book finder's title comparison.

Each candidate's evidence: English label, aliases, the English description line ("American
novelist"), birth and death years, occupations (P106 labels), citizenships, matching and
non-matching work titles, the English sitelink title if any, and the sitelink count.

#### 5.2 Decision

The first rule that applies wins:

| Rule | Outcome | `decided_by`, confidence |
|---|---|---|
| **Held id corroborated:** the held item is a person whose label or an alias equals the author's name or an alternate name (after `NameNormalizer`, case and diacritics folded), with no year conflict | matched | `identifier`, `certain` |
| **Id bridge:** exactly one person reached through the author's ids, corroborated the same way | matched | `identifier`, `certain` |
| **Corroborated name:** exactly one person whose label or alias equals the name, no year conflict, and at least one work title in common | matched | `rule`, `high` |
| **No person candidates** | unmatched | `rule`, `high` |
| **Otherwise** | the AI selects | `ai`, the model's confidence |

A **year conflict** means both sides have a birth year, or both have a death year, and they differ by
more than one. It blocks every rule and is shown to the AI.

**The AI step** is `Services::Ai::Tasks::Matching::SelectExternalRecordTask`, a sibling of
`SelectCandidateTask` sharing its response schema and "select one or none" structure, but worded for
the question "which external record is this author" rather than "is this already in our catalog":

- At most 6 candidates, ordered by evidence: id hits, then title overlap, then exact name, then
  sitelink count.
- Each candidate is shown as one line of its evidence. The incoming author's line carries name,
  alternate names, years, our titles, and countries.
- The guidance says to select 0 unless the evidence ties the person to writing these books, because a
  shared name alone is not enough and no link is better than a wrong link.

`needs_review` is set when an AI decision's confidence is `medium` or `low`.

#### 5.3 Recording

One `MatchDecision` per run: `finder` = `Services::Books::Authors::ResolveWikidata`, `subject` = the
author, `record` = nil, `query` = the author snapshot, `candidates` = every candidate with its
evidence (dropped non-persons included, marked), `selected_index`, `decided_by`, `confidence`,
`reason`. A `FinderRegistry` entry of a new external-link kind (no merge action, no re-check, the
Reject link action from §12) puts these on the existing audit pages.

#### 5.4 Wikipedia

Only for a matched item with an English sitelink:

1. Fetch the lead with `Wikipedia::Client#lead`.
2. The page must report the same `wikibase_item` back, and must not be a disambiguation page.
   Otherwise the article is ignored and the ledger says why.
3. Store the response in `external_records` (`wikipedia`, `en:<page id>`).
4. Add an `ExternalLink` (`source: wikipedia`, `name: "Wikipedia"`) to the author with
   `find_or_initialize_by` on the URL.
5. The lead text is evidence for the AI step. It is never shown on the site.

#### 5.5 Re-runs

A run is skipped when the author already has a `books.author_wikidata` ledger row created after the
author row, unless `refresh: true`. The skip also means a link a person removed stays removed: the
rake does not bring it back.

### 6. Applying Wikidata

`Services::Books::Authors::ApplyWikidata`, fills blanks only:

| From Wikidata | Written to | Rule |
|---|---|---|
| item id, P214, P213 (spaces removed), P244, P648 (every value), P2963, P7400 | `identifiers` via `find_or_initialize_by` | `books_author_wikidata_qid`, `_viaf`, `_isni`, `_lcnaf`, `_openlibrary_id`, `_goodreads_id`, `_librarything_id`. Every Open Library value is stamped, since Wikidata often lists several for one person and each helps the finder |
| P569 / P570 | `birth_year`, `death_year` | Only at year precision or finer (precision ≥ 9). Decade and century precision, several disagreeing values, `somevalue`, and BCE dates are recorded, not applied |
| P21 | `gender` | male (Q6581097) → male, female (Q6581072) → female, trans woman (Q1052281) → female, trans man (Q2449503) → male, non-binary (Q48270) → non_binary. Anything else is recorded, not applied. With 92% already set by the legacy AI, disagreements are the common case: recorded as conflicts, never overwritten |
| English label, English aliases, P1559 (native-language name), P742 (pseudonym) | `alternate_names` | Union, deduplicated after normalization, the author's own name excluded, capped at 20 added per run |
| P27 | `books_author_countries` | Through the country lookup (§7), fills only when the author has no countries |
| English sitelink | `external_links` | §5.4 |

The legacy Wikipedia cleanup also runs here (§12).

### 7. Countries

**Table.** `books_author_countries`: `author_id`, `country_id`, timestamps, unique pair, foreign keys.
`Books::Author has_many :author_countries` and `:countries`. `Books::Author::Merger` carries the rows
over (find-or-create on the target), which the merger's association list and its test must name.

**`Services::Books::CountryLookup`**, shared by books and authors (it replaces `find_country` in
`ApplyBookFacts`):

- `from_wikidata(country_item_ids)`: `P297` → `ISO3166::Country#nationality` from the `countries`
  gem (already in the Gemfile) → the text path. Historical states have no `P297`; a small explicit
  map covers them, keyed by item: Russian Empire → Russian, Soviet Union → Soviet, Austria-Hungary →
  Austro-Hungarian, Kingdom of Great Britain and United Kingdom of Great Britain and Ireland →
  British, Ottoman Empire → Ottoman, Kingdom of Prussia → German, Yugoslavia → Yugoslav. The plan
  sizes this map from a measured sample of P27 values on our resolved authors.
- `from_iso(codes)` for VIAF: ISO code → gem nationality → the text path.
- `from_text(names)`: an alias map for the duplicates `Books::Country` already holds (Argentine →
  Argentinian, New Zealander → New Zealand, Persian → Iranian, Philippine → Filipino, South Korean →
  Korean, Saudi Arabian → Saudi), then a case-insensitive name match.
- **Never creates a `Books::Country`.** The table already carries junk from the legacy
  `find_or_create_by!` ("Krakatoa", "Kaddish"). An unmatched value is returned as unmatched and
  recorded.
- English, Scottish, Welsh and Northern Irish rows stay distinct; whichever the source says is used.
  Wikidata citizenship for a UK author says British.

**Legacy nationality.** A new idempotent migrator, `data_migration:author_countries`, runs inside
`data_migration:all` after authors. It reads `LegacyBooks::Author#nationality_text`, splits compounds
on `-` and `/` ("Russian-American" → Russian + American) except a keep-whole list
(Austro-Hungarian), maps each part through `from_text`, and `find_or_create_by!`s the join rows.
It prints the unmapped strings with their author counts. It is a migration step, not a one-off,
because production books data is truncated and migrated again before launch.

### 8. VIAF

**When.** `ViafJob` runs only after a Wikidata *miss* (outcome unmatched). For a matched author the
VIAF id comes from Wikidata (P214) and VIAF itself is not called.

**`Services::Books::Authors::ResolveViaf`:**

1. **Held id.** When the author already holds `books_author_viaf`, fetch that cluster with
   `Viaf::Cluster#find` (1–4 requests including redirect hops). Corroborate name and years, as in
   §5.2.
2. **Otherwise search.** `Viaf::Search::AutoSuggest` on the name (one request, about 3 KB). Keep
   personal-name suggestions. If exactly one has a heading equal to the name and a birth year agreeing
   with the author's, accept by rule (`rule`, `high`). Otherwise fetch the clusters of the top 3 or
   fewer and give them to `SelectExternalRecordTask`. The evidence is headings, years, nationality,
   occupations, work titles, and how many national libraries contribute.
3. **Record** a `MatchDecision` as in §5.3, `finder` = `Services::Books::Authors::ResolveViaf`.

**`Services::Books::Authors::ApplyViaf`**, fills blanks only (ledger kind `books.author_viaf`):

- Identifiers: VIAF, ISNI, LC.
- A Wikidata id in the cluster's sources is stamped. `WikidataJob` then runs **once** for that author
  with `via_viaf: true`, which forbids it from enqueuing VIAF again. It takes the held-id path (§5.1).
- Years from the cluster dates. Gender from the `a`/`b` codes. Countries via `CountryLookup.from_iso`.
  *(Amended in increment 4: years only when the cluster names no Wikidata item, since the Wikidata
  run that follows is the better source, and never a death year more than two years before one of the
  author's own books first appeared. A VIAF cluster can merge two people: Sarah Morgan's, the right
  one by its titles and Wikidata link, carried another Sarah Morgan's 1948–2013. The same death-year
  check applies to the AI step's years.)*
- Alternate names from main headings only: inverted forms ("Tolstoy, Leo, graf, 1828-1910") become
  natural order ("Leo Tolstoy") with dates and titles stripped. Latin script only, at most 10.

**Storage.** `Viaf::Distiller` also keeps work titles (it drops them today), bumping
`SCHEMA_VERSION`; production has no cached rows yet. The gzipped raw cluster goes in `raw`.

**Pacing and failure.** `ViafJob` is on the `low` queue, not `serial`.

- `Viaf::RateLimiter` is built in `:immediate` mode. An exceeded limit reschedules the job after its
  `retry_after` plus jitter, so no worker thread sleeps.
- When the response headers report fewer than 50 requests left for the day, the job reschedules an
  hour out.
- A 403 sets a Redis pause key (`viaf:paused_until`) for one hour, doubling on each repeat up to 24
  hours. Every `ViafJob` checks it before calling. A 403 is never retried directly: the firewall
  behind it has not recovered within 9.5 minutes in testing, and retries may extend the ban.
- **The chain never waits on VIAF.** A paused `ViafJob` (`Viaf::Exceptions::Paused`: a Cloudflare
  block, a 429, or the day's budget running low) enqueues `EnrichJob` at once, once, and
  reschedules itself. A busy pace only reschedules: it clears in seconds. Facts it finds later land
  as fills only. *(Amended in increment 4.)*

At 1–2 requests for a held id and 3–5 for a search, the ~1,000/day budget covers about 200–300
authors a day. That is ample for imports; the backfill's VIAF share takes months, in the background.

### 9. The AI step

**`Services::Ai::Tasks::Books::AuthorFactsTask < EnrichmentTask`**, ledger kind `books.author_facts`.

*Input*, labelled so the model knows what each part is:

- name, alternate names, and the years, gender and countries already stored
- up to 10 of our titles by the author, ranked first, with first published years
- Wikidata: description line, years, occupations, citizenships, notable works
- VIAF: headings, years, nationality, occupations (when there is a VIAF match)
- the full Wikipedia lead (when there is one)

The ledger row lists the `external_records` (source and id) whose content went into the input, so a
rejected link can find the descriptions it influenced (§12).

*Output*, each fact with a value and a confidence: `recognized`, overall `confidence`, `birth_year`,
`death_year`, `gender` (`male`, `female`, `non_binary`, or null), `nationalities` (English
adjectives), `description`.

**Modes.**

- **Knowledge** (the `standard` role) by default, grounded in the input.
- **Research** (web search) only when neither Wikidata nor VIAF matched *and* the model reports
  `recognized: false` or low overall confidence. It counts against the shared
  `config.x.ai.research_daily_cap`. The backfill passes `allow_research: false`, so bulk runs never
  spend the budget imports need.

**Skip.** The run is skipped entirely (a `skipped` ledger row, no model call) when the author has an
AI or manual description and `birth_year`, `gender` and countries are all populated. `death_year` is
excluded because living authors have none.

**Description rules** (the book rules adapted to a person):

- One paragraph of at most 110 words, sentences of varied length, only as long as the facts support:
  as few as 20 words for an author little is known about, never padded or repeated to reach a length.
  *(Amended in increment 4: the 60-word minimum produced repetitive filler for thin evidence.)*
- Content: who the author is or was, when and where, what they write or wrote, best-known works named
  plainly, a movement if one applies.
- Never mention the sources, records or catalogs, or what is not known. *(Amended in increment 4.)*
- At most one major prize, stated plainly ("won the 1954 Nobel Prize in Literature"). For a person
  this is a fact, not marketing. Book descriptions still ban awards.
- Do not open with the author's name; the page shows it.
- Living authors: no personal-life detail beyond what the sources state, and never a death year.
- The book list of banned words, no em dashes or double hyphens, no semicolons, no lists, no
  marketing or judgment, no meta narration.
- Write in your own words and your own structure; do not reuse phrases from the source text.

**Checks.**

- `Services::Books::DescriptionCheck` gains an overlap check: a draft sharing any run of 8 or more
  consecutive words (normalized) with the Wikipedia lead fails as `copied`. *(Amended in increment
  4: words are letters, marks and digits; a work title of 4 or more words that both texts name is
  exempt from the count, since naming a book is not copying.)*
- `Services::Ai::Tasks::Books::AuthorDescriptionReviewTask` (the `fast` role) replaces the book
  reviewer's spoiler judgment with `copied_phrasing` and `names_author_at_start`, keeping `marketing`,
  `meta_narration` and the style flags.
- A failed draft gets one rewrite. If that fails too, the description is recorded as `rejected` and
  not applied, the same as books.

**`Services::Books::Authors::ApplyAuthorFacts`**, fills blanks only:

- Low-confidence facts are deferred, as `ApplyBookFacts` does.
- Nationalities go through `CountryLookup.from_text`.
- The description is written with `assign_description(source: :ai_generated)` only when the author has
  no `ai_generated` row. The 42,327 legacy AI descriptions are kept.

**Runner and job.** `Services::Books::Authors::EnrichAuthor` mirrors `Services::Books::EnrichBook`
(knowledge, then research on the conditions above, one ledger row per run). `EnrichJob` runs it on
the `low` queue with `retry: 3`, then does §10's hand-off.

### 10. Feeding book enrichment

**Prompt.** `BookFactsTask`'s input gains one line per author from stored data, for example
`Author: Ernest Hemingway (1899–1961; American)`. The `origin_countries` definition is unchanged.

**Ordering.** When a book import creates an author, that author's countries do not exist yet at the
moment the book's enrichment would run.

- The book importer runs the author importer without its async provider, collects the authors
  this import created, and enqueues their `WikidataJob`s from `Providers::AuthorEnrichment` after
  the book and its `book_authors` rows are saved, so the chain sees the book's title.
  `Providers::AuthorEnrichment` runs after `Providers::AiEnrichment`, so the book's deferral row
  (next bullet) is already written before any author chain is queued -- a chain that finishes fast
  cannot reach its hand-off before the book's wait is recorded.
- The book's `Providers::AiEnrichment` checks whether any of the book's linked authors were created
  by this import. If so, it does not enqueue `EnrichBookJob`: it writes a skipped `books.book_facts`
  row with reason `deferred_to_authors` and reports `[:ai_enrichment_deferred_to_authors]`.
- `EnrichJob` ends, after a successful run or once its retries are exhausted, by enqueuing
  `EnrichBookJob` for each of the author's books whose latest `books.book_facts` row is that
  deferral. Only books that waited are handed on, never the author's other books (Shane,
  2026-09-30: an author is created because a book is being added). Every chain is meant to reach
  `EnrichJob`, including after Wikidata or VIAF failures -- not guaranteed: an author deleted or
  merged away mid-chain makes every job return early, and a `WikidataJob` or `ViafJob` that
  exhausts its own Sidekiq retries never reaches `EnrichJob` either (a `ViafJob` that already
  paused has queued `EnrichJob` itself, so a pause alone strands nothing). *(Amended in increment
  4.)*
- A book with two new authors can be enqueued twice, when both chains finish close together: the
  second hand-off runs before the first book run has written its row. The second run only fills
  blanks, and concurrent runs are safe (the unique description index). When the chains finish far
  apart, the second hand-off finds the newer row and queues nothing, and the book may then be
  enriched before its second new author has countries. At 1.004 authors per book this is rare, and
  it is accepted. *(Amended in increment 4.)*
- `books:enrich_missing` catches any book the chain never reached; a deferral row does not count as
  a ledger row there.

### 11. Jobs and queues

| Job | Queue | Retry | Enqueues |
|---|---|---|---|
| `Books::Authors::WikidataJob` `(author_id, refresh = false, via_viaf = false)` | `low` | 3 | `ViafJob` on a miss (unless `via_viaf`), else `EnrichJob` |
| `Books::Authors::ViafJob` `(author_id, refresh = false, enrich_queued = false)` | `low` | 3 | `EnrichJob` after a normal run; immediately, once, on a pause; or `WikidataJob(author_id, true, true)` instead, when the run newly stamped a Wikidata id and the decision does not need review |
| `Books::Authors::EnrichJob` `(author_id, allow_research = true)` | `low` | 3 | `EnrichBookJob` for the author's books that waited for it |

`low` is the last queue in strict priority, so these jobs never delay anything else.

Expected failures (HTTP errors, timeouts, malformed data) write a `failed` ledger row and continue
the chain. Rate-limit signals reschedule the same job. Anything else raises and uses Sidekiq's
retries.

### 12. Reject link

A decision on the audit page for `ResolveWikidata` or `ResolveViaf` gets a **Reject link** action. It
has the same authorization as the audit page's merge action, and asks for confirmation.

`Services::Books::Authors::RejectExternalLink.call(decision:, user:)`:

1. Removes what the decision's run applied, using the run's ledger row:
   - the identifiers it stamped
   - the Wikipedia `ExternalLink`
   - the `author_countries` rows it added
   - each scalar (`birth_year`, `death_year`, `gender`) whose current value still equals what the run
     wrote
   - `alternate_names` it added
2. Marks `deprecated` any AI description whose run used this record as evidence. The `books.author_facts`
   ledger row names the Wikidata and VIAF records its input came from.
3. Sets the decision's new `verdict` column to `rejected` (enum: `confirmed`, `rejected`, nullable)
   and calls `review!`.
4. Re-enqueues `WikidataJob` with `refresh: true`. `ResolveWikidata` and `ResolveViaf` drop any record
   that a rejected decision for this author selected, so the rejected link cannot come back.

This lands before the backfill (§16), so the thousands of links the backfill makes can be undone
one by one from the start. Adding it requires a Playwright test (it is a new admin flow).

*(Amended in increment 5: a reject is about the person, not one record or one decision, so every other
decision of the same finder that selected the same record for this author, and isn't rejected yet, is
rejected with it. A rejected VIAF run also takes every Wikidata decision that matched the Wikidata id
the VIAF run stamped, directly or through a Wikidata redirect the ledger recorded as `redirected_from`,
regardless of when the decision was recorded -- once the record is banned for this author, every
decision that ever chose it has to go. It runs the other way too: rejecting a Wikidata decision also
rejects every matched, unrejected VIAF decision whose cluster names that Wikidata item as its own link,
one hop, never chased further. The record's own id and its Wikipedia article link are removed whoever
added them, even when the run found them already set, since they name the rejected record itself; a
superseded id a Wikidata merge run kept held alongside the canonical one (`ApplyWikidata`'s
`redirected_from`) is removed the same way. An AI run that used the record as evidence is reverted too,
not only its description -- its applied years, gender and countries go the same as any other run's. A
rejected record's id is never stamped on that author again, by any step, so `FactSheet#stamp` returns
`"rejected"` for one; a rejected Wikidata record is its key plus every id Wikidata merged into it that
the author's own runs recorded, so none of those ids is stamped or selected again either. A run whose
decision was rejected stops counting as processed, and `MatchedRecords` ignores it too, so no rejected
evidence reaches the AI step. A deprecated AI description no longer counts as present, so the AI step's
completeness check and the "already set" checks look past it. Legacy Wikipedia descriptions the
rejected run deprecated go back to normal rank, since the rank before isn't recorded and the re-run
judges them again.)*

### 13. Backfill and the legacy Wikipedia cleanup

**`books:authors:enrich[limit]`.** The limit is required; `all` is accepted.

- Selects authors with no `books.author_wikidata` ledger row newer than the author row: ranked
  authors by rank first, then the rest by book count.
- Enqueues `WikidataJob` for each with `perform_in` spaced at the configured Wikidata pace (about one
  author per 6 seconds), and `allow_research: false` threaded through to `EnrichJob`.
- Prints how many it enqueued and the expected finish time.
- **Run `[100]` first**, then report the match rate, how decisions split across rules, AI and
  unmatched, how many need review, and the real AI cost from `ai_chats`, before anyone runs `[all]`.
  Wikidata alone for all 71k takes about four days at this pace.

**Legacy Wikipedia cleanup**, inside `ApplyWikidata` whenever the author has a `wikipedia`-source
description:

- The description's `source_url` is resolved to a Wikidata item (`pageprops`, following redirects).
- If the author was matched and that item is the matched item, the description is kept.
- If the item differs, **or the author could not be matched at all**, the description's rank is set
  to `deprecated`. Given the error rate in §Problem, an unconfirmed page counts as wrong.
- Deprecated, not deleted, so the change is reversible. The ledger records each decision.

### 14. Re-runs after the production re-migration

Production books data is a rehearsal copy. It will be truncated and migrated again, author ids
preserved, before launch. Everything here is therefore a repeating step:

- "Processed" means a ledger row **newer than the author row**. Old ledger rows and decisions
  survive the truncation and point at re-created authors with the same ids.
- `external_records` survives the truncation, so re-running costs no Wikidata, Wikipedia or VIAF
  fetches for records already held. Only searches repeat, and the AI selections repeat (the `fast`
  role, which is cheap).
- Rejected verdicts are keyed by author id and selected record, so they survive too. A legacy author
  keeps its id across migrations.
- Launch sequence additions, after the final data migration: `data_migration:author_countries` runs
  inside `data_migration:all`, then `books:authors:enrich[all]`.

### 15. Testing

- **Clients:** WebMock tests using trimmed real responses saved as fixture files (entity, search,
  CirrusSearch, SPARQL works and country codes, Wikipedia lead, disambiguation page, 429, maxlag).
  Test base URLs are non-loopback, because WebMock allows localhost.
- **`ResolveWikidata`:** each rule, plus a deliberate **negative class** built from the legacy
  failures: a book, a series, a list, a movement and a fictional character carrying the author's
  name; a same-name person from another century; a year conflict; a TV chef whose name differs by
  one letter; an item whose English sitelink is a disambiguation page; a sitelink whose page reports
  a different item.
- **Appliers:**
  - fill-only
  - conflicts recorded
  - date precision, `somevalue`, BCE
  - several citizenships
  - unmatched countries
  - alias caps
  - every Open Library value stamped
- **Country lookup:** ISO path, historical map, alias map, never creating a row.
- **Legacy migrator:** compounds, the keep-whole list, idempotency, the unmapped report.
- **The chain:**
  - each job enqueues the next
  - VIAF only after a miss
  - `via_viaf` prevents a loop
  - a failed Wikidata run skips VIAF
  - a VIAF pause sends work straight to `EnrichJob`
  - `EnrichJob` always hands off book enrichment
  - the book provider defers for new authors
- **VIAF pacing:** a limiter-exceeded reschedule, the daily-budget reschedule, the 403 pause and its
  doubling.
- **AI step:** the task's prompt and schema, the skip rule, knowledge → research escalation and the
  `allow_research: false` path, the copy check, the rejected-after-rewrite path.
- **Reject link:** every reverted field; a scalar edited by a person since the run is left alone; the
  rejected record is excluded on the re-run.
- **Merger:** `author_countries` carried over.
- **Registry:** the authors finder entry and the external-link entries.
- **E2E:** the Reject link flow on the audit page (a Playwright spec in `e2e/tests/books/admin/`). If
  the public author page starts showing the Wikipedia link, a check there too.
- **Before merging each API increment:** a console smoke run against the real APIs on about 20 hard
  authors, including the six wrong-page cases in §Problem. Shane runs it, or an agent does with his
  go-ahead.

### 16. Increments

Each gets its own plan under `docs/superpowers/plans/`.

1. **Core importer.** §2: the approved finder-redesign §9 plus the registry entry, the created-author
   signal (`ImportResult#created?`), save-before-providers, and the book provider's author step. This
   alone unblocks the book importer.
2. **Wikidata and Wikipedia.** §3, §4, §5, §6, §7:
   - `external_records` changes, both clients, `ResolveWikidata`, `SelectExternalRecordTask`,
     `ApplyWikidata`
   - `books_author_countries`, `CountryLookup` (with `ApplyBookFacts` switched to it)
   - the legacy nationality migrator, `WikidataJob`
   - the legacy Wikipedia cleanup logic (exercised only by the backfill)
3. **VIAF.** §8.
4. **AI step and book enrichment.** §9, §10, `EnrichJob`.
5. **Reject link.** §12, with its E2E spec.
6. **Backfill.** §13's rake task and its `[100]` report.

## Non-goals

- **Author photos from Wikimedia Commons.** Their own spec: a licence check per file, attribution on
  the author page, downloading rather than hotlinking.
- **Displaying Wikipedia text.** The lead is evidence only.
- **Regenerating the 42,327 legacy AI author descriptions** in the house style. They are kept; a
  later pass can replace them if one voice everywhere becomes worth the cost.
- **Changing how a book's country is decided** beyond giving the book prompt the authors' stored
  countries.
- **Adding `remote_ids`, bio or photos to the Open Library artifact.** Wikidata supplies the
  identifiers live, and the service is not in production.
- **Library of Congress or ISNI clients.**
- **Removing or parallelising the `serial` queue.** None of this work uses it.

## Deferred

- **Commons photos** (above).
- **Author pages showing nationality, identifiers or the Wikipedia link.** This spec stores them;
  display is a UI decision.
- **Using stored nationality elsewhere**, for example suggesting a book's country without an AI call.
- **Cleaning the junk rows in `Books::Country`**, and merging its duplicate names.
- **A separate research cap for authors**, if imports ever compete with books for the shared one.

## Decisions made during brainstorming

- **Scope:** the core importer plus Wikidata, VIAF and AI. Photos are later.
- **VIAF is in.** The reasons it was deferred were its rate limits (answered by running it
  asynchronously and only after a Wikidata miss) and the fact that choosing a VIAF record is a match
  decision (answered by one shared selection step for Wikidata and VIAF).
- **Nationality is stored**, as a join to `Books::Country`, several per author. It feeds the book
  prompt, because the legacy app's main use of author nationality was deciding a book's country. The
  33,678 legacy strings are migrated.
- **Imports first; a backfill rake is wanted, an admin button is not.**
- **Keep every external response**, in `external_records`, gzipped raw next to a distilled payload.
- **Approach A:** a chain with authority data first and the AI last.
- **Wikipedia only through a confirmed Wikidata item, never searched.** Candidates are typed
  (persons only). An AI step selects one of several or none, rather than confirming a single hit.
  The article must name the same item back.
- **Legacy Wikipedia descriptions are checked and deprecated** when they are not the confirmed
  author's article.
- **Descriptions are always AI-written in one house style** from the Wikipedia lead and the facts,
  with a copy check. The Wikipedia text itself is never shown. Legacy AI descriptions are kept.
- **One plainly stated major prize** is allowed in an author description.
- **Book enrichment waits for new authors**, handed off by the author chain's last step.
- **Declared while writing the spec** (not raised section by section, flagged for review):
  - the Reject link action (§12), which is how the "a wrong link can be undone" promise is kept, given
    the admin author page cannot remove an identifier today
  - the `verdict` column on `match_decisions`
  - `death_year` excluded from the AI skip rule
