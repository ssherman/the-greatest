# Books Author Importer — Increment 2 (Wikidata and Wikipedia) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve every newly imported author to a Wikidata person (or explicitly to none), fill its identifiers, years, gender, alternate names and countries from that item, link its English Wikipedia article only through the confirmed item, store author nationalities (including the legacy strings), and deprecate legacy Wikipedia descriptions that do not belong to the confirmed item.

**Architecture:** A paced `Wikimedia::Http` sits under two thin clients (`Wikidata::Client`, `Wikipedia::Client`). `Services::Books::Authors::ResolveWikidata` gathers candidates, keeps persons, decides by rule or asks `SelectExternalRecordTask`, and records a `MatchDecision`. `EnrichFromWikidata` then runs `ApplyWikidata`, `LinkWikipedia` and `CleanLegacyWikipedia` and writes one `books.author_wikidata` ledger row. `Books::Authors::WikidataJob` runs that on the `low` queue. The author importer's new async `Providers::Enrichment` enqueues it. Nationality lives in a new `books_author_countries` join, filled through a shared `Services::Books::CountryLookup` that never creates a country.

**Tech Stack:** Rails 8, PostgreSQL (jsonb, bytea), Faraday, Redis (`DistributedRateLimiter`), Sidekiq, the `countries` gem, OpenAI via `Services::Ai::Tasks`, Minitest + Mocha + WebMock.

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md` — this plan implements §3, §4, §5, §6, §7, the legacy-cleanup half of §13, and §16 item 2 (with `Providers::Enrichment`, moved here from increment 1). Increment 1's plan is `docs/superpowers/plans/2026-09-27-books-author-importer-increment-1-core.md`.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in the repository root's `docs/`.
- Tests: `bin/rails test`. Lint: `bundle exec standardrb` (never `bin/rubocop`). Never run brakeman.
- Use generators: `bin/rails generate model|migration`, and `bin/rails generate sidekiq:job <path>` for jobs (never `generate job`).
- Services live under `app/lib/services/`, never `app/services/`. Inside `Services::Books::…`, write model constants root-anchored: `::Books::Author`, `::Books::Country`, `::Wikidata::…`, `::Wikipedia::…`, `::Wikimedia::…`.
- Service results use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Identifiers: `find_or_initialize_by`, never `build`.
- Enum syntax: `enum :source, {…}`.
- Minitest 6: `assert_nil` for nil, never `assert_equal nil, x`.
- A clean `bin/rails test` prints no new warning lines.
- **Fills blanks only.** Nothing overwrites a populated field. `name` and `kind` are never written. A disagreement is recorded, never applied.
- **Never text-search Wikipedia.** An article is reached only as the English sitelink of a matched Wikidata item. `Wikipedia::Client` has no search method.
- **Never send an email address to Wikimedia.** The User-Agent contact comes from `WIKIMEDIA_CONTACT`, default `https://thegreatestbooks.org`. Tests, fixtures and scripts use a site URL.
- User-Agent format: `TheGreatest/1.0 (<contact>)`. Action API calls carry `maxlag=5`. One request per second across all Wikimedia hosts, Redis key `wikimedia:api`.
- WebMock stubs the real hosts (`www.wikidata.org`, `query.wikidata.org`, `en.wikipedia.org`), which are non-loopback. `WebMock.disable_net_connect!(allow_localhost: true)` is already on.
- New `app/lib` directories (`wikimedia/`, `wikidata/`, `wikipedia/`, `services/external_records/`) need `CI=1 bin/rails zeitwerk:check`, because eager loading is off in test.
- **All worktrees share one development database.** Run `bin/rails db:migrate` (additive only), then diff `db/schema.rb` and strip anything your own migration did not create. Revert annotate_rb comment changes on models your migration did not touch. Then run `RAILS_ENV=test bin/rails db:test:prepare`. Never run a destructive command against development.
- Jobs run on the `low` queue with `retry: 3`.
- No new page or flow: the only visible change is a new "Wikidata link" entity on the existing audit pages, covered by a controller test. The first Playwright spec for this feature is the Reject link's, in increment 5.
- Ledger kind `books.author_wikidata`, provider `wikidata`, `mode` left at its default, `model` blank.
- Commit after each task on the worktree branch. Never commit to `main`. Never push.
- Commit message trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Rulings made while planning

Planning measured or probed each of these on 2026-09-27. They refine the spec; none changes its intent.

1. **Pacing waits inline, briefly.** The spec's `:immediate` limiter at one request a second would reschedule every job on its second request, since an author costs about eight. `Wikimedia::Http` waits inline for a slot up to `max_inline_wait` (5 s). A longer wait becomes `RateLimited` and the job reschedules.
2. **Measured limits.** The 2026 caps apply to every per-wiki `api.php`: 200 requests a minute with a policy User-Agent, 10 without. The Query Service keeps its own limits: 60 s of query time a minute and 5 parallel queries. On success no host sends rate-limit headers, so the only signals are a 429 with `Retry-After` and the `maxlag` error. One request a second is under a third of the cap.
3. **`works` returns every English title** instead of 50 per item. Stephen King alone returns 326 titles even with scholarly articles (Q13442814) and editions (Q3331189) filtered out. Capping before comparing would miss matches. The query takes about 0.35 s for five famous people. The evidence keeps at most 10 matching and 5 other titles.
4. **A `labels(ids)` client operation** (English labels, cached 30 days) supplies the occupation (P106) labels the spec lists as evidence.
5. **The historical-state map has 40 items, not 7.** In a sample of 2,000 of our Open Library keys, 788 reached a person. Of their 883 citizenship values, 117 (13%) had no ISO code. The largest group was "United Kingdom of Great Britain and Ireland" (32). The rest were mostly kingdoms, the German states and Chinese dynasties. Some are deliberately unmapped because the nationality they imply is ambiguous: Czechoslovakia, Cisleithania, Austrian Empire, Dutch East Indies. East Germany and the Yugoslav federations carry `P297` codes (DD, YU) the `countries` gem lacks, so the map is checked before the ISO path.
6. **The alias map adds the `countries` gem's mismatches.** 70 of the gem's 249 nationalities match no `Books::Country` name. About 20 of those differ from a row we have only in spelling: Argentinean, Motswana, Icelander, Kirghiz, Slovene… The map also adds "United States" and "United Kingdom", the two largest unmapped legacy strings. Placeholder rows ("Unknown", "Multiple", "Mixed") are never matched.
7. **Legacy nationality.** 33,678 authors, 655 strings. Splitting on `-` and `/` and matching exactly leaves 375 authors (1.1%) unmapped. The migrator adds no further parsing (parenthesised notes, "born X").
8. **`WikidataJob(author_id, refresh = false)`.** `via_viaf` arrives with VIAF in increment 3. In this increment the chain ends at `WikidataJob`, because `ViafJob` and `EnrichJob` do not exist yet.
9. **`enrichments.match_decision_id`** (nullable, `on_delete: :nullify`) links a run's ledger row to its decision. §12's Reject link needs it, and rows written before increment 5 would otherwise be unlinkable.
10. **The runner is its own class,** `EnrichFromWikidata`. Wikipedia work is split into `LinkWikipedia` (§5.4) and `CleanLegacyWikipedia` (§13) rather than folded into `ApplyWikidata`. The cleanup must also run for an unmatched author, whom `ApplyWikidata` never sees.
11. **"Processed"** means a ledger row newer than the author row with outcome `applied`, `nothing_to_apply` or `unrecognized`. A `failed` or `skipped` row does not count, or one transient outage would skip an author forever.
12. **Early exit.** A corroborated held id or a single corroborated bridge hit decides without searching. Re-runs and VIAF-supplied ids then cost no name search.
13. **A held Wikidata id that differs from the matched item** applies nothing and flags the decision for review. The exception is an id Wikidata has merged into the matched item (a redirect). That is the same person, and the current id is stamped beside the old one.
14. **An identifier another author already holds** is not stamped. The pair is flagged as a duplicate (`external_key_collision`), as increment 1's Open Library provider does.
15. **`unspecified` gender counts as blank.** 334 authors hold it. It is the legacy AI's "don't know".
16. **Placeholder authors** (`exclude_from_rankings`, the seven "Unknown" rows) are skipped.
17. **Excluding rejected records** from candidates (§5.1 step 4) lands with the `verdict` column in increment 5.
18. **Wikipedia lead request** is `prop=extracts|pageprops|info&inprop=url`, which adds the canonical URL. A lead is read through by `payload->>'title'`, since its `source_id` (the page id) is unknown before the fetch.
19. **ISNI.** Wikidata now stores ISNI without spaces (`0000000122424494`). `haswbstatement:P648=…|P214=…|P213=…` works unquoted (verified live). Spaces are still stripped defensively.
20. **`SelectExternalRecordTask < SelectCandidateTask`**: same schema, fast role and validation; different wording.

## Review Focus

These are the failure modes most likely to bite that no single task's main path exercises. Each is pinned by a test in the named task.

1. **A failed or skipped run must not count as processed**, and neither must a processed row older than the author row (a re-migrated author). Otherwise one outage or one re-migration silently skips authors forever. Task 14.
2. **A rate limit mid-run, after facts were saved.** The rescheduled run must finish without duplicating identifiers, links or countries. Task 14.
3. **An author already holding a different Wikidata id** than the matched item: nothing is applied and the decision is flagged for review. Tasks 12 and 14.
4. **Diacritics and other scripts.** "Gabriel Garcia Marquez" corroborates "Gabriel García Márquez", while alternate names keep each spelling as its own search variant. Tasks 10 and 12.
5. **A held Wikidata id that has since been merged** (a redirect) still resolves to the surviving item, and applying it is not a "held id conflict". Tasks 4, 10, 12 and 14.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/initializers/wikimedia.rb` | Pace, inline wait, maxlag, contact (`config.x.wikimedia`) |
| `app/lib/wikimedia/exceptions.rb` | `Error` tree plus `RateLimited` (deliberately outside `Error`) |
| `app/lib/wikimedia/http.rb` | The one HTTP path: User-Agent, pacing, 429 and maxlag, JSON |
| `app/lib/wikidata/distiller.rb` | Entity JSON → distilled payload (best-rank statements) |
| `app/lib/wikidata/entity.rb` | Read-only view of a payload: names, years with reasons, person check |
| `app/lib/wikidata/client.rb` | `entities`, `search`, `by_statements`, `works`, `country_codes`, `labels` |
| `app/lib/wikipedia/lead.rb` | An article lead: page id, title, URL, extract, item, disambiguation |
| `app/lib/wikipedia/client.rb` | `lead(language:, title:)`. No search |
| `app/lib/services/external_records/store.rb` | Read-through `find` / `find_all` / `write` with the race handled |
| `app/models/external_record.rb` | Sources `wikidata`, `wikipedia`; `raw_text` gzip reader and writer |
| `app/models/books/author_country.rb` | The author ↔ country join |
| `app/lib/services/books/country_lookup.rb` | `from_text`, `from_iso`, `from_wikidata`; never creates a country |
| `app/lib/services/books_migration/author_country_migrator.rb` | Legacy `nationality_text` → join rows, with an unmapped report |
| `app/lib/services/ai/tasks/matching/select_external_record_task.rb` | "Which external record is this, or none" |
| `app/lib/services/books/authors/resolve_wikidata.rb` | Candidates, rules, AI, `MatchDecision`, store the chosen item |
| `app/lib/services/books/authors/apply_wikidata.rb` | Fill identifiers, years, gender, alternate names, countries |
| `app/lib/services/books/authors/wikipedia_lead.rb` | Read-through fetch and store of a Wikipedia lead |
| `app/lib/services/books/authors/link_wikipedia.rb` | §5.4: verify the sitelink page, link it |
| `app/lib/services/books/authors/clean_legacy_wikipedia.rb` | §13: keep or deprecate legacy Wikipedia descriptions |
| `app/lib/services/books/authors/enrich_from_wikidata.rb` | One run, one ledger row |
| `app/sidekiq/books/authors/wikidata_job.rb` | Runs the runner on `low`; reschedules on `RateLimited` |
| `app/lib/data_importers/books/author/providers/enrichment.rb` | Async provider: enqueue `WikidataJob` |
| `app/lib/data_importers/finder_registry.rb` | New `kind`; the "Wikidata link" external-link entry |
| `test/support/wikidata_entity_builder.rb` | Builds entity hashes for tests |
| `test/support/fake_wikidata_client.rb` | Fake `Wikidata::Client` and `Wikipedia::Client` recording calls |

---

### Task 1: Wikimedia HTTP foundation (pace, etiquette, errors), verified live

**Files:**
- Create: `config/initializers/wikimedia.rb`
- Create: `app/lib/wikimedia/exceptions.rb`
- Create: `app/lib/wikimedia/http.rb`
- Test: `test/lib/wikimedia/http_test.rb`
- Modify: `.env.example` (repository root), `deployment/ENV.md` (repository root)

**Interfaces:**
- Consumes: `::DistributedRateLimiter.new(key:, limit:, window:, mode: :immediate)`. Its `#acquire!` raises `DistributedRateLimiter::RateLimitExceeded` with `#retry_after` (Float seconds).
- Produces:
  - `Wikimedia::Http.new(settings: Rails.application.config.x.wikimedia, limiter: nil, sleeper: nil)`
  - `#action_api(url, params) → Wikimedia::Http::Response(data: Hash, body: String)`
  - `#sparql(url, query) → Response`
  - `#user_agent → String`
  - `Wikimedia::Exceptions::{Error, NetworkError, TimeoutError, HttpError(status_code, response_body), ParseError, ApiError(code)}`
  - `Wikimedia::Exceptions::RateLimited(retry_after:)`, a `StandardError` and **not** an `Error`

- [ ] **Step 1: Verify the limits live before building on them**

Run each request once, from `web-app/`, one second apart:

```bash
UA="TheGreatest/1.0 (+https://thegreatestbooks.org) plan verification"
curl -s -o /dev/null -w "%{http_code}\n" -A "$UA" "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=Q7243&props=info&format=json&maxlag=5"; sleep 1
curl -s -o /dev/null -w "%{http_code}\n" -A "$UA" "https://en.wikipedia.org/w/api.php?action=query&prop=pageprops&titles=Leo_Tolstoy&redirects=1&format=json&maxlag=5"; sleep 1
curl -s -o /dev/null -w "%{http_code}\n" -A "$UA" "https://query.wikidata.org/sparql?query=ASK%7B%7D&format=json"
```

Expected: `200` three times. Then read https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits (WebFetch). Confirm that the cap for a client with a policy-compliant User-Agent is still at least 60 requests a minute. Planning measured 200 on 2026-09-27.

If any request returns 403 or 429, or the documented cap is below 60 a minute, stop and report NEEDS_CONTEXT with the output. Do not build on a pace that is not safe. Record the three codes and the cap in your report.

- [ ] **Step 2: Add the configuration**

`config/initializers/wikimedia.rb`:

```ruby
# Pacing and etiquette for every call to a Wikimedia host: the Wikidata
# Action API, the Wikidata Query Service and Wikipedia. Spec:
# docs/superpowers/specs/2026-09-27-books-author-importer-design.md §4.
#
# Measured 2026-09-27: the 2026 limits apply to every per-wiki api.php, at
# 200 requests a minute for a client whose User-Agent follows the policy;
# the Query Service keeps its own budget (60 s of query time a minute, 5
# parallel queries). No host sends rate-limit headers on success, so the
# only signals are a 429 with Retry-After and the Action API's maxlag error.
# One request a second across all three hosts is under a third of the cap.
Rails.application.config.x.wikimedia = ActiveSupport::OrderedOptions.new.merge(
  requests_per_window: 1,
  window_seconds: 1.0,
  max_inline_wait: 5.0,
  maxlag: 5,
  contact: ENV.fetch("WIKIMEDIA_CONTACT", "https://thegreatestbooks.org")
)
```

Add to the root `.env.example`, after the page fetcher block:

```bash
# Contact in the User-Agent sent to Wikidata and Wikipedia (their policy asks
# for one). A URL is enough; defaults to https://thegreatestbooks.org.
# WIKIMEDIA_CONTACT=https://thegreatestbooks.org
```

Add to `deployment/ENV.md` under `### Application Features`, after the Firebase entries:

```markdown
#### WIKIMEDIA_CONTACT
- **Description**: Contact in the User-Agent the app sends to Wikidata and Wikipedia (author enrichment). The Wikimedia User-Agent policy requires one; a URL or an email address both qualify.
- **Default**: `https://thegreatestbooks.org`
- **Required**: No
```

- [ ] **Step 3: Write the failing tests**

`test/lib/wikimedia/http_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikimedia
  class HttpTest < ActiveSupport::TestCase
    API = "https://www.wikidata.org/w/api.php"
    SPARQL = "https://query.wikidata.org/sparql"
    AGENT = "TheGreatest/1.0 (https://example.org/contact)"

    def setup
      @settings = ActiveSupport::OrderedOptions.new.merge(
        requests_per_window: 1, window_seconds: 1.0, max_inline_wait: 5.0, maxlag: 5,
        contact: "https://example.org/contact"
      )
      @limiter = mock("limiter")
      @limiter.stubs(:acquire!)
      @slept = []
      @http = Http.new(settings: @settings, limiter: @limiter, sleeper: ->(seconds) { @slept << seconds })
    end

    def json(body, status: 200, headers: {})
      {status: status, body: body.to_json, headers: {"Content-Type" => "application/json"}.merge(headers)}
    end

    def busy(retry_after)
      ::DistributedRateLimiter::RateLimitExceeded.new("busy", key: "wikimedia:api", retry_after: retry_after)
    end

    test "builds the shared limiter on the wikimedia:api key in immediate mode" do
      ::DistributedRateLimiter.expects(:new)
        .with(key: "wikimedia:api", limit: 1, window: 1.0, mode: :immediate)
        .returns(@limiter)

      Http.new(settings: @settings)
    end

    test "sends the policy User-Agent, JSON format, formatversion 2 and maxlag on Action API calls" do
      stub = stub_request(:get, API)
        .with(
          query: {action: "wbgetentities", ids: "Q1", format: "json", formatversion: "2", maxlag: "5"},
          headers: {"User-Agent" => AGENT}
        )
        .to_return(json({entities: {}}))

      @http.action_api(API, action: "wbgetentities", ids: "Q1")

      assert_requested stub
    end

    test "returns the parsed data and the raw body" do
      stub_request(:get, API).with(query: hash_including(action: "wbsearchentities")).to_return(json({search: []}))

      response = @http.action_api(API, action: "wbsearchentities")

      assert_equal({"search" => []}, response.data)
      assert_equal({search: []}.to_json, response.body)
    end

    test "a 429 raises RateLimited carrying Retry-After" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 429, body: "", headers: {"Retry-After" => "120"})

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal 120, error.retry_after
    end

    test "a 429 without Retry-After waits the default" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 429, body: "")

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal Http::DEFAULT_RETRY_AFTER, error.retry_after
    end

    test "a maxlag error raises RateLimited carrying Retry-After" do
      body = {error: {code: "maxlag", info: "Waiting for db1: 6 seconds lagged", lag: 6}}
      stub_request(:get, API).with(query: hash_including({})).to_return(json(body, headers: {"Retry-After" => "5"}))

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal 5, error.retry_after
    end

    test "RateLimited is not a Wikimedia error, so a rescue of Error never swallows it" do
      assert_not Exceptions::RateLimited <= Exceptions::Error
    end

    test "another Action API error raises ApiError with its code" do
      body = {error: {code: "no-such-entity", info: "Could not find an entity with the ID Q0."}}
      stub_request(:get, API).with(query: hash_including({})).to_return(json(body))

      error = assert_raises(Exceptions::ApiError) { @http.action_api(API, action: "wbgetentities") }

      assert_equal "no-such-entity", error.code
    end

    test "a 403 raises HttpError naming the User-Agent policy" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 403, body: "Forbidden")

      error = assert_raises(Exceptions::HttpError) { @http.action_api(API, action: "query") }

      assert_equal 403, error.status_code
      assert_match(/User-Agent/, error.message)
    end

    test "a 500 raises HttpError" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 500, body: "oops")

      error = assert_raises(Exceptions::HttpError) { @http.action_api(API, action: "query") }

      assert_equal 500, error.status_code
    end

    test "invalid JSON raises ParseError" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 200, body: "<html>")

      assert_raises(Exceptions::ParseError) { @http.action_api(API, action: "query") }
    end

    test "a timeout raises TimeoutError" do
      stub_request(:get, API).with(query: hash_including({})).to_timeout

      assert_raises(Exceptions::TimeoutError) { @http.action_api(API, action: "query") }
    end

    test "SPARQL posts the query with the results Accept header and the User-Agent" do
      stub = stub_request(:post, SPARQL)
        .with(body: {query: "ASK {}"}, headers: {"Accept" => "application/sparql-results+json", "User-Agent" => AGENT})
        .to_return(json({boolean: true}))

      response = @http.sparql(SPARQL, "ASK {}")

      assert_requested stub
      assert_equal true, response.data["boolean"]
    end

    test "waits inline for a busy slot, then sends" do
      @limiter.stubs(:acquire!).raises(busy(0.4)).then.returns({allowed: true})
      stub = stub_request(:get, API).with(query: hash_including({})).to_return(json({}))

      @http.action_api(API, action: "query")

      assert_equal [0.4], @slept
      assert_requested stub
    end

    test "raises RateLimited, without sending, when the slot stays busy past max_inline_wait" do
      @limiter.stubs(:acquire!).raises(busy(3.0))
      stub = stub_request(:get, API).with(query: hash_including({})).to_return(json({}))

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal [3.0], @slept
      assert_equal 3, error.retry_after
      assert_not_requested stub
    end
  end
end
```

- [ ] **Step 4: Run to verify they fail**

Run: `bin/rails test test/lib/wikimedia/http_test.rb`
Expected: errors with `NameError: uninitialized constant Wikimedia::Http`.

- [ ] **Step 5: Implement**

`app/lib/wikimedia/exceptions.rb`:

```ruby
# frozen_string_literal: true

module Wikimedia
  module Exceptions
    class Error < StandardError; end

    class NetworkError < Error
      attr_reader :original_error

      def initialize(message, original_error = nil)
        super(message)
        @original_error = original_error
      end
    end

    class TimeoutError < NetworkError; end

    class HttpError < Error
      attr_reader :status_code, :response_body

      def initialize(message, status_code, response_body = nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
      end
    end

    class ParseError < Error; end

    # The Action API answered {"error": {...}} for a reason other than maxlag.
    class ApiError < Error
      attr_reader :code

      def initialize(message, code)
        super(message)
        @code = code
      end
    end

    # Not a failure: a host (a 429, a maxlag error) or our own pace asked us
    # to wait. Deliberately outside Error, so a rescue of Error never
    # swallows it; the job reschedules itself for retry_after seconds.
    class RateLimited < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        super(message)
        @retry_after = retry_after
      end
    end
  end
end
```

`app/lib/wikimedia/http.rb`:

```ruby
# frozen_string_literal: true

require "faraday"
require "json"

module Wikimedia
  # The one HTTP path to every Wikimedia host. Adds the policy User-Agent,
  # takes a slot from the shared pace before each request, and turns the
  # hosts' back-off signals (a 429, a maxlag error) into RateLimited.
  #
  # The pace is an :immediate DistributedRateLimiter, but a request waits
  # inline for a slot up to max_inline_wait seconds: one author costs about
  # eight requests at one a second, so failing on the first busy slot would
  # reschedule every job forever. Only a longer wait (several workers
  # competing) becomes RateLimited, so no thread sleeps for long.
  class Http
    Response = Struct.new(:data, :body, keyword_init: true)

    USER_AGENT = "TheGreatest/1.0 (%s)"
    LIMITER_KEY = "wikimedia:api"
    TIMEOUT = 30
    OPEN_TIMEOUT = 10
    DEFAULT_RETRY_AFTER = 60
    MIN_SLEEP = 0.05

    attr_reader :settings

    def initialize(settings: Rails.application.config.x.wikimedia, limiter: nil, sleeper: nil)
      @settings = settings
      @limiter = limiter || ::DistributedRateLimiter.new(
        key: LIMITER_KEY, limit: settings.requests_per_window, window: settings.window_seconds, mode: :immediate
      )
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def user_agent = format(USER_AGENT, settings.contact)

    # GET against an Action API endpoint (www.wikidata.org or a Wikipedia).
    def action_api(url, params)
      response = perform(:get, url, params.merge(format: "json", formatversion: 2, maxlag: settings.maxlag))
      data = parse(response)
      error = data.is_a?(Hash) ? data["error"] : nil
      raise Exceptions::ApiError.new("Wikimedia API error #{error["code"]}: #{error["info"]}", error["code"].to_s) if error

      Response.new(data: data, body: response.body)
    end

    # POST to the Wikidata Query Service, so a long VALUES list fits.
    def sparql(url, query)
      response = perform(:post, url, {query: query}, accept: "application/sparql-results+json")
      Response.new(data: parse(response), body: response.body)
    end

    private

    def perform(verb, url, params, accept: "application/json")
      acquire_slot!
      headers = {"User-Agent" => user_agent, "Accept" => accept}
      response = if verb == :get
        connection.get(url, params, headers)
      else
        connection.post(url, URI.encode_www_form(params), headers.merge("Content-Type" => "application/x-www-form-urlencoded"))
      end
      check_status!(response)
      response
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Wikimedia request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Wikimedia connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Wikimedia network error: #{e.message}", e)
    end

    def check_status!(response)
      if response.status == 429 || maxlag?(response)
        raise Exceptions::RateLimited.new("Wikimedia asked us to wait (HTTP #{response.status})", retry_after: retry_after(response))
      end
      return if response.status == 200

      message = if response.status == 403
        "Wikimedia refused the request (403). Check the User-Agent policy before retrying."
      else
        "Wikimedia returned HTTP #{response.status}"
      end
      raise Exceptions::HttpError.new(message, response.status, response.body)
    end

    def maxlag?(response)
      return false unless response.body.to_s.include?("maxlag")

      JSON.parse(response.body).dig("error", "code") == "maxlag"
    rescue JSON::ParserError, TypeError
      false
    end

    def retry_after(response)
      value = Integer(response.headers["retry-after"].to_s, exception: false)
      (value && value.positive?) ? value : DEFAULT_RETRY_AFTER
    end

    def parse(response)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Exceptions::ParseError, "Wikimedia returned invalid JSON: #{e.message}"
    end

    def acquire_slot!
      waited = 0.0
      begin
        @limiter.acquire!
      rescue ::DistributedRateLimiter::RateLimitExceeded => e
        wait = [e.retry_after.to_f, MIN_SLEEP].max
        if waited + wait > settings.max_inline_wait
          raise Exceptions::RateLimited.new("Wikimedia pace still busy after #{waited.round(2)}s", retry_after: wait.ceil)
        end

        @sleeper.call(wait)
        waited += wait
        retry
      end
    end

    def connection
      @connection ||= Faraday.new do |conn|
        conn.options.timeout = TIMEOUT
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.adapter Faraday.default_adapter
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests, lint, and the Zeitwerk check**

Run: `bin/rails test test/lib/wikimedia/http_test.rb && bundle exec standardrb app/lib/wikimedia config/initializers/wikimedia.rb test/lib/wikimedia && CI=1 bin/rails zeitwerk:check`
Expected: all tests pass, no offenses, "All is good!".

- [ ] **Step 7: Commit**

```bash
git add config/initializers/wikimedia.rb app/lib/wikimedia test/lib/wikimedia ../.env.example ../deployment/ENV.md
git commit -m "Wikimedia HTTP foundation: shared pace, User-Agent, 429 and maxlag handling

Limits verified live 2026-09-27 (Task 1 Step 1).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `external_records` raw column, new sources, read-through store

**Files:**
- Create: migration via `bin/rails generate migration AddRawToExternalRecords raw:binary`
- Modify: `app/models/external_record.rb`
- Create: `app/lib/services/external_records/store.rb`
- Test: `test/models/external_record_test.rb` (extend), `test/lib/services/external_records/store_test.rb`

**Interfaces:**
- Produces:
  - `ExternalRecord.sources` → `{"viaf" => 0, "wikidata" => 1, "wikipedia" => 2}`
  - `ExternalRecord#raw_text` → the decompressed UTF-8 String, or nil
  - `ExternalRecord#raw_text=(String or nil)` → gzips into `raw`
  - `Services::ExternalRecords::Store.find(source:, source_id:, schema_version:)` → `ExternalRecord` or nil
  - `Services::ExternalRecords::Store.find_all(source:, source_ids:, schema_version:)` → `Hash{source_id String => ExternalRecord}`
  - `Services::ExternalRecords::Store.write(source:, source_id:, payload:, raw:, schema_version:)` → `ExternalRecord`

- [ ] **Step 1: Generate and edit the migration**

Run: `bin/rails generate migration AddRawToExternalRecords raw:binary`

The generated body must be exactly:

```ruby
  def change
    add_column :external_records, :raw, :binary
  end
```

Run: `bin/rails db:migrate`. Diff `db/schema.rb`: the only changes should be the version bump and `t.binary "raw"` in `external_records`. Strip anything else, per the Global Constraints. Then run `RAILS_ENV=test bin/rails db:test:prepare`.

- [ ] **Step 2: Write the failing tests**

Append inside the existing class in `test/models/external_record_test.rb`:

```ruby
  test "sources include wikidata and wikipedia alongside viaf" do
    assert_equal({"viaf" => 0, "wikidata" => 1, "wikipedia" => 2}, ExternalRecord.sources)
  end

  test "raw_text round-trips UTF-8 through the gzipped raw column" do
    record = ExternalRecord.create!(source: :wikidata, source_id: "Q7243", payload: {}, fetched_at: Time.current)
    record.update!(raw_text: '{"label":"Лев Толстой"}')

    reloaded = ExternalRecord.find(record.id)

    assert_equal '{"label":"Лев Толстой"}', reloaded.raw_text
    assert_operator reloaded.raw.bytesize, :>, 0
    assert_not_equal reloaded.raw_text.b, reloaded.raw
  end

  test "raw_text is nil when nothing is stored" do
    record = ExternalRecord.new(source: :wikidata, source_id: "Q1", payload: {}, fetched_at: Time.current)
    record.raw_text = nil

    assert_nil record.raw
    assert_nil record.raw_text
  end
```

`test/lib/services/external_records/store_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module ExternalRecords
    class StoreTest < ActiveSupport::TestCase
      def write(source_id, payload: {"id" => source_id}, raw: "{}", schema_version: 1)
        Store.write(source: :wikidata, source_id: source_id, payload: payload, raw: raw, schema_version: schema_version)
      end

      test "write creates a row with the payload, the gzipped raw body and the schema version" do
        record = write("Q7243", payload: {"id" => "Q7243", "label" => "Leo Tolstoy"}, raw: '{"id":"Q7243"}')

        assert record.persisted?
        assert_equal "Leo Tolstoy", record.payload["label"]
        assert_equal '{"id":"Q7243"}', record.reload.raw_text
        assert_equal 1, record.schema_version
        assert_not_nil record.fetched_at
      end

      test "write updates the existing row for the same source and id" do
        write("Q7243", payload: {"label" => "old"})

        assert_no_difference -> { ::ExternalRecord.count } do
          write("Q7243", payload: {"label" => "new"}, schema_version: 2)
        end
        record = ::ExternalRecord.find_by!(source: :wikidata, source_id: "Q7243")
        assert_equal ["new", 2], [record.payload["label"], record.schema_version]
      end

      test "write returns the winner's row when another worker inserted it first" do
        winner = write("Q42")
        loser = ::ExternalRecord.new(source: :wikidata, source_id: "Q42")
        ::ExternalRecord.stubs(:find_or_initialize_by).returns(loser)
        loser.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

        assert_equal winner.id, write("Q42").id
      end

      test "find returns a row only at the current schema version and for the right source" do
        write("Q1", schema_version: 1)

        assert_not_nil Store.find(source: :wikidata, source_id: "Q1", schema_version: 1)
        assert_nil Store.find(source: :wikidata, source_id: "Q1", schema_version: 2)
        assert_nil Store.find(source: :wikipedia, source_id: "Q1", schema_version: 1)
        assert_nil Store.find(source: :wikidata, source_id: "Q2", schema_version: 1)
      end

      test "find_all maps each held id to its row in one query" do
        write("Q1")
        write("Q2")

        found = Store.find_all(source: :wikidata, source_ids: ["Q1", "Q2", "Q3"], schema_version: 1)

        assert_equal ["Q1", "Q2"], found.keys.sort
        assert_equal({}, Store.find_all(source: :wikidata, source_ids: [], schema_version: 1))
      end
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/models/external_record_test.rb test/lib/services/external_records/store_test.rb`
Expected: failures on the enum and `NoMethodError: raw_text=`; `NameError` for `Store`.

- [ ] **Step 4: Implement**

In `app/models/external_record.rb`, change the enum and add the two methods above `private`:

```ruby
  enum :source, {viaf: 0, wikidata: 1, wikipedia: 2}
```

```ruby
  # The complete response body, gzipped in `raw` (spec §3). `payload` stays
  # the small distilled view the code reads; this is kept so a later feature
  # can use more of a response without calling the API again.
  def raw_text
    raw && ActiveSupport::Gzip.decompress(raw).force_encoding(Encoding::UTF_8)
  end

  def raw_text=(text)
    self.raw = text && ActiveSupport::Gzip.compress(text)
  end
```

`app/lib/services/external_records/store.rb`:

```ruby
# frozen_string_literal: true

module Services
  module ExternalRecords
    # Read-through storage for external responses (spec §3): a row held at
    # the current schema_version is used as is; otherwise the caller fetches
    # and writes. Viaf::Cluster predates this and keeps its own copy.
    class Store
      def self.find(source:, source_id:, schema_version:)
        find_all(source: source, source_ids: [source_id], schema_version: schema_version)[source_id.to_s]
      end

      # source_id => row, for the ids held at the current schema_version.
      def self.find_all(source:, source_ids:, schema_version:)
        ids = Array(source_ids).map(&:to_s).uniq
        return {} if ids.empty?

        ::ExternalRecord.where(source: source, source_id: ids, schema_version: schema_version).index_by(&:source_id)
      end

      # Two workers can fetch the same record at once. The unique index on
      # (source, source_id), or the uniqueness validation just before it,
      # settles the race, and the loser returns the winner's row.
      def self.write(source:, source_id:, payload:, raw:, schema_version:)
        record = ::ExternalRecord.find_or_initialize_by(source: source, source_id: source_id.to_s)
        record.assign_attributes(payload: payload, raw_text: raw, schema_version: schema_version, fetched_at: Time.current)
        record.save!
        record
      rescue ActiveRecord::RecordNotUnique
        ::ExternalRecord.find_by!(source: source, source_id: source_id.to_s)
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.errors.of_kind?(:source_id, :taken)

        ::ExternalRecord.find_by!(source: source, source_id: source_id.to_s)
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests, the VIAF tests (same table), lint, Zeitwerk**

Run: `bin/rails test test/models/external_record_test.rb test/lib/services/external_records test/lib/viaf && bundle exec standardrb app/models/external_record.rb app/lib/services/external_records test/lib/services/external_records test/models/external_record_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, "All is good!".

- [ ] **Step 6: Commit**

```bash
git add db/migrate/*_add_raw_to_external_records.rb db/schema.rb app/models/external_record.rb app/lib/services/external_records test/models/external_record_test.rb test/lib/services/external_records
git commit -m "external_records: wikidata and wikipedia sources, gzipped raw body, read-through store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Wikidata distiller and entity view

**Files:**
- Create: `app/lib/wikidata/distiller.rb`, `app/lib/wikidata/entity.rb`
- Create: `test/support/wikidata_entity_builder.rb` and require it from `test/test_helper.rb`
- Create: `test/fixtures/files/wikidata/wbgetentities_Q7243.json` (a trimmed real response, Step 1)
- Test: `test/lib/wikidata/distiller_test.rb`, `test/lib/wikidata/entity_test.rb`

**Interfaces:**
- Consumes: `Wikimedia::Exceptions::ParseError` (Task 1).
- Produces:
  - `Wikidata::Distiller::SCHEMA_VERSION` (1)
  - `Wikidata::Distiller::IDENTIFIER_PROPERTIES` (`kind => property`, kinds `viaf isni lcnaf openlibrary goodreads librarything`)
  - `Wikidata::Distiller.call(entity_hash) → payload Hash` (string keys)
  - `Wikidata::Entity.from_payload(payload)`
  - `Wikidata::Entity` scalar readers: `#id`, `#label`, `#description`, `#enwiki_title`, `#sitelink_count`, `#payload`
  - `Wikidata::Entity` list readers: `#aliases`, `#instance_of`, `#gender_ids`, `#citizenship_ids`, `#occupation_ids`, `#native_names`, `#pseudonyms`, `#names` (label plus aliases)
  - `Wikidata::Entity#identifiers(kind) → [String]`, `#person?`
  - `Wikidata::Entity#birth` / `#death` → `YearFact(year:, reason:)`
  - `YearFact#reason` is nil or one of `"null" "unknown" "imprecise" "disagreeing" "bce"`
  - `Wikidata::Entity#birth_year`, `#death_year`
  - `Wikidata::Entity::PERSON_TYPES` (`%w[Q5 Q61002 Q16017119]`)
  - Test helper `wikidata_entity(id, **options)`, included in every `ActiveSupport::TestCase`

- [ ] **Step 1: Save a trimmed real entity as a fixture**

Write this script to the scratch path `tmp/fetch_wikidata_entity.rb`. It is not committed; `tmp/` is gitignored.

```ruby
require "net/http"
require "json"
require "uri"
require "fileutils"

uri = URI("https://www.wikidata.org/w/api.php")
uri.query = URI.encode_www_form(action: "wbgetentities", ids: "Q7243", format: "json", formatversion: 2)
request = Net::HTTP::Get.new(uri)
request["User-Agent"] = "TheGreatest/1.0 (+https://thegreatestbooks.org) test fixtures"
response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
abort "HTTP #{response.code}" unless response.code == "200"

entity = JSON.parse(response.body)["entities"]["Q7243"]
keep = %w[P31 P21 P27 P106 P569 P570 P1559 P742 P214 P213 P244 P648 P2963 P7400]
trimmed = {
  "type" => entity["type"],
  "id" => entity["id"],
  "labels" => entity["labels"].slice("en", "ru"),
  "descriptions" => entity["descriptions"].slice("en"),
  "aliases" => entity["aliases"].slice("en"),
  "claims" => entity["claims"].slice(*keep).transform_values do |statements|
    statements.map { |s| {"mainsnak" => s["mainsnak"].slice("snaktype", "property", "datavalue"), "rank" => s["rank"]} }
  end,
  "sitelinks" => entity["sitelinks"].slice("enwiki", "ruwiki", "frwiki").transform_values { |l| l.slice("site", "title") }
}
FileUtils.mkdir_p("test/fixtures/files/wikidata")
File.write("test/fixtures/files/wikidata/wbgetentities_Q7243.json", JSON.pretty_generate({"entities" => {"Q7243" => trimmed}, "success" => 1}) + "\n")
```

Run: `ruby tmp/fetch_wikidata_entity.rb && head -c 400 test/fixtures/files/wikidata/wbgetentities_Q7243.json`.

The distiller test below asserts values measured on 2026-09-27:

| Field | Value |
|---|---|
| label | `Leo Tolstoy` |
| P214 | `96987389` |
| P213 | `0000000122424494` |
| P244 | `n79068416` |
| P648 | `OL26783A`, `OL7555476A` |
| P2963 | `128382` |
| P7400 | `tolstoyleo` |
| birth | 1828 |
| death | 1910 |
| P21 | Q6581097 |
| P31 | Q5 |
| sitelinks kept | 3 |

If the fetched file differs on any of these, change the test's expected value to the file's, not the file.

- [ ] **Step 2: Add the entity builder for tests**

`test/support/wikidata_entity_builder.rb`:

```ruby
# frozen_string_literal: true

# Builds wbgetentities entity hashes (formatversion 2) with only the shapes
# Wikidata::Distiller reads. Years: an Integer is year precision (9);
# {year:, precision:} sets the precision; :unknown is a somevalue snak.
module WikidataEntityBuilder
  def wikidata_entity(id, label: nil, aliases: [], description: nil, types: ["Q5"], born: nil, died: nil,
    gender: [], citizenships: [], occupations: [], native_names: [], pseudonyms: [], identifiers: {},
    enwiki: nil, sitelinks: 0, claims: {})
    all_claims = {
      "P31" => types.map { |type| wikidata_item_statement(type) },
      "P21" => gender.map { |item| wikidata_item_statement(item) },
      "P27" => citizenships.map { |item| wikidata_item_statement(item) },
      "P106" => occupations.map { |item| wikidata_item_statement(item) },
      "P1559" => native_names.map { |text| wikidata_statement({"text" => text, "language" => "mul"}) },
      "P742" => pseudonyms.map { |name| wikidata_statement(name) },
      "P569" => wikidata_dates(born).map { |value| wikidata_time_statement(value) },
      "P570" => wikidata_dates(died).map { |value| wikidata_time_statement(value) }
    }
    Wikidata::Distiller::IDENTIFIER_PROPERTIES.each do |kind, property|
      all_claims[property] = Array(identifiers[kind.to_sym] || identifiers[kind]).map { |value| wikidata_statement(value) }
    end

    links = {}
    links["enwiki"] = {"site" => "enwiki", "title" => enwiki} if enwiki
    (sitelinks - links.size).times { |i| links["x#{i}wiki"] = {"site" => "x#{i}wiki", "title" => label.to_s} }

    {
      "type" => "item",
      "id" => id,
      "labels" => label ? {"en" => {"language" => "en", "value" => label}} : {},
      "descriptions" => description ? {"en" => {"language" => "en", "value" => description}} : {},
      "aliases" => aliases.any? ? {"en" => aliases.map { |name| {"language" => "en", "value" => name} }} : {},
      "claims" => all_claims.reject { |_property, statements| statements.empty? }.merge(claims),
      "sitelinks" => links
    }
  end

  # nil → none; one value (an Integer, a {year:, precision:} Hash, :unknown) → one; an Array → each.
  # Not Array(value): Array({year: 1900}) would turn the Hash into pairs.
  def wikidata_dates(value)
    return [] if value.nil?

    value.is_a?(Array) ? value : [value]
  end

  def wikidata_time_statement(value, rank: "normal")
    return {"mainsnak" => {"snaktype" => "somevalue"}, "rank" => rank} if value == :unknown

    year, precision = value.is_a?(Hash) ? [value[:year], value[:precision]] : [value, 9]
    time = format("%s%04d-00-00T00:00:00Z", year.negative? ? "-" : "+", year.abs)
    wikidata_statement({"time" => time, "precision" => precision}, rank: rank)
  end

  def wikidata_item_statement(item_id, rank: "normal")
    wikidata_statement({"entity-type" => "item", "id" => item_id}, rank: rank)
  end

  def wikidata_statement(value, rank: "normal")
    {"mainsnak" => {"snaktype" => "value", "datavalue" => {"value" => value}}, "rank" => rank}
  end
end

ActiveSupport::TestCase.include(WikidataEntityBuilder)
```

Add to `test/test_helper.rb`, after `require_relative "support/sql_capture"`:

```ruby
require_relative "support/wikidata_entity_builder"
```

- [ ] **Step 3: Write the failing tests**

`test/lib/wikidata/distiller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikidata
  class DistillerTest < ActiveSupport::TestCase
    def real_entity
      JSON.parse(file_fixture("wikidata/wbgetentities_Q7243.json").read)["entities"]["Q7243"]
    end

    test "distills a real entity into the fields the author steps read" do
      payload = Distiller.call(real_entity)

      assert_equal "Q7243", payload["id"]
      assert_equal "Leo Tolstoy", payload["label"]
      assert_includes payload["instance_of"], "Q5"
      assert_includes payload["gender"], "Q6581097"
      # Wikidata may carry both a Gregorian and a Julian date for 1828; both are day precision.
      assert_equal [1828], payload["birth"].map { |date| date["year"] }.uniq
      assert payload["birth"].all? { |date| date["precision"] == 11 }
      assert_equal [1910], payload["death"].map { |date| date["year"] }.uniq
      assert_not_empty payload["citizenships"]
      assert_not_empty payload["native_names"]
      assert_equal ["96987389"], payload["identifiers"]["viaf"]
      assert_equal ["0000000122424494"], payload["identifiers"]["isni"]
      assert_equal ["n79068416"], payload["identifiers"]["lcnaf"]
      assert_equal ["OL26783A", "OL7555476A"], payload["identifiers"]["openlibrary"].sort
      assert_equal ["128382"], payload["identifiers"]["goodreads"]
      assert_equal ["tolstoyleo"], payload["identifiers"]["librarything"]
      assert_equal "Leo Tolstoy", payload["enwiki_title"]
      assert_equal 3, payload["sitelink_count"]
    end

    test "uses only best-rank statements: preferred when any, never deprecated" do
      entity = wikidata_entity("Q1", label: "X", claims: {
        "P569" => [wikidata_time_statement(1900, rank: "preferred"), wikidata_time_statement(1901)],
        "P27" => [wikidata_item_statement("Q30", rank: "deprecated"), wikidata_item_statement("Q145")]
      })

      payload = Distiller.call(entity)

      assert_equal [{"year" => 1900, "precision" => 9}], payload["birth"]
      assert_equal ["Q145"], payload["citizenships"]
    end

    test "keeps somevalue dates as unknown and BCE years as negative" do
      payload = Distiller.call(wikidata_entity("Q1", label: "X", born: :unknown, died: {year: -347, precision: 9}))

      assert_equal [{"unknown" => true}], payload["birth"]
      assert_equal [{"year" => -347, "precision" => 9}], payload["death"]
    end

    test "handles an entity with no English label, aliases, claims or sitelinks" do
      payload = Distiller.call({"id" => "Q9", "labels" => {}, "aliases" => {}, "claims" => {}, "sitelinks" => {}})

      assert_nil payload["label"]
      assert_equal [], payload["aliases"]
      assert_equal [], payload["instance_of"]
      assert_equal 0, payload["sitelink_count"]
    end

    test "refuses a missing entity" do
      assert_raises(::Wikimedia::Exceptions::ParseError) { Distiller.call({"id" => "Q0", "missing" => true}) }
      assert_raises(::Wikimedia::Exceptions::ParseError) { Distiller.call(nil) }
    end
  end
end
```

`test/lib/wikidata/entity_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikidata
  class EntityTest < ActiveSupport::TestCase
    def entity(**options)
      Entity.from_payload(Distiller.call(wikidata_entity("Q1", label: "Leo Tolstoy", **options)))
    end

    test "a human, a pseudonym and a collective pseudonym are persons; a book is not" do
      assert entity(types: ["Q5"]).person?
      assert entity(types: ["Q61002"]).person?
      assert entity(types: ["Q16017119"]).person?
      assert_not entity(types: ["Q7725634"]).person?
    end

    test "names are the label and the English aliases" do
      assert_equal ["Leo Tolstoy", "Lev Tolstoy"], entity(aliases: ["Lev Tolstoy", "Leo Tolstoy"]).names
    end

    test "a year at year precision or finer is usable" do
      subject = entity(born: {year: 1828, precision: 11}, died: 1910)

      assert_equal [1828, 1910], [subject.birth_year, subject.death_year]
      assert_nil subject.birth.reason
    end

    test "every reason a year is not usable" do
      assert_equal "null", entity.birth.reason
      assert_equal "unknown", entity(born: :unknown).birth.reason
      assert_equal "imprecise", entity(born: {year: 1820, precision: 8}).birth.reason
      assert_equal "disagreeing", entity(born: [1828, 1829]).birth.reason
      assert_equal "bce", entity(born: -427).birth.reason
      assert_nil entity(born: -427).birth_year
    end

    test "a precise value wins over an imprecise one, and agreeing duplicates are one year" do
      assert_equal 1828, entity(born: [{year: 1820, precision: 8}, 1828]).birth_year
      assert_equal 1828, entity(born: [1828, {year: 1828, precision: 11}]).birth_year
    end

    test "identifiers are read by kind" do
      subject = entity(identifiers: {openlibrary: ["OL1A", "OL2A"], viaf: ["123"]})

      assert_equal ["OL1A", "OL2A"], subject.identifiers(:openlibrary)
      assert_equal ["123"], subject.identifiers("viaf")
      assert_equal [], subject.identifiers(:isni)
    end

    test "a stored payload with symbol keys reads the same" do
      payload = Distiller.call(wikidata_entity("Q1", label: "X", born: 1900)).deep_symbolize_keys

      assert_equal 1900, Entity.from_payload(payload).birth_year
    end
  end
end
```

- [ ] **Step 4: Run to verify they fail**

Run: `bin/rails test test/lib/wikidata`
Expected: `NameError: uninitialized constant Wikidata::Distiller` (the builder also names it). Every test errors.

- [ ] **Step 5: Implement**

`app/lib/wikidata/distiller.rb`:

```ruby
# frozen_string_literal: true

module Wikidata
  # Reduces one wbgetentities entity to the fields the author steps read.
  # Only best-rank statements count: the preferred ones when any exist,
  # otherwise the normal ones, never deprecated ones. The full entity is kept
  # separately, gzipped (ExternalRecord#raw_text).
  module Distiller
    SCHEMA_VERSION = 1

    IDENTIFIER_PROPERTIES = {
      "viaf" => "P214", "isni" => "P213", "lcnaf" => "P244",
      "openlibrary" => "P648", "goodreads" => "P2963", "librarything" => "P7400"
    }.freeze

    TIME = /\A([+-])(\d+)-/

    module_function

    def call(entity)
      unless entity.is_a?(Hash) && entity["id"].present? && !entity.key?("missing")
        raise ::Wikimedia::Exceptions::ParseError, "Not a Wikidata entity: #{entity.to_s[0, 200]}"
      end

      claims = entity["claims"].is_a?(Hash) ? entity["claims"] : {}
      {
        "id" => entity["id"],
        "label" => english(entity["labels"]),
        "aliases" => english_list(entity["aliases"]),
        "description" => english(entity["descriptions"]),
        "instance_of" => item_ids(claims, "P31"),
        "birth" => times(claims, "P569"),
        "death" => times(claims, "P570"),
        "gender" => item_ids(claims, "P21"),
        "citizenships" => item_ids(claims, "P27"),
        "occupations" => item_ids(claims, "P106"),
        "native_names" => values(claims, "P1559").filter_map { |value| value["text"] if value.is_a?(Hash) },
        "pseudonyms" => values(claims, "P742").grep(String),
        "identifiers" => IDENTIFIER_PROPERTIES.transform_values { |property| values(claims, property).grep(String) },
        "enwiki_title" => entity["sitelinks"].is_a?(Hash) ? entity["sitelinks"].dig("enwiki", "title") : nil,
        "sitelink_count" => entity["sitelinks"].is_a?(Hash) ? entity["sitelinks"].size : 0
      }
    end

    def english(terms)
      terms.is_a?(Hash) ? terms.dig("en", "value") : nil
    end

    def english_list(terms)
      return [] unless terms.is_a?(Hash)

      Array(terms["en"]).filter_map { |term| term["value"] if term.is_a?(Hash) }
    end

    def best(claims, property)
      statements = Array(claims[property]).select { |statement| statement.is_a?(Hash) && statement["rank"] != "deprecated" }
      preferred = statements.select { |statement| statement["rank"] == "preferred" }
      preferred.any? ? preferred : statements
    end

    def values(claims, property)
      best(claims, property).filter_map do |statement|
        snak = statement["mainsnak"]
        snak.dig("datavalue", "value") if snak.is_a?(Hash) && snak["snaktype"] == "value"
      end
    end

    def item_ids(claims, property)
      values(claims, property).filter_map { |value| value["id"] if value.is_a?(Hash) }.uniq
    end

    def times(claims, property)
      best(claims, property).filter_map do |statement|
        snak = statement["mainsnak"]
        next unless snak.is_a?(Hash)
        next {"unknown" => true} if snak["snaktype"] == "somevalue"

        value = snak.dig("datavalue", "value")
        match = value.is_a?(Hash) && value["time"].to_s.match(TIME)
        next unless match

        {"year" => match[2].to_i * ((match[1] == "-") ? -1 : 1), "precision" => value["precision"].to_i}
      end
    end

    private_class_method :english, :english_list, :best, :values, :item_ids, :times
  end
end
```

`app/lib/wikidata/entity.rb`:

```ruby
# frozen_string_literal: true

module Wikidata
  # Read-only view of a distilled entity (Distiller's payload), built the
  # same way from a stored external_records row and from a fresh fetch.
  class Entity
    PERSON_TYPES = %w[Q5 Q61002 Q16017119].freeze # human, pseudonym, collective pseudonym
    MIN_YEAR_PRECISION = 9 # year; 8 is decade, 7 century

    YearFact = Struct.new(:year, :reason, keyword_init: true)

    attr_reader :payload

    def self.from_payload(payload) = new(payload)

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def id = payload["id"]

    def label = payload["label"]

    def description = payload["description"]

    def aliases = Array(payload["aliases"])

    def instance_of = Array(payload["instance_of"])

    def gender_ids = Array(payload["gender"])

    def citizenship_ids = Array(payload["citizenships"])

    def occupation_ids = Array(payload["occupations"])

    def native_names = Array(payload["native_names"])

    def pseudonyms = Array(payload["pseudonyms"])

    def enwiki_title = payload["enwiki_title"]

    def sitelink_count = payload["sitelink_count"].to_i

    def identifiers(kind) = Array(payload.dig("identifiers", kind.to_s))

    def person? = instance_of.intersect?(PERSON_TYPES)

    # The label and the English aliases: the names this item answers to.
    def names = ([label] + aliases).compact_blank.uniq

    def birth = year_fact(payload["birth"])

    def death = year_fact(payload["death"])

    def birth_year = birth.year

    def death_year = death.year

    private

    # A year is usable only at year precision or finer, when those values
    # agree, and when it is CE. Otherwise the reason says why: null (no
    # value), unknown (somevalue), imprecise (decade or century only),
    # disagreeing, or bce.
    def year_fact(values)
      values = Array(values)
      known = values.reject { |value| value["unknown"] }
      return YearFact.new(year: nil, reason: values.any? ? "unknown" : "null") if known.empty?

      precise = known.select { |value| value["precision"].to_i >= MIN_YEAR_PRECISION }
      return YearFact.new(year: nil, reason: "imprecise") if precise.empty?

      years = precise.map { |value| value["year"].to_i }.uniq
      return YearFact.new(year: nil, reason: "disagreeing") if years.size > 1
      return YearFact.new(year: nil, reason: "bce") unless years.first.positive?

      YearFact.new(year: years.first, reason: nil)
    end
  end
end
```

- [ ] **Step 6: Run tests, lint, Zeitwerk**

Run: `bin/rails test test/lib/wikidata && bundle exec standardrb app/lib/wikidata test/lib/wikidata test/support/wikidata_entity_builder.rb && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, "All is good!".

- [ ] **Step 7: Commit**

```bash
git add app/lib/wikidata test/lib/wikidata test/support/wikidata_entity_builder.rb test/test_helper.rb test/fixtures/files/wikidata/wbgetentities_Q7243.json
git commit -m "Wikidata distiller and entity view: best-rank statements, year precision, person types

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `Wikidata::Client`

**Files:**
- Create: `app/lib/wikidata/client.rb`
- Create fixtures (Step 1): `test/fixtures/files/wikidata/wbsearchentities_leo_tolstoy.json`, `haswbstatement_tolstoy.json`, `sparql_works_Q7243.json`, `sparql_country_codes.json`
- Test: `test/lib/wikidata/client_test.rb`

**Interfaces:**
- Consumes: `Wikimedia::Http#action_api`, `#sparql` (Task 1).
- Produces (`Wikidata::Client.new(http: nil)`):
  - `#entities(ids) → Hash{requested id => entity Hash}`. Missing ids are absent. A redirected id maps to the target entity, whose `"id"` differs.
  - `#search(name) → [{"id", "label", "description"}]`: up to 10, English, items.
  - `#by_statements(pairs) → [item id]`. `pairs` is `[[property, value], …]`; pairs with unsafe values are dropped.
  - `#works(item_ids) → Hash{item id => [English work titles]}`
  - `#country_codes(item_ids) → Hash{item id => {"code" => "US" or nil, "label" => "United States"}}`, cached 30 days
  - `#labels(item_ids) → Hash{item id => English label}`, cached 30 days
  - Each operation returns empty without a request when given nothing usable.

- [ ] **Step 1: Save trimmed real responses as fixtures**

Scratch script `tmp/fetch_wikidata_fixtures.rb` (not committed):

```ruby
require "net/http"
require "json"
require "uri"

AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org) test fixtures"
DIR = "test/fixtures/files/wikidata"

def fetch(request)
  request["User-Agent"] = AGENT
  uri = request.uri
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 90) { |http| http.request(request) }
  abort "HTTP #{response.code} for #{uri}" unless response.code == "200"
  sleep 1
  JSON.parse(response.body)
end

def api(params)
  uri = URI("https://www.wikidata.org/w/api.php")
  uri.query = URI.encode_www_form(params.merge(format: "json", formatversion: 2))
  fetch(Net::HTTP::Get.new(uri))
end

def sparql(query)
  request = Net::HTTP::Post.new(URI("https://query.wikidata.org/sparql"))
  request["Accept"] = "application/sparql-results+json"
  request.set_form_data("query" => query)
  fetch(request)
end

def save(name, data) = File.write("#{DIR}/#{name}", JSON.pretty_generate(data) + "\n")

search = api(action: "wbsearchentities", search: "Leo Tolstoy", language: "en", uselang: "en", type: "item", limit: 3)
search["search"] = search["search"].map { |hit| hit.slice("id", "label", "description", "match") }
save("wbsearchentities_leo_tolstoy.json", search)

save("haswbstatement_tolstoy.json",
  api(action: "query", list: "search", srsearch: "haswbstatement:P648=OL26783A|P214=96987389", srnamespace: 0, srlimit: 10, srprop: ""))

works = sparql(<<~SPARQL)
  SELECT ?author ?workLabel WHERE {
    VALUES ?author { wd:Q7243 }
    { ?work wdt:P50 ?author } UNION { ?author wdt:P800 ?work }
    FILTER NOT EXISTS { ?work wdt:P31 wd:Q13442814 }
    FILTER NOT EXISTS { ?work wdt:P31 wd:Q3331189 }
    ?work rdfs:label ?workLabel . FILTER(LANG(?workLabel) = "en")
  }
SPARQL
rows = works["results"]["bindings"]
wanted = rows.select { |row| ["War and Peace", "Anna Karenina"].include?(row.dig("workLabel", "value")) }
works["results"]["bindings"] = (wanted + (rows - wanted)).first(20)
save("sparql_works_Q7243.json", works)

save("sparql_country_codes.json", sparql(<<~SPARQL))
  SELECT ?country ?code ?countryLabel WHERE {
    VALUES ?country { wd:Q30 wd:Q34266 }
    OPTIONAL { ?country wdt:P297 ?code }
    SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
  }
SPARQL
```

Run: `ruby tmp/fetch_wikidata_fixtures.rb && ls test/fixtures/files/wikidata`

Expected: four new files. The search's first hit is `Q7243`, and a later hit is a non-person ("1984 film", `Q4256164`). The CirrusSearch result contains `Q7243`. The works file contains "War and Peace". The country file has `US` for Q30 and no code for Q34266 (Russian Empire).

- [ ] **Step 2: Write the failing tests**

`test/lib/wikidata/client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikidata
  class ClientTest < ActiveSupport::TestCase
    API = "https://www.wikidata.org/w/api.php"
    SPARQL = "https://query.wikidata.org/sparql"

    def setup
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      @client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
    end

    def fixture(name) = file_fixture("wikidata/#{name}").read

    def json_response(body) = {status: 200, body: body, headers: {"Content-Type" => "application/json"}}

    def sparql_query(request) = URI.decode_www_form(request.body).to_h["query"]

    test "entities fetches with wbgetentities and keys each entity by the requested id" do
      stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q7243"))
        .to_return(json_response(fixture("wbgetentities_Q7243.json")))

      found = @client.entities(["Q7243"])

      assert_equal ["Q7243"], found.keys
      assert_equal "Leo Tolstoy", found["Q7243"].dig("labels", "en", "value")
    end

    test "entities drops missing ids and keeps a redirected id under the id we asked for" do
      body = {entities: {
        "Q1" => {"id" => "Q1", "missing" => true},
        "Q2" => {"id" => "Q7243", "labels" => {}, "claims" => {}}
      }}.to_json
      stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q1|Q2")).to_return(json_response(body))

      found = @client.entities(["Q1", "Q2"])

      assert_equal ["Q2"], found.keys
      assert_equal "Q7243", found["Q2"]["id"]
    end

    test "entities asks for at most 50 ids per request and nothing at all for none" do
      ids = (1..51).map { |n| "Q#{n}" }
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities")).to_return(json_response({entities: {}}.to_json))

      @client.entities(ids)
      @client.entities([])

      assert_requested stub, times: 2
    end

    test "search asks for English items, ten at most, and returns id, label and description" do
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "wbsearchentities", search: "Leo Tolstoy", language: "en", uselang: "en", type: "item", limit: "10"))
        .to_return(json_response(fixture("wbsearchentities_leo_tolstoy.json")))

      hits = @client.search("Leo Tolstoy")

      assert_requested stub
      assert_equal "Q7243", hits.first["id"]
      assert_equal "Leo Tolstoy", hits.first["label"]
      assert hits.all? { |hit| hit.keys.sort == %w[description id label] }
    end

    test "by_statements ORs every pair into one haswbstatement search and returns item ids" do
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "query", list: "search", srsearch: "haswbstatement:P648=OL26783A|P214=96987389", srnamespace: "0"))
        .to_return(json_response(fixture("haswbstatement_tolstoy.json")))

      ids = @client.by_statements([["P648", "OL26783A"], ["P214", "96987389"]])

      assert_requested stub
      assert_includes ids, "Q7243"
    end

    test "by_statements drops values that would break the search syntax, and sends nothing when none remain" do
      stub = stub_request(:get, API).with(query: hash_including(action: "query"))

      assert_equal [], @client.by_statements([["P213", "0000 0001"], ["P648", "OL1A\" OR"]])
      assert_equal [], @client.by_statements([])
      assert_not_requested stub
    end

    test "works posts one SPARQL query for every item and groups English titles per item" do
      stub = stub_request(:post, SPARQL)
        .with { |request| sparql_query(request).include?("wd:Q7243") && sparql_query(request).include?("wd:Q13442814") }
        .to_return(json_response(fixture("sparql_works_Q7243.json")))

      works = @client.works(["Q7243"])

      assert_requested stub
      assert_includes works["Q7243"], "War and Peace"
      assert_equal works["Q7243"].uniq, works["Q7243"]
      assert_equal({}, @client.works([]))
    end

    test "country_codes returns the ISO code and English label, and caches each country" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      stub = stub_request(:post, SPARQL).to_return(json_response(fixture("sparql_country_codes.json")))

      codes = @client.country_codes(["Q30", "Q34266"])
      again = @client.country_codes(["Q30", "Q34266"])

      assert_equal "US", codes.dig("Q30", "code")
      assert_nil codes.dig("Q34266", "code")
      assert_equal "Russian Empire", codes.dig("Q34266", "label")
      assert_equal codes, again
      assert_requested stub, times: 1
    end

    test "country_codes ignores a code that is not two capital letters" do
      body = {results: {bindings: [
        {"country" => {"value" => "http://www.wikidata.org/entity/Q1"}, "code" => {"value" => "http://www.wikidata.org/.well-known/genid/abc"}, "countryLabel" => {"value" => "Somewhere"}}
      ]}}.to_json
      stub_request(:post, SPARQL).to_return(json_response(body))

      assert_nil @client.country_codes(["Q1"]).dig("Q1", "code")
    end

    test "labels reads English labels with wbgetentities and caches them" do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      body = {entities: {"Q36180" => {"id" => "Q36180", "labels" => {"en" => {"language" => "en", "value" => "writer"}}}}}.to_json
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q36180", props: "labels", languages: "en"))
        .to_return(json_response(body))

      assert_equal({"Q36180" => "writer"}, @client.labels(["Q36180"]))
      assert_equal({"Q36180" => "writer"}, @client.labels(["Q36180"]))
      assert_requested stub, times: 1
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/wikidata/client_test.rb`
Expected: `NameError: uninitialized constant Wikidata::Client`.

- [ ] **Step 4: Implement**

`app/lib/wikidata/client.rb`:

```ruby
# frozen_string_literal: true

module Wikidata
  # The Wikidata operations the author steps use (spec §4), over the paced
  # Wikimedia::Http. Country and label lookups are cached for 30 days: they
  # repeat across nearly every author, and a country entity fetched whole
  # can be megabytes.
  class Client
    API_URL = "https://www.wikidata.org/w/api.php"
    SPARQL_URL = "https://query.wikidata.org/sparql"
    MAX_IDS = 50
    SEARCH_LIMIT = 10
    STATEMENT_LIMIT = 10
    WORKS_ROW_LIMIT = 5000
    CACHE_TTL = 30.days
    ITEM_ID = /\AQ\d+\z/
    ISO_CODE = /\A[A-Z]{2}\z/
    # A value is safe inside haswbstatement when it has no space or quote.
    STATEMENT_VALUE = /\A[\w.\-]+\z/

    def initialize(http: nil)
      @http = http || ::Wikimedia::Http.new
    end

    # Keyed by the id asked for: a merged item answers under the surviving
    # item's id inside the entity, so a caller can tell a redirect happened.
    def entities(ids)
      ids = Array(ids).map(&:to_s).uniq.grep(ITEM_ID)
      ids.each_slice(MAX_IDS).each_with_object({}) do |slice, found|
        data = @http.action_api(API_URL, action: "wbgetentities", ids: slice.join("|")).data
        (data["entities"] || {}).each do |requested, entity|
          found[requested] = entity if entity.is_a?(Hash) && !entity.key?("missing")
        end
      end
    end

    def search(name)
      data = @http.action_api(API_URL, action: "wbsearchentities", search: name.to_s, language: "en", uselang: "en",
        type: "item", limit: SEARCH_LIMIT).data
      Array(data["search"]).map { |hit| {"id" => hit["id"], "label" => hit["label"], "description" => hit["description"]} }
    end

    # One CirrusSearch query: `haswbstatement:P648=OL1A|P214=123` matches an
    # item carrying any of the pairs.
    def by_statements(pairs)
      safe = Array(pairs).select { |property, value| property.to_s.match?(/\AP\d+\z/) && value.to_s.match?(STATEMENT_VALUE) }
      return [] if safe.empty?

      expression = safe.map { |property, value| "#{property}=#{value}" }.join("|")
      data = @http.action_api(API_URL, action: "query", list: "search", srsearch: "haswbstatement:#{expression}",
        srnamespace: 0, srlimit: STATEMENT_LIMIT, srprop: "").data
      Array(data.dig("query", "search")).map { |hit| hit["title"] }.grep(ITEM_ID)
    end

    # Every English title of the works each item wrote (P50, read backwards)
    # or is known for (P800). Scholarly articles and editions are left out: a
    # scientist can author thousands of articles, and editions repeat titles.
    def works(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      return {} if ids.empty?

      query = <<~SPARQL
        SELECT ?author ?workLabel WHERE {
          VALUES ?author { #{ids.map { |id| "wd:#{id}" }.join(" ")} }
          { ?work wdt:P50 ?author } UNION { ?author wdt:P800 ?work }
          FILTER NOT EXISTS { ?work wdt:P31 wd:Q13442814 }
          FILTER NOT EXISTS { ?work wdt:P31 wd:Q3331189 }
          ?work rdfs:label ?workLabel . FILTER(LANG(?workLabel) = "en")
        } LIMIT #{WORKS_ROW_LIMIT}
      SPARQL
      bindings(@http.sparql(SPARQL_URL, query)).each_with_object({}) do |row, found|
        id = entity_id(row["author"])
        title = row.dig("workLabel", "value")
        next if id.nil? || title.blank?

        titles = (found[id] ||= [])
        titles << title unless titles.include?(title)
      end
    end

    def country_codes(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      cached = read_cached("country", ids)
      missing = ids - cached.keys
      return cached if missing.empty?

      query = <<~SPARQL
        SELECT ?country ?code ?countryLabel WHERE {
          VALUES ?country { #{missing.map { |id| "wd:#{id}" }.join(" ")} }
          OPTIONAL { ?country wdt:P297 ?code }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
      SPARQL
      fetched = {}
      bindings(@http.sparql(SPARQL_URL, query)).each do |row|
        id = entity_id(row["country"])
        next if id.nil?

        entry = (fetched[id] ||= {"code" => nil, "label" => row.dig("countryLabel", "value")})
        code = row.dig("code", "value").to_s
        entry["code"] ||= code if code.match?(ISO_CODE)
      end
      fetched.each { |id, entry| Rails.cache.write(cache_key("country", id), entry, expires_in: CACHE_TTL) }
      cached.merge(fetched)
    end

    def labels(item_ids)
      ids = Array(item_ids).map(&:to_s).uniq.grep(ITEM_ID)
      cached = read_cached("label", ids)
      fetched = {}
      (ids - cached.keys).each_slice(MAX_IDS) do |slice|
        data = @http.action_api(API_URL, action: "wbgetentities", ids: slice.join("|"), props: "labels", languages: "en").data
        (data["entities"] || {}).each do |requested, entity|
          label = entity.is_a?(Hash) && entity["labels"].is_a?(Hash) ? entity["labels"].dig("en", "value") : nil
          next if label.blank?

          fetched[requested] = label
          Rails.cache.write(cache_key("label", requested), label, expires_in: CACHE_TTL)
        end
      end
      cached.merge(fetched)
    end

    private

    def bindings(response) = Array(response.data.dig("results", "bindings"))

    def entity_id(binding) = binding.is_a?(Hash) ? binding["value"].to_s[%r{/entity/(Q\d+)\z}, 1] : nil

    def cache_key(kind, id) = "wikidata:#{kind}:#{id}"

    def read_cached(kind, ids)
      return {} if ids.empty?

      keys = ids.index_by { |id| cache_key(kind, id) }
      Rails.cache.read_multi(*keys.keys).transform_keys { |key| keys[key] }
    end
  end
end
```

- [ ] **Step 5: Run tests, lint, Zeitwerk**

Run: `bin/rails test test/lib/wikidata && bundle exec standardrb app/lib/wikidata test/lib/wikidata && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, "All is good!".

- [ ] **Step 6: Commit**

```bash
git add app/lib/wikidata/client.rb test/lib/wikidata/client_test.rb test/fixtures/files/wikidata
git commit -m "Wikidata client: entities, search, haswbstatement bridge, works, cached country codes and labels

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `Wikipedia::Client` and `Wikipedia::Lead`

**Files:**
- Create: `app/lib/wikipedia/lead.rb`, `app/lib/wikipedia/client.rb`
- Create fixtures (Step 1): `test/fixtures/files/wikipedia/lead_leo_tolstoy.json`, `lead_john_smith.json`
- Test: `test/lib/wikipedia/client_test.rb`, `test/lib/wikipedia/lead_test.rb`

**Interfaces:**
- Consumes: `Wikimedia::Http#action_api` (Task 1).
- Produces:
  - `Wikipedia::Client.new(http: nil)#lead(language:, title:) → Wikipedia::Lead` or nil. Raises `ArgumentError` for a bad language or blank title.
  - `Wikipedia::Lead::SCHEMA_VERSION` (1)
  - `Wikipedia::Lead.new(language:, page_id:, title:, url:, extract:, wikibase_item:, disambiguation:, raw: nil)`, with a reader for each keyword
  - `#disambiguation?`, `#source_id` (`"en:18622119"`), `#to_payload` (string keys, no raw), `.from_payload(payload)`

- [ ] **Step 1: Save trimmed real responses**

Scratch script `tmp/fetch_wikipedia_fixtures.rb` (not committed):

```ruby
require "net/http"
require "json"
require "uri"
require "fileutils"

FileUtils.mkdir_p("test/fixtures/files/wikipedia")
{"Leo Tolstoy" => "lead_leo_tolstoy.json", "John Smith" => "lead_john_smith.json"}.each do |title, file|
  uri = URI("https://en.wikipedia.org/w/api.php")
  uri.query = URI.encode_www_form(action: "query", prop: "extracts|pageprops|info", inprop: "url", exintro: 1,
    explaintext: 1, redirects: 1, titles: title, format: "json", formatversion: 2, maxlag: 5)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "TheGreatest/1.0 (+https://thegreatestbooks.org) test fixtures"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  abort "HTTP #{response.code}" unless response.code == "200"
  data = JSON.parse(response.body)
  data["query"]["pages"].each { |page| page["extract"] = page["extract"].to_s[0, 400] }
  File.write("test/fixtures/files/wikipedia/#{file}", JSON.pretty_generate(data) + "\n")
  sleep 1
end
```

Run: `ruby tmp/fetch_wikipedia_fixtures.rb`

Values measured 2026-09-27:
- Leo Tolstoy: `pageid` 18622119, `fullurl` `https://en.wikipedia.org/wiki/Leo_Tolstoy`, `wikibase_item` Q7243, no `disambiguation` key.
- John Smith: `wikibase_item` Q245903, `pageprops.disambiguation` present.

If the file differs, the file wins; adjust the expected values.

- [ ] **Step 2: Write the failing tests**

`test/lib/wikipedia/client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class ClientTest < ActiveSupport::TestCase
    API = "https://en.wikipedia.org/w/api.php"

    def setup
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      @client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
    end

    def respond_with(name)
      stub_request(:get, API).with(query: hash_including(action: "query"))
        .to_return(status: 200, body: file_fixture("wikipedia/#{name}").read, headers: {"Content-Type" => "application/json"})
    end

    test "reads the lead, page id, canonical URL and Wikidata item of one exact title" do
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "query", prop: "extracts|pageprops|info", inprop: "url", exintro: "1",
          explaintext: "1", redirects: "1", titles: "Leo Tolstoy"))
        .to_return(status: 200, body: file_fixture("wikipedia/lead_leo_tolstoy.json").read)

      lead = @client.lead(language: "en", title: "Leo Tolstoy")

      assert_requested stub
      assert_equal [18622119, "Leo Tolstoy", "https://en.wikipedia.org/wiki/Leo_Tolstoy", "Q7243"],
        [lead.page_id, lead.title, lead.url, lead.wikibase_item]
      assert_not lead.disambiguation?
      assert_match(/Tolstoy/, lead.extract)
      assert_equal "en:18622119", lead.source_id
      assert_includes lead.raw, "Leo_Tolstoy"
    end

    test "flags a disambiguation page" do
      respond_with("lead_john_smith.json")

      assert @client.lead(language: "en", title: "John Smith").disambiguation?
    end

    test "returns nil for a title with no page" do
      body = {batchcomplete: true, query: {pages: [{ns: 0, title: "No Such Page Here", missing: true}]}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "query")).to_return(status: 200, body: body)

      assert_nil @client.lead(language: "en", title: "No Such Page Here")
    end

    test "refuses a malformed language or a blank title without calling out" do
      stub = stub_request(:get, /wikipedia\.org/)

      assert_raises(ArgumentError) { @client.lead(language: "evil.com/x?", title: "Leo Tolstoy") }
      assert_raises(ArgumentError) { @client.lead(language: "en", title: " ") }
      assert_not_requested stub
    end

    test "has no search method" do
      assert_not Client.public_method_defined?(:search)
    end
  end
end
```

`test/lib/wikipedia/lead_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class LeadTest < ActiveSupport::TestCase
    def lead
      Lead.new(language: "en", page_id: 1, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
        extract: "Count Lev…", wikibase_item: "Q7243", disambiguation: false, raw: "{}")
    end

    test "round-trips through its payload, without the raw body" do
      payload = lead.to_payload
      copy = Lead.from_payload(payload)

      assert_not payload.key?("raw")
      assert_equal [lead.source_id, lead.url, lead.wikibase_item, false], [copy.source_id, copy.url, copy.wikibase_item, copy.disambiguation?]
      assert_nil copy.raw
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/wikipedia`
Expected: `NameError: uninitialized constant Wikipedia::Client` (and `Wikipedia::Lead`).

- [ ] **Step 4: Implement**

`app/lib/wikipedia/lead.rb`:

```ruby
# frozen_string_literal: true

module Wikipedia
  # One article's plain-text lead, as Wikipedia::Client read it. The text is
  # CC BY-SA: evidence for the AI step, never shown on the site.
  class Lead
    SCHEMA_VERSION = 1
    FIELDS = %i[language page_id title url extract wikibase_item disambiguation].freeze

    attr_reader :language, :page_id, :title, :url, :extract, :wikibase_item, :raw

    def self.from_payload(payload)
      values = payload.to_h.stringify_keys
      new(**FIELDS.to_h { |field| [field, values[field.to_s]] })
    end

    def initialize(language:, page_id:, title:, url:, extract:, wikibase_item:, disambiguation:, raw: nil)
      @language = language
      @page_id = page_id
      @title = title
      @url = url
      @extract = extract
      @wikibase_item = wikibase_item
      @disambiguation = disambiguation == true
      @raw = raw
    end

    def disambiguation? = @disambiguation

    # Page ids survive renames, so a stored lead is keyed by one.
    def source_id = "#{language}:#{page_id}"

    def to_payload
      {
        "language" => language, "page_id" => page_id, "title" => title, "url" => url,
        "extract" => extract, "wikibase_item" => wikibase_item, "disambiguation" => disambiguation?
      }
    end
  end
end
```

`app/lib/wikipedia/client.rb`:

```ruby
# frozen_string_literal: true

module Wikipedia
  # Reads one article's lead by exact title, following redirects. There is
  # no search method, on purpose (spec §4): the legacy app searched
  # Wikipedia for "<name> Author" and attached the wrong page to one author
  # in six. An article is only ever reached as a Wikidata item's sitelink.
  class Client
    URL = "https://%s.wikipedia.org/w/api.php"
    LANGUAGE = /\A[a-z]{2,3}(-[a-z]+)*\z/

    def initialize(http: nil)
      @http = http || ::Wikimedia::Http.new
    end

    # nil when no page has this title.
    def lead(language:, title:)
      raise ArgumentError, "Invalid Wikipedia language #{language.inspect}" unless language.to_s.match?(LANGUAGE)
      raise ArgumentError, "Title cannot be blank" if title.to_s.strip.empty?

      response = @http.action_api(format(URL, language),
        action: "query", prop: "extracts|pageprops|info", inprop: "url",
        exintro: 1, explaintext: 1, redirects: 1, titles: title)
      page = Array(response.data.dig("query", "pages")).first
      return nil if !page.is_a?(Hash) || page["missing"] || page["invalid"]

      pageprops = page["pageprops"].is_a?(Hash) ? page["pageprops"] : {}
      Lead.new(
        language: language.to_s, page_id: page["pageid"], title: page["title"], url: page["fullurl"],
        extract: page["extract"].to_s, wikibase_item: pageprops["wikibase_item"],
        disambiguation: pageprops.key?("disambiguation"), raw: response.body
      )
    end
  end
end
```

- [ ] **Step 5: Run tests, lint, Zeitwerk**

Run: `bin/rails test test/lib/wikipedia && bundle exec standardrb app/lib/wikipedia test/lib/wikipedia && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, "All is good!".

- [ ] **Step 6: Commit**

```bash
git add app/lib/wikipedia test/lib/wikipedia test/fixtures/files/wikipedia
git commit -m "Wikipedia client: one exact-title lead with its Wikidata item; no search method

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `books_author_countries`, associations, merger

**Files:**
- Create: via `bin/rails generate model Books::AuthorCountry author:references country:references` (migration, model, test, fixture)
- Modify: `app/models/books/author.rb`, `app/models/books/country.rb`, `app/lib/books/author/merger.rb`
- Test: `test/models/books/author_country_test.rb`, `test/lib/books/author/merger_test.rb` (extend)

**Interfaces:**
- Produces:
  - `Books::AuthorCountry(author_id, country_id)`, unique on the pair
  - `Books::Author#author_countries`, `#countries`
  - `Books::Country#author_countries`
  - `Books::Author::Merger` carries `author_countries` to the target (`stats[:author_countries]`)

- [ ] **Step 1: Generate, then fix the migration's foreign keys and add the unique index**

Run: `bin/rails generate model Books::AuthorCountry author:references country:references`

Edit the generated `db/migrate/*_create_books_author_countries.rb` to exactly:

```ruby
class CreateBooksAuthorCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_author_countries do |t|
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.references :country, null: false, foreign_key: {to_table: :books_countries}

      t.timestamps
    end
    add_index :books_author_countries, [:author_id, :country_id], unique: true
  end
end
```

Keep whatever `Migration[x.y]` version the generator wrote. Replace the generated fixture file `test/fixtures/books/author_countries.yml` with a comment only, because its generated rows reference fixtures named `one` that do not exist:

```yaml
# Rows are created in tests; no shared fixtures.
```

Run: `bin/rails db:migrate`. Diff `db/schema.rb` and keep only the version bump, the `books_author_countries` table and its two foreign keys. Then run `RAILS_ENV=test bin/rails db:test:prepare`.

- [ ] **Step 2: Write the failing tests**

Replace `test/models/books/author_country_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class AuthorCountryTest < ActiveSupport::TestCase
    test "links an author to a country once" do
      author = books_authors(:tolstoy)
      country = books_countries(:french)
      ::Books::AuthorCountry.create!(author: author, country: country)

      assert_equal [country], author.reload.countries.to_a
      assert_not ::Books::AuthorCountry.new(author: author, country: country).valid?
    end

    test "is removed with its author and with its country" do
      author = books_authors(:king)
      country = books_countries(:japanese)
      ::Books::AuthorCountry.create!(author: author, country: country)

      assert_difference -> { ::Books::AuthorCountry.count }, -1 do
        country.destroy!
      end
    end
  end
end
```

Add to `test/lib/books/author/merger_test.rb`, next to the category tests. Read the file's setup first; it names the source and target authors (`@source`, `@target` or similar). Use its own names:

```ruby
      test "carries the source's countries to the target" do
        country = ::Books::Country.create!(name: "Merger Test Nation")
        ::Books::AuthorCountry.create!(author: @source, country: country)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?
        assert_equal [country.id], @target.reload.author_countries.pluck(:country_id)
      end

      test "does not duplicate a country both authors share" do
        country = ::Books::Country.create!(name: "Shared Test Nation")
        ::Books::AuthorCountry.create!(author: @source, country: country)
        ::Books::AuthorCountry.create!(author: @target, country: country)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal 1, @target.reload.author_countries.count
      end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/models/books/author_country_test.rb test/lib/books/author/merger_test.rb`
Expected: failures on `undefined method 'countries'` and on the merger tests (the target has no countries).

- [ ] **Step 4: Implement**

`app/models/books/author_country.rb` (replace the generated body; keep the annotation block the generator or annotate_rb writes):

```ruby
module Books
  class AuthorCountry < ApplicationRecord
    belongs_to :author, class_name: "Books::Author"
    belongs_to :country, class_name: "Books::Country"

    validates :country_id, uniqueness: {scope: :author_id}
  end
end
```

In `app/models/books/author.rb`, after `has_many :books, through: :book_authors, …`:

```ruby
  has_many :author_countries, class_name: "Books::AuthorCountry", dependent: :destroy
  has_many :countries, through: :author_countries, class_name: "Books::Country"
```

In `app/models/books/country.rb`, after `has_many :books, …`:

```ruby
    has_many :author_countries, class_name: "Books::AuthorCountry", dependent: :destroy
```

In `app/lib/books/author/merger.rb`, add `merge_author_countries` to `merge_all_associations`, right after `merge_category_items`, and define it next to `merge_category_items`:

```ruby
      def merge_author_countries
        count = 0
        source_author.author_countries.find_each do |author_country|
          target_author.author_countries.find_or_create_by!(country_id: author_country.country_id)
          count += 1
        end
        @stats[:author_countries] = count
      end
```

- [ ] **Step 5: Run tests and lint**

Run: `bin/rails test test/models/books test/lib/books/author && bundle exec standardrb app/models/books app/lib/books/author test/models/books test/lib/books/author`
Expected: all pass, no offenses.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/*_create_books_author_countries.rb db/schema.rb app/models/books/author_country.rb app/models/books/author.rb app/models/books/country.rb app/lib/books/author/merger.rb test/models/books/author_country_test.rb test/fixtures/books/author_countries.yml test/lib/books/author/merger_test.rb
git commit -m "books_author_countries: author nationality as a join to Books::Country; the merger carries it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `Services::Books::CountryLookup`; `ApplyBookFacts` uses it

**Files:**
- Create: `app/lib/services/books/country_lookup.rb`
- Modify: `app/lib/services/books/apply_book_facts.rb` (`apply_origin_countries`, remove `find_country`)
- Test: `test/lib/services/books/country_lookup_test.rb`; extend `test/lib/services/books/apply_book_facts_test.rb`

**Interfaces:**
- Consumes: `Wikidata::Client#country_codes(ids)` (Task 4), called only for ids missing from the historical map.
- Produces:
  - `Services::Books::CountryLookup::Result(countries: [Books::Country], unmatched: [String])`
  - Class methods: `.from_text(names)`, `.from_iso(codes)`, `.from_wikidata(item_ids, client: nil)`
  - `Services::Books::CountryLookup.new(client: nil)` has the same three instance methods and memoizes its name lookups (the migrator reuses one instance).
  - `from_wikidata` reports an unmatched item as `"Q33946 Czechoslovakia"` (id and label).

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/country_lookup_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class CountryLookupTest < ActiveSupport::TestCase
      def country(name) = ::Books::Country.find_by(name: name) || ::Books::Country.create!(name: name)

      test "from_text matches names case-insensitively and reports the rest" do
        french = books_countries(:french)

        result = CountryLookup.from_text(["french", "Martian", " French "])

        assert_equal [french], result.countries
        assert_equal ["Martian"], result.unmatched
      end

      test "from_text maps the duplicate spellings Books::Country already holds" do
        argentinian = country("Argentinian")
        new_zealand = country("New Zealand")
        korean = country("Korean")

        result = CountryLookup.from_text(["Argentine", "New Zealander", "South Korean"])

        assert_equal [argentinian, new_zealand, korean], result.countries
      end

      test "from_text never matches a placeholder row" do
        country("Multiple")

        result = CountryLookup.from_text(["Unknown", "Multiple"])

        assert_empty result.countries
        assert_equal ["Unknown", "Multiple"], result.unmatched
      end

      test "from_text never creates a country" do
        assert_no_difference -> { ::Books::Country.count } do
          CountryLookup.from_text(["Atlantean", "Krakatoan"])
        end
      end

      test "from_iso goes through the countries gem's nationality" do
        french = books_countries(:french)
        argentinian = country("Argentinian")
        bosnian = country("Bosnian")

        result = CountryLookup.from_iso(["fr", "AR", "BA", "ZZ"])

        assert_equal [french, argentinian, bosnian], result.countries
        assert_equal ["ZZ"], result.unmatched
      end

      test "from_wikidata uses the historical map first, without calling Wikidata for those items" do
        russian = country("Russian")
        client = mock("wikidata")
        client.expects(:country_codes).never

        result = CountryLookup.from_wikidata(["Q34266"], client: client)

        assert_equal [russian], result.countries
      end

      test "from_wikidata maps an item's ISO code, and reports an item it cannot place" do
        french = books_countries(:french)
        client = mock("wikidata")
        client.expects(:country_codes).with(["Q142", "Q33946"]).returns(
          "Q142" => {"code" => "FR", "label" => "France"},
          "Q33946" => {"code" => nil, "label" => "Czechoslovakia"}
        )

        result = CountryLookup.from_wikidata(["Q142", "Q33946"], client: client)

        assert_equal [french], result.countries
        assert_equal ["Q33946 Czechoslovakia"], result.unmatched
      end

      test "the historical map wins over an ISO code the countries gem does not know" do
        german = country("German")
        client = mock("wikidata")
        client.expects(:country_codes).never

        assert_equal [german], CountryLookup.from_wikidata(["Q16957"], client: client).countries
      end

      test "two items for one nationality give one country" do
        british = country("British")
        client = mock("wikidata")
        client.expects(:country_codes).with(["Q145"]).returns("Q145" => {"code" => "GB", "label" => "United Kingdom"})

        assert_equal [british], CountryLookup.from_wikidata(["Q145", "Q174193"], client: client).countries
      end
    end
  end
end
```

Add to `test/lib/services/books/apply_book_facts_test.rb`. Follow the file's existing way of building a book and facts; the variable names below are illustrative:

```ruby
  test "origin countries map through the country lookup's aliases" do
    argentinian = ::Books::Country.create!(name: "Argentinian")
    book = ::Books::Book.create!(title: "Alias Country Book")

    result = Services::Books::ApplyBookFacts.call(book: book, facts: {origin_countries: {value: ["Argentine"], confidence: "high"}})

    assert_equal [argentinian], book.reload.countries.to_a
    assert_equal({"value" => ["Argentine"], "applied" => true, "reason" => "filled", "unmatched" => []},
      result.data[:facts]["origin_countries"].except("confidence"))
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/country_lookup_test.rb test/lib/services/books/apply_book_facts_test.rb`
Expected: `NameError: uninitialized constant Services::Books::CountryLookup`. The alias test fails because "Argentine" is unmatched.

- [ ] **Step 3: Implement**

`app/lib/services/books/country_lookup.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Maps what a source says about nationality onto Books::Country rows, for
    # books and authors alike (spec §7). Never creates a row: the table
    # already carries junk from the legacy app's find_or_create_by!
    # ("Krakatoa", "Kaddish"), so an unknown value comes back as unmatched
    # for the caller to record.
    class CountryLookup
      Result = Struct.new(:countries, :unmatched, keyword_init: true)

      # Spellings that differ from the row Books::Country holds. The first six
      # are its own duplicate names; the rest are the countries gem's
      # nationalities (measured against our 255 rows on 2026-09-27) and the
      # two largest unmapped legacy strings.
      ALIASES = {
        "argentine" => "Argentinian", "argentinean" => "Argentinian",
        "new zealander" => "New Zealand", "persian" => "Iranian", "philippine" => "Filipino",
        "south korean" => "Korean", "saudi arabian" => "Saudi",
        "united states" => "American", "united kingdom" => "British",
        "emirian" => "Emirati", "motswana" => "Botswanan", "cape verdian" => "Cape Verdean",
        "djibouti" => "Djiboutian", "ecuadorean" => "Ecuadorian", "guinea-bissauan" => "Guinea Bissauan",
        "hong kongese" => "Hong Konger", "icelander" => "Icelandic", "kirghiz" => "Kyrgyz",
        "mosotho" => "Lesothoan", "myanmarian" => "Burmese", "maldivan" => "Maldivian",
        "slovene" => "Slovenian", "surinamer" => "Surinamese", "tadzhik" => "Tajikistani",
        "east timorese" => "Timorese", "vatican citizen" => "Vatican"
      }.freeze

      # Rows that are not nationalities.
      PLACEHOLDERS = %w[unknown multiple mulitple mixed].freeze

      # Wikidata items for states with no ISO code (or one the countries gem
      # lacks), keyed by item. Sized from 2,000 of our authors' Open Library
      # keys on 2026-09-27: 117 of 883 citizenship values had no ISO code.
      # Deliberately unmapped because the nationality is ambiguous:
      # Czechoslovakia, Cisleithania, Austrian Empire, Dutch East Indies.
      HISTORICAL = {
        "Q174193" => "British", # United Kingdom of Great Britain and Ireland
        "Q161885" => "British", # Kingdom of Great Britain
        "Q179876" => "English", # Kingdom of England
        "Q21" => "English", "Q22" => "Scottish", "Q25" => "Welsh", "Q26" => "Northern Irish",
        "Q215530" => "Irish", # Kingdom of Ireland
        "Q172579" => "Italian", # Kingdom of Italy
        "Q1747689" => "Roman", # Ancient Rome
        "Q844930" => "Greek", # Classical Athens
        "Q34266" => "Russian", # Russian Empire
        "Q2184" => "Russian", # Russian SFSR
        "Q15180" => "Soviet", # Soviet Union
        "Q28513" => "Austro-Hungarian", # Austria-Hungary
        "Q12560" => "Ottoman", # Ottoman Empire
        "Q27306" => "German", # Kingdom of Prussia
        "Q43287" => "German", # German Empire
        "Q1206012" => "German", # German Reich
        "Q41304" => "German", # Weimar Republic
        "Q7318" => "German", # Nazi Germany
        "Q713750" => "German", # West Germany
        "Q16957" => "German", # German Democratic Republic (P297 DD)
        "Q159631" => "German", # Kingdom of Württemberg
        "Q756617" => "Danish", # Kingdom of Denmark
        "Q70972" => "French", # Kingdom of France
        "Q45670" => "Portuguese", # Kingdom of Portugal
        "Q203493" => "Romanian", # Kingdom of Romania
        "Q170072" => "Dutch", # Dutch Republic
        "Q188553" => "Dutch", # Batavian Republic
        "Q129286" => "Indian", # British Raj
        "Q1775277" => "Indian", # Dominion of India
        "Q107258515" => "Iranian", # Pahlavi Iran
        "Q2526023" => "Jamaican", # Colony of Jamaica
        "Q7462" => "Chinese", "Q7313" => "Chinese", "Q9683" => "Chinese", # Song, Yuan, Tang dynasties
        "Q9903" => "Chinese", "Q8733" => "Chinese", # Ming, Qing dynasties
        "Q13426199" => "Chinese", # Republic of China (1912–1949)
        "Q191077" => "Yugoslav", # Kingdom of Yugoslavia
        "Q83286" => "Yugoslav", # SFR Yugoslavia (P297 YU)
        "Q838261" => "Yugoslav" # FR Yugoslavia (P297 YU)
      }.freeze

      def self.from_text(names) = new.from_text(names)

      def self.from_iso(codes) = new.from_iso(codes)

      def self.from_wikidata(item_ids, client: nil) = new(client: client).from_wikidata(item_ids)

      def initialize(client: nil)
        @client = client
        @rows = {}
      end

      def from_text(names)
        collect(Array(names).map { |name| name.to_s.squish }.reject(&:blank?).uniq(&:downcase)) { |name| [find(name), name] }
      end

      def from_iso(codes)
        collect(Array(codes).map { |code| code.to_s.strip.upcase }.reject(&:blank?).uniq) do |code|
          nationality = iso_nationality(code)
          [nationality && find(nationality), code]
        end
      end

      def from_wikidata(item_ids)
        ids = Array(item_ids).map(&:to_s).uniq
        rest = ids.reject { |id| HISTORICAL.key?(id) }
        codes = rest.empty? ? {} : client.country_codes(rest)
        collect(ids) do |id|
          text = HISTORICAL[id] || iso_nationality(codes.dig(id, "code"))
          [text && find(text), [id, codes.dig(id, "label")].compact.join(" ")]
        end
      end

      private

      def client
        @client ||= ::Wikidata::Client.new
      end

      # Each item yields [country or nil, how to report it when unmatched].
      def collect(items)
        countries = []
        unmatched = []
        items.each do |item|
          country, label = yield(item)
          country ? countries << country : unmatched << label
        end
        Result.new(countries: countries.uniq(&:id), unmatched: unmatched)
      end

      # "Antiguan, Barbudan" and "Bosnian, Herzegovinian": the first part names the country.
      def iso_nationality(code)
        return nil if code.blank?

        ISO3166::Country[code]&.nationality.to_s.split(",").first.to_s.strip.presence
      end

      def find(name)
        target = (ALIASES[name.downcase] || name).downcase
        return nil if PLACEHOLDERS.include?(target)
        return @rows[target] if @rows.key?(target)

        @rows[target] = ::Books::Country.where("lower(name) = ?", target).order(:id).first
      end
    end
  end
end
```

In `app/lib/services/books/apply_book_facts.rb`, replace `apply_origin_countries` and delete `find_country`:

```ruby
      def apply_origin_countries
        f = fact(:origin_countries)
        names = Array(f[:value]).map { |n| n.to_s.strip }.reject(&:blank?).uniq(&:downcase)
        return record(:origin_countries, f, applied: false, reason: "null", value: [], unmatched: []) if names.empty?
        return record(:origin_countries, f, applied: false, reason: "already_set", unmatched: []) if book.book_countries.exists?

        lookup = CountryLookup.from_text(names)
        lookup.countries.each { |country| book.book_countries.build(country: country) }
        matched = names - lookup.unmatched

        if lookup.countries.any?
          record(:origin_countries, f, applied: true, reason: "filled", value: matched, unmatched: lookup.unmatched)
        else
          record(:origin_countries, f, applied: false, reason: "no_match", unmatched: lookup.unmatched)
        end
      end
```

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/books && bundle exec standardrb app/lib/services/books test/lib/services/books`
Expected: all pass, including every existing `ApplyBookFacts` origin-country test. No offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/country_lookup.rb app/lib/services/books/apply_book_facts.rb test/lib/services/books/country_lookup_test.rb test/lib/services/books/apply_book_facts_test.rb
git commit -m "CountryLookup: text, ISO and Wikidata paths onto Books::Country, never creating a row; ApplyBookFacts uses it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Legacy nationality migrator (`data_migration:author_countries`)

**Files:**
- Create: `app/lib/services/books_migration/author_country_migrator.rb`
- Modify: `app/lib/services/books_migration/bulk_upsert_migrator.rb` (merge `extra_result_data`), `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/author_country_migrator_test.rb`

**Interfaces:**
- Consumes: `Services::Books::CountryLookup.new#from_text` (Task 7), `Books::AuthorCountry` and its unique index `index_books_author_countries_on_author_id_and_country_id` (Task 6).
- Produces: `Services::BooksMigration::AuthorCountryMigrator.call` returns `{success: true, data: {model: "Books::AuthorCountry", count:, unmapped: {String => author count} (largest first), missing_authors: Integer}}`. The rake task is `data_migration:author_countries`, inside `data_migration:all` right after `:countries`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books_migration/author_country_migrator_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::AuthorCountryMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    migrator = Services::BooksMigration::AuthorCountryMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  def country(name) = ::Books::Country.find_by(name: name) || ::Books::Country.create!(name: name)

  def countries_of(author) = author.reload.countries.pluck(:name).sort

  test "links an author to the country its nationality names" do
    country("Russian")
    tolstoy = books_authors(:tolstoy)

    result = run_migrator([{"id" => tolstoy.id, "nationality_text" => "Russian"}])

    assert result[:success], result[:error]
    assert_equal "Books::AuthorCountry", result[:data][:model]
    assert_equal ["Russian"], countries_of(tolstoy)
  end

  test "splits compounds on hyphens and slashes" do
    country("Russian")
    country("American")
    country("French")
    king = books_authors(:king)
    garnett = books_authors(:garnett)

    run_migrator([
      {"id" => king.id, "nationality_text" => "Russian-American"},
      {"id" => garnett.id, "nationality_text" => "French/American"}
    ])

    assert_equal ["American", "Russian"], countries_of(king)
    assert_equal ["American", "French"], countries_of(garnett)
  end

  test "keeps Austro-Hungarian whole, even inside a compound" do
    country("Austro-Hungarian")
    country("American")
    king = books_authors(:king)

    result = run_migrator([{"id" => king.id, "nationality_text" => "Austro-Hungarian-American"}])

    assert_equal ["American", "Austro-Hungarian"], countries_of(king)
    assert_empty result[:data][:unmapped]
  end

  test "maps aliases through the country lookup" do
    country("Argentinian")
    king = books_authors(:king)

    run_migrator([{"id" => king.id, "nationality_text" => "Argentine"}])

    assert_equal ["Argentinian"], countries_of(king)
  end

  test "reports unmapped strings with their author counts, largest first, and never creates a country" do
    country("Russian")
    rows = [
      {"id" => books_authors(:king).id, "nationality_text" => "Martian"},
      {"id" => books_authors(:garnett).id, "nationality_text" => "Martian"},
      {"id" => books_authors(:tolstoy).id, "nationality_text" => "Russian-Venusian"}
    ]

    result = assert_no_difference(-> { ::Books::Country.count }) { run_migrator(rows) }

    assert_equal({"Martian" => 2, "Venusian" => 1}, result[:data][:unmapped])
    assert_equal [["Martian", 2], ["Venusian", 1]], result[:data][:unmapped].to_a
  end

  test "skips a legacy author that no longer exists and counts it" do
    country("Russian")

    result = run_migrator([{"id" => 999_999_999, "nationality_text" => "Russian"}])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:missing_authors]
    assert_equal 0, ::Books::AuthorCountry.count
  end

  test "is idempotent" do
    country("Russian")
    rows = [{"id" => books_authors(:tolstoy).id, "nationality_text" => "Russian"}]
    run_migrator(rows)

    assert_no_difference(-> { ::Books::AuthorCountry.count }) { run_migrator(rows) }
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/author_country_migrator_test.rb`
Expected: `NameError: uninitialized constant Services::BooksMigration::AuthorCountryMigrator`.

- [ ] **Step 3: Implement**

In `app/lib/services/books_migration/bulk_upsert_migrator.rb`, change the success line in `call` to:

```ruby
        {success: true, data: {model: model_key, count: @count}.merge(extra_result_data)}
```

`app/lib/services/books_migration/author_country_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy authors.nationality_text -> books_author_countries (spec §7).
    # The legacy app used author nationality to decide a book's country, and
    # 33,678 authors carry one of 655 strings. Compounds split on "-" and
    # "/" ("Russian-American" -> Russian + American) except the names in
    # KEEP_WHOLE; each part goes through CountryLookup.from_text, which never
    # creates a country. Unmapped parts are reported with their author
    # counts (375 authors, 1.1%, measured 2026-09-27). Authors ids are
    # preserved by AuthorMigrator; one missing here (merged away in this
    # database) is skipped and counted. A repeating step: production books
    # data is truncated and migrated again before launch.
    class AuthorCountryMigrator < BulkUpsertMigrator
      KEEP_WHOLE = ["Austro-Hungarian"].freeze
      SEPARATORS = %r{[-/]}

      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::AuthorCountry"
      end

      def target_model
        ::Books::AuthorCountry
      end

      def unique_by
        :index_books_author_countries_on_author_id_and_country_id
      end

      def legacy_each(&block)
        legacy_model.where.not(nationality_text: [nil, ""]).select(:id, :nationality_text)
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def preload_context
        @author_ids = ::Books::Author.pluck(:id).to_set
        @lookup = ::Services::Books::CountryLookup.new
        @unmapped = Hash.new(0)
        @missing_authors = 0
        @seen = Set.new
      end

      def build_rows(attrs)
        author_id = attrs["id"]
        unless @author_ids.include?(author_id)
          @missing_authors += 1
          return []
        end

        parts(attrs["nationality_text"]).filter_map do |part|
          country = @lookup.from_text([part]).countries.first
          if country.nil?
            @unmapped[part] += 1
            next
          end

          key = [author_id, country.id]
          next if @seen.include?(key)

          @seen << key
          {author_id: author_id, country_id: country.id}
        end
      end

      # Protect each keep-whole name with a placeholder before splitting.
      def parts(text)
        value = text.to_s.squish
        KEEP_WHOLE.each_with_index { |whole, index| value = value.gsub(/#{Regexp.escape(whole)}/i, "\u0001#{index}\u0001") }
        value.split(SEPARATORS).map { |part| part.gsub(/\u0001(\d+)\u0001/) { KEEP_WHOLE[$1.to_i] }.squish }.reject(&:blank?)
      end

      def extra_result_data
        {unmapped: @unmapped.sort_by { |part, count| [-count, part] }.to_h, missing_authors: @missing_authors}
      end
    end
  end
end
```

In `lib/tasks/data_migration.rake`, add after the `countries` task:

```ruby
  desc "Map legacy author nationality_text onto books_author_countries (prints unmapped strings)"
  task author_countries: :environment do
    pp Services::BooksMigration::AuthorCountryMigrator.call
  end
```

In the `all` task's list, change `:book_type_categories, :countries,` to `:book_type_categories, :countries, :author_countries,`.

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/books_migration && bundle exec standardrb app/lib/services/books_migration lib/tasks/data_migration.rake test/lib/services/books_migration`
Expected: all pass, including every existing migrator test. No offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/author_country_migrator.rb app/lib/services/books_migration/bulk_upsert_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/author_country_migrator_test.rb
git commit -m "data_migration:author_countries: legacy nationality strings onto books_author_countries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `SelectExternalRecordTask`

**Files:**
- Create: `app/lib/services/ai/tasks/matching/select_external_record_task.rb`
- Test: `test/lib/services/ai/tasks/matching/select_external_record_task_test.rb`

**Interfaces:**
- Consumes: `Services::Ai::Tasks::Matching::SelectCandidateTask` (its `ResponseSchema`, role, validation, `process_and_persist`).
- Produces: `SelectExternalRecordTask.new(source_name:, entity_noun:, query_line:, candidate_lines:, parent: nil, guidance: "", provider: nil, model: nil)`. Its `#call` returns a `Services::Ai::Result` whose `data` is `{selected_index: Integer 0..n, confidence: "high"|"medium"|"low", reasoning: String, same_entity_groups: [[Integer]]}`.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Matching
        class SelectExternalRecordTaskTest < ActiveSupport::TestCase
          def setup
            @task = SelectExternalRecordTask.new(
              source_name: "Wikidata", entity_noun: "author",
              query_line: "Leo Tolstoy | 1828–1910 | wrote: War and Peace",
              candidate_lines: ["Leo Tolstoy | Russian writer | 1828–1910 | wikidata Q7243", "Lev Tolstoy | 1984 film | wikidata Q4256164"],
              guidance: "Our author wrote the books listed."
            )
          end

          test "is a select-one-or-none task on the fast role with the shared response schema" do
            assert_operator SelectExternalRecordTask, :<, SelectCandidateTask
            assert_equal :fast, @task.send(:task_role)
            assert_equal SelectCandidateTask::ResponseSchema, @task.send(:response_schema)
          end

          test "system message is about linking to the source, prefers no link to a wrong one, and carries the guidance" do
            message = @task.send(:system_message)

            assert_includes message, "Wikidata"
            assert_includes message, "No link is better than a wrong link"
            assert_includes message, "A shared name alone is not enough"
            assert_includes message, "year conflict"
            assert_includes message, "Our author wrote the books listed."
            assert_not_includes message, "already exists in a catalog"
          end

          test "user prompt numbers the records from 1 and asks for 0 when none match" do
            prompt = @task.send(:user_prompt)

            assert_includes prompt, "Our author: Leo Tolstoy | 1828–1910 | wrote: War and Peace"
            assert_includes prompt, "Wikidata records:"
            assert_includes prompt, "1. Leo Tolstoy | Russian writer"
            assert_includes prompt, "2. Lev Tolstoy | 1984 film"
            assert_includes prompt, "0 for none"
          end

          test "validates the selection against the number of records" do
            result = @task.send(:process_and_persist, {parsed: {selected_index: 3, confidence: "high", reasoning: "x", same_entity_groups: []}})

            assert_not result.success?
            assert_match(/outside 0..2/, result.error)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/services/ai/tasks/matching/select_external_record_task_test.rb`
Expected: `NameError: uninitialized constant …SelectExternalRecordTask`.

- [ ] **Step 3: Implement**

```ruby
module Services
  module Ai
    module Tasks
      module Matching
        # Which record in an external source describes one of ours, or none
        # (spec §5.2). The same "select one or none" call as
        # SelectCandidateTask, with its schema, role and validation, but
        # worded for linking rather than de-duplicating: every candidate is
        # external, and no link is better than a wrong link.
        class SelectExternalRecordTask < SelectCandidateTask
          attr_reader :source_name

          def initialize(source_name:, entity_noun:, query_line:, candidate_lines:, parent: nil, guidance: "", provider: nil, model: nil)
            @source_name = source_name
            super(entity_noun: entity_noun, query_line: query_line, candidate_lines: candidate_lines,
              parent: parent, guidance: guidance, provider: provider, model: model)
          end

          private

          def system_message
            <<~SYSTEM
              You link one #{entity_noun} in our catalog to the record in #{source_name} that describes the same #{entity_noun}, or to none.
              You are given our #{entity_noun} and a numbered list of #{source_name} records.

              Select the one record that describes our #{entity_noun}, or 0 if none does.
              - Select 0 unless the evidence ties the record to ours: matching works, matching life dates, or a shared identifier. A shared name alone is not enough.
              - No link is better than a wrong link. When two records fit equally well, select 0.
              - A record marked "shares <identifier>" carries the same identifier as our #{entity_noun}. Treat that as strong evidence, not proof.
              - A record marked "year conflict" has a birth or death year more than one year away from ours.
              - Two records may describe the same #{entity_noun} (duplicates in #{source_name}). Report every such group in same_entity_groups, as lists of record numbers.
              #{guidance}
              Confidence is "high" when the evidence is unambiguous, "medium" when one detail is missing or slightly off, and "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Our #{entity_noun}: #{query_line}", "", "#{source_name} records:"]
            candidate_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with selected_index (the record number, or 0 for none), confidence, reasoning, and same_entity_groups."
            lines.join("\n")
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/ai/tasks/matching && bundle exec standardrb app/lib/services/ai/tasks/matching test/lib/services/ai/tasks/matching`
Expected: all pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/ai/tasks/matching/select_external_record_task.rb test/lib/services/ai/tasks/matching/select_external_record_task_test.rb
git commit -m "SelectExternalRecordTask: select-one-or-none worded for linking to an external source

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: `Services::Books::Authors::ResolveWikidata`

**Files:**
- Create: `app/lib/services/books/authors/resolve_wikidata.rb`
- Create: `test/support/fake_wikidata_client.rb` and require it from `test/test_helper.rb`
- Test: `test/lib/services/books/authors/resolve_wikidata_test.rb`

**Interfaces:**
- Consumes:
  - `Wikidata::Client`: `#entities`, `#by_statements`, `#search`, `#works`, `#labels` (Task 4)
  - `Wikidata::Distiller.call`, `Wikidata::Entity` (Task 3)
  - `Services::ExternalRecords::Store.find_all` and `.write` (Task 2)
  - `SelectExternalRecordTask` (Task 9)
- Produces:
  - `Services::Books::Authors::ResolveWikidata.call(author:, refresh: false, client: nil) → Result`
  - `data` keys: `outcome:` (`:matched`, `:unmatched` or `:failed`), `entity:` (a `Wikidata::Entity` or nil), `record:` (an `ExternalRecord` or nil), `decision:` (a `MatchDecision`), `reason:` (String), `redirected_ids:` (the requested ids Wikidata merged into the chosen item, else `[]`)
  - The decision records:
    - `finder` `"Services::Books::Authors::ResolveWikidata"`, `subject` the author, `record` nil
    - `candidates` (persons in AI order, then dropped non-persons) as `external_source: "wikidata"` snapshots
    - `selected_index` (1-based into `candidates`)
    - `decided_by`: `identifier`, `rule`, `ai` or `fallback`
    - `needs_review` on a `fallback`, `medium` or `low` decision
  - Test fakes `FakeWikidataClient` and `FakeWikipediaClient`

- [ ] **Step 1: Add the test fakes**

`test/support/fake_wikidata_client.rb`:

```ruby
# frozen_string_literal: true

# Stand-ins for Wikidata::Client and Wikipedia::Client with canned answers.
# Each records its calls so a test can assert what was (not) asked.
class FakeWikidataClient
  attr_reader :calls

  # entities: requested id => entity Hash (see WikidataEntityBuilder)
  # searches: name => [ids]; statements: [ids]; works: id => [titles]
  def initialize(entities: {}, searches: {}, statements: [], works: {}, labels: {}, country_codes: {}, works_error: nil)
    @entities = entities
    @searches = searches
    @statements = statements
    @works = works
    @labels = labels
    @country_codes = country_codes
    @works_error = works_error
    @calls = []
  end

  def entities(ids)
    @calls << [:entities, ids]
    ids.each_with_object({}) { |id, found| found[id] = @entities[id] if @entities.key?(id) }
  end

  def search(name)
    @calls << [:search, name]
    Array(@searches[name]).map { |id| {"id" => id, "label" => nil, "description" => nil} }
  end

  def by_statements(pairs)
    @calls << [:by_statements, pairs]
    @statements
  end

  def works(ids)
    @calls << [:works, ids]
    raise @works_error if @works_error

    @works.slice(*ids)
  end

  def labels(ids)
    @calls << [:labels, ids]
    @labels.slice(*ids)
  end

  def country_codes(ids)
    @calls << [:country_codes, ids]
    @country_codes.slice(*ids)
  end

  def called?(method) = calls.any? { |call| call.first == method }
end

class FakeWikipediaClient
  attr_reader :calls

  # leads: [language, title] => Wikipedia::Lead, nil, or an exception to raise
  def initialize(leads = {})
    @leads = leads
    @calls = []
  end

  def lead(language:, title:)
    @calls << [language, title]
    value = @leads[[language, title]]
    raise value if value.is_a?(Exception)

    value
  end
end
```

Add to `test/test_helper.rb` after the builder's require:

```ruby
require_relative "support/fake_wikidata_client"
```

- [ ] **Step 2: Write the failing tests**

`test/lib/services/books/authors/resolve_wikidata_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ResolveWikidataTest < ActiveSupport::TestCase
        TOLSTOY = {label: "Leo Tolstoy", aliases: ["Lev Tolstoy"], born: 1828, died: 1910, enwiki: "Leo Tolstoy", sitelinks: 150}.freeze

        def setup
          @author = books_authors(:tolstoy) # alternate names Lev Tolstoy, Lev Nikolayevich Tolstoy; wrote War and Peace
        end

        def resolve(client, refresh: false) = ResolveWikidata.call(author: @author, refresh: refresh, client: client)

        def hold(type, value) = @author.identifiers.create!(identifier_type: type, value: value)

        def ai_selects(index, confidence: "high")
          result = Services::Ai::Result.new(success: true, data: {selected_index: index, confidence: confidence, reasoning: "Because.", same_entity_groups: []})
          task = mock("task")
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).with { |options| @ai_options = options }.returns(task)
        end

        test "a corroborated held id matches by identifier, certain, without searching" do
          hold(:books_author_wikidata_qid, "Q7243")
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal :matched, result.data[:outcome]
          assert_equal "Q7243", result.data[:entity].id
          decision = result.data[:decision]
          assert_equal ["identifier", "certain", false], [decision.decided_by, decision.confidence, decision.needs_review]
          assert_not client.called?(:search)
        end

        test "names are compared with case and diacritics folded" do
          author = ::Books::Author.create!(name: "Gabriel Garcia Marquez")
          author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q5878")
          client = FakeWikidataClient.new(entities: {"Q5878" => wikidata_entity("Q5878", label: "Gabriel García Márquez")})

          result = ResolveWikidata.call(author: author, client: client)

          assert_equal ["matched", "identifier"], [result.data[:decision].outcome, result.data[:decision].decided_by]
        end

        test "a held id that Wikidata has merged resolves to the surviving item" do
          hold(:books_author_wikidata_qid, "Q999")
          client = FakeWikidataClient.new(entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal "Q7243", result.data[:entity].id
          assert_equal "Q7243", result.data[:decision].candidates.first["external_key"]
          assert_equal ["Q999"], result.data[:redirected_ids]
        end

        test "one person reached through the author's other ids matches by identifier" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q7243"],
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, identifiers: {openlibrary: ["OL26783A"]})}
          )

          result = resolve(client)

          assert_equal [:matched, "identifier"], [result.data[:outcome], result.data[:decision].decided_by]
          assert_includes client.calls, [:by_statements, [["P648", "OL26783A"]]]
          assert_not client.called?(:search)
          evidence = result.data[:decision].candidates.first["evidence"]
          assert_equal({"type" => "books_author_openlibrary_id", "value" => "OL26783A"}, evidence["matched_identifier"])
        end

        test "two persons reached through the ids go to the AI" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q7243", "Q1"],
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY), "Q1" => wikidata_entity("Q1", label: "Leo Tolstoy")}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal "ai", result.data[:decision].decided_by
          assert_equal "Q7243", result.data[:entity].id
          assert_equal 1, result.data[:decision].selected_index
        end

        test "the only same-name person with agreeing years and a shared title matches by rule" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243", "Q4256164"]},
            entities: {
              "Q7243" => wikidata_entity("Q7243", **TOLSTOY),
              "Q4256164" => wikidata_entity("Q4256164", label: "Lev Tolstoy", types: ["Q11424"], description: "1984 film")
            },
            works: {"Q7243" => ["War and Peace", "Anna Karenina"]}
          )

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "high"], [decision.outcome, decision.decided_by, decision.confidence]
          film = decision.candidates.find { |candidate| candidate["external_key"] == "Q4256164" }
          assert_equal "not a person", film["evidence"]["dropped"]
          assert_equal ["War and Peace"], decision.candidates.first["evidence"]["matching_titles"]
        end

        test "a same-name person with no shared title goes to the AI" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          ai_selects(1, confidence: "medium")

          result = resolve(client)

          assert_equal ["ai", "medium", true], [result.data[:decision].decided_by, result.data[:decision].confidence, result.data[:decision].needs_review]
        end

        test "no person among the candidates: unmatched by rule, with no AI call" do
          non_persons = {
            "Q10" => ["Q7725634", "War and Peace (novel)"], "Q11" => ["Q277759", "Tolstoy series"],
            "Q12" => ["Q13406463", "list of works by Leo Tolstoy"], "Q13" => ["Q2198855", "Tolstoyan movement"],
            "Q14" => ["Q95074", "Leo Tolstoy (character)"]
          }
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => non_persons.keys},
            entities: non_persons.to_h { |id, (type, label)| [id, wikidata_entity(id, label: label, types: [type])] }
          )
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal [:unmatched, "unmatched", "rule"], [result.data[:outcome], decision.outcome, decision.decided_by]
          assert_equal 5, decision.candidates.size
          assert decision.candidates.all? { |candidate| candidate["evidence"]["dropped"] == "not a person" }
          assert_nil result.data[:record]
        end

        test "a same-name person from another century is never matched by rule and is shown to the AI with a year conflict" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q1"]},
            entities: {"Q1" => wikidata_entity("Q1", label: "Leo Tolstoy", born: 1650)},
            works: {"Q1" => ["War and Peace"]}
          )
          ai_selects(0)

          result = resolve(client)

          assert_equal [:unmatched, "ai"], [result.data[:outcome], result.data[:decision].decided_by]
          assert @ai_options[:candidate_lines].first.include?("year conflict")
          assert_equal true, result.data[:decision].candidates.first["evidence"]["year_conflict"]
        end

        test "a TV chef whose name differs by one letter is left to the AI, which may reject him" do
          author = ::Books::Author.create!(name: "Michael Harriot")
          client = FakeWikidataClient.new(
            searches: {"Michael Harriot" => ["Q2"]},
            entities: {"Q2" => wikidata_entity("Q2", label: "Ainsley Harriott", description: "British celebrity chef", born: 1957)}
          )
          ai_selects(0)

          result = ResolveWikidata.call(author: author, client: client)

          assert_equal [:unmatched, "ai"], [result.data[:outcome], result.data[:decision].decided_by]
        end

        test "an AI failure records a fallback decision for review and reports failed" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal :failed, result.data[:outcome]
          assert_equal ["unmatched", "fallback", true], [decision.outcome, decision.decided_by, decision.needs_review]
          assert_match(/timeout/, decision.reason)
        end

        test "a failed works query is recorded and the AI decides" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)},
            works_error: ::Wikimedia::Exceptions::HttpError.new("boom", 500)
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal ["wikidata_works"], result.data[:decision].sources_failed
          assert_equal "ai", result.data[:decision].decided_by
        end

        test "a rate limit propagates and records nothing" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          client.stubs(:works).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Wikimedia::Exceptions::RateLimited) { resolve(client) }
          end
        end

        test "stores only the chosen item, with its complete entity gzipped" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243", "Q4256164"]},
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY), "Q4256164" => wikidata_entity("Q4256164", label: "Lev Tolstoy", types: ["Q11424"])},
            works: {"Q7243" => ["War and Peace"]}
          )

          result = resolve(client)

          assert_equal ["Q7243"], ::ExternalRecord.where(source: :wikidata).pluck(:source_id)
          assert_equal result.data[:record], ::ExternalRecord.find_by!(source: :wikidata, source_id: "Q7243")
          assert_equal "Leo Tolstoy", JSON.parse(result.data[:record].raw_text).dig("labels", "en", "value")
        end

        test "reads a stored item instead of fetching it, and fetches again on refresh" do
          hold(:books_author_wikidata_qid, "Q7243")
          ::Services::ExternalRecords::Store.write(source: :wikidata, source_id: "Q7243",
            payload: ::Wikidata::Distiller.call(wikidata_entity("Q7243", **TOLSTOY)), raw: "{}", schema_version: ::Wikidata::Distiller::SCHEMA_VERSION)
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          resolve(client)
          assert_not client.calls.any? { |call| call.first == :entities && call.last.include?("Q7243") }

          resolve(client, refresh: true)
          assert_includes client.calls, [:entities, ["Q7243"]]
        end

        test "records one decision for the audit pages" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, occupations: ["Q36180"])},
            works: {"Q7243" => ["War and Peace"]}, labels: {"Q36180" => "writer"}
          )

          assert_difference(-> { ::MatchDecision.count }, 1) { resolve(client) }
          decision = ::MatchDecision.order(:id).last

          assert_equal ["Services::Books::Authors::ResolveWikidata", @author, nil], [decision.finder, decision.subject, decision.record]
          assert_equal "Leo Tolstoy", decision.query["name"]
          candidate = decision.candidates.first
          assert_equal ["wikidata", "Q7243", ["name_search"]], [candidate["external_source"], candidate["external_key"], candidate["sources"]]
          assert_equal ["Leo Tolstoy", 1828, ["writer"]], candidate["evidence"].values_at("external_title", "external_year", "occupations")
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/resolve_wikidata_test.rb`
Expected: `NameError: uninitialized constant Services::Books::Authors::ResolveWikidata`.

- [ ] **Step 4: Implement**

`app/lib/services/books/authors/resolve_wikidata.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Which Wikidata person is this author, or none (spec §5).
      #
      # Candidates come in three stages, and a stage whose rule decides ends
      # the run: the Wikidata id the author already holds (rule 1), one
      # haswbstatement query over its other identifiers (rule 2), then a name
      # search on the name and up to two alternate names. Only persons
      # (human, pseudonym, collective pseudonym) survive; their works are
      # compared with our titles; rule 3 or the AI decides. Every run records
      # one MatchDecision and stores the chosen item in external_records.
      # Applies nothing.
      class ResolveWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Candidate = Struct.new(:entity, :sources, :titles, :matching_titles, keyword_init: true)
        Verdict = Struct.new(:outcome, :candidate, :decided_by, :confidence, :reason, :ai_chat, keyword_init: true)

        ALTERNATE_SEARCHES = 2
        TITLE_LIMIT = 50
        MAX_AI_CANDIDATES = 6
        YEAR_TOLERANCE = 1
        QID = "books_author_wikidata_qid"
        BRIDGE_PROPERTIES = {
          "books_author_openlibrary_id" => "P648",
          "books_author_viaf" => "P214",
          "books_author_isni" => "P213",
          "books_author_lcnaf" => "P244"
        }.freeze
        SHARED_IDENTIFIER_KINDS = {
          "openlibrary" => "books_author_openlibrary_id",
          "viaf" => "books_author_viaf",
          "isni" => "books_author_isni",
          "lcnaf" => "books_author_lcnaf"
        }.freeze
        GUIDANCE = "Our author wrote the books listed. Select a record only when its works, its life dates or a shared " \
          "identifier tie that person to these books; a person who merely shares the name is someone else. " \
          "A pseudonym or pen-name record counts when its works match."

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client || ::Wikidata::Client.new
          @candidates = {}
          @loaded = {}
          @raw = {}
          @redirects = {}
          @sources_failed = []
        end

        def call
          record(held_stage || bridge_stage || search_stage)
        end

        private

        attr_reader :author

        # ---- stages ---------------------------------------------------------

        def held_stage
          ids = identifier_values(QID)
          return nil if ids.empty?

          gather(ids, "held_id")
          held = persons.find { |candidate| candidate.sources.include?("held_id") && corroborated?(candidate) }
          return nil unless held

          Verdict.new(outcome: :matched, candidate: held, decided_by: :identifier, confidence: :certain,
            reason: "The Wikidata id the author holds, #{held.entity.id}, is a person whose name and years agree.")
        end

        def bridge_stage
          pairs = bridge_pairs
          return nil if pairs.empty?

          gather(@client.by_statements(pairs), "id_bridge")
          bridged = persons.select { |candidate| candidate.sources.include?("id_bridge") }
          return nil unless bridged.size == 1 && corroborated?(bridged.first)

          shared = shared_identifiers(bridged.first).map { |identifier| identifier["type"] }.uniq
          Verdict.new(outcome: :matched, candidate: bridged.first, decided_by: :identifier, confidence: :certain,
            reason: "The only person carrying the author's #{shared.join(", ").presence || "identifiers"}, with agreeing name and years.")
        end

        def search_stage
          search_names.each { |name| gather(@client.search(name).map { |hit| hit["id"] }, "name_search") }
          if persons.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "No person among #{@candidates.size} Wikidata candidates.")
          end

          attach_titles
          named = persons.select { |candidate| names_agree?(candidate) && !year_conflict?(candidate) }
          if named.size == 1 && named.first.matching_titles.any?
            only = named.first
            return Verdict.new(outcome: :matched, candidate: only, decided_by: :rule, confidence: :high,
              reason: "The only person named #{author.name} with agreeing years, sharing #{only.matching_titles.size} title(s) with our books.")
          end

          ask_ai
        end

        def ask_ai
          shown = ordered_persons.first(MAX_AI_CANDIDATES)
          lines = shown.map { |candidate| describe(candidate) }
          result = ::Services::Ai::Tasks::Matching::SelectExternalRecordTask.new(
            parent: author, source_name: "Wikidata", entity_noun: "author",
            query_line: describe_author, candidate_lines: lines, guidance: GUIDANCE
          ).call
          return ai_failed(result.error, result.ai_chat) unless result.success?

          index = result.data[:selected_index]
          chosen = index.positive? ? shown[index - 1] : nil
          Verdict.new(outcome: chosen ? :matched : :unmatched, candidate: chosen, decided_by: :ai,
            confidence: result.data[:confidence].to_sym, reason: result.data[:reasoning].to_s, ai_chat: result.ai_chat)
        rescue ::Wikimedia::Exceptions::RateLimited
          raise
        rescue => e
          ai_failed("#{e.class}: #{e.message}", nil)
        end

        def ai_failed(message, chat)
          Verdict.new(outcome: :failed, candidate: nil, decided_by: :fallback, confidence: :low,
            reason: "AI selection failed: #{message}", ai_chat: chat)
        end

        # ---- gathering ------------------------------------------------------

        # Adds the entities for these ids as candidates reached by `source`.
        # A merged item arrives under the surviving id, so two requested ids
        # can land on one candidate.
        def gather(ids, source)
          load_entities(Array(ids).map(&:to_s).uniq).each do |entity|
            candidate = (@candidates[entity.id] ||= Candidate.new(entity: entity, sources: [], titles: [], matching_titles: []))
            candidate.sources |= [source]
          end
        end

        def load_entities(ids)
          wanted = ids.reject { |id| @loaded.key?(id) }
          stored = @refresh ? {} : ::Services::ExternalRecords::Store.find_all(
            source: :wikidata, source_ids: wanted, schema_version: ::Wikidata::Distiller::SCHEMA_VERSION
          )
          stored.each { |id, row| @loaded[id] = ::Wikidata::Entity.from_payload(row.payload) }
          fetch = wanted - stored.keys
          @client.entities(fetch).each do |requested, data|
            payload = ::Wikidata::Distiller.call(data)
            @raw[payload["id"]] = JSON.generate(data)
            @redirects[requested] = payload["id"] if requested != payload["id"]
            @loaded[requested] = ::Wikidata::Entity.from_payload(payload)
          end
          ids.filter_map { |id| @loaded[id] }
        end

        def persons = @candidates.values.select { |candidate| candidate.entity.person? }

        def attach_titles
          works = begin
            @client.works(persons.map { |candidate| candidate.entity.id })
          rescue ::Wikimedia::Exceptions::Error => e
            Rails.logger.warn("#{self.class.name}: works query failed for author #{author.id}: #{e.class}: #{e.message}")
            @sources_failed << "wikidata_works"
            {}
          end
          ours = our_titles.map { |title| title_key(title) }.to_set
          persons.each do |candidate|
            candidate.titles = works.fetch(candidate.entity.id, [])
            candidate.matching_titles = candidate.titles.select { |title| ours.include?(title_key(title)) }.uniq { |title| title_key(title) }
          end
        end

        # Evidence labels only: a failure leaves them out, never the run.
        def labels
          @labels ||= begin
            ids = persons.flat_map { |candidate| candidate.entity.occupation_ids + candidate.entity.citizenship_ids }.uniq
            ids.empty? ? {} : @client.labels(ids)
          rescue ::Wikimedia::Exceptions::Error => e
            Rails.logger.warn("#{self.class.name}: labels failed for author #{author.id}: #{e.class}: #{e.message}")
            {}
          end
        end

        # ---- judgements -----------------------------------------------------

        def corroborated?(candidate) = names_agree?(candidate) && !year_conflict?(candidate)

        def names_agree?(candidate)
          candidate.entity.names.any? { |name| author_name_keys.include?(name_key(name)) }
        end

        def year_conflict?(candidate)
          years_conflict?(author.birth_year, candidate.entity.birth_year) ||
            years_conflict?(author.death_year, candidate.entity.death_year)
        end

        def years_conflict?(ours, theirs)
          ours.present? && theirs.present? && (ours - theirs).abs > YEAR_TOLERANCE
        end

        def id_hit?(candidate)
          candidate.sources.intersect?(%w[held_id id_bridge]) || shared_identifiers(candidate).any?
        end

        # Identifier hits first, then shared titles, exact name, fame.
        def ordered_persons
          persons.each_with_index.sort_by do |candidate, index|
            [id_hit?(candidate) ? 0 : 1, -candidate.matching_titles.size, names_agree?(candidate) ? 0 : 1,
              -candidate.entity.sitelink_count, index]
          end.map(&:first)
        end

        def shared_identifiers(candidate)
          shared = []
          shared << {"type" => QID, "value" => candidate.entity.id} if candidate.sources.include?("held_id")
          SHARED_IDENTIFIER_KINDS.each do |kind, type|
            ours = identifier_values(type)
            candidate.entity.identifiers(kind).map { |value| value.delete(" ") }.each do |value|
              shared << {"type" => type, "value" => value} if ours.include?(value)
            end
          end
          shared
        end

        # ---- our side -------------------------------------------------------

        def identifier_values(type)
          @identifiers ||= author.identifiers.to_a
          @identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        def bridge_pairs
          BRIDGE_PROPERTIES.flat_map { |type, property| identifier_values(type).map { |value| [property, value.delete(" ")] } }.uniq
        end

        def search_names
          ([author.name] + Array(author.alternate_names)).map { |name| name.to_s.squish }.reject(&:blank?)
            .uniq { |name| name_key(name) }.first(1 + ALTERNATE_SEARCHES)
        end

        def author_name_keys
          @author_name_keys ||= ([author.name] + Array(author.alternate_names)).map { |name| name_key(name) }.compact_blank.to_set
        end

        # Up to 50: the author's books, ranked first, each with its alternate titles.
        def our_titles
          @our_titles ||= begin
            configuration = ::Books::RankingConfiguration.default_primary
            scope = author.books
            scope = if configuration
              join = ActiveRecord::Base.sanitize_sql_array([
                "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Book' " \
                "AND ranked_items.item_id = books_books.id AND ranked_items.ranking_configuration_id = ?",
                configuration.id
              ])
              scope.joins(join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), "books_books.id")
            else
              scope.order("books_books.id")
            end
            scope.limit(TITLE_LIMIT).pluck(:title, :alternate_titles)
              .flat_map { |title, alternates| [title, *Array(alternates)] }
              .compact_blank.uniq.first(TITLE_LIMIT)
          end
        end

        # Case and diacritics folded: "Gabriel Garcia Marquez" meets "Gabriel García Márquez".
        def name_key(text)
          normalized(text).unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
        end

        def title_key(text) = normalized(text).downcase

        def normalized(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
        end

        # ---- describing -----------------------------------------------------

        def describe_author
          parts = [author.name]
          alternates = Array(author.alternate_names).first(5)
          parts << "also known as #{alternates.join(", ")}" if alternates.any?
          span = lifespan(author.birth_year, author.death_year)
          parts << span if span
          parts << "wrote: #{our_titles.first(10).join("; ")}" if our_titles.any?
          countries = author.countries.map(&:name)
          parts << "countries: #{countries.join(", ")}" if countries.any?
          parts.join(" | ")
        end

        def describe(candidate)
          entity = candidate.entity
          parts = [entity.label || entity.id]
          parts << entity.description if entity.description.present?
          span = lifespan(entity.birth_year, entity.death_year)
          parts << span if span
          parts << "also known as #{entity.aliases.first(5).join(", ")}" if entity.aliases.any?
          occupations = label_list(entity.occupation_ids)
          parts << "occupations: #{occupations.first(5).join(", ")}" if occupations.any?
          citizenships = label_list(entity.citizenship_ids)
          parts << "citizenship: #{citizenships.join(", ")}" if citizenships.any?
          parts << "works matching ours: #{candidate.matching_titles.first(5).join("; ")}" if candidate.matching_titles.any?
          others = candidate.titles - candidate.matching_titles
          parts << "other works: #{others.first(5).join("; ")}" if others.any?
          parts << "English Wikipedia: #{entity.enwiki_title}" if entity.enwiki_title
          parts << "#{entity.sitelink_count} sitelinks"
          shared = shared_identifiers(candidate).map { |identifier| identifier["type"] }.uniq
          parts << "shares #{shared.join(", ")}" if shared.any?
          parts << "year conflict" if year_conflict?(candidate)
          parts << "wikidata #{entity.id}"
          parts.join(" | ")
        end

        def lifespan(birth, death)
          return nil if birth.nil? && death.nil?

          "#{birth || "?"}–#{death}"
        end

        def label_list(ids) = ids.filter_map { |id| labels[id] }

        # ---- recording ------------------------------------------------------

        def record(verdict)
          ordered = ordered_persons + (@candidates.values - persons)
          confidence = verdict.confidence
          confidence = :medium if confidence == :high && @sources_failed.any?
          decision = ::MatchDecision.create!(
            finder: self.class.name,
            subject: author,
            record: nil,
            outcome: (verdict.outcome == :matched) ? :matched : :unmatched,
            confidence: confidence,
            decided_by: verdict.decided_by,
            verify: false,
            query: author_snapshot,
            candidates: ordered.map { |candidate| snapshot(candidate) },
            selected_index: verdict.candidate && (ordered.index(verdict.candidate) + 1),
            reason: verdict.reason,
            ai_chat: verdict.ai_chat,
            sources_failed: @sources_failed,
            needs_review: verdict.decided_by == :fallback || %i[medium low].include?(confidence)
          )
          stored = (verdict.outcome == :matched) ? store(verdict.candidate.entity) : nil
          Result.new(
            success?: true,
            data: {
              outcome: verdict.outcome, entity: verdict.candidate&.entity, record: stored, decision: decision,
              reason: verdict.reason, redirected_ids: redirected_ids(verdict.candidate)
            },
            errors: []
          )
        end

        # Ids Wikidata has merged into the chosen item: an author holding one
        # holds the same person under an old id, which is not a conflict.
        def redirected_ids(candidate)
          return [] if candidate.nil?

          @redirects.select { |_requested, target| target == candidate.entity.id }.keys
        end

        def author_snapshot
          {
            "name" => author.name,
            "alternate_names" => Array(author.alternate_names).first(10),
            "birth_year" => author.birth_year,
            "death_year" => author.death_year,
            "open_library_author_key" => identifier_values("books_author_openlibrary_id"),
            "wikidata_qid" => identifier_values(QID),
            "viaf" => identifier_values("books_author_viaf"),
            "titles" => our_titles.first(10)
          }
        end

        def snapshot(candidate)
          entity = candidate.entity
          evidence = {
            "external_title" => entity.label || entity.id,
            "external_year" => entity.birth_year,
            "description" => entity.description,
            "aliases" => entity.aliases.first(10),
            "birth_year" => entity.birth_year,
            "death_year" => entity.death_year,
            "instance_of" => entity.instance_of,
            "enwiki_title" => entity.enwiki_title,
            "sitelink_count" => entity.sitelink_count
          }
          if entity.person?
            shared = shared_identifiers(candidate)
            evidence.merge!(
              "occupations" => label_list(entity.occupation_ids),
              "citizenships" => label_list(entity.citizenship_ids),
              "matching_titles" => candidate.matching_titles.first(10),
              "other_titles" => (candidate.titles - candidate.matching_titles).first(5),
              "shared_identifiers" => shared,
              "year_conflict" => year_conflict?(candidate)
            )
            evidence["matched_identifier"] = shared.first if shared.any?
          else
            evidence["dropped"] = "not a person"
          end
          {
            "record_type" => nil, "record_id" => nil,
            "external_source" => "wikidata", "external_key" => entity.id,
            "sources" => candidate.sources, "scores" => {},
            "evidence" => evidence.compact
          }
        end

        # Only the chosen item is kept (spec §3). One read from storage this
        # run is already held and has no fresh body to write.
        def store(entity)
          raw = @raw[entity.id]
          return ::ExternalRecord.find_by(source: :wikidata, source_id: entity.id) if raw.nil?

          ::Services::ExternalRecords::Store.write(source: :wikidata, source_id: entity.id, payload: entity.payload,
            raw: raw, schema_version: ::Wikidata::Distiller::SCHEMA_VERSION)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run tests and lint**

Run: `bin/rails test test/lib/services/books/authors && bundle exec standardrb app/lib/services/books/authors test/lib/services/books/authors test/support/fake_wikidata_client.rb`
Expected: all pass, no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books/authors/resolve_wikidata.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/support/fake_wikidata_client.rb test/test_helper.rb
git commit -m "ResolveWikidata: held id, identifier bridge, name search; persons only; rules then select-one-or-none

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: FinderRegistry external-link kind; Wikidata decisions on the audit pages

**Files:**
- Modify: `app/lib/data_importers/finder_registry.rb`
- Test: `test/lib/data_importers/finder_registry_test.rb`, `test/controllers/admin/books/match_decisions_controller_test.rb`

**Interfaces:**
- Consumes: the `ResolveWikidata` class name (Task 10).
- Produces:
  - `FinderRegistry::Entry` gains `kind` (nil or `:finder` means a FinderBase finder; `:external_link` is a service that links a record to an external source) and `#external_link?`, `#finder?`.
  - `entry_for_model`, `models_for` and `finders_for` consider finder entries only.
  - The entry for `"Services::Books::Authors::ResolveWikidata"` is labelled "Wikidata link" in domain `:books`. Its model is `"Books::Author"` and its query is nil. It has no merge action and no re-check.

- [ ] **Step 1: Write the failing tests**

In `test/lib/data_importers/finder_registry_test.rb`:

- In the first test, compare against `FinderRegistry::ENTRIES.select(&:finder?).map(&:finder).sort`.
- In the second test, iterate `FinderRegistry::ENTRIES.select(&:finder?)`.
- Add:

```ruby
    test "the Wikidata link entry is an external-link kind: no query, merge or re-check" do
      entry = FinderRegistry.entry("Services::Books::Authors::ResolveWikidata")

      assert entry.external_link?
      assert_not entry.finder?
      assert_equal [:books, "Books::Author", "Wikidata link"], [entry.domain, entry.model, entry.label]
      assert_respond_to entry.finder_class, :call
      assert_not entry.mergeable?
      assert_not entry.recheck?
      assert_nil entry.query
    end

    test "an external-link entry never shadows the finder for its model" do
      assert_equal "DataImporters::Books::Author::Finder", FinderRegistry.entry_for_model("Books::Author").finder
      assert_includes FinderRegistry.for_domain(:books).map(&:finder), "Services::Books::Authors::ResolveWikidata"
    end
```

The existing test "for_domain groups entries by admin domain" must still pass unchanged: `models_for` and `finders_for` count finder entries only.

In `test/controllers/admin/books/match_decisions_controller_test.rb`:

```ruby
      test "a Wikidata link decision, with no local record and only external candidates, shows, filters and refuses re-check" do
        decision = ::MatchDecision.create!(
          finder: "Services::Books::Authors::ResolveWikidata", subject: books_authors(:tolstoy), record: nil,
          outcome: :matched, confidence: :medium, decided_by: :ai, needs_review: true,
          query: {"name" => "Leo Tolstoy", "open_library_author_key" => ["OL26783A"]},
          candidates: [{
            "record_type" => nil, "record_id" => nil, "external_source" => "wikidata", "external_key" => "Q7243",
            "sources" => ["name_search"], "scores" => {},
            "evidence" => {"external_title" => "Leo Tolstoy", "external_year" => 1828, "matched_identifier" => {"type" => "books_author_openlibrary_id", "value" => "OL26783A"}}
          }],
          selected_index: 1, reason: "Works and years match."
        )
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decision_path(decision)
        assert_response :success

        get admin_books_match_decisions_path(entity: "wikidata-link")
        assert_equal [decision.id], row_ids

        post recheck_admin_books_match_decision_path(decision)
        assert_redirected_to admin_books_match_decision_path(decision)
      end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb`
Expected: `NoMethodError: finder?`, a nil entry, and `ActiveRecord::RecordNotFound` on the show (the decision is outside the domain scope).

- [ ] **Step 3: Implement**

In `app/lib/data_importers/finder_registry.rb`:

- Add `:kind` to the `Entry` members, after `:recheck`.
- Add to the struct block:

```ruby
      # A FinderBase finder answers "is this already in our catalog?". An
      # external-link entry is a service that links a record to an external
      # source (spec §5.3): its decisions are audited here too, but it has no
      # ImportQuery, merge action or re-check, and it never stands for its
      # model in entry_for_model.
      def external_link? = kind == :external_link

      def finder? = !external_link?
```

- Append to `ENTRIES`:

```ruby
      Entry.new(
        finder: "Services::Books::Authors::ResolveWikidata", domain: :books, model: "Books::Author", label: "Wikidata link",
        query: nil, preloads: [], merge_action: nil, source_field: nil, execute_action_path: nil,
        recheck: false, kind: :external_link
      )
```

- Change the lookups:

```ruby
    BY_FINDER = ENTRIES.index_by(&:finder).freeze
    BY_MODEL = ENTRIES.select(&:finder?).index_by(&:model).freeze

    class << self
      def entry(finder_name) = BY_FINDER[finder_name.to_s]

      def entry_for_model(model_name) = BY_MODEL[model_name.to_s]

      def for_domain(domain) = ENTRIES.select { |entry| entry.domain == domain.to_sym }

      def finders_for(domain) = for_domain(domain).select(&:finder?).map(&:finder)

      def models_for(domain) = for_domain(domain).select(&:finder?).map(&:model)
    end
```

- Extend the module comment's first paragraph with one sentence: "External-link entries (kind :external_link) audit a service that links a record to an external source; see Entry#external_link?."

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/data_importers test/controllers/admin && bundle exec standardrb app/lib/data_importers/finder_registry.rb test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb`
Expected: all pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/data_importers/finder_registry.rb test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb
git commit -m "FinderRegistry: external-link entries; Wikidata link decisions on the books audit pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `Services::Books::Authors::ApplyWikidata`

**Files:**
- Create: `app/lib/services/books/authors/apply_wikidata.rb`
- Test: `test/lib/services/books/authors/apply_wikidata_test.rb`

**Interfaces:**
- Consumes:
  - `Wikidata::Entity` (Task 3)
  - `Services::Books::CountryLookup.new(client:)#from_wikidata` (Task 7)
  - `Books::Author#author_countries` (Task 6)
  - `Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:, match_decision:)`
- Produces:
  - `ApplyWikidata.call(author:, entity:, decision: nil, client: nil, country_lookup: nil, redirected_ids: []) → Result`, whose `data` is `{facts: Hash, applied: [fact names], conflict: Boolean}`. `redirected_ids` comes from `ResolveWikidata`'s data (Task 10): a held id that Wikidata merged into this item is not a conflict.
  - Fact names: `wikidata_qid viaf isni lcnaf goodreads_id librarything_id openlibrary_ids birth_year death_year gender alternate_names countries`.
  - Each fact is `{"value", "applied", "reason", …extras}`.
  - Reasons: `filled`, `already_set`, `conflict`, `held_by_other`, `null`, `unknown`, `imprecise`, `disagreeing`, `bce`, `unmapped`, `no_match`, `held_qid_conflict`.
  - Saves the author when there is no conflict.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyWikidataTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Test Author Wikidata")
          @lookup = mock("country_lookup")
          @lookup.stubs(:from_wikidata).returns(::Services::Books::CountryLookup::Result.new(countries: [], unmatched: []))
        end

        def entity(**options)
          ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q42", label: "Test Author Wikidata", **options)))
        end

        def apply(entity, author: @author) = ApplyWikidata.call(author: author, entity: entity, country_lookup: @lookup)

        def held(type) = @author.reload.identifiers.where(identifier_type: type).pluck(:value).sort

        test "stamps the item id and every identifier, one value each, every Open Library key" do
          result = apply(entity(identifiers: {viaf: ["123"], isni: ["0000 0001 2345 6789"], lcnaf: ["n79068416"],
            openlibrary: ["OL1A", "OL2A"], goodreads: ["55"], librarything: ["testauthor"]}))

          assert_equal ["Q42"], held("books_author_wikidata_qid")
          assert_equal ["123"], held("books_author_viaf")
          assert_equal ["0000000123456789"], held("books_author_isni")
          assert_equal ["n79068416"], held("books_author_lcnaf")
          assert_equal ["OL1A", "OL2A"], held("books_author_openlibrary_id")
          assert_equal ["55"], held("books_author_goodreads_id")
          assert_equal ["testauthor"], held("books_author_librarything_id")
          assert_equal ["OL1A", "OL2A"], result.data[:facts]["openlibrary_ids"]["added"]
        end

        test "a different identifier of a single-value type is a conflict, not a second value" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")

          fact = apply(entity(identifiers: {viaf: ["123"]})).data[:facts]["viaf"]

          assert_equal ["conflict", ["999"]], [fact["reason"], fact["stored"]]
          assert_equal ["999"], held("books_author_viaf")
        end

        test "an identifier another author holds is not stamped, and the pair is flagged as a duplicate" do
          other = ::Books::Author.create!(name: "Someone Else")
          other.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q42")

          result = assert_difference(-> { ::DuplicateCandidate.count }, 1) { apply(entity) }

          assert_equal "held_by_other", result.data[:facts]["wikidata_qid"]["reason"]
          assert_equal [], held("books_author_wikidata_qid")
          assert_equal "external_key_collision", ::DuplicateCandidate.last.source
        end

        test "an author holding a different Wikidata id gets nothing applied" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")

          result = apply(entity(born: 1900, identifiers: {viaf: ["123"]}))

          assert result.data[:conflict]
          assert_equal ["held_qid_conflict", ["Q1"]], result.data[:facts]["wikidata_qid"].values_at("reason", "held")
          assert_nil @author.reload.birth_year
          assert_equal [], held("books_author_viaf")
        end

        test "a held id Wikidata has merged into the item is not a conflict" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")

          result = ApplyWikidata.call(author: @author, entity: entity(born: 1900), country_lookup: @lookup, redirected_ids: ["Q1"])

          assert_not result.data[:conflict]
          assert_equal ["Q1", "Q42"], held("books_author_wikidata_qid")
          assert_equal 1900, @author.reload.birth_year
          assert_equal ["Q1"], result.data[:facts]["wikidata_qid"]["redirected_from"]
        end

        test "fills blank years; a disagreeing stored year is a recorded conflict" do
          @author.update!(death_year: 1950)

          facts = apply(entity(born: {year: 1900, precision: 11}, died: 1951)).data[:facts]

          assert_equal [1900, 1950], [@author.reload.birth_year, @author.death_year]
          assert_equal ["filled", "conflict"], [facts["birth_year"]["reason"], facts["death_year"]["reason"]]
          assert_equal 1950, facts["death_year"]["stored"]
        end

        test "a decade-precision, unknown or BCE date is recorded, never applied" do
          assert_equal "imprecise", apply(entity(born: {year: 1900, precision: 8})).data[:facts]["birth_year"]["reason"]
          assert_equal "unknown", apply(entity(born: :unknown)).data[:facts]["birth_year"]["reason"]
          assert_equal "bce", apply(entity(born: -427)).data[:facts]["birth_year"]["reason"]
          assert_nil @author.reload.birth_year
        end

        test "maps gender, fills unspecified, and records a conflict with a stored gender" do
          apply(entity(gender: ["Q1052281"]))
          assert_equal "female", @author.reload.gender

          unspecified = ::Books::Author.create!(name: "Unspecified Gender", gender: :unspecified)
          apply(entity(gender: ["Q6581097"]), author: unspecified)
          assert_equal "male", unspecified.reload.gender

          stored = ::Books::Author.create!(name: "Stored Gender", gender: :female)
          fact = apply(entity(gender: ["Q6581097"]), author: stored).data[:facts]["gender"]
          assert_equal ["conflict", "female"], [fact["reason"], stored.reload.gender]
        end

        test "an unmapped gender is recorded, not applied" do
          fact = apply(entity(gender: ["Q505371"])).data[:facts]["gender"]

          assert_equal "unmapped", fact["reason"]
          assert_nil @author.reload.gender
        end

        test "adds the label, aliases, native names and pseudonyms as alternate names, skipping its own name" do
          apply(entity(aliases: ["T. A. Wikidata", "test author wikidata"], native_names: ["Тест Автор"], pseudonyms: ["Penname"]))

          assert_equal ["T. A. Wikidata", "Тест Автор", "Penname"], @author.reload.alternate_names
        end

        test "keeps each spelling of a name with diacritics as its own alternate name" do
          author = ::Books::Author.create!(name: "Gabriel Garcia Marquez")

          apply(::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q5878", label: "Gabriel García Márquez"))), author: author)

          assert_equal ["Gabriel García Márquez"], author.reload.alternate_names
        end

        test "adds at most 20 alternate names per run" do
          fact = apply(entity(aliases: (1..25).map { |n| "Alias Number #{n}" })).data[:facts]["alternate_names"]

          assert_equal 20, @author.reload.alternate_names.size
          assert_equal 26, fact["offered"]
        end

        test "fills countries through the lookup only when the author has none" do
          russian = ::Books::Country.create!(name: "Russian Test")
          @lookup.stubs(:from_wikidata).with(["Q34266", "Q33946"])
            .returns(::Services::Books::CountryLookup::Result.new(countries: [russian], unmatched: ["Q33946 Czechoslovakia"]))

          fact = apply(entity(citizenships: ["Q34266", "Q33946"])).data[:facts]["countries"]

          assert_equal [russian], @author.reload.countries.to_a
          assert_equal ["filled", ["Q33946 Czechoslovakia"]], [fact["reason"], fact["unmatched"]]
          assert_equal "already_set", apply(entity(citizenships: ["Q30"])).data[:facts]["countries"]["reason"]
        end

        test "never writes the name or the kind" do
          apply(entity(aliases: ["Other Name"]))

          assert_equal ["Test Author Wikidata", "person"], [@author.reload.name, @author.kind]
        end

        test "a second run applies nothing new" do
          applied = entity(born: 1900, identifiers: {openlibrary: ["OL1A"]}, aliases: ["Another"])
          apply(applied)

          result = assert_no_difference(-> { ::Identifier.count }) { apply(applied) }

          assert_empty result.data[:applied]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/apply_wikidata_test.rb`
Expected: `NameError: uninitialized constant …ApplyWikidata`.

- [ ] **Step 3: Implement**

`app/lib/services/books/authors/apply_wikidata.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what a matched Wikidata item says onto the author, filling
      # blanks only (spec §6). Never writes name or kind. A value that
      # disagrees with a stored one is a recorded conflict, never applied;
      # an identifier another author holds is flagged as a duplicate pair,
      # never stamped on a second author. Returns the ledger facts.
      class ApplyWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ALTERNATE_NAME_CAP = 20
        QID = "books_author_wikidata_qid"
        OPEN_LIBRARY = "books_author_openlibrary_id"
        GENDERS = {
          "Q6581097" => "male", "Q6581072" => "female",
          "Q1052281" => "female", # trans woman
          "Q2449503" => "male", # trans man
          "Q48270" => "non_binary"
        }.freeze
        # identifier type => Distiller kind; one value each. Every Open Library
        # value is stamped (apply_open_library_ids): Wikidata often lists
        # several for one person, and each helps the finder.
        SINGLE_IDENTIFIERS = {
          "books_author_viaf" => "viaf",
          "books_author_isni" => "isni",
          "books_author_lcnaf" => "lcnaf",
          "books_author_goodreads_id" => "goodreads",
          "books_author_librarything_id" => "librarything"
        }.freeze

        def self.call(author:, entity:, decision: nil, client: nil, country_lookup: nil, redirected_ids: [])
          new(author: author, entity: entity, decision: decision, client: client, country_lookup: country_lookup,
            redirected_ids: redirected_ids).call
        end

        def initialize(author:, entity:, decision:, client:, country_lookup:, redirected_ids:)
          @author = author
          @entity = entity
          @decision = decision
          @country_lookup = country_lookup || ::Services::Books::CountryLookup.new(client: client)
          @redirected_ids = Array(redirected_ids)
          @facts = {}
          @applied = []
          @collisions = {}
        end

        # A held id Wikidata has merged into this item is the same person, so
        # only another live id is a conflict.
        def call
          other_qids = values_of(QID) - [entity.id] - @redirected_ids
          if other_qids.any?
            record("wikidata_qid", entity.id, applied: false, reason: "held_qid_conflict", held: other_qids)
            return result(conflict: true)
          end

          apply_qid
          apply_single_identifiers
          apply_open_library_ids
          apply_year("birth_year", entity.birth)
          apply_year("death_year", entity.death)
          apply_gender
          apply_alternate_names
          apply_countries
          author.save!
          flag_collisions
          result(conflict: false)
        end

        private

        attr_reader :author, :entity, :decision, :facts, :applied

        def result(conflict:)
          Result.new(success?: true, data: {facts: facts, applied: applied, conflict: conflict}, errors: [])
        end

        def record(name, value, applied:, reason:, **extra)
          facts[name] = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          self.applied << name if applied
        end

        def values_of(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # "filled", "already_set" or "held_by_other".
        def stamp(type, value)
          return "already_set" if values_of(type).include?(value)

          other = ::Identifier.where(identifiable_type: "Books::Author", identifier_type: type, value: value)
            .where.not(identifiable_id: author.id).pick(:identifiable_id)
          if other
            (@collisions[other] ||= []) << {"type" => type, "value" => value}
            return "held_by_other"
          end

          author.identifiers.find_or_initialize_by(identifier_type: type, value: value)
          "filled"
        end

        def apply_qid
          reason = stamp(QID, entity.id)
          extra = @redirected_ids.any? ? {redirected_from: @redirected_ids} : {}
          record("wikidata_qid", entity.id, applied: reason == "filled", reason: reason, **extra)
        end

        def apply_single_identifiers
          SINGLE_IDENTIFIERS.each do |type, kind|
            name = type.delete_prefix("books_author_")
            value = entity.identifiers(kind).first&.delete(" ")
            next record(name, nil, applied: false, reason: "null") if value.blank?

            stored = values_of(type)
            next record(name, value, applied: false, reason: "conflict", stored: stored) if stored.any? && !stored.include?(value)

            reason = stamp(type, value)
            record(name, value, applied: reason == "filled", reason: reason)
          end
        end

        def apply_open_library_ids
          values = entity.identifiers("openlibrary").map { |value| value.delete(" ") }.uniq
          return record("openlibrary_ids", [], applied: false, reason: "null") if values.empty?

          outcomes = values.index_with { |value| stamp(OPEN_LIBRARY, value) }
          added = outcomes.select { |_value, reason| reason == "filled" }.keys
          reason = if added.any? then "filled"
          elsif outcomes.values.all?("already_set") then "already_set"
          else "held_by_other"
          end
          record("openlibrary_ids", values, applied: added.any?, reason: reason, added: added, outcomes: outcomes)
        end

        def apply_year(name, fact)
          return record(name, nil, applied: false, reason: fact.reason) if fact.year.nil?

          current = author.public_send(name)
          if current.nil?
            author.public_send(:"#{name}=", fact.year)
            record(name, fact.year, applied: true, reason: "filled")
          elsif current == fact.year
            record(name, fact.year, applied: false, reason: "already_set")
          else
            record(name, fact.year, applied: false, reason: "conflict", stored: current)
          end
        end

        # "unspecified" is the legacy AI's "don't know" (334 authors), so it
        # counts as blank.
        def apply_gender
          ids = entity.gender_ids
          return record("gender", nil, applied: false, reason: "null") if ids.empty?

          mapped = ids.map { |id| GENDERS[id] }.uniq
          return record("gender", ids, applied: false, reason: "unmapped") if mapped.include?(nil) || mapped.size > 1

          value = mapped.first
          current = author.gender
          if current.nil? || current == "unspecified"
            author.gender = value
            record("gender", value, applied: true, reason: "filled", wikidata: ids)
          elsif current == value
            record("gender", value, applied: false, reason: "already_set")
          else
            record("gender", value, applied: false, reason: "conflict", stored: current)
          end
        end

        # Compared after normalization and case folding only: "García" and
        # "Garcia" are both kept, since each is a spelling someone searches.
        def apply_alternate_names
          offered = ([entity.label] + entity.aliases + entity.native_names + entity.pseudonyms)
            .map { |name| name.to_s.squish }.reject(&:blank?)
          taken = ([author.name] + Array(author.alternate_names)).map { |name| name_key(name) }.to_set
          added = []
          offered.each do |name|
            key = name_key(name)
            next if taken.include?(key)

            taken << key
            added << name
            break if added.size >= ALTERNATE_NAME_CAP
          end
          if added.empty?
            return record("alternate_names", [], applied: false, reason: offered.empty? ? "null" : "already_set", offered: offered.size)
          end

          author.alternate_names = Array(author.alternate_names) + added
          record("alternate_names", added, applied: true, reason: "filled", offered: offered.size)
        end

        def apply_countries
          ids = entity.citizenship_ids
          return record("countries", [], applied: false, reason: "null", unmatched: []) if ids.empty?
          return record("countries", ids, applied: false, reason: "already_set", unmatched: []) if author.author_countries.exists?

          lookup = @country_lookup.from_wikidata(ids)
          return record("countries", ids, applied: false, reason: "no_match", unmatched: lookup.unmatched) if lookup.countries.empty?

          lookup.countries.each { |country| author.author_countries.build(country: country) }
          record("countries", lookup.countries.map(&:name), applied: true, reason: "filled", unmatched: lookup.unmatched, wikidata: ids)
        end

        def flag_collisions
          @collisions.each do |other_id, identifiers|
            ::Services::DuplicateCandidates::Flag.call(
              item_type: "Books::Author", ids: [author.id, other_id], source: :external_key_collision,
              evidence: {reason: "Wikidata #{entity.id} lists identifiers another author already holds", identifiers: identifiers},
              match_decision: decision
            )
          end
        end

        def name_key(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s.downcase
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/books/authors && bundle exec standardrb app/lib/services/books/authors test/lib/services/books/authors`
Expected: all pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/authors/apply_wikidata.rb test/lib/services/books/authors/apply_wikidata_test.rb
git commit -m "ApplyWikidata: fill identifiers, years, gender, alternate names and countries; record conflicts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Wikipedia link and legacy Wikipedia cleanup

**Files:**
- Create: `app/lib/services/books/authors/wikipedia_lead.rb`, `link_wikipedia.rb`, `clean_legacy_wikipedia.rb`
- Test: `test/lib/services/books/authors/link_wikipedia_test.rb`, `clean_legacy_wikipedia_test.rb`

**Interfaces:**
- Consumes:
  - `Wikipedia::Client#lead`, `Wikipedia::Lead` (Task 5)
  - `Services::ExternalRecords::Store.write` (Task 2)
  - `Wikidata::Entity#id`, `#enwiki_title` (Task 3)
- Produces:
  - `WikipediaLead.fetch(language:, title:, refresh: false, client: nil) → Wikipedia::Lead` or nil (read-through by title)
  - `WikipediaLead.store(lead) → ExternalRecord`
  - `LinkWikipedia.call(author:, entity:, refresh: false, client: nil) → Result`, whose `data` is `{fact: Hash, lead: Wikipedia::Lead or nil, record: ExternalRecord or nil}`
  - `LinkWikipedia` fact reasons: `no_sitelink`, `missing`, `item_mismatch`, `disambiguation`, `linked`, `already_set`
  - `CleanLegacyWikipedia.call(author:, entity:, refresh: false, client: nil)` → nil when the author has no active Wikipedia description; otherwise a fact
  - The cleanup fact is `{"value" => [{"description_id", "url", "verdict", "why", …}], "applied", "reason" => "deprecated"|"kept"}`. `entity` nil means the author is unmatched.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/authors/link_wikipedia_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class LinkWikipediaTest < ActiveSupport::TestCase
        def setup
          @author = books_authors(:tolstoy)
          @entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q7243", label: "Leo Tolstoy", enwiki: "Leo Tolstoy")))
        end

        def lead(item: "Q7243", disambiguation: false, raw: "{\"page\":1}")
          ::Wikipedia::Lead.new(language: "en", page_id: 18622119, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
            extract: "Count Lev Nikolayevich Tolstoy…", wikibase_item: item, disambiguation: disambiguation, raw: raw)
        end

        def link(client) = LinkWikipedia.call(author: @author, entity: @entity, client: client)

        test "links the article when the page names the same item back, and stores the lead" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead}))

          assert_equal ["https://en.wikipedia.org/wiki/Leo_Tolstoy", true, "linked"], result.data[:fact].values_at("value", "applied", "reason")
          link_row = @author.external_links.find_by!(url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          assert_equal ["Wikipedia", "wikipedia", "information"], [link_row.name, link_row.source, link_row.link_category]
          assert_equal "en:18622119", result.data[:record].source_id
          assert_equal "Q7243", result.data[:record].payload["wikibase_item"]
        end

        test "ignores a page that reports a different item" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead(item: "Q999")}))

          assert_equal ["item_mismatch", "Q999"], result.data[:fact].values_at("reason", "page_item")
          assert_empty @author.external_links.where(source: :wikipedia)
          assert_equal 0, ::ExternalRecord.where(source: :wikipedia).count
        end

        test "ignores a disambiguation page" do
          result = link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead(disambiguation: true)}))

          assert_equal "disambiguation", result.data[:fact]["reason"]
          assert_empty @author.external_links.where(source: :wikipedia)
        end

        test "does nothing without an English sitelink, and never searches" do
          entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q7243", label: "Leo Tolstoy")))
          client = FakeWikipediaClient.new

          result = LinkWikipedia.call(author: @author, entity: entity, client: client)

          assert_equal "no_sitelink", result.data[:fact]["reason"]
          assert_empty client.calls
        end

        test "a missing page is recorded" do
          assert_equal "missing", link(FakeWikipediaClient.new).data[:fact]["reason"]
        end

        test "a second run reads the stored lead and does not add a second link" do
          link(FakeWikipediaClient.new({["en", "Leo Tolstoy"] => lead}))
          client = FakeWikipediaClient.new

          result = link(client)

          assert_empty client.calls
          assert_equal "already_set", result.data[:fact]["reason"]
          assert_equal 1, @author.external_links.where(source: :wikipedia).count
        end
      end
    end
  end
end
```

`test/lib/services/books/authors/clean_legacy_wikipedia_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class CleanLegacyWikipediaTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Michael Harriot")
          @entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q100", label: "Michael Harriot", enwiki: "Michael Harriot")))
        end

        def legacy(url)
          @author.descriptions.create!(source: :wikipedia, content: "Legacy text.", source_url: url)
        end

        def lead(title, item, page_id: 1)
          ::Wikipedia::Lead.new(language: "en", page_id: page_id, title: title, url: "https://en.wikipedia.org/wiki/#{title.tr(" ", "_")}",
            extract: "", wikibase_item: item, disambiguation: false, raw: "{}")
        end

        def clean(entity, client = FakeWikipediaClient.new) = CleanLegacyWikipedia.call(author: @author, entity: entity, client: client)

        test "keeps a description whose URL is the matched item's sitelink, without calling Wikipedia" do
          row = legacy("https://en.wikipedia.org/wiki/Michael_Harriot")
          client = FakeWikipediaClient.new

          fact = clean(@entity, client)

          assert_equal ["kept", "sitelink"], fact["value"].first.values_at("verdict", "why")
          assert row.reload.normal?
          assert_empty client.calls
        end

        test "deprecates a description whose page is another item (the TV chef)" do
          row = legacy("https://en.wikipedia.org/wiki/Ainsley_Harriott")

          fact = clean(@entity, FakeWikipediaClient.new({["en", "Ainsley Harriott"] => lead("Ainsley Harriott", "Q4697012")}))

          assert row.reload.deprecated?
          assert_equal ["deprecated", "different_item", "Q4697012"], fact["value"].first.values_at("verdict", "why", "page_item")
          assert_equal ["deprecated", true], fact.values_at("reason", "applied")
        end

        test "keeps a description on a redirect title that resolves to the matched item" do
          row = legacy("https://en.wikipedia.org/wiki/M._Harriot")

          clean(@entity, FakeWikipediaClient.new({["en", "M. Harriot"] => lead("Michael Harriot", "Q100")}))

          assert row.reload.normal?
        end

        test "deprecates every Wikipedia description of an author who could not be matched" do
          row = legacy("https://en.wikipedia.org/wiki/Michael_Harriot")

          fact = clean(nil)

          assert row.reload.deprecated?
          assert_equal "author_unmatched", fact["value"].first["why"]
        end

        test "decodes percent-encoded titles and reads mobile URLs" do
          author = ::Books::Author.create!(name: "Arnaldur Indriðason")
          entity = ::Wikidata::Entity.from_payload(::Wikidata::Distiller.call(wikidata_entity("Q300", label: "Arnaldur Indriðason", enwiki: "Arnaldur Indriðason")))
          row = author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.m.wikipedia.org/wiki/Arnaldur_Indri%C3%B0ason")

          CleanLegacyWikipedia.call(author: author, entity: entity, client: FakeWikipediaClient.new)

          assert row.reload.normal?
        end

        test "deprecates a description whose URL is not a Wikipedia article" do
          row = legacy("https://example.com/somewhere")

          assert_equal "unreadable_url", clean(@entity)["value"].first["why"]
          assert row.reload.deprecated?
        end

        test "returns nil, touching nothing, when the author has no active Wikipedia description" do
          ai = @author.descriptions.create!(source: :ai_generated, content: "AI text.")
          @author.descriptions.create!(source: :wikipedia, content: "Old.", source_url: "https://en.wikipedia.org/wiki/X", rank: :deprecated)

          assert_nil clean(nil)
          assert ai.reload.normal?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/link_wikipedia_test.rb test/lib/services/books/authors/clean_legacy_wikipedia_test.rb`
Expected: `NameError` for `LinkWikipedia` and `CleanLegacyWikipedia`.

- [ ] **Step 3: Implement**

`app/lib/services/books/authors/wikipedia_lead.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Read-through for Wikipedia leads (spec §3). A stored lead is keyed by
      # page id, which is unknown before a fetch, so it is found by language
      # and title instead.
      class WikipediaLead
        def self.fetch(language:, title:, refresh: false, client: nil)
          unless refresh
            stored = ::ExternalRecord.where(source: :wikipedia, schema_version: ::Wikipedia::Lead::SCHEMA_VERSION)
              .where("payload->>'language' = ? AND payload->>'title' = ?", language, title).first
            return ::Wikipedia::Lead.from_payload(stored.payload) if stored
          end

          (client || ::Wikipedia::Client.new).lead(language: language, title: title)
        end

        # A lead read from storage has no raw body and is already held.
        def self.store(lead)
          return ::ExternalRecord.find_by(source: :wikipedia, source_id: lead.source_id) if lead.raw.nil?

          ::Services::ExternalRecords::Store.write(source: :wikipedia, source_id: lead.source_id, payload: lead.to_payload,
            raw: lead.raw, schema_version: ::Wikipedia::Lead::SCHEMA_VERSION)
        end
      end
    end
  end
end
```

`app/lib/services/books/authors/link_wikipedia.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The matched item's English article (spec §5.4). Wikidata allows one
      # article per item per wiki, so the sitelink is by construction about
      # the item; the page must still name the same item back and must not be
      # a disambiguation page. Adds the link and keeps the lead in
      # external_records as evidence for the AI step. The text is never shown.
      class LinkWikipedia
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        LANGUAGE = "en"

        def self.call(author:, entity:, refresh: false, client: nil)
          new(author: author, entity: entity, refresh: refresh, client: client).call
        end

        def initialize(author:, entity:, refresh:, client:)
          @author = author
          @entity = entity
          @refresh = refresh
          @client = client
        end

        def call
          title = @entity.enwiki_title
          return done(nil, false, "no_sitelink") if title.blank?

          lead = WikipediaLead.fetch(language: LANGUAGE, title: title, refresh: @refresh, client: @client)
          return done(title, false, "missing") if lead.nil?
          return done(lead.url, false, "item_mismatch", page_item: lead.wikibase_item) if lead.wikibase_item != @entity.id
          return done(lead.url, false, "disambiguation") if lead.disambiguation?

          record = WikipediaLead.store(lead)
          link = @author.external_links.find_or_initialize_by(url: lead.url)
          created = link.new_record?
          if created
            link.assign_attributes(name: "Wikipedia", source: :wikipedia, link_category: :information)
            link.save!
          end
          done(lead.url, created, created ? "linked" : "already_set", lead: lead, record: record, page: lead.source_id)
        end

        private

        def done(value, applied, reason, lead: nil, record: nil, **extra)
          fact = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          Result.new(success?: true, data: {fact: fact, lead: lead, record: record}, errors: [])
        end
      end
    end
  end
end
```

`app/lib/services/books/authors/clean_legacy_wikipedia.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Legacy descriptions sourced from Wikipedia came from a text search and
      # are often the wrong page (17% name a page without the author's
      # surname; a sample of 12 had six wrong). Spec §13: keep one only when
      # its page is the matched item's article; deprecate the rest, including
      # every one of an author who could not be matched. Deprecated, not
      # deleted, so it can be undone. Exercised by the backfill: imports
      # create no legacy descriptions.
      class CleanLegacyWikipedia
        TITLE_PATH = %r{\A/wiki/(.+)\z}
        HOST = /\A([a-z][a-z-]*)\.(?:m\.)?wikipedia\.org\z/

        def self.call(author:, entity:, refresh: false, client: nil)
          new(author: author, entity: entity, refresh: refresh, client: client).call
        end

        def initialize(author:, entity:, refresh:, client:)
          @author = author
          @entity = entity
          @refresh = refresh
          @client = client
        end

        def call
          rows = @author.descriptions.select { |description| description.source == "wikipedia" && !description.deprecated? }
          return nil if rows.empty?

          verdicts = rows.map { |description| verdict_for(description) }
          deprecated = verdicts.any? { |verdict| verdict["verdict"] == "deprecated" }
          {"value" => verdicts, "applied" => deprecated, "reason" => deprecated ? "deprecated" : "kept"}
        end

        private

        def verdict_for(description)
          return deprecate(description, "author_unmatched") if @entity.nil?

          language, title = parse(description.source_url)
          return deprecate(description, "unreadable_url") if title.nil?
          return keep(description, "sitelink") if language == "en" && title == @entity.enwiki_title

          lead = WikipediaLead.fetch(language: language, title: title, refresh: @refresh, client: @client)
          return deprecate(description, "page_missing") if lead.nil?
          return keep(description, "same_item") if lead.wikibase_item == @entity.id

          deprecate(description, "different_item", page_item: lead.wikibase_item)
        end

        def keep(description, why, **extra) = entry(description, "kept", why, extra)

        def deprecate(description, why, **extra)
          description.update!(rank: :deprecated)
          entry(description, "deprecated", why, extra)
        end

        def entry(description, verdict, why, extra)
          {"description_id" => description.id, "url" => description.source_url, "verdict" => verdict, "why" => why}
            .merge(extra.stringify_keys)
        end

        # [language, title] from https://en.wikipedia.org/wiki/Leo_Tolstoy or
        # its mobile form; [nil, nil] for anything else.
        def parse(url)
          uri = URI.parse(url.to_s)
          language = uri.host.to_s[HOST, 1]
          path = uri.path.to_s[TITLE_PATH, 1]
          return [nil, nil] if language.nil? || path.nil?

          [language, URI.decode_uri_component(path).tr("_", " ")]
        rescue URI::InvalidURIError, ArgumentError
          [nil, nil]
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests and lint**

Run: `bin/rails test test/lib/services/books/authors && bundle exec standardrb app/lib/services/books/authors test/lib/services/books/authors`
Expected: all pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/authors/wikipedia_lead.rb app/lib/services/books/authors/link_wikipedia.rb app/lib/services/books/authors/clean_legacy_wikipedia.rb test/lib/services/books/authors/link_wikipedia_test.rb test/lib/services/books/authors/clean_legacy_wikipedia_test.rb
git commit -m "Wikipedia only through the confirmed item: link the verified sitelink page; deprecate legacy pages that are not it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: `EnrichFromWikidata` runner, `WikidataJob`, the ledger link

**Files:**
- Create: migration via `bin/rails generate migration AddMatchDecisionToEnrichments match_decision:references`
- Modify: `app/models/enrichment.rb`, `app/models/books/author.rb`
- Create: `app/lib/services/books/authors/enrich_from_wikidata.rb`
- Create: via `bin/rails generate sidekiq:job books/authors/wikidata` → `app/sidekiq/books/authors/wikidata_job.rb`, `test/sidekiq/books/authors/wikidata_job_test.rb`
- Test: `test/lib/services/books/authors/enrich_from_wikidata_test.rb`

**Interfaces:**
- Consumes: `ResolveWikidata` (Task 10), `ApplyWikidata` (Task 12), `LinkWikipedia` and `CleanLegacyWikipedia` (Task 13), `Wikimedia::Exceptions` (Task 1).
- Produces:
  - `enrichments.match_decision_id`, `Enrichment#match_decision`
  - `Books::Author#enrichments`
  - `Services::Books::Authors::EnrichFromWikidata::KIND` (`"books.author_wikidata"`)
  - `EnrichFromWikidata.call(author:, refresh: false, client: nil, wikipedia_client: nil) → Result`, whose `data` is `{outcome: :matched|:unmatched|:failed|:skipped, enrichment: Enrichment, decision: MatchDecision or nil}`
  - `Books::Authors::WikidataJob.perform_async(author_id, refresh = false)` (queue `low`, retry 3)

- [ ] **Step 1: Migration and associations**

Run: `bin/rails generate migration AddMatchDecisionToEnrichments match_decision:references`

Edit the body to exactly:

```ruby
  def change
    add_reference :enrichments, :match_decision, foreign_key: {on_delete: :nullify}, index: true
  end
```

Run `bin/rails db:migrate`. Strip foreign changes from `db/schema.rb` (see the Global Constraints). Run `RAILS_ENV=test bin/rails db:test:prepare`.

In `app/models/enrichment.rb`, after `belongs_to :ai_chat, optional: true`:

```ruby
  belongs_to :match_decision, optional: true
```

In `app/models/books/author.rb`, after `has_many :ai_chats, …`:

```ruby
  has_many :enrichments, as: :enrichable, dependent: :destroy
```

- [ ] **Step 2: Generate the job**

Run: `bin/rails generate sidekiq:job books/authors/wikidata`

- [ ] **Step 3: Write the failing tests**

`test/lib/services/books/authors/enrich_from_wikidata_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichFromWikidataTest < ActiveSupport::TestCase
        TOLSTOY = {label: "Leo Tolstoy", born: 1828, died: 1910, enwiki: "Leo Tolstoy", identifiers: {viaf: ["96987389"]}}.freeze

        def setup
          @author = books_authors(:tolstoy)
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243")
          @wikidata = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          @lead = ::Wikipedia::Lead.new(language: "en", page_id: 18622119, title: "Leo Tolstoy", url: "https://en.wikipedia.org/wiki/Leo_Tolstoy",
            extract: "Count Lev…", wikibase_item: "Q7243", disambiguation: false, raw: "{}")
          @wikipedia = FakeWikipediaClient.new({["en", "Leo Tolstoy"] => @lead})
        end

        def run(refresh: false, wikipedia: @wikipedia, wikidata: @wikidata)
          EnrichFromWikidata.call(author: @author, refresh: refresh, client: wikidata, wikipedia_client: wikipedia)
        end

        def rows = @author.enrichments.for_kind(EnrichFromWikidata::KIND).order(:id)

        test "a match applies the item, links Wikipedia and writes one applied ledger row tied to the decision" do
          result = run

          row = rows.sole
          assert_equal [:matched, true], [result.data[:outcome], result.success?]
          assert_equal ["applied", "wikidata", true, "high"], [row.outcome, row.provider, row.recognized, row.confidence]
          assert_equal result.data[:decision], row.match_decision
          assert_equal "filled", row.facts.dig("viaf", "reason")
          assert_equal "linked", row.facts.dig("wikipedia", "reason")
          assert_includes row.citations, "https://www.wikidata.org/wiki/Q7243"
          assert_equal ["96987389"], @author.identifiers.where(identifier_type: :books_author_viaf).pluck(:value)
        end

        test "a miss writes an unrecognized row and deprecates the legacy Wikipedia description" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")

          result = run(wikidata: FakeWikidataClient.new)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal ["unrecognized", false], [rows.sole.outcome, rows.sole.recognized]
          assert legacy.reload.deprecated?
          assert_equal "deprecated", rows.sole.facts.dig("legacy_wikipedia", "reason")
        end

        test "a failed resolution writes a failed row and leaves legacy descriptions alone" do
          @author.identifiers.destroy_all
          legacy = @author.descriptions.create!(source: :wikipedia, content: "x", source_url: "https://en.wikipedia.org/wiki/Leo_Tolstoy")
          wikidata = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = run(wikidata: wikidata)

          assert_equal [:failed, false], [result.data[:outcome], result.success?]
          assert_equal "failed", rows.sole.outcome
          assert legacy.reload.normal?
        end

        test "a Wikimedia error writes a failed row with the error" do
          wikidata = FakeWikidataClient.new
          wikidata.stubs(:entities).raises(::Wikimedia::Exceptions::HttpError.new("Wikimedia returned HTTP 503", 503))

          result = run(wikidata: wikidata)

          assert_equal "failed", rows.sole.outcome
          assert_match(/503/, rows.sole.error)
          assert_not result.success?
        end

        test "a rate limit propagates and writes no row" do
          wikidata = FakeWikidataClient.new
          wikidata.stubs(:entities).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))

          assert_raises(::Wikimedia::Exceptions::RateLimited) { run(wikidata: wikidata) }
          assert_empty rows
        end

        test "an author already processed since its row was created is skipped without calling out" do
          run
          ResolveWikidata.expects(:call).never

          result = run

          assert_equal :skipped, result.data[:outcome]
          assert_equal ["applied", "skipped"], rows.map(&:outcome)
          assert_equal "already_processed", rows.last.reason
        end

        test "a failed or skipped run does not count as processed" do
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :failed, error: "boom")
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :skipped, reason: "placeholder")

          assert_equal :matched, run.data[:outcome]
        end

        test "a processed row older than the author row (a re-migrated author) does not count" do
          @author.enrichments.create!(kind: EnrichFromWikidata::KIND, outcome: :applied, created_at: 2.days.ago)
          @author.update_columns(created_at: 1.day.ago)

          assert_equal :matched, run.data[:outcome]
        end

        test "refresh runs even when processed" do
          run

          assert_equal :matched, run(refresh: true).data[:outcome]
        end

        test "a placeholder author is skipped" do
          placeholder = books_authors(:excluded_placeholder)

          result = EnrichFromWikidata.call(author: placeholder, client: FakeWikidataClient.new)

          assert_equal [:skipped, "placeholder"], [result.data[:outcome], result.data[:enrichment].reason]
        end

        test "an author holding a different Wikidata id: nothing applied, the decision flagged for review" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")
          wikidata = FakeWikidataClient.new(entities: {
            "Q7243" => wikidata_entity("Q7243", **TOLSTOY),
            "Q1" => wikidata_entity("Q1", label: "Somebody Else", born: 1700)
          })

          result = run(wikidata: wikidata)

          assert_equal ["nothing_to_apply", "held_qid_conflict"], [rows.sole.outcome, rows.sole.reason]
          assert result.data[:decision].reload.needs_review
          assert_empty @author.identifiers.where(identifier_type: :books_author_viaf)
        end

        test "a rate limit after the facts were saved: the rescheduled run finishes without duplicating anything" do
          russian = ::Books::Country.create!(name: "Russian Runner Test")
          lookup_result = ::Services::Books::CountryLookup::Result.new(countries: [russian], unmatched: [])
          ::Services::Books::CountryLookup.any_instance.stubs(:from_wikidata).returns(lookup_result)
          @wikidata = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, citizenships: ["Q34266"])})
          limited = FakeWikipediaClient.new({["en", "Leo Tolstoy"] => ::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30)})

          assert_raises(::Wikimedia::Exceptions::RateLimited) { run(wikipedia: limited) }
          identifiers = @author.identifiers.count
          run

          assert_equal identifiers, @author.identifiers.count
          assert_equal 1, @author.author_countries.count
          assert_equal 1, @author.external_links.where(source: :wikipedia).count
          # Only the second run wrote a row (the first raised before writing):
          # it found everything already set except the link.
          assert_equal "linked", rows.sole.facts.dig("wikipedia", "reason")
          assert_equal "already_set", rows.sole.facts.dig("viaf", "reason")
        end

        test "a held id Wikidata has merged into the matched item applies normally" do
          @author.identifiers.destroy_all
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q999")
          wikidata = FakeWikidataClient.new(entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          run(wikidata: wikidata)

          assert_equal "applied", rows.sole.outcome
          assert_equal ["Q7243", "Q999"], @author.identifiers.where(identifier_type: :books_author_wikidata_qid).pluck(:value).sort
        end
      end
    end
  end
end
```

`test/sidekiq/books/authors/wikidata_job_test.rb` (replace the generated content):

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  test "runs on the low queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the Wikidata step for the author" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: author, refresh: true)

    Books::Authors::WikidataJob.new.perform(author.id, true)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).never

    Books::Authors::WikidataJob.new.perform(0)
  end

  test "reschedules itself after the wait a rate limit carries, plus jitter" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 120))
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::WikidataJob.expects(:perform_in).with(127, author.id, false)

    job.perform(author.id)
  end
end
```

- [ ] **Step 4: Run to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/enrich_from_wikidata_test.rb test/sidekiq/books/authors/wikidata_job_test.rb`
Expected: `NameError` for `EnrichFromWikidata`. The generated job does not reschedule.

- [ ] **Step 5: Implement**

`app/lib/services/books/authors/enrich_from_wikidata.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # One Wikidata run for one author (spec §5, §6, §13). Resolve; on a
      # match, apply the item, link its Wikipedia article and check any
      # legacy Wikipedia description; on a miss, deprecate those
      # descriptions. Exactly one books.author_wikidata ledger row per run,
      # skips and failures included, tied to the run's decision. A Wikimedia
      # failure writes a failed row and returns; a rate limit propagates so
      # the job can reschedule.
      class EnrichFromWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_wikidata"
        PROVIDER = "wikidata"
        # "Done" outcomes. A failed or skipped run leaves the author to be tried again.
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        LEDGER_CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        def self.call(author:, refresh: false, client: nil, wikipedia_client: nil)
          new(author: author, refresh: refresh, client: client, wikipedia_client: wikipedia_client).call
        end

        def initialize(author:, refresh:, client:, wikipedia_client:)
          @author = author
          @refresh = refresh
          @client = client || ::Wikidata::Client.new
          @wikipedia_client = wikipedia_client
          @decision = nil
        end

        def call
          return finish(:skipped, write(outcome: :skipped, reason: "placeholder")) if author.exclude_from_rankings?
          return finish(:skipped, write(outcome: :skipped, reason: "already_processed")) if !refresh && processed?

          resolved = ResolveWikidata.call(author: author, refresh: refresh, client: @client).data
          @decision = resolved[:decision]
          case resolved[:outcome]
          when :matched then matched(resolved[:entity], resolved[:redirected_ids])
          when :unmatched then unmatched
          else finish(:failed, write(outcome: :failed, reason: "resolve_failed", error: resolved[:reason]))
          end
        rescue ::Wikimedia::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "wikimedia_error", error: "#{e.class.name.demodulize}: #{e.message}"))
        end

        private

        attr_reader :author, :refresh

        # "Newer than the author row": after the production re-migration an
        # author is re-created with its id, and the old rows no longer count.
        def processed?
          author.enrichments.for_kind(KIND).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at).exists?
        end

        def matched(entity, redirected_ids)
          applied = ApplyWikidata.call(author: author, entity: entity, decision: @decision, client: @client,
            redirected_ids: redirected_ids)
          facts = applied.data[:facts]
          if applied.data[:conflict]
            @decision.update!(needs_review: true)
            return finish(:matched, write(outcome: :nothing_to_apply, reason: "held_qid_conflict", recognized: true, facts: facts))
          end

          wikipedia = LinkWikipedia.call(author: author, entity: entity, refresh: refresh, client: @wikipedia_client)
          facts["wikipedia"] = wikipedia.data[:fact]
          legacy = CleanLegacyWikipedia.call(author: author, entity: entity, refresh: refresh, client: @wikipedia_client)
          facts["legacy_wikipedia"] = legacy if legacy
          changed = applied.data[:applied].any? || wikipedia.data[:fact]["applied"] || legacy&.dig("applied")
          citations = ["https://www.wikidata.org/wiki/#{entity.id}", wikipedia.data[:lead]&.url].compact
          finish(:matched, write(outcome: changed ? :applied : :nothing_to_apply, reason: "matched #{entity.id}",
            recognized: true, facts: facts, citations: citations))
        end

        def unmatched
          legacy = CleanLegacyWikipedia.call(author: author, entity: nil, refresh: refresh, client: @wikipedia_client)
          facts = legacy ? {"legacy_wikipedia" => legacy} : {}
          finish(:unmatched, write(outcome: :unrecognized, reason: "no_match", recognized: false, facts: facts))
        end

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          author.enrichments.create!(
            kind: KIND, provider: PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: LEDGER_CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        def finish(outcome, row)
          Result.new(success?: outcome != :failed, data: {outcome: outcome, enrichment: row, decision: @decision},
            errors: Array(row.error))
        end
      end
    end
  end
end
```

`app/sidekiq/books/authors/wikidata_job.rb`:

```ruby
# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromWikidata (spec §11).
# On the low queue: it has no latency requirement, and low is last in the
# strict queue order. Expected failures write a failed ledger row inside the
# runner and do not raise. A rate limit (a 429, maxlag, or our own pace busy
# for longer than the inline wait) reschedules this job rather than holding
# a worker thread. The chain ends here until VIAF and the AI step land.
class Books::Authors::WikidataJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    ::Services::Books::Authors::EnrichFromWikidata.call(author: author, refresh: refresh)
  rescue ::Wikimedia::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh)
  end
end
```

- [ ] **Step 6: Run tests, lint, Zeitwerk**

Run: `bin/rails test test/lib/services/books/authors test/sidekiq/books test/models && bundle exec standardrb app/lib/services/books/authors app/sidekiq/books/authors app/models test/lib/services/books/authors test/sidekiq/books/authors && CI=1 bin/rails zeitwerk:check`
Expected: all pass, no offenses, "All is good!".

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*_add_match_decision_to_enrichments.rb db/schema.rb app/models/enrichment.rb app/models/books/author.rb app/lib/services/books/authors/enrich_from_wikidata.rb app/sidekiq/books/authors/wikidata_job.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb test/sidekiq/books/authors/wikidata_job_test.rb
git commit -m "EnrichFromWikidata and WikidataJob: one ledger row per run, tied to its decision; rate limits reschedule

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: `Providers::Enrichment` on the author importer

**Files:**
- Create: `app/lib/data_importers/books/author/providers/enrichment.rb`
- Modify: `app/lib/data_importers/books/author/importer.rb`
- Modify: every existing test that imports an author (Step 4)
- Modify: `docs/features/data_importers.md` (the Books Author importer section)
- Test: `test/lib/data_importers/books/author/providers/enrichment_test.rb`, `test/lib/data_importers/books/author/importer_test.rb`

**Interfaces:**
- Consumes: `Books::Authors::WikidataJob.perform_async(author_id)` (Task 14).
- Produces: `DataImporters::Books::Author::Providers::Enrichment#populate(author, query:, match: nil)` returns `success` with `data_populated: [:author_enrichment_queued]`. It fails when the author is not persisted. The author importer's providers are `[Providers::OpenLibrary, Providers::Enrichment]`.

- [ ] **Step 1: Write the failing tests**

`test/lib/data_importers/books/author/providers/enrichment_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      module Providers
        class EnrichmentTest < ActiveSupport::TestCase
          test "queues the Wikidata step for the author and reports it" do
            author = books_authors(:king)
            ::Books::Authors::WikidataJob.expects(:perform_async).with(author.id)

            result = Enrichment.new.populate(author, query: nil)

            assert result.success?
            assert_equal [:author_enrichment_queued], result.data_populated
          end

          test "fails for an author that is not saved" do
            ::Books::Authors::WikidataJob.expects(:perform_async).never

            result = Enrichment.new.populate(::Books::Author.new(name: "Unsaved"), query: nil)

            assert_not result.success?
            assert_includes result.errors, "Author must be persisted before queuing enrichment"
          end

          test "reports a queueing error as a failure" do
            ::Books::Authors::WikidataJob.stubs(:perform_async).raises(RedisClient::CannotConnectError)

            result = Enrichment.new.populate(books_authors(:king), query: nil)

            assert_not result.success?
            assert_match(/Author enrichment provider error/, result.errors.first)
          end
        end
      end
    end
  end
end
```

`RedisClient::CannotConnectError` is what Sidekiq 7+ raises when Redis is down. If that constant is not loaded in the test environment, raise `StandardError` instead.

In `test/lib/data_importers/books/author/importer_test.rb` add:

```ruby
    test "a new author gets the Wikidata step queued; a matched author does not" do
      ::Books::Authors::WikidataJob.expects(:perform_async).once

      created = Importer.call(name: "A Brand New Author Name")
      matched = Importer.call(name: created.item.name)

      assert created.created?
      assert_not matched.created?
    end
```

Match the file's existing setup. If it stubs the Open Library client or the finder in a way that changes how an author is created, follow its pattern. What must be pinned is exactly one enqueue for the created author and none for the matched one.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/data_importers/books/author`
Expected: `NameError` for `Providers::Enrichment`. The importer test fails because `perform_async` is never called.

- [ ] **Step 3: Implement**

`app/lib/data_importers/books/author/providers/enrichment.rb`:

```ruby
# frozen_string_literal: true

module DataImporters
  module Books
    module Author
      module Providers
        # Async provider (spec §2): queues the Wikidata step for the author and
        # returns at once. Providers run only for a new author (or a forced
        # re-import), so a matched author is never re-enriched from here; the
        # chain continues from the job.
        class Enrichment < DataImporters::ProviderBase
          def populate(author, query:, match: nil)
            return failure_result(errors: ["Author must be persisted before queuing enrichment"]) unless author.persisted?

            ::Books::Authors::WikidataJob.perform_async(author.id)
            success_result(data_populated: [:author_enrichment_queued])
          rescue => e
            failure_result(errors: ["Author enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
```

In `app/lib/data_importers/books/author/importer.rb`:

```ruby
        def providers
          @providers ||= [Providers::OpenLibrary.new, Providers::Enrichment.new]
        end
```

- [ ] **Step 4: Stop every other importing test from running the job for real**

Sidekiq runs inline in tests. Without a stub, `perform_async` runs the whole Wikidata step, and WebMock refuses the call with an `Exception` that no provider rescue catches. Find every test that can create an author through the importer:

```bash
grep -rln -e "Author::Importer" -e "Book::Importer" -e "Providers::Authors" -e "Book::Providers::OpenLibrary" test/
```

In each file's `setup`, add:

```ruby
    ::Books::Authors::WikidataJob.stubs(:perform_async)
```

Skip the two test files from Step 1, which set their own expectations. Then run the full suite. Any remaining failure naming `WebMock::NetConnectNotAllowedError` and `wikidata.org` is a missed file; add the stub there too.

- [ ] **Step 5: Document**

In `docs/features/data_importers.md`, in the Books Author importer section, after the Open Library provider paragraph:

```markdown
**Enrichment (async).** Queues `Books::Authors::WikidataJob` for the new author and returns
`[:author_enrichment_queued]`. The job resolves the author to a Wikidata person or to none,
fills blanks from the item, and links the English Wikipedia article only through that item. See
`docs/features/books-author-enrichment.md`. Providers run only for a new author, so a matched
author is never re-enriched from an import.
```

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: everything passes, no offenses, and no new warning lines.

- [ ] **Step 7: Commit**

```bash
git add app/lib/data_importers/books/author test/lib/data_importers test ../docs/features/data_importers.md
git commit -m "Author importer: async Enrichment provider queues the Wikidata step for a new author

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Feature docs and whole-branch verification

**Files:**
- Create: `docs/features/books-author-enrichment.md`, `docs/features/wikimedia-clients.md`
- Modify: `docs/features/import-finder.md` (one paragraph on external-link registry entries)

**Interfaces:** none (documentation and verification).

- [ ] **Step 1: Write `docs/features/wikimedia-clients.md`**

Sections, in this order, stating these facts. Follow `docs/documentation.md`: features, not classes.

1. **What it is.** `Wikimedia::Http` is the one path to Wikimedia hosts. `Wikidata::Client` offers `entities`, `search`, `by_statements`, `works`, `country_codes` and `labels`. `Wikipedia::Client` offers only `lead`.
2. **Pacing and etiquette.**
   - One request per second across all hosts, Redis key `wikimedia:api`.
   - A request waits inline up to 5 s for a slot; a longer wait raises `RateLimited`.
   - A 429 or maxlag also raises `RateLimited`, which the job turns into `perform_in(retry_after + jitter)`.
   - `maxlag=5`. User-Agent `TheGreatest/1.0 (<WIKIMEDIA_CONTACT>)`; never an email by default.
   - Tuning lives in `config/initializers/wikimedia.rb`.
3. **Verified limits (2026-09-27).**
   - Action API: 200 requests a minute with a policy User-Agent, 10 without.
   - Query Service: 60 s of query time a minute, 5 parallel queries.
   - No rate-limit headers on success.
   - The three probe codes recorded by Task 1.
4. **No Wikipedia search.** Why: the legacy app's wrong pages, with the six examples from the spec.
5. **Caching.** Country codes and labels in `Rails.cache` for 30 days. Chosen entities and leads live in `external_records`: gzipped `raw` plus a distilled `payload`, read through unless `refresh`.
6. **Testing.** Fixtures under `test/fixtures/files/wikidata|wikipedia` are trimmed real responses. `FakeWikidataClient` and `FakeWikipediaClient`. The `wikidata_entity` builder.

- [ ] **Step 2: Write `docs/features/books-author-enrichment.md`**

Sections:

1. **The chain today.** Author importer → `Providers::Enrichment` → `Books::Authors::WikidataJob` → `EnrichFromWikidata`, on the `low` queue. VIAF, the AI facts step and book-enrichment hand-off arrive in increments 3–4, per the spec.
2. **Resolution.**
   - The three candidate stages, with early exit.
   - The persons-only filter.
   - Rules 1–3, "no persons", then the AI.
   - Year conflict (> 1 year).
   - Name folding.
   - `needs_review`.
   - Decisions on the books audit pages as "Wikidata link" (an external-link registry entry).
3. **What gets filled.** The §6 table, as built: identifiers (every Open Library key), years at precision ≥ 9, gender mapping including `unspecified` as blank, alternate names (cap 20), countries. Conflicts are recorded. Identifier collisions become duplicate pairs. A held-QID conflict applies nothing.
4. **Wikipedia.** Only the matched item's English sitelink. Item-back check, disambiguation check, `ExternalLink`, the lead stored as AI evidence and never displayed.
5. **Legacy Wikipedia cleanup.** Keep or deprecate rules; exercised by the backfill (increment 6).
6. **Countries.**
   - The `books_author_countries` table and `CountryLookup` (text, ISO, Wikidata).
   - The alias and historical maps and how they were sized; the deliberately unmapped states.
   - Never creates a country.
   - `data_migration:author_countries`: 375 of 33,678 legacy authors unmapped.
7. **The ledger.**
   - Kind `books.author_wikidata`, one row per run, facts per field, `match_decision_id`.
   - "Processed" means applied, nothing_to_apply or unrecognized, newer than the author row; so a production re-migration re-runs everyone.
   - `external_records` makes re-runs cheap.
8. **Operating.**
   - Run one author: `Books::Authors::WikidataJob.new.perform(author_id)`.
   - Refresh: pass `true` as the second argument.
   - Where to look: the audit pages, `Enrichment.for_kind("books.author_wikidata")`.

- [ ] **Step 3: Update `docs/features/import-finder.md`**

Add one paragraph where the registry is described: external-link entries (`kind: :external_link`) put a linking service's decisions on the same audit pages without a query, merge or re-check. The first is `Services::Books::Authors::ResolveWikidata`.

- [ ] **Step 4: Verify the whole branch**

Run, from `web-app/`:

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
git diff main -- db/schema.rb
```

Expected:
- Every test passes, with no new warning lines.
- No lint offenses. "All is good!".
- The schema diff holds only `external_records.raw`, `books_author_countries` (table, index and two foreign keys), `enrichments.match_decision_id` (column, index and foreign key) and the version bump.

- [ ] **Step 5: Commit**

```bash
git add ../docs/features/books-author-enrichment.md ../docs/features/wikimedia-clients.md ../docs/features/import-finder.md
git commit -m "Docs: books author enrichment (Wikidata, Wikipedia, countries) and the Wikimedia clients

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the tasks: the real-API smoke run (needs Shane's go-ahead)

Spec §15 asks for a console run against the real APIs on about 20 hard authors before this increment merges. It writes to the shared development database and calls Wikidata, Wikipedia and OpenAI. **Stop and ask Shane before running it.**

When approved:

1. `bin/snapshot-dev-db.sh --label pre-wikidata-smoke`. Redis must be running; the AI step needs the OpenAI key in `web-app/.env`.
2. Run the authors below, one at a time, through `Services::Books::Authors::EnrichFromWikidata.call(author:)` in `bin/rails runner`. Look each author up by exact name, and skip any that is absent.
   - Legacy wrong-page cases: Michael Harriot, Stacy Willingham, John Crowe Ransom, Bill Clinton, Arnaldur Indriðason, Zhou Haohui.
   - Pseudonyms: Richard Bachman, Robert Galbraith.
   - A collective pseudonym: Ellery Queen.
   - Name order and transliteration: Mo Yan, Fyodor Dostoevsky, Gabriel García Márquez.
   - A same-name pair: Winston Churchill.
   - A common name: James Patterson.
   - Famous control authors: Toni Morrison, Haruki Murakami, Chinua Achebe, Stephen King.
   - A long-tail author with no Wikipedia article, and "Anonymous".
3. Report, per author:
   - outcome, `decided_by`, confidence and the selected QID
   - identifiers added, countries, and the Wikipedia link
   - for the six legacy cases, whether the legacy description was kept or deprecated
4. Report totals: the match rate, the rule/AI split, how many decisions need review, and the AI cost from `ai_chats`.
5. If anything is wrong, restore with `bin/snapshot-dev-db.sh --restore`.
