# Books subject and location cleanup — design (Spec A)

Date: 2026-10-11 · Branch: `worktree-books-category-cleanup`

## Goal

Turn the books `subject` and `location` categories into a clean, canonical vocabulary, and make
the machinery that keeps them clean (merging, redirects, a location hierarchy) safe to use. Genres
are out of scope; another piece of work owns them.

This is the first of two specs. **Spec B** (next, separate) ports AI subject and location
*assignment* into the books enrichment framework and re-judges existing per-book links. Spec B
maps its answers onto the vocabulary this spec produces, which is why this one goes first.

What subjects and locations are for, in priority order (owner, 2026-10-11): browse and landing
pages ("The greatest books on War", "Set in Paris") first, similarity and recommendations a close
second. Both matter. So every browse-worthy category must have one clean name, and specific tags
that only help similarity are kept rather than pruned.

Success:

- No live books subject or location has a truncated or broken name (`Japan (`, `61)`), a case or
  punctuation twin, or the wrong type (`Hope` as a location).
- Every real location has a parent chain up to a continent or region, and a book linked to a city
  is also linked to its region, country and continent.
- Merging or renaming a category never produces a 404, never empties a saved search, and never
  makes the weekly legacy sync drop a link.
- No book has more than 15 direct location links (today: 1,653 books over 25, max 361).
- The cleanup is a reviewable plan: nothing changes until the owner has seen counts and samples
  and run apply.

## Problem

### The data (dev, 2026-10-11)

| | live | on 0 books | on 1 book | on 2–4 | on 5–19 | on 20+ | links | links on 20+ |
|---|---|---|---|---|---|---|---|---|
| location | 17,154 | 805 | 8,815 | 3,875 | 2,206 | 1,453 | 458,989 | 420,146 |
| subject | 45,100 | 1,054 | 22,361 | 11,083 | 6,805 | 3,797 | 1,115,678 | 1,001,657 |

About 92% of links sit on the categories with 20+ books. Half of each vocabulary is on one book.

Kinds of junk, with examples from the live data:

- **Truncated or broken names**, from legacy's free-text parsing: `Japan (`, `United Kingdom (`,
  `Podgorica (Montenegro`, `61)`, `2014)`. 721 locations contain a bracket.
- **Case and punctuation twins**: 193 location clusters and 457 subject clusters differ only in
  case or punctuation. `Washington D.C.` (2,879) / `Washington, D.C.` (782); `Decision-making` /
  `Decision making`; `Women's Studies` / `Womens Studies`; `Self-discovery` / `Self‑discovery`
  (U+2011).
- **Synonyms and qualified names** that no string rule catches: `Kolkata (Calcutta)`,
  `Paris, France`, `New York (city)` / `New York City`, `Vienna (state)`, `Danzig (Gdańsk)`.
- **Wrong type**: `Hope` (2,746 books, *The Grapes of Wrath*, *A Farewell to Arms*) and `Media`
  (1,469, *White Noise*) are subjects stored as locations.
- **Placeholders**: `Fictional Location` is on 39,267 books, and it's the only location on 13,167
  of them. It's co-tagged with `United States` on 11,810.
- **Style drift**: 441 subjects start lowercase (`secrets` 8,040, `isolation` 7,817), mostly with
  no capitalised twin.
- **Over-tagged books**: location is the only axis legacy never pruned. *Running The World* has
  361 locations; 1,653 books have more than 25 (see memory `books-location-categories-unpruned`).
- **Near-universal subjects**: `Identity` 39,739, `Family` 28,250, `Friendship` 19,504. These are
  per-book over-tagging, not vocabulary errors; **Spec B** re-judges them. This spec keeps them.

To regenerate these numbers, run the queries in `docs/data-quality/books-categories.md` (added by
this spec, see §8).

### Why legacy produced it

Legacy's `CategoryLocation` and `CategorySubject` prompts (`the-greatest-books/admin/app/lib/openai/chats/`)
sent only `"Title by Author"`: no description, no existing vocabulary, no confidence. Every answer
was find-or-created by name. Locations matched on exact case-sensitive name and forced any match to
`category_type: :location`, which is how `Hope` became a place. The location prompt said "include
both the city, state, and its country as separate entries", so every city dragged its country along
as an unrelated flat category, and qualified strings like `Paris, France` became categories of their
own. On an unknown book the model guessed. Legacy is still live, and the weekly
`data_migration:sync` still brings its new categories and links over.

### Why merging is unsafe today

- `Books::FilterParams` resolves slugs against `Books::Category.active` and 404s on a miss, so a
  merged or soft-deleted category's URL dies. friendly_id has no `:history`, so a rename kills the
  old URL too (`should_generate_new_friendly_id?` returns true on `name_changed?`).
- `Books::LegacyCategoriesController` (`/genres/:id`) finds only active categories.
- Saved searches and recommendation configs store category ids
  (`Books::SavedSearchCriteria`, `Books::RecommendationCriteria`, applied in
  `Search::Books::Search::CriteriaClauses`); a soft-deleted id is skipped, so a merge silently
  empties part of a user's saved criteria.
- `Services::BooksMigration::CategoryItemMigrator` drops any new legacy link to a mapped category
  that is soft-deleted here. After a merge, new legacy books lose the link instead of gaining the
  target.
- `Categories::Merger` exists but nothing calls it. It copies links one row at a time (a
  counter-cache update and a reindex request per row), doesn't check types, and doesn't move child
  categories.

## Decisions (owner, 2026-10-11)

1. Two specs: this cleanup first (most important), then AI assignment (Spec B).
2. Locations become a **hierarchy, with ancestor links materialised on the book** (§3).
3. Long tail: **fold in where a broader category covers it, keep real specific places, delete
   junk**, and hide categories under a minimum ranked-book count from browse listings and the public
   filter search (§6).
4. Near-universal subjects are **kept**; Spec B re-judges their per-book links.
5. The cleanup is an **AI-assisted plan the owner reviews, then applies** (§4). Wikidata anchoring
   and manual admin-only cleanup were considered and rejected: Wikidata handles historical and
   literary places poorly and adds a dependency; manual review doesn't finish at 62k categories.
6. **Smaller AI batches.** The owner has seen accuracy fall as batch size rises. The head goes one
   category per call; the tail's batch size is chosen by measurement (§4.4).

## 1. Safe merging

### 1.1 `merged_into_id`

Add `categories.merged_into_id` (nullable self-FK, indexed). A category with `merged_into_id` set is
always also `deleted: true`. `Merger` flattens on write: when A merges into B, every category whose
`merged_into_id` is A is repointed to B, so lookups never follow chains.

`Category#canonical` returns `self` for an active category, the `merged_into` target for a merged
one, and `nil` for a deleted-without-merge one. One class method,
`Category.replace_merged_ids(ids)` returns the ids with each merged id swapped for its target
(deduplicated, order kept) and every other id unchanged. Every reader below uses one of the two.

### 1.2 Readers that follow merges

- **Public filter URLs.** `Books::FilterParams` gets a slug miss on `Books::Category.active`, then
  looks the slug up among merged categories and in friendly_id slug history. If every missing slug
  resolves, the result carries the canonical categories and `redirect? = true`;
  `Books::RankedItemsController#index` then 301s to `Books::FilterPath.call(...)` with the canonical
  slugs, keeping every other path segment. `Books::FiltersController` (the modal pane) and the CSV
  export just use the canonical categories. A slug that resolves to nothing still 404s.
- **Renames.** Add friendly_id `:history` to `Category` (the `friendly_id_slugs` table already
  exists, with a `scope` column). An old slug resolves through history and 301s the same way. The
  admin rename keeps going through `update`; history makes that safe.
- **Legacy `/genres/:id`.** `Books::LegacyCategoriesController#find_category!` resolves slug or
  legacy id to any category, then takes `canonical`; `nil` → 404.
- **Saved searches and recommendation configs.** `CriteriaClauses` passes stored ids through
  `Category.replace_merged_ids` before building the query, so behaviour for deleted-without-merge ids
  is exactly today's. `SavedSearchFilterLabels` resolves the same way so the label matches the
  search. Stored ids are not rewritten.
- **Weekly legacy sync.** `CategoryItemMigrator#preload_context` builds its map from every mapped
  category's `canonical` instead of only the active ones. A link to a merged category lands on the
  target; a link to a deleted-without-merge category is still dropped (legacy's own corruption
  case stays a deliberate drop). The sync then runs the ancestor reconciler (§3.3).

### 1.3 `Categories::Merger` rework

- One transaction. `INSERT INTO category_items (...) SELECT ... ON CONFLICT DO NOTHING` copies the
  source's links onto the target, preserving `source` (§3.2); then the source's links are deleted
  with `delete_all`; `item_count` is recomputed for both once; `Categories::ItemReindexer` queues
  the affected items once.
- The source name and its `alternative_names` are appended to the target's `alternative_names`.
- Children of the source are re-parented to the target.
- **Allowed**: different `category_type` within the same STI `type` (location `Hope` → subject
  `Hope`). **Refused**: different STI `type`; merging a category into itself or its own descendant;
  either side being one of the four book-type categories.
- Book-type protection: `Books::BookType` already knows the four (Fiction, Nonfiction, Poetry,
  Religion & Spirituality, resolved through `LegacyIdMap`). `Merger` and `Deleter` refuse them, and
  so does the admin destroy action. `BookTypeCategoryMigrator` raises if one is soft-deleted, so a
  merge would break the sync.
- If a location merges, the ancestor reconciler runs for the moved items (§3.3).

### 1.4 Admin

On the books category show page: a "Merge into…" form (target picked through the existing
category autocomplete, with a confirm checkbox), posting to a new `merge` member route on
`Admin::Books::CategoriesController`. The categories admin has no `Actions::Admin` plumbing, and a
member route is smaller than adding it. The category form permits `parent_id` (already) and `alternative_names`
(new, as a comma-separated field). Deleting a books category from admin goes through
`Categories::Deleter` (soft delete *and* remove links), not the bare `soft_delete!` it calls today,
which leaves links attached. Music and games keep today's behaviour.

## 2. Naming rules

These go into the AI prompts and into `docs/features/books-categories.md`.

**Both types**
- Title Case, Chicago style (minor words lowercase unless first): `Death and Grief`,
  `Women in Science`.
- `and`, not `&`. Straight ASCII apostrophes and hyphens.
- No trailing punctuation, no surrounding whitespace, no unbalanced brackets.

**Subjects**
- A noun or noun phrase naming a topic or theme. Not a genre (`Science Fiction`), not a location,
  not a format (`Anthology`).
- Don't create a rename just to change singular/plural; merge only when both forms exist, into
  the more-used one.

**Locations**
- The common English name, current if the place still exists: `Kolkata` (alias `Calcutta`),
  `Gdańsk` (alias `Danzig`), `Istanbul`. Historical states keep their historical name:
  `Soviet Union`, `Roman Empire`, `Ottoman Empire`.
- No containing place in the name: `Paris`, not `Paris, France`. The hierarchy carries that.
- When two different places share a name, the more-linked one keeps the bare name and the other
  gets a parenthetical qualifier: `Georgia` (country) and `Georgia (U.S. state)`. Qualifiers are the
  only legitimate brackets.
- Old names and spellings go into `alternative_names`.

## 3. Location hierarchy

### 3.1 Shape

A single-parent tree on the existing `categories.parent_id`, for `location` only. Subjects stay
flat.

```
Continent / region → Country → State / province / region → City → Neighbourhood / landmark
```

- Levels may be skipped (`Kilwa` → Tanzania → Africa).
- Roots are the continents (`Africa`, `Antarctica`, `Asia`, `Europe`, `North America`,
  `Oceania`, `South America`), `Fictional Location`, regions that span continents (`Middle East`,
  `Arctic`), and a few genuinely global places (`Outer Space`, `Atlantic Ocean`). The AI location
  pass may propose another root; the report lists every proposed root so the owner sees them all.
- **A country's parent is always its continent.** Named regions inside one continent
  (`Scandinavia`, `Balkans`, `Caribbean`) are categories under that continent, but countries do not
  nest beneath them, so every country has exactly one obvious parent. `Middle East` and other
  cross-continent regions stay roots that books link to directly; `Egypt` is under `Africa`,
  `Israel` under `Asia`. A transcontinental country goes under the continent holding most of its
  population (`Russia` → Europe, `Turkey` → Asia).
- Places spanning several countries go under their nearest shared region (`Alps` → Europe,
  `Sahara` → Africa).
- **Historical places**: historical cities and sites go under the modern country they lie in
  (`Troy` → Turkey). Historical states and empires go under their continent (`Soviet Union` →
  Europe, `Roman Empire` → Europe, `Frankish Kingdom` → Europe) and are not merged into modern
  countries.
- **Fictional places**: named invented worlds and their places sit under `Fictional Location`
  (`Middle-earth`, `Ansalon`, `Hogwarts` → `Fictional Location`). An invented place inside the real
  world gets its real parent (an invented Maine town → Maine). Whether a given book should carry
  `Fictional Location` at all is Spec B's per-book judgment.
- A location with a real parent chain never also has `Fictional Location` as an ancestor.

`Books::Category` gets `ancestors` (walks `parent`, capped at 8 levels to guard against a cycle
written outside the validated path) and a validation that `parent` is a books location and is not
the category itself or a descendant.

### 3.2 `category_items.source`

Add `category_items.source`, an integer enum, `null: false, default: 0`:
`legacy: 0, admin: 1, inherited: 2`. Spec B adds `ai`. Every existing row becomes `legacy`; there is
no way to tell legacy-AI links from admin links added in this app since the migration, and this spec
doesn't try. The admin add-category action writes `admin`. The sync writes `legacy`. The book merger
(`app/lib/books/book/merger.rb`) copies `source` with each direct link, and then runs the ancestor reconciler
for the survivor.

`source` records why a link exists *directly*. A row is `inherited` only when it exists solely
because a descendant location is linked to the same item. If a direct link to the same category is
added later, the row's source is upgraded to that direct source; it is never downgraded.

### 3.3 `Categories::AncestorReconciler`

One service keeps inherited links right for every caller: the admin add/remove-category actions,
`Merger`, the book merger, the weekly sync, the over-tagged trim (§5), cleanup apply, and Spec B's
applier. `Categories::AncestorReconciler.call(item_ids: nil)` (all books when `nil`; rake
`categories:reconcile_ancestors`) is idempotent:

1. Insert missing `inherited` links for every direct location link's ancestors (set-based SQL over a
   recursive CTE of the location tree).
2. Delete `inherited` links that no longer have a direct descendant link on the same item.
3. Recompute `item_count` for touched categories; queue reindexes through
   `Categories::ItemReindexer`.

It runs after cleanup apply, after every weekly sync (appended to `data_migration:sync`), and after
any admin re-parent (enqueued as a Sidekiq job, scoped to the moved subtree).

Removing a direct link from the admin removes that row only; the reconciler (scoped to the item)
then drops inherited ancestors nothing else needs.

### 3.4 Readers

The search index, filters, similarity and recommendations read `category_items` and need no change:
the ancestor links really exist.

The **book page** (`books/books/show.html.erb`) shows only direct (non-`inherited`) location links,
each rendered as a breadcrumb up to its country (`Chicago, Illinois, United States`), each segment
linking to its own filter page. The controller preloads the ancestors in one query (location trees
are shallow; one recursive CTE for the book's direct locations). Subjects render as today.

## 4. The cleanup pipeline

### 4.1 Decisions table

`category_cleanup_decisions`:

| column | |
|---|---|
| `category_id` | FK, not null |
| `run` | string, a label per propose run (e.g. `2026-10-15-prod`) |
| `action` | enum: `keep, rename, merge, retype, set_parent, delete` |
| `new_name` | for `rename`, and for a `merge` whose target doesn't exist yet |
| `target_category_id` | for `merge` |
| `parent_chain` | string array, for `set_parent`: immediate parent first, root last |
| `new_category_type` | for `retype` |
| `place_kind` | for locations: `continent, region, country, subdivision, city, site, historical_state, fictional, global` |
| `decided_by` | enum: `rule, ai` |
| `reason` | text, the model's or the rule's one-line reason |
| `ai_chat_id` | FK, nullable |
| `category_snapshot` | jsonb: name, type, parent_id, item_count when proposed |
| `status` | enum: `proposed, rejected, applied, stale, failed` |
| `error` | text |

A category can have several decisions in one run (a `rename` and a `set_parent`). An AI `keep`
is written too, so a category the AI has seen is never sent again in that run. The model is
`CategoryCleanupDecision`, global namespace (it references `Category`, a shared model), with only
validations and scopes; all logic is in services under `app/lib/services/categories/cleanup/`.

### 4.2 Stages

1. **Rules pass** (`Services::Categories::Cleanup::RulePass`, no AI):
   - Unicode NFKC, plus mapping U+2010–2015 to `-` and curly quotes to straight ones; trim and
     collapse whitespace.
   - Unbalanced bracket fragments: a name that is only a bracketed fragment or a number with a
     bracket (`61)`, `2014)`, `(`) → `delete`. A name ending in an unclosed `(` or `(...` without a
     closing bracket (`Japan (`, `Podgorica (Montenegro`) → its prefix before the bracket, then
     `merge` into the category of that name if one exists, else `rename`.
   - Twins: group by `lower(regexp_replace(name, '[^[:alnum:]]', '', 'g'))` within a type; every
     member `merge`s into the one with the most links.
   - Lowercase-initial names with no twin → `rename` to Title Case.
   - `&` → `and` renames (merging if the `and` form exists).
   - Zero-link categories → `delete`.
   - Names the rules can't settle are left without a decision for the AI passes.
2. **AI location pass, head first** (`LocationTask`). Head = locations with ≥ 20 links after the
   rules pass (configurable). One category per call. Input: the name, its link count, up to 5
   sample book titles with authors, and its current `alternative_names`. The system prompt (cached)
   holds the rules from §2 and §3.1 plus the current list of head location names with their
   proposed parents, so merges and parents point at known names. Output (strict schema):
   `verdict` (`real_place, fictional_place, not_a_place, junk`), `canonical_name`,
   `merge_into` (an existing name or null), `parent_chain` (names from the immediate parent up to a
   root, e.g. `["Illinois", "United States", "North America"]`; empty for a root), `place_kind`,
   `retype_to` (`subject` or null, for `not_a_place`), `ambiguous` (bool: the sample titles show
   two different places under one name), `reason`. A `not_a_place` verdict with `retype_to:
   subject` becomes a `retype` decision, or a `merge` into an existing subject of that name.
   Because the cached prompt lists every head location name, one round suffices: Chicago can name
   Illinois as its parent before Illinois itself has been processed. A chain name that matches no
   category is created at apply time, with its parent taken from the next name in the first chain
   (by decision id) that mentions it; the report lists every created category and its parent.
3. **AI location pass, tail.** Same task, prompt carrying the settled head. Batch size from §4.4.
4. **AI subject pass** (`SubjectTask`), head then tail, same structure. Head = subjects with ≥ 20
   links. Output: `action` (`keep, rename, merge, delete, is_location`), `name`, `merge_into`,
   `reason`. `is_location` hands the category to the location tail pass. `delete` is reserved for
   junk and things that aren't subjects (`Book titles`, `Packages`); a vague but real subject is
   `keep` or `merge`. The head first dedupes against itself (`Death and Grief` vs `Grief` is a
   judgement the prompt spells out: merge only true synonyms, never a broader/narrower pair).
5. **Validation at propose time.** Every decision is checked before it's written: a `merge_into` or
   `parent` name must resolve to an existing category or to a category another decision in the same
   run creates; a parent must be a location; no cycles. A decision that fails validation is written
   as `failed` with the error, so it shows in the report.
6. **Ambiguous names** (`ambiguous: true`, e.g. `Georgia`) get the dominant meaning in this spec
   and are listed in the report. Splitting a mixed category is per-book work for Spec B.

Every AI call goes through the existing `Services::Ai::Tasks::BaseTask` (an `AiChat` per call,
parented on the category) on the `standard` role. Failed or invalid responses write nothing;
re-running `propose` for a run only processes categories with no decision in that run.

### 4.3 Review and apply

- `categories:cleanup:propose[run,stage]` runs a stage (`rules`, `locations_head`,
  `locations_tail`, `subjects_head`, `subjects_tail`).
- `categories:cleanup:report[run]` prints counts per action and type, the 50 largest merges by
  links moved, every proposed new root, every `ambiguous` location, all `failed` decisions, and 25
  random samples per action; it writes the full decision list to a CSV in `tmp/`.
- `categories:cleanup:reject[run,ids]` marks decisions `rejected`. Re-running a stage after a
  prompt change replaces that stage's `proposed` decisions; `rejected` and `applied` ones are kept.
- `categories:cleanup:apply[run]` applies `proposed` decisions in dependency order: create missing
  parents → rename → merge → retype → set parent → delete. Before applying anything it compares
  every decision's category to its `category_snapshot`; a decision whose category changed is marked
  `stale` and skipped. Each
  decision is its own transaction; a failure marks it `failed` and the run continues. Afterwards:
  `categories:reconcile_ancestors`, then one `ItemReindexer` pass over touched items. Re-running
  apply is a no-op for `applied` decisions.

Search indexing during apply: the reindex requests are bulk-inserted into the existing queue
(memory: `search-index-queue-is-built-for-bulk`); nothing is reindexed per decision.

### 4.4 Batch size calibration

`config.x.categories_cleanup.tail_batch_size` defaults to 1. Before the tail runs, the rake task
`categories:cleanup:calibrate[type]` takes 200 random tail categories (seeded) and runs the AI task at
batch sizes 1, 10 and 25, writing nothing to the decisions table. It reports, per size, the share of
categories whose decision agrees with the size-1 decision (same action, and same target/parent/name
after normalization), and lists the disagreements. The owner sets the tail batch size to the
largest size at or above 97% agreement, or leaves it at 1.

Batched calls use the same schema wrapped in an array keyed by an id the prompt assigns, so a
dropped or reordered row is detected and that row retried alone.

### 4.5 After each sync, until cutover

The sync's `CategoryMigrator` keeps inserting new legacy categories. A step appended to
`data_migration:sync` runs the rules pass for categories created since the last cleanup run, plus an
exact match on name or `alternative_names` against active categories (case-insensitive, after the
rules' normalization): a match becomes an auto-applied `merge`. Everything else waits as an
undecided category for the next owner-run `propose`. Auto-apply covers only rule decisions and
alias matches, never AI ones.

## 5. Over-tagged books

After apply, books with more than `config.x.categories_cleanup.max_direct_locations` (15) direct
location links each get one AI call (`LocationTrimTask`, `standard` role). Input: title, authors,
description (if any), first published year, and the book's current direct locations with their
parent chains. The model returns the subset to keep: the primary settings for narrative books; for
world-survey or reference nonfiction, the continents/regions it covers, or `[]` when it is truly
global. The schema is a list of the given category ids, so the model can't add anything; ids not in
the input are discarded in code.

Removal applies to `legacy` links only; `admin` links are never removed. Then the reconciler
(scoped to those books) drops orphaned inherited links. Each run writes an `Enrichment` ledger row
(kind `books.location_trim`, facts = kept and removed ids), so it's auditable and a book isn't
trimmed twice unless forced. Rake: `categories:trim_locations[limit]`, with a dry-run flag that
prints the decisions without writing.

## 6. Browse threshold and search

- `Books::BrowseQuery.categories` already gates on ranked-book count > 0. For `location` and
  `subject` it gates on `ranked_count >= config.x.books.browse_min_category_books` (default 5).
  Genres are unchanged.
- The public filter modal's category search (`Books::FiltersController` →
  `CategorySearchQuery`) passes a `min_items:` of the same value for subject and location results;
  the admin search passes none.
- `CategorySearchQuery` also matches `alternative_names`, so `Calcutta` finds `Kolkata`. Active
  categories only, as today.
- Category pages under the threshold still render (book-page badges link to them); they are just not
  listed.

## 7. Rollout

1. Merge the code (migrations are additive: `merged_into_id`, `category_items.source` with a
   default, `category_cleanup_decisions`, plus a backfill of one `friendly_id_slugs` row per existing
   category). The backfill is required, not optional: friendly_id 5.7 writes only the *new* slug on a
   rename, and with `:history` its conflict check joins `friendly_id_slugs`, so without a row per
   existing category a rename would lose the old URL and a new category could reuse an existing slug —
   on music and games too.
2. In dev: run the rules pass and the head passes, then iterate on the prompts against the report.
   Run calibration and set the tail batch size.
3. In production, from a fresh snapshot: propose all stages, report, owner reviews and rejects,
   apply, reconcile, then trim over-tagged books (dry run first).
4. Until cutover, the post-sync step (§4.5) keeps new legacy categories in line; the owner re-runs
   `propose` occasionally for whatever it leaves undecided.

These steps go into `docs/launch-todo.md`. Books isn't live, but music and games share the
`categories` table: every query and every rake task is scoped to `type = 'Books::Category'`, and
the tests assert a music category is untouched by apply.

Cost, at 2026-09 research prices (re-check before running): head ≈ 5,300 calls one at a time on
`standard` (flex, cached system prompt) ≈ tens of dollars; tail at batch size 1 ≈ 55,000 calls,
$100–200, less if calibration allows batching; trim ≈ 1,650 calls, a few dollars. `propose` prints
an estimate from the category counts and refuses to start a stage over $50 without `FORCE=1`.

## 8. Testing and docs

Minitest, AI stubbed with Mocha, fixtures named for what they are.

- **Merger**: bulk copy with conflicts, `source` preserved, `merged_into` set and flattened,
  children moved, cross-`category_type` allowed, cross-STI / self / descendant / book-type refused,
  `item_count` correct on both sides.
- **Resolution**: a merged slug 301s to the target filter path with other segments kept; a renamed
  slug 301s through history; a deleted slug 404s; `/genres/:id` follows a merge; saved-search
  criteria and labels resolve merged ids; `CategoryItemMigrator` links new legacy items to the
  target and still drops deleted-without-merge.
- **Hierarchy**: parent validation (location only, no cycles); reconciler adds and removes correctly and keeps an inherited link another
  descendant still needs; a direct link upgrades an inherited row.
- **Rules pass**: a table test built from real names in today's data (`Japan (`, `61)`,
  `Self‑discovery`, `Washington, D.C.`, `secrets`, `Death & Grief`).
- **AI passes**: stubbed responses for each verdict; propose-time validation rejects unknown
  targets, non-location parents and cycles. Fixtures include a real place, a fictional place, a
  not-a-place and junk, so an implementation that accepts everything fails (memory:
  `fixture-corpus-needs-a-negative-class`).
- **Apply**: dependency order, idempotency, `stale` on a changed category, per-decision failure
  isolation, music categories untouched.
- **Trim**: ids outside the input discarded, `admin` links kept, ledger row written, dry run writes
  nothing.
- **Browse and search**: threshold applied to subject/location only; alias search.
- **Playwright E2E** (`web-app/e2e/tests/books/`): an old category URL redirects to the merged
  category's page; a book page shows a location breadcrumb; the admin merge action moves a book's
  link.

Docs:

- New `docs/features/books-categories.md`: what subjects and locations are for, naming rules (§2),
  the hierarchy (§3), `source`, merge semantics, the cleanup runbook.
- New `docs/data-quality/books-categories.md`: the measurement queries behind the tables above.
- Update `docs/features/books-legacy-sync.md` (merges are followed; post-sync cleanup step and
  ancestor reconcile) and `docs/launch-todo.md` (§7).

## 9. Not in this spec

- **Spec B**: AI subject and location assignment in the enrichment framework, with richer context
  (description, year, origin country, genres), gated on `recognized` and high confidence, mapped
  onto this vocabulary, picking the most specific place; re-judging `legacy` links per book (which
  is how `Identity` and other near-universal subjects shrink, and how `Fictional Location` and
  ambiguous names like `Georgia` get resolved per book); a backfill over the catalog with a cost
  estimate.
- Genres, including the closed genre list.
- A hierarchy for subjects.
- Gazetteer ids (Wikidata, GeoNames). They can be added later as a column without rework.
- Applying `book_type`.
- Author categories.
