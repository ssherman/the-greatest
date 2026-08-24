# Books Amazon Product Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Amazon product enrichment to the books domain — where a validated match becomes a `Books::Edition`, not just a link — and collapse the duplicated music and games orchestrators into one template-method base class.

**Architecture:** A new `Services::Amazon::BaseProductService` owns the pipeline (`validate → search → AI match → persist → after_persist`). Music, games and books subclass it and fill four hooks. Books' `persist_match` delegates to a dedicated `AmazonEditionUpserter` that upserts a `Books::Edition` keyed on a new edition-level ASIN identifier, which a one-time backfill must write for the 148,296 legacy editions first.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, Minitest + Mocha + WebMock, Sidekiq 9, `vacuum` 5.1 (Amazon Creators API), OpenAI `gpt-5-mini` via `Services::Ai`.

**Spec:** `docs/superpowers/specs/2026-08-24-books-amazon-product-service-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**, not `web-app/docs/`.
- Linter is `bundle exec standardrb` — **never** `bin/rubocop`.
- Never run a destructive command against the development database. `bin/rails test` only.
- Before any test run: `ps aux | grep "[r]ails test"` — concurrent runs share one database and manufacture phantom failures.
- Namespace all media code. Inside `Services::Books::`, a bare `Books::Book` resolves to the **nested** module — root-anchor `::Books::Book` in implementation **and** test files.
- Rails 8 enum syntax: `enum :status, {active: 0}`.
- Use `find_or_initialize_by` for identifiers, never `build`.
- Services return the Hash `{success:, data:, error:, errors:}` — **not** the `Result` struct. Existing tests and jobs depend on it.
- Sidekiq test mode is `:inline` globally; never `require "sidekiq/testing"`.
- Minitest 6: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Jobs are generated with `bin/rails generate sidekiq:job books/foo`, never `generate job`.
- No new user-facing pages in this plan, so no Playwright E2E is required.

---

### Task 1: Base product service + music refactor

**Files:**
- Create: `web-app/app/lib/services/amazon/base_product_service.rb`
- Modify: `web-app/app/lib/services/music/amazon_product_service.rb` (full rewrite, 226 → ~55 lines)
- Test: `web-app/test/lib/services/music/amazon_product_service_test.rb` (unchanged — it is the safety net)

**Interfaces:**
- Consumes: `::Services::Amazon::Client.search_items(**params)` → Array of product Hashes, raises `::Services::Amazon::Client::Error` on non-2xx. `::Services::Amazon::Product.lowest_price_cents(product)` → Integer or nil.
- Produces: `Services::Amazon::BaseProductService` with public `#call` → `{success:, data:}` / `{success:, error:, errors:}`; protected constant `AMAZON_RESOURCES`; private hooks `#validation_errors` → Array<String>, `#search_param_sets` → Array<Hash>, `#match_task_class` → Class, `#persist_match(match, product)` → ExternalLink or nil, `#after_persist(validated_results, search_results)` → ignored; private helpers `#upsert_external_link(parent:, product:, metadata: {})` → ExternalLink, `#attach_primary_image(parent:, image_url:)` → nil, `#best_product(validated_results, search_results)` → Hash or nil, `#product_for(match, search_results)` → Hash or nil, `#extract_price_cents(product)` → Integer or nil, `#success(message)`, `#failure(error)`.

- [ ] **Step 1: Confirm the safety net is green before touching anything**

Run:

```bash
cd web-app
ps aux | grep "[r]ails test"   # must print nothing
bin/rails test test/lib/services/music/amazon_product_service_test.rb test/lib/services/games/amazon_product_service_test.rb test/sidekiq/music/amazon_product_enrichment_job_test.rb test/sidekiq/games/amazon_product_enrichment_job_test.rb test/lib/services/ai/tasks/amazon_product_match_task_test.rb test/lib/services/ai/tasks/amazon_album_match_task_test.rb test/lib/services/ai/tasks/games/amazon_game_match_task_test.rb test/lib/services/amazon
```

Expected: `72 runs, 196 assertions, 0 failures, 0 errors, 0 skips`.

This whole task is a behaviour-preserving refactor. These tests are the specification; you write no new tests here.

- [ ] **Step 2: Create the base class**

Create `web-app/app/lib/services/amazon/base_product_service.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Amazon
    # Template-method base for the per-domain Amazon enrichment services.
    #
    # The pipeline -- search Amazon, ask an AI task which results genuinely match,
    # then persist -- is identical across music, games and books. What differs is
    # what a match becomes: an ExternalLink on the record for music and games, a
    # Books::Edition for books. Subclasses fill in the hooks; the pipeline, the
    # link and image writers, and the result shape live here.
    #
    # The result is a Hash rather than the Result struct used elsewhere because
    # both existing jobs and 359 lines of existing tests read result[:success]
    # and result[:error].
    class BaseProductService
      # Default resources requested from the Creators API. Books overrides this
      # to add itemInfo.externalIds, which carries the ISBNs and EANs it needs.
      AMAZON_RESOURCES = [
        "itemInfo.title",
        "itemInfo.byLineInfo",
        "itemInfo.classifications",
        "itemInfo.contentInfo",
        "itemInfo.productInfo",
        "images.primary.small",
        "images.primary.medium",
        "images.primary.large",
        "browseNodeInfo.websiteSalesRank",
        "offersV2.listings.condition",
        "offersV2.listings.price"
      ].freeze

      def initialize(record)
        @record = record
        @errors = []
      end

      def call
        first_error = validation_errors.first
        return failure(first_error) if first_error

        search_results = search_amazon_products
        return failure("Amazon API search failed: #{@errors.join(", ")}") unless search_results
        return success("No products found") if search_results.empty?

        validated_results = validate_matches_with_ai(search_results)
        return failure("AI validation failed: #{@errors.join(", ")}") unless validated_results
        return success("No matching products found") if validated_results.empty?

        persisted = persist_matches(validated_results, search_results)
        after_persist(validated_results, search_results)

        success("Amazon enrichment completed: #{validated_results.count} products, #{persisted.count} links created")
      rescue => e
        Rails.logger.error "Amazon service error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        failure("Amazon service error: #{e.message}")
      end

      private

      attr_reader :record

      # ---- hooks every subclass must implement ---------------------------

      # Array of human-readable strings. The first one aborts the run.
      def validation_errors
        raise NotImplementedError, "Subclasses must implement #validation_errors"
      end

      # One Hash of search parameters per Amazon call. Most domains need a single
      # call; books makes a second pass against the Audible browse node because
      # the plain search never surfaces audiobooks.
      def search_param_sets
        raise NotImplementedError, "Subclasses must implement #search_param_sets"
      end

      def match_task_class
        raise NotImplementedError, "Subclasses must implement #match_task_class"
      end

      # Returns the ExternalLink created or refreshed for this match, or nil to
      # skip it. Whatever is returned is counted in the success message.
      def persist_match(match, product)
        raise NotImplementedError, "Subclasses must implement #persist_match"
      end

      # ---- optional hook -------------------------------------------------

      # Runs once after every match is persisted. Default is a no-op; music uses
      # it for the album cover, books for the book-level cover and affiliate link.
      def after_persist(validated_results, search_results)
        nil
      end

      def amazon_resources
        self.class::AMAZON_RESOURCES
      end

      # ---- pipeline ------------------------------------------------------

      def search_amazon_products
        param_sets = search_param_sets

        items = param_sets.flat_map do |params|
          ::Services::Amazon::Client.search_items(resources: amazon_resources, **params)
        end

        deduped = items.uniq { |item| item["asin"] }
        Rails.logger.info "Amazon returned #{deduped.count} unique results across #{param_sets.count} search(es)"
        deduped
      rescue => e
        @errors << "Amazon API error: #{e.message}"
        Rails.logger.error "Amazon API error: #{e.message}"
        nil
      end

      def validate_matches_with_ai(search_results)
        result = match_task_class.new(parent: record, search_results: search_results).call

        Rails.logger.info "AI task result: success=#{result.success?}"

        if result.success?
          matching_results = result.data[:matching_results] || []
          Rails.logger.info "Found #{matching_results.count} matching results from AI"
          matching_results
        else
          @errors << result.error
          Rails.logger.error "AI task failed: #{result.error}"
          nil
        end
      end

      def persist_matches(validated_results, search_results)
        validated_results.filter_map do |match|
          product = product_for(match, search_results)

          if product.nil?
            Rails.logger.info "AI returned ASIN #{match[:asin].inspect}, which is not in the search results; skipping"
            next
          end

          persist_match(match, product)
        end
      rescue => e
        @errors << "Failed to persist matches: #{e.message}"
        Rails.logger.error "Persist error: #{e.message}"
        []
      end

      def product_for(match, search_results)
        search_results.find { |item| item["asin"] == match[:asin] }
      end

      # The matched product with the best (lowest) sales rank. Products carrying
      # no rank sort last rather than winning by virtue of a nil.
      def best_product(validated_results, search_results)
        validated_results
          .filter_map { |match| product_for(match, search_results) }
          .min_by { |product| product.dig("browseNodeInfo", "websiteSalesRank", "salesRank") || Float::INFINITY }
      end

      def extract_price_cents(product)
        ::Services::Amazon::Product.lowest_price_cents(product)
      end

      # Creates the link when absent; refreshes price and metadata when present.
      # The detail page URL is the natural key -- it carries the partner tag, so
      # it is also the thing that earns affiliate revenue.
      def upsert_external_link(parent:, product:, metadata: {})
        link = parent.external_links.find_or_initialize_by(
          source: :amazon,
          url: product["detailPageURL"]
        )

        link.name = product.dig("itemInfo", "title", "displayValue").presence || "Amazon Product" if link.name.blank?
        link.link_category = :product_link
        link.public = true if link.new_record?
        link.price_cents = extract_price_cents(product)
        link.metadata = {amazon: product}.merge(metadata)
        link.save!

        Rails.logger.info "#{link.previously_new_record? ? "Created" : "Updated"} external link: #{link.name} (#{link.url})"
        link
      end

      # Attaches the Amazon cover as the parent's primary image. No-op when the
      # parent already has one -- Amazon is a fallback source, never an override
      # for curated art.
      def attach_primary_image(parent:, image_url:)
        return if image_url.blank?

        if parent.images.where(primary: true).exists?
          Rails.logger.info "#{parent.class.name} #{parent.id} already has a primary image; skipping Amazon download"
          return
        end

        tempfile = Down.download(image_url)
        return unless tempfile

        image = parent.images.build(primary: true)
        image.file.attach(
          io: tempfile,
          filename: tempfile.original_filename,
          content_type: tempfile.content_type
        )
        image.save!

        Rails.logger.info "Set primary image for #{parent.class.name} #{parent.id}"
        nil
      rescue => e
        @errors << "Image download failed: #{e.message}"
        Rails.logger.error "Failed to download image from #{image_url}: #{e.message}"
        nil
      ensure
        tempfile&.close
        tempfile&.unlink
      end

      def success(message)
        {success: true, data: message}
      end

      def failure(error)
        {success: false, error: error, errors: @errors}
      end
    end
  end
end
```

- [ ] **Step 3: Rewrite the music service as a subclass**

Replace the entire contents of `web-app/app/lib/services/music/amazon_product_service.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Music
    class AmazonProductService < ::Services::Amazon::BaseProductService
      def self.call(album:)
        new(album).call
      end

      private

      alias_method :album, :record

      def validation_errors
        return ["Album title required"] if album.title.blank?
        return ["Album must have at least one artist"] if album.artists.empty?
        []
      end

      def search_param_sets
        [{
          artist: album.artists.first.name,
          title: album.title,
          search_index: "Music"
        }]
      end

      def match_task_class
        ::Services::Ai::Tasks::Music::AmazonAlbumMatchTask
      end

      def persist_match(match, product)
        upsert_external_link(parent: album, product: product)
      end

      # Amazon is a fallback cover source for albums. attach_primary_image
      # already no-ops when the album has one, so no extra guard is needed here.
      def after_persist(validated_results, search_results)
        product = best_product(validated_results, search_results)
        return if product.nil?

        attach_primary_image(
          parent: album,
          image_url: product.dig("images", "primary", "large", "url")
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run the music tests**

Run: `bin/rails test test/lib/services/music/amazon_product_service_test.rb`

Expected: PASS, same run and assertion counts as before the refactor.

If `"call searches Amazon by artist and title within the Music index"` fails, check that `search_items` is still receiving `artist:`, `title:` and `search_index:` — `has_entries` tolerates the extra `resources:` key, so a failure there means the keys themselves changed.

- [ ] **Step 5: Run the whole safety net plus the job tests**

Run:

```bash
bin/rails test test/lib/services/music/ test/lib/services/games/ test/lib/services/amazon test/sidekiq/music/ test/sidekiq/games/
```

Expected: PASS. Games is still the old standalone class at this point and must be unaffected.

- [ ] **Step 6: Lint**

Run: `bundle exec standardrb app/lib/services/amazon/base_product_service.rb app/lib/services/music/amazon_product_service.rb`

Expected: no offenses. Run `bundle exec standardrb --fix <files>` if there are any.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/amazon/base_product_service.rb app/lib/services/music/amazon_product_service.rb
git commit -m "Extract Services::Amazon::BaseProductService and move music onto it"
```

---

### Task 2: Games refactor

**Files:**
- Modify: `web-app/app/lib/services/games/amazon_product_service.rb` (full rewrite, 169 → ~45 lines)
- Test: `web-app/test/lib/services/games/amazon_product_service_test.rb` (unchanged)

**Interfaces:**
- Consumes: `Services::Amazon::BaseProductService` and all of its hooks and helpers, as defined in Task 1.
- Produces: nothing new. `Services::Games::AmazonProductService.call(game:)` keeps its existing signature and result shape.

- [ ] **Step 1: Rewrite the games service as a subclass**

Replace the entire contents of `web-app/app/lib/services/games/amazon_product_service.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Games
    class AmazonProductService < ::Services::Amazon::BaseProductService
      def self.call(game:)
        new(game).call
      end

      private

      alias_method :game, :record

      def validation_errors
        return ["Game title required"] if game.title.blank?
        []
      end

      # Every category, not just video games: guides, soundtracks, art books and
      # collectibles are all legitimate matches for a game.
      def search_param_sets
        [{keywords: game.title, search_index: "All"}]
      end

      def match_task_class
        ::Services::Ai::Tasks::Games::AmazonGameMatchTask
      end

      # No after_persist override: games take cover art from IGDB, never Amazon.
      def persist_match(match, product)
        upsert_external_link(
          parent: game,
          product: product,
          metadata: {product_type: match[:product_type], platform: match[:platform]}
        )
      end
    end
  end
end
```

- [ ] **Step 2: Run the games tests**

Run: `bin/rails test test/lib/services/games/amazon_product_service_test.rb`

Expected: PASS. In particular `"call does not download images (IGDB only for cover art)"` asserts `Down.expects(:download).never`, which proves the inherited `after_persist` no-op is in effect.

- [ ] **Step 3: Run the full safety net**

Run:

```bash
ps aux | grep "[r]ails test"
bin/rails test test/lib/services/music/amazon_product_service_test.rb test/lib/services/games/amazon_product_service_test.rb test/sidekiq/music/amazon_product_enrichment_job_test.rb test/sidekiq/games/amazon_product_enrichment_job_test.rb test/lib/services/ai/tasks/amazon_product_match_task_test.rb test/lib/services/ai/tasks/amazon_album_match_task_test.rb test/lib/services/ai/tasks/games/amazon_game_match_task_test.rb test/lib/services/amazon
```

Expected: `72 runs, 196 assertions, 0 failures, 0 errors, 0 skips` — identical to Task 1 Step 1. Unchanged numbers are the proof the extraction preserved behaviour.

- [ ] **Step 4: Lint and commit**

```bash
bundle exec standardrb app/lib/services/games/amazon_product_service.rb
git add app/lib/services/games/amazon_product_service.rb
git commit -m "Move games Amazon service onto the shared base class"
```

---

### Task 3: Edition identifier backfill

The 148,296 legacy editions hold their ASIN only inside `metadata.amazon.ASIN`, in the dead PA-API PascalCase shape. Nothing can dedupe on an edition until those become real `Identifier` rows. This task must land before any enrichment runs, or every legacy edition gets a duplicate.

**Files:**
- Create: `web-app/app/lib/services/books/edition_identifier_backfill.rb`
- Create: `web-app/lib/tasks/books/amazon.rake`
- Modify: `web-app/test/fixtures/books/editions.yml`
- Test: `web-app/test/lib/services/books/edition_identifier_backfill_test.rb`

**Interfaces:**
- Consumes: `::Books::Edition` (`metadata` jsonb), `Identifier` (`identifiable_type`, `identifiable_id`, `identifier_type` enum, `value`).
- Produces: `Services::Books::EditionIdentifierBackfill.call(batch_size: 1_000)` → Integer count of identifier rows written.

- [ ] **Step 1: Add a fixture edition carrying legacy PascalCase metadata**

Append to `web-app/test/fixtures/books/editions.yml`:

```yaml
wp_legacy_amazon:
  book: war_and_peace
  title: "War and Peace (Legacy Amazon Import)"
  edition_type: 0
  book_binding: 1
  metadata:
    amazon:
      ASIN: "1400042062"
      DetailPageURL: "https://amazon.com/dp/1400042062"
      ItemInfo:
        ExternalIds:
          ISBNs:
            DisplayValues: ["1400042062"]
          EANs:
            DisplayValues: ["9781400042067"]
```

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lib/services/books/edition_identifier_backfill_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class EditionIdentifierBackfillTest < ActiveSupport::TestCase
      def setup
        @edition = books_editions(:wp_legacy_amazon)
      end

      test "writes the ASIN as an edition-level identifier" do
        EditionIdentifierBackfill.call

        assert_equal ["1400042062"],
          @edition.identifiers.where(identifier_type: :books_edition_asin).pluck(:value)
      end

      test "classifies a 10-character ISBN as isbn10" do
        EditionIdentifierBackfill.call

        assert_equal ["1400042062"],
          @edition.identifiers.where(identifier_type: :books_edition_isbn10).pluck(:value)
        assert_empty @edition.identifiers.where(identifier_type: :books_edition_isbn13)
      end

      test "writes the EAN as ean13" do
        EditionIdentifierBackfill.call

        assert_equal ["9781400042067"],
          @edition.identifiers.where(identifier_type: :books_edition_ean13).pluck(:value)
      end

      test "is idempotent across repeated runs" do
        EditionIdentifierBackfill.call
        count_after_first = @edition.identifiers.count

        EditionIdentifierBackfill.call

        assert_equal count_after_first, @edition.identifiers.count
      end

      test "ignores editions with no amazon metadata" do
        plain = books_editions(:wp_maude)

        EditionIdentifierBackfill.call

        assert_empty plain.identifiers.where(identifier_type: :books_edition_asin)
      end

      test "returns the number of rows written" do
        written = EditionIdentifierBackfill.call

        assert_operator written, :>=, 3
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books/edition_identifier_backfill_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::Books::EditionIdentifierBackfill`.

- [ ] **Step 4: Write the implementation**

Create `web-app/app/lib/services/books/edition_identifier_backfill.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # One-time lift of edition-level identifiers out of the legacy Amazon blob.
    #
    # Every books_editions row came from Amazon via the legacy application, which
    # stored the whole PA-API 5.0 response under metadata.amazon in PascalCase.
    # The books migration deliberately folded edition ISBNs and ASINs UP to the
    # work level, so there are no edition-level identifiers to dedupe on today.
    # Enrichment that ran before this backfill would duplicate every one of them.
    #
    # Idempotent: insert_all with unique_by the identifiers lookup index, so a
    # re-run inserts nothing.
    class EditionIdentifierBackfill
      LOOKUP_INDEX = :index_identifiers_on_lookup_unique

      def self.call(batch_size: 1_000)
        new(batch_size: batch_size).call
      end

      def initialize(batch_size: 1_000)
        @batch_size = batch_size
      end

      def call
        written = 0

        scope.find_in_batches(batch_size: @batch_size) do |editions|
          rows = editions.flat_map { |edition| rows_for(edition) }
          next if rows.empty?

          rows.uniq! { |row| [row[:identifiable_type], row[:identifier_type], row[:value], row[:identifiable_id]] }
          Identifier.insert_all(rows, unique_by: LOOKUP_INDEX)

          written += rows.size
          Rails.logger.info "EditionIdentifierBackfill: #{written} rows attempted"
        end

        written
      end

      private

      def scope
        ::Books::Edition.where("metadata -> 'amazon' IS NOT NULL")
      end

      def rows_for(edition)
        amazon = edition.metadata["amazon"]
        return [] unless amazon.is_a?(Hash)

        now = Time.current
        rows = []

        asin = amazon["ASIN"].presence
        rows << row(edition, :books_edition_asin, asin, now) if asin

        external_ids = amazon.dig("ItemInfo", "ExternalIds") || {}

        Array(external_ids.dig("ISBNs", "DisplayValues")).each do |raw|
          value = raw.to_s
          type = case value.length
          when 13 then :books_edition_isbn13
          when 10 then :books_edition_isbn10
          end
          rows << row(edition, type, value, now) if type
        end

        Array(external_ids.dig("EANs", "DisplayValues")).each do |raw|
          value = raw.to_s
          rows << row(edition, :books_edition_ean13, value, now) if value.length == 13
        end

        rows
      end

      def row(edition, identifier_type, value, now)
        {
          identifiable_type: "Books::Edition",
          identifiable_id: edition.id,
          identifier_type: Identifier.identifier_types[identifier_type],
          value: value,
          created_at: now,
          updated_at: now
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books/edition_identifier_backfill_test.rb`

Expected: PASS, 6 runs.

- [ ] **Step 6: Prove the tests are not vacuous**

Temporarily change `when 10 then :books_edition_isbn10` to `when 10 then nil` and re-run.

Expected: `"classifies a 10-character ISBN as isbn10"` FAILS. Restore the line and confirm the test passes again.

This matters because `assert_empty` on the isbn13 side would pass against code that writes nothing at all — the `assert_equal ["1400042062"]` half is what actually pins the behaviour.

- [ ] **Step 7: Add the rake task**

Create `web-app/lib/tasks/books/amazon.rake`:

```ruby
namespace :books do
  desc "Backfill edition-level ASIN/ISBN/EAN identifiers from legacy Amazon metadata (one-time)"
  task backfill_edition_asins: :environment do
    puts "Backfilling edition identifiers from legacy Amazon metadata..."
    written = Services::Books::EditionIdentifierBackfill.call
    puts "Done. #{written} identifier rows attempted (duplicates ignored)."
  end
end
```

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/edition_identifier_backfill.rb lib/tasks/books/amazon.rake test/lib/services/books/edition_identifier_backfill_test.rb
git add app/lib/services/books/edition_identifier_backfill.rb lib/tasks/books/amazon.rake test/lib/services/books/edition_identifier_backfill_test.rb test/fixtures/books/editions.yml
git commit -m "Backfill edition-level Amazon identifiers from legacy metadata"
```

- [ ] **Step 9: Snapshot the development database, then run the backfill for real**

```bash
bin/snapshot-dev-db.sh --label pre-amazon-backfill
bin/rails books:backfill_edition_asins
```

Expected: roughly 307,000 rows attempted (148,296 ASIN + 78,387 ISBN + 80,397 EAN).

Verify:

```bash
bin/rails runner 'puts Identifier.where(identifiable_type: "Books::Edition").group(:identifier_type).count.inspect'
```

Expected: `books_edition_asin` near 148,296, `books_edition_ean13` near 80,397, the two ISBN types summing to about 78,387, plus the pre-existing 18 `books_edition_openlibrary_id`.

---

### Task 4: Books AI match task

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/amazon_book_match_task.rb`
- Test: `web-app/test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb`

**Interfaces:**
- Consumes: `Services::Ai::Tasks::AmazonProductMatchTask` (existing base; supplies `#call`, `#system_message`, `#user_prompt`, `#format_search_results`, `#process_and_persist`, and requires `#domain_name`, `#item_description`, `#match_criteria`, `#non_match_criteria`, and a `ResponseSchema` constant).
- Produces: `Services::Ai::Tasks::Books::AmazonBookMatchTask.new(parent:, search_results:)` whose `#call` returns a `Services::Ai::Result` with `data[:matching_results]` — an Array of Hashes with symbol keys `:asin`, `:title`, `:author`, `:explanation`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class AmazonBookMatchTaskTest < ActiveSupport::TestCase
          def setup
            @book = books_books(:war_and_peace)
            @search_results = [
              {
                "asin" => "1400079985",
                "itemInfo" => {
                  "title" => {"displayValue" => "War and Peace (Vintage Classics)"},
                  "byLineInfo" => {
                    "contributors" => [{"role" => "Author", "name" => "Leo Tolstoy"}],
                    "manufacturer" => {"displayValue" => "Vintage"}
                  },
                  "classifications" => {"binding" => {"displayValue" => "Paperback"}},
                  "contentInfo" => {"publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"}}
                }
              },
              {
                "asin" => "0553213504",
                "itemInfo" => {
                  "title" => {"displayValue" => "CliffsNotes on Tolstoy's War and Peace"},
                  "classifications" => {"binding" => {"displayValue" => "Paperback"}}
                }
              }
            ]
            @task = AmazonBookMatchTask.new(parent: @book, search_results: @search_results)
          end

          test "domain_name returns book" do
            assert_equal "book", @task.send(:domain_name)
          end

          test "item_description includes the title and the author names" do
            description = @task.send(:item_description)

            assert_includes description, "War and Peace"
            assert_includes description, "Leo Tolstoy"
          end

          test "item_description includes the first published year when present" do
            description = @task.send(:item_description)

            assert_includes description, "1869"
          end

          test "item_description includes alternate titles when present" do
            description = @task.send(:item_description)

            assert_includes description, "Voyna i mir"
          end

          test "non_match_criteria rules out study guides" do
            criteria = @task.send(:non_match_criteria)

            assert_includes criteria, "CliffsNotes"
          end

          test "match_criteria allows different bindings of the same work" do
            criteria = @task.send(:match_criteria)

            assert_includes criteria, "Hardcover"
          end

          test "format_search_result exposes author, publisher and publication date" do
            formatted = @task.send(:format_search_result, @search_results.first)

            assert_includes formatted, "1400079985"
            assert_includes formatted, "Leo Tolstoy"
            assert_includes formatted, "Vintage"
            assert_includes formatted, "2008-10-14"
          end

          test "response schema requires asin title author and explanation" do
            properties = AmazonBookMatchTask::MatchResult.to_json_schema
              .dig(:properties)
              &.keys
              &.map(&:to_s)

            assert_equal %w[asin author explanation title], properties.sort
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::Ai::Tasks::Books::AmazonBookMatchTask`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/ai/tasks/books/amazon_book_match_task.rb`. The criteria are ported verbatim from the legacy application's `Openai::Chats::AmazonMatchConfirmation`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        class AmazonBookMatchTask < ::Services::Ai::Tasks::AmazonProductMatchTask
          private

          def domain_name
            "book"
          end

          def item_description
            lines = ["- Title: #{parent.title}"]
            lines << "- Subtitle: #{parent.subtitle}" if parent.subtitle.present?
            lines << "- Authors: #{parent.authors.map(&:name).join(", ")}"
            if parent.alternate_titles.present?
              lines << "- Alternate Titles: #{parent.alternate_titles.join(", ")}"
            end
            if parent.first_published_year.present?
              lines << "- First Published: #{parent.first_published_year}"
            end
            lines.join("\n")
          end

          def match_criteria
            <<~CRITERIA.strip
              - The titles represent the same literary work (allowing for variations in subtitles or editions)
              - The authors match (allowing for variations in name format)
              - The result is the actual book, not a study guide, companion, or analysis of the book

              Examples of what IS a match:
              - Different editions of the same book
              - Slight variations in title formatting
              - Presence or absence of edition information in title (e.g. "Original 1925 Edition", "Annotated Edition")
              - Different ISBN/EAN numbers for the same book
              - Hardcover vs Paperback editions
              - Kindle vs physical vs audiobook editions
              - Publisher variations
            CRITERIA
          end

          def non_match_criteria
            <<~CRITERIA.strip
              - Study guides or companion books
              - Books about the original book
              - Different books by the same author
              - Different volumes or parts of a series
              - SparkNotes or CliffsNotes editions
              - Abridged versions (unless the original is also abridged)
            CRITERIA
          end

          # Books care about the author, the publisher and the publication date --
          # the three fields that tell one printing from another.
          def format_search_result(result)
            item_info = result["itemInfo"] || {}
            contributors = item_info.dig("byLineInfo", "contributors") || []
            author = contributors.find { |c| c["role"] == "Author" }&.dig("name")

            <<~RESULT
              - ASIN: #{result["asin"]}
                Title: #{item_info.dig("title", "displayValue")}
                Author: #{author}
                Format: #{item_info.dig("classifications", "binding", "displayValue")}
                Publisher: #{item_info.dig("byLineInfo", "manufacturer", "displayValue")}
                Publication Date: #{item_info.dig("contentInfo", "publicationDate", "displayValue")}
            RESULT
          end

          class MatchResult < OpenAI::BaseModel
            required :asin, String, doc: "Amazon ASIN of the matching product"
            required :title, String, doc: "Product title from Amazon"
            required :author, String, doc: "Author name from Amazon"
            required :explanation, String, doc: "Brief explanation of why this is a match"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[MatchResult]
          end
        end
      end
    end
  end
end
```

Note `to_json_schema` is a **class** method on `OpenAI::BaseModel` subclasses — `MatchResult.new.to_json_schema` raises `NoMethodError`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb`

Expected: PASS, 8 runs.

If the schema test fails on the shape of `to_json_schema`, inspect the real return value with `bin/rails runner 'pp Services::Ai::Tasks::Books::AmazonBookMatchTask::MatchResult.to_json_schema'` and adjust the assertion to match the actual structure — keep asserting the four property names, not the wrapper shape.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/ai/tasks/books/amazon_book_match_task.rb test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb
git add app/lib/services/ai/tasks/books/amazon_book_match_task.rb test/lib/services/ai/tasks/books/amazon_book_match_task_test.rb
git commit -m "Add books Amazon match AI task"
```

---

### Task 5: Edition upserter

**Files:**
- Create: `web-app/app/lib/services/books/amazon_edition_upserter.rb`
- Test: `web-app/test/lib/services/books/amazon_edition_upserter_test.rb`

**Interfaces:**
- Consumes: `::Books::Book#editions`, `::Books::Edition` (columns `title`, `subtitle`, `book_binding`, `publication_year`, `publisher_name`, `page_count`, `popularity`, `language_id`, `metadata`), `Identifier`, `Language`.
- Produces: `Services::Books::AmazonEditionUpserter.call(book:, product:)` → `Services::Books::AmazonEditionUpserter::Result` (a `Struct` with members `edition` and `created`, `keyword_init: true`).

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books/amazon_edition_upserter_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonEditionUpserterTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
      end

      def product(overrides = {})
        {
          "asin" => "1400079985",
          "detailPageURL" => "https://amazon.com/dp/1400079985",
          "itemInfo" => {
            "title" => {"displayValue" => "War and Peace: A Novel (Vintage Classics)"},
            "byLineInfo" => {"manufacturer" => {"displayValue" => "Vintage"}},
            "classifications" => {"binding" => {"displayValue" => "Paperback"}},
            "contentInfo" => {
              "pagesCount" => {"displayValue" => 1296},
              "publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"},
              "languages" => {"displayValues" => [
                {"displayValue" => "English", "type" => "Published"},
                {"displayValue" => "Russian", "type" => "Original Language"}
              ]}
            },
            "externalIds" => {
              "isbns" => {"displayValues" => ["1400079985"]},
              "eans" => {"displayValues" => ["9781400079988"]}
            }
          },
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 4211}}
        }.deep_merge(overrides)
      end

      test "creates a new edition for an unseen ASIN" do
        assert_difference "::Books::Edition.count", 1 do
          result = AmazonEditionUpserter.call(book: @book, product: product)

          assert result.created
          assert_equal @book, result.edition.book
        end
      end

      test "maps the descriptive fields off the product" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_equal "War and Peace", edition.title
        assert_equal "A Novel", edition.subtitle
        assert_equal "paperback", edition.book_binding
        assert_equal "Vintage", edition.publisher_name
        assert_equal 2008, edition.publication_year
        assert_equal 1296, edition.page_count
        assert_equal 4211, edition.popularity
        assert_equal languages(:english), edition.language
      end

      test "writes edition level asin isbn and ean identifiers" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_equal ["1400079985"], edition.identifiers.where(identifier_type: :books_edition_asin).pluck(:value)
        assert_equal ["1400079985"], edition.identifiers.where(identifier_type: :books_edition_isbn10).pluck(:value)
        assert_equal ["9781400079988"], edition.identifiers.where(identifier_type: :books_edition_ean13).pluck(:value)
      end

      test "finds the existing edition again by ASIN instead of duplicating it" do
        first = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_no_difference "::Books::Edition.count" do
          second = AmazonEditionUpserter.call(book: @book, product: product)

          refute second.created
          assert_equal first.id, second.edition.id
        end
      end

      # The fixture ISBN is 10 characters, so this resolves through the EAN-13
      # fallback -- ISBN-10 is deliberately not a lookup key.
      test "finds the existing edition by EAN when the ASIN changed" do
        first = AmazonEditionUpserter.call(book: @book, product: product).edition
        reissued = product("asin" => "9999999999")

        assert_no_difference "::Books::Edition.count" do
          assert_equal first.id, AmazonEditionUpserter.call(book: @book, product: reissued).edition.id
        end
      end

      test "does not match an edition belonging to a different book" do
        other_book = books_books(:crime_and_punishment)
        AmazonEditionUpserter.call(book: @book, product: product)

        assert_difference "::Books::Edition.count", 1 do
          AmazonEditionUpserter.call(book: other_book, product: product)
        end
      end

      test "always refreshes popularity and metadata on an existing edition" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        AmazonEditionUpserter.call(
          book: @book,
          product: product("browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 12}})
        )

        edition.reload
        assert_equal 12, edition.popularity
        assert_equal "1400079985", edition.metadata.dig("amazon", "asin")
      end

      test "never overwrites a populated descriptive field" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition
        edition.update!(title: "Hand Corrected Title", publisher_name: "Corrected Publisher")

        AmazonEditionUpserter.call(book: @book, product: product)

        edition.reload
        assert_equal "Hand Corrected Title", edition.title
        assert_equal "Corrected Publisher", edition.publisher_name
      end

      test "fills a descriptive field that is blank on an existing edition" do
        edition = @book.editions.create!(edition_type: :standard, title: "Existing")
        edition.identifiers.create!(identifier_type: :books_edition_asin, value: "1400079985")

        AmazonEditionUpserter.call(book: @book, product: product)

        edition.reload
        assert_equal "Existing", edition.title
        assert_equal 1296, edition.page_count
        assert_equal "Vintage", edition.publisher_name
      end

      test "maps an unrecognised binding to other rather than raising" do
        edition = AmazonEditionUpserter.call(
          book: @book,
          product: product("itemInfo" => {"classifications" => {"binding" => {"displayValue" => "Papyrus Scroll"}}})
        ).edition

        assert_equal "other", edition.book_binding
      end

      test "leaves language nil when Amazon names one we do not have" do
        edition = AmazonEditionUpserter.call(
          book: @book,
          product: product("itemInfo" => {"contentInfo" => {"languages" => {"displayValues" => [
            {"displayValue" => "Esperanto", "type" => "Published"}
          ]}}})
        ).edition

        assert_nil edition.language_id
      end

      test "does not create a Language row from Amazon data" do
        assert_no_difference "Language.count" do
          AmazonEditionUpserter.call(
            book: @book,
            product: product("itemInfo" => {"contentInfo" => {"languages" => {"displayValues" => [
              {"displayValue" => "Esperanto", "type" => "Published"}
            ]}}})
          )
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books/amazon_edition_upserter_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::Books::AmazonEditionUpserter`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/books/amazon_edition_upserter.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Turns one validated Amazon product into a Books::Edition of the given book.
    #
    # Identity is the edition-level ASIN identifier, falling back to ISBN-13 and
    # then EAN-13, ALWAYS scoped to the book: the legacy data has 2,149 ASINs
    # attached to more than one book, so a global lookup would hang editions off
    # the wrong work. The ISBN fallback is what keeps an Amazon reissue under a
    # fresh ASIN from creating a second edition of the same printing.
    #
    # Write rules: sales rank and the raw metadata always refresh, because they
    # are inherently live. Everything descriptive is written only when blank --
    # admins can hand-edit every one of those columns, and a blind refresh would
    # silently revert their corrections across 148,296 rows.
    class AmazonEditionUpserter
      Result = Struct.new(:edition, :created, keyword_init: true)

      # Amazon binding display value (downcased) -> Books::Edition#book_binding
      BINDINGS = {
        "hardcover" => :hardcover,
        "paperback" => :paperback,
        "mass market paperback" => :mass_market,
        "kindle edition" => :ebook,
        "ebook" => :ebook,
        "audible audiobook" => :audiobook,
        "audio cd" => :audiobook,
        "mp3 cd" => :audiobook,
        "library binding" => :library_binding,
        "leather bound" => :leather_bound,
        "imitation leather" => :leather_bound
      }.freeze

      def self.call(book:, product:)
        new(book: book, product: product).call
      end

      def initialize(book:, product:)
        @book = book
        @product = product
      end

      def call
        edition = find_edition || book.editions.build(edition_type: :standard)
        created = edition.new_record?

        apply_volatile(edition)
        apply_descriptive(edition)
        edition.save!

        write_identifiers(edition)

        Result.new(edition: edition, created: created)
      end

      private

      attr_reader :book, :product

      # ---- identity ------------------------------------------------------

      def find_edition
        edition_by(:books_edition_asin, [asin]) ||
          edition_by(:books_edition_isbn13, isbns.select { |v| v.length == 13 }) ||
          edition_by(:books_edition_ean13, eans)
      end

      # order(:id) so the 2,747 legacy in-book duplicate groups resolve the same
      # way on every run instead of picking an arbitrary row.
      def edition_by(identifier_type, values)
        values = Array(values).compact_blank
        return nil if values.empty?

        edition_ids = Identifier.where(
          identifiable_type: "Books::Edition",
          identifier_type: identifier_type,
          value: values
        ).pluck(:identifiable_id)
        return nil if edition_ids.empty?

        book.editions.where(id: edition_ids).order(:id).first
      end

      # ---- writes --------------------------------------------------------

      def apply_volatile(edition)
        edition.popularity = product.dig("browseNodeInfo", "websiteSalesRank", "salesRank")
        edition.metadata = (edition.metadata || {}).merge("amazon" => product)
      end

      def apply_descriptive(edition)
        title, subtitle = split_title(product.dig("itemInfo", "title", "displayValue"))

        edition.title = title if edition.title.blank? && title.present?
        edition.subtitle = subtitle if edition.subtitle.blank? && subtitle.present?
        edition.book_binding = book_binding if edition.book_binding.blank? && book_binding.present?
        edition.publisher_name = publisher_name if edition.publisher_name.blank? && publisher_name.present?
        edition.publication_year = publication_year if edition.publication_year.blank? && publication_year.present?
        edition.page_count = page_count if edition.page_count.blank? && page_count.present?
        edition.language = language if edition.language_id.blank? && language.present?
      end

      def write_identifiers(edition)
        upsert_identifier(edition, :books_edition_asin, asin)

        isbns.each do |isbn|
          upsert_identifier(edition, (isbn.length == 13) ? :books_edition_isbn13 : :books_edition_isbn10, isbn)
        end

        eans.each { |ean| upsert_identifier(edition, :books_edition_ean13, ean) }
      end

      def upsert_identifier(edition, identifier_type, value)
        return if value.blank?

        edition.identifiers
          .find_or_initialize_by(identifier_type: identifier_type, value: value)
          .save!
      end

      # ---- product reads --------------------------------------------------

      def asin
        product["asin"].presence
      end

      def isbns
        Array(product.dig("itemInfo", "externalIds", "isbns", "displayValues"))
          .map(&:to_s)
          .select { |value| [10, 13].include?(value.length) }
      end

      def eans
        Array(product.dig("itemInfo", "externalIds", "eans", "displayValues"))
          .map(&:to_s)
          .select { |value| value.length == 13 }
      end

      def publisher_name
        product.dig("itemInfo", "byLineInfo", "manufacturer", "displayValue").presence
      end

      def page_count
        product.dig("itemInfo", "contentInfo", "pagesCount", "displayValue")
      end

      def publication_year
        product.dig("itemInfo", "contentInfo", "publicationDate", "displayValue").to_s[/\d{4}/]&.to_i
      end

      # An unmapped binding must never raise -- one odd string would otherwise
      # abort a multi-day sweep.
      def book_binding
        return @book_binding if defined?(@book_binding)

        raw = product.dig("itemInfo", "classifications", "binding", "displayValue")
        @book_binding = if raw.blank?
          nil
        else
          BINDINGS.fetch(raw.to_s.strip.downcase) do
            Rails.logger.info "Unmapped Amazon binding #{raw.inspect}; storing as :other"
            :other
          end
        end
      end

      # Amazon returns several language entries per product; only the "Published"
      # one describes this printing. Never creates a Language row.
      def language
        return @language if defined?(@language)

        entries = Array(product.dig("itemInfo", "contentInfo", "languages", "displayValues"))
        name = entries.find { |entry| entry["type"] == "Published" }&.dig("displayValue")
        @language = name.blank? ? nil : Language.find_by(name: name)
      end

      # Legacy's process_title: drop parenthesised and bracketed noise, then split
      # the first colon into title and subtitle.
      def split_title(raw)
        return [nil, nil] if raw.blank?

        cleaned = raw.gsub(/\s*[(\[][^)\]]*[)\]]\s*/, " ").squeeze(" ").strip
        head, tail = cleaned.split(":", 2)
        [head&.strip.presence, tail&.strip.presence]
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books/amazon_edition_upserter_test.rb`

Expected: PASS, 13 runs.

- [ ] **Step 5: Prove the fill-if-blank tests are not vacuous**

Temporarily delete the whole `apply_descriptive` body (leave the method empty) and re-run.

Expected: `"maps the descriptive fields off the product"` and `"fills a descriptive field that is blank on an existing edition"` FAIL, while `"never overwrites a populated descriptive field"` still PASSES.

That last one passing against deleted code is exactly the trap — it is only meaningful alongside the two that fail. Restore the method body and confirm all 13 pass.

- [ ] **Step 6: Prove the book scoping is load-bearing**

Temporarily change `book.editions.where(id: edition_ids)` to `::Books::Edition.where(id: edition_ids)` and re-run.

Expected: `"does not match an edition belonging to a different book"` FAILS. Restore it.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/amazon_edition_upserter.rb test/lib/services/books/amazon_edition_upserter_test.rb
git add app/lib/services/books/amazon_edition_upserter.rb test/lib/services/books/amazon_edition_upserter_test.rb
git commit -m "Add Books::AmazonEditionUpserter"
```

---

### Task 6: Books product service

**Files:**
- Create: `web-app/app/lib/services/books/amazon_product_service.rb`
- Test: `web-app/test/lib/services/books/amazon_product_service_test.rb`

**Interfaces:**
- Consumes: `Services::Amazon::BaseProductService` (Task 1), `Services::Ai::Tasks::Books::AmazonBookMatchTask` (Task 4), `Services::Books::AmazonEditionUpserter.call(book:, product:) → Result(edition:, created:)` (Task 5).
- Produces: `Services::Books::AmazonProductService.call(book:)` → `{success:, data:}` / `{success:, error:, errors:}`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/books/amazon_product_service_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonProductServiceTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
      end

      test "fails when the book title is blank" do
        @book.title = ""

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "Book title required", result[:error]
      end

      test "fails when the book has no authors" do
        @book.stubs(:authors).returns([])

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "Book must have at least one author", result[:error]
      end

      test "fails loudly when the Amazon API errors" do
        ::Services::Amazon::Client.stubs(:search_items)
          .raises(::Services::Amazon::Client::Error, "Amazon API credentials not configured (AMAZON_PRODUCT_API_CRED_ID is missing)")

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_match(/Amazon API search failed/, result[:error])
      end

      test "the second search pass targets the Audible browse node" do
        captured = []
        ::Services::Amazon::Client.stubs(:search_items).with { |**kwargs| captured << kwargs; true }.returns([])

        AmazonProductService.call(book: @book)

        assert_equal 2, captured.size
        assert_nil captured.first[:browse_node_id]
        assert_equal "18145289011", captured.last[:browse_node_id]
      end

      test "keywords combine the title and the author names" do
        captured = []
        ::Services::Amazon::Client.stubs(:search_items).with { |**kwargs| captured << kwargs; true }.returns([])

        AmazonProductService.call(book: @book)

        assert_includes captured.first[:keywords], "War and Peace"
        assert_includes captured.first[:keywords], "Leo Tolstoy"
      end

      test "de-duplicates the same ASIN across both search passes" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        assert_difference "::Books::Edition.count", 1 do
          AmazonProductService.call(book: @book)
        end
      end

      test "creates an edition and hangs the buy link off it" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        result = AmazonProductService.call(book: @book)

        assert result[:success]
        edition = ::Books::Edition.joins(:identifiers)
          .where(identifiers: {identifier_type: Identifier.identifier_types[:books_edition_asin], value: "1400079985"})
          .first
        assert edition

        link = edition.external_links.find_by(source: :amazon)
        assert link
        assert_equal "https://amazon.com/dp/1400079985", link.url
        assert_equal "product_link", link.link_category
      end

      test "gives the book a cover when it has none" do
        @book.images.destroy_all
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert @book.reload.images.where(primary: true).exists?
      end

      test "leaves an existing book cover alone" do
        @book.images.create!(primary: true) do |image|
          image.file.attach(io: StringIO.new("existing"), filename: "existing.jpg", content_type: "image/jpeg")
        end
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_equal 1, @book.reload.images.where(primary: true).count
      end

      test "creates the book level affiliate link from the physical edition" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_equal "https://amazon.com/dp/1400079985",
          @book.external_links.find_by(source: :amazon)&.url
      end

      test "does not build a book level link from an audiobook only match" do
        audiobook = amazon_product.deep_merge(
          "itemInfo" => {"classifications" => {"binding" => {"displayValue" => "Audible Audiobook"}}}
        )
        ::Services::Amazon::Client.stubs(:search_items).returns([audiobook])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_nil @book.external_links.find_by(source: :amazon)
      end

      test "surfaces AI failures" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        ai_result = stub(success?: false, error: "AI processing failed", data: nil)
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.any_instance.stubs(:call).returns(ai_result)

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "AI validation failed: AI processing failed", result[:error]
      end

      private

      def amazon_product
        {
          "asin" => "1400079985",
          "detailPageURL" => "https://amazon.com/dp/1400079985",
          "itemInfo" => {
            "title" => {"displayValue" => "War and Peace (Vintage Classics)"},
            "byLineInfo" => {"manufacturer" => {"displayValue" => "Vintage"}},
            "classifications" => {"binding" => {"displayValue" => "Paperback"}},
            "contentInfo" => {
              "pagesCount" => {"displayValue" => 1296},
              "publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"}
            }
          },
          "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/wp.jpg"}}},
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 4211}},
          "offersV2" => {"listings" => [
            {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 14.99}}}
          ]}
        }
      end

      def stub_ai_match
        ai_result = stub(
          success?: true,
          data: {matching_results: [
            {asin: "1400079985", title: "War and Peace", author: "Leo Tolstoy", explanation: "Same work"}
          ]}
        )
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.any_instance.stubs(:call).returns(ai_result)
      end

      def stub_image
        stub_request(:get, "https://images.amazon.com/wp.jpg")
          .to_return(status: 200, body: "fake image data", headers: {"Content-Type" => "image/jpeg"})
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books/amazon_product_service_test.rb`

Expected: FAIL with `NameError: uninitialized constant Services::Books::AmazonProductService`.

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/books/amazon_product_service.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Amazon enrichment for books.
    #
    # Unlike music and games, where a validated match is just an ExternalLink, a
    # books match is a Books::Edition: an Amazon book product IS a specific
    # printing, with its own ISBN, binding, publisher and page count. The buy
    # link and the cover hang off that edition.
    class AmazonProductService < ::Services::Amazon::BaseProductService
      # Audible. The plain Books search never surfaces audiobooks, so legacy ran
      # a second pass against this node and so do we.
      AUDIBLE_BROWSE_NODE = "18145289011"

      AMAZON_RESOURCES = (
        ::Services::Amazon::BaseProductService::AMAZON_RESOURCES + ["itemInfo.externalIds"]
      ).freeze

      # The bindings a "buy the book" link should point at. Legacy's
      # set_primary_amazon_url used exactly this list, deliberately excluding
      # ebook and audiobook.
      PHYSICAL_BINDINGS = %w[hardcover paperback mass_market].freeze

      def self.call(book:)
        new(book).call
      end

      def initialize(book)
        super
        @persisted = []
      end

      private

      alias_method :book, :record

      def validation_errors
        return ["Book title required"] if book.title.blank?
        return ["Book must have at least one author"] if book.authors.empty?
        []
      end

      def search_param_sets
        keywords = [book.title, book.authors.map(&:name).join(" ")].join(" ").squeeze(" ").strip

        [
          {keywords: keywords, search_index: "Books"},
          {keywords: keywords, search_index: "Books", browse_node_id: AUDIBLE_BROWSE_NODE}
        ]
      end

      def match_task_class
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask
      end

      def persist_match(match, product)
        edition = ::Services::Books::AmazonEditionUpserter.call(book: book, product: product).edition
        @persisted << {edition: edition, product: product}

        link = upsert_external_link(parent: edition, product: product)
        attach_primary_image(
          parent: edition,
          image_url: product.dig("images", "primary", "large", "url")
        )
        link
      end

      # The book-level cover and affiliate link both come from the best-selling
      # PHYSICAL edition -- an audiobook is a poor default cover and a poor
      # default thing to sell someone who asked for the book.
      def after_persist(_validated_results, _search_results)
        best = best_physical
        return if best.nil?

        attach_primary_image(
          parent: book,
          image_url: best[:product].dig("images", "primary", "large", "url")
        )

        return if book.external_links.exists?(source: :amazon)
        upsert_external_link(parent: book, product: best[:product])
      end

      def best_physical
        @persisted
          .select { |entry| PHYSICAL_BINDINGS.include?(entry[:edition].book_binding) }
          .min_by { |entry| entry[:edition].popularity || Float::INFINITY }
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books/amazon_product_service_test.rb`

Expected: PASS, 12 runs.

- [ ] **Step 5: Prove the physical-binding filter is load-bearing**

Temporarily change `PHYSICAL_BINDINGS` to also include `"audiobook"` and re-run.

Expected: `"does not build a book level link from an audiobook only match"` FAILS. Restore the constant.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/amazon_product_service.rb test/lib/services/books/amazon_product_service_test.rb
git add app/lib/services/books/amazon_product_service.rb test/lib/services/books/amazon_product_service_test.rb
git commit -m "Add books Amazon product service"
```

---

### Task 7: Enrichment job, tracking column and sweep tasks

**Files:**
- Create: `web-app/db/migrate/<timestamp>_add_amazon_enriched_at_to_books_books.rb` (generated)
- Modify: `web-app/db/schema.rb` (generated)
- Modify: `web-app/app/models/books/book.rb` (annotation only, regenerated)
- Create: `web-app/app/sidekiq/books/amazon_product_enrichment_job.rb` (generated)
- Create: `web-app/test/sidekiq/books/amazon_product_enrichment_job_test.rb` (generated, then filled in)
- Modify: `web-app/lib/tasks/books/amazon.rake`

**Interfaces:**
- Consumes: `Services::Books::AmazonProductService.call(book:)` (Task 6).
- Produces: `Books::AmazonProductEnrichmentJob.perform_async(book_id)`; `books_books.amazon_enriched_at`; rake tasks `books:amazon_enrich[book_id]` and `books:amazon_enrich_ranked`.

- [ ] **Step 1: Generate and run the migration**

```bash
bin/rails generate migration AddAmazonEnrichedAtToBooksBooks amazon_enriched_at:datetime
```

Confirm the generated file contains exactly:

```ruby
class AddAmazonEnrichedAtToBooksBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :amazon_enriched_at, :datetime
  end
end
```

A nullable column with no default does not rewrite the table. This matters: `docker-entrypoint` is `bash -e` and migrates *before* exec'ing the server, so a slow or raising migration takes all four sites down.

```bash
bin/rails db:migrate
git diff db/schema.rb
```

Inspect that diff carefully. A worktree shares the development database with every other worktree, so `db:migrate` can pull another agent's migrations into your `schema.rb`. Keep only the `amazon_enriched_at` line and the `version:` bump.

- [ ] **Step 2: Generate the job**

```bash
bin/rails generate sidekiq:job books/amazon_product_enrichment
```

This creates both `app/sidekiq/books/amazon_product_enrichment_job.rb` and `test/sidekiq/books/amazon_product_enrichment_job_test.rb`.

- [ ] **Step 3: Write the failing job test**

Replace the generated `web-app/test/sidekiq/books/amazon_product_enrichment_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::AmazonProductEnrichmentJobTest < ActiveSupport::TestCase
  def setup
    @book = books_books(:war_and_peace)
  end

  test "perform calls the books Amazon service with the book" do
    ::Services::Books::AmazonProductService.expects(:call).with(book: @book).returns(
      {success: true, data: "Enrichment completed"}
    )

    Books::AmazonProductEnrichmentJob.new.perform(@book.id)
  end

  test "perform stamps amazon_enriched_at on success" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: true, data: "ok"})

    Books::AmazonProductEnrichmentJob.new.perform(@book.id)

    assert_not_nil @book.reload.amazon_enriched_at
  end

  test "perform raises so Sidekiq retries when the service fails" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, error: "API error"})

    error = assert_raises(StandardError) do
      Books::AmazonProductEnrichmentJob.new.perform(@book.id)
    end

    assert_match(/API error/, error.message)
  end

  test "perform stamps amazon_enriched_at even when the service fails" do
    ::Services::Books::AmazonProductService.stubs(:call).returns({success: false, error: "API error"})

    assert_raises(StandardError) do
      Books::AmazonProductEnrichmentJob.new.perform(@book.id)
    end

    assert_not_nil @book.reload.amazon_enriched_at
  end

  test "job is configured for the serial queue" do
    assert_equal :serial, Books::AmazonProductEnrichmentJob.get_sidekiq_options["queue"]
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/sidekiq/books/amazon_product_enrichment_job_test.rb`

Expected: FAIL — the generated job's `perform` does nothing.

- [ ] **Step 5: Write the job**

Replace `web-app/app/sidekiq/books/amazon_product_enrichment_job.rb`:

```ruby
# frozen_string_literal: true

class Books::AmazonProductEnrichmentJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(book_id)
    book = ::Books::Book.find(book_id)

    Rails.logger.info "Starting Amazon product enrichment for book: #{book.title}"

    result = ::Services::Books::AmazonProductService.call(book: book)

    # Stamped before the raise on purpose. Sidekiq owns retries; this column owns
    # sweep coverage. Stamping only on success would make a permanently
    # unmatchable book re-enqueue on every sweep, forever.
    book.update_column(:amazon_enriched_at, Time.current)

    if result[:success]
      Rails.logger.info "Amazon enrichment completed for #{book.title}: #{result[:data]}"
    else
      error_message = result[:error] || result[:errors]&.join(", ") || "Unknown error"
      Rails.logger.error "Failed to enrich book #{book.title}: #{error_message}"
      raise StandardError, "Amazon enrichment failed: #{error_message}"
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/sidekiq/books/amazon_product_enrichment_job_test.rb`

Expected: PASS, 5 runs.

- [ ] **Step 7: Add the sweep rake tasks**

Add these two tasks inside the existing `namespace :books do` block in `web-app/lib/tasks/books/amazon.rake`, alongside `backfill_edition_asins`:

```ruby
  desc "Enrich one book from Amazon: bin/rails books:amazon_enrich[123]"
  task :amazon_enrich, [:book_id] => :environment do |_task, args|
    book = ::Books::Book.find(args[:book_id])
    puts "Enriching #{book.title} (##{book.id})..."
    Books::AmazonProductEnrichmentJob.new.perform(book.id)
    puts "Done."
  end

  desc "Enqueue Amazon enrichment for every ranked book, best-ranked first"
  task amazon_enrich_ranked: :environment do
    configuration = ::Books::RankingConfiguration.default_primary
    abort "No default primary books ranking configuration" if configuration.nil?

    scope = ::Books::Book
      .joins(:ranked_items)
      .where(ranked_items: {ranking_configuration_id: configuration.id})
      .where("books_books.amazon_enriched_at IS NULL OR books_books.amazon_enriched_at < ?", 7.days.ago)
      .order("ranked_items.rank ASC")

    total = scope.count
    puts "Enqueuing #{total} ranked books onto the :serial queue."
    puts "At one job at a time this takes days, and it shares that queue with the"
    puts "cover-art and recording-id jobs. Ctrl-C now if that is not what you want."

    enqueued = 0
    scope.find_each(order: :desc) do |book|
      Books::AmazonProductEnrichmentJob.perform_async(book.id)
      enqueued += 1
      puts "... #{enqueued}/#{total}" if (enqueued % 500).zero?
    end

    puts "Enqueued #{enqueued} books."
  end
```

Note: `find_each` ignores the `order` clause and batches by primary key, which is why rank ordering cannot be preserved through it — the `order` above governs `scope.count` and any manual inspection only. If strict rank ordering matters for the first run, replace `find_each` with `scope.limit(N).pluck(:id).each`, run it in chunks, and say so in the run log.

- [ ] **Step 8: Run the full test suite**

```bash
ps aux | grep "[r]ails test"
bin/rails test
```

Expected: PASS with no new warnings. A clean run emits no warnings beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`). A new warning line is a regression — fix the cause rather than filtering it.

- [ ] **Step 9: Lint everything**

Run: `bundle exec standardrb`

Expected: no offenses.

- [ ] **Step 10: Smoke test one real book end to end**

```bash
bin/rails runner 'b = Books::Book.joins(:book_authors).where.not(first_published_year: nil).first; puts "#{b.id} #{b.title}"'
bin/rails books:amazon_enrich[<that id>]
```

Then inspect what it produced:

```bash
bin/rails runner 'b = Books::Book.find(<that id>); puts "editions: #{b.editions.count}"; puts "book links: #{b.external_links.where(source: :amazon).count}"; puts "book cover: #{b.images.where(primary: true).exists?}"; b.editions.each { |e| puts "  #{e.title.inspect} #{e.book_binding} pages=#{e.page_count} rank=#{e.popularity} links=#{e.external_links.count} asin=#{e.identifiers.where(identifier_type: :books_edition_asin).pluck(:value).inspect}" }'
```

This is a live Amazon call and a live OpenAI call. Confirm editions were created with page counts and ASIN identifiers, that each has a buy link, and that the book-level link points at a physical edition.

- [ ] **Step 11: Commit**

```bash
git add db/migrate db/schema.rb app/models/books/book.rb app/sidekiq/books/amazon_product_enrichment_job.rb test/sidekiq/books/amazon_product_enrichment_job_test.rb lib/tasks/books/amazon.rake
git commit -m "Add books Amazon enrichment job, tracking column and sweep tasks"
```

---

## Deferred (explicitly out of scope)

- `DataImporters::Books` and its Amazon provider — deliberately waiting until there are other books data sources worth importing from.
- An admin "enrich from Amazon" button.
- Removing or parallelising the `serial` queue.
- Merging the 2,747 duplicate-ASIN edition groups.
- Making `Games::AmazonProductEnrichmentJob` raise the way music's and books' do.
- Any change to the `{success:, data:, error:, errors:}` result Hash.
