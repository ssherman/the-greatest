# Data Migration Phase 1 — ETL Framework + languages/authors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the reusable old→new ETL framework (read-only legacy DB connection, id-mapping table, Migrator/Transformer base, search-suppression) and prove it end-to-end with two migrators — `languages` (fresh-id + map) and `authors` (preserved-id + FriendlyId slug).

**Architecture:** A second, read-only ActiveRecord connection (`LegacyBooks::*`, a Rails multi-DB `replica`) reads the restored legacy database. Pure per-entity `Transformer`s map a legacy attributes hash → new-model attributes; a `Migrator` base streams legacy rows in batches, transforms, and idempotently upserts through the real new-model AR classes (so slugs/enums/validations run), wrapping the load in a search-indexing suppression block. Fresh-id entities record `legacy_id → new_id` in a `legacy_id_maps` table; preserved-id entities insert with the legacy `id` and reset the sequence afterward.

**Tech Stack:** Rails 8.1, PostgreSQL 17 (dual database on one server), Minitest + Mocha + fixtures, `Services::` objects returning `{success:, data:/error:}`.

## Global Constraints

- Run all commands from `/home/shane/dev/the-greatest/web-app`.
- Lint with `bundle exec standardrb` (NOT rubocop). Tests: `bin/rails test`.
- Legacy dev DB is `the_greatest_books_legacy` on `localhost:6543` (user `postgres`, pw from repo-root `.env` `DOCKER_POSTGRES_PASSWORD`). Legacy volumes: `languages` 201, `authors` 58,193 (max id 66,839).
- **No test legacy database is required or created.** Transformer tests are pure (plain hashes); Migrator tests stub the legacy read (`legacy_each`) so the legacy connection is never opened in the suite.
- Preserved-id entities (`authors` → `books_authors`) insert with the legacy `id` unchanged (books-only table, empty at real import time via the planned DB reset) and reset the PK sequence after load. Fresh-id entities (`languages`) get new ids + a `legacy_id_maps` row.
- New models to write **through** (do not bypass with raw SQL): `Language` (FriendlyId `:name`), `Books::Author` (FriendlyId `:name`, `SearchIndexable`, `kind` enum default `person`, `alternate_names` is `default: [], null: false`).
- `Services::BooksMigration` already exists (`app/lib/services/books_migration.rb`, holds the reservation constants) — extend it, don't replace it.

## File Structure

- `config/database.yml` — restructure to 3-tier (`primary` + `legacy_books` replica per env).
- `app/models/legacy_books/record.rb` — `LegacyBooks::Record` abstract read-only base.
- `app/models/legacy_books/{language,author}.rb` — thin legacy models.
- `app/models/legacy_id_map.rb` + migration — `model/legacy_id/new_id` mapping.
- `app/lib/services/books_migration.rb` — add `without_search_indexing` / `search_indexing_suppressed?`.
- `app/models/concerns/search_indexable.rb` — honor the suppression flag.
- `app/lib/services/books_migration/migrator.rb` — Migrator base.
- `app/lib/services/books_migration/{language,author}_transformer.rb` — pure transformers.
- `app/lib/services/books_migration/{language,author}_migrator.rb` — the two migrators.
- `lib/tasks/data_migration.rake` — orchestrator tasks.

---

### Task 1: Legacy read-only connection + models

**Files:**
- Modify: `web-app/config/database.yml`
- Create: `web-app/app/models/legacy_books/record.rb`
- Create: `web-app/app/models/legacy_books/language.rb`
- Create: `web-app/app/models/legacy_books/author.rb`
- Test: `web-app/test/models/legacy_books/record_test.rb`

**Interfaces:**
- Produces: `LegacyBooks::Record` (abstract, read-only, reads `legacy_books`); `LegacyBooks::Language` (`table_name "languages"`); `LegacyBooks::Author` (`table_name "authors"`). Later tasks read these via `find_each` returning records whose `.attributes` is a String-keyed hash.

- [ ] **Step 1: Restructure `config/database.yml` to 3-tier**

Replace the `development:`, `test:`, and `production:` blocks (keep the `default: &default` anchor as-is) with:

```yaml
development:
  primary:
    <<: *default
    database: the_greatest_development
  legacy_books:
    <<: *default
    database: the_greatest_books_legacy
    replica: true

test:
  primary:
    <<: *default
    database: the_greatest_test
  legacy_books:
    <<: *default
    database: <%= ENV.fetch("LEGACY_BOOKS_TEST_DATABASE", "the_greatest_books_legacy_test") %>
    replica: true

production:
  primary:
    <<: *default
    host: <%= ENV.fetch("POSTGRES_HOST", "localhost") %>
    port: <%= ENV.fetch("POSTGRES_PORT", "5432") %>
    database: <%= ENV.fetch("POSTGRES_DATABASE", "the_greatest_production") %>
    username: <%= ENV.fetch("POSTGRES_USER", "the_greatest") %>
    password: <%= ENV["POSTGRES_PASSWORD"] %>
  legacy_books:
    <<: *default
    host: <%= ENV.fetch("LEGACY_BOOKS_HOST", ENV.fetch("POSTGRES_HOST", "localhost")) %>
    port: <%= ENV.fetch("LEGACY_BOOKS_PORT", ENV.fetch("POSTGRES_PORT", "5432")) %>
    database: <%= ENV.fetch("LEGACY_BOOKS_DATABASE", "the_greatest_books") %>
    username: <%= ENV.fetch("LEGACY_BOOKS_USER", ENV.fetch("POSTGRES_USER", "the_greatest")) %>
    password: <%= ENV.fetch("LEGACY_BOOKS_PASSWORD", ENV["POSTGRES_PASSWORD"]) %>
    replica: true
```

`replica: true` excludes `legacy_books` from `db:migrate`, `db:schema:load`, and `db:test:prepare` — it is read-only infrastructure, never migrated.

- [ ] **Step 2: Verify the app still boots on the primary connection**

Run: `bin/rails runner 'puts ActiveRecord::Base.connection.select_value("SELECT 1")'`
Expected: prints `1` (the primary connection still resolves after the 3-tier restructure).

- [ ] **Step 3: Create the read-only legacy base + models**

`app/models/legacy_books/record.rb`:

```ruby
module LegacyBooks
  # Read-only base for the legacy Greatest Books database (a Rails multi-db
  # `replica`). Never written to — the migration only reads from here.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: {reading: :legacy_books}

    def readonly?
      true
    end
  end
end
```

`app/models/legacy_books/language.rb`:

```ruby
module LegacyBooks
  class Language < Record
    self.table_name = "languages"
  end
end
```

`app/models/legacy_books/author.rb`:

```ruby
module LegacyBooks
  class Author < Record
    self.table_name = "authors"
  end
end
```

- [ ] **Step 4: Write the structural test (connection-free)**

`test/models/legacy_books/record_test.rb`:

```ruby
require "test_helper"

module LegacyBooks
  class RecordTest < ActiveSupport::TestCase
    test "Record is an abstract read-only base" do
      assert LegacyBooks::Record.abstract_class?
    end

    test "legacy models point at the legacy tables" do
      assert_equal "authors", LegacyBooks::Author.table_name
      assert_equal "languages", LegacyBooks::Language.table_name
    end
  end
end
```

> These assertions read only class configuration (`abstract_class?`, an explicitly-set `table_name`) and never open the legacy connection, so the suite needs no legacy test DB.

- [ ] **Step 5: Run the test — verify it passes**

Run: `bin/rails test test/models/legacy_books/record_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 6: Manually verify the real legacy connection in dev**

Run:
```bash
bin/rails runner 'puts "languages=#{LegacyBooks::Language.count} authors=#{LegacyBooks::Author.count}"; puts(LegacyBooks::Author.order(:id).last.attributes.slice("id","name"))'
```
Expected: `languages=201 authors=58193` and a real author row printed. Then confirm read-only:
```bash
bin/rails runner 'begin; LegacyBooks::Author.first.update!(name: "x"); rescue => e; puts e.class; end'
```
Expected: prints `ActiveRecord::ReadOnlyRecord`.

- [ ] **Step 7: Commit**

```bash
git add config/database.yml app/models/legacy_books test/models/legacy_books
git commit -m "Add read-only LegacyBooks connection + models"
```

---

### Task 2: `legacy_id_maps` table + `LegacyIdMap` model

**Files:**
- Create: `web-app/db/migrate/<timestamp>_create_legacy_id_maps.rb` (via generator)
- Create: `web-app/app/models/legacy_id_map.rb`
- Modify: `web-app/db/schema.rb` (generated)
- Test: `web-app/test/models/legacy_id_map_test.rb`

**Interfaces:**
- Produces: `LegacyIdMap.record(model:, legacy_id:, new_id:)` → upserts and returns `new_id`; `LegacyIdMap.lookup(model:, legacy_id:)` → `new_id` or `nil`.

- [ ] **Step 1: Generate + write the migration**

Run: `bin/rails generate migration CreateLegacyIdMaps`
Then replace the file body with:

```ruby
class CreateLegacyIdMaps < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_id_maps do |t|
      t.string :model, null: false
      t.bigint :legacy_id, null: false
      t.bigint :new_id, null: false
      t.timestamps
    end
    add_index :legacy_id_maps, [:model, :legacy_id], unique: true
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate` and `RAILS_ENV=test bin/rails db:migrate`
Expected: `legacy_id_maps` created; `db/schema.rb` updated.

- [ ] **Step 3: Write the failing test**

`test/models/legacy_id_map_test.rb`:

```ruby
require "test_helper"

class LegacyIdMapTest < ActiveSupport::TestCase
  test "record creates a mapping and returns new_id" do
    assert_equal 42, LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 42)
    assert_equal 42, LegacyIdMap.lookup(model: "Language", legacy_id: 7)
  end

  test "record is idempotent and updates new_id on the same key" do
    LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 42)
    LegacyIdMap.record(model: "Language", legacy_id: 7, new_id: 99)
    assert_equal 1, LegacyIdMap.where(model: "Language", legacy_id: 7).count
    assert_equal 99, LegacyIdMap.lookup(model: "Language", legacy_id: 7)
  end

  test "lookup returns nil for an unknown key" do
    assert_nil LegacyIdMap.lookup(model: "Language", legacy_id: 123)
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bin/rails test test/models/legacy_id_map_test.rb`
Expected: FAIL (`NoMethodError: undefined method 'record'`).

- [ ] **Step 5: Write the model**

`app/models/legacy_id_map.rb`:

```ruby
class LegacyIdMap < ApplicationRecord
  validates :model, presence: true
  validates :legacy_id, presence: true, uniqueness: {scope: :model}
  validates :new_id, presence: true

  def self.record(model:, legacy_id:, new_id:)
    upsert(
      {model: model, legacy_id: legacy_id, new_id: new_id, created_at: Time.current, updated_at: Time.current},
      unique_by: [:model, :legacy_id]
    )
    new_id
  end

  def self.lookup(model:, legacy_id:)
    where(model: model, legacy_id: legacy_id).pick(:new_id)
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/models/legacy_id_map_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 7: Lint + commit**

```bash
bundle exec standardrb --fix app/models/legacy_id_map.rb test/models/legacy_id_map_test.rb
git add db/migrate/*_create_legacy_id_maps.rb db/schema.rb app/models/legacy_id_map.rb test/models/legacy_id_map_test.rb
git commit -m "Add legacy_id_maps table + LegacyIdMap model"
```

---

### Task 3: Search-indexing suppression

**Files:**
- Modify: `web-app/app/lib/services/books_migration.rb`
- Modify: `web-app/app/models/concerns/search_indexable.rb`
- Test: `web-app/test/lib/services/books_migration/search_suppression_test.rb`

**Interfaces:**
- Produces: `Services::BooksMigration.without_search_indexing { }` (thread-local); `Services::BooksMigration.search_indexing_suppressed?` → Boolean. Inside the block, `SearchIndexable` create/update/destroy callbacks enqueue nothing.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/search_suppression_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SearchSuppressionTest < ActiveSupport::TestCase
  test "suppresses SearchIndexRequest creation inside the block" do
    author = books_authors(:tolkien)
    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        author.update!(description: "changed inside block")
      end
    end
  end

  test "does not suppress outside the block" do
    author = books_authors(:tolkien)
    assert_difference -> { SearchIndexRequest.count }, 1 do
      author.update!(description: "changed outside block")
    end
  end

  test "resets the flag even if the block raises" do
    assert_raises(RuntimeError) do
      Services::BooksMigration.without_search_indexing { raise "boom" }
    end
    refute Services::BooksMigration.search_indexing_suppressed?
  end
end
```

> Uses the existing `books_authors(:tolkien)` fixture. If that fixture name differs, run `grep -h '^[a-z].*:' test/fixtures/books/authors.yml` and use a real one.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/search_suppression_test.rb`
Expected: FAIL (`NoMethodError: undefined method 'without_search_indexing'`).

- [ ] **Step 3: Add the suppression helpers to `Services::BooksMigration`**

In `app/lib/services/books_migration.rb`, inside `module BooksMigration` (after the constants), add:

```ruby
    SUPPRESS_KEY = :books_migration_suppress_search

    # Runs the block with SearchIndexable enqueuing disabled on this thread, so a
    # bulk migration doesn't create a SearchIndexRequest per row. Always restores
    # the flag, even on error.
    def self.without_search_indexing
      previous = Thread.current[SUPPRESS_KEY]
      Thread.current[SUPPRESS_KEY] = true
      yield
    ensure
      Thread.current[SUPPRESS_KEY] = previous
    end

    def self.search_indexing_suppressed?
      Thread.current[SUPPRESS_KEY] == true
    end
```

- [ ] **Step 4: Honor the flag in `SearchIndexable`**

In `app/models/concerns/search_indexable.rb`, add an early return to both callback methods:

```ruby
  def queue_for_indexing
    return if Services::BooksMigration.search_indexing_suppressed?
    SearchIndexRequest.create!(parent: self, action: :index_item)
  end

  def queue_for_unindexing
    return if Services::BooksMigration.search_indexing_suppressed?
    SearchIndexRequest.create!(parent: self, action: :unindex_item)
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/search_suppression_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 6: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration.rb app/models/concerns/search_indexable.rb test/lib/services/books_migration/search_suppression_test.rb
git add app/lib/services/books_migration.rb app/models/concerns/search_indexable.rb test/lib/services/books_migration/search_suppression_test.rb
git commit -m "Add search-indexing suppression for bulk migration"
```

---

### Task 4: Migrator base + LanguageTransformer + LanguageMigrator

**Files:**
- Create: `web-app/app/lib/services/books_migration/migrator.rb`
- Create: `web-app/app/lib/services/books_migration/language_transformer.rb`
- Create: `web-app/app/lib/services/books_migration/language_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/language_transformer_test.rb`
- Test: `web-app/test/lib/services/books_migration/language_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::Language`, `LegacyIdMap`, `Services::BooksMigration.without_search_indexing`.
- Produces: `Services::BooksMigration::Migrator` base (`.call` → `{success:, data: {model:, count:}}`; subclasses define `legacy_model`, `model_key`, `upsert_row(attrs)`, optionally `finalize`; `legacy_each` yields String-keyed attribute hashes and is stubbable in tests). `LanguageTransformer.call(attrs) -> {name:}`. `LanguageMigrator`.

- [ ] **Step 1: Write the Migrator base**

`app/lib/services/books_migration/migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Base for one-way old->new entity migrators. Streams legacy rows in batches
    # (as String-keyed attribute hashes), transforms + upserts each through the
    # real new-model AR class, with search indexing suppressed for the load.
    # Idempotent — safe to re-run. Subclasses define legacy_model, model_key, and
    # upsert_row(attrs); optionally finalize.
    class Migrator
      BATCH_SIZE = 1000

      def self.call
        new.call
      end

      def call
        @count = 0
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            upsert_row(attrs)
            @count += 1
          end
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message}
      end

      private

      # Yields each legacy row's attributes (String keys). Stubbed in tests so the
      # legacy connection is never opened.
      def legacy_each(&block)
        legacy_model.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def finalize
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing LanguageTransformer test**

`test/lib/services/books_migration/language_transformer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::LanguageTransformerTest < ActiveSupport::TestCase
  test "maps legacy name; drops legacy-only columns" do
    attrs = Services::BooksMigration::LanguageTransformer.call(
      {"id" => 5, "name" => "French", "description" => "legacy only"}
    )
    assert_equal({name: "French"}, attrs)
  end
end
```

- [ ] **Step 3: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/language_transformer_test.rb`
Expected: FAIL (uninitialized constant `LanguageTransformer`).

- [ ] **Step 4: Write LanguageTransformer**

`app/lib/services/books_migration/language_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `languages` row -> new Language attributes. The new schema has no
    # description; only the name carries over (iso codes are absent in legacy).
    class LanguageTransformer
      def self.call(attrs)
        {name: attrs["name"]}
      end
    end
  end
end
```

- [ ] **Step 5: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/language_transformer_test.rb`
Expected: PASS (1 run).

- [ ] **Step 6: Write the failing LanguageMigrator test**

`test/lib/services/books_migration/language_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::LanguageMigratorTest < ActiveSupport::TestCase
  def legacy_rows
    [
      {"id" => 10, "name" => "Klingon"},
      {"id" => 11, "name" => "French"}
    ]
  end

  test "creates missing languages, dedupes existing by name, and maps legacy ids" do
    Language.create!(name: "French") # pre-existing new-app language (shared table)

    migrator = Services::BooksMigration::LanguageMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.map { |r| [r] })

    assert_difference -> { Language.count }, 1 do # only Klingon is new
      result = migrator.call
      assert result[:success]
      assert_equal 2, result[:data][:count]
    end

    assert Language.exists?(name: "Klingon")
    assert_equal Language.find_by(name: "Klingon").id, LegacyIdMap.lookup(model: "Language", legacy_id: 10)
    assert_equal Language.find_by(name: "French").id, LegacyIdMap.lookup(model: "Language", legacy_id: 11)
  end

  test "is idempotent: a second run creates no duplicate languages" do
    migrator = Services::BooksMigration::LanguageMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.map { |r| [r] })
    migrator.call

    migrator2 = Services::BooksMigration::LanguageMigrator.new
    migrator2.stubs(:legacy_each).multiple_yields(*legacy_rows.map { |r| [r] })
    assert_no_difference -> { Language.count } do
      migrator2.call
    end
  end
end
```

- [ ] **Step 7: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/language_migrator_test.rb`
Expected: FAIL (uninitialized constant `LanguageMigrator`).

- [ ] **Step 8: Write LanguageMigrator**

`app/lib/services/books_migration/language_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Fresh-id migrator: dedupes against existing new-app languages by name
    # (languages is a shared table) and records legacy_id -> new_id for later FK
    # remapping (e.g. books.original_language_id).
    class LanguageMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Language
      end

      def model_key
        "Language"
      end

      def upsert_row(attrs)
        target = LanguageTransformer.call(attrs)
        language = Language.find_or_create_by!(name: target[:name])
        LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: language.id)
      end
    end
  end
end
```

- [ ] **Step 9: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/language_migrator_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 10: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/migrator.rb app/lib/services/books_migration/language_transformer.rb app/lib/services/books_migration/language_migrator.rb test/lib/services/books_migration/language_transformer_test.rb test/lib/services/books_migration/language_migrator_test.rb
git add app/lib/services/books_migration/migrator.rb app/lib/services/books_migration/language_transformer.rb app/lib/services/books_migration/language_migrator.rb test/lib/services/books_migration/language_transformer_test.rb test/lib/services/books_migration/language_migrator_test.rb
git commit -m "Add Migrator base + languages migrator (fresh id + map)"
```

---

### Task 5: AuthorTransformer + AuthorMigrator (preserved id)

**Files:**
- Create: `web-app/app/lib/services/books_migration/author_transformer.rb`
- Create: `web-app/app/lib/services/books_migration/author_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/author_transformer_test.rb`
- Test: `web-app/test/lib/services/books_migration/author_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::Author`, `Books::Author`, `Migrator` base.
- Produces: `AuthorTransformer.call(attrs) -> {name:, sort_name:, birth_year:, death_year:, description:, alternate_names:}`. `AuthorMigrator` (preserves legacy `id`; `finalize` resets the `books_authors` sequence).

- [ ] **Step 1: Write the failing AuthorTransformer test**

`test/lib/services/books_migration/author_transformer_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::AuthorTransformerTest < ActiveSupport::TestCase
  test "maps core fields; sort_name from family_name" do
    attrs = Services::BooksMigration::AuthorTransformer.call(
      {"id" => 5, "name" => "J.R.R. Tolkien", "family_name" => "Tolkien",
       "birth_year" => 1892, "death_year" => 1973, "description" => "Author",
       "alternative_names" => ["John Ronald Reuel Tolkien"]}
    )
    assert_equal "J.R.R. Tolkien", attrs[:name]
    assert_equal "Tolkien", attrs[:sort_name]
    assert_equal 1892, attrs[:birth_year]
    assert_equal 1973, attrs[:death_year]
    assert_equal "Author", attrs[:description]
    assert_equal ["John Ronald Reuel Tolkien"], attrs[:alternate_names]
  end

  test "falls back to name for sort_name and coerces nil alternative_names to []" do
    attrs = Services::BooksMigration::AuthorTransformer.call(
      {"id" => 6, "name" => "Homer", "family_name" => nil, "alternative_names" => nil}
    )
    assert_equal "Homer", attrs[:sort_name]
    assert_equal [], attrs[:alternate_names]
  end
end
```

- [ ] **Step 2: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/author_transformer_test.rb`
Expected: FAIL (uninitialized constant `AuthorTransformer`).

- [ ] **Step 3: Write AuthorTransformer**

`app/lib/services/books_migration/author_transformer.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `authors` row -> new Books::Author attributes. `kind` is intentionally
    # omitted so the model default (:person) applies; `slug` is generated by
    # FriendlyId on save. `alternate_names` is NOT NULL default [] in the new
    # schema, so nil coerces to [].
    class AuthorTransformer
      def self.call(attrs)
        {
          name: attrs["name"],
          sort_name: attrs["family_name"].presence || attrs["name"],
          birth_year: attrs["birth_year"],
          death_year: attrs["death_year"],
          description: attrs["description"],
          alternate_names: Array(attrs["alternative_names"])
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/author_transformer_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 5: Write the failing AuthorMigrator test**

`test/lib/services/books_migration/author_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::AuthorMigratorTest < ActiveSupport::TestCase
  def legacy_rows
    [
      {"id" => 90001, "name" => "Legacy Author One", "family_name" => "One", "alternative_names" => nil},
      {"id" => 90002, "name" => "Legacy Author Two", "family_name" => "Two", "alternative_names" => ["L. Two"]}
    ]
  end

  def run_migrator
    migrator = Services::BooksMigration::AuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*legacy_rows.map { |r| [r] })
    migrator.call
  end

  test "creates authors preserving the legacy id, with a generated slug" do
    result = run_migrator
    assert result[:success], result[:error]
    assert_equal 2, result[:data][:count]

    a = Books::Author.find(90001)
    assert_equal "Legacy Author One", a.name
    assert_equal "One", a.sort_name
    assert a.slug.present?
    assert_equal ["L. Two"], Books::Author.find(90002).alternate_names
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator
    end
  end

  test "is idempotent: re-running does not duplicate or error" do
    run_migrator
    assert_no_difference -> { Books::Author.count } do
      run_migrator
    end
  end

  test "resets the books_authors sequence above the max id" do
    run_migrator
    fresh = Books::Author.create!(name: "Sequence Probe")
    assert_operator fresh.id, :>, 90002
  end
end
```

- [ ] **Step 6: Run it — verify it fails**

Run: `bin/rails test test/lib/services/books_migration/author_migrator_test.rb`
Expected: FAIL (uninitialized constant `AuthorMigrator`).

- [ ] **Step 7: Write AuthorMigrator**

`app/lib/services/books_migration/author_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Preserved-id migrator: books_authors is a books-only table, so legacy author
    # ids are kept verbatim (author URLs). Writes through Books::Author so
    # FriendlyId slugs, name normalization, and the kind enum all apply. Resets
    # the PK sequence after load so later auto-inserts don't collide.
    class AuthorMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::Author"
      end

      def upsert_row(attrs)
        author = Books::Author.find_or_initialize_by(id: attrs["id"])
        author.assign_attributes(AuthorTransformer.call(attrs))
        author.save!
      end

      def finalize
        Books::Author.connection.reset_pk_sequence!("books_authors")
      end
    end
  end
end
```

- [ ] **Step 8: Run it — verify it passes**

Run: `bin/rails test test/lib/services/books_migration/author_migrator_test.rb`
Expected: PASS (4 runs).

> Note on the search-suppression test: creating a `Books::Author` fires both `SearchIndexable#queue_for_indexing` (suppressed) and the author's own `queue_books_for_reindexing` — but the latter iterates `book_ids`, which is empty for a freshly-migrated author (no book_authors yet), so it is a no-op regardless. Both paths therefore create zero `SearchIndexRequest` rows.

- [ ] **Step 9: Lint + commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration/author_transformer.rb app/lib/services/books_migration/author_migrator.rb test/lib/services/books_migration/author_transformer_test.rb test/lib/services/books_migration/author_migrator_test.rb
git add app/lib/services/books_migration/author_transformer.rb app/lib/services/books_migration/author_migrator.rb test/lib/services/books_migration/author_transformer_test.rb test/lib/services/books_migration/author_migrator_test.rb
git commit -m "Add authors migrator (preserved id + slug + sequence reset)"
```

---

### Task 6: Orchestrator rake tasks + end-to-end dev run

**Files:**
- Create: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `LanguageMigrator`, `AuthorMigrator`.
- Produces: `rake data_migration:languages`, `data_migration:authors`, `data_migration:all`.

- [ ] **Step 1: Write the rake tasks**

`lib/tasks/data_migration.rake`:

```ruby
namespace :data_migration do
  desc "Migrate legacy languages (fresh ids + legacy_id_maps)"
  task languages: :environment do
    pp Services::BooksMigration::LanguageMigrator.call
  end

  desc "Migrate legacy authors into books_authors (preserves ids)"
  task authors: :environment do
    pp Services::BooksMigration::AuthorMigrator.call
  end

  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :authors]
end
```

- [ ] **Step 2: Verify the tasks are registered**

Run: `bin/rails -T data_migration`
Expected: lists `data_migration:languages`, `data_migration:authors`, `data_migration:all`.

- [ ] **Step 3: End-to-end dev run against the real legacy DB**

> This reads the real legacy dev DB and writes to dev. `authors` writes 58k rows via AR `save!`, so it takes a few minutes. (Snapshot dev first only if you care about its current books_authors contents.)

Run:
```bash
bin/rails data_migration:languages
bin/rails runner 'puts "lang_maps=#{LegacyIdMap.where(model: "Language").count}"'
bin/rails data_migration:authors
bin/rails runner 'puts "authors=#{Books::Author.count} max=#{Books::Author.maximum(:id)} pending_index=#{SearchIndexRequest.where(parent_type: "Books::Author").count}"'
```
Expected: `languages` result `{success: true, ...}` with `count: 201` and `lang_maps=201`; `authors` result `count: 58193`, `authors=58193 max=66839`, and `pending_index=0` (search indexing was suppressed). Finally confirm the sequence reset:
```bash
bin/rails runner 'a = Books::Author.create!(name: "Post-migration Probe"); puts a.id > 66839; a.destroy'
```
Expected: prints `true`.

- [ ] **Step 4: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Add data_migration orchestrator rake tasks"
```

---

## Self-Review

**1. Spec coverage** (design doc "Architecture" + Phase 1 scope for this increment):
- Legacy read-only second connection (`LegacyBooks::*`, replica) → Task 1. ✓
- `legacy_id_map(model, legacy_id, new_id)` → Task 2. ✓
- Transformer (pure) + Migrator base (batched read → transform → idempotent upsert) → Tasks 4/5. ✓
- Search-callback suppression via thread-local checked by SearchIndexable → Task 3. ✓
- languages migrator (fresh id + map, dedupe by name) → Task 4. ✓
- authors migrator (preserve id via AR, slug, sort_name, alternate_names, sequence reset, search suppressed) → Task 5. ✓
- orchestrator rake tasks + dependency order → Task 6. ✓
- Deferred entities (users/books/editions/identifiers/book_authors/categories/external_links) and Phases 2–3 are explicitly out of this plan. ✓

**2. Placeholder scan:** No TBD/TODO. Complete code in every code step. Migration timestamps come from the generator (Tasks 2). The one fixture reference (`books_authors(:tolkien)`) carries a fallback grep instruction.

**3. Type consistency:** `Migrator#call` → `{success:, data: {model:, count:}}` / `{success:, error:}` used consistently in Tasks 4–6. Subclass contract (`legacy_model`, `model_key`, `upsert_row(attrs)`, `finalize`, stubbable `legacy_each`) matches between the base (Task 4) and both migrators (Tasks 4/5). `LegacyIdMap.record(model:, legacy_id:, new_id:)` / `.lookup(model:, legacy_id:)` keyword signatures match between definition (Task 2) and callers (Task 4). Transformer `.call(attrs)` (String-keyed hash) → symbol-keyed attrs hash consistent across Tasks 4/5.
