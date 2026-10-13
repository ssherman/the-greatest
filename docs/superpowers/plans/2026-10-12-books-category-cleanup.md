# Books Subject and Location Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make merging books categories safe, give locations a hierarchy with inherited links, and build a reviewable rules + AI pipeline that cleans the subject and location vocabulary and trims over-tagged books.

**Architecture:** A `merged_into_id` pointer plus friendly_id history makes every reader (URLs, legacy redirects, saved searches, the weekly sync) follow merges and renames. `category_items.source` and one `Categories::AncestorReconciler` keep inherited location links consistent. The cleanup writes `CategoryCleanupDecision` rows (rules pass, then AI passes one category per call), the owner reviews a report, and an idempotent applier executes them in dependency order.

**Tech Stack:** Rails 8, PostgreSQL (recursive CTEs, `ON CONFLICT`), friendly_id `:history`, the existing `Services::Ai::Tasks::BaseTask` (OpenAI Responses API, strict `OpenAI::BaseModel` schemas), Minitest + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md`

## Global Constraints

- Run every Rails/yarn command from `web-app/`. Lint is `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- Use Rails generators for models and migrations (`bin/rails generate model ...`, `bin/rails generate migration ...`), then edit the generated file.
- Only `type = 'Books::Category'` rows are ever touched by cleanup, the reconciler or the trim. Music and games categories must stay byte-identical; tests assert this.
- Inside `module Services ...` and `module Actions::Admin::Books`, root-anchor every top-level constant: `::Categories::Merger`, `::Books::Category`, `::Books::Book`, `::Category`, `::CategoryItem`. A bare `Categories::` inside `Services` resolves to `Services::Categories` and raises.
- `CategoryItem#source` is `enum :source, {legacy: 0, admin: 1, inherited: 2}, prefix: true`. The prefix is mandatory: an unprefixed scope named `inherited` overrides Ruby's `Class#inherited` hook.
- `CategoryCleanupDecision#action` and `#decided_by` use `prefix: true` (unprefixed `delete`/`merge` scopes collide with Active Record).
- The four book-type categories (`::Books::Category.protected_ids`) are never merged, deleted, renamed or re-parented by any code in this plan.
- AI tasks declare `task_role = :standard` and never name a model id. Tests never make a network call: stub the task's `call` or the provider with Mocha.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`. A clean `bin/rails test` prints no new warnings.
- Config values (all in `config/initializers/categories.rb`, Task 9): `config.x.books.browse_min_category_books = 5`, `config.x.categories_cleanup.head_min_links = 20`, `tail_batch_size = 1`, `max_direct_locations = 15`, `sample_titles = 5`, `estimated_cost_per_call = 0.004`, `max_unforced_cost = 50`.
- Never run a cleanup, reconcile or trim rake task against the development database as part of a task. They are for the owner's rollout (spec §7).

## Review Focus

1. **A merge target later deleted as junk.** Category A merged into B, then B soft-deleted without a merge. Every reader must treat A as gone (404 / dropped link), never resolve to the deleted B. Pinned in Task 1 (`canonical`) and Task 6 (sync map).
2. **Two legacy categories that both merged into one target, on the same new book, in one sync batch.** The upsert must not raise "ON CONFLICT DO UPDATE command cannot affect row a second time". Pinned in Task 6.
3. **A filter URL listing two slugs that resolve to the same category** (`/the-greatest/a,b/books` with `a` merged into `b`). Expect a 301 to `/the-greatest/b/books`, not a 404. Pinned in Task 4.
4. **An admin adds a category the book already holds as `inherited`.** Expect success with the row upgraded to `admin`, not a uniqueness error. Pinned in Task 7.
5. **Apply re-run after a partial failure, and a category edited between propose and apply.** Expect no double merges and no exceptions on re-run, and the edited category's decisions marked `stale`. Pinned in Task 14.

---

### Task 1: Schema and model basics (merged_into, source, slug history, hierarchy validation)

**Files:**
- Create: `web-app/db/migrate/<ts>_add_merged_into_to_categories.rb` (generator)
- Create: `web-app/db/migrate/<ts>_add_source_to_category_items.rb` (generator)
- Modify: `web-app/app/models/category.rb`
- Modify: `web-app/app/models/books/category.rb`
- Modify: `web-app/app/models/category_item.rb`
- Test: `web-app/test/models/category_test.rb`, `web-app/test/models/books/category_test.rb`, `web-app/test/models/category_item_test.rb`

**Interfaces:**
- Produces: `Category#merged_into` (belongs_to), `Category.merged` scope, `Category#canonical` → `Category | nil`, `Category.replace_merged_ids(ids) → Array<Integer>`, friendly_id history on `Category`; `Books::Category::MAX_DEPTH = 8`, `Books::Category#ancestors → Array<Books::Category>` (nearest first), `Books::Category.protected_ids → Array<Integer>`; `CategoryItem` enum `source` with `prefix: true` (`source_legacy`, `source_admin`, `source_inherited` scopes; `source_inherited?`), `CategoryItem.direct` scope.

- [ ] **Step 1: Generate the migrations**

```bash
cd web-app
bin/rails generate migration AddMergedIntoToCategories
bin/rails generate migration AddSourceToCategoryItems
```

Edit the first generated file to:

```ruby
class AddMergedIntoToCategories < ActiveRecord::Migration[8.1]
  def change
    add_reference :categories, :merged_into, foreign_key: {to_table: :categories}, index: true, null: true
  end
end
```

Edit the second to (keep whatever `Migration[x.y]` version the generator wrote):

```ruby
class AddSourceToCategoryItems < ActiveRecord::Migration[8.1]
  def change
    # Adding a column with a constant default is metadata-only on PostgreSQL 11+,
    # so this does not rewrite the ~1.8M-row table during the deploy.
    add_column :category_items, :source, :integer, null: false, default: 0
  end
end
```

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && bin/rails db:test:prepare`
Expected: both migrations run; `db/schema.rb` gains `merged_into_id` and `source`.

- [ ] **Step 2: Write the failing tests**

Append to `web-app/test/models/category_test.rb` (inside the existing test class):

```ruby
  test "canonical is self for an active category" do
    category = categories(:books_france_location)
    assert_equal category, category.canonical
  end

  test "canonical follows merged_into to an active target" do
    target = categories(:books_france_location)
    source = ::Books::Category.create!(name: "France (country)", category_type: :location, deleted: true, merged_into: target)
    assert_equal target, source.canonical
  end

  test "canonical is nil for a deleted category with no merge" do
    assert_nil categories(:books_deleted_genre).canonical
  end

  test "canonical is nil when the merge target was itself deleted without a merge" do
    target = ::Books::Category.create!(name: "Junk Target", category_type: :location, deleted: true)
    source = ::Books::Category.create!(name: "Junk Source", category_type: :location, deleted: true, merged_into: target)
    assert_nil source.canonical
  end

  test "replace_merged_ids swaps merged ids for their targets and keeps every other id" do
    target = categories(:books_france_location)
    source = ::Books::Category.create!(name: "Paris, France", category_type: :location, deleted: true, merged_into: target)
    deleted = categories(:books_deleted_genre)

    assert_equal [target.id, deleted.id], ::Category.replace_merged_ids([source.id, deleted.id, target.id])
    assert_equal [], ::Category.replace_merged_ids([])
  end

  test "a renamed category keeps its old slug in history" do
    category = ::Books::Category.create!(name: "Washington DC", category_type: :location)
    old_slug = category.slug
    category.update!(name: "Washington, D.C.")

    refute_equal old_slug, category.slug
    assert_equal category, ::Books::Category.friendly.find(old_slug)
  end
```

Append to `web-app/test/models/books/category_test.rb` (create the file with this wrapper if it does not exist):

```ruby
require "test_helper"

module Books
  class CategoryTest < ActiveSupport::TestCase
    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "ancestors walks up the parent chain, nearest first" do
      na = location("North America")
      us = location("United States", parent: na)
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)

      assert_equal [il, us, na], chicago.ancestors
      assert_equal [], na.ancestors
    end

    test "a location's parent must be a books location" do
      subject = ::Books::Category.create!(name: "War", category_type: :subject)
      place = ::Books::Category.new(name: "Somewhere", category_type: :location, parent: subject)

      refute place.valid?
      assert_includes place.errors[:parent_id], "must be a books location"
    end

    test "a location can't be re-parented under its own descendant" do
      us = location("United States")
      il = location("Illinois", parent: us)
      us.parent = il

      refute us.valid?
      assert_includes us.errors[:parent_id], "would create a cycle"
    end

    test "genres keep their existing freedom to have any parent" do
      parent = ::Books::Category.create!(name: "Speculative", category_type: :genre)
      child = ::Books::Category.new(name: "Space Opera", category_type: :genre, parent: parent)
      assert child.valid?
    end

    test "protected_ids are the four book-type categories resolved through LegacyIdMap" do
      fiction = categories(:books_fiction_genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: ::Books::BookType::LEGACY_CATEGORY_IDS[0], new_id: fiction.id)
      ::Books::BookType.reset_category_ids!

      assert_includes ::Books::Category.protected_ids, fiction.id
    ensure
      ::Books::BookType.reset_category_ids!
    end
  end
end
```

If `test/models/books/category_test.rb` already exists, add only the `location` helper and the five tests to the existing class.

Append to `web-app/test/models/category_item_test.rb` (inside the existing class):

```ruby
  test "source defaults to legacy and the direct scope excludes inherited rows" do
    book = books_books(:war_and_peace)
    category = categories(:books_france_location)
    item = CategoryItem.create!(category: category, item: book)

    assert item.source_legacy?
    item.update!(source: :inherited)
    refute_includes CategoryItem.direct, item
    assert_includes CategoryItem.source_inherited, item
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/category_test.rb test/models/books/category_test.rb test/models/category_item_test.rb`
Expected: FAIL (`unknown attribute 'merged_into'`, `undefined method 'canonical'`, `ancestors`, `protected_ids`, `source_legacy?`).

- [ ] **Step 4: Implement**

In `web-app/app/models/category.rb`:

```ruby
  # :history keeps every old slug in friendly_id_slugs, so a rename no longer
  # breaks the old URL (Books::FilterParams and the legacy redirect resolve it).
  friendly_id :name, use: [:slugged, :scoped, :finders, :history], scope: :type
```

Add next to the other associations:

```ruby
  # Set when this category was merged into another. Always paired with
  # deleted: true, and flattened by Categories::Merger so it never chains.
  belongs_to :merged_into, class_name: "Category", optional: true
```

Add next to the other scopes:

```ruby
  scope :merged, -> { where.not(merged_into_id: nil) }

  # Ids with every merged one swapped for its target, order kept, duplicates
  # dropped. Ids that are not merged (active, or deleted as junk) pass through
  # unchanged so callers keep their existing behaviour for them.
  def self.replace_merged_ids(ids)
    ids = Array(ids)
    return ids if ids.empty?

    targets = where(id: ids).merged.pluck(:id, :merged_into_id).to_h
    ids.map { |id| targets.fetch(id, id) }.uniq
  end
```

Add a public instance method (above `private`):

```ruby
  # The category a reader should use in place of this one: itself when active,
  # its merge target when merged into an active category, nil otherwise.
  def canonical
    return self unless deleted?
    return nil if merged_into.nil? || merged_into.deleted?

    merged_into
  end
```

In `web-app/app/models/books/category.rb`, inside the class:

```ruby
    # Location trees are shallow; this caps any walk so a cycle written around
    # the validation (raw SQL) can't loop forever.
    MAX_DEPTH = 8

    validate :location_parent_is_valid, if: -> { location? && parent_id.present? && will_save_change_to_parent_id? }

    # The four book-type categories (Fiction, Nonfiction, Religion & Spirituality,
    # Poetry). BookTypeCategoryMigrator raises if one is soft-deleted and saved
    # searches filter on them, so nothing may merge, delete or rename them.
    def self.protected_ids
      ::Books::BookType::LABELS.keys.filter_map { |value| ::Books::BookType.category_id(value) }
    end

    # Nearest first: Chicago -> [Illinois, United States, North America].
    def ancestors
      chain = []
      node = parent
      while node && chain.size < MAX_DEPTH
        chain << node
        node = node.parent
      end
      chain
    end
```

and in its `private` section:

```ruby
    def location_parent_is_valid
      unless parent.is_a?(::Books::Category) && parent.location?
        errors.add(:parent_id, "must be a books location")
        return
      end
      errors.add(:parent_id, "would create a cycle") if parent == self || parent.ancestors.include?(self)
    end
```

In `web-app/app/models/category_item.rb`, after the associations:

```ruby
  # Why the link exists directly. `inherited` rows exist only because a more
  # specific location is linked to the same item; Categories::AncestorReconciler
  # owns them. prefix: true is required -- an unprefixed `inherited` scope would
  # override Ruby's Class#inherited hook.
  enum :source, {legacy: 0, admin: 1, inherited: 2}, prefix: true

  scope :direct, -> { where.not(source: :inherited) }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/category_test.rb test/models/books/category_test.rb test/models/category_item_test.rb test/lib/categories`
Expected: PASS. If the friendly_id history test fails on the lookup, check `friendly_id_slugs.scope` holds `type:Books::Category` for the new row (`FriendlyId::Slug.last`); the `:scoped` + `:history` combination writes it there.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: PASS. Friendly_id history touches every `Category` save; any failure here is a test that asserted slug behaviour on rename and needs its expectation updated to the history behaviour, not a reason to drop `:history`.

- [ ] **Step 7: Commit**

```bash
git add web-app/db web-app/app/models web-app/test/models
git commit -m "Categories: merged_into pointer, slug history, link source, location hierarchy validation"
```

---

### Task 2: Item counter, bulk reindex helper, and the ancestor reconciler

**Files:**
- Create: `web-app/app/lib/categories/item_counter.rb`
- Create: `web-app/app/lib/categories/ancestor_reconciler.rb`
- Modify: `web-app/app/lib/categories/item_reindexer.rb`
- Create: `web-app/lib/tasks/categories.rake`
- Test: `web-app/test/lib/categories/item_counter_test.rb`, `web-app/test/lib/categories/ancestor_reconciler_test.rb`, `web-app/test/lib/categories/item_reindexer_test.rb`

**Interfaces:**
- Consumes: Task 1 (`CategoryItem` source enum, `Books::Category::MAX_DEPTH`).
- Produces: `Categories::ItemCounter.call(category_ids) → Integer` (rows updated); `Categories::ItemReindexer.queue_items(pairs) → Integer` where `pairs` is `Array<[item_type String, item_id Integer]>`; `Categories::AncestorReconciler.call(item_ids: nil) → Result` with `data: {added: Integer, removed: Integer}`; rake `categories:reconcile_ancestors`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/categories/item_counter_test.rb`:

```ruby
require "test_helper"

module Categories
  class ItemCounterTest < ActiveSupport::TestCase
    test "recomputes item_count from category_items for the given ids only" do
      france = categories(:books_france_location)
      politics = categories(:books_politics_subject)
      france.update_column(:item_count, 999)
      politics.update_column(:item_count, 999)

      ItemCounter.call([france.id])

      assert_equal CategoryItem.where(category_id: france.id).count, france.reload.item_count
      assert_equal 999, politics.reload.item_count
    end

    test "does nothing for an empty list" do
      assert_equal 0, ItemCounter.call([])
    end
  end
end
```

Append to `web-app/test/lib/categories/item_reindexer_test.rb` (inside the existing class):

```ruby
  test "queue_items inserts one request per distinct indexed item" do
    book = books_books(:war_and_peace)

    assert_difference -> { SearchIndexRequest.count }, 1 do
      ItemReindexer.queue_items([["Books::Book", book.id], ["Books::Book", book.id], ["Unindexed::Thing", 1]])
    end
  end

  test "queue_items is a no-op while search indexing is suppressed" do
    Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

    assert_no_difference -> { SearchIndexRequest.count } do
      ItemReindexer.queue_items([["Books::Book", books_books(:war_and_peace).id]])
    end
  end
```

`web-app/test/lib/categories/ancestor_reconciler_test.rb`:

```ruby
require "test_helper"

module Categories
  class AncestorReconcilerTest < ActiveSupport::TestCase
    setup do
      @na = location("North America")
      @us = location("United States", parent: @na)
      @il = location("Illinois", parent: @us)
      @chicago = location("Chicago", parent: @il)
      @springfield = location("Springfield", parent: @il)
      @book = books_books(:war_and_peace)
    end

    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    def link(category, source: :legacy, item: @book)
      CategoryItem.create!(category: category, item: item, source: source)
    end

    def inherited_ids(item = @book)
      CategoryItem.where(item: item).source_inherited.pluck(:category_id).sort
    end

    test "adds every ancestor of a direct location link as inherited" do
      link(@chicago)

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert result.success?
      assert_equal 3, result.data[:added]
      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids
    end

    test "is idempotent" do
      link(@chicago)
      AncestorReconciler.call(item_ids: [@book.id])

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [0, 0], [result.data[:added], result.data[:removed]]
    end

    test "removes inherited links whose descendant is gone" do
      chicago_link = link(@chicago)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert_equal 3, result.data[:removed]
      assert_equal [], inherited_ids
    end

    test "keeps an inherited link another descendant still needs" do
      chicago_link = link(@chicago)
      link(@springfield)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids
    end

    test "never touches a direct link to an ancestor" do
      chicago_link = link(@chicago)
      link(@us, source: :admin)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      AncestorReconciler.call(item_ids: [@book.id])

      assert CategoryItem.exists?(item: @book, category: @us, source: :admin)
    end

    test "skips a soft-deleted parent and everything above it" do
      @il.update!(deleted: true)
      link(@chicago)

      AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [], inherited_ids
    end

    test "with no item_ids it reconciles every book and recounts what it touched" do
      other = books_books(:crime_and_punishment)
      link(@chicago)
      link(@springfield, item: other)

      AncestorReconciler.call

      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids(other)
      assert_equal 2, @il.reload.item_count
    end

    test "an empty item_ids list does nothing" do
      link(@chicago)
      assert_equal 0, AncestorReconciler.call(item_ids: []).data[:added]
    end

    test "queues a reindex for every item it changed" do
      link(@chicago)
      assert_difference -> { SearchIndexRequest.where(parent: @book).count }, 1 do
        AncestorReconciler.call(item_ids: [@book.id])
      end
    end

    test "leaves music categories alone" do
      rock = categories(:music_rock_genre)
      before = CategoryItem.where(category: rock).pluck(:id, :source)
      link(@chicago)

      AncestorReconciler.call

      assert_equal before, CategoryItem.where(category: rock).pluck(:id, :source)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/categories/item_counter_test.rb test/lib/categories/ancestor_reconciler_test.rb test/lib/categories/item_reindexer_test.rb`
Expected: FAIL (`uninitialized constant Categories::ItemCounter`, `AncestorReconciler`, `undefined method 'queue_items'`).

- [ ] **Step 3: Implement**

`web-app/app/lib/categories/item_counter.rb`:

```ruby
# frozen_string_literal: true

module Categories
  # Recomputes the item_count counter cache for specific categories. Bulk SQL
  # writers (Merger, AncestorReconciler) bypass CategoryItem's counter_cache,
  # so they call this once at the end instead.
  class ItemCounter
    def self.call(category_ids)
      ids = Array(category_ids).map(&:to_i).uniq
      return 0 if ids.empty?

      ::Category.connection.update(<<~SQL)
        UPDATE categories c
        SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
        WHERE c.id IN (#{ids.join(",")})
      SQL
    end
  end
end
```

In `web-app/app/lib/categories/item_reindexer.rb`, add below `self.batch_size`:

```ruby
    # Queue specific items, for bulk writers that know exactly which items they
    # changed (Merger, AncestorReconciler). Same suppression rule as #call.
    def self.queue_items(pairs)
      return 0 if ::Services::BooksMigration.search_indexing_suppressed?

      now = Time.current
      rows = pairs.uniq
        .select { |item_type, _| ::Search::IndexerJob::INDEXED_MODEL_TYPES.include?(item_type) }
        .map do |item_type, item_id|
          {parent_type: item_type, parent_id: item_id, action: ::SearchIndexRequest.actions[:index_item], created_at: now, updated_at: now}
        end
      rows.each_slice(batch_size) { |slice| ::SearchIndexRequest.insert_all(slice) }
      rows.size
    end
```

`web-app/app/lib/categories/ancestor_reconciler.rb`:

```ruby
# frozen_string_literal: true

module Categories
  # Keeps inherited location links consistent (spec §3.3). A book linked
  # directly to Chicago also carries `inherited` links to Illinois, United
  # States and North America; when the Chicago link goes, so do the inherited
  # links nothing else still needs. Set-based SQL over a recursive CTE of the
  # books location tree, so a whole-catalog run is two statements.
  #
  # Callers: admin add/remove category, Merger, Deleter, the book merger, the
  # weekly sync, cleanup apply, the over-tagged trim. Idempotent.
  class AncestorReconciler
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    ITEM_TYPE = "Books::Book"

    def self.call(item_ids: nil)
      new(item_ids: item_ids).call
    end

    def initialize(item_ids: nil)
      @item_ids = item_ids&.map(&:to_i)&.uniq
    end

    def call
      return result(0, 0) if @item_ids&.empty?

      added = removed = []
      ::CategoryItem.transaction do
        added = select_rows(insert_sql)
        removed = select_rows(delete_sql)
      end

      touched = added + removed
      ItemCounter.call(touched.map { |row| row["category_id"] })
      ItemReindexer.queue_items(touched.map { |row| [row["item_type"], row["item_id"]] })
      result(added.size, removed.size)
    end

    private

    def result(added, removed)
      Result.new(success?: true, data: {added: added, removed: removed}, errors: [])
    end

    def select_rows(sql)
      ::CategoryItem.connection.exec_query(sql).to_a
    end

    def inherited = ::CategoryItem.sources.fetch("inherited")

    def location = ::Category.category_types.fetch("location")

    def item_filter(table)
      return "" if @item_ids.nil?

      "AND #{table}.item_id IN (#{@item_ids.join(",")})"
    end

    # (descendant_id, ancestor_id) for every live books location and every live
    # ancestor above it. A soft-deleted parent ends the chain.
    def ancestry_cte
      <<~SQL
        WITH RECURSIVE ancestry(descendant_id, ancestor_id, depth) AS (
          SELECT c.id, p.id, 1
          FROM categories c
          JOIN categories p ON p.id = c.parent_id AND p.deleted = false
          WHERE c.type = 'Books::Category' AND c.category_type = #{location} AND c.deleted = false
          UNION ALL
          SELECT a.descendant_id, p.id, a.depth + 1
          FROM ancestry a
          JOIN categories c ON c.id = a.ancestor_id
          JOIN categories p ON p.id = c.parent_id AND p.deleted = false
          WHERE a.depth < #{::Books::Category::MAX_DEPTH}
        )
      SQL
    end

    def insert_sql
      <<~SQL
        #{ancestry_cte}
        INSERT INTO category_items (category_id, item_type, item_id, source, created_at, updated_at)
        SELECT DISTINCT a.ancestor_id, d.item_type, d.item_id, #{inherited}, NOW(), NOW()
        FROM category_items d
        JOIN ancestry a ON a.descendant_id = d.category_id
        WHERE d.item_type = '#{ITEM_TYPE}' AND d.source <> #{inherited} #{item_filter("d")}
        ON CONFLICT (category_id, item_type, item_id) DO NOTHING
        RETURNING category_id, item_type, item_id
      SQL
    end

    def delete_sql
      <<~SQL
        #{ancestry_cte}
        DELETE FROM category_items i
        USING categories c
        WHERE c.id = i.category_id AND c.type = 'Books::Category'
          AND i.item_type = '#{ITEM_TYPE}' AND i.source = #{inherited} #{item_filter("i")}
          AND NOT EXISTS (
            SELECT 1
            FROM category_items d
            JOIN ancestry a ON a.descendant_id = d.category_id
            WHERE d.item_type = i.item_type AND d.item_id = i.item_id
              AND d.source <> #{inherited} AND a.ancestor_id = i.category_id
          )
        RETURNING i.category_id, i.item_type, i.item_id
      SQL
    end
  end
end
```

`web-app/lib/tasks/categories.rake`:

```ruby
namespace :categories do
  desc "Add missing inherited location links and remove orphaned ones, for every book (idempotent)"
  task reconcile_ancestors: :environment do
    result = ::Categories::AncestorReconciler.call
    puts "Inherited location links: #{result.data[:added]} added, #{result.data[:removed]} removed"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/categories`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/categories lib/tasks/categories.rake test/lib/categories
git add web-app/app/lib/categories web-app/lib/tasks/categories.rake web-app/test/lib/categories
git commit -m "Categories: ancestor reconciler, item counter, bulk reindex helper"
```

---

### Task 3: Rework `Categories::Merger` and guard `Categories::Deleter`

**Files:**
- Create: `web-app/app/lib/categories/refused.rb`
- Modify: `web-app/app/lib/categories/merger.rb`
- Modify: `web-app/app/lib/categories/deleter.rb`
- Test: `web-app/test/lib/categories/merger_test.rb`, `web-app/test/lib/categories/deleter_test.rb`

**Interfaces:**
- Consumes: Task 1 (`merged_into`, `protected_ids`, `ancestors`), Task 2 (`ItemCounter`, `ItemReindexer.queue_items`, `AncestorReconciler`).
- Produces: `Categories::Refused < StandardError`; `Categories::Merger.new(category:, category_to_merge_with:).merge → target Category` (raises `Categories::Refused`); `Categories::Deleter.new(category:, soft: true).delete` (raises `Categories::Refused` for protected books categories; reconciles moved books for locations).

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/categories/merger_test.rb` (inside the existing class; keep the existing tests):

```ruby
    def books_location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "sets merged_into on the source and soft-deletes it" do
      target = books_location("Washington, D.C.")
      source = books_location("Washington DC")

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      source.reload
      assert source.deleted?
      assert_equal target, source.merged_into
    end

    test "flattens earlier merges into the source onto the new target" do
      a = books_location("Kolkata (Calcutta)")
      b = books_location("Calcutta")
      c = books_location("Kolkata")
      Categories::Merger.new(category: a, category_to_merge_with: b).merge

      Categories::Merger.new(category: b, category_to_merge_with: c).merge

      assert_equal c, a.reload.merged_into
    end

    test "moves links in bulk, keeps the strongest source, and recounts both sides" do
      target = books_location("Paris")
      source = books_location("Paris, France")
      book = books_books(:war_and_peace)
      other = books_books(:crime_and_punishment)
      CategoryItem.create!(category: source, item: book, source: :admin)
      CategoryItem.create!(category: source, item: other)
      CategoryItem.create!(category: target, item: book, source: :inherited)

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      assert_equal "admin", CategoryItem.find_by(category: target, item: book).source
      assert CategoryItem.exists?(category: target, item: other, source: :legacy)
      assert_equal 0, CategoryItem.where(category: source).count
      assert_equal 2, target.reload.item_count
      assert_equal 0, source.reload.item_count
    end

    test "moves child categories to the target" do
      target = books_location("United States")
      source = books_location("USA")
      child = books_location("Ohio", parent: source)

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      assert_equal target, child.reload.parent
    end

    test "merges a location into a subject of the same name" do
      target = ::Books::Category.create!(name: "Hope", category_type: :subject)
      source = books_location("Hope")
      book = books_books(:war_and_peace)
      CategoryItem.create!(category: source, item: book)

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      assert CategoryItem.exists?(category: target, item: book)
    end

    test "adds the source name and its alternative names to the target" do
      target = books_location("Gdańsk")
      source = ::Books::Category.create!(name: "Danzig", category_type: :location, alternative_names: ["Dantzig"])

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      assert_equal %w[Danzig Dantzig], target.reload.alternative_names
    end

    test "refuses self, cross-domain, deleted, descendant and protected merges" do
      us = books_location("United States")
      ohio = books_location("Ohio", parent: us)
      music = categories(:music_rock_genre)
      deleted = categories(:books_deleted_genre)
      fiction = categories(:books_fiction_genre)
      ::Books::Category.stubs(:protected_ids).returns([fiction.id])

      [[us, us], [us, music], [deleted, us], [us, ohio], [fiction, us], [us, fiction]].each do |source, target|
        assert_raises(Categories::Refused, "#{source.name} -> #{target.name}") do
          Categories::Merger.new(category: source, category_to_merge_with: target).merge
        end
      end
    end

    test "refuses to move location children under a non-location" do
      source = books_location("Hope")
      books_location("Hope Street", parent: source)
      target = ::Books::Category.create!(name: "Hope", category_type: :subject)

      assert_raises(Categories::Refused) do
        Categories::Merger.new(category: source, category_to_merge_with: target).merge
      end
    end

    test "reconciles inherited links for books it moved onto a location" do
      us = books_location("United States")
      target = books_location("Chicago", parent: us)
      source = books_location("Chicago, Illinois")
      book = books_books(:war_and_peace)
      CategoryItem.create!(category: source, item: book)

      Categories::Merger.new(category: source, category_to_merge_with: target).merge

      assert CategoryItem.exists?(category: us, item: book, source: :inherited)
    end
```

Append to `web-app/test/lib/categories/deleter_test.rb` (inside the existing class; create the file with the usual `require "test_helper"` / `module Categories` / `class DeleterTest < ActiveSupport::TestCase` wrapper if absent):

```ruby
    test "refuses to delete a protected books category" do
      fiction = categories(:books_fiction_genre)
      ::Books::Category.stubs(:protected_ids).returns([fiction.id])

      assert_raises(Categories::Refused) { Categories::Deleter.new(category: fiction, soft: true).delete }
      refute fiction.reload.deleted?
    end

    test "soft-deleting a location drops the inherited links it justified" do
      us = ::Books::Category.create!(name: "United States", category_type: :location)
      chicago = ::Books::Category.create!(name: "Chicago", category_type: :location, parent: us)
      book = books_books(:war_and_peace)
      CategoryItem.create!(category: chicago, item: book)
      Categories::AncestorReconciler.call(item_ids: [book.id])

      Categories::Deleter.new(category: chicago, soft: true).delete

      refute CategoryItem.exists?(category: us, item: book)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/categories/merger_test.rb test/lib/categories/deleter_test.rb`
Expected: FAIL (`uninitialized constant Categories::Refused`, no `merged_into` set, children not moved).

- [ ] **Step 3: Implement**

`web-app/app/lib/categories/refused.rb`:

```ruby
# frozen_string_literal: true

module Categories
  # A merge or delete that would break an invariant (spec §1.3). The message is
  # shown to admins as-is.
  class Refused < StandardError; end
end
```

Replace `web-app/app/lib/categories/merger.rb` with:

```ruby
# frozen_string_literal: true

module Categories
  # Merges one category into another (spec §1.3). Bulk SQL, because cleanup
  # merges categories with tens of thousands of links: the old row-by-row copy
  # fired a counter-cache update and a reindex request per link.
  #
  # The source ends soft-deleted with merged_into pointing at the target, and
  # anything previously merged into the source is repointed too, so a lookup
  # never follows a chain. Readers (URLs, saved searches, the sync) resolve a
  # merged category through Category#canonical / Category.replace_merged_ids.
  class Merger
    attr_reader :category, :category_to_merge_with

    def initialize(category:, category_to_merge_with:)
      @category = category
      @category_to_merge_with = category_to_merge_with
    end

    def merge
      refuse_invalid!
      moved = []

      ::Category.transaction do
        moved = move_items
        ::Category.where(merged_into_id: source.id).update_all(merged_into_id: target.id)
        ::Category.where(parent_id: source.id).update_all(parent_id: target.id)
        update_alternative_names
        # update! (not update_column) so Category's reindex callback still fires.
        source.update!(deleted: true, merged_into: target)
      end

      ItemCounter.call([source.id, target.id])
      ItemReindexer.queue_items(moved)
      reconcile(moved) if source.location? || target.location?
      target
    end

    private

    def source = @category

    def target = @category_to_merge_with

    def refuse_invalid!
      raise Refused, "A category can't be merged into itself." if source.id == target.id
      raise Refused, "Categories from different sites can't be merged." if source.type != target.type
      raise Refused, "Deleted categories can't be merged." if source.deleted? || target.deleted?

      return unless source.is_a?(::Books::Category)

      protected_ids = ::Books::Category.protected_ids
      if protected_ids.include?(source.id) || protected_ids.include?(target.id)
        raise Refused, "Fiction, Nonfiction, Poetry and Religion & Spirituality can't be merged."
      end
      if target.ancestors.include?(source)
        raise Refused, "A category can't be merged into a place inside it."
      end
      if source.child_categories.exists? && !target.location?
        raise Refused, "#{source.name} has places under it, so it can only merge into a location."
      end
    end

    # Copies every link to the target. On a conflict a direct source beats an
    # inherited one; otherwise the target's row is left as it is.
    def move_items
      inherited = ::CategoryItem.sources.fetch("inherited")
      pairs = source.category_items.pluck(:item_type, :item_id)

      ::CategoryItem.connection.execute(<<~SQL)
        INSERT INTO category_items (category_id, item_type, item_id, source, created_at, updated_at)
        SELECT #{target.id.to_i}, item_type, item_id, source, NOW(), NOW()
        FROM category_items
        WHERE category_id = #{source.id.to_i}
        ON CONFLICT (category_id, item_type, item_id) DO UPDATE
          SET source = EXCLUDED.source, updated_at = NOW()
          WHERE category_items.source = #{inherited} AND EXCLUDED.source <> #{inherited}
      SQL
      ::CategoryItem.where(category_id: source.id).delete_all
      pairs
    end

    def update_alternative_names
      names = target.alternative_names + [source.name] + source.alternative_names
      target.alternative_names = names.uniq - [target.name]
      target.save!
    end

    def reconcile(pairs)
      book_ids = pairs.select { |type, _| type == "Books::Book" }.map(&:last)
      AncestorReconciler.call(item_ids: book_ids) if book_ids.any?
    end
  end
end
```

Replace the body of `web-app/app/lib/categories/deleter.rb` `delete` / `soft_delete`:

```ruby
    def delete
      refuse_protected!
      if @soft
        soft_delete
      else
        hard_delete
      end
    end

    private

    def refuse_protected!
      return unless @category.is_a?(::Books::Category)
      return unless ::Books::Category.protected_ids.include?(@category.id)

      raise Refused, "Fiction, Nonfiction, Poetry and Religion & Spirituality can't be deleted."
    end

    def soft_delete
      book_ids = @category.category_items.where(item_type: "Books::Book").pluck(:item_id)
      Category.transaction do
        # update! rather than update_column: update_column fires no callbacks, which
        # would silently skip Category#queue_items_for_reindexing and reintroduce the
        # stale-index defect this service is meant to be safe for.
        @category.update!(deleted: true)
        @category.category_items.destroy_all
      end
      # A deleted location no longer justifies the inherited links above it.
      AncestorReconciler.call(item_ids: book_ids) if @category.location? && book_ids.any?
    end
```

(Keep `hard_delete` as is.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/categories`
Expected: PASS, including the pre-existing merger and updater tests (`Updater` calls `Merger#merge` and still gets the target back). If a pre-existing merger test expects `Merger` to call `Deleter`, update that expectation: merging now bulk-deletes the source's links and soft-deletes it directly, because `Deleter` destroys links one row at a time.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/categories test/lib/categories
git add web-app/app/lib/categories web-app/test/lib/categories
git commit -m "Categories: bulk merger with merged_into, guards, child moves; protected deletes"
```

---

### Task 4: Public filter URLs and legacy `/genres/:id` follow merges and renames

**Files:**
- Modify: `web-app/app/lib/books/filter_params.rb`
- Modify: `web-app/app/controllers/books/ranked_items_controller.rb:18-20`
- Modify: `web-app/app/controllers/books/legacy_categories_controller.rb`
- Test: `web-app/test/lib/books/filter_params_test.rb`, `web-app/test/controllers/books/ranked_items_controller_test.rb`, `web-app/test/controllers/books/legacy_categories_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 (`canonical`, `merged` scope, slug history).
- Produces: `Books::FilterParams::Result#redirect?` (true when any category slug was resolved through a merge or slug history; `categories` then holds the canonical categories).

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/books/filter_params_test.rb`:

```ruby
    test "an active slug needs no redirect" do
      refute resolve(category_id: "france").redirect?
    end

    test "a merged slug resolves to its target and asks for a redirect" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      result = resolve(category_id: "france-country")

      assert result.redirect?
      assert_equal [target], result.categories
    end

    test "an old slug from before a rename resolves through history" do
      category = ::Books::Category.create!(name: "Washington DC", category_type: :location)
      old_slug = category.slug
      category.update!(name: "Washington, D.C.")

      result = resolve(category_id: old_slug)

      assert result.redirect?
      assert_equal [category], result.categories
    end

    test "two slugs that resolve to the same category collapse to one" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      result = resolve(category_id: "france,france-country")

      assert result.redirect?
      assert_equal [target], result.categories
    end

    test "a slug deleted without a merge still raises" do
      assert_raises(ActiveRecord::RecordNotFound) { resolve(category_id: "retired-genre") }
    end

    test "a merged slug whose target was deleted as junk raises" do
      junk = ::Books::Category.create!(name: "Junk", category_type: :location, deleted: true)
      ::Books::Category.create!(name: "Junk Twin", slug: "junk-twin", category_type: :location, deleted: true, merged_into: junk)

      assert_raises(ActiveRecord::RecordNotFound) { resolve(category_id: "junk-twin") }
    end
```

Append to `web-app/test/controllers/books/ranked_items_controller_test.rb` (inside the class):

```ruby
    test "a merged category slug 301s to the target's filter page" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      get "/the-greatest/france-country/books"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/france/books"
    end

    test "a merged slug keeps the other path segments when redirecting" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      get "/the-greatest/france-country/books/of/1900"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/france/books/of/1900"
    end
```

(If `/the-greatest/:slug/books/of/:year` is not a valid route shape in `config/routes.rb:1083-1105`, use whichever date segment `Books::FilterPath#date_segment` emits for `year_start == year_end` — the expectation is that `FilterPath` rebuilds the same URL with the canonical slug.)

Append to `web-app/test/controllers/books/legacy_categories_controller_test.rb`:

```ruby
    test "a merged category slug redirects to the target's filter page" do
      target = categories(:books_france_location)
      ::Books::Category.create!(name: "France (country)", slug: "france-country", category_type: :location, deleted: true, merged_into: target)

      get "/genres/france-country"

      assert_redirected_to "/the-greatest/france/books"
    end

    test "a legacy id of a merged category redirects to the target" do
      target = categories(:books_france_location)
      merged = ::Books::Category.create!(name: "France (country)", category_type: :location, deleted: true, merged_into: target)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 777_001, new_id: merged.id)

      get "/genres/777001"

      assert_redirected_to "/the-greatest/france/books"
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/books/filter_params_test.rb test/controllers/books/ranked_items_controller_test.rb test/controllers/books/legacy_categories_controller_test.rb`
Expected: FAIL (`undefined method 'redirect?'`, 404 instead of 301).

- [ ] **Step 3: Implement**

In `web-app/app/lib/books/filter_params.rb`, change `Result` and `call`, and add the category resolver:

```ruby
    Result = Struct.new(:categories, :countries, :year_start, :year_end, :redirect, keyword_init: true) do
      # True when a category slug resolved through a merge or a pre-rename slug;
      # the page should 301 to the canonical URL built from `categories`.
      def redirect? = redirect == true
    end

    def call
      year = validated_year(@params[:year])
      categories, redirect = resolve_categories(@params[:category_id])

      Result.new(
        categories: categories,
        countries: resolve(Books::Country.all, @params[:country_id], MAX_COUNTRIES),
        year_start: year || validated_year(@params[:published_start]),
        year_end: year || validated_year(@params[:published_end]),
        redirect: redirect
      )
    end
```

and in `private`:

```ruby
    def resolve_categories(raw)
      slugs = parse_slugs(raw, MAX_CATEGORIES)
      return [[], false] if slugs.empty?

      active = Books::Category.active.where(slug: slugs).index_by(&:slug)
      missing = slugs - active.keys
      return [active.values.sort_by(&:slug), false] if missing.empty?

      replacements = missing.map { |slug| canonical_for(slug) || raise(ActiveRecord::RecordNotFound) }
      [(active.values + replacements).uniq.sort_by(&:slug), true]
    end

    # A merged category's own slug, or a slug the category had before a rename
    # (friendly_id history), resolved to the category a reader should land on.
    def canonical_for(slug)
      merged = Books::Category.merged.find_by(slug: slug)
      return merged.canonical if merged

      historical = FriendlyId::Slug.where(sluggable_type: "Category", slug: slug).order(id: :desc).first
      return nil if historical.nil?

      Books::Category.find_by(id: historical.sluggable_id)&.canonical
    end

    def parse_slugs(raw, max)
      slugs = raw.to_s.split(",").map(&:strip).reject(&:blank?).uniq
      raise ActiveRecord::RecordNotFound if slugs.size > max

      slugs
    end
```

and make the existing `resolve` use `parse_slugs`:

```ruby
    def resolve(scope, raw, max)
      slugs = parse_slugs(raw, max)
      return [] if slugs.empty?

      records = scope.where(slug: slugs).sort_by(&:slug)
      raise ActiveRecord::RecordNotFound if records.size != slugs.size

      records
    end
```

(`Books::Category.find_by(id:)` scopes by STI type, so a music category's historical slug never resolves here.)

In `web-app/app/controllers/books/ranked_items_controller.rb#index`, directly after `filters = Books::FilterParams.call(params)`:

```ruby
    # A merged or renamed category slug: send the visitor (and search engines)
    # to the canonical URL, keeping every other segment.
    if filters.redirect?
      return redirect_to(Books::FilterPath.call(
        categories: filters.categories,
        countries: @collection ? [] : filters.countries,
        year_start: filters.year_start,
        year_end: filters.year_end,
        page: params[:page],
        ranking_configuration: @ranking_configuration,
        collection: @collection
      ), status: :moved_permanently)
    end
```

Replace the private methods of `web-app/app/controllers/books/legacy_categories_controller.rb`:

```ruby
  private

  # Slug before id, matching legacy's Category.active.friendly.find AND because
  # 206 books categories have a purely numeric slug that must beat a
  # coincidentally equal legacy id. A merged category resolves to its target;
  # a category deleted without a merge still 404s, as on legacy.
  def find_category!
    category = find_by_slug || find_by_legacy_id
    category&.canonical || raise(ActiveRecord::RecordNotFound)
  end

  def find_by_slug
    Books::Category.active.find_by(slug: params[:id]) || Books::Category.merged.find_by(slug: params[:id])
  end

  # Category ids were not preserved by the migration, so a numeric id resolves
  # through LegacyIdMap. find_by(id:), never .find: Category uses friendly_id
  # with :finders, which resolves slugs before primary keys.
  def find_by_legacy_id
    return nil unless /\A\d+\z/.match?(params[:id])

    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: params[:id])
    new_id && Books::Category.find_by(id: new_id)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/books test/controllers/books`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/filter_params.rb app/controllers/books test/lib/books test/controllers/books
git add web-app/app/lib/books/filter_params.rb web-app/app/controllers/books web-app/test/lib/books web-app/test/controllers/books
git commit -m "Books filters: merged and renamed category slugs 301 to the canonical URL"
```

---

### Task 5: Saved searches and recommendation configs resolve merged categories

**Files:**
- Modify: `web-app/app/lib/search/books/search/criteria_clauses.rb:56-62,91-92`
- Modify: `web-app/app/lib/books/saved_search_filter_labels.rb:38-39,137-161`
- Test: `web-app/test/lib/search/books/search/criteria_clauses_test.rb`, `web-app/test/lib/books/saved_search_filter_labels_test.rb`

**Interfaces:**
- Consumes: Task 1 (`Category.replace_merged_ids`).

- [ ] **Step 1: Write the failing tests**

Read the top of `test/lib/search/books/search/criteria_clauses_test.rb` first and reuse its existing helper for building clauses from a raw criteria hash (it constructs `Books::SavedSearchCriteria.new(raw)` and calls the clauses builder). Append, adapting only the helper call name:

```ruby
    test "an included merged category id is replaced by its target" do
      target = categories(:books_france_location)
      merged = ::Books::Category.create!(name: "France (country)", category_type: :location, deleted: true, merged_into: target)

      clauses = filter_clauses_for("included_category_ids" => [merged.id], "genre_match_mode" => "any")

      assert_includes clauses, {terms: {category_ids: [target.id]}}
    end

    test "an excluded merged category id is replaced by its target" do
      target = categories(:books_france_location)
      merged = ::Books::Category.create!(name: "France (country)", category_type: :location, deleted: true, merged_into: target)

      clauses = must_not_clauses_for("excluded_category_ids" => [merged.id])

      assert_includes clauses, {terms: {category_ids: [target.id]}}
    end
```

Append to `test/lib/books/saved_search_filter_labels_test.rb`, using its existing way of building labels from a raw hash:

```ruby
    test "a merged category is labelled with its target's name" do
      target = categories(:books_france_location)
      merged = ::Books::Category.create!(name: "France (country)", category_type: :location, deleted: true, merged_into: target)

      group = labels_for("included_category_ids" => [merged.id]).find { |g| g.label == "Including genres" }

      assert_equal ["France"], group.values
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/search/books/search/criteria_clauses_test.rb test/lib/books/saved_search_filter_labels_test.rb`
Expected: FAIL (clause carries the merged id; label is "France (country)").

- [ ] **Step 3: Implement**

In `criteria_clauses.rb`:

```ruby
        # `all` means a book must carry every category, which one terms clause
        # cannot express -- terms is an OR. One term filter per id is the AND.
        # A merged category's id is swapped for its target: the merged row has
        # no links any more, so the stored id would otherwise match nothing.
        def category_clauses(criteria)
          ids = ::Category.replace_merged_ids(criteria.included_category_ids)
          return [] if ids.empty?
          return [{terms: {category_ids: ids}}] if criteria.genre_match_mode == :any

          ids.map { |id| {term: {category_ids: id}} }
        end
```

and in `must_not_clauses`:

```ruby
          categories = ::Category.replace_merged_ids(criteria.excluded_category_ids)
          clauses << {terms: {category_ids: categories}} if categories.any?
```

In `saved_search_filter_labels.rb`:

```ruby
        category_group("Including genres", ::Category.replace_merged_ids(criteria.included_category_ids), genre_note),
        category_group("Excluding genres", ::Category.replace_merged_ids(criteria.excluded_category_ids), nil),
```

and

```ruby
    def category_names
      @category_names ||= name_map(
        ::Category,
        ::Category.replace_merged_ids(criteria.included_category_ids | criteria.excluded_category_ids)
      )
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/search/books test/lib/books`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/search/books/search/criteria_clauses.rb app/lib/books/saved_search_filter_labels.rb
git add web-app/app/lib/search/books/search/criteria_clauses.rb web-app/app/lib/books/saved_search_filter_labels.rb web-app/test/lib
git commit -m "Saved searches: merged category ids resolve to their target"
```

---

### Task 6: Weekly sync follows merges; book merger keeps link source; sync reconciles ancestors

**Files:**
- Modify: `web-app/app/lib/services/books_migration/category_item_migrator.rb`
- Modify: `web-app/app/lib/services/books_migration/sync.rb:58-61`
- Modify: `web-app/app/lib/books/book/merger.rb:250-261`
- Test: `web-app/test/lib/services/books_migration/category_item_migrator_test.rb`, `web-app/test/lib/services/books_migration/sync_test.rb`, `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Consumes: Task 1 (`merged_into`, source enum), Task 2 (`AncestorReconciler`).
- Produces: sync step `"location_ancestors"` right after `"book_type_categories"`.

- [ ] **Step 1: Write the failing tests**

Append to `category_item_migrator_test.rb`:

```ruby
  test "a link to a category merged here lands on the merge target" do
    target = ::Books::Category.create!(name: "Target Cat")
    merged = make_category(8101, deleted: true)
    merged.update_columns(merged_into_id: target.id)
    book = ::Books::Book.create!(title: "Merged Link Book")

    result = run_migrator([{"id" => 11, "category_id" => 8101, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert CategoryItem.exists?(category_id: target.id, item_id: book.id, item_type: "Books::Book")
  end

  test "two legacy categories merged into one target on the same book do not collide" do
    target = ::Books::Category.create!(name: "Shared Target")
    [8102, 8103].each { |legacy_id| make_category(legacy_id, deleted: true).update_columns(merged_into_id: target.id) }
    book = ::Books::Book.create!(title: "Double Merge Book")

    result = run_migrator([
      {"id" => 12, "category_id" => 8102, "book_id" => book.id},
      {"id" => 13, "category_id" => 8103, "book_id" => book.id}
    ])

    assert result[:success], result[:error]
    assert_equal 1, CategoryItem.where(category_id: target.id, item_id: book.id).count
  end

  test "a link to a category merged into a target later deleted as junk is dropped" do
    junk = ::Books::Category.create!(name: "Junk Target", deleted: true)
    make_category(8104, deleted: true).update_columns(merged_into_id: junk.id)
    book = ::Books::Book.create!(title: "Junk Merge Book")

    assert_no_difference -> { CategoryItem.count } do
      result = run_migrator([{"id" => 14, "category_id" => 8104, "book_id" => book.id}])
      assert result[:success], result[:error]
    end
  end
```

Append to `sync_test.rb`:

```ruby
  test "reconciles inherited location links right after the category steps" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    labels = result.data[:steps].map(&:first)
    assert_operator labels.index("location_ancestors"), :>, labels.index("book_type_categories")
    assert_operator labels.index("location_ancestors"), :<, labels.index("countries")
  end
```

Append to `test/lib/books/book/merger_test.rb` (reuse its existing setup that builds `source`/`target` books and calls the merger; adapt variable names):

```ruby
  test "category links keep their source and inherited links are rebuilt on the survivor" do
    us = ::Books::Category.create!(name: "United States", category_type: :location)
    chicago = ::Books::Category.create!(name: "Chicago", category_type: :location, parent: us)
    CategoryItem.create!(category: chicago, item: @source, source: :admin)
    CategoryItem.create!(category: us, item: @source, source: :inherited)

    ::Books::Book::Merger.new(source: @source, target: @target).call

    assert CategoryItem.exists?(category: chicago, item: @target, source: :admin)
    assert CategoryItem.exists?(category: us, item: @target, source: :inherited)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/category_item_migrator_test.rb test/lib/services/books_migration/sync_test.rb test/lib/books/book/merger_test.rb`
Expected: FAIL (merged link dropped; no `location_ancestors` step; target link is `legacy`).

- [ ] **Step 3: Implement**

In `category_item_migrator.rb`, replace `preload_context`, rename the map in `build_rows`, add `flush`, and update the class comment's second sentence to say merged categories map to their target:

```ruby
      def preload_context
        # legacy id -> the category its links should land on: the category itself
        # when active, its merge target when merged here into a still-active
        # category. Categories deleted without a merge are absent (deliberate drop).
        @category_map = LegacyIdMap
          .where(model: "Books::Category")
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .joins("LEFT JOIN categories targets ON targets.id = categories.merged_into_id")
          .where("categories.deleted = false OR (targets.id IS NOT NULL AND targets.deleted = false)")
          .pluck(:legacy_id, Arel.sql("CASE WHEN categories.deleted THEN targets.id ELSE categories.id END"))
          .to_h
        # Every mapped legacy id, including categories soft-deleted, or deleted or
        # merged here since they were mapped: dropping their items is deliberate.
        # Only an id with no map entry at all is a missing prerequisite.
        @known_category_ids = LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id).to_set
      end

      def build_rows(attrs)
        legacy_category_id = attrs["category_id"]
        new_category_id = @category_map[legacy_category_id]
        return [{category_id: new_category_id, item_type: "Books::Book", item_id: attrs["book_id"]}] if new_category_id
        # No live mapping: a soft-deleted category is a deliberate drop
        # (legacy corruption); an unmigrated one is a missing prerequisite -> raise.
        return [] if @known_category_ids.include?(legacy_category_id)
        raise "no LegacyIdMap for Books::Category legacy_id=#{legacy_category_id} (run the categories migrator first)"
      end

      # Two legacy categories merged into one target can put the same
      # (category, book) pair twice in one batch, which upsert_all rejects.
      def flush(rows)
        super(rows.uniq { |row| row.values_at(:category_id, :item_type, :item_id) })
      end
```

In `sync.rb#steps`, insert after the `book_type_categories` line:

```ruby
          ["location_ancestors", -> { ::Categories::AncestorReconciler.call(item_ids: scope.book_ids.to_a) }],
```

In `books/book/merger.rb`, replace `merge_category_items`:

```ruby
      # Copy-or-skip rather than move: the source's own rows die with it. Direct
      # links carry their source across (an inherited row on the target is
      # upgraded); inherited links are not copied, the reconciler rebuilds them
      # from the survivor's direct locations. Counted like the other stats: only
      # when the target didn't already have this category (see @stats above).
      def merge_category_items
        count = 0
        source_book.category_items.direct.find_each do |category_item|
          existing = target_book.category_items.find_by(category_id: category_item.category_id)
          if existing.nil?
            target_book.category_items.create!(category_id: category_item.category_id, source: category_item.source)
            count += 1
          elsif existing.source_inherited?
            existing.update!(source: category_item.source)
          end
        end
        ::Categories::AncestorReconciler.call(item_ids: [target_book.id])
        @stats[:category_items] = count
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/books_migration test/lib/books/book`
Expected: PASS (the existing "last(9)" user-data step order test is unaffected; the new step sits in the catalog section).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books_migration app/lib/books/book/merger.rb
git add web-app/app/lib/services/books_migration web-app/app/lib/books/book/merger.rb web-app/test/lib
git commit -m "Sync follows category merges; book merger keeps link source; sync reconciles ancestors"
```

---

### Task 7: Admin — merge form, alternative names, protected delete, inherited-link upgrade

**Files:**
- Modify: `web-app/config/routes.rb` (books admin `resources :categories`, around line 1210)
- Modify: `web-app/app/controllers/admin/books/categories_controller.rb`
- Modify: `web-app/app/controllers/admin/categories_base_controller.rb:79-81`
- Modify: `web-app/app/components/admin/categories/form_component.html.erb`
- Modify: `web-app/app/views/admin/books/categories/show.html.erb`
- Create: `web-app/app/views/admin/books/categories/_merge_form.html.erb`
- Modify: `web-app/app/controllers/admin/category_items_controller.rb`
- Create (generator): `web-app/app/sidekiq/categories/reconcile_ancestors_job.rb`, `web-app/test/sidekiq/categories/reconcile_ancestors_job_test.rb`
- Test: `web-app/test/controllers/admin/books/categories_controller_test.rb`, `web-app/test/controllers/admin/category_items_controller_test.rb`

**Interfaces:**
- Consumes: Task 3 (`Categories::Merger`, `Categories::Deleter`, `Categories::Refused`), Task 2 (`AncestorReconciler`), Task 1 (source enum).
- Produces: route `merge_admin_books_category_path(category)` (POST, params `target_category_id`, `confirm_merge`); `Categories::ReconcileAncestorsJob` (no arguments; whole-catalog reconcile on the `:low` queue).

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/books/categories_controller_test.rb` (inside the class):

```ruby
      # Merge

      test "merge moves links and redirects to the target" do
        sign_in_as(@admin_user, stub_auth: true)
        target = categories(:books_france_location)
        source = ::Books::Category.create!(name: "France (country)", category_type: :location)
        CategoryItem.create!(category: source, item: books_books(:war_and_peace))

        post merge_admin_books_category_path(source), params: {target_category_id: target.id, confirm_merge: "1"}

        assert_redirected_to admin_books_category_path(target)
        assert_equal target, source.reload.merged_into
      end

      test "merge without confirmation changes nothing" do
        sign_in_as(@admin_user, stub_auth: true)
        source = ::Books::Category.create!(name: "France (country)", category_type: :location)

        post merge_admin_books_category_path(source), params: {target_category_id: categories(:books_france_location).id}

        assert_redirected_to admin_books_category_path(source)
        refute source.reload.deleted?
      end

      test "a refused merge redirects back with the reason" do
        sign_in_as(@admin_user, stub_auth: true)
        source = ::Books::Category.create!(name: "Lonely", category_type: :location)

        post merge_admin_books_category_path(source), params: {target_category_id: source.id, confirm_merge: "1"}

        assert_redirected_to admin_books_category_path(source)
        assert_match "itself", flash[:alert]
      end

      test "merge is forbidden to a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        source = ::Books::Category.create!(name: "France (country)", category_type: :location)

        post merge_admin_books_category_path(source), params: {target_category_id: categories(:books_france_location).id, confirm_merge: "1"}

        refute source.reload.deleted?
      end

      # Alternative names and delete

      test "update saves comma-separated alternative names" do
        sign_in_as(@admin_user, stub_auth: true)
        category = categories(:books_france_location)

        patch admin_books_category_path(category), params: {books_category: {alternative_names: "La France, République française"}}

        assert_equal ["La France", "République française"], category.reload.alternative_names
      end

      test "destroy removes the category's links" do
        sign_in_as(@admin_user, stub_auth: true)
        category = ::Books::Category.create!(name: "Doomed", category_type: :subject)
        CategoryItem.create!(category: category, item: books_books(:war_and_peace))

        delete admin_books_category_path(category)

        assert category.reload.deleted?
        assert_equal 0, CategoryItem.where(category: category).count
      end

      test "destroy refuses a protected category" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::Category.stubs(:protected_ids).returns([@category.id])

        delete admin_books_category_path(@category)

        refute @category.reload.deleted?
        assert_redirected_to admin_books_category_path(@category)
      end

      test "re-parenting a location rebuilds inherited links" do
        sign_in_as(@admin_user, stub_auth: true)
        us = ::Books::Category.create!(name: "United States", category_type: :location)
        chicago = ::Books::Category.create!(name: "Chicago", category_type: :location)
        book = books_books(:war_and_peace)
        CategoryItem.create!(category: chicago, item: book)

        patch admin_books_category_path(chicago), params: {books_category: {parent_id: us.id}}

        assert CategoryItem.exists?(category: us, item: book, source: :inherited)
      end
```

Create the job with the generator, then replace its test with the one below:

```bash
bin/rails generate sidekiq:job categories/reconcile_ancestors
```

`test/sidekiq/categories/reconcile_ancestors_job_test.rb`:

```ruby
require "test_helper"

module Categories
  class ReconcileAncestorsJobTest < ActiveSupport::TestCase
    test "reconciles every book" do
      Categories::AncestorReconciler.expects(:call).with(no_args).returns(Categories::AncestorReconciler::Result.new(success?: true, data: {added: 0, removed: 0}, errors: []))

      Categories::ReconcileAncestorsJob.new.perform
    end
  end
end
```

Append to the **books** test class in `test/controllers/admin/category_items_controller_test.rb` (the class whose setup uses `books_books(:war_and_peace)`):

```ruby
    test "adding a category the book already has as inherited upgrades it to admin" do
      us = ::Books::Category.create!(name: "United States", category_type: :location)
      CategoryItem.create!(category: us, item: @book, source: :inherited)

      assert_no_difference "CategoryItem.count" do
        post admin_books_book_category_items_path(@book), params: {category_item: {category_id: us.id}}, as: :turbo_stream
      end

      assert_response :success
      assert CategoryItem.exists?(category: us, item: @book, source: :admin)
    end

    test "adding a location adds its ancestors as inherited" do
      us = ::Books::Category.create!(name: "United States", category_type: :location)
      chicago = ::Books::Category.create!(name: "Chicago", category_type: :location, parent: us)

      post admin_books_book_category_items_path(@book), params: {category_item: {category_id: chicago.id}}, as: :turbo_stream

      assert CategoryItem.exists?(category: chicago, item: @book, source: :admin)
      assert CategoryItem.exists?(category: us, item: @book, source: :inherited)
    end

    test "removing a location removes the ancestors it justified" do
      us = ::Books::Category.create!(name: "United States", category_type: :location)
      chicago = ::Books::Category.create!(name: "Chicago", category_type: :location, parent: us)
      link = CategoryItem.create!(category: chicago, item: @book, source: :admin)
      Categories::AncestorReconciler.call(item_ids: [@book.id])

      delete admin_category_item_path(link), as: :turbo_stream

      refute CategoryItem.exists?(category: us, item: @book)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/admin/books/categories_controller_test.rb test/controllers/admin/category_items_controller_test.rb test/sidekiq/categories`
Expected: FAIL (`undefined method 'merge_admin_books_category_path'`, uniqueness error on the inherited upgrade, no inherited rows).

- [ ] **Step 3: Implement**

`config/routes.rb`, the books admin categories block (the one just before `resources :lists do ... wizard`):

```ruby
      resources :categories do
        collection do
          get :search
        end
        member do
          post :merge
        end
      end
```

`app/controllers/admin/categories_base_controller.rb`, replace `category_params`:

```ruby
  # alternative_names arrives as one comma-separated text field.
  def category_params
    permitted = params.require(param_key).permit(:name, :description, :category_type, :parent_id, :alternative_names)
    if permitted.key?(:alternative_names)
      permitted[:alternative_names] = permitted[:alternative_names].to_s.split(",").map(&:strip).reject(&:blank?)
    end
    permitted
  end
```

`app/components/admin/categories/form_component.html.erb`: after the Name field's closing `</div>` (inside the same grid), add:

```erb
        <!-- Alternative names -->
        <div class="md:col-span-2">
          <%= f.label :alternative_names, class: "label" do %>
            <span class="font-semibold">Alternative names</span>
          <% end %>
          <%= f.text_field :alternative_names,
              value: category.alternative_names.join(", "),
              class: "input w-full",
              placeholder: "Old names and spellings, separated by commas" %>
        </div>
```

`app/controllers/admin/books/categories_controller.rb`, add above `protected`:

```ruby
  before_action :set_category, only: [:merge]
  before_action :authorize_merge, only: [:merge]

  # Merging deletes the source, so it needs the destroy permission.
  def merge
    target = ::Books::Category.active.find_by(id: params[:target_category_id])
    return redirect_to(admin_books_category_path(@category), alert: "Pick a category to merge into.") if target.nil?
    return redirect_to(admin_books_category_path(@category), alert: "Tick the box to confirm the merge.") unless params[:confirm_merge] == "1"

    ::Categories::Merger.new(category: @category, category_to_merge_with: target).merge
    redirect_to admin_books_category_path(target), notice: "Merged \"#{@category.name}\" into \"#{target.name}\"."
  rescue ::Categories::Refused => e
    redirect_to admin_books_category_path(@category), alert: e.message
  end

  # A location moved to a new parent changes the inherited links of every
  # book under it; the whole-catalog reconcile is two statements but takes
  # seconds in production, so it runs in the background.
  def update
    parent_before = @category.parent_id
    if @category.update(category_params)
      ::Categories::ReconcileAncestorsJob.perform_async if @category.location? && @category.parent_id != parent_before
      redirect_to admin_books_category_path(@category), notice: "Category updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Books deletes through Categories::Deleter so the links go too and the
  # book-type categories are refused. Music and games keep the base behaviour.
  def destroy
    ::Categories::Deleter.new(category: @category, soft: true).delete
    redirect_to categories_path, notice: "Category deleted successfully."
  rescue ::Categories::Refused => e
    redirect_to admin_books_category_path(@category), alert: e.message
  end
```

and a `private` section at the bottom of the class:

```ruby
  private

  def authorize_merge
    authorize @category, :destroy?
  end
```

(`set_category` is defined in the base controller; the subclass's extra `before_action :set_category, only: [:merge]` adds `merge` to it.)

`app/sidekiq/categories/reconcile_ancestors_job.rb` (keep the generator's `include Sidekiq::Job`):

```ruby
# Whole-catalog inherited-link reconcile after an admin re-parents a location.
class Categories::ReconcileAncestorsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform
    ::Categories::AncestorReconciler.call
  end
end
```

`app/views/admin/books/categories/show.html.erb`:

```erb
<% content_for :title, @category.name %>
<%= render Admin::Categories::ShowComponent.new(category: @category, domain_config: domain_config, stats: @stats) %>
<%= render "admin/books/categories/merge_form", category: @category %>
```

`app/views/admin/books/categories/_merge_form.html.erb`:

```erb
<%# Merging moves every book to the chosen category, adds this name to its
    alternative names, and deletes this one. Old URLs redirect to the target. %>
<div class="card bg-base-100 shadow-xl mt-6" data-testid="merge-category">
  <div class="card-body">
    <h2 class="card-title">Merge into another category</h2>
    <%= form_with url: merge_admin_books_category_path(category), method: :post, class: "space-y-4" do %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend">Merge "<%= category.name %>" into</legend>
        <%= render AutocompleteComponent.new(
              name: "target_category_id",
              url: search_admin_books_categories_path,
              placeholder: "Search for the category to keep...",
              required: true
            ) %>
      </fieldset>
      <label class="label">
        <%= check_box_tag :confirm_merge, "1", false, class: "checkbox" %>
        This deletes "<%= category.name %>" and moves its <%= category.item_count %> links.
      </label>
      <%= submit_tag "Merge", class: "btn btn-warning" %>
    <% end %>
  </div>
</div>
```

`app/controllers/admin/category_items_controller.rb`: in `create`, delete the line `@category_item = @item.category_items.build(category_item_params)` and change `if @category_item.save` to:

```ruby
    if save_category_item
      reconcile_ancestors(@item)
```

(the existing `@item.reload` and both `respond_to` blocks stay as they are). In `destroy`, directly after `@category_item.destroy!`, add `reconcile_ancestors(@item)`. Add private methods:

```ruby
  # An admin pick is a direct link. If the item already carries the category
  # only as an inherited ancestor, upgrade that row instead of failing the
  # uniqueness check.
  def save_category_item
    existing = @item.category_items.find_by(category_id: category_item_params[:category_id])
    if existing&.source_inherited?
      @category_item = existing
      return existing.update(source: :admin)
    end

    @category_item = @item.category_items.build(category_item_params.merge(source: :admin))
    @category_item.save
  end

  def reconcile_ancestors(item)
    ::Categories::AncestorReconciler.call(item_ids: [item.id]) if item.is_a?(::Books::Book)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/controllers/admin test/sidekiq/categories`
Expected: PASS (the music category-item tests are unchanged: `reconcile_ancestors` is a no-op for non-books items; Sidekiq runs inline in tests, so the re-parent test sees the job's effect).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/controllers/admin test/controllers/admin
git add web-app/config/routes.rb web-app/app/controllers/admin web-app/app/components/admin/categories web-app/app/views/admin/books/categories web-app/app/sidekiq/categories web-app/test/controllers/admin web-app/test/sidekiq/categories
git commit -m "Admin: merge books categories, edit alternative names, safe delete, inherited upgrade"
```

---

### Task 8: Book page shows direct locations as breadcrumbs

**Files:**
- Create: `web-app/app/lib/books/location_trails.rb`
- Modify: `web-app/app/controllers/books/books_controller.rb:38-43`
- Modify: `web-app/app/views/books/books/show.html.erb:107-130`
- Test: `web-app/test/lib/books/location_trails_test.rb`, `web-app/test/controllers/books/books_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 (`MAX_DEPTH`, `CategoryItem.direct`).
- Produces: `Books::LocationTrails.call(categories) → Hash{category_id => Array<Books::Category>}` (the category first, then its live ancestors; the root dropped when the trail has more than one element).

- [ ] **Step 1: Write the failing tests**

`test/lib/books/location_trails_test.rb`:

```ruby
require "test_helper"

module Books
  class LocationTrailsTest < ActiveSupport::TestCase
    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "builds each trail up to, but not including, the root" do
      na = location("North America")
      us = location("United States", parent: na)
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)

      assert_equal [chicago, il, us], LocationTrails.call([chicago])[chicago.id]
    end

    test "a root on its own keeps itself" do
      france = location("France")
      assert_equal [france], LocationTrails.call([france])[france.id]
    end

    test "a soft-deleted ancestor ends the trail without dropping the last live place" do
      us = location("United States")
      il = location("Illinois", parent: us)
      chicago = location("Chicago", parent: il)
      us.update!(deleted: true)

      assert_equal [chicago, il], LocationTrails.call([chicago])[chicago.id]
    end
  end
end
```

Append to `test/controllers/books/books_controller_test.rb` (inside the class; it already sets the books host):

```ruby
    test "the location group shows each direct location once, as a trail" do
      book = books_books(:war_and_peace)
      book.category_items.destroy_all
      na = ::Books::Category.create!(name: "North America", category_type: :location)
      us = ::Books::Category.create!(name: "United States", category_type: :location, parent: na)
      chicago = ::Books::Category.create!(name: "Chicago", category_type: :location, parent: us)
      CategoryItem.create!(category: chicago, item: book)
      Categories::AncestorReconciler.call(item_ids: [book.id])

      get "/book/#{book.slug}"

      assert_response :success
      assert_select "[data-testid='location-trail']", 1
    end
```

(If the other tests in this file reach the book page another way, use theirs.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/books/location_trails_test.rb test/controllers/books/books_controller_test.rb`
Expected: FAIL (`uninitialized constant Books::LocationTrails`; no `location-trail` element).

- [ ] **Step 3: Implement**

`app/lib/books/location_trails.rb`:

```ruby
# frozen_string_literal: true

module Books
  # "Chicago, Illinois, United States" for the book page (spec §3.4): each
  # direct location with its live ancestors, nearest first. The root (a
  # continent, or Fictional Location) is dropped when there is anything below
  # it -- every American book would otherwise end in "North America".
  # One query per tree level; trees are shallow.
  class LocationTrails
    def self.call(categories)
      new(categories).call
    end

    def initialize(categories)
      @categories = categories
    end

    def call
      by_id = load_ancestors
      @categories.to_h do |category|
        trail = [category]
        node = category
        while (parent = by_id[node.parent_id]) && trail.size < ::Books::Category::MAX_DEPTH
          trail << parent
          node = parent
        end
        trail.pop if trail.size > 1 && trail.last.parent_id.nil?
        [category.id, trail]
      end
    end

    private

    def load_ancestors
      by_id = @categories.index_by(&:id)
      frontier = @categories.filter_map(&:parent_id)
      ::Books::Category::MAX_DEPTH.times do
        missing = frontier.uniq - by_id.keys
        break if missing.empty?

        found = ::Books::Category.active.where(id: missing).to_a
        found.each { |category| by_id[category.id] = category }
        frontier = found.filter_map(&:parent_id)
      end
      by_id
    end
  end
end
```

In `app/controllers/books/books_controller.rb`, replace the `@categories_by_type = ...` statement (and its comment) with:

```ruby
    # Locations show only the places the book is linked to directly; their
    # inherited ancestors appear inside each trail instead of as badges.
    direct_ids = @book.category_items.direct.pluck(:category_id).to_set
    shown = @book.categories.active.reject { |category| category.location? && !direct_ids.include?(category.id) }
    @location_trails = Books::LocationTrails.call(shown.select(&:location?))
    # An array of [category_type, categories] pairs rather than a Hash -- the view
    # only iterates it, and an array is the only way to pin the order.
    @categories_by_type = shown
      .sort_by { |category| category.name.to_s.downcase }
      .group_by(&:category_type)
      .sort_by { |type, _| [CATEGORY_TYPE_ORDER.index(type) || CATEGORY_TYPE_ORDER.size, type.to_s] }
```

In `app/views/books/books/show.html.erb`, replace the inner `<% categories.each do |category| %> ... <% end %>` loop with:

```erb
                <% categories.each do |category| %>
                  <% if category_type == "location" %>
                    <span class="badge badge-ghost h-auto py-1" data-testid="location-trail">
                      <% @location_trails.fetch(category.id, [category]).each_with_index do |place, index| %>
                        <%= ", " if index.positive? %><%= link_to place.name,
                              Books::FilterPath.call(categories: [place], ranking_configuration: @ranking_configuration),
                              class: "hover:underline" %>
                      <% end %>
                    </span>
                  <% else %>
                    <%= link_to category.name,
                          Books::FilterPath.call(categories: [category], ranking_configuration: @ranking_configuration),
                          class: "badge badge-ghost hover:badge-primary" %>
                  <% end %>
                <% end %>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/books/location_trails_test.rb test/controllers/books`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/location_trails.rb app/controllers/books/books_controller.rb test/lib/books test/controllers/books
git add web-app/app/lib/books/location_trails.rb web-app/app/controllers/books/books_controller.rb web-app/app/views/books/books/show.html.erb web-app/test
git commit -m "Book page: direct locations rendered as linked breadcrumbs"
```

---

### Task 9: Config, browse threshold, filter-search threshold and alternative-name search

**Files:**
- Create: `web-app/config/initializers/categories.rb`
- Modify: `web-app/app/lib/books/browse_query.rb:10-25`
- Modify: `web-app/app/lib/category_search_query.rb`
- Modify: `web-app/app/controllers/books/filters_controller.rb:49-50`
- Test: `web-app/test/lib/books/browse_query_test.rb`, `web-app/test/lib/category_search_query_test.rb`, `web-app/test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Produces: `Rails.configuration.x.books.browse_min_category_books`; `Rails.configuration.x.categories_cleanup.{head_min_links, tail_batch_size, max_direct_locations, sample_titles, estimated_cost_per_call, max_unforced_cost}`; `CategorySearchQuery.call(query, scope:, types: [], limit:, min_items: 0, min_items_types: [])`.

- [ ] **Step 1: Write the failing tests**

Read `test/lib/books/browse_query_test.rb` first; it already seeds ranked books for a ranking configuration. Append, using its existing helper/ivar for ranking a book (adapt the names `rank_book` and `@ranking_configuration` to what the file uses):

```ruby
    test "subject and location cards need the minimum number of ranked books; genres do not" do
      Rails.configuration.x.books.stubs(:browse_min_category_books).returns(2)
      rare_place = ::Books::Category.create!(name: "Kilwa", category_type: :location)
      rare_genre = ::Books::Category.create!(name: "Tiny Genre", category_type: :genre)
      book = books_books(:war_and_peace)
      rank_book(book)
      CategoryItem.create!(category: rare_place, item: book)
      CategoryItem.create!(category: rare_genre, item: book)

      ids = Books::BrowseQuery.categories(ranking_configuration: @ranking_configuration).map(&:id)

      refute_includes ids, rare_place.id
      assert_includes ids, rare_genre.id
    end
```

Append to `test/lib/category_search_query_test.rb`:

```ruby
  test "matches alternative names" do
    kolkata = ::Books::Category.create!(name: "Kolkata", category_type: :location, alternative_names: ["Calcutta"])

    assert_includes CategorySearchQuery.call("calcutta", scope: ::Books::Category), kolkata
  end

  test "min_items hides small categories of the listed types only" do
    small_place = ::Books::Category.create!(name: "Smallville", category_type: :location, item_count: 1)
    small_genre = ::Books::Category.create!(name: "Smallgenre", category_type: :genre, item_count: 1)

    results = CategorySearchQuery.call("small", scope: ::Books::Category, min_items: 5, min_items_types: %w[location subject])

    refute_includes results, small_place
    assert_includes results, small_genre
  end
```

Append to `test/controllers/books/filters_controller_test.rb`, requesting the category pane's search the same way this file's existing category-search tests do (path and `q` param):

```ruby
  test "the public category search hides locations under the browse minimum" do
    ::Books::Category.create!(name: "Zzyzx Springs", category_type: :location, item_count: 1)

    # Same request shape as this file's existing category-search tests, with q: "Zzyzx".
    get books_filters_categories_path(q: "Zzyzx")

    assert_response :success
    assert_no_match "Zzyzx Springs", response.body
  end
```

(Replace `books_filters_categories_path` with the route helper the existing tests use. The assertion is behavioural — the row is absent — not markup.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/books/browse_query_test.rb test/lib/category_search_query_test.rb test/controllers/books/filters_controller_test.rb`
Expected: FAIL (`undefined method 'browse_min_category_books'`, `unknown keyword: :min_items`).

- [ ] **Step 3: Implement**

`config/initializers/categories.rb`:

```ruby
# frozen_string_literal: true

# Books subject/location settings. Rails config, not an admin UI.
# Spec: docs/superpowers/specs/2026-10-11-books-category-cleanup-design.md
Rails.application.configure do
  # Subject and location categories with fewer ranked books than this are not
  # listed on browse pages or in the public filter search (spec §6). Their
  # pages still render; genres are exempt.
  config.x.books.browse_min_category_books = 5

  # Cleanup pipeline (spec §4).
  # Categories with at least this many direct links are the "head": they go to
  # the AI one per call and form the known vocabulary in every prompt.
  config.x.categories_cleanup.head_min_links = 20
  # Tail batch size. Stays 1 until categories:cleanup:calibrate shows a larger
  # size agrees with one-at-a-time answers at least 97% of the time.
  config.x.categories_cleanup.tail_batch_size = 1
  # Books with more direct locations than this get the trim pass (spec §5).
  config.x.categories_cleanup.max_direct_locations = 15
  # Sample books shown to the model per category.
  config.x.categories_cleanup.sample_titles = 5
  # Rough cost of one standard-role flex call with a cached system prompt, in
  # USD (2026-09 research prices; re-check before a production run), and the
  # estimate above which a propose stage needs FORCE=1.
  config.x.categories_cleanup.estimated_cost_per_call = 0.004
  config.x.categories_cleanup.max_unforced_cost = 50
end
```

`app/lib/books/browse_query.rb`, in `self.categories`, immediately before `order_by(scope, sort, "categories.name")`:

```ruby
      # Subject and location cards need a minimum of ranked books (spec §6);
      # one-book categories exist for similarity, not as landing pages.
      scope = scope.where(
        "categories.category_type = :genre OR ranked_counts.ranked_count >= :min",
        genre: ::Category.category_types.fetch("genre"),
        min: Rails.configuration.x.books.browse_min_category_books
      )
```

`app/lib/category_search_query.rb`, replace `self.call`, `initialize` and `call`, and add the two private methods (merge them into an existing `private` section if there is one):

```ruby
  def self.call(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [])
    new(query, scope: scope, types: types, limit: limit, min_items: min_items, min_items_types: min_items_types).call
  end

  def initialize(query, scope:, types: [], limit: DEFAULT_LIMIT, min_items: 0, min_items_types: [])
    @query = query.to_s.strip
    @scope = scope
    @types = Array(types)
    @limit = limit
    @min_items = min_items.to_i
    @min_items_types = Array(min_items_types).map(&:to_s)
  end

  def call
    return [] if @query.blank?

    relation = @scope.active.where(name_or_alias_sql, pattern: "%#{@scope.sanitize_sql_like(@query)}%")
    relation = relation.where(category_type: @types) if @types.any?
    relation = apply_minimum(relation)

    relation.order(item_count: :desc, name: :asc).limit(@limit).to_a
  end

  private

  # Old names and spellings live in alternative_names, so "Calcutta" finds Kolkata.
  def name_or_alias_sql
    "categories.name ILIKE :pattern OR EXISTS (SELECT 1 FROM unnest(categories.alternative_names) AS alt WHERE alt ILIKE :pattern)"
  end

  def apply_minimum(relation)
    return relation if @min_items <= 0 || @min_items_types.empty?

    type_values = @min_items_types.map { |type| ::Category.category_types.fetch(type) }
    relation.where("categories.category_type NOT IN (:types) OR categories.item_count >= :min", types: type_values, min: @min_items)
  end
```

`app/controllers/books/filters_controller.rb`, the category branch:

```ruby
      CategorySearchQuery.call(
        params[:q],
        scope: ::Books::Category,
        min_items: Rails.configuration.x.books.browse_min_category_books,
        min_items_types: %w[location subject]
      )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/books/browse_query_test.rb test/lib/category_search_query_test.rb test/controllers/books/filters_controller_test.rb test/controllers/admin`
Expected: PASS (the admin search passes no minimum).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb config/initializers/categories.rb app/lib/books/browse_query.rb app/lib/category_search_query.rb app/controllers/books/filters_controller.rb
git add web-app/config/initializers/categories.rb web-app/app/lib/books/browse_query.rb web-app/app/lib/category_search_query.rb web-app/app/controllers/books/filters_controller.rb web-app/test
git commit -m "Books: browse and filter-search minimum for subjects/locations; alias search"
```

---

### Task 10: `CategoryCleanupDecision` model and `NameNormalizer`

**Files:**
- Create (generator): `web-app/app/models/category_cleanup_decision.rb`, `web-app/db/migrate/<ts>_create_category_cleanup_decisions.rb`, `web-app/test/models/category_cleanup_decision_test.rb`, `web-app/test/fixtures/category_cleanup_decisions.yml`
- Create: `web-app/app/lib/services/category_cleanup/name_normalizer.rb`
- Test: `web-app/test/lib/services/category_cleanup/name_normalizer_test.rb`

**Interfaces:**
- Produces: `CategoryCleanupDecision` with `STAGES`, `SNAPSHOT_FIELDS`, enums `action` (`prefix: true`: `action_keep?`, scope `action_merge`, …), `decided_by` (`prefix: true`), `status` (`proposed rejected applied stale failed`), scopes `for_run(run)`, `terminal`, class method `snapshot_of(category) → Hash`; `Services::CategoryCleanup::NameNormalizer.clean(name) → String`, `.twin_key(name) → String`, `.target_name(name) → String | :delete`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model CategoryCleanupDecision category:references run:string stage:string action:integer decided_by:integer status:integer new_name:string new_category_type:integer place_kind:string ambiguous:boolean reason:text category_snapshot:jsonb error:text
```

Replace the generated migration's `create_table` block with:

```ruby
    create_table :category_cleanup_decisions do |t|
      t.references :category, null: false, foreign_key: true
      t.string :run, null: false
      t.string :stage, null: false
      t.integer :action, null: false
      t.integer :decided_by, null: false
      t.integer :status, null: false, default: 0
      t.string :new_name
      t.references :target_category, foreign_key: {to_table: :categories}
      t.string :parent_chain, array: true, null: false, default: []
      t.integer :new_category_type
      t.string :place_kind
      t.boolean :ambiguous, null: false, default: false
      t.text :reason
      t.references :ai_chat, foreign_key: true
      t.jsonb :category_snapshot, null: false, default: {}
      t.text :error
      t.timestamps
    end
    add_index :category_cleanup_decisions, [:run, :status]
    add_index :category_cleanup_decisions, [:run, :stage]
    add_index :category_cleanup_decisions, [:run, :category_id]
```

Replace the generated `test/fixtures/category_cleanup_decisions.yml` with one comment line, `# Tests build decisions explicitly.` — the generator's `one:`/`two:` rows reference categories that don't exist and would break every test.

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && bin/rails db:test:prepare`

- [ ] **Step 2: Write the failing tests**

Replace `test/models/category_cleanup_decision_test.rb` with:

```ruby
require "test_helper"

class CategoryCleanupDecisionTest < ActiveSupport::TestCase
  def decision(**attrs)
    CategoryCleanupDecision.new({category: categories(:books_france_location), run: "test", stage: "rules", action: :keep, decided_by: :rule}.merge(attrs))
  end

  test "a keep decision is valid and defaults to proposed" do
    record = decision
    assert record.valid?
    assert record.proposed?
  end

  test "a proposed rename needs a new name, a merge a target, a set_parent a chain, a retype a type" do
    refute decision(action: :rename).valid?
    refute decision(action: :merge).valid?
    refute decision(action: :set_parent).valid?
    refute decision(action: :retype).valid?
  end

  test "a failed decision may lack the fields a proposed one needs" do
    assert decision(action: :merge, status: :failed, error: "merge_into matches nothing").valid?
  end

  test "stage must be a known stage" do
    refute decision(stage: "whenever").valid?
  end

  test "terminal covers merge, retype and delete" do
    category = categories(:books_france_location)
    merge = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :merge, decided_by: :rule, target_category: categories(:books_american_location))
    keep = CategoryCleanupDecision.create!(category: category, run: "t", stage: "rules", action: :keep, decided_by: :rule)

    assert_includes CategoryCleanupDecision.terminal, merge
    refute_includes CategoryCleanupDecision.terminal, keep
  end

  test "snapshot_of records the fields apply compares" do
    snapshot = CategoryCleanupDecision.snapshot_of(categories(:books_france_location))
    assert_equal %w[category_type deleted item_count name parent_id], snapshot.keys.sort
    assert_equal "France", snapshot["name"]
    assert_equal "location", snapshot["category_type"]
  end
end
```

`test/lib/services/category_cleanup/name_normalizer_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class NameNormalizerTest < ActiveSupport::TestCase
      # Real names from the dev database, 2026-10-11.
      TARGETS = {
        "Japan (" => "Japan",
        "United Kingdom (" => "United Kingdom",
        "Podgorica (Montenegro" => "Podgorica",
        "61)" => :delete,
        "2014)" => :delete,
        "(" => :delete,
        "Self‑discovery" => "Self-discovery",
        "  Massachusetts" => "Massachusetts",
        "England," => "England",
        "secrets" => "Secrets",
        "isolation and loneliness" => "Isolation and Loneliness",
        "Death & Grief" => "Death and Grief",
        "Washington D.C." => "Washington D.C.",
        "Kolkata (Calcutta)" => "Kolkata (Calcutta)",
        "9/11" => "9/11",
        "iPhone culture" => "iPhone Culture"
      }.freeze

      TARGETS.each do |input, expected|
        test "target_name(#{input.inspect}) is #{expected.inspect}" do
          assert_equal expected, NameNormalizer.target_name(input)
        end
      end

      test "twins share a key across case and punctuation" do
        assert_equal NameNormalizer.twin_key("Washington D.C."), NameNormalizer.twin_key("Washington, D.C.")
        assert_equal NameNormalizer.twin_key("Decision-making"), NameNormalizer.twin_key("Decision making")
        assert_equal NameNormalizer.twin_key("Women's Studies"), NameNormalizer.twin_key("Womens Studies")
        refute_equal NameNormalizer.twin_key("Georgia"), NameNormalizer.twin_key("Georgia (U.S. state)")
      end

      test "clean maps typographic dashes and quotes to ASCII" do
        assert_equal "Women's Studies", NameNormalizer.clean("Women’s Studies")
        assert_equal "Self-discovery", NameNormalizer.clean("Self‑discovery")
      end
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/category_cleanup_decision_test.rb test/lib/services/category_cleanup/name_normalizer_test.rb`
Expected: FAIL (enums and validations missing; `uninitialized constant Services::CategoryCleanup`).

- [ ] **Step 4: Implement**

`app/models/category_cleanup_decision.rb` (keep the annotation comment annotaterb writes at the top):

```ruby
# One proposed change to a books category from the cleanup pipeline
# (spec §4.1). Written by Services::CategoryCleanup::RulePass and ::AiPass,
# reviewed through the report, executed by ::Applier. Validations and scopes
# only; the logic lives in app/lib/services/category_cleanup/.
class CategoryCleanupDecision < ApplicationRecord
  STAGES = %w[rules locations_head locations_tail subjects_head subjects_tail sync apply].freeze
  SNAPSHOT_FIELDS = %w[name category_type parent_id deleted item_count].freeze

  belongs_to :category
  belongs_to :target_category, class_name: "Category", optional: true
  belongs_to :ai_chat, optional: true

  # prefix: true -- unprefixed `delete` and `merge` scopes collide with Active Record.
  enum :action, {keep: 0, rename: 1, merge: 2, retype: 3, set_parent: 4, delete: 5}, prefix: true
  enum :decided_by, {rule: 0, ai: 1}, prefix: true
  enum :status, {proposed: 0, rejected: 1, applied: 2, stale: 3, failed: 4}

  validates :run, presence: true
  validates :stage, inclusion: {in: STAGES}
  validates :new_name, presence: true, if: -> { proposed? && action_rename? }
  validates :target_category, presence: true, if: -> { proposed? && action_merge? }
  validates :parent_chain, presence: true, if: -> { proposed? && action_set_parent? }
  validates :new_category_type, presence: true, if: -> { proposed? && action_retype? }

  scope :for_run, ->(run) { where(run: run) }
  # Decisions after which the category no longer exists under its own name and type.
  scope :terminal, -> { where(action: %i[merge retype delete]) }

  def self.snapshot_of(category)
    category.attributes.slice(*SNAPSHOT_FIELDS).merge("category_type" => category.category_type)
  end
end
```

`app/lib/services/category_cleanup/name_normalizer.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Deterministic name repair for the rules pass (spec §4.2 step 1) and the
    # comparison key every stage uses to tell whether two names are the same.
    module NameNormalizer
      DASHES = /[‐-―−]/
      SINGLE_QUOTES = /[‘’‚‛′]/
      DOUBLE_QUOTES = /[“”„‟″]/
      MINOR_WORDS = %w[a an and as at but by for in nor of on or the to with].freeze

      module_function

      def clean(name)
        name.to_s.unicode_normalize(:nfkc)
          .gsub(DASHES, "-").gsub(SINGLE_QUOTES, "'").gsub(DOUBLE_QUOTES, '"')
          .gsub(/\s+/, " ").strip
      end

      # Case, spacing and punctuation-insensitive. "&" is NOT folded into "and"
      # here; target_name rewrites "&" first so those twins meet.
      def twin_key(name)
        clean(name).downcase.gsub(/[^[:alnum:]]/, "")
      end

      # The name a category should have, or :delete for a bracket fragment with
      # no letters ("61)", "2014)"). Names with balanced brackets and no letters
      # ("9/11") are left for the AI.
      def target_name(name)
        cleaned = clean(name).sub(/[\s,;:]+\z/, "")
        repaired = repair_brackets(cleaned)
        return :delete if repaired == :delete || repaired.blank?

        repaired = repaired.gsub(/\s*&\s*/, " and ")
        repaired = title_case(repaired) if repaired.match?(/\A[[:lower:]]/)
        repaired
      end

      def repair_brackets(name)
        opens = name.count("(")
        closes = name.count(")")
        return name if opens == closes

        remainder = (opens > closes) ? name[0...name.rindex("(")] : name.sub(/\)\s*\z/, "")
        remainder = remainder.strip
        remainder.match?(/[[:alpha:]]/) ? remainder : :delete
      end

      # Capitalises all-lowercase words, keeps minor words lowercase after the
      # first, and leaves mixed-case words ("iPhone") alone.
      def title_case(name)
        name.split(" ").each_with_index.map do |word, index|
          if index.positive? && MINOR_WORDS.include?(word)
            word
          elsif word.match?(/\A[[:lower:]]+\z/)
            word.capitalize
          else
            word
          end
        end.join(" ")
      end
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/category_cleanup_decision_test.rb test/lib/services/category_cleanup && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!" (new `app/lib/services/category_cleanup` directory; eager loading is off in test, so zeitwerk:check is the guard).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/models/category_cleanup_decision.rb app/lib/services/category_cleanup test/models test/lib/services/category_cleanup
git add web-app/db web-app/app/models/category_cleanup_decision.rb web-app/app/lib/services/category_cleanup web-app/test
git commit -m "Category cleanup: decisions table and name normalizer"
```

---

### Task 11: Rules pass

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/rule_pass.rb`
- Test: `web-app/test/lib/services/category_cleanup/rule_pass_test.rb`

**Interfaces:**
- Consumes: Task 10 (`CategoryCleanupDecision`, `NameNormalizer`), Task 1 (`protected_ids`).
- Produces: `Services::CategoryCleanup::RulePass.call(run:, only_ids: nil, stage: "rules") → Result` with `data: {decisions: Integer, by_action: Hash{String => Integer}}`; `RulePass::TYPES = %w[location subject]`.

- [ ] **Step 1: Write the failing test**

`test/lib/services/category_cleanup/rule_pass_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class RulePassTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
      end

      def category(name, type: :location, links: 1, alternative_names: [])
        record = ::Books::Category.create!(name: name, category_type: type, alternative_names: alternative_names)
        [@book, @other].first(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def decisions_for(record)
        CategoryCleanupDecision.where(run: "r1", category: record)
      end

      test "merges case and punctuation twins into the most-linked spelling" do
        winner = category("Washington D.C.", links: 2)
        loser = category("Washington, D.C.", links: 1)

        RulePass.call(run: "r1")

        merge = decisions_for(loser).sole
        assert merge.action_merge?
        assert_equal winner.id, merge.target_category_id
        assert decisions_for(winner).none?
      end

      test "repairs a truncated bracket into a merge with the clean name" do
        japan = category("Japan", links: 2)
        broken = category("Japan (", links: 1)

        RulePass.call(run: "r1")

        assert_equal japan.id, decisions_for(broken).sole.target_category_id
      end

      test "renames when the repaired name has no twin" do
        broken = category("Podgorica (Montenegro")

        RulePass.call(run: "r1")

        rename = decisions_for(broken).sole
        assert rename.action_rename?
        assert_equal "Podgorica", rename.new_name
      end

      test "deletes letterless fragments and categories with no links" do
        fragment = category("61)")
        empty = category("Nowhere At All", links: 0)

        RulePass.call(run: "r1")

        assert decisions_for(fragment).sole.action_delete?
        assert decisions_for(empty).sole.action_delete?
      end

      test "never deletes an empty category that has places under it" do
        parent = category("North America", links: 0)
        ::Books::Category.create!(name: "Canada", category_type: :location, parent: parent)

        RulePass.call(run: "r1")

        assert decisions_for(parent).none?
      end

      test "title-cases a lowercase subject and rewrites ampersands" do
        lower = category("secrets", type: :subject)
        amp = category("Death & Grief", type: :subject)

        RulePass.call(run: "r1")

        assert_equal "Secrets", decisions_for(lower).sole.new_name
        assert_equal "Death and Grief", decisions_for(amp).sole.new_name
      end

      test "merges into a category whose alternative names include the name" do
        kolkata = category("Kolkata", links: 2, alternative_names: ["Calcutta"])
        calcutta = category("Calcutta")

        RulePass.call(run: "r1")

        assert_equal kolkata.id, decisions_for(calcutta).sole.target_category_id
      end

      test "twins in different types are not merged" do
        place = category("Hope", type: :location)
        theme = category("hope", type: :subject)

        RulePass.call(run: "r1")

        assert decisions_for(place).none?
        assert decisions_for(theme).sole.action_rename?
      end

      test "leaves genres and music categories alone" do
        genre = category("fiction stuff", type: :genre)

        RulePass.call(run: "r1")

        assert decisions_for(genre).none?
        assert CategoryCleanupDecision.where(category: categories(:music_uk_location)).none?
      end

      test "rerunning replaces its own proposed decisions and keeps rejected ones" do
        loser = category("Washington, D.C.", links: 1)
        category("Washington D.C.", links: 2)
        RulePass.call(run: "r1")
        decisions_for(loser).update_all(status: CategoryCleanupDecision.statuses["rejected"])

        RulePass.call(run: "r1")

        assert_equal ["rejected"], decisions_for(loser).pluck(:status)
      end

      test "with only_ids it writes decisions for those categories only and prefers existing winners" do
        existing = category("Georgia", links: 1)
        incoming = category("georgia", links: 2)

        RulePass.call(run: "r1", only_ids: [incoming.id], stage: "sync")

        assert_equal existing.id, decisions_for(incoming).sole.target_category_id
        assert decisions_for(existing).none?
      end

      test "each decision snapshots its category" do
        broken = category("Podgorica (Montenegro")

        RulePass.call(run: "r1")

        assert_equal "Podgorica (Montenegro", decisions_for(broken).sole.category_snapshot["name"]
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/category_cleanup/rule_pass_test.rb`
Expected: FAIL (`uninitialized constant Services::CategoryCleanup::RulePass`).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/rule_pass.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.2 step 1: the decisions no AI is needed for. Every live books
    # location and subject gets a target name (or :delete); categories whose
    # target names are twins within a type merge into the most-linked one; a
    # lone name that matches another category's alternative name merges into
    # it. Names the rules can't improve get no decision and wait for the AI.
    #
    # `only_ids` (the post-sync step) limits which categories may receive a
    # decision; every live category still takes part in twin matching, and an
    # existing category wins over an incoming one.
    class RulePass
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      TYPES = %w[location subject].freeze

      def self.call(run:, only_ids: nil, stage: "rules")
        new(run: run, only_ids: only_ids, stage: stage).call
      end

      def initialize(run:, only_ids: nil, stage: "rules")
        @run = run
        @only_ids = only_ids&.to_set
        @stage = stage
      end

      def call
        ::CategoryCleanupDecision.for_run(@run).where(stage: @stage, status: :proposed).delete_all
        categories = load_categories
        counts = link_counts
        settled = ::CategoryCleanupDecision.for_run(@run).where.not(status: :proposed).distinct.pluck(:category_id).to_set
        parents = ::Books::Category.active.where.not(parent_id: nil).distinct.pluck(:parent_id).to_set
        targets = categories.to_h { |c| [c.id, target_for(c, counts, parents)] }

        decisions = categories.filter_map do |c|
          build(c, :delete, reason: delete_reason(c, counts)) if targets[c.id] == :delete && writable?(c, settled)
        end

        live = categories.reject { |c| targets[c.id] == :delete }
        aliases = alias_index(live)
        live.group_by { |c| [c.category_type, NameNormalizer.twin_key(targets[c.id])] }.each do |(type, key), members|
          winner = pick_winner(members, counts)
          members.each do |c|
            next unless writable?(c, settled)

            if c.id != winner.id
              decisions << build(c, :merge, target_category_id: winner.id,
                reason: "Same name as #{winner.name.inspect} apart from case, punctuation or brackets")
            elsif members.one? && (alias_target = aliases[[type, key]]) && alias_target != c.id
              decisions << build(c, :merge, target_category_id: alias_target, reason: "Matches another category's alternative name")
            elsif targets[c.id] != c.name
              decisions << build(c, :rename, new_name: targets[c.id], reason: "Name clean-up")
            end
          end
        end

        persist(decisions)
        Result.new(success?: true, data: {decisions: decisions.size, by_action: decisions.map { |d| d[:action_name] }.tally}, errors: [])
      end

      private

      def load_categories
        ::Books::Category.active
          .where(category_type: TYPES)
          .where.not(id: ::Books::Category.protected_ids)
          .select(:id, :name, :category_type, :alternative_names, :parent_id, :deleted, :item_count)
          .to_a
      end

      def link_counts
        ::CategoryItem.joins(:category)
          .where(categories: {type: "Books::Category", category_type: TYPES, deleted: false})
          .group(:category_id)
          .count
      end

      # A category with places under it is never deleted, even with no links of
      # its own: it is a node of the location tree.
      def target_for(category, counts, parents)
        return :delete if counts[category.id].to_i.zero? && !parents.include?(category.id)

        NameNormalizer.target_name(category.name)
      end

      def delete_reason(category, counts)
        counts[category.id].to_i.zero? ? "No books" : "Broken name fragment"
      end

      def alias_index(categories)
        categories.each_with_object({}) do |c, index|
          c.alternative_names.each { |alt| index[[c.category_type, NameNormalizer.twin_key(alt)]] ||= c.id }
        end
      end

      def pick_winner(members, counts)
        pool = @only_ids ? members.reject { |c| @only_ids.include?(c.id) } : []
        pool = members if pool.empty?
        pool.max_by { |c| [counts[c.id].to_i, -c.id] }
      end

      def writable?(category, settled)
        !settled.include?(category.id) && (@only_ids.nil? || @only_ids.include?(category.id))
      end

      def build(category, action, new_name: nil, target_category_id: nil, reason: nil)
        {
          category_id: category.id,
          action: ::CategoryCleanupDecision.actions.fetch(action.to_s),
          action_name: action.to_s,
          new_name: new_name,
          target_category_id: target_category_id,
          reason: reason,
          category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)
        }
      end

      def persist(decisions)
        now = Time.current
        common = {
          run: @run, stage: @stage, created_at: now, updated_at: now,
          decided_by: ::CategoryCleanupDecision.decided_bies.fetch("rule"),
          status: ::CategoryCleanupDecision.statuses.fetch("proposed")
        }
        decisions.each_slice(1000) do |slice|
          ::CategoryCleanupDecision.insert_all(slice.map { |d| d.except(:action_name).merge(common) })
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/category_cleanup/rule_pass_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup test/lib/services/category_cleanup
git add web-app/app/lib/services/category_cleanup/rule_pass.rb web-app/test/lib/services/category_cleanup/rule_pass_test.rb
git commit -m "Category cleanup: deterministic rules pass"
```

---

### Task 12: AI cleanup tasks (locations and subjects)

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/category_cleanup/base_cleanup_task.rb`
- Create: `web-app/app/lib/services/ai/tasks/category_cleanup/location_task.rb`
- Create: `web-app/app/lib/services/ai/tasks/category_cleanup/subject_task.rb`
- Test: `web-app/test/lib/services/ai/tasks/category_cleanup/location_task_test.rb`, `web-app/test/lib/services/ai/tasks/category_cleanup/subject_task_test.rb`

**Interfaces:**
- Produces: `Services::Ai::Tasks::CategoryCleanup::BaseCleanupTask::Entry` (Struct: `key:, name:, links:, samples:, alternative_names:`); `LocationTask.new(entries:, known_names:, tier:, parent: nil).call → Services::Ai::Result` with `data: {results: {key => {key:, verdict:, canonical_name:, merge_into:, parent_chain:, place_kind:, retype_to:, ambiguous:, reason:}}}`; `SubjectTask` likewise with `{key:, action:, name:, merge_into:, reason:}`. A result whose key isn't in the batch, repeats a key, or has an unknown verdict/action is dropped; the caller retries those categories alone.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/ai/tasks/category_cleanup/location_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        class LocationTaskTest < ActiveSupport::TestCase
          Entry = BaseCleanupTask::Entry

          setup do
            @entries = [
              Entry.new(key: "1", name: "Chicago", links: 812, samples: ["Native Son by Richard Wright"], alternative_names: []),
              Entry.new(key: "2", name: "Hope", links: 2746, samples: ["The Grapes of Wrath by John Steinbeck"], alternative_names: ["Hope, Arkansas"])
            ]
            @task = LocationTask.new(entries: @entries, known_names: ["Illinois", "United States", "North America"], tier: :head)
          end

          def result(overrides = {})
            {key: "1", verdict: "real_place", canonical_name: "Chicago", merge_into: nil,
             parent_chain: ["Illinois", "United States", "North America"], place_kind: "city",
             retype_to: nil, ambiguous: false, reason: "City in Illinois."}.merge(overrides)
          end

          test "runs on the standard role with a strict schema and needs no parent" do
            assert_equal :standard, @task.send(:task_role)
            assert_equal LocationTask::ResponseSchema, @task.send(:response_schema)
          end

          test "the prompt numbers each location with its count, samples and other names" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "[1] \"Chicago\" (812 books)"
            assert_includes prompt, "Native Son by Richard Wright"
            assert_includes prompt, "Other names: Hope, Arkansas"
          end

          test "the system prompt carries the naming and hierarchy rules and the known names" do
            system = @task.send(:system_message)
            assert_includes system, "A country's parent is always its continent"
            assert_includes system, "\"Paris\", not \"Paris, France\""
            assert_includes system, "Illinois\nUnited States\nNorth America"
          end

          test "keeps valid results keyed by number and drops unknown keys, repeats and verdicts" do
            response = {parsed: {results: [
              result,
              result(key: "1", canonical_name: "Second answer"),
              result(key: "9"),
              result(key: "2", verdict: "maybe")
            ]}}

            outcome = @task.send(:process_and_persist, response)

            assert outcome.success?
            assert_equal ["1"], outcome.data[:results].keys
            assert_equal "Chicago", outcome.data[:results]["1"][:canonical_name]
            assert_equal ["Illinois", "United States", "North America"], outcome.data[:results]["1"][:parent_chain]
          end

          test "an unknown place kind or retype target becomes nil" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [result(place_kind: "planet", retype_to: "genre")]}})
            parsed = outcome.data[:results]["1"]
            assert_nil parsed[:place_kind]
            assert_nil parsed[:retype_to]
          end

          test "the schema lists every field" do
            fields = LocationTask::LocationResult.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[key verdict canonical_name merge_into parent_chain place_kind retype_to ambiguous reason], fields
          end
        end
      end
    end
  end
end
```

`test/lib/services/ai/tasks/category_cleanup/subject_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        class SubjectTaskTest < ActiveSupport::TestCase
          Entry = BaseCleanupTask::Entry

          def task(tier)
            SubjectTask.new(
              entries: [Entry.new(key: "1", name: "Spacecraft missions", links: 1, samples: [], alternative_names: [])],
              known_names: ["Space Exploration", "War"],
              tier: tier
            )
          end

          test "head prompt allows only true synonyms; tail prompt allows folding into a broader subject" do
            assert_includes task(:head).send(:system_message), "Never merge a narrower subject into a broader one"
            assert_includes task(:tail).send(:system_message), "too narrow to stand on its own"
            refute_includes task(:head).send(:system_message), "too narrow to stand on its own"
          end

          test "keeps a valid result and drops an unknown action" do
            outcome = task(:tail).send(:process_and_persist, {parsed: {results: [
              {key: "1", action: "merge", name: "Spacecraft Missions", merge_into: "Space Exploration", reason: "Covered."}
            ]}})
            assert_equal "Space Exploration", outcome.data[:results]["1"][:merge_into]

            bad = task(:tail).send(:process_and_persist, {parsed: {results: [{key: "1", action: "split", name: "", merge_into: nil, reason: ""}]}})
            assert_empty bad.data[:results]
          end

          test "the schema lists every field" do
            fields = SubjectTask::SubjectResult.to_json_schema[:properties].keys.map(&:to_s)
            assert_equal %w[key action name merge_into reason], fields
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/category_cleanup`
Expected: FAIL (`uninitialized constant Services::Ai::Tasks::CategoryCleanup`).

- [ ] **Step 3: Implement**

`app/lib/services/ai/tasks/category_cleanup/base_cleanup_task.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Shared plumbing for the cleanup passes (spec §4.2): a numbered batch of
        # categories in, one result per category out, keyed by its number so a
        # dropped or reordered row is detected. Batch size is the caller's choice
        # (one per call for the head; spec §4.4 calibrates the tail).
        class BaseCleanupTask < BaseTask
          Entry = Struct.new(:key, :name, :links, :samples, :alternative_names, keyword_init: true)

          attr_reader :entries, :known_names, :tier

          def initialize(entries:, known_names:, tier:, parent: nil, provider: nil, model: nil)
            @entries = entries
            @known_names = known_names
            @tier = tier.to_sym
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def user_prompt
            lines = ["#{noun.capitalize} to review:"]
            entries.each do |entry|
              lines << "[#{entry.key}] #{entry.name.inspect} (#{entry.links} #{"book".pluralize(entry.links)})"
              lines << "  Sample books: #{entry.samples.join("; ")}" if entry.samples.any?
              lines << "  Other names: #{entry.alternative_names.join(", ")}" if entry.alternative_names.any?
            end
            lines << ""
            lines << "Return exactly one result per #{noun.singularize}, with its number in \"key\"."
            lines.join("\n")
          end

          def known_names_block
            "Known #{noun} (use these exact names when they fit):\n#{known_names.join("\n")}"
          end

          def process_and_persist(provider_response)
            keys = entries.map(&:key).to_set
            results = Array(provider_response[:parsed][:results]).each_with_object({}) do |raw, by_key|
              parsed = normalize(raw)
              next if parsed.nil? || !keys.include?(parsed[:key]) || by_key.key?(parsed[:key])

              by_key[parsed[:key]] = parsed
            end
            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def value(raw, key)
            raw.respond_to?(key) ? raw.public_send(key) : (raw[key] || raw[key.to_s])
          end

          def string(raw, key) = value(raw, key).to_s.strip
        end
      end
    end
  end
end
```

`app/lib/services/ai/tasks/category_cleanup/location_task.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Decides what each books location category should become (spec §2, §3.1, §4.2).
        class LocationTask < BaseCleanupTask
          VERDICTS = %w[real_place fictional_place not_a_place junk].freeze
          PLACE_KINDS = %w[continent region country subdivision city site historical_state fictional global].freeze

          private

          def noun = "locations"

          def system_message
            <<~SYSTEM
              You are cleaning up the "setting" locations of a book catalog. Each location is a category books are linked to because they are set there.

              For each location you get its current name, how many books carry it, and a few of those books. Decide:
              - verdict: "real_place" (a real place, current or historical), "fictional_place" (an invented place), "not_a_place" (a theme or topic stored as a location by mistake, like "Hope"), or "junk" (meaningless, truncated, or not a name).
              - canonical_name: the name it should have, following the naming rules.
              - merge_into: when it is the same place as one of the known locations below, that location's exact name; otherwise null.
              - parent_chain: for a real or fictional place that is not merged, the places containing it from the immediate parent up to a root, using known names when they exist. Empty for a root.
              - place_kind: continent, region, country, subdivision, city, site, historical_state, fictional, or global.
              - retype_to: "subject" when the verdict is not_a_place and the name is a real subject; otherwise null.
              - ambiguous: true when the sample books show the name used for two different places.
              - reason: one short sentence.
              Judge by the sample books when the name alone is unclear.

              Naming rules:
              - The common English name, current if the place still exists ("Kolkata", not "Calcutta"; "Gdańsk", not "Danzig"). Historical states keep their historical name ("Soviet Union", "Roman Empire").
              - No containing place in the name: "Paris", not "Paris, France".
              - Title Case, "and" not "&", no trailing punctuation.
              - A parenthetical qualifier only to tell apart two different places with one name, leaving the bare name to the better-known one: "Georgia" (the country), "Georgia (U.S. state)".

              Hierarchy rules:
              - Roots: Africa, Antarctica, Asia, Europe, North America, Oceania, South America, Fictional Location, regions spanning continents (Middle East, Arctic), and global places (Outer Space, Atlantic Ocean, Pacific Ocean, Indian Ocean).
              - A country's parent is always its continent. Named regions inside one continent (Scandinavia, Balkans, Caribbean) sit under that continent, but countries never go under them.
              - A transcontinental country goes under the continent holding most of its population (Russia: Europe; Turkey: Asia).
              - Places spanning several countries go under their nearest shared region or continent (Alps: Europe).
              - Historical cities and sites go under the modern country they lie in (Troy: Turkey). Historical states and empires go under their continent.
              - Invented worlds and places in them go under Fictional Location (Middle-earth). An invented town inside the real world gets its real parent.

              #{known_names_block}
            SYSTEM
          end

          def response_schema = ResponseSchema

          def normalize(raw)
            verdict = string(raw, :verdict)
            return nil unless VERDICTS.include?(verdict)

            kind = string(raw, :place_kind)
            {
              key: string(raw, :key),
              verdict: verdict,
              canonical_name: string(raw, :canonical_name),
              merge_into: string(raw, :merge_into).presence,
              parent_chain: Array(value(raw, :parent_chain)).map { |name| name.to_s.strip }.reject(&:blank?),
              place_kind: PLACE_KINDS.include?(kind) ? kind : nil,
              retype_to: (string(raw, :retype_to) == "subject") ? "subject" : nil,
              ambiguous: value(raw, :ambiguous) == true,
              reason: string(raw, :reason)
            }
          end

          class LocationResult < OpenAI::BaseModel
            required :key, String, doc: "The location's number from the list"
            required :verdict, String, doc: "real_place, fictional_place, not_a_place or junk"
            required :canonical_name, String, doc: "The name it should have"
            required :merge_into, String, nil?: true, doc: "Exact name of the known location it duplicates, or null"
            required :parent_chain, OpenAI::ArrayOf[String], doc: "Containing places, immediate parent first, root last; empty for a root"
            required :place_kind, String, nil?: true, doc: "continent, region, country, subdivision, city, site, historical_state, fictional or global"
            required :retype_to, String, nil?: true, doc: "subject, or null"
            required :ambiguous, OpenAI::Boolean, doc: "true if the books show two different places under this name"
            required :reason, String, doc: "One short sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[LocationResult], doc: "One result per location"
          end
        end
      end
    end
  end
end
```

`app/lib/services/ai/tasks/category_cleanup/subject_task.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Decides what each books subject category should become (spec §2, §4.2).
        # The head may only merge true synonyms; the rare tail may also fold into
        # a broader known subject (the owner's long-tail decision, 2026-10-11).
        class SubjectTask < BaseCleanupTask
          ACTIONS = %w[keep rename merge delete is_location].freeze

          private

          def noun = "subjects"

          def system_message
            <<~SYSTEM
              You are cleaning up the subject categories of a book catalog. A subject names a topic or theme a book is about ("Slavery", "Medicine", "War", "Grief").

              For each subject choose an action:
              - "keep": a good subject whose name already follows the rules.
              - "rename": a good subject whose name breaks the rules; give the new name in "name".
              - "merge": the same subject as one of the known subjects below; give its exact name in "merge_into".
              - "delete": junk or not a subject: a truncated fragment, a placeholder ("Book titles", "Packages"), a genre ("Science Fiction"), a format ("Anthology") or an audience ("Young Adult").
              - "is_location": a place, which belongs with locations.
              Merge only true synonyms and variant spellings ("Decision Making" and "Decision-Making"; "Womens Studies" and "Women's Studies").
              #{merge_scope_rule}
              A vague but real theme ("Identity", "Family") is a keep.

              Naming rules: Title Case with minor words lowercase unless first, "and" not "&", straight apostrophes, no trailing punctuation, a noun or noun phrase.

              #{known_names_block}
            SYSTEM
          end

          def merge_scope_rule
            if tier == :tail
              "This subject is rare. If it is too narrow to stand on its own and one known subject clearly covers it, merge it into that subject (\"Spacecraft Missions\" into \"Space Exploration\"). Never merge into a subject that only overlaps."
            else
              "Never merge a narrower subject into a broader one, or a broader into a narrower one: \"Grief\" is not \"Death\"."
            end
          end

          def response_schema = ResponseSchema

          def normalize(raw)
            action = string(raw, :action)
            return nil unless ACTIONS.include?(action)

            {key: string(raw, :key), action: action, name: string(raw, :name), merge_into: string(raw, :merge_into).presence, reason: string(raw, :reason)}
          end

          class SubjectResult < OpenAI::BaseModel
            required :key, String, doc: "The subject's number from the list"
            required :action, String, doc: "keep, rename, merge, delete or is_location"
            required :name, String, doc: "The name it should have (same as now for keep)"
            required :merge_into, String, nil?: true, doc: "Exact name of the known subject to merge into, or null"
            required :reason, String, doc: "One short sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[SubjectResult], doc: "One result per subject"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/category_cleanup && CI=1 bin/rails zeitwerk:check`
Expected: PASS; "All is good!".

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/ai/tasks/category_cleanup test/lib/services/ai/tasks/category_cleanup
git add web-app/app/lib/services/ai/tasks/category_cleanup web-app/test/lib/services/ai/tasks/category_cleanup
git commit -m "Category cleanup: AI location and subject tasks"
```

---

### Task 13: Name index, sample titles, and the AI-answer-to-decision builders

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/name_index.rb`
- Create: `web-app/app/lib/services/category_cleanup/sample_titles.rb`
- Create: `web-app/app/lib/services/category_cleanup/location_decisions.rb`
- Create: `web-app/app/lib/services/category_cleanup/subject_decisions.rb`
- Test: `web-app/test/lib/services/category_cleanup/name_index_test.rb`, `.../sample_titles_test.rb`, `.../location_decisions_test.rb`, `.../subject_decisions_test.rb`

**Interfaces:**
- Consumes: Task 10, Task 11 (rule decisions shape the effective names), Task 12 (result hashes).
- Produces:
  - `NameIndex.new(run:, category_type:)` with `#entries → Array<NameIndex::Entry>` (`Entry` Struct: `category:, name:, links:`; `#id`), `#head_names → Array<String>` (links ≥ `head_min_links`, most-linked first), `#lookup(name) → Integer | nil`.
  - `SampleTitles.for(category) → Array<String>` ("Title by Author, Author").
  - `LocationDecisions.call(entry:, result:, locations:, subjects:) → Array<Hash>` and `SubjectDecisions.call(entry:, result:, locations:, subjects:) → Array<Hash>`. Each hash has `category_id:, action:` (Symbol), `status:` (`:proposed` or `:failed`), and any of `new_name:, target_category_id:, parent_chain:, new_category_type:, place_kind:, ambiguous:, reason:, error:`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/category_cleanup/name_index_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class NameIndexTest < ActiveSupport::TestCase
      def location(name, links:, alternative_names: [])
        record = ::Books::Category.create!(name: name, category_type: :location, alternative_names: alternative_names)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def decide(category, action, **attrs)
        CategoryCleanupDecision.create!({category: category, run: "r1", stage: "rules", action: action, decided_by: :rule}.merge(attrs))
      end

      test "applies proposed renames and merges from the run to names and counts" do
        dc = location("Washington D.C.", links: 2)
        twin = location("Washington, D.C.", links: 1)
        lower = location("paris", links: 1)
        decide(twin, :merge, target_category: dc)
        decide(lower, :rename, new_name: "Paris")

        index = NameIndex.new(run: "r1", category_type: "location")
        by_id = index.entries.index_by(&:id)

        refute by_id.key?(twin.id)
        assert_equal 3, by_id[dc.id].links
        assert_equal "Paris", by_id[lower.id].name
      end

      test "lookup matches effective names, original names and alternative names, case-insensitively" do
        kolkata = location("Kolkata", links: 1, alternative_names: ["Calcutta"])
        index = NameIndex.new(run: "r1", category_type: "location")

        assert_equal kolkata.id, index.lookup("kolkata")
        assert_equal kolkata.id, index.lookup("Calcutta")
        assert_nil index.lookup("Bombay")
      end

      test "head_names lists the most-linked names at or above the head threshold" do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(2)
        location("Big Place", links: 2)
        location("Small Place", links: 1)

        names = NameIndex.new(run: "r1", category_type: "location").head_names

        assert_includes names, "Big Place"
        refute_includes names, "Small Place"
      end

      test "only books categories of the given type take part" do
        refute_includes NameIndex.new(run: "r1", category_type: "location").entries.map(&:id), categories(:music_uk_location).id
      end
    end
  end
end
```

`test/lib/services/category_cleanup/sample_titles_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class SampleTitlesTest < ActiveSupport::TestCase
      test "lists linked books as 'Title by Author'" do
        category = ::Books::Category.create!(name: "Russia", category_type: :location)
        book = books_books(:war_and_peace)
        CategoryItem.create!(category: category, item: book)
        expected = book.authors.any? ? "#{book.title} by #{book.authors.map(&:name).join(", ")}" : book.title

        assert_equal [expected], SampleTitles.for(category)
      end

      test "is capped by config" do
        Rails.configuration.x.categories_cleanup.stubs(:sample_titles).returns(1)
        category = ::Books::Category.create!(name: "Russia", category_type: :location)
        CategoryItem.create!(category: category, item: books_books(:war_and_peace))
        CategoryItem.create!(category: category, item: books_books(:crime_and_punishment))

        assert_equal 1, SampleTitles.for(category).size
      end
    end
  end
end
```

`test/lib/services/category_cleanup/location_decisions_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class LocationDecisionsTest < ActiveSupport::TestCase
      setup do
        @us = ::Books::Category.create!(name: "United States", category_type: :location)
        @chicago = ::Books::Category.create!(name: "Chicago", category_type: :location)
        @hope_subject = ::Books::Category.create!(name: "Hope", category_type: :subject)
        [@us, @chicago].each { |c| CategoryItem.create!(category: c, item: books_books(:war_and_peace)) }
        CategoryItem.create!(category: @hope_subject, item: books_books(:war_and_peace))
        @locations = NameIndex.new(run: "r1", category_type: "location")
        @subjects = NameIndex.new(run: "r1", category_type: "subject")
      end

      def entry_for(category) = @locations.entries.find { |e| e.id == category.id } || NameIndex::Entry.new(category: category, name: category.name, links: 1)

      def result(overrides = {})
        {key: "1", verdict: "real_place", canonical_name: "Chicago", merge_into: nil, parent_chain: ["Illinois", "United States", "North America"],
         place_kind: "city", retype_to: nil, ambiguous: false, reason: "City."}.merge(overrides)
      end

      def build(category, overrides = {})
        LocationDecisions.call(entry: entry_for(category), result: result(overrides), locations: @locations, subjects: @subjects)
      end

      test "a real place with a chain gets a set_parent decision" do
        decisions = build(@chicago)

        assert_equal [:set_parent], decisions.map { |d| d[:action] }
        assert_equal ["Illinois", "United States", "North America"], decisions.first[:parent_chain]
        assert_equal "city", decisions.first[:place_kind]
      end

      test "a new canonical name adds a rename; a name that clashes with another location becomes a merge" do
        renamed = build(@chicago, canonical_name: "Chicago (Illinois)")
        assert_equal [:rename, :set_parent], renamed.map { |d| d[:action] }

        clash = build(@chicago, canonical_name: "United States")
        assert_equal [{action: :merge, target: @us.id}], clash.map { |d| {action: d[:action], target: d[:target_category_id]} }
      end

      test "merge_into resolves to a known location, or fails" do
        ok = build(@chicago, merge_into: "united states")
        assert_equal @us.id, ok.sole[:target_category_id]

        missing = build(@chicago, merge_into: "Atlantis")
        assert_equal :failed, missing.sole[:status]
        assert_match "Atlantis", missing.sole[:error]
      end

      test "junk is deleted; a root with no chain is kept" do
        assert_equal :delete, build(@chicago, verdict: "junk").sole[:action]
        assert_equal :keep, build(@us, canonical_name: "United States", parent_chain: [], place_kind: "country").sole[:action]
      end

      test "a fictional place with no chain goes under Fictional Location" do
        decisions = build(@chicago, verdict: "fictional_place", canonical_name: "Chicago", parent_chain: [])
        assert_equal ["Fictional Location"], decisions.sole[:parent_chain]
      end

      test "not a place merges into the subject of that name, or is retyped" do
        hope = ::Books::Category.create!(name: "Hope", category_type: :location)
        merged = build(hope, verdict: "not_a_place", canonical_name: "Hope", retype_to: "subject", parent_chain: [])
        assert_equal [:merge, @hope_subject.id], [merged.sole[:action], merged.sole[:target_category_id]]

        media = ::Books::Category.create!(name: "Media", category_type: :location)
        retyped = build(media, verdict: "not_a_place", canonical_name: "Media", retype_to: "subject", parent_chain: [])
        assert_equal :retype, retyped.sole[:action]
        assert_equal ::Category.category_types["subject"], retyped.sole[:new_category_type]

        noise = build(media, verdict: "not_a_place", retype_to: nil, parent_chain: [])
        assert_equal :delete, noise.sole[:action]
      end

      test "a chain that contains the place itself or repeats a name fails" do
        own = build(@chicago, parent_chain: ["Chicago", "United States"])
        assert_equal :failed, own.last[:status]

        repeat = build(@chicago, parent_chain: ["Illinois", "illinois"])
        assert_equal :failed, repeat.last[:status]
      end

      test "every decision carries the reason and the ambiguous flag" do
        decision = build(@chicago, ambiguous: true, reason: "Two Chicagos.").sole
        assert decision[:ambiguous]
        assert_equal "Two Chicagos.", decision[:reason]
      end
    end
  end
end
```

`test/lib/services/category_cleanup/subject_decisions_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class SubjectDecisionsTest < ActiveSupport::TestCase
      setup do
        @space = ::Books::Category.create!(name: "Space Exploration", category_type: :subject)
        @missions = ::Books::Category.create!(name: "Spacecraft missions", category_type: :subject)
        @paris_place = ::Books::Category.create!(name: "Paris", category_type: :location)
        [@space, @missions, @paris_place].each { |c| CategoryItem.create!(category: c, item: books_books(:war_and_peace)) }
        @locations = NameIndex.new(run: "r1", category_type: "location")
        @subjects = NameIndex.new(run: "r1", category_type: "subject")
      end

      def build(category, result)
        entry = NameIndex::Entry.new(category: category, name: category.name, links: 1)
        SubjectDecisions.call(entry: entry, result: {key: "1", name: category.name, merge_into: nil, reason: "r"}.merge(result), locations: @locations, subjects: @subjects)
      end

      test "keep, delete and merge map directly" do
        assert_equal :keep, build(@missions, action: "keep").sole[:action]
        assert_equal :delete, build(@missions, action: "delete").sole[:action]
        assert_equal @space.id, build(@missions, action: "merge", merge_into: "space exploration").sole[:target_category_id]
      end

      test "a merge into an unknown subject fails" do
        assert_equal :failed, build(@missions, action: "merge", merge_into: "Rocketry").sole[:status]
      end

      test "a rename onto an existing subject becomes a merge; a fresh name is a rename" do
        assert_equal :merge, build(@missions, action: "rename", name: "Space Exploration").sole[:action]
        assert_equal "Spacecraft Missions", build(@missions, action: "rename", name: "Spacecraft Missions").sole[:new_name]
      end

      test "is_location merges into the location of that name, or retypes" do
        paris = ::Books::Category.create!(name: "Paris", category_type: :subject)
        assert_equal @paris_place.id, build(paris, action: "is_location").sole[:target_category_id]

        lyon = ::Books::Category.create!(name: "Lyon", category_type: :subject)
        assert_equal :retype, build(lyon, action: "is_location").sole[:action]
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/category_cleanup`
Expected: FAIL (`uninitialized constant ...NameIndex`, `SampleTitles`, `LocationDecisions`, `SubjectDecisions`).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/name_index.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # The vocabulary of one category type as a run currently sees it: live books
    # categories, minus those a proposed or applied merge/retype/delete removes,
    # with proposed renames applied and merged-in link counts added to their
    # targets. The AI passes build prompts from it and resolve the model's
    # names back to category ids with #lookup.
    class NameIndex
      Entry = Struct.new(:category, :name, :links, keyword_init: true) do
        def id = category.id
      end

      def initialize(run:, category_type:)
        @run = run
        @category_type = category_type.to_s
        build
      end

      attr_reader :entries

      def head_names
        min = Rails.configuration.x.categories_cleanup.head_min_links
        entries.select { |entry| entry.links >= min }.sort_by { |entry| [-entry.links, entry.name] }.map(&:name)
      end

      def lookup(name)
        return nil if name.blank?

        @by_key[NameNormalizer.twin_key(name)]
      end

      private

      def build
        categories = ::Books::Category.active
          .where(category_type: @category_type)
          .where.not(id: ::Books::Category.protected_ids)
          .to_a
        counts = ::CategoryItem.direct.joins(:category)
          .where(categories: {type: "Books::Category", category_type: @category_type, deleted: false})
          .group(:category_id).count
        decisions = ::CategoryCleanupDecision.for_run(@run).where(status: %i[proposed applied]).to_a
        removed = decisions.select { |d| d.action_merge? || d.action_retype? || d.action_delete? }.map(&:category_id).to_set
        renames = decisions.select(&:action_rename?).to_h { |d| [d.category_id, d.new_name] }

        links = categories.to_h { |c| [c.id, counts[c.id].to_i] }
        decisions.select(&:action_merge?).each do |d|
          links[d.target_category_id] += links[d.category_id].to_i if links.key?(d.target_category_id)
        end

        @entries = categories.reject { |c| removed.include?(c.id) }.map do |c|
          Entry.new(category: c, name: renames[c.id] || c.name, links: links[c.id])
        end
        index_names
      end

      # Effective names first, then original names, then alternative names;
      # within each tier the most-linked category wins a shared key.
      def index_names
        @by_key = {}
        ordered = entries.sort_by { |entry| [-entry.links, entry.id] }
        ordered.each { |entry| @by_key[NameNormalizer.twin_key(entry.name)] ||= entry.id }
        ordered.each { |entry| @by_key[NameNormalizer.twin_key(entry.category.name)] ||= entry.id }
        ordered.each do |entry|
          entry.category.alternative_names.each { |alt| @by_key[NameNormalizer.twin_key(alt)] ||= entry.id }
        end
      end
    end
  end
end
```

`app/lib/services/category_cleanup/sample_titles.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # A few books carrying a category, for the model's context. Oldest ids
    # first: those are the long-standing legacy records, which skew towards
    # well-known books the model can place.
    class SampleTitles
      def self.for(category)
        limit = Rails.configuration.x.categories_cleanup.sample_titles
        ::Books::Book
          .joins(:category_items).where(category_items: {category_id: category.id})
          .includes(:authors).order(:id).limit(limit)
          .map do |book|
            names = book.authors.map(&:name)
            names.any? ? "#{book.title} by #{names.join(", ")}" : book.title
          end
      end
    end
  end
end
```

`app/lib/services/category_cleanup/location_decisions.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Turns one LocationTask answer into decision attributes (spec §4.2 step 2).
    # Names the model gave are resolved to ids here; anything that can't be
    # resolved becomes a `failed` decision so it shows in the report.
    class LocationDecisions
      FICTIONAL_ROOT = "Fictional Location"

      def self.call(**) = new(**).call

      def initialize(entry:, result:, locations:, subjects:)
        @entry = entry
        @result = result
        @locations = locations
        @subjects = subjects
      end

      def call
        case @result[:verdict]
        when "junk" then [decision(:delete)]
        when "not_a_place" then not_a_place
        else place
        end
      end

      private

      def not_a_place
        return [decision(:delete)] unless @result[:retype_to] == "subject"

        name = @result[:canonical_name].presence || @entry.name
        subject_id = @subjects.lookup(name)
        return [decision(:merge, target_category_id: subject_id)] if subject_id

        decisions = [decision(:retype, new_category_type: ::Category.category_types.fetch("subject"))]
        decisions << decision(:rename, new_name: name) if name != @entry.name
        decisions
      end

      def place
        if @result[:merge_into]
          target = @locations.lookup(@result[:merge_into])
          return [failed(:merge, "merge_into #{@result[:merge_into].inspect} matches no location")] if target.nil?
          return [decision(:merge, target_category_id: target)] if target != @entry.id
        end

        name = @result[:canonical_name].presence || @entry.name
        decisions = []
        if name != @entry.name
          clash = @locations.lookup(name)
          return [decision(:merge, target_category_id: clash)] if clash && clash != @entry.id

          decisions << decision(:rename, new_name: name)
        end

        chain = @result[:parent_chain]
        chain = [FICTIONAL_ROOT] if chain.empty? && @result[:verdict] == "fictional_place" && name != FICTIONAL_ROOT
        if chain.any?
          error = chain_error(chain, name)
          decisions << (error ? failed(:set_parent, error, parent_chain: chain) : decision(:set_parent, parent_chain: chain))
        end

        decisions.presence || [decision(:keep)]
      end

      def chain_error(chain, name)
        return "parent chain is longer than #{::Books::Category::MAX_DEPTH - 1} places" if chain.size >= ::Books::Category::MAX_DEPTH

        keys = chain.map { |link| NameNormalizer.twin_key(link) }
        return "parent chain repeats a place" if keys.uniq.size != keys.size
        return "parent chain contains the place itself" if keys.include?(NameNormalizer.twin_key(name))
        return "parent chain starts at the place itself" if @locations.lookup(chain.first) == @entry.id

        nil
      end

      def decision(action, **attrs)
        {
          category_id: @entry.id, action: action, status: :proposed,
          place_kind: @result[:place_kind], ambiguous: @result[:ambiguous] == true, reason: @result[:reason]
        }.merge(attrs)
      end

      def failed(action, error, **attrs)
        decision(action, **attrs).merge(status: :failed, error: error)
      end
    end
  end
end
```

`app/lib/services/category_cleanup/subject_decisions.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Turns one SubjectTask answer into decision attributes (spec §4.2 step 4).
    # "is_location" merges into the location of that name when one exists and
    # otherwise retypes; after apply, a retyped category is an undecided
    # location that the next locations propose picks up.
    class SubjectDecisions
      def self.call(**) = new(**).call

      def initialize(entry:, result:, locations:, subjects:)
        @entry = entry
        @result = result
        @locations = locations
        @subjects = subjects
      end

      def call
        case @result[:action]
        when "delete" then [decision(:delete)]
        when "merge" then merge
        when "rename" then rename
        when "is_location" then is_location
        else [decision(:keep)]
        end
      end

      private

      def merge
        target = @subjects.lookup(@result[:merge_into])
        return [failed(:merge, "merge_into #{@result[:merge_into].inspect} matches no subject")] if target.nil?
        return [decision(:keep)] if target == @entry.id

        [decision(:merge, target_category_id: target)]
      end

      def rename
        name = @result[:name]
        return [decision(:keep)] if name.blank? || name == @entry.name

        clash = @subjects.lookup(name)
        return [decision(:merge, target_category_id: clash)] if clash && clash != @entry.id

        [decision(:rename, new_name: name)]
      end

      def is_location
        location_id = @locations.lookup(@entry.name)
        return [decision(:merge, target_category_id: location_id)] if location_id

        [decision(:retype, new_category_type: ::Category.category_types.fetch("location"))]
      end

      def decision(action, **attrs)
        {category_id: @entry.id, action: action, status: :proposed, reason: @result[:reason]}.merge(attrs)
      end

      def failed(action, error, **attrs)
        decision(action, **attrs).merge(status: :failed, error: error)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/category_cleanup`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup test/lib/services/category_cleanup
git add web-app/app/lib/services/category_cleanup web-app/test/lib/services/category_cleanup
git commit -m "Category cleanup: name index, sample titles, decision builders"
```

---

### Task 14: AI pass (propose stages for locations and subjects)

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/ai_pass.rb`
- Test: `web-app/test/lib/services/category_cleanup/ai_pass_test.rb`

**Interfaces:**
- Consumes: Task 12 (tasks), Task 13 (`NameIndex`, `SampleTitles`, builders).
- Produces: `AiPass.new(run:, category_type:, tier:, batch_size: nil, limit: nil)` with `#call → Result` (`data: {candidates:, decided:, failed_calls:, missing:}`), `#call_count → Integer`, `#stage → String` (`"locations_head"` etc.); class methods `AiPass.task_class(category_type) → Class`, `AiPass.task_entry(entry, key) → BaseCleanupTask::Entry`.

- [ ] **Step 1: Write the failing test**

`test/lib/services/category_cleanup/ai_pass_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class AiPassTest < ActiveSupport::TestCase
      LocationTask = ::Services::Ai::Tasks::CategoryCleanup::LocationTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(2)
        # Fixture locations would otherwise join the candidate lists and the counts.
        ::Books::Category.where(category_type: :location).update_all(deleted: true)
        @us = location("United States", links: 2)
        @chicago = location("Chicago", links: 1)
        @boston = location("Boston", links: 1)
      end

      def location(name, links:)
        record = ::Books::Category.create!(name: name, category_type: :location)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def answer(key, name, chain)
        {key: key, verdict: "real_place", canonical_name: name, merge_into: nil, parent_chain: chain,
         place_kind: "city", retype_to: nil, ambiguous: false, reason: "r"}
      end

      def stub_task(results_by_call)
        calls = results_by_call.map do |results|
          ::Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: nil)
        end
        LocationTask.any_instance.stubs(:call).returns(*calls)
      end

      test "the head goes one category per call and writes ai decisions with a snapshot" do
        stub_task([{"1" => answer("1", "United States", [])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 1, result.data[:decided]
        decision = CategoryCleanupDecision.find_by!(run: "r1", category: @us)
        assert decision.decided_by_ai?
        assert_equal "locations_head", decision.stage
        assert_equal "United States", decision.category_snapshot["name"]
      end

      test "the tail batches, and a category missing from a batch answer is retried alone" do
        stub_task([
          {"1" => answer("1", "Chicago", ["United States"])},
          {"1" => answer("1", "Boston", ["United States"])}
        ])

        AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 2).call

        assert CategoryCleanupDecision.exists?(run: "r1", category: @chicago, action: :set_parent)
        assert CategoryCleanupDecision.exists?(run: "r1", category: @boston, action: :set_parent)
      end

      test "a rerun skips categories already decided in that stage" do
        stub_task([{"1" => answer("1", "United States", [])}])
        AiPass.new(run: "r1", category_type: "location", tier: :head).call

        LocationTask.any_instance.expects(:call).never
        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 0, result.data[:candidates]
      end

      test "categories removed by a rule decision are not sent" do
        CategoryCleanupDecision.create!(category: @chicago, run: "r1", stage: "rules", action: :delete, decided_by: :rule)
        stub_task([{"1" => answer("1", "Boston", ["United States"])}])

        result = AiPass.new(run: "r1", category_type: "location", tier: :tail).call

        assert_equal 1, result.data[:candidates]
      end

      test "a failed call writes nothing and is counted" do
        LocationTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: false, error: "timeout"))

        result = AiPass.new(run: "r1", category_type: "location", tier: :head).call

        assert_equal 1, result.data[:failed_calls]
        assert CategoryCleanupDecision.where(run: "r1").none?
      end

      test "call_count reflects the pending candidates, the batch size and the limit" do
        assert_equal 1, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 25).call_count
        assert_equal 2, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 1).call_count
        assert_equal 1, AiPass.new(run: "r1", category_type: "location", tier: :tail, batch_size: 1, limit: 1).call_count
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/category_cleanup/ai_pass_test.rb`
Expected: FAIL (`uninitialized constant Services::CategoryCleanup::AiPass`).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/ai_pass.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.2 steps 2-4: sends one type's undecided head or tail categories
    # to the AI, most-linked first, and writes the answers as decisions. The
    # head always goes one per call; the tail uses the calibrated batch size.
    # Resumable: a category already decided in this stage is never re-sent, so
    # an interrupted run just continues (REDO=1 on the rake task starts over).
    class AiPass
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      TASKS = {
        "location" => "::Services::Ai::Tasks::CategoryCleanup::LocationTask",
        "subject" => "::Services::Ai::Tasks::CategoryCleanup::SubjectTask"
      }.freeze
      BUILDERS = {"location" => "LocationDecisions", "subject" => "SubjectDecisions"}.freeze

      def self.task_class(category_type) = TASKS.fetch(category_type.to_s).constantize

      def self.task_entry(entry, key)
        ::Services::Ai::Tasks::CategoryCleanup::BaseCleanupTask::Entry.new(
          key: key, name: entry.name, links: entry.links,
          samples: SampleTitles.for(entry.category), alternative_names: entry.category.alternative_names
        )
      end

      attr_reader :stage

      def initialize(run:, category_type:, tier:, batch_size: nil, limit: nil)
        @run = run
        @category_type = category_type.to_s
        @tier = tier.to_sym
        @batch_size = (@tier == :head) ? 1 : (batch_size || Rails.configuration.x.categories_cleanup.tail_batch_size)
        @limit = limit.to_i.positive? ? limit.to_i : nil
        @stage = "#{@category_type.pluralize}_#{@tier}"
      end

      def call_count
        (candidates.size / @batch_size.to_f).ceil
      end

      def call
        stats = Hash.new(0)
        known = own_index.head_names
        candidates.each_slice(@batch_size) { |batch| process(batch, known, stats) }
        Result.new(success?: true, data: {candidates: candidates.size}.merge(stats), errors: [])
      end

      private

      def locations = @locations ||= NameIndex.new(run: @run, category_type: "location")

      def subjects = @subjects ||= NameIndex.new(run: @run, category_type: "subject")

      def own_index = (@category_type == "location") ? locations : subjects

      def candidates
        @candidates ||= begin
          seen = ::CategoryCleanupDecision.for_run(@run)
            .where(stage: ["#{@category_type.pluralize}_head", "#{@category_type.pluralize}_tail"])
            .distinct.pluck(:category_id).to_set
          head_min = Rails.configuration.x.categories_cleanup.head_min_links
          list = own_index.entries
            .select { |entry| (@tier == :head) == (entry.links >= head_min) }
            .reject { |entry| seen.include?(entry.id) }
            .sort_by { |entry| [-entry.links, entry.id] }
          @limit ? list.first(@limit) : list
        end
      end

      def process(batch, known, stats)
        entries = batch.each_with_index.map { |entry, index| self.class.task_entry(entry, (index + 1).to_s) }
        parent = batch.one? ? batch.first.category : nil
        result = self.class.task_class(@category_type).new(entries: entries, known_names: known, tier: @tier, parent: parent).call
        unless result.success?
          stats[:failed_calls] += 1
          return
        end

        batch.each_with_index do |entry, index|
          answer = result.data[:results][(index + 1).to_s]
          if answer.nil?
            batch.one? ? stats[:missing] += 1 : process([entry], known, stats)
            next
          end
          persist(entry, answer, result.ai_chat)
          stats[:decided] += 1
        end
      end

      def persist(entry, answer, ai_chat)
        builder = "::Services::CategoryCleanup::#{BUILDERS.fetch(@category_type)}".constantize
        snapshot = ::CategoryCleanupDecision.snapshot_of(entry.category)
        builder.call(entry: entry, result: answer, locations: locations, subjects: subjects).each do |attrs|
          ::CategoryCleanupDecision.create!(
            attrs.merge(run: @run, stage: @stage, decided_by: :ai, ai_chat: ai_chat, category_snapshot: snapshot)
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/category_cleanup/ai_pass_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup/ai_pass.rb test/lib/services/category_cleanup/ai_pass_test.rb
git add web-app/app/lib/services/category_cleanup/ai_pass.rb web-app/test/lib/services/category_cleanup/ai_pass_test.rb
git commit -m "Category cleanup: AI pass with resumable, batched propose stages"
```

---

### Task 15: Applier

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/location_lookup.rb`
- Create: `web-app/app/lib/services/category_cleanup/applier.rb`
- Test: `web-app/test/lib/services/category_cleanup/location_lookup_test.rb`, `web-app/test/lib/services/category_cleanup/applier_test.rb`

**Interfaces:**
- Consumes: Task 3 (`Merger`, `Deleter`), Task 2 (`AncestorReconciler`), Task 10 (decisions, `NameNormalizer`).
- Produces: `LocationLookup.new` with `#find(name) → Integer | nil`, `#register(category)`; `Applier.call(run:, only_rules: false) → Result` with `data` a Hash of counts keyed by action name plus `"created"`, `"stale"`, `"failed"`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/category_cleanup/location_lookup_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class LocationLookupTest < ActiveSupport::TestCase
      test "finds live locations by name or alternative name, ignoring case and punctuation" do
        kolkata = ::Books::Category.create!(name: "Kolkata", category_type: :location, alternative_names: ["Calcutta"])
        ::Books::Category.create!(name: "Ghost Town", category_type: :location, deleted: true)
        ::Books::Category.create!(name: "Kolkata Studies", category_type: :subject)
        lookup = LocationLookup.new

        assert_equal kolkata.id, lookup.find("KOLKATA")
        assert_equal kolkata.id, lookup.find("calcutta")
        assert_nil lookup.find("Ghost Town")
        assert_nil lookup.find("Kolkata Studies")
      end

      test "register adds a category created after the lookup was built" do
        lookup = LocationLookup.new
        europe = ::Books::Category.create!(name: "Europe", category_type: :location)
        lookup.register(europe)

        assert_equal europe.id, lookup.find("Europe")
      end
    end
  end
end
```

`test/lib/services/category_cleanup/applier_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class ApplierTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
      end

      def location(name, links: 1, type: :location)
        record = ::Books::Category.create!(name: name, category_type: type)
        CategoryItem.create!(category: record, item: @book) if links.positive?
        record
      end

      def decide(category, action, decided_by: :rule, **attrs)
        CategoryCleanupDecision.create!({
          category: category, run: "r1", stage: "rules", action: action, decided_by: decided_by,
          category_snapshot: CategoryCleanupDecision.snapshot_of(category)
        }.merge(attrs))
      end

      test "applies renames, merges, retypes, parents and deletes, then reconciles" do
        us = location("United States", links: 0)
        typo = location("Chicgo")
        twin = location("Chicago, Illinois")
        hope = location("Hope")
        junk = location("61)")
        rename = decide(typo, :rename, new_name: "Chicago")
        merge = decide(twin, :merge, target_category: typo)
        retype = decide(hope, :retype, new_category_type: ::Category.category_types["subject"])
        parent = decide(typo, :set_parent, parent_chain: ["United States"])
        delete = decide(junk, :delete)

        result = Applier.call(run: "r1")

        assert_equal "Chicago", typo.reload.name
        assert_equal typo, twin.reload.merged_into
        assert hope.reload.subject?
        assert_equal us.id, typo.parent_id
        assert junk.reload.deleted?
        assert CategoryItem.exists?(category: us, item: @book, source: :inherited)
        assert_equal %w[applied] * 5, [rename, merge, retype, parent, delete].map { |d| d.reload.status }
        assert_equal 1, result.data["merge"]
      end

      test "creates missing chain parents with their own parents and records them as kept" do
        chicago = location("Chicago")
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States", "North America"])

        result = Applier.call(run: "r1")

        illinois = ::Books::Category.find_by!(name: "Illinois", category_type: :location)
        assert_equal ["United States", "North America"], illinois.ancestors.map(&:name)
        assert_equal illinois, chicago.reload.parent
        assert_equal 3, result.data["created"]
        assert CategoryCleanupDecision.exists?(category: illinois, stage: "apply", action: :keep, status: :applied)
        assert CategoryItem.exists?(category: illinois.parent.parent, item: @book, source: :inherited)
      end

      test "a category changed after propose gets stale decisions" do
        place = location("Chicgo")
        decision = decide(place, :rename, new_name: "Chicago")
        place.update!(name: "Chicago, IL")

        Applier.call(run: "r1")

        assert decision.reload.stale?
        assert_equal "Chicago, IL", place.reload.name
      end

      test "a failing decision is marked failed and the rest still apply" do
        gone = location("Gone Target")
        source = location("Source")
        ok = location("chicago")
        failing = decide(source, :merge, target_category: gone)
        gone.update_columns(deleted: true)
        rename = decide(ok, :rename, new_name: "Chicago")

        Applier.call(run: "r1")

        assert failing.reload.failed?
        assert_match "gone", failing.error
        assert rename.reload.applied?
      end

      test "re-running is a no-op, including after a crash between phases" do
        typo = location("Chicgo")
        us = location("United States")
        rename = decide(typo, :rename, new_name: "Chicago")
        decide(typo, :set_parent, parent_chain: ["United States"])
        # Simulate a crash after the rename phase: the rename landed, the set_parent didn't.
        typo.update!(name: "Chicago")
        rename.update!(status: :applied)

        Applier.call(run: "r1")
        assert_equal us, typo.reload.parent

        assert_no_difference -> { CategoryCleanupDecision.applied.count } do
          result = Applier.call(run: "r1")
          assert_equal 0, result.data.values.sum
        end
      end

      test "only_rules applies rule decisions and leaves ai ones proposed" do
        rule_place = location("paris")
        ai_place = location("Lyons")
        decide(rule_place, :rename, new_name: "Paris")
        ai = decide(ai_place, :rename, new_name: "Lyon", decided_by: :ai)

        Applier.call(run: "r1", only_rules: true)

        assert_equal "Paris", rule_place.reload.name
        assert ai.reload.proposed?
      end

      test "never touches a protected category" do
        fiction = categories(:books_fiction_genre)
        ::Books::Category.stubs(:protected_ids).returns([fiction.id])
        decision = decide(fiction, :rename, new_name: "Fiction Books")

        Applier.call(run: "r1")

        assert decision.reload.failed?
        assert_equal "Fiction", fiction.reload.name
      end

      test "leaves music categories alone" do
        rock = categories(:music_rock_genre)
        before = [rock.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
        decide(location("paris"), :rename, new_name: "Paris")

        Applier.call(run: "r1")

        assert_equal before, [rock.reload.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
      end

      test "refuses to delete a place that has places under it" do
        parent = location("Somewhere")
        ::Books::Category.create!(name: "Inside", category_type: :location, parent: parent)
        decision = decide(parent, :delete)

        Applier.call(run: "r1")

        assert decision.reload.failed?
        refute parent.reload.deleted?
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/category_cleanup/location_lookup_test.rb test/lib/services/category_cleanup/applier_test.rb`
Expected: FAIL (`uninitialized constant ...LocationLookup`, `...Applier`).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/location_lookup.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Live books locations by comparison key, built at apply time (after the
    # renames and merges have landed) so set_parent resolves parent names
    # against the vocabulary as it now is. Names beat alternative names; the
    # most-linked category wins a shared key.
    class LocationLookup
      def initialize
        @by_key = {}
        categories = ::Books::Category.active.where(category_type: :location).order(item_count: :desc, id: :asc).to_a
        categories.each { |category| @by_key[NameNormalizer.twin_key(category.name)] ||= category.id }
        categories.each do |category|
          category.alternative_names.each { |alt| @by_key[NameNormalizer.twin_key(alt)] ||= category.id }
        end
      end

      def register(category)
        @by_key[NameNormalizer.twin_key(category.name)] ||= category.id
      end

      def find(name)
        return nil if name.blank?

        @by_key[NameNormalizer.twin_key(name)]
      end
    end
  end
end
```

`app/lib/services/category_cleanup/applier.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.3: executes a run's proposed decisions in dependency order --
    # rename, merge, retype, create missing parents, set parent, delete -- then
    # reconciles inherited links once. Staleness is checked for every decision
    # before anything is applied. Each decision is its own savepoint: a failure
    # marks that decision `failed` and the run carries on. Re-running only
    # touches decisions still `proposed`, so it is idempotent.
    class Applier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      COMPARED = %w[name category_type parent_id deleted].freeze

      def self.call(run:, only_rules: false)
        new(run: run, only_rules: only_rules).call
      end

      def initialize(run:, only_rules: false)
        @run = run
        @only_rules = only_rules
        @stats = Hash.new(0)
      end

      def call
        mark_stale
        %w[rename merge retype].each { |action| apply_each(action) }
        @lookup = LocationLookup.new
        create_missing_parents
        apply_each("set_parent")
        apply_each("delete")
        kept = pending.where(action: :keep).update_all(status: ::CategoryCleanupDecision.statuses.fetch("applied"), updated_at: Time.current)
        @stats["keep"] += kept if kept.positive?

        changed = @stats.except("keep", "stale", "failed").values.sum
        ::Categories::AncestorReconciler.call if changed.positive?
        Result.new(success?: true, data: @stats.to_h, errors: [])
      end

      private

      def pending
        scope = ::CategoryCleanupDecision.for_run(@run).proposed
        @only_rules ? scope.decided_by_rule : scope
      end

      def mark_stale
        applied = ::CategoryCleanupDecision.for_run(@run).applied.to_a.group_by(&:category_id)
        pending.includes(:category).find_each do |decision|
          next if unchanged?(decision, applied.fetch(decision.category_id, []))

          decision.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("stale"),
            error: "Category changed after this decision was proposed", updated_at: Time.current)
          @stats["stale"] += 1
        end
      end

      # The snapshot, adjusted for decisions of this run that already landed
      # (a re-run after a crash between phases must not call those stale).
      def unchanged?(decision, applied)
        category = decision.category
        expected = decision.category_snapshot.slice(*COMPARED)
        applied.each do |done|
          expected["name"] = done.new_name if done.action_rename?
          expected["parent_id"] = category.parent_id if done.action_set_parent?
          expected["category_type"] = ::Category.category_types.key(done.new_category_type) if done.action_retype?
        end
        current = {"name" => category.name, "category_type" => category.category_type, "parent_id" => category.parent_id, "deleted" => category.deleted}
        current == expected
      end

      def apply_each(action)
        pending.where(action: action).find_each { |decision| apply_one(decision) }
      end

      def apply_one(decision)
        ::Category.transaction(requires_new: true) do
          send(:"apply_#{decision.action}", decision)
          decision.update!(status: :applied, error: nil)
        end
        @stats[decision.action] += 1
      rescue => e
        decision.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("failed"), error: e.message.truncate(500), updated_at: Time.current)
        @stats["failed"] += 1
      end

      def apply_rename(decision)
        live_category!(decision).update!(name: decision.new_name)
      end

      def apply_merge(decision)
        target = decision.target_category&.canonical
        raise "merge target is gone" if target.nil?

        ::Categories::Merger.new(category: live_category!(decision), category_to_merge_with: target).merge
      end

      def apply_retype(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        category.update!(category_type: ::Category.category_types.key(decision.new_category_type), parent_id: nil)
      end

      def apply_set_parent(decision)
        category = live_category!(decision)
        parent_id = @lookup.find(decision.parent_chain.first)
        raise "parent #{decision.parent_chain.first.inspect} not found" if parent_id.nil?
        raise "a place can't be its own parent" if parent_id == category.id

        category.update!(parent_id: parent_id)
      end

      def apply_delete(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        ::Categories::Deleter.new(category: category, soft: true).delete
      end

      def live_category!(decision)
        category = ::Books::Category.find_by(id: decision.category_id)
        raise "category is gone" if category.nil? || category.deleted?
        raise "#{category.name} is a protected book-type category" if ::Books::Category.protected_ids.include?(category.id)

        category
      end

      # Chain names that match no live location become new locations. Each
      # takes its parent from the next name in the first chain (by decision id)
      # that mentions it, and gets an applied `keep` so later syncs see it as
      # decided.
      def create_missing_parents
        wanted = {}
        pending.action_set_parent.order(:id).each do |decision|
          decision.parent_chain.each_with_index do |name, index|
            key = NameNormalizer.twin_key(name)
            next if @lookup.find(name) || wanted.key?(key)

            wanted[key] = [name, decision.parent_chain[index + 1]]
          end
        end

        created = wanted.values.map do |name, parent_name|
          category = ::Books::Category.create!(name: name, category_type: :location)
          @lookup.register(category)
          record_created(category)
          @stats["created"] += 1
          [category, parent_name]
        end

        created.each do |category, parent_name|
          parent_id = @lookup.find(parent_name)
          category.update!(parent_id: parent_id) if parent_id && parent_id != category.id
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[category cleanup] #{category.name}: parent #{parent_name.inspect} refused (#{e.message}); left as a root")
        end
      end

      def record_created(category)
        ::CategoryCleanupDecision.create!(
          category: category, run: @run, stage: "apply", action: :keep, decided_by: :rule, status: :applied,
          reason: "Created as a parent in the location hierarchy",
          category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/category_cleanup`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup test/lib/services/category_cleanup
git add web-app/app/lib/services/category_cleanup web-app/test/lib/services/category_cleanup
git commit -m "Category cleanup: idempotent applier with stale detection and parent creation"
```

---

### Task 16: Report, calibration, cost guard, and the cleanup rake tasks

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/report.rb`
- Create: `web-app/app/lib/services/category_cleanup/calibrator.rb`
- Create: `web-app/app/lib/services/category_cleanup/cost_guard.rb`
- Create: `web-app/lib/tasks/category_cleanup.rake`
- Test: `web-app/test/lib/services/category_cleanup/report_test.rb`, `.../calibrator_test.rb`, `.../cost_guard_test.rb`, `web-app/test/tasks/category_cleanup_rake_test.rb`

**Interfaces:**
- Consumes: Tasks 11, 14, 15.
- Produces: `Report.call(run:, out_dir: Rails.root.join("tmp")) → Result` (`data: {lines: Array<String>, csv_path: String}`); `Calibrator.call(run:, category_type:, sample_size: 200, seed: 42, sizes: [1, 10, 25]) → Result` (`data: {sizes: [{size:, compared:, agreement:, disagreements: [...]}]}`); `CostGuard.check!(calls:, force: false) → Float` (raises `CostGuard::TooExpensive`); rake `categories:cleanup:propose[run,stage]`, `:report[run]`, `:reject[run,ids]`, `:apply[run]`, `:calibrate[run,type]`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/category_cleanup/cost_guard_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class CostGuardTest < ActiveSupport::TestCase
      setup do
        Rails.configuration.x.categories_cleanup.stubs(:estimated_cost_per_call).returns(0.01)
        Rails.configuration.x.categories_cleanup.stubs(:max_unforced_cost).returns(50)
      end

      test "returns the estimate under the limit" do
        assert_in_delta 10.0, CostGuard.check!(calls: 1000)
      end

      test "refuses over the limit unless forced" do
        assert_raises(CostGuard::TooExpensive) { CostGuard.check!(calls: 6000) }
        assert_in_delta 60.0, CostGuard.check!(calls: 6000, force: true)
      end
    end
  end
end
```

`test/lib/services/category_cleanup/report_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class ReportTest < ActiveSupport::TestCase
      def decide(category, action, **attrs)
        CategoryCleanupDecision.create!({category: category, run: "r1", stage: "locations_head", action: action, decided_by: :ai,
          category_snapshot: CategoryCleanupDecision.snapshot_of(category)}.merge(attrs))
      end

      test "summarises counts, merges, created parents, roots, ambiguous names and failures, and writes a CSV" do
        target = ::Books::Category.create!(name: "Washington, D.C.", category_type: :location)
        source = ::Books::Category.create!(name: "Washington DC", category_type: :location, item_count: 40)
        chicago = ::Books::Category.create!(name: "Chicago", category_type: :location)
        europe = ::Books::Category.create!(name: "Europe", category_type: :location)
        georgia = ::Books::Category.create!(name: "Georgia", category_type: :location)
        decide(source, :merge, target_category: target)
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States"])
        decide(europe, :keep, place_kind: "continent")
        decide(georgia, :keep, ambiguous: true)
        decide(chicago, :merge, status: :failed, error: "merge_into \"Atlantis\" matches no location")

        result = Report.call(run: "r1", out_dir: Dir.mktmpdir)
        text = result.data[:lines].join("\n")

        assert_includes text, "Washington DC (40) -> Washington, D.C."
        assert_includes text, "Illinois"
        assert_includes text, "Europe (continent)"
        assert_includes text, "Georgia"
        assert_includes text, "Atlantis"
        assert File.exist?(result.data[:csv_path])
        assert_equal 6, CSV.read(result.data[:csv_path]).size
      end
    end
  end
end
```

`test/lib/services/category_cleanup/calibrator_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class CalibratorTest < ActiveSupport::TestCase
      LocationTask = ::Services::Ai::Tasks::CategoryCleanup::LocationTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(5)
        ::Books::Category.where(category_type: :location).update_all(deleted: true)
        @places = %w[Kilwa Orapa].map do |name|
          record = ::Books::Category.create!(name: name, category_type: :location)
          CategoryItem.create!(category: record, item: books_books(:war_and_peace))
          record
        end
      end

      def answer(key, chain)
        {key: key, verdict: "real_place", canonical_name: "x", merge_into: nil, parent_chain: chain,
         place_kind: "city", retype_to: nil, ambiguous: false, reason: ""}
      end

      test "measures how often batched answers agree with one-at-a-time answers and writes nothing" do
        one_by_one = [
          {"1" => answer("1", ["Tanzania"])},
          {"1" => answer("1", ["Botswana"])}
        ]
        batched = [{"1" => answer("1", ["Tanzania"]), "2" => answer("2", ["Namibia"])}]
        responses = (one_by_one + batched).map { |results| ::Services::Ai::Result.new(success: true, data: {results: results}) }
        LocationTask.any_instance.stubs(:call).returns(*responses)

        result = Calibrator.call(run: "r1", category_type: "location", sample_size: 2, seed: 1, sizes: [1, 2])

        row = result.data[:sizes].sole
        assert_equal 2, row[:size]
        assert_equal 2, row[:compared]
        assert_in_delta 0.5, row[:agreement]
        assert_equal 1, row[:disagreements].size
        assert CategoryCleanupDecision.none?
      end
    end
  end
end
```

(The sample is drawn with `Random.new(seed)`; if seed 1 orders the two places the other way, swap the two one-by-one answers rather than changing the seed. The assertion that matters is 1 agreement of 2.)

`test/tasks/category_cleanup_rake_test.rb`:

```ruby
require "test_helper"
require "rake"

class CategoryCleanupRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    %w[categories:cleanup:propose categories:cleanup:reject categories:cleanup:apply].each { |name| Rake::Task[name].reenable }
  end

  test "propose rules writes rule decisions" do
    place = ::Books::Category.create!(name: "Japan (", category_type: :location)
    CategoryItem.create!(category: place, item: books_books(:war_and_peace))

    assert_output(/Rules:/) { Rake::Task["categories:cleanup:propose"].invoke("t1", "rules") }

    assert CategoryCleanupDecision.exists?(run: "t1", category: place)
  end

  test "an AI stage over the cost limit aborts without calling the AI" do
    Services::CategoryCleanup::AiPass.any_instance.stubs(:call_count).returns(1_000_000)
    Services::CategoryCleanup::AiPass.any_instance.expects(:call).never

    assert_raises(SystemExit) do
      capture_io { Rake::Task["categories:cleanup:propose"].invoke("t1", "locations_head") }
    end
  end

  test "reject marks the given decisions rejected" do
    decision = CategoryCleanupDecision.create!(category: categories(:books_france_location), run: "t1", stage: "rules", action: :keep, decided_by: :rule)

    capture_io { Rake::Task["categories:cleanup:reject"].invoke("t1", decision.id.to_s) }

    assert decision.reload.rejected?
  end
end
```

(If `test/tasks/` has an existing helper for invoking rake tasks, use it instead of the `setup` above.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/category_cleanup test/tasks/category_cleanup_rake_test.rb`
Expected: FAIL (missing constants and tasks).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/cost_guard.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # A propose stage prints its estimated cost and refuses to start above
    # max_unforced_cost unless forced (spec §7).
    class CostGuard
      class TooExpensive < StandardError; end

      def self.check!(calls:, force: false)
        config = Rails.configuration.x.categories_cleanup
        estimate = calls * config.estimated_cost_per_call
        if estimate > config.max_unforced_cost && !force
          raise TooExpensive, format("Estimated $%.2f for %d calls is over $%d; rerun with FORCE=1", estimate, calls, config.max_unforced_cost)
        end

        estimate
      end
    end
  end
end
```

`app/lib/services/category_cleanup/report.rb`:

```ruby
# frozen_string_literal: true

require "csv"

module Services
  module CategoryCleanup
    # What the owner reviews before apply (spec §4.3): counts, the largest
    # merges, the locations apply would create, proposed roots, ambiguous
    # names, failures, and seeded random samples per action. The full list
    # goes to a CSV.
    class Report
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SAMPLE_SIZE = 25
      TOP_MERGES = 50

      def self.call(run:, out_dir: Rails.root.join("tmp"))
        new(run: run, out_dir: out_dir).call
      end

      def initialize(run:, out_dir:)
        @run = run
        @out_dir = Pathname(out_dir)
      end

      def call
        lines = ["Category cleanup run #{@run}: #{decisions.count} decisions"]
        section(lines, "By stage, action and status") do
          decisions.group(:stage, :action, :status).count.sort_by { |key, _| key.map(&:to_s) }
            .map { |(stage, action, status), count| "#{stage} #{action} #{status}: #{count}" }
        end
        section(lines, "Largest merges (links moved)") { largest_merges }
        section(lines, "Locations apply would create") { would_create }
        section(lines, "Proposed roots") do
          decisions.proposed.action_keep.where.not(place_kind: nil).includes(:category).map { |d| "#{d.category.name} (#{d.place_kind})" }.sort
        end
        section(lines, "Ambiguous names") { decisions.where(ambiguous: true).map { |d| d.category_snapshot["name"] }.uniq.sort }
        section(lines, "Failed") { decisions.failed.map { |d| "#{d.category_snapshot["name"]} [#{d.action}]: #{d.error}" } }
        ::CategoryCleanupDecision.actions.each_key do |action|
          section(lines, "Sample: #{action}") do
            decisions.proposed.where(action: action).includes(:target_category)
              .order(Arel.sql("md5(category_cleanup_decisions.id::text)")).limit(SAMPLE_SIZE).map { |d| describe(d) }
          end
        end

        Result.new(success?: true, data: {lines: lines, csv_path: write_csv.to_s}, errors: [])
      end

      private

      def decisions = ::CategoryCleanupDecision.for_run(@run)

      def section(lines, title)
        rows = yield
        lines << "" << "#{title}:"
        lines.concat(rows.empty? ? ["  (none)"] : rows.map { |row| "  #{row}" })
      end

      def largest_merges
        decisions.proposed.action_merge.includes(:target_category).to_a
          .sort_by { |d| -d.category_snapshot["item_count"].to_i }.first(TOP_MERGES)
          .map { |d| "#{d.category_snapshot["name"]} (#{d.category_snapshot["item_count"]}) -> #{d.target_category&.name}" }
      end

      def would_create
        lookup = LocationLookup.new
        decisions.proposed.action_set_parent.flat_map(&:parent_chain)
          .uniq { |name| NameNormalizer.twin_key(name) }
          .reject { |name| lookup.find(name) }
          .sort
      end

      def describe(decision)
        detail = case decision.action
        when "rename" then decision.new_name
        when "merge" then decision.target_category&.name
        when "set_parent" then decision.parent_chain.join(" > ")
        when "retype" then ::Category.category_types.key(decision.new_category_type)
        end
        ["#{decision.category_snapshot["name"]} -> #{decision.action}", detail, ("(#{decision.reason})" if decision.reason.present?)].compact.join(" ")
      end

      def write_csv
        FileUtils.mkdir_p(@out_dir)
        path = @out_dir.join("category_cleanup_#{@run.parameterize}.csv")
        CSV.open(path, "w") do |csv|
          csv << %w[id stage status decided_by action category_id name category_type links new_name target parent_chain new_category_type place_kind ambiguous reason error]
          decisions.includes(:target_category).order(:id).find_each do |d|
            snapshot = d.category_snapshot
            csv << [d.id, d.stage, d.status, d.decided_by, d.action, d.category_id, snapshot["name"], snapshot["category_type"], snapshot["item_count"],
              d.new_name, d.target_category&.name, d.parent_chain.join(" > "), d.new_category_type && ::Category.category_types.key(d.new_category_type),
              d.place_kind, d.ambiguous, d.reason, d.error]
          end
        end
        path
      end
    end
  end
end
```

`app/lib/services/category_cleanup/calibrator.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.4: runs a seeded sample of tail categories through the AI at
    # several batch sizes and reports how often each batched answer agrees with
    # the one-at-a-time answer. Writes no decisions; the owner reads the
    # numbers and sets config.x.categories_cleanup.tail_batch_size.
    class Calibrator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      SIZES = [1, 10, 25].freeze

      def self.call(run:, category_type:, sample_size: 200, seed: 42, sizes: SIZES)
        new(run: run, category_type: category_type, sample_size: sample_size, seed: seed, sizes: sizes).call
      end

      def initialize(run:, category_type:, sample_size:, seed:, sizes:)
        @run = run
        @category_type = category_type.to_s
        @sample_size = sample_size
        @seed = seed
        @sizes = sizes
      end

      def call
        index = NameIndex.new(run: @run, category_type: @category_type)
        head_min = Rails.configuration.x.categories_cleanup.head_min_links
        tail = index.entries.select { |entry| entry.links < head_min }.sort_by(&:id)
        sample = tail.sample([@sample_size, tail.size].min, random: Random.new(@seed))
        known = index.head_names

        answers = @sizes.to_h { |size| [size, ask(sample, size, known)] }
        reference = answers.fetch(@sizes.first)
        rows = @sizes.drop(1).map { |size| compare(size, reference, answers.fetch(size)) }
        Result.new(success?: true, data: {sample: sample.size, sizes: rows}, errors: [])
      end

      private

      def ask(sample, size, known)
        sample.each_slice(size).each_with_object({}) do |batch, out|
          entries = batch.each_with_index.map { |entry, index| AiPass.task_entry(entry, (index + 1).to_s) }
          result = AiPass.task_class(@category_type).new(entries: entries, known_names: known, tier: :tail).call
          next unless result.success?

          batch.each_with_index do |entry, index|
            answer = result.data[:results][(index + 1).to_s]
            out[entry.id] = {name: entry.name, signature: signature(answer)} if answer
          end
        end
      end

      # What must match for two answers to count as the same decision.
      def signature(answer)
        key = ->(name) { NameNormalizer.twin_key(name.to_s) }
        if @category_type == "location"
          [answer[:verdict], key.call(answer[:merge_into]), key.call(answer[:parent_chain].first), key.call(answer[:canonical_name])]
        else
          [answer[:action], key.call(answer[:name]), key.call(answer[:merge_into])]
        end
      end

      def compare(size, reference, batched)
        compared = reference.keys & batched.keys
        disagreements = compared.reject { |id| reference[id][:signature] == batched[id][:signature] }
        {
          size: size,
          compared: compared.size,
          agreement: compared.empty? ? 0.0 : (compared.size - disagreements.size).fdiv(compared.size),
          disagreements: disagreements.map { |id| {name: reference[id][:name], one_at_a_time: reference[id][:signature], batched: batched[id][:signature]} }
        }
      end
    end
  end
end
```

`lib/tasks/category_cleanup.rake`:

```ruby
namespace :categories do
  namespace :cleanup do
    desc "Propose decisions for one stage: bin/rails 'categories:cleanup:propose[RUN,STAGE]'. " \
      "Stages: rules, locations_head, locations_tail, subjects_head, subjects_tail. LIMIT=n, REDO=1, FORCE=1"
    task :propose, [:run, :stage] => :environment do |_task, args|
      run = args[:run].to_s
      stage = args[:stage].to_s
      ai_stages = {
        "locations_head" => ["location", :head], "locations_tail" => ["location", :tail],
        "subjects_head" => ["subject", :head], "subjects_tail" => ["subject", :tail]
      }
      abort "Usage: bin/rails 'categories:cleanup:propose[RUN,STAGE]' (STAGE: rules, #{ai_stages.keys.join(", ")})" if run.blank? || (stage != "rules" && !ai_stages.key?(stage))

      if stage == "rules"
        result = ::Services::CategoryCleanup::RulePass.call(run: run)
        puts "Rules: #{result.data[:decisions]} decisions #{result.data[:by_action].inspect}"
        next
      end

      ::CategoryCleanupDecision.for_run(run).where(stage: stage, status: %i[proposed failed]).delete_all if ENV["REDO"] == "1"
      type, tier = ai_stages.fetch(stage)
      pass = ::Services::CategoryCleanup::AiPass.new(run: run, category_type: type, tier: tier, limit: ENV["LIMIT"])
      calls = pass.call_count
      begin
        estimate = ::Services::CategoryCleanup::CostGuard.check!(calls: calls, force: ENV["FORCE"] == "1")
      rescue ::Services::CategoryCleanup::CostGuard::TooExpensive => e
        abort e.message
      end
      puts format("%s: %d calls, estimated $%.2f", stage, calls, estimate)
      puts pass.call.data.inspect
    end

    desc "Print the review report for a run and write the full CSV to tmp/: bin/rails 'categories:cleanup:report[RUN]'"
    task :report, [:run] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:report[RUN]'" if args[:run].blank?
      result = ::Services::CategoryCleanup::Report.call(run: args[:run])
      puts result.data[:lines]
      puts "", "CSV: #{result.data[:csv_path]}"
    end

    desc "Reject decisions by id (space-separated): bin/rails 'categories:cleanup:reject[RUN,12 15 19]'"
    task :reject, [:run, :ids] => :environment do |_task, args|
      ids = args[:ids].to_s.split.map(&:to_i).select(&:positive?)
      abort "Usage: bin/rails 'categories:cleanup:reject[RUN,ID ID ...]'" if args[:run].blank? || ids.empty?
      count = ::CategoryCleanupDecision.for_run(args[:run]).proposed.where(id: ids).update_all(status: ::CategoryCleanupDecision.statuses.fetch("rejected"), updated_at: Time.current)
      puts "Rejected #{count} decision(s)"
    end

    desc "Apply a run's proposed decisions: bin/rails 'categories:cleanup:apply[RUN]'"
    task :apply, [:run] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:apply[RUN]'" if args[:run].blank?
      result = ::Services::CategoryCleanup::Applier.call(run: args[:run])
      puts "Applied: #{result.data.inspect}"
    end

    desc "Measure batch-size agreement on the tail (writes no decisions): bin/rails 'categories:cleanup:calibrate[RUN,location]'"
    task :calibrate, [:run, :type] => :environment do |_task, args|
      abort "Usage: bin/rails 'categories:cleanup:calibrate[RUN,location|subject]'" unless args[:run].present? && %w[location subject].include?(args[:type])
      sizes = ::Services::CategoryCleanup::Calibrator::SIZES
      calls = sizes.sum { |size| (200 / size.to_f).ceil }
      ::Services::CategoryCleanup::CostGuard.check!(calls: calls, force: ENV["FORCE"] == "1")
      result = ::Services::CategoryCleanup::Calibrator.call(run: args[:run], category_type: args[:type])
      puts "Sample: #{result.data[:sample]} tail #{args[:type]}s"
      result.data[:sizes].each do |row|
        puts format("Batch size %d: %.1f%% agreement over %d categories", row[:size], row[:agreement] * 100, row[:compared])
        row[:disagreements].each { |d| puts "  #{d[:name]}: one-at-a-time #{d[:one_at_a_time].inspect} vs batched #{d[:batched].inspect}" }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/category_cleanup test/tasks/category_cleanup_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup lib/tasks/category_cleanup.rake test/lib/services/category_cleanup test/tasks
git add web-app/app/lib/services/category_cleanup web-app/lib/tasks/category_cleanup.rake web-app/test
git commit -m "Category cleanup: review report, batch-size calibration, cost guard, rake tasks"
```

---

### Task 17: Post-sync cleanup step

**Files:**
- Create: `web-app/app/lib/services/category_cleanup/sync_step.rb`
- Modify: `web-app/app/lib/services/books_migration/sync.rb` (steps list)
- Test: `web-app/test/lib/services/category_cleanup/sync_step_test.rb`, `web-app/test/lib/services/books_migration/sync_test.rb`

**Interfaces:**
- Consumes: Task 11 (`RulePass` with `only_ids`/`stage: "sync"`), Task 15 (`Applier` with `only_rules: true`).
- Produces: `SyncStep.call → Result` (`data: {skipped: true}` or `{new_categories:, decisions:, applied:}`); sync step `"category_cleanup"` immediately before `"location_ancestors"`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/category_cleanup/sync_step_test.rb`:

```ruby
require "test_helper"

module Services
  module CategoryCleanup
    class SyncStepTest < ActiveSupport::TestCase
      def place(name, links: 1)
        record = ::Books::Category.create!(name: name, category_type: :location)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def mark_decided(category)
        CategoryCleanupDecision.create!(category: category, run: "main", stage: "locations_head", action: :keep,
          decided_by: :ai, status: :applied, category_snapshot: CategoryCleanupDecision.snapshot_of(category))
      end

      test "does nothing before any cleanup has been applied" do
        place("georgia")
        assert SyncStep.call.data[:skipped]
        assert CategoryCleanupDecision.none?
      end

      test "merges an incoming twin into the existing category and applies it" do
        existing = place("Georgia", links: 1)
        mark_decided(existing)
        incoming = place("georgia", links: 2)

        result = SyncStep.call

        assert result.success?
        assert_equal existing, incoming.reload.merged_into
      end

      test "leaves an incoming category the rules can't improve undecided" do
        mark_decided(place("Georgia"))
        fresh = place("Brand New Place")

        SyncStep.call

        assert CategoryCleanupDecision.where(category: fresh).none?
        refute fresh.reload.deleted?
      end
    end
  end
end
```

Append to `test/lib/services/books_migration/sync_test.rb`:

```ruby
  test "runs the category cleanup step just before reconciling location ancestors" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    labels = result.data[:steps].map(&:first)
    assert_equal labels.index("location_ancestors") - 1, labels.index("category_cleanup")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/category_cleanup/sync_step_test.rb test/lib/services/books_migration/sync_test.rb`
Expected: FAIL (`uninitialized constant ...SyncStep`; no `category_cleanup` step).

- [ ] **Step 3: Implement**

`app/lib/services/category_cleanup/sync_step.rb`:

```ruby
# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.5: until cutover the weekly sync keeps bringing new legacy
    # categories. Once a cleanup has been applied, each sync runs the rules
    # pass for categories no run has decided yet (twins and alias matches
    # merge into the existing vocabulary) and applies those rule decisions
    # straight away. AI decisions are never auto-applied; what the rules can't
    # settle waits for the owner's next propose.
    class SyncStep
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        return result(skipped: true) unless ::CategoryCleanupDecision.applied.exists?

        new_ids = ::Books::Category.active
          .where(category_type: RulePass::TYPES)
          .where.not(id: ::CategoryCleanupDecision.select(:category_id))
          .pluck(:id)
        return result(new_categories: 0) if new_ids.empty?

        run = "sync-#{Time.current.utc.strftime("%Y%m%d%H%M%S")}"
        rules = RulePass.call(run: run, only_ids: new_ids, stage: "sync")
        applied = Applier.call(run: run, only_rules: true)
        result(new_categories: new_ids.size, decisions: rules.data[:decisions], applied: applied.data)
      end

      private

      def result(**data)
        Result.new(success?: true, data: data, errors: [])
      end
    end
  end
end
```

In `app/lib/services/books_migration/sync.rb#steps`, insert directly above the `location_ancestors` line added in Task 6:

```ruby
          ["category_cleanup", -> { ::Services::CategoryCleanup::SyncStep.call }],
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/category_cleanup test/lib/services/books_migration`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/category_cleanup/sync_step.rb app/lib/services/books_migration/sync.rb
git add web-app/app/lib/services/category_cleanup/sync_step.rb web-app/app/lib/services/books_migration/sync.rb web-app/test
git commit -m "Category cleanup: rules-only pass for new legacy categories after each sync"
```

---

### Task 18: Trim over-tagged books

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/location_trim_task.rb`
- Create: `web-app/app/lib/services/books/trim_locations.rb`
- Modify: `web-app/lib/tasks/categories.rake`
- Test: `web-app/test/lib/services/ai/tasks/books/location_trim_task_test.rb`, `web-app/test/lib/services/books/trim_locations_test.rb`

**Interfaces:**
- Consumes: Task 8 (`Books::LocationTrails`), Task 2 (`AncestorReconciler`), Task 1 (`CategoryItem.direct`, source enum).
- Produces: `Services::Ai::Tasks::Books::LocationTrimTask.new(book:, locations:)` where `locations` is `Array<LocationTrimTask::Location>` (`id:, trail:`), `#call → Services::Ai::Result` with `data: {keep_ids: Array<Integer>, reason: String}`; `Services::Books::TrimLocations.call(book:, dry_run: false, force: false) → Result` (`data: {kept:, removed:, reason:}` or `{skipped: String}`), `TrimLocations.candidate_ids(limit: nil) → Array<Integer>`, `TrimLocations::KIND = "books.location_trim"`; rake `categories:trim_locations[limit]` with `DRY_RUN=1`, `FORCE=1`.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/ai/tasks/books/location_trim_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class LocationTrimTaskTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @locations = [
              LocationTrimTask::Location.new(id: 11, trail: "Moscow, Russia"),
              LocationTrimTask::Location.new(id: 12, trail: "Paris, France")
            ]
            @task = LocationTrimTask.new(book: @book, locations: @locations)
          end

          test "runs on the standard role, parented on the book" do
            assert_equal :standard, @task.send(:task_role)
          end

          test "the prompt lists each location with its id and trail" do
            prompt = @task.send(:user_prompt)
            assert_includes prompt, @book.title
            assert_includes prompt, "[11] Moscow, Russia"
            assert_includes prompt, "[12] Paris, France"
          end

          test "drops ids that were not offered" do
            outcome = @task.send(:process_and_persist, {parsed: {keep_ids: [11, 99], reason: "Set in Moscow."}})

            assert outcome.success?
            assert_equal [11], outcome.data[:keep_ids]
          end

          test "the schema has keep_ids and reason" do
            assert_equal %w[keep_ids reason], LocationTrimTask::ResponseSchema.to_json_schema[:properties].keys.map(&:to_s)
          end
        end
      end
    end
  end
end
```

`test/lib/services/books/trim_locations_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    class TrimLocationsTest < ActiveSupport::TestCase
      TrimTask = ::Services::Ai::Tasks::Books::LocationTrimTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:max_direct_locations).returns(2)
        @book = books_books(:war_and_peace)
        @book.category_items.destroy_all
        @russia = ::Books::Category.create!(name: "Russia", category_type: :location)
        @moscow = ::Books::Category.create!(name: "Moscow", category_type: :location, parent: @russia)
        @peru = ::Books::Category.create!(name: "Peru", category_type: :location)
        @chile = ::Books::Category.create!(name: "Chile", category_type: :location)
        CategoryItem.create!(category: @moscow, item: @book)
        CategoryItem.create!(category: @peru, item: @book)
        CategoryItem.create!(category: @chile, item: @book, source: :admin)
        ::Categories::AncestorReconciler.call(item_ids: [@book.id])
      end

      def stub_keep(ids)
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {keep_ids: ids, reason: "Set in Moscow."}))
      end

      test "removes the legacy links the model did not keep, never admin links, and keeps inherited ones right" do
        stub_keep([@moscow.id])

        result = TrimLocations.call(book: @book)

        assert result.success?
        refute CategoryItem.exists?(category: @peru, item: @book)
        assert CategoryItem.exists?(category: @chile, item: @book)
        assert CategoryItem.exists?(category: @russia, item: @book, source: :inherited)
        assert_equal [@peru.id], result.data[:removed]
      end

      test "writes one ledger row and does not trim the same book twice unless forced" do
        stub_keep([@moscow.id])
        TrimLocations.call(book: @book)

        assert_equal 1, @book.enrichments.for_kind(TrimLocations::KIND).count
        assert_equal "already trimmed", TrimLocations.call(book: @book).data[:skipped]
      end

      test "a dry run writes nothing" do
        stub_keep([@moscow.id])

        result = TrimLocations.call(book: @book, dry_run: true)

        assert_equal [@peru.id], result.data[:removed]
        assert CategoryItem.exists?(category: @peru, item: @book)
        assert @book.enrichments.for_kind(TrimLocations::KIND).none?
      end

      test "a book at or under the limit is skipped without calling the AI" do
        CategoryItem.where(category: @peru, item: @book).destroy_all
        TrimTask.any_instance.expects(:call).never

        assert_equal "not over the limit", TrimLocations.call(book: @book).data[:skipped]
      end

      test "a failed AI call changes nothing" do
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: false, error: "timeout"))

        result = TrimLocations.call(book: @book)

        refute result.success?
        assert CategoryItem.exists?(category: @peru, item: @book)
      end

      test "candidate_ids lists books over the limit that were not trimmed yet" do
        assert_includes TrimLocations.candidate_ids, @book.id

        stub_keep([@moscow.id])
        TrimLocations.call(book: @book)

        refute_includes TrimLocations.candidate_ids, @book.id
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/location_trim_task_test.rb test/lib/services/books/trim_locations_test.rb`
Expected: FAIL (missing constants).

- [ ] **Step 3: Implement**

`app/lib/services/ai/tasks/books/location_trim_task.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Spec §5: picks which of a book's existing direct locations to keep.
        # The answer is a subset of the ids offered; anything else is dropped
        # in code, so the model can remove but never add.
        class LocationTrimTask < BaseTask
          Location = Struct.new(:id, :trail, keyword_init: true)

          attr_reader :book, :locations

          def initialize(book:, locations:, provider: nil, model: nil)
            @book = book
            @locations = locations
            super(parent: book, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def system_message
            <<~SYSTEM
              You are trimming the setting locations of one book. Old tagging attached every place a book mentions, sometimes hundreds; the book page should list only where the book is set.

              Return the ids of the locations to keep, chosen only from the list:
              - A novel, memoir or other narrative: the places where substantial parts of it take place, usually one to six.
              - Nonfiction that surveys many countries or the whole world: the continents or regions it covers, or an empty list when it is truly global.
              - Keep the most specific place that matters. Containing places are added automatically, so do not keep a country just because a city in it is kept.
              - Never return an id that is not in the list.
            SYSTEM
          end

          def user_prompt
            lines = ["Book: #{book.title.inspect}"]
            authors = book.authors.map(&:name)
            lines << "Author(s): #{authors.join(", ")}" if authors.any?
            lines << "First published: #{::Services::Books::YearLabel.call(book.first_published_year)}" if book.first_published_year.present?
            description = book.primary_description&.content
            lines << "Description: #{description}" if description.present?
            lines << "" << "Current locations:"
            locations.each { |location| lines << "[#{location.id}] #{location.trail}" }
            lines << "" << "Answer with keep_ids and a one-sentence reason."
            lines.join("\n")
          end

          def response_schema = ResponseSchema

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            raw = data.respond_to?(:keep_ids) ? data.keep_ids : (data[:keep_ids] || data["keep_ids"])
            reason = data.respond_to?(:reason) ? data.reason : (data[:reason] || data["reason"])
            offered = locations.map(&:id).to_set
            keep = Array(raw).select { |id| id.is_a?(Integer) && offered.include?(id) }.uniq
            Services::Ai::Result.new(success: true, data: {keep_ids: keep, reason: reason.to_s}, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :keep_ids, OpenAI::ArrayOf[Integer], doc: "Ids from the list to keep; empty when the book is truly global"
            required :reason, String, doc: "One sentence"
          end
        end
      end
    end
  end
end
```

`app/lib/services/books/trim_locations.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Spec §5: a book with more direct locations than max_direct_locations
    # (Running The World had 361) gets one AI call that keeps its primary
    # settings. Only `legacy` links are removed -- an admin's pick always
    # stays -- and the reconciler then drops inherited ancestors nothing needs.
    # Every run writes an Enrichment ledger row, so a book is trimmed once.
    class TrimLocations
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      KIND = "books.location_trim"

      def self.call(book:, dry_run: false, force: false)
        new(book: book, dry_run: dry_run, force: force).call
      end

      def self.candidate_ids(limit: nil)
        trimmed = ::Enrichment.for_kind(KIND).where(enrichable_type: "Books::Book").select(:enrichable_id)
        scope = direct_location_links
          .where.not(item_id: trimmed)
          .group(:item_id)
          .having("COUNT(*) > ?", Rails.configuration.x.categories_cleanup.max_direct_locations)
          .order(Arel.sql("COUNT(*) DESC"))
        scope = scope.limit(limit) if limit
        scope.pluck(:item_id)
      end

      def self.direct_location_links
        ::CategoryItem.direct.joins(:category).where(
          item_type: "Books::Book",
          categories: {type: "Books::Category", category_type: ::Category.category_types.fetch("location"), deleted: false}
        )
      end

      def initialize(book:, dry_run:, force:)
        @book = book
        @dry_run = dry_run
        @force = force
      end

      def call
        links = self.class.direct_location_links.where(item_id: @book.id).includes(:category).to_a
        return skipped("not over the limit") if links.size <= Rails.configuration.x.categories_cleanup.max_direct_locations
        return skipped("already trimmed") if !@force && @book.enrichments.for_kind(KIND).exists?

        result = ::Services::Ai::Tasks::Books::LocationTrimTask.new(book: @book, locations: offered(links)).call
        return Result.new(success?: false, data: {}, errors: [result.error]) unless result.success?

        keep = result.data[:keep_ids]
        removable = links.select { |link| link.source_legacy? && !keep.include?(link.category_id) }
        data = {kept: keep, removed: removable.map(&:category_id), reason: result.data[:reason]}
        return Result.new(success?: true, data: data.merge(dry_run: true), errors: []) if @dry_run

        ::CategoryItem.transaction do
          ::CategoryItem.where(id: removable.map(&:id)).destroy_all
          ::Categories::AncestorReconciler.call(item_ids: [@book.id])
          @book.enrichments.create!(
            kind: KIND, mode: :knowledge, outcome: removable.any? ? :applied : :nothing_to_apply,
            facts: {kept: keep, removed: data[:removed]}, ai_chat: result.ai_chat,
            provider: result.ai_chat&.provider, model: result.ai_chat&.model
          )
        end
        Result.new(success?: true, data: data, errors: [])
      end

      private

      def offered(links)
        trails = ::Books::LocationTrails.call(links.map(&:category))
        links.map do |link|
          trail = trails.fetch(link.category_id, [link.category]).map(&:name).join(", ")
          ::Services::Ai::Tasks::Books::LocationTrimTask::Location.new(id: link.category_id, trail: trail)
        end
      end

      def skipped(reason)
        Result.new(success?: true, data: {skipped: reason}, errors: [])
      end
    end
  end
end
```

Append to `lib/tasks/categories.rake`, inside `namespace :categories`:

```ruby
  desc "Trim books with too many direct locations (one AI call per book): bin/rails 'categories:trim_locations[100]' (DRY_RUN=1 prints, FORCE=1 re-trims)"
  task :trim_locations, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails 'categories:trim_locations[LIMIT]' -- a limit is required" unless limit.positive?

    dry_run = ENV["DRY_RUN"] == "1"
    ::Services::Books::TrimLocations.candidate_ids(limit: limit).each do |book_id|
      book = ::Books::Book.find(book_id)
      result = ::Services::Books::TrimLocations.call(book: book, dry_run: dry_run, force: ENV["FORCE"] == "1")
      status = result.success? ? result.data.inspect : "FAILED #{result.errors.join("; ")}"
      puts "#{book.title} (##{book.id}): #{status}"
    end
  end
```

(`::Books::Book.find(book_id)` takes an Integer here, so friendly_id's slug-first lookup can't misfire.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/services/ai/tasks/books/location_trim_task_test.rb test/lib/services/books/trim_locations_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/ai/tasks/books/location_trim_task.rb app/lib/services/books/trim_locations.rb lib/tasks/categories.rake test/lib/services
git add web-app/app/lib/services/ai/tasks/books/location_trim_task.rb web-app/app/lib/services/books/trim_locations.rb web-app/lib/tasks/categories.rake web-app/test/lib/services
git commit -m "Books: AI trim for books with too many direct locations"
```

---

### Task 19: E2E coverage and documentation

**Files:**
- Modify: `web-app/app/lib/services/e2e/prepare.rb`
- Modify: `web-app/test/lib/services/e2e/prepare_test.rb`
- Modify: `web-app/e2e/tests/books/book-detail.spec.ts`
- Modify: `web-app/e2e/tests/books/admin/categories.spec.ts`
- Create: `docs/features/books-categories.md`
- Create: `docs/data-quality/books-categories.md`
- Modify: `docs/features/books-legacy-sync.md`
- Modify: `docs/launch-todo.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `Services::E2e::Prepare::LOCATION_TRAIL`, `Services::E2e::Prepare::MERGE_TARGET_NAME`.

- [ ] **Step 1: Seed the E2E scratch data (TDD)**

Add to `test/lib/services/e2e/prepare_test.rb`, using that file's existing way of running `Prepare` successfully (its happy-path setup):

```ruby
  test "links the scratch book to a three-level scratch location trail and makes the merge target" do
    run_prepare_successfully

    book = ::Books::Book.find_by!(slug: Services::E2e::Prepare::SCRATCH_BOOK_SLUGS.first)
    town = ::Books::Category.find_by!(name: Services::E2e::Prepare::LOCATION_TRAIL.first, deleted: false)
    assert CategoryItem.exists?(category: town, item: book, source: :admin)
    assert_equal Services::E2e::Prepare::LOCATION_TRAIL.drop(1), town.ancestors.map(&:name)
    assert ::Books::Category.exists?(name: Services::E2e::Prepare::MERGE_TARGET_NAME, deleted: false)

    assert_no_difference -> { ::Books::Category.count } do
      run_prepare_successfully
    end
  end
```

(Replace `run_prepare_successfully` with the file's existing helper.) Run it, see it fail, then add to `Prepare`:

```ruby
      # Scratch rows for the book-page trail and admin merge specs. Nearest
      # first; the last is a root, so the book page shows only the first two.
      LOCATION_TRAIL = ["E2E Scratch Town", "E2E Scratch Region", "E2E Scratch Country"].freeze
      MERGE_TARGET_NAME = "E2E Merge Target"
```

call `seed_category_scratch` in `call` right after `clear_scratch_books(accounts)`, and add the private method:

```ruby
      # Idempotent. Touches only the scratch book and categories it names.
      def seed_category_scratch
        book = scratch_books.first
        return if book.nil?

        parent = nil
        LOCATION_TRAIL.reverse_each do |name|
          category = ::Books::Category.find_or_create_by!(name: name, category_type: :location, deleted: false)
          category.update!(parent_id: parent&.id) if category.parent_id != parent&.id
          parent = category
        end
        link = ::CategoryItem.find_or_initialize_by(category: parent, item: book)
        link.update!(source: :admin)
        ::Categories::AncestorReconciler.call(item_ids: [book.id])
        ::Books::Category.find_or_create_by!(name: MERGE_TARGET_NAME, category_type: :location, deleted: false)
      end
```

Run: `bin/rails test test/lib/services/e2e/prepare_test.rb` — Expected: PASS.

- [ ] **Step 2: Write the E2E specs**

Append to `e2e/tests/books/book-detail.spec.ts` (inside the `describe`):

```ts
  test('a location shows as a trail of links up to, not including, the root', async ({ page }) => {
    await page.goto('/book/headlong-hall');

    const trail = page.getByTestId('location-trail').filter({ hasText: 'E2E Scratch Town' });
    await expect(trail).toBeVisible();
    await expect(trail.getByRole('link', { name: 'E2E Scratch Region' })).toHaveAttribute('href', /e2e-scratch-region/);
    await expect(trail.getByRole('link', { name: 'E2E Scratch Country' })).toHaveCount(0);
  });
```

Append to `e2e/tests/books/admin/categories.spec.ts` (inside the `describe`):

```ts
  test("merges a category into another and its old URL redirects", async ({ page }) => {
    const name = `E2E Merge Source ${Date.now()}`;
    await page.goto("/admin/categories");
    await page.getByRole("link", { name: "New Category" }).click();
    await page.locator('input[name="books_category[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const sourceSlug = new URL(page.url()).pathname.split("/").pop();

    const mergeCard = page.getByTestId("merge-category");
    await mergeCard.getByPlaceholder("Search for the category to keep...").fill("E2E Merge Target");
    await mergeCard.locator("li.cursor-pointer").first().click();
    await mergeCard.getByRole("checkbox").check();
    await mergeCard.getByRole("button", { name: "Merge" }).click();

    await expect(page.getByRole("heading", { name: "E2E Merge Target", level: 1 })).toBeVisible();

    await page.goto(`/the-greatest/${sourceSlug}/books`);
    await expect(page).toHaveURL(/\/the-greatest\/e2e-merge-target\/books/);
  });
```

- [ ] **Step 3: Run the E2E suite against this worktree's server**

```bash
yarn build:all
bin/rails server -d
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

Expected: the `readlink` prints this worktree's `web-app` directory. If it prints another checkout, stop and tell the user — do not kill their server and do not use another port. Then:

```bash
yarn test:e2e e2e/tests/books/book-detail.spec.ts e2e/tests/books/admin/categories.spec.ts
kill "$(cat tmp/pids/server.pid)"
```

Expected: PASS. (`yarn test:e2e` runs `bin/rails e2e:prepare` itself, which seeds the scratch trail. Note that the dev database must have the Task 1 and Task 10 migrations applied; Task 1 Step 1 and Task 10 Step 1 already ran `db:migrate` against it.)

- [ ] **Step 4: Write the docs**

`docs/data-quality/books-categories.md` — a short header ("Measured in dev 2026-10-11; regenerate before acting"), the two tables from the spec's Problem section, and these queries verbatim, each under a heading saying what it measures:

```sql
-- Usage distribution per type (live categories, real link counts)
WITH c AS (
  SELECT c.id, c.category_type,
         (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id) AS n
  FROM categories c
  WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
)
SELECT category_type, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE n = 0) AS zero, COUNT(*) FILTER (WHERE n = 1) AS one,
       COUNT(*) FILTER (WHERE n BETWEEN 2 AND 4) AS two_4, COUNT(*) FILTER (WHERE n BETWEEN 5 AND 19) AS five_19,
       COUNT(*) FILTER (WHERE n >= 20) AS ge20, SUM(n) FILTER (WHERE n >= 20) AS links_ge20, SUM(n) AS links
FROM c GROUP BY 1;

-- Junk patterns
SELECT category_type,
       COUNT(*) FILTER (WHERE name ~ '[()\[\]]') AS brackets,
       COUNT(*) FILTER (WHERE name ~ '[,;:/]') AS punctuation,
       COUNT(*) FILTER (WHERE name ~ '[^\x01-\x7F]') AS non_ascii,
       COUNT(*) FILTER (WHERE name ~ '^[a-z]') AS lowercase_start
FROM categories
WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
GROUP BY 1;

-- Case/punctuation twin clusters
WITH c AS (
  SELECT category_type, lower(regexp_replace(name, '[^[:alnum:]]', '', 'g')) AS k
  FROM categories
  WHERE type = 'Books::Category' AND NOT deleted AND category_type IN (1, 2)
)
SELECT category_type, COUNT(*) AS clusters, SUM(n) AS categories
FROM (SELECT category_type, k, COUNT(*) AS n FROM c GROUP BY 1, 2 HAVING COUNT(*) > 1) x
GROUP BY 1;

-- Books by number of direct location links (over-tagging)
SELECT COUNT(*) FILTER (WHERE n > 15) AS over_15, COUNT(*) FILTER (WHERE n > 25) AS over_25, MAX(n) AS max
FROM (
  SELECT ci.item_id, COUNT(*) AS n
  FROM category_items ci JOIN categories c ON c.id = ci.category_id
  WHERE ci.item_type = 'Books::Book' AND ci.source <> 2 AND c.category_type = 1 AND NOT c.deleted
  GROUP BY 1
) x;
```

`docs/features/books-categories.md` — sections, in this order, each a few short paragraphs drawn from the spec:
1. **What subjects and locations are for** (browse pages first, similarity second; genres documented elsewhere).
2. **Naming rules** (spec §2, verbatim bullets).
3. **The location tree** (spec §3.1 rules; `Books::Category#ancestors`; `MAX_DEPTH`).
4. **Link sources** (`category_items.source`: legacy, admin, inherited; `Categories::AncestorReconciler` and who calls it; book page shows direct links as trails).
5. **Merging and renaming** (`merged_into_id`, `Category#canonical`, `Category.replace_merged_ids`, slug history; what redirects; protected book-type categories; the admin merge form).
6. **Browse threshold and alias search** (`config.x.books.browse_min_category_books`).
7. **The cleanup runbook** — the exact commands in order:
   `bin/snapshot-dev-db.sh --label pre-category-cleanup` (dev) / a fresh backup (production) →
   `bin/rails 'categories:cleanup:propose[RUN,rules]'` →
   `bin/rails 'categories:cleanup:propose[RUN,locations_head]'` → `subjects_head` →
   `bin/rails 'categories:cleanup:calibrate[RUN,location]'` and `[RUN,subject]`, set `tail_batch_size` →
   `locations_tail` → `subjects_tail` →
   `bin/rails 'categories:cleanup:report[RUN]'` → `reject[RUN,ids]` as needed →
   `bin/rails 'categories:cleanup:apply[RUN]'` →
   `bin/rails 'categories:trim_locations[100]'` with `DRY_RUN=1` first, then without →
   a second `propose[RUN2,locations_tail]` for categories the subject pass retyped into locations (and vice versa) →
   note that the weekly sync applies rule decisions to new legacy categories automatically (§4.5).
   Explain `LIMIT`, `REDO`, `FORCE`, and that every stage is resumable.
8. **Configuration** (the `config/initializers/categories.rb` values and what each controls).

Use the `avoid-ai-writing` skill on both new docs before committing.

`docs/features/books-legacy-sync.md` — add to the step list: links to a category merged here land on the merge target; the `category_cleanup` step applies rule decisions to new legacy categories once a cleanup has been applied; `location_ancestors` reconciles inherited links for the synced books.

`docs/launch-todo.md` — add a "Books categories cleanup" item: run the runbook in production from a fresh backup (propose → report → owner review → apply → trim), and that it can run before or after cutover because the post-sync step keeps new legacy categories in line.

- [ ] **Step 5: Full verification**

Run: `bin/rails test && bundle exec standardrb && CI=1 bin/rails zeitwerk:check`
Expected: all PASS; no new warning lines in the test output.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/e2e/prepare.rb web-app/test/lib/services/e2e web-app/e2e/tests/books docs/features/books-categories.md docs/data-quality/books-categories.md docs/features/books-legacy-sync.md docs/launch-todo.md
git commit -m "Books categories: E2E coverage, feature doc, data-quality queries, runbook"
```
