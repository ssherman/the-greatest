# Books category and origin enrichment, stage 3 (categories) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every book gets its genres, audience, Fiction/Nonfiction type, subjects and locations, judged from evidence by one AI call per book. Answers are mapped onto the existing vocabulary and never create a category. Only well-supported answers are applied, within caps. A re-judge removes `legacy` links that nothing supports. Existing books get this through the stage 2 backfill, now with category scopes.

**Architecture:**
- The stage 2 `Categorize::Dossier` gains the category evidence. Most of it is already in the `books.evidence` row:
  - Wikidata P136/P921/P840/P2408/P7937;
  - the Wikipedia plot and the genre/subject/set-in infobox fields;
  - WorldCat mapped genres, subjects and summary;
  - the Goodreads shelves;
  - our own record's description and current links.
- `BookCategoriesTask` (standard role) answers from the dossier and a closed list of genres and audiences, read from `categories.description`.
- `Categories::Mapper` turns subject and location names into categories in four ways:
  - exact names and aliases;
  - merged rows;
  - trigram candidates with one `CategoryChoiceTask` call (fast role);
  - otherwise the name is recorded as unmatched.
- `Categories::Apply` applies the deterministic rules:
  - confidence gates;
  - external support;
  - caps;
  - the type rule;
  - re-sourcing confirmed links;
  - re-judge removals.
- `Categories::Judge` writes one `books.categories` ledger row per mode.
- A new `categories` step runs after `categorize` in `books.book_enrichment` (v5) and `books.book_categorize` (v2).

**Tech Stack:** Rails 8, Minitest + Mocha + WebMock, Sidekiq, the workflow engine (`app/lib/workflows/`), `Services::Ai::Tasks::EnrichmentTask`, PostgreSQL `pg_trgm`.

**Spec:** `docs/superpowers/specs/2026-11-02-books-category-origin-enrichment-design.md`, specifically:
- §4.2: the dossier, its category parts;
- §4.5: judging;
- §4.6: mapping;
- §4.7: apply and re-judge;
- §4.8: research, for categories;
- §4.9: workflow and the admin action;
- §4.10: backfill scopes and the report;
- §4.11: the rehearsal;
- §5: increment 3.

Stage 2 (origin) shipped in PR #470. Read its plan's rulings (`docs/superpowers/plans/2026-11-05-books-category-origin-enrichment-stage-2-origin.md`, last section). This plan extends the following and keeps their behaviour for origin:
- `Categorize::Dossier`;
- `Steps::Categorize`;
- `Categorize::Backfill`;
- `books.book_categorize`.

## Global Constraints

- **Where to run.** Rails commands run from `web-app/` in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-category-enrichment`. Paths below are relative to `web-app/` unless they start with `docs/`.
- **Namespaces.** The new services live in `module Services; module Books; module Categories`. Inside `Services::Books` always write `::Books::Book`, `::Books::Category`, `::Books::Author`, `::CategoryItem` and `::Categories::AncestorReconciler`. A bare `Books::` resolves to `Services::Books`, and a bare `Categories::` resolves to `Services::Books::Categories`.
- **Tests.**
  - Stub every external call: Mocha for clients and AI tasks, WebMock for HTTP. No test makes an AI call.
  - Tests mirror the namespace.
  - Minitest 6: use `assert_nil`.
  - No new warnings in `bin/rails test`.
  - `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check` are clean.
- **Generators and schema.**
  - Generate migrations with `bin/rails generate migration`.
  - `bin/rails db:migrate` runs annotaterb. Keep its annotation changes and never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
  - The dev DB is shared between worktrees. Delete only annotation lines for columns this branch's `schema.rb` does not have.
- **Results.** Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Ledger.** Kind `"books.categories"`. Every row's `facts` carries:
  - `"prompt_version" => Services::Ai::Tasks::Books::BookCategoriesTask::PROMPT_VERSION` (= `1`);
  - `"context"` (`"import"`, `"backfill"` or `"admin"`);
  - `"label"`, `"path"`, `"dossier"` (trimmed), `"answer"`, `"mapping"`, `"apply"` and `"deferred_research"`.
- **Never create** a `Category`. **Never remove** a link whose source is not `legacy`. Never remove Fiction, Nonfiction or an audience link.
- **Caps** count the book's *direct* links of a type from every source (`CategoryItem.direct`):
  - 5 genres, not counting Fiction and Nonfiction;
  - 8 subjects;
  - 5 locations;
  - 1 audience.
- **Indexing and counts.** Write links through `CategoryItem` records, never `insert_all`/`delete_all`: its `counter_cache` and `after_save`/`after_destroy` reindex callbacks must fire. Call `::Categories::AncestorReconciler.call(item_ids: [book.id])` once after a book's writes.
- **Research budgets.**
  - Imports and admin runs use `config.x.ai.research_daily_cap` (`Enrichment.against_research_cap`).
  - The backfill uses `config.x.ai.categorize_backfill_research_daily_cap`, now counting backfill research rows of both `books.origin` and `books.categories` (Task 7).
  - At most one research call per book per workflow run, across `book_facts`, `categorize` and `categories`.
- **Long-running work goes through Sidekiq.** Rake tasks only print or enqueue, except the report, the definitions writer and restoring removals, which are small and bounded.

## Review Focus

1. **"Georgia" with parent hint "United States"**, when the only exact "Georgia" location is the Caucasus country. A single exact match is accepted only when the hint is that category or one of its ancestors, so this goes to candidates and the chooser. Pinned in Task 4.
2. **A book with 5 legacy genres.** A high-confidence new genre is not added (cap). A legacy genre the judge did not pick is removed only when the run is recognized, high-confidence and has an external section, and no source supports that genre. After a removal, the freed slot is not refilled in the same run. Apply order: removals are decided against the *pre-run* link set, then additions are capped against the post-removal count. Pinned in Task 5.
3. **A legacy "United States" location and a judge that picked "Chicago"**, a descendant. The legacy link stays: picking a descendant counts as picking it. Pinned in Task 5.
4. **A judged "fiction" type on a book holding Nonfiction**: `type_conflict` is recorded and nothing is changed or removed. A judged "poetry" type writes no type link (Poetry arrives only as a genre id). Pinned in Task 5.
5. **The model returns a genre id outside the closed list** (Fiction's id, a deleted genre, or nonsense). It is recorded as unmatched with via `invalid_id`, never linked. Pinned in Task 4.

---

### Task 1: The `ai` source and genre definitions in `categories.description`

**Files:**
- Modify: `app/models/category_item.rb` (enum)
- Create: `app/lib/services/books/categories/definitions.rb`
- Create: `lib/tasks/books/categories.rake`
- Test: `test/models/category_item_test.rb`, `test/lib/services/books/categories/definitions_test.rb`

**Interfaces:**
- Produces:
  - `CategoryItem` source `ai: 5` (`source_ai?`).
  - `Services::Books::Categories::Definitions.call(apply:, plan_path: Rails.root.join("config/books/genre_plan.yml"))` returns a Result. Its `data` has:
    - `written:` the names it set (or would set);
    - `kept:` `[{name:, held:, plan:}]`, where a non-blank description differs from the plan and is left alone;
    - `missing:` the names of active genre/audience categories with a blank description and no plan entry.
  - Rake `books:categories:write_definitions` (dry run unless `APPLY=1`).

- [ ] **Step 1: Write the failing tests.**
  - `CategoryItem.sources["ai"] == 5`.
  - Definitions, with a temp YAML holding `genres: [{name: "Adventure", definition: "A."}]` and `audiences: [{name: "Young Adult", definition: "B."}]`:
    - it fills a blank description on the active genre "Adventure" and on the audience "Young Adult";
    - it leaves a different non-blank description and reports it in `kept`;
    - it reports an active genre with no plan entry and a blank description in `missing`;
    - `apply: false` writes nothing but returns the same `written`;
    - a second run writes nothing (`written` is empty);
    - plan entries match categories by `name` on `::Books::Category.active` of type genre (for `genres:`) or audience (for `audiences:`), case-insensitively. A plan name with no category is ignored.
- [ ] **Step 2: Run them.** `bin/rails test test/models/category_item_test.rb test/lib/services/books/categories/definitions_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add `ai: 5` to the enum, the service, and the rake task. The rake prints `written`, `kept` and `missing` (one line each per name) and a closing line `"Re-run with APPLY=1 to write."` when dry. Use `update_columns(description:)`: description is not search-relevant, so no reindex callback is wanted.
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Books categories: ai link source; write the reviewed genre definitions into categories.description"`

### Task 2: Trigram candidates

**Files:**
- Create: `db/migrate/<timestamp>_enable_pg_trgm_on_category_names.rb`
- Modify: `db/schema.rb` (by migrating), plus the model annotations annotaterb updates (`category.rb`, `books/category.rb` and the other `Category` subclasses)
- Create: `app/lib/services/books/categories/candidates.rb`
- Test: `test/lib/services/books/categories/candidates_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::Categories::Candidates.call(name:, category_type:, fictional: nil, limit: 10)` returns an Array of `::Books::Category`. They are active, of that type, ordered by `similarity(lower(name), lower(?))` descending then id, and filtered with `similarity > 0.3`.
    - For `category_type: "location"`, `fictional: true` restricts to the `Fictional Location` subtree (the root included) and `fictional: false` excludes it.
  - `Services::Books::Categories::Candidates.fictional_ids` returns a Set of the `Fictional Location` root and its active descendants (a recursive CTE on `parent_id`), or an empty Set when the root does not exist.

- [ ] **Step 1: Write the migration.** `enable_extension "pg_trgm"`, then `add_index :categories, "lower(name) gin_trgm_ops", using: :gin, name: "index_categories_on_lower_name_trgm"`. `pg_trgm` is a trusted extension on PostgreSQL 13+, so the app's database owner can create it in production without a superuser. Run `bin/rails db:migrate`, and check that `schema.rb` gains `enable_extension "pg_catalog.pg_trgm"` (or `"pg_trgm"`) and the index. Keep the annotation changes.
- [ ] **Step 2: Write the failing tests.**
  - "Paris" finds a location "Paris" ahead of "Parisian Suburbs".
  - A subject query never returns locations.
  - Deleted categories are left out.
  - `fictional: true` returns only Fictional Location descendants, and `fictional: false` none of them.
  - `limit` is respected.
  - `fictional_ids` includes a grandchild of the root.

  Create the categories in the test: fixtures may not hold these names. Check `test/fixtures/categories.yml` first and reuse what fits.
- [ ] **Step 3: Run them.** `bin/rails test test/lib/services/books/categories/candidates_test.rb`. Expected: FAIL.
- [ ] **Step 4: Implement** with `where("similarity(lower(categories.name), lower(?)) > 0.3", name)` and an `Arel.sql` order bound through `sanitize_sql_array`.
- [ ] **Step 5: Run the tests again.** Expected: PASS. Also run `bin/rails db:test:prepare` first if the test DB lacks the extension.
- [ ] **Step 6: Commit** the migration, schema, annotations, service and test: `"Books categories: pg_trgm index on category names and candidate retrieval"`.

### Task 3: The dossier's category evidence

**Files:**
- Modify: `app/lib/services/books/categorize/dossier.rb`
- Test: `test/lib/services/books/categorize/dossier_test.rb`

**Interfaces:**
- Consumes: the `books.evidence` facts (schema 3). Their keys are named in `Evidence::Gather::LIST_FIELDS` and `WorldCatSection#build`, and the Wikipedia `infobox` keys are `country language genre subject set_in`.
- Produces: additions to `Dossier`. The existing keys and methods are unchanged, and `BookOriginTask` keeps working.
  - **New member `goodreads`**: `{"genres" => [String]}` or nil. These are the raw genre names of the found `::Books::GoodreadsPage` for the book's `books_work_goodreads_id` identifier values (latest `fetched_at` when several), capped at 15. Give the member a default of nil (override `initialize(goodreads: nil, **rest)`), so the existing `Dossier.new(...)` calls in tests still work.
  - **`record`** gains:
    - `"description"`: the book's primary description text, first 1,000 characters, or nil;
    - `"categories"`: `[{"id", "name", "type", "source", "ancestors"}]` for the book's direct active links of types genre/audience/subject/location, ordered by type then name. `"ancestors"` holds the location ancestor names nearest first, and is `[]` for the other types.
  - **`wikidata`** adds the lists `genres main_subjects narrative_locations set_in_periods forms` (add them to `WIKIDATA_LISTS`).
  - **`wikipedia`** adds:
    - `"plot"`, cut to `PLOT_LIMIT = 2_000`;
    - `"infobox_genre"`, `"infobox_subject"` and `"infobox_set_in"`.
  - **`worldcat`** adds:
    - `"mapped_genres"` (the hash as stored);
    - `"subjects"`: the stored subject headings, keys only, first `WORLDCAT_SUBJECTS = 25`;
    - `"summary"`.
  - `to_ledger` adds `goodreads`, cuts `plot` to 500 and `worldcat["subjects"]` to 15, and drops `record["description"]` past 300 characters.
  - `external?` is unchanged: Wikidata, Wikipedia or WorldCat. Goodreads is evidence but not external, per spec §4.7.

  Look up the primary description the way the book page does: `grep -n "description" app/models/books/book.rb`.

- [ ] **Step 1: Write the failing tests** for each new key, built from an evidence row's facts in the test. Also test that a book with no Goodreads page has `goodreads` nil, and that `Dossier.new` without `goodreads:` still constructs.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/categorize/dossier_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the dossier, origin and origin task tests.** `bin/rails test test/lib/services/books/categorize test/lib/services/books/origin test/lib/services/ai/tasks/books/book_origin_task_test.rb`. Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categorize: the dossier carries the category evidence (Wikidata, Wikipedia, WorldCat, Goodreads, our links)"`

### Task 4: The judge tasks and the mapper

**Files:**
- Create: `app/lib/services/ai/tasks/books/book_categories_task.rb`
- Create: `app/lib/services/ai/tasks/books/category_choice_task.rb`
- Create: `app/lib/services/books/categories/mapper.rb`
- Test: `test/lib/services/ai/tasks/books/book_categories_task_test.rb`, `test/lib/services/ai/tasks/books/category_choice_task_test.rb`, `test/lib/services/books/categories/mapper_test.rb`

**Interfaces:**
- Consumes: `Dossier` (Task 3), `Candidates.new(category_type:)#call(name:, fictional: nil, limit: 10)` and `Candidates.fictional_ids` (Task 2), and `Services::CategoryCleanup::NameNormalizer.twin_key`.
- Produces:
  - **`BookCategoriesTask.new(parent:, dossier:, vocabulary:, mode: :knowledge)`** (`< EnrichmentTask`, standard role; `:sourced` raises like `BookOriginTask`), with `PROMPT_VERSION = 1`.
    - `vocabulary` is an Array of `::Books::Category`: the active genres minus Fiction and Nonfiction, plus the active audiences.
    - The response schema, as `OpenAI::BaseModel` classes:
      - `recognized` Boolean;
      - `confidence` String;
      - `book_type`: `{value String (fiction|nonfiction|poetry|religious|unknown), confidence String, evidence String}`;
      - `genres`: `ArrayOf[{id Integer, confidence String, evidence String}]`;
      - `audience`: `{id Integer nil?, confidence String, evidence String}`;
      - `subjects`: `ArrayOf[{name String, confidence String, evidence String}]`;
      - `locations`: `ArrayOf[{name String, kind String (real|fictional), parent String nil?, confidence String, evidence String}]`;
      - `unlisted_genres`: `ArrayOf[String]`, at most 5: genre names the evidence uses (Wikidata, Wikipedia, WorldCat, Goodreads) that are not on the list, such as "Bildungsroman". This is a report only; it is never mapped or linked.
    - The task's `data[:facts]` is that hash.
  - **`CategoryChoiceTask.new(parent:, book_line:, questions:)`** (fast role, `task_provider` as `SameWorkTask`).
    - `questions`: `[{proposed: String, category_type: String, candidates: [{id: Integer, label: String}]}]`.
    - Response: `choices: ArrayOf[{proposed String, category_id Integer nil?}]`.
  - **`Services::Books::Categories::Mapper.call(book:, answer:, vocabulary:)`** returns a Result. Its `data` has:
    - `resolved:` `[{type: "genre"|"audience"|"subject"|"location", category: ::Books::Category, proposed: String, confidence: String, evidence: String, via: "id"|"exact"|"merged"|"chosen"|"fictional_root"}]`;
    - `unmatched:` `[{type:, proposed:, via: "invalid_id"|"no_candidate"|"declined"}]`;
    - `ai_chat:` the `CategoryChoiceTask` chat or nil.

  `answer` is the task's facts hash, string or symbol keys.

**The prompt (BookCategoriesTask).** System message:
- what each output is, with the spec §4.5 rules verbatim in substance;
- at most 5 genres, 1 audience or none (there is no adult audience), 8 subjects and 5 locations;
- subjects are browse-page topics, not broad themes such as identity, love or human nature unless the book is centrally about that;
- a location is the most specific place the book is substantially set in, or for nonfiction the place it is about, never every place mentioned, each marked real or fictional, with a parent hint;
- confidence per item, and an evidence note naming the dossier section;
- `recognized` false when the book is unknown.

The vocabulary goes in as `id: Name — description` lines (genres, then audiences, under separate headings). The user prompt renders every dossier section that is present, in the order record, earlier AI facts, Wikidata, Wikipedia (lead, infobox, plot), WorldCat (mapped genres, subjects, summary), Goodreads shelves. Our current links go under the heading "Categories the book holds now (source in brackets)". Research mode adds the same instruction line `BookOriginTask#research_instruction` uses.

**The mapping algorithm (Mapper):**
- **Genres and audience.** Look up `id` in `vocabulary` by id and type. If it is absent, record it as unmatched with via `invalid_id`. A genre id that is an audience, or the reverse, is also `invalid_id`.
- **Subjects and locations, in order:**
  1. **Exact.** Compare `twin_key(proposed)` with the twin keys of `name` and `alternative_names`, on active categories of the type. Do it in Ruby over one load per type, memoised per call; the types hold about 11k and 15k rows, so load only `id, name, alternative_names, parent_id, merged_into_id, deleted`. For locations, honour the real/fictional subtree (`Candidates.fictional_ids`). Exact needs exactly one hit. A location hit with a non-blank `parent` hint also needs the hint's twin key to equal the twin key of the hit or of one of its `ancestors`.
  2. **Merged.** The same keys (the merged row's `name` **and its `alternative_names`**) on deleted rows that have `merged_into_id`, following `canonical`. Accept only an active canonical of the same type. The owner asked for merged rows' alternative names to always count.
  3. **Candidates.** One `Candidates.new(category_type:)` per type per Mapper call (it loads the type's rows once), then `#call(name:, fictional:, limit: 10)` per name. (Task 2 ruling: no pg_trgm migration; Candidates scores trigrams in Ruby.) For an ambiguous exact location, the exact hits come first and the trigram results fill the rest. Location labels are `"Name › Parent › Grandparent"`. All of the book's unresolved names go into **one** `CategoryChoiceTask` call. Skip the call when no name has candidates. A `category_id` not among that question's candidates counts as declined.
  4. **Otherwise** record it as unmatched (`no_candidate` or `declined`).
- **A fictional location** left unmatched whose position in `answer["locations"]` is 0 (the main setting) resolves to the `Fictional Location` root with via `fictional_root`. A real location is never matched inside the fictional subtree.
- **Duplicates.** Two answers that resolve to one category keep the first.

- [ ] **Step 1: Write the failing tests.**
  - **Task tests** (stub the provider as `book_origin_task_test.rb` does):
    - the prompt lists vocabulary ids with descriptions and leaves out Fiction and Nonfiction;
    - it renders each dossier section when present and omits it when nil;
    - research mode adds the instruction;
    - `:sourced` raises.
  - **Chooser task:** the prompt lists each question's candidates with ids, and the role resolves to `:fast`.
  - **Mapper tests:**
    - genre id valid, and an id outside the vocabulary or a Fiction id → `invalid_id` (Review Focus 5);
    - an exact subject match through an alternative name;
    - a merged subject follows its target;
    - "Georgia" with hint "United States", where the only "Georgia" sits under "Caucasus": no exact match, so the chooser is called with "Georgia › Caucasus" among the candidates, and declining gives `declined` (Review Focus 1);
    - the same "Georgia" with hint "Caucasus" → exact;
    - one chooser call for three unresolved names (`CategoryChoiceTask.any_instance.expects(:call).once`);
    - no chooser call when nothing is unresolved;
    - a chooser id outside the candidates → `declined`;
    - an unmatched fictional location first in the list → `fictional_root`, and second in the list → unmatched;
    - a real "Paris" never resolves to a fictional "Paris" under Fictional Location.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/ai/tasks/books/book_categories_task_test.rb test/lib/services/ai/tasks/books/category_choice_task_test.rb test/lib/services/books/categories/mapper_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement the three classes.**
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categories: BookCategoriesTask, CategoryChoiceTask and the vocabulary mapper"`

### Task 5: Support and Apply

**Files:**
- Create: `app/lib/services/books/categories/support.rb`
- Create: `app/lib/services/books/categories/apply.rb`
- Test: `test/lib/services/books/categories/support_test.rb`, `test/lib/services/books/categories/apply_test.rb`

**Interfaces:**
- Consumes: `Dossier` (Task 3) and the Mapper's `resolved` entries (Task 4).
- Produces:
  - **`Services::Books::Categories::Support.new(dossier)`**, with `#sources_for(category)`, which returns an Array of the source names that back the category, and `#supported?(category)`, which is `sources_for(category).any?`. Source names: `wikidata`, `wikipedia`, `worldcat` and `goodreads`.
    - A category's **names** are its `name` and `alternative_names`, plus the `name` and `alternative_names` of every row merged into it (`merged_into_id` = its id; one query per Support instance). `Categories::Merger` copies these onto the target, but older merges may not have.
    - A text test is a whole-word, case-insensitive match of one of the category's names against a string, or equality of their twin keys.
    - `wikidata`: the text test against each entry of the wikidata `genres`, `main_subjects`, `narrative_locations` and `forms`.
    - `wikipedia`: the text test against `infobox_genre`, `infobox_subject` and `infobox_set_in`.
    - `worldcat`:
      - genres and audiences: `mapped_genres` has the key `"genre:<Name>"` or `"audience:<Name>"`;
      - subjects and locations: the text test against any `worldcat["subjects"]` heading.
    - `goodreads`: `GoodreadsEnrichment::GenreMatcher#match(shelf)` returns this category (or its canonical) for some shelf. Build one matcher per Support instance.
    - Support is checked per category only. The location descendant rule lives in Apply's "picked" test, not here.
  - **`Services::Books::Categories::Apply.call(book:, dossier:, answer:, resolved:, rejudge:)`** returns a Result. Its `data` has:
    - `added:` `[{id, name, type, confidence, support: [..]}]`;
    - `confirmed:` `[{id, name, type, from: "legacy"|"inherited"}]`;
    - `removed:` `[{id, name, type, source: "legacy"}]`;
    - `held_back:` `[{id, name, type, confidence, reason: "low_confidence"|"unsupported_medium"|"cap"}]`;
    - `type:` `{judged:, confidence:, held:, applied: Boolean, reason: "applied"|"held"|"type_conflict"|"not_high"|"book_facts_disagrees"|"no_type"}`;
    - `rejudged:` Boolean, true when the removal conditions held.

**The rules, in this order, inside `book.with_lock`:**
1. **Snapshot.** Load the book's direct links of types genre/audience/subject/location once.
2. **Removals**, when `rejudge` and `answer["recognized"] == true` and `answer["confidence"] == "high"` and `dossier.external?`. Each `legacy` link comes off when all of these hold:
   - it is not Fiction or Nonfiction and not an audience;
   - it is not picked (its id is not among `resolved`, and for a location no resolved location has it among its `ancestors`);
   - `Support#supported?` is false.

   Destroy each through the record.
3. **Type.** The judged value fiction or nonfiction maps to the Fiction or Nonfiction genre by name (`::Books::Book::BOOK_TYPE_CATEGORY_NAMES`).
   - poetry, religious or unknown → `no_type`.
   - The book holds the other type → `type_conflict`.
   - It holds the same type → `held`.
   - Its confidence is not high → `not_high`.
   - `dossier.book_facts["book_type"]` is present and its fiction/nonfiction value differs → `book_facts_disagrees`.
   - Otherwise create the link with source `ai` → `applied`. Type links are never capped.
4. **Additions**, for each resolved entry ordered high before medium (stable otherwise):
   - low → `held_back` `low_confidence`;
   - medium and not supported → `unsupported_medium`;
   - already held with source `legacy` or `inherited` → update the source to `ai`, and add to `confirmed`;
   - already held with another source → nothing;
   - otherwise, when the post-removal direct count of that type is below its cap, create the link with source `ai` and count it;
   - else → `cap`.
5. **Reconcile.** `::Categories::AncestorReconciler.call(item_ids: [book.id])` runs once if anything was written.

- [ ] **Step 1: Write the failing tests.**
  - **Support:** each of the four sources positive and negative; the whole-word test ("War" does not match "Warsaw"); alternative names count; a Wikidata genre label equal to an alternative name of a category *merged into* this one counts.
  - **Apply:**
    - high is added with source `ai`; medium with WorldCat support is added; medium without support is held back; low is held back;
    - Review Focus 2: 5 legacy genres, one unpicked and unsupported, on a high recognized external run → that one is removed and one new high genre is then added (4 + 1 = 5), while a second new high genre gets `cap`;
    - the same with `dossier.external?` false → nothing removed;
    - the same with `rejudge: false` → nothing removed;
    - Review Focus 3: a legacy United States link stays when Chicago (child) is resolved;
    - a legacy link backed by a Goodreads shelf stays;
    - `admin`, `goodreads`, `worldcat` and `ai` links are never removed;
    - Review Focus 4: Fiction is judged on a book holding Nonfiction → `type_conflict` and the Nonfiction link survives; poetry → `no_type`; `book_facts` "nonfiction" against a judged high "fiction" on a typeless book → `book_facts_disagrees`;
    - a picked legacy link becomes `ai`; a picked inherited location becomes `ai`;
    - the audience cap is 1;
    - `AncestorReconciler` is called once when something was written and not when nothing was;
    - `item_count` of an added category rises by 1.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/categories/support_test.rb test/lib/services/books/categories/apply_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categories: external support test and the deterministic apply and re-judge rules"`

### Task 6: The categories judge and its ledger

**Files:**
- Create: `app/lib/services/books/categorize/research_budget.rb`
- Create: `app/lib/services/books/categories/judge.rb`
- Modify: `app/lib/services/books/origin/judge.rb` (`research_permitted?` uses the budget)
- Modify: `app/models/enrichment.rb` (`against_research_cap` excludes backfill rows of both kinds)
- Test: `test/lib/services/books/categorize/research_budget_test.rb`, `test/lib/services/books/categories/judge_test.rb`, `test/models/enrichment_test.rb`

**Interfaces:**
- Consumes: Tasks 3-5.
- Produces:
  - **`Services::Books::Categorize::ResearchBudget.permitted?(context:)`**, a Boolean.
    - For `"backfill"`: research rows created today whose kind is `books.origin` or `books.categories` and whose `facts->>'context'` is `'backfill'`, compared against `categorize_backfill_research_daily_cap`.
    - Otherwise: `Enrichment.against_research_cap.count < research_daily_cap`.
  - `Enrichment.against_research_cap` excludes backfill rows of both kinds.
  - `Origin::Judge#research_permitted?` keeps its `research_allowed` and `force_research` guards, then calls the budget.
  - **`Services::Books::Categories::Judge.call(book:, context:, label: nil, research_allowed: true, force_research: false)`** returns a Result with `data: {enrichments: [Enrichment], applied: Boolean}`. `KIND = "books.categories"`.

**Flow.** It mirrors `Origin::Judge` minus the shortcut and `has_origin`:
1. A blank title gives a `skipped` row (`missing_inputs`).
2. Otherwise:
   - read `previously_deferred?` (latest `books.categories` row, current PROMPT_VERSION, with `deferred_research` true);
   - build the dossier;
   - build the vocabulary: `::Books::Category.active.where(category_type: %w[genre audience]).where.not(name: ::Books::Book::BOOK_TYPE_CATEGORY_NAMES).order(:category_type, :name)`.
3. Choose the first mode:
   - research when `force_research`;
   - or when past `knowledge_cutoff_year` and permitted;
   - or when it owes research and it is permitted;
   - else knowledge.
4. Run the task.
   - **Unrecognized** means `recognized == false && !dossier.external? && !dossier.research_backed?`. That row is `unrecognized` and applies nothing.
   - **Otherwise:** run the Mapper, then Apply with `rejudge: context != "import"`. The outcome is `applied` when anything was added, confirmed, removed or typed, else `nothing_to_apply`. `reason` is `"applied"` or `"nothing_applied"`.
   - The row records (`answer` includes `unlisted_genres` as given): `recognized`; `confidence` (the overall value, normalised as in `Origin::Judge#confidence_for`); `citations`; `ai_chat`; the facts `answer`, `mapping` (`{resolved: [{id, name, type, via, confidence}], unmatched: [...]}`) and `apply` (the Apply data with ids and names only); and `"choice_chat_id"`.
5. **Research follows** a knowledge row when that row is unrecognized and `research_allowed`; when it is not permitted, the row gets `deferred_research: true`. A past-cutoff book judged from knowledge because research was not permitted is also deferred, as in `Origin::Judge#judge`.
6. **Failure.** A task failure, or an exception, gives a `failed` row and stops.

- [ ] **Step 1: Write the failing tests.**
  - **Budget:** backfill counts research rows of both kinds; import rows count against the import cap and backfill rows do not.
  - **Judge** (stub `BookCategoriesTask`, `CategoryChoiceTask` and Apply where needed):
    - happy path: one row, `applied`, with prompt_version 1 and context;
    - unrecognized with no external section and research not permitted → an `unrecognized` row with `deferred_research` true;
    - the same with research permitted → a second row in research mode;
    - `research_allowed: false` → never research;
    - `force_research` → the first row is research;
    - a failed task → a `failed` row and `success?` false;
    - `rejudge` is false for context import and true for backfill and admin (`Apply.expects(:call).with(has_entry(rejudge: ...))`);
    - the facts carry the dossier ledger, the mapping and the apply.
  - **Origin:** `test/lib/services/books/origin/judge_test.rb` still passes unchanged.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/categorize test/lib/services/books/categories test/lib/services/books/origin test/models/enrichment_test.rb`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categories: the judge, its books.categories ledger rows and a shared backfill research budget"`

### Task 7: The `categories` workflow step

**Files:**
- Create: `app/lib/workflows/books/steps/categories.rb`
- Create: `app/lib/workflows/books/steps/judge_options.rb` (module, shared with `Steps::Categorize`)
- Modify: `app/lib/workflows/books/steps/categorize.rb`, `app/lib/workflows/books/book_enrichment.rb` (version 5), `app/lib/workflows/books/book_categorize.rb` (version 2, `scope` option → skips)
- Test: `test/lib/workflows/books/steps/categories_test.rb`, plus the existing workflow tests for both definitions

**Interfaces:**
- Consumes: `Categories::Judge` (Task 6).
- Produces:
  - **`Steps::JudgeOptions`** (a module):
    - `context_for(run)`, moved out of `Steps::Categorize` unchanged;
    - `researched_in_run?(run, keys)`: true when an `Enrichment` with `mode: :research` exists for any of the run's steps named in `keys`.
  - **`Steps::Categories#call(step:, run:, target:)`** calls `Categories::Judge.call` with:
    - `context: context_for(run)`;
    - `label: run.options["label"]`;
    - `research_allowed: !(run.options["book_facts_researched"] || researched_in_run?(run, %w[book_facts categorize]))`;
    - `force_research: run.workflow == "books.book_categorize" && run.options.fetch("force_research", false)`.

    It raises on failure and returns `Workflows::Outcome.succeeded(label, {"enrichment_ids" => [...], "applied" => ...})`, as `Steps::Categorize` does.
  - **`books.book_enrichment` v5:** `add_step key: :categories, queue: :low, lease: 10.minutes, waits_on: {categorize: :finish}`. Update the class comment ("Version 5 added categories ...; a run planned under version 4 has no categories step and still runs").
  - **`books.book_categorize` v2:** the same step after `categorize`.
    - `BookCategorize.start` maps `options["scope"]` to `skips:`:
      - `"origin_only"` → `{categories: "scope_origin_only"}`;
      - `"categories_only"` → `{categorize: "scope_categories_only"}`;
      - `"all"` or absent → `{}`.
    - Any other value raises `ArgumentError`.
    - Comment the new option.

- [ ] **Step 1: Write the failing tests.**
  - The step calls the judge with the context, label and research flags. Research is not allowed when the run's `categorize` step wrote a research-mode `books.origin` row, or `book_facts` wrote one.
  - Force research only in `books.book_categorize`.
  - A failed judge raises.
  - Both definitions list the step, waiting on categorize.
  - `BookCategorize.start(book, initiated_by: "test", options: {"scope" => "categories_only"})` plans `categorize` as skipped, and the `categories` step is ready once evidence finishes.
  - An unknown scope raises.

  Find the existing tests with `ls test/lib/workflows/books/`.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/workflows`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests again,** then `bin/rails test test/sidekiq test/lib/services/wikidata`. The re-check and `EnrichBookJob` start `books.book_categorize` with no scope, so they now run both steps. Expected: PASS.
- [ ] **Step 5: Commit.** `"Books workflows: a categories step after categorize (book_enrichment v5, book_categorize v2 with a scope option)"`

### Task 8: Backfill scopes

**Files:**
- Modify: `app/lib/services/books/categorize/backfill.rb`, `lib/tasks/books/categorize.rake`, `app/sidekiq/books/categorize_backfill_job.rb` (only if it validates the scope)
- Test: `test/lib/services/books/categorize/backfill_test.rb`, the rake/job tests if they exist

**Interfaces:**
- Produces:
  - `Backfill::SCOPES = %w[origin_only categories_only all]`. `Backfill.refusal(scope)` returns nil for these and `"unknown scope <x>; use one of origin_only, categories_only, all"` otherwise.
  - `Backfill.candidates(scope:, book_ids: nil)` selects by scope:
    - `origin_only`: unchanged;
    - `categories_only`: `NOT EXISTS done_rows(Categories::Judge::KIND, BookCategoriesTask::PROMPT_VERSION)`;
    - `all`: books not done in **either** kind.

    `done_rows(kind, version)` generalises today's query; the deferred rule is unchanged and applies per kind. Order:
    - ranked first;
    - then books with no real country (for `origin_only` and `all`) or with no direct genre link other than Fiction/Nonfiction (for `categories_only` and `all`);
    - then the rest, ties by id.
  - The planned run carries `options: {"context" => "backfill", "label" => label, "scope" => scope}`.
  - `first_slot_time` is unchanged (the evidence step's slots).
  - `SPACING` stays 8. See Rulings.
  - The rake help and usage text name the three scopes, with the example `books:categorize:backfill[categories_only,all,categories-v1]`.

- [ ] **Step 1: Write the failing tests.**
  - `categories_only` leaves out books with a current successful `books.categories` row and keeps books done only for origin.
  - `all` keeps a book done for origin but not categories.
  - A book with no genre sorts before a book with genres among unranked books (`categories_only`).
  - The planned run's options carry the scope, and with `categories_only` the run's `categorize` step is skipped.
  - The refusal of `"bogus"`.
  - Delete the old "refuses any other scope" test.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/categorize/backfill_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categorize backfill: categories_only and all scopes"`

### Task 9: The report, restoring removals, and the unmatched list

**Files:**
- Create: `app/lib/services/books/categories/report.rb`, `app/lib/services/books/categories/restore_removals.rb`
- Modify: `lib/tasks/books/categories.rake` (Task 1's file)
- Test: `test/lib/services/books/categories/report_test.rb`, `test/lib/services/books/categories/restore_removals_test.rb`

**Interfaces:**
- Produces:
  - **`Categories::Report.call(label: nil)`** works over the latest `books.categories` row per book (reuse the shape of `Origin::Report.latest_rows`, parameterised by kind; extract it to `Categorize::LatestRows.call(kind:, label:)` and switch `Origin::Report` and `AcceptDisagreements` to it). Its `data` has:
    - `books:`;
    - `by_outcome:`;
    - `added:` `{type => count}`;
    - `confirmed:` `{type => count}`;
    - `removed:` `{type => count}`;
    - `held_back:` `{reason => count}`;
    - `type:` `{reason => count}`;
    - `type_conflicts:` `[{book_id, title, judged, held}]`, first 50;
    - `unmatched:` `{type => [[proposed, count]]}`, top 20 per type, case-folded;
    - `unlisted_genres:` `[[name, count]]`, top 30, case-folded: the task's `unlisted_genres` plus the dossier's Wikidata `genres` labels that `GenreMatcher#match` resolves to nothing. Each is a candidate alias for an existing genre; the report prints them under the heading "Genre names to alias (add as an alternative name on an existing genre, or ignore)". Nothing is created from this list;
    - `research_rows:`;
    - `research_cost_estimate:` (`Origin::Report::RESEARCH_COST_PER_ROW`);
    - `deferred_research:`;
    - `avg_added_per_book:`, `avg_removed_per_book:`.
  - **`Categories::RestoreRemovals.call(label:, apply:)`**: for each row with that label whose `facts["apply"]["removed"]` is non-empty, it re-creates each removed link with source `legacy` when the category is still active and the book lacks it, then reconciles the touched books once. Its `data` has `{books:, links:, skipped:}`.
  - **Rake** `books:categories:report[label]`, which prints every field (format like `books:origin:report`), and `books:categories:restore_removals[label]`, a dry run unless `APPLY=1`, with the label required.

- [ ] **Step 1: Write the failing tests** for the counts over fixture-built rows, "only the latest row per book counts", restore (re-created as legacy, skipped when the category is deleted or already held, a dry run writes nothing), and the origin report tests still passing after the `LatestRows` extraction.
- [ ] **Step 2: Run them.** `bin/rails test test/lib/services/books/categories test/lib/services/books/origin`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests again.** Expected: PASS.
- [ ] **Step 5: Commit.** `"Books categories: run report, unmatched names, and restoring a run's removals"`

### Task 10: Docs and launch steps

**Files:**
- Modify: `docs/features/books_enrichment.md`, `docs/features/enrichment-workflows.md`, `docs/features/books-categories.md`, `docs/launch-todo.md`

The Technical Writer conventions apply: the code is the source of truth, and there are no per-class files.

- [ ] **Step 1: `books_enrichment.md`.** Add a "The `books.categories` kind" section after `books.origin`. It covers:
  - the dossier additions;
  - the task and vocabulary (`categories.description`, written by `books:categories:write_definitions`);
  - mapping, with its `via` values;
  - the apply and re-judge rules as built;
  - the facts keys;
  - research and budgets;
  - the rake tasks (report, restore_removals, write_definitions).

  Also list `books.categories` among the kinds.
- [ ] **Step 2: `enrichment-workflows.md`.** `book_enrichment` v5, `book_categorize` v2, the `scope` option and its skips.
- [ ] **Step 3: `books-categories.md`.** The `ai` and `worldcat` link sources and what a re-judge may remove.
- [ ] **Step 4: `docs/launch-todo.md`.**
  - **§14:** retitle it "Book origins and categories". Add:
    - a step 0, `bin/rails books:categories:write_definitions` then with `APPLY=1`, and fill any `missing` genre in admin;
    - the categories backfill `books:categorize:backfill[categories_only,all,categories-v1]` after the origin backfill. Alternatively, run `[all,...]` once in place of both, since one evidence gather serves both. Prefer that;
    - `books:categories:report[...]`;
    - `restore_removals` as the undo.

    Keep "only Shane runs it, after §12".
  - **§15 step 12** (the rehearsal): it now covers categories too (Task 11 of this plan).
- [ ] **Step 5: Commit.** `"Docs: books.categories kind, workflow v5/v2, ai link source, launch steps for the categories backfill"`

### Task 11: Full checks, then the categories rehearsal in development (controller, needs Shane's go)

- [ ] **Step 1: Run every check.** `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`. Expected: green, no new warnings.
- [ ] **Step 2: Ask Shane before spending on real AI calls.** The estimate is about 300 standard calls plus some fast calls.
- [ ] **Step 3: Prepare.** `bin/snapshot-dev-db.sh --label pre-categories-rehearsal`, then `bin/rails db:migrate`, then `bin/rails books:categories:write_definitions APPLY=1`.
- [ ] **Step 4: Pick the books.** Per spec §4.11 step 1: 100 top-ranked, 100 mid-ranked, and 100 unranked or recent, including non-English-origin, nonfiction and children's/YA books. Write their ids to the scratchpad.
- [ ] **Step 5: Run.** `BOOK_IDS=... APPLY=1 bin/rails "books:categorize:backfill[all,300,rehearsal-c1]"`, with the dev Sidekiq running. Wait for it to finish.
- [ ] **Step 6: Report.** Run `books:categories:report[rehearsal-c1]` and `books:origin:report[rehearsal-c1]`.
- [ ] **Step 7: Build the side-by-side review** as an Artifact: per book, the old links, new links, removed links, held-back items with reasons, unmatched names, origin before and after, and the evidence sections present. Add the measurements from spec §4.11 step 4: cost per book by path, the Wikidata work share, applied vs held back, and removals per book.
- [ ] **Step 8: Shane signs off** on the prompts, gates and cost estimate before any production run, then the PR.

---

## Rulings made in this plan (the spec left these open, or this plan narrows it)

These need the owner's eye.

1. **Two steps, not one.** `categories` is its own workflow step after `categorize`, not a second call inside it. Each step retries on its own, so a categories failure never re-runs (and re-pays for) the origin judgment, and backfill scopes become step skips.
2. **One research call per book per run.** Categories researches only when neither `book_facts` nor `categorize` researched in the same run. Spec §4.8's single combined research call is not built. For the backfill, whose research cap is 0 by default, this changes nothing. An unknown book whose origin was researched gets its categories research on a later run.
3. **The backfill research cap is shared** by origin and categories: one `categorize_backfill_research_daily_cap`, counted over both kinds.
4. **Open Library is left out of the dossier.** The dossier reads only stored rows. The book's own description, the Wikipedia lead and plot, and the WorldCat summary cover what an OL description would add.
5. **Fiction and Nonfiction come from `book_type`, never from the genre list,** and do not count toward the 5-genre cap. Poetry and Religion & Spirituality are ordinary genre ids.
6. **"Picked" means any confidence.** A legacy link the judge picked at low confidence is not removed: it was picked. It is not re-sourced either, because only applied picks are re-sourced.
7. **Removals are decided first, against the links held before the run.** Additions are then capped against what remains, so a run can swap a dropped legacy genre for a new one.
8. **An exact location match must agree with the parent hint** (Review Focus 1). Otherwise it goes to the chooser.
9. **The admin action is the existing Enrich button.** `EnrichBookJob` already starts `books.book_categorize` with context `admin`, which now includes the categories step with re-judging on. No new button. Forcing research from the admin page is not wired.
10. **The Wikidata re-check** (off by default) now re-judges categories as well as origin for the books it re-checks. That is the point of a re-check, but it costs one standard call per book.
11. **Backfill spacing stays at 8 s.** With local Wikidata the real limit is Wikipedia's one request a second (about 2 per matched book). Lowering it is a one-constant change after the rehearsal measures requests per book.
12. **`write_definitions` never overwrites** a non-blank description that differs from the plan. It reports it instead.
13. **Genres we don't hold are handled through aliases, not a new table** (owner's question, 2026-11-09). The judge reports `unlisted_genres`, and the report ranks them with the unmatched Wikidata genre labels. The owner adds the useful ones as `alternative_names` on an existing genre and ignores the rest. Creating a genre stays a deliberate admin decision outside this pipeline; the genre list was cut down on purpose, and the old site's junk genres came from auto-creation. Note: the judge reads the vocabulary live, so a genre added in admin is offered to the AI at once (and needs a description). Every matcher already reads alternative names (Goodreads, the mapper, the support test), so one alias fixes all three. WorldCat keeps its own reviewed genre map.
