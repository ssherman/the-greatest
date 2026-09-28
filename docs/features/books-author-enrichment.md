# Books author enrichment

Gives a `Books::Author` the data a person would look up by hand: identifiers, birth and death
years, gender, nationality, alternate names, and a Wikipedia link, resolved through Wikidata and
never by searching Wikipedia. Every choice of an external record is a recorded decision, visible
on the books admin audit pages, and every value it writes is traceable to the run that wrote it.

Spec: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §3-§7, §13, §14. See
also `docs/features/wikimedia-clients.md` for the Wikidata/Wikipedia clients themselves, and
`docs/features/import-finder.md` for the audit pages and the `MatchDecision` machinery this
reuses.

## The chain today

```
DataImporters::Books::Author::Importer
  Providers::OpenLibrary        by key, fills blanks
  Providers::Enrichment         enqueues WikidataJob, returns at once
Books::Authors::WikidataJob     Services::Books::Authors::EnrichFromWikidata
                                   ResolveWikidata -> ApplyWikidata
                                     -> LinkWikipedia, CleanLegacyWikipedia
```

`Providers::Enrichment` runs only when the importer created or force-re-imported the author (an
already-matched author is never re-enriched from the provider chain). It queues
`Books::Authors::WikidataJob.perform_async(author.id)` and returns immediately, so an author
import never blocks on a Wikimedia round trip. The job runs on the `low` queue with `retry: 3`
(`low` is last in strict priority order, so it never delays anything else).

VIAF, the AI facts step (the house-style description and gap-filling), and the hand-off into book
enrichment are increments 3 and 4 of the same spec -- not built yet. Today the chain ends after
the Wikidata/Wikipedia run, whatever its outcome.

An author an admin has flagged `exclude_from_rankings` (the "Exclude from author rankings"
checkbox on the admin author form) is skipped without a Wikimedia call at all -- a `skipped`
ledger row with reason `placeholder`.

**Known gap:** when a book import creates a new author, that author's `WikidataJob` can run
before the book and its `book_authors` row are saved, so `ResolveWikidata`'s title-matching step
may see none of the author's actual books yet. The book importer has no production caller today,
so this has not mattered in practice; it is a real ordering issue for the next increment to
address once book enrichment feeds back into resolution.

## Resolution

`Services::Books::Authors::ResolveWikidata.call(author:, refresh: false)` answers one question:
which Wikidata person is this author, or none. It never writes to the author; it only picks a
candidate and records a `MatchDecision`.

**Three candidate stages, with early exit** -- a stage whose rule decides ends the run without
running the later stages:

1. **Held id.** If the author already holds `books_author_wikidata_qid`, that item is fetched and
   checked (identifiers are evidence, not verdicts).
2. **Id bridge.** One `by_statements` query over every identifier the author holds (Open Library
   P648, VIAF P214, ISNI P213, LC P244).
3. **Name search.** `search` on the author's name and up to two alternate names, top 10 each.

**Persons-only filter.** Every candidate found in any stage is fetched and filtered to items
whose P31 (instance of) includes human (Q5), pseudonym (Q61002), or collective pseudonym
(Q16017119). Everything else -- books, series, lists, movements, fictional characters sharing the
author's name -- is dropped and logged with its own P31, never shown to the AI step.

**Rules 1-3, then the AI:**

| Rule | Outcome |
|---|---|
| Held item is a person whose name and years agree | matched, `identifier`, `certain` |
| Exactly one person reached through the id bridge, name and years agree | matched, `identifier`, `certain` |
| Exactly one person named like the author, no year conflict, sharing a work title with ours | matched, `rule`, `high` |
| No person among the candidates at all | unmatched, `rule`, `high` |
| Anything else | the AI selects |

The AI step is `Services::Ai::Tasks::Matching::SelectExternalRecordTask`, the same "select one or
none" shape as the import finder's `SelectCandidateTask`, shown at most 6 candidates ordered by
identifier hits, then shared titles, then exact name, then sitelink count. It is told to select 0
unless the evidence ties the person to writing these books: a matching work, a shared identifier,
or life dates that agree together with a description or occupation that shows a writer. A shared
name alone, or a shared name and matching dates without anything else, is treated as someone else.

**Year conflict**: both sides have a birth year, or both have a death year, and they differ by
more than one. It blocks every rule (1 through 3) and is shown to the AI as a flag on that
candidate.

**Name folding.** A name match compares `NameNormalizer` + `QuoteNormalizer` output, further
folded to remove case and diacritics (NFD, strip combining marks), so "Gabriel Garcia Marquez"
and "Gabriel García Márquez" are the same key.

**A held id that Wikidata has since merged into the matched item** (a redirect) is treated as the
same person, not a conflict -- the current id is stamped beside the old one. Any *other* live
QID the author already holds, that the resolution did not reach as the matched item, is a
conflict: nothing from that run is applied (see "held-QID conflict" below), and the decision is
flagged for review.

**`needs_review`** is set when the decision was decided by the AI fallback (the AI call itself
failed) or its confidence is `medium` or `low`. A rule that would otherwise land at `high`
confidence is downgraded to `medium` -- and so flagged for review -- when a source it depended on
(for example the `works` SPARQL query) failed partway through the run.

Every run, whatever it decides, writes one `MatchDecision` (`finder` =
`Services::Books::Authors::ResolveWikidata`) and is visible on the books admin audit pages as a
**Wikidata link** decision. It is registered as a `DataImporters::FinderRegistry` entry of kind
`:external_link`: same audit trail as an import finder, but with no `ImportQuery`, no merge
action, and no re-check button, because it is not deciding "is this in our catalog" -- it is
linking an existing record to an outside source.

## What gets filled

`Services::Books::Authors::ApplyWikidata` fills blanks only. It never writes `name` or `kind`,
and nothing overwrites a populated field -- a disagreement is recorded as a conflict on the
ledger and left alone.

| From Wikidata | Written to | Notes |
|---|---|---|
| Item id, P214 (VIAF), P213 (ISNI), P244 (LC), P648 (Open Library), P2963 (Goodreads), P7400 (LibraryThing) | `identifiers` | Every Open Library value is stamped, since Wikidata often carries several for one person and each helps the import finder. The other identifier types are single-valued: a stored value that disagrees with Wikidata's is recorded as a conflict, not overwritten. |
| P569 / P570 | `birth_year` / `death_year` | Only at year precision (9) or finer; decade/century precision, disagreeing best-rank values, `somevalue`, and BCE dates are recorded but not applied. |
| P21 | `gender` | male, female, trans woman -> female, trans man -> male, non-binary; anything else recorded, not applied. The legacy AI's `unspecified` counts as blank, so Wikidata can fill it. |
| English label, English aliases, P1559 (native name), P742 (pseudonym) | `alternate_names` | Union after normalization (case- and diacritic-folded comparison; the stored spelling keeps its accents), author's own name excluded, capped at 20 *added* per run. |
| P27 (citizenship) | `books_author_countries` | Through `CountryLookup` (below); fills only when the author has no countries at all yet -- it is an all-or-nothing gate, not per-country. |
| English sitelink | `external_links` | See "Wikipedia" below. |

**Identifier collisions become duplicate pairs.** If a value Wikidata offers is already held by a
*different* author, nothing is stamped on the current author; instead
`Services::DuplicateCandidates::Flag` raises an `external_key_collision` pair between the two
authors, the same mechanism the import finder itself uses.

**A held-QID conflict applies nothing.** If the author already holds a Wikidata id other than the
one this run matched (and it isn't one Wikidata has since redirected into the matched item), the
whole apply step stops after recording that one conflict -- no identifiers, years, gender,
alternate names, or countries are written for that run, and the decision is flagged
`needs_review`.

Every fact -- applied or not -- is recorded in the ledger (see below), including the reason it
was not applied: `already_set`, `conflict`, `null`, `no_match`, `held_by_other`,
`held_qid_conflict`.

## Wikipedia

`Services::Books::Authors::LinkWikipedia` only runs for a matched item, and only reads the
matched item's own English sitelink -- never a search. Wikidata permits at most one article per
item per wiki, so an item's sitelink is, by construction, about that item.

1. Fetch the lead through `WikipediaLead.fetch` (read-through `external_records`).
2. **Item-back check.** The fetched page must report the same `wikibase_item` back. If it names a
   different item, the link is not used.
3. **Disambiguation check.** A page carrying a `disambiguation` pageprop is not used either.
4. On success, add an `ExternalLink` (`source: wikipedia`, `name: "Wikipedia"`) to the author,
   found or created by URL.
5. The lead's plain-text extract is kept as evidence for the future AI description step
   (`external_records`, source `wikipedia`, keyed `en:<page id>` so a page rename does not break
   the cache) and is **never displayed on the site**.

## Legacy Wikipedia cleanup

`Services::Books::Authors::CleanLegacyWikipedia` checks any existing `wikipedia`-source,
non-deprecated description on the author whenever a Wikidata run completes (matched or not):

- **Kept** when its `source_url` resolves (by page-props lookup, following redirects, in
  whatever language the URL names) to the same Wikidata item the author was just matched to.
- **Deprecated** (rank set to `deprecated`, not deleted -- reversible) when the item differs, when
  the URL cannot be parsed, or when the author could not be matched to any Wikidata item at all.

This exists because the legacy descriptions came from a text search and are frequently the wrong
page (see `docs/features/wikimedia-clients.md`). It only ever touches descriptions that already
exist -- a freshly created author has none, so this logic runs but does nothing until the
backfill (increment 6) walks the existing 71k authors. Checked against the current development
database: all 8,218 legacy Wikipedia descriptions on authors are ordinary
`en.wikipedia.org/wiki/...` URLs (548 percent-encoded), at most one per author, and none is
displayed today (every one of those authors has a higher-priority description already).

## Countries

**`books_author_countries`** is a plain join table: `author_id`, `country_id`, a unique pair, two
foreign keys. `Books::Author has_many :author_countries` and `:countries` (through). A merge
carries the source author's rows onto the target (`Books::Author::Merger#merge_author_countries`,
find-or-create so a shared country never raises a uniqueness error mid-merge).

**`Services::Books::CountryLookup`** is shared by books and authors (it replaced the old
`find_country` inline in `ApplyBookFacts`):

- `from_text(names)` -- an alias map for spellings that differ from what `Books::Country` already
  holds (the table's own duplicate names, plus a handful of `countries`-gem nationalities that
  differ from our spelling), then a case-insensitive name match.
- `from_iso(codes)` -- ISO code through the `countries` gem's nationality, then the text path
  (used by VIAF, increment 3).
- `from_wikidata(item_ids)` -- P297 (country code) through the gem, then the text path. States
  with no usable ISO code go through a small, explicit map of historical-state Wikidata items
  (Russian Empire, Soviet Union, Austria-Hungary, several defunct German and Chinese states, and
  so on), sized from a sample of 2,000 authors' Open Library-linked citizenship values (117 of
  883 had no ISO code). A handful of genuinely ambiguous states are deliberately left unmapped
  (Czechoslovakia, Cisleithania, Austrian Empire, Dutch East Indies) rather than guessed at.

**It never creates a `Books::Country`.** The table already carries junk from the legacy app's
`find_or_create_by!` ("Krakatoa", "Kaddish" are real rows). An unmatched value is returned as
unmatched and recorded on the ledger, never inserted.

**`data_migration:author_countries`** (`Services::BooksMigration::AuthorCountryMigrator`, runs
inside `data_migration:all` immediately after `:countries`) reads
`LegacyBooks::Author#nationality_text` (33,678 authors, 655 distinct strings), splits compound
values on `-`/`/` (`"Russian-American"` -> Russian + American) except a keep-whole list
(`"Austro-Hungarian"`), maps each part through `from_text`, and idempotently upserts the join
rows. A compound row already sitting in `Books::Country` (`"British-American"`) is never linked
to an author, on purpose -- the migrator always splits. A read-only dry run against the real
legacy data (2026-09-27): 33,678 authors -> 34,400 join rows, 0 missing authors, 288 authors
(0.86%) with at least one unmapped part (185 distinct unmapped parts). It is a repeating
migration step, not a one-off: production's books data is truncated and re-migrated more than
once before launch, and this task has to run every time, right after `:countries`.

## The ledger

Every Wikidata run writes exactly one `Enrichment` row, kind `books.author_wikidata`, provider
`wikidata`, linked to the `MatchDecision` it produced via `enrichments.match_decision_id` --
skips and failures included. `mode` stays at its default and `model` is blank; this step makes no
AI-facts call of its own (the AI selection inside `ResolveWikidata` writes to the decision, not
the ledger, the same as every other `SelectCandidateTask`-style finder).

**"Processed"** means a `books.author_wikidata` row *newer than the author row* with outcome
`applied`, `nothing_to_apply`, or `unrecognized`. A `skipped` or `failed` row does not count, so
the author is tried again next time. This definition is deliberate: after the pre-launch
production re-migration truncates and re-creates the books tables (author ids preserved), every
old ledger row becomes older than the freshly created author row, so a re-run of the chain
processes everyone again rather than treating stale history as done.

**A run that fails after already applying some Wikidata facts still records those facts** on its
`failed` row (the facts hash captured before the exception, not lost). `Wikidata::Exceptions::Error`
(network, HTTP, parse) is caught and written as a `failed` row with `reason: "wikimedia_error"`;
`Wikimedia::Exceptions::RateLimited` propagates uncaught, so `WikidataJob` can reschedule the
whole run rather than recording a false failure.

`external_records` is what makes a re-run cheap: a Wikidata entity or Wikipedia lead already held
at the current schema version costs no network call at all on a re-run, only the search/bridge
queries and (when the case reaches it) the AI selection repeat.

## Operating

Run one author by hand:

```ruby
Services::Books::Authors::EnrichFromWikidata.call(author: Books::Author.find(id))
# or, through the job:
Books::Authors::WikidataJob.new.perform(author_id)
```

Force a refresh (ignore `external_records` and the "already processed" check, refetch
everything):

```ruby
Books::Authors::WikidataJob.new.perform(author_id, true)
```

Where to look:

- The books admin **Match Decisions** audit page, filtered to the "Wikidata link" entity.
- `Enrichment.for_kind("books.author_wikidata")` -- every run, its outcome, and its facts.
- `author.enrichments.for_kind("books.author_wikidata")` for one author's history.

There is no backfill rake task and no admin button yet -- both are increment 6. Today the only
way an author reaches this chain is through the author importer's async provider.
