# Books & Authors Search Indexing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the OpenSearch backend (index classes, indexing pipeline, query classes) for `Books::Book` and `Books::Author`, providing general-purpose search and book autocomplete.

**Architecture:** Mirror the existing music domain exactly. Two index classes subclass `Search::Base::Index`; three query classes subclass `Search::Base::Search` and use `Search::Shared::Utils` builders. Turn on the existing `SearchIndexable` → `SearchIndexRequest` → `Search::IndexerJob` pipeline for the two models, plus freshness triggers so book documents stay correct when authorship or author names change.

**Tech Stack:** Rails 8, `opensearch-ruby`, Minitest + fixtures + Mocha, Sidekiq.

## Global Constraints

- Reference spec: `docs/superpowers/specs/2026-07-02-books-authors-search-indexing-design.md`. Reference feature doc: `docs/features/search.md`.
- Run all commands from `web-app/`.
- **Search index/query tests hit a real OpenSearch** — it must be running (`docker compose up` per `docker-compose.yml`; `OPENSEARCH_URL` set). Model/job tests do not need it.
- Every new Ruby file starts with `# frozen_string_literal: true`.
- All books search code namespaced under `Search::Books::` (index classes) and `Search::Books::Search::` (query classes); shared infra (`Search::Base::*`, `Search::Shared::*`, `SearchIndexRequest`, `SearchIndexable`) is reused **unchanged**.
- Skinny models: query logic lives in the `Search::Books::Search::*` classes, never in models.
- `book_kind` is indexed as its string enum value (`"standalone"` / `"collection"`); general search and autocomplete filter to `standalone`.
- CI must stay green: `bin/rubocop -f github`, `bin/brakeman --no-pager`, `bin/rails test`. Run `bin/rubocop -a` before each commit; autocorrect anything it flags.
- Branch: `books-authors-search-indexing` (already created).
- No new fixtures are required — the existing `test/fixtures/books/*.yml` already contain standalone books with an author link (`war_and_peace` ← `tolstoy`) and a `collection` book (`combo_steinbeck`, title "Of Mice and Men / Cannery Row") alongside a standalone `of_mice_and_men`, which is exactly what the exclusion tests need.

---

### Task 1: `Search::Books::BookIndex` + book document shape

**Files:**
- Modify: `app/models/books/book.rb` (extend `as_indexed_json`, ~lines 71-79)
- Create: `app/lib/search/books/book_index.rb`
- Test: `test/lib/search/books/book_index_test.rb`

**Interfaces:**
- Consumes: `Search::Base::Index` (base class), `Books::Book#as_indexed_json`.
- Produces: `Search::Books::BookIndex` with class methods `index_name`, `index_definition`, `model_klass`, `model_includes`, and inherited `create_index`, `delete_index`, `index_exists?`, `index(model)`, `find(id)`, `bulk_index`, `reindex_all`. `index_name` returns `books_books_{env}` (test: `books_books_test_{pid}`). Book document keys: `title, subtitle, alternate_titles, author_names, author_ids, category_ids, book_kind`.

- [ ] **Step 1: Update the book document shape**

In `app/models/books/book.rb`, replace the existing `as_indexed_json` method:

```ruby
  def as_indexed_json
    {
      title: title,
      subtitle: subtitle,
      alternate_titles: alternate_titles,
      author_names: authors.map(&:name),
      author_ids: authors.map(&:id),
      category_ids: categories.active.pluck(:id),
      book_kind: book_kind
    }
  end
```

- [ ] **Step 2: Write the failing test**

Create `test/lib/search/books/book_index_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    class BookIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Books::BookIndex.index_name
        assert_match(/^books_books_test/, index_name)
        assert_match(/books_books_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Books::BookIndex.index_definition

        assert definition[:settings][:analysis][:analyzer][:folding]
        assert_equal "standard", definition[:settings][:analysis][:analyzer][:folding][:tokenizer]
        assert_equal ["lowercase", "asciifolding"], definition[:settings][:analysis][:analyzer][:folding][:filter]

        properties = definition[:mappings][:properties]
        assert_equal "text", properties[:title][:type]
        assert_equal "folding", properties[:title][:analyzer]
        assert_equal "keyword", properties[:title][:fields][:keyword][:type]
        assert_equal "autocomplete", properties[:title][:fields][:autocomplete][:analyzer]
        assert_equal "autocomplete_search", properties[:title][:fields][:autocomplete][:search_analyzer]
        assert_equal "text", properties[:subtitle][:type]
        assert_equal "text", properties[:alternate_titles][:type]
        assert_equal "text", properties[:author_names][:type]
        assert_equal "keyword", properties[:author_ids][:type]
        assert_equal "keyword", properties[:category_ids][:type]
        assert_equal "keyword", properties[:book_kind][:type]
      end

      test "can create and delete index" do
        ::Search::Books::BookIndex.create_index
        assert ::Search::Books::BookIndex.index_exists?

        ::Search::Books::BookIndex.delete_index
        assert_not ::Search::Books::BookIndex.index_exists?
      end

      test "can index and find book" do
        ::Search::Books::BookIndex.create_index

        book = books_books(:war_and_peace)
        ::Search::Books::BookIndex.index(book)
        sleep(0.1)

        result = ::Search::Books::BookIndex.find(book.id)
        assert_equal "War and Peace", result["title"]
        assert_equal "standalone", result["book_kind"]
        assert_includes result["author_names"], "Leo Tolstoy"
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

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::BookIndex`.

- [ ] **Step 4: Create the index class**

Create `app/lib/search/books/book_index.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    class BookIndex < ::Search::Base::Index
      def self.model_klass
        ::Books::Book
      end

      def self.model_includes
        [:authors]
      end

      def self.index_definition
        {
          settings: {
            analysis: {
              filter: {
                edge_ngram_filter: {
                  type: "edge_ngram",
                  min_gram: 3,
                  max_gram: 20
                },
                ascii_folding_with_preserve: {
                  type: "asciifolding",
                  preserve_original: true
                }
              },
              analyzer: {
                folding: {
                  tokenizer: "standard",
                  filter: ["lowercase", "asciifolding"]
                },
                autocomplete: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "edge_ngram_filter",
                    "ascii_folding_with_preserve"
                  ]
                },
                autocomplete_search: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "ascii_folding_with_preserve"
                  ]
                }
              }
            }
          },
          mappings: {
            properties: {
              title: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  },
                  autocomplete: {
                    type: "text",
                    analyzer: "autocomplete",
                    search_analyzer: "autocomplete_search"
                  }
                }
              },
              subtitle: {
                type: "text",
                analyzer: "folding"
              },
              alternate_titles: {
                type: "text",
                analyzer: "folding"
              },
              author_names: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  }
                }
              },
              author_ids: {
                type: "keyword"
              },
              category_ids: {
                type: "keyword"
              },
              book_kind: {
                type: "keyword"
              }
            }
          }
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/lib/search/books/book_index_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 6: Lint and commit**

```bash
bin/rubocop -a app/lib/search/books/book_index.rb app/models/books/book.rb test/lib/search/books/book_index_test.rb
git add app/lib/search/books/book_index.rb app/models/books/book.rb test/lib/search/books/book_index_test.rb
git commit -m "Add Search::Books::BookIndex and book document shape"
```

---

### Task 2: `Search::Books::AuthorIndex`

**Files:**
- Create: `app/lib/search/books/author_index.rb`
- Test: `test/lib/search/books/author_index_test.rb`

**Interfaces:**
- Consumes: `Search::Base::Index`, `Books::Author#as_indexed_json` (unchanged: `name, alternate_names, category_ids`).
- Produces: `Search::Books::AuthorIndex`; `index_name` returns `books_authors_{env}`. Author document fields as above; `name` has `.keyword` and `.autocomplete` subfields.

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/books/author_index_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    class AuthorIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Books::AuthorIndex.index_name
        assert_match(/^books_authors_test/, index_name)
        assert_match(/books_authors_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Books::AuthorIndex.index_definition

        properties = definition[:mappings][:properties]
        assert_equal "text", properties[:name][:type]
        assert_equal "folding", properties[:name][:analyzer]
        assert_equal "keyword", properties[:name][:fields][:keyword][:type]
        assert_equal "autocomplete", properties[:name][:fields][:autocomplete][:analyzer]
        assert_equal "text", properties[:alternate_names][:type]
        assert_equal "keyword", properties[:category_ids][:type]
      end

      test "can create and delete index" do
        ::Search::Books::AuthorIndex.create_index
        assert ::Search::Books::AuthorIndex.index_exists?

        ::Search::Books::AuthorIndex.delete_index
        assert_not ::Search::Books::AuthorIndex.index_exists?
      end

      test "can index and find author" do
        ::Search::Books::AuthorIndex.create_index

        author = books_authors(:tolstoy)
        ::Search::Books::AuthorIndex.index(author)
        sleep(0.1)

        result = ::Search::Books::AuthorIndex.find(author.id)
        assert_equal "Leo Tolstoy", result["name"]
        assert_includes result["alternate_names"], "Lev Tolstoy"
      end

      private

      def cleanup_test_index
        ::Search::Books::AuthorIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/search/books/author_index_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::AuthorIndex`.

- [ ] **Step 3: Create the index class**

Create `app/lib/search/books/author_index.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    class AuthorIndex < ::Search::Base::Index
      def self.model_klass
        ::Books::Author
      end

      def self.index_definition
        {
          settings: {
            analysis: {
              filter: {
                edge_ngram_filter: {
                  type: "edge_ngram",
                  min_gram: 3,
                  max_gram: 20
                },
                ascii_folding_with_preserve: {
                  type: "asciifolding",
                  preserve_original: true
                }
              },
              analyzer: {
                folding: {
                  tokenizer: "standard",
                  filter: ["lowercase", "asciifolding"]
                },
                autocomplete: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "edge_ngram_filter",
                    "ascii_folding_with_preserve"
                  ]
                },
                autocomplete_search: {
                  type: "custom",
                  tokenizer: "standard",
                  filter: [
                    "lowercase",
                    "ascii_folding_with_preserve"
                  ]
                }
              }
            }
          },
          mappings: {
            properties: {
              name: {
                type: "text",
                analyzer: "folding",
                fields: {
                  keyword: {
                    type: "keyword",
                    normalizer: "lowercase"
                  },
                  autocomplete: {
                    type: "text",
                    analyzer: "autocomplete",
                    search_analyzer: "autocomplete_search"
                  }
                }
              },
              alternate_names: {
                type: "text",
                analyzer: "folding"
              },
              category_ids: {
                type: "keyword"
              }
            }
          }
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/search/books/author_index_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/lib/search/books/author_index.rb test/lib/search/books/author_index_test.rb
git add app/lib/search/books/author_index.rb test/lib/search/books/author_index_test.rb
git commit -m "Add Search::Books::AuthorIndex"
```

---

### Task 3: `Search::Books::Search::BookGeneral` (general-purpose book search)

**Files:**
- Create: `app/lib/search/books/search/book_general.rb`
- Test: `test/lib/search/books/search/book_general_test.rb`

**Interfaces:**
- Consumes: `Search::Base::Search`, `Search::Shared::Utils`, `Search::Books::BookIndex.index_name`.
- Produces: `Search::Books::Search::BookGeneral.call(text, options = {})` → `[{id:, score:, source:}]`; `[]` for blank text. Options: `min_score` (default 1), `size` (default 10), `from` (default 0). Filters results to `book_kind: "standalone"`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/books/search/book_general_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookGeneralTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::BookGeneral.call("")
          assert_equal [], ::Search::Books::Search::BookGeneral.call(nil)
        end

        test "call finds books by title" do
          book = books_books(:war_and_peace)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookGeneral.call("War and Peace")

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "War and Peace", results[0][:source]["title"]
        end

        test "call finds books by author name" do
          book = books_books(:war_and_peace)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookGeneral.call("Tolstoy")

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
        end

        test "call finds books by alternate title" do
          book = books_books(:war_and_peace)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookGeneral.call("Voyna i mir")

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
        end

        test "call excludes collection books" do
          standalone = books_books(:of_mice_and_men)
          collection = books_books(:combo_steinbeck)
          ::Search::Books::BookIndex.index(standalone)
          ::Search::Books::BookIndex.index(collection)
          sleep(0.1)

          results = ::Search::Books::Search::BookGeneral.call("Of Mice and Men")
          ids = results.map { |r| r[:id] }

          assert_includes ids, standalone.id.to_s
          assert_not_includes ids, collection.id.to_s
        end

        test "call respects custom options" do
          book = books_books(:crime_and_punishment)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookGeneral.call("Crime and Punishment", {
            size: 1,
            from: 0,
            min_score: 0.5
          })

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/search/books/search/book_general_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::Search::BookGeneral`.

- [ ] **Step 3: Create the query class**

Create `app/lib/search/books/search/book_general.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      class BookGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          Rails.logger.info "Book search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_text.downcase, boost: 9.0),
            ::Search::Shared::Utils.build_match_query("title", cleaned_text, boost: 8.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("alternate_titles", cleaned_text, boost: 7.0),
            ::Search::Shared::Utils.build_match_phrase_query("author_names", cleaned_text, boost: 6.0),
            ::Search::Shared::Utils.build_match_query("author_names", cleaned_text, boost: 5.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("subtitle", cleaned_text, boost: 4.0, operator: "and")
          ]

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              filter: [{term: {book_kind: "standalone"}}],
              minimum_should_match: 1
            )
          }
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/search/books/search/book_general_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/lib/search/books/search/book_general.rb test/lib/search/books/search/book_general_test.rb
git add app/lib/search/books/search/book_general.rb test/lib/search/books/search/book_general_test.rb
git commit -m "Add Search::Books::Search::BookGeneral"
```

---

### Task 4: `Search::Books::Search::AuthorGeneral` (general-purpose author search)

**Files:**
- Create: `app/lib/search/books/search/author_general.rb`
- Test: `test/lib/search/books/search/author_general_test.rb`

**Interfaces:**
- Consumes: `Search::Base::Search`, `Search::Shared::Utils`, `Search::Books::AuthorIndex.index_name`.
- Produces: `Search::Books::Search::AuthorGeneral.call(text, options = {})` → `[{id:, score:, source:}]`; `[]` for blank. Options: `min_score` (default 1), `size` (default 10), `from` (default 0). No collection filter (authors have none).

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/books/search/author_general_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class AuthorGeneralTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::AuthorIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::AuthorGeneral.call("")
          assert_equal [], ::Search::Books::Search::AuthorGeneral.call(nil)
        end

        test "call finds authors by name" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Leo Tolstoy")

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "Leo Tolstoy", results[0][:source]["name"]
        end

        test "call finds authors by alternate name" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Lev Nikolayevich Tolstoy")

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
        end

        test "call respects custom options" do
          author = books_authors(:king)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Stephen King", {
            size: 1,
            from: 0,
            min_score: 0.5
          })

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Books::AuthorIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/search/books/search/author_general_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::Search::AuthorGeneral`.

- [ ] **Step 3: Create the query class**

Create `app/lib/search/books/search/author_general.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      class AuthorGeneral < ::Search::Base::Search
        def self.index_name
          ::Search::Books::AuthorIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 1
          size = options[:size] || 10
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          Rails.logger.info "Author search query: #{query_definition.inspect}"

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_phrase_query("name", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_term_query("name.keyword", cleaned_text.downcase, boost: 8.0),
            ::Search::Shared::Utils.build_match_query("name", cleaned_text, boost: 5.0, operator: "and"),
            ::Search::Shared::Utils.build_match_query("alternate_names", cleaned_text, boost: 3.0)
          ]

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              minimum_should_match: 1
            )
          }
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/search/books/search/author_general_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/lib/search/books/search/author_general.rb test/lib/search/books/search/author_general_test.rb
git add app/lib/search/books/search/author_general.rb test/lib/search/books/search/author_general_test.rb
git commit -m "Add Search::Books::Search::AuthorGeneral"
```

---

### Task 5: `Search::Books::Search::BookAutocomplete` (book autocomplete)

**Files:**
- Create: `app/lib/search/books/search/book_autocomplete.rb`
- Test: `test/lib/search/books/search/book_autocomplete_test.rb`

**Interfaces:**
- Consumes: `Search::Base::Search`, `Search::Shared::Utils`, `Search::Books::BookIndex.index_name`.
- Produces: `Search::Books::Search::BookAutocomplete.call(text, options = {})` → `[{id:, score:, source:}]`; `[]` for blank. Options: `min_score` (default 0.1), `size` (default 20), `from` (default 0). Targets `title.autocomplete` (edge-ngram) for prefix matching; filters to `book_kind: "standalone"`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/search/books/search/book_autocomplete_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookAutocompleteTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::BookAutocomplete.call("")
          assert_equal [], ::Search::Books::Search::BookAutocomplete.call(nil)
        end

        test "call finds books with partial prefix match" do
          book = books_books(:crime_and_punishment)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookAutocomplete.call("cri")

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call excludes collection books" do
          standalone = books_books(:of_mice_and_men)
          collection = books_books(:combo_steinbeck)
          ::Search::Books::BookIndex.index(standalone)
          ::Search::Books::BookIndex.index(collection)
          sleep(0.1)

          results = ::Search::Books::Search::BookAutocomplete.call("Of Mice")
          ids = results.map { |r| r[:id] }

          assert_includes ids, standalone.id.to_s
          assert_not_includes ids, collection.id.to_s
        end

        private

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/search/books/search/book_autocomplete_test.rb`
Expected: FAIL with `uninitialized constant Search::Books::Search::BookAutocomplete`.

- [ ] **Step 3: Create the query class**

Create `app/lib/search/books/search/book_autocomplete.rb`:

```ruby
# frozen_string_literal: true

module Search
  module Books
    module Search
      class BookAutocomplete < ::Search::Base::Search
        def self.index_name
          ::Search::Books::BookIndex.index_name
        end

        def self.call(text, options = {})
          return empty_response if text.blank?

          min_score = options[:min_score] || 0.1
          size = options[:size] || 20
          from = options[:from] || 0

          query_definition = build_query_definition(text, min_score, size, from)

          response = search(query_definition)
          extract_hits_with_scores(response)
        end

        def self.build_query_definition(text, min_score, size, from)
          cleaned_text = ::Search::Shared::Utils.normalize_search_text(text)

          should_clauses = [
            ::Search::Shared::Utils.build_match_query("title.autocomplete", cleaned_text, boost: 10.0),
            ::Search::Shared::Utils.build_match_phrase_query("title", cleaned_text, boost: 8.0),
            ::Search::Shared::Utils.build_term_query("title.keyword", cleaned_text.downcase, boost: 6.0)
          ]

          {
            min_score: min_score,
            size: size,
            from: from,
            query: ::Search::Shared::Utils.build_bool_query(
              should: should_clauses,
              filter: [{term: {book_kind: "standalone"}}],
              minimum_should_match: 1
            )
          }
        end

        def self.empty_response
          []
        end

        private_class_method :empty_response
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/search/books/search/book_autocomplete_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/lib/search/books/search/book_autocomplete.rb test/lib/search/books/search/book_autocomplete_test.rb
git add app/lib/search/books/search/book_autocomplete.rb test/lib/search/books/search/book_autocomplete_test.rb
git commit -m "Add Search::Books::Search::BookAutocomplete"
```

---

### Task 6: Turn on the indexing pipeline (SearchIndexable + IndexerJob)

**Files:**
- Modify: `app/models/books/book.rb` (add `include SearchIndexable`, ~line 33)
- Modify: `app/models/books/author.rb` (add `include SearchIndexable`, ~line 23)
- Modify: `app/sidekiq/search/indexer_job.rb:10` (add Books types)
- Test: `test/models/books/book_test.rb`, `test/models/books/author_test.rb`, `test/sidekiq/search/indexer_job_test.rb`

**Interfaces:**
- Consumes: `SearchIndexable` concern (`after_commit` → `SearchIndexRequest`), `Search::IndexerJob` (generic index-class resolution).
- Produces: `Books::Book` and `Books::Author` enqueue `SearchIndexRequest` rows on create/update/destroy, drained into `Search::Books::BookIndex` / `Search::Books::AuthorIndex` by the cron job.

- [ ] **Step 1: Write failing model tests**

In `test/models/books/book_test.rb`, add inside the test class:

```ruby
  # SearchIndexable concern tests
  test "should create search index request on create" do
    assert_difference "SearchIndexRequest.count", 1 do
      Books::Book.create!(title: "Test Search Book")
    end

    request = SearchIndexRequest.last
    assert_equal "Books::Book", request.parent_type
    assert request.index_item?
  end

  test "should create search index request on update" do
    book = books_books(:war_and_peace)

    assert_difference "SearchIndexRequest.count", 1 do
      book.update!(subtitle: "Updated Subtitle")
    end

    request = SearchIndexRequest.last
    assert_equal book, request.parent
    assert request.index_item?
  end

  test "should create search index request on destroy" do
    book = books_books(:crime_and_punishment)

    assert_difference "SearchIndexRequest.count", 1 do
      book.destroy!
    end

    request = SearchIndexRequest.last
    assert_equal book.id, request.parent_id
    assert_equal "Books::Book", request.parent_type
    assert request.unindex_item?
  end
```

In `test/models/books/author_test.rb`, add inside the test class:

```ruby
  # SearchIndexable concern tests
  test "should create search index request on create" do
    assert_difference "SearchIndexRequest.count", 1 do
      Books::Author.create!(name: "Test Search Author")
    end

    request = SearchIndexRequest.last
    assert_equal "Books::Author", request.parent_type
    assert request.index_item?
  end

  test "should create search index request on destroy" do
    author = books_authors(:garnett)

    assert_difference "SearchIndexRequest.count", 1 do
      author.destroy!
    end

    request = SearchIndexRequest.last
    assert_equal author.id, request.parent_id
    assert_equal "Books::Author", request.parent_type
    assert request.unindex_item?
  end
```

Note: `books_books(:crime_and_punishment)` and `books_authors(:garnett)` have no author/book links, so destroy tests count exactly one request (no cascade from Task 7/8 triggers).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/books/book_test.rb test/models/books/author_test.rb`
Expected: FAIL — `SearchIndexRequest.count` does not change (no `SearchIndexable` yet).

- [ ] **Step 3: Include SearchIndexable in both models**

In `app/models/books/book.rb`, add as the first line inside the class body (after `class Books::Book < ApplicationRecord`):

```ruby
  include SearchIndexable
```

In `app/models/books/author.rb`, add as the first line inside the class body (after `class Books::Author < ApplicationRecord`):

```ruby
  include SearchIndexable
```

- [ ] **Step 4: Run model tests to verify they pass**

Run: `bin/rails test test/models/books/book_test.rb test/models/books/author_test.rb`
Expected: PASS (new tests green; existing tests still green).

- [ ] **Step 5: Write failing IndexerJob tests**

In `test/sidekiq/search/indexer_job_test.rb`, add `@book`/`@author` to `setup` (after the `@game` line):

```ruby
    @book = books_books(:war_and_peace)
    @author = books_authors(:tolstoy)
```

Then add these tests inside the class:

```ruby
  test "should process index requests for Books::Book" do
    SearchIndexRequest.create!(parent: @book, action: :index_item)

    Search::Books::BookIndex.stubs(:model_includes).returns([])
    Search::Books::BookIndex.expects(:bulk_index).with([@book])

    @job.perform

    assert_equal 0, SearchIndexRequest.count
  end

  test "should process index requests for Books::Author" do
    SearchIndexRequest.create!(parent: @author, action: :index_item)

    Search::Books::AuthorIndex.stubs(:model_includes).returns([])
    Search::Books::AuthorIndex.expects(:bulk_index).with([@author])

    @job.perform

    assert_equal 0, SearchIndexRequest.count
  end

  test "should process unindex requests for Books::Book" do
    SearchIndexRequest.create!(parent: @book, action: :unindex_item)

    Search::Books::BookIndex.expects(:bulk_unindex).with([@book.id])

    @job.perform

    assert_equal 0, SearchIndexRequest.count
  end
```

- [ ] **Step 6: Run IndexerJob test to verify new tests fail**

Run: `bin/rails test test/sidekiq/search/indexer_job_test.rb`
Expected: FAIL — the new `Books::Book`/`Books::Author` requests are not processed, so `SearchIndexRequest.count` is not 0 (and `bulk_index` expectation is unmet).

- [ ] **Step 7: Register Books types in the IndexerJob**

In `app/sidekiq/search/indexer_job.rb`, change the model-type list (line 10) from:

```ruby
    %w[Music::Artist Music::Album Music::Song Games::Game].each do |model_type|
```

to:

```ruby
    %w[Music::Artist Music::Album Music::Song Games::Game Books::Book Books::Author].each do |model_type|
```

- [ ] **Step 8: Run IndexerJob test to verify it passes**

Run: `bin/rails test test/sidekiq/search/indexer_job_test.rb`
Expected: PASS.

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/models/books/book.rb app/models/books/author.rb app/sidekiq/search/indexer_job.rb test/models/books/book_test.rb test/models/books/author_test.rb test/sidekiq/search/indexer_job_test.rb
git add app/models/books/book.rb app/models/books/author.rb app/sidekiq/search/indexer_job.rb test/models/books/book_test.rb test/models/books/author_test.rb test/sidekiq/search/indexer_job_test.rb
git commit -m "Wire Books::Book and Books::Author into the search indexing pipeline"
```

---

### Task 7: `Books::BookAuthor` reindex trigger

**Files:**
- Modify: `app/models/books/book_author.rb` (add `after_commit` trigger)
- Test: `test/models/books/book_author_test.rb`

**Interfaces:**
- Consumes: `SearchIndexRequest`.
- Produces: any create/update/destroy of a `Books::BookAuthor` enqueues a `SearchIndexRequest` with `parent_type: "Books::Book"`, `parent_id: book_id`, `action: :index_item`, keeping the book document's `author_names`/`author_ids` fresh.

- [ ] **Step 1: Write the failing test**

In `test/models/books/book_author_test.rb`, add inside the test class:

```ruby
  # Search freshness: adding/removing authorship reindexes the book
  test "creating a book author enqueues the book for reindexing" do
    book = books_books(:crime_and_punishment)
    author = books_authors(:garnett)

    assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
      Books::BookAuthor.create!(book: book, author: author, position: 1)
    end
  end

  test "destroying a book author enqueues the book for reindexing" do
    book_author = books_book_authors(:war_and_peace_tolstoy)
    book_id = book_author.book_id

    assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book_id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
      book_author.destroy!
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/books/book_author_test.rb`
Expected: FAIL — no `SearchIndexRequest` is created (no trigger yet).

- [ ] **Step 3: Add the reindex trigger**

Replace the contents of `app/models/books/book_author.rb` class body so it reads:

```ruby
class Books::BookAuthor < ApplicationRecord
  enum :role, {author: 0, editor: 1}

  belongs_to :book, class_name: "Books::Book"
  belongs_to :author, class_name: "Books::Author"

  validates :book_id, uniqueness: {scope: :author_id}

  after_commit :queue_book_for_reindexing

  private

  def queue_book_for_reindexing
    SearchIndexRequest.create!(parent_type: "Books::Book", parent_id: book_id, action: :index_item)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/books/book_author_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/models/books/book_author.rb test/models/books/book_author_test.rb
git add app/models/books/book_author.rb test/models/books/book_author_test.rb
git commit -m "Reindex book when its authorship links change"
```

---

### Task 8: `Books::Author` name-change cascade

**Files:**
- Modify: `app/models/books/author.rb` (add `after_commit` cascade)
- Test: `test/models/books/author_test.rb`

**Interfaces:**
- Consumes: `SearchIndexRequest`, `Books::Author#books`.
- Produces: when a `Books::Author`'s `name` changes, every one of its books is enqueued for reindex (`parent_type: "Books::Book"`, `action: :index_item`), so embedded `author_names` stay current. A non-name change does not trigger the cascade.

- [ ] **Step 1: Write the failing test**

In `test/models/books/author_test.rb`, add inside the test class:

```ruby
  # Search freshness: renaming an author reindexes their books
  test "renaming an author enqueues its books for reindexing" do
    author = books_authors(:tolstoy)
    book = books_books(:war_and_peace) # linked via war_and_peace_tolstoy fixture

    assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
      author.update!(name: "Lev Tolstoy")
    end
  end

  test "a non-name author change does not enqueue its books for reindexing" do
    author = books_authors(:tolstoy)
    book = books_books(:war_and_peace)

    assert_no_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count } do
      author.update!(birth_year: 1829)
    end
  end
```

Note: the author itself still enqueues its own `Books::Author` reindex request via `SearchIndexable` on every update — these assertions scope to `parent_type: "Books::Book"` so they measure only the cascade.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: FAIL — the rename test finds 0 `Books::Book` requests (no cascade yet).

- [ ] **Step 3: Add the cascade**

In `app/models/books/author.rb`, add the callback registration directly below `include SearchIndexable` (added in Task 6):

```ruby
  after_commit :queue_books_for_reindexing, if: :saved_change_to_name?
```

Then add the private method (inside the existing `private` section, alongside `normalize_name`):

```ruby
  def queue_books_for_reindexing
    book_ids.each do |book_id|
      SearchIndexRequest.create!(parent_type: "Books::Book", parent_id: book_id, action: :index_item)
    end
  end
```

Note: `book_ids` is the association reader for `has_many :books` — it returns the linked book IDs with a single query and no model instantiation.

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop -a app/models/books/author.rb test/models/books/author_test.rb
git add app/models/books/author.rb test/models/books/author_test.rb
git commit -m "Reindex an author's books when the author is renamed"
```

---

### Task 9: Rake tasks (`search:books:*`)

**Files:**
- Modify: `lib/tasks/search.rake` (add a `search:books` namespace)

**Interfaces:**
- Consumes: `Search::Books::BookIndex.reindex_all`, `Search::Books::AuthorIndex.reindex_all`.
- Produces: `search:books:recreate_and_reindex_all`, `search:books:recreate_books`, `search:books:recreate_authors`.

- [ ] **Step 1: Add the books namespace**

In `lib/tasks/search.rake`, add a new `namespace :books do ... end` block inside the top-level `namespace :search do`, after the `namespace :games` block (before the final `end` that closes `namespace :search`):

```ruby
  namespace :books do
    desc "Recreate and reindex all books indices (Books, Authors)"
    task recreate_and_reindex_all: :environment do
      puts "=" * 80
      puts "Search Books Indices - Recreation and Reindexing"
      puts "=" * 80
      puts "\nThis will delete existing indices and recreate them with updated mappings.\n\n"

      indices = [
        {klass: Search::Books::BookIndex, name: "Books", model: Books::Book},
        {klass: Search::Books::AuthorIndex, name: "Authors", model: Books::Author}
      ]

      indices.each do |index_info|
        record_count = index_info[:model].count
        puts "[#{index_info[:name]}] Starting recreation and reindex (#{record_count} records to index)..."

        index_info[:klass].reindex_all

        puts "[#{index_info[:name]}] ✓ Complete!"
      end

      puts "\n" + "=" * 80
      puts "All books indices recreated and reindexed successfully!"
      puts "=" * 80
    end

    desc "Recreate Books index"
    task recreate_books: :environment do
      record_count = Books::Book.count
      puts "Recreating Books index (#{record_count} records)..."
      Search::Books::BookIndex.reindex_all
      puts "✓ Books index recreated and reindexed"
    end

    desc "Recreate Authors index"
    task recreate_authors: :environment do
      record_count = Books::Author.count
      puts "Recreating Authors index (#{record_count} records)..."
      Search::Books::AuthorIndex.reindex_all
      puts "✓ Authors index recreated and reindexed"
    end
  end
```

- [ ] **Step 2: Verify the tasks are registered**

Run: `bin/rails -T search:books`
Expected: lists `search:books:recreate_and_reindex_all`, `search:books:recreate_books`, `search:books:recreate_authors`.

- [ ] **Step 3: Verify a task runs end-to-end (requires OpenSearch)**

Run: `bin/rails search:books:recreate_and_reindex_all`
Expected: prints the banner and `✓ Complete!` for Books and Authors with no errors. (In dev this indexes whatever books/authors exist — zero is fine.)

- [ ] **Step 4: Lint and commit**

```bash
bin/rubocop -a lib/tasks/search.rake
git add lib/tasks/search.rake
git commit -m "Add search:books rake tasks"
```

---

### Task 10: Documentation

**Files:**
- Modify: `docs/features/search.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the search feature doc**

In `docs/features/search.md`, make these edits:

1. In the **Overview** (line ~5), change "for music (artists, albums, songs) and games." to "for music (artists, albums, songs), games, and books (books, authors)."

2. In the **File Structure** block, add a `books/` subtree under the `music/` and `games/` entries:

```
  books/
    book_index.rb
    author_index.rb
    search/
      book_general.rb
      author_general.rb
      book_autocomplete.rb
```

3. In **§1 SearchIndexable Concern** ("Currently included in:"), append `, Books::Book, Books::Author`.

4. In **§5 Document Shape**, add:

```
**Books::Book**:
{ title:, subtitle:, alternate_titles:, author_names:, author_ids:, category_ids:, book_kind: }

**Books::Author**:
{ name:, alternate_names:, category_ids: }
```

5. Add a new subsection after §3 (Category Change Reindexing) titled **"Author/authorship change reindexing"** describing the two triggers:

```
### Author & authorship change reindexing

Book documents embed author_names/author_ids. Two after_commit triggers keep them fresh
(dedup in Search::IndexerJob makes redundant enqueues harmless):

- Books::BookAuthor (create/update/destroy) enqueues its book for reindex — covers adding,
  removing, reordering, and reassigning authorship.
- Books::Author, when its `name` changes, enqueues all of the author's books for reindex.

Author alternate_names are not embedded in book documents, so only name changes cascade.
```

6. In **§ IndexerJob**, update the processed-types list to include `Books::Book`, `Books::Author`.

7. In **Rake Tasks**, add rows: `search:books:recreate_and_reindex_all`, `search:books:recreate_books`, `search:books:recreate_authors`.

- [ ] **Step 2: Commit**

```bash
git add docs/features/search.md
git commit -m "Document books & authors search indexing"
```

---

## Final Verification

- [ ] **Run the full books search suite (requires OpenSearch):**

Run: `bin/rails test test/lib/search/books/ test/models/books/book_test.rb test/models/books/author_test.rb test/models/books/book_author_test.rb test/sidekiq/search/indexer_job_test.rb`
Expected: all green.

- [ ] **Run the full test suite + linters (what CI runs):**

Run: `bin/rails db:test:prepare test && bin/rubocop -f github && bin/brakeman --no-pager`
Expected: all green.

- [ ] **Sanity-check indexing end-to-end in dev (optional, requires dev OpenSearch + Sidekiq):**

In `bin/rails console`: create a `Books::Book`, wait ~30s for the `Search::IndexerJob` cron (or run `Search::Books::BookIndex.reindex_all`), then confirm `Search::Books::Search::BookGeneral.call("<title>")` returns it and `Search::Books::Search::BookGeneral.call` never returns a `collection` book.

---

## Self-Review (completed by plan author)

- **Spec coverage:** §3 pipeline → Tasks 6/7/8; §4 document shape → Task 1 (book) + unchanged author; §5 index definitions → Tasks 1-2; §6 query classes → Tasks 3-5; §7 rake tasks → Task 9; §8 tests → each task's tests + Final Verification; §9 docs → Task 10; §10 file inventory → all tasks. §2 out-of-scope items (no page/controller/ListableAutocomplete/Series) are correctly absent.
- **Placeholder scan:** none — every step has concrete code or an exact command.
- **Type consistency:** `Search::Books::BookIndex` / `AuthorIndex` and `Search::Books::Search::{BookGeneral,AuthorGeneral,BookAutocomplete}` names, `.call(text, options = {})` signatures, and the `book_kind: "standalone"` filter value are used identically across index, query, and test tasks.
