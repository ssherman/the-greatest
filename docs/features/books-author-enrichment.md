# Books author enrichment

Gives a `Books::Author` the data a person would look up by hand: identifiers, birth and death
years, gender, nationality, alternate names, and a Wikipedia link, resolved through Wikidata
first, then through VIAF when Wikidata finds no person, and never by searching Wikipedia. Every
choice of an external record is a recorded decision, visible on the books admin audit pages, and
every value it writes is traceable to the run that wrote it.

Spec: `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` §3-§8, §13, §14. See
also `docs/features/wikimedia-clients.md` for the Wikidata/Wikipedia clients themselves,
`docs/features/viaf-api-client.md` for the VIAF client the VIAF step below consumes, and
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
  on a miss (not via_viaf) ->   Books::Authors::ViafJob
Books::Authors::ViafJob         Services::Books::Authors::EnrichFromViaf
                                   ResolveViaf -> ApplyViaf
  new Wikidata id stamped ->    WikidataJob(author_id, refresh = true, via_viaf = true)
```

`Providers::Enrichment` runs only when the importer created or force-re-imported the author (an
already-matched author is never re-enriched from the provider chain). It queues
`Books::Authors::WikidataJob.perform_async(author.id)` and returns immediately, so an author
import never blocks on a Wikimedia round trip. The job runs on the `low` queue with `retry: 3`
(`low` is last in strict priority order, so it never delays anything else).

The AI facts step (the house-style description and gap-filling) and the hand-off into book
enrichment are increment 4 of the same spec -- not built yet. A Wikidata match, failure, or skip
ends the chain right there at `WikidataJob`. Only a genuine miss (outcome `unmatched`) goes on to
`ViafJob`, which itself ends the chain -- unless it newly stamped a Wikidata id, in which case one
more `via_viaf` Wikidata run follows.

An author an admin has flagged `exclude_from_rankings` (the "Exclude from author rankings"
checkbox on the admin author form) is skipped without a Wikimedia call at all -- a `skipped`
ledger row with reason `placeholder`.

**Known gap:** when a book import creates a new author, that author's `WikidataJob` can run
before the book and its `book_authors` row are saved, so `ResolveWikidata`'s title-matching step
may see none of the author's actual books yet. `ResolveViaf` shares the same gap on a Wikidata
miss: it builds its own title evidence (`AuthorProfile#titles`, shown to `SelectExternalRecordTask`
as `matching_titles`/`other works`) from the same `author.books` association. The book importer has
no production caller today, so this has not mattered in practice; it is a real ordering issue for
the next increment to address once book enrichment feeds back into resolution.

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
| Item id, P214 (VIAF), P213 (ISNI), P244 (LC), P648 (Open Library), P2963 (Goodreads), P7400 (LibraryThing) | `identifiers` | Every best-rank Open Library value is stamped, since Wikidata often carries several for one person and each helps the import finder. The other identifier types are single-valued: a stored value that disagrees with Wikidata's is recorded as a conflict, not overwritten. |
| P569 / P570 | `birth_year` / `death_year` | Only at year precision (9) or finer; decade/century precision, disagreeing best-rank values, `somevalue`, and BCE dates are recorded but not applied. |
| P21 | `gender` | male, female, trans woman -> female, trans man -> male, non-binary; anything else recorded, not applied. The legacy AI's `unspecified` counts as blank, so Wikidata can fill it. |
| English label, English aliases, P1559 (native name), P742 (pseudonym) | `alternate_names` | Union after normalization, author's own name excluded, capped at 20 *added* per run. |
| P27 (citizenship) | `books_author_countries` | Through `CountryLookup` (below); fills only when the author has no countries at all yet -- it is an all-or-nothing gate, not per-country. |
| English sitelink | `external_links` | See "Wikipedia" below. |

**Only best-rank statements count**, everywhere a fact comes from Wikidata: the preferred-rank
statement when the item has one, otherwise the normal-rank ones, never a deprecated one. This is
`Wikidata::Distiller#best`, applied before any of the rows above are even considered. A deprecated
Open Library key never reaches `ApplyWikidata` at all, so it is neither stamped on an author nor
usable as evidence that a candidate shares an identifier with ours (§Resolution) -- Tolstoy's
`OL7555476A` is a real example of a deprecated-rank Open Library key on Wikidata that this
filtering excludes on both sides.

**Alternate names are compared case-folded only, not diacritic-folded.** `ApplyWikidata` runs each
candidate name through the same normalizer the app uses when saving any name (quote folding first,
then NFKC -- quote folding has to come first because NFKC turns a stray U+00B4 acute accent into a
space plus a combining accent) and then folds case for the *comparison* against names already
stored -- so "García" and
"Garcia" are treated as different spellings and both can end up in `alternate_names`. Diacritic
folding only happens in the resolver's own name matching (`ResolveWikidata`'s `name_key`, used to
decide whether a Wikidata label *is* the author's name), never here. Whatever a run actually adds
to `alternate_names` is recorded in the ledger's `alternate_names` fact in that same
normalized-but-accented form -- the ledger and the column never disagree about what was written.

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

## VIAF

`Services::Books::Authors::ResolveViaf.call(author:, refresh: false)` runs only after a Wikidata
run ends `unmatched` -- a matched author gets its VIAF id from Wikidata's P214 and VIAF is never
called at all. It answers the same question as `ResolveWikidata`: which VIAF person is this
author, or none.

**Two stages, the first that decides ends the run:**

1. **Held id.** Every `books_author_viaf` identifier the author already holds is fetched. A held
   cluster whose name and years agree with ours matches, `identifier`, `certain` -- the same shape
   as Wikidata's held-item stage.
2. **Search.** One `Viaf::Client#suggest` call on the author's name. VIAF's AutoSuggest answers
   with several rows per cluster -- a plain heading, one carrying dates, one carrying a
   description, translated forms -- so `ResolveViaf` groups rows by VIAF id into one candidate
   each before judging anything (see `docs/features/viaf-api-client.md`).

**The rule**: exactly one candidate has a heading equal to the author's name (or an alternate
name) *and* a birth year within one year of the author's own. Its cluster is then fetched and must
still be a person with no year conflict -- `matched`, `rule`, `high`. No person at all among the
candidates is `unmatched`, `rule`, `high` -- whether because none of the AutoSuggest rows names a
person to begin with, or because every one of the (up to three) fetched clusters turns out not to
be one. Anything else fetches up to three clusters (`MAX_FETCHED`), ordered by held id first, then
a matching heading, then no year conflict, then the most contributing libraries, and hands them to
`SelectExternalRecordTask`, whose guidance also covers VIAF's duplicate-cluster problem: VIAF often
holds the same person as two clusters (one heavily catalogued, one nearly empty), and the AI is
told to prefer the more-catalogued one rather than treat that as a tie.

**A cluster VIAF no longer serves** (a 404, or a withdrawn/abandoned record) is dropped as a
candidate rather than ending the run; it is recorded on the candidate and in `sources_failed`,
which caps what would otherwise be a `high`-confidence verdict (matched or unmatched) at `medium`
-- and so flags the decision `needs_review` -- the same downgrade Wikidata applies when a source
it depended on fails partway through a run.

Every run, whatever it decides, writes one `MatchDecision` (`finder` =
`Services::Books::Authors::ResolveViaf`), visible on the audit pages as a **VIAF link** decision,
registered the same way as the Wikidata link (`DataImporters::FinderRegistry`, kind
`:external_link`).

**`Services::Books::Authors::ApplyViaf`** fills blanks only, through the same `FactSheet` the
Wikidata step uses:

| From the VIAF cluster | Written to | Notes |
|---|---|---|
| VIAF id, ISNI, LC, a Wikidata id (a bare `Q`-number) from the cluster's sources | `identifiers` | |
| Birth/death date | `birth_year` / `death_year` | Only when `dateType` is `lived` (a "flourished" span is not a birth or death) and the year is not BCE. VIAF's unknown markers -- `deathDate: 0`, the string `"0"`, and a partial date such as `"18XX"` -- are read as no year at all by `Viaf::Person#year_from`, so they are recorded `null`, never as a conflicting `0`. |
| Gender code `a`/`b` | `gender` | `u` (unspecified) is left unmapped, so it fills nothing -- the same "record, don't apply" treatment as any code `ApplyViaf` does not recognise. |
| Nationality codes | `books_author_countries` | Through `CountryLookup#from_iso` (an instance method). Fills only when the author has no countries at all yet -- the same all-or-nothing `FactSheet#countries` gate every source shares, not a rule specific to this one. |
| Main headings, inverted to natural order at the comma | `alternate_names` | Only a heading entered under a surname (`surname_first == true`, see `docs/features/viaf-api-client.md` for where that flag comes from) is turned into an alternate name at all -- "Willingham, Stacy" becomes "Stacy Willingham". A forename heading ("Marcus Aurelius, Emperor of Rome") is skipped here entirely, since inverting it would be wrong -- `ResolveViaf` shows it to the AI as written, but `ApplyViaf` never adds it as an alternate name. A heading with no entry-order indicator at all (nil -- BnF's UNIMARC style, for example) is skipped the same way, and so is a surname-entered heading with no comma in it ("Willingham Stacy"): there is no inversion to perform, so `ViafNames.natural` returns nil and it is dropped too. The Wikidata-built heading (source `WKP`) is skipped, and so is any heading that only reorders a name the author already has ("Mo, Yan" is Mo Yan, not "Yan Mo"). Latin script only, at most 10 added per run. |

**A held VIAF id that differs from the matched cluster applies nothing.** The whole apply step
stops after recording that one conflict (reason `held_viaf_conflict`) -- no identifiers, years,
gender, alternate names or countries are written for that run -- and the decision is flagged
`needs_review`, mirroring Wikidata's `held_qid_conflict`.

**When the cluster names a Wikidata item `ApplyViaf` newly stamps**, `ViafJob` enqueues
`WikidataJob.perform_async(author_id, true, true)` -- `refresh: true` because the earlier Wikidata
miss already counts as processed, `via_viaf: true` so a second miss cannot send the author back to
VIAF. An id the author already held, one another author holds, or one that conflicts sends
nothing.

**Pacing.** `Viaf::Client` is what `ResolveViaf` calls through: `suggest` (AutoSuggest, cached a
day) and `cluster` (the VIAF cluster fetch, itself cached in `external_records` regardless of
outcome), both behind `Viaf::Gate`. The gate closes every VIAF call -- held-id fetches included --
for one hour after a Cloudflare block, doubling on each repeat up to a day; a real VIAF answer
(one carrying budget headers) resets that doubling. It also closes for an hour whenever fewer than
50 of the day's requests are left. Either way `Viaf::Client#get` raises
`Viaf::Exceptions::RateLimited`, and `Books::Authors::ViafJob` reschedules itself for the wait plus
jitter rather than blocking a worker thread. A redirect hop is the one exception: resolving a
merged cluster, it waits for its own pace slot instead of raising, for up to about a minute,
since a hop that has already spent its 301 cannot be rescheduled without just repeating it.

**A rescheduled run repeats nothing it does not have to.** AutoSuggest answers are cached a day,
so a re-run's `suggest` call is free the same day. An ordinary (`refresh: false`) run also reads
every cluster it already stored from `external_records` -- `Viaf::Cluster` keeps *every* cluster
it reads, chosen or not, unlike Wikidata's resolver, which stores only the item it ends up
selecting -- so a run interrupted partway through resumes from where it left off, spending a
request only on the cluster it had not yet fetched. A forced (`refresh: true`) run would otherwise
refetch a cluster on every attempt regardless of whether it already has it: `Viaf::Client#cluster`
downgrades `refresh` to `false` for any cluster fetched within the last day (`REFRESH_WINDOW`), so
its rescheduled attempts read what an earlier attempt of the same run already fetched and spend
their share of the pace on the cluster still missing, rather than refetching the same one or two
clusters forever (see `docs/features/viaf-api-client.md`'s Caching section).

At 1-4 requests for a held id (the cluster plus any redirect hops) and, for a search, 1 `suggest`
plus 0-3 cluster fetches (each with its own possible redirect hops) -- about 3-5 requests on
average -- the roughly-1,000-a-day budget covers about 200-300 authors a day -- ample for imports,
with the backfill's VIAF share running in the background over months.

## Countries

**`books_author_countries`** is a plain join table: `author_id`, `country_id`, a unique pair, two
foreign keys. `Books::Author has_many :author_countries` and `:countries` (through). A merge
carries the source author's rows onto the target (`Books::Author::Merger#merge_author_countries`,
find-or-create so a shared country never raises a uniqueness error mid-merge). The same merger
also carries the enrichment ledger (`#merge_enrichments`, repointing every row's `enrichable_id`),
so a survivor that absorbed an already-enriched duplicate counts as processed too -- see "The
ledger" below, for the Wikidata and VIAF ledgers alike. Every `MatchDecision` naming the author
moves with it too (`#merge_decision_subjects`) -- Wikidata's and VIAF's both, since neither names a
`record`, only the author as `subject`, which the shared `RecordMerge` step (it follows
`record_id`) never reaches, so the merger repoints `subject_id` itself directly
(`app/lib/books/author/merger.rb`).

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

Every Wikidata run writes at most one `Enrichment` row, kind `books.author_wikidata`, provider
`wikidata`, linked to the `MatchDecision` it produced via `enrichments.match_decision_id` --
skips and failures included, once a decision exists (see the rate-limit case below, which can
write none). `mode` stays at its default and `model` is blank; this step makes no
AI-facts call of its own (the AI selection inside `ResolveWikidata` writes to the decision, not
the ledger, the same as every other `SelectCandidateTask`-style finder).

**"Processed"** means a `books.author_wikidata` row *newer than the author row* with outcome
`applied`, `nothing_to_apply`, or `unrecognized`. A `skipped` or `failed` row does not count, so
the author is tried again next time. This definition is deliberate: after the pre-launch
production re-migration truncates and re-creates the books tables (author ids preserved), every
old ledger row becomes older than the freshly created author row it now points at, so "processed"
compares against that re-created row and a re-run of the chain processes everyone again rather
than treating stale history as done. A merge can count too: `Books::Author::Merger` carries the
source author's ledger rows onto the survivor (`#merge_enrichments`), so a survivor that absorbed
an already-processed duplicate is processed without a run of its own *provided* the carried row is
newer than the survivor's own `created_at` -- the same "newer than the author row" check applies
here, and it is not guaranteed: a survivor created after the absorbed author's Wikidata run is not
covered by it and still gets picked up.

**A run that fails after already applying some Wikidata facts still records those facts** on its
`failed` row (the facts hash captured before the exception, not lost). `Wikimedia::Exceptions::Error`
(`app/lib/wikimedia/exceptions.rb`: network, timeout, HTTP, parse, and API-error responses) is
caught and written as a `failed` row with `reason: "wikimedia_error"`. `RateLimited` is
deliberately defined *outside* `Error` -- it is not a failure but a request to wait.
`EnrichFromWikidata` rescues it too: if a decision was already recorded this run (`ResolveWikidata`
had already decided a match or non-match before the wait hit -- from `CountryLookup` inside
`ApplyWikidata`, from `LinkWikipedia`, or from `CleanLegacyWikipedia`), it writes a `failed` row
with `reason: "rate_limited"` carrying whatever facts were applied before the wait, then re-raises;
a rate limit hit during resolution itself, before any decision exists, writes nothing -- there is
no decision yet to tie a row to. Either way the exception still propagates, and `WikidataJob`
catches it separately to reschedule the whole run with `perform_in(retry_after + jitter)`. A
`rate_limited` row does not count as processed (see above), so the rescheduled run still runs.

**A re-run is only cheap in the cases that decide early.** `ResolveWikidata` stores just the
*chosen* item in `external_records` (spec §3); a candidate that was fetched and considered but not
selected is never written there, so it is fetched fresh again on every later run that meets it.
That means a held-id run, or a run that resolves at the id-bridge stage, stays cheap on a re-run
-- the one entity it needs was the one a previous run chose and stored, so `entities` costs no
network call, even though the bridge search itself (`by_statements`) still runs live every time.
A run that falls through to the name-search stage is not cheap to repeat: every candidate the
search turns up is fetched again regardless of whether it was seen before, and the `works` SPARQL
query (`attach_titles`) is never cached at all, so it re-runs in full for every person-candidate
each time that stage is reached. This is worth sizing correctly before the increment-6 backfill:
authors who resolve by identifier stay cheap to re-touch, but the long tail that reaches AI
selection costs close to a fresh run every time.

**VIAF writes the same way.** Every VIAF run, matched or not, writes at most one `Enrichment` row,
kind `books.author_viaf`, provider `viaf`, linked to its own `MatchDecision` *once a decision
exists* -- a `placeholder` or `already_processed` skip writes before `ResolveViaf` ever runs, and a
`viaf_error` raised while resolving (before `ResolveViaf` reaches its own `record` step) writes
before a decision exists either, so both leave their row with no `MatchDecision` at all. The same
"processed" rule applies -- a `books.author_viaf` row newer than the author row, with outcome
`applied`,
`nothing_to_apply` or `unrecognized`, counts as done. Its own reasons: `resolve_failed` (the
resolver itself could not decide -- the AI selection call errored), `viaf_error` (a
`Viaf::Exceptions::Error`: network, timeout, HTTP, or parse), and `held_viaf_conflict` (a held
VIAF id disagreed with the matched cluster; recorded as `nothing_to_apply`, not `failed`, since
`ApplyViaf` did decide a match, it just applied none of it). A `RateLimited` run writes no row at
all: every VIAF call happens before `EnrichFromViaf` records anything, so an interrupted run
leaves nothing behind for the reschedule to un-see.

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

Run one VIAF pass by hand (only meaningful after a Wikidata miss):

```ruby
Services::Books::Authors::EnrichFromViaf.call(author: Books::Author.find(id))
# or, through the job:
Books::Authors::ViafJob.new.perform(author_id)
```

Check whether VIAF is currently paused, and what the last call reported for budget:

```ruby
Viaf::Gate.new.wait_seconds  # seconds until VIAF may be called again, or nil if it may now

c = Viaf::Client.new
c.suggest("Stacy Willingham")
c.last_rate_limit  # nil on a fresh instance, and nil above too if that suggest was cached today
```

Where to look:

- The books admin **Match Decisions** audit page, filtered to the "Wikidata link" entity, or to
  "VIAF link" for the VIAF step.
- `Enrichment.for_kind("books.author_wikidata")` / `Enrichment.for_kind("books.author_viaf")` --
  every run, its outcome, and its facts.
- `author.enrichments.for_kind("books.author_wikidata")` (or `"books.author_viaf"`) for one
  author's history.

There is no backfill rake task and no admin button yet -- both are increment 6. Today the only
way an author reaches this chain is through the author importer's async provider.

**Launch sequence.** Production's books data is a rehearsal copy: it gets truncated and
re-migrated more than once before launch (spec §14). The pre-launch truncate has to include
`books_author_countries` -- it carries foreign keys to both `books_authors` and
`books_countries`, so a truncate that forgets it either fails outright on the constraint or, if
run with `CASCADE`, silently drops rows that were never in the truncate list to begin with.
`data_migration:author_countries` then runs inside `data_migration:all` immediately after
`:countries`.

`external_records`, the enrichment ledger, and `MatchDecision` history all survive a re-migration
**by design** (spec §14): none of those tables are truncated, and they are keyed by external ids
and by author id rather than by anything the truncate reaches. What does *not* survive is
everything a previous run stamped onto the author row itself. `AuthorIdentifierMigrator` only
re-creates `books_author_openlibrary_id` from the legacy data, so if the truncate clears the
authors' identifiers along with the author rows, `books_author_wikidata_qid`, VIAF, ISNI, LC,
Goodreads and LibraryThing -- plus any alternate names, years, gender, or countries either a
Wikidata run or a VIAF run had filled in -- go with them. That means the held-id stage
(§Resolution) cannot fire on the first pass after a re-migration, since there is no held QID left
to check; more authors than before fall
through to the id-bridge or name-search stage. The Open Library key does survive, so the bridge
stage can still fire for the authors it reaches.

Every author runs again regardless: "processed" (above) compares a ledger row's timestamp against
the *re-created* author row, and every pre-migration row is now older than it, so nothing counts as
done. What that re-run actually costs is the story told above under "a re-run is only cheap in the
cases that decide early" -- not "already paid": losing the held QIDs, if anything, pushes *more*
authors into the name-search path that costs close to a fresh run.

**VIAF identifiers are lost the same way, and are cheaper to re-fetch.** `books_author_viaf`, ISNI
and LC on the author row do not survive a truncate and re-migration either, for the same reason as
the Wikidata id above -- `AuthorIdentifierMigrator` only re-creates the Open Library key. But
`external_records` rows for VIAF survive untouched (they carry no foreign key into the books
tables at all), and `Viaf::Cluster` keeps every cluster it ever reads, chosen or not (see "VIAF"
above) -- so a post-migration re-run reads every cluster a previous run already fetched straight
from the cache, spending none of the day's VIAF budget on it. What does repeat is the cheap part:
one `Viaf::Client#suggest` call per author (itself cached a day, so a same-day re-run of the same
name is free too), and the AI selection where resolution reaches it.
