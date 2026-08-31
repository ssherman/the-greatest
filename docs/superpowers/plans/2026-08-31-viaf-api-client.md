# VIAF API Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only Ruby client for the VIAF authority file that resolves author names to VIAF clusters and returns distilled person data, caching every fetched record so no cluster is ever fetched twice.

**Architecture:** A global `Viaf::` namespace under `app/lib/viaf/`, layered like the existing `Music::Musicbrainz` client: `BaseClient` handles HTTP, `Normalizer` and `Distiller` are pure functions over JSON, and `Cluster` / `Search::AutoSuggest` / `Search::PersonSearch` are the public entry points. Fetched clusters are distilled (not archived raw) into a generic `external_records` table keyed by `(source, source_id)`. Nothing writes to `Books::Author`.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, Faraday 2.14, PostgreSQL 17, Minitest + Mocha + WebMock, standardrb.

**Spec:** `docs/superpowers/specs/2026-08-30-viaf-api-client-design.md`

## Global Constraints

- **Working directory is `web-app/`.** Run all Rails commands from there. Docs live in `docs/` at the project root.
- **Branch is `viaf-api-client`.** Already created; the spec is committed on it. Never commit to `main`.
- **Linter is `bundle exec standardrb`**, not `bin/rubocop`. Run `--fix` before each commit.
- **Use Rails generators for models.** `bin/rails generate model ...`. Never hand-create a model or its migration.
- **Rails 8 enum syntax:** `enum :source, {viaf: 0}` with a colon prefix. Never `enum source: {...}`.
- **Minitest is 6.x.** `assert_equal nil, x` is a hard failure. Use `assert_nil`.
- **WebMock is globally enabled** in `test/test_helper.rb` via `WebMock.disable_net_connect!(allow_localhost: true)`. No test may make a real HTTP request to viaf.org.
- **Services use the Result pattern** where they return status, but this client follows the `Music::Musicbrainz` convention instead: `BaseClient#get` returns a hash `{success:, data:, errors:, metadata:}` and raises `Viaf::Exceptions::*` on failure. Higher-level classes return value objects.
- **No class-level documentation files.** Code is the source of truth. Feature docs go in `docs/features/`.
- **100% coverage of public methods. Never test private methods.**
- **Fixture names are semantic** (`regular_user`), never `one`/`two`.
- All new Ruby files start with `# frozen_string_literal: true`.

---

### Task 1: `external_records` table and model

Generic cache table for external provider payloads. No polymorphic owner: it is keyed by the provider's own identifier so a `Books::Author` and a `Music::Artist` resolving to the same VIAF cluster share one row.

**Files:**
- Create: `web-app/app/models/external_record.rb` (via generator)
- Create: `web-app/db/migrate/<timestamp>_create_external_records.rb` (via generator)
- Create: `web-app/test/fixtures/external_records.yml`
- Test: `web-app/test/models/external_record_test.rb` (created by generator)

**Interfaces:**
- Consumes: nothing
- Produces: `ExternalRecord` with `enum :source, {viaf: 0}`, string `source_id`, jsonb `payload`, integer `schema_version` (default 1), datetime `fetched_at`. Unique index on `(source, source_id)`. Scope `ExternalRecord.stale(before)`.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model ExternalRecord source:integer source_id:string payload:jsonb schema_version:integer fetched_at:datetime
```

- [ ] **Step 2: Edit the migration to add constraints and indexes**

Replace the generated migration body in `web-app/db/migrate/<timestamp>_create_external_records.rb`:

```ruby
class CreateExternalRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :external_records do |t|
      t.integer :source, null: false
      t.string :source_id, null: false
      t.jsonb :payload, null: false
      t.integer :schema_version, null: false, default: 1
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :external_records, [:source, :source_id], unique: true
    add_index :external_records, [:source, :fetched_at]
  end
end
```

- [ ] **Step 3: Write the failing model test**

Create `web-app/test/models/external_record_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class ExternalRecordTest < ActiveSupport::TestCase
  test "valid with required attributes" do
    record = ExternalRecord.new(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389"},
      fetched_at: Time.current
    )

    assert record.valid?
  end

  test "requires source_id" do
    record = ExternalRecord.new(source: :viaf, payload: {}, fetched_at: Time.current)

    assert_not record.valid?
    assert_includes record.errors[:source_id], "can't be blank"
  end

  test "requires payload" do
    record = ExternalRecord.new(source: :viaf, source_id: "1", fetched_at: Time.current)

    assert_not record.valid?
    assert_includes record.errors[:payload], "can't be blank"
  end

  test "source_id is unique per source" do
    ExternalRecord.create!(
      source: :viaf, source_id: "96987389", payload: {}, fetched_at: Time.current
    )

    duplicate = ExternalRecord.new(
      source: :viaf, source_id: "96987389", payload: {}, fetched_at: Time.current
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:source_id], "has already been taken"
  end

  test "schema_version defaults to 1" do
    record = ExternalRecord.create!(
      source: :viaf, source_id: "1", payload: {}, fetched_at: Time.current
    )

    assert_equal 1, record.schema_version
  end

  test "stale scope returns records fetched before the cutoff" do
    old = ExternalRecord.create!(
      source: :viaf, source_id: "old", payload: {}, fetched_at: 10.days.ago
    )
    ExternalRecord.create!(
      source: :viaf, source_id: "fresh", payload: {}, fetched_at: 1.hour.ago
    )

    assert_equal [old], ExternalRecord.stale(3.days.ago).to_a
  end

  test "source enum exposes viaf" do
    record = ExternalRecord.new(source: :viaf)

    assert record.viaf?
    assert_equal "viaf", record.source
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd web-app && bin/rails db:test:prepare && bin/rails test test/models/external_record_test.rb`
Expected: FAIL. The migration has not run and the validations do not exist.

- [ ] **Step 5: Run the migration**

```bash
cd web-app
bin/rails db:migrate
```

Then diff `db/schema.rb`. Worktrees share the development database, so `db:migrate` can pull sibling branches' migrations into `schema.rb`. Only stage the `external_records` table and the schema version bump.

- [ ] **Step 6: Write the model**

Replace `web-app/app/models/external_record.rb`:

```ruby
# frozen_string_literal: true

class ExternalRecord < ApplicationRecord
  enum :source, {viaf: 0}

  validates :source, presence: true
  validates :source_id, presence: true, uniqueness: {scope: :source}
  validates :payload, presence: true
  validates :fetched_at, presence: true

  scope :stale, ->(cutoff) { where(fetched_at: ...cutoff) }
end
```

- [ ] **Step 7: Create the fixtures file**

Create `web-app/test/fixtures/external_records.yml`:

```yaml
# Read about fixtures at https://api.rubyonrails.org/classes/ActiveRecord/FixtureSet.html

tolstoy_viaf:
  source: 0
  source_id: "96987389"
  schema_version: 1
  fetched_at: <%= 1.day.ago.to_fs(:db) %>
  payload: >
    {"viaf_id":"96987389","name_type":"Personal","birth_date":"1828-09-09",
     "death_date":"1910-11-20","date_type":"lived","gender":"b",
     "source_ids":{"LC":"n79068416","ISNI":"0000000122424494","WKP":"Q7243"},
     "main_headings":[{"source":"LC","name":"Tolstoy, Leo"}],
     "names":["Tolstoi, Lev Nikolaevich"],
     "nationality":["RU"],"language":["rus"],
     "occupation":["authors"],"field_of_activity":["literature"]}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/models/external_record_test.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 9: Annotate, lint, and commit**

```bash
cd web-app
bundle exec annotaterb models
bundle exec standardrb --fix app/models/external_record.rb test/models/external_record_test.rb
bin/rails test test/models/external_record_test.rb
git add app/models/external_record.rb db/migrate db/schema.rb test/models/external_record_test.rb test/fixtures/external_records.yml
git commit -m "Add generic external_records cache table"
```

---

### Task 2: `Viaf::Configuration` and `Viaf::Exceptions`

**Files:**
- Create: `web-app/app/lib/viaf/configuration.rb`
- Create: `web-app/app/lib/viaf/exceptions.rb`
- Test: `web-app/test/lib/viaf/configuration_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `Viaf::Configuration#base_url`, `#user_agent`, `#timeout`, `#open_timeout`, `#logger`. `Viaf::Exceptions::Error` and subclasses `ConfigurationError`, `NetworkError`, `TimeoutError`, `HttpError(message, status_code, response_body)`, `ClientError`, `ServerError`, `NotFoundError`, `BadRequestError`, `ParseError(message, response_body)`, `BlockedError`, `AbandonedRecordError`.

- [ ] **Step 1: Write the failing configuration test**

Create `web-app/test/lib/viaf/configuration_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::ConfigurationTest < ActiveSupport::TestCase
  test "defaults to the public VIAF host" do
    assert_equal "https://viaf.org", Viaf::Configuration.new.base_url
  end

  test "reads the base url from the environment" do
    ENV["VIAF_URL"] = "https://example.test"

    assert_equal "https://example.test", Viaf::Configuration.new.base_url
  ensure
    ENV.delete("VIAF_URL")
  end

  test "sets a descriptive user agent" do
    assert_match(/TheGreatest/, Viaf::Configuration.new.user_agent)
  end

  test "rejects a blank base url" do
    ENV["VIAF_URL"] = ""

    assert_raises(ArgumentError) { Viaf::Configuration.new }
  ensure
    ENV.delete("VIAF_URL")
  end

  test "rejects a non-http base url" do
    ENV["VIAF_URL"] = "ftp://viaf.org"

    assert_raises(ArgumentError) { Viaf::Configuration.new }
  ensure
    ENV.delete("VIAF_URL")
  end

  test "has sane timeouts" do
    config = Viaf::Configuration.new

    assert_equal 30, config.timeout
    assert_equal 10, config.open_timeout
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/configuration_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf`.

- [ ] **Step 3: Write the exceptions**

Create `web-app/app/lib/viaf/exceptions.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  module Exceptions
    class Error < StandardError; end

    class ConfigurationError < Error; end

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

    class ClientError < HttpError; end

    class ServerError < HttpError; end

    class NotFoundError < ClientError; end

    class BadRequestError < ClientError; end

    # Cloudflare refused to forward the request. This is NOT VIAF rejecting it.
    # Roughly 5-8 rapid requests trips a WAF rule that blocks the IP for minutes.
    # Never retry: evidence suggests retrying refreshes the ban.
    class BlockedError < HttpError; end

    class ParseError < Error
      attr_reader :response_body

      def initialize(message, response_body = nil)
        super(message)
        @response_body = response_body
      end
    end

    # The cluster exists but VIAF has withdrawn it (abandoned / scavenged / redirect).
    class AbandonedRecordError < Error; end
  end
end
```

- [ ] **Step 4: Write the configuration**

Create `web-app/app/lib/viaf/configuration.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  class Configuration
    DEFAULT_URL = "https://viaf.org"
    DEFAULT_USER_AGENT = "TheGreatest/1.0 (+https://thegreatestbooks.org)"
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 10

    attr_accessor :base_url, :user_agent, :timeout, :open_timeout, :logger

    def initialize
      @base_url = ENV.fetch("VIAF_URL", DEFAULT_URL)
      @user_agent = DEFAULT_USER_AGENT
      @timeout = DEFAULT_TIMEOUT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @logger = Rails.logger

      validate_configuration!
    end

    private

    def validate_configuration!
      raise ArgumentError, "VIAF_URL cannot be blank" if base_url.blank?

      uri = URI.parse(base_url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise ArgumentError, "VIAF_URL must be a valid HTTP/HTTPS URL"
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "VIAF_URL must be a valid URL"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/configuration_test.rb`
Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 6: Verify Zeitwerk can load the new directory**

`eager_load` is off in the test environment, so a naming mistake in `app/lib/viaf/` will not surface during tests.

Run: `cd web-app && CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 7: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf test/lib/viaf
git add app/lib/viaf test/lib/viaf
git commit -m "Add Viaf configuration and exception hierarchy"
```

---

### Task 3: `Viaf::RateLimiter`

Configured for **spacing, not throughput**. The Cloudflare WAF trips far below the ~1,000/day application budget, so the binding constraint is burst rate.

**Files:**
- Create: `web-app/app/lib/viaf/rate_limiter.rb`
- Test: `web-app/test/lib/viaf/rate_limiter_test.rb`

**Interfaces:**
- Consumes: `DistributedRateLimiter.new(key:, limit:, window:, mode:)` and its `#acquire!`
- Produces: `Viaf::RateLimiter.new(mode: :blocking)` with `#wait!`. Constants `REQUESTS_PER_WINDOW = 2`, `WINDOW_SECONDS = 60.0`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/rate_limiter_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::RateLimiterTest < ActiveSupport::TestCase
  test "delegates to DistributedRateLimiter with spacing configuration" do
    underlying = mock("distributed_limiter")
    underlying.expects(:acquire!).returns({allowed: true, remaining: 1, retry_after: 0.0})

    DistributedRateLimiter.expects(:new).with(
      key: "viaf:api",
      limit: 2,
      window: 60.0,
      mode: :blocking
    ).returns(underlying)

    Viaf::RateLimiter.new.wait!
  end

  test "supports immediate mode" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).returns({allowed: true, remaining: 1, retry_after: 0.0})

    DistributedRateLimiter.expects(:new).with(
      key: "viaf:api",
      limit: 2,
      window: 60.0,
      mode: :immediate
    ).returns(underlying)

    Viaf::RateLimiter.new(mode: :immediate).wait!
  end

  test "propagates RateLimitExceeded from the underlying limiter" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).raises(
      DistributedRateLimiter::RateLimitExceeded.new("nope", key: "viaf:api", retry_after: 5.0)
    )
    DistributedRateLimiter.stubs(:new).returns(underlying)

    assert_raises(DistributedRateLimiter::RateLimitExceeded) do
      Viaf::RateLimiter.new(mode: :immediate).wait!
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/rate_limiter_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::RateLimiter`.

- [ ] **Step 3: Write the rate limiter**

Create `web-app/app/lib/viaf/rate_limiter.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # Paces requests to stay under VIAF's Cloudflare WAF, which trips at roughly
  # 5-8 requests in rapid succession and then blocks the IP for minutes.
  # Two requests per minute (~30s apart) is deliberately more conservative than
  # the 25s spacing that was verified safe. The ~1,000/day application budget
  # cannot be spent at this pace, so it is not the binding constraint.
  class RateLimiter
    REQUESTS_PER_WINDOW = 2
    WINDOW_SECONDS = 60.0

    def initialize(mode: :blocking)
      @limiter = ::DistributedRateLimiter.new(
        key: "viaf:api",
        limit: REQUESTS_PER_WINDOW,
        window: WINDOW_SECONDS,
        mode: mode
      )
    end

    def wait!
      @limiter.acquire!
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/rate_limiter_test.rb`
Expected: PASS, 3 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/rate_limiter.rb test/lib/viaf/rate_limiter_test.rb
git add app/lib/viaf/rate_limiter.rb test/lib/viaf/rate_limiter_test.rb
git commit -m "Add Viaf rate limiter tuned for the Cloudflare WAF"
```

---

### Task 4: `Viaf::BaseClient`

The HTTP layer. Its most important job is distinguishing a Cloudflare block from a VIAF error.

**Files:**
- Create: `web-app/app/lib/viaf/base_client.rb`
- Create: `web-app/test/fixtures/files/viaf/cloudflare_blocked.html`
- Test: `web-app/test/lib/viaf/base_client_test.rb`

**Interfaces:**
- Consumes: `Viaf::Configuration`, `Viaf::RateLimiter`, `Viaf::Exceptions`
- Produces: `Viaf::BaseClient#get(path, params = {})` returning `{success: true, data: Hash, errors: [], metadata: {path:, response_time:, status_code:, rate_limit: {remaining:, limit:, remaining_day:}}}`. Also `#last_rate_limit` returning the most recent budget hash or `nil`.

- [ ] **Step 1: Create the Cloudflare block fixture**

Create `web-app/test/fixtures/files/viaf/cloudflare_blocked.html`. This is a trimmed copy of a real 403 body observed from viaf.org:

```html
<!DOCTYPE html>
<html class="no-js" lang="en-US">
<head>
<title>Attention Required! | Cloudflare</title>
<meta charset="UTF-8" />
<meta name="robots" content="noindex, nofollow" />
</head>
<body>
  <div id="cf-wrapper">
    <h1 data-translate="block_headline">Sorry, you have been blocked</h1>
    <h2 data-translate="blocked_why_headline">Why have I been blocked?</h2>
    <p>This website is using a security service to protect itself from online attacks.</p>
    <div class="cf-error-footer">
      <p>Cloudflare Ray ID: <strong>a33434762e3d3acc</strong></p>
    </div>
  </div>
</body>
</html>
```

- [ ] **Step 2: Write the failing client test**

Create `web-app/test/lib/viaf/base_client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::BaseClientTest < ActiveSupport::TestCase
  def setup
    @config = Viaf::Configuration.new
    @config.base_url = "https://viaf.test"
    @limiter = mock("rate_limiter")
    @limiter.stubs(:wait!)
    Viaf::RateLimiter.stubs(:new).returns(@limiter)
    @client = Viaf::BaseClient.new(@config)
  end

  test "sends an Accept: application/json header" do
    stub = stub_request(:get, "https://viaf.test/viaf/96987389")
      .with(headers: {"Accept" => "application/json"})
      .to_return(status: 200, body: '{"ok":true}', headers: {"Content-Type" => "application/json"})

    @client.get("viaf/96987389")

    assert_requested stub
  end

  test "sends the configured User-Agent" do
    stub = stub_request(:get, "https://viaf.test/viaf/1")
      .with(headers: {"User-Agent" => @config.user_agent})
      .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

    @client.get("viaf/1")

    assert_requested stub
  end

  test "acquires a rate limit slot before every request" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

    @limiter.expects(:wait!).once

    @client.get("viaf/1")
  end

  test "returns parsed data on success" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: '{"ns1:viafID":1}', headers: {"Content-Type" => "application/json"})

    result = @client.get("viaf/1")

    assert result[:success]
    assert_equal({"ns1:viafID" => 1}, result[:data])
    assert_empty result[:errors]
  end

  test "captures rate limit headers into metadata" do
    stub_request(:get, "https://viaf.test/viaf/1").to_return(
      status: 200,
      body: "{}",
      headers: {
        "Content-Type" => "application/json",
        "ratelimit-limit" => "1003",
        "ratelimit-remaining" => "998",
        "x-ratelimit-remaining-day" => "998"
      }
    )

    result = @client.get("viaf/1")

    assert_equal 998, result[:metadata][:rate_limit][:remaining]
    assert_equal 1003, result[:metadata][:rate_limit][:limit]
    assert_equal 998, @client.last_rate_limit[:remaining_day]
  end

  test "raises BlockedError on a Cloudflare 403, not ParseError" do
    body = file_fixture("viaf/cloudflare_blocked.html").read
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 403, body: body, headers: {"Content-Type" => "text/html"})

    error = assert_raises(Viaf::Exceptions::BlockedError) { @client.get("viaf/1") }

    assert_equal 403, error.status_code
    assert_match(/blocked/i, error.message)
  end

  test "raises NotFoundError on 404" do
    stub_request(:get, "https://viaf.test/viaf/nope")
      .to_return(status: 404, body: '{"message":"not found"}')

    assert_raises(Viaf::Exceptions::NotFoundError) { @client.get("viaf/nope") }
  end

  test "raises ServerError on 500" do
    stub_request(:get, "https://viaf.test/viaf/1").to_return(status: 500, body: "boom")

    assert_raises(Viaf::Exceptions::ServerError) { @client.get("viaf/1") }
  end

  test "raises ParseError when a 200 body is not JSON" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: "<html>nope</html>", headers: {"Content-Type" => "text/html"})

    assert_raises(Viaf::Exceptions::ParseError) { @client.get("viaf/1") }
  end

  # WebMock's to_timeout raises Net::OpenTimeout, which Faraday's net_http
  # adapter maps to ConnectionFailed rather than TimeoutError. Assert on the
  # NetworkError parent so this holds either way (TimeoutError < NetworkError).
  test "raises NetworkError when the connection times out" do
    stub_request(:get, "https://viaf.test/viaf/1").to_timeout

    assert_raises(Viaf::Exceptions::NetworkError) { @client.get("viaf/1") }
  end

  test "raises TimeoutError when Faraday reports a read timeout" do
    stub_request(:get, "https://viaf.test/viaf/1").to_raise(Faraday::TimeoutError)

    assert_raises(Viaf::Exceptions::TimeoutError) { @client.get("viaf/1") }
  end

  test "follows redirects for merged clusters" do
    stub_request(:get, "https://viaf.test/viaf/111")
      .to_return(status: 301, headers: {"Location" => "https://viaf.test/viaf/222"})
    stub_request(:get, "https://viaf.test/viaf/222")
      .to_return(status: 200, body: '{"ns1:viafID":222}', headers: {"Content-Type" => "application/json"})

    result = @client.get("viaf/111")

    assert_equal({"ns1:viafID" => 222}, result[:data])
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/base_client_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::BaseClient`.

- [ ] **Step 4: Write the client**

Create `web-app/app/lib/viaf/base_client.rb`:

```ruby
# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
require "json"

module Viaf
  # HTTP transport for VIAF.
  #
  # VIAF dropped format suffixes in the January 2025 rebuild, so the content
  # type is negotiated with an Accept header rather than a .json path suffix.
  class BaseClient
    BLOCKED_MARKER = "you have been blocked"

    attr_reader :config, :connection, :last_rate_limit

    def initialize(config = nil, rate_limiter: nil)
      @config = config || Configuration.new
      @rate_limiter = rate_limiter || RateLimiter.new
      @connection = build_connection
      @last_rate_limit = nil
    end

    def get(path, params = {})
      start_time = Time.current
      @rate_limiter.wait!

      response = connection.get(path) do |req|
        req.params = params
        req.headers["Accept"] = "application/json"
        req.headers["User-Agent"] = config.user_agent
      end

      parse_response(response, path, start_time)
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Network error: #{e.message}", e)
    end

    private

    def build_connection
      Faraday.new(url: config.base_url) do |conn|
        conn.options.timeout = config.timeout
        conn.options.open_timeout = config.open_timeout
        # Merged clusters answer 301 pointing at the surviving cluster.
        conn.response :follow_redirects, limit: 3
        conn.adapter Faraday.default_adapter
      end
    end

    def parse_response(response, path, start_time)
      response_time = Time.current - start_time
      @last_rate_limit = extract_rate_limit(response)

      case response.status
      when 200
        parse_success(response, path, response_time)
      when 403
        raise Exceptions::BlockedError.new(blocked_message(response), 403, response.body)
      when 400
        raise Exceptions::BadRequestError.new("Bad request", 400, response.body)
      when 404
        raise Exceptions::NotFoundError.new("Not found", 404, response.body)
      when 400..499
        raise Exceptions::ClientError.new("Client error: #{response.status}", response.status, response.body)
      when 500..599
        raise Exceptions::ServerError.new("Server error: #{response.status}", response.status, response.body)
      else
        raise Exceptions::HttpError.new("Unexpected status: #{response.status}", response.status, response.body)
      end
    end

    def blocked_message(response)
      if response.body.to_s.downcase.include?(BLOCKED_MARKER)
        "Cloudflare blocked this request. Do not retry; back off."
      else
        "Forbidden (403). Treating as blocked; do not retry."
      end
    end

    def parse_success(response, path, response_time)
      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise Exceptions::ParseError.new("Failed to parse JSON response: #{e.message}", response.body)
      end

      {
        success: true,
        data: parsed,
        errors: [],
        metadata: {
          path: path,
          response_time: response_time.round(3),
          status_code: response.status,
          rate_limit: @last_rate_limit
        }
      }
    end

    def extract_rate_limit(response)
      headers = response.respond_to?(:headers) ? response.headers : {}
      {
        limit: headers["ratelimit-limit"]&.to_i,
        remaining: headers["ratelimit-remaining"]&.to_i,
        remaining_day: headers["x-ratelimit-remaining-day"]&.to_i
      }
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/base_client_test.rb`
Expected: PASS, 13 runs, 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/base_client.rb test/lib/viaf/base_client_test.rb
git add app/lib/viaf/base_client.rb test/lib/viaf/base_client_test.rb test/fixtures/files/viaf
git commit -m "Add Viaf base client with Cloudflare block detection"
```

---

### Task 5: `Viaf::Normalizer`

A pure function. This is one of the two highest-value tests in the plan because every downstream parse depends on it.

**Files:**
- Create: `web-app/app/lib/viaf/normalizer.rb`
- Test: `web-app/test/lib/viaf/normalizer_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `Viaf::Normalizer.call(object)` returning a deep copy with namespace prefixes stripped from every hash key. `Viaf::Normalizer.array(value)` returning `[]` for nil, the value for an array, `[value]` otherwise.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/normalizer_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::NormalizerTest < ActiveSupport::TestCase
  test "strips the ns1 prefix used by cluster fetches" do
    assert_equal({"viafID" => 1}, Viaf::Normalizer.call({"ns1:viafID" => 1}))
  end

  test "strips incrementing prefixes used by search results" do
    input = {"ns2:VIAFCluster" => {"ns3:viafID" => 1}}

    assert_equal({"VIAFCluster" => {"viafID" => 1}}, Viaf::Normalizer.call(input))
  end

  # viapy normalizes with /^ns\d+:/ which silently fails here and yields a nil
  # lookup rather than an error. BriefVIAF really does use a "v:" prefix.
  test "strips a non-numeric prefix such as BriefVIAF's v:" do
    assert_equal({"VIAFCluster" => {}}, Viaf::Normalizer.call({"v:VIAFCluster" => {}}))
  end

  test "preserves xmlns declarations" do
    input = {"xmlns:foaf" => "http://xmlns.com/foaf/0.1/", "ns1:viafID" => 1}

    assert_equal(
      {"xmlns:foaf" => "http://xmlns.com/foaf/0.1/", "viafID" => 1},
      Viaf::Normalizer.call(input)
    )
  end

  test "recurses through arrays" do
    input = {"ns1:sources" => [{"ns1:s" => "LC"}, {"ns1:s" => "BNF"}]}

    assert_equal({"sources" => [{"s" => "LC"}, {"s" => "BNF"}]}, Viaf::Normalizer.call(input))
  end

  test "leaves keys without a prefix alone" do
    assert_equal({"content" => 5}, Viaf::Normalizer.call({"content" => 5}))
  end

  test "leaves scalars alone" do
    assert_equal 5, Viaf::Normalizer.call(5)
    assert_nil Viaf::Normalizer.call(nil)
  end

  test "array wraps a bare value" do
    assert_equal ["LC"], Viaf::Normalizer.array("LC")
  end

  test "array passes an array through" do
    assert_equal ["LC", "BNF"], Viaf::Normalizer.array(["LC", "BNF"])
  end

  test "array turns nil into an empty array" do
    assert_equal [], Viaf::Normalizer.array(nil)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/normalizer_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Normalizer`.

- [ ] **Step 3: Write the normalizer**

Create `web-app/app/lib/viaf/normalizer.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # VIAF's JSON is a mechanical translation of XML, so every key carries a
  # namespace prefix. The prefix is not stable: cluster fetches use "ns1:",
  # search results increment per result ("ns2:", "ns3:"), and BriefVIAF uses
  # "v:". Anything matching only /^ns\d+:/ will silently miss the last case.
  module Normalizer
    module_function

    def call(object)
      case object
      when Hash
        object.each_with_object({}) { |(key, value), acc| acc[strip_prefix(key)] = call(value) }
      when Array
        object.map { |element| call(element) }
      else
        object
      end
    end

    def array(value)
      case value
      when nil then []
      when Array then value
      else [value]
      end
    end

    def strip_prefix(key)
      key_string = key.to_s
      return key_string if key_string.start_with?("xmlns")
      return key_string unless key_string.include?(":")

      key_string.split(":", 2).last
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/normalizer_test.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/normalizer.rb test/lib/viaf/normalizer_test.rb
git add app/lib/viaf/normalizer.rb test/lib/viaf/normalizer_test.rb
git commit -m "Add Viaf normalizer for unstable namespace prefixes"
```

---

### Task 6: `Viaf::Distiller`

Turns a normalized cluster into the small payload we persist. This is the other highest-value test: it encodes every parsing landmine from spec §7.

**Files:**
- Create: `web-app/app/lib/viaf/distiller.rb`
- Test: `web-app/test/lib/viaf/distiller_test.rb`

**Interfaces:**
- Consumes: `Viaf::Normalizer`, `Viaf::Exceptions::AbandonedRecordError`
- Produces: `Viaf::Distiller.call(raw_cluster_hash, requested_id:)` returning a `Hash` with string keys `viaf_id`, `name_type`, `birth_date`, `death_date`, `date_type`, `gender`, `source_ids`, `main_headings`, `names`, `nationality`, `language`, `occupation`, `field_of_activity`. Constant `Viaf::Distiller::SCHEMA_VERSION = 1`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/distiller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::DistillerTest < ActiveSupport::TestCase
  # Shapes below are copied from real responses observed on 2026-08-30.
  def cluster(overrides = {})
    {
      "ns1:VIAFCluster" => {
        "ns1:viafID" => 96987389,
        "ns1:nameType" => "Personal",
        "ns1:birthDate" => "1828-09-09",
        "ns1:deathDate" => "1910-11-20",
        "ns1:dateType" => "lived",
        "ns1:fixed" => {"ns1:gender" => "b"},
        "ns1:sources" => {
          "ns1:source" => [
            {"ns1:nsid" => "n  79068416", "ns1:content" => "LC|n  79068416"},
            {"ns1:nsid" => "Q7243", "ns1:content" => "WKP|Q7243"},
            {"ns1:nsid" => 56654, "ns1:content" => "PTBNP|56654"}
          ]
        },
        "ns1:mainHeadings" => {
          "ns1:mainHeadingEl" => [{
            "ns1:sources" => {"ns1:s" => "LC"},
            "ns1:datafield" => {
              "tag" => 100,
              "ns1:subfield" => [
                {"code" => "a", "content" => "Tolstoy, Leo,"},
                {"code" => "d", "content" => "1828-1910"}
              ]
            }
          }]
        },
        "ns1:x400s" => {
          "ns1:x400" => [{
            "ns1:datafield" => {
              "tag" => 400,
              "ns1:subfield" => [{"code" => "a", "content" => "Tolstoi, Lev Nikolaevich"}]
            }
          }]
        },
        "ns1:nationalityOfEntity" => {
          "ns1:data" => {"ns1:sources" => {"ns1:s" => ["LC", "BNF"]}, "ns1:text" => "RU"}
        },
        "ns1:languageOfEntity" => {"ns1:data" => {"ns1:text" => "rus"}},
        "ns1:occupation" => {"ns1:data" => [{"ns1:text" => "authors"}]},
        "ns1:fieldOfActivity" => {"ns1:data" => [{"ns1:text" => "literature"}]}
      }
    }.deep_merge(overrides)
  end

  def distill(overrides = {}, requested_id: "96987389")
    Viaf::Distiller.call(cluster(overrides), requested_id: requested_id)
  end

  test "extracts the scalar fields" do
    result = distill

    assert_equal "Personal", result["name_type"]
    assert_equal "1828-09-09", result["birth_date"]
    assert_equal "1910-11-20", result["death_date"]
    assert_equal "lived", result["date_type"]
    assert_equal "b", result["gender"]
  end

  # VIAF has been seen emitting viafID in scientific notation, which Ruby parses
  # as a Float and coerces back to the WRONG integer. Always carry the requested id.
  test "uses the requested id rather than the echoed one" do
    result = distill({"ns1:VIAFCluster" => {"ns1:viafID" => 2.71711845065478e+19}},
      requested_id: "27171184506547771093")

    assert_equal "27171184506547771093", result["viaf_id"]
  end

  test "viaf_id is always a string" do
    assert_instance_of String, distill["viaf_id"]
  end

  test "parses source ids from content, splitting on the pipe" do
    result = distill

    assert_equal "Q7243", result["source_ids"]["WKP"]
    assert_equal "56654", result["source_ids"]["PTBNP"]
  end

  # LC arrives space-padded as "n  79068416" but AutoSuggest returns "n79068416"
  # for the same record. Squeezing instead of stripping writes two values.
  test "strips all whitespace from identifier values" do
    assert_equal "n79068416", distill["source_ids"]["LC"]
  end

  # nsid and content can disagree; content is authoritative.
  test "prefers content over a disagreeing nsid" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {"ns1:source" => [
      {"ns1:nsid" => "LNB:V*35849;=BP", "ns1:content" => "LIH|LNB:V-35849;=BP"}
    ]}}})

    assert_equal "LNB:V-35849;=BP", result["source_ids"]["LIH"]
  end

  test "handles a single source that is not wrapped in an array" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {
      "ns1:source" => {"ns1:content" => "LC|n123"}
    }}})

    assert_equal "n123", result["source_ids"]["LC"]
  end

  test "keeps main headings with their contributing source" do
    assert_equal [{"source" => "LC", "name" => "Tolstoy, Leo"}], distill["main_headings"]
  end

  # MARC21 tag 100 and UNIMARC tag 200 assign different meanings to the same
  # subfield codes, and some agencies use integer codes. Naive joining yields
  # "eng ba Austen J. 1775-1817 Jane".
  test "selects only name subfields and ignores integer codes" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => "NLR"},
      "ns1:datafield" => {"tag" => 200, "ns1:subfield" => [
        {"code" => 8, "content" => "eng"},
        {"code" => 7, "content" => "ba"},
        {"code" => "a", "content" => "Austen"},
        {"code" => "b", "content" => "J."},
        {"code" => "f", "content" => "1775-1817"},
        {"code" => "g", "content" => "Jane"}
      ]}
    }]}}})

    assert_equal [{"source" => "NLR", "name" => "Austen J."}], result["main_headings"]
  end

  test "takes the first source when a heading lists several" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => ["DNB", "SZ"]},
      "ns1:datafield" => {"tag" => 100, "ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}
    }]}}})

    assert_equal "DNB", result["main_headings"].first["source"]
  end

  test "collects deduplicated alternate names from x400s" do
    result = distill({"ns1:VIAFCluster" => {"ns1:x400s" => {"ns1:x400" => [
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}},
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}},
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "تولستوي"}]}}
    ]}}})

    assert_equal ["Tolstoi", "تولستوي"], result["names"].sort
  end

  test "collects text values, coercing a lone data hash into an array" do
    result = distill

    assert_equal ["RU"], result["nationality"]
    assert_equal ["rus"], result["language"]
    assert_equal ["authors"], result["occupation"]
    assert_equal ["literature"], result["field_of_activity"]
  end

  test "returns empty collections when fields are absent" do
    minimal = {"ns1:VIAFCluster" => {"ns1:viafID" => 1, "ns1:nameType" => "Personal"}}
    result = Viaf::Distiller.call(minimal, requested_id: "1")

    assert_nil result["birth_date"]
    assert_nil result["gender"]
    assert_empty result["source_ids"]
    assert_empty result["names"]
    assert_empty result["nationality"]
  end

  test "raises AbandonedRecordError for a withdrawn cluster" do
    assert_raises(Viaf::Exceptions::AbandonedRecordError) do
      Viaf::Distiller.call({"ns1:abandoned_viaf_record" => "true"}, requested_id: "1")
    end
  end

  test "raises AbandonedRecordError for a scavenged cluster" do
    assert_raises(Viaf::Exceptions::AbandonedRecordError) do
      Viaf::Distiller.call({"ns1:scavenged" => "true"}, requested_id: "1")
    end
  end

  test "raises ParseError when no cluster is present" do
    assert_raises(Viaf::Exceptions::ParseError) do
      Viaf::Distiller.call({"something" => "else"}, requested_id: "1")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/distiller_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Distiller`.

- [ ] **Step 3: Write the distiller**

Create `web-app/app/lib/viaf/distiller.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # Reduces a VIAF cluster to the ~13 fields worth persisting.
  #
  # Roughly 82% of a cluster is MARC scaffolding around the name forms: each
  # x400 entry spends ~870 bytes to convey a ~25 byte name, and Tolstoy's 1,016
  # entries deduplicate to 777 unique strings. Distilling is a 25-46x reduction
  # with no loss of information we can use.
  #
  # This is deliberately separate from the HTTP client so a future dump-based
  # backfill can reuse it: the dump contains the same cluster records.
  module Distiller
    SCHEMA_VERSION = 1

    # MARC name subfields. Deliberately excludes dates (d/f) and the language
    # and script codes some agencies emit as integer codes.
    NAME_SUBFIELD_CODES = %w[a b c q].freeze

    WITHDRAWN_MARKERS = %w[
      abandoned abandoned_viaf_record scavenged redirect directto
    ].freeze

    module_function

    def call(raw, requested_id:)
      normalized = Normalizer.call(raw)
      guard_withdrawn!(normalized)

      cluster = normalized["VIAFCluster"]
      if cluster.nil?
        raise Exceptions::ParseError.new("No VIAFCluster in response", raw.to_s[0, 500])
      end

      {
        "viaf_id" => requested_id.to_s,
        "name_type" => cluster["nameType"],
        "birth_date" => cluster["birthDate"],
        "death_date" => cluster["deathDate"],
        "date_type" => cluster["dateType"],
        "gender" => cluster.dig("fixed", "gender"),
        "source_ids" => source_ids(cluster),
        "main_headings" => main_headings(cluster),
        "names" => alternate_names(cluster),
        "nationality" => text_values(cluster, "nationalityOfEntity"),
        "language" => text_values(cluster, "languageOfEntity"),
        "occupation" => text_values(cluster, "occupation"),
        "field_of_activity" => text_values(cluster, "fieldOfActivity")
      }
    end

    def guard_withdrawn!(normalized)
      return unless normalized.is_a?(Hash)

      marker = WITHDRAWN_MARKERS.find { |key| normalized.key?(key) }
      return if marker.nil?

      raise Exceptions::AbandonedRecordError, "VIAF cluster is #{marker}"
    end

    # sources.source entries look like {"nsid" => ..., "content" => "LC|n  79068416"}.
    # nsid can disagree with content and is sometimes an Integer, so content wins.
    def source_ids(cluster)
      entries = Normalizer.array(cluster.dig("sources", "source"))

      entries.each_with_object({}) do |entry, acc|
        content = entry.is_a?(Hash) ? entry["content"] : entry
        next unless content.is_a?(String) && content.include?("|")

        code, local = content.split("|", 2)
        next if acc.key?(code)

        acc[code] = local.gsub(/\s+/, "")
      end
    end

    def main_headings(cluster)
      Normalizer.array(cluster.dig("mainHeadings", "mainHeadingEl")).filter_map do |entry|
        name = heading_name(entry)
        next if name.blank?

        {"source" => Normalizer.array(entry.dig("sources", "s")).first, "name" => name}
      end
    end

    def alternate_names(cluster)
      Normalizer.array(cluster.dig("x400s", "x400")).filter_map { |entry| heading_name(entry).presence }.uniq
    end

    def heading_name(entry)
      subfields = Normalizer.array(entry.dig("datafield", "subfield"))

      parts = subfields.filter_map do |subfield|
        next unless subfield.is_a?(Hash)
        next unless NAME_SUBFIELD_CODES.include?(subfield["code"].to_s)

        subfield["content"].to_s
      end

      parts.join(" ").squish.sub(/[,\s]+\z/, "")
    end

    def text_values(cluster, field)
      Normalizer.array(cluster.dig(field, "data")).filter_map do |entry|
        entry["text"] if entry.is_a?(Hash)
      end.uniq
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/distiller_test.rb`
Expected: PASS, 16 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/distiller.rb test/lib/viaf/distiller_test.rb
git add app/lib/viaf/distiller.rb test/lib/viaf/distiller_test.rb
git commit -m "Add Viaf distiller encoding the MARC parsing landmines"
```

---

### Task 7: `Viaf::Person` and `Viaf::Suggestion`

Value objects. `Person` is always built from a distilled payload so a cache hit and a fresh fetch cannot diverge.

**Files:**
- Create: `web-app/app/lib/viaf/person.rb`
- Create: `web-app/app/lib/viaf/suggestion.rb`
- Test: `web-app/test/lib/viaf/person_test.rb`
- Test: `web-app/test/lib/viaf/suggestion_test.rb`

**Interfaces:**
- Consumes: the distilled payload hash from `Viaf::Distiller.call`
- Produces:
  - `Viaf::Person.from_payload(hash)` with readers `viaf_id`, `name_type`, `birth_date`, `death_date`, `gender_code`, `source_ids`, `main_headings`, `names`, `nationality`, `language`, `occupation`, `field_of_activity`; derived `#birth_year`, `#death_year`, `#gender`, `#kind`, `#preferred_name`, `#viaf?`/`#isni`/`#wikidata_qid`/`#lcnaf`.
  - `Viaf::Suggestion.from_result(hash)` with readers `viaf_id`, `term`, `name_type`, `score`, `source_ids`; derived `#birth_year`, `#death_year`, `#kind`.

- [ ] **Step 1: Write the failing Person test**

Create `web-app/test/lib/viaf/person_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::PersonTest < ActiveSupport::TestCase
  def payload(overrides = {})
    {
      "viaf_id" => "96987389",
      "name_type" => "Personal",
      "birth_date" => "1828-09-09",
      "death_date" => "1910-11-20",
      "gender" => "b",
      "source_ids" => {"LC" => "n79068416", "ISNI" => "0000000122424494", "WKP" => "Q7243"},
      "main_headings" => [{"source" => "LC", "name" => "Tolstoy, Leo"}],
      "names" => ["Tolstoi, Lev Nikolaevich"],
      "nationality" => ["RU"],
      "language" => ["rus"],
      "occupation" => ["authors"],
      "field_of_activity" => ["literature"]
    }.merge(overrides)
  end

  def person(overrides = {})
    Viaf::Person.from_payload(payload(overrides))
  end

  test "exposes the raw payload fields" do
    assert_equal "96987389", person.viaf_id
    assert_equal ["RU"], person.nationality
  end

  test "derives birth and death years from day-precision dates" do
    assert_equal 1828, person.birth_year
    assert_equal 1910, person.death_year
  end

  test "derives years from year-precision integers" do
    subject = person("birth_date" => 1473, "death_date" => 1531)

    assert_equal 1473, subject.birth_year
    assert_equal 1531, subject.death_year
  end

  test "handles BCE years" do
    assert_equal(-384, person("birth_date" => "-384").birth_year)
  end

  test "returns nil years when dates are absent" do
    subject = person("birth_date" => nil, "death_date" => nil)

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "maps gender codes to the Books::Author enum values" do
    assert_equal :male, person("gender" => "b").gender
    assert_equal :female, person("gender" => "a").gender
    assert_equal :unspecified, person("gender" => "u").gender
    assert_nil person("gender" => nil).gender
  end

  test "maps name type to the Books::Author kind enum" do
    assert_equal :person, person("name_type" => "Personal").kind
    assert_equal :organization, person("name_type" => "Corporate").kind
    assert_nil person("name_type" => "UniformTitle").kind
  end

  test "exposes mapped identifiers" do
    subject = person

    assert_equal "n79068416", subject.lcnaf
    assert_equal "0000000122424494", subject.isni
    assert_equal "Q7243", subject.wikidata_qid
  end

  test "returns nil for identifiers the cluster lacks" do
    assert_nil person("source_ids" => {}).isni
  end

  test "preferred_name uses the first main heading" do
    assert_equal "Tolstoy, Leo", person.preferred_name
  end

  test "preferred_name falls back to the first alternate name" do
    assert_equal "Tolstoi, Lev Nikolaevich", person("main_headings" => []).preferred_name
  end

  test "preferred_name is nil when there are no names at all" do
    assert_nil person("main_headings" => [], "names" => []).preferred_name
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/person_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Person`.

- [ ] **Step 3: Write Person**

Create `web-app/app/lib/viaf/person.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # A distilled VIAF cluster. Always constructed from the persisted payload so
  # a cache hit and a fresh fetch produce an identical object.
  #
  # Every field is optional. The heavily catalogued authors used to design this
  # have 44-48 contributing agencies; a mid-list contemporary novelist may have
  # two, with no gender, no birth date and no ISNI.
  class Person
    GENDER_CODES = {"a" => :female, "b" => :male, "u" => :unspecified}.freeze
    NAME_TYPE_KINDS = {"Personal" => :person, "Corporate" => :organization}.freeze

    attr_reader :viaf_id, :name_type, :birth_date, :death_date, :gender_code,
      :source_ids, :main_headings, :names, :nationality, :language,
      :occupation, :field_of_activity

    def self.from_payload(payload)
      new(payload)
    end

    def initialize(payload)
      @viaf_id = payload["viaf_id"]
      @name_type = payload["name_type"]
      @birth_date = payload["birth_date"]
      @death_date = payload["death_date"]
      @gender_code = payload["gender"]
      @source_ids = payload["source_ids"] || {}
      @main_headings = payload["main_headings"] || []
      @names = payload["names"] || []
      @nationality = payload["nationality"] || []
      @language = payload["language"] || []
      @occupation = payload["occupation"] || []
      @field_of_activity = payload["field_of_activity"] || []
    end

    def birth_year = year_from(birth_date)

    def death_year = year_from(death_date)

    def gender = GENDER_CODES[gender_code]

    def kind = NAME_TYPE_KINDS[name_type]

    def lcnaf = source_ids["LC"]

    def isni = source_ids["ISNI"]

    def wikidata_qid = source_ids["WKP"]

    def preferred_name
      main_headings.first&.fetch("name", nil) || names.first
    end

    private

    # Dates are strings at day precision ("1828-09-09") and integers at year
    # precision (1473). Negative years occur.
    def year_from(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      match = value.to_s.match(/\A(-?\d+)/)
      match && match[1].to_i
    end
  end
end
```

- [ ] **Step 4: Run the Person test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/person_test.rb`
Expected: PASS, 12 runs, 0 failures.

- [ ] **Step 5: Write the failing Suggestion test**

Create `web-app/test/lib/viaf/suggestion_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::SuggestionTest < ActiveSupport::TestCase
  # Real AutoSuggest result observed on 2026-08-30. Agency codes arrive as
  # variable top-level keys mixed in with the structural keys.
  def result(overrides = {})
    {
      "term" => "Tolstoy, Leo, graf, 1828-1910",
      "displayForm" => "Tolstoy, Leo, graf, 1828-1910",
      "nametype" => "personal",
      "lc" => "n79068416",
      "dnb" => "11864291x",
      "bnf" => "11926775",
      "viafid" => "96987389",
      "score" => "63074",
      "recordID" => "96987389"
    }.merge(overrides)
  end

  def suggestion(overrides = {})
    Viaf::Suggestion.from_result(result(overrides))
  end

  test "exposes the structural fields" do
    subject = suggestion

    assert_equal "96987389", subject.viaf_id
    assert_equal "Tolstoy, Leo, graf, 1828-1910", subject.term
    assert_equal "personal", subject.name_type
    assert_equal 63074, subject.score
  end

  test "collects agency ids from the variable top-level keys" do
    subject = suggestion

    assert_equal "n79068416", subject.source_ids["lc"]
    assert_equal "11926775", subject.source_ids["bnf"]
  end

  test "excludes structural keys from source_ids" do
    subject = suggestion

    refute subject.source_ids.key?("term")
    refute subject.source_ids.key?("viafid")
    refute subject.source_ids.key?("score")
    refute subject.source_ids.key?("nametype")
    refute subject.source_ids.key?("recordID")
    refute subject.source_ids.key?("displayForm")
  end

  test "parses birth and death years out of the term string" do
    subject = suggestion

    assert_equal 1828, subject.birth_year
    assert_equal 1910, subject.death_year
  end

  test "parses an open-ended date range" do
    subject = suggestion("term" => "Smith, Jane, 1950-")

    assert_equal 1950, subject.birth_year
    assert_nil subject.death_year
  end

  test "returns nil years when the term carries no dates" do
    subject = suggestion("term" => "Anonymous")

    assert_nil subject.birth_year
    assert_nil subject.death_year
  end

  test "maps nametype to the Books::Author kind enum" do
    assert_equal :person, suggestion("nametype" => "personal").kind
    assert_equal :organization, suggestion("nametype" => "corporate").kind
    assert_nil suggestion("nametype" => "uniformtitle").kind
  end
end
```

- [ ] **Step 6: Run the Suggestion test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/suggestion_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Suggestion`.

- [ ] **Step 7: Write Suggestion**

Create `web-app/app/lib/viaf/suggestion.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # One AutoSuggest candidate.
  #
  # AutoSuggest is ~250x cheaper than a cluster fetch (3 KB for ten candidates
  # versus 361-782 KB for one author), so resolution happens here and only the
  # chosen VIAF ID gets an expensive cluster fetch.
  class Suggestion
    # Everything else in the response is a contributing agency code.
    STRUCTURAL_KEYS = %w[term displayForm nametype viafid score recordID].freeze

    NAME_TYPE_KINDS = {"personal" => :person, "corporate" => :organization}.freeze

    attr_reader :viaf_id, :term, :display_form, :name_type, :score, :source_ids

    def self.from_result(result)
      new(result)
    end

    def initialize(result)
      @viaf_id = result["viafid"].to_s
      @term = result["term"]
      @display_form = result["displayForm"]
      @name_type = result["nametype"]
      @score = result["score"]&.to_i
      @source_ids = result.except(*STRUCTURAL_KEYS)
    end

    def kind = NAME_TYPE_KINDS[name_type]

    def birth_year = date_range[0]

    def death_year = date_range[1]

    private

    # Dates are embedded in the heading, e.g. "Tolstoy, Leo, graf, 1828-1910".
    def date_range
      @date_range ||= begin
        match = term.to_s.match(/(\d{3,4})\s*-\s*(\d{3,4})?/)
        match ? [match[1].to_i, match[2]&.to_i] : [nil, nil]
      end
    end
  end
end
```

- [ ] **Step 8: Run both tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/viaf/person_test.rb test/lib/viaf/suggestion_test.rb`
Expected: PASS, 19 runs, 0 failures.

- [ ] **Step 9: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf test/lib/viaf
git add app/lib/viaf/person.rb app/lib/viaf/suggestion.rb test/lib/viaf/person_test.rb test/lib/viaf/suggestion_test.rb
git commit -m "Add Viaf Person and Suggestion value objects"
```

---

### Task 8: `Viaf::Search::AutoSuggest`

**Files:**
- Create: `web-app/app/lib/viaf/search/auto_suggest.rb`
- Test: `web-app/test/lib/viaf/search/auto_suggest_test.rb`

**Interfaces:**
- Consumes: `Viaf::BaseClient#get`, `Viaf::Suggestion.from_result`
- Produces: `Viaf::Search::AutoSuggest.new(client = nil)#call(query)` returning `Array<Viaf::Suggestion>`, empty when VIAF matches nothing.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/search/auto_suggest_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::Search::AutoSuggestTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @search = Viaf::Search::AutoSuggest.new(@client)
  end

  def response(results)
    {success: true, data: {"query" => "tolstoy", "result" => results}, errors: [], metadata: {}}
  end

  test "requests the AutoSuggest endpoint with the query" do
    @client.expects(:get).with("viaf/AutoSuggest", {query: "tolstoy"}).returns(response([]))

    @search.call("tolstoy")
  end

  test "returns Suggestion objects" do
    @client.stubs(:get).returns(response([
      {"term" => "Tolstoy, Leo, graf, 1828-1910", "nametype" => "personal",
       "viafid" => "96987389", "score" => "63074", "lc" => "n79068416"}
    ]))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_instance_of Viaf::Suggestion, results.first
    assert_equal "96987389", results.first.viaf_id
    assert_equal 1828, results.first.birth_year
  end

  test "returns an empty array when result is null" do
    @client.stubs(:get).returns(
      {success: true, data: {"query" => "zzz", "result" => nil}, errors: [], metadata: {}}
    )

    assert_empty @search.call("zzz")
  end

  test "returns an empty array when result is missing" do
    @client.stubs(:get).returns({success: true, data: {"query" => "zzz"}, errors: [], metadata: {}})

    assert_empty @search.call("zzz")
  end

  test "raises ArgumentError for a blank query" do
    assert_raises(ArgumentError) { @search.call("") }
    assert_raises(ArgumentError) { @search.call(nil) }
  end

  test "propagates BlockedError from the client" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_raises(Viaf::Exceptions::BlockedError) { @search.call("tolstoy") }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/search/auto_suggest_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Search`.

- [ ] **Step 3: Write AutoSuggest**

Create `web-app/app/lib/viaf/search/auto_suggest.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  module Search
    # Cheap candidate resolution. 3 KB returns ten ranked candidates carrying
    # VIAF IDs, name types, dates embedded in the heading, and agency IDs.
    class AutoSuggest
      ENDPOINT = "viaf/AutoSuggest"

      def initialize(client = nil)
        @client = client || BaseClient.new
      end

      def call(query)
        raise ArgumentError, "query cannot be blank" if query.blank?

        response = @client.get(ENDPOINT, {query: query})

        Normalizer.array(response[:data]["result"]).map do |result|
          Suggestion.from_result(result)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/search/auto_suggest_test.rb`
Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/search test/lib/viaf/search
git add app/lib/viaf/search/auto_suggest.rb test/lib/viaf/search/auto_suggest_test.rb
git commit -m "Add Viaf AutoSuggest search"
```

---

### Task 9: `Viaf::Cluster`

Owns the cache. This is the task that ties storage to transport.

**Files:**
- Create: `web-app/app/lib/viaf/cluster.rb`
- Test: `web-app/test/lib/viaf/cluster_test.rb`

**Interfaces:**
- Consumes: `Viaf::BaseClient#get`, `Viaf::Distiller.call`, `Viaf::Person.from_payload`, `ExternalRecord`
- Produces: `Viaf::Cluster.new(client = nil)#find(viaf_id, refresh: false)` returning `Viaf::Person`. Raises `Viaf::Exceptions::NotFoundError` for an unknown ID and `Viaf::Exceptions::AbandonedRecordError` for a withdrawn one.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/cluster_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::ClusterTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @cluster = Viaf::Cluster.new(@client)
  end

  def raw_response
    {
      success: true,
      data: {
        "ns1:VIAFCluster" => {
          "ns1:viafID" => 96987389,
          "ns1:nameType" => "Personal",
          "ns1:birthDate" => "1828-09-09",
          "ns1:deathDate" => "1910-11-20",
          "ns1:fixed" => {"ns1:gender" => "b"},
          "ns1:sources" => {"ns1:source" => [{"ns1:content" => "LC|n  79068416"}]},
          "ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
            "ns1:sources" => {"ns1:s" => "LC"},
            "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoy, Leo"}]}
          }]}
        }
      },
      errors: [],
      metadata: {}
    }
  end

  test "fetches, distills, and returns a Person on a cache miss" do
    @client.expects(:get).with("viaf/96987389").returns(raw_response)

    person = @cluster.find("96987389")

    assert_instance_of Viaf::Person, person
    assert_equal "96987389", person.viaf_id
    assert_equal 1828, person.birth_year
    assert_equal "n79068416", person.lcnaf
  end

  test "writes exactly one ExternalRecord on a cache miss" do
    @client.stubs(:get).returns(raw_response)

    assert_difference "ExternalRecord.count", 1 do
      @cluster.find("96987389")
    end

    record = ExternalRecord.find_by(source: :viaf, source_id: "96987389")

    assert_equal "Personal", record.payload["name_type"]
    assert_equal Viaf::Distiller::SCHEMA_VERSION, record.schema_version
    assert_not_nil record.fetched_at
  end

  test "does not hit the network on a cache hit" do
    ExternalRecord.create!(
      source: :viaf,
      source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Personal", "birth_date" => "1828-09-09"},
      fetched_at: Time.current
    )
    @client.expects(:get).never

    person = @cluster.find("96987389")

    assert_equal 1828, person.birth_year
  end

  test "a cache hit and a fresh fetch produce equal people" do
    @client.stubs(:get).returns(raw_response)
    fresh = @cluster.find("96987389")

    cached = Viaf::Cluster.new(@client).find("96987389")

    assert_equal fresh.viaf_id, cached.viaf_id
    assert_equal fresh.birth_year, cached.birth_year
    assert_equal fresh.lcnaf, cached.lcnaf
    assert_equal fresh.preferred_name, cached.preferred_name
  end

  test "refresh: true refetches and updates the existing row" do
    ExternalRecord.create!(
      source: :viaf, source_id: "96987389",
      payload: {"viaf_id" => "96987389", "name_type" => "Stale"},
      fetched_at: 10.days.ago
    )
    @client.expects(:get).returns(raw_response)

    assert_no_difference "ExternalRecord.count" do
      @cluster.find("96987389", refresh: true)
    end

    assert_equal "Personal", ExternalRecord.find_by(source_id: "96987389").payload["name_type"]
  end

  test "raises ArgumentError for a blank id" do
    assert_raises(ArgumentError) { @cluster.find("") }
    assert_raises(ArgumentError) { @cluster.find(nil) }
  end

  test "propagates NotFoundError and caches nothing" do
    @client.stubs(:get).raises(Viaf::Exceptions::NotFoundError.new("nope", 404, "{}"))

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::NotFoundError) { @cluster.find("999") }
    end
  end

  test "propagates AbandonedRecordError and caches nothing" do
    @client.stubs(:get).returns(
      {success: true, data: {"ns1:scavenged" => "true"}, errors: [], metadata: {}}
    )

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::AbandonedRecordError) { @cluster.find("999") }
    end
  end

  test "propagates BlockedError and caches nothing" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_no_difference "ExternalRecord.count" do
      assert_raises(Viaf::Exceptions::BlockedError) { @cluster.find("96987389") }
    end
  end

  test "accepts an integer viaf id" do
    @client.stubs(:get).returns(raw_response)

    assert_equal "96987389", @cluster.find(96987389).viaf_id
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/cluster_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Cluster`.

- [ ] **Step 3: Write Cluster**

Create `web-app/app/lib/viaf/cluster.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  # Fetches one cluster by VIAF ID, and owns the cache.
  #
  # Person is always built from the distilled payload, never from raw response
  # JSON, so a cache hit and a fresh fetch cannot diverge.
  class Cluster
    def initialize(client = nil)
      @client = client || BaseClient.new
    end

    def find(viaf_id, refresh: false)
      id = viaf_id.to_s
      raise ArgumentError, "viaf_id cannot be blank" if id.blank?

      record = ExternalRecord.find_by(source: :viaf, source_id: id) unless refresh
      return Person.from_payload(record.payload) if record

      payload = fetch_and_distill(id)
      store(id, payload)
      Person.from_payload(payload)
    end

    private

    def fetch_and_distill(id)
      response = @client.get("viaf/#{id}")
      Distiller.call(response[:data], requested_id: id)
    end

    def store(id, payload)
      record = ExternalRecord.find_or_initialize_by(source: :viaf, source_id: id)
      record.payload = payload
      record.schema_version = Distiller::SCHEMA_VERSION
      record.fetched_at = Time.current
      record.save!
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/cluster_test.rb`
Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/cluster.rb test/lib/viaf/cluster_test.rb
git add app/lib/viaf/cluster.rb test/lib/viaf/cluster_test.rb
git commit -m "Add Viaf cluster fetch with external_records caching"
```

---

### Task 10: `Viaf::Search::PersonSearch`

SRU/CQL search, used when AutoSuggest does not resolve a name. Its response shape differs from a cluster fetch in three ways that all need handling.

**Files:**
- Create: `web-app/app/lib/viaf/search/person_search.rb`
- Test: `web-app/test/lib/viaf/search/person_search_test.rb`

**Interfaces:**
- Consumes: `Viaf::BaseClient#get`, `Viaf::Normalizer`, `Viaf::Distiller`, `Viaf::Person`
- Produces: `Viaf::Search::PersonSearch.new(client = nil)#call(name, limit: 10)` returning `Array<Viaf::Person>`. Does **not** write to `external_records`: search returns whole clusters, but they arrive without a requested-ID guarantee, so caching them would risk storing a payload under a lossy ID.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/viaf/search/person_search_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Viaf::Search::PersonSearchTest < ActiveSupport::TestCase
  def setup
    @client = mock("client")
    @search = Viaf::Search::PersonSearch.new(@client)
  end

  # Namespace prefixes increment per result: ns2 for the first, ns3 for the second.
  def record(prefix, viaf_id, name)
    {
      "recordData" => {
        "#{prefix}:VIAFCluster" => {
          "#{prefix}:viafID" => viaf_id,
          "#{prefix}:nameType" => "Personal",
          "#{prefix}:mainHeadings" => {
            "#{prefix}:mainHeadingEl" => [{
              "#{prefix}:sources" => {"#{prefix}:s" => "LC"},
              "#{prefix}:datafield" => {"#{prefix}:subfield" => [{"code" => "a", "content" => name}]}
            }]
          }
        }
      }
    }
  end

  def response(records, count: nil)
    {
      success: true,
      data: {
        "searchRetrieveResponse" => {
          "numberOfRecords" => {"content" => count || Array(records).size},
          "records" => {"record" => records}
        }
      },
      errors: [],
      metadata: {}
    }
  end

  test "builds a CQL personal-names query" do
    @client.expects(:get).with("viaf/search", {
      query: 'local.personalNames all "leo tolstoy"',
      maximumRecords: 10,
      sortKey: "holdingscount"
    }).returns(response([]))

    @search.call("leo tolstoy")
  end

  test "honours the limit" do
    @client.expects(:get).with("viaf/search", has_entry(maximumRecords: 3)).returns(response([]))

    @search.call("tolstoy", limit: 3)
  end

  test "escapes double quotes in the query" do
    @client.expects(:get).with(
      "viaf/search",
      has_entry(query: 'local.personalNames all "the \\"great\\" author"')
    ).returns(response([]))

    @search.call('the "great" author')
  end

  test "returns Person objects" do
    @client.stubs(:get).returns(response([record("ns2", 96987389, "Tolstoy, Leo")]))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_instance_of Viaf::Person, results.first
    assert_equal "96987389", results.first.viaf_id
    assert_equal "Tolstoy, Leo", results.first.preferred_name
  end

  # ns2 for record 1, ns3 for record 2. A /^ns\d+:/ regex handles this, but the
  # normalizer must not assume the prefix is identical across records.
  test "handles incrementing namespace prefixes across records" do
    @client.stubs(:get).returns(response([
      record("ns2", 96987389, "Tolstoy, Leo"),
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal %w[96987389 102333412], results.map(&:viaf_id)
    assert_equal ["Tolstoy, Leo", "Austen, Jane"], results.map(&:preferred_name)
  end

  # records.record is an object for one hit and an array for several.
  test "handles a single record arriving unwrapped" do
    @client.stubs(:get).returns(response(record("ns2", 96987389, "Tolstoy, Leo")))

    results = @search.call("tolstoy")

    assert_equal 1, results.size
    assert_equal "96987389", results.first.viaf_id
  end

  test "returns an empty array when nothing matched" do
    @client.stubs(:get).returns(
      {success: true, data: {"searchRetrieveResponse" => {
        "numberOfRecords" => {"content" => 0}
      }}, errors: [], metadata: {}}
    )

    assert_empty @search.call("zzzznotanauthor")
  end

  test "skips records that fail to distill rather than aborting the search" do
    @client.stubs(:get).returns(response([
      {"recordData" => {"ns2:something" => "unusable"}},
      record("ns3", 102333412, "Austen, Jane")
    ]))

    results = @search.call("authors")

    assert_equal ["102333412"], results.map(&:viaf_id)
  end

  test "raises ArgumentError for a blank name" do
    assert_raises(ArgumentError) { @search.call("") }
    assert_raises(ArgumentError) { @search.call(nil) }
  end

  test "propagates BlockedError from the client" do
    @client.stubs(:get).raises(Viaf::Exceptions::BlockedError.new("blocked", 403, "<html>"))

    assert_raises(Viaf::Exceptions::BlockedError) { @search.call("tolstoy") }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/viaf/search/person_search_test.rb`
Expected: FAIL with `NameError: uninitialized constant Viaf::Search::PersonSearch`.

- [ ] **Step 3: Write PersonSearch**

Create `web-app/app/lib/viaf/search/person_search.rb`:

```ruby
# frozen_string_literal: true

module Viaf
  module Search
    # SRU/CQL search, for when AutoSuggest does not resolve a name.
    #
    # Much more expensive than AutoSuggest: a 3-record search is ~136 KB against
    # AutoSuggest's 3 KB for ten candidates. Prefer AutoSuggest.
    #
    # Results are NOT cached in external_records. Search returns whole clusters,
    # but the viafID in the body is the only ID available and VIAF has been seen
    # emitting it in lossy scientific notation, so there is no trustworthy cache
    # key. Fetch the chosen ID through Viaf::Cluster to cache it.
    class PersonSearch
      ENDPOINT = "viaf/search"
      DEFAULT_LIMIT = 10

      def initialize(client = nil)
        @client = client || BaseClient.new
      end

      def call(name, limit: DEFAULT_LIMIT)
        raise ArgumentError, "name cannot be blank" if name.blank?

        response = @client.get(ENDPOINT, {
          query: %(local.personalNames all "#{escape(name)}"),
          maximumRecords: limit,
          sortKey: "holdingscount"
        })

        records(response[:data]).filter_map { |record| person_from(record) }
      end

      private

      # Block form: gsub's replacement string treats backslashes as escapes,
      # so a literal '\\"' replacement is ambiguous.
      def escape(name) = name.gsub('"') { '\\"' }

      def records(data)
        Normalizer.array(data.dig("searchRetrieveResponse", "records", "record"))
      end

      def person_from(record)
        cluster = record["recordData"]
        return nil if cluster.nil?

        normalized = Normalizer.call(cluster)
        viaf_id = normalized.dig("VIAFCluster", "viafID")
        return nil if viaf_id.nil?

        payload = Distiller.call(cluster, requested_id: viaf_id.to_s)
        Person.from_payload(payload)
      rescue Exceptions::Error
        nil
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/viaf/search/person_search_test.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/viaf/search test/lib/viaf/search
git add app/lib/viaf/search/person_search.rb test/lib/viaf/search/person_search_test.rb
git commit -m "Add Viaf SRU person search"
```

---

### Task 11: Feature documentation and full-suite verification

**Files:**
- Create: `docs/features/viaf-api-client.md` (project root, NOT `web-app/docs/`)

**Interfaces:**
- Consumes: everything built in Tasks 1-10
- Produces: no code

- [ ] **Step 1: Write the feature doc**

Create `docs/features/viaf-api-client.md`:

````markdown
# VIAF API Client

Read-only client for VIAF (Virtual International Authority File), OCLC's aggregation of name
authority records from ~50 national libraries. Used to enrich author identity data: dates, name
variants, and cross-references to ISNI, Wikidata and LCNAF.

Design and research notes: `docs/superpowers/specs/2026-08-30-viaf-api-client-design.md`.

## Usage

Resolve a name to candidates (cheap, ~3 KB):

```ruby
candidates = Viaf::Search::AutoSuggest.new.call("leo tolstoy")
candidates.first.viaf_id     # => "96987389"
candidates.first.birth_year  # => 1828
candidates.first.kind        # => :person
```

Fetch full detail for a chosen ID (expensive, 361-782 KB, cached after the first call):

```ruby
person = Viaf::Cluster.new.find("96987389")
person.birth_year     # => 1828
person.gender         # => :male
person.isni           # => "0000000122424494"
person.wikidata_qid   # => "Q7243"
person.lcnaf          # => "n79068416"
person.names          # => [...] alternate name forms
```

Fall back to CQL search when AutoSuggest does not resolve a name:

```ruby
Viaf::Search::PersonSearch.new.call("leo tolstoy", limit: 5)
```

## Rate limits

**Two independent limiters.**

1. An application budget of roughly **1,000/day per IP**, reported on every response in
   `ratelimit-*` headers and available via `client.last_rate_limit`. Only 200s and 404s decrement
   it.
2. A **Cloudflare WAF** that trips at roughly 5-8 requests in rapid succession and blocks the IP
   for minutes. This is the binding constraint. `Viaf::RateLimiter` paces requests at 2 per minute
   to stay under it.

**Never retry a `Viaf::Exceptions::BlockedError`.** Evidence suggests retrying refreshes the ban;
polling every 30s failed to recover within 9.5 minutes. Back off and try later.

## Caching

Every cluster fetched through `Viaf::Cluster#find` is distilled and stored in `external_records`
keyed by `(source: :viaf, source_id: viaf_id)`. Subsequent calls do not hit the network.

We store a **distilled** record, not the raw payload: ~82% of a VIAF cluster is MARC scaffolding
around the name forms, and distilling is a 25-46x reduction with no loss of usable information.
Distillation is lossy, so changing `Viaf::Distiller` means refetching. `schema_version` identifies
rows written by an older distiller.

Force a refresh with `Viaf::Cluster.new.find(id, refresh: true)`.

## What VIAF does and does not provide

Maps cleanly to `Books::Author`: VIAF/ISNI/Wikidata/LCNAF identifiers, `birth_year`, `death_year`,
`gender`, `kind`, name forms.

**VIAF has no biography or description field.** Author descriptions remain the AI description
provider's job.

`nationality`, `occupation` and `field_of_activity` are captured but are multilingual uncontrolled
free text (`philosopher` / `forfatter` / `escritores`) with no home in the current schema.

**Every field is optional.** A mid-list contemporary author may have two contributing agencies, no
gender, no birth date and no ISNI.

## Not built

This client does not write to `Books::Author`. The `AuthorImport` provider that consumes it is a
separate piece of work.

Bulk dumps are not used: OCLC froze them at 2024-08-04 and withdrew the cheap cross-reference
files. If dumps resume, `Viaf::Distiller` is directly reusable since the dump contains the same
cluster records.
````

- [ ] **Step 2: Verify Zeitwerk loads everything**

Run: `cd web-app && CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

- [ ] **Step 3: Run the full VIAF suite**

Run: `cd web-app && bin/rails test test/lib/viaf test/models/external_record_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 4: Run the whole test suite**

Run: `cd web-app && bin/rails db:test:prepare test`
Expected: PASS. Compare the runs count against the pre-change baseline; a clean run emits no new
warnings beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and
npm/yarn during `test:prepare`). A new warning line is a regression.

- [ ] **Step 5: Lint everything**

Run: `cd web-app && bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 6: Confirm no test made a real network call**

Run: `cd web-app && grep -rn "viaf.org" test/ || echo "no real host references in tests"`
Expected: no matches. Tests use `https://viaf.test` or mocked clients.

- [ ] **Step 7: Commit**

```bash
cd /home/shane/dev/the-greatest
git add docs/features/viaf-api-client.md
git commit -m "Document the VIAF API client"
```

---

## Verification checklist

Before considering this complete:

- [ ] `bin/rails test` passes with no new failures and no new warnings
- [ ] `bundle exec standardrb` reports no offenses
- [ ] `CI=1 bin/rails zeitwerk:check` passes
- [ ] No test makes a real HTTP request to viaf.org
- [ ] `db/schema.rb` contains only the `external_records` change, not sibling worktrees' migrations
- [ ] Nothing in `app/lib/viaf/` writes to `Books::Author` or `Identifier`
