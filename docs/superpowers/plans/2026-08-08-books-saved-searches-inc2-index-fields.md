# Books Saved Searches — Increment 2: OpenSearch Index Fields

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the books OpenSearch index the six fields the saved-search query layer filters on, and keep the two rank-derived ones fresh after every ranking recalculation.

**Architecture:** Six mapping fields are added to `Search::Books::BookIndex` and emitted by `Books::Book#as_indexed_json`. Rank is read through a new `primary_ranked_item` scoped association preloaded in `model_includes`, so bulk indexing costs one extra query per batch and needs no cache. A generic `bulk_update` on `Search::Base::Index` performs partial document updates, and a books job uses it to refresh `ranked`/`ranked_position` after a recalc — chained from the same place the author-rankings job already chains.

**Tech Stack:** Rails 8.1, OpenSearch, Sidekiq, Minitest + fixtures + Mocha, `standardrb`.

**Spec:** `docs/superpowers/specs/2026-08-08-books-saved-searches-design.md` §5.

**Depends on:** increment 1 (merged, PR #209) — `books_books.book_length` exists.

## Global Constraints

- Run **all** commands from `web-app/`.
- Rails 8 enum syntax: `enum :name, {key: 0}` (colon prefix).
- Jobs are generated with `bin/rails generate sidekiq:job books/foo` — **NOT** `generate job` — and live in `app/sidekiq/`, not `app/jobs/`.
- Business logic lives in `app/lib/`, never `app/services/`.
- Lint with `bundle exec standardrb`, **never** `bin/rubocop`. Do **not** run `bin/brakeman`.
- Tests mirror the namespace: `Search::Books::BookIndexTest`, `Books::ReindexRankedFieldsJobTest`.
- **Never run a destructive DB command against development.** `ActiveRecord::FixtureSet.create_fixtures` truncates every table it names — read fixture YAML with `sed` instead.
- Comment only to explain a non-obvious **why**, never the *what*.
- Before any commit that finishes a task: `bin/rails test` and `bundle exec standardrb` must both pass.

## Environment Notes

- **OpenSearch must be running** for the index tests. Test index names are suffixed with the process id (`books_books_test_12345`), so parallel test workers do not collide. Existing index tests create and delete their index in `setup`/`teardown` — follow that pattern.
- The development books index has ~126,282 documents. Task 4 recreates it; that is expected and safe (the search index is derived data, unlike the development *database*, which is not).

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/search/books/book_index.rb` | Six new mapping fields; `model_includes` gains four preloads |
| `app/models/books/book.rb` | `primary_ranked_item` association; six new `as_indexed_json` keys |
| `app/lib/search/base/index.rb` | New generic `bulk_update` partial-update method |
| `app/sidekiq/books/reindex_ranked_fields_job.rb` | Refresh `ranked`/`ranked_position` after a recalc |
| `app/sidekiq/calculate_rankings_job.rb` | Chain the new job for `Books::RankingConfiguration` |
| `test/lib/search/books/book_index_test.rb` | Mapping assertions (existing file) |
| `test/models/books/book_test.rb` | `as_indexed_json` assertions (existing file) |
| `test/lib/search/base/index_test.rb` | `bulk_update` tests |
| `test/sidekiq/books/reindex_ranked_fields_job_test.rb` | Job tests |
| `test/sidekiq/calculate_rankings_job_test.rb` | Chain assertion (existing file) |

---

### Task 1: Index fields and `as_indexed_json`

**Files:**
- Modify: `app/lib/search/books/book_index.rb`
- Modify: `app/models/books/book.rb`
- Test: `test/lib/search/books/book_index_test.rb` (existing — append)
- Test: `test/models/books/book_test.rb` (existing — append)

**Interfaces:**
- Consumes: `books_books.book_length` (increment 1); `Books::Country` / `has_many :countries` (PR #201); `RankedItem`; `Books::RankingConfiguration.default_primary`.
- Produces: six index fields and the matching `as_indexed_json` keys —
  `first_published_year` (integer), `original_language_id` (keyword), `country_ids` (keyword),
  `book_length` (integer), `ranked` (boolean), `ranked_position` (integer).
  Also `Books::Book#primary_ranked_item`, a `has_one` returning the `RankedItem` for the primary books ranking configuration. Task 3 writes `ranked` and `ranked_position` via partial update; increment 4 filters on all six.

**Why `ranked_position` is indexed at all:** every saved-search query will carry
`filter: {exists: {field: "ranked_position"}}` as a coarse narrowing filter. It cuts candidates
from 126,282 to ~24,242, which matters because 142 saved searches carry no real filter and would
otherwise pull the whole corpus on every page view. It must be `ranked_position` rather than
`ranked`: 24,362 books have list items while only 24,249 are scored, so narrowing on `ranked`
would silently drop the difference from every search.

**Why the rank fields live in `as_indexed_json` and not only in Task 3's job:** `index_item` does a
full document replace. If the job owned these fields exclusively, a book edited in admin would have
its `ranked_position` wiped and vanish from every saved search until the next recalc.

- [ ] **Step 1: Write the failing index-mapping test**

Append inside the existing `Search::Books::BookIndexTest` class in `test/lib/search/books/book_index_test.rb`:

```ruby
      test "index_definition maps the six saved-search filter fields" do
        properties = ::Search::Books::BookIndex.index_definition[:mappings][:properties]

        assert_equal "integer", properties[:first_published_year][:type]
        assert_equal "keyword", properties[:original_language_id][:type]
        assert_equal "keyword", properties[:country_ids][:type]
        assert_equal "integer", properties[:book_length][:type]
        assert_equal "boolean", properties[:ranked][:type]
        assert_equal "integer", properties[:ranked_position][:type]
      end

      test "model_includes preloads every association as_indexed_json touches" do
        includes = ::Search::Books::BookIndex.model_includes

        [:authors, :categories, :countries, :list_items, :original_language, :primary_ranked_item].each do |assoc|
          assert_includes includes, assoc
        end
      end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: FAIL — `NoMethodError: undefined method '[]' for nil` on `properties[:first_published_year]`

- [ ] **Step 3: Add the mapping fields and preloads**

In `app/lib/search/books/book_index.rb`, replace `model_includes`:

```ruby
      def self.model_includes
        [:authors, :categories, :countries, :list_items, :original_language, :primary_ranked_item]
      end
```

and add the six properties inside `index_definition`'s `mappings: {properties: {...}}` hash, after the existing `book_kind` entry:

```ruby
              first_published_year: {
                type: "integer"
              },
              original_language_id: {
                type: "keyword"
              },
              country_ids: {
                type: "keyword"
              },
              book_length: {
                type: "integer"
              },
              ranked: {
                type: "boolean"
              },
              ranked_position: {
                type: "integer"
              }
```

`original_language_id` and `country_ids` are `keyword` rather than `integer` to match the existing
`author_ids` and `category_ids`, which are already keyword — the query layer treats all four the
same way.

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: PASS

- [ ] **Step 5: Write the failing `as_indexed_json` test**

Append inside the existing `Books::BookTest` class in `test/models/books/book_test.rb`:

```ruby
    test "as_indexed_json includes the saved-search filter fields" do
      book = books_books(:war_and_peace)
      json = book.as_indexed_json

      assert_equal book.first_published_year, json[:first_published_year]
      assert_equal book.original_language_id, json[:original_language_id]
      assert_kind_of Array, json[:country_ids]
      assert_includes [true, false], json[:ranked]
    end

    test "as_indexed_json emits book_length as its integer enum value, not the string key" do
      book = books_books(:war_and_peace)
      book.update!(book_length: :long)

      assert_equal 4, book.as_indexed_json[:book_length]
    end

    test "as_indexed_json emits a nil book_length rather than raising" do
      book = Books::Book.create!(title: "No Length At All")

      assert_nil book.as_indexed_json[:book_length]
    end

    test "as_indexed_json reports ranked_position from the primary ranking configuration" do
      book = books_books(:war_and_peace)
      RankedItem.create!(
        item: book,
        ranking_configuration: ranking_configurations(:books_global),
        rank: 7,
        score: 90.0
      )

      assert_equal 7, book.reload.as_indexed_json[:ranked_position]
    end

    test "as_indexed_json reports a nil ranked_position for an unranked book" do
      book = Books::Book.create!(title: "Never Ranked")

      assert_nil book.as_indexed_json[:ranked_position]
    end

    test "as_indexed_json ignores a rank from a non-primary ranking configuration" do
      book = books_books(:war_and_peace)
      RankedItem.create!(
        item: book,
        ranking_configuration: ranking_configurations(:books_user),
        rank: 3,
        score: 80.0
      )

      assert_nil book.reload.as_indexed_json[:ranked_position]
    end
```

`RankedItem` records are created inline rather than added to `test/fixtures/ranked_items.yml`. That
file carries no `Books::Book` entries by design, and adding one would change the result set of every
existing books ranking test.

- [ ] **Step 6: Run it to verify it fails**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: FAIL — the new keys are `nil` / `NoMethodError: undefined method 'primary_ranked_item'`

- [ ] **Step 7: Add the association and the JSON keys**

In `app/models/books/book.rb`, add the association immediately after the existing
`has_many :ranked_items, as: :item, dependent: :destroy` line:

```ruby
  # Scoped so bulk indexing preloads one row per book instead of every configuration's
  # rank. The lambda runs once per preload, not once per record, so a 1,000-book batch
  # costs one extra query and the value is always read live -- no cache to go stale.
  has_one :primary_ranked_item,
    -> { where(ranking_configuration_id: Books::RankingConfiguration.default_primary&.id) },
    as: :item, class_name: "RankedItem"
```

and extend `as_indexed_json`:

```ruby
  def as_indexed_json
    {
      title: title,
      subtitle: subtitle,
      alternate_titles: alternate_titles,
      author_names: authors.map(&:name),
      author_ids: authors.map(&:id),
      category_ids: categories.active.pluck(:id),
      book_kind: book_kind,
      first_published_year: first_published_year,
      original_language_id: original_language_id,
      country_ids: countries.map(&:id),
      book_length: self.class.book_lengths[book_length],
      ranked: list_items.any?,
      ranked_position: primary_ranked_item&.rank
    }
  end
```

`self.class.book_lengths[book_length]` converts the enum's string key back to its integer. A nil
`book_length` yields nil. `countries.map(&:id)` and `list_items.any?` read the preloaded
associations in memory during bulk indexing and fall back to queries for a single record.

- [ ] **Step 8: Run it to verify it passes**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: PASS

- [ ] **Step 9: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass. The full suite matters — `as_indexed_json` is called by the indexer job for every
books test that touches indexing.

- [ ] **Step 10: Commit**

```bash
git add app/lib/search/books/book_index.rb app/models/books/book.rb \
        test/lib/search/books/book_index_test.rb test/models/books/book_test.rb
git commit -m "Index the six saved-search filter fields on books"
```

---

### Task 2: Generic `bulk_update` on the index base class

**Files:**
- Modify: `app/lib/search/base/index.rb`
- Create: `test/lib/search/base/index_test.rb` (the `test/lib/search/base/` directory does not exist yet — create it)

**Interfaces:**
- Consumes: nothing.
- Produces: `Search::Base::Index.bulk_update(updates)` where `updates` is a Hash of `{item_id => partial_doc_hash}`. Issues one OpenSearch bulk request of `update` actions and returns the response. Task 3 calls it.

**Why a partial update rather than a reindex:** after a ranking recalculation, ~24k ranks change and
no book row does. Re-indexing 126,282 full documents to change two fields each is waste; `update`
actions carry only the changed fields.

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/base/index_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Base
    class IndexBulkUpdateTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
        ::Search::Books::BookIndex.create_index
      end

      def teardown
        cleanup_test_index
      end

      test "bulk_update patches only the named fields and leaves the rest intact" do
        book = books_books(:war_and_peace)
        ::Search::Books::BookIndex.index_item(book)

        ::Search::Books::BookIndex.bulk_update(book.id => {ranked: true, ranked_position: 12})

        doc = ::Search::Books::BookIndex.find_by_id(book.id)
        assert_equal 12, doc["ranked_position"]
        assert_equal true, doc["ranked"]
        assert_equal book.title, doc["title"]
      end

      test "bulk_update is a no-op for an empty hash" do
        assert_nil ::Search::Books::BookIndex.bulk_update({})
      end

      test "bulk_update applies each document its own values" do
        first = books_books(:war_and_peace)
        second = Books::Book.create!(title: "Second Indexed Book")
        ::Search::Books::BookIndex.index_item(first)
        ::Search::Books::BookIndex.index_item(second)

        ::Search::Books::BookIndex.bulk_update(
          first.id => {ranked_position: 1},
          second.id => {ranked_position: 2}
        )

        assert_equal 1, ::Search::Books::BookIndex.find_by_id(first.id)["ranked_position"]
        assert_equal 2, ::Search::Books::BookIndex.find_by_id(second.id)["ranked_position"]
      end

      private

      def cleanup_test_index
        ::Search::Books::BookIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/search/base/index_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'bulk_update'`

- [ ] **Step 3: Implement `bulk_update`**

In `app/lib/search/base/index.rb`, add immediately after the existing `bulk_unindex` method, matching its shape (same error logging, same `refresh: true`):

```ruby
      # Partial document update: patches only the given fields, leaving the rest of each
      # document intact. Used when derived values change without the record changing --
      # a full reindex would rewrite every field to alter two.
      def self.bulk_update(updates)
        return if updates.empty?

        actions = updates.map do |item_id, fields|
          {update: {_index: index_name, _id: item_id, data: {doc: fields}}}
        end

        response = client.bulk(body: actions, refresh: true)

        if response["errors"]
          response["items"].each do |item|
            if item["update"]["error"]
              Rails.logger.error "Failed to update item ID #{item["update"]["_id"]}: #{item["update"]["error"]}"
            end
          end
        else
          Rails.logger.info "Successfully updated #{updates.size} items in '#{index_name}'"
        end

        response
      end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/search/base/index_test.rb`
Expected: PASS

- [ ] **Step 5: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/search/base/index.rb test/lib/search/base/index_test.rb
git commit -m "Add bulk_update partial-document updates to the search index base"
```

---

### Task 3: Refresh rank fields after a recalculation

**Files:**
- Create: `app/sidekiq/books/reindex_ranked_fields_job.rb` (via generator)
- Create: `test/sidekiq/books/reindex_ranked_fields_job_test.rb` (created by the generator)
- Modify: `app/sidekiq/calculate_rankings_job.rb`
- Test: `test/sidekiq/calculate_rankings_job_test.rb` (existing — append)

**Interfaces:**
- Consumes: `Search::Base::Index.bulk_update` (Task 2); `RankedItem`; `Books::RankingConfiguration.default_primary`.
- Produces: `Books::ReindexRankedFieldsJob#perform`, which refreshes `ranked_position` for every book ranked in the primary books configuration.

**Where it chains:** `CalculateRankingsJob#perform` already fans out to
`Books::CalculateAuthorRankingsJob` when the configuration is a `Books::RankingConfiguration`. The
new job goes beside it — same condition, same place.

**Known limitation, deliberate:** a book that *falls out* of the ranked set keeps its stale
`ranked_position` in the index until the next full reindex. This is harmless: the field is only a
coarse narrowing filter, and the Postgres side of the query — which is the source of truth for
membership — drops any book without a live `RankedItem`. Nulling those documents would require a
second OpenSearch query per run to find them; it is not worth it. Do not add it.

- [ ] **Step 1: Generate the job**

Run:

```bash
bin/rails generate sidekiq:job books/reindex_ranked_fields
```

This creates `app/sidekiq/books/reindex_ranked_fields_job.rb` and its test file. Do **not** use
`bin/rails generate job` — this project uses Sidekiq, and jobs live in `app/sidekiq/`.

- [ ] **Step 2: Write the failing job test**

Replace the generated `test/sidekiq/books/reindex_ranked_fields_job_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::ReindexRankedFieldsJobTest < ActiveSupport::TestCase
  test "sends each ranked book's current rank to the index" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: 5,
      score: 88.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| updates[book.id] == {ranked_position: 5} }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "ignores ranks from non-primary ranking configurations" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_user),
      rank: 3,
      score: 70.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| !updates.key?(book.id) }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "skips ranked items with a nil rank" do
    book = books_books(:war_and_peace)
    RankedItem.create!(
      item: book,
      ranking_configuration: ranking_configurations(:books_global),
      rank: nil,
      score: 60.0
    )

    Search::Books::BookIndex.expects(:bulk_update).with { |updates| !updates.key?(book.id) }

    Books::ReindexRankedFieldsJob.new.perform
  end

  test "raises when there is no primary books ranking configuration" do
    Books::RankingConfiguration.stubs(:default_primary).returns(nil)

    assert_raises(RuntimeError) { Books::ReindexRankedFieldsJob.new.perform }
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/sidekiq/books/reindex_ranked_fields_job_test.rb`
Expected: FAIL — the generated job's `perform` does nothing, so `bulk_update` is never called and Mocha reports an unsatisfied expectation.

- [ ] **Step 4: Implement the job**

Replace `app/sidekiq/books/reindex_ranked_fields_job.rb` with:

```ruby
class Books::ReindexRankedFieldsJob
  include Sidekiq::Job

  BATCH_SIZE = 1000

  def perform
    config = Books::RankingConfiguration.default_primary
    raise "No primary Books::RankingConfiguration; ranked fields not refreshed" if config.nil?

    total = 0
    RankedItem
      .where(ranking_configuration_id: config.id, item_type: "Books::Book")
      .where.not(rank: nil)
      .in_batches(of: BATCH_SIZE) do |batch|
        updates = batch.pluck(:item_id, :rank).to_h { |item_id, rank| [item_id, {ranked_position: rank}] }
        Search::Books::BookIndex.bulk_update(updates)
        total += updates.size
      end

    Rails.logger.info "Refreshed ranked_position for #{total} books"
  end
end
```

The job writes `ranked_position` only. `ranked` tracks list membership, which a ranking
recalculation does not change — it is refreshed by the ordinary `SearchIndexRequest` path when a
book's list items change.

- [ ] **Step 5: Run it to verify it passes**

Run: `bin/rails test test/sidekiq/books/reindex_ranked_fields_job_test.rb`
Expected: PASS

- [ ] **Step 6: Write the failing chain test**

Append to the existing class in `test/sidekiq/calculate_rankings_job_test.rb`:

These mirror the two author-chain tests already in that file exactly — same `any_instance` stub, same
real `ItemRankings::Calculator::Result`, same fixture names:

```ruby
  test "enqueues the ranked-fields reindex after a books configuration succeeds" do
    config = ranking_configurations(:books_global)
    RankingConfiguration.any_instance
      .expects(:calculate_rankings)
      .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))
    Books::CalculateAuthorRankingsJob.stubs(:perform_async)
    Books::ReindexRankedFieldsJob.expects(:perform_async).once

    CalculateRankingsJob.new.perform(config.id)
  end

  test "does not enqueue the ranked-fields reindex for a music configuration" do
    config = ranking_configurations(:music_albums_global)
    RankingConfiguration.any_instance
      .expects(:calculate_rankings)
      .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))
    Books::ReindexRankedFieldsJob.expects(:perform_async).never

    CalculateRankingsJob.new.perform(config.id)
  end
```

The existing books-chain test (`"enqueues the author ranking job after a books configuration
succeeds"`) does not stub `Books::ReindexRankedFieldsJob`, so once Step 8 adds the chain that test
will enqueue the real job. Sidekiq jobs do not execute inline in this suite, so it should still
pass — but if it fails, add `Books::ReindexRankedFieldsJob.stubs(:perform_async)` to it rather than
changing the production code.

- [ ] **Step 7: Run it to verify it fails**

Run: `bin/rails test test/sidekiq/calculate_rankings_job_test.rb`
Expected: FAIL — unsatisfied Mocha expectation on `perform_async`

- [ ] **Step 8: Add the chain**

In `app/sidekiq/calculate_rankings_job.rb`, extend the existing books branch:

```ruby
      if ranking_configuration.type == "Books::RankingConfiguration"
        Books::CalculateAuthorRankingsJob.perform_async
        Books::ReindexRankedFieldsJob.perform_async
      end
```

- [ ] **Step 9: Run it to verify it passes**

Run: `bin/rails test test/sidekiq/calculate_rankings_job_test.rb`
Expected: PASS

- [ ] **Step 10: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 11: Commit**

```bash
git add app/sidekiq/books/reindex_ranked_fields_job.rb app/sidekiq/calculate_rankings_job.rb \
        test/sidekiq/books/reindex_ranked_fields_job_test.rb test/sidekiq/calculate_rankings_job_test.rb
git commit -m "Refresh indexed book ranks after a ranking recalculation"
```

---

### Task 4: Reindex development and verify

**Files:** none changed. This task produces verification evidence only.

**Interfaces:** consumes everything above.

- [ ] **Step 1: Confirm OpenSearch is reachable and capture the before-state**

Run:

```bash
bin/rails runner 'puts({docs: Search::Books::BookIndex.client.count(index: Search::Books::BookIndex.index_name)["count"]}.inspect)'
```

Record the number. If this raises a connection error, STOP and report — OpenSearch is not running.

- [ ] **Step 2: Recreate and reindex the books index**

Run: `bin/rails search:books:recreate_books`

This is the books-only task (`lib/tasks/search.rake`); `search:books:recreate_and_reindex_all` also
works but additionally rebuilds the authors index, which this increment does not change.

Expected: completes without error. ~126,282 documents.

- [ ] **Step 3: Verify the document count and the new fields**

Run:

```bash
bin/rails runner '
idx = Search::Books::BookIndex
puts({docs: idx.client.count(index: idx.index_name)["count"]}.inspect)
book = Books::Book.joins(:ranked_items).where(ranked_items: {ranking_configuration_id: Books::RankingConfiguration.default_primary.id}).where.not(ranked_items: {rank: nil}).first
puts({sample_book_id: book.id, indexed: idx.find_by_id(book.id).slice("first_published_year", "original_language_id", "country_ids", "book_length", "ranked", "ranked_position")}.inspect)
'
```

Expected: the document count matches `Books::Book.count` (~126,282), and the sampled ranked book
shows a non-nil `ranked_position` plus the other five fields populated as the database has them.

- [ ] **Step 4: Verify the narrowing filter's selectivity**

This is the number the whole design rests on — confirm it before increment 4 depends on it.

```bash
bin/rails runner '
idx = Search::Books::BookIndex
total = idx.client.count(index: idx.index_name)["count"]
narrowed = idx.client.count(index: idx.index_name, body: {query: {bool: {filter: [{exists: {field: "ranked_position"}}]}}})["count"]
expected = RankedItem.where(ranking_configuration_id: Books::RankingConfiguration.default_primary.id, item_type: "Books::Book").where.not(rank: nil).count
puts({total: total, narrowed: narrowed, expected_from_pg: expected, match: narrowed == expected}.inspect)
'
```

Expected: `narrowed` equals `expected_from_pg` exactly (~24,242 against a total of ~126,282), and
`match: true`. **If they differ, STOP and report both figures** — a mismatch means `as_indexed_json`
and the database disagree about who is ranked, which would silently distort every saved search.

- [ ] **Step 5: Verify the refresh job**

```bash
bin/rails runner 'Books::ReindexRankedFieldsJob.new.perform; puts "ok"'
```

Then re-run Step 4's command. Expected: identical figures — the job is idempotent against a
freshly-built index.

- [ ] **Step 6: Full suite and lint**

Run: `bin/rails test && bundle exec standardrb`
Expected: both pass.

- [ ] **Step 7: Commit the verification record**

No code changed, so there may be nothing to commit. If the earlier tasks left the tree clean, skip
this step and report the figures in your task report instead.

---

## Done When

- [ ] `bin/rails test` passes with zero failures; `bundle exec standardrb` reports no offenses.
- [ ] The books index mapping carries all six new fields, verified by test.
- [ ] `as_indexed_json` emits all six, with `book_length` as an integer and `ranked_position` scoped to the primary configuration, verified by test.
- [ ] `Search::Base::Index.bulk_update` patches named fields without disturbing the rest of a document, verified against a live index.
- [ ] `Books::ReindexRankedFieldsJob` is chained from `CalculateRankingsJob` for books configurations only, verified by test.
- [ ] Development index rebuilt; `exists: ranked_position` selects exactly the same count Postgres reports as ranked.

**Not in this increment** (spec §12): the `SavedSearch` model and its migration (increment 3), the criteria/query layer (increment 4), and everything user-facing (increments 5–7). Nothing here is visible to users.

## Landmines

- **Do not narrow on `ranked` instead of `ranked_position`** — 24,362 books have list items but only 24,249 are scored; the difference would vanish from every search (§5.2 of the spec).
- **Do not move the rank fields out of `as_indexed_json`** into the job alone — `index_item` is a full document replace, so an admin edit would wipe them (§5.3).
- **`bin/rails generate sidekiq:job`**, never `generate job`; jobs live in `app/sidekiq/`.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Read fixture YAML directly; never run it against development.
- **Do not add `Books::Book` entries to `test/fixtures/ranked_items.yml`** — that file has none by design, and adding one changes the result set of every existing books ranking test. Create `RankedItem` records inline in the tests that need them.
- **`RankedItem` validates `item_type_matches_ranking_configuration`**, so a non-book item cannot be attached to a `Books::RankingConfiguration` at all. The job's `item_type: "Books::Book"` clause is therefore belt-and-braces, and cross-domain leakage is not testable by construction — do not try to write a test for it.
