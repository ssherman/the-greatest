# Goodreads Import, Increment 2: Provisional Records — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `provisional` flag to `Books::Book` and `Books::Author` and keep provisional records off every public surface (spec §9), while they stay findable by the import finder and by admins. Nothing creates provisional records yet; increments 3 and 6 will.

**Architecture:** A `catalog` scope (`where(provisional: false)`) on both models is the one predicate SQL surfaces use. OpenSearch documents carry a `provisional` field; public book queries exclude it with a `must_not` clause, admin callers opt back in, and the finder's queries are untouched. Ranked surfaces are protected at their source: the books and authors ranking calculators skip provisional records, so they never get a ranked item. Show pages still load by URL, render `noindex`, and show a notice.

**Tech Stack:** Rails 8.1, Postgres, OpenSearch (real, in tests), Minitest 6 + fixtures + Mocha, ViewComponent, DaisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (§9; §3 "Changes to existing tables and models"; §14 "Visibility")

## Global Constraints

- Run every Rails/yarn command from `web-app/`. Docs live in `docs/` at the project root.
- Lint is `bundle exec standardrb`. Never `bin/rubocop`, never brakeman.
- Use generators: `bin/rails generate migration …`, `bin/rails generate component …`.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`.
- Controller tests assert behavior (status, assigns, robots meta), not copy or CSS.
- Inside `Api::V1::Books`, `Books::*` resolves to the API namespace: root-anchor every model as `::Books::Book`.
- Shared dev DB: after `bin/rails db:migrate`, diff `db/schema.rb` and keep only this branch's two columns, two indexes and the version bump. Revert annotation changes to any model other than `Books::Book` and `Books::Author`.
- Column spec (§3): `books_books.provisional` and `books_authors.provisional`, boolean, default false, not null, indexed.
- Notice copy (§9), verbatim: `Added from a Goodreads import; not yet reviewed or enriched.`
- The import finder's OpenSearch sources (`BookByTitleAndAuthors`, `AuthorByName`) must NOT filter provisional records (§9: "Search stays complete for matching").
- A clean `bin/rails test` emits no new warning lines.

## Review Focus

1. **Documents indexed before the field existed.** Production book documents have no `provisional` key until each book is reindexed. They must still appear in public search. Pinned in Task 2 ("a document with no provisional field is still found").
2. **Admins must still find provisional books.** The admin books search and autocomplete use the same classes as public search. If they filtered, the approval workflow (increment 6) could not find what it approves. Pinned in Task 2 (admin controller tests pass `include_provisional: true`, and a search test shows the opt-in returns the record).
3. **The owner versus everyone else on a public list.** A member who imports a book onto their public Read list still sees it; an anonymous viewer does not. Pinned in Task 5, with both views.
4. **A stale ranked row.** A book flagged provisional after it was ranked must leave the rankings at the next calculation, not stay ranked forever. Pinned in Task 3 (the stale `RankedItem` is gone after `call`).
5. **Merging across the flag.** Merging a catalog source into a provisional target must leave a catalog record, or a merge hides a real book. Pinned in Task 7.

Decisions the plan makes on the spec's behalf (each is in a task, and the executor should ledger a ruling if it deviates):

- **Rankings are filtered at calculation, not at every ranked query.** Every ranked surface reads `ranked_items`: ranked pages, browse counts, global canon, the API ranked endpoints, the author ranking, and top books per author. A provisional book gets no ranked item, so all of them are covered by one test on each calculator. Increment 5 marks legacy books provisional, and it must queue a recalculation afterwards. Task 8's feature doc records that.
- **The author search classes are unchanged.** `AuthorGeneral` and `AuthorAutocomplete` have only admin callers, and admins need to see provisional authors. The `provisional` field is still indexed on authors, for a future public author search.
- **Curated list pages (`Books::ListsController#show`) are not filtered.** They are not in §9, and imports never write curated list items. The generated favorites list is filtered when it is generated (Task 5), so its public page needs nothing more.
- **The public reading-goal page counts as "other people's views of a user's lists"** (it renders the Read list). Public goals are edge-cached and identical for every viewer, so they hide provisional books from everyone, the owner included. Private goals and `my/reading-goals` do not filter.
- **API embeds.** A catalog book embedding a provisional author still shows that author's name. Approval promotes a book and the authors created with it together, so this combination does not arise from imports. It is out of scope.

---

### Task 1: Schema, `catalog` scope, index documents

**Files:**
- Create: `web-app/db/migrate/<timestamp>_add_provisional_to_books_books_and_books_authors.rb` (via generator)
- Modify: `web-app/db/schema.rb` (by migrate; strip foreign changes)
- Modify: `web-app/app/models/books/book.rb` (scope near `scope :selectable`, line ~138; `as_indexed_json`, line ~212)
- Modify: `web-app/app/models/books/author.rb` (add a scope after the `validates` lines; `as_indexed_json`, line ~70)
- Modify: `web-app/app/lib/search/books/book_index.rb` (mappings, after `ranked_position`; new constant)
- Modify: `web-app/app/lib/search/books/author_index.rb` (mappings, after `category_ids`)
- Test: `web-app/test/models/books/book_test.rb`, `web-app/test/models/books/author_test.rb`, `web-app/test/lib/search/books/book_index_test.rb`, `web-app/test/lib/search/books/author_index_test.rb`

**Interfaces:**
- Produces: `Books::Book.catalog`, `Books::Author.catalog` (scopes, `where(provisional: false)`); `provisional` boolean attribute on both; `as_indexed_json[:provisional]` on both; `Search::Books::BookIndex::EXCLUDE_PROVISIONAL` = `{term: {provisional: true}}` (frozen), used in `must_not` arrays by Task 2.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration AddProvisionalToBooksBooksAndBooksAuthors`

Replace the generated body with:

```ruby
class AddProvisionalToBooksBooksAndBooksAuthors < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :provisional, :boolean, default: false, null: false
    add_column :books_authors, :provisional, :boolean, default: false, null: false

    # Partial: nearly every row is false, so a full index would never serve the
    # catalog scope. This one serves "find the provisional rows" for the admin queue.
    add_index :books_books, :provisional, where: "provisional"
    add_index :books_authors, :provisional, where: "provisional"
  end
end
```

Keep whatever `Migration[x.y]` version the generator wrote.

- [ ] **Step 2: Migrate dev and test, then clean the schema diff**

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && RAILS_ENV=test bin/rails db:test:prepare`
Then: `git diff db/schema.rb`
Expected: the version bump, the two `t.boolean "provisional", default: false, null: false` lines and the two `t.index ["provisional"], name: …, where: "provisional"` lines. Remove anything else (it belongs to another worktree's migrations). Then add `#  provisional :boolean default(FALSE), not null` to the schema comment blocks of `book.rb` and `author.rb` by hand, in alphabetical position, matching the existing comment format. `ANNOTATERB_SKIP_ON_DB_TASKS` stops annotaterb from restamping unrelated models.

- [ ] **Step 3: Write the failing model tests**

Append to `test/models/books/book_test.rb` inside the class:

```ruby
    test "catalog excludes provisional books and keeps the rest" do
      provisional = Books::Book.create!(title: "A Provisional Import", provisional: true)

      assert_includes Books::Book.catalog, books_books(:war_and_peace)
      refute_includes Books::Book.catalog, provisional
    end

    test "as_indexed_json carries the provisional flag" do
      book = books_books(:war_and_peace)

      assert_equal false, book.as_indexed_json[:provisional]
      book.provisional = true
      assert_equal true, book.as_indexed_json[:provisional]
    end
```

Append to `test/models/books/author_test.rb` inside the class:

```ruby
    test "catalog excludes provisional authors and keeps the rest" do
      provisional = Books::Author.create!(name: "A Provisional Author", provisional: true)

      assert_includes Books::Author.catalog, books_authors(:tolstoy)
      refute_includes Books::Author.catalog, provisional
    end

    test "as_indexed_json carries the provisional flag" do
      author = books_authors(:tolstoy)

      assert_equal false, author.as_indexed_json[:provisional]
      author.provisional = true
      assert_equal true, author.as_indexed_json[:provisional]
    end
```

Add to the mapping test in `test/lib/search/books/book_index_test.rb`, after `assert_equal "keyword", properties[:book_kind][:type]`:

```ruby
        assert_equal "boolean", properties[:provisional][:type]
```

and to `test/lib/search/books/author_index_test.rb`, after `assert_equal "keyword", properties[:category_ids][:type]`:

```ruby
        assert_equal "boolean", properties[:provisional][:type]
```

- [ ] **Step 4: Run them to verify they fail**

Run: `bin/rails test test/models/books/book_test.rb test/models/books/author_test.rb test/lib/search/books/book_index_test.rb test/lib/search/books/author_index_test.rb`
Expected: FAIL. `catalog` is an undefined method, `as_indexed_json[:provisional]` is nil, and `properties[:provisional]` is nil.

- [ ] **Step 5: Implement**

`app/models/books/book.rb`, below `scope :selectable`:

```ruby
  # Imported and not yet approved by an admin (Goodreads import spec §9). Every
  # public surface reads through this; the import finder deliberately does not, so
  # a second import of the same book finds the provisional copy instead of making
  # another.
  scope :catalog, -> { where(provisional: false) }
```

In `as_indexed_json`, add after `ranked_position: primary_ranked_item&.rank`:

```ruby
      ranked_position: primary_ranked_item&.rank,
      provisional: provisional
```

`app/models/books/author.rb`, after `validates :kind, presence: true`:

```ruby
  # Same flag and contract as Books::Book.catalog.
  scope :catalog, -> { where(provisional: false) }
```

and `as_indexed_json` becomes:

```ruby
  def as_indexed_json
    {
      name: name,
      alternate_names: alternate_names,
      category_ids: categories.active.pluck(:id),
      provisional: provisional
    }
  end
```

`app/lib/search/books/book_index.rb`: after the `ranked_position` mapping, add:

```ruby
              ranked_position: {
                type: "integer"
              },
              provisional: {
                type: "boolean"
              }
```

and inside the class, above `def self.model_klass`:

```ruby
      # For must_not, never `filter: {term: {provisional: false}}`. Documents indexed
      # before this field existed carry no provisional key, and a filter on false
      # would drop every one of them from public search until a full reindex.
      EXCLUDE_PROVISIONAL = {term: {provisional: true}}.freeze
```

`app/lib/search/books/author_index.rb`: after the `category_ids` mapping, add:

```ruby
              category_ids: {
                type: "keyword"
              },
              provisional: {
                type: "boolean"
              }
```

No production reindex is required: the indexes use default dynamic mapping, so the first document carrying `provisional` maps it as boolean, and the `must_not` form treats a missing field as "not provisional".

- [ ] **Step 6: Run them to verify they pass**

Run: same command as Step 4.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add web-app/db/migrate web-app/db/schema.rb web-app/app/models/books/book.rb web-app/app/models/books/author.rb web-app/app/lib/search/books/book_index.rb web-app/app/lib/search/books/author_index.rb web-app/test/models/books web-app/test/lib/search/books/book_index_test.rb web-app/test/lib/search/books/author_index_test.rb
git commit -m "Books: provisional flag and catalog scope on books and authors"
```

---

### Task 2: Public book search excludes provisional books; admin and the finder do not

**Files:**
- Modify: `web-app/app/lib/search/books/search/book_general.rb`
- Modify: `web-app/app/lib/search/books/search/book_autocomplete.rb`
- Modify: `web-app/app/lib/search/books/search/book_advanced.rb` (`must_not_clauses`, line ~165)
- Modify: `web-app/app/lib/search/books/search/book_similar.rb` (`build_query_definition`, `must_not = …`)
- Modify: `web-app/app/controllers/admin/books/books_controller.rb` (lines 11 and 110)
- Test: `web-app/test/lib/search/books/search/book_general_test.rb`, `book_autocomplete_test.rb`, `book_advanced_test.rb`, `book_similar_test.rb`, `book_by_title_and_authors_test.rb`, `web-app/test/controllers/admin/books/books_controller_test.rb`

**Interfaces:**
- Consumes: `Search::Books::BookIndex::EXCLUDE_PROVISIONAL`, the `provisional` document field (Task 1).
- Produces: option `include_provisional:` (default `false`) on `BookGeneral.call(text, options)` and `BookAutocomplete.call(text, options)`; `build_query_definition(text, min_score, size, from, book_kind = "standalone", include_provisional: false)` on both. `BookAdvanced` and `BookSimilar` always exclude. Every public caller (`Books::BookSearchQuery`, `Search::ListableAutocomplete`, `Books::SavedSearchQuery`, `Services::Books::SimilarBooks`) inherits the default and needs no change.

- [ ] **Step 1: Write the failing search tests**

Every one of these test files already has `setup` creating the index and `teardown` deleting it. Where a file lacks a raw-document helper, add this one inside the class (`book_advanced_test.rb` and `book_similar_test.rb` already have `index_book`; reuse theirs):

```ruby
        def index_doc(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {title: "Book #{id}", book_kind: "standalone", author_names: [], alternate_titles: []}.merge(attrs),
            refresh: true
          )
        end
```

`book_general_test.rb`:

```ruby
        test "call leaves out provisional books" do
          index_doc(1, title: "Quiet Harbour", provisional: false)
          index_doc(2, title: "Quiet Harbour", provisional: true)

          ids = ::Search::Books::Search::BookGeneral.call("Quiet Harbour").map { |hit| hit[:id] }

          assert_equal ["1"], ids
        end

        test "call includes provisional books when asked" do
          index_doc(2, title: "Quiet Harbour", provisional: true)

          ids = ::Search::Books::Search::BookGeneral.call("Quiet Harbour", include_provisional: true).map { |hit| hit[:id] }

          assert_equal ["2"], ids
        end

        test "a document with no provisional field is still found" do
          index_doc(3, title: "Quiet Harbour")

          ids = ::Search::Books::Search::BookGeneral.call("Quiet Harbour").map { |hit| hit[:id] }

          assert_equal ["3"], ids
        end
```

`book_autocomplete_test.rb`: the same three tests, calling `::Search::Books::Search::BookAutocomplete` with the query `"Quiet Harb"`.

`book_advanced_test.rb`:

```ruby
        test "leaves out provisional books" do
          index_book(1)
          index_book(2, provisional: true)

          assert_equal [1], ids_for({"genre_match_mode" => "any"})
        end
```

`book_similar_test.rb`:

```ruby
        test "leaves out provisional candidates" do
          index_book(@book.id, genre_category_ids: [@novels], similarity_category_count: 1)
          index_book(9001, genre_category_ids: [@novels], similarity_category_count: 1)
          index_book(9002, genre_category_ids: [@novels], similarity_category_count: 1, provisional: true)

          assert_equal ["9001"], ids_for
        end
```

`book_by_title_and_authors_test.rb` (the finder: this pins that it does NOT filter):

```ruby
        test "finds a provisional book, because the import finder must see it" do
          book = books_books(:war_and_peace)
          book.update!(provisional: true)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace", authors: ["Leo Tolstoy"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end
```

- [ ] **Step 2: Run them to verify the right ones fail**

Run: `bin/rails test test/lib/search/books/search/`
Expected: the four "leaves out" tests FAIL, each returning the provisional id as well. `include_provisional: true` passes trivially before the change (nothing filters yet), and so do "no provisional field" and the finder test. That is expected: they pin behaviour the change must not break. The "include" test becomes meaningful once the filter exists (verify it in Step 4).

- [ ] **Step 3: Implement**

`book_general.rb`:

```ruby
        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0
          book_kind = options.fetch(:book_kind, "standalone")
          include_provisional = options.fetch(:include_provisional, false)

          query_definition = build_query_definition(text, min_score, size, from, book_kind, include_provisional: include_provisional)
          ...
        end

        def self.build_query_definition(text, min_score, size, from, book_kind = "standalone", include_provisional: false)
          ...
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              filter: book_kind.nil? ? [] : [{term: {book_kind: book_kind}}],
              must_not: include_provisional ? [] : [::Search::Books::BookIndex::EXCLUDE_PROVISIONAL],
              minimum_should_match: 1
            )
```

`book_autocomplete.rb`: the identical three edits (option read, signature, `must_not:` line).

`book_advanced.rb`, `must_not_clauses`: add before the method's final `clauses` return:

```ruby
          clauses << ::Search::Books::BookIndex::EXCLUDE_PROVISIONAL
```

`book_similar.rb`, `build_query_definition`:

```ruby
          must_not = [{ids: {values: excluded}}, ::Search::Books::BookIndex::EXCLUDE_PROVISIONAL]
```

Existing tests that pin the exact `must_not` array of `BookAdvanced` or `BookSimilar` (search both test files for `must_not`) need the new clause added. That is an expected update.

- [ ] **Step 4: Run them to verify they pass**

Run: `bin/rails test test/lib/search/books/search/`
Expected: PASS. Mutation check: in `book_general.rb`, temporarily replace `must_not: include_provisional ? [] : [::Search::Books::BookIndex::EXCLUDE_PROVISIONAL]` with `must_not: [::Search::Books::BookIndex::EXCLUDE_PROVISIONAL]`, so it always filters. "call includes provisional books when asked" must FAIL. Revert.

- [ ] **Step 5: Admin search opts back in; failing tests first**

In `test/controllers/admin/books/books_controller_test.rb`, every Mocha expectation of the form `BookGeneral.expects(:call).with("war", size: 1000, book_kind: nil)` or `BookAutocomplete.expects(:call).with(…, size: 20, book_kind: nil)` gains `include_provisional: true`. For example:

```ruby
::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 1000, book_kind: nil, include_provisional: true).returns([...])
```

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: FAIL (unexpected invocation; the controller does not pass the option yet).

- [ ] **Step 6: Implement the admin opt-in**

`app/controllers/admin/books/books_controller.rb`:

```ruby
    results = ::Search::Books::Search::BookAutocomplete.call(params[:q], size: 20, book_kind: nil, include_provisional: true)
```

```ruby
      results = ::Search::Books::Search::BookGeneral.call(params[:q], size: 1000, book_kind: nil, include_provisional: true)
```

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb test/lib/search test/lib/books test/lib/services/books/similar_books_test.rb test/controllers/books/searches_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add web-app/app/lib/search/books/search web-app/app/controllers/admin/books/books_controller.rb web-app/test/lib/search/books/search web-app/test/controllers/admin/books/books_controller_test.rb
git commit -m "Books search: leave provisional books out of public queries"
```

---

### Task 3: Rankings skip provisional books and authors

**Files:**
- Modify: `web-app/app/lib/item_rankings/calculator.rb` (`prepare_items`, line ~75; new protected hook)
- Modify: `web-app/app/lib/item_rankings/books/calculator.rb`
- Modify: `web-app/app/lib/item_rankings/books/authors/calculator.rb` (`aggregation_sql`, line ~76)
- Create: `web-app/test/lib/item_rankings/books/calculator_test.rb`
- Test: `web-app/test/lib/item_rankings/books/authors/calculator_test.rb`

**Interfaces:**
- Consumes: `provisional` columns (Task 1).
- Produces: protected `ItemRankings::Calculator#excluded_item_ids` → `Set` of listable ids (base returns an empty `Set`), overridden by `ItemRankings::Books::Calculator`.

- [ ] **Step 1: Write the failing books calculator test**

Create `test/lib/item_rankings/books/calculator_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module ItemRankings
  module Books
    class CalculatorTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @list = lists(:books_list)
        # books_list is the only list ranked by books_global. Its fixture item points
        # at a book that does not exist (see list_items.yml); replace it with two real
        # ones, and make the list active so prepare_lists reads it.
        @list.update!(status: :active)
        ListItem.where(list: @list).delete_all
        @catalog_book = books_books(:war_and_peace)
        @provisional_book = books_books(:got)
        ListItem.create!(list: @list, listable: @catalog_book, position: 1)
        ListItem.create!(list: @list, listable: @provisional_book, position: 2)
        @provisional_book.update!(provisional: true)
        @config.ranked_items.delete_all
      end

      test "ranks catalog books and leaves provisional books out" do
        result = ItemRankings::Books::Calculator.new(@config).call

        assert result.success?, "expected success, got #{result.errors}"
        ranked_ids = @config.ranked_items.pluck(:item_id)
        assert_includes ranked_ids, @catalog_book.id
        refute_includes ranked_ids, @provisional_book.id
      end

      test "a book ranked before it became provisional loses its ranked item" do
        RankedItem.create!(item: @provisional_book, ranking_configuration: @config, rank: 1, score: 100)

        ItemRankings::Books::Calculator.new(@config).call

        refute RankedItem.exists?(item: @provisional_book, ranking_configuration: @config)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/item_rankings/books/calculator_test.rb`
Expected: both FAIL. The provisional book is ranked.

- [ ] **Step 3: Implement the hook**

`app/lib/item_rankings/calculator.rb`. In the `protected` section (after `median_list_count`):

```ruby
    # Listable ids that must not be ranked even when a list carries them. Base
    # excludes nothing; Books overrides it for provisional imports.
    def excluded_item_ids
      Set.new
    end
```

In `prepare_items`, after the `next if list_item.listable_id.nil?` line:

```ruby
        next if excluded_ids.include?(list_item.listable_id)
```

and in the `private` section:

```ruby
    # Memoized: prepare_items runs once per ranked list, and the set must not be
    # re-queried for each of them.
    def excluded_ids
      @excluded_ids ||= excluded_item_ids
    end
```

`app/lib/item_rankings/books/calculator.rb`, in its `protected` section:

```ruby
      # Provisional books are imports nobody has approved. update_ranked_items
      # deletes ranked rows missing from the new set, so a book flagged after it
      # was ranked drops out on the next calculation.
      def excluded_item_ids
        ::Books::Book.where(provisional: true).pluck(:id).to_set
      end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/item_rankings/`
Expected: PASS (music calculator tests unaffected).

- [ ] **Step 5: Write the failing author calculator test**

Append to `test/lib/item_rankings/books/authors/calculator_test.rb`:

```ruby
        test "leaves provisional authors out of the ranking" do
          credit(books_books(:war_and_peace), @tolstoy)
          credit(books_books(:got), @king)
          rank_book(books_books(:war_and_peace), 100)
          rank_book(books_books(:got), 50)
          @king.update!(provisional: true)

          @calculator.call

          assert_equal [@tolstoy.id], @config.ranked_items.pluck(:item_id)
        end

        test "a provisional book's score does not count toward its author" do
          credit(books_books(:war_and_peace), @tolstoy)
          credit(books_books(:got), @king)
          rank_book(books_books(:war_and_peace), 100)
          rank_book(books_books(:got), 50)
          books_books(:got).update!(provisional: true)

          @calculator.call

          assert_equal [@tolstoy.id], @config.ranked_items.pluck(:item_id)
        end
```

The second test covers the window between a book being flagged and the next books calculation, while its stale `ranked_items` row still exists.

- [ ] **Step 6: Run it to verify it fails**

Run: `bin/rails test test/lib/item_rankings/books/authors/calculator_test.rb`
Expected: both new tests FAIL; King is ranked.

- [ ] **Step 7: Implement**

In `aggregation_sql`:

```sql
            FROM ranked_items ri
            JOIN books_books b ON b.id = ri.item_id
            JOIN books_book_authors ba ON ba.book_id = ri.item_id
            JOIN books_authors a ON a.id = ba.author_id
            WHERE ri.item_type = 'Books::Book'
              AND ri.ranking_configuration_id = #{source_id.to_i}
              AND ri.score > 0
              AND ba.role = #{::Books::BookAuthor.roles[:author].to_i}
              AND a.exclude_from_rankings = FALSE
              AND a.provisional = FALSE
              AND b.provisional = FALSE
            GROUP BY ba.author_id
```

- [ ] **Step 8: Run and commit**

Run: `bin/rails test test/lib/item_rankings/ test/sidekiq/books/calculate_author_rankings_job_test.rb`
Expected: PASS.

```bash
git add web-app/app/lib/item_rankings web-app/test/lib/item_rankings
git commit -m "Rankings: skip provisional books and authors"
```

---

### Task 4: Show pages (notice and noindex) and an author's book list

**Files:**
- Create (generator): `web-app/app/components/books/provisional_notice_component.rb`, `.html.erb`, `web-app/test/components/books/provisional_notice_component_test.rb`
- Modify: `web-app/app/controllers/books/books_controller.rb` (`show` and `similar`: `@indexable`)
- Modify: `web-app/app/controllers/books/authors_controller.rb` (`show`: `@indexable`; `authored_books`)
- Modify: `web-app/app/views/books/books/show.html.erb`, `similar.html.erb`, `web-app/app/views/books/authors/show.html.erb`, `all_books.html.erb`
- Test: `web-app/test/controllers/books/books_controller_test.rb`, `web-app/test/controllers/books/authors_controller_test.rb`

**Interfaces:**
- Consumes: `provisional?`, `Books::Book.catalog` (Task 1).
- Produces: `Books::ProvisionalNoticeComponent.new(record:)`, which renders only when `record.provisional?`, with `data-testid="provisional-notice"` (used by Task 8's E2E).

- [ ] **Step 1: Generate the component**

Run: `bin/rails generate component Books::ProvisionalNotice record`

- [ ] **Step 2: Write the failing component test**

`test/components/books/provisional_notice_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::ProvisionalNoticeComponentTest < ViewComponent::TestCase
  test "renders for a provisional record" do
    book = books_books(:war_and_peace)
    book.provisional = true

    render_inline(Books::ProvisionalNoticeComponent.new(record: book))

    assert_selector "[data-testid='provisional-notice']"
  end

  test "renders nothing for a catalog record" do
    render_inline(Books::ProvisionalNoticeComponent.new(record: books_authors(:tolstoy)))

    assert_no_selector "[data-testid='provisional-notice']"
  end
end
```

Run: `bin/rails test test/components/books/provisional_notice_component_test.rb`
Expected: FAIL. The generated template renders no testid.

- [ ] **Step 3: Implement the component**

`app/components/books/provisional_notice_component.rb`:

```ruby
# frozen_string_literal: true

class Books::ProvisionalNoticeComponent < ViewComponent::Base
  def initialize(record:)
    @record = record
  end

  def render?
    @record.provisional?
  end
end
```

`app/components/books/provisional_notice_component.html.erb`:

```erb
<div role="status" class="alert alert-info mb-6" data-testid="provisional-notice">
  <span>Added from a Goodreads import; not yet reviewed or enriched.</span>
</div>
```

It depends only on the record, so the edge-cached HTML stays identical for every visitor.

Run: same test. Expected: PASS.

- [ ] **Step 4: Write the failing controller tests**

`test/controllers/books/books_controller_test.rb`:

```ruby
    test "a provisional book renders but is never indexable, even when ranked" do
      @book.update!(provisional: true)
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)

      get "/book/#{@book.slug}"

      assert_response :success
      refute @controller.view_assigns["indexable"]
      assert_select "meta[name=robots][content^=noindex]"
    end

    test "the similar page of a provisional book is never indexable" do
      @book.update!(provisional: true)
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)
      ::Services::Books::SimilarBooks.stubs(:call).returns(
        ::Services::Books::SimilarBooks::Result.new(success?: true, data: {books: [books_books(:crime_and_punishment)], more_available: false}, errors: [])
      )

      get "/book/#{@book.slug}/similar"

      assert_response :success
      refute @controller.view_assigns["indexable"]
    end
```

Before writing the stub, read the existing `stubs(:call).returns(` at line ~352 of this file. Copy its exact `Result.new(...)` shape and the similar page's URL from the "full similar-books page" tests (line ~375). The shape above is a guess at both.

`test/controllers/books/authors_controller_test.rb` (read its setup first for the host, the author fixture and how a book is credited; the snippets assume `@author = books_authors(:tolstoy)`, a books host, and `war_and_peace` credited to Tolstoy as `:author`):

```ruby
    test "a provisional author renders but is never indexable" do
      @author.update!(provisional: true)

      get "/author/#{@author.slug}"

      assert_response :success
      refute @controller.view_assigns["indexable"]
    end

    test "the author's book lists leave out provisional books" do
      provisional = ::Books::Book.create!(title: "An Unapproved Tolstoy", provisional: true)
      ::Books::BookAuthor.create!(book: provisional, author: @author, role: :author, position: 9)

      get "/author/#{@author.slug}/all-books"

      assert_response :success
      refute_includes @controller.view_assigns["books"].map(&:id), provisional.id
      assert_includes @controller.view_assigns["books"].map(&:id), books_books(:war_and_peace).id
    end
```

Routes (verified): `/author/:slug` and `/author/:slug/all-books`. If the test file's setup does not credit `war_and_peace` to Tolstoy, create that `Books::BookAuthor` in the test: the positive half is what makes the test non-vacuous.

Run: `bin/rails test test/controllers/books/books_controller_test.rb test/controllers/books/authors_controller_test.rb`
Expected: the indexable tests FAIL (ranked ⇒ indexable today) and the book-list test FAILS (the provisional book is listed).

- [ ] **Step 5: Implement the controllers**

`books_controller.rb#show`:

```ruby
    # A provisional book is reachable by URL but stays out of search engines until
    # an admin approves its import (Goodreads import spec §9).
    @indexable = @ranked_item.present? && !@book.provisional?
```

`books_controller.rb#similar`: change its existing `@indexable = …` line to append `&& !@book.provisional?`.

`authors_controller.rb#show`:

```ruby
    @indexable = @ranked_item.present? && !@author.provisional?
```

`authors_controller.rb#authored_books`:

```ruby
  def authored_books
    @author.books.merge(Books::Book.catalog).where(books_book_authors: {role: Books::BookAuthor.roles[:author]})
  end
```

Extend the comment above it with one line: `Provisional books are left out (Goodreads import spec §9).`

- [ ] **Step 6: Render the notice**

Insert `<%= render Books::ProvisionalNoticeComponent.new(record: @book) %>` directly after the closing `%>` of the `content_for` block in `books/books/show.html.erb` (before the grid `<div>`) and in `books/books/similar.html.erb` (before `<div class="mb-6">`). Insert `<%= render Books::ProvisionalNoticeComponent.new(record: @author) %>` as the first child inside `<div class="space-y-8">` in `books/authors/show.html.erb` and `all_books.html.erb`.

- [ ] **Step 7: Run and commit**

Run: `bin/rails test test/controllers/books/ test/components/books/`
Expected: PASS.

```bash
git add web-app/app/components/books/provisional_notice_component.* web-app/test/components/books/provisional_notice_component_test.rb web-app/app/controllers/books web-app/app/views/books web-app/test/controllers/books
git commit -m "Books: notice and noindex on provisional show pages"
```

---

### Task 5: Other people's views of a user's lists, and the generated favorites list

**Files:**
- Modify: `web-app/app/models/user_list.rb` (new class hook, beside `listable_display_includes`)
- Modify: `web-app/app/models/books/user_list.rb` (override)
- Modify: `web-app/app/controllers/my_lists_controller.rb` (`show`, the `scope = …` line, ~69)
- Modify: `web-app/app/lib/services/lists/user_favorites_tally.rb` (`load_ballots`)
- Modify: `web-app/app/lib/services/books/reading_goals/progress_query.rb`
- Modify: `web-app/app/controllers/books/reading_goals_controller.rb`
- Test: `web-app/test/models/books/user_list_test.rb`, `web-app/test/controllers/my_lists_controller_test.rb`, `web-app/test/lib/services/lists/user_favorites_tally_test.rb`, `web-app/test/lib/services/books/reading_goals/progress_query_test.rb`, `web-app/test/controllers/books/reading_goals_controller_test.rb`

**Interfaces:**
- Consumes: `Books::Book.catalog` (Task 1).
- Produces: `UserList.catalog_items(scope)`. It takes a `UserListItem` relation and returns it restricted to listables the public may see. The base returns the scope unchanged; `Books::UserList` filters to `Books::Book.catalog`. Also produces `ProgressQuery.call(goal:, page: 1, catalog_only: false)`.

- [ ] **Step 1: Write the failing hook test**

Append to `test/models/books/user_list_test.rb` (create the file with the standard `require "test_helper"` / `module Books; class UserListTest < ActiveSupport::TestCase` shell if it does not exist):

```ruby
    test "catalog_items keeps catalog books and drops provisional ones" do
      list = user_lists(:regular_user_books_read)
      kept = list.user_list_items.create!(listable: books_books(:war_and_peace))
      provisional = ::Books::Book.create!(title: "An Unapproved Import", provisional: true)
      dropped = list.user_list_items.create!(listable: provisional)

      ids = ::Books::UserList.catalog_items(list.user_list_items).pluck(:id)

      assert_includes ids, kept.id
      refute_includes ids, dropped.id
    end
```

Run: `bin/rails test test/models/books/user_list_test.rb`
Expected: FAIL (undefined method `catalog_items`).

- [ ] **Step 2: Implement the hook**

`app/models/user_list.rb`, after `listable_display_includes`:

```ruby
  # Narrows a UserListItem relation to the items anyone but the owner may see.
  # Base hides nothing; Books hides provisional imports (Goodreads import spec §9).
  def self.catalog_items(scope)
    scope
  end
```

`app/models/books/user_list.rb`, beside its other class-method overrides:

```ruby
    def self.catalog_items(scope)
      scope.where(listable_id: ::Books::Book.catalog.select(:id))
    end
```

Run: same test. Expected: PASS.

- [ ] **Step 3: Write the failing list-page tests**

Append to `test/controllers/my_lists_controller_test.rb`:

```ruby
  test "a provisional book on a public Books list is hidden from other viewers" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_read)
    list.update!(public: true)
    provisional = ::Books::Book.create!(title: "An Unapproved Import", provisional: true)
    hidden = list.user_list_items.create!(listable: provisional)
    shown = list.user_list_items.create!(listable: books_books(:war_and_peace))

    get user_list_path(list)

    assert_response :success
    item_ids = @controller.view_assigns["items"].map(&:id)
    assert_includes item_ids, shown.id
    refute_includes item_ids, hidden.id
  end

  test "the owner still sees their provisional book" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_read)
    provisional = ::Books::Book.create!(title: "An Unapproved Import", provisional: true)
    item = list.user_list_items.create!(listable: provisional)
    sign_in_as(@user, stub_auth: true)

    get my_list_path(list)

    assert_response :success
    assert_includes @controller.view_assigns["items"].map(&:id), item.id
  end
```

Run: `bin/rails test test/controllers/my_lists_controller_test.rb`
Expected: the first FAILS (the hidden item is listed); the second passes and pins the owner path.

- [ ] **Step 4: Implement in `MyListsController#show`**

Replace the `scope = …` line:

```ruby
    scope = @list.user_list_items.ordered.includes(listable: @list.class.listable_display_includes)
    scope = @list.class.catalog_items(scope) unless @owner
```

HTML, CSV and the ranking sort all derive from `scope`, so all three are covered.

Run: same test. Expected: PASS.

- [ ] **Step 5: Write the failing favorites-tally test**

Append to `test/lib/services/lists/user_favorites_tally_test.rb`:

```ruby
      test "a provisional book casts no vote and costs the ballot no mass" do
        a = books_books(:war_and_peace)
        b = books_books(:got)
        provisional = ::Books::Book.create!(title: "An Unapproved Import", provisional: true)
        build_ballot([a, provisional, b])

        result = tally

        assert_nil score_for(result, provisional)
        # Dropped before the ballot is built: two items share sqrt(2), not sqrt(3).
        assert_in_delta Math.sqrt(2) / 2, score_for(result, a), 0.0001
      end
```

Run: `bin/rails test test/lib/services/lists/user_favorites_tally_test.rb`
Expected: FAIL (the provisional book has a score).

- [ ] **Step 6: Implement in `load_ballots`**

```ruby
        relation = ::UserListItem
          .joins(:user_list)
          .where(user_lists: {type: @user_list_class.name, list_type: favorites})
        rows = @user_list_class.catalog_items(relation)
          .order(Arel.sql("user_list_items.user_list_id, user_list_items.position, user_list_items.id"))
          .pluck(
            ...unchanged...
          )
```

Add a line to the method comment: `Provisional imports are filtered here, before ballots are built, so they neither score nor dilute a voter's mass.`

Run: `bin/rails test test/lib/services/lists/ test/sidekiq/generate_user_favorites_lists_job_test.rb`
Expected: PASS.

- [ ] **Step 7: Write the failing reading-goal tests**

Append to `test/lib/services/books/reading_goals/progress_query_test.rb`:

```ruby
        test "catalog_only leaves out provisional books; the default keeps them" do
          goal = reading_goal
          kept = add_read_item(goal.user, books_books(:war_and_peace), goal.starts_on)
          provisional = ::Books::Book.create!(title: "An Unapproved Import", provisional: true)
          hidden = add_read_item(goal.user, provisional, goal.starts_on)

          public_view = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, catalog_only: true)
          owner_view = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_equal [kept.id], public_view.items.map(&:id)
          assert_equal 1, public_view.count
          assert_equal [hidden.id, kept.id].sort, owner_view.items.map(&:id).sort
        end
```

Append to `test/controllers/books/reading_goals_controller_test.rb`:

```ruby
  test "a public goal's page leaves out provisional books" do
    Services::Books::ReadingGoals::ProgressQuery.expects(:call)
      .with(goal: @public_goal, page: 1, catalog_only: true)
      .returns(Services::Books::ReadingGoals::ProgressQuery::Progress.new(items: [], count: 0, percentage: 0.0, complete: false, bar_percentage: 0.0))

    get books_reading_goal_path(@public_goal), headers: {"HOST" => @host}

    assert_response :success
  end
```

Run: `bin/rails test test/lib/services/books/reading_goals/progress_query_test.rb test/controllers/books/reading_goals_controller_test.rb`
Expected: both FAIL (unknown keyword `catalog_only`; unexpected invocation).

- [ ] **Step 8: Implement**

`progress_query.rb`:

```ruby
        def self.call(goal:, page: 1, catalog_only: false)
          new(goal: goal, page: page, catalog_only: catalog_only).call
        end

        def initialize(goal:, page: 1, catalog_only: false)
          @goal = goal
          @page = [page.to_i, 1].max
          @catalog_only = catalog_only
        end
```

Add `:catalog_only` to the `attr_reader`. In `projected_items`, assign the existing chain to `items`, then:

```ruby
          catalog_only ? ::Books::UserList.catalog_items(items) : items
```

`reading_goals_controller.rb#show`:

```ruby
    # A public goal is edge-cached and identical for every viewer, owner included,
    # so it can only show what anyone may see.
    @progress = Services::Books::ReadingGoals::ProgressQuery.call(
      goal: @reading_goal,
      page: params[:page] || 1,
      catalog_only: @reading_goal.public?
    )
```

The cache invalidators keep calling `ProgressQuery` without the option. A count that is higher than the public page's only purges an extra page, which is harmless.

- [ ] **Step 9: Run and commit**

Run: `bin/rails test test/models/books/user_list_test.rb test/controllers/my_lists_controller_test.rb test/lib/services/lists test/lib/services/books/reading_goals test/controllers/books/reading_goals_controller_test.rb`
Expected: PASS.

```bash
git add web-app/app/models/user_list.rb web-app/app/models/books/user_list.rb web-app/app/controllers/my_lists_controller.rb web-app/app/lib/services/lists/user_favorites_tally.rb web-app/app/lib/services/books/reading_goals/progress_query.rb web-app/app/controllers/books/reading_goals_controller.rb web-app/test
git commit -m "Lists: hide provisional books from other viewers and the favorites tally"
```

---

### Task 6: The public API

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/books_controller.rb` (`show`)
- Modify: `web-app/app/controllers/api/v1/books/book_lists_controller.rb` (`index`)
- Modify: `web-app/app/controllers/api/v1/books/authors_controller.rb` (`show`)
- Modify: `web-app/app/controllers/api/v1/books/base_controller.rb` (`book_items`)
- Test: the four matching files in `web-app/test/controllers/api/v1/books/` (`books_controller_test.rb`, `book_lists_controller_test.rb`, `authors_controller_test.rb`, `list_items_controller_test.rb`)

**Interfaces:**
- Consumes: `::Books::Book.catalog`, `::Books::Author.catalog` (Task 1). Ranked endpoints (`/books`, `/authors`, `/ranking_configurations/:id/books`) are already covered by Task 3.

- [ ] **Step 1: Write the failing tests**

`books_controller_test.rb`:

```ruby
        test "show of a provisional book is a 404 problem" do
          @war_and_peace.update!(provisional: true)

          get "/api/v1/books/#{@war_and_peace.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end
```

`book_lists_controller_test.rb`:

```ruby
        test "the lists of a provisional book are a 404 problem" do
          @book.update!(provisional: true)

          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end
```

`authors_controller_test.rb` (read its setup for the author ivar; the snippet assumes `books_authors(:tolstoy)`):

```ruby
        test "show of a provisional author is a 404 problem" do
          author = books_authors(:tolstoy)
          author.update!(provisional: true)

          get "/api/v1/authors/#{author.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end
```

`list_items_controller_test.rb`:

```ruby
        test "a row whose book is provisional is neither counted nor served" do
          @got.update!(provisional: true)

          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 3, json[:meta][:total_count]
          refute_includes json[:data].map { |row| row[:book][:slug] }, @got.slug
        end
```

Check the row shape against the existing "rows are {position, book}" test: if the key is not `row[:book][:slug]`, use the one it uses. Four valid book rows exist in setup (crime, war and peace, got, mice), so 3 remain.

Run: `bin/rails test test/controllers/api/v1/books/`
Expected: the four new tests FAIL (200 instead of 404; total_count 4).

- [ ] **Step 2: Implement**

In `books_controller.rb#show`, `book_lists_controller.rb#index` and `authors_controller.rb#show`, insert `.catalog` before `.find_by!(slug: params[:slug])`. For example:

```ruby
          book = ::Books::Book
            .includes(:categories, :countries, :original_language, :descriptions, {book_authors: :author},
              {primary_image: {file_attachment: :blob}})
            .catalog
            .find_by!(slug: params[:slug])
```

`book_lists_controller.rb`: `book = ::Books::Book.catalog.find_by!(slug: params[:slug])`.

`base_controller.rb#book_items`:

```ruby
        def book_items(scope)
          scope.by_listable_type("Books::Book").where(listable_id: ::Books::Book.catalog.select(:id))
        end
```

Add `…or whose book is a provisional import` to the comment above it.

- [ ] **Step 3: Run and commit**

Run: `bin/rails test test/controllers/api/`
Expected: PASS.

```bash
git add web-app/app/controllers/api/v1/books web-app/test/controllers/api/v1/books
git commit -m "API: provisional books and authors are not served"
```

---

### Task 7: Mergers keep a merged record in the catalog

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb` (`reconcile_scalars`, line ~469)
- Modify: `web-app/app/lib/books/author/merger.rb` (`reconcile_scalars`, line ~356)
- Test: `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/lib/books/author/merger_test.rb`

**Interfaces:**
- Consumes: the `provisional` attribute (Task 1). Increment 5's `merge_books` and `merge_authors` verdicts rely on this rule.

- [ ] **Step 1: Write the failing tests**

`test/lib/books/book/merger_test.rb` (setup has `@source = crime_and_punishment`, `@target = war_and_peace`):

```ruby
      test "merging a catalog book into a provisional one leaves a catalog book" do
        @target.update!(provisional: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        refute @target.reload.provisional?
      end

      test "merging two provisional books leaves a provisional book" do
        @source.update!(provisional: true)
        @target.update!(provisional: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert @target.reload.provisional?
      end
```

`test/lib/books/author/merger_test.rb`: read its setup for the source and target ivar names, then add the same two tests against `::Books::Author::Merger`.

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb`
Expected: each "catalog into provisional" test FAILS; each "two provisional" test passes.

- [ ] **Step 2: Implement**

`book/merger.rb`:

```ruby
      def reconcile_scalars
        fill_blank_fields
        reconcile_first_published_year
        absorb_alternate_titles
        reconcile_provisional
      end

      # The merged book is provisional only if both halves were. Folding a real book
      # into an unapproved import must not hide the real one.
      def reconcile_provisional
        target_book.provisional = false unless source_book.provisional?
      end
```

`author/merger.rb`: same, with `target_author` and `source_author`, called from its `reconcile_scalars` after `absorb_alternate_names`. Before relying on it, confirm that each merger persists the target with `save!` after `reconcile_scalars`, like `fill_blank_fields` does.

- [ ] **Step 3: Run and commit**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/books/author/merger_test.rb`
Expected: PASS.

```bash
git add web-app/app/lib/books/book/merger.rb web-app/app/lib/books/author/merger.rb web-app/test/lib/books
git commit -m "Mergers: a merge with a catalog record stays in the catalog"
```

---

### Task 8: E2E, feature doc, full verification

**Files:**
- Modify: `web-app/lib/tasks/e2e.rake` (constants at the top, two tasks at the end of the namespace)
- Create: `web-app/e2e/tests/books/provisional.spec.ts`
- Create: `docs/features/books-provisional-records.md`

**Interfaces:**
- Consumes: `data-testid="provisional-notice"` (Task 4); the robots meta (Task 4).

- [ ] **Step 1: Add the seed and cleanup tasks**

At the top of `lib/tasks/e2e.rake`, beside the other constants:

```ruby
# The provisional book and author e2e:provisional_seed owns, found by title and name.
PROVISIONAL_BOOK_TITLE = "E2E Provisional Seed"
PROVISIONAL_AUTHOR_NAME = "E2E Provisional Seed Author"
```

Inside the `namespace :e2e` block, after the `reject_link_cleanup` task:

```ruby
  desc "Seed a provisional book and author for e2e/tests/books/provisional.spec.ts"
  task provisional_seed: :environment do
    # Idempotent: a rerun finds both rows and re-flags them.
    author = Books::Author.find_or_initialize_by(name: PROVISIONAL_AUTHOR_NAME)
    author.update!(provisional: true, exclude_from_rankings: true)
    book = Books::Book.find_or_initialize_by(title: PROVISIONAL_BOOK_TITLE)
    book.update!(provisional: true)
    Books::BookAuthor.find_or_create_by!(book: book, author: author) { |credit| credit.role = :author }

    puts({book_slug: book.slug, author_slug: author.slug}.to_json)
  end

  desc "Remove the rows e2e:provisional_seed created"
  task provisional_cleanup: :environment do
    book = Books::Book.find_by(title: PROVISIONAL_BOOK_TITLE)
    author = Books::Author.find_by(name: PROVISIONAL_AUTHOR_NAME)
    book&.destroy!
    author&.destroy!
    puts "removed #{[book, author].compact.size} row(s)"
  end
```

Run: `bin/rails e2e:provisional_seed`
Expected: one JSON line with both slugs. Running it a second time prints the same slugs.

- [ ] **Step 2: Write the spec**

`e2e/tests/books/provisional.spec.ts`:

```ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Goodreads import spec §9: a provisional book or author loads by URL, shows a
// notice, and is noindex. The rake tasks run from web-app, like reject-link.spec.ts.
const WEB_APP = path.resolve(__dirname, "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });
const lastJson = (output: string) => {
  const lines = output.trim().split("\n");
  return JSON.parse(lines[lines.length - 1]);
};

let seed: { book_slug: string; author_slug: string };

test.describe("Books — provisional records", () => {
  test.beforeAll(() => {
    seed = lastJson(rails("e2e:provisional_seed"));
  });

  test.afterAll(() => {
    rails("e2e:provisional_cleanup");
  });

  test("a provisional book shows the notice and is noindex", async ({ page }) => {
    await page.goto(`/book/${seed.book_slug}`);

    await expect(page.getByTestId("provisional-notice")).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
  });

  test("a provisional author shows the notice and is noindex", async ({ page }) => {
    await page.goto(`/author/${seed.author_slug}`);

    await expect(page.getByTestId("provisional-notice")).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
  });

  test("a catalog book shows no notice", async ({ page }) => {
    await page.goto("/book/headlong-hall");

    await expect(page.getByTestId("provisional-notice")).toHaveCount(0);
  });
});
```

Check: `WEB_APP` must resolve to `web-app/`. This file is one directory shallower than `admin/reject-link.spec.ts`, so it uses three `..`, not four. The `/book/:slug` and `/author/:slug` routes are verified.

- [ ] **Step 3: Run the E2E**

Build and boot: `yarn build:all`, then `bin/rails server` in the background. Before running, confirm port 3000 is this worktree's:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If it prints another checkout, stop and tell the user.

Run: `yarn test:e2e e2e/tests/books/provisional.spec.ts`
Expected: 3 passed.

- [ ] **Step 4: Write the feature doc**

`docs/features/books-provisional-records.md`: one page that states:
- what the flag means;
- the `catalog` scope rule ("public surfaces read through it; the import finder and admin do not");
- the `must_not` search clause and why it is not a filter;
- that rankings exclude at calculation, so whoever flags an existing book provisional (increment 5's replay) must queue a books ranking recalculation and an author ranking recalculation afterwards;
- the merge rule;
- the list of surfaces, each with its file;
- sitemaps do not exist yet; when they are built they must read through `catalog` (spec §9 lists them).

No class-level docs (the docs rule is about files in `docs/`).

- [ ] **Step 5: Full verification**

Run: `bin/rails test > ../../tmp-suite.log 2>&1; tail -30 ../../tmp-suite.log`. Write the log to a scratch path outside the repo if you prefer.
Expected: 0 failures, 0 errors, no new warning lines. If a wall of books-route 404s appears, note the seed: seed 27887 is a known leak on main (see memory). Rerun without the seed.

Run: `bundle exec standardrb`
Expected: no offenses.

Run: `CI=1 bin/rails zeitwerk:check`
Expected: `All is good!`

- [ ] **Step 6: Commit**

```bash
git add web-app/lib/tasks/e2e.rake web-app/e2e/tests/books/provisional.spec.ts docs/features/books-provisional-records.md
git commit -m "Books: E2E and feature doc for provisional records"
```
