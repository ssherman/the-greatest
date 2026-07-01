# Books Object Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the books domain object model (9 `Books::` tables + 1 shared `Language` table) per the approved design spec, mirroring the existing music domain.

**Architecture:** 2-tier `Books::Book` (Work) → `Books::Edition` (Manifestation), with `Books::Author` (role-neutral), `Books::Series` (non-ranked grouping), join/relationship models, and reuse of the existing shared polymorphic tables (`Identifier`, `Image`, `ExternalLink`, `Category`, `List`, `RankedItem`, `AiChat`). No importers, no dedup/merge pipeline, no UI — model layer only.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + fixtures + Mocha, FriendlyId, OpenSearch (`SearchIndexable` concern), namespaced ActiveRecord models.

**Design spec:** `docs/superpowers/specs/2026-06-29-books-object-model-design.md`
**Reference implementation:** the `Music::` domain — `app/models/music/{album,release,artist,credit,membership,song_relationship,category}.rb` and their tests in `test/models/music/`.

## Global Constraints

- Run **all** commands from `web-app/` (`cd web-app` first).
- **Use Rails generators** — never hand-create models. `bin/rails generate model ...` creates the model, migration, test, and fixture files; then edit their contents to match this plan.
- **Namespace all books code under `Books::`**; the shared `Language` model stays in the global namespace. Tests mirror the namespace (`module Books; class BookTest`).
- **Skinny models, fat services.** Models hold only validations/associations/scopes/enums. No business logic in models.
- **Rails 8 enum syntax:** `enum :book_kind, {standalone: 0}` (colon prefix), never `enum book_kind: {...}`.
- **Polymorphic associations** use the existing `_able`/`parent`/`item`/`identifiable` conventions from music. In fixtures use `listable: dark_side (Music::Album)` style — never set `_type` manually.
- **No code comments** unless essential; write self-documenting code following music patterns.
- **Fixtures use semantic names** (`regular_user`, `dark_side`), never `one`/`two`. Check actual fixture names before referencing.
- CI must stay green: `bin/rails db:test:prepare test test:system`, `bin/rubocop -f github`, `bin/brakeman --no-pager`.
- After each task: `bin/rubocop -a` on touched files, then commit.

---

## File Structure

**New shared model:**
- `app/models/language.rb` + `db/migrate/*_create_languages.rb` + `test/models/language_test.rb` + `test/fixtures/languages.yml`

**New `Books::` models** (each: `app/models/books/<name>.rb` + migration + `test/models/books/<name>_test.rb` + `test/fixtures/books/<name>.yml`):
- `book.rb` (`books_books`), `edition.rb` (`books_editions`), `author.rb` (`books_authors`), `series.rb` (`books_series`), `book_author.rb` (`books_book_authors`), `credit.rb` (`books_credits`), `author_relationship.rb` (`books_author_relationships`), `series_book.rb` (`books_series_books`), `book_relationship.rb` (`books_book_relationships`)

**Modified:**
- `app/models/identifier.rb` — reorganize `books_*` enum (Task 2)
- `app/models/books/category.rb` — enable book/author associations (Task 12)

**Dependency order:** Language → Identifier enum → Book → Edition → Author → BookAuthor → Credit → AuthorRelationship → Series → SeriesBook → BookRelationship → Category wiring. Cross-model associations are added to `Books::Book`/`Books::Author` incrementally as each counterpart model comes online.

---

## Task 1: Shared `Language` model

**Files:**
- Create: `app/models/language.rb`, `db/migrate/<ts>_create_languages.rb`
- Test: `test/models/language_test.rb`, `test/fixtures/languages.yml`

**Interfaces:**
- Produces: `Language` with `name`, `slug`, `iso_639_1`, `iso_639_3`; `friendly_id :name`. Referenced later by `Books::Book.original_language_id` and `Books::Edition.language_id`.

- [ ] **Step 1: Generate the model**

```bash
cd web-app
bin/rails generate model Language name:string slug:string iso_639_1:string iso_639_3:string
```

- [ ] **Step 2: Replace the migration** with this content (file `db/migrate/<ts>_create_languages.rb`):

```ruby
class CreateLanguages < ActiveRecord::Migration[8.0]
  def change
    create_table :languages do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :iso_639_1, limit: 2
      t.string :iso_639_3, limit: 3

      t.timestamps
    end

    add_index :languages, :slug, unique: true
    add_index :languages, :iso_639_3, unique: true
    add_index :languages, :name
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:languages)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/language_test.rb`:

```ruby
require "test_helper"

class LanguageTest < ActiveSupport::TestCase
  test "is valid with a name" do
    assert_predicate Language.new(name: "Klingon"), :valid?
  end

  test "requires a name" do
    language = Language.new
    assert_not language.valid?
    assert_includes language.errors[:name], "can't be blank"
  end

  test "generates a slug from the name" do
    language = Language.create!(name: "Ancient Greek")
    assert_equal "ancient-greek", language.slug
  end

  test "iso_639_3 is unique" do
    Language.create!(name: "Latin", iso_639_3: "lat")
    dup = Language.new(name: "Latin II", iso_639_3: "lat")
    assert_not dup.valid?
    assert_includes dup.errors[:iso_639_3], "has already been taken"
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/languages.yml`:

```yaml
english:
  name: English
  slug: english
  iso_639_1: en
  iso_639_3: eng

french:
  name: French
  slug: french
  iso_639_1: fr
  iso_639_3: fra

russian:
  name: Russian
  slug: russian
  iso_639_1: ru
  iso_639_3: rus

latin:
  name: Latin
  slug: latin
  iso_639_3: lat
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/language_test.rb`
Expected: FAIL (no validations/friendly_id yet — slug/name/uniqueness tests fail).

- [ ] **Step 7: Implement the model** — replace `app/models/language.rb`:

```ruby
class Language < ApplicationRecord
  extend FriendlyId
  friendly_id :name, use: [:slugged, :finders]

  validates :name, presence: true
  validates :iso_639_1, length: {is: 2}, allow_blank: true
  validates :iso_639_3, length: {is: 3}, allow_blank: true, uniqueness: {allow_nil: true}
end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/language_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/models/language.rb test/models/language_test.rb
git add app/models/language.rb db/migrate/*_create_languages.rb test/models/language_test.rb test/fixtures/languages.yml db/schema.rb
git commit -m "Add shared Language model"
```

---

## Task 2: Reorganize the `books_*` Identifier enum

**Files:**
- Modify: `app/models/identifier.rb:24-59` (the `books_*` entries only)
- Test: `test/models/identifier_test.rb` (add coverage)

**Interfaces:**
- Produces: work/edition/author-level books identifier types used by `Books::Book`/`Edition`/`Author` for external IDs. Music/games entries are untouched.

**Context:** A grep confirmed the old `books_*` enum values are referenced ONLY inside `identifier.rb`; no books data exists, so this is a clean redefine.

- [ ] **Step 1: Write the failing test** — add to `test/models/identifier_test.rb`:

```ruby
test "books identifier types are organized by entity level" do
  assert_equal 0, Identifier.identifier_types["books_work_oclc_id"]
  assert_equal 10, Identifier.identifier_types["books_edition_isbn13"]
  assert_equal 30, Identifier.identifier_types["books_author_viaf"]
end

test "music and games identifier types are unchanged" do
  assert_equal 100, Identifier.identifier_types["music_musicbrainz_artist_id"]
  assert_equal 400, Identifier.identifier_types["games_igdb_id"]
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/identifier_test.rb`
Expected: FAIL (old keys like `books_isbn10` still present; new keys undefined).

- [ ] **Step 3: Replace the `books_*` block** in `app/models/identifier.rb`. Change lines 24-59 so the enum reads (keep everything from `music_*` onward exactly as-is):

```ruby
  enum :identifier_type, {
    # Books - Work level (Books::Book)
    books_work_oclc_id: 0,
    books_work_wikidata_qid: 1,
    books_work_openlibrary_id: 2,
    books_work_goodreads_id: 3,
    books_work_librarything_id: 4,

    # Books - Edition level (Books::Edition)
    books_edition_isbn13: 10,
    books_edition_isbn10: 11,
    books_edition_asin: 12,
    books_edition_ean13: 13,
    books_edition_oclc_number: 14,
    books_edition_goodreads_id: 15,
    books_edition_openlibrary_id: 16,
    books_edition_google_id: 17,
    books_edition_bookshop_org_id: 18,

    # Books - Author level (Books::Author)
    books_author_viaf: 30,
    books_author_isni: 31,
    books_author_wikidata_qid: 32,
    books_author_openlibrary_id: 33,
    books_author_goodreads_id: 34,
    books_author_librarything_id: 35,
    books_author_lcnaf: 36,

    # Music - Artists
    music_musicbrainz_artist_id: 100,
```

- [ ] **Step 4: Update the `Identifier.books` class method** (around line 73). It currently filters `["Books::Book"]`. Replace it with three helpers so each entity level is queryable:

```ruby
  def self.books_works
    for_domain(["Books::Book"])
  end

  def self.books_editions
    for_domain(["Books::Edition"])
  end

  def self.books_authors
    for_domain(["Books::Author"])
  end
```

Delete the old `def self.books; for_domain(["Books::Book"]); end` method.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/models/identifier_test.rb`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bin/rubocop -a app/models/identifier.rb test/models/identifier_test.rb
git add app/models/identifier.rb test/models/identifier_test.rb
git commit -m "Reorganize books_* Identifier enum into work/edition/author levels"
```

---

## Task 3: `Books::Book` (the Work)

**Files:**
- Create: `app/models/books/book.rb`, migration, `test/models/books/book_test.rb`, `test/fixtures/books/books.yml`

**Interfaces:**
- Consumes: `Language` (Task 1).
- Produces: `Books::Book` with `title`, `subtitle`, `sort_title`, `alternate_titles` (string[]), `slug`, `description`, `first_published_year`, `original_language_id`, `book_kind` enum (`standalone`/`collection`); scope `selectable`; `belongs_to :original_language`. `default_edition` is added in Task 4. Table `books_books`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Book title:string subtitle:string sort_title:string slug:string description:text first_published_year:integer original_language:references book_kind:integer
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksBooks < ActiveRecord::Migration[8.0]
  def change
    create_table :books_books do |t|
      t.string :title, null: false
      t.string :subtitle
      t.string :sort_title
      t.string :alternate_titles, array: true, default: [], null: false
      t.string :slug, null: false
      t.text :description
      t.integer :first_published_year
      t.references :original_language, foreign_key: {to_table: :languages}
      t.integer :book_kind, null: false, default: 0

      t.timestamps
    end

    add_index :books_books, :slug, unique: true
    add_index :books_books, :book_kind
    add_index :books_books, :first_published_year
    add_index :books_books, :alternate_titles, using: :gin
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_books)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/book_test.rb`:

```ruby
require "test_helper"

module Books
  class BookTest < ActiveSupport::TestCase
    test "is valid with a title" do
      assert_predicate Books::Book.new(title: "Ulysses"), :valid?
    end

    test "requires a title" do
      book = Books::Book.new
      assert_not book.valid?
      assert_includes book.errors[:title], "can't be blank"
    end

    test "generates a slug from the title" do
      book = Books::Book.create!(title: "War and Peace")
      assert_equal "war-and-peace", book.slug
    end

    test "defaults to standalone kind" do
      assert_predicate Books::Book.new(title: "X"), :standalone?
    end

    test "selectable scope excludes collections" do
      assert_includes Books::Book.selectable, books_books(:war_and_peace)
      assert_not_includes Books::Book.selectable, books_books(:combo_steinbeck)
    end

    test "belongs to an original language" do
      assert_equal languages(:russian), books_books(:war_and_peace).original_language
    end

    test "as_indexed_json includes title, alternate_titles and author names" do
      json = books_books(:war_and_peace).as_indexed_json
      assert_equal "War and Peace", json[:title]
      assert_kind_of Array, json[:alternate_titles]
      assert_kind_of Array, json[:author_names]
    end
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/books/books.yml`:

```yaml
war_and_peace:
  title: War and Peace
  slug: war-and-peace
  first_published_year: 1869
  original_language: russian (Language)
  book_kind: 0
  alternate_titles: ["Voyna i mir"]

crime_and_punishment:
  title: Crime and Punishment
  slug: crime-and-punishment
  first_published_year: 1866
  original_language: russian (Language)
  book_kind: 0

combo_steinbeck:
  title: Of Mice and Men / Cannery Row
  slug: of-mice-and-men-cannery-row
  book_kind: 1
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: FAIL (model has no enum/scope/associations/`as_indexed_json`).

- [ ] **Step 7: Implement the model** — replace `app/models/books/book.rb`:

```ruby
class Books::Book < ApplicationRecord
  include SearchIndexable

  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  enum :book_kind, {standalone: 0, collection: 1}

  belongs_to :original_language, class_name: "Language", optional: true

  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Books::Category"
  has_many :list_items, as: :listable, dependent: :destroy
  has_many :lists, through: :list_items
  has_many :user_list_items, as: :listable, dependent: :destroy
  has_many :user_lists, through: :user_list_items
  has_many :ranked_items, as: :item, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title

  scope :selectable, -> { where(book_kind: :standalone) }

  def as_indexed_json
    {
      title: title,
      alternate_titles: alternate_titles,
      author_names: [],
      category_ids: categories.active.pluck(:id)
    }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end
end
```

> Note: `author_names` returns `[]` for now; Task 6 fills it in once `book_authors` exists. The books `categories` association omits `inverse_of` on purpose (the `Books::Category#books` inverse doesn't exist until Task 12); it works fine without it.

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/books/book_test.rb`
Expected: PASS (7 tests). If `categories.active` errors, confirm `Books::Category` exists (it does) — the `active` scope is inherited from `Category`.

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/models/books/book.rb test/models/books/book_test.rb
git add app/models/books/book.rb db/migrate/*_create_books_books.rb test/models/books/book_test.rb test/fixtures/books/books.yml db/schema.rb
git commit -m "Add Books::Book (Work) model"
```

---

## Task 4: `Books::Edition` (the Manifestation) + Book#default_edition

**Files:**
- Create: `app/models/books/edition.rb`, migration, `test/models/books/edition_test.rb`, `test/fixtures/books/editions.yml`
- Modify: `app/models/books/book.rb` (add `has_many :editions`, `belongs_to :default_edition`), migration to add `default_edition_id` to `books_books`

**Interfaces:**
- Consumes: `Books::Book` (Task 3), `Language` (Task 1).
- Produces: `Books::Edition` with `book_id`, `title`, `subtitle`, `edition_type` enum, `language_id`, `book_binding` enum, `publication_year`, `volume_number`, `page_count`, `popularity`, `metadata` jsonb; `belongs_to :book`, `belongs_to :language`. Adds `Books::Book#editions` and `#default_edition`. Table `books_editions`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Edition book:references title:string subtitle:string edition_type:integer language:references book_binding:integer publication_year:integer volume_number:integer page_count:integer popularity:integer metadata:jsonb
```

- [ ] **Step 2: Replace the migration** (`*_create_books_editions.rb`):

```ruby
class CreateBooksEditions < ActiveRecord::Migration[8.0]
  def change
    create_table :books_editions do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.string :title
      t.string :subtitle
      t.integer :edition_type, null: false, default: 0
      t.references :language, foreign_key: {to_table: :languages}
      t.integer :book_binding
      t.integer :publication_year
      t.integer :volume_number
      t.integer :page_count
      t.integer :popularity
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :books_editions, :edition_type
    add_index :books_editions, :volume_number
  end
end
```

- [ ] **Step 3: Generate the migration to add default_edition to books_books**

```bash
bin/rails generate migration AddDefaultEditionToBooksBooks
```

Replace its content:

```ruby
class AddDefaultEditionToBooksBooks < ActiveRecord::Migration[8.0]
  def change
    add_reference :books_books, :default_edition, foreign_key: {to_table: :books_editions}
  end
end
```

- [ ] **Step 4: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both tables/columns created.

- [ ] **Step 5: Write the failing test** — replace `test/models/books/edition_test.rb`:

```ruby
require "test_helper"

module Books
  class EditionTest < ActiveSupport::TestCase
    test "is valid with a book" do
      assert_predicate Books::Edition.new(book: books_books(:war_and_peace)), :valid?
    end

    test "requires a book" do
      edition = Books::Edition.new
      assert_not edition.valid?
      assert_includes edition.errors[:book], "must exist"
    end

    test "defaults to standard edition_type" do
      assert_predicate Books::Edition.new(book: books_books(:war_and_peace)), :edition_type_standard?
    end

    test "belongs to a language" do
      assert_equal languages(:english), books_editions(:wp_maude).language
    end

    test "volume editions carry a volume_number" do
      assert_equal 1, books_editions(:wp_volume_one).volume_number
    end

    test "book has many editions" do
      assert_includes books_books(:war_and_peace).editions, books_editions(:wp_maude)
    end
  end
end
```

- [ ] **Step 6: Add fixtures** — replace `test/fixtures/books/editions.yml`:

```yaml
wp_maude:
  book: war_and_peace (Books::Book)
  title: War and Peace
  edition_type: 0
  language: english (Language)
  book_binding: 1
  publication_year: 1990

wp_volume_one:
  book: war_and_peace (Books::Book)
  title: "War and Peace, Volume 1"
  edition_type: 0
  language: english (Language)
  volume_number: 1
```

- [ ] **Step 7: Run the test to verify it fails**

Run: `bin/rails test test/models/books/edition_test.rb`
Expected: FAIL (model lacks enums/associations).

- [ ] **Step 8: Implement the model** — replace `app/models/books/edition.rb`:

```ruby
class Books::Edition < ApplicationRecord
  enum :edition_type, {standard: 0, annotated: 1, illustrated: 2, critical: 3, abridged: 4, revised: 5}, prefix: :edition_type
  enum :book_binding, {hardcover: 0, paperback: 1, mass_market: 2, ebook: 3, audiobook: 4, library_binding: 5, leather_bound: 6, other: 7}, prefix: :book_binding

  belongs_to :book, class_name: "Books::Book"
  belongs_to :language, class_name: "Language", optional: true

  has_many :credits, as: :creditable, class_name: "Books::Credit", dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  validates :book, presence: true
  validates :edition_type, presence: true

  scope :complete, -> { where(volume_number: nil) }
  scope :by_binding, ->(value) { where(book_binding: value) }
end
```

> Note: `has_many :credits` references `Books::Credit`, created in Task 7. The declaration is lazy and compiles now; it's exercised in Task 7's tests.

- [ ] **Step 9: Add associations to `Books::Book`** — in `app/models/books/book.rb`, add after the `belongs_to :original_language` line:

```ruby
  belongs_to :default_edition, class_name: "Books::Edition", optional: true
  has_many :editions, class_name: "Books::Edition", dependent: :destroy
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/edition_test.rb test/models/books/book_test.rb`
Expected: PASS.

- [ ] **Step 11: Lint and commit**

```bash
bin/rubocop -a app/models/books/edition.rb app/models/books/book.rb test/models/books/edition_test.rb
git add app/models/books/edition.rb app/models/books/book.rb db/migrate/*_create_books_editions.rb db/migrate/*_add_default_edition_to_books_books.rb test/models/books/edition_test.rb test/fixtures/books/editions.yml db/schema.rb
git commit -m "Add Books::Edition model and Book#default_edition/editions"
```

---

## Task 5: `Books::Author`

**Files:**
- Create: `app/models/books/author.rb`, migration, `test/models/books/author_test.rb`, `test/fixtures/books/authors.yml`

**Interfaces:**
- Produces: `Books::Author` with `name`, `sort_name`, `slug`, `kind` enum (`person`/`organization`/`pseudonym`/`collective`), `birth_year`, `death_year`, `description`, `alternate_names` (string[]). Table `books_authors`. Ranked/listable via shared polymorphics. Mirrors `Music::Artist`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Author name:string sort_name:string slug:string kind:integer birth_year:integer death_year:integer description:text
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksAuthors < ActiveRecord::Migration[8.0]
  def change
    create_table :books_authors do |t|
      t.string :name, null: false
      t.string :sort_name
      t.string :slug, null: false
      t.integer :kind, null: false, default: 0
      t.integer :birth_year
      t.integer :death_year
      t.text :description
      t.string :alternate_names, array: true, default: [], null: false

      t.timestamps
    end

    add_index :books_authors, :slug, unique: true
    add_index :books_authors, :kind
    add_index :books_authors, :alternate_names, using: :gin
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_authors)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/author_test.rb`:

```ruby
require "test_helper"

module Books
  class AuthorTest < ActiveSupport::TestCase
    test "is valid with a name" do
      assert_predicate Books::Author.new(name: "Leo Tolstoy"), :valid?
    end

    test "requires a name" do
      author = Books::Author.new
      assert_not author.valid?
      assert_includes author.errors[:name], "can't be blank"
    end

    test "generates a slug from the name" do
      author = Books::Author.create!(name: "Fyodor Dostoevsky")
      assert_equal "fyodor-dostoevsky", author.slug
    end

    test "defaults to person kind" do
      assert_predicate Books::Author.new(name: "X"), :person?
    end

    test "supports pseudonym kind" do
      assert_predicate books_authors(:bachman), :pseudonym?
    end

    test "as_indexed_json includes name and alternate_names" do
      json = books_authors(:tolstoy).as_indexed_json
      assert_equal "Leo Tolstoy", json[:name]
      assert_kind_of Array, json[:alternate_names]
    end
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/books/authors.yml`:

```yaml
tolstoy:
  name: Leo Tolstoy
  slug: leo-tolstoy
  kind: 0
  birth_year: 1828
  death_year: 1910
  alternate_names: ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"]

king:
  name: Stephen King
  slug: stephen-king
  kind: 0
  birth_year: 1947

bachman:
  name: Richard Bachman
  slug: richard-bachman
  kind: 2
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: FAIL (no enum/friendly_id/`as_indexed_json`).

- [ ] **Step 7: Implement the model** — replace `app/models/books/author.rb`:

```ruby
class Books::Author < ApplicationRecord
  include SearchIndexable

  extend FriendlyId
  friendly_id :name, use: [:slugged, :finders]

  enum :kind, {person: 0, organization: 1, pseudonym: 2, collective: 3}

  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Books::Category"
  has_many :ranked_items, as: :item, dependent: :destroy

  validates :name, presence: true
  validates :kind, presence: true

  before_validation :normalize_name

  def as_indexed_json
    {
      name: name,
      alternate_names: alternate_names,
      category_ids: categories.active.pluck(:id)
    }
  end

  private

  def normalize_name
    self.name = Services::Text::QuoteNormalizer.call(name) if name.present?
  end
end
```

> `book_authors`, `books`, `credits`, and `author_relationships` associations are added in Tasks 6–8.

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/books/author_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/models/books/author.rb test/models/books/author_test.rb
git add app/models/books/author.rb db/migrate/*_create_books_authors.rb test/models/books/author_test.rb test/fixtures/books/authors.yml db/schema.rb
git commit -m "Add Books::Author model"
```

---

## Task 6: `Books::BookAuthor` (primary authorship join)

**Files:**
- Create: `app/models/books/book_author.rb`, migration, `test/models/books/book_author_test.rb`, `test/fixtures/books/book_authors.yml`
- Modify: `app/models/books/book.rb` (add `book_authors`/`authors`, update `as_indexed_json`), `app/models/books/author.rb` (add `book_authors`/`books`)

**Interfaces:**
- Consumes: `Books::Book` (Task 3), `Books::Author` (Task 5).
- Produces: `Books::BookAuthor` with `book_id`, `author_id`, `position`, `role` enum (`author`/`editor`), `credited_as`. Adds `Book#authors`, `Author#books`. Table `books_book_authors`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::BookAuthor book:references author:references position:integer role:integer credited_as:string
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksBookAuthors < ActiveRecord::Migration[8.0]
  def change
    create_table :books_book_authors do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.integer :position
      t.integer :role, null: false, default: 0
      t.string :credited_as

      t.timestamps
    end

    add_index :books_book_authors, [:book_id, :author_id], unique: true
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_book_authors)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/book_author_test.rb`:

```ruby
require "test_helper"

module Books
  class BookAuthorTest < ActiveSupport::TestCase
    test "is valid with a book and author" do
      ba = Books::BookAuthor.new(book: books_books(:crime_and_punishment), author: books_authors(:tolstoy))
      assert_predicate ba, :valid?
    end

    test "defaults to author role" do
      assert_predicate Books::BookAuthor.new, :author?
    end

    test "is unique per book and author" do
      dup = Books::BookAuthor.new(book: books_books(:war_and_peace), author: books_authors(:tolstoy))
      assert_not dup.valid?
      assert_includes dup.errors[:book_id], "has already been taken"
    end

    test "book exposes its authors" do
      assert_includes books_books(:war_and_peace).authors, books_authors(:tolstoy)
    end

    test "author exposes its books" do
      assert_includes books_authors(:tolstoy).books, books_books(:war_and_peace)
    end

    test "credited_as stores the printed name" do
      assert_equal "Lev Tolstoy", books_book_authors(:war_and_peace_tolstoy).credited_as
    end

    test "book as_indexed_json includes author names" do
      assert_includes books_books(:war_and_peace).as_indexed_json[:author_names], "Leo Tolstoy"
    end
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/books/book_authors.yml`:

```yaml
war_and_peace_tolstoy:
  book: war_and_peace (Books::Book)
  author: tolstoy (Books::Author)
  position: 1
  role: 0
  credited_as: Lev Tolstoy
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_author_test.rb`
Expected: FAIL (model + Book/Author associations missing).

- [ ] **Step 7: Implement the join model** — replace `app/models/books/book_author.rb`:

```ruby
class Books::BookAuthor < ApplicationRecord
  enum :role, {author: 0, editor: 1}

  belongs_to :book, class_name: "Books::Book"
  belongs_to :author, class_name: "Books::Author"

  validates :book_id, uniqueness: {scope: :author_id}
end
```

- [ ] **Step 8: Wire `Books::Book`** — in `app/models/books/book.rb`, add these associations (near `has_many :editions`):

```ruby
  has_many :book_authors, -> { order(:position) }, class_name: "Books::BookAuthor", dependent: :destroy
  has_many :authors, through: :book_authors, class_name: "Books::Author"
```

And update `as_indexed_json` so `author_names:` reads:

```ruby
      author_names: authors.map(&:name),
```

- [ ] **Step 9: Wire `Books::Author`** — in `app/models/books/author.rb`, add:

```ruby
  has_many :book_authors, class_name: "Books::BookAuthor", dependent: :destroy
  has_many :books, through: :book_authors, class_name: "Books::Book"
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/book_author_test.rb test/models/books/book_test.rb`
Expected: PASS.

- [ ] **Step 11: Lint and commit**

```bash
bin/rubocop -a app/models/books/book_author.rb app/models/books/book.rb app/models/books/author.rb test/models/books/book_author_test.rb
git add app/models/books/book_author.rb app/models/books/book.rb app/models/books/author.rb db/migrate/*_create_books_book_authors.rb test/models/books/book_author_test.rb test/fixtures/books/book_authors.yml db/schema.rb
git commit -m "Add Books::BookAuthor join and wire Book/Author authorship"
```

---

## Task 7: `Books::Credit` (secondary roles, polymorphic)

**Files:**
- Create: `app/models/books/credit.rb`, migration, `test/models/books/credit_test.rb`, `test/fixtures/books/credits.yml`
- Modify: `app/models/books/author.rb` (add `credits`), `test/fixtures/books/authors.yml` (add translator)

**Interfaces:**
- Consumes: `Books::Author`, `Books::Book`, `Books::Edition`.
- Produces: `Books::Credit` — `author_id`, polymorphic `creditable` (→ `Books::Book` or `Books::Edition`), `role` enum, `position`. Table `books_credits`. Mirrors `Music::Credit`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Credit author:references creditable:references{polymorphic} role:integer position:integer
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :books_credits do |t|
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.references :creditable, polymorphic: true, null: false
      t.integer :role, null: false, default: 0
      t.integer :position

      t.timestamps
    end

    add_index :books_credits, [:author_id, :role]
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_credits)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/credit_test.rb`:

```ruby
require "test_helper"

module Books
  class CreditTest < ActiveSupport::TestCase
    test "is valid with author, creditable and role" do
      credit = Books::Credit.new(author: books_authors(:garnett), creditable: books_editions(:wp_maude), role: :translator)
      assert_predicate credit, :valid?
    end

    test "requires an author" do
      credit = Books::Credit.new(creditable: books_editions(:wp_maude), role: :translator)
      assert_not credit.valid?
      assert_includes credit.errors[:author], "must exist"
    end

    test "attaches to an edition as translator" do
      assert_equal :translator, books_credits(:wp_translator).role.to_sym
      assert_equal books_editions(:wp_maude), books_credits(:wp_translator).creditable
    end

    test "by_role scope filters" do
      assert_includes Books::Credit.by_role(:translator), books_credits(:wp_translator)
    end
  end
end
```

- [ ] **Step 5: Add fixtures.** Append a translator to `test/fixtures/books/authors.yml`:

```yaml
garnett:
  name: Constance Garnett
  slug: constance-garnett
  kind: 0
```

Replace `test/fixtures/books/credits.yml`:

```yaml
wp_translator:
  author: garnett (Books::Author)
  creditable: wp_maude (Books::Edition)
  role: 0
  position: 1
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/credit_test.rb`
Expected: FAIL (model not implemented).

- [ ] **Step 7: Implement the model** — replace `app/models/books/credit.rb`:

```ruby
class Books::Credit < ApplicationRecord
  enum :role, {translator: 0, illustrator: 1, editor: 2, introduction: 3, foreword: 4, afterword: 5, narrator: 6, cover_artist: 7, contributor: 8, ghostwriter: 9}

  belongs_to :author, class_name: "Books::Author"
  belongs_to :creditable, polymorphic: true

  validates :author, presence: true
  validates :creditable, presence: true
  validates :role, presence: true

  scope :by_role, ->(role) { where(role: role) }
  scope :ordered, -> { order(:position, :id) }
end
```

- [ ] **Step 8: Wire `Books::Author`** — add to `app/models/books/author.rb`:

```ruby
  has_many :credits, class_name: "Books::Credit", dependent: :destroy
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bin/rails test test/models/books/credit_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 10: Lint and commit**

```bash
bin/rubocop -a app/models/books/credit.rb app/models/books/author.rb test/models/books/credit_test.rb
git add app/models/books/credit.rb app/models/books/author.rb db/migrate/*_create_books_credits.rb test/models/books/credit_test.rb test/fixtures/books/credits.yml test/fixtures/books/authors.yml db/schema.rb
git commit -m "Add Books::Credit polymorphic role model"
```

---

## Task 8: `Books::AuthorRelationship` (pen-names / personas)

**Files:**
- Create: `app/models/books/author_relationship.rb`, migration, `test/models/books/author_relationship_test.rb`, `test/fixtures/books/author_relationships.yml`
- Modify: `app/models/books/author.rb` (add relationship associations)

**Interfaces:**
- Consumes: `Books::Author`.
- Produces: `Books::AuthorRelationship` — `from_author_id`, `to_author_id`, `relation_type` enum (`pseudonym_of`/`member_of`). Table `books_author_relationships`. Mirrors `Music::Membership`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::AuthorRelationship from_author:references to_author:references relation_type:integer
```

- [ ] **Step 2: Replace the migration** (note the FK `to_table` overrides, since both columns point at `books_authors`):

```ruby
class CreateBooksAuthorRelationships < ActiveRecord::Migration[8.0]
  def change
    create_table :books_author_relationships do |t|
      t.references :from_author, null: false, foreign_key: {to_table: :books_authors}
      t.references :to_author, null: false, foreign_key: {to_table: :books_authors}
      t.integer :relation_type, null: false, default: 0

      t.timestamps
    end

    add_index :books_author_relationships, [:from_author_id, :to_author_id, :relation_type], unique: true, name: "index_books_author_relationships_unique"
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_author_relationships)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/author_relationship_test.rb`:

```ruby
require "test_helper"

module Books
  class AuthorRelationshipTest < ActiveSupport::TestCase
    test "links a pseudonym to a person" do
      rel = books_author_relationships(:bachman_is_king)
      assert_equal books_authors(:bachman), rel.from_author
      assert_equal books_authors(:king), rel.to_author
      assert_predicate rel, :relation_type_pseudonym_of?
    end

    test "rejects self-reference" do
      rel = Books::AuthorRelationship.new(from_author: books_authors(:king), to_author: books_authors(:king), relation_type: :pseudonym_of)
      assert_not rel.valid?
      assert_includes rel.errors[:to_author_id], "cannot relate an author to itself"
    end

    test "is unique per from/to/type" do
      dup = Books::AuthorRelationship.new(from_author: books_authors(:bachman), to_author: books_authors(:king), relation_type: :pseudonym_of)
      assert_not dup.valid?
      assert_includes dup.errors[:from_author_id], "has already been taken"
    end
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/books/author_relationships.yml`:

```yaml
bachman_is_king:
  from_author: bachman (Books::Author)
  to_author: king (Books::Author)
  relation_type: 0
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/author_relationship_test.rb`
Expected: FAIL (model not implemented).

- [ ] **Step 7: Implement the model** — replace `app/models/books/author_relationship.rb`:

```ruby
class Books::AuthorRelationship < ApplicationRecord
  enum :relation_type, {pseudonym_of: 0, member_of: 1}, prefix: true

  belongs_to :from_author, class_name: "Books::Author"
  belongs_to :to_author, class_name: "Books::Author"

  validates :from_author_id, uniqueness: {scope: [:to_author_id, :relation_type]}
  validate :no_self_reference

  private

  def no_self_reference
    errors.add(:to_author_id, "cannot relate an author to itself") if from_author_id == to_author_id
  end
end
```

- [ ] **Step 8: Wire `Books::Author`** — add to `app/models/books/author.rb`:

```ruby
  has_many :author_relationships, class_name: "Books::AuthorRelationship", foreign_key: :from_author_id, dependent: :destroy
  has_many :inverse_author_relationships, class_name: "Books::AuthorRelationship", foreign_key: :to_author_id, dependent: :destroy
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bin/rails test test/models/books/author_relationship_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 10: Lint and commit**

```bash
bin/rubocop -a app/models/books/author_relationship.rb app/models/books/author.rb test/models/books/author_relationship_test.rb
git add app/models/books/author_relationship.rb app/models/books/author.rb db/migrate/*_create_books_author_relationships.rb test/models/books/author_relationship_test.rb test/fixtures/books/author_relationships.yml db/schema.rb
git commit -m "Add Books::AuthorRelationship for pen-names and personas"
```

---

## Task 9: `Books::Series`

**Files:**
- Create: `app/models/books/series.rb`, migration, `test/models/books/series_test.rb`, `test/fixtures/books/series.yml`

**Interfaces:**
- Consumes: `Books::Book` (for `representative_book`).
- Produces: `Books::Series` — `title`, `slug`, `description`, `representative_book_id`. Table `books_series`. `series_books`/`books`/`resolved_representative_book` added in Task 10.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::Series title:string slug:string description:text representative_book:references
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksSeries < ActiveRecord::Migration[8.0]
  def change
    create_table :books_series do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.references :representative_book, foreign_key: {to_table: :books_books}

      t.timestamps
    end

    add_index :books_series, :slug, unique: true
    add_index :books_series, :title
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_series)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/series_test.rb`:

```ruby
require "test_helper"

module Books
  class SeriesTest < ActiveSupport::TestCase
    test "is valid with a title" do
      assert_predicate Books::Series.new(title: "Mistborn"), :valid?
    end

    test "requires a title" do
      series = Books::Series.new
      assert_not series.valid?
      assert_includes series.errors[:title], "can't be blank"
    end

    test "generates a slug from the title" do
      series = Books::Series.create!(title: "The Wheel of Time")
      assert_equal "the-wheel-of-time", series.slug
    end

    test "representative_book is optional" do
      assert_nil books_series(:asoiaf).representative_book
    end
  end
end
```

- [ ] **Step 5: Add fixtures** — replace `test/fixtures/books/series.yml`:

```yaml
asoiaf:
  title: A Song of Ice and Fire
  slug: a-song-of-ice-and-fire
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/series_test.rb`
Expected: FAIL (model not implemented).

- [ ] **Step 7: Implement the model** — replace `app/models/books/series.rb`:

```ruby
class Books::Series < ApplicationRecord
  include SearchIndexable

  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  belongs_to :representative_book, class_name: "Books::Book", optional: true

  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title

  def as_indexed_json
    {title: title}
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end
end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/books/series_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 9: Lint and commit**

```bash
bin/rubocop -a app/models/books/series.rb test/models/books/series_test.rb
git add app/models/books/series.rb db/migrate/*_create_books_series.rb test/models/books/series_test.rb test/fixtures/books/series.yml db/schema.rb
git commit -m "Add Books::Series model"
```

---

## Task 10: `Books::SeriesBook` (series membership)

**Files:**
- Create: `app/models/books/series_book.rb`, migration, `test/models/books/series_book_test.rb`, `test/fixtures/books/series_books.yml`
- Modify: `app/models/books/series.rb` (members + `resolved_representative_book`), `app/models/books/book.rb` (series associations), `test/fixtures/books/books.yml` (append saga members)

**Interfaces:**
- Consumes: `Books::Series`, `Books::Book`.
- Produces: `Books::SeriesBook` — `series_id`, `book_id`, `position` (decimal), `position_label`, `numbered`. Adds `Series#books`, `Book#series`, `Series#resolved_representative_book`. Table `books_series_books`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::SeriesBook series:references book:references position:decimal position_label:string numbered:boolean
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksSeriesBooks < ActiveRecord::Migration[8.0]
  def change
    create_table :books_series_books do |t|
      t.references :series, null: false, foreign_key: {to_table: :books_series}
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.decimal :position, precision: 8, scale: 2
      t.string :position_label
      t.boolean :numbered, null: false, default: true

      t.timestamps
    end

    add_index :books_series_books, [:series_id, :book_id], unique: true
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_series_books)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/series_book_test.rb`:

```ruby
require "test_helper"

module Books
  class SeriesBookTest < ActiveSupport::TestCase
    test "is valid with a series and book" do
      sb = Books::SeriesBook.new(series: books_series(:asoiaf), book: books_books(:war_and_peace))
      assert_predicate sb, :valid?
    end

    test "defaults numbered to true" do
      assert_predicate Books::SeriesBook.new, :numbered?
    end

    test "supports decimal positions" do
      assert_equal 1.5, books_series_books(:asoiaf_novella).position
    end

    test "is unique per series and book" do
      dup = Books::SeriesBook.new(series: books_series(:asoiaf), book: books_books(:got))
      assert_not dup.valid?
      assert_includes dup.errors[:series_id], "has already been taken"
    end

    test "series lists its books ordered by position" do
      assert_equal [books_books(:got), books_series_books(:asoiaf_novella).book, books_books(:clash)],
        books_series(:asoiaf).books.to_a
    end

    test "resolved_representative_book falls back to the first member" do
      assert_equal books_books(:got), books_series(:asoiaf).resolved_representative_book
    end
  end
end
```

- [ ] **Step 5: Add fixtures.** Append two saga members to `test/fixtures/books/books.yml`:

```yaml
got:
  title: A Game of Thrones
  slug: a-game-of-thrones
  first_published_year: 1996
  book_kind: 0

clash:
  title: A Clash of Kings
  slug: a-clash-of-kings
  first_published_year: 1998
  book_kind: 0
```

Replace `test/fixtures/books/series_books.yml`:

```yaml
asoiaf_got:
  series: asoiaf (Books::Series)
  book: got (Books::Book)
  position: 1.0
  numbered: true

asoiaf_novella:
  series: asoiaf (Books::Series)
  book: crime_and_punishment (Books::Book)
  position: 1.5
  numbered: false

asoiaf_clash:
  series: asoiaf (Books::Series)
  book: clash (Books::Book)
  position: 2.0
  numbered: true
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/series_book_test.rb`
Expected: FAIL (model + associations missing).

- [ ] **Step 7: Implement the join model** — replace `app/models/books/series_book.rb`:

```ruby
class Books::SeriesBook < ApplicationRecord
  belongs_to :series, class_name: "Books::Series"
  belongs_to :book, class_name: "Books::Book"

  validates :series_id, uniqueness: {scope: :book_id}
end
```

- [ ] **Step 8: Wire `Books::Series`** — add to `app/models/books/series.rb`:

```ruby
  has_many :series_books, -> { order(:position) }, class_name: "Books::SeriesBook", dependent: :destroy
  has_many :books, through: :series_books, class_name: "Books::Book"
```

And add this reader:

```ruby
  def resolved_representative_book
    representative_book || series_books.order(:position).first&.book
  end
```

- [ ] **Step 9: Wire `Books::Book`** — add to `app/models/books/book.rb`:

```ruby
  has_many :series_books, class_name: "Books::SeriesBook", dependent: :destroy
  has_many :series, through: :series_books, class_name: "Books::Series"
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/series_book_test.rb test/models/books/series_test.rb`
Expected: PASS.

- [ ] **Step 11: Lint and commit**

```bash
bin/rubocop -a app/models/books/series_book.rb app/models/books/series.rb app/models/books/book.rb test/models/books/series_book_test.rb
git add app/models/books/series_book.rb app/models/books/series.rb app/models/books/book.rb db/migrate/*_create_books_series_books.rb test/models/books/series_book_test.rb test/fixtures/books/series_books.yml test/fixtures/books/books.yml db/schema.rb
git commit -m "Add Books::SeriesBook membership and wire Series/Book"
```

---

## Task 11: `Books::BookRelationship` (Work↔Work)

**Files:**
- Create: `app/models/books/book_relationship.rb`, migration, `test/models/books/book_relationship_test.rb`, `test/fixtures/books/book_relationships.yml`
- Modify: `app/models/books/book.rb` (relationship associations), `test/fixtures/books/books.yml` (append combo components)

**Interfaces:**
- Consumes: `Books::Book`.
- Produces: `Books::BookRelationship` — `book_id`, `related_book_id`, `relation_type` enum (`contains`/`abridgement_of`/`adaptation_of`/`revision_of`/`related_to`). Adds `Book#book_relationships`, `Book#related_books`, `Book#inverse_book_relationships`. Table `books_book_relationships`. Mirrors `Music::SongRelationship`.

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model Books::BookRelationship book:references related_book:references relation_type:integer
```

- [ ] **Step 2: Replace the migration**:

```ruby
class CreateBooksBookRelationships < ActiveRecord::Migration[8.0]
  def change
    create_table :books_book_relationships do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :related_book, null: false, foreign_key: {to_table: :books_books}
      t.integer :relation_type, null: false, default: 0

      t.timestamps
    end

    add_index :books_book_relationships, [:book_id, :related_book_id, :relation_type], unique: true, name: "index_books_book_relationships_unique"
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:books_book_relationships)` succeeds.

- [ ] **Step 4: Write the failing test** — replace `test/models/books/book_relationship_test.rb`:

```ruby
require "test_helper"

module Books
  class BookRelationshipTest < ActiveSupport::TestCase
    test "a collection contains component works" do
      rel = books_book_relationships(:combo_contains_omam)
      assert_equal books_books(:combo_steinbeck), rel.book
      assert_equal books_books(:of_mice_and_men), rel.related_book
      assert_predicate rel, :relation_type_contains?
    end

    test "rejects self-reference" do
      rel = Books::BookRelationship.new(book: books_books(:war_and_peace), related_book: books_books(:war_and_peace), relation_type: :contains)
      assert_not rel.valid?
      assert_includes rel.errors[:related_book_id], "cannot relate a book to itself"
    end

    test "is unique per book/related/type" do
      dup = Books::BookRelationship.new(book: books_books(:combo_steinbeck), related_book: books_books(:of_mice_and_men), relation_type: :contains)
      assert_not dup.valid?
      assert_includes dup.errors[:book_id], "has already been taken"
    end

    test "book exposes related_books" do
      assert_includes books_books(:combo_steinbeck).related_books, books_books(:of_mice_and_men)
    end

    test "containing scope filters" do
      assert_includes Books::BookRelationship.containing, books_book_relationships(:combo_contains_omam)
    end
  end
end
```

- [ ] **Step 5: Add fixtures.** Append component works to `test/fixtures/books/books.yml`:

```yaml
of_mice_and_men:
  title: Of Mice and Men
  slug: of-mice-and-men
  first_published_year: 1937
  book_kind: 0

cannery_row:
  title: Cannery Row
  slug: cannery-row
  first_published_year: 1945
  book_kind: 0
```

Replace `test/fixtures/books/book_relationships.yml`:

```yaml
combo_contains_omam:
  book: combo_steinbeck (Books::Book)
  related_book: of_mice_and_men (Books::Book)
  relation_type: 0

combo_contains_cannery:
  book: combo_steinbeck (Books::Book)
  related_book: cannery_row (Books::Book)
  relation_type: 0
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_relationship_test.rb`
Expected: FAIL (model + associations missing).

- [ ] **Step 7: Implement the model** — replace `app/models/books/book_relationship.rb`:

```ruby
class Books::BookRelationship < ApplicationRecord
  enum :relation_type, {contains: 0, abridgement_of: 1, adaptation_of: 2, revision_of: 3, related_to: 4}, prefix: true

  belongs_to :book, class_name: "Books::Book"
  belongs_to :related_book, class_name: "Books::Book"

  validates :book_id, uniqueness: {scope: [:related_book_id, :relation_type]}
  validate :no_self_reference

  scope :containing, -> { where(relation_type: :contains) }

  private

  def no_self_reference
    errors.add(:related_book_id, "cannot relate a book to itself") if book_id == related_book_id
  end
end
```

- [ ] **Step 8: Wire `Books::Book`** — add to `app/models/books/book.rb`:

```ruby
  has_many :book_relationships, class_name: "Books::BookRelationship", dependent: :destroy
  has_many :related_books, through: :book_relationships, class_name: "Books::Book"
  has_many :inverse_book_relationships, class_name: "Books::BookRelationship", foreign_key: :related_book_id, dependent: :destroy
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `bin/rails test test/models/books/book_relationship_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 10: Lint and commit**

```bash
bin/rubocop -a app/models/books/book_relationship.rb app/models/books/book.rb test/models/books/book_relationship_test.rb
git add app/models/books/book_relationship.rb app/models/books/book.rb db/migrate/*_create_books_book_relationships.rb test/models/books/book_relationship_test.rb test/fixtures/books/book_relationships.yml test/fixtures/books/books.yml db/schema.rb
git commit -m "Add Books::BookRelationship for Work-to-Work links"
```

---

## Task 12: Enable `Books::Category` book/author associations

**Files:**
- Modify: `app/models/books/category.rb`
- Test: `test/models/books/category_test.rb` (create if absent)

**Interfaces:**
- Consumes: `Books::Book`, `Books::Author`, shared `Category`/`CategoryItem`.
- Produces: `Books::Category#books`, `#authors`, and `by_book_ids`/`by_author_ids` scopes. `location`-type categories carry origin/nationality.

- [ ] **Step 1: Write the failing test** — create `test/models/books/category_test.rb`:

```ruby
require "test_helper"

module Books
  class CategoryTest < ActiveSupport::TestCase
    test "location categories associate books" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_books(:war_and_peace))
      assert_includes russia.books, books_books(:war_and_peace)
    end

    test "location categories associate authors as nationality" do
      russia = Books::Category.create!(name: "Russia", category_type: :location)
      CategoryItem.create!(category: russia, item: books_authors(:tolstoy))
      assert_includes russia.authors, books_authors(:tolstoy)
    end

    test "by_book_ids scope filters" do
      fiction = Books::Category.create!(name: "Fiction", category_type: :genre)
      CategoryItem.create!(category: fiction, item: books_books(:war_and_peace))
      assert_includes Books::Category.by_book_ids([books_books(:war_and_peace).id]), fiction
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/books/category_test.rb`
Expected: FAIL (`undefined method 'books'` on `Books::Category`).

- [ ] **Step 3: Implement** — replace `app/models/books/category.rb`:

```ruby
module Books
  class Category < ::Category
    has_many :books, through: :category_items, source: :item, source_type: "Books::Book"
    has_many :authors, through: :category_items, source: :item, source_type: "Books::Author"

    scope :by_book_ids, ->(book_ids) { joins(:category_items).where(category_items: {item_type: "Books::Book", item_id: book_ids}) }
    scope :by_author_ids, ->(author_ids) { joins(:category_items).where(category_items: {item_type: "Books::Author", item_id: author_ids}) }
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/books/category_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Full-suite regression + lint**

Run: `bin/rails test test/models/books/ test/models/language_test.rb test/models/identifier_test.rb`
Expected: PASS (all books + language + identifier tests).

```bash
bin/rubocop -a app/models/books/category.rb test/models/books/category_test.rb
```

- [ ] **Step 6: Commit**

```bash
git add app/models/books/category.rb test/models/books/category_test.rb
git commit -m "Enable Books::Category book/author associations"
```

---

## Final Verification

- [ ] **Run the full books model suite + shared:**

Run: `bin/rails test test/models/books/ test/models/language_test.rb test/models/identifier_test.rb`
Expected: all PASS, zero failures/errors.

- [ ] **Run the full CI gate:**

Run: `bin/rails db:test:prepare test test:system && bin/rubocop -f github && bin/brakeman --no-pager`
Expected: all green (this is what `.github/workflows/ci.yml` enforces).

- [ ] **Confirm schema:** `db/schema.rb` contains `languages`, `books_books`, `books_editions`, `books_authors`, `books_book_authors`, `books_credits`, `books_author_relationships`, `books_series`, `books_series_books`, `books_book_relationships`, and the reorganized `books_*` identifier enum is reflected in `app/models/identifier.rb`.

---

## Self-Review (completed during authoring)

**1. Spec coverage.** Every spec section maps to a task:
- §4.1 Book → Task 3 (+ `default_edition` Task 4, authors Task 6, series Task 10, relationships Task 11, `alternate_titles` Task 3)
- §4.2 Edition → Task 4
- §4.3 Author → Task 5 (identifiers via shared table; `alternate_names` Task 5)
- §4.4 Series (+ `representative_book`) → Tasks 9–10
- §4.5 Language → Task 1
- §5.1 BookAuthor → Task 6 · §5.2 Credit → Task 7 · §5.3 AuthorRelationship → Task 8 · §5.4 SeriesBook → Task 10 · §5.5 BookRelationship → Task 11
- §6 scenarios: `book_kind` (Task 3), `volume_number` (Task 4), Series (Tasks 9–10), `contains` (Task 11)
- §7 representative_book / non-ranked Series → Tasks 9–10 (no `ranked_items` on Series — confirmed absent)
- §8.1 identifier enum → Task 2 · §8.3 `alternate_titles` → Task 3
- §9 origin via `location` categories → Task 12 · language → Task 1
- §10 shared wiring → per-entity association steps
- §12 deferred items → **intentionally not built** (dedup/merge, importers, routing, UI, Publisher)

**2. Placeholder scan.** No TBD/TODO/"handle edge cases"/"write tests for the above"; every code and test step contains complete code.

**3. Type/name consistency.** Table names (`books_*`), enum names/values, association names (`editions`, `authors`, `books`, `series`, `related_books`, `credits`, `author_relationships`), and cross-task references (`Books::Credit` used in Task 4, defined in Task 7; `default_edition` added Task 4; `as_indexed_json` author_names updated Task 6) are consistent across tasks. Fixtures referenced in later tasks (`garnett`, `got`, `clash`, `of_mice_and_men`, `cannery_row`) are appended in the task that first needs them.

**Deferred (NOT in this plan, by design):** `work_key`, `merged_into_id`, `Books::BookMerge`, the matching/merge pipeline, importers, hostname routing, UI/Avo — all per spec §12.

