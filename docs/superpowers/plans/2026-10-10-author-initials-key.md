# Author Initials Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the books finders treat `J.D. Salinger`, `J. D. Salinger` and `J D Salinger` as one author name, without loosening anything else.

**Architecture:** One key function, `Services::Text::PersonNameKey`, folds single-letter initials on top of the finder's existing normalization. `Books::Author` stores the keys of its name and alternate names in a GIN-indexed `name_keys` column, set on save and filled by the migration that adds it. The author and book finders compare names through the key, in Ruby and in SQL, through two new `FinderBase` hooks whose defaults keep music and games exactly as they are.

**Tech Stack:** Rails 8.1, PostgreSQL arrays and GIN, Minitest + fixtures + Mocha.

**Spec:** `docs/superpowers/specs/2026-10-09-author-initials-key-design.md` (approved by Shane 2026-10-10).

## Global Constraints

- **Never match on surnames alone.** Every word other than a single-letter initial must still match.
- **The key is exactly spec §3:** `QuoteNormalizer`, then `NameNormalizer`, then `downcase`; a letter with no letter before it, followed by a full stop, becomes that letter plus a space; spaces squeezed; stripped; blank → `nil`.
- **Bare run-together initials (`JD`, `JR`) and hyphenated initials are not folded.**
- **Display names never change:** only the derived `name_keys` column is new.
- **Music and games finders behave exactly as today:** the `FinderBase` hook defaults are `normalize`.
- **Titles are not touched.** `title_key` is overridden only by the author finder, whose "title" is a person's name.
- **A failing migration is an outage.** The fill must never raise on odd stored data.
- Migrations come from `bin/rails generate migration`. Lint with `bundle exec standardrb`, never `bin/rubocop`. Never run brakeman.
- Work on branch `worktree-author-initials-key` in `/home/shane/dev/the-greatest/.claude/worktrees/author-initials-key`. Never commit to `main`. Do not push.
- **Do not edit `docs/todo.md`:** Shane has uncommitted edits to it in the main checkout.
- Run Rails commands from `web-app/`.

## Review Focus

1. **Fixture authors skip model callbacks**, so their `name_keys` would be empty and every fixture-based finder test would silently stop exact-matching. Expected: the fixtures carry the right keys, and a test fails if a fixture's keys ever drift from its names (Task 2).
2. **Folding makes two stored authors share one key.** Expected: rule 4 still needs exactly one exact candidate, so both go to the AI and neither wins by rule (Task 3).
3. **Odd stored data during the migration's fill:** blank alternate names, apostrophes and other characters that need SQL quoting. Expected: correct keys, no error (Task 2).
4. **A fill that spans batch boundaries.** Expected: every row is written once, and a second run writes nothing (Task 2).
5. **Music and games creator comparison.** Expected: unchanged, so `J.D.` and `J. D.` still disagree under the default hook (Task 3).

---

### Task 1: `PersonNameKey`

**Files:**
- Create: `web-app/app/lib/services/text/person_name_key.rb`
- Test: `web-app/test/lib/services/text/person_name_key_test.rb`

**Interfaces:**
- Produces: `Services::Text::PersonNameKey.call(text) -> String | nil` and `Services::Text::PersonNameKey.all(names) -> Array<String>` (distinct, non-nil keys, in first-seen order; `all(nil) == []`).

- [ ] **Step 1: Write the failing test**

`web-app/test/lib/services/text/person_name_key_test.rb`:

```ruby
require "test_helper"

module Services
  module Text
    class PersonNameKeyTest < ActiveSupport::TestCase
      test ".call folds single-letter initials however they are spaced or stopped" do
        {
          "J.D. Salinger" => "j d salinger",
          "J. D. Salinger" => "j d salinger",
          "J D Salinger" => "j d salinger",
          "J. D Salinger" => "j d salinger",
          "j.d. salinger" => "j d salinger",
          "e.e. cummings" => "e e cummings",
          "J.R.R. Tolkien" => "j r r tolkien"
        }.each { |name, key| assert_equal key, PersonNameKey.call(name), name }
      end

      test ".call leaves every other word alone" do
        {
          "Martin Luther King Jr." => "martin luther king jr.",
          "JD Salinger" => "jd salinger",
          "J. Salinger" => "j salinger",
          "Malcolm X" => "malcolm x",
          "Leo Tolstoy" => "leo tolstoy"
        }.each { |name, key| assert_equal key, PersonNameKey.call(name), name }
      end

      test ".call keeps apart names that differ in more than how the initials are written" do
        salinger = PersonNameKey.call("J. D. Salinger")

        assert_not_equal salinger, PersonNameKey.call("J. Salinger")
        assert_not_equal salinger, PersonNameKey.call("Salinger")
        assert_not_equal salinger, PersonNameKey.call("JD Salinger")
        assert_not_equal PersonNameKey.call("King Jr."), PersonNameKey.call("King JR")
      end

      test ".call applies the finder's normalization first: quotes, Unicode spaces and case" do
        assert_equal "flann o'brien", PersonNameKey.call("FLANN O’BRIEN")
        assert_equal "j d salinger", PersonNameKey.call("J. D. Salinger")
      end

      test ".call folds an initial in a non-Latin script the same way" do
        assert_equal "а с пушкин", PersonNameKey.call("А.С. Пушкин")
      end

      test ".call returns nil for nil, empty and blank names" do
        assert_nil PersonNameKey.call(nil)
        assert_nil PersonNameKey.call("")
        assert_nil PersonNameKey.call("   ")
      end

      test ".all keys every name once, in order, and drops blanks" do
        assert_equal ["j d salinger", "jerome david salinger"],
          PersonNameKey.all(["J.D. Salinger", "J. D. Salinger", nil, "", "Jerome David Salinger"])
        assert_equal [], PersonNameKey.all(nil)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/text/person_name_key_test.rb`
Expected: errors with `NameError: uninitialized constant Services::Text::PersonNameKey`.

- [ ] **Step 3: Write the implementation**

`web-app/app/lib/services/text/person_name_key.rb`:

```ruby
module Services
  module Text
    # The comparison key for a person's name: the finder's normalization
    # (quotes, Unicode spaces, NFKC, case), plus single-letter initials
    # folded, so "J.D. Salinger", "J. D. Salinger" and "J D Salinger" are one
    # name. Measured on the development authors (2026-10-09), the fold joined
    # 212 authors in 64 groups, all the same person, and nothing else.
    #
    # Only a single letter followed by a full stop is folded. Every other word
    # must still match: "Jr." and "JR" stay apart, "JD" is not "J. D.", and a
    # surname alone is never a name. The legacy books app matched on surnames
    # and produced many wrong authors; this key exists so nothing has to.
    class PersonNameKey
      # A letter with no letter before it, followed by a full stop.
      INITIAL = /(?<!\p{L})(\p{L})\./

      def self.call(text)
        return nil if text.nil?

        NameNormalizer.call(QuoteNormalizer.call(text.to_s)).downcase
          .gsub(INITIAL, '\1 ')
          .squeeze(" ").strip
          .presence
      end

      def self.all(names)
        Array(names).filter_map { |name| call(name) }.uniq
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/services/text/person_name_key_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/text/person_name_key.rb test/lib/services/text/person_name_key_test.rb
cd .. && git add web-app/app/lib/services/text/person_name_key.rb web-app/test/lib/services/text/person_name_key_test.rb
git commit -m "Add PersonNameKey: the finder's name normalization with initials folded"
```

---

### Task 2: The stored key (`books_authors.name_keys`)

**Files:**
- Create (generator): `web-app/db/migrate/<timestamp>_add_name_keys_to_books_authors.rb`
- Create: `web-app/app/lib/services/books/refresh_author_name_keys.rb`
- Create: `web-app/lib/tasks/books/author_name_keys.rake`
- Modify: `web-app/app/models/books/author.rb` (the `before_validation` lines near 73-74, and the private callbacks near 88-98)
- Modify: `web-app/test/fixtures/books/authors.yml` (all five fixtures)
- Modify: `web-app/db/schema.rb` (by running the migration)
- Test: `web-app/test/models/books/author_test.rb`, `web-app/test/lib/services/books/refresh_author_name_keys_test.rb`, `web-app/test/lib/tasks/books_author_name_keys_rake_test.rb`

**Interfaces:**
- Consumes: `Services::Text::PersonNameKey.all(names)` (Task 1).
- Produces: the column `books_authors.name_keys` (`character varying[]`, `null: false`, `default: []`, GIN index `index_books_authors_on_name_keys`). `Books::Author#name_keys` always equals `PersonNameKey.all([name, *alternate_names])` after a save. `Services::Books::RefreshAuthorNameKeys.call(batch_size: 2000) -> Result` with `data: {scanned: Integer, updated: Integer}`. Rake task `books:refresh_author_name_keys`.

- [ ] **Step 1: Generate the migration**

```bash
cd web-app && bin/rails generate migration AddNameKeysToBooksAuthors
```

Replace the generated body with:

```ruby
class AddNameKeysToBooksAuthors < ActiveRecord::Migration[8.1]
  # The finders read name_keys from the moment this deploy is live, so the
  # column is filled here rather than by a task run afterwards: an empty
  # column would make every exact match miss and imports create duplicates.
  def up
    add_column :books_authors, :name_keys, :string, array: true, default: [], null: false
    add_index :books_authors, :name_keys, using: :gin
    Books::Author.reset_column_information
    Services::Books::RefreshAuthorNameKeys.call
  end

  def down
    remove_index :books_authors, :name_keys
    remove_column :books_authors, :name_keys
  end
end
```

Keep the `Migration[8.1]` version the generator wrote, if it differs.

- [ ] **Step 2: Write the failing model tests**

Add inside `class AuthorTest` in `web-app/test/models/books/author_test.rb`:

```ruby
    test "saving sets name_keys from the name and alternate names, initials folded, each once" do
      author = Books::Author.create!(name: "J.D. Salinger", alternate_names: ["J. D. Salinger", "Jerome David Salinger"])

      assert_equal ["j d salinger", "jerome david salinger"], author.name_keys
    end

    test "changing the name or an alternate name updates name_keys" do
      author = Books::Author.create!(name: "J.D. Salinger")

      author.update!(name: "Jerome Salinger", alternate_names: ["J. D. Salinger"])

      assert_equal ["jerome salinger", "j d salinger"], author.reload.name_keys
    end

    # Fixtures are inserted without callbacks, so their name_keys are written
    # by hand in authors.yml. This keeps them honest.
    test "every author fixture carries the name_keys its names produce" do
      Books::Author.find_each do |author|
        assert_equal Services::Text::PersonNameKey.all([author.name, *author.alternate_names]), author.name_keys, author.name
      end
    end
```

- [ ] **Step 3: Write the failing service test**

`web-app/test/lib/services/books/refresh_author_name_keys_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    class RefreshAuthorNameKeysTest < ActiveSupport::TestCase
      test "fills stale keys, writes only the rows that changed, and reports counts" do
        stale = ::Books::Author.create!(name: "J.D. Salinger", alternate_names: ["Jerome David Salinger"])
        stale.update_columns(name_keys: [])

        result = RefreshAuthorNameKeys.call

        assert result.success?
        assert_equal ["j d salinger", "jerome david salinger"], stale.reload.name_keys
        assert_equal({scanned: ::Books::Author.count, updated: 1}, result.data)
      end

      test "a second run writes nothing" do
        ::Books::Author.create!(name: "J.D. Salinger").update_columns(name_keys: [])
        RefreshAuthorNameKeys.call

        assert_equal 0, RefreshAuthorNameKeys.call.data[:updated]
      end

      test "blank alternate names and characters that need quoting never raise" do
        lewis = ::Books::Author.create!(name: "C. S. Lewis")
        lewis.update_columns(alternate_names: ["", "   ", "C.S. Lewis"], name_keys: [])
        obrien = ::Books::Author.create!(name: "Flann O'Brien")
        obrien.update_columns(alternate_names: ["Myles na gCopaleen", "Brian O\"Nolan"], name_keys: ["stale"])

        RefreshAuthorNameKeys.call

        assert_equal ["c s lewis"], lewis.reload.name_keys
        assert_equal ["flann o'brien", "myles na gcopaleen", "brian o\"nolan"], obrien.reload.name_keys
      end

      test "every stale row is written across batch boundaries" do
        authors = 3.times.map { |i| ::Books::Author.create!(name: "A.B. Writer #{i}") }
        authors.each { |author| author.update_columns(name_keys: []) }

        RefreshAuthorNameKeys.call(batch_size: 2)

        assert_equal [["a b writer 0"], ["a b writer 1"], ["a b writer 2"]], authors.map { |author| author.reload.name_keys }
      end
    end
  end
end
```

- [ ] **Step 4: Write the failing rake test**

`web-app/test/lib/tasks/books_author_name_keys_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class BooksAuthorNameKeysRakeTest < ActiveSupport::TestCase
  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("books:refresh_author_name_keys")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/books/author_name_keys.rake").to_s }
    end
    @task = Rake::Task["books:refresh_author_name_keys"]
    @task.reenable
  end

  test "runs the refresh and prints its counts" do
    ::Services::Books::RefreshAuthorNameKeys.expects(:call).returns(
      ::Services::Books::RefreshAuthorNameKeys::Result.new(success?: true, data: {scanned: 7, updated: 2}, errors: [])
    )

    assert_output(/7 scanned, 2 updated/) { @task.invoke }
  end
end
```

- [ ] **Step 4b: Run the new tests to verify they fail**

Run: `cd web-app && bin/rails test test/models/books/author_test.rb test/lib/services/books/refresh_author_name_keys_test.rb test/lib/tasks/books_author_name_keys_rake_test.rb`
Expected: errors. `name_keys` is an unknown attribute, `RefreshAuthorNameKeys` is an uninitialized constant, and the rake file does not exist.

- [ ] **Step 5: Write the service**

`web-app/app/lib/services/books/refresh_author_name_keys.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    # Recomputes books_authors.name_keys (Services::Text::PersonNameKey over
    # the name and alternate names) for every author whose stored keys
    # differ, and writes them in batches with one UPDATE ... FROM (VALUES)
    # per batch. Books::Author keeps the column current on every save; this
    # fills it once (the migration that adds the column calls it) and again
    # only if the key rule changes (bin/rails books:refresh_author_name_keys).
    #
    # It must never raise on odd stored data: the migration runs it during a
    # deploy, and a failing migration is an outage.
    class RefreshAuthorNameKeys
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      BATCH_SIZE = 2000

      def self.call(batch_size: BATCH_SIZE)
        new(batch_size: batch_size).call
      end

      def initialize(batch_size:)
        @batch_size = batch_size
      end

      def call
        scanned = 0
        updated = 0
        ::Books::Author.in_batches(of: @batch_size) do |batch|
          rows = batch.pluck(:id, :name, :alternate_names, :name_keys)
          scanned += rows.size
          changed = rows.filter_map do |id, name, alternate_names, stored|
            keys = ::Services::Text::PersonNameKey.all([name, *Array(alternate_names)])
            [id, keys] unless keys == stored
          end
          next if changed.empty?

          write(changed)
          updated += changed.size
        end
        Result.new(success?: true, data: {scanned: scanned, updated: updated}, errors: [])
      end

      private

      def write(rows)
        connection = ::Books::Author.connection
        type = ::Books::Author.type_for_attribute(:name_keys)
        values = rows.map { |id, keys| "(#{connection.quote(id)}, #{connection.quote(type.serialize(keys))}::varchar[])" }
        connection.exec_update(<<~SQL.squish, "RefreshAuthorNameKeys")
          UPDATE books_authors SET name_keys = v.keys
          FROM (VALUES #{values.join(", ")}) AS v(id, keys)
          WHERE books_authors.id = v.id
        SQL
      end
    end
  end
end
```

- [ ] **Step 6: Write the rake task**

`web-app/lib/tasks/books/author_name_keys.rake`:

```ruby
# frozen_string_literal: true

namespace :books do
  desc "Recompute every author's name_keys (the finders' initials-folded name keys). " \
    "Only needed if Services::Text::PersonNameKey's rule changes; saves keep the column current."
  task refresh_author_name_keys: :environment do
    data = Services::Books::RefreshAuthorNameKeys.call.data
    puts "authors: #{data[:scanned]} scanned, #{data[:updated]} updated"
  end
end
```

- [ ] **Step 7: Set the keys on save**

In `web-app/app/models/books/author.rb`, add a third callback **after** the two existing normalizers (it reads their output):

```ruby
  before_validation :normalize_name
  before_validation :normalize_alternate_names
  before_validation :set_name_keys
```

and with the other private callbacks:

```ruby
  # The finders' exact match compares these, GIN-indexed (see
  # Services::Text::PersonNameKey). Every write to name or alternate_names
  # saves through the model, so the keys cannot go stale.
  def set_name_keys
    self.name_keys = Services::Text::PersonNameKey.all([name, *Array(alternate_names)])
  end
```

- [ ] **Step 8: Give the fixtures their keys**

In `web-app/test/fixtures/books/authors.yml`, add a `name_keys` line to each fixture:

```yaml
tolstoy:
  # ...existing lines...
  name_keys: ["leo tolstoy", "lev tolstoy", "lev nikolayevich tolstoy"]

king:
  # ...
  name_keys: ["stephen king"]

bachman:
  # ...
  name_keys: ["richard bachman"]

garnett:
  # ...
  name_keys: ["constance garnett"]

excluded_placeholder:
  # ...
  name_keys: ["unknown"]
```

- [ ] **Step 9: Run the migration**

```bash
cd web-app && bin/rails db:migrate
```

Expected: the migration finishes in under a minute; it fills the shared development database's ~72k authors, which only adds data. `git diff db/schema.rb` shows `t.string "name_keys", default: [], null: false, array: true` and `t.index ["name_keys"], name: "index_books_authors_on_name_keys", using: :gin`. If annotaterb rewrites schema comments in models, fixtures or tests, keep those changes. If annotaterb errors because the legacy database is missing, re-run with `ANNOTATERB_SKIP_ON_DB_TASKS=1`.

Then confirm nothing was left empty:

```bash
bin/rails runner 'puts Books::Author.where(name_keys: []).count'
```

Expected: `0`.

- [ ] **Step 10: Run the tests**

```bash
bin/rails test test/models/books/author_test.rb test/lib/services/books/refresh_author_name_keys_test.rb test/lib/tasks/books_author_name_keys_rake_test.rb test/lib/data_importers/books/
```

Expected: all pass. The finder tests run here only as a regression check: they still compare `LOWER(name)` until Task 3.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb app/models/books/author.rb app/lib/services/books/refresh_author_name_keys.rb lib/tasks/books/author_name_keys.rake db/migrate test/models/books/author_test.rb test/lib/services/books/refresh_author_name_keys_test.rb test/lib/tasks/books_author_name_keys_rake_test.rb
cd .. && git add -A web-app/db web-app/app web-app/lib web-app/test
git commit -m "Store each author's name keys, set on save and filled by the migration"
```

---

### Task 3: `FinderBase` hooks and the author finder

**Files:**
- Modify: `web-app/app/lib/data_importers/finder_base.rb` (`titles_agree?` and `creators_agree?` at lines 34-46; new hooks in the `protected` section after `record_creator_alternate_names`, near line 181)
- Modify: `web-app/app/lib/data_importers/books/author/finder.rb` (new `title_key` in the `protected` section; `exact_scope` and its comment at lines 107-122)
- Test: `web-app/test/lib/data_importers/finder_base_test.rb`, `web-app/test/lib/data_importers/books/author/finder_test.rb`

**Interfaces:**
- Consumes: `Services::Text::PersonNameKey.call` and `.all` (Task 1); `books_authors.name_keys` (Task 2).
- Produces: protected `DataImporters::FinderBase#title_key(text)` and `#creator_key(text)`, both defaulting to `normalize(text)`. Task 4 overrides `creator_key` in the book finder.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/data_importers/finder_base_test.rb`, under `# ---- agreement judgements`:

```ruby
    # TestFinder keeps the default hooks, as the music and games finders do.
    test "the default keys are normalize: initials written differently do not agree" do
      author = ::Books::Author.create!(name: "J. D. Salinger")
      book = ::Books::Book.create!(title: "Nine Stories")
      ::Books::BookAuthor.create!(book: book, author: author, position: 1)

      assert_not @finder.creators_agree?({creators: ["J.D. Salinger"]}, book)
      assert @finder.creators_agree?({creators: ["j. d. salinger"]}, book)
      assert_not @finder.titles_agree?({title: "Nine  Stories."}, book)
    end
```

In `web-app/test/lib/data_importers/books/author/finder_test.rb`, under `# ---- exact (rule 4)`:

```ruby
        test "initials written differently are the same name for the exact rule, by name and by alternate name" do
          salinger = ::Books::Author.create!(name: "J. D. Salinger")
          tolkien = ::Books::Author.create!(name: "John Ronald Reuel Tolkien", alternate_names: ["J.R.R. Tolkien"])
          expect_no_ai

          assert_equal [salinger, :rule], @finder.call(query: ImportQuery.new(name: "J.D. Salinger")).then { |m| [m.record, m.decided_by] }
          assert_equal [tolkien, :rule], @finder.call(query: ImportQuery.new(name: "J R R Tolkien")).then { |m| [m.record, m.decided_by] }
        end

        test "a different set of initials, a bare surname or run-together initials is not the same name" do
          ::Books::Author.create!(name: "J. D. Salinger")
          expect_no_ai

          ["J. Salinger", "Salinger", "JD Salinger"].each do |name|
            assert_nil @finder.call(query: ImportQuery.new(name: name)).record, name
          end
        end

        test "a multi-letter word is not an initial: Jr. and JR stay apart" do
          ::Books::Author.create!(name: "Walter M. Miller Jr.")
          expect_no_ai

          assert_nil @finder.call(query: ImportQuery.new(name: "Walter M. Miller JR")).record
          assert_equal :rule, @finder.call(query: ImportQuery.new(name: "Walter M Miller Jr.")).decided_by
        end

        test "two authors whose names differ only in how the initials are written both go to the AI" do
          a = ::Books::Author.create!(name: "J.D. Smith")
          b = ::Books::Author.create!(name: "J. D. Smith")
          TASK.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "medium", reasoning: "Two people.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: ImportQuery.new(name: "J D Smith"))

          assert_equal :ai, match.decided_by
          assert_includes [a, b], match.record
        end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/data_importers/finder_base_test.rb test/lib/data_importers/books/author/finder_test.rb`
Expected: the new author-finder tests fail: `J.D. Salinger` finds no candidate, and the two Smiths do not both reach the AI. The new `FinderBase` test already passes, because it pins today's behaviour.

- [ ] **Step 3: Add the hooks to `FinderBase`**

In `web-app/app/lib/data_importers/finder_base.rb`, change `titles_agree?` and `creators_agree?` to:

```ruby
    def titles_agree?(query, record)
      wanted = title_key(query_title(query))
      return false if wanted.blank?

      ([record_title(record)] + record_alternate_titles(record)).any? { |title| title_key(title) == wanted }
    end

    def creators_agree?(query, record)
      wanted = query_creators(query).map { |name| creator_key(name) }.compact_blank
      return false if wanted.empty?

      held = (record_creators(record) + record_creator_alternate_names(record)).map { |name| creator_key(name) }.compact_blank
      (wanted & held).any?
    end
```

In the `protected` section, after `record_creator_alternate_names`, add:

```ruby
    # How titles and creator names compare. A domain whose titles are
    # people's names (books authors) or whose creators are people (books)
    # overrides these with Services::Text::PersonNameKey; music and games
    # keep plain normalize.
    def title_key(text) = normalize(text)

    def creator_key(text) = normalize(text)
```

- [ ] **Step 4: Use the key in the author finder**

In `web-app/app/lib/data_importers/books/author/finder.rb`, add to the `protected` section (after `def model_class = ::Books::Author`):

```ruby
        # An author's "title" is its name and alternate names.
        def title_key(text) = ::Services::Text::PersonNameKey.call(text)
```

Replace `exact_scope` and its comment with:

```ruby
        # The query's name and alternate names against every stored name and
        # alternate name, compared as Services::Text::PersonNameKey keys
        # through the GIN-indexed books_authors.name_keys, so initials written
        # differently still meet. Ids are plucked first, as in the books
        # finder, so no ORDER BY + LIMIT steers the planner.
        def exact_scope(query)
          keys = ::Services::Text::PersonNameKey.all([query.name, *query.alternate_names])
          return ::Books::Author.none if keys.empty?

          ids = ::Books::Author.where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
            .pluck(:id).sort.first(EXACT_LIMIT)
          ::Books::Author.where(id: ids).includes(:identifiers).order(:id)
        end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/data_importers/`
Expected: all pass, including the existing curly-apostrophe and alternate-name tests, which now run through the new SQL.

- [ ] **Step 6: Check the index is used**

```bash
bin/rails runner 'puts ActiveRecord::Base.connection.select_values("EXPLAIN ANALYZE SELECT id FROM books_authors WHERE name_keys && ARRAY[$$j d salinger$$]::varchar[]")'
```

Expected: a `Bitmap Index Scan on index_books_authors_on_name_keys`, in a few milliseconds or less. If the plan shows a sequential scan, run `bin/rails runner 'ActiveRecord::Base.connection.execute("ANALYZE books_authors")'` and check again.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/finder_base.rb app/lib/data_importers/books/author/finder.rb test/lib/data_importers/finder_base_test.rb test/lib/data_importers/books/author/finder_test.rb
cd .. && git add web-app/app/lib/data_importers web-app/test/lib/data_importers
git commit -m "Author finder compares names by PersonNameKey through name_keys"
```

---

### Task 4: The book finder

**Files:**
- Modify: `web-app/app/lib/data_importers/books/book/finder.rb` (new `creator_key` in the `protected` section near line 91; the author half of `exact_scope` at lines 130-142)
- Test: `web-app/test/lib/data_importers/books/book/finder_test.rb`

**Interfaces:**
- Consumes: `FinderBase#creator_key` (Task 3), `PersonNameKey` (Task 1), `name_keys` (Task 2).
- Produces: book-finder agreement and exact lookup across initials spellings. `Services::Books::GoodreadsReplay::CompareEdition` calls `creators_agree?` on this finder and picks the change up with no edit.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/data_importers/books/book/finder_test.rb`, after the test `"the query is normalized the way the models store titles and names"`:

```ruby
        test "an author's initials written differently still make an exact title-and-author match" do
          author = ::Books::Author.create!(name: "J. D. Salinger")
          book = ::Books::Book.create!(title: "Nine Stories")
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Nine Stories", author_names: ["J.D. Salinger"]))

          assert_equal [book, :high, :rule], [match.record, match.confidence, match.decided_by]
        end

        test "creators_agree? folds initials but the same title by different initials is no match" do
          author = ::Books::Author.create!(name: "J. D. Salinger")
          book = ::Books::Book.create!(title: "Nine Stories")
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)
          expect_no_ai

          assert @finder.creators_agree?(ImportQuery.new(title: "Nine Stories", author_names: ["J D Salinger"]), book)
          assert_not @finder.creators_agree?(ImportQuery.new(title: "Nine Stories", author_names: ["J. Salinger"]), book)
          assert_nil @finder.call(query: ImportQuery.new(title: "Nine Stories", author_names: ["J. Salinger"])).record
        end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/data_importers/books/book/finder_test.rb`
Expected: both new tests fail. The first finds no exact candidate. The second fails on the `J D Salinger` agreement.

- [ ] **Step 3: Use the key in the book finder**

In `web-app/app/lib/data_importers/books/book/finder.rb`, add to the `protected` section next to `query_creators`:

```ruby
        # Authors are people: initials written differently are one name.
        def creator_key(text) = ::Services::Text::PersonNameKey.call(text)
```

In `exact_scope`, replace the author half:

```ruby
          keys = ::Services::Text::PersonNameKey.all(query.author_names)
          if keys.any?
            filtered = filtered.joins(book_authors: :author)
              .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
          end
```

and change the comment's second sentence to read: "joined to an author whose name keys (Services::Text::PersonNameKey, GIN-indexed books_authors.name_keys) meet the query's when the query names authors." Leave the title half (`LOWER(books_books.title) = ?` with `normalize`) as it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/data_importers/ test/lib/services/books/goodreads_replay/`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/data_importers/books/book/finder.rb test/lib/data_importers/books/book/finder_test.rb
cd .. && git add web-app/app/lib/data_importers/books/book/finder.rb web-app/test/lib/data_importers/books/book/finder_test.rb
git commit -m "Book finder compares author names by PersonNameKey"
```

---

### Task 5: The wizard adapter, the backfill's author keys, and the docs

**Files:**
- Modify: `web-app/app/lib/services/lists/wizard/books/adapter.rb` (`book_created_from_text_since_match`, lines ~164-182)
- Modify: `web-app/app/lib/services/books/ol_backfill/author_keys.rb` (`key_for`, lines ~49-56)
- Modify: `docs/features/import-finder.md` (the corroboration and exact-match paragraph near line 78, the Sources paragraph near line 86, and a new section)
- Test: `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`, `web-app/test/lib/services/books/ol_backfill/author_keys_test.rb`

**Interfaces:**
- Consumes: `PersonNameKey` (Task 1).
- Produces: no new interface.

- [ ] **Step 1: Write the failing tests**

In `web-app/test/lib/services/lists/wizard/books/adapter_test.rb`, after `"recheck for a text row ignores a book made before its match, or by someone else"`:

```ruby
          test "recheck for a text row agrees on an author whose initials are written differently" do
            row = wizard_row(@list, position: 1, title: "Nine Stories", authors: ["J.D. Salinger"],
              wizard: {bucket: "create", matched_at: 1.hour.ago.iso8601})
            author = ::Books::Author.create!(name: "J. D. Salinger")
            book = ::Books::Book.create!(title: "Nine Stories")
            book.book_authors.create!(author: author, position: 1)

            assert_equal book, @adapter.recheck(row)
          end
```

In `web-app/test/lib/services/books/ol_backfill/author_keys_test.rb`, after `"an alternate name pairs an author"`:

```ruby
        test "a work author whose initials are written differently pairs the author" do
          salinger = ::Books::Author.create!(name: "J. D. Salinger")
          book = ::Books::Book.create!(title: "Nine Stories")
          book.book_authors.create!(author: salinger, position: 1)
          work = ol_work("OL2W", title: "Nine Stories", authors: [["OL57A", "J.D. Salinger"]])

          assert_equal [[salinger.id, "OL57A"]], AuthorKeys.call(book: book, work: work)["added"]
        end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/books/ol_backfill/author_keys_test.rb`
Expected: both new tests fail. The adapter returns `nil`, and `AuthorKeys` returns `[]`.

- [ ] **Step 3: Use the key in the adapter**

In `book_created_from_text_since_match`, the title keeps `Signature.normalize`; the author names use the key:

```ruby
            title = ::Services::Lists::Wizard::Core::Signature.normalize(metadata["title"])
            names = ::Services::Text::PersonNameKey.all(metadata["authors"])
            return nil if title.blank? || names.empty?
```

and in the `find` block:

```ruby
                ::Services::Lists::Wizard::Core::Signature.normalize(book.title) == title &&
                  ::Services::Text::PersonNameKey.all(book.authors.flat_map { |author| [author.name, *Array(author.alternate_names)] })
                    .intersect?(names)
```

Update the method's comment: the title comparison uses the wizard's own normalization; author names compare by `Services::Text::PersonNameKey`, so initials written differently agree.

- [ ] **Step 4: Use the key in `AuthorKeys#key_for`**

```ruby
        # The key of the one work author whose name agrees (initials folded,
        # Services::Text::PersonNameKey), or nil.
        def key_for(author)
          names = ::Services::Text::PersonNameKey.all([author.name, *Array(author.alternate_names)])
          names_on_work = Array(@work.author_names)
          keys_on_work = Array(@work.author_keys)
          keys = names_on_work.each_index.select { |index| names.include?(::Services::Text::PersonNameKey.call(names_on_work[index])) }
            .filter_map { |index| keys_on_work[index] }.uniq
          keys.first if keys.size == 1
        end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/lists/wizard/ test/lib/services/books/ol_backfill/`
Expected: all pass.

- [ ] **Step 6: Update the feature doc**

In `docs/features/import-finder.md`:

1. At the end of the paragraph that defines **Exact match** (rule 4), add:

   > For books authors, names compare by `Services::Text::PersonNameKey`: the same normalization,
   > plus single-letter initials folded, so `J.D.`, `J. D.` and `J D` are one spelling. Every other
   > word must still match. There is no surname-only matching. That shortcut is what gave the
   > legacy books app its wrong authors.

2. In the Sources paragraph, change "the `lower(title)`/`lower(name)` expression indexes serve it" to "the `lower(title)` expression index and, for books authors, the GIN-indexed `books_authors.name_keys` serve it".

3. Add a section after the Sources section:

   ```markdown
   ## Author name keys

   `books_authors.name_keys` holds the `PersonNameKey` of an author's name and each alternate name,
   GIN-indexed. `Books::Author` sets it on every save. The migration that added it filled it in
   place, so it was complete the moment the finders began reading it. Both books finders match on
   it (`name_keys && ARRAY[...]`). So do their creator and name agreement, the list wizard's
   created-since-Match re-check, and the Open Library backfill's author-key step.
   `bin/rails books:refresh_author_name_keys` recomputes it. It is needed only if the key rule
   changes. Bare run-together initials (`JD`) and hyphenated ones (`J.-P.`) are not folded.
   Existing authors that differ only in their initials are left to
   `bin/rails books:goodreads_replay:duplicates`.
   ```

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/lists/wizard/books/adapter.rb app/lib/services/books/ol_backfill/author_keys.rb test/lib/services/lists/wizard/books/adapter_test.rb test/lib/services/books/ol_backfill/author_keys_test.rb
cd .. && git add web-app/app/lib/services web-app/test/lib/services docs/features/import-finder.md
git commit -m "Wizard re-check and backfill author keys fold initials; document the name key"
```

---

### Task 6: Whole-branch verification

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `cd web-app && bin/rails test`
Expected: 0 failures, 0 errors, and no new warning lines. If parallel workers hang at startup, check `pg_stat_activity` for stale sessions on this worktree's test databases before blaming the workers. If the unix socket path is too long, use `TMPDIR=/home/shane/.cache/aik`.

- [ ] **Step 2: Lint and zeitwerk**

Run: `bundle exec standardrb && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; "All is good!".

- [ ] **Step 3: Spot-check on the development data (read-only)**

```bash
bin/rails runner 'f = DataImporters::Books::Author::Finder.new; ["J.D. Salinger", "J D Salinger", "G.K. Chesterton"].each { |n| m = f.send(:exact_scope, DataImporters::Books::Author::ImportQuery.new(name: n)); puts "#{n}: #{m.map(&:name).uniq.inspect} (#{m.size})" }'
```

Expected: each query returns the authors stored under every spelling of those initials, for example both "J. D. Salinger" and "J.D. Salinger" rows. This reads only.
