# Import finder redesign: candidates, decisions, and an audit trail

**Date:** 2026-09-22
**Status:** approved design, awaiting implementation plans (one per increment)
**Related:** `docs/features/data_importers.md`, `docs/features/open-library-data-service.md`,
`docs/features/list-wizard.md`, `docs/features/record-merge.md`,
`docs/data-quality/books-duplicate-rows.md`,
`docs/superpowers/specs/2026-09-01-open-library-data-service-design.md`

## Problem

Every `DataImporters::*::Finder` answers "is this thing already in our catalog?" with a record
or `nil`. There is no third answer. When the evidence is ambiguous the finder returns `nil`,
`ImporterBase` creates a new record at `importer_base.rb:57`, and the catalog has a duplicate.
Nothing records what the finder considered or why it chose, so a wrong choice is invisible until
someone notices two rows.

Measured on the books data (`docs/data-quality/books-duplicate-rows.md`, 2026-09-05): 1,042
confident duplicate groups covering 2,209 rows, a floor rather than a count. 808 groups are
translations or spelling variants held under different titles, 128 are the same author name with
an exotic Unicode space, 106 share an identical title. The measurement doc's own conclusion is that
resolution at import time is the version that scales, because it only needs the incoming row to
resolve.

The state of the finders today:

| Finder | What it does | Gap |
|---|---|---|
| `Books::Book` | identifiers, then exact lower-cased title joined to an exact author name | any title or author variance creates a duplicate; never consults OpenSearch or the Open Library service |
| `Music::Artist` | MBID, else MusicBrainz search and trust the first hit, else exact name | first-hit trust; the MusicBrainz result is discarded, so the provider searches again |
| `Music::Album` | release-group MBID, else artist-scoped MusicBrainz search, first hit, else exact title | same |
| `Music::Song` | recording MBID, else `find_by(title:)` | matches any same-titled song by anyone |
| `Music::Release` | unreachable (multi-item imports never call a finder) | dead code |
| `Games::Game`, `Games::Company` | IGDB id only | a title-only import always creates |

Books has no list-import pipeline at all: the AI parser writes `lists.items_json` and stops, the
book importer has no caller, and the admin can link an unresolved list item to an existing book
but never create one. Music and games are duplicate-safe only because their wizards import items
that already carry a stable external id; the matching intelligence lives in the wizard enrichers
(`Services::Lists::BaseListItemEnricher` and subclasses), reimplemented per domain, not in the
finders. Copying that shape to books does not work: a parsed book item carries only title and
author strings, and the Open Library matcher abstains on two thirds of title-plus-author queries
by design.

## Goals

1. A finder returns a **decision**: matched or new, with a confidence, the candidates it
   considered, who decided (identifier, rule, AI, fallback), and a reason.
2. **Always decide.** A user adding a brand-new book to a list must never be refused. Uncertainty
   is a flag on the decision, not a stopping state.
3. **Every decision is recorded** and the low-confidence ones are reviewable in an admin UI.
4. **Local duplicates discovered along the way are recorded** as pairs, with a human verdict that
   is never re-raised.
5. **Candidates come from several sources**, unioned: Postgres identifiers, Postgres exact match,
   OpenSearch, and the domain's external service (Open Library, MusicBrainz, IGDB).
6. **Identifiers are evidence, not verdicts.** A tenth of the legacy Open Library keys no longer
   exist and 380 sit on more than one book. An identifier hit is decisive only when the record
   corroborates the query, and a `verify` option disables every early exit.
7. **Ranked records win ties.** When two candidates are the same entity, the one in the primary
   ranking is chosen and the pair is flagged.
8. **One contract for every domain.** Books, authors, music and games all move to it.
9. **An authors importer**, which does not exist today, so book imports can create and reuse
   authors.

## Non-goals

- A books list wizard UI. It is the natural first caller and gets its own spec.
- Batch reconciliation of the existing 157k books against Open Library. The finder catches
  duplicates incidentally; a bulk pass is separate work.
- VIAF enrichment of authors. The client exists; its two-requests-a-minute limit and the fact that
  choosing a VIAF cluster is itself a match decision keep it out of this spec (see Deferred).
- Retiring the wizard's AI validate step. It becomes partly redundant; leave it.
- Performance tuning. The finder mostly runs inside slow admin list imports; long runs are fine.
- tsvector columns or triggers. Postgres does exact lookups; OpenSearch does everything fuzzy.

## Prior art

The design follows the record-linkage literature and the operational patterns of the catalogs
we import from.

- **Fellegi and Sunter (1969)** define the three-way outcome every mature linkage tool implements:
  link, non-link, and possible link sent to clerical review
  (https://doi.org/10.1080/01621459.1969.10501049). Splink, Dedupe and Zingg all expose blocking,
  pairwise scoring, thresholds and a review band
  (https://moj-analytical-services.github.io/splink/topic_guides/theory/fellegi_sunter.html,
  https://docs.dedupe.io/en/latest/API-documentation.html,
  https://docs.zingg.ai/latest/stepbystep). Our "always decide, audit afterwards" is that model
  with the review band moved off the critical path; the decision log keeps the possible-link set
  intact.
- **Splink's blocking guidance**: "It's usually better to use a longer list of strict blocking
  rules, than a short list of loose blocking rules"
  (https://moj-analytical-services.github.io/splink/topic_guides/blocking/blocking_rules.html).
  Sources here are unioned, never sequenced, except that a corroborated identifier hit ends the
  search.
- **LLM entity matching.** Wang et al., "Match, Compare, or Select?" (arXiv:2405.16884) measured
  that presenting several candidates and asking the model to select one or none beats pairwise
  yes/no prompting: GPT-3.5 mean F1 across eight datasets rose from 64.0 to 81.6, at less than
  half the cost. Their caveat is position bias, so candidates are ordered by evidence strength
  and the list is kept short; their best pipeline keeps the top four. Peeters and Bizer
  (arXiv:2310.11244) found attribute-value serialization with minimal attribute names works best
  and that prompt wording matters more for small models.
- **Never re-raise a dismissed pair.** Open Library's merge queue (`community_edits_queue`)
  records `DECLINED` requests and refuses a new request for the same record set
  (https://github.com/internetarchive/openlibrary/blob/master/openlibrary/core/edits.py).
  Wikidata's `different from` (P1889) blocks tool-driven merges
  (https://www.wikidata.org/wiki/Property:P1889). Reltio, Tamr and FamilySearch all persist a
  "not a match" verdict so the pair stops surfacing
  (https://support.reltio.com/hc/en-us/articles/4403208429453-Anatomy-of-a-Match-Rule,
  https://docs.tamr.com/new/docs/working-with-record-pairs,
  https://www.familysearch.org/en/help/helpcenter/article/how-do-i-show-that-duplicates-are-not-a-match-in-family-tree).
- **MusicBrainz** surfaces suspected duplicate artists as a generated report, resolved by a merge
  edit or a disambiguation comment (https://musicbrainz.org/doc/Merge,
  https://musicbrainz.org/report/DuplicateArtists). A table with a verdict is the stronger shape.

## Design

### 1. The contract

`FinderBase#call(query:, verify: false, subject: nil, exclude: nil)` returns a `Match`. `exclude`
names one local record that every source drops from its results, so a record can be resolved
against the rest of the catalog (the duplicate sweep in Section 16).

```ruby
Match
  outcome              :matched | :unmatched   (the spec's "new"; an enum value `new` would shadow MatchDecision.new)
  record               the local record, or nil when :new
  confidence           :certain | :high | :medium | :low
  decided_by           :identifier | :rule | :ai | :fallback
  reason               one sentence
  candidates           [Candidate], in the order the AI saw them
  external             the best external candidate to hydrate from when :new, or nil
  external_resolution  the whole external response when a source returned one
                       (books: the Open Library Resolution), so a provider can reuse it
  decision             the persisted MatchDecision
  needs_review?        confidence medium or low, or decided_by :fallback
```

A `Candidate` is one thing the finder considered:

```ruby
Candidate
  record          local record or nil
  external_key    "OL123W" | MBID | IGDB id | nil
  external_record the source's value object (Books::OpenLibrary::Candidate, a MusicBrainz hash, ...)
  sources         [:identifier, :exact, :opensearch, :open_library, :musicbrainz, :igdb]
  scores          {opensearch: 12.4, open_library: 0.91, ...}
  evidence        {title:, creators:, year:, ranked_position:, identifiers: [...], ...}
  decisive?       true for a corroborated identifier hit or an Open Library accept on a held key
  ranked?
```

Candidates are merged by local id or external key. An external candidate whose key a local
record carries becomes one candidate with both halves.

`FinderBase#call` runs four fixed stages. A domain subclass supplies only what differs:
`candidate_sources(query)`, the identifier types in priority order, `describe_query(query)` and
`describe_candidate(candidate)` for the AI prompt, domain guidance text for the prompt, the
ranking configuration class that defines "ranked", and the normalization used for "creators
agree" and "titles agree".

1. **Gather.** Run each source, union, merge. A `decisive?` candidate stops gathering unless
   `verify` is set. A source that raises contributes nothing and is named in `sources_failed`.
2. **Rules.** Section 3.
3. **AI.** Section 4, only when rules could not decide.
4. **Record.** Always write a `MatchDecision`. Write `DuplicateCandidate` rows for any two local
   records judged the same entity.

The finder never creates or mutates catalog records, is callable on its own (the wizard
enrichers call it directly), and is not transactional.

### 2. Candidate sources

Sources are small objects with `#name` and `#call -> [Candidate]`, built by the finder with what they need. Three are shared:

- **`Sources::Identifiers`.** Postgres lookup on `Identifier` for the query's values, in the
  domain's priority order, through the existing `(identifiable_type, value)` index. Two local
  records carrying the same value both come back (the unique index includes `identifiable_id`, so
  it allows that). Marks candidates decisive only when corroborated (Section 3).
- **`Sources::Exact`.** One Postgres query: normalized title or name equality, joined to a creator
  whose name or alternate name matches when the query has creators. This is today's books
  fallback made normalization-aware, kept because the search index is written by a queued job and
  a record created seconds ago is not yet searchable. A migration adds a btree expression index
  on `lower(title)` for books, albums, songs and games and on `lower(name)` for authors and
  artists where one does not already exist.
- **`Sources::OpenSearch`.** The domain's title-plus-creators dedup query, top five, records
  loaded with creators, identifiers and ranked position. `AlbumByTitleAndArtists`,
  `SongByTitleAndArtists` and `GameByTitleAndDevelopers` exist; `BookByTitleAndAuthors`,
  `AuthorByName` and `ArtistByName` are new, each a clone of the album query. No mapping changes.

Domain sources return external candidates and look up whether any key is already held locally:

| Domain | Source | Verdict? |
|---|---|---|
| Books::Book | `POST /resolve` on the Open Library service, limit 5 | yes: accept / abstain / reject |
| Books::Author | `GET /authors/{key}` when the query carries a key | no |
| Music::Artist | `ArtistSearch#search_by_name`, top 5 | no |
| Music::Album | `ReleaseGroupSearch` scoped to the artist MBID, primary albums first, top 5 | no |
| Music::Song | `RecordingSearch` by artist and title, top 5 | no |
| Games::Game | IGDB `search_by_name` with expanded fields, top 10 | no |
| Games::Company | none | |

### 3. Decision rules

The first rule that applies wins.

1. **Corroborated identifier hit** → matched, certain, decided_by identifier. Corroboration: the
   creators agree, or the normalized title agrees, or the query carried nothing to compare (an
   identifier-only import). An identifier hit whose record disagrees on both stays a candidate
   with its identifier in the evidence, gathering continues, and the AI decides. Several
   corroborated hits: prefer the ranked one, then the one on more lists, then the oldest; the
   rest are flagged as duplicate candidates with source `identifier_collision`.
2. **Open Library accept on a key a local record holds**, corroborated the same way → matched,
   certain. Books only.
3. **No candidates from any source** → new, high.
4. **Exactly one local candidate with equal normalized title, agreeing creators (alternate names
   count), and no year conflict** → matched, high, decided_by rule. A year conflict means both
   years present and more than two apart.
5. **Open Library accept on a key nobody holds, and no local candidates** → new, high, external
   set to the accepted work. Books only.
6. Otherwise → **AI**.

Under `verify: true`, rules 1 and 2 do not fire and every source runs; the decision records that
it was made under `verify`.

**"Agree"** has one definition everywhere. Creators agree when at least one of the query's
creators matches one of the candidate's by normalized name or alternate name. Titles agree when
the normalized titles are equal, or the query title equals one of the candidate's alternate
titles. Rule 4 requires creator agreement only in domains whose entities have creators (books,
albums, songs); a query with no creators in those domains goes to the AI, because a bare title is
ambiguous there. Authors, artists, games and companies apply rule 4 on the title or name alone.

**"Ranked"** is `RankedItem.exists?(item:, ranking_configuration: <domain>::RankingConfiguration.default_primary)`;
`Books::Book` and `Books::Author` already expose it as `primary_ranked_item`. The position is
evidence; the boolean is the tie-breaker.

**Normalization.** A new `Services::Text::NameNormalizer` applies NFKC, folds every Unicode space
separator to a plain space, collapses runs and strips. It is chained after the existing
`QuoteNormalizer` in `Books::Author#normalize_name` and `Books::Book#normalize_title`, and used
for every "agrees" comparison and for search text. The 128 whitespace duplicate groups came from
an exact-string author lookup on names containing U+202F.

### 4. The AI selection step

`Services::Ai::Tasks::Matching::SelectCandidateTask`, one gpt-5-mini call through the existing
`BaseTask` framework, following the select-one-or-none pattern:

- **Input:** the query described in one line, then the candidates numbered from 1, ordered by
  evidence strength (local and multi-source first, then externals by score), at most six, each
  on one line in a fixed field order: title or name, creators, year, `ranked #n` when ranked, `in
  our catalog` or the external source and key, `shares <identifier type>` when it shares an
  identifier with the query, and the Open Library verdict when there is one. Field labels are
  minimal. The system message says identifiers in
  our data are sometimes wrong, that two candidates may be the same entity, and that when they
  are, the ranked one is preferred. Each domain adds a short guidance paragraph (games: prefer
  the original over remakes and DLC unless the query says otherwise).
- **Schema:** `selected_index` (Integer, 0 for none), `confidence` (`high | medium | low`),
  `reasoning` (String), `same_entity_groups` (arrays of candidate numbers the model believes
  are the same entity).
- **Interpretation:** a local candidate selected → matched. An external-only candidate selected →
  new, with that external set. None → new. Confidence maps straight onto the decision; medium
  and low set `needs_review`.
- **Post-rule:** if the selection is in a same-entity group with a ranked local candidate, the
  ranked one wins and the reason says so. Every same-entity group containing two local records
  raises a duplicate candidate with source `ai`, unless a human has already ruled that pair
  `not_duplicate`, in which case the group is ignored for the ranked-preference too.
- **Failure** (exception, invalid schema, out-of-range index): new, confidence low, decided_by
  fallback, the error in the reason. The import proceeds; the decision lands in the audit queue.

The task takes a serializable case (the query description plus the candidate lines and
evidence) and returns the selection. A future agent loop, in Strands or LangChain, replaces this
one class.

### 5. Data model

**`match_decisions`**, one row per finder call.

| Column | Type | Purpose |
|---|---|---|
| `finder` | string, indexed | finder class name; filters by domain and entity |
| `record_type`, `record_id` | polymorphic, nullable, indexed | the matched record, or the created one once the importer saves it |
| `subject_type`, `subject_id` | polymorphic, nullable, indexed | what the caller was resolving for (a list item), via `Importer.call(..., subject:)` |
| `outcome` | enum: matched 0, unmatched 1 | |
| `confidence` | enum: certain 0, high 1, medium 2, low 3 | |
| `decided_by` | enum: identifier 0, rule 1, ai 2, fallback 3 | |
| `verify` | boolean | early exits disabled |
| `query` | jsonb | the query fields as sent |
| `candidates` | jsonb | array of `{record_type, record_id, external_source, external_key, sources, scores, evidence}` |
| `selected_index` | integer, nullable | 1-based, as the AI saw it; nil for none (the AI's 0 is stored as nil) |
| `reason` | text | |
| `ai_chat_id` | bigint, nullable, FK | the prompt and response |
| `sources_failed` | string array | |
| `needs_review` | boolean, indexed with `reviewed_at` | |
| `reviewed_at`, `reviewed_by_id`, `review_note` | | the audit verdict |

Index on `created_at` as well. The importer updates `record` after it saves a new item.

**`duplicate_candidates`**, one row per suspected pair of local records.

| Column | Type | Purpose |
|---|---|---|
| `item_type` | string | both records share it |
| `item_a_id`, `item_b_id` | bigint | check constraint `item_a_id < item_b_id`; unique with `item_type` |
| `source` | enum: identifier_collision 0, external_key_collision 1, ai 2, human 3, bulk_verify 4 | |
| `status` | enum: pending 0, merged 1, not_duplicate 2 | |
| `evidence` | jsonb | scores, reasoning, identifier values |
| `occurrences` | integer, default 1 | how many finder calls raised it |
| `match_decision_id` | bigint, nullable, FK | the first decision that raised it |
| `resolved_at`, `resolved_by_id`, `resolution_note` | | the human verdict |

No foreign keys on `item_a_id`/`item_b_id`, matching `ranked_items`. Flagging goes through
`find_or_initialize_by` on `(item_type, item_a_id, item_b_id)`: a pending row gains an occurrence
and merged evidence; a `merged` or `not_duplicate` row is left untouched.

### 6. Importer and provider changes

`ImporterBase#call` changes in three places: `existing = finder.call(query:, verify:,
subject:).record`; the match is passed to providers; after a new item is saved,
`match.decision.update!(record: item)`. `ImporterBase.call` accepts `subject:` and `verify:` and
passes them through to the finder.

`ProviderBase#populate(item, query:, match: nil)`. All thirteen providers take the new keyword.
The MusicBrainz artist, album and song providers and the IGDB game provider hydrate from
`match.external` when the query carries no identifier instead of searching again. The Open
Library book provider reuses `match.external_resolution` for a new book (Section 8). Amazon, cover
art and AI description ignore the match.

`Music::Release::Finder` is deleted.

### 7. Mergers

Each of the six mergers (`Books::Book`, `Books::Author`, `Music::Album`, `Music::Artist`,
`Music::Song`, `Games::Game`) gains one call inside its transaction,
`Services::DuplicateCandidates::RecordMerge.call(item_type:, source_id:, target_id:)`, which marks the
`(source, target)` pair `merged`, repoints every other open pair from the source id to the target
id (dropping any that would now pair the target with itself or collide with an existing row), and
repoints `match_decisions.record` from source to target. `Books::Book::Merger` already folds the
source title into the survivor's `alternate_titles`, which is what makes a merged-away wrong
"new" findable by OpenSearch next time.

### 8. Books

**Query** is unchanged: `title`, `author_names`, `year`, `isbn13`, `isbn10`, `asin`,
`goodreads_id`, `open_library_work_key`.

**Sources, in order:** identifiers (Open Library key, ISBN-13, ISBN-10, ASIN, Goodreads);
exact (normalized title joined to author name or alternate name); OpenSearch
`BookByTitleAndAuthors` (title must, `alternate_titles` and `author_names` as boosts, a small
boost for `first_published_year` within one; authors optional, with a higher minimum score when
absent); Open Library resolve with `limit: 5`. Every returned candidate carries verdict, score,
margin, rules hit, authors and year in its evidence; a candidate whose key a local book holds
merges into it. The whole `Resolution` is kept on the match as `external_resolution`.

**Provider.** Same fills-only writes and identifier stamping as today. For a new book it reuses
`match.external_resolution` rather than calling `/resolve` again; an existing book under
`force_providers` resolves from its own state as today. New: an author step. On accept for a book
with no authors, each author on the accepted work goes through the author importer
(`name:`, `open_library_author_key:`, `work_titles: [book.title]`) and is linked through
`book_authors` with `find_or_initialize_by`, in Open Library's order. When the service abstains
or rejects, the query's `author_names` go through the author importer by name. A book that
already has authors is left alone, the same ruling as the merger. This closes the documented
gap where a title-plus-author import was not idempotent.

**One-off task:** normalize every stored title and author name the save-time normalizer would
change, in place (`docs/data-quality/books-normalizer-effect.md`).
Any duplicate pairs that fall out go to the duplicates queue; nothing is merged automatically.

### 9. Authors

New: `DataImporters::Books::Author::{ImportQuery, Finder, Importer, Providers::OpenLibrary}`.

**Query:** `name` (required unless a key is given), `open_library_author_key`, `birth_year`,
`death_year`, `alternate_names`, `work_titles` (context, not matched on).

**Sources:** identifiers (`books_author_openlibrary_id`, `books_author_viaf`,
`books_author_isni`, `books_author_wikidata_qid`, `books_author_lcnaf`; only the first is
populated today); exact on normalized name or `alternate_names` (GIN-indexed); OpenSearch
`AuthorByName` over the existing authors index (`name` must, `alternate_names` boost); and the
Open Library author record by key when the query has one, as evidence (alternate names, years)
and as the external candidate. No external name search: the service has none, and VIAF cannot
sit on an import path.

**Evidence per candidate:** name, alternate names, birth and death years, kind, up to five book
titles, ranked position. The query side carries the `work_titles`. That is what separates the
two Hertzes and the two McNeils in the measured data.

**Rules:** the shared ones. Rule 4 for authors is equal normalized name and no year conflict.
That is a deliberate trade-off: two different authors with the same exact name and no dates on
either side would be matched. The alternative, a new author row on every re-import, is the old
app's failure mode.

**Provider:** Open Library by key (from the query or the match's external). Fills blank
`birth_year` and `death_year`, unions `alternate_names`, stamps `books_author_openlibrary_id`.
Never touches `name`.

### 10. Music

- **Artist:** identifiers (MBID); exact name; `ArtistByName`; MusicBrainz artist search.
  Evidence: name, disambiguation, type, country, life-span years, MusicBrainz score; local
  candidates add ranked position and a few album titles.
- **Album:** identifiers (release-group MBID); exact title within the artist;
  `AlbumByTitleAndArtists`; artist-scoped release-group search keeping the primary-albums-first
  preference. Evidence: title, artist credits, first release year, primary and secondary types,
  ranked position.
- **Song:** identifiers (recording MBID); exact title plus artist; `SongByTitleAndArtists`;
  recording search by artist and title.
- **Release:** finder deleted.

### 11. Games

- **Game:** identifiers (IGDB id); exact title; `GameByTitleAndDevelopers`; IGDB search, top ten
  with the expanded fields. Evidence: name, first release year, developers, cover presence,
  ranked position. `Services::Ai::Tasks::Games::IgdbSearchMatchTask` retires; its guidance moves
  into the game finder's prompt text.
- **Company:** identifiers and exact name, rules only, never AI.

### 12. Wizard enrichers

`Services::Lists::BaseListItemEnricher#call` builds the domain query from the item's metadata
(title, artists or developers, year), calls the finder with the list item as `subject`, and
writes the result:

- matched → `listable_id`, plus `match_source`, `match_confidence`, `match_decision_id` in
  metadata;
- new with an external candidate → the same metadata keys the import step and review components
  already read (`mb_release_group_id`, `mb_recording_id`, `igdb_id`), plus the decision keys;
- new without one → the decision keys only; the row stays unlinked.

The music and games subclasses lose `find_via_musicbrainz`, `find_via_igdb` and
`select_best_igdb_match`. Wizard step stats derive from `decided_by` and the candidate sources.
`BaseWizardImportJob` is unchanged: it imports by external id, and the identifier rule makes that
idempotent. The AI validate step stays.

### 13. Audit UI

Two admin pages per domain under each domain's admin namespace, sharing
`Admin::MatchDecisionsBaseController` and `Admin::DuplicateCandidatesBaseController`, scoped by
the `finder` prefix, with the existing domain-scoped authorization: read needs the domain admin
role, review and merge need write.

**Match decisions.** Index opens on needs-review and unreviewed; filters for entity, outcome,
confidence, decided-by, reviewed; path-based pagination. Row: when, the query in one line,
outcome, chosen record, confidence, decided-by. Show: the query, the candidate table with the
selected row highlighted (local or external, title or name, creators, year, ranked position,
sources, scores, shared identifiers), the reasoning, links to the AI chat, the record and the
subject. Actions: **Mark reviewed** with a note; **Re-check**, which runs the finder again with
`verify: true` synchronously and shows the new decision beside the old; **Merge into candidate
N**, offered only when the outcome was new and candidate N is local, posting to the domain's
existing merge action with the created record as source, behind the same confirm checkbox as the
merge modal.

**Duplicate candidates.** Index lists open pairs side by side (title or name, creators, year,
ranked position, list count, identifiers) with the evidence summary and occurrence count. Per row:
**Not a duplicate** with a note; **Merge A into B** and **Merge B into A**, each posting to the
existing merge action behind the confirm checkbox. A status filter shows merged and dismissed
pairs.

### 14. Failure handling and cost

A fuzzy source that raises contributes nothing, is named in `sources_failed`, and caps a `high`
confidence at `medium` so the decision is reviewed. A `certain` decision stands: it comes from a
corroborated identifier hit (or, in increment 1, the legacy lookup), which is complete identity
evidence a failed fuzzy source cannot weaken, and gathering stops at a decisive hit anyway. A
Postgres failure raises. An AI failure takes the fallback. A decision that cannot be written
raises; that is our own database.

Worst case for a book is roughly twelve seconds (five or six for the resolve, a few for the AI).
Anything on a request path runs the finder in a job; bulk callers serialize Open Library calls
through the `serial` queue as the service doc already says. AI spend is cents per hundred
ambiguous decisions. Enrichment of a mostly-ambiguous 500-item music list moves from about ten
minutes to tens of minutes in the background, which is accepted.

### 15. Testing

- Unit tests per shared source, with search classes and clients stubbed at the class level the
  way `test/lib/books/book_search_query_test.rb` does.
- A table-driven rules test covering every rule, corroboration, `verify`, the tie-break order,
  and the wrong-identifier case: an identifier hit on a record whose title and creators both
  disagree must reach the AI, never certain.
- Per-domain finder tests whose fixtures carry a negative class: same title different creator,
  same creator different title, near-spelling, a translated alternate title, an identifier
  collision. Every rule test must go red when its rule is removed.
- The selection task with a stubbed provider: schema, index bounds, same-entity groups, the
  ranked post-rule, the fallback.
- Decision recording; duplicate flagging with never-re-raise and occurrence counting; the merger
  hook on all six mergers; `ImporterBase` with a stub finder and the `record` update; the
  provider signature change; the rewritten enricher tests.
- Controller tests assert behaviour only. One Playwright spec on the books admin host seeds one
  decision and one pair against two development books through a rake helper, exercises the
  filters, marks reviewed, dismisses a pair, drives a merge to the confirm gate and stops, then
  removes what it seeded. It never performs a merge.
- `CI=1 bin/rails zeitwerk:check` for the new `app/lib` directories; no new warnings; standardrb.

### 16. The duplicate sweep

The finder resolves an existing record against the rest of the catalog when called with the
record's own fields and `exclude:` set to it. A `Books::FindDuplicatesJob` on the `serial` queue
loops the books in the primary ranking and, for each, builds a query from the book's title,
author names, year and identifiers and calls the finder with `verify: true`, `subject: book`,
`exclude: book`. A `matched` outcome means another local book is the same work: the job raises
the pair `(book, match.record)` with source `bulk_verify` and the decision's reason as evidence.
Same-entity groups from the AI raise their pairs as usual. Nothing else is written; the finder
never runs providers. The pairs go to the duplicates queue with the rest and obey the same
never-re-raise rule.

With the Open Library source on, the sweep costs about six seconds a book, serialized, so a
ranked set of ten thousand is a couple of days of background work. That source is also what finds
translations held under another title, so it stays on.

The sweep gathers, for every ranked book, exactly the evidence a "should this be
`book_kind: collection`" classifier would want (the Open Library work record, subjects, edition
counts). That classifier is a separate AI task on the same candidate case, not a finder decision,
and is future work.

## Increments

Each gets its own plan under `docs/superpowers/plans/`.

1. **Core.** `Match`, `Candidate`, the `FinderBase` pipeline, the three shared sources, the rules
   with corroboration and `verify`, `SelectCandidateTask`, both tables and models, the provider
   signature change across all providers, the merger hook on all six mergers, the expression
   indexes, `NameNormalizer`. Every existing finder is reshaped to return a `Match` while keeping
   its current lookup logic (the music finders' MusicBrainz calls included), so behaviour does
   not change and the suite stays green. The Release finder is deleted.
2. **Books.** `BookByTitleAndAuthors`, the Open Library source, the provider reusing the
   resolution, the whitespace one-off task, and the duplicate sweep job.
3. **Audit UI.** Both pages per domain and the E2E spec, so books imports are auditable as soon
   as they exist.
4. **Authors.** The importer, finder and provider, and the book provider's author step.
5. **Games.** The game finder's full pipeline, company on rules, the enricher delegating, the
   IGDB task retired.
6. **Music.** Artist, album and song finders, `ArtistByName`, providers hydrating from the match,
   enrichers delegating.

## Deferred

- **VIAF author enrichment.** An async job on the `serial` queue that runs `AutoSuggest` by name
  and dates, feeds the suggestions through `SelectCandidateTask` as candidates, and stamps
  `books_author_viaf`, `books_author_isni`, `books_author_wikidata_qid` and `books_author_lcnaf`
  from the chosen cluster. Everything it needs exists after increment 4.
- **Books list wizard.** The first real caller; its own spec.
- **A `book_kind: collection` classifier** riding on the sweep's evidence (Section 16).
- **Stale local Open Library keys.** A local key that redirects or no longer exists never matches
  the canonical key the service returns. A backfill through `redirects` is separate data work.
- **Retiring the wizard AI validate step**, and stamping an external key onto a local record when
  the AI says a local candidate and an external candidate are the same entity.
- **An agent loop for the decision step**, replacing `SelectCandidateTask` behind the same case
  boundary.

## Decisions made during brainstorming

- **Scope: engine plus authors; the wizard UI is a follow-on.** The engine is what the wizard, the
  user-facing add-a-book flow and bulk jobs all need.
- **Always decide.** A user adding a brand-new book must not be refused; ambiguity is audited
  afterwards. Chosen over abstain-to-queue and over lean-toward-matching.
- **One structured call now, an agent loop later.** The selection task takes a serializable case
  so the swap touches one class.
- **All domains now.** The contract is introduced for every finder in increment 1 with no
  behaviour change (each keeps its current lookups behind the new return type), and each
  domain's full pipeline lands in its own increment.
- **Identifiers are evidence.** Corroboration on every identifier hit, plus `verify`.
- **Postgres and OpenSearch, no tsvector.** Expression indexes on `lower(title)` and
  `lower(name)` for the exact source.
- **Performance is not a constraint.** The finder mostly runs inside slow admin list imports.
- **Three names changed at implementation:** outcome `unmatched` (not `new`), pair status `pending` (not `open`), and sources take no argument on `call`. Increment 1's plan explains each.
- **The failed-source cap spares `certain` decisions** (declared at implementation; see §14).
- **Rule 4 counts exact-matching locals** (declared in increment 2): the rule fires when exactly one local candidate passes the exact test, whatever else the fuzzy sources returned; two exact locals go to the AI. Increment 1 had read it as "exactly one local candidate, and it is exact", which would have sent nearly every import with an OpenSearch neighbour to the AI.
- **Increment 2 readings** (declared at implementation): `alternate_titles` sits inside the required title group of `BookByTitleAndAuthors`, so a merged-away title satisfies the search; the Open Library source treats a local book holding a key in the work's `redirected_from` list as a holder of that work; the one-off normalization covers every row the save-time normalizer would change (1,965 titles, 3,436 author names measured 2026-09-23), not only the 365 with exotic spaces; `U+00B4` joins `QuoteNormalizer`; the sweep is one job per ranked book rather than one looping job; the one-off's collision pairs use source `bulk_verify`.
