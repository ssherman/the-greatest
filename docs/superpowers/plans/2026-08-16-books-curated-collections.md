# Books Curated Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the legacy site's curated "Lists" nav menu — six filtered collection pages on their legacy URLs, plus the menu itself.

**Architecture:** A collection is one more *narrowing* alongside genre and year, not a new subsystem. A domain-neutral registry (`Collections::Registry`) holds value objects whose `filter` field is an **opaque hash only the owning domain's query object reads**. Books registers six; `Books::RankedItemsController#index` serves them through the existing view, query, path builder, and title builder. No new controller, no new view.

**Tech Stack:** Rails 8.1, Ruby 4.0.6, Minitest + Mocha + fixtures, ViewComponent, daisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/specs/books-curated-collections.md`

## Global Constraints

- Run all commands from `web-app/`. Worktree: `.claude/worktrees/books-collections`, branch `worktree-books-collections`.
- Lint is `bundle exec standardrb` (NOT `bin/rubocop`). Never run brakeman.
- Rails 8 enum syntax: `enum :gender, {male: 0}` — colon prefix, never `enum gender: {...}`.
- Namespace all books code under `Books::`; tests mirror the namespace (`module Books; class FooTest`).
- Business logic goes in `app/lib/`, NOT `app/services/`. Services use `Result = Struct.new(..., keyword_init: true)`.
- **Name the books registry `Books::CollectionsRegistry`, never `Books::Collections`** — a nested `Collections` inside `Books::` shadows the shared top-level `::Collections`. Root-anchor `::Books::` from inside `Collections::`.
- daisyUI 5: never use `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is to remove the class, never to add an allowlist entry.
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. Never run `db:drop`/`db:reset`/`db:schema:load`/`create_fixtures` against development.
- **`the_greatest_test` is shared with the main checkout.** Task 1 adds a column to `books_authors`; if anything runs from the main checkout mid-run the column vanishes. Confirm no other session is running tests before starting.
- Commit after every task. Do not push or open a PR without asking.

---

### Task 1: Author gender column

Legacy `authors.gender` was never migrated. This is the only hard blocker for `/women`.

**Files:**
- Create: `db/migrate/<timestamp>_add_gender_to_books_authors.rb` (via generator)
- Modify: `app/models/books/author.rb`
- Modify: `app/lib/services/books_migration/author_transformer.rb`
- Test: `test/models/books/author_test.rb`, `test/lib/services/books_migration/author_transformer_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::Author#gender` enum with values `male: 0, female: 1, non_binary: 2, unspecified: 3`; scope `Books::Author.where(gender: :female)`. Task 3 depends on these exact ordinals.

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration AddGenderToBooksAuthors gender:integer:index
```

Open the generated file and confirm it reads exactly:

```ruby
class AddGenderToBooksAuthors < ActiveRecord::Migration[8.1]
  def change
    add_column :books_authors, :gender, :integer
    add_index :books_authors, :gender
  end
end
```

The books tables are empty in production (books data lives only in development), so a plain
`add_index` is safe — no `algorithm: :concurrently` needed.

- [ ] **Step 2: Write the failing tests**

Append to `test/models/books/author_test.rb`, inside the existing `module Books` / class body:

```ruby
test "gender enum ordinals match the legacy authors.gender enum" do
  assert_equal({"male" => 0, "female" => 1, "non_binary" => 2, "unspecified" => 3},
    Books::Author.genders)
end

test "gender is optional" do
  author = Books::Author.new(name: "Anon")
  assert author.valid?
  assert_nil author.gender
end

test "authors can be scoped by gender" do
  garnett = books_authors(:garnett)
  garnett.update!(gender: :female)

  assert_includes Books::Author.where(gender: :female), garnett
end
```

Append to `test/lib/services/books_migration/author_transformer_test.rb`, inside the class body:

```ruby
test "carries gender straight across as the raw legacy integer" do
  attrs = Services::BooksMigration::AuthorTransformer.call(
    {"id" => 7, "name" => "Virginia Woolf", "gender" => 1}
  )
  assert_equal 1, attrs[:gender]
end

test "a null legacy gender stays nil" do
  attrs = Services::BooksMigration::AuthorTransformer.call(
    {"id" => 8, "name" => "Anon", "gender" => nil}
  )
  assert_nil attrs[:gender]
end
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bin/rails db:test:prepare
bin/rails test test/models/books/author_test.rb test/lib/services/books_migration/author_transformer_test.rb
```

Expected: FAIL. The enum test raises `NoMethodError: undefined method 'genders'`; the transformer tests fail with `nil` not matching `1`.

- [ ] **Step 4: Run the migration and add the enum**

```bash
bin/rails db:migrate
```

In `app/models/books/author.rb`, add alongside the existing associations/validations:

```ruby
enum :gender, {male: 0, female: 1, non_binary: 2, unspecified: 3}
```

- [ ] **Step 5: Carry gender in the transformer**

In `app/lib/services/books_migration/author_transformer.rb`, add one key to the returned hash:

Add exactly one line — `gender: attrs["gender"],` — after the `description:` line. Change nothing else. The result:

```ruby
{
  name: attrs["name"],
  sort_name: attrs["family_name"].presence || attrs["name"],
  birth_year: attrs["birth_year"],
  death_year: attrs["death_year"],
  description: attrs["description"],
  gender: attrs["gender"],
  alternate_names: Array(attrs["alternative_names"])
}
```

Note the legacy key is `alternative_names` (with the "iv") while the new attribute is `alternate_names`. That mismatch is pre-existing and correct — do not "fix" it.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/models/books/author_test.rb test/lib/services/books_migration/author_transformer_test.rb
```

Expected: PASS.

- [ ] **Step 7: Backfill the development database**

This is dev convenience only — the production path is the transformer line, because cutover truncates and re-runs `data_migration:all` from scratch. Snapshot first; the books dev data cannot be rebuilt quickly.

```bash
bin/snapshot-dev-db.sh --label pre-author-gender
bin/rails data_migration:authors
```

Then verify:

```bash
bin/rails runner 'puts Books::Author.group(:gender).count.inspect'
```

Expected: roughly `{nil => 3797, "male" => 36437, "female" => 17532, "non_binary" => 143, "unspecified" => 284}`. If female is 0, the transformer change did not take effect.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb
git add app/models/books/author.rb app/lib/services/books_migration/author_transformer.rb db/migrate db/schema.rb test/models/books/author_test.rb test/lib/services/books_migration/author_transformer_test.rb
git commit -m "feat(books): migrate author gender from the legacy database"
```

---

### Task 2: Domain-neutral collection registry

**Files:**
- Create: `app/lib/collections/collection.rb`
- Create: `app/lib/collections/registry.rb`
- Create: `app/lib/books/collections_registry.rb`
- Test: `test/lib/collections/registry_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Collections::Collection` — `Struct.new(:domain, :slug, :name, :title_prefix, :title_suffix, :filter, keyword_init: true)`
  - `Collections::Registry.for(:books)` → `Array<Collections::Collection>`
  - `Collections::Registry.find(:books, "africa")` → `Collections::Collection` or `nil`
  - `Collections::Registry.slugs(:books)` → `["women", "africa", "asia", "latin-america", "western", "non-western"]`
  - `Books::CollectionsRegistry.all` → the six entries
  - Tasks 3–6 depend on these exact names.

- [ ] **Step 1: Write the failing test**

Create `test/lib/collections/registry_test.rb`:

```ruby
require "test_helper"

module Collections
  class RegistryTest < ActiveSupport::TestCase
    test "books registers the six curated collections" do
      assert_equal %w[women africa asia latin-america western non-western],
        Collections::Registry.slugs(:books)
    end

    test "find returns the collection for a known slug" do
      collection = Collections::Registry.find(:books, "africa")

      assert_equal "africa", collection.slug
      assert_equal :books, collection.domain
      assert_equal "African", collection.title_prefix
      assert_equal({country_label: "african"}, collection.filter)
    end

    test "find returns nil for an unknown slug" do
      assert_nil Collections::Registry.find(:books, "antarctica")
    end

    test "find returns nil for a domain with no collections" do
      assert_nil Collections::Registry.find(:music, "africa")
      assert_equal [], Collections::Registry.for(:music)
    end

    test "non-western negates the western label rather than naming its own" do
      collection = Collections::Registry.find(:books, "non-western")

      assert_equal({country_label: "western", exclude: true}, collection.filter)
    end

    test "women filters on author gender and reads as a title suffix" do
      collection = Collections::Registry.find(:books, "women")

      assert_nil collection.title_prefix
      assert_equal "Written by Women", collection.title_suffix
      assert_equal({author_gender: :female}, collection.filter)
    end

    test "every collection has a nav name" do
      Collections::Registry.for(:books).each do |collection|
        assert collection.name.present?, "#{collection.slug} has no nav name"
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/collections/registry_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Collections`.

- [ ] **Step 3: Create the value object**

Create `app/lib/collections/collection.rb`:

```ruby
module Collections
  # One curated collection of ranked items. Domain-neutral on purpose: `filter`
  # is an opaque payload that ONLY the owning domain's query object reads, which
  # is what lets a second domain register collections with a completely
  # different filter vocabulary and no change to this file.
  #
  # title_prefix lands directly after "The Greatest"; title_suffix lands last.
  # Both are optional and a collection normally sets exactly one.
  Collection = Struct.new(
    :domain, :slug, :name, :title_prefix, :title_suffix, :filter,
    keyword_init: true
  )
end
```

- [ ] **Step 4: Create the registry**

Create `app/lib/collections/registry.rb`:

```ruby
module Collections
  # Looks up a domain's collections. Providers are resolved by convention --
  # `Books::CollectionsRegistry` -- so registering a domain is one new file and
  # no edit here. Root-anchored constant lookup (`::Books`) is deliberate: a
  # bare `Books::` inside `Collections::` would resolve to a nested module.
  class Registry
    PROVIDERS = {books: "::Books::CollectionsRegistry"}.freeze

    def self.for(domain)
      provider = PROVIDERS[domain.to_sym]
      return [] if provider.nil?

      provider.constantize.all
    end

    def self.find(domain, slug)
      self.for(domain).find { |collection| collection.slug == slug.to_s }
    end

    def self.slugs(domain)
      self.for(domain).map(&:slug)
    end
  end
end
```

- [ ] **Step 5: Register the six books collections**

Create `app/lib/books/collections_registry.rb`:

```ruby
module Books
  # The six curated collections migrated from the legacy site's Lists nav menu.
  # NOT named Books::Collections -- that would shadow the shared ::Collections
  # module for every constant lookup inside this namespace.
  #
  # `filter` shapes are read only by Books::RankedBooksQuery.
  class CollectionsRegistry
    def self.all
      @all ||= [
        build("women", "Greatest Books Written by Women",
          title_suffix: "Written by Women", filter: {author_gender: :female}),
        build("africa", "Greatest African Books",
          title_prefix: "African", filter: {country_label: "african"}),
        build("asia", "Greatest Asian Books",
          title_prefix: "Asian", filter: {country_label: "asian"}),
        build("latin-america", "Greatest Latin American Books",
          title_prefix: "Latin American", filter: {country_label: "latin_american"}),
        build("western", "Greatest Western Canon Books",
          title_prefix: "Western", filter: {country_label: "western"}),
        build("non-western", "Greatest Non-Western Canon Books",
          title_prefix: "Non-Western", filter: {country_label: "western", exclude: true})
      ].freeze
    end

    def self.build(slug, name, filter:, title_prefix: nil, title_suffix: nil)
      ::Collections::Collection.new(
        domain: :books, slug: slug, name: name,
        title_prefix: title_prefix, title_suffix: title_suffix, filter: filter
      )
    end
    private_class_method :build
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bin/rails test test/lib/collections/registry_test.rb
```

Expected: PASS, 7 assertions-bearing tests.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add app/lib/collections app/lib/books/collections_registry.rb test/lib/collections
git commit -m "feat(collections): domain-neutral curated collection registry"
```

---

### Task 3: Thread the collection through query, path, title, and facets

**Files:**
- Modify: `app/lib/books/ranked_books_query.rb`
- Modify: `app/lib/books/filter_path.rb`
- Modify: `app/lib/books/filter_title.rb`
- Modify: `app/lib/books/filter_facets_query.rb`
- Test: `test/lib/books/ranked_books_query_test.rb`, `test/lib/books/filter_path_test.rb`, `test/lib/books/filter_title_test.rb`, `test/lib/books/filter_facets_query_test.rb`

**Interfaces:**
- Consumes: `Collections::Registry.find(:books, slug)` from Task 2.
- Produces:
  - `Books::RankedBooksQuery.call(ranking_configuration:, categories:, countries:, year_start:, year_end:, collection: nil)`
  - `Books::FilterPath.call(categories:, countries:, year_start:, year_end:, page:, ranking_configuration:, collection: nil)`
  - `Books::FilterTitle.call(categories:, countries:, year_start:, year_end:, collection: nil)`
  - `Books::FilterFacetsQuery.genres(ranking_configuration:, ..., collection: nil)`
  - Tasks 4 and 5 call all four with `collection:`.

- [ ] **Step 1: Write the failing query tests**

Append to `test/lib/books/ranked_books_query_test.rb`, inside `module Books` / the class body:

```ruby
def collection(slug) = ::Collections::Registry.find(:books, slug)

test "a country-label collection keeps only books from labelled countries" do
  # war_and_peace -> french (western); of_mice_and_men -> japanese (asian)
  RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)

  results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("western"))

  assert_includes results.map(&:item_id), books_books(:war_and_peace).id
  refute_includes results.map(&:item_id), books_books(:of_mice_and_men).id
end

test "a negated country-label collection keeps only books outside the label" do
  RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)

  results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("non-western"))

  assert_includes results.map(&:item_id), books_books(:of_mice_and_men).id
  refute_includes results.map(&:item_id), books_books(:war_and_peace).id
end

test "an author-gender collection keeps books with any author of that gender" do
  books_authors(:garnett).update!(gender: :female)
  Books::BookAuthor.create!(book: books_books(:crime_and_punishment),
    author: books_authors(:garnett), position: 2, role: 0)

  results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("women"))

  assert_equal [books_books(:crime_and_punishment).id], results.map(&:item_id)
end

test "a collection composes with a year bound" do
  results = Books::RankedBooksQuery.call(
    ranking_configuration: @rc, collection: collection("western"), year_start: 3000
  )

  assert_empty results
end

test "a nil collection narrows nothing" do
  assert_equal 2, Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: nil).count
end
```

- [ ] **Step 2: Write the failing path and title tests**

Append to `test/lib/books/filter_path_test.rb`, inside `module Books` / the class body:

```ruby
def collection(slug) = ::Collections::Registry.find(:books, slug)

test "an unfiltered collection is its bare slug" do
  assert_equal "/africa", Books::FilterPath.call(collection: collection("africa"))
end

test "an unfiltered collection with a page" do
  assert_equal "/africa/page/3", Books::FilterPath.call(collection: collection("africa"), page: 3)
end

test "a collection with a category" do
  path = Books::FilterPath.call(collection: collection("africa"), categories: [category("fiction")])

  assert_equal "/africa/the-greatest/fiction/books", path
end

test "a collection with a date but no category keeps the the-greatest-books base" do
  path = Books::FilterPath.call(collection: collection("africa"), year_start: "2000")

  assert_equal "/africa/the-greatest-books/since/2000", path
end

test "a collection composes category, date, and page" do
  path = Books::FilterPath.call(
    collection: collection("africa"), categories: [category("fiction")],
    year_start: "2000", year_end: "2010", page: 2
  )

  assert_equal "/africa/the-greatest/fiction/books/from/2000/to/2010/page/2", path
end
```

Append to `test/lib/books/filter_title_test.rb`, inside `module Books` / the class body:

```ruby
def collection(slug) = ::Collections::Registry.find(:books, slug)

test "a title_prefix collection lands right after The Greatest" do
  assert_equal "The Greatest African Books of All Time",
    Books::FilterTitle.call(collection: collection("africa"))
end

test "a title_suffix collection lands last" do
  assert_equal "The Greatest Books of All Time Written by Women",
    Books::FilterTitle.call(collection: collection("women"))
end

test "a collection composes with genre and date" do
  assert_equal "The Greatest African Fiction Books Since 2000",
    Books::FilterTitle.call(
      collection: collection("africa"),
      categories: [Books::Category.new(slug: "fiction", name: "Fiction", category_type: :genre)],
      year_start: "2000"
    )
end
```

- [ ] **Step 3: Write the failing facets test**

Append to `test/lib/books/filter_facets_query_test.rb`, inside `module Books` / the class body:

```ruby
test "genre facet counts are narrowed by the collection" do
  collection = ::Collections::Registry.find(:books, "western")

  scoped = Books::FilterFacetsQuery.genres(ranking_configuration: @rc, collection: collection)
  unscoped = Books::FilterFacetsQuery.genres(ranking_configuration: @rc)

  scoped_total = scoped.sum { |row| row[:count] }
  unscoped_total = unscoped.sum { |row| row[:count] }

  assert_operator scoped_total, :>, 0, "western should still count some genres"
  assert_operator scoped_total, :<, unscoped_total
end
```

The existing `setup` in that file ranks `war_and_peace` and `got` (both `french`, western) plus
`crime_and_punishment` (no country). So the western collection drops exactly one ranked book —
which is what makes both assertions meaningful rather than trivially true.

- [ ] **Step 4: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/ranked_books_query_test.rb test/lib/books/filter_path_test.rb test/lib/books/filter_title_test.rb test/lib/books/filter_facets_query_test.rb
```

Expected: FAIL with `ArgumentError: unknown keyword: :collection` on all four.

- [ ] **Step 5: Add collection narrowing to the query**

In `app/lib/books/ranked_books_query.rb`, add the keyword and apply it after the country filter and before `with_year_bounds`:

```ruby
def self.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil)
  # ... existing ranking_configuration / categories / countries clauses unchanged ...

  relation = with_collection(relation, collection)
  relation = with_year_bounds(relation, year_start, year_end)

  relation
    .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
    .order(:rank)
end

# A collection's `filter` is opaque to the shared registry -- this is the only
# place in the app that knows what its keys mean.
def self.with_collection(relation, collection)
  filter = collection&.filter
  return relation if filter.nil?

  if filter[:author_gender]
    relation.where(item_id: Books::BookAuthor
      .where(author_id: Books::Author.where(gender: filter[:author_gender]).select(:id))
      .select(:book_id))
  else
    countries = if filter[:exclude]
      Books::Country.without_label(filter[:country_label])
    else
      Books::Country.with_label(filter[:country_label])
    end
    relation.where(item_id: Books::BookCountry.where(country_id: countries.select(:id)).select(:book_id))
  end
end
private_class_method :with_collection
```

- [ ] **Step 6: Add the collection prefix to FilterPath**

In `app/lib/books/filter_path.rb`, accept `collection:` in `initialize`, store it, and thread it into two methods:

```ruby
def initialize(categories: [], countries: [], year_start: nil, year_end: nil, page: nil, ranking_configuration: nil, collection: nil)
  # ... existing assignments ...
  @collection = collection
end

def collection_segment
  @collection ? "/#{@collection.slug}" : ""
end

def unfiltered_path
  base = "#{prefix}#{collection_segment}"
  return "#{base}/page/#{@page}" if @page > 1

  base.presence || "/"
end
```

and in `call`, insert the collection segment between the prefix and the base:

```ruby
def call
  return unfiltered_path if @categories.empty? && @countries.empty? && @year_start.nil? && @year_end.nil?

  "#{prefix}#{collection_segment}#{base_segment}#{country_segment}#{date_segment}#{page_segment}"
end
```

`base_segment`, `country_segment`, `date_segment`, and `page_segment` are unchanged.

- [ ] **Step 7: Add prefix and suffix to FilterTitle**

In `app/lib/books/filter_title.rb`, accept `collection:` and use it in `call`:

```ruby
def initialize(categories: [], countries: [], year_start: nil, year_end: nil, collection: nil)
  # ... existing assignments ...
  @collection = collection
end

def call
  parts = ["The Greatest"]
  parts << @collection.title_prefix if @collection&.title_prefix
  parts << @countries.map { |country| country.name.titlecase }.join(", ") if @countries.any?
  parts.concat(genre_parts)
  parts << date_phrase
  parts << "on #{format_list(names_for(:subject))}" if names_for(:subject).any?
  parts << "Set in #{format_list(names_for(:location))}" if names_for(:location).any?
  parts << @collection.title_suffix if @collection&.title_suffix
  parts.join(" ")
end
```

- [ ] **Step 8: Pass the collection through the facets query**

In `app/lib/books/filter_facets_query.rb`, add `collection: nil` to `call`, `genres`, `countries`, and `build`; store it in `initialize`; and pass it in `book_ids`:

```ruby
def book_ids(countries:, categories:)
  RankedBooksQuery.call(
    ranking_configuration: @ranking_configuration,
    categories: categories,
    countries: countries,
    year_start: @year_start,
    year_end: @year_end,
    collection: @collection
  ).except(:includes).reorder(nil).reselect(:item_id)
end
```

- [ ] **Step 9: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/
```

Expected: PASS, all files green.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb
git add app/lib/books test/lib/books
git commit -m "feat(books): thread collections through query, path, title, and facets"
```

---

### Task 4: Routes, controller, and the rendered page

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/books/ranked_items_controller.rb`
- Modify: `app/views/books/ranked_items/index.html.erb`
- Test: `test/controllers/books/collections_controller_test.rb` (new), `test/routing/books_collections_routes_test.rb` (new)

**Interfaces:**
- Consumes: everything from Tasks 2 and 3.
- Produces: `params[:collection]` on every collection route; `@collection` in the view.

- [ ] **Step 1: Write the failing routing test**

Create `test/routing/books_collections_routes_test.rb`:

```ruby
require "test_helper"

module Books
  class CollectionsRoutesTest < ActionDispatch::IntegrationTest
    setup { host! "dev-new.thegreatestbooks.org" }

    test "every registered collection has a route" do
      Collections::Registry.slugs(:books).each do |slug|
        assert_recognizes({controller: "books/ranked_items", action: "index", collection: slug},
          "/#{slug}")
      end
    end

    test "a bare collection routes to the ranked index" do
      assert_routing "/africa",
        controller: "books/ranked_items", action: "index", collection: "africa"
    end

    test "a collection with a category and a date range routes" do
      assert_routing "/africa/the-greatest/fiction/books/from/1900/to/2000",
        controller: "books/ranked_items", action: "index", collection: "africa",
        category_id: "fiction", published_start: "1900", published_end: "2000"
    end

    test "the full legacy grammar with a category, a date, and a page routes" do
      assert_routing "/africa/the-greatest/fiction/books/since/2000/page/2",
        controller: "books/ranked_items", action: "index", collection: "africa",
        category_id: "fiction", published_start: "2000", page: "2"
    end

    test "an unknown collection slug does not route" do
      assert_raises(ActionController::RoutingError) do
        get "/antarctica"
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing controller test**

Create `test/controllers/books/collections_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class CollectionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 2, score: 90)
    end

    test "every registered collection renders" do
      Collections::Registry.slugs(:books).each do |slug|
        get "/#{slug}"
        assert_response :success, "/#{slug} did not render"
      end
    end

    test "western shows only books from western countries" do
      get "/western"

      ids = @controller.view_assigns["ranked_books"].map(&:item_id)
      assert_includes ids, books_books(:war_and_peace).id
      refute_includes ids, books_books(:of_mice_and_men).id
    end

    test "africa shows books from african countries" do
      books_countries(:algerian).update!(labels: ["african"])
      Books::BookCountry.create!(book: books_books(:of_mice_and_men), country: books_countries(:algerian))

      get "/africa"

      assert_equal [books_books(:of_mice_and_men).id],
        @controller.view_assigns["ranked_books"].map(&:item_id)
    end

    test "women shows books with any female author" do
      books_authors(:garnett).update!(gender: :female)
      Books::BookAuthor.create!(book: books_books(:war_and_peace),
        author: books_authors(:garnett), position: 2, role: 0)

      get "/women"

      assert_equal [books_books(:war_and_peace).id],
        @controller.view_assigns["ranked_books"].map(&:item_id)
    end

    test "the page title uses the collection prefix" do
      get "/africa"
      assert_equal "The Greatest African Books of All Time", @controller.view_assigns["page_title"]
    end

    test "the canonical path is the bare collection" do
      get "/africa"
      assert_equal "/africa", @controller.view_assigns["canonical_path"]
    end

    test "the site hero is suppressed on a collection page" do
      get "/africa"
      refute @controller.view_assigns["show_hero"]
    end

    test "an rc-prefixed collection gets no canonical" do
      get "/rc/#{@rc.id}/africa"
      assert_response :success
      assert_nil @controller.view_assigns["canonical_path"]
    end

    test "a collection paginates on a path" do
      # 100 per page, so page 2 needs more than 100 ranked western books.
      120.times do |i|
        book = Books::Book.create!(title: "Western Filler #{i}", first_published_year: 1950)
        Books::BookCountry.create!(book: book, country: books_countries(:french))
        RankedItem.create!(item: book, ranking_configuration: @rc, rank: 100 + i, score: 10)
      end

      get "/western/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "a page past the last raises not found" do
      get "/western/page/99"
      assert_response :not_found
    end

    test "the-greatest-books under a collection redirects to the bare slug" do
      get "/africa/the-greatest-books"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "the legacy the-greatest/books form redirects to the bare slug" do
      get "/africa/the-greatest/books"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "a legacy view-type url redirects to the bare slug" do
      get "/v/grid/africa"
      assert_redirected_to "/africa"
      assert_response :moved_permanently
    end

    test "a collection index does not N+1 over its books" do
      assert_queries_count(12) { get "/western" }
    end

    test "collection pages have no turbo-frame trapped links" do
      get "/africa"
      assert_no_frame_trapped_links
    end
  end
end
```

`assert_queries_count(12)` is a placeholder bound — run the test, read the actual count from
the failure message, and set it to that number. If it scales with the number of books
rendered, there is a real N+1: add the missing preload to `RankedBooksQuery` before pinning.

- [ ] **Step 3: Run both tests to verify they fail**

```bash
bin/rails test test/routing/books_collections_routes_test.rb test/controllers/books/collections_controller_test.rb
```

Expected: FAIL — routing errors on every collection path.

- [ ] **Step 4: Draw the routes**

In `config/routes.rb`, inside the books `DomainConstraint` block, immediately **after** the existing `filter_bases` / `filter_dates` loop, append:

```ruby
    # Curated collections (the legacy Lists nav menu). One constrained
    # :collection segment rather than six copies of the grammar. The regex union
    # is LOAD-BEARING: an unconstrained :collection would match any single
    # segment and mint an unbounded space of indexable soft-duplicates.
    # Read straight from the registry -- no duplicated literal, so drift is
    # impossible. Autoloading from routes.rb is already proven safe in this app:
    # DomainConstraint lives in app/lib and is referenced at the top of this file.
    collection_re = Regexp.union(Collections::Registry.slugs(:books))
    collection_bases = ["the-greatest-books", "the-greatest/:category_id/books"]

    ["", "rc/:ranking_configuration_id/"].each do |rc_prefix|
      get "#{rc_prefix}:collection", to: "books/ranked_items#index",
        constraints: {collection: collection_re}
      get "#{rc_prefix}:collection/page/:page", to: "books/ranked_items#index",
        constraints: {collection: collection_re, page: /\d+/}

      collection_bases.each do |base|
        filter_dates.each do |date|
          # The bare the-greatest-books form is the canonical slug's duplicate.
          next if base == "the-greatest-books" && date == ""

          get "#{rc_prefix}:collection/#{base}#{date}", to: "books/ranked_items#index",
            constraints: {collection: collection_re}
          get "#{rc_prefix}:collection/#{base}#{date}/page/:page", to: "books/ranked_items#index",
            constraints: {collection: collection_re, page: /\d+/}
        end
      end
    end

    # Legacy duplicates of the canonical bare slug.
    get ":collection/the-greatest-books", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    get ":collection/the-greatest-books/page/:page", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re, page: /\d+/}
    get ":collection/the-greatest/books", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    get ":collection/the-greatest/books/page/:page", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re, page: /\d+/}
    get "v/:view_type/:collection", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
    get "v/:view_type/:collection/*rest", to: redirect("/%{collection}", status: 301),
      constraints: {collection: collection_re}
```

If `Collections::Registry` somehow cannot be reached when routes are drawn, boot fails loudly
and immediately — fall back to a literal `%w[women africa asia latin-america western
non-western]` in `routes.rb`. Do not paper over a boot error any other way.

- [ ] **Step 5: Resolve the collection in the controller**

In `app/controllers/books/ranked_items_controller.rb`, add a `before_action` and use it:

```ruby
before_action :find_collection

# ... in index, after the FilterParams call:
@show_hero = !@filtered && params[:page].blank? && params[:ranking_configuration_id].blank? && @collection.nil?

@page_title = Books::FilterTitle.call(
  categories: @categories, countries: @countries,
  year_start: @year_start, year_end: @year_end, collection: @collection
)

if params[:ranking_configuration_id].blank?
  @canonical_path = Books::FilterPath.call(
    categories: @categories, countries: @countries,
    year_start: @year_start, year_end: @year_end,
    page: params[:page], collection: @collection
  )
end

@pagy, @ranked_books = pagy_path(
  Books::RankedBooksQuery.call(
    ranking_configuration: @ranking_configuration,
    categories: @categories, countries: @countries,
    year_start: @year_start, year_end: @year_end, collection: @collection
  ),
  limit: 100
)
```

and privately:

```ruby
private

# The route regex already restricts :collection to known slugs; this is the
# defensive half, and the only thing standing between a future loosened
# constraint and a 500.
def find_collection
  return if params[:collection].blank?

  @collection = Collections::Registry.find(:books, params[:collection])
  raise ActiveRecord::RecordNotFound if @collection.nil?
end
```

Leave `app/views/books/ranked_items/index.html.erb` **untouched** in this task. It already renders `@page_title` and honours `@show_hero`, which is everything this task needs. The filter components gain their `collection:` keyword in Task 5, and passing it from the view before then would raise `ArgumentError`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/routing/books_collections_routes_test.rb test/controllers/books/collections_controller_test.rb
```

Expected: PASS. Fix the `assert_queries_count` bound to the real number as noted in Step 2.

- [ ] **Step 7: Run the full suite**

Confirm no other session is using `the_greatest_test`, then:

```bash
bin/rails db:test:prepare test
```

Expected: green. A single `:collection` segment sits alongside existing single-segment routes
(`/lists`, `/authors`, `/genres`, `/countries`, `/searches`); the regex constraint should keep
them apart, and this run is what proves it.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb
git add config/routes.rb app/controllers/books/ranked_items_controller.rb test/routing test/controllers/books/collections_controller_test.rb

git commit -m "feat(books): serve the six curated collection pages on their legacy urls"
```

---

### Task 5: Scope the filter surface to the collection

The filter bar must drop the Origin axis on a collection page (genre + year only), and Apply must return **into** the collection rather than to the unscoped list.

**Files:**
- Modify: `app/components/books/filter_bar_component.rb`
- Modify: `app/components/books/filter_modal_component.rb`
- Modify: `app/components/books/filter_modal_component.html.erb`
- Modify: `app/controllers/books/filters_controller.rb`
- Modify: `app/views/books/ranked_items/index.html.erb`
- Test: `test/components/books/filter_modal_component_test.rb`, `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Consumes: `Collections::Registry`, `Books::FilterPath`, `Books::FilterFacetsQuery` with `collection:`.
- Produces: `Books::FilterBarComponent.new(..., collection: nil)`, `Books::FilterModalComponent.new(..., collection: nil)`; `params[:collection]` accepted by `Books::FiltersController`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/books/filters_controller_test.rb`, inside the class body:

```ruby
test "apply redirects back into the collection" do
  get "/filters", params: {collection: "africa", category_slugs: ["fiction"]}

  assert_redirected_to "/africa/the-greatest/fiction/books"
  assert_response :see_other
end

test "apply with no filters returns to the bare collection" do
  get "/filters", params: {collection: "africa"}

  assert_redirected_to "/africa"
end

test "an unknown collection on apply is not found" do
  get "/filters", params: {collection: "antarctica"}

  assert_response :not_found
end

test "the category pane accepts a collection" do
  get "/filters/categories", params: {collection: "africa"}

  assert_response :success
end
```

Create or append to `test/components/books/filter_modal_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterModalComponentTest < ViewComponent::TestCase
    test "the origin axis is offered on the unscoped list" do
      render_inline(Books::FilterModalComponent.new)

      assert_selector "[data-level-target='country']"
    end

    test "the origin axis is dropped on a collection page" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_no_selector "[data-level-target='country']"
      assert_selector "[data-level-target='category']"
      assert_selector "[data-level-target='year']"
    end

    test "a collection page carries its slug through apply" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_selector "input[name='collection'][value='africa']", visible: :all
    end

    test "clear returns to the bare collection" do
      render_inline(Books::FilterModalComponent.new(
        collection: Collections::Registry.find(:books, "africa")
      ))

      assert_selector "a[href='/africa']", text: "Clear"
    end
  end
end
```

Capybara's `text:` is a substring match and whitespace is not normalized by default — after
these pass, break the implementation deliberately once and confirm each assertion actually
fails. Assertions in this file have silently passed against broken code before.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/filters_controller_test.rb test/components/books/filter_modal_component_test.rb
```

Expected: FAIL with `ArgumentError: unknown keyword: :collection`.

- [ ] **Step 3: Add collection to the filter bar**

In `app/components/books/filter_bar_component.rb`, accept and store `collection:`, add it to `attr_reader`, and pass it in `path_without`:

```ruby
def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil, collection: nil)
  # ... existing assignments ...
  @collection = collection
end

attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration, :collection

def path_without(categories: self.categories, countries: self.countries, year_start: self.year_start, year_end: self.year_end)
  Books::FilterPath.call(
    categories: categories, countries: countries,
    year_start: year_start, year_end: year_end,
    ranking_configuration: ranking_configuration, collection: collection
  )
end
```

- [ ] **Step 4: Drop the origin axis in the modal**

In `app/components/books/filter_modal_component.rb`, accept and store `collection:`, then replace direct `AXES` use with filtered readers:

```ruby
# Origin is the collection's own axis -- offering it would let a reader pick a
# country the collection cannot contain and land on an empty page. Legacy had no
# such URL either.
def axes
  collection ? AXES.reject { |row| row[:axis] == "country" } : AXES
end

def drill_axes
  axes.map { |row| row[:axis] } - ["year"]
end

def clear_path
  Books::FilterPath.call(ranking_configuration: ranking_configuration, collection: collection)
end

def filter_query
  {
    category_slugs: categories.map(&:slug),
    country_slugs: countries.map(&:slug),
    year_start: year_start,
    year_end: year_end,
    ranking_configuration_id: rc_param,
    collection: collection&.slug
  }.compact_blank.to_query
end
```

Add `collection` to the `attr_reader` line.

- [ ] **Step 5: Update the modal template**

In `app/components/books/filter_modal_component.html.erb`:

- line 15: `<% AXES.each do |row| %>` → `<% axes.each do |row| %>`
- line 36: `<% ["category", "country"].each do |axis| %>` → `<% drill_axes.each do |axis| %>`
- after the `rc_param` hidden field (line 8–10), add:

```erb
<% if collection %>
  <%= hidden_field_tag :collection, collection.slug %>
<% end %>
```

The two `AXES.find { |row| row[:axis] == axis }` lookups inside the drill-down loop stay as
they are — they look up labels in the full list, which is still correct.

- [ ] **Step 6: Accept the collection in FiltersController**

In `app/controllers/books/filters_controller.rb`, add a `before_action :find_collection` and thread it through:

```ruby
before_action :find_collection

def show
  filters = resolved_filters

  redirect_to Books::FilterPath.call(
    categories: filters.categories,
    countries: filters.countries,
    year_start: filters.year_start,
    year_end: filters.year_end,
    ranking_configuration: @ranking_configuration,
    collection: @collection
  ), status: :see_other
end

private

def find_collection
  return if params[:collection].blank?

  @collection = Collections::Registry.find(:books, params[:collection])
  raise ActiveRecord::RecordNotFound if @collection.nil?
end
```

and add `collection: @collection` to the hash returned by `facet_args`.

- [ ] **Step 7: Pass the collection from the view**

In `app/views/books/ranked_items/index.html.erb`, add `collection: @collection` to both component renders:

```erb
<%= render Books::FilterBarComponent.new(
      categories: @categories,
      countries: @countries,
      year_start: @year_start,
      year_end: @year_end,
      ranking_configuration: @ranking_configuration,
      collection: @collection
    ) %>
```

and the same keyword on the `Books::FilterModalComponent.new(...)` render at the bottom.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/books/filters_controller_test.rb test/components/books/filter_modal_component_test.rb test/controllers/books/collections_controller_test.rb
```

Expected: PASS.

- [ ] **Step 9: Verify the component assertions are not vacuous**

Temporarily change `axes` to return `AXES` unconditionally. Re-run the modal component test.
Expected: the "origin axis is dropped" test FAILS. Revert the change and confirm it passes again.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb
git add app/components/books app/controllers/books/filters_controller.rb app/views/books/ranked_items/index.html.erb test/components/books test/controllers/books/filters_controller_test.rb
git commit -m "feat(books): scope the filter surface to the active collection"
```

---

### Task 6: Nav menu and end-to-end coverage

**Files:**
- Create: `app/views/books/shared/_nav_links.html.erb`
- Modify: `app/views/layouts/books/application.html.erb:36-45` and `:52-59`
- Create: `e2e/tests/books/collections.spec.ts`
- Test: `test/lint/daisyui_v4_classes_test.rb` (existing guard, just run it)

**Interfaces:**
- Consumes: `Collections::Registry.for(:books)`.
- Produces: nothing downstream.

- [ ] **Step 1: Extract the nav links to a shared partial**

The nav `<li>` block is currently duplicated verbatim in the narrow-screen dropdown and the wide-screen bar. Create `app/views/books/shared/_nav_links.html.erb`:

```erb
<li><%= link_to "Books", books_root_path %></li>
<li>
  <details>
    <summary>Lists</summary>
    <ul class="bg-base-100 rounded-box z-[1] w-64 p-2 shadow">
      <li><%= link_to "All Lists", books_lists_path %></li>
      <li class="menu-title"><span class="sr-only">Curated collections</span></li>
      <li><%= link_to "The Greatest Books of the 21st Century", "/the-greatest-books/since/2000" %></li>
      <% Collections::Registry.for(:books).each do |collection| %>
        <li><%= link_to collection.name, "/#{collection.slug}" %></li>
      <% end %>
      <li><%= link_to "Our Users' Favorite Books of All Time", "/lists/463" %></li>
    </ul>
  </details>
</li>
<li><%= link_to "Authors", books_authors_path %></li>
<%# Revealed client-side by user_list_state_controller when signed in. %>
<li id="navbar_my_lists" class="hidden"><a href="/my/lists">My Lists</a></li>
<li id="navbar_my_searches" class="hidden"><a href="/searches">My Searches</a></li>
<li id="navbar_my_reviews" class="hidden"><a href="/my/reviews">My Reviews</a></li>
```

Registry order is women, africa, asia, latin-america, western, non-western — which differs from
the legacy menu's order. If you want legacy order exactly, list the six links explicitly here
instead of looping; the registry is the source of truth for *behaviour*, not for menu order.

`<summary>` does not navigate, which is why "All Lists" is the first item — matching legacy.

- [ ] **Step 2: Render the partial from both nav copies**

In `app/views/layouts/books/application.html.erb`, replace the six `<li>` lines inside the
narrow-screen `<ul class="menu menu-sm dropdown-content ...">` with:

```erb
<%= render "books/shared/nav_links" %>
```

and do the same for the six `<li>` lines inside `<ul class="menu menu-horizontal px-1">`.

Note both copies carry duplicate `id="navbar_my_lists"` / `navbar_my_searches` /
`navbar_my_reviews` today. That duplication is pre-existing and intentional (the
`user_list_state_controller` reveals both); the partial preserves it. Do not "fix" it.

- [ ] **Step 3: Verify the nav renders in both copies**

Append to `test/controllers/books/collections_controller_test.rb`:

```ruby
test "the nav lists every registered collection" do
  get "/"

  Collections::Registry.for(:books).each do |collection|
    assert_select "a[href=?]", "/#{collection.slug}", {minimum: 1},
      "nav is missing a link to /#{collection.slug}"
  end
  assert_select "a[href=?]", "/the-greatest-books/since/2000"
  assert_select "a[href=?]", "/lists/463"
end
```

- [ ] **Step 4: Run the tests and the daisyUI guard**

```bash
bin/rails test test/controllers/books/collections_controller_test.rb test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS. If the daisyUI guard fails, remove the offending class from the partial —
never add an allowlist entry.

- [ ] **Step 5: Write the Playwright spec**

Create `e2e/tests/books/collections.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books curated collections', () => {
  test('the Lists menu links to a collection', async ({ page }) => {
    await page.goto('/');
    await page.setViewportSize({ width: 1280, height: 900 });

    await page.locator('.navbar-center summary', { hasText: 'Lists' }).click();
    await page.locator('.navbar-center a', { hasText: 'Greatest African Books' }).click();

    await expect(page).toHaveURL('/africa');
    await expect(page.getByRole('heading', { level: 1 }))
      .toHaveText('The Greatest African Books of All Time');
  });

  test('a collection page offers genre and year but not origin', async ({ page }) => {
    await page.goto('/africa');
    await page.getByRole('button', { name: 'Filters' }).click();
    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();

    await expect(page.locator("[data-level-target='category']")).toBeVisible();
    await expect(page.locator("[data-level-target='year']")).toBeVisible();
    await expect(page.locator("[data-level-target='country']")).toHaveCount(0);
  });

  test('applying a genre stays inside the collection', async ({ page }) => {
    await page.goto('/western');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator("[data-level-target='category']").click();

    const firstGenre = page
      .locator("turbo-frame#books_filter_pane_category label")
      .first();
    await firstGenre.waitFor();
    await firstGenre.click();

    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(/^\/western\/the-greatest\/[^/]+\/books$/);
  });
});
```

- [ ] **Step 6: Run the E2E spec**

Start the dev server first — `bin/dev` needs a TTY and self-terminates in a background agent
shell, so use the split form and check what is actually listening on port 3000:

```bash
yarn build:all
bin/rails server -p 3000
```

In another shell:

```bash
yarn test:e2e e2e/tests/books/collections.spec.ts
```

Expected: 3 passing. If admin-ish specs elsewhere start timing out on the homepage, the e2e
user lost its role — `bin/rails e2e:admin`.

- [ ] **Step 7: Run the full suite and lint**

```bash
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: both green.

- [ ] **Step 8: Commit**

```bash
git add app/views/books/shared/_nav_links.html.erb app/views/layouts/books/application.html.erb e2e/tests/books/collections.spec.ts test/controllers/books/collections_controller_test.rb
git commit -m "feat(books): add the curated collections nav menu"
```

---

## Done When

- [ ] All six collection pages render on their bare slug and on the full legacy filter grammar.
- [ ] The three redirect families 301 to the bare slug.
- [ ] Titles match the golden examples in the spec exactly.
- [ ] The filter bar on a collection page offers genre + year only, and Apply returns into the collection.
- [ ] The nav "Lists" menu shows 9 items in both copies.
- [ ] `bin/rails test` green, `bundle exec standardrb` clean, Playwright spec passing.
- [ ] Spec updated: Implementation Notes, Key Files Touched, Deviations; status moved to Completed and the file moved to `docs/specs/completed/`.
