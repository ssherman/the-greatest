# Books category and origin enrichment (design)

Date: 2026-11-02. Status: draft for owner review.

This is "Spec B" from `2026-10-11-books-category-cleanup-design.md` §9, widened to cover genres and
country of origin as well as subjects and locations. It builds on the enrichment framework
(`2026-09-24-books-ai-enrichment-framework-design.md`), the enrichment workflows
(`2026-10-20-books-enrichment-workflows-design.md`), the cleaned category vocabulary (category
cleanup + `2026-10-17-books-genre-cleanup-design.md`), and the WorldCat service
(`2026-10-11-worldcat-data-service-design.md`).

## 1. Why

The old site (`../the-greatest-books`, `admin/app/models/book.rb`) ran four per-book ChatGPT jobs on
every new book: `set_book_countries` (origin), `set_ai_genre_categories`,
`set_ai_subject_categories` and `set_ai_location_categories`. None of them came over to this app.
Today a new book gets genres, subjects and audiences only where a Goodreads shelf name matches one
of ours (`GoodreadsEnrichment::GenreMatcher` covers all three types), plus WorldCat links once its
backfill runs. It gets no locations at all, and its origin comes from one generic sentence in
`BookFactsTask`.

The old jobs were also not good enough to copy as they were. They sent only "Title by Author" and
find-or-created every answer, which produced 17k locations and 45k subjects (half of them singletons)
and books with 361 locations. The category cleanup fixed the vocabulary. This spec fixes how a book
gets its categories: collect what trusted sources already say about the book, give that evidence
to the model, apply only well-supported answers onto the existing vocabulary, and fall back to web
search only when nothing else knows the book.

What categories are for, in the owner's order (2026-10-11): browse and landing pages first,
similarity a close second. Origin drives the "Greatest French Novels" style pages, the country
facet, and the western-canon penalty.

## 2. Current state (dev, measured 2026-11-02)

| | |
|---|---|
| Books | 159,779 |
| Active categories | 96 genre, 3 audience, 10,712 subject, 15,029 location |
| Books with ≥1 genre / subject / location link | 137,651 / 117,454 / 75,757 |
| `category_items` on books by source | legacy 1,869,747 · inherited 129,513 · goodreads 452 · admin 8 |
| Origin "Unknown" / no country row | 31,803 / 22,326 (≈34% with no usable origin) |
| Books with 2 countries | 55 (everything else has exactly one) |
| Books holding a Goodreads id / ISBN-13 / OL work id / OCLC id | 155,752 / 137,777 / 34,639 / 15,701 |
| Books holding a `books_work_wikidata_qid` | 0 |
| Ranked books (primary config 8) | 21,260 |
| Books holding a *verified* ISBN-13 (`Identifier.verified`: open_library/worldcat source) | 17,826, all of them ranked (84% of ranked books; the `books:verify` ranked pass). Unranked books: 0 |
| Ranked books holding an OCLC id | 15,701 |
| Genres with a description | 58 of 96 |

Re-run these before acting; they describe a moment.

What exists that this spec reuses:

- `Services::Ai::Tasks::EnrichmentTask` / `BaseTask`, model roles in `config/initializers/ai.rb`
  (`fast`, `standard`, `premium`, `research` with web search), `research_daily_cap` (50/day, about
  15 cents each), and the `enrichments` ledger (one row per run, per-field facts in jsonb).
- `Workflows::Books::BookEnrichment` (version 2: `goodreads` → `book_facts`, `amazon`).
- `BookFactsTask` already returns `recognized`, `confidence`, `original_language`, `book_type`
  (recorded, not applied) and `origin_countries` (applied by `ApplyBookFacts#apply_origin_countries`
  only when the book has no country).
- `Services::Books::CountryLookup` (nationality adjective → `Books::Country`).
- `Services::Books::GoodreadsEnrichment::GenreMatcher` (name/alias → genre) and the Goodreads page's
  raw `genres`.
- `Books::WorldCat::Client#lookup` and `Services::Books::WorldCat::ApplyCategories` (genre map +
  subject name matching, `MIN_SHARE` rule).
- `Wikidata::Client` (`entities`, `by_statements` via `haswbstatement`, cached), and the author-side
  rule that Wikipedia is reached only through a confirmed Wikidata item (never text search).
  `Wikidata::Client#works` returns English title labels only, with no QIDs, so §4.3 step 4 needs a
  new query that returns work QIDs with their titles. `Wikipedia::Client` fetches only the
  plain-text intro (`exintro`); the infobox and plot section in §4.2 need new client code (the parse
  API). All Wikimedia traffic shares one 1 request/second pace (`config/initializers/wikimedia.rb`)
  with the author workflow.
- Location hierarchy with materialised ancestors (`Categories::AncestorReconciler`), the
  `Fictional Location` root, and `Services::Books::TrimLocations`.

## 3. Goals, non-goals, anti-goals

**Goals**

1. Every newly imported book gets origin, genres (including audience and book type), subjects and
   locations as part of its enrichment workflow, with no manual step.
2. Answers are judged from evidence (Wikidata, Wikipedia, WorldCat, Goodreads, our own record), not
   from the title alone.
3. Only well-supported answers are applied, and only onto existing categories.
4. Existing books are re-judged by a backfill: the 54k books without a usable origin get one, and
   legacy category links the new judgment rejects (with no source backing them) come off.
5. Every decision is explainable after the fact from the ledger: which evidence was shown, what the
   model said, what was applied and why.

**Non-goals**

- Creating categories. Proposals that match nothing are logged for an admin to act on.
- Changing the vocabulary (that was the cleanup), adding a subject hierarchy, or gazetteer ids.
- Author categories, series handling, music/games.
- Replacing Goodreads or WorldCat genre linking; they keep running and become evidence here too.

**Anti-goals (a failure even if it runs)**

- Re-creating the old over-tagging: a book with dozens of locations, or a near-universal subject
  like `Identity` stuck on every literary novel.
- A confident wrong answer winning over a source that knew better (for example, the model's guess
  of origin overriding a Wikidata country of origin that agrees with the author and the language).
- Removing a link a person or a library record put there.
- A backfill that runs up a bill nobody estimated, or runs inline in a terminal.

## 4. Design

### 4.1 Shape

One new per-book pipeline, three stages:

1. **Gather** evidence into a *dossier* (no AI, cached, cheap).
2. **Judge** with focused AI tasks that receive the dossier.
3. **Apply** with deterministic rules (confidence gates, source agreement, caps, never create).

It runs as new steps in `books.book_enrichment` (§4.9) and as a backfill (§4.10).

### 4.2 The dossier

A plain Ruby value object built by one service (`Services::Books::Categorize::Dossier` or similar;
naming is the builder's). Each source contributes a section, or `nil` when it has nothing. The
dossier is also written into the ledger row (trimmed) so a decision can be audited later.

| Section | Content |
|---|---|
| Our record | title, subtitle, authors (life years and countries, as `BookFactsTask#author_lines` already formats them; editors labelled), first published year, original language, book type genre held, primary description, current direct category links with their source |
| Wikidata work | QID, English label, country of origin (P495), language of work (P407), genre (P136), main subject (P921), narrative location (P840), set in period (P2408), form of work (P7937), publication date (P577); labels resolved to English |
| Wikipedia | through the Wikidata enwiki sitelink only: lead section, infobox fields (Country, Language, Genre, Set in, Subject), and the Plot/Synopsis/Summary section trimmed to a token budget |
| WorldCat | over the book's ISBN-13s, **only records that pass the identity check below**: mapped genres (via the genre map), subject headings in full (LCSH strings keep their geographic and period subdivisions, e.g. "World War, 1939-1945 -- France -- Paris -- Fiction"), the longest English summary, publication places and the earliest year among records |
| Goodreads | the matched page's raw genre shelf names (already cached in `Books::GoodreadsPage`) |
| Open Library | only the work description, and only when no other section supplies a description. OL subjects are not used (measured as junk: 54k distinct strings, 37k singletons, bestseller tags, call numbers) |

**WorldCat identity check.** The verification pass covered the ranked books: 84% of them hold
Open Library/WorldCat-verified ISBN-13s. The ~140k unranked books (and the remaining ranked 16%)
hold only legacy, Goodreads-import or Amazon ISBNs, some of which point at other books. So a WorldCat
record enters the dossier when its ISBN is verified, **or** its title matches the book's title or
an alternate title (normalised, ignoring subtitle) **and** its creator or a contributor matches one
of the book's authors by name key. Records that fail are dropped and counted in the ledger. For
ranked books this check almost never matters; it is what lets the unranked catalog use WorldCat
without waiting for an unranked verification pass. The builder may reuse the matching in
`Services::Books::Verification::ConfirmWithWorldCat` if it fits.

Sources that fail (timeout, 5xx) are recorded as `sources_failed` in the ledger and the judge runs
without them; a source failure does not fail the step. A step whose dossier has none of the external
sections and whose book is not recognized falls into the research path (§4.8).

### 4.3 Finding the Wikidata work

Never by text search. In order, stopping at the first hit that passes the check:

1. A stored `books_work_wikidata_qid` identifier.
2. `by_statements` on the book's ids: Goodreads book id (P2969; our `books_work_goodreads_id` is a
   `/book/show/` id, not a Goodreads work id, so P8383 is not usable), Open Library work id (P648),
   OCLC control number (P243).
3. ISBN-13 (P212) / ISBN-10 (P957) via `by_statements`; these usually land on an *edition* item, so
   follow "edition or translation of" (P629) to the work.
4. The works of the book's authors that already hold a `books_author_wikidata_qid` (a new client
   query returning work QID + English label, same P50/P800 shape as `#works`), matched on
   normalised title or one of the book's alternate titles.

**Check before accepting:** the item is a written work (instance of / subclass of literary work,
book, novel, poem, play, essay, written work and so on; not an edition, film, or scholarly
article), and if the item lists authors (P50), at least one is an author of ours (by QID, or by
name key when the author has no QID). A hit that fails the check is ignored, not stored.

An accepted QID is stored as a `books_work_wikidata_qid` identifier (the enum value exists, unused
today) so later runs and the backfill skip resolution. Step 4 is ambiguous when two works by the
same author share a title; in that case store nothing. If the QID is already held by another of
our books, that pair is very likely a duplicate: store it on neither, use no Wikidata evidence for
this run, and record the other book's id in the ledger (`qid_conflict`) so the duplicate report can
pick it up.

### 4.4 Judging origin

A new `Services::Ai::Tasks::Books::BookOriginTask` on the `standard` role, carrying the old site's
rules (`admin/app/lib/openai/chats/book_nationality_setup.txt`): original language first, then the
author's primary nationality at the time of first publication; when they disagree, the country of
the original language wins; for authors with several nationalities, the one matching the language;
one demonym adjective; "Unknown" rather than a guess; "Multiple" only when no single answer is
defensible. Keep the old worked examples (Lolita → American, Heart of Darkness → British, One
Thousand and One Nights → Multiple, and so on). Input: the dossier's record, Wikidata P495 and P407,
the authors' countries, WorldCat publication places and earliest year, and the Wikipedia infobox
Country field. Output: one country, a confidence, and a one-line reason.

**Shortcut, no AI call:** when Wikidata P495 names exactly one country, that country is among the
book's authors' countries, and the original language is a language of that country (a small
language → country table; the builder decides whether it lives in config or on `Books::Country`),
apply it directly with reason `wikidata_agrees`.

**One country per book**, as before (owner's existing data has 55 two-country books out of ~138k).
`origin_countries` in `BookFactsTask` stays as it is for now, but `ApplyBookFacts` stops applying
it once this step exists (the origin task supersedes it; the book_facts value is still recorded
and becomes one more piece of evidence in the dossier).

**Placeholders.** `Unknown`, `Multiple`, `Mixed` and `Mulitple` (the `CountryLookup::PLACEHOLDERS`)
are not usable origins. A book holding only placeholder rows is treated like a book with no country.
An `Unknown` or `Multiple` answer writes nothing (no new placeholder row) and is recorded with its
reason; an existing placeholder row stays until a real answer replaces it.

**Apply rules:**
- Book with no country, or only placeholders: apply a high-confidence answer, or a medium one that
  Wikidata P495 or the Wikipedia infobox agrees with. The real country replaces the placeholder rows.
- Book with a real country already: never overwritten automatically. When the new answer is high
  confidence, differs, and Wikidata P495 agrees with the new answer, record a `disagreement` in the
  ledger. The backfill report lists these for the owner to accept in bulk or one by one.
- Answers that `CountryLookup` cannot match are recorded as `no_match` with the raw string. Never
  create a country.

### 4.5 Judging genres, subjects and locations

A new `Services::Ai::Tasks::Books::BookCategoriesTask` on the `standard` role, one book per call
(owner, 2026-10-11: accuracy drops with batch size).

Input: the full dossier, plus the closed list of active genres and audiences with their
definitions. The owner already reviewed a definition for every kept genre and the three audiences
in `config/books/genre_plan.yml`; the genre apply never wrote them to `categories.description`.
Write them there as part of this work (an idempotent rake step), and have the prompt read
`categories.description`. Genres added since the plan with no definition are listed by the step
for an admin to fill.

Both judges also report their own `recognized` and overall `confidence`. Backfill and sync-added
books have no `books.book_facts` row, and this spec does not run `book_facts` on them (that would
also rewrite descriptions, subtitles and alternate titles). Where a `book_facts` row exists, its
values join the dossier as evidence; where it does not, the judges' own answers stand in.

Output, each item with a confidence (high/medium/low) and a short evidence note naming which
dossier section supports it:
- `recognized`, `confidence` (overall).
- `book_type`: fiction / nonfiction / poetry / religious.
- `genres`: ids from the closed list, at most 5.
- `audience`: Children's, Middle Grade, Young Adult, or none (there is no Adult audience).
- `subjects`: free-text names, at most 8, most important first. The prompt says what a subject is
  for (a browse page a reader would want this book on) and what it is not (themes so broad they
  describe most literary fiction, such as identity, love, or human nature, unless the book is
  centrally *about* that).
- `locations`: free-text places, at most 5, each marked `real` or `fictional`, with a parent hint
  ("Paris, France"; "Georgia, United States"). The most specific place the book is substantially
  set in. For nonfiction, the place the book is about. Never every place mentioned.

### 4.6 Mapping answers onto the vocabulary

Genres arrive as ids, so they need no mapping. Subjects and locations arrive as names and are mapped:

1. **Exact:** normalised name or `alternative_names` match on an active category of the right type
   (same normalisation the genre matcher uses). For locations, if more than one category matches,
   it is not exact: go to step 3.
2. **Merged:** a match on a merged category follows `merged_into_id`.
3. **Candidates:** otherwise retrieve up to ~10 candidates of that type, each shown with its ancestor chain for locations ("Georgia
   › United States" vs "Georgia › Caucasus"), and ask a `fast`-role
   `CategoryChoiceTask` to pick one or none for every unresolved name of the book in one call.
4. **No match:** logged in the ledger as `unmatched` with the proposed name. A rake report lists
   unmatched names by frequency so an admin can add aliases or categories later. Nothing is created.

A `fictional` place that matches no real category maps to `Fictional Location` only if it is the
book's main setting. A `real` answer never maps under `Fictional Location`.

### 4.7 Apply rules for categories

New `category_items.source` values: `ai` and `worldcat`. `WorldCat::ApplyCategories` is changed to
write `worldcat` from now on (today it writes the default `legacy`, which makes its links
indistinguishable from the old site's AI links).

**Adding links** (source `ai`):
- Apply a high-confidence answer, or a medium-confidence answer that an external dossier section
  supports (Wikidata, Wikipedia infobox, WorldCat mapped genre or a WorldCat subject heading
  containing the place or subject, Goodreads shelf through `GenreMatcher`).
- Low confidence is never applied.
- **Type genres.** Only Fiction and Nonfiction are mutually exclusive
  (`Books::Book::BOOK_TYPE_CATEGORY_NAMES`, the rule Goodreads and WorldCat already follow). Poetry
  and Religion & Spirituality are ordinary genres here and can sit beside either. Fiction or
  Nonfiction is applied only when the book holds neither, the judge's `book_type` is high
  confidence, and it agrees with the `book_facts` value when one exists. A judged type that
  conflicts with the held one is recorded as `type_conflict` and listed in the backfill report.
- **Caps** count the book's direct links of that type from every source: an `ai` link is added only
  while the book's total stays within 5 genres, 8 subjects, 5 direct locations (audiences: 1).
  Highest confidence first. Links from other sources are never removed to make room. Ancestors
  come from `AncestorReconciler`, which runs after every apply.
- **Confirmed legacy links** (the judge picked a category the book already holds as `legacy`) are
  re-sourced to `ai`, so a later run that happens not to pick it does not remove it.

**Removing links** (the re-judge; on the backfill, on books the weekly sync adds, and on admin
re-runs; a book created by this app's own importer has no legacy links to re-judge):
- Only `legacy` links. Never `admin`, `goodreads`, `worldcat`, or `ai` links; `inherited` is
  recomputed by the reconciler.
- Never Fiction, Nonfiction or audience links: a wrong one shows up as a `type_conflict` in the
  report instead, so a book is never left without a type.
- Only when the run was `recognized`, the task's overall confidence was high, and the dossier had at
  least one external section (Wikidata, Wikipedia, or WorldCat). A thin dossier removes nothing.
- A legacy link comes off when the judge did not pick that category (or a descendant of it, for
  locations) **and** no external dossier section supports it. Support uses the same test as for
  adding. So a legacy link that WorldCat or Goodreads backs stays, which also protects WorldCat links
  made before the `worldcat` source existed.
- Removals are soft in the ledger sense: every removed link is recorded with its old source, so a
  rake task can restore one run's removals.
- `item_count` and search reindexing follow the existing `Categories::ItemCounter` /
  `ItemReindexer` paths.

### 4.8 Web search fallback

The `research` role (web search) is used only when:
- the book is not recognized by `BookFactsTask` (or its own judge reports not recognized), **and**
- the dossier has no Wikidata, Wikipedia or WorldCat section,

or when the origin task returns low confidence for a book with no usable origin. In research mode
both tasks run in one combined research call (one web search session per book, not two), with the
instruction to prefer library, publisher and encyclopedia sources and to report what sources say.
Citations go in the ledger. When the cap is spent the book keeps whatever the knowledge-mode
answer allowed and is marked `deferred_research` so a later run can pick it up. A book first
published at or after `knowledge_cutoff_year` goes to research directly, as `BookFactsTask` does.

**Budget.** On an import, if `book_facts` already ran in research mode for this run, `categorize`
does not make a second research call: it runs in knowledge mode with book_facts' answer, citations
and description in the dossier. Import research counts against `research_daily_cap` as today. The
backfill gets its own cap, `config.x.ai.categorize_backfill_research_daily_cap`, default **0**, so a
backfill can never starve new imports of research; the owner raises it after the rehearsal measures
what research buys.

### 4.9 Workflow integration

`books.book_enrichment` version 3 adds two steps:

- `evidence` (queue `low`): resolves the Wikidata work (§4.3) and caches the WorldCat lookup and
  Wikipedia sections the judges need. Waits on `goodreads: :finish` (it reads the Goodreads page and
  ids). Its result names the QID found or `none`.
- `categorize` (queue `low`): builds the dossier, runs origin then categories, applies. Waits on
  `book_facts` and `evidence` (it needs the fresh description, language and book type).

Runs planned under version 2 have neither step and still complete. The existing step adapters
pattern (`Workflows::Books::Steps::*`) is followed. Each step writes one `enrichments` row per run
(kinds `books.origin` and `books.categories`; the builder may split the evidence step's record into
its own kind).

An admin "Re-categorize" action on the book page runs `evidence` + `categorize` outside a workflow
(like the existing Enrich With AI button), with re-judging on and an option to force research.

WorldCat increment 3 ("import-time seeding") is effectively delivered by the dossier: the import's
categorize step reads WorldCat directly. `ApplyCategories` is **not** run by the evidence step: its
links are permanent (no re-judge removes a `worldcat` link) and it has no identity check, which is
why `worldcat:backfill[all]` is on hold. WorldCat terms reach a book through this spec only as
evidence that the judge weighs.

**The WorldCat backfill becomes verified-only (owner, 2026-11-03).** The hold on
`worldcat:backfill[all]` exists because it would link categories through the unverified ISBNs of
~120k unranked books. Every verified ISBN-13 today belongs to a ranked book, so the safe part can
run now:

- `worldcat:backfill` looks up only `Identifier.verified` ISBN-13s, always. `Backfill` already takes
  a `scope:`; the rake task passes the verified scope. Books with no verified ISBN-13 are not
  processed.
- Accepted arguments: `[verified]` (every book with a verified ISBN-13) and `[<count>]` (the first
  N such books, for dev rehearsals). `[all]` aborts with a message pointing at `[verified]`, so the
  old command cannot be run by habit.
- It is additive and idempotent, so it is safe to re-run after any later verification pass adds
  verified ISBNs (including an unranked pass, if one is ever run).
- Unranked books never get WorldCat links through `ApplyCategories` while their ISBNs are
  unverified. Their WorldCat data arrives only as dossier evidence behind the identity check above.
- Docs in the same PR: launch-todo §9 step 15 becomes `bin/rails "worldcat:backfill[verified]"`
  (runnable now, no longer waiting on the ISBN cleanup), and the `docs/todo.md` "Books data quality"
  entry for `worldcat:backfill[all]` is removed. `docs/features/` text describing the backfill is
  updated to match.

### 4.10 Backfill

A rake entry point that enqueues per-book runs through Sidekiq (never inline), ordered: ranked books
in the primary ranking configuration first, then books with no usable origin or no genre, then the
rest. It accepts a limit, a scope (`origin_only`, `categories_only`, `all`), and a run label, and
paces itself so new imports are not starved (same approach as the author backfill's pacing). The
Wikimedia pace (1 request/second, shared with authors) is the real limit: at ~5-8 requests per book
the evidence pass over the catalog takes one to two weeks, so the pacing must leave room for the
author workflow and new imports. Research is limited by the backfill cap in §4.8.

**Skipping done books.** `enrichments` has no prompt-version concept today. Add one: each judge task
declares a `PROMPT_VERSION` constant, written into the ledger row's `facts`. The backfill and the
sync enqueue skip a book whose latest `books.origin` / `books.categories` row succeeded under the
current version, so re-running either is idempotent and a prompt change can re-judge deliberately.

**Rankings.** Filling ~54k origins changes `percentage_western` on lists and so the western-canon
penalty and the rankings. The origin backfill is followed by the usual weights and rankings
recalculation, written as an owner step in `docs/launch-todo.md` right after the backfill step.

A report task summarises a run: counts applied/removed/unmatched per type, origin disagreements,
top unmatched names, research spend, and a sample of before/after per book.

### 4.11 Rehearsal before any production backfill

In dev, after a snapshot:

1. Pick ~300 books: 100 top-ranked, 100 ranked mid-list, 100 unranked or recently imported (include
   some non-English-origin books, some nonfiction, some children's/YA).
2. Run the backfill over them with re-judging on.
3. Produce a side-by-side review (old links, new links, removed, origin before/after, evidence
   used) for the owner. The earlier genre worksheet artifact is the model.
4. Measure: cost per book by path (shortcut, knowledge, research), share of books that found a
   Wikidata work, share applied vs held back by the gates, removals per book.
5. Owner signs off on the prompts and gates, and on a cost estimate for the full catalog, before any
   production run.

## 5. Increments

1. **Evidence.** Wikidata work resolution and QID storage, Wikipedia sections (new client code),
   WorldCat lookup with the identity check, `worldcat` source on `ApplyCategories`, the verified-only
   `worldcat:backfill` (§4.9) with its launch-todo/todo doc changes, the `evidence` workflow step.
   Shippable alone: it stores QIDs, makes WorldCat links distinguishable, and unblocks launch-todo
   §9 step 15 for the ranked books.
2. **Origin.** `BookOriginTask`, shortcut, placeholder and apply rules, `ApplyBookFacts` stops
   applying `origin_countries`, origin part of `categorize`, prompt versions, origin backfill scope,
   rehearsal for origin, launch-todo steps (backfill, then rankings recalculation).
3. **Categories.** Genre definitions into `categories.description`, `BookCategoriesTask`, mapping +
   `CategoryChoiceTask`, apply and re-judge rules, `ai` source, admin action, categories backfill
   scope, rehearsal, report.

Each increment gets its own PR. The production backfill is an owner step in `docs/launch-todo.md`
and repeats after each weekly `data_migration:sync` only for books the sync added (they arrive
without workflow runs), so the sync's new-book list should enqueue `evidence` + `categorize` for
them. That enqueue must be idempotent: a book with a finished `books.categories` row from the
current prompt version is skipped.

## 6. Calls made in this design (owner did not decide these explicitly)

- One origin country per book, keeping the old rules and examples.
- Existing real origins are never overwritten automatically; disagreements are reported.
- Wikidata shortcut for origin when Wikidata, author nationality and language all agree.
- Open Library contributes only a fallback description, not subjects.
- Caps: 5 genres, 8 subjects, 5 direct locations.
- Re-judging removes only `legacy` links, only on a high-confidence recognized run with external
  evidence, and only links no source supports.
- Research fallback only when the book is unknown and no external source knows it; imports use the
  existing daily cap, the backfill its own cap defaulting to 0.
- Two workflow steps (`evidence`, `categorize`) rather than one per category type.
- `standard` role for both judges, `fast` for the candidate choice.
- WorldCat records are used for any ISBN that passes a title + author identity check, so the
  catalog does not wait on the ISBN cleanup; the categorize/evidence steps never run
  `ApplyCategories` themselves.
- (Owner decided 2026-11-03.) `worldcat:backfill` is verified-ISBN-only; `[all]` is retired and
  launch-todo step 15 runs `[verified]`.
- The backfill does not run `book_facts`; the judges report `recognized` and `book_type` themselves.
- Only Fiction/Nonfiction are mutually exclusive; type and audience links are never removed by a
  re-judge.
- Caps count all sources; confirmed legacy links become `ai`.
- Placeholder origins (Unknown, Multiple, Mixed) count as no origin; those answers write nothing.
- A Wikidata QID already held by another book is stored on neither and reported as a likely
  duplicate.
- Books added by the weekly sync are re-judged like backfill books.
- Origin backfill is followed by a rankings recalculation (owner step).

## 7. Left to the builder

- Class and file names; whether origin and categories are one adapter or two inside `categorize`.
- Candidate retrieval method for mapping. Neither obvious option exists yet: `pg_trgm` is not
  enabled (`schema.rb` enables only `plpgsql`) and there is no OpenSearch category index for books,
  only `ILIKE` scopes on `Category`. Enabling `pg_trgm` with a trigram index on `categories.name` is
  the likely route; any migration ships with its annotaterb update.
- Where the language → country table lives.
- Token budgets for the Wikipedia plot section and WorldCat subjects, and how the dossier is
  trimmed for the ledger.
- Backfill pacing numbers.
- Exact Wikidata "written work" class list for the §4.3 check.

## 8. Not in this spec

- New categories from unmatched proposals (report only).
- A location hierarchy for fictional places beyond `Fictional Location`.
- Using these signals for recommendations or similarity directly (they benefit automatically from
  better links).
- Other providers' web search (the separate research spike).
