# Books category and origin enrichment, stage 2 (origin) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every book gets one national origin, judged from evidence (our record, the stage 1 `books.evidence` row, the last `book_facts` answer), applied only when well supported, never overwriting a real country. Existing books get it through a paced Sidekiq backfill.

**Architecture:**
- A `Dossier` reads the book, its latest `books.evidence` row and its latest `books.book_facts` row.
- A Wikidata shortcut applies the origin with no AI call when Wikidata, the author and the language agree. Otherwise `BookOriginTask` (standard role, the old site's nationality rules) answers, with a research fallback under budgets.
- A deterministic `Origin::Apply` writes the country, and `Origin::Judge` writes one `books.origin` ledger row per mode.
- Two workflows run it:
  - a `categorize` step in `books.book_enrichment` (version 4);
  - a new two-step `books.book_categorize` workflow (evidence, then categorize), used by the backfill and by the admin Enrich button's job.

**Tech Stack:** Rails 8, Minitest + Mocha + WebMock, Sidekiq, the workflow engine (`app/lib/workflows/`), `Services::Ai::Tasks::EnrichmentTask`, the `countries` gem (8.1, `ISO3166::Country`).

**Spec:** `docs/superpowers/specs/2026-11-02-books-category-origin-enrichment-design.md`, specifically:
- §4.2: the dossier, the origin parts only;
- §4.4: judging origin;
- §4.8: research fallback;
- §4.9: workflow;
- §4.10: backfill, prompt versions, rankings;
- §4.11: the rehearsal, for origin;
- §5: increment 2.

Stage 1 (evidence) shipped in PR #446. Stage 3 (categories) gets its own plan and extends `Dossier`, `Steps::Categorize`, `Categorize::Backfill` and the `books.book_categorize` workflow.

## Global Constraints

- **Where to run.** Rails commands run from `web-app/` in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-origin-enrichment`. Paths below are relative to `web-app/` unless they start with `docs/`.
- **Namespaces.** Inside `module Services; module Books`, always write `::Books::Book`, `::Books::Country` and `::Books::Author`. A bare `Books::` resolves to `Services::Books`.
- **Tests.**
  - Stub every external call: Mocha for clients and AI tasks, WebMock for HTTP. No test makes an AI call.
  - Tests mirror the namespace.
  - Minitest 6: use `assert_nil`.
  - No new warnings in `bin/rails test`.
  - `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check` are clean.
- **Generators and schema.**
  - Generate jobs with `bin/rails generate sidekiq:job <name>`.
  - This stage has no migrations. If one becomes necessary, run annotaterb with it and never set `ANNOTATERB_SKIP_ON_DB_TASKS`.
- **Results.** Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- **Ledger.** The ledger kind is `"books.origin"`. Every `books.origin` row's `facts` carries `"prompt_version" => Services::Ai::Tasks::Books::BookOriginTask::PROMPT_VERSION` (= `1`) and `"context"` (`"import"`, `"backfill"` or `"admin"`).
- **Placeholder countries.** These are not usable origins: `Services::Books::CountryLookup::PLACEHOLDERS` (`unknown multiple mulitple mixed`, compared lowercase).
  - An answer that names one writes nothing.
  - A book holding only placeholder rows counts as having no country.
- **Never create** a `Books::Country`. **Never overwrite** a book's real country automatically.
- **Indexing.** Every write to `books_book_countries` queues `SearchIndexRequest.create!(parent: book, action: :index_item)`, because the book index carries `country_ids`.
- **Research budgets.**
  - Imports and admin runs use `config.x.ai.research_daily_cap`, counted as `Enrichment.research.today.count`, as `EnrichBook` does.
  - The backfill uses a new `config.x.ai.categorize_backfill_research_daily_cap`, default **0**. It counts research-mode `books.origin` rows created today whose `facts->>'context' = 'backfill'`.
- **Long-running work goes through Sidekiq.** Rake tasks only print or enqueue.

## Review Focus

1. **A book whose only country row is "Unknown"** and a high-confidence answer of "French": the Unknown row is removed and French is added. Both `book_count` counters move, and a search index request is queued. Pinned in Task 5.
2. **A book that holds "American"**, answered high-confidence "British" with no Wikidata support: nothing changes and no disagreement is recorded. The same answer with Wikidata P495 = United Kingdom records a `disagreement` and still changes nothing. Pinned in Task 5.
3. **Odd answers.**
   - `"Chinese American"` gives `no_match` with the raw string kept.
   - `"multiple"` in lowercase gives `placeholder_answer`.
   - `"France"` (a country name, not an adjective) resolves to French.
   - Pinned in Tasks 1 and 5.
4. **The backfill research cap left at its default 0.** A low-confidence answer for a book with no origin never makes a research call. Its row is marked `deferred_research`, and the next backfill run plans that book again. Pinned in Tasks 6 and 8.
5. **Running the backfill twice.** The second run plans nothing for books already done under the current prompt version, and skips books with a running `books.book_enrichment` run. Pinned in Task 8.

---

### Task 1: Placeholder and place-named authors; country names in CountryLookup

**Files:**
- Create: `app/lib/services/books/authors/author_kind.rb`
- Modify: `app/lib/services/books/country_lookup.rb` (`find`)
- Test: `test/lib/services/books/authors/author_kind_test.rb`, `test/lib/services/books/country_lookup_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::Authors::AuthorKind.kind(author) -> :placeholder | :place | :person`
  - `AuthorKind.place_country(author) -> ::Books::Country | nil`
  - `CountryLookup.from_text` now also resolves country names.

Rules (from the owner's conventions, memory `placeholder-and-place-authors`):
- **`:placeholder`** when `Services::Books::Authors::UnknownAuthor.placeholder?(author.name)`, or the normalised name is `"various"` or `"various authors"`. Reuse `UnknownAuthor.normalize`.
- **`:place`** when the author's whole name is a country name: `ISO3166::Country.find_country_by_any_name(author.name)` is non-nil and `CountryLookup.from_text([nationality])` finds a row.
  - Do not use birth or death years to decide. Dev's "China" author has a junk `birth_year` of 1972.
- **`place_country`** is that row, or nil.

- [ ] **Step 1: Write the failing tests**

```ruby
test "Unknown, Anonymous and Various are placeholders" do
  %w[Unknown Anonymous Various].each { |name| assert_equal :placeholder, AuthorKind.kind(::Books::Author.new(name: name)) }
end

test "a country name is a place author with that nationality" do
  chinese = ::Books::Country.find_or_create_by!(name: "Chinese")
  author = ::Books::Author.new(name: "China", birth_year: 1972)
  assert_equal :place, AuthorKind.kind(author)
  assert_equal chinese, AuthorKind.place_country(author)
end

test "a person is a person" do
  assert_equal :person, AuthorKind.kind(::Books::Author.new(name: "Ernest Hemingway"))
  assert_nil AuthorKind.place_country(::Books::Author.new(name: "Ernest Hemingway"))
end
```

Add to `country_lookup_test.rb`:
```ruby
test "from_text resolves a country name to its nationality row" do
  french = ::Books::Country.find_or_create_by!(name: "French")
  assert_equal [french], CountryLookup.from_text(["France"]).countries
end

test "a nationality row still wins over the country-name fallback" do
  english = ::Books::Country.find_or_create_by!(name: "English")
  assert_equal [english], CountryLookup.from_text(["English"]).countries
end
```
Check the fixture file `test/fixtures/books/countries.yml` first, and use the existing rows where they exist.

- [ ] **Step 2: Run the tests to see them fail**

Run: `bin/rails test test/lib/services/books/authors/author_kind_test.rb test/lib/services/books/country_lookup_test.rb`

Expected: FAIL (`AuthorKind` is undefined; "France" is unmatched).

- [ ] **Step 3: Implement**
  - Add `AuthorKind` as above.
  - In `CountryLookup#find`, when no row matches the target name, try `ISO3166::Country.find_country_by_any_name(name)`. Look up its nationality's first comma part (`iso_nationality` already splits) and cache the result under the original key.
  - Placeholders still return nil before either lookup.

- [ ] **Step 4: Run the tests to see them pass.** Use the same command; expect PASS. Also run `bin/rails test test/lib/services/books/` to see the existing CountryLookup callers stay green.

- [ ] **Step 5: Commit.** Message: `Books origin: placeholder and place-named authors; CountryLookup reads country names`.

---

### Task 2: Evidence schema 2 (P495 ids and their countries); placeholder authors in Wikidata resolution

**Files:**
- Modify: `app/lib/services/books/evidence/gather.rb` (`SCHEMA_VERSION`, `wikidata_section_for`)
- Modify: `app/lib/services/books/evidence/resolve_wikidata_work.rb` (`authors_ok?`)
- Modify: `lib/tasks/books/enrich.rake` (`books:evidence` prints `facts["wikidata_qid"]`)
- Modify: `docs/features/books_enrichment.md` ("The `books.evidence` kind")
- Test: `test/lib/services/books/evidence/gather_test.rb`, `resolve_wikidata_work_test.rb`, and the existing rake test if one covers `books:evidence`

**Interfaces:**
- Consumes: `AuthorKind.kind` (Task 1).
- Produces:
  - `Gather::SCHEMA_VERSION = 2`.
  - Two new keys in the wikidata section:
    - `"country_ids"` (P495 QIDs, `work.countries`);
    - `"country_matches"` (`Books::Country` names from `CountryLookup.from_wikidata(work.countries, client: @wikidata).countries.map(&:name)`).
  - Version-1 rows lack both keys, and readers treat a missing key as `[]`.

Rules:
- **`country_matches`** is computed inside `wikidata_section_for`'s existing rescue. A `RateLimited` still propagates, and any other Wikimedia error fails the `wikidata` source as today.
- **`authors_ok?`** When every one of the book's authors is `:placeholder` or `:place`, accept a work with no P50, or whose P50 values are all `Q4233718` (Wikidata's "anonymous"). Reject any other P50 (`author_mismatch`), exactly as before. Books with at least one person author are unchanged.

- [ ] **Step 1: Write the failing tests**

```ruby
# gather_test.rb
test "the wikidata section carries P495 ids and the countries they map to" do
  # existing work stub with countries ["Q142"]; stub @wikidata.country_codes(["Q142"]) => {"Q142" => {"code" => "FR", "label" => "France"}}
  facts = Gather.call(book: @book, wikidata: @wikidata, wikipedia: @wikipedia, worldcat: @worldcat).data[:enrichment].facts
  assert_equal 2, facts["schema_version"]
  assert_equal ["Q142"], facts["wikidata"]["country_ids"]
  assert_equal ["French"], facts["wikidata"]["country_matches"]
end

# resolve_wikidata_work_test.rb
test "a book by Unknown accepts a work whose only author is anonymous" do
  # book whose only author is named "Unknown"; stored QID whose entity has P50 = Q4233718 and a matching label
  result = ResolveWikidataWork.call(book: @book, client: @client)
  assert_equal "Q_STORED", result.data[:qid]
end

test "a book by Unknown rejects a work naming a real author" do
  # same book; entity P50 = Q42
  assert_includes result.data[:rejected].map { it["reason"] }, "author_mismatch"
end
```
Follow each file's existing stub helpers. The rejected-entry shape is whatever `reject` already writes.

- [ ] **Step 2: Run them to see them fail.** Run: `bin/rails test test/lib/services/books/evidence/`. Expected: FAIL.

- [ ] **Step 3: Implement the three changes, the rake print fix, and the doc lines.**
  - The doc gets: schema 2, the two keys, and the placeholder rule.
  - The rake prints `QID: <facts["wikidata_qid"] || "none">`. It keeps the `via` from the section when present.

- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/evidence/ test/lib/workflows/books/steps/evidence_test.rb`. Expected: PASS.

- [ ] **Step 5: Commit.** Message: `Books evidence: schema 2 stores P495 ids and countries; anonymous works for placeholder authors`.

---

### Task 3: The origin dossier and the language table

**Files:**
- Create: `app/lib/services/books/categorize/dossier.rb`
- Create: `config/books/country_languages.yml`
- Create: `app/lib/services/books/origin/country_languages.rb`
- Test: `test/lib/services/books/categorize/dossier_test.rb`, `test/lib/services/books/origin/country_languages_test.rb`

**Interfaces:**
- Consumes: `AuthorKind` (Task 1); evidence facts, schema 1 or 2 (Task 2).
- Produces:
  - **`Services::Books::Categorize::Dossier.build(book:) -> Dossier`**, where `Dossier = Data.define(:book, :evidence_id, :record, :book_facts, :wikidata, :wikipedia, :worldcat)`.
  - **`#external?`**: true when any of wikidata, wikipedia or worldcat is present.
  - **`#real_countries -> [::Books::Country]`**
  - **`#author_countries -> [String]`**: person authors' country names plus place authors' `place_country` names. It excludes editors and placeholders.
  - **`#to_ledger -> Hash`**: string keys, with the Wikipedia lead cut to 500 chars.
  - **`Services::Books::Origin::CountryLanguages.include?(country_name, language_name) -> Boolean`**: case-insensitive on both sides; false for any nil or unknown key.

Section contents (string keys; a section is nil when its source has nothing):
- **`record`**:
  - `title`, `subtitle`, `first_published_year`, `original_language` (the name, or nil);
  - `countries` (all held names), `real_countries` (held names minus placeholders);
  - `authors`: one entry per book_author ordered by `position, id`, shaped `{"name", "role" => "author"|"editor", "kind" => "person"|"placeholder"|"place", "countries" => [names], "birth_year", "death_year", "place_country" => name|nil}`.
- **`book_facts`**: the latest `books.book_facts` row with outcome applied, nothing_to_apply or unrecognized, as `{"recognized", "mode", "original_language", "origin_countries", "book_type"}`.
  - Values are read from each fact's `"value"`.
  - nil when there is no such row.
- **`wikidata`**: from the latest `books.evidence` row's `facts["wikidata"]`: `qid label description countries country_ids country_matches languages publication_years`.
  - Missing list keys become `[]`.
- **`wikipedia`**: `{"title", "url", "lead" (first 1,000 chars), "infobox_country", "infobox_language"}` from `facts["wikipedia"]` and its `infobox` hash.
- **`worldcat`**: `{"publication_places", "earliest_year", "cataloging_languages"}` from `facts["worldcat"]`.
- **`evidence_id`**: the row's id, or nil.

`config/books/country_languages.yml` lists, for each `Books::Country` name, the languages a book from that country is written in. Use this content (names are compared lowercase against `languages.name`, so extra spellings do no harm):

```yaml
American: [English]
British: [English, Middle English, Old English, Scots, Scottish Gaelic, Welsh]
English: [English, Middle English, Old English]
Scottish: [English, Scots, Scottish Gaelic]
Welsh: [English, Welsh]
Irish: [English, Irish]
Northern Irish: [English, Irish]
Canadian: [English, French]
Australian: [English]
New Zealand: [English, Maori]
New Zealander: [English, Maori]
South African: [English, Afrikaans, Zulu, Xhosa]
Nigerian: [English, Yoruba, Igbo, Hausa]
Indian: [English, Hindi, Bengali, Urdu, Tamil, Telugu, Marathi, Kannada, Malayalam, Gujarati, Punjabi, Odia, Assamese, Sanskrit]
Japanese: [Japanese]
Chinese: [Chinese, Classical Chinese, Mandarin, Cantonese]
Korean: [Korean]
Indonesian: [Indonesian]
French: [French, Old French]
Belgian: [French, Dutch]
Swiss: [German, French, Italian]
German: [German]
Austrian: [German]
Russian: [Russian]
Soviet: [Russian]
Ukrainian: [Ukrainian]
Polish: [Polish]
Czech: [Czech]
Slovak: [Slovak]
Hungarian: [Hungarian]
Romanian: [Romanian]
Bulgarian: [Bulgarian]
Serbian: [Serbian, Serbo-Croatian]
Croatian: [Croatian, Serbo-Croatian]
Yugoslav: [Serbo-Croatian, Serbian, Croatian, Slovenian, Macedonian]
Lithuanian: [Lithuanian]
Georgian: [Georgian]
Spanish: [Spanish, Catalan, Galician, Basque]
Mexican: [Spanish]
Argentinian: [Spanish]
Chilean: [Spanish]
Colombian: [Spanish]
Peruvian: [Spanish]
Cuban: [Spanish]
Uruguayan: [Spanish]
Brazilian: [Portuguese]
Portuguese: [Portuguese]
Italian: [Italian]
Roman: [Latin]
Greek: [Greek, Ancient Greek, Modern Greek]
Dutch: [Dutch]
Swedish: [Swedish]
Norwegian: [Norwegian, Norwegian Bokmål, Norwegian Nynorsk]
Danish: [Danish]
Finnish: [Finnish, Swedish]
Icelandic: [Icelandic, Old Norse]
Turkish: [Turkish]
Ottoman: [Ottoman Turkish, Turkish]
Israeli: [Hebrew]
Iranian: [Persian]
Egyptian: [Arabic]
```

- [ ] **Step 1: Write the failing tests**

```ruby
# dossier_test.rb
test "reads the latest evidence row and the book's record" do
  # book with original_language English, country "Unknown" only, author person with country American;
  # an older and a newer books.evidence row (schema 2), the newer with wikidata countries ["United States"], country_matches ["American"]
  dossier = Dossier.build(book: @book)
  assert_equal newer.id, dossier.evidence_id
  assert_equal ["American"], dossier.wikidata["country_matches"]
  assert_equal [], dossier.real_countries
  assert_equal ["Unknown"], dossier.record["countries"]
  assert dossier.external?
end

test "a schema 1 evidence row has no country_matches and still builds" do
  assert_equal [], Dossier.build(book: @book).wikidata["country_matches"]
end

test "a book with no evidence row has no external section" do
  refute Dossier.build(book: @book).external?
end

test "placeholder and place authors are marked, and only people and places give author countries" do
  # authors: "Unknown" (placeholder), "China" (place -> Chinese), an editor with country British
  dossier = Dossier.build(book: @book)
  assert_equal %w[placeholder place person], dossier.record["authors"].map { it["kind"] }
  assert_equal ["Chinese"], dossier.author_countries
end

test "book_facts comes from the latest usable book_facts row" do
  # a failed row (newest) and an applied row with origin_countries {"value" => ["French"], ...}
  assert_equal ["French"], Dossier.build(book: @book).book_facts["origin_countries"]
end

test "to_ledger trims the Wikipedia lead" do
  assert_operator Dossier.build(book: @book).to_ledger.dig("wikipedia", "lead").length, :<=, 500
end

# country_languages_test.rb
test "a language of the country" do
  assert CountryLanguages.include?("French", "french")
  assert CountryLanguages.include?("greek", "Ancient greek")
end

test "a language that is not the country's" do
  refute CountryLanguages.include?("French", "English")
end

test "an unknown country or a nil is false" do
  refute CountryLanguages.include?("Atlantean", "English")
  refute CountryLanguages.include?("French", nil)
end
```

- [ ] **Step 2: Run them to see them fail.** Run: `bin/rails test test/lib/services/books/categorize/ test/lib/services/books/origin/`. Expected: FAIL.

- [ ] **Step 3: Implement both.** `CountryLanguages` loads the YAML once, with lowercase keys and values, from `Rails.root.join("config/books/country_languages.yml")`.

- [ ] **Step 4: Run them to see them pass.**

- [ ] **Step 5: Commit.** Message: `Books origin: the dossier and the country language table`.

---

### Task 4: BookOriginTask and the Wikidata shortcut

**Files:**
- Create: `app/lib/services/ai/tasks/books/book_origin_task.rb`
- Create: `app/lib/services/books/origin/shortcut.rb`
- Test: `test/lib/services/ai/tasks/books/book_origin_task_test.rb`, `test/lib/services/books/origin/shortcut_test.rb`

**Interfaces:**
- Consumes: `Dossier` (Task 3), `CountryLanguages` (Task 3).
- Produces:
  - **`Services::Ai::Tasks::Books::BookOriginTask.new(parent: book, dossier:, mode: :knowledge|:research)`**, a subclass of `EnrichmentTask`.
    - `PROMPT_VERSION = 1`.
    - `#call` returns the usual `Services::Ai::Result` with `data[:facts]` = `{recognized:, original_language:, nationality:, confidence:, reason:}` and `data[:citations]`.
    - The knowledge role is `:standard`. Do not pass `:sourced`.
  - **`Services::Books::Origin::Shortcut.call(dossier) -> ::Books::Country | nil`**

**Shortcut rule.** Return the country only when all of these hold:
- `dossier.wikidata` is present;
- its `country_ids` has exactly 1 entry (or, on a schema-1 row, `countries` has exactly 1);
- `country_matches` has exactly 1 entry;
- that name is in `dossier.author_countries`;
- `CountryLanguages.include?(name, language)` is true. `language` is the first present of:
  1. `record["original_language"]`;
  2. the single entry of `wikidata["languages"]`, when there is exactly one;
  3. `book_facts["original_language"]`.

The returned row is `CountryLookup.from_text([name]).countries.first`.

**System message.** Use this verbatim. `#{research_instruction}` is empty in knowledge mode. In research mode it is the same sentence `BookFactsTask#research_instruction` uses.

```
You decide the national origin of one book for a book catalog: the single country whose literature the book belongs to, given as one English nationality adjective such as "French", "Japanese" or "Brazilian".#{research_instruction}

Rules, in order:
1. Start from the original language the book was written in.
2. Then the author's primary nationality at the time the book was first published.
3. If the original language is a main language of the author's country, use that country.
4. If they disagree, the country associated with the original language wins.
5. For an author with several nationalities, use the one that matches the original language.
6. If the author's nationality changed over time, use the one at the time of first publication.
7. Use the book's setting or cultural context only when it agrees with the original language or the author's nationality.
8. Never a mixed nationality such as "Chinese American". Choose one.
9. Answer "Unknown" when you cannot determine a single nationality. It is better than a guess.
10. Answer "Multiple" only when no single answer is defensible after every rule above.

Evidence. The book's record and what outside sources say about it follow. Wikidata's country of origin and the Wikipedia infobox's country are strong evidence when they agree with the author and the language. Library publication places show where editions were printed, which is weak evidence: translations and foreign editions are published everywhere. An author marked as a placeholder is not a person: the book has no known author, so decide from the language and the sources. An author marked as a place name stands for a traditional or anonymous work from that place, and is strong evidence of origin.

Examples:
- "The Great Gatsby" by F. Scott Fitzgerald. Original language English; author American. Result: American.
- "One Hundred Years of Solitude" by Gabriel García Márquez. Spanish; Colombian. Result: Colombian.
- "Lolita" by Vladimir Nabokov. English; Russian-American. Result: American, because of the original language.
- "The Blind Assassin" by Margaret Atwood. English; Canadian. Result: Canadian.
- "Heart of Darkness" by Joseph Conrad. English; Polish-British. Result: British, from the original language and the author's adopted nationality.
- "One Thousand and One Nights". Arabic and Persian; no single author. Result: Multiple.
- "Ideas and Opinions" by Albert Einstein. Mostly German; German-Swiss-American. Result: German, from the original language and the author's nationality when he wrote it.
- "Haroun and the Sea of Stories" by Salman Rushdie. English; British-Indian. Result: British, from the original language and the author's citizenship.

Set "recognized" to false if you do not know this specific book. "original_language" is the language the book was written in, or null. "confidence" is high, medium or low for the nationality you give. "reason" is one short sentence naming the rule and the evidence that decided it. Output only the JSON object described by the schema.
```

**User prompt.** One line per present item, in this order and with these labels:
- `Book: "<title>"`
- `Subtitle: <subtitle>`
- One line per author:
  - a person: `Author: <name> (<life years>; <countries>)`;
  - a placeholder: `Author: none known (catalogued as "<name>", a placeholder, not a person)`;
  - a place: `Author: catalogued under the place name "<name>" (origin signal: <place_country>)`;
  - an editor: `Editor: <name>`.
- `First published (our record): <YearLabel>`
- `Original language (our record): <name>`
- `Our current origin: <real country names>`, only when real countries exist.
- `Earlier AI facts: original language <x>; origin <y>`, from `book_facts`, only for present values.
- The Wikidata line: `Wikidata: "<label>" (<description>); country of origin: <countries>; language: <languages>; published: <years>`
- `Wikipedia infobox: country <x>; language <y>`
- `Wikipedia lead: <lead>`
- `Library records (WorldCat): published in <first 5 places>; earliest edition <year>`
- A blank line, then `Give the book's origin as JSON matching the schema.`

Life years use `Services::Books::YearLabel`, as `BookFactsTask#life_years` does. Read them from the dossier's author hash, not from the database.

**Schema.**
```ruby
class ResponseSchema < OpenAI::BaseModel
  required :recognized, OpenAI::Boolean, doc: "false if you do not know this specific book"
  required :original_language, String, nil?: true, doc: "The language's English name, or null"
  required :nationality, String, doc: "One English nationality adjective, or Unknown, or Multiple"
  required :confidence, String, doc: "high, medium or low, for the nationality"
  required :reason, String, doc: "One short sentence: the rule and evidence that decided it"
end
```

- [ ] **Step 1: Write the failing tests**

```ruby
# book_origin_task_test.rb (no provider call: test the prompt and schema through send, the way book_facts_task_test.rb does)
test "the user prompt carries the record and every evidence section" do
  prompt = task.send(:user_prompt)
  assert_includes prompt, "Author: Gabriel García Márquez (1927–2014; Colombian)"
  assert_includes prompt, "Wikidata: \"One Hundred Years of Solitude\""
  assert_includes prompt, "country of origin: Colombia"
  assert_includes prompt, "Library records (WorldCat): published in Buenos Aires"
end

test "a placeholder author is not presented as a person" do
  assert_includes task_for(unknown_author_book).send(:user_prompt), "Author: none known (catalogued as \"Unknown\", a placeholder, not a person)"
end

test "a place author is presented as an origin signal" do
  assert_includes task_for(china_book).send(:user_prompt), "catalogued under the place name \"China\" (origin signal: Chinese)"
end

test "sections the dossier lacks produce no lines" do
  prompt = task_for(book_without_evidence).send(:user_prompt)
  refute_includes prompt, "Wikidata:"
  refute_includes prompt, "Wikipedia"
end

test "the system message keeps the old site's worked examples" do
  assert_includes task.send(:system_message), "\"Lolita\" by Vladimir Nabokov"
  assert_includes task.send(:system_message), "Result: Multiple"
end

test "research mode asks for web search and uses the research role" do
  research = task_for(@book, mode: :research)
  assert_includes research.send(:system_message), "Use web search"
  assert_equal :research, research.send(:task_role)
end

test "PROMPT_VERSION is 1" do
  assert_equal 1, BookOriginTask::PROMPT_VERSION
end
```

`shortcut_test.rb` builds `Dossier` values directly with `Dossier.new(...)` and needs no database for the dossier. It covers:
- returns French when the Wikidata country is French, the author is French and the language is French;
- nil when the author is Belgian;
- nil when the language is English;
- nil when Wikidata lists two countries;
- nil without a wikidata section;
- a place author ("China", place_country Chinese) with Wikidata Chinese and language Classical Chinese returns Chinese.

- [ ] **Step 2: Run them to see them fail.**

- [ ] **Step 3: Implement both.**

- [ ] **Step 4: Run them to see them pass.**

- [ ] **Step 5: Commit.** Message: `Books origin: BookOriginTask with the old nationality rules, and the Wikidata shortcut`.

---

### Task 5: Apply an origin answer

**Files:**
- Create: `app/lib/services/books/origin/apply.rb`
- Test: `test/lib/services/books/origin/apply_test.rb`

**Interfaces:**
- Consumes: `Dossier` (Task 3), `CountryLookup` (Task 1).
- Produces: `Services::Books::Origin::Apply.call(book:, dossier:, nationality:, confidence:) -> Result`.
  - `data` is `{applied: Boolean, reason: String, country: String|nil, raw: String|nil, held: [String], replaced: [String]}`.

**Rules,** evaluated in this order. `reason` takes one of the quoted values.

1. A blank `nationality` gives `"null"`.
2. A nationality whose lowercase form is in `CountryLookup::PLACEHOLDERS` gives `"placeholder_answer"`.
3. If `CountryLookup.from_text([nationality])` matches nothing, the result is `"no_match"`, with `raw` set to the string.
4. The book holds real countries (`dossier.real_countries`; `held` lists their names):
   - one of them is the answer: `"already_set"`;
   - otherwise, if `confidence == "high"` and `dossier.wikidata&.dig("country_matches")` includes the answer's name: `"disagreement"`;
   - otherwise: `"already_set"`.
   - Nothing is written in any of these cases.
5. The book holds no real country:
   - `confidence == "high"`: write it, `"filled"`;
   - `confidence == "medium"` and the answer is supported: write it, `"filled"`. Supported means the wikidata `country_matches` includes it, or `CountryLookup.from_text` over the infobox country (split on `,`, `;`, `/` and ` and `) includes it;
   - `"medium"` otherwise: `"unsupported"`;
   - anything else: `"low_confidence"`.

**Write,** in one transaction:
- destroy the book's placeholder `book_countries` rows (`replaced` lists their names);
- `find_or_create_by!` the answer's row;
- queue `SearchIndexRequest.create!(parent: book, action: :index_item)`.

Use `destroy`, not `delete`, so the `book_count` counter cache moves.

- [ ] **Step 1: Write the failing tests**

```ruby
test "a high answer replaces the Unknown placeholder" do
  # book holds only Unknown
  result = Apply.call(book: @book, dossier: dossier, nationality: "French", confidence: "high")
  assert_equal [true, "filled", "French", ["Unknown"]], [result.data[:applied], result.data[:reason], result.data[:country], result.data[:replaced]]
  assert_equal ["French"], @book.reload.countries.map(&:name)
  assert_equal unknown_count_before - 1, @unknown.reload.book_count
  assert SearchIndexRequest.exists?(parent: @book, action: :index_item)
end

test "a medium answer needs Wikidata or the infobox" do
  assert_equal "unsupported", Apply.call(book: @book, dossier: dossier(wikidata: nil), nationality: "French", confidence: "medium").data[:reason]
  assert_equal "filled", Apply.call(book: @book, dossier: dossier(infobox_country: "France"), nationality: "French", confidence: "medium").data[:reason]
end

test "low confidence writes nothing" do
  assert_equal "low_confidence", Apply.call(book: @book, dossier: dossier, nationality: "French", confidence: "low").data[:reason]
  assert_empty @book.reload.countries.reject { it.name == "Unknown" }
end

test "a real country is never overwritten, and an unsupported difference is not a disagreement" do
  # book holds American
  result = Apply.call(book: @book, dossier: dossier(wikidata: nil), nationality: "British", confidence: "high")
  assert_equal ["already_set", ["American"]], [result.data[:reason], @book.reload.countries.map(&:name)]
end

test "a high difference that Wikidata backs is a disagreement and still writes nothing" do
  result = Apply.call(book: @book, dossier: dossier(country_matches: ["British"]), nationality: "British", confidence: "high")
  assert_equal ["disagreement", ["American"]], [result.data[:reason], result.data[:held]]
  assert_equal ["American"], @book.reload.countries.map(&:name)
end

test "Unknown, Multiple and multiple are placeholder answers" do
  %w[Unknown Multiple multiple].each { |n| assert_equal "placeholder_answer", Apply.call(book: @book, dossier: dossier, nationality: n, confidence: "high").data[:reason] }
end

test "a mixed nationality is no_match with the raw answer" do
  result = Apply.call(book: @book, dossier: dossier, nationality: "Chinese American", confidence: "high")
  assert_equal ["no_match", "Chinese American"], [result.data[:reason], result.data[:raw]]
end

test "a country name answer resolves" do
  assert_equal "French", Apply.call(book: @book, dossier: dossier, nationality: "France", confidence: "high").data[:country]
end
```

- [ ] **Step 2: Run to see them fail.** Then implement, run to see them pass.

- [ ] **Step 3: Commit.** Message: `Books origin: apply rules (placeholders, support, never overwrite, disagreements)`.

---

### Task 6: The origin judge and its ledger

**Files:**
- Create: `app/lib/services/books/origin/judge.rb`
- Modify: `config/initializers/ai.rb` (add `config.x.ai.categorize_backfill_research_daily_cap = 0`, with a comment that it is the backfill's own research cap, so a backfill never starves imports, and that it is raised after the rehearsal)
- Test: `test/lib/services/books/origin/judge_test.rb`

**Interfaces:**
- Consumes: `Dossier`, `Shortcut`, `BookOriginTask`, `Apply`.
- Produces: `Services::Books::Origin::Judge.call(book:, context:, label: nil, research_allowed: true, force: false, force_research: false) -> Result`.
  - `KIND = "books.origin"`.
  - `data` is `{enrichments: [Enrichment], applied: Boolean}`.
  - `success?` is false when any row failed. The step raises on that.

**Flow:**
1. If the title is blank, write one `skipped` row with reason `"missing_inputs"`.
2. Build the `Dossier` and run the `Shortcut`.
3. **The book holds a real country and `force` is false.** No AI call.
   - With a shortcut country, `Apply` it as `confidence: "high"`. This yields `already_set` or `disagreement`.
   - Without one, write a `nothing_to_apply` row with reason `"has_origin"`.
   - `path` is `"shortcut"` or `"has_origin"`.
4. **Otherwise, with a shortcut country.** `Apply` it as high, with `path` `"shortcut"`, reason from Apply, and `answer.reason` `"wikidata_agrees"`.
5. **Otherwise, the judge path.**
   - The first mode is `:research` when `force_research`, or when `first_published_year >= config.x.ai.knowledge_cutoff_year` and research is permitted (see below).
     - A past-cutoff book whose research is not permitted runs `:knowledge` and is marked deferred.
   - Otherwise the first mode is `:knowledge`.
   - Run the task and `Apply` its nationality and confidence.
   - The run **needs research** when:
     - the mode was knowledge;
     - the book still has no real country;
     - and either the answer's confidence is `"low"`, or (`recognized == false` and `!dossier.external?`).
   - When research is needed and permitted, write the knowledge row, then run research and write its row.
   - When research is needed and not permitted, the knowledge row carries `"deferred_research" => true`. The exception is `research_allowed: false`, where book_facts already researched in this run: no deferral is marked.

**Research is permitted when:**
- `research_allowed` is true;
- and either `force_research` is set, or the context's budget is not spent:
  - `"backfill"`: fewer than `categorize_backfill_research_daily_cap` research `books.origin` rows today with `facts->>'context' = 'backfill'`;
  - `"import"` and `"admin"`: `Enrichment.research.today.count < research_daily_cap`.

**Rows.** Each row gets:
- `kind`, and `mode`: knowledge for shortcut and has_origin rows;
- `provider`, `model` and `ai_chat` from the task's chat when one ran;
- `citations`.

`outcome`:
- `applied` when Apply wrote;
- `unrecognized` when the task said `recognized == false` and `!dossier.external?`. In that case Apply is not called and the reason is `"unrecognized"`;
- `failed` with `error` when the task failed, or answered without `:nationality`;
- `nothing_to_apply` otherwise.

`reason` is the Apply reason (or the path's reason above).

`facts`:
```ruby
{"prompt_version" => BookOriginTask::PROMPT_VERSION, "context" => context, "label" => label, "path" => "shortcut"|"has_origin"|"judge",
 "dossier" => dossier.to_ledger, "answer" => {"nationality", "confidence", "reason", "recognized", "original_language"},
 "origin" => apply.data (string keys), "deferred_research" => true|false}
```

Any exception after the task call writes a `failed` row, as `EnrichBook#run` does.

- [ ] **Step 1: Write the failing tests** (stub `BookOriginTask#call` with Mocha)

```ruby
test "the shortcut applies with no AI call" do
  BookOriginTask.any_instance.expects(:call).never
  result = Judge.call(book: @book_with_agreeing_wikidata, context: "import")
  row = result.data[:enrichments].sole
  assert_equal ["applied", "shortcut", 1], [row.outcome, row.facts["path"], row.facts["prompt_version"]]
end

test "a book with a real country makes no AI call" do
  BookOriginTask.any_instance.expects(:call).never
  assert_equal "has_origin", Judge.call(book: @american_book, context: "backfill").data[:enrichments].sole.reason
end

test "force judges a book that has a real country" do
  stub_answer(nationality: "American", confidence: "high")
  assert_equal "already_set", Judge.call(book: @american_book, context: "admin", force: true).data[:enrichments].sole.reason
end

test "a high knowledge answer applies" do
  stub_answer(nationality: "French", confidence: "high")
  row = Judge.call(book: @book, context: "import").data[:enrichments].sole
  assert_equal ["applied", "knowledge", "filled"], [row.outcome, row.mode, row.reason]
end

test "a low answer researches within the import cap" do
  stub_answers({nationality: "French", confidence: "low"}, {nationality: "French", confidence: "high"})
  rows = Judge.call(book: @book, context: "import").data[:enrichments]
  assert_equal %w[knowledge research], rows.map(&:mode)
  assert rows.last.applied?
end

test "the backfill cap at 0 defers research" do
  stub_answer(nationality: "French", confidence: "low")
  rows = Judge.call(book: @book, context: "backfill").data[:enrichments]
  assert_equal ["knowledge"], rows.map(&:mode)
  assert rows.sole.facts["deferred_research"]
end

test "research_allowed false runs knowledge only and does not defer" do
  stub_answer(nationality: "French", confidence: "low")
  row = Judge.call(book: @book, context: "import", research_allowed: false).data[:enrichments].sole
  refute row.facts["deferred_research"]
end

test "an unrecognized book with no external evidence is unrecognized and researched" do
  # no evidence row
  stub_answers({recognized: false, nationality: "Unknown", confidence: "low"}, {recognized: true, nationality: "Peruvian", confidence: "high"})
  rows = Judge.call(book: @book, context: "import").data[:enrichments]
  assert_equal %w[unrecognized applied], rows.map(&:outcome)
end

test "a past-cutoff book goes straight to research" do
  # first_published_year = 2026
  stub_answer(nationality: "French", confidence: "high")
  assert_equal ["research"], Judge.call(book: @new_book, context: "import").data[:enrichments].map(&:mode)
end

test "a failed task writes a failed row and fails the result" do
  BookOriginTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "boom"))
  result = Judge.call(book: @book, context: "import")
  refute result.success?
  assert result.data[:enrichments].sole.failed?
end
```

- [ ] **Step 2: Run to see them fail.** Then implement, run to see them pass.

- [ ] **Step 3: Commit.** Message: `Books origin: the judge writes books.origin rows with prompt versions and research budgets`.

---

### Task 7: Workflows: `categorize` in book_enrichment v4, the `books.book_categorize` workflow, and book_facts stops applying origin

**Files:**
- Create: `app/lib/workflows/books/steps/categorize.rb`
- Create: `app/lib/workflows/books/book_categorize.rb`
- Modify: `app/lib/workflows/books/steps/evidence.rb` (`initialize(reuse_fresh: false)`)
- Modify: `app/lib/workflows/books/book_enrichment.rb` (version 4, the `categorize` step, and the header comment)
- Modify: `app/lib/workflows/registry.rb` (`"books.book_categorize" => "Workflows::Books::BookCategorize"`)
- Modify: `app/lib/services/books/apply_book_facts.rb` (`origin_countries` becomes recorded-only)
- Modify: `app/sidekiq/books/enrich_book_job.rb` (start `books.book_categorize` after a successful run)
- Modify: `docs/features/enrichment-workflows.md`, `docs/features/books_enrichment.md`
- Test: `test/lib/workflows/books/steps/categorize_test.rb`, `test/lib/workflows/books/book_categorize_test.rb`, `test/lib/workflows/books/steps/evidence_test.rb`, `test/lib/workflows/books/book_enrichment_test.rb`, `test/lib/services/books/apply_book_facts_test.rb`, `test/sidekiq/books/enrich_book_job_test.rb`, plus the workflow definition test that validates registered definitions.

**Interfaces:**
- Consumes: `Origin::Judge.call` (Task 6), `Gather::SCHEMA_VERSION` (Task 2).
- Produces:
  - **`Workflows::Books::BookCategorize.start(book, initiated_by:, options: {}, start_after: nil) -> WorkflowRun`.** It is shaped like `AuthorEnrichment.start`. Workflow `"books.book_categorize"`, version 1, target `::Books::Book`, with two steps:
    - `evidence` (queue `:low`, lease 10 minutes, `Steps::Evidence.new(reuse_fresh: true)`);
    - `categorize` (queue `:low`, lease 10 minutes, `waits_on: {evidence: :finish}`, `Steps::Categorize.new`).
    - Run options read by the steps: `"context"`, `"label"`, `"force_judge"` and `"force_research"`.
  - **`Steps::Categorize#call(step:, run:, target:)`.** It calls `Origin::Judge` with:
    - `context: run.options["context"] || (run.workflow == "books.book_enrichment" ? "import" : "backfill")`;
    - `label: run.options["label"]`;
    - `force: run.options.fetch("force_judge", false)`;
    - `force_research:` the run's `"force_research"`, only when the run is `books.book_categorize` (in `books.book_enrichment` that option belongs to book_facts);
    - `research_allowed: !book_facts_researched?(run)`. This is true when the run has a `book_facts` step and an `Enrichment` with that `workflow_step_id` and mode `research` exists.
    - It raises when `success?` is false. Otherwise it returns `Outcome.succeeded(<last row's reason or outcome>, {"enrichment_ids" => [...], "applied" => Boolean})`.
  - **`Steps::Evidence.new(reuse_fresh: true)`.** When the book's latest `books.evidence` row has `facts["schema_version"] == Gather::SCHEMA_VERSION` and an empty `sources_failed`, it returns `Outcome.succeeded("reused", {"enrichment_id" => row.id, "qid" => row.facts["wikidata_qid"]})` without calling Gather. The default (`false`) behaves as today.
  - **BookEnrichment v4** adds `add_step key: :categorize, queue: :low, lease: 10.minutes, waits_on: {book_facts: :finish, evidence: :finish}, adapter: Steps::Categorize.new`. Fix the evidence step's comment ("Nothing waits on it yet"). The header comment adds the version 4 paragraph: a run planned under version 3 has no categorize step and still runs.
  - **`ApplyBookFacts`.** `origin_countries` joins `RECORDED_ONLY` handling, with reason `"superseded"` (the origin step decides now). Its value is still recorded. Remove `apply_origin_countries` and anything only it used.
  - **`Books::EnrichBookJob#perform`.** After a successful `EnrichBook`, call `Workflows::Books::BookCategorize.start(book, initiated_by: "enrich_book_job", options: {"context" => "admin", "force_research" => force_research})`. This keeps the admin Enrich With AI button, `books:enrich_missing` and the deferred hand-off setting an origin.

- [ ] **Step 1: Write the failing tests**

```ruby
# categorize_test.rb
test "calls the judge with import context in a book_enrichment run" do
  Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "import", research_allowed: true)).returns(ok_result)
  Steps::Categorize.new.call(step: step, run: book_enrichment_run, target: @book)
end

test "no research when book_facts researched in this run" do
  # an Enrichment(kind books.book_facts, mode research, workflow_step_id: run.step(:book_facts).id)
  Services::Books::Origin::Judge.expects(:call).with(has_entries(research_allowed: false)).returns(ok_result)
  Steps::Categorize.new.call(step: step, run: book_enrichment_run, target: @book)
end

test "backfill context and label come from a book_categorize run" do
  Services::Books::Origin::Judge.expects(:call).with(has_entries(context: "backfill", label: "origin-v1")).returns(ok_result)
  Steps::Categorize.new.call(step: step, run: categorize_run(options: {"context" => "backfill", "label" => "origin-v1"}), target: @book)
end

test "a failed judge raises so the coordinator retries" do
  Services::Books::Origin::Judge.stubs(:call).returns(failed_result)
  assert_raises(StandardError) { Steps::Categorize.new.call(step: step, run: book_enrichment_run, target: @book) }
end

# evidence_test.rb
test "reuse_fresh reuses a current, complete evidence row" do
  Services::Books::Evidence::Gather.expects(:call).never
  assert_equal "reused", Steps::Evidence.new(reuse_fresh: true).call(step: step, run: run, target: @book).outcome
end

test "reuse_fresh gathers again when the row lists a failed source or an old schema" do
  Services::Books::Evidence::Gather.expects(:call).twice.returns(gather_result)
  # one row with sources_failed ["worldcat"]; then one with schema_version 1
end

# book_enrichment_test.rb
test "version 4 plans categorize after book_facts and evidence" do
  run = BookEnrichment.start(@book, initiated_by: "test")
  categorize = run.step(:categorize)
  assert_equal %w[book_facts evidence], categorize.prerequisite_steps.map(&:key).sort  # use the association the existing tests use
end

# book_categorize_test.rb
test "plans evidence then categorize, and a second start reuses the active run" do
  run = BookCategorize.start(@book, initiated_by: "backfill", options: {"context" => "backfill"})
  assert_equal %w[categorize evidence], run.steps.map(&:key).sort
  assert_equal run, BookCategorize.start(@book, initiated_by: "backfill")
end

test "start_after holds the evidence step" do
  run = BookCategorize.start(@book, initiated_by: "backfill", start_after: 1.hour.from_now)
  assert run.step(:evidence).waiting?
end

# apply_book_facts_test.rb (replace the origin tests)
test "origin_countries is recorded, not applied" do
  result = ApplyBookFacts.call(book: @book, facts: facts(origin_countries: {value: ["French"], confidence: "high"}))
  assert_equal [false, "superseded", ["French"]], result.data[:facts]["origin_countries"].values_at("applied", "reason", "value")
  assert_empty @book.reload.countries
end

# enrich_book_job_test.rb
test "a successful enrichment starts the categorize workflow" do
  Services::Books::EnrichBook.stubs(:call).returns(success_result)
  Workflows::Books::BookCategorize.expects(:start).with(@book, has_entry(initiated_by: "enrich_book_job"))
  Books::EnrichBookJob.new.perform(@book.id)
end
```

Use the existing step and run helpers in `test/lib/workflows/books/steps/*_test.rb` and `test/support/workflows/`. Integration flows that run the whole book workflow inline (stage 1 found two) must stub `Services::Books::Origin::Judge`, as they stub Gather. Search `test/` for `Evidence::Gather.stubs` and add the Judge stub beside each one.

- [ ] **Step 2: Run to see them fail.** Run: `bin/rails test test/lib/workflows/ test/lib/services/books/apply_book_facts_test.rb test/sidekiq/books/enrich_book_job_test.rb`.

- [ ] **Step 3: Implement. Update the two feature docs:**
  - `enrichment-workflows.md`: the third workflow, v4's `categorize` step, `reuse_fresh`.
  - `books_enrichment.md`: ApplyBookFacts no longer applies origin; a new "The `books.origin` kind" section covering the paths, reasons, `deferred_research`, `prompt_version` and the two research caps.

- [ ] **Step 4: Run** `bin/rails test`. Expected: 0 failures, 0 errors, no new warnings.

- [ ] **Step 5: Commit.** Message: `Books origin: categorize step (book_enrichment v4), books.book_categorize workflow, book_facts stops applying origin`.

---

### Task 8: The origin backfill

**Files:**
- Create: `app/lib/services/books/categorize/backfill.rb`
- Create: `app/sidekiq/books/categorize_backfill_job.rb` (`bin/rails generate sidekiq:job books/categorize_backfill`)
- Create: `lib/tasks/books/categorize.rake`
- Modify: `docs/launch-todo.md`
- Test: `test/lib/services/books/categorize/backfill_test.rb`, `test/sidekiq/books/categorize_backfill_job_test.rb`, `test/lib/tasks/books_categorize_rake_test.rb` (follow the existing rake test pattern, e.g. `books_authors_rake_test.rb`)

**Interfaces:**
- Consumes: `BookCategorize.start` (Task 7), `Judge::KIND`, `BookOriginTask::PROMPT_VERSION`.
- Produces:
  - **`Services::Books::Categorize::Backfill.candidates(scope: "origin_only", book_ids: nil) -> ActiveRecord::Relation`.** The books in plan order.
  - **`Backfill.call(scope:, limit:, label:, book_ids: nil) -> Result`.** `data` is `{planned:, reused:, done_at:}`. `SPACING = 8` (seconds, for Wikimedia's pace of one request a second).
  - **`Books::CategorizeBackfillJob#perform(scope, limit, label, book_ids = nil)`.** Queue `:low`, `retry: false`. It logs `"Categorize backfill <label>: planned N (reused M), evidence done by <time>"`.
  - **The rake task `books:categorize:backfill[scope,limit,label]`.**

Rules:
- **Scope.** Only `"origin_only"` is accepted in this stage. Any other value is refused with `"scope <x> arrives with stage 3 (categories); use origin_only"`, by both the service (failure Result) and the rake task (abort).
- **Done books are left out.** A book is done when its latest `books.origin` row (highest id) has:
  - `facts->>'prompt_version'` = the current version;
  - outcome not `failed` and not `skipped`;
  - `facts->>'deferred_research'` IS DISTINCT FROM `'true'`.
- **Books with a running `books.book_enrichment` run are left out**, because their import's categorize step will judge them.
- **Order:**
  1. books ranked in `Books::RankingConfiguration.default_primary`, by `ranked_items.rank` ascending (`item_type 'Books::Book'`);
  2. then books with no real country (none, or placeholders only);
  3. then the rest;
  4. ties by `books_books.id`.
- **Pacing.** Each book is planned with `BookCategorize.start(book, initiated_by: "backfill", options: {"context" => "backfill", "label" => label}, start_after: (index * SPACING).seconds.from_now)`. `reused` counts starts that returned an already-running run.
- **`book_ids`** restricts the candidates; it is for the rehearsal. `limit` is an Integer or nil (all).
- **The rake task.**
  - `limit` is a positive integer or `all`. `label` is required. `BOOK_IDS` (comma-separated) is optional.
  - Without `APPLY=1` it prints `"<n> books would be planned (scope origin_only, label <label>); about <n * 8 / 3600> hours of Wikimedia pacing. Re-run with APPLY=1 to queue Books::CategorizeBackfillJob."`.
  - With `APPLY=1` it enqueues the job and prints that it did.

**`docs/launch-todo.md`:**
- **A new section "## 12. Book origins (the backfill once, then weekly)",** with these steps:
  1. The dev rehearsal is done and the owner has signed off on the review (stage 2 plan, Task 10).
  2. In production (Shane runs with `!`), `bin/rails "books:categorize:backfill[origin_only,all,origin-v1]"` to see the count, then again with `APPLY=1`. It paces itself at one book every 8 seconds, so the whole catalog takes days. The ranked books go first. The research cap for the backfill is `config.x.ai.categorize_backfill_research_daily_cap`, which is 0 until raised. Until WorldCat is reachable from production, rows list `worldcat` in `sources_failed`, and a later run gathers those books again.
  3. `bin/rails "books:origin:report[origin-v1]"` (Task 9).
  4. Accept or skip the disagreements: `bin/rails "books:origin:accept_disagreements[origin-v1]"`, with `IDS=` and `APPLY=1` (Task 9).
  5. **Rankings.** The books list weights and book rankings, then author rankings. Filling origins changes `percentage_western` and so the western-canon penalty.
- **§4 gets a step 10:** after section 12 step 2 has run once, `bin/rails "books:categorize:backfill[origin_only,all,weekly]" APPLY=1` after the sync. It plans only books the sync added, and books a deferred research or failure left undone.
- **The cutover's "Section 4, steps 3-9" becomes "Section 4, steps 3-10".**

- [ ] **Step 1: Write the failing tests**

```ruby
test "orders ranked books first, then books without a real origin, then the rest" do
  assert_equal [@ranked.id, @unknown_only.id, @american.id], Backfill.candidates.where(id: [@american, @unknown_only, @ranked]).pluck(:id)
end

test "leaves out books done under the current prompt version" do
  @book.enrichments.create!(kind: "books.origin", outcome: :applied, facts: {"prompt_version" => 1, "context" => "backfill"})
  refute_includes Backfill.candidates.pluck(:id), @book.id
end

test "keeps books whose latest row deferred research, failed, or ran an older prompt" do
  # three books, one each; all three included
end

test "leaves out books with a running book_enrichment run" do
end

test "plans paced runs and reuses running ones" do
  result = Backfill.call(scope: "origin_only", limit: 2, label: "t", book_ids: [@a.id, @b.id])
  assert_equal 2, result.data[:planned]
  runs = WorkflowRun.where(workflow: "books.book_categorize").order(:id)
  assert_equal [{"context" => "backfill", "label" => "t"}], runs.map { it.options.slice("context", "label") }.uniq
  assert_operator runs.last.step(:evidence).run_after, :>, runs.first.step(:evidence).run_after
  assert_equal 2, Backfill.call(scope: "origin_only", limit: 2, label: "t", book_ids: [@a.id, @b.id]).data[:reused]
end

test "refuses any other scope" do
  refute Backfill.call(scope: "all", limit: 1, label: "t").success?
end
```

The rake tests cover:
- the dry run prints the count and enqueues nothing;
- `APPLY=1` enqueues one `Books::CategorizeBackfillJob` (wrap in `Sidekiq::Testing.fake!`);
- a missing label aborts;
- a `categories_only` scope aborts.

- [ ] **Step 2: Run to see them fail.** Then implement and run to see them pass.

- [ ] **Step 3: Write the launch-todo changes.**

- [ ] **Step 4: Commit.** Message: `Books origin: paced Sidekiq backfill through books.book_categorize, and its launch-todo steps`.

---

### Task 9: The origin report and accepting disagreements

**Files:**
- Create: `app/lib/services/books/origin/report.rb`
- Create: `app/lib/services/books/origin/accept_disagreements.rb`
- Modify: `lib/tasks/books/categorize.rake` (a `books:origin` namespace in the same file)
- Test: `test/lib/services/books/origin/report_test.rb`, `accept_disagreements_test.rb`, and the rake test from Task 8

**Interfaces:**
- **`Services::Books::Origin::Report.call(label: nil) -> Result`.** It reads the latest `books.origin` row per book, filtered to `facts->>'label' = label` when given. `data` is:
  ```ruby
  {books:, by_path: {"shortcut" => n, "judge" => n, "has_origin" => n}, by_reason: {"filled" => n, ...},
   applied_countries: [[name, n], ...] (top 15), disagreements: [{enrichment_id:, book_id:, title:, held: [..], proposed:}] (all),
   no_match: [[raw, n], ...] (top 20), research_rows:, research_cost_estimate: research_rows * 0.15, deferred_research:}
  ```
  `research_rows` counts all research-mode rows with that label, not only the latest per book.
- **`Services::Books::Origin::AcceptDisagreements.call(label: nil, enrichment_ids: nil, apply: false) -> Result`.**
  - It takes the latest-per-book rows with reason `"disagreement"`, an absent `facts["accepted_at"]`, and the book's current real country names still equal to `facts.dig("origin", "held")`. This keeps an admin's later edit from being reverted.
  - With `apply: true`, for each one, in a transaction:
    - destroy all the book's `book_countries`;
    - create the proposed country's row (`CountryLookup.from_text([proposed])`);
    - set `facts["accepted_at"]` (ISO 8601) on that enrichment;
    - queue a search index request.
  - `data` is `{candidates: [{enrichment_id:, book_id:, title:, held:, proposed:}], accepted: n}`.
  - Disagreements are a short list (they need Wikidata, the author and the language all agreeing against the held country), so this runs inline.
- **Rake tasks.**
  - `books:origin:report[label]` prints each `data` part in plain lines. Disagreements print as `#<book_id> <title>: <held> -> <proposed> (enrichment <id>)`.
  - `books:origin:accept_disagreements[label]` prints the candidates. `IDS=1,2` narrows to those enrichment ids; `APPLY=1` applies and prints `"accepted N"`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "report counts the latest row per book in a label" do
  # two rows for one book (older judge/low_confidence, newer shortcut/filled), one book in another label
  data = Report.call(label: "r1").data
  assert_equal [1, {"shortcut" => 1}, {"filled" => 1}], [data[:books], data[:by_path], data[:by_reason]]
end

test "report lists disagreements and no_match strings" do
  assert_equal "British", data[:disagreements].sole[:proposed]
  assert_equal [["Chinese American", 1]], data[:no_match]
end

test "accept replaces the held country and stamps the row" do
  result = AcceptDisagreements.call(label: "r1", apply: true)
  assert_equal 1, result.data[:accepted]
  assert_equal ["British"], @book.reload.countries.map(&:name)
  assert @row.reload.facts["accepted_at"].present?
end

test "accept skips a book whose countries changed since the run" do
  # book now holds Irish, row held ["American"]
  assert_equal 0, AcceptDisagreements.call(label: "r1", apply: true).data[:accepted]
end

test "a dry run changes nothing" do
  AcceptDisagreements.call(label: "r1")
  assert_equal ["American"], @book.reload.countries.map(&:name)
end
```

- [ ] **Step 2: Run to see them fail.** Then implement and run to see them pass.

- [ ] **Step 3: Commit.** Message: `Books origin: run report and disagreement acceptance`.

---

### Task 10: Full checks, then the origin rehearsal in development (controller)

This is not an implementer task. The controller runs it after the final whole-branch review. It makes AI calls in dev: about 300 books, most taking one standard-role call, at a cost of cents to a few dollars. It also uses Wikimedia at the backfill pace (about 40 minutes for 300 books).

- [ ] **Step 1:** Run `bin/rails test`, `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check` on the branch. All must be clean.
- [ ] **Step 2:** From the repo root, take a snapshot: `COMPOSE_PROJECT_NAME=the-greatest bin/snapshot-dev-db.sh --label pre-origin-rehearsal`.
- [ ] **Step 3:** Pick about 300 book ids with a runner script in the scratchpad:
  - 100 top-ranked books;
  - 100 ranked mid-list books (ranks 2,000 to 8,000);
  - 100 unranked books, of which at least 60 have no real country.
  - The sample includes some non-English-origin books, some nonfiction, some children's or YA, and the place-named and Unknown-author books.
- [ ] **Step 4:** Start Sidekiq for the `low` queue in the worktree (`bundle exec sidekiq -q low`, in the background). Then run `BOOK_IDS=<ids> bin/rails "books:categorize:backfill[origin_only,all,rehearsal-1]" APPLY=1`. Wait for the runs to finish (`WorkflowRun.where(workflow: "books.book_categorize").running.count` reaches 0).
- [ ] **Step 5:** Run `bin/rails "books:origin:report[rehearsal-1]"`. Build the owner's review as an artifact, one row per book:
  - title, author and rank;
  - origin before → after;
  - path, confidence and reason;
  - which evidence sections existed.
  - Group the rows: applied, held back (unsupported, low_confidence, no_match, placeholder_answer), disagreements, has_origin.
  - Include the measurements: the share of books by path, the share that found a Wikidata work, applied against held back, AI calls per book, and an estimated cost for the ~53k books with no usable origin.
- [ ] **Step 6:** Leave the dev data as the rehearsal left it, so the owner can inspect it. The snapshot is the way back.

---

## Rulings made in this plan (the spec left these open, or this plan narrows it)

These need the owner's eye.

1. **A book that already holds a real country gets the Wikidata shortcut check only** (Task 6, `has_origin`), unless an admin run forces it. The spec never overwrites a real country, so a full AI judgment there could only produce a disagreement report. That would mean about 106k AI calls in the backfill to buy one. Disagreements still surface whenever Wikidata, the author and the language all agree on a different country.
2. **Sync-added books are handled by re-running the paced backfill weekly** (launch-todo §4 step 10). The `data_migration:sync` service is not changed. The backfill skips done books, so the weekly run plans only the new books.
3. **A new `books.book_categorize` workflow** (evidence, then categorize) serves the backfill and the admin Enrich job. `books.book_enrichment` stays the import workflow. It never re-runs Goodreads or `book_facts` on old books, which the spec forbids (§4.5).
4. **Evidence schema 2** stores the P495 QIDs and the `Books::Country` names they map to. Without them the shortcut would have to match English labels ("France") against adjectives ("French"). `CountryLookup` also learns country names, which helps the infobox and place-named authors.
5. **No expression index on `duplicate_candidates.evidence`.** Dev holds 724 rows, so the stage 1 blocking query stays a cheap scan. Revisit if the table passes about 50k.
6. **Parked:** the evidence step waiting on new authors' `author_facts` (stage 1 item 6). The import's `categorize` waits on `book_facts`, which already waits on new authors, so origin sees their countries. Only the author-works Wikidata route misses for a brand-new author, and that belongs to stage 3, if anywhere.
7. **Wikidata misses on famous books** (Macbeth, The Name of the Rose, Demons) trace to their authors lacking QIDs. That belongs to the author pipeline, not this stage. Those books fall to the AI judge, which knows them.
