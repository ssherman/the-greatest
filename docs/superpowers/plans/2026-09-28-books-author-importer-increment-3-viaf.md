# Books Author Importer — Increment 3 (VIAF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Wikidata finds no person for an author, resolve the author to a VIAF cluster (or explicitly to none) and fill its blanks from that cluster: identifiers, life years, gender, countries and alternate names. When the cluster names a Wikidata item, run the Wikidata step once more for it.

**Architecture:** A new `Viaf::Client` wraps the existing `Viaf::BaseClient`. It adds an `:immediate` pace, a Redis-held `Viaf::Gate` (a Cloudflare block or a low daily budget pauses every VIAF call) and a one-day cache of AutoSuggest answers. `Services::Books::Authors::ResolveViaf` groups AutoSuggest rows by cluster and decides by rule or through `SelectExternalRecordTask`, then records a `MatchDecision`. `ApplyViaf` fills blanks through a `FactSheet` extracted from `ApplyWikidata`. `EnrichFromViaf` writes one `books.author_viaf` ledger row per run. `Books::Authors::ViafJob` runs it on the `low` queue. `WikidataJob` enqueues it on a miss, and `ViafJob` sends a newly found Wikidata id back to `WikidataJob` once, with `via_viaf`.

**Tech Stack:** Rails 8, PostgreSQL (jsonb, bytea), Faraday, Redis (`DistributedRateLimiter`, a hash for the gate), Sidekiq, OpenAI via `Services::Ai::Tasks`, Minitest + Mocha + WebMock.

**Spec:** `docs/superpowers/specs/2026-09-27-books-author-importer-design.md`. This plan implements §8, the VIAF half of §11 and §15, and §16 item 3. Increment 2's plan is `docs/superpowers/plans/2026-09-27-books-author-importer-increment-2-wikidata.md`. The VIAF client it builds on is `docs/superpowers/specs/2026-08-30-viaf-api-client-design.md` / `docs/features/viaf-api-client.md`.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in the repository root's `docs/`.
- Tests: `bin/rails test`. Lint: `bundle exec standardrb` (never `bin/rubocop`). Never run brakeman.
- Use generators. For jobs, run `bin/rails generate sidekiq:job <path>` (never `generate job`).
- Services live under `app/lib/services/`, never `app/services/`. Inside `Services::Books::…`, write constants root-anchored: `::Books::Author`, `::Viaf::…`, `::MatchDecision`.
- Service results use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Identifiers: `find_or_initialize_by`, never `build`.
- Minitest 6: `assert_nil` for nil, never `assert_equal nil, x`.
- A clean `bin/rails test` prints no new warning lines.
- **Fills blanks only.** Nothing overwrites a populated field. `name` and `kind` are never written. A disagreement is recorded, never applied.
- **VIAF runs only after a Wikidata miss** (outcome `unmatched`). A matched author gets its VIAF id from Wikidata's P214, and VIAF itself is not called.
- **Never retry a Cloudflare block (403) directly.** A block pauses every VIAF call through `Viaf::Gate` for one hour, doubling on each repeat up to 24 hours.
- **VIAF pace:** 2 requests a minute (the existing `Viaf::RateLimiter`, key `viaf:api`), in `:immediate` mode inside jobs, so no worker thread sleeps. `Viaf::BaseClient`'s own default stays `:blocking` for console use.
- **CI has no Redis.** Tests never touch `REDIS_POOL`. Inject a fake: `Books::OpenLibrary::FakeRedis` (`test/support/books/open_library/fake_redis.rb`), or a Mocha stub.
- **No live VIAF calls in tests.** Viaf library tests stub the transport or use WebMock against `https://viaf.test`. Service tests use `FakeViafClient`. Any real-API run needs Shane's go-ahead (see "After the final review").
- **No migration in this increment.** `external_records` already has the `viaf` source and the `raw` column; `MatchDecision` and `enrichments` need nothing new.
- Jobs run on the `low` queue with `retry: 3`.
- Ledger kind `books.author_viaf`, provider `viaf`, `mode` left at its default, `model` blank.
- No new page or flow. The only visible change is a new "VIAF link" entity on the existing audit pages, covered by a controller test. The first Playwright spec for this feature is the Reject link's, in increment 5.
- Commit after each task on the worktree branch. Never commit to `main`. Never push.
- Commit message trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Rulings made while planning

Planning probed VIAF live on 2026-09-28: one AutoSuggest call ("Stacy Willingham") and one cluster fetch, 35 seconds apart. The raw responses are in the controller's scratchpad and are not committed. These rulings refine the spec; none changes its intent.

1. **AutoSuggest has changed since the client was written.**
   - Terms now come in natural order ("Stacy Willingham", not "Willingham, Stacy").
   - One cluster answers with several rows: a plain heading, one with dates ("Stacy Willingham 1991–", with an en dash), one with a description ("Stacy Willingham American writer") and translated forms.
   - Rows of other name types (`uniformtitleexpression`, which are works) are mixed in.
   - So `ResolveViaf` groups rows by VIAF id into one candidate each, compares names as sorted word sets rather than strings, and `Viaf::Suggestion` reads an en dash as a date separator.
2. **VIAF holds duplicate clusters for one person.** Stacy Willingham has two: `5391164721401702340007` with 20 contributing sources and `1375178795817914280004` with none. Both have a heading equal to the name, so the spec's rule ("exactly one") does not fire and the AI decides. The guidance tells the AI to choose the most-catalogued record rather than treat duplicates as a tie.
3. **The spec's rule, made concrete.**
   - It needs exactly one personal candidate with a heading equal to the author's name (or an alternate name).
   - Our author must have a birth year, and one of that candidate's AutoSuggest rows must carry a birth year within one year of it.
   - The rule's cluster is then fetched and must still be a person with no year conflict. Otherwise the AI decides.
4. **"No person among the candidates" is `unmatched` by rule, `high`**, as in §5.2. This also covers a run where none of the fetched clusters can be read as a person.
5. **Every cluster the importer fetches is kept, chosen or not.** This deviates from §3's "only the chosen record is stored". The pace is two requests a minute in `:immediate` mode, so a run that needs four requests is rescheduled partway through. Only stored answers let the rescheduled run resume without repeating requests against a budget of about 1,000 a day. `Viaf::Cluster` already stores every cluster it reads. AutoSuggest answers are cached for a day in `Rails.cache` for the same reason.
6. **`Viaf::Client` is new:** a facade with `suggest`, `cluster` and a gated `get` that `AutoSuggest` and `Cluster` call as their transport. A stored cluster is read without touching the gate, so a paused VIAF still serves what we hold.
7. **The gate is one Redis hash, `viaf:pause`**, with the fields `until` and `block_seconds`, instead of the spec's `viaf:paused_until` key.
   - The block and the low-budget pause share one clock, and a low budget never shortens a longer block.
   - The doubling needs memory, and a real VIAF answer (one that carries budget headers) resets it.
   - Hash commands are what the existing `FakeRedis` implements.
8. **Budget.** `ratelimit-remaining` and `x-ratelimit-remaining-day` both report the day's budget: 1,002 of 1,003 were left, with a reset in 81,144 s (measured). The gate reads the smaller of the two. Below 50 it pauses VIAF for an hour.
9. **VIAF's "unknown" markers are not years.**
   - `deathDate: 0` for a living person (measured).
   - `"0"`, and partial dates such as `"18XX"`.
   - `Viaf::Person#year_from` returns nil for these. `ApplyViaf` applies years only when `dateType` is `lived` (a "flourished" span is not a birth or death) and never a BCE year.
10. **Work titles.** The distiller keeps up to 200 work titles, the most-catalogued first (the number of sources listing each work). It drops titles that are only an authority id (NDL files `n2021040535` as a title). `SCHEMA_VERSION` goes to 2. Production holds no VIAF rows; development may hold a few, which are refetched on use.
11. **Titles are compared by main title**: the text before a colon, slash or semicolon, with case and diacritics folded. VIAF titles carry subtitles, as in "Forget me not : a novel".
12. **Alternate names come from main headings only.**
    - Each is put in natural order at its comma ("Willingham, Stacy" becomes "Stacy Willingham"), in Latin script, at most 10.
    - The Wikidata-built heading (source `WKP`, "Stacy Willingham American writer") is skipped, and so is a heading without a comma, whose order is unknowable ("Willingham Stacy").
    - A heading whose words only reorder a name we already have is skipped too: "Mo, Yan" is Mo Yan, not "Yan Mo".
13. **A held VIAF id that differs from the matched cluster** applies nothing and flags the decision for review, mirroring `held_qid_conflict`.
14. **A cluster VIAF no longer serves** (404, or withdrawn) is dropped as a candidate, and the run goes on. It is recorded on the candidate and in `sources_failed`, which caps the decision's confidence at `medium`.
15. **The Wikidata round trip.**
    - `ApplyViaf` stamps the cluster's `WKP` id like any single-value identifier.
    - `ViafJob` enqueues `WikidataJob.perform_async(author_id, true, true)` only when this run newly stamped the Wikidata id. An id the author already held (Wikidata already tried it), one another author holds, or one that conflicts sends nothing.
    - `refresh` is `true` because the earlier Wikidata miss counts as processed and would otherwise skip the run.
16. **`ViafJob(author_id, refresh = false)`.** The spec lists `(author_id)`. `refresh` passes through from `WikidataJob`, so a forced Wikidata re-run (increment 5's Reject link) does not stop at VIAF's own "already processed" check.
17. **Shared pieces extracted from the Wikidata step, with no behaviour change:**
    - `FactSheet`: the fill-blanks ledger, identifier stamping and collision flags.
    - `AuthorProfile`: our titles, our names and the AI's one-line author summary.

    Both VIAF services use them, and increment 4's `ApplyAuthorFacts` and `AuthorFactsTask` will too.
18. **Pen names stay in alternate names** (Shane, 2026-09-28). Wikidata P742 is unchanged.
19. **Deferred to later increments, as the spec orders them:**
    - Increment 4: the `EnrichJob` hand-off. The spec's "a paused `ViafJob` enqueues `EnrichJob` at once" lands with `EnrichJob`. Until then the chain ends at `ViafJob`, or at the `via_viaf` Wikidata run.
    - Increment 5: dropping records a rejected decision selected.
20. **Merged clusters are still cached under the superseded id** (a known deviation in the client doc). The stamped id still resolves through VIAF's redirect, and re-keying stays deferred.

## Review Focus

These are the failure modes most likely to bite that no task's main path exercises. Each is pinned by a test in the named task.

1. **A rescheduled run must not repeat VIAF requests.** An AutoSuggest answer is cached for a day, and a stored cluster is read even while VIAF is paused. Task 2.
2. **One person, many AutoSuggest rows, and duplicate clusters.** Rows are grouped by VIAF id. Two clusters with equal headings do not satisfy the rule, and the AI sees both. Task 5.
3. **VIAF's unknown markers** (`0`, `"18XX"`, a flourished span, BCE) are never applied as years. Tasks 1 and 6.
4. **A Cloudflare block mid-run.** Every later call stops at the gate. A repeat block doubles the pause up to a day. A real answer resets the doubling, and a Cloudflare page does not. Task 2.
5. **The Wikidata ↔ VIAF loop.** `via_viaf` stops a second Wikidata miss from re-enqueueing VIAF. `ViafJob` enqueues Wikidata only for a Wikidata id this run newly stamped. Tasks 6 and 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/viaf/distiller.rb` | Also keeps work titles; `SCHEMA_VERSION` 2 |
| `app/lib/viaf/person.rb` | `titles`, `date_type`, `lived?`, `country_codes`, `agency_count`; unknown dates are nil |
| `app/lib/viaf/suggestion.rb` | Reads an en dash in heading dates |
| `app/lib/viaf/cluster.rb` | Stores the gzipped raw response beside the payload |
| `app/lib/viaf/exceptions.rb` | `RateLimited` (deliberately outside `Error`) |
| `app/lib/viaf/gate.rb` | Redis-held pause: Cloudflare block (doubling) and low budget |
| `app/lib/viaf/client.rb` | The jobs' client: gated `get`, `suggest` (cached a day), `cluster` |
| `app/lib/services/books/authors/fact_sheet.rb` | Fill-blanks ledger shared by the appliers |
| `app/lib/services/books/authors/author_profile.rb` | Our names, titles and one-line summary for matching |
| `app/lib/services/books/authors/apply_wikidata.rb` | Uses `FactSheet` (no behaviour change) |
| `app/lib/services/books/authors/resolve_wikidata.rb` | Uses `AuthorProfile` (no behaviour change) |
| `app/lib/services/books/authors/viaf_names.rb` | Word-set comparison, natural order, Latin-script check |
| `app/lib/services/books/authors/resolve_viaf.rb` | Held id, AutoSuggest grouped by cluster, rule or AI, `MatchDecision` |
| `app/lib/services/books/authors/apply_viaf.rb` | Fill identifiers, years, gender, countries, alternate names |
| `app/lib/services/books/authors/enrich_from_viaf.rb` | One run, one ledger row |
| `app/sidekiq/books/authors/viaf_job.rb` | Runs the runner on `low`; reschedules on `RateLimited`; sends a new Wikidata id back |
| `app/sidekiq/books/authors/wikidata_job.rb` | `via_viaf`; enqueues `ViafJob` on a miss |
| `app/lib/data_importers/finder_registry.rb` | The "VIAF link" external-link entry |
| `test/support/viaf_builders.rb` | Builds `Viaf::Person` and `Viaf::Suggestion` for tests |
| `test/support/fake_viaf_client.rb` | Fake `Viaf::Client` recording calls |
| `docs/features/books-author-enrichment.md`, `docs/features/viaf-api-client.md` | Feature docs |

---

### Task 1: VIAF client: work titles, unknown dates, en-dash headings, raw storage

**Files:**
- Modify: `app/lib/viaf/distiller.rb`
- Modify: `app/lib/viaf/person.rb`
- Modify: `app/lib/viaf/suggestion.rb`
- Modify: `app/lib/viaf/cluster.rb`
- Test: `test/lib/viaf/distiller_test.rb`, `test/lib/viaf/person_test.rb`, `test/lib/viaf/suggestion_test.rb`, `test/lib/viaf/cluster_test.rb`

**Interfaces:**
- Consumes: `ExternalRecord#raw_text=` (gzips on write) and `#raw_text` (increment 2).
- Produces:
  - `Viaf::Distiller::SCHEMA_VERSION == 2`, and a payload key `"titles"` (Array of String, at most 200).
  - `Viaf::Person` gains:
    - `#titles` (Array of String)
    - `#date_type` (String or nil)
    - `#lived?` (Boolean)
    - `#country_codes` (upcased two-letter values, Array)
    - `#agency_count` (Integer: source codes other than `WKP`)
  - `Viaf::Person#birth_year` and `#death_year` return nil for `0`, `"0"` and partial dates.
  - `Viaf::Suggestion#birth_year` and `#death_year` read an en dash.
  - `Viaf::Cluster#find` stores `raw` as well as `payload`.

- [ ] **Step 1: Write the failing tests**

Add to `test/lib/viaf/distiller_test.rb` (the file's `distill(overrides)` helper deep-merges into a real cluster shape):

```ruby
  # Shape observed 2026-09-28: titles.work[] with per-work sources.
  test "keeps work titles, most-catalogued first, without authority-id titles" do
    result = distill({"ns1:VIAFCluster" => {"ns1:titles" => {"ns1:work" => [
      {"ns1:sources" => {"ns1:s" => "NDL"}, "ns1:title" => "n2021040535"},
      {"ns1:sources" => {"ns1:s" => "BNF"}, "ns1:title" => "Forget me not : a novel"},
      {"ns1:sources" => {"ns1:s" => ["LC", "BNF", "DNB"]}, "ns1:title" => "A Flicker in the Dark"},
      {"ns1:sources" => {"ns1:s" => ["LC", "BNF"]}, "ns1:title" => 1984}
    ]}}})

    assert_equal ["A Flicker in the Dark", "1984", "Forget me not : a novel"], result["titles"]
  end

  test "keeps at most 200 titles" do
    works = (1..205).map { |n| {"ns1:sources" => {"ns1:s" => "LC"}, "ns1:title" => "Work #{n}"} }

    assert_equal 200, distill({"ns1:VIAFCluster" => {"ns1:titles" => {"ns1:work" => works}}})["titles"].size
  end

  test "a cluster without titles distills an empty list" do
    assert_equal [], distill["titles"]
  end
```

Add to `test/lib/viaf/person_test.rb` (the file has `payload(overrides)` and `person(overrides)` helpers):

```ruby
  # Observed 2026-09-28: a living author's cluster sends deathDate 0.
  test "an unknown date is no year" do
    living = person("birth_date" => "1991-01-30", "death_date" => 0)

    assert_equal [1991, nil], [living.birth_year, living.death_year]
    assert_nil person("birth_date" => "0").birth_year
  end

  test "a partial date is no year" do
    assert_nil person("birth_date" => "18XX").birth_year
  end

  test "only dates VIAF types as lived are life dates" do
    assert person("date_type" => "lived").lived?
    assert_not person("date_type" => "flourished").lived?
    assert_not person("date_type" => nil).lived?
  end

  test "exposes titles, two-letter country codes, and how many sources other than Wikidata contribute" do
    subject = person(
      "titles" => ["War and Peace"],
      "nationality" => ["RU", "ru", "Rusko", "XX"],
      "source_ids" => {"LC" => "n1", "WKP" => "Q7243", "DNB" => "1"}
    )

    assert_equal ["War and Peace"], subject.titles
    assert_equal ["RU", "XX"], subject.country_codes
    assert_equal 2, subject.agency_count
  end

  test "a payload without titles has none" do
    assert_equal [], person.titles
  end
```

Add to `test/lib/viaf/suggestion_test.rb` (the file has a `result(overrides)` helper):

```ruby
  # Observed 2026-09-28: newer rows write the open range with an en dash.
  test "reads a birth year before an en dash" do
    subject = Viaf::Suggestion.from_result(result("term" => "Stacy Willingham 1991–"))

    assert_equal [1991, nil], [subject.birth_year, subject.death_year]
  end

  test "reads a closed range written with an en dash" do
    subject = Viaf::Suggestion.from_result(result("term" => "Tolstoy, Leo, 1828–1910"))

    assert_equal [1828, 1910], [subject.birth_year, subject.death_year]
  end
```

Add to `test/lib/viaf/cluster_test.rb`. The file's `raw_response` is the full client response, with the body under `:data`:

```ruby
  test "stores the complete response, gzipped, beside the distilled payload" do
    @client.stubs(:get).returns(raw_response)

    @cluster.find("96987389")

    record = ExternalRecord.find_by!(source: :viaf, source_id: "96987389")
    assert_equal JSON.parse(JSON.generate(raw_response[:data])), JSON.parse(record.raw_text)
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/viaf/`
Expected: the new tests FAIL:
- `titles` missing;
- year 0 returned;
- `lived?`, `country_codes`, `agency_count` and `titles` undefined;
- the en-dash years nil;
- `raw_text` nil.

- [ ] **Step 3: Implement**

`app/lib/viaf/distiller.rb`:
- Set `SCHEMA_VERSION = 2`.
- Add two constants under `NAME_SUBFIELD_CODES`:

```ruby
    TITLE_LIMIT = 200
    # A "title" that is only an authority id: NDL files LC's record number
    # ("n2021040535") as one of its works.
    ID_LIKE_TITLE = /\A\p{L}{0,3}\s?\d{6,}\z/
```

- Add `"titles" => titles(cluster)` as the last key of the payload hash in `call`.
- Add this method after `text_values`:

```ruby
    # Work titles, the most-catalogued first: how many sources list a work is
    # the best signal of what the person is known for. A title that parses as
    # a number ("1984") arrives as an Integer.
    def titles(cluster)
      works = Normalizer.array(cluster.dig("titles", "work")).filter_map do |work|
        next unless work.is_a?(Hash)

        title = work["title"].to_s.squish
        next if title.blank? || title.match?(ID_LIKE_TITLE)

        [title, Normalizer.array(work.dig("sources", "s")).size]
      end
      works.each_with_index.sort_by { |(_title, count), index| [-count, index] }
        .map { |(title, _count), _index| title }.uniq.first(TITLE_LIMIT)
    end
```

- Add `:titles` to the `private_class_method` list.

`app/lib/viaf/person.rb`:
- Add `:date_type` and `:titles` to the `attr_reader` list.
- In `initialize`, add `@date_type = payload["date_type"]` and `@titles = payload["titles"] || []`.
- Add `ISO_CODE = /\A[A-Za-z]{2}\z/` under `NAME_TYPE_KINDS`.
- Add these public methods after `wikidata_qid`:

```ruby
    # The dates are life dates, not a "flourished" span.
    def lived? = date_type.to_s.casecmp?("lived")

    # Nationality values that are ISO 3166 alpha-2 codes. The rest is free
    # text in the cataloguing library's language ("Stany Zjednoczone").
    def country_codes = nationality.map(&:to_s).select { |value| value.match?(ISO_CODE) }.map(&:upcase).uniq

    # Contributing sources other than Wikidata: how widely catalogued the person is.
    def agency_count = source_ids.keys.count { |code| code != "WKP" }
```

- Replace `year_from` and its comment:

```ruby
    # Dates are strings at day precision ("1828-09-09") and integers at year
    # precision (1473). Negative years occur. VIAF sends 0 for an unknown
    # date (a living person's death), and a partial date ("18XX") carries no
    # year, so both are nil.
    def year_from(value)
      return nil if value.nil?
      return value.nonzero? if value.is_a?(Integer)

      match = value.to_s.match(/\A(-?\d{3,4})(?!\d)/)
      match && match[1].to_i.nonzero?
    end
```

`app/lib/viaf/suggestion.rb`: in `date_range`, accept an en dash as well as a hyphen:

```ruby
        if (match = text.match(/(\d{3,4})\s*[-–]\s*(\d{3,4})?/))
          [match[1].to_i, match[2]&.to_i]
        elsif (match = text.match(/[-–]\s*(\d{3,4})/))
          [nil, match[1].to_i]
```

and add to its comment: `Newer AutoSuggest rows write the range with an en dash ("Stacy Willingham 1991–").`

`app/lib/viaf/cluster.rb`:
- Replace `fetch_and_distill` and `store` so the raw body is kept.
- Keep the long race comment above `store`, and add one line to it: `The raw body is stored gzipped beside the payload (spec §3).`

```ruby
    def find(viaf_id, refresh: false)
      id = viaf_id.to_s
      raise ArgumentError, "viaf_id cannot be blank" if id.blank?

      record = ExternalRecord.find_by(source: :viaf, source_id: id) unless refresh
      return Person.from_payload(record.payload) if record && current_schema?(record)

      data = @client.get("viaf/#{id}")[:data]
      payload = Distiller.call(data, requested_id: id)
      store(id, payload, data)
      Person.from_payload(payload)
    end
```

```ruby
    def store(id, payload, data)
      record = ExternalRecord.find_or_initialize_by(source: :viaf, source_id: id)
      record.payload = payload
      record.raw_text = JSON.generate(data)
      record.schema_version = Distiller::SCHEMA_VERSION
      record.fetched_at = Time.current
      record.save!
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.debug { "Viaf::Cluster: lost the race caching viaf source_id=#{id}: #{e.class}" }
    end
```

- [ ] **Step 4: Fix the cluster tests that relied on schema version 1**

The column defaults to `1`, so a cached row a test creates without `schema_version` is now stale and gets refetched. In `test/lib/viaf/cluster_test.rb`, add `schema_version: Viaf::Distiller::SCHEMA_VERSION` to every `ExternalRecord.create!` meant as a *current* cache hit. Among them are "does not hit the network on a cache hit" and "a cache hit and a fresh fetch produce equal people". Leave the `schema_version: 0` row in the stale-schema test alone.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/viaf/`
Expected: PASS, no warnings.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/viaf test/lib/viaf
git add app/lib/viaf test/lib/viaf
git commit -m "VIAF client: keep work titles, read unknown dates as none, en-dash headings, store raw clusters

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `Viaf::Gate` and `Viaf::Client`, the jobs' paced and paused client

**Files:**
- Modify: `app/lib/viaf/exceptions.rb`
- Create: `app/lib/viaf/gate.rb`
- Create: `app/lib/viaf/client.rb`
- Test: `test/lib/viaf/gate_test.rb`, `test/lib/viaf/client_test.rb`

**Interfaces:**
- Consumes:
  - `Viaf::BaseClient.new(config = nil, rate_limiter:)`, `#get(path, params)` (returns `{data:, …}`) and `#last_rate_limit` (`{limit:, remaining:, remaining_day:}`).
  - `Viaf::RateLimiter.new(mode:)`.
  - `Viaf::Search::AutoSuggest.new(client)` and `Viaf::Cluster.new(client)`: both call only `client.get`.
  - `DistributedRateLimiter::RateLimitExceeded#retry_after` (Float seconds).
- Produces:
  - `Viaf::Exceptions::RateLimited < StandardError`, with `#retry_after` (Integer seconds).
  - `Viaf::Gate.new(redis: nil)`: `#wait_seconds` (Integer or nil), `#blocked!` (returns the pause in seconds), `#observe(rate_limit)`.
  - `Viaf::Client.new(base_client: nil, gate: nil, cache: Rails.cache)`:
    - `#suggest(query)`: Array of `Viaf::Suggestion`.
    - `#cluster(viaf_id, refresh: false)`: a `Viaf::Person`. Raises `NotFoundError` or `AbandonedRecordError` for a gone cluster.
    - `#get(path, params = {})`
    - `#last_rate_limit`
    - Every VIAF call can raise `RateLimited`.

- [ ] **Step 1: Write the failing gate tests**

`test/lib/viaf/gate_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::GateTest < ActiveSupport::TestCase
  # CI has no Redis. FakeRedis implements the hash commands the gate uses
  # and models expiry against Time.current, so travel exercises it.
  def setup
    @gate = Viaf::Gate.new(redis: Books::OpenLibrary::FakeRedis.new)
  end

  def budget(left) = {limit: 1003, remaining: left, remaining_day: left}

  test "is open until something closes it" do
    assert_nil @gate.wait_seconds
  end

  test "a Cloudflare block pauses every call for an hour" do
    assert_equal 3600, @gate.blocked!
    assert_in_delta 3600, @gate.wait_seconds, 1

    travel 3601.seconds
    assert_nil @gate.wait_seconds
  end

  test "each repeat block doubles the pause, up to a day" do
    pauses = 7.times.map do
      seconds = @gate.blocked!
      travel((seconds + 1).seconds)
      seconds
    end

    assert_equal [3600, 7200, 14_400, 28_800, 57_600, 86_400, 86_400], pauses
  end

  test "a real VIAF answer resets the doubling" do
    @gate.blocked!
    travel 3601.seconds
    @gate.observe(budget(900))

    assert_equal 3600, @gate.blocked!
  end

  test "an answer without budget headers, as Cloudflare's page has none, resets nothing" do
    @gate.blocked!
    travel 3601.seconds
    @gate.observe({limit: nil, remaining: nil, remaining_day: nil})
    @gate.observe(nil)

    assert_equal 7200, @gate.blocked!
  end

  test "fewer than 50 requests left for the day pauses an hour, reading the smaller of the two counts" do
    @gate.observe({limit: 1003, remaining: 900, remaining_day: 49})

    assert_in_delta 3600, @gate.wait_seconds, 1
  end

  test "50 or more left leaves it open" do
    @gate.observe(budget(50))

    assert_nil @gate.wait_seconds
  end

  test "a low budget never shortens a longer block" do
    @gate.blocked!
    @gate.blocked!
    @gate.observe(budget(10))

    assert_in_delta 7200, @gate.wait_seconds, 2
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/viaf/gate_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Gate`.

- [ ] **Step 3: Implement the exception and the gate**

Append to `Viaf::Exceptions` in `app/lib/viaf/exceptions.rb`, after `AbandonedRecordError`:

```ruby
    # Not a failure: VIAF is paused (a Cloudflare block, or the day's budget
    # running low) or our own pace is busy. Deliberately outside Error, so a
    # rescue of Error never swallows it; the job reschedules itself for
    # retry_after seconds.
    class RateLimited < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        super(message)
        @retry_after = retry_after
      end
    end
```

`app/lib/viaf/gate.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # Whether VIAF may be called now (spec §8). Held in Redis so every worker
  # sees it; two things close it:
  # - A Cloudflare block (403): an hour, doubling on each repeat up to a day.
  #   Retrying a block did not recover it within 9.5 minutes and may extend
  #   the ban, so nothing calls VIAF until the pause ends. A real VIAF answer
  #   (one carrying budget headers) resets the doubling.
  # - The day's budget running low (under LOW_BUDGET requests left): an hour.
  # One hash, so the two share a clock and a low budget never shortens a block.
  class Gate
    KEY = "viaf:pause"
    FIRST_BLOCK = 3600
    MAX_BLOCK = 86_400
    LOW_BUDGET = 50
    LOW_BUDGET_PAUSE = 3600
    # How long the doubling is remembered after the last write.
    MEMORY = 2 * MAX_BLOCK

    def initialize(redis: nil)
      @redis = redis || REDIS_POOL
    end

    # Seconds until VIAF may be called, or nil when it may be called now.
    def wait_seconds
      remaining = state["until"].to_i - now
      remaining.positive? ? remaining : nil
    end

    # Records a Cloudflare block. Returns the pause in seconds.
    def blocked!
      previous = state["block_seconds"].to_i
      seconds = previous.positive? ? [previous * 2, MAX_BLOCK].min : FIRST_BLOCK
      Rails.logger.warn("Viaf::Gate: Cloudflare blocked VIAF; pausing every VIAF call for #{seconds}s")
      write("block_seconds" => seconds)
      pause_for(seconds)
      seconds
    end

    # Reads the budget headers of the last response
    # (Viaf::BaseClient#last_rate_limit). A response without them came from
    # Cloudflare, not VIAF, and changes nothing.
    def observe(rate_limit)
      left = [rate_limit&.dig(:remaining), rate_limit&.dig(:remaining_day)].compact.min
      return if left.nil?

      write("block_seconds" => 0)
      pause_for(LOW_BUDGET_PAUSE) if left < LOW_BUDGET
    end

    private

    def pause_for(seconds)
      target = now + seconds
      write("until" => target) if target > state["until"].to_i
    end

    def state = with_redis { |redis| redis.hgetall(KEY) }

    def write(fields)
      with_redis do |redis|
        fields.each { |field, value| redis.hset(KEY, field, value.to_s) }
        redis.expire(KEY, MEMORY)
      end
    end

    def now = Time.current.to_i

    def with_redis(&block)
      @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
    end
  end
end
```

- [ ] **Step 4: Run the gate tests to verify they pass**

Run: `bin/rails test test/lib/viaf/gate_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing client tests**

`test/lib/viaf/client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::ClientTest < ActiveSupport::TestCase
  RATE = {limit: 1003, remaining: 900, remaining_day: 900}.freeze

  def setup
    @base = mock("base_client")
    @base.stubs(:last_rate_limit).returns(RATE)
    @gate = mock("gate")
    @gate.stubs(:wait_seconds).returns(nil)
    @gate.stubs(:observe)
    @client = Viaf::Client.new(base_client: @base, gate: @gate, cache: ActiveSupport::Cache::MemoryStore.new)
  end

  def suggest_response
    {data: {"result" => [{"viafid" => "1", "term" => "Stacy Willingham", "displayForm" => "Stacy Willingham", "nametype" => "personal"}]}}
  end

  test "the default transport paces in immediate mode, so no worker thread sleeps" do
    Viaf::RateLimiter.expects(:new).with(mode: :immediate).returns(stub(wait!: nil))

    Viaf::Client.new(gate: @gate)
  end

  test "asks nothing of VIAF while the gate is closed, and carries the wait" do
    @gate.stubs(:wait_seconds).returns(600)
    @base.expects(:get).never

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 600, error.retry_after
  end

  test "reads the budget headers after every answer, a 404 included" do
    @base.expects(:get).raises(Viaf::Exceptions::NotFoundError.new("Not found", 404))
    @gate.expects(:observe).with(RATE)

    assert_raises(Viaf::Exceptions::NotFoundError) { @client.get("viaf/1") }
  end

  test "a busy pace becomes RateLimited with its wait, rounded up" do
    @base.stubs(:get).raises(::DistributedRateLimiter::RateLimitExceeded.new("busy", key: "viaf:api", retry_after: 12.2))

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 13, error.retry_after
  end

  test "a Cloudflare block closes the gate and becomes RateLimited for the whole pause" do
    @base.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403))
    @gate.expects(:blocked!).returns(7200)

    error = assert_raises(Viaf::Exceptions::RateLimited) { @client.get("viaf/1") }

    assert_equal 7200, error.retry_after
  end

  test "RateLimited is not a VIAF error, so a rescue of Error never swallows it" do
    assert_not_kind_of Viaf::Exceptions::Error, Viaf::Exceptions::RateLimited.new("wait", retry_after: 1)
  end

  test "an AutoSuggest answer is cached for a day, so a rescheduled run asks once" do
    @base.expects(:get).with("viaf/AutoSuggest", {query: "Stacy Willingham"}).twice.returns(suggest_response)

    2.times { assert_equal ["1"], @client.suggest("Stacy Willingham").map(&:viaf_id) }
    travel 1.day + 1.second
    @client.suggest("Stacy Willingham")
  end

  test "a stored cluster is read while VIAF is paused" do
    ExternalRecord.create!(source: :viaf, source_id: "1", payload: {"viaf_id" => "1", "name_type" => "Personal"},
      schema_version: Viaf::Distiller::SCHEMA_VERSION, fetched_at: Time.current)
    @gate.stubs(:wait_seconds).returns(600)
    @base.expects(:get).never

    assert_equal "1", @client.cluster("1").viaf_id
  end

  test "a cluster not held is fetched through the gate" do
    @gate.stubs(:wait_seconds).returns(600)

    assert_raises(Viaf::Exceptions::RateLimited) { @client.cluster("2") }
  end
end
```

- [ ] **Step 6: Run them to verify they fail**

Run: `bin/rails test test/lib/viaf/client_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Client`.

- [ ] **Step 7: Implement the client**

`app/lib/viaf/client.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # The VIAF client background jobs use (spec §8). AutoSuggest and cluster
  # fetches go through BaseClient behind the Gate and an :immediate pace, so
  # no worker thread sleeps and nothing calls VIAF while it is paused. A
  # closed gate, a busy pace or a Cloudflare block raises RateLimited, which
  # the job turns into a reschedule. Every answer is kept (clusters in
  # external_records by Viaf::Cluster, AutoSuggest answers in the cache for a
  # day), so a rescheduled run resumes without repeating a request, and a
  # stored cluster is read even while VIAF is paused.
  class Client
    SUGGEST_TTL = 1.day

    def initialize(base_client: nil, gate: nil, cache: Rails.cache)
      @base_client = base_client || BaseClient.new(rate_limiter: RateLimiter.new(mode: :immediate))
      @gate = gate || Gate.new
      @cache = cache
    end

    def suggest(query)
      @cache.fetch(["viaf", "suggest", query.to_s.squish.downcase], expires_in: SUGGEST_TTL) do
        Search::AutoSuggest.new(self).call(query)
      end
    end

    def cluster(viaf_id, refresh: false) = Cluster.new(self).find(viaf_id, refresh: refresh)

    def last_rate_limit = @base_client.last_rate_limit

    # BaseClient#get behind the gate: the transport AutoSuggest and Cluster call.
    def get(path, params = {})
      wait = @gate.wait_seconds
      raise Exceptions::RateLimited.new("VIAF is paused for #{wait}s", retry_after: wait) if wait

      begin
        @base_client.get(path, params)
      ensure
        @gate.observe(@base_client.last_rate_limit)
      end
    rescue ::DistributedRateLimiter::RateLimitExceeded => e
      raise Exceptions::RateLimited.new("VIAF pace busy", retry_after: [e.retry_after.to_f.ceil, 1].max)
    rescue Exceptions::BlockedError
      seconds = @gate.blocked!
      raise Exceptions::RateLimited.new("Cloudflare blocked VIAF; every VIAF call is paused for #{seconds}s", retry_after: seconds)
    end
  end
end
```

- [ ] **Step 8: Run the tests, zeitwerk and lint**

Run: `bin/rails test test/lib/viaf/ && CI=1 bin/rails zeitwerk:check && bundle exec standardrb app/lib/viaf test/lib/viaf`
Expected: PASS; "All is good!"; no offenses.

- [ ] **Step 9: Commit**

```bash
git add app/lib/viaf test/lib/viaf
git commit -m "VIAF: a Redis-held gate (block doubling, low budget) and the jobs' gated client

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Extract `FactSheet` and `AuthorProfile` from the Wikidata step (no behaviour change)

**Files:**
- Create: `app/lib/services/books/authors/fact_sheet.rb`
- Create: `app/lib/services/books/authors/author_profile.rb`
- Modify: `app/lib/services/books/authors/apply_wikidata.rb`
- Modify: `app/lib/services/books/authors/resolve_wikidata.rb`
- Test: `test/lib/services/books/authors/fact_sheet_test.rb`, `test/lib/services/books/authors/author_profile_test.rb`

**Interfaces:**
- Consumes: `::Services::DuplicateCandidates::Flag.call(item_type:, ids:, source:, evidence:, match_decision:)`, `::Services::Books::CountryLookup::Result` (`countries`, `unmatched`) and `::Books::RankingConfiguration.default_primary`.
- Produces:
  - `Services::Books::Authors::FactSheet.new(author)`, with readers `#author`, `#facts` (Hash) and `#applied` (Array of fact names).
    - `#record(name, value, applied:, reason:, **extra)`
    - `#identifier_values(type)` returns an Array of String.
    - `#stamp(type, value)` returns `"filled"`, `"already_set"` or `"held_by_other"`.
    - `#single_identifier(name, type, value)`
    - `#year(name, value)`
    - `#gender(value, **source)`
    - `#alternate_names(offered, cap:)`
    - `#countries(values, **source) { |values| CountryLookup::Result }`
    - `#flag_collisions(reason:, decision:)`
    - The caller saves the author.
  - `Services::Books::Authors::AuthorProfile.new(author)`:
    - `#names`: name then alternates, squished, non-blank.
    - `#titles`: up to 50, ranked first, each followed by its alternate titles.
    - `#line`: the query line `SelectExternalRecordTask` is given.
  - `AuthorProfile.lifespan(birth, death)` returns a String or nil.

This task changes no behaviour. **Every existing test in `apply_wikidata_test.rb`, `resolve_wikidata_test.rb` and `enrich_from_wikidata_test.rb` must pass unmodified.** Do not edit those files.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/authors/fact_sheet_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class FactSheetTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Fact Sheet Author")
          @sheet = FactSheet.new(@author)
        end

        def lookup(countries, unmatched = []) = ::Services::Books::CountryLookup::Result.new(countries: countries, unmatched: unmatched)

        test "records one fact per field, extras stringified, and lists the applied ones" do
          @sheet.record("birth_year", 1900, applied: true, reason: "filled", source: {kind: "test"})
          @sheet.record("gender", nil, applied: false, reason: "null")

          assert_equal({"value" => 1900, "applied" => true, "reason" => "filled", "source" => {"kind" => "test"}}, @sheet.facts["birth_year"])
          assert_equal ["birth_year"], @sheet.applied
        end

        test "stamps a new identifier and reports one already held" do
          assert_equal "filled", @sheet.stamp("books_author_viaf", "123")
          @author.save!

          assert_equal "already_set", @sheet.stamp("books_author_viaf", "123")
          assert_equal ["123"], @author.reload.identifiers.where(identifier_type: "books_author_viaf").pluck(:value)
        end

        test "never stamps an identifier another author holds, and flags the pair" do
          other = ::Books::Author.create!(name: "Other Holder")
          other.identifiers.create!(identifier_type: "books_author_viaf", value: "123")
          ::Services::DuplicateCandidates::Flag.expects(:call).with(
            item_type: "Books::Author", ids: [@author.id, other.id], source: :external_key_collision,
            evidence: {reason: "VIAF 123 is held by another author", identifiers: [{"type" => "books_author_viaf", "value" => "123"}]},
            match_decision: nil
          )

          assert_equal "held_by_other", @sheet.stamp("books_author_viaf", "123")
          @sheet.flag_collisions(reason: "VIAF 123 is held by another author", decision: nil)
          @author.save!

          assert_empty @author.reload.identifiers
        end

        test "a single-value identifier: blank is null, a different stored value is a conflict" do
          @sheet.single_identifier("isni", "books_author_isni", nil)
          assert_equal "null", @sheet.facts["isni"]["reason"]

          @author.identifiers.create!(identifier_type: "books_author_isni", value: "0000000100000001")
          @sheet.single_identifier("isni", "books_author_isni", "0000000100000002")

          assert_equal ["conflict", ["0000000100000001"]], @sheet.facts["isni"].values_at("reason", "stored")
        end

        test "fills a blank year, keeps an equal one, records a disagreeing one" do
          @author.death_year = 1950
          @sheet.year("birth_year", 1900)
          @sheet.year("death_year", 1951)

          assert_equal [1900, "filled"], [@author.birth_year, @sheet.facts["birth_year"]["reason"]]
          assert_equal [1950, "conflict", 1950], [@author.death_year, *@sheet.facts["death_year"].values_at("reason", "stored")]

          @sheet.year("birth_year", 1900)
          assert_equal "already_set", @sheet.facts["birth_year"]["reason"]
        end

        test "fills gender over a blank or unspecified one, records its source, and never overwrites" do
          @author.gender = :unspecified
          @sheet.gender("female", viaf: "a")
          assert_equal ["female", "filled", "a"], [@author.gender, *@sheet.facts["gender"].values_at("reason", "viaf")]

          @sheet.gender("male", viaf: "b")
          assert_equal ["female", "conflict", "female"], [@author.gender, *@sheet.facts["gender"].values_at("reason", "stored")]
        end

        test "adds new alternate names up to the cap, in stored form, skipping the author's own" do
          @sheet.alternate_names(["fact sheet author", "F. S. Author", "Flannery O’Connor", "Third Name"], cap: 2)

          assert_equal ["F. S. Author", "Flannery O'Connor"], @author.alternate_names
          assert_equal [true, "filled", 4], @sheet.facts["alternate_names"].values_at("applied", "reason", "offered")
        end

        test "no alternate names offered is null; nothing new is already_set" do
          @sheet.alternate_names(["", nil], cap: 10)
          assert_equal "null", @sheet.facts["alternate_names"]["reason"]

          @sheet.alternate_names(["Fact Sheet Author"], cap: 10)
          assert_equal "already_set", @sheet.facts["alternate_names"]["reason"]
        end

        test "fills countries through the lookup, recording what did not match and the source" do
          country = ::Books::Country.create!(name: "Fact Sheet Country")

          @sheet.countries(["FS", "XX"], viaf: ["FS", "XX"]) { |values| lookup([country], values - ["FS"]) }
          @author.save!

          assert_equal [country], @author.reload.countries.to_a
          assert_equal [["Fact Sheet Country"], ["XX"], ["FS", "XX"]], @sheet.facts["countries"].values_at("value", "unmatched", "viaf")
        end

        test "an author with countries is already_set, and the lookup never runs" do
          @author.author_countries.create!(country: ::Books::Country.create!(name: "Held Country"))

          @sheet.countries(["FS"]) { flunk "the lookup must not run" }

          assert_equal "already_set", @sheet.facts["countries"]["reason"]
        end

        test "no values is null, and a lookup matching nothing is no_match" do
          @sheet.countries([]) { flunk "the lookup must not run" }
          assert_equal "null", @sheet.facts["countries"]["reason"]

          @sheet.countries(["ZZ"]) { lookup([], ["ZZ"]) }
          assert_equal ["no_match", ["ZZ"]], @sheet.facts["countries"].values_at("reason", "unmatched")
        end
      end
    end
  end
end
```

`test/lib/services/books/authors/author_profile_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class AuthorProfileTest < ActiveSupport::TestCase
        test "names are the name then the alternate names, squished, without blanks" do
          author = ::Books::Author.new(name: "Leo  Tolstoy", alternate_names: ["Lev Tolstoy", " "])

          assert_equal ["Leo Tolstoy", "Lev Tolstoy"], AuthorProfile.new(author).names
        end

        test "titles come ranked first, each followed by its alternate titles" do
          author = ::Books::Author.create!(name: "Profile Author")
          unranked = ::Books::Book.create!(title: "Unranked Book")
          ranked = ::Books::Book.create!(title: "Ranked Book", alternate_titles: ["Ranked Alt"])
          author.book_authors.create!(book: unranked, position: 1)
          author.book_authors.create!(book: ranked, position: 2)
          RankedItem.create!(item: ranked, ranking_configuration: ranking_configurations(:books_global), rank: 1)

          assert_equal ["Ranked Book", "Ranked Alt", "Unranked Book"], AuthorProfile.new(author).titles
        end

        test "the line names the author, alternates, years, titles and countries" do
          line = AuthorProfile.new(books_authors(:tolstoy)).line

          assert_equal "Leo Tolstoy | also known as Lev Tolstoy, Lev Nikolayevich Tolstoy | 1828–1910 | wrote: War and Peace; Voyna i mir",
            line.split(" | countries: ").first
        end

        test "a lifespan shows an unknown birth as a question mark and a living author open-ended" do
          assert_equal ["?–1910", "1991–"], [AuthorProfile.lifespan(nil, 1910), AuthorProfile.lifespan(1991, nil)]
          assert_nil AuthorProfile.lifespan(nil, nil)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/fact_sheet_test.rb test/lib/services/books/authors/author_profile_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::Authors::FactSheet` (and `AuthorProfile`).

- [ ] **Step 3: Implement `FactSheet`**

`app/lib/services/books/authors/fact_sheet.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The fill-blanks bookkeeping every author applier shares (spec §1):
      # one ledger fact per field, a value written only into a blank, and a
      # disagreement with a stored value recorded, never applied. An
      # identifier another author already holds is never stamped; the pair is
      # remembered for flag_collisions. The caller saves the author.
      class FactSheet
        attr_reader :author, :facts, :applied

        def initialize(author)
          @author = author
          @facts = {}
          @applied = []
          @collisions = {}
        end

        def record(name, value, applied:, reason:, **extra)
          facts[name] = {"value" => value, "applied" => applied, "reason" => reason}.merge(extra.deep_stringify_keys)
          @applied << name if applied
        end

        def identifier_values(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # "filled", "already_set" or "held_by_other".
        def stamp(type, value)
          return "already_set" if identifier_values(type).include?(value)

          other = ::Identifier.where(identifiable_type: "Books::Author", identifier_type: type, value: value)
            .where.not(identifiable_id: author.id).pick(:identifiable_id)
          if other
            (@collisions[other] ||= []) << {"type" => type, "value" => value}
            return "held_by_other"
          end

          author.identifiers.find_or_initialize_by(identifier_type: type, value: value)
          "filled"
        end

        # A type the author holds one value of: a different stored value is a conflict.
        def single_identifier(name, type, value)
          return record(name, nil, applied: false, reason: "null") if value.blank?

          stored = identifier_values(type)
          return record(name, value, applied: false, reason: "conflict", stored: stored) if stored.any? && !stored.include?(value)

          reason = stamp(type, value)
          record(name, value, applied: reason == "filled", reason: reason)
        end

        def year(name, value)
          current = author.public_send(name)
          if current.nil?
            author.public_send(:"#{name}=", value)
            record(name, value, applied: true, reason: "filled")
          elsif current == value
            record(name, value, applied: false, reason: "already_set")
          else
            record(name, value, applied: false, reason: "conflict", stored: current)
          end
        end

        # "unspecified" is the legacy AI's "don't know" (334 authors), so it
        # counts as blank. `source` is recorded beside a filled value.
        def gender(value, **source)
          current = author.gender
          if current.nil? || current == "unspecified"
            author.gender = value
            record("gender", value, applied: true, reason: "filled", **source)
          elsif current == value
            record("gender", value, applied: false, reason: "already_set")
          else
            record("gender", value, applied: false, reason: "conflict", stored: current)
          end
        end

        # A union, compared after normalization and case folding only: "García"
        # and "Garcia" are both kept, since each is a spelling someone searches.
        # Each name is added, and recorded, in the form it is stored.
        def alternate_names(offered, cap:)
          offered = offered.map { |name| normalize(name.to_s.squish) }.reject(&:blank?)
          taken = ([author.name] + Array(author.alternate_names)).map { |name| normalize(name).downcase }.to_set
          added = []
          offered.each do |name|
            key = name.downcase
            next if taken.include?(key)

            taken << key
            added << name
            break if added.size >= cap
          end
          if added.empty?
            return record("alternate_names", [], applied: false, reason: offered.empty? ? "null" : "already_set", offered: offered.size)
          end

          author.alternate_names = Array(author.alternate_names) + added
          record("alternate_names", added, applied: true, reason: "filled", offered: offered.size)
        end

        # Fills only when the author has no countries. The block maps the
        # source's values to a CountryLookup::Result and runs only when needed.
        # `source` is recorded beside a filled value.
        def countries(values, **source)
          return record("countries", [], applied: false, reason: "null", unmatched: []) if values.empty?
          return record("countries", values, applied: false, reason: "already_set", unmatched: []) if author.author_countries.exists?

          lookup = yield(values)
          return record("countries", values, applied: false, reason: "no_match", unmatched: lookup.unmatched) if lookup.countries.empty?

          lookup.countries.each { |country| author.author_countries.build(country: country) }
          record("countries", lookup.countries.map(&:name), applied: true, reason: "filled", unmatched: lookup.unmatched, **source)
        end

        def flag_collisions(reason:, decision:)
          @collisions.each do |other_id, identifiers|
            ::Services::DuplicateCandidates::Flag.call(
              item_type: "Books::Author", ids: [author.id, other_id], source: :external_key_collision,
              evidence: {reason: reason, identifiers: identifiers}, match_decision: decision
            )
          end
        end

        private

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `AuthorProfile`**

`app/lib/services/books/authors/author_profile.rb`. Its `titles` body is `ResolveWikidata#our_titles`, moved verbatim:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Our side of an author, as matching evidence (spec §5.1, §5.2): its
      # names, its titles (the author's books, ranked first under the default
      # primary configuration, each followed by its alternate titles), and the
      # one line SelectExternalRecordTask is given about it.
      class AuthorProfile
        TITLE_LIMIT = 50

        def self.lifespan(birth, death)
          return nil if birth.nil? && death.nil?

          "#{birth || "?"}–#{death}"
        end

        def initialize(author)
          @author = author
        end

        def names
          ([author.name] + Array(author.alternate_names)).map { |name| name.to_s.squish }.reject(&:blank?)
        end

        def titles
          @titles ||= begin
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

        def line
          parts = [author.name]
          alternates = Array(author.alternate_names).first(5)
          parts << "also known as #{alternates.join(", ")}" if alternates.any?
          span = self.class.lifespan(author.birth_year, author.death_year)
          parts << span if span
          parts << "wrote: #{titles.first(10).join("; ")}" if titles.any?
          countries = author.countries.map(&:name)
          parts << "countries: #{countries.join(", ")}" if countries.any?
          parts.join(" | ")
        end

        private

        attr_reader :author
      end
    end
  end
end
```

- [ ] **Step 5: Move `ApplyWikidata` onto `FactSheet`**

In `app/lib/services/books/authors/apply_wikidata.rb`:
- `initialize` builds `@sheet = FactSheet.new(author)` in place of `@facts`, `@applied` and `@collisions`.
- The `attr_reader` line becomes `attr_reader :author, :entity, :decision, :sheet`.
- Delete `record`, `values_of`, `stamp`, `apply_single_identifiers`, `apply_alternate_names`, `apply_countries`, `flag_collisions` and `normalize`.
- `call`, `result`, `apply_qid`, `apply_open_library_ids`, `apply_year` and `apply_gender` become:

```ruby
        # A held id Wikidata has merged into this item is the same person, so
        # only another live id is a conflict.
        def call
          other_qids = sheet.identifier_values(QID) - [entity.id] - @redirected_ids
          if other_qids.any?
            sheet.record("wikidata_qid", entity.id, applied: false, reason: "held_qid_conflict", held: other_qids)
            return result(conflict: true)
          end

          apply_qid
          SINGLE_IDENTIFIERS.each do |type, kind|
            sheet.single_identifier(type.delete_prefix("books_author_"), type, entity.identifiers(kind).first&.delete(" "))
          end
          apply_open_library_ids
          apply_year("birth_year", entity.birth)
          apply_year("death_year", entity.death)
          apply_gender
          sheet.alternate_names([entity.label] + entity.aliases + entity.native_names + entity.pseudonyms, cap: ALTERNATE_NAME_CAP)
          sheet.countries(entity.citizenship_ids, wikidata: entity.citizenship_ids) { |ids| @country_lookup.from_wikidata(ids) }
          author.save!
          sheet.flag_collisions(reason: "Wikidata #{entity.id} lists identifiers another author already holds", decision: decision)
          result(conflict: false)
        end

        private

        attr_reader :author, :entity, :decision, :sheet

        def result(conflict:)
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied, conflict: conflict}, errors: [])
        end

        def apply_qid
          reason = sheet.stamp(QID, entity.id)
          extra = @redirected_ids.any? ? {redirected_from: @redirected_ids} : {}
          sheet.record("wikidata_qid", entity.id, applied: reason == "filled", reason: reason, **extra)
        end

        def apply_open_library_ids
          values = entity.identifiers("openlibrary").map { |value| value.delete(" ") }.uniq
          return sheet.record("openlibrary_ids", [], applied: false, reason: "null") if values.empty?

          outcomes = values.index_with { |value| sheet.stamp(OPEN_LIBRARY, value) }
          added = outcomes.select { |_value, reason| reason == "filled" }.keys
          reason = if added.any? then "filled"
          elsif outcomes.values.all?("already_set") then "already_set"
          else "held_by_other"
          end
          sheet.record("openlibrary_ids", values, applied: added.any?, reason: reason, added: added, outcomes: outcomes)
        end

        def apply_year(name, fact)
          return sheet.record(name, nil, applied: false, reason: fact.reason) if fact.year.nil?

          sheet.year(name, fact.year)
        end

        def apply_gender
          ids = entity.gender_ids
          return sheet.record("gender", nil, applied: false, reason: "null") if ids.empty?

          mapped = ids.map { |id| GENDERS[id] }.uniq
          return sheet.record("gender", ids, applied: false, reason: "unmapped") if mapped.include?(nil) || mapped.size > 1

          sheet.gender(mapped.first, wikidata: ids)
        end
```

Keep the class comment and the constants. `SINGLE_IDENTIFIERS`' comment still applies.

- [ ] **Step 6: Move `ResolveWikidata` onto `AuthorProfile`**

In `app/lib/services/books/authors/resolve_wikidata.rb`:
- Add `@profile = AuthorProfile.new(author)` to `initialize`.
- Delete `TITLE_LIMIT`, `our_titles`, `describe_author` and `lifespan`.
- Then:
  - in `attach_titles`, `ours = @profile.titles.map { |title| title_key(title) }.to_set`;
  - in `ask_ai`, `query_line: @profile.line`;
  - in `describe`, `span = AuthorProfile.lifespan(entity.birth_year, entity.death_year)`;
  - in `author_snapshot`, `"titles" => @profile.titles.first(10)`.

Run `grep -n "our_titles\|describe_author\|lifespan\|TITLE_LIMIT" app/lib/services/books/authors/resolve_wikidata.rb`. Nothing may be left except the one `AuthorProfile.lifespan` call.

- [ ] **Step 7: Run the new tests and every Wikidata-step test**

Run: `bin/rails test test/lib/services/books/authors/`
Expected: PASS. `git diff --stat test/lib/services/books/authors/apply_wikidata_test.rb test/lib/services/books/authors/resolve_wikidata_test.rb test/lib/services/books/authors/enrich_from_wikidata_test.rb` is empty.

- [ ] **Step 8: Lint and commit**

```bash
CI=1 bin/rails zeitwerk:check
bundle exec standardrb app/lib/services/books/authors test/lib/services/books/authors
git add app/lib/services/books/authors test/lib/services/books/authors
git commit -m "Extract FactSheet and AuthorProfile from the Wikidata step, unchanged in behaviour

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `ViafNames`, comparing and converting VIAF name forms

**Files:**
- Create: `app/lib/services/books/authors/viaf_names.rb`
- Test: `test/lib/services/books/authors/viaf_names_test.rb`

**Interfaces:**
- Consumes: `::Services::Text::NameNormalizer` and `::Services::Text::QuoteNormalizer` (both `.call(String)`).
- Produces: `Services::Books::Authors::ViafNames` (module functions):
  - `.words(text)`: folded words in order.
  - `.tokens(text)`: the same words, sorted.
  - `.same?(left, right)`
  - `.reordering?(name, of:)`: the same words as `of`, in a different order.
  - `.natural(heading)`: a String, or nil when the heading has no comma.
  - `.latin?(text)`

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/authors/viaf_names_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ViafNamesTest < ActiveSupport::TestCase
        test "words are letters only, case and diacritics folded, in order; tokens are sorted" do
          assert_equal ["willingham", "stacy"], ViafNames.words("Willingham, Stacy, 1991-")
          assert_equal ["stacy", "willingham"], ViafNames.tokens("Willingham, Stacy, 1991-")
          assert_equal ["tolstoi", "leon"], ViafNames.words("Tolstoï, Léon")
        end

        test "a parenthesised fuller form is dropped" do
          assert_equal ["j", "r", "r", "tolkien"], ViafNames.tokens("Tolkien, J. R. R. (John Ronald Reuel)")
        end

        test "the same name in any order, with or without the comma or dates" do
          assert ViafNames.same?("Stacy Willingham", "Willingham, Stacy")
          assert ViafNames.same?("Stacy Willingham", "Willingham Stacy")
          assert ViafNames.same?("Stacy Willingham", "Stacy Willingham 1991–")
          assert ViafNames.same?("Gabriel Garcia Marquez", "García Márquez, Gabriel")
          assert_not ViafNames.same?("Stacy Willingham", "Stacy Willingham American writer")
          assert_not ViafNames.same?("Stacy Willingham", "Stacy Willinghamová")
          assert_not ViafNames.same?("", "")
        end

        test "a reordering has the same words as a name, in another order" do
          assert ViafNames.reordering?("Yan Mo", of: "Mo Yan")
          assert_not ViafNames.reordering?("Mo Yan", of: "Mo Yan")
          assert_not ViafNames.reordering?("Léon Tolstoï", of: "Leo Tolstoy")
        end

        test "an inverted heading reads in natural order; titles and later parts are dropped" do
          assert_equal "Stacy Willingham", ViafNames.natural("Willingham, Stacy")
          assert_equal "Leo Tolstoy", ViafNames.natural("Tolstoy, Leo, graf")
          assert_equal "J. R. R. Tolkien", ViafNames.natural("Tolkien, J. R. R. (John Ronald Reuel)")
          assert_equal "Stacy Willingham", ViafNames.natural("Willingham, Stacy, 1991-")
        end

        test "a heading without a comma has no reliable order" do
          assert_nil ViafNames.natural("Willingham Stacy")
          assert_nil ViafNames.natural("Homer")
          assert_nil ViafNames.natural(", Stacy")
        end

        test "Latin script only" do
          assert ViafNames.latin?("Léon Tolstoï")
          assert ViafNames.latin?("J. R. R. Tolkien")
          assert_not ViafNames.latin?("Лев Толстой")
          assert_not ViafNames.latin?("ウィリンガム, ステイシー")
          assert_not ViafNames.latin?("1991")
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/viaf_names_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::Authors::ViafNames`.

- [ ] **Step 3: Implement**

`app/lib/services/books/authors/viaf_names.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # VIAF name forms (spec §8). Library headings come inverted ("Tolstoy,
      # Leo, graf"), sometimes without the comma ("Willingham Stacy"), with
      # fuller forms in parentheses ("Tolkien, J. R. R. (John Ronald
      # Reuel)"); AutoSuggest rows add dates and descriptions ("Stacy
      # Willingham, 1991-"). Names are compared as sorted word sets, so word
      # order, punctuation and dates never decide a comparison.
      module ViafNames
        PARENTHESISED = /\([^)]*\)/

        module_function

        # Letters-only words, case and diacritics folded, in order.
        def words(text)
          normalized = ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
          normalized.gsub(PARENTHESISED, " ").unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.scan(/\p{L}+/)
        end

        def tokens(text) = words(text).sort

        def same?(left, right)
          ours = tokens(left)
          ours.any? && ours == tokens(right)
        end

        # The same words as `of`, in another order: "Yan Mo" of "Mo Yan".
        def reordering?(name, of:)
          words(name) != words(of) && tokens(name) == tokens(of)
        end

        # "Tolstoy, Leo, graf" is "Leo Tolstoy". Titles and anything after the
        # second comma are dropped, as are parenthesised fuller forms and
        # dates. Without a comma the order is unknowable: nil.
        def natural(heading)
          text = heading.to_s.gsub(PARENTHESISED, " ").gsub(/\d[\d\s\-–?.]*/, " ")
          surname, forenames = text.split(",").map(&:squish)
          return nil if surname.blank? || forenames.blank?

          "#{forenames} #{surname}"
        end

        def latin?(text)
          letters = text.to_s.scan(/\p{L}/)
          letters.any? && letters.all? { |letter| letter.match?(/\p{Latin}/) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/viaf_names_test.rb`
Expected: PASS. If `NameNormalizer` changes a test's input in some way these expectations miss, read `app/lib/services/text/name_normalizer.rb` and fix the expectation only where the normalizer is right.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/viaf_names.rb test/lib/services/books/authors/viaf_names_test.rb
git add app/lib/services/books/authors/viaf_names.rb test/lib/services/books/authors/viaf_names_test.rb
git commit -m "ViafNames: compare VIAF name forms as word sets and read inverted headings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ResolveViaf`, the "VIAF link" audit entry, and the VIAF test fakes

**Files:**
- Create: `test/support/viaf_builders.rb`
- Create: `test/support/fake_viaf_client.rb`
- Modify: `test/test_helper.rb` (require both, after `support/fake_wikidata_client`)
- Create: `app/lib/services/books/authors/resolve_viaf.rb`
- Modify: `app/lib/data_importers/finder_registry.rb`
- Test: `test/lib/services/books/authors/resolve_viaf_test.rb`, `test/lib/data_importers/finder_registry_test.rb`, `test/controllers/admin/books/match_decisions_controller_test.rb`

**Interfaces:**
- Consumes:
  - `Viaf::Client#suggest(query)` and `#cluster(viaf_id, refresh:)` (Task 2).
  - `Viaf::Person#titles`, `#lived?`, `#country_codes`, `#agency_count` and `#kind` (Task 1).
  - `Viaf::Suggestion#viaf_id`, `#term`, `#display_form`, `#kind`, `#birth_year`, `#death_year` and `#source_ids`.
  - `AuthorProfile` (Task 3), `ViafNames` (Task 4), and `SelectExternalRecordTask.new(parent:, source_name:, entity_noun:, query_line:, candidate_lines:, guidance:).call`, which returns `Services::Ai::Result` (`success?`, `data[:selected_index]`, `data[:confidence]`, `data[:reasoning]`, `error` and `ai_chat`).
- Produces:
  - `Services::Books::Authors::ResolveViaf.call(author:, refresh: false, client: nil)` returns a `Result`. Its `data` is `{outcome: :matched | :unmatched | :failed, person: Viaf::Person or nil, decision: MatchDecision, reason: String}`.
  - Exactly one `MatchDecision` per run. `Viaf::Exceptions::RateLimited` and other `Viaf::Exceptions::Error`s propagate, and nothing is recorded.
  - A `FinderRegistry` entry "VIAF link".
  - Test helpers `viaf_person(id, …)`, `viaf_suggestion(id, term, …)` and `FakeViafClient`.

- [ ] **Step 1: Add the test support**

`test/support/viaf_builders.rb`:

```ruby
# frozen_string_literal: true

# Builds Viaf::Person and Viaf::Suggestion objects in the shapes the importer
# reads (live shapes observed 2026-09-28). A person's default sources are
# libraries the appliers never stamp, so only an explicit wikidata:, isni: or
# lc: produces an identifier.
module ViafBuilders
  def viaf_person(id, headings: [], born: nil, died: nil, date_type: "lived", gender: nil, wikidata: nil, isni: nil,
    lc: nil, nationality: [], occupations: [], titles: [], names: [], name_type: "Personal", agencies: %w[DNB BNF])
    source_ids = agencies.index_with { |code| "#{code.downcase}-#{id}" }
    source_ids["WKP"] = wikidata if wikidata
    source_ids["ISNI"] = isni if isni
    source_ids["LC"] = lc if lc
    Viaf::Person.from_payload(
      "viaf_id" => id.to_s, "name_type" => name_type, "birth_date" => born, "death_date" => died,
      "date_type" => date_type, "gender" => gender, "source_ids" => source_ids,
      "main_headings" => headings.map { |heading| heading.is_a?(Hash) ? heading : {"source" => "LC", "name" => heading} },
      "names" => names, "nationality" => nationality, "language" => [], "occupation" => occupations,
      "field_of_activity" => [], "titles" => titles
    )
  end

  def viaf_suggestion(id, term, name_type: "personal", agencies: {"lc" => "n1"})
    Viaf::Suggestion.from_result(
      {"term" => term, "displayForm" => term, "nametype" => name_type, "viafid" => id.to_s, "score" => "100"}.merge(agencies)
    )
  end
end

ActiveSupport::TestCase.include(ViafBuilders)
```

`test/support/fake_viaf_client.rb`:

```ruby
# frozen_string_literal: true

# A stand-in for Viaf::Client with canned answers. Records its calls so a test
# can assert what was (not) asked.
class FakeViafClient
  attr_reader :calls

  # suggestions: query => [Viaf::Suggestion], or an exception to raise.
  # people: viaf id => Viaf::Person, or an exception to raise. An id with no
  # entry answers NotFoundError, as VIAF does.
  def initialize(suggestions: {}, people: {})
    @suggestions = suggestions
    @people = people.transform_keys(&:to_s)
    @calls = []
  end

  def suggest(query)
    @calls << [:suggest, query]
    value = @suggestions.fetch(query, [])
    raise value if value.is_a?(Exception)

    value
  end

  def cluster(viaf_id, refresh: false)
    @calls << [:cluster, viaf_id.to_s]
    value = @people[viaf_id.to_s]
    raise value if value.is_a?(Exception)
    raise ::Viaf::Exceptions::NotFoundError.new("Not found", 404) if value.nil?

    value
  end

  def called?(method) = calls.any? { |call| call.first == method }

  def clusters = calls.select { |call| call.first == :cluster }.map(&:last)
end
```

In `test/test_helper.rb`, after `require_relative "support/fake_wikidata_client"`, add:

```ruby
require_relative "support/viaf_builders"
require_relative "support/fake_viaf_client"
```

- [ ] **Step 2: Write the failing resolver tests**

`test/lib/services/books/authors/resolve_viaf_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ResolveViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham", birth_year: 1991)
          book = ::Books::Book.create!(title: "A Flicker in the Dark")
          @author.book_authors.create!(book: book, position: 1)
        end

        def resolve(client, author: @author, refresh: false) = ResolveViaf.call(author: author, refresh: refresh, client: client)

        # Options override the defaults (merged, not double-splatted beside
        # them, which would warn about a duplicated key).
        def willingham(id = "5391", **options)
          defaults = {headings: ["Willingham, Stacy"], born: "1991-01-30", died: 0, gender: "a",
                      titles: ["A Flicker in the Dark", "All the Dangerous Things"], nationality: ["US"]}
          viaf_person(id, **defaults.merge(options))
        end

        def ai_selects(index, confidence: "high")
          result = Services::Ai::Result.new(success: true, data: {selected_index: index, confidence: confidence, reasoning: "Because.", same_entity_groups: []})
          task = mock("task")
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).with { |options| @ai_options = options }.returns(task)
        end

        test "a corroborated held id matches by identifier, certain, without searching" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          client = FakeViafClient.new(people: {"5391" => willingham})

          result = resolve(client)

          assert_equal [:matched, "5391"], [result.data[:outcome], result.data[:person].viaf_id]
          decision = result.data[:decision]
          assert_equal ["identifier", "certain", false], [decision.decided_by, decision.confidence, decision.needs_review]
          assert_not client.called?(:suggest)
        end

        test "a held id whose person disagrees on years is not decided by identifier" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          client = FakeViafClient.new(people: {"5391" => willingham(born: "1950")})
          ai_selects(0)

          result = resolve(client)

          assert_equal ["unmatched", "ai"], [result.data[:decision].outcome, result.data[:decision].decided_by]
          assert client.called?(:suggest)
        end

        test "a held id VIAF no longer serves is dropped, and the search decides" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "404")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham}
          )

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "medium"], [decision.outcome, decision.decided_by, decision.confidence]
          assert_equal ["viaf_cluster"], decision.sources_failed
          held = decision.candidates.find { |candidate| candidate["external_key"] == "404" }
          assert_equal "NotFoundError", held["evidence"]["unavailable"]
        end

        test "no person among the suggestions is unmatched by rule, and fetches nothing" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [
            viaf_suggestion("2750", "Stacy. Willingham, No salgas de noche", name_type: "uniformtitleexpression")
          ]})

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["unmatched", "rule", "high"], [decision.outcome, decision.decided_by, decision.confidence]
          assert_equal "not a person", decision.candidates.first["evidence"]["dropped"]
          assert_empty client.clusters
        end

        test "rows for one cluster are one candidate; the only one named and born as ours matches by rule" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [
              viaf_suggestion("5391", "Stacy Willingham"),
              viaf_suggestion("5391", "Stacy Willingham 1991–"),
              viaf_suggestion("5391", "Stacy Willingham American writer")
            ]},
            people: {"5391" => willingham}
          )
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "high", 1], [decision.outcome, decision.decided_by, decision.confidence, decision.candidates.size]
          assert_equal ["5391"], client.clusters
        end

        test "the rule needs our birth year" do
          author = ::Books::Author.create!(name: "Stacy Willingham Unborn")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham Unborn" => [viaf_suggestion("9", "Stacy Willingham Unborn, 1991-")]},
            people: {"9" => viaf_person("9", headings: ["Willingham Unborn, Stacy"], born: "1991")}
          )
          ai_selects(1)

          result = resolve(client, author: author)

          assert_equal ["matched", "ai"], [result.data[:decision].outcome, result.data[:decision].decided_by]
        end

        test "two clusters named as ours (a VIAF duplicate) go to the AI, which sees both and is told about duplicates" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [
              viaf_suggestion("5391", "Stacy Willingham 1991–"),
              viaf_suggestion("1375", "Stacy Willingham, 1991-", agencies: {})
            ]},
            people: {"5391" => willingham, "1375" => viaf_person("1375", headings: ["Willingham, Stacy"], born: "1991", agencies: [])}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal ["5391", "matched", "ai"], [result.data[:person].viaf_id, result.data[:decision].outcome, result.data[:decision].decided_by]
          assert_equal 2, @ai_options[:candidate_lines].size
          assert_match(/2 contributing libraries/, @ai_options[:candidate_lines].first)
          assert_match(/two records/, @ai_options[:guidance])
          assert_equal "VIAF", @ai_options[:source_name]
        end

        test "the AI is shown at most three clusters, named-as-ours first, with titles matched on the main title" do
          people = %w[1 2 3 4].to_h { |id| [id, viaf_person(id, headings: ["Other#{id}, Person"])] }
          people["5"] = willingham("5", titles: ["A flicker in the dark : a novel", "Another Book"])
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => %w[1 2 3 4].map { |id| viaf_suggestion(id, "Person Other#{id}") } +
              [viaf_suggestion("5", "Stacy Willingham")]},
            people: people
          )
          ai_selects(0)

          resolve(client)

          assert_equal 3, client.clusters.size
          assert_equal "5", client.clusters.first
          assert_match(/works matching ours: A flicker in the dark : a novel/, @ai_options[:candidate_lines].first)
          assert_match(/other works: Another Book/, @ai_options[:candidate_lines].first)
        end

        test "a suggested cluster VIAF no longer serves is never shown to the AI" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("404", "Stacy Willingham"), viaf_suggestion("5391", "S. Willingham")]},
            people: {"5391" => willingham}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal 1, @ai_options[:candidate_lines].size
          assert_equal "5391", result.data[:person].viaf_id
        end

        test "an AI choice of none is unmatched, and a medium one needs review" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => willingham})

          ai_selects(0)
          assert_equal "unmatched", resolve(client).data[:decision].outcome

          ai_selects(1, confidence: "medium")
          assert resolve(client).data[:decision].needs_review
        end

        test "a failed AI call records a failed run for review" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => willingham})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = resolve(client)

          assert_equal :failed, result.data[:outcome]
          assert_equal ["fallback", true], [result.data[:decision].decided_by, result.data[:decision].needs_review]
        end

        test "a rate limit propagates and records no decision" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::RateLimited.new("wait", retry_after: 60)})

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Viaf::Exceptions::RateLimited) { resolve(client) }
          end
        end

        test "records one decision about the author, with VIAF candidates and the selected one" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham}
          )

          decision = resolve(client).data[:decision]

          assert_equal ["Services::Books::Authors::ResolveViaf", @author, nil], [decision.finder, decision.subject, decision.record]
          selected = decision.candidates[decision.selected_index - 1]
          assert_equal ["viaf", "5391", "Stacy Willingham", 1991], [selected["external_source"], selected["external_key"],
            selected["evidence"]["external_title"], selected["evidence"]["birth_year"]]
          assert_equal "Stacy Willingham", decision.query["name"]
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/resolve_viaf_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::Authors::ResolveViaf`.

- [ ] **Step 4: Implement**

`app/lib/services/books/authors/resolve_viaf.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Which VIAF person is this author, or none (spec §8). Runs after a
      # Wikidata miss. Two stages, and the first that decides ends the run:
      # the VIAF id the author already holds, then one AutoSuggest on the
      # name. AutoSuggest answers with several rows per cluster (a plain
      # heading, one with dates, one with a description, translations), so
      # rows are grouped by VIAF id into one candidate each. A rule decides
      # when exactly one person has a heading equal to our name and a birth
      # year agreeing with ours; otherwise at most three clusters are read and
      # SelectExternalRecordTask chooses. Every run records one MatchDecision.
      # Applies nothing; Viaf::Client stores every cluster it reads.
      class ResolveViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        # suggestions: this cluster's AutoSuggest rows. unavailable: why its
        # cluster could not be read.
        Candidate = Struct.new(:viaf_id, :sources, :suggestions, :person, :matching_titles, :unavailable, keyword_init: true)
        Verdict = Struct.new(:outcome, :candidate, :decided_by, :confidence, :reason, :ai_chat, keyword_init: true)

        VIAF = "books_author_viaf"
        MAX_FETCHED = 3
        YEAR_TOLERANCE = 1
        GUIDANCE = "Our author wrote the books listed. Select a record only when the evidence ties that person to writing " \
          "these books: a matching work, or life dates that agree together with an occupation or nationality that fits. " \
          "A person who merely shares the name is someone else. VIAF often holds one person as two records; when " \
          "records describe the same person, select the one with the most contributing libraries, and do not treat " \
          "that as a tie."

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client || ::Viaf::Client.new
          @profile = AuthorProfile.new(author)
          @candidates = {}
          @sources_failed = []
        end

        def call
          record(held_stage || search_stage)
        end

        private

        attr_reader :author

        # ---- stages ---------------------------------------------------------

        def held_stage
          ids = identifier_values(VIAF)
          return nil if ids.empty?

          ids.each { |id| fetch(add(id, "held_id")) }
          held = persons.find { |candidate| candidate.sources.include?("held_id") && corroborated?(candidate) }
          return nil unless held

          Verdict.new(outcome: :matched, candidate: held, decided_by: :identifier, confidence: :certain,
            reason: "The VIAF id the author holds, #{held.viaf_id}, is a person whose name and years agree.")
        end

        def search_stage
          @client.suggest(author.name).each { |suggestion| add(suggestion.viaf_id, "name_search").suggestions << suggestion }
          pool = persons
          if pool.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "No person among #{@candidates.size} VIAF candidates.")
          end

          rule_verdict(pool) || ask_ai(pool)
        end

        # Exactly one person with a heading equal to our name and a birth year
        # agreeing with ours. Its cluster is then read and must still agree.
        def rule_verdict(pool)
          named = pool.select { |candidate| heading_matches?(candidate) }
          return nil unless named.size == 1 && suggested_birth_agrees?(named.first)

          only = fetch(named.first)
          return nil unless person?(only) && !year_conflict?(only)

          Verdict.new(outcome: :matched, candidate: only, decided_by: :rule, confidence: :high,
            reason: "The only VIAF person named #{author.name}, born #{author.birth_year} as ours.")
        end

        def ask_ai(pool)
          shown = ordered(pool).first(MAX_FETCHED).each { |candidate| fetch(candidate) }.select { |candidate| person?(candidate) }
          if shown.empty?
            return Verdict.new(outcome: :unmatched, candidate: nil, decided_by: :rule, confidence: :high,
              reason: "None of the suggested VIAF clusters could be read as a person.")
          end

          attach_titles(shown)
          select_with_ai(shown)
        end

        def select_with_ai(shown)
          result = ::Services::Ai::Tasks::Matching::SelectExternalRecordTask.new(
            parent: author, source_name: "VIAF", entity_noun: "author",
            query_line: @profile.line, candidate_lines: shown.map { |candidate| describe(candidate) }, guidance: GUIDANCE
          ).call
          return ai_failed(result.error, result.ai_chat) unless result.success?

          index = result.data[:selected_index]
          chosen = index.positive? ? shown[index - 1] : nil
          Verdict.new(outcome: chosen ? :matched : :unmatched, candidate: chosen, decided_by: :ai,
            confidence: result.data[:confidence].to_sym, reason: result.data[:reasoning].to_s, ai_chat: result.ai_chat)
        rescue => e
          ai_failed("#{e.class}: #{e.message}", nil)
        end

        def ai_failed(message, chat)
          Verdict.new(outcome: :failed, candidate: nil, decided_by: :fallback, confidence: :low,
            reason: "AI selection failed: #{message}", ai_chat: chat)
        end

        # ---- gathering ------------------------------------------------------

        def add(viaf_id, source)
          candidate = (@candidates[viaf_id.to_s] ||= Candidate.new(viaf_id: viaf_id.to_s, sources: [], suggestions: [], matching_titles: []))
          candidate.sources |= [source]
          candidate
        end

        # Reads the cluster once. A cluster VIAF no longer serves (gone or
        # withdrawn) drops out; any other error ends the run.
        def fetch(candidate)
          return candidate if candidate.person || candidate.unavailable

          candidate.person = @client.cluster(candidate.viaf_id, refresh: @refresh)
          candidate
        rescue ::Viaf::Exceptions::NotFoundError, ::Viaf::Exceptions::AbandonedRecordError => e
          candidate.unavailable = e.class.name.demodulize
          @sources_failed |= ["viaf_cluster"]
          candidate
        end

        def persons = @candidates.values.select { |candidate| person?(candidate) }

        # A read cluster decides; before that, AutoSuggest's name type.
        def person?(candidate)
          return false if candidate.unavailable
          return candidate.person.kind == :person if candidate.person

          candidate.suggestions.any? { |suggestion| suggestion.kind == :person }
        end

        def attach_titles(shown)
          ours = @profile.titles.map { |title| title_key(title) }.to_set
          shown.each do |candidate|
            candidate.matching_titles = candidate.person.titles.select { |title| ours.include?(title_key(title)) }
              .uniq { |title| title_key(title) }
          end
        end

        # ---- judgements -----------------------------------------------------

        def corroborated?(candidate) = names_agree?(candidate) && !year_conflict?(candidate)

        def names_agree?(candidate)
          person = candidate.person
          names = person.main_headings.map { |heading| heading["name"] } + person.names
          names.any? { |name| author_tokens.include?(ViafNames.tokens(name)) }
        end

        def heading_matches?(candidate)
          candidate.suggestions.any? { |suggestion| author_tokens.include?(ViafNames.tokens(suggestion.term)) }
        end

        def author_tokens
          @author_tokens ||= @profile.names.map { |name| ViafNames.tokens(name) }.reject(&:empty?).to_set
        end

        def suggested_birth_agrees?(candidate)
          theirs = candidate.suggestions.filter_map(&:birth_year).first
          author.birth_year.present? && theirs.present? && (author.birth_year - theirs).abs <= YEAR_TOLERANCE
        end

        def year_conflict?(candidate)
          birth, death = candidate_years(candidate)
          years_conflict?(author.birth_year, birth) || years_conflict?(author.death_year, death)
        end

        def years_conflict?(ours, theirs)
          ours.present? && theirs.present? && (ours - theirs).abs > YEAR_TOLERANCE
        end

        # From the cluster once read (life dates only, never a flourished
        # span), else from the AutoSuggest rows.
        def candidate_years(candidate)
          person = candidate.person
          return [nil, nil] if person && !person.lived?
          return [person.birth_year, person.death_year] if person

          [candidate.suggestions.filter_map(&:birth_year).first, candidate.suggestions.filter_map(&:death_year).first]
        end

        def agency_count(candidate)
          return candidate.person.agency_count if candidate.person

          candidate.suggestions.flat_map { |suggestion| suggestion.source_ids.keys }.uniq.size
        end

        # Held ids first, then a heading equal to our name, no year conflict,
        # the most contributing libraries, and AutoSuggest's own order.
        def ordered(pool)
          pool.each_with_index.sort_by do |candidate, index|
            [candidate.sources.include?("held_id") ? 0 : 1, heading_matches?(candidate) ? 0 : 1,
              year_conflict?(candidate) ? 1 : 0, -agency_count(candidate), index]
          end.map(&:first)
        end

        # ---- our side -------------------------------------------------------

        def identifier_values(type)
          author.identifiers.select { |identifier| identifier.identifier_type == type }.map(&:value)
        end

        # The main title, case and diacritics folded: VIAF titles carry
        # subtitles ("Forget me not : a novel").
        def title_key(text)
          main = text.to_s.sub(%r{\s*[:/;].*\z}m, "").presence || text.to_s
          ::Services::Text::QuoteNormalizer.call(main).to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.squish
        end

        # ---- describing -----------------------------------------------------

        def describe(candidate)
          person = candidate.person
          parts = [display_name(candidate)]
          span = lifespan(person)
          parts << span if span
          parts << "nationality: #{person.country_codes.join(", ")}" if person.country_codes.any?
          parts << "occupations: #{person.occupation.first(5).join(", ")}" if person.occupation.any?
          parts << "works matching ours: #{candidate.matching_titles.first(5).join("; ")}" if candidate.matching_titles.any?
          others = person.titles - candidate.matching_titles
          parts << "other works: #{others.first(5).join("; ")}" if others.any?
          parts << "#{person.agency_count} contributing libraries"
          parts << "year conflict" if year_conflict?(candidate)
          parts << "viaf #{candidate.viaf_id}"
          parts.join(" | ")
        end

        # The first library heading in natural order ("Willingham, Stacy" is
        # Stacy Willingham), else AutoSuggest's form, else the id. The
        # Wikidata-built heading is a label and a description, not a name.
        def display_name(candidate)
          heading = candidate.person&.main_headings&.find { |entry| entry["source"] != "WKP" }&.dig("name")
          return ViafNames.natural(heading) || heading if heading

          candidate.suggestions.first&.display_form || candidate.viaf_id
        end

        def lifespan(person)
          span = AuthorProfile.lifespan(person.birth_year, person.death_year)
          return nil if span.nil?

          person.lived? ? span : "active #{span}"
        end

        # ---- recording ------------------------------------------------------

        def record(verdict)
          ordered_all = ordered(persons) + (@candidates.values - persons)
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
            candidates: ordered_all.map { |candidate| snapshot(candidate) },
            selected_index: verdict.candidate && (ordered_all.index(verdict.candidate) + 1),
            reason: verdict.reason,
            ai_chat: verdict.ai_chat,
            sources_failed: @sources_failed,
            needs_review: verdict.decided_by == :fallback || %i[medium low].include?(confidence)
          )
          Result.new(
            success?: true,
            data: {outcome: verdict.outcome, person: verdict.candidate&.person, decision: decision, reason: verdict.reason},
            errors: []
          )
        end

        def author_snapshot
          {
            "name" => author.name,
            "alternate_names" => Array(author.alternate_names).first(10),
            "birth_year" => author.birth_year,
            "death_year" => author.death_year,
            "viaf" => identifier_values(VIAF),
            "titles" => @profile.titles.first(10)
          }
        end

        def snapshot(candidate)
          person = candidate.person
          birth, death = candidate_years(candidate)
          evidence = {
            "external_title" => display_name(candidate),
            "external_year" => birth,
            "headings" => candidate.suggestions.map(&:term).uniq.first(5),
            "birth_year" => birth,
            "death_year" => death,
            "agency_count" => agency_count(candidate),
            "year_conflict" => year_conflict?(candidate)
          }
          if person
            evidence.merge!(
              "date_type" => person.date_type,
              "nationality" => person.country_codes,
              "occupations" => person.occupation.first(5),
              "matching_titles" => candidate.matching_titles.first(10),
              "other_titles" => (person.titles - candidate.matching_titles).first(5),
              "wikidata_qid" => person.wikidata_qid
            )
          end
          evidence["unavailable"] = candidate.unavailable if candidate.unavailable
          evidence["dropped"] = "not a person" unless candidate.unavailable || person?(candidate)
          {
            "record_type" => nil, "record_id" => nil,
            "external_source" => "viaf", "external_key" => candidate.viaf_id,
            "sources" => candidate.sources, "scores" => {},
            "evidence" => evidence.compact
          }
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the resolver tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/resolve_viaf_test.rb`
Expected: PASS.

- [ ] **Step 6: Add the audit entry, with its tests**

In `app/lib/data_importers/finder_registry.rb`, add a second external-link entry after the "Wikidata link" one, inside `ENTRIES`:

```ruby
      Entry.new(
        finder: "Services::Books::Authors::ResolveViaf", domain: :books, model: "Books::Author", label: "VIAF link",
        query: nil, preloads: [], merge_action: nil, source_field: nil, execute_action_path: nil,
        recheck: false, kind: :external_link
      )
```

In `test/lib/data_importers/finder_registry_test.rb`, add after the Wikidata link test:

```ruby
    test "the VIAF link entry is an external-link kind: no query, merge or re-check" do
      entry = FinderRegistry.entry("Services::Books::Authors::ResolveViaf")

      assert entry.external_link?
      assert_equal [:books, "Books::Author", "VIAF link"], [entry.domain, entry.model, entry.label]
      assert_respond_to entry.finder_class, :call
      assert_not entry.mergeable?
      assert_not entry.recheck?
      assert_nil entry.query
    end
```

and in "an external-link entry never shadows the finder for its model", add:

```ruby
      assert_includes FinderRegistry.for_domain(:books).map(&:finder), "Services::Books::Authors::ResolveViaf"
```

In `test/controllers/admin/books/match_decisions_controller_test.rb`, add after the Wikidata link test:

```ruby
      test "a VIAF link decision shows, filters and refuses re-check" do
        decision = ::MatchDecision.create!(
          finder: "Services::Books::Authors::ResolveViaf", subject: books_authors(:tolstoy), record: nil,
          outcome: :matched, confidence: :high, decided_by: :rule, needs_review: false,
          query: {"name" => "Leo Tolstoy", "viaf" => []},
          candidates: [{
            "record_type" => nil, "record_id" => nil, "external_source" => "viaf", "external_key" => "96987389",
            "sources" => ["name_search"], "scores" => {},
            "evidence" => {"external_title" => "Leo Tolstoy", "external_year" => 1828, "agency_count" => 44}
          }],
          selected_index: 1, reason: "The only VIAF person named Leo Tolstoy, born 1828 as ours."
        )
        sign_in_as(@admin, stub_auth: true)

        get admin_books_match_decision_path(decision)
        assert_response :success

        get admin_books_match_decisions_path(entity: "viaf-link")
        assert_equal [decision.id], row_ids

        post recheck_admin_books_match_decision_path(decision)
        assert_redirected_to admin_books_match_decision_path(decision)
      end
```

The `entity` filter value comes from the label, the same way `"wikidata-link"` does. If the Wikidata test's filter is built differently, build this one the same way.

- [ ] **Step 7: Run the registry, controller and resolver tests; zeitwerk; lint**

Run: `bin/rails test test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb test/lib/services/books/authors/ && CI=1 bin/rails zeitwerk:check && bundle exec standardrb app/lib test/support test/lib/services/books/authors test/lib/data_importers test/controllers/admin/books`
Expected: PASS; "All is good!"; no offenses.

- [ ] **Step 8: Commit**

```bash
git add app/lib/services/books/authors/resolve_viaf.rb app/lib/data_importers/finder_registry.rb test/support/viaf_builders.rb \
  test/support/fake_viaf_client.rb test/test_helper.rb test/lib/services/books/authors/resolve_viaf_test.rb \
  test/lib/data_importers/finder_registry_test.rb test/controllers/admin/books/match_decisions_controller_test.rb
git commit -m "ResolveViaf: held id, AutoSuggest grouped by cluster, rule or AI, one recorded decision

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `ApplyViaf`

**Files:**
- Create: `app/lib/services/books/authors/apply_viaf.rb`
- Test: `test/lib/services/books/authors/apply_viaf_test.rb`

**Interfaces:**
- Consumes:
  - `FactSheet` (Task 3) and `ViafNames` (Task 4).
  - `Viaf::Person`: `viaf_id`, `isni`, `lcnaf`, `wikidata_qid`, `birth_year`, `death_year`, `lived?`, `date_type`, `gender_code`, `main_headings` and `country_codes`.
  - `::Services::Books::CountryLookup#from_iso(codes)` returns a `Result`.
- Produces: `Services::Books::Authors::ApplyViaf.call(author:, person:, decision: nil, country_lookup: nil)` returns a `Result`. Its `data` is `{facts: Hash, applied: Array, conflict: Boolean, wikidata_qid: String or nil}`, where `wikidata_qid` is set only when this run newly stamped it.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/authors/apply_viaf_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ApplyViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham")
          @lookup = mock("country_lookup")
          @lookup.stubs(:from_iso).returns(::Services::Books::CountryLookup::Result.new(countries: [], unmatched: []))
        end

        def apply(person, author: @author) = ApplyViaf.call(author: author, person: person, country_lookup: @lookup)

        def held(type) = @author.reload.identifiers.where(identifier_type: type).pluck(:value).sort

        test "stamps VIAF, ISNI, LC and the cluster's Wikidata id, and reports the new Wikidata id" do
          result = apply(viaf_person("5391", isni: "0000000507233592", lc: "n2021040535", wikidata: "Q115493575"))

          assert_equal [["5391"], ["0000000507233592"], ["n2021040535"], ["Q115493575"]],
            %w[books_author_viaf books_author_isni books_author_lcnaf books_author_wikidata_qid].map { |type| held(type) }
          assert_equal "Q115493575", result.data[:wikidata_qid]
        end

        test "a Wikidata id already held, held by another author, or conflicting is not reported as new" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1")
          assert_nil apply(viaf_person("1", wikidata: "Q1")).data[:wikidata_qid]
          assert_nil apply(viaf_person("1", wikidata: "Q2")).data[:wikidata_qid]

          other = ::Books::Author.create!(name: "Other Author")
          other.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q3")
          fresh = ::Books::Author.create!(name: "Fresh Author")
          assert_nil apply(viaf_person("2", wikidata: "Q3"), author: fresh).data[:wikidata_qid]
        end

        test "an author holding a different VIAF id gets nothing applied" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")

          result = apply(viaf_person("5391", born: "1991", isni: "0000000507233592"))

          assert result.data[:conflict]
          assert_equal "held_viaf_conflict", result.data[:facts]["viaf"]["reason"]
          assert_nil @author.reload.birth_year
          assert_empty held("books_author_isni")
        end

        test "fills life years; a living person's 0 death date is no year" do
          apply(viaf_person("1", born: "1991-01-30", died: 0))

          assert_equal [1991, nil], [@author.reload.birth_year, @author.death_year]
        end

        test "a flourished span, a BCE year or a disagreeing year is recorded, never applied" do
          facts = apply(viaf_person("1", born: "1850", died: "1870", date_type: "flourished")).data[:facts]
          assert_equal ["not_life_dates", "not_life_dates"], [facts["birth_year"]["reason"], facts["death_year"]["reason"]]

          ancient = ::Books::Author.create!(name: "Ancient Author")
          assert_equal "bce", apply(viaf_person("2", born: "-384"), author: ancient).data[:facts]["birth_year"]["reason"]

          dated = ::Books::Author.create!(name: "Dated Author", birth_year: 1900)
          assert_equal "conflict", apply(viaf_person("3", born: "1950"), author: dated).data[:facts]["birth_year"]["reason"]
          assert_nil @author.reload.birth_year
        end

        test "maps gender codes; unspecified is recorded, not applied" do
          apply(viaf_person("1", gender: "a"))
          assert_equal "female", @author.reload.gender

          other = ::Books::Author.create!(name: "Unknown Gender")
          fact = apply(viaf_person("2", gender: "u"), author: other).data[:facts]["gender"]
          assert_equal ["null", nil], [fact["reason"], other.reload.gender]
        end

        test "fills countries from the two-letter nationality codes only" do
          american = ::Books::Country.create!(name: "American Test")
          @lookup.expects(:from_iso).with(["US"]).returns(::Services::Books::CountryLookup::Result.new(countries: [american], unmatched: []))

          apply(viaf_person("1", nationality: ["US", "us", "Stany Zjednoczone"]))

          assert_equal [american], @author.reload.countries.to_a
        end

        test "adds main headings in natural order, Latin script only, never the Wikidata heading or a reordering" do
          author = ::Books::Author.create!(name: "Leo Tolstoy")
          apply(viaf_person("1", headings: [
            "Tolstoy, Leo", "Tolstoï, Léon", "Tolstoi, Lev Nikolaevich, graf", "Толстой, Лев", "Tolstoy Leo",
            {"source" => "WKP", "name" => "Tolstoy, Russian writer"}
          ]), author: author)

          assert_equal ["Léon Tolstoï", "Lev Nikolaevich Tolstoi"], author.reload.alternate_names
        end

        test "a heading that only reorders our name is skipped" do
          author = ::Books::Author.create!(name: "Mo Yan")

          apply(viaf_person("1", headings: ["Mo, Yan"]), author: author)

          assert_empty Array(author.reload.alternate_names)
        end

        # Letters, not digits: natural() strips digits as dates.
        test "adds at most 10 alternate names" do
          apply(viaf_person("1", headings: ("A".."L").map { |letter| "Surname#{letter}, Given" }))

          assert_equal 10, @author.reload.alternate_names.size
        end

        test "never writes the name or the kind, and a second run applies nothing new" do
          person = viaf_person("1", born: "1991", gender: "a", isni: "0000000507233592", headings: ["Willingham, Stacy J."])
          apply(person)

          result = assert_no_difference(-> { ::Identifier.count }) { apply(person) }

          assert_empty result.data[:applied]
          assert_equal ["Stacy Willingham", "person"], [@author.reload.name, @author.kind]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/apply_viaf_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::Authors::ApplyViaf`.

- [ ] **Step 3: Implement**

`app/lib/services/books/authors/apply_viaf.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what a matched VIAF cluster says onto the author, filling
      # blanks only (spec §8). Identifiers (VIAF, ISNI, LC, and the Wikidata
      # id in the cluster's sources), life years, gender, countries from the
      # nationality codes, and alternate names from the libraries' main
      # headings. Never writes name or kind. An author holding a different
      # VIAF id gets nothing. Returns the ledger facts, and the Wikidata id
      # when this run newly stamped it (the job runs Wikidata once more).
      class ApplyViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ALTERNATE_NAME_CAP = 10
        VIAF = "books_author_viaf"
        QID = "books_author_wikidata_qid"
        GENDERS = {"a" => "female", "b" => "male"}.freeze
        # A heading built from Wikidata ("Stacy Willingham American writer")
        # is a label and a description, not a library's name form.
        SKIPPED_HEADING_SOURCES = %w[WKP].freeze

        def self.call(author:, person:, decision: nil, country_lookup: nil)
          new(author: author, person: person, decision: decision, country_lookup: country_lookup).call
        end

        def initialize(author:, person:, decision:, country_lookup:)
          @author = author
          @person = person
          @decision = decision
          @country_lookup = country_lookup || ::Services::Books::CountryLookup.new
          @sheet = FactSheet.new(author)
        end

        def call
          other = sheet.identifier_values(VIAF) - [person.viaf_id]
          if other.any?
            sheet.record("viaf", person.viaf_id, applied: false, reason: "held_viaf_conflict", held: other)
            return result(conflict: true)
          end

          sheet.single_identifier("viaf", VIAF, person.viaf_id)
          sheet.single_identifier("isni", "books_author_isni", person.isni)
          sheet.single_identifier("lcnaf", "books_author_lcnaf", person.lcnaf)
          sheet.single_identifier("wikidata_qid", QID, person.wikidata_qid.to_s[/\AQ\d+\z/])
          apply_year("birth_year", person.birth_year)
          apply_year("death_year", person.death_year)
          apply_gender
          sheet.alternate_names(heading_names, cap: ALTERNATE_NAME_CAP)
          codes = person.country_codes
          sheet.countries(codes, viaf: codes) { |values| @country_lookup.from_iso(values) }
          author.save!
          sheet.flag_collisions(reason: "VIAF #{person.viaf_id} lists identifiers another author already holds", decision: decision)
          result(conflict: false)
        end

        private

        attr_reader :author, :person, :decision, :sheet

        def result(conflict:)
          new_qid = sheet.facts.dig("wikidata_qid", "applied") ? sheet.facts["wikidata_qid"]["value"] : nil
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied, conflict: conflict, wikidata_qid: new_qid},
            errors: [])
        end

        def apply_year(name, year)
          if year.nil?
            sheet.record(name, nil, applied: false, reason: "null")
          elsif !person.lived?
            sheet.record(name, year, applied: false, reason: "not_life_dates", date_type: person.date_type)
          elsif year.negative?
            sheet.record(name, year, applied: false, reason: "bce")
          else
            sheet.year(name, year)
          end
        end

        def apply_gender
          code = person.gender_code
          value = GENDERS[code]
          return sheet.record("gender", code, applied: false, reason: "null") if value.nil?

          sheet.gender(value, viaf: code)
        end

        # Main headings only, in natural order, Latin script. A heading whose
        # words only reorder a name the author already has is skipped: "Mo,
        # Yan" is Mo Yan, not "Yan Mo", and the comma cannot tell the two apart.
        def heading_names
          existing = [author.name] + Array(author.alternate_names)
          person.main_headings.filter_map do |heading|
            next if SKIPPED_HEADING_SOURCES.include?(heading["source"])

            name = ViafNames.natural(heading["name"])
            next if name.nil? || !ViafNames.latin?(name)
            next if existing.any? { |ours| ViafNames.reordering?(name, of: ours) }

            name
          end.uniq
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/apply_viaf_test.rb`
Expected: PASS. In the heading test, "Tolstoy, Leo" becomes "Leo Tolstoy", the author's own name, so `FactSheet` skips it. "Tolstoy Leo" has no comma, the Cyrillic heading is not Latin, and the `WKP` heading is skipped.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/apply_viaf.rb test/lib/services/books/authors/apply_viaf_test.rb
git add app/lib/services/books/authors/apply_viaf.rb test/lib/services/books/authors/apply_viaf_test.rb
git commit -m "ApplyViaf: fill identifiers, life years, gender, countries and headings from a matched cluster

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `EnrichFromViaf`, one run and one ledger row

**Files:**
- Create: `app/lib/services/books/authors/enrich_from_viaf.rb`
- Test: `test/lib/services/books/authors/enrich_from_viaf_test.rb`

**Interfaces:**
- Consumes: `ResolveViaf.call(author:, refresh:, client:)` (Task 5), `ApplyViaf.call(author:, person:, decision:)` (Task 6) and `author.enrichments.for_kind(kind)`.
- Produces: `Services::Books::Authors::EnrichFromViaf.call(author:, refresh: false, client: nil)` returns a `Result`. Its `data` is `{outcome: :skipped | :matched | :unmatched | :failed, enrichment: Enrichment, decision: MatchDecision or nil, wikidata_qid: String or nil}`. Also `EnrichFromViaf::KIND == "books.author_viaf"`. `Viaf::Exceptions::RateLimited` propagates.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/authors/enrich_from_viaf_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class EnrichFromViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham", birth_year: 1991)
          @person = viaf_person("5391", headings: ["Willingham, Stacy"], born: "1991", gender: "a", wikidata: "Q115493575")
          @client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => @person}
          )
        end

        def run_viaf(refresh: false, client: @client) = EnrichFromViaf.call(author: @author, refresh: refresh, client: client)

        def rows = @author.enrichments.for_kind(EnrichFromViaf::KIND).order(:id)

        test "a match applies the cluster and writes one applied row tied to the decision" do
          result = run_viaf

          row = rows.sole
          assert_equal ["applied", "viaf", true, "high"], [row.outcome, row.provider, row.recognized, row.confidence]
          assert_equal result.data[:decision], row.match_decision
          assert_equal ["https://viaf.org/viaf/5391"], row.citations
          assert_equal "filled", row.facts["gender"]["reason"]
          assert_equal ["female", "Q115493575"], [@author.reload.gender, result.data[:wikidata_qid]]
        end

        test "no match writes an unrecognized row" do
          result = run_viaf(client: FakeViafClient.new)

          assert_equal [:unmatched, "unrecognized", false], [result.data[:outcome], rows.sole.outcome, rows.sole.recognized]
          assert_nil result.data[:wikidata_qid]
        end

        # The held cluster is someone else, so the search matches by rule at
        # high confidence (no review) and only the conflict flags it.
        test "an author holding a different VIAF id applies nothing and flags the decision" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "999")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => @person, "999" => viaf_person("999", headings: ["Else, Someone"])}
          )

          result = run_viaf(client: client)

          assert_equal ["nothing_to_apply", "held_viaf_conflict"], [rows.last.outcome, rows.last.reason]
          assert_equal "high", result.data[:decision].confidence
          assert result.data[:decision].reload.needs_review
          assert_nil @author.reload.gender
        end

        test "an already processed author is skipped without asking VIAF; refresh runs it again" do
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :unrecognized, reason: "no_match")

          assert_equal ["skipped", "already_processed"], [run_viaf.data[:enrichment].outcome, rows.last.reason]
          assert_empty @client.calls

          run_viaf(refresh: true)
          assert_equal "applied", rows.last.outcome
        end

        test "a failed or skipped row, or one older than the author row, does not count as processed" do
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :failed, error: "boom")
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :skipped, reason: "placeholder")
          @author.enrichments.create!(kind: EnrichFromViaf::KIND, outcome: :applied, created_at: 2.days.ago)

          assert_equal :matched, run_viaf.data[:outcome]
        end

        test "a placeholder author is skipped without asking VIAF" do
          @author.update!(exclude_from_rankings: true)

          assert_equal ["skipped", "placeholder"], [run_viaf.data[:enrichment].outcome, rows.sole.reason]
          assert_empty @client.calls
        end

        test "a failed AI selection writes a failed row tied to its decision" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => @person})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = run_viaf(client: client)

          assert_equal ["failed", "resolve_failed"], [rows.sole.outcome, rows.sole.reason]
          assert_equal result.data[:decision], rows.sole.match_decision
          assert_not result.success?
        end

        test "a VIAF error writes a failed row and returns" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::ServerError.new("Server error: 503", 503)})

          result = run_viaf(client: client)

          assert_equal ["failed", "viaf_error"], [rows.sole.outcome, rows.sole.reason]
          assert_match(/ServerError/, rows.sole.error)
          assert_not result.success?
        end

        test "a rate limit propagates and writes nothing, so the rescheduled run starts clean" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::RateLimited.new("wait", retry_after: 60)})

          assert_raises(::Viaf::Exceptions::RateLimited) { run_viaf(client: client) }
          assert_empty rows
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/authors/enrich_from_viaf_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Books::Authors::EnrichFromViaf`.

- [ ] **Step 3: Implement**

`app/lib/services/books/authors/enrich_from_viaf.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Authors
      # One VIAF run for one author (spec §8, §11). Resolve; on a match,
      # apply the cluster. Exactly one books.author_viaf ledger row per run,
      # skips and failures included, tied to the run's decision. A VIAF
      # failure writes a failed row and returns. RateLimited (VIAF paused,
      # blocked, or our pace busy) propagates so the job reschedules: every
      # VIAF call happens before the decision is recorded, so nothing is
      # written and the rescheduled run starts clean, resuming from the
      # suggestions and clusters already stored.
      class EnrichFromViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_viaf"
        PROVIDER = "viaf"
        # "Done" outcomes. A failed or skipped run leaves the author to be tried again.
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        LEDGER_CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client
          @decision = nil
          @wikidata_qid = nil
        end

        def call
          return finish(:skipped, write(outcome: :skipped, reason: "placeholder")) if author.exclude_from_rankings?
          return finish(:skipped, write(outcome: :skipped, reason: "already_processed")) if !refresh && processed?

          resolved = ResolveViaf.call(author: author, refresh: refresh, client: @client).data
          @decision = resolved[:decision]
          case resolved[:outcome]
          when :matched then matched(resolved[:person])
          when :unmatched then finish(:unmatched, write(outcome: :unrecognized, reason: "no_match", recognized: false))
          else finish(:failed, write(outcome: :failed, reason: "resolve_failed", error: resolved[:reason]))
          end
        rescue ::Viaf::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "viaf_error", error: "#{e.class.name.demodulize}: #{e.message}"))
        end

        private

        attr_reader :author, :refresh

        # "Newer than the author row": after the production re-migration an
        # author is re-created with its id, and the old rows no longer count.
        def processed?
          author.enrichments.for_kind(KIND).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at).exists?
        end

        def matched(person)
          applied = ApplyViaf.call(author: author, person: person, decision: @decision)
          facts = applied.data[:facts]
          if applied.data[:conflict]
            @decision.update!(needs_review: true)
            return finish(:matched, write(outcome: :nothing_to_apply, reason: "held_viaf_conflict", recognized: true, facts: facts))
          end

          @wikidata_qid = applied.data[:wikidata_qid]
          outcome = applied.data[:applied].any? ? :applied : :nothing_to_apply
          finish(:matched, write(outcome: outcome, reason: "matched #{person.viaf_id}", recognized: true, facts: facts,
            citations: ["https://viaf.org/viaf/#{person.viaf_id}"]))
        end

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          author.enrichments.create!(
            kind: KIND, provider: PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: LEDGER_CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        def finish(outcome, row)
          Result.new(success?: outcome != :failed,
            data: {outcome: outcome, enrichment: row, decision: @decision, wikidata_qid: @wikidata_qid},
            errors: Array(row.error))
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/authors/enrich_from_viaf_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/authors/enrich_from_viaf.rb test/lib/services/books/authors/enrich_from_viaf_test.rb
git add app/lib/services/books/authors/enrich_from_viaf.rb test/lib/services/books/authors/enrich_from_viaf_test.rb
git commit -m "EnrichFromViaf: one VIAF run, one books.author_viaf ledger row

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `ViafJob`, and `WikidataJob` hands a miss to VIAF

**Files:**
- Create (generator): `app/sidekiq/books/authors/viaf_job.rb`, `test/sidekiq/books/authors/viaf_job_test.rb`
- Modify: `app/sidekiq/books/authors/wikidata_job.rb`
- Test: `test/sidekiq/books/authors/wikidata_job_test.rb`

**Interfaces:**
- Consumes: `EnrichFromViaf.call(author:, refresh:)` (its `data[:wikidata_qid]`, from Task 7), `EnrichFromWikidata.call(author:, refresh:)` (its `data[:outcome]`) and `Viaf::Exceptions::RateLimited#retry_after`.
- Produces:
  - `Books::Authors::ViafJob#perform(author_id, refresh = false)`
  - `Books::Authors::WikidataJob#perform(author_id, refresh = false, via_viaf = false)`

- [ ] **Step 1: Generate the job**

Run: `bin/rails generate sidekiq:job books/authors/viaf`
Expected: creates `app/sidekiq/books/authors/viaf_job.rb` and `test/sidekiq/books/authors/viaf_job_test.rb`. Replace both files' contents in the steps below.

- [ ] **Step 2: Write the failing tests**

`test/sidekiq/books/authors/viaf_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::ViafJobTest < ActiveSupport::TestCase
  def outcome(wikidata_qid: nil)
    ::Services::Books::Authors::EnrichFromViaf::Result.new(success?: true, data: {outcome: :matched, wikidata_qid: wikidata_qid}, errors: [])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::ViafJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the VIAF step for the author, passing refresh through" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).with(author: author, refresh: true).returns(outcome)
    Books::Authors::WikidataJob.expects(:perform_async).never

    Books::Authors::ViafJob.new.perform(author.id, true)
  end

  test "a newly found Wikidata id sends the author back to Wikidata once, forced, and never back here" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).returns(outcome(wikidata_qid: "Q7243"))
    Books::Authors::WikidataJob.expects(:perform_async).with(author.id, true, true)

    Books::Authors::ViafJob.new.perform(author.id)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromViaf.expects(:call).never

    Books::Authors::ViafJob.new.perform(0)
  end

  test "reschedules itself after the wait a pause or busy pace carries, plus jitter" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromViaf.stubs(:call).raises(::Viaf::Exceptions::RateLimited.new("paused", retry_after: 3600))
    job = Books::Authors::ViafJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::ViafJob.expects(:perform_in).with(3607, author.id, false)

    job.perform(author.id)
  end
end
```

Replace `test/sidekiq/books/authors/wikidata_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Authors::WikidataJobTest < ActiveSupport::TestCase
  def outcome(value)
    ::Services::Books::Authors::EnrichFromWikidata::Result.new(success?: value != :failed, data: {outcome: value}, errors: [])
  end

  test "runs on the low queue with three retries" do
    options = Books::Authors::WikidataJob.get_sidekiq_options

    assert_equal ["low", 3], [options["queue"].to_s, options["retry"]]
  end

  test "runs the Wikidata step for the author" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).with(author: author, refresh: true).returns(outcome(:matched))

    Books::Authors::WikidataJob.new.perform(author.id, true)
  end

  test "a miss goes on to VIAF, passing refresh through" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).with(author.id, true)

    Books::Authors::WikidataJob.new.perform(author.id, true)
  end

  test "a match, a failure or a skip does not go to VIAF" do
    author = books_authors(:tolstoy)
    Books::Authors::ViafJob.expects(:perform_async).never

    %i[matched failed skipped].each do |value|
      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(value))
      Books::Authors::WikidataJob.new.perform(author.id)
    end
  end

  test "a miss on a run VIAF sent here does not go back to VIAF" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(outcome(:unmatched))
    Books::Authors::ViafJob.expects(:perform_async).never

    Books::Authors::WikidataJob.new.perform(author.id, true, true)
  end

  test "does nothing for an author deleted since enqueue" do
    ::Services::Books::Authors::EnrichFromWikidata.expects(:call).never

    Books::Authors::WikidataJob.new.perform(0)
  end

  test "reschedules itself after the wait a rate limit carries, plus jitter, keeping via_viaf" do
    author = books_authors(:tolstoy)
    ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 120))
    job = Books::Authors::WikidataJob.new
    job.stubs(:rand).returns(7)
    Books::Authors::WikidataJob.expects(:perform_in).with(127, author.id, true, true)

    job.perform(author.id, true, true)
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/rails test test/sidekiq/books/authors/`
Expected: FAIL. `ViafJob#perform` is the generator's stub, and `WikidataJob` never enqueues `ViafJob` and does not accept `via_viaf`.

- [ ] **Step 4: Implement**

`app/sidekiq/books/authors/viaf_job.rb`:

```ruby
# frozen_string_literal: true

# One author through Services::Books::Authors::EnrichFromViaf (spec §8,
# §11), only after a Wikidata miss. On the low queue, not serial. VIAF paused
# (a Cloudflare block, or the day's budget running low) or our pace busy
# reschedules this job for the wait RateLimited carries, so no worker thread
# sleeps. When the matched cluster named a Wikidata item this run stamped,
# Wikidata runs once more for it -- forced, since the earlier miss counts as
# processed, and with via_viaf, so a second miss cannot send the author back
# here. The chain ends here until the AI step lands.
class Books::Authors::ViafJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  RESCHEDULE_JITTER = 0..30

  def perform(author_id, refresh = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromViaf.call(author: author, refresh: refresh)
    return if result.data[:wikidata_qid].nil?

    ::Books::Authors::WikidataJob.perform_async(author_id, true, true)
  rescue ::Viaf::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh)
  end
end
```

`app/sidekiq/books/authors/wikidata_job.rb`: replace the last sentence of the header comment ("The chain ends here until VIAF and the AI step land.") with:

```ruby
# A miss goes on to Books::Authors::ViafJob, unless VIAF sent this author
# here (via_viaf), which would loop. The chain ends at VIAF until the AI
# step lands.
```

and replace `perform`:

```ruby
  def perform(author_id, refresh = false, via_viaf = false)
    author = ::Books::Author.find_by(id: author_id)
    # Deleted or merged away between enqueue and run: nothing to do.
    return if author.nil?

    result = ::Services::Books::Authors::EnrichFromWikidata.call(author: author, refresh: refresh)
    return unless result.data[:outcome] == :unmatched && !via_viaf

    ::Books::Authors::ViafJob.perform_async(author_id, refresh)
  rescue ::Wikimedia::Exceptions::RateLimited => e
    self.class.perform_in(e.retry_after.to_i + rand(RESCHEDULE_JITTER), author_id, refresh, via_viaf)
  end
```

- [ ] **Step 5: Run the job tests and every caller's tests**

Run: `bin/rails test test/sidekiq/books/authors/ test/lib/data_importers/books/ test/lib/services/books/authors/`
Expected: PASS. The importer tests stub `WikidataJob.perform_async`, so the inline Sidekiq mode never reaches VIAF.

- [ ] **Step 6: Lint, zeitwerk and commit**

```bash
CI=1 bin/rails zeitwerk:check
bundle exec standardrb app/sidekiq/books/authors test/sidekiq/books/authors
git add app/sidekiq/books/authors test/sidekiq/books/authors
git commit -m "ViafJob after a Wikidata miss; a new Wikidata id from VIAF runs Wikidata once more

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Docs, and the full suite

**Files:**
- Modify: `docs/features/books-author-enrichment.md`
- Modify: `docs/features/viaf-api-client.md`

**Interfaces:**
- Consumes: everything above. The docs state what the code does. Verify each claim against the code before writing it.

- [ ] **Step 1: Update `docs/features/books-author-enrichment.md`**

- **Opening paragraph and spec line.** Add VIAF: resolved through Wikidata first, then VIAF when Wikidata finds no person. The spec reference becomes §3-§8, §13, §14. Add `docs/features/viaf-api-client.md` to the "see also" list.
- **"The chain today".** Replace the diagram with:

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

  Then replace the paragraph that says VIAF is not built. The new one says the AI facts step and the book-enrichment hand-off are increment 4, and today the chain ends at `ViafJob` or at the `via_viaf` Wikidata run.
- **New section "VIAF", after "Legacy Wikipedia cleanup".** Cover each of these, with the class names:
  - When it runs: only after a Wikidata miss, never for a matched author.
  - Resolution: the held id (corroborated by name and years, then `identifier`/`certain`), then one AutoSuggest, grouped by cluster.
  - The rule: exactly one person named as ours, with a birth year within one of ours (`rule`/`high`). Otherwise up to three clusters go to `SelectExternalRecordTask`, whose guidance covers VIAF duplicates. No person among the candidates is unmatched by rule.
  - What `ApplyViaf` fills, with rulings 9, 12, 13 and 15 in plain words.
  - Pacing: `Viaf::Client`, the gate (`viaf:pause`: a block pauses one hour, doubling to a day, and a real answer resets it; fewer than 50 requests left pauses one hour), `RateLimited`, and the reschedule with jitter.
  - Why a rescheduled run repeats nothing: suggestions are cached a day, clusters are stored, and every fetched cluster is kept (ruling 5).
  - About 200–300 authors a day at 3–5 requests each against the roughly 1,000-a-day budget.
- **"The ledger".** Add the `books.author_viaf` kind, provider `viaf`, with the same "processed" rule, and its failure reasons: `resolve_failed`, `viaf_error`, `held_viaf_conflict`. A `RateLimited` VIAF run writes no row, because every VIAF call happens before its decision.
- **"Operating".** Add the one-author snippets, `Services::Books::Authors::EnrichFromViaf.call(author: Books::Author.find(id))` and `Books::Authors::ViafJob.new.perform(author_id)`. Add how to read the gate from a console: `Viaf::Gate.new.wait_seconds`, plus `Viaf::Client.new.last_rate_limit` after a call. Add the "VIAF link" audit filter and `Enrichment.for_kind("books.author_viaf")`.
- **Launch sequence.** Add that VIAF identifiers stamped by `ApplyViaf` are lost on re-migration like the Wikidata ones. The `external_records` VIAF rows survive, so a re-run re-reads stored clusters without spending budget. Only AutoSuggest repeats (once a day per name, cached), plus the AI selections.

- [ ] **Step 2: Update `docs/features/viaf-api-client.md`**

- **"Usage".** Add `Viaf::Client` as the client background jobs use:
  - `suggest` (cached a day), `cluster` and `last_rate_limit`;
  - `:immediate` pace;
  - gate checked before every request;
  - `RateLimited` for a closed gate, a busy pace or a block.

  Keep the direct `AutoSuggest`/`Cluster` examples for console use and note they block, 30 s between requests.
- **"Rate limits".** Add the gate (ruling 7 and 8). Keep "never retry a 403" and explain how the gate enforces it.
- **"Caching".** Clusters now also store the gzipped raw response in `raw`, and the distiller keeps up to 200 work titles (`SCHEMA_VERSION` 2).
- **Stale claim.** Fix the claim that `BaseClient` uses `conn.response :follow_redirects`: it follows redirects itself, one limiter slot per hop (see `base_client.rb`).
- **AutoSuggest's 2026 shape.** Natural-order terms, several rows per cluster, en-dash dates, work rows of other name types, and duplicate clusters for one person.
- **Unknown dates.** `deathDate: 0`, partial dates and a `dateType` other than `lived`.
- **"Not built".** Replace it: `Services::Books::Authors::ResolveViaf`/`ApplyViaf` now consume the client (see `docs/features/books-author-enrichment.md`). Merged clusters still cache under the superseded id, and re-keying is still deferred.

- [ ] **Step 3: Run the full suite, zeitwerk and lint**

Run: `bin/rails test && CI=1 bin/rails zeitwerk:check && bundle exec standardrb`
Expected:
- 0 failures, 0 errors, and no warning lines beyond the two known upstream sources;
- "All is good!";
- no offenses.

- [ ] **Step 4: Commit**

```bash
git add docs/features/books-author-enrichment.md docs/features/viaf-api-client.md
git commit -m "Docs: the VIAF step of author enrichment and the jobs' VIAF client

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the final review: the real-API smoke run (Shane's go-ahead required)

Spec §15 asks for a console smoke run against the real APIs before an API increment merges. This one hits VIAF, whose firewall bans the machine's IP for a while if tripped. Run it only when Shane says so.

1. Snapshot the dev DB: `bin/snapshot-dev-db.sh --label pre-viaf-smoke`.
2. Pick about ten authors that Wikidata misses. Start from `MatchDecision.where(finder: "Services::Books::Authors::ResolveWikidata", outcome: :unmatched)`, or run `EnrichFromWikidata` on long-tail authors first. Include Stacy Willingham (duplicate clusters) if she misses. Include an author with a pen name and one with a non-Latin name.
3. Run the chain one author at a time: `Books::Authors::ViafJob.new.perform(id)`. A `RateLimited` ends a call early, which is expected at two requests a minute: run that author again after `Viaf::Gate.new.wait_seconds` or the pace clears. Expect 3–5 requests per author and about 30 minutes in all.
4. Report for each author: the decision (rule, AI or unmatched, and confidence), what was applied, whether a Wikidata id came back and what the `via_viaf` run did, and any wrong match. Include `Viaf::Client.new.last_rate_limit` at the end.
