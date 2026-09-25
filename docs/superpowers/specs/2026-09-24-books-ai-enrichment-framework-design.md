# Books AI enrichment framework — design

Date: 2026-09-24 · Branch: `books-ai-enrichment-spec`

## Goal

Give the new app the one thing the legacy books admin got from ChatGPT that we have not replaced:
metadata for a book we know little about. Do it as a framework rather than a pile of jobs, so
that categories, authors, and later music and games plug into the same pieces, and so that every
value an AI wrote is traceable to the run that wrote it, with a confidence attached.

Success:

- A `Books::Book` created through the importer gets first published year, original language,
  word count, page range, subtitle, alternate titles, origin country, and a description filled in
  by one background job, and every one of those values shows up in a queryable ledger with a
  confidence and the model that produced it.
- A book the model does not recognize, or one published after the model's training data, is
  re-run with web search, under a daily budget, and the ledger says which mode produced each value.
- No task in the app names `gpt-5-mini` any more. Every task declares a role; roles map to model
  IDs in one config file. OpenAI retires `gpt-5-mini` on 2026-12-11.
- Descriptions are spoiler-free and pass the condensed style rules in §5, checked by a cheap
  review call and a deterministic check, and never contain a URL or a citation.

Non-goals are listed in §11.

## Problem

### What the legacy app does

`/home/shane/dev/the-greatest-books/admin` fires eight jobs from `Book#populate_external_data`
(`app/models/book.rb:371-386`) on every create, serialized behind one global Redis mutex keyed on
the literal string `"chatgpt_processing"`. Six are AI:

| Legacy job | Writes | Replacement in this design |
|---|---|---|
| `set_book_details_from_ai` | first published year (+estimated, +ancient), original language, page count, word count, book type, series, alternate titles, subtitle | the book facts task (§4). Type and series are recorded, not applied |
| `set_ai_generated_description` | `ai_generated_description` | the same call, written through `assign_description` |
| `set_book_countries` | `book_countries` join rows | the same call, `origin_countries` fact |
| `set_ai_genre_categories` | genre `BookCategory` rows from a closed list | categories spec, later |
| `set_ai_subject_categories` (enqueued twice) | open-vocabulary subject categories | categories spec |
| `set_ai_location_categories` | location categories | categories spec |
| Goodreads search + `GoodreadsTitleSummary` rewrite | `goodreads_description` | out of scope, its own spec |
| Bookshop.org search + `BookshopMatchConfirmation` | `primary_bookshop_org_url` | dropped; Bookshop blocks scraping. Affiliate links from ISBNs are a separate spec |

`Author#populate_from_chatgpt` fires one more (`AuthorInfo`: birth and death year, gender,
nationality, description). Authors are a separate spec; the new app has no author importer yet.

Everything runs on `gpt-5-mini` at temperature 1. The base class (`app/lib/openai/chat.rb:15-20`)
forces temperature 1 for any `gpt-5*` model, so every per-class temperature is dead. Four classes
that appear to choose a bigger model (`BookDuplicateCheck`, `GermanListParser`, `ListDetails`,
`ListSummaryGenerator`) pass `model: @model` before assigning it, so they get mini too.

"Unknown book" handling is inconsistent. Description, genre, location, subject, and nationality
prompts say "return null or an empty array if unknown" and the callers silently no-op. Nothing
records that the model did not know the book, so nothing can come back later and try harder.
`AuthorInfo` uses `Hash#fetch` with no default on an unschema'd response and raises `KeyError`
when a key is missing.

### What the new app has

- `Services::Ai::Tasks::BaseTask` + `Services::Ai::Providers::OpenaiStrategy`, calling the
  Responses API with structured outputs (`text: <OpenAI::BaseModel subclass>`), `service_tier:
  "flex"`, one `AiChat` row per call. Every concrete task hardcodes `def task_model = "gpt-5-mini"`.
  No task uses a tool. `docs/features/ai_agents.md` documents the stack.
- `DataImporters::Books::Book::Importer` with one provider, `Providers::OpenLibrary`, which fills
  `title`, `subtitle`, `description` (via `assign_description(source: :openlibrary)`), and
  `first_published_year` when blank. The finder already spends an AI call per import through
  `Services::Ai::Tasks::Matching::SelectCandidateTask`.
- Music's `Providers::AiDescription` → `Music::AlbumDescriptionJob` → `AlbumDescriptionTask` →
  `assign_description(source: :ai_generated)`: the shape this design generalizes.
- `Describable`, `Correctable`, `Identifier`, `AiChat`, `Category`: shared polymorphic models.
  The ledger in §3 follows the same pattern.
- No callback on `Books::Book` enqueues anything on create. This is deliberate and stays so:
  `data_migration:all` creates 157k books, and a callback would fire 157k AI jobs.

### Two facts that shape the design

**Models.** Verified against the account's `/v1/models` on 2026-09-24. Prices are from the
research pass and were not read raw from the pricing page; re-check before any cost model is
load-bearing.

| Model | In $/1M | Out $/1M | Notes |
|---|---|---|---|
| `gpt-6-luna` | 0.10 | 0.50 | small tier; cheaper than `gpt-5-mini` (0.25 / 2.00) |
| `gpt-6-sol` | 2.00 | 10.00 | mid tier |
| `gpt-6-astra` | 10.00 | 50.00 | flagship; the only GPT-6 model that supports the web search tool |
| `gpt-5-mini` | 0.25 | 2.00 | what every task uses today; shutdown 2026-12-11 |

Web search is `$10` per 1,000 calls on top of tokens. Only `gpt-6-astra`, `gpt-5.5`, and the
`gpt-4.1` pair accept the tool.

**The probe.** One request on 2026-09-24 against `gpt-6-astra` with `tools: [{type: "web_search",
search_context_size: "low"}]`, `tool_choice: {type: "web_search"}`, and a strict `json_schema`
`text.format` returned a validated object with two `url_citation` annotations. Web search and
structured outputs combine in one call. Usage was 12,987 input and 283 output tokens, about 15
cents including the search fee. The model also pasted markdown citations *inside* the description
string, which is why §5 forbids them in the prompt and §5 strips them in code.

## Prior art

- `DataImporters::Music::Album::Providers::AiDescription` and `Music::AlbumDescriptionJob`: the
  async-provider shape, copied here.
- `config/initializers/api.rb`: tunables in `config.x`, not an admin UI. The roles file follows it.
- `Books::Book::Merger#merge_ai_chats`: the one-line association migration the merger needs for
  `enrichments`.
- `Descriptions::SourcePriority::ORDER`: `manual` outranks `ai_generated`, which outranks
  `openlibrary`. The applier relies on this rather than deciding which description to show.
- The legacy `GoodreadsBookMatchConfirmation` schema (`confidence: high | medium | low |
  no_match`) is the one legacy pattern worth keeping: explicit confidence, every failure path
  rescued to a safe default.

## Design

### 1. Model roles

`config/initializers/ai.rb`:

```ruby
Rails.application.configure do
  config.x.ai.roles = {
    fast:     {provider: :openai, model: "gpt-6-luna"},
    standard: {provider: :openai, model: "gpt-6-sol"},
    premium:  {provider: :openai, model: "gpt-6-astra"},
    research: {provider: :openai, model: "gpt-6-astra", tools: [:web_search]}
  }
  config.x.ai.knowledge_cutoff_year = 2026     # research mode skips the knowledge call at or past this
  config.x.ai.research_daily_cap = 50          # research-mode runs per UTC day, all kinds combined
end
```

- `BaseTask` gains `task_role` (symbol, default `:fast`) and resolves provider and model from it.
  Precedence: explicit `model:` argument, then `task_model` (kept as an escape hatch, no longer
  used by any task), then the role. A role that names an unknown provider raises at boot through
  the same `create_provider_from_task` case statement.
- `Services::Ai::Roles.resolve(role)` returns a frozen struct `(provider:, model:, tools:)`. It is
  the only reader of `config.x.ai.roles`, so a test can stub one method.
- **Every existing task moves to a role in this spec.** `SelectCandidateTask`, every
  `Lists::*RawParserTask` and validator, `AmazonProductMatchTask` and subclasses,
  `IgdbSearchMatchTask`, `RecordingMatcherTask` → `:fast`. `AlbumDescriptionTask` and
  `ArtistDescriptionTask` → `:standard`. The 14 `task_model` overrides are deleted. The import
  finder audit UI (`docs/features/import-finder.md`) shows the match task's decisions and is
  where the `fast` model's quality gets eyeballed; if it disappoints, the fix is the config line.
- `AiChat.model` keeps recording the resolved model ID, so the admin AI Chats page shows what
  actually ran.

### 2. Tools on the OpenAI strategy

- `BaseTask#tools` returns the role's tools plus anything the task adds; default `[]`.
- `OpenaiStrategy#build_parameters` maps `:web_search` to
  `{type: "web_search", search_context_size: "low"}` and, when the task sets `force_tool?`
  (research mode does), `tool_choice: {type: "web_search"}`. Unknown tool symbols raise.
- `OpenaiStrategy#format_response` adds `citations:` (the distinct `url_citation` URLs from the
  message's annotations, with the `utm_source=openai` parameter stripped) and
  `web_search_calls:` (count) to the hash it already returns. Tasks that never request a tool see
  `citations: []`.
- `send_message!` keeps its signature; the tools ride on `ai_chat.parameters`, which is already
  persisted before the call. Nothing about `AiChat` changes.

### 3. The `enrichments` ledger

One table, shared across domains like `ai_chats`. Generated with `bin/rails generate model
Enrichment`.

| Column | Type | Notes |
|---|---|---|
| `enrichable_type`, `enrichable_id` | polymorphic | indexed together |
| `kind` | string, not null | `books.book_facts`. Namespaced so `books.categories`, `books.author_facts`, `music.*` add their own. Indexed |
| `mode` | integer enum | `knowledge: 0`, `research: 1` |
| `outcome` | integer enum, not null | `applied: 0`, `nothing_to_apply: 1`, `unrecognized: 2`, `skipped: 3`, `failed: 4`. Indexed |
| `recognized` | boolean, nullable | null on skipped and failed rows |
| `confidence` | integer enum, nullable | `high: 0`, `medium: 1`, `low: 2`; the run's overall confidence |
| `facts` | jsonb, default `{}` | see below |
| `citations` | jsonb, default `[]` | array of URL strings |
| `provider`, `model` | string | resolved values, copied from the task |
| `ai_chat_id` | bigint FK, nullable | null on skipped rows; `on_delete: :nullify` |
| `error` | text, nullable | failed rows |
| `reason` | string, nullable | skipped rows: `budget_exhausted`, `missing_inputs` |
| timestamps | | |

`facts` is a hash keyed by fact name:

```json
{
  "first_published_year": {"value": 1925, "confidence": "high", "applied": true,  "reason": "filled"},
  "word_count":           {"value": 47094, "confidence": "low",  "applied": false, "reason": "already_set"},
  "book_type":            {"value": "fiction", "confidence": "high", "applied": false, "reason": "not_applied_yet"},
  "original_language":    {"value": "Englisch", "confidence": "high", "applied": false, "reason": "no_match"},
  "description":          {"value": "…", "confidence": "high", "applied": true, "reason": "filled",
                           "review": {"spoilers": false, "style_violations": ["em_dash"], "rewritten": true}}
}
```

Reasons: `filled`, `already_set`, `null` (the model returned null), `not_applied_yet` (recorded
for a later spec), `no_match` (a lookup such as language or country found nothing), `rejected`
(failed the deterministic description check), `review_failed` (the review call errored, so the
description was not written), `human_cleared` (an applied correction blanked this field, so it is
never refilled).

Model: `Enrichment` with `belongs_to :enrichable, polymorphic: true`, `belongs_to :ai_chat,
optional: true`, the three enums, validation of `kind` format (`/\A[a-z_]+\.[a-z_]+\z/`), and
scopes `for_kind`, `research`, `today` (`created_at >= Time.current.beginning_of_day`), and
`low_confidence_on(fact)` (`facts -> fact ->> 'confidence' = 'low'`). Every run writes exactly one
row, including skips and failures, so the table is both audit trail and backlog.

`Books::Book` gets `has_many :enrichments, as: :enrichable, dependent: :destroy` and
`Books::Book::Merger` gets `merge_enrichments` next to `merge_ai_chats`
(`update_all(enrichable_id: target.id)`). `test/lib/books/book/merger_test.rb` gets the case.
Music and games models add the association when they get a consumer, not before.

### 4. The book facts task

`Services::Ai::Tasks::EnrichmentTask < BaseTask` adds:

- `mode:` keyword (`:knowledge` or `:research`), stored on the instance. `task_role` returns
  `:standard` in knowledge mode and `:research` in research mode; `force_tool?` is true in
  research mode.
- The schema convention: a `Fact` base with `value` and `confidence` (enum `high | medium |
  low`), a top-level `recognized` boolean and `confidence`, and per-task fact classes.
- `process_and_persist` returns `Services::Ai::Result` with `data: parsed, citations:` and
  **does not write to the parent**. The runner hands the result to an applier. The task knows the
  prompt and the schema; the applier knows the write policy.

`Services::Ai::Tasks::Books::BookFactsTask < EnrichmentTask`, `chat_type :analysis`, parent a
`Books::Book`.

Inputs to the prompt: title, subtitle, author names, existing `first_published_year` if any, the
existing primary description if any (as context, marked as such), and identifiers when present
(ISBN-13, Open Library work key) because they disambiguate. Author names come from
`book.authors` when the book has any, otherwise from the import query: the importer creates a
new book with no `book_authors` rows (the Open Library provider deliberately does not create
authors), so the provider passes `query.author_names` through the job to the task. A book with
neither is `missing_inputs`.

Schema fields (each a `Fact` unless noted):

| Fact | Type | Applied by `ApplyBookFacts` |
|---|---|---|
| `recognized` | boolean, top level | governs the fallback (§6) |
| `confidence` | enum, top level | governs the fallback |
| `first_published_year` | integer, nullable | fill if blank |
| `first_published_year_estimated` | boolean | recorded, `not_applied_yet`; `books_books` has no column for it |
| `original_language` | string, nullable, ISO 639-1 code preferred, name accepted | fill `original_language_id` if blank, via `Language.find_by(iso_639_1:)` then `find_by(name:)` (case-insensitive); no match → `no_match` |
| `word_count` | integer, nullable | fill if blank and positive |
| `page_range` | string, nullable, `"300"` or `"250-350"` | fill if blank; must match `/\A\d+(-\d+)?\z/` |
| `subtitle` | string, nullable | fill if blank |
| `alternate_titles` | array of strings | union, case-insensitive, excluding the title itself |
| `origin_countries` | array of strings | add `Books::BookCountry` rows only when the book has none; each name via `Books::Country.find_by("lower(name) = ?", …)`; unmatched names → `no_match` |
| `book_type` | enum `fiction | nonfiction | poetry | religious`, nullable | recorded, `not_applied_yet` |
| `series_name`, `series_number` | string / integer, nullable | recorded, `not_applied_yet` |
| `description` | string, nullable | §5 |

Every fill goes through the model's writer so `before_validation :derive_book_length` and the
correctable hooks keep working. Nothing overwrites a non-blank value, which protects most human
corrections. It does not protect a correction that *cleared* a field: the column target accepts
blanks on purpose ("blanking a subtitle or a page range is a real correction"), and the dev
database holds a dozen such corrections, mostly subtitles that earlier AI output got wrong. So the
applier also checks the book's applied `correction_fields`: a field whose accepted `new_value`
was blank is recorded with `reason: "human_cleared"` and never refilled, since the AI would make
the same mistake again.

`Services::Books::ApplyBookFacts.call(book:, facts:, citations:)` returns the ledger `facts` hash
and the list of applied names. It is the only class that writes `Books::Book` columns from AI
output, so the write policy is reviewable in one file. It saves the book once, at the end.

### 5. Descriptions

**Prompt rules** (system message of `BookFactsTask`, verbatim in the code):

- Spoiler-free. Describe the premise, the setting, and the situation the book opens on. Never
  reveal twists, deaths, endings, or how the central question resolves. For nonfiction, describe
  the subject and the argument, not the conclusions.
- One paragraph, 60 to 110 words, sentences of varied length. Do not name the title or the author;
  the page shows both.
- No em dashes or double hyphens, no semicolons, no lists, no emoji, no quotation marks around
  titles.
- No marketing or judgment: no acclaimed, bestselling, masterpiece, unforgettable, must-read, no
  awards, no sales figures.
- No meta narration such as "This novel" or "Readers will". Open on the subject.
- Plain words. Do not use: delve, tapestry, testament, poignant, seminal, groundbreaking,
  timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, or
  "explores themes of".
- No "not X but Y" constructions. No ornamental triads of adjectives.
- Only what you are sure of. Say less rather than guess. If you do not know the book well enough
  to describe its premise, return null.
- No citations, URLs, footnotes, or bracketed references inside any text field.

This is the condensed form of `.claude/skills/avoid-ai-writing/SKILL.md`. The full guide is
aimed at essays; for a blurb these rules are the ones that fire.

**Review pass.** `Services::Ai::Tasks::Books::DescriptionReviewTask < BaseTask`, role `:fast`,
parent the book, `chat_type :analysis`. Input: the description, the title and authors (so it can
detect them), and the rules above. Schema: `spoilers: boolean`, `spoiler_notes: string?`,
`style_violations: [string]` (from a fixed enum: `em_dash`, `semicolon`, `names_title`,
`names_author`, `marketing`, `meta_narration`, `banned_word`, `not_but`, `triad`, `too_long`,
`too_short`, `citation`), `rewritten: string?` (null when nothing needed changing). The runner
calls it after every facts call that returned a description, in both modes. Cost is under a tenth
of a cent per book.

**Deterministic check**, `Services::Books::DescriptionCheck.call(text, book:)`: fails on `—`,
`--`, `http`, `[`…`](`, `utm_source`, or the book's title as a case-insensitive substring;
fails on fewer than 40 or more than 140 words, deliberately looser than the prompt's 60 to 110 so
the check catches runaways rather than policing the target. Runs on the reviewed text. Markdown citations of
the form `([label](url))` are stripped before the check because the probe showed the model adds
them despite instructions; the strip is idempotent and the URLs are already in `citations`.

**Write.** `assign_description(source: :ai_generated, content:, source_url: citations.first)`
only when the book has no `ai_generated` description yet; the resolver keeps `manual` above it.
The reviewer's verdict is binding: a description flagged `spoilers: true` with no `rewritten`
text is recorded `rejected` and not written, and a review reply with no `spoilers` verdict at all
(an empty response) is `review_failed`. The rewrite is the only way past a spoiler flag.
A description that fails the deterministic check is recorded with `reason: "rejected"` and not
written. The ledger's `description` fact carries the review verdict, so "descriptions the
reviewer rewrote for spoilers" is one query.

### 6. Runner, job, and entry points

`Services::Books::EnrichBook.call(book:, force_research: false)`:

1. Inputs check: title present and at least one author name (from `book.authors`, or the
   `author_names` the caller passed). Otherwise write a `skipped` row with
   `reason: "missing_inputs"` and return.
2. Decide the first mode. Research if `force_research`, or if `book.first_published_year` is at or
   past `knowledge_cutoff_year`. Otherwise knowledge. The daily cap applies to every research run,
   direct or fallback: a past-cutoff book with the cap exhausted gets a `skipped` row
   (`reason: "budget_exhausted"`) and no call. Only `force_research` bypasses the cap.
3. Run `BookFactsTask` in that mode. On a task failure write a `failed` row and return a failure
   Result.
4. If a description came back, run `DescriptionReviewTask` and the deterministic check.
5. If `recognized` is false, apply nothing: every fact is recorded with `reason: "unrecognized"`
   and the row's `outcome` is `unrecognized`. A model that does not know the book is guessing at
   whatever it did return. Otherwise `ApplyBookFacts`, and the `outcome` is `applied` when at
   least one fact was filled, else `nothing_to_apply`.
6. Fallback decision, only after a knowledge run: research if `recognized` is false, or
   `recognized` is true and overall `confidence` is `low`. If the daily cap is reached
   (`Enrichment.research.today.count >= research_daily_cap`) and not `force_research`, write a
   `skipped` row with `reason: "budget_exhausted"` and stop. Otherwise repeat steps 3 to 5 in
   research mode. A research run's `applied` fills whatever the knowledge run left blank.
7. Return a Result whose `data` is the ledger rows written.

The count-based budget has a small race at the boundary under concurrent jobs. Overshooting the
cap by a handful of 15-cent calls is acceptable; a lock is not worth it.

`Books::EnrichBookJob` (`bin/rails generate sidekiq:job books/enrich_book`): `queue: :default`,
`retry: 3`, `perform(book_id, force_research = false, author_names = [])`. It looks the book up with `find_by(id:)`
and returns quietly when there is none, because a book deleted between enqueue and run is not an
error worth three retries. It calls the runner and re-raises on a failed Result so Sidekiq retries
transient API errors. Fill-blanks makes a retry, a re-run, and two concurrent runs on one book
all safe, so it does not need the `serial` queue.

Entry points:

- `DataImporters::Books::Book::Providers::AiEnrichment`, appended to the importer's `providers`
  after `OpenLibrary` so the Open Library fills happen first and the AI fills fewer blanks.
  Mirrors music's `AiDescription`: validate title, `persisted?`, and that either the book has
  authors or the query carries `author_names`, then `perform_async(book.id, false, author_names)`,
  return `success_result(data_populated: [:ai_enrichment_queued])`.
- `Actions::Admin::Books::EnrichBook` (visible on show, not destructive) with a checkbox field
  "Search the web even if the model knows this book" that maps to `force_research`. Enqueues the
  job and reports "queued". Registered in `Admin::Books::BooksController`'s action list.
- `lib/tasks/books/enrich.rake`: `books:enrich[id]` (id is digits-only routed to `find_by!(id:)`,
  never `find`, because 137 books have numeric slugs) and `books:enrich_missing[limit]`, which
  enqueues books with no `enrichments` row and no description, ordered by id, up to `limit`. No
  default limit; running it wide is a decision, not a default.

### 7. Cost, stated so the config has a reason

Knowledge run on `gpt-6-sol`: roughly 1,500 input and 400 output tokens, under one cent.
Review on `gpt-6-luna`: under a tenth of a cent. Research run on `gpt-6-astra`: the probe
measured about 15 cents. At the default cap of 50 research runs a day, the ceiling is about
$7.50 a day for research plus whatever the knowledge runs cost. Enriching every book in the
catalog through the knowledge path alone would be on the order of $1,000 on `sol` or $60 on
`luna`; that decision is out of scope here, and the role mapping is the knob if it is ever made.

### 8. Testing

Unit (Minitest + Mocha, provider stubbed, no network):

- `Services::Ai::Roles`: resolution, unknown role raises, unknown provider raises.
- `OpenaiStrategy`: tools and `tool_choice` land in parameters; `citations` extracted and
  de-duplicated with `utm_source` stripped; no tools → `citations: []`.
- `BaseTask`: precedence of `model:`, `task_model`, role.
- `BookFactsTask`: schema `to_json_schema` is a class method call; mode switches role and
  `force_tool?`; prompt includes identifiers when present; `process_and_persist` writes nothing.
- `ApplyBookFacts`: one test per fact for fill and for already-set; array union; title excluded
  from alternate titles; language by ISO code, by name, and `no_match`; countries only when none
  exist; `word_count` zero not applied; `page_range` format; type and series recorded not applied.
- `DescriptionCheck`: each failure condition; citation strip idempotent.
- `DescriptionReviewTask`: returns the rewritten text; null when clean.
- `EnrichBook`: a decision table test over (`recognized`, `confidence`, year vs cutoff,
  `force_research`, budget remaining) → sequence of modes run and outcomes written. Missing
  inputs → `skipped`. Task failure → `failed` and no apply.
- `Enrichment` model: enums, kind format, scopes; fixtures with at least one row per outcome and
  per mode, so the negative class exists (`test/fixtures/enrichments.yml`).
- `Books::Book::Merger`: enrichments move to the target.
- `Books::EnrichBookJob`: success path, re-raise on failure, `Sidekiq::Testing.fake!` for the
  provider test.
- Every existing task test that asserted `"gpt-5-mini"` asserts the role instead.

Integration: importer chain enqueues the job after Open Library ran (fake mode, assert enqueued);
admin action enqueues with and without `force_research`; the job returns without error on an
unknown book id and writes no ledger row.

E2E (Playwright, `web-app/e2e/tests/books/admin/`): the admin book show page has the enrich action,
submitting it shows the queued confirmation. The enrichment itself is not exercised end to end
because it would call OpenAI.

Docs: `docs/features/ai_agents.md` gains roles, tools, and the enrichment contract;
`docs/features/data_importers.md` gains the books provider and loses the line saying music
descriptions "use Claude" (they use OpenAI). `docs/features/books_enrichment.md` is new and is the
feature doc; this spec is the rationale.

### 9. Error handling summary

| Failure | Behavior |
|---|---|
| OpenAI error or timeout | task returns failure; `failed` ledger row with the message; job re-raises, Sidekiq retries up to 3 |
| Schema violation in the response | the SDK raises; same path |
| `recognized: false` | `unrecognized` row; research fallback if budget allows, else `skipped` |
| Review task fails | description recorded with `reason: "review_failed"`, not written; other facts still applied |
| Description fails deterministic check | `reason: "rejected"`, not written |
| Language or country not found | `reason: "no_match"`; the name is kept in the ledger for a later mapping pass |
| Book deleted before the job runs | job returns without error, no ledger row, no retry |
| Book missing title or authors | `skipped`, `reason: "missing_inputs"` |

### 10. Increments

One implementation plan, in this order, each step green before the next:

1. Roles config, `Services::Ai::Roles`, `BaseTask#task_role`; migrate every existing task off
   `task_model`; update tests and `ai_agents.md`. Ships on its own and retires `gpt-5-mini`.
2. Tools and citations in `OpenaiStrategy`.
3. `Enrichment` model, migration, fixtures, association on `Books::Book`, merger case.
4. `EnrichmentTask`, `BookFactsTask`, `ApplyBookFacts`.
5. `DescriptionReviewTask`, `DescriptionCheck`.
6. `EnrichBook` runner, `EnrichBookJob`.
7. Provider, admin action, rake tasks, E2E test, feature doc.

Steps 1 and 2 are cross-domain and should be reviewed with the music and games tasks in mind.

## Non-goals

- Categories (genre, subject, location, and applying the recorded `book_type`): next spec.
- Authors: needs a `Books::Author` importer first; its own spec.
- Goodreads scraping and the rewritten Goodreads blurb: parked, own spec.
- Bookshop.org: dropped. Affiliate links built from ISBNs: own spec.
- Comparing other providers' grounded search (Anthropic, Google, Perplexity) on price and
  quality: a research spike. The role config already carries a provider so the outcome plugs in.
- Retiring the legacy list summary, list metadata, category description, category fixer, and
  sub-category features: decided in brainstorming, nothing to build.
- A catalog-wide backfill. `books:enrich_missing[limit]` exists; running it wide is a decision.
- Applying `series_name` / `series_number`. Recorded in the ledger; a later decision.
- An admin page for the ledger. The `Enrichment` rows are visible through the console and the
  linked `AiChat`; a UI comes when there is a workflow that needs one.

## Decisions made during brainstorming

- **Trigger: importer provider + admin action + rake, no model callback.** A callback would fire
  during `data_migration:all`.
- **Ledger is one row per run, shared across domains, not one row per field value.** Shane asked
  that it not be books-specific. Per-field rows were rejected as more machinery than the question
  "why is this value here" needs.
- **Facts and description in one call**, because both depend on whether the model knows the book,
  and `recognized` governs both.
- **Type and series recorded, not applied.** Categories own type; series data has never been
  used.
- **Fallback triggers**: `recognized: false`, or overall `low`, or year at/past the cutoff (skips
  the knowledge call). Daily cap in config; admin force ignores the cap.
- **Web search uses `gpt-6-astra`** because it is the only GPT-6 model that supports the tool;
  cheaper providers are a separate spike.
- **Descriptions get the condensed avoid-ai-writing rules plus a spoiler rule in the prompt, a
  cheap review call, and a deterministic check**, because Shane has seen AI descriptions give
  away too much, and em dashes on a public page read as AI.
- **Existing tasks move to `fast` (`gpt-6-luna`) except the two music description tasks
  (`standard`).** Quality is checked on the import finder audit UI; the fix is a config line.
- **Probe result**: web search + strict JSON schema combine in one Responses API call; the model
  pastes citations into strings anyway.
