# External Links Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the legacy `links` table (13,404 rows) into the polymorphic `ExternalLink` model, parented to `Books::Book` (preserved ids) with `submitted_by` resolving to the migrated users, inferring `source` from the URL host.

**Architecture:** A per-row ActiveRecord `Migrator` subclass (`ExternalLinkMigrator`) reads each legacy `links` row and upserts an `ExternalLink` via `find_or_initialize_by` on the natural key `[parent_type, parent_id, url]` — no schema change, no unique index needed. Model validations run, so a missing `Books::Book` (required `belongs_to :parent`) or missing user (DB FK on `submitted_by_id`) fails loud, wrapped by the base rescue that names the legacy link id. `source` is inferred from a string-extracted host (never `URI.parse`, which raises on the two non-ASCII Wikipedia URLs).

**Tech Stack:** Rails 8, Minitest + Mocha, PostgreSQL. Reuses `Services::BooksMigration::Migrator` (per-row AR base) and `LegacyBooks::Record` (read-only legacy replica).

## Global Constraints

- Run **all** Rails commands from `web-app/` (`cd web-app` first).
- Lint with `bundle exec standardrb` (NOT rubocop); must be clean.
- Namespace: `Services::BooksMigration::` for the migrator; `LegacyBooks::` for the legacy model; tests mirror the namespace (`module Services; module BooksMigration; class ...Test`).
- **No schema change.** `external_links` already has every needed column and polymorphic `parent`. Do not add an index.
- **Per-row AR write path** (subclass `Migrator`, not `BulkUpsertMigrator`). Idempotency via `find_or_initialize_by(parent_type:, parent_id:, url:)`.
- **Fail loud** on a missing FK — never silently drop. Achieved here for free by AR validation (`belongs_to :parent` required) + the DB FK on `submitted_by_id`; the base `Migrator` rescue re-raises naming the legacy link id.
- Owner decisions baked in: `name` migrated **verbatim**; `link_category` always `:information`; scheme-less URLs **normalized** to `https://`.
- Preserve legacy `created_at`/`updated_at`.
- No code comments beyond the one class-level doc comment (house style; see sibling migrators).

## File Structure

- **Create** `web-app/app/models/legacy_books/link.rb` — read-only legacy `links` model (mirrors `legacy_books/user.rb`).
- **Create** `web-app/app/lib/services/books_migration/external_link_migrator.rb` — the migrator (per-row AR + host/source/url helpers).
- **Create** `web-app/test/lib/services/books_migration/external_link_migrator_test.rb` — unit tests (stub `legacy_each`).
- **Modify** `web-app/lib/tasks/data_migration.rake` — add `:external_links` task + insert into `:all`.

---

## Task 1: `LegacyBooks::Link` + `ExternalLinkMigrator` + orchestration

**Files:**
- Create: `web-app/app/models/legacy_books/link.rb`
- Create: `web-app/app/lib/services/books_migration/external_link_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/external_link_migrator_test.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `Services::BooksMigration::Migrator` (base; provides `call`, `legacy_each`, per-row rescue, `@count`, `without_search_indexing`); `ExternalLink` (target model, `enum :source` + `enum :link_category` both `prefix: true`); `Books::Book`, `User` (parents/submitters).
- Produces: `Services::BooksMigration::ExternalLinkMigrator.call → {success:, data: {model: "ExternalLink", count:}}` (or `{success: false, error:}`); `LegacyBooks::Link` (read-only, `table_name = "links"`); rake task `data_migration:external_links`.

- [ ] **Step 1: Create the read-only legacy model**

Create `web-app/app/models/legacy_books/link.rb`:

```ruby
module LegacyBooks
  class Link < Record
    self.table_name = "links"
  end
end
```

- [ ] **Step 2: Write the failing test file**

Create `web-app/test/lib/services/books_migration/external_link_migrator_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class ExternalLinkMigratorTest < ActiveSupport::TestCase
      setup do
        @book = Books::Book.create!(title: "Link Parent")
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = ExternalLinkMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 1,
          "name" => "Wikipedia",
          "url" => "http://en.wikipedia.org/wiki/Test",
          "user_id" => @user.id,
          "description" => nil,
          "book_id" => @book.id,
          "created_at" => Time.utc(2022, 11, 5, 4, 12, 17),
          "updated_at" => Time.utc(2022, 11, 5, 4, 12, 17)
        }.merge(overrides)
      end

      test "maps a legacy link to a Books::Book-parented ExternalLink" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "ExternalLink", result[:data][:model]

        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_not_nil link
        assert_equal @book, link.parent
        assert_equal @user, link.submitted_by
        assert_equal "Wikipedia", link.name
        assert_nil link.description
        assert_equal "http://en.wikipedia.org/wiki/Test", link.url
        assert link.public?
        assert link.link_category_information?
        assert link.source_wikipedia?
        assert_nil link.source_name
      end

      test "preserves legacy created_at/updated_at" do
        ts = Time.utc(2024, 12, 15, 9, 0, 0)
        run_migrator([legacy_row("created_at" => ts, "updated_at" => ts)])

        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_equal ts, link.created_at
        assert_equal ts, link.updated_at
      end

      test "infers source from the URL host" do
        cases = {
          "http://en.wikipedia.org/wiki/A" => "wikipedia",
          "http://de.wikipedia.org/wiki/B" => "wikipedia",
          "https://www.goodreads.com/book/show/1" => "goodreads",
          "http://www.amazon.com/dp/123" => "amazon",
          "https://bookshop.org/books/x" => "bookshop_org",
          "http://books.google.com/books?q=x" => "other",
          "http://www.time.com/x" => "other",
          "http://www.powells.com/biblio/x" => "other"
        }
        rows = cases.keys.each_with_index.map do |url, i|
          book = Books::Book.create!(title: "Src Parent #{i}")
          legacy_row("id" => 100 + i, "book_id" => book.id, "url" => url)
        end
        result = run_migrator(rows)

        assert result[:success], result[:error]
        cases.each do |url, expected|
          link = ExternalLink.find_by(url: url)
          assert_not_nil link, "no link for #{url}"
          assert_equal expected, link.source, "wrong source for #{url}"
        end
      end

      test "sets source_name to the host for other-source links only" do
        other_book = Books::Book.create!(title: "Other Parent")
        run_migrator([
          legacy_row("id" => 200, "book_id" => other_book.id, "url" => "http://books.google.com/books?q=x"),
          legacy_row("id" => 201, "url" => "http://en.wikipedia.org/wiki/Y")
        ])

        other = ExternalLink.find_by(url: "http://books.google.com/books?q=x")
        assert other.source_other?
        assert_equal "books.google.com", other.source_name

        wiki = ExternalLink.find_by(url: "http://en.wikipedia.org/wiki/Y")
        assert wiki.source_wikipedia?
        assert_nil wiki.source_name
      end

      test "classifies non-ASCII wikipedia URLs without raising" do
        url = "http://en.wikipedia.org/wiki/Gödel,_Escher,_Bach"
        result = run_migrator([legacy_row("url" => url)])

        assert result[:success], result[:error]
        assert ExternalLink.find_by(url: url).source_wikipedia?
      end

      test "normalizes scheme-less URLs to https" do
        result = run_migrator([legacy_row("url" => "en.wikipedia.org/wiki/The_Hunting_of_the_Snark")])

        assert result[:success], result[:error]
        link = ExternalLink.find_by(parent_type: "Books::Book", parent_id: @book.id)
        assert_equal "https://en.wikipedia.org/wiki/The_Hunting_of_the_Snark", link.url
        assert link.source_wikipedia?
      end

      test "is idempotent on [parent, url]: re-running does not duplicate" do
        run_migrator([legacy_row])

        assert_no_difference -> { ExternalLink.count } do
          result = run_migrator([legacy_row])
          assert result[:success], result[:error]
          assert_equal 1, result[:data][:count]
        end
      end

      test "fails loud naming the legacy id when the book is missing" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 4242, "book_id" => missing)])

        refute result[:success]
        assert_match(/4242/, result[:error])
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/external_link_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::ExternalLinkMigrator` (the migrator does not exist yet).

- [ ] **Step 4: Implement the migrator**

Create `web-app/app/lib/services/books_migration/external_link_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `links` -> polymorphic ExternalLink, parented to Books::Book (preserved
    # ids), submitted_by -> the migrated user. Per-row AR (find_or_initialize_by on the
    # natural key [parent, url]) because external_links has no unique index to upsert
    # against. Validations run, so fail-loud is free: a missing Books::Book fails the
    # required belongs_to :parent, a missing user hits the submitted_by_id DB FK; the
    # base rescue names the legacy link id. `source` is inferred from the URL host by
    # string ops (not URI.parse, which raises on the non-ASCII Wikipedia urls). `name`
    # is migrated verbatim, `link_category` is always :information, and scheme-less urls
    # are normalized to https://. Legacy created_at/updated_at are preserved (assigning
    # non-nil timestamps leaves AR's create-time callback untouched). Idempotent on
    # [parent, url].
    class ExternalLinkMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Link
      end

      def model_key
        "ExternalLink"
      end

      def upsert_row(attrs)
        url = normalize_url(attrs["url"])
        source = source_for(url)
        link = ExternalLink.find_or_initialize_by(
          parent_type: "Books::Book",
          parent_id: attrs["book_id"],
          url: url
        )
        link.assign_attributes(
          name: attrs["name"],
          description: attrs["description"],
          submitted_by_id: attrs["user_id"],
          source: source,
          source_name: (source == :other ? extract_host(url) : nil),
          link_category: :information,
          public: true,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        )
        link.save!
      end

      def normalize_url(url)
        url.to_s.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
      end

      def extract_host(url)
        url.to_s.sub(%r{\Ahttps?://}i, "").split("/").first.to_s.downcase.sub(/\Awww\./, "")
      end

      def source_for(url)
        host = extract_host(url)
        return :wikipedia if host.end_with?("wikipedia.org")
        return :goodreads if host == "goodreads.com" || host.end_with?(".goodreads.com")
        return :amazon if host.include?("amazon.")
        return :bookshop_org if host == "bookshop.org" || host.end_with?(".bookshop.org")
        :other
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/external_link_migrator_test.rb`
Expected: PASS — 8 runs, 0 failures, 0 errors.

- [ ] **Step 6: Add the orchestration rake task**

In `web-app/lib/tasks/data_migration.rake`, add this task after the `category_items` task (before the `all` task):

```ruby
  desc "Migrate legacy links into external_links (Books::Book parent; source inferred from host)"
  task external_links: :environment do
    pp Services::BooksMigration::ExternalLinkMigrator.call
  end
```

Then append `:external_links` to the end of the `:all` task list:

```ruby
  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links]
```

- [ ] **Step 7: Verify the rake task is registered**

Run: `cd web-app && bin/rails -T data_migration:external_links`
Expected: lists `rake data_migration:external_links  # Migrate legacy links into external_links ...`.

- [ ] **Step 8: Lint**

Run: `cd web-app && bundle exec standardrb app/models/legacy_books/link.rb app/lib/services/books_migration/external_link_migrator.rb test/lib/services/books_migration/external_link_migrator_test.rb lib/tasks/data_migration.rake`
Expected: no offenses (autocorrect with `--fix` if needed, then re-run).

- [ ] **Step 9: Commit**

```bash
cd web-app && git add app/models/legacy_books/link.rb app/lib/services/books_migration/external_link_migrator.rb test/lib/services/books_migration/external_link_migrator_test.rb lib/tasks/data_migration.rake
git commit -m "Add ExternalLinkMigrator (legacy links -> external_links)"
```

---

## Final verification (controller-run against the real legacy DB, after Task 1)

Run by the controlling session (not a subagent — this touches the real legacy replica). Reset dev DB to the migrated baseline first if needed.

- [ ] Run `cd web-app && bin/rails data_migration:external_links` → `{success: true, data: {model: "ExternalLink", count: 13404}}`.
- [ ] `ExternalLink.where(parent_type: "Books::Book").count == 13404` (was 0).
- [ ] Source distribution: `ExternalLink.where(parent_type: "Books::Book").group(:source).count` → `{"wikipedia" => 13390, "other" => 13, "goodreads" => 1}`.
- [ ] Every `other`-source Books link has a non-null `source_name`; no Books link has a null/invalid url; `link_category` all `information`; `public` all true; all `submitted_by_id == 1`.
- [ ] Legacy `created_at` min/max preserved: `2022-11-05 04:12:17 UTC` … `2026-06-20 04:15:26 UTC`.
- [ ] Pre-existing `amazon` (non-Books) rows untouched: `ExternalLink.where.not(parent_type: "Books::Book").count` unchanged (15,677).
- [ ] Idempotent: a second `data_migration:external_links` run leaves the Books::Book `external_links` count at 13,404.
- [ ] Full suite green (`bin/rails test`); `bundle exec standardrb` and `bin/brakeman --no-pager` clean.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-08-books-external-links-migration-design.md`):
- D-write (per-row AR, find_or_initialize_by, fresh id, no unique index) → Task 1 Step 4; idempotency test (Step 2). ✓
- D-timestamps (preserve created_at/updated_at) → Step 4 assign; preservation test. ✓
- D-source (host via string ops, host→enum map) → `source_for`/`extract_host` (Step 4); source-per-host + non-ASCII tests. ✓
- D-source_name (host for `other` only) → Step 4; dedicated test. ✓
- D-name (verbatim) → Step 4 `name: attrs["name"]`; mapping test asserts "Wikipedia". ✓
- D-category (`:information`) → Step 4; mapping test asserts `link_category_information?`. ✓
- D-url (normalize scheme-less) → `normalize_url` (Step 4); normalize test. ✓
- D-public (true) → Step 4; mapping test. ✓
- D-fail-loud (validation + FK, base rescue names id) → Step 4 relies on required `belongs_to :parent`; missing-book test asserts `/4242/`. ✓
- No schema change → File Structure / Global Constraints; no migration task. ✓
- Orchestration (`:external_links` after `:users`/`:books`, appended to `:all`) → Steps 6-7. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete code; every run step has an exact command + expected output. ✓

**Type consistency:** `ExternalLinkMigrator.call` returns `{success:, data: {model:, count:}}` (inherited from `Migrator#call`, matched in tests). `source_for` returns a Symbol; `assign_attributes(source: symbol)` is valid for the `prefix: true` enum, and `link.source` reads back the String value the tests compare against (`assert_equal "wikipedia", link.source`). `extract_host` returns a String used both for `source_name` and inside `source_for`. `legacy_model`/`model_key`/`upsert_row` are the exact private methods the base `Migrator` calls. ✓
