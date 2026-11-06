# Books Genre Cleanup (PR 1: the code) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship everything the genre cleanup needs except the reviewed data files: a new `audience` category type supported across the books site, a `split` cleanup action, the plan-file tooling (`categories:genres:*`), and the WorldCat and legacy-sync changes, all inert until a plan file exists.

**Architecture:** One committed YAML plan (`config/books/genre_plan.yml`) plus a CSV of per-book split answers drive everything. A validator checks the plan against the live genres, a builder turns it into `CategoryCleanupDecision` rows (stage `genres`), and the existing `Services::CategoryCleanup::Applier` applies them, extended with a `split` action and "extra targets" for keep/rename. Audience is a sixth `category_type` that scores exactly as a genre (one constant on `Books::Book` maps category type to scoring bucket) and shows as its own group everywhere types are shown.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, PostgreSQL, OpenSearch, `OpenAI::BaseModel` response schemas, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md`. This plan covers PR 1 only (spec §9 step 1). PR 2 (the generated files) is produced by running the commands this plan builds; it has no code.

## Global Constraints

- All Rails commands run from `web-app/`. Docs live in `docs/` at the repo root.
- Lint is `bundle exec standardrb` (never `bin/rubocop`). Never run brakeman.
- Never run anything destructive against the development database; the plan's commands are not run against dev in PR 1 at all. Tests use the per-worktree test DB.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`.
- Services return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- AI response schemas are `OpenAI::BaseModel` subclasses; `to_json_schema` is a class method. Stub all AI calls in tests (Mocha); no test makes a network call.
- Rails 8 enum syntax: `enum :name, {...}`.
- Generators for migrations: `bin/rails generate migration ...`.
- The four protected book-type genres (`Fiction`, `Nonfiction`, `Religion & Spirituality`, `Poetry`; `Books::Category.protected_ids`) are never renamed, retyped, merged, split or deleted.
- The audiences are exactly `Children's`, `Middle Grade`, `Young Adult` (spec §2). Nothing is ever tagged Adult.
- Audience scores exactly as a genre in similar books and recommendations (spec §6).
- Soft deletes only (`Categories::Deleter` with `soft: true`, `Categories::Merger`).
- PR 1 must work with zero audience categories and with no plan file.
- Commit after each task. Never commit to `main`; the branch is `worktree-books-genre-cleanup`. Do not push.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Rulings made while planning (record in the spec in Task 15)

- **No `audience_category_ids` index field.** Nothing would query it (filters use `category_ids`, scoring uses `genre_category_ids`), and adding a mapped field to the live index needs a rebuild. Audience ids go into `category_ids` and `genre_category_ids`.
- **The taste panel shows audiences under Genres**, because recommendations see them as genres. Labelling them separately would mean carrying the real type through the profile for no scoring benefit.
- **Off-list names are rejected by validation, not schema enums.** `OpenAI::BaseModel` classes are static; the map task fails the whole batch on any off-list name (as `WorldCatGenreMappingTask` does), and the batch is retried on the next run.
- **Sample titles use the existing `Services::CategoryCleanup::SampleTitles`** (oldest ids, which skew towards well-known books), not "highest-ranked".
- **The subject cleanup prompt keeps deleting audience-named subjects**, and now says why (audience is its own type). Merging across types from the subject pass is out of scope.
- **Search placeholders stay "Search genres, subjects, settings"** (14 Playwright selectors depend on them); only the modal's axis hint changes.
- **The spec's "no merge or split target is itself merged, split, retyped or deleted" check is dropped.** Targets are list entries, and list entries are produced only by keep, rename, renaming split, or audience retype, so a merge into an audience-retyped category (`teen` into Young Adult) is legitimate.

## Review Focus

1. A combined genre whose split answers drop the primary for some books (*The Lord of the Rings* answered "Fantasy" only, primary Science Fiction): those books must not end on the primary in either split mode, and must keep Fantasy. Pinned in Task 6.
2. Applying the plan a second time, including after a crash mid-apply: no duplicate decisions, no duplicate links, no error. Pinned in Task 10.
3. A genre added to production after the plan was written: `apply` stops, names it, and writes nothing. Pinned in Task 9 and Task 10.
4. A saved search that included a deleted genre: after apply it still returns results (the id is gone from its criteria), and a search that never used it is untouched. Pinned in Task 10.
5. A book already carrying the Children's audience versus one with only weak WorldCat "Juvenile fiction" evidence: the first keeps it (no duplicate), the second does not get it. Pinned in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/category.rb` | add `audience: 6` |
| `app/models/books/book.rb` | `SCORING_TYPE_OF`, `scoring_type`, indexing |
| `app/lib/search/books/search/book_similar.rb` | bucket by scoring type |
| `app/lib/recommendations/books/adapter.rb` | bucket by scoring type |
| `app/lib/books/filter_facets_query.rb`, `filter_title.rb`, `app/components/books/filter_modal_component.rb` | audience in the modal and titles |
| `app/lib/books/saved_search_filter_labels.rb` | copy |
| `app/controllers/books/books_controller.rb` | book page order |
| `app/lib/csv_exports/books/ranked_book_row.rb` | Audiences column |
| `config/api/v1/openapi.yaml` | document `audience` |
| `app/lib/books/browse_query.rb`, `browse_path.rb`, `app/controllers/books/browse_controller.rb`, `app/components/books/browse_toolbar_component.rb`, `config/routes.rb` | `/categories/audiences` |
| `app/lib/books/global_canon_params.rb`, `app/controllers/books/global_canon_controller.rb`, `app/views/books/global_canon/show.html.erb` | audience exclusions, old slugs 301 |
| `db/migrate/*_add_split_columns_to_category_cleanup_decisions.rb`, `app/models/category_cleanup_decision.rb` | `split`, `extra_target_ids`, `split_assignments`, stage `genres` |
| `app/lib/services/category_cleanup/applier.rb` | `apply_split`, extra links on keep/rename |
| `app/lib/services/books_migration/category_item_migrator.rb` | extra targets for new legacy links |
| `app/lib/books/world_cat/genre_map.rb`, `app/lib/services/books/world_cat/{apply_categories,apply_aliases,mapping_report}.rb` | audience verdicts, `also:`, weak Juvenile |
| `app/lib/services/books/genre_plan/plan_file.rb` | load/write the YAML plan |
| `app/lib/services/books/genre_plan/assignments.rb` | load/append the split CSV |
| `app/lib/services/books/genre_plan/references.rb` | saved-search reference counts |
| `app/lib/services/books/genre_plan/validator.rb` | the spec §4 checks |
| `app/lib/services/books/genre_plan/decision_builder.rb` | plan -> decisions |
| `app/lib/services/books/genre_plan/criteria_cleaner.rb` | strip deleted ids from criteria |
| `app/lib/services/books/genre_plan/apply.rb` | validate, build, apply, clean |
| `app/lib/services/ai/tasks/books/genre_{draft,map,split_check}_task.rb` | the three prompts |
| `app/lib/services/books/genre_plan/{draft,map,split_check}.rb` | drive the tasks, write files |
| `app/lib/services/books/genre_plan/{report,retarget_world_cat}.rb` | review output, WorldCat map rewrite |
| `lib/tasks/genre_cleanup.rake` | `categories:genres:*` |
| `app/lib/services/ai/tasks/category_cleanup/subject_task.rb` | prompt wording |
| `docs/features/books-categories.md`, `docs/launch-todo.md`, the spec | docs |

---

### Task 1: The audience type, and audience scoring as a genre in the index

**Files:**
- Modify: `app/models/category.rb:46`
- Modify: `app/models/books/book.rb:66-81` (constants), `:218-241` (`similarity_category_count`, `as_indexed_json`)
- Test: `test/models/books/book_test.rb`, `test/models/category_test.rb`

**Interfaces:**
- Produces: `Category.category_types["audience"] == 6`; scopes `Category.audience`, `#audience?`; `Books::Book::SCORING_TYPE_OF` (Hash type -> bucket), `Books::Book::SCORED_CATEGORY_TYPES` (`%w[genre audience subject location]`), `Books::Book::GENRE_SCORED_TYPES` (`%w[genre audience]`), `Books::Book.scoring_type(category_type) -> "genre" | "subject" | "location" | nil`. `SIMILARITY_CATEGORY_TYPES` stays `%w[genre subject location]` (the buckets).

- [ ] **Step 1: Write the failing tests**

Add to `test/models/books/book_test.rb` (after "as_indexed_json counts only the categories that score"):

```ruby
    test "an audience category indexes and counts as a genre" do
      book = books_books(:crime_and_punishment)
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
      CategoryItem.create!(category: audience, item: book)
      book.reload
      json = book.as_indexed_json

      assert_includes json[:genre_category_ids], audience.id
      assert_includes json[:category_ids], audience.id
      assert_equal 4, json[:similarity_category_count]
    end

    test "scoring_type buckets audience with genre and ignores unscored types" do
      assert_equal "genre", Books::Book.scoring_type("audience")
      assert_equal "genre", Books::Book.scoring_type(:genre)
      assert_equal "subject", Books::Book.scoring_type("subject")
      assert_equal "location", Books::Book.scoring_type("location")
      assert_nil Books::Book.scoring_type("theme")
    end
```

Add to `test/models/category_test.rb`:

```ruby
  test "audience is category type 6" do
    assert_equal 6, Category.category_types["audience"]
  end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/models/books/book_test.rb test/models/category_test.rb`
Expected: FAIL (`'audience' is not a valid category_type`, `undefined method 'scoring_type'`).

- [ ] **Step 3: Implement**

`app/models/category.rb:46`:

```ruby
  enum :category_type, {genre: 0, location: 1, subject: 2, theme: 3, game_mode: 4, player_perspective: 5, audience: 6}
```

`app/models/books/book.rb`, replace the `SIMILARITY_CATEGORY_TYPES` block (keep its comment) with:

```ruby
  # The scoring buckets of similarity and recommendations. Books carry no
  # `theme` categories today; counting only the scoring types keeps
  # similarity_category_count honest if that changes.
  SIMILARITY_CATEGORY_TYPES = %w[genre subject location].freeze

  # Category type -> the bucket it scores in. Audience scores exactly as a
  # genre (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §6):
  # Children's, Middle Grade and Young Adult were genres until the genre
  # cleanup, and similar books and recommendations were tuned with them in.
  SCORING_TYPE_OF = {"genre" => "genre", "audience" => "genre", "subject" => "subject", "location" => "location"}.freeze
  SCORED_CATEGORY_TYPES = SCORING_TYPE_OF.keys.freeze
  GENRE_SCORED_TYPES = SCORING_TYPE_OF.select { |_type, bucket| bucket == "genre" }.keys.freeze

  def self.scoring_type(category_type) = SCORING_TYPE_OF[category_type.to_s]
```

`similarity_category_count`:

```ruby
  def similarity_category_count
    categories.count do |c|
      c.deleted == false &&
        self.class.scoring_type(c.category_type) &&
        !(c.category_type == "genre" && BOOK_TYPE_CATEGORY_NAMES.include?(c.name))
    end
  end
```

`as_indexed_json`, the first lines and the genre line:

```ruby
    active = categories.select { |c| c.deleted == false }
    scored = active.select { |c| self.class.scoring_type(c.category_type) }
    ...
      genre_category_ids: scored.select { |c| self.class.scoring_type(c.category_type) == "genre" }.map(&:id),
```

(`subject_category_ids` and `location_category_ids` are unchanged.)

- [ ] **Step 4: Run them to see them pass**

Run: `bin/rails test test/models/books/book_test.rb test/models/category_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/category.rb app/models/books/book.rb test/models/books/book_test.rb test/models/category_test.rb
git commit -m "Books: audience category type, scored as a genre in the index

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Similar books and recommendations treat audience as a genre

**Files:**
- Modify: `app/lib/search/books/search/book_similar.rb:70-86` (`categories_by_type`), `:117-124` (`restore_rarest_genre_if_ceiling_emptied_genres`)
- Modify: `app/lib/recommendations/books/adapter.rb:11`, `:48-62` (`categories_for`), `:85-87` (`item_facts`)
- Test: `test/lib/search/books/search/book_similar_test.rb`, `test/lib/recommendations/books/adapter_test.rb`

**Interfaces:**
- Consumes: `Books::Book.scoring_type`, `SCORED_CATEGORY_TYPES`, `GENRE_SCORED_TYPES` (Task 1).
- Produces: `CategoryFact#category_type` is the scoring bucket (`"genre"` for an audience).

- [ ] **Step 1: Write the failing tests**

`test/lib/search/books/search/book_similar_test.rb`:

```ruby
        test "an audience category on the source scores in the genre bucket" do
          audience = ::Books::Category.create!(name: "Young Adult", category_type: :audience, item_count: 10)
          CategoryItem.create!(category: audience, item: @book)
          @book.reload

          by_type = BookSimilar.categories_by_type(@book, {max_categories_per_type: 10, drop_common_categories: false})

          assert_includes by_type["genre"].map(&:id), audience.id
          refute by_type.key?("audience")
        end
```

`test/lib/recommendations/books/adapter_test.rb`:

```ruby
      test "categories_for reports an audience as a genre" do
        book = books_books(:crime_and_punishment)
        audience = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
        CategoryItem.create!(category: audience, item: book)

        fact = @adapter.categories_for([book.id]).fetch(book.id).find { |f| f.id == audience.id }

        assert_equal "genre", fact.category_type
      end

      test "item_facts count an audience among the genre ids" do
        audience = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
        CategoryItem.create!(category: audience, item: books_books(:got))

        assert_includes @adapter.item_facts([books_books(:got).id])[books_books(:got).id].genre_ids, audience.id
      end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb test/lib/recommendations/books/adapter_test.rb`
Expected: FAIL (audience missing from the genre bucket; `fact` is nil).

- [ ] **Step 3: Implement**

`book_similar.rb` `categories_by_type`, replace the `by_type` block:

```ruby
          by_type = ::Books::Book::SIMILARITY_CATEGORY_TYPES.index_with do |type|
            select_categories(active.select { |c| ::Books::Book.scoring_type(c.category_type) == type }, opts)
          end
```

and in `restore_rarest_genre_if_ceiling_emptied_genres`:

```ruby
          rarest_genre = active.select { |c| ::Books::Book.scoring_type(c.category_type) == "genre" }.min_by { |c| [c.item_count.to_i, c.id] }
```

Update the comment above `by_type` to say the buckets come from `Books::Book.scoring_type`, so an audience lands in `"genre"`.

`adapter.rb`:

```ruby
      SCORING_TYPES = ::Books::Book::SCORED_CATEGORY_TYPES
```

In `categories_for`, the fact's type:

```ruby
            CategoryFact.new(id: id, category_type: ::Books::Book.scoring_type(type_name(type)),
              item_count: ranked_counts ? ranked_counts.fetch(id, 0) : count.to_i)
```

In `item_facts`:

```ruby
          .where(categories: {deleted: false, category_type: ::Books::Book::GENRE_SCORED_TYPES})
```

- [ ] **Step 4: Run them, then the neighbouring suites**

Run: `bin/rails test test/lib/search/books/search/book_similar_test.rb test/lib/recommendations/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/search/books/search/book_similar.rb app/lib/recommendations/books/adapter.rb test/lib/search/books/search/book_similar_test.rb test/lib/recommendations/books/adapter_test.rb
git commit -m "Books: similar books and recommendations score audience as a genre

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Audience in the filter modal, page titles, labels, book page, CSV and API

**Files:**
- Modify: `app/lib/books/filter_facets_query.rb:51-62`
- Modify: `app/lib/books/filter_title.rb:30-37`
- Modify: `app/components/books/filter_modal_component.rb:4`
- Modify: `app/lib/books/saved_search_filter_labels.rb:19-20,37-38`
- Modify: `app/controllers/books/books_controller.rb:15`
- Modify: `app/lib/csv_exports/books/ranked_book_row.rb:12-13,38-40,58-60`
- Modify: `config/api/v1/openapi.yaml` (the books `categories[].category_type` property)
- Test: `test/lib/books/filter_facets_query_test.rb`, `test/lib/books/filter_title_test.rb`, `test/lib/books/saved_search_filter_labels_test.rb`, `test/controllers/books/books_controller_test.rb`, the ranked-book CSV row test (find it with `grep -rln "RankedBookRow" test`)

**Interfaces:**
- Consumes: `Category.category_types["audience"]` (Task 1).
- Produces: `FilterFacetsQuery#genre_facet` returns genre and audience rows; `RankedBookRow::HEADERS` gains `"Audiences"` after `"Genres"`.

- [ ] **Step 1: Write the failing tests**

`test/lib/books/filter_title_test.rb`, add a helper next to the others and three tests:

```ruby
    def audience(name) = Books::Category.new(name: name, category_type: :audience)

    test "an audience alone reads as an audience of books" do
      assert_equal "The Greatest Young Adult Books of All Time", Books::FilterTitle.call(categories: [audience("Young Adult")])
    end

    test "an audience comes before the genre" do
      title = Books::FilterTitle.call(categories: [genre("Fantasy"), audience("Middle Grade")])

      assert_equal "The Greatest Middle Grade Fantasy Books of All Time", title
    end

    test "a plural genre after an audience still drops the word Books" do
      assert_equal "The Greatest Young Adult Novels of All Time", Books::FilterTitle.call(categories: [audience("Young Adult"), genre("Novels")])
    end
```

`test/lib/books/filter_facets_query_test.rb`: the existing test at line 25 ("genre facet excludes non-genre category types") pins that only genres appear. Keep it (subjects and locations must still be excluded) and add:

```ruby
    test "genre facet includes audience categories" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
      CategoryItem.create!(category: audience, item: books_books(:crime_and_punishment))

      slugs = facets.genres.map { |row| row[:record].slug }

      assert_includes slugs, audience.slug
    end
```

(`facets` and `@rc` come from the file's setup, which ranks war_and_peace, crime_and_punishment and got.)

`test/lib/books/saved_search_filter_labels_test.rb`: replace every `"Including genres"` with `"Including categories"`, `"Excluding genres"` with `"Excluding categories"`, `"Books must have at least one of these genres"` with `"Books must have at least one of these categories"`, and `"Books must have all of these genres"` with `"Books must have all of these categories"`:

```bash
sed -i -e 's/Including genres/Including categories/g' -e 's/Excluding genres/Excluding categories/g' \
  -e 's/of these genres/of these categories/g' test/lib/books/saved_search_filter_labels_test.rb
```

`test/controllers/books/books_controller_test.rb`: next to the test at line 259 that pins the type order, add:

```ruby
    test "an audience group sits between genres and subjects" do
      CategoryItem.create!(category: categories(:books_france_location), item: @book)
      CategoryItem.create!(category: categories(:books_politics_subject), item: @book)
      CategoryItem.create!(category: Books::Category.create!(name: "Young Adult", category_type: :audience), item: @book)

      get "/book/#{@book.slug}"

      assert_equal %w[genre audience subject location],
        @controller.view_assigns["categories_by_type"].map(&:first)
    end
```

(Same setup as the neighbouring "groups the categories genre, then subject, then location" test, whose `@book` carries a genre.)

`test/lib/csv_exports/books/ranked_book_row_test.rb`: update the `"headers"` test's expected array to `["Rank", "Score", "ID", "Title", "Authors", "Year", "Original Language", "Countries", "Genres", "Audiences", "Subjects", "Locations", "Page Range", "Word Count", "URL"]`, update "a row from a ranked item" to expect `"Classics, Novels", nil, nil, nil, nil, nil,` (one more nil, for Audiences), and add:

```ruby
      test "an audience goes in the Audiences column" do
        CategoryItem.create!(category: ::Books::Category.create!(name: "Young Adult", category_type: :audience), item: @book)

        row = RankedBookRow.row(@ranked, RankedBookRow.context([@book.id]))

        assert_equal "Young Adult", row[RankedBookRow::HEADERS.index("Audiences")]
      end
```

Check the "a soft-deleted category is left out" test: it reads `row[8]` (Genres), which does not move.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/books/filter_title_test.rb test/lib/books/filter_facets_query_test.rb test/lib/books/saved_search_filter_labels_test.rb test/controllers/books/books_controller_test.rb` plus the CSV row test.
Expected: FAIL.

- [ ] **Step 3: Implement**

`filter_facets_query.rb` `genre_facet`:

```ruby
        .where(categories: {deleted: false, category_type: Category.category_types.values_at("genre", "audience"), type: "Books::Category"})
```

and update the class comment's first sentence to say the category facet lists genres and audiences.

`filter_title.rb`, replace `genre_parts`:

```ruby
    # Audience reads as part of the kind of book: "Young Adult Fantasy Books".
    def genre_parts
      audiences = names_for(:audience)
      genres = names_for(:genre)
      return ["Books"] if audiences.empty? && genres.empty?

      parts = []
      parts << format_list(audiences) if audiences.any?
      parts << format_list(genres) if genres.any?
      parts << "Books" unless genres.any? { |name| name.end_with?("s") }
      parts
    end
```

`filter_modal_component.rb:4`:

```ruby
      {axis: "category", label: "Category", hint: "Genre, audience, subject, or setting"},
```

`saved_search_filter_labels.rb`:

```ruby
    ANY_NOTE = "Books must have at least one of these categories"
    ALL_NOTE = "Books must have all of these categories"
    ...
        category_group("Including categories", included_category_ids, genre_note),
        category_group("Excluding categories", excluded_category_ids, nil),
```

`books_controller.rb:15`:

```ruby
  CATEGORY_TYPE_ORDER = %w[genre audience subject location].freeze
```

`ranked_book_row.rb`: `HEADERS` gets `"Audiences"` after `"Genres"`; `context` gets `audiences: category_names(categories, types[:audience]),` after `genres:`; `row_for_book` gets `ctx[:audiences][book.id],` after `ctx[:genres][book.id],`.

`openapi.yaml`, the books `categories` item's `category_type`:

```yaml
                  category_type: {type: string, description: "genre, audience (Children's, Middle Grade, Young Adult), subject or location"}
```

- [ ] **Step 4: Run them to see them pass**

Run the same tests. Expected: PASS. Then `bin/rails test test/lib/books/ test/controllers/books/ test/components/books/`. Expected: PASS. If an API test compares the OpenAPI document to a snapshot, update the snapshot the way that test's file says to.

- [ ] **Step 5: Commit**

```bash
git add -A app config test
git commit -m "Books: audience in the filter modal, titles, labels, book page, CSV and API docs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `/categories/audiences`

**Files:**
- Modify: `app/lib/books/browse_query.rb:7` (`TYPES`), `:124-129` (the ranked-count gate)
- Modify: `app/lib/books/browse_path.rb:15` (`TYPE_SEGMENTS`)
- Modify: `app/controllers/books/browse_controller.rb:13-17` (`TITLES`)
- Modify: `app/components/books/browse_toolbar_component.rb:3,29` (labels; hide Audiences when none exist)
- Modify: `config/routes.rb` (after the `categories/subjects` route)
- Test: `test/lib/books/browse_query_test.rb`, `test/lib/books/browse_path_test.rb` (create if absent: `grep -rln BrowsePath test`), `test/routing/books_browse_routing_test.rb`, `test/components/books/browse_toolbar_component_test.rb`
- E2E: `e2e/tests/books/browse.spec.ts`

**Interfaces:**
- Consumes: `Category.category_types["audience"]`.
- Produces: `Books::BrowseQuery::TYPES == %w[genre audience location subject]`; route `/categories/audiences(/sorted-by/:sort)(/page/:page)` with `filter: "audience"`; `BrowsePath.call(axis: :categories, type: "audience") == "/categories/audiences"`.

- [ ] **Step 1: Write the failing tests**

`test/routing/books_browse_routing_test.rb`: add rows to its table, next to the subject rows:

```ruby
    ["/categories/audiences", "categories", {filter: "audience"}],
    ["/categories/audiences/sorted-by/name/page/2", "categories", {filter: "audience", sort: "name", page: "2"}],
```

`test/lib/books/browse_path_test.rb` (follow the existing file if there is one):

```ruby
  test "the audience type has its own segment" do
    assert_equal "/categories/audiences", Books::BrowsePath.call(axis: :categories, type: "audience")
    assert_equal "/categories/audiences/sorted-by/name", Books::BrowsePath.call(axis: :categories, type: "audience", sort: "name")
  end
```

`test/lib/books/browse_query_test.rb`:

```ruby
    test "audience categories list without the ranked-book minimum, like genres" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
      CategoryItem.create!(category: audience, item: books_books(:war_and_peace))

      ids = with_browse_minimum(2) { categories_for(type: "audience").map(&:id) }

      assert_equal [audience.id], ids
    end
```

(`categories_for`, `@rc` and `with_browse_minimum` are the file's own helpers; war_and_peace is ranked in its setup.)

`test/components/books/browse_toolbar_component_test.rb`:

```ruby
  test "the Audiences tab appears only when an audience category exists" do
    render_inline(Books::BrowseToolbarComponent.new(axis: :categories, sort: "book_count", type: "genre", show_types: true))
    refute_text "Audiences"

    Books::Category.create!(name: "Young Adult", category_type: :audience)
    render_inline(Books::BrowseToolbarComponent.new(axis: :categories, sort: "book_count", type: "genre", show_types: true))
    assert_text "Audiences"
  end
```

(Copy the constructor arguments from the existing tests in that file.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/routing/books_browse_routing_test.rb test/lib/books/browse_query_test.rb test/lib/books/browse_path_test.rb test/components/books/browse_toolbar_component_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

`browse_query.rb`:

```ruby
    TYPES = %w[genre audience location subject].freeze
```

The gate in `ranked_scope`:

```ruby
      # Subject and location cards need a minimum of ranked books (spec §6);
      # one-book categories exist for similarity, not as landing pages. Genres
      # and audiences are a short curated list and always show.
      scope.where(
        "categories.category_type IN (:curated) OR ranked_counts.ranked_count >= :min",
        curated: ::Category.category_types.values_at("genre", "audience"),
        min: Rails.configuration.x.books.browse_min_category_books
      )
```

Fix the comment on `self.search` ("Searches all three category types") to "every category type".

`browse_path.rb`:

```ruby
    TYPE_SEGMENTS = {"audience" => "audiences", "location" => "settings", "subject" => "subjects"}.freeze
```

`browse_controller.rb` `TITLES`: add `"audience" => "Books by Audience",`.

`browse_toolbar_component.rb`:

```ruby
    TYPE_LABELS = {"genre" => "Genres", "audience" => "Audiences", "location" => "Settings", "subject" => "Subjects"}.freeze
```

and in the method at line 29 that maps `TYPE_LABELS`, skip `"audience"` unless one exists:

```ruby
      TYPE_LABELS.filter_map do |value, label|
        next if value == "audience" && !audiences?
        # ...the existing body, unchanged...
      end
```

with a private memoised helper:

```ruby
    # Audiences arrive with the genre cleanup; until then the tab would lead to
    # an empty page.
    def audiences?
      @audiences ||= ::Books::Category.active.audience.exists?
    end
```

(If the existing method uses `map`, change it to `filter_map` and keep its block's return value for the other types.)

`config/routes.rb`, after the `categories/subjects` route:

```ruby
    get "categories/audiences(/sorted-by/:sort)(/page/:page)", to: "books/browse#categories",
      defaults: {filter: "audience"}, constraints: {sort: browse_sort, page: /\d+/}
```

Leave `browse_filter` (the legacy `/genres/filtered-by/:filter` redirect) alone: legacy never had an audience filter.

- [ ] **Step 4: Run them to see them pass**

Run the same tests, then `bin/rails test test/lib/books/ test/controllers/books/ test/components/books/ test/routing/`. Expected: PASS.

- [ ] **Step 5: E2E**

Add to `e2e/tests/books/browse.spec.ts`, following its existing style:

```ts
  test('the audiences page renders', async ({ page }) => {
    const response = await page.goto('/categories/audiences');
    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { level: 1 })).toContainText('Books by Audience');
  });
```

Check port 3000 belongs to this worktree (AGENTS.md "Port 3000 is shared"), `yarn build:all`, start `bin/rails server`, then run `yarn test:e2e e2e/tests/books/browse.spec.ts`. If port 3000 belongs to another checkout, stop and report it instead of running E2E.

- [ ] **Step 6: Commit**

```bash
git add -A app config test e2e
git commit -m "Books: /categories/audiences, shown once audiences exist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Global canon accepts audiences and follows old slugs

**Files:**
- Modify: `app/lib/books/global_canon_params.rb:57-73` (`genres`)
- Modify: `app/controllers/books/global_canon_controller.rb:55-68` (`genres` picker)
- Modify: `app/views/books/global_canon/show.html.erb:74` (placeholder)
- Test: `test/lib/books/global_canon_params_test.rb`, `test/controllers/books/global_canon_controller_test.rb`

**Interfaces:**
- Consumes: `Books::CategorySlugResolver.call(slug) -> Books::Category | nil`.
- Produces: `GlobalCanonParams` exclusions may be genre or audience categories; a merged or renamed slug resolves to its current category (the controller's existing `redirect_to_canonical_form` then 301s to the canonical path).

- [ ] **Step 1: Write the failing tests**

`test/lib/books/global_canon_params_test.rb`:

```ruby
    test "an audience slug is a valid exclusion" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)

      assert_equal [audience], Books::GlobalCanonParams.call(excluded_genres: audience.slug).excluded_genres
    end

    test "a slug merged away resolves to the category it was merged into" do
      old = Books::Category.create!(name: "Childrens Books Old", category_type: :genre)
      current = Books::Category.create!(name: "Children's", category_type: :audience)
      old.update!(deleted: true, merged_into: current)

      assert_equal [current], Books::GlobalCanonParams.call(excluded_genres: old.slug).excluded_genres
    end

    test "a slug that resolves to a subject still 404s" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Books::GlobalCanonParams.call(excluded_genres: categories(:books_politics_subject).slug)
      end
    end
```

`test/controllers/books/global_canon_controller_test.rb` (its setup sets the host):

```ruby
    test "an excluded slug that was merged away 301s to the canonical path" do
      old = Books::Category.create!(name: "Childrens Books Old", category_type: :genre)
      current = Books::Category.create!(name: "Children's", category_type: :audience)
      old.update!(deleted: true, merged_into: current)

      get "/global-canon/total_books/150/nonfiction/20/max_per_country/3/excluding/#{old.slug}"

      assert_response :moved_permanently
      assert_includes response.location, "/excluding/#{current.slug}"
    end

    test "the genres endpoint finds audiences" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)

      get "/global-canon/genres", params: {q: "Young"}, as: :json

      assert_includes response.parsed_body.map { |row| row["value"] }, audience.slug
    end
```

If the redirect test gets a 200, read `redirect_to_canonical_form` in the controller: it must compare the path `GlobalCanonPath` builds from the resolved settings with `request.path`. A resolved slug differs from the requested one, so it should redirect; if the method short-circuits on something else, make it compare paths whenever `excluded_genres` was given.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/books/global_canon_params_test.rb test/controllers/books/global_canon_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

`global_canon_params.rb`:

```ruby
    EXCLUDABLE_TYPES = %w[genre audience].freeze

    # Accepts BOTH shapes the two entry points produce: a comma-joined string
    # from the path segment, and an array from the picker's `name="...[]"`
    # hidden inputs. A slug that is not live resolves like Books::FilterParams
    # does (merged -> its target, renamed -> friendly_id history), so the
    # controller's canonical-form check 301s an old URL to the current one. A
    # count mismatch or an unresolvable slug 404s rather than silently
    # dropping it, because a URL promising two exclusions must not quietly
    # apply one.
    #
    # Genres and audiences only. A subject or setting slug 404s rather than
    # filtering, so the URL space stays exactly what the picker can produce.
    def genres(raw)
      slugs = Array(raw).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq
      return [] if slugs.empty?
      raise ActiveRecord::RecordNotFound if slugs.size > MAX_EXCLUDED_GENRES

      records = slugs.map do |slug|
        category = ::Books::Category.active.find_by(slug: slug) || ::Books::CategorySlugResolver.call(slug)
        raise ActiveRecord::RecordNotFound unless category && EXCLUDABLE_TYPES.include?(category.category_type)

        category
      end
      records.uniq.sort_by(&:slug)
    end
```

`global_canon_controller.rb` `genres`: `types: [:genre, :audience]`, and update its comment ("types: [:genre, :audience] is deliberate ...").

`show.html.erb:74`: `placeholder="Search genres and audiences"` (and the matching `aria-label` if there is one on that input).

- [ ] **Step 4: Run them to see them pass**

Run the same tests, then `bin/rails test test/lib/books/ test/controllers/books/`. Expected: PASS. Run `yarn test:e2e e2e/tests/books/global-canon.spec.ts` under the port-3000 check from Task 4; if a selector there used the old placeholder, update it.

- [ ] **Step 5: Commit**

```bash
git add -A app test e2e
git commit -m "Books: global canon excludes audiences; old exclusion slugs 301

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The `split` action and extra targets in the applier

**Files:**
- Create: migration via `bin/rails generate migration AddSplitColumnsToCategoryCleanupDecisions`
- Modify: `app/models/category_cleanup_decision.rb`
- Modify: `app/lib/services/category_cleanup/applier.rb`
- Test: `test/lib/services/category_cleanup/applier_test.rb`, `test/models/category_cleanup_decision_test.rb`

**Interfaces:**
- Produces:
  - `CategoryCleanupDecision` action `split` (enum 6); columns `extra_target_ids bigint[] default {}`, `split_assignments jsonb default {}` (`{"<book_id>" => [category_id, ...]}`); stage `"genres"` valid.
  - A split decision has either `target_category_id` (merging mode: merge into the primary) or `new_name` (renaming mode: the category becomes the primary under that name). Its targets, primary first, are `[target_category_id || category_id] + extra_target_ids`.
  - A `keep` or `rename` decision with non-empty `extra_target_ids` links the category's books to those categories.
  - `Applier` stats gain `"split"`.

- [ ] **Step 1: Generate and write the migration**

Run: `bin/rails generate migration AddSplitColumnsToCategoryCleanupDecisions`

Fill it in:

```ruby
class AddSplitColumnsToCategoryCleanupDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :category_cleanup_decisions, :extra_target_ids, :bigint, array: true, default: [], null: false
    add_column :category_cleanup_decisions, :split_assignments, :jsonb, default: {}, null: false
  end
end
```

(Use the migration superclass version the generator wrote.) Run `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate` and confirm `db/schema.rb` gained both columns. This migrates the development database's schema only (additive columns with defaults, no data touched); that is expected for a migration and is not a bulk data change.

- [ ] **Step 2: Write the failing tests**

`test/models/category_cleanup_decision_test.rb` (follow the file's style for building a valid decision):

```ruby
  test "a split needs a target or a new name" do
    category = categories(:books_novels_genre)
    base = {category: category, run: "r1", stage: "genres", action: :split, decided_by: :ai,
            category_snapshot: CategoryCleanupDecision.snapshot_of(category)}

    refute CategoryCleanupDecision.new(base).valid?
    assert CategoryCleanupDecision.new(base.merge(new_name: "History")).valid?
    assert CategoryCleanupDecision.new(base.merge(target_category: categories(:books_classics_genre))).valid?
  end
```

`test/lib/services/category_cleanup/applier_test.rb`, add a helper and tests (the file's `@book` is War and Peace; add a second book from fixtures, e.g. `books_books(:crime_and_punishment)`):

```ruby
      def genre(name, books: [])
        record = ::Books::Category.create!(name: name, category_type: :genre)
        books.each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      test "a merging split gives each book only its assigned targets and merges the empty genre" do
        lotr = @book
        dune = books_books(:crime_and_punishment)
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        combined = genre("Science Fiction Fantasy", books: [lotr, dune])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {lotr.id.to_s => [fantasy.id], dune.id.to_s => [sf.id, fantasy.id]})

        result = Applier.call(run: "r1")

        assert_equal "applied", split.reload.status
        assert_equal 1, result.data["split"]
        assert_equal sf, combined.reload.merged_into
        assert combined.deleted?
        refute CategoryItem.exists?(category: sf, item: lotr)
        assert CategoryItem.exists?(category: fantasy, item: lotr)
        assert CategoryItem.exists?(category: sf, item: dune)
        assert CategoryItem.exists?(category: fantasy, item: dune)
        assert_equal 0, CategoryItem.where(category: combined).count
      end

      test "a book missing from the assignments gets every target" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        combined = genre("Science Fiction Fantasy", books: [@book])
        decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])

        Applier.call(run: "r1")

        assert CategoryItem.exists?(category: sf, item: @book)
        assert CategoryItem.exists?(category: fantasy, item: @book)
      end

      test "a renaming split keeps the genre for its assigned books and drops it for the rest" do
        history_book = @book
        politics_book = books_books(:crime_and_punishment)
        politics = ::Books::Category.create!(name: "Politics", category_type: :subject)
        combined = genre("History and Politics", books: [history_book, politics_book])
        decide(combined, :split, stage: "genres", new_name: "History", extra_target_ids: [politics.id],
          split_assignments: {history_book.id.to_s => [combined.id], politics_book.id.to_s => [politics.id]})

        Applier.call(run: "r1")

        combined.reload
        assert_equal "History", combined.name
        refute combined.deleted?
        assert CategoryItem.exists?(category: combined, item: history_book)
        refute CategoryItem.exists?(category: combined, item: politics_book)
        assert CategoryItem.exists?(category: politics, item: politics_book)
        refute CategoryItem.exists?(category: politics, item: history_book)
      end

      test "a split keeps the source of each link and does not duplicate existing links" do
        sf = genre("Science Fiction", books: [@book])
        fantasy = genre("Fantasy")
        combined = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
        CategoryItem.create!(category: combined, item: @book, source: :admin)
        decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])

        Applier.call(run: "r1")

        assert_equal 1, CategoryItem.where(category: sf, item: @book).count
        assert CategoryItem.exists?(category: fantasy, item: @book, source: :admin)
      end

      test "a keep with extra targets links the genre's books to them; a re-run adds nothing" do
        romance = genre("Romance")
        fantasy = genre("Fantasy")
        romantasy = genre("Romantasy", books: [@book])
        keep = decide(romantasy, :keep, stage: "genres", extra_target_ids: [romance.id, fantasy.id])

        Applier.call(run: "r1")
        Applier.call(run: "r1")

        assert_equal "applied", keep.reload.status
        assert_equal 1, CategoryItem.where(category: romance, item: @book).count
        assert_equal 1, CategoryItem.where(category: fantasy, item: @book).count
      end

      test "a rename with extra targets renames and links" do
        romance = genre("Romance")
        rom_com = genre("romcom", books: [@book])
        decide(rom_com, :rename, stage: "genres", new_name: "Romantic Comedy", extra_target_ids: [romance.id])

        Applier.call(run: "r1")

        assert_equal "Romantic Comedy", rom_com.reload.name
        assert CategoryItem.exists?(category: romance, item: @book)
      end

      test "a split is terminal: a keep on the same category goes stale" do
        sf = genre("Science Fiction")
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf)
        keep = decide(combined, :keep, stage: "genres")

        Applier.call(run: "r1")

        assert_equal %w[applied stale], [split, keep].map { |d| d.reload.status }
      end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/lib/services/category_cleanup/applier_test.rb test/models/category_cleanup_decision_test.rb`
Expected: FAIL (`'split' is not a valid action`, unknown attribute `extra_target_ids` before the migration, etc.).

- [ ] **Step 4: Implement the model**

`app/models/category_cleanup_decision.rb`:

```ruby
  STAGES = %w[rules locations_head locations_tail subjects_head subjects_tail sync apply genres].freeze
  ...
  enum :action, {keep: 0, rename: 1, merge: 2, retype: 3, set_parent: 4, delete: 5, split: 6}, prefix: true
  ...
  validate :split_has_a_primary, if: -> { proposed? && action_split? }
  ...
  scope :terminal, -> { where(action: %i[merge split retype delete]) }
  ...
  private

  # Merging mode names the category to merge into; renaming mode names what
  # this category becomes. Spec 2026-10-17 §4, "Combined genres".
  def split_has_a_primary
    errors.add(:base, "a split needs a target category or a new name") if target_category_id.nil? && new_name.blank?
  end
```

(If the model already has a `private` section, add the method there.)

- [ ] **Step 5: Implement the applier**

`applier.rb`:

```ruby
      STAT_KEYS = %w[rename merge split retype set_parent delete keep created stale failed].freeze
      # Which terminal decision wins when one category has several: phase order.
      TERMINAL_RANK = {"merge" => 0, "split" => 1, "retype" => 2, "delete" => 3}.freeze
```

In `call`, the phases:

```ruby
        mark_stale
        %w[rename merge split retype].each { |action| apply_each(action) }
        @lookup = LocationLookup.new
        create_missing_parents
        apply_each("set_parent")
        apply_each("delete")
        # A keep with extra targets (genre cleanup `also:`) links books, so it
        # runs one by one; a plain keep only records the decision.
        pending.where(action: :keep).where.not(extra_target_ids: []).find_each { |decision| apply_one(decision) }
        kept = pending.where(action: :keep).update_all(status: ::CategoryCleanupDecision.statuses.fetch("applied"), updated_at: Time.current)
```

Update the class comment's phase list to "rename, merge, split, retype, create missing parents, set parent, delete, keep".

Refactor `apply_rename` so its body is a reusable method, and link extras:

```ruby
      def apply_rename(decision)
        category = live_category!(decision)
        rename_category(category, decision.new_name)
        link_books(category, decision.extra_target_ids)
      end

      def rename_category(category, new_name)
        old_name = category.name
        old_key = NameNormalizer.twin_key(old_name)
        alternatives = Array(category.alternative_names)
        remember_old = old_key && old_key != NameNormalizer.twin_key(new_name) &&
          alternatives.none? { |alt| NameNormalizer.twin_key(alt) == old_key }
        # Keep the old name as an alternative so a set_parent chain proposed
        # against it still resolves once the rename has landed.
        category.update!({name: new_name}.merge(remember_old ? {alternative_names: alternatives + [old_name]} : {}))
      end

      def apply_keep(decision)
        link_books(live_category!(decision), decision.extra_target_ids)
      end

      # Spec 2026-10-17 §4, "Combined genres". Each book gets the targets
      # split_check assigned it (all of them when it has no answer), then the
      # genre's own book links go: merging mode merges the emptied genre into
      # the primary, so saved searches, old URLs and legacy links follow it;
      # renaming mode keeps the links of books assigned the primary and renames.
      def apply_split(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        primary_id = decision.target_category_id ? decision.target_category.canonical.id : category.id
        targets = ([primary_id] + decision.extra_target_ids).uniq
        links = category.category_items.where(item_type: "Books::Book").pluck(:item_id, :source).to_h
        assigned = decision.split_assignments.transform_keys(&:to_i)
        wanted = links.keys.index_with { |book_id| Array(assigned.fetch(book_id, targets)).map(&:to_i) & targets }

        insert_links(wanted.flat_map { |book_id, ids| (ids - [category.id]).map { |id| [id, book_id, links[book_id]] } })
        if decision.target_category_id
          ::CategoryItem.where(category_id: category.id, item_type: "Books::Book").delete_all
          ::Categories::Merger.new(category: category, category_to_merge_with: ::Category.find(primary_id)).merge
        else
          dropped = wanted.reject { |_book_id, ids| ids.include?(category.id) }.keys
          ::CategoryItem.where(category_id: category.id, item_type: "Books::Book", item_id: dropped).delete_all
          rename_category(category, decision.new_name)
        end
        ::Categories::ItemCounter.call(([category.id] + targets).uniq)
        ::Categories::ItemReindexer.queue_items(links.keys.map { |book_id| ["Books::Book", book_id] })
      end

      # Links every book of `category` to each of `target_ids`, keeping each
      # link's source; existing links are left alone.
      def link_books(category, target_ids)
        return if target_ids.blank?

        links = category.category_items.where(item_type: "Books::Book").pluck(:item_id, :source)
        insert_links(target_ids.flat_map { |id| links.map { |book_id, source| [id, book_id, source] } })
        ::Categories::ItemCounter.call(target_ids)
        ::Categories::ItemReindexer.queue_items(links.map { |book_id, _| ["Books::Book", book_id] })
      end

      # rows: [[category_id, book_id, source], ...]
      def insert_links(rows)
        return if rows.empty?

        now = Time.current
        ::CategoryItem.insert_all(
          # pluck returns the enum's name; insert_all skips enum casting.
          rows.map { |category_id, book_id, source| {category_id: category_id, item_type: "Books::Book", item_id: book_id, source: ::CategoryItem.sources.fetch(source.to_s), created_at: now, updated_at: now} },
          unique_by: :index_category_items_on_category_id_and_item_type_and_item_id
        )
      end
```

Notes for the implementer:
- `insert_all` with `unique_by` skips rows that already exist (Postgres `ON CONFLICT DO NOTHING`), which is the "do not duplicate" requirement.
- Check `Categories::ItemCounter.call` and `Categories::ItemReindexer.queue_items` signatures in `app/lib/categories/` before using them; the Merger calls both exactly this way.
- `live_category!` refuses protected categories, so a split or extra-target keep on one fails the decision, which is correct.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/category_cleanup/ test/models/category_cleanup_decision_test.rb`
Expected: PASS, including every pre-existing applier test.

- [ ] **Step 7: Commit**

```bash
git add -A db app test
git commit -m "Category cleanup: split action and extra targets for keep and rename

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The legacy sync gives new links every extra target

**Files:**
- Modify: `app/lib/services/books_migration/category_item_migrator.rb` (`preload_context`, `build_rows`)
- Test: `test/lib/services/books_migration/category_item_migrator_test.rb`

**Interfaces:**
- Consumes: applied `CategoryCleanupDecision` rows with `extra_target_ids` (Task 6).
- Produces: a legacy link whose category (by its new-app id, before any merge redirect) has an applied decision with extra targets yields one row for the usual target plus one per live extra target.

- [ ] **Step 1: Write the failing test**

The file's helpers: `make_category(legacy_id, deleted: false)` creates a `Books::Category` with a `LegacyIdMap` row; `run_migrator(rows)` feeds legacy `book_categories` hashes. Add:

```ruby
  def split_into(sf, fantasy, legacy_id:)
    combined = make_category(legacy_id)
    combined.update!(deleted: true, merged_into: sf)
    CategoryCleanupDecision.create!(category: combined, run: "g1", stage: "genres", action: :split, decided_by: :ai,
      status: :applied, target_category: sf, extra_target_ids: [fantasy.id], category_snapshot: {})
    combined
  end

  test "a link to a split genre also lands on its extra targets" do
    sf = ::Books::Category.create!(name: "Science Fiction")
    fantasy = ::Books::Category.create!(name: "Fantasy")
    split_into(sf, fantasy, legacy_id: 8101)
    book = ::Books::Book.create!(title: "Split Link Book")

    result = run_migrator([{"id" => 11, "category_id" => 8101, "book_id" => book.id}])

    assert result[:success], result[:error]
    assert CategoryItem.exists?(category: sf, item_id: book.id, item_type: "Books::Book")
    assert CategoryItem.exists?(category: fantasy, item_id: book.id, item_type: "Books::Book")
  end

  test "an extra target that has since been deleted is skipped" do
    sf = ::Books::Category.create!(name: "Science Fiction")
    fantasy = ::Books::Category.create!(name: "Fantasy", deleted: true)
    split_into(sf, fantasy, legacy_id: 8102)
    book = ::Books::Book.create!(title: "Split Link Book 2")

    run_migrator([{"id" => 12, "category_id" => 8102, "book_id" => book.id}])

    assert CategoryItem.exists?(category: sf, item_id: book.id, item_type: "Books::Book")
    refute CategoryItem.exists?(category: fantasy, item_id: book.id, item_type: "Books::Book")
  end

  test "a kept genre with also links its extra genres" do
    romantasy = make_category(8103)
    romance = ::Books::Category.create!(name: "Romance")
    CategoryCleanupDecision.create!(category: romantasy, run: "g1", stage: "genres", action: :keep, decided_by: :ai,
      status: :applied, extra_target_ids: [romance.id], category_snapshot: {})
    book = ::Books::Book.create!(title: "Romantasy Book")

    run_migrator([{"id" => 13, "category_id" => 8103, "book_id" => book.id}])

    assert CategoryItem.exists?(category: romantasy, item_id: book.id, item_type: "Books::Book")
    assert CategoryItem.exists?(category: romance, item_id: book.id, item_type: "Books::Book")
  end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/lib/services/books_migration/category_item_migrator_test.rb`
Expected: FAIL (no Fantasy link).

- [ ] **Step 3: Implement**

In `preload_context`, after `@category_map`:

```ruby
        # Genre cleanup (spec 2026-10-17 §4): a split genre, or a kept genre
        # with `also:`, sends its links to extra categories too. Keyed by the
        # category's own new-app id, before the merge redirect above.
        @new_ids = LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
        live = ::Category.where(deleted: false)
        @extra_targets = ::CategoryCleanupDecision.applied.where.not(extra_target_ids: [])
          .pluck(:category_id, :extra_target_ids)
          .each_with_object({}) do |(category_id, ids), out|
            out[category_id] = live.where(id: ids).pluck(:id)
          end
```

In `build_rows`:

```ruby
        if new_category_id
          extras = @extra_targets.fetch(@new_ids[legacy_category_id], [])
          return ([new_category_id] + extras).uniq.map { |id| {category_id: id, item_type: "Books::Book", item_id: attrs["book_id"]} }
        end
```

Update the class comment with one sentence about extra targets.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/books_migration/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/category_item_migrator.rb test/lib/services/books_migration/category_item_migrator_test.rb
git commit -m "Legacy sync: new links to a split genre land on every target

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: WorldCat audience verdicts, `also:`, and weak Juvenile terms

**Files:**
- Modify: `app/lib/books/world_cat/genre_map.rb`
- Modify: `app/lib/services/books/world_cat/apply_categories.rb`
- Modify: `app/lib/services/books/world_cat/apply_aliases.rb`
- Modify: `app/lib/services/books/world_cat/mapping_report.rb`
- Modify: `app/lib/services/books/world_cat/backfill.rb:35,50` and `app/sidekiq/books/world_cat_backfill_job.rb:19` (count audience links)
- Test: `test/lib/books/world_cat/genre_map_test.rb`, `test/lib/services/books/world_cat/apply_categories_test.rb`, `apply_aliases_test.rb`, `mapping_report_test.rb`

**Interfaces:**
- Produces:
  - `GenreMap#audiences -> [String]`; `GenreMap#targets_for(term) -> [GenreMap::Target]` with `Target = Struct.new(:kind, :name, :weak, keyword_init: true)`, `kind` `:genre` or `:audience`; an `also:` name is an audience when it is in `audiences`, otherwise a genre. `GenreMap#terms_by_audience -> {name => [terms]}`.
  - Map entry shapes: `{verdict: genre, genre: X, also: [Y]}`, `{verdict: audience, audience: X, weak: true, also: [...]}`.
  - `ApplyCategories` data gains `audiences_linked: [names]` and `weak_skipped: Integer`.

- [ ] **Step 1: Write the failing tests**

`test/lib/books/world_cat/genre_map_test.rb`:

```ruby
  test "targets_for reads genre, audience, also and weak" do
    map = Books::WorldCat::GenreMap.new({
      "genres" => ["Science Fiction", "Fantasy"], "audiences" => ["Children's", "Young Adult"],
      "terms" => {
        "Fantasy och science fiction" => {"verdict" => "genre", "genre" => "Science Fiction", "also" => ["Fantasy"]},
        "Juvenile fiction" => {"verdict" => "audience", "audience" => "Children's", "weak" => true},
        "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult"},
        "Electronic books" => {"verdict" => "drop", "reason" => "format"}
      }
    })

    assert_equal [[:genre, "Science Fiction", false], [:genre, "Fantasy", false]],
      map.targets_for("Fantasy och science fiction").map { |t| [t.kind, t.name, t.weak] }
    assert_equal [[:audience, "Children's", true]], map.targets_for("Juvenile fiction").map { |t| [t.kind, t.name, t.weak] }
    assert_empty map.targets_for("Electronic books")
    assert_equal({"Children's" => ["Juvenile fiction"], "Young Adult" => ["Young adult fiction"]}, map.terms_by_audience)
    assert_equal ["Children's", "Young Adult"], map.audiences
  end
```

`test/lib/services/books/world_cat/apply_categories_test.rb` (its setup gives `@book` = War and Peace, a `record(oclc, genre:, subjects:)` helper and a map; these tests build their own map):

```ruby
        def audience_map
          ::Books::WorldCat::GenreMap.new(
            "genres" => ["Science Fiction", "Fantasy"], "audiences" => ["Children's", "Young Adult"],
            "terms" => {
              "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult"},
              "Juvenile fiction" => {"verdict" => "audience", "audience" => "Children's", "weak" => true},
              "Children's stories" => {"verdict" => "audience", "audience" => "Children's"},
              "Fantasy och science fiction" => {"verdict" => "genre", "genre" => "Science Fiction", "also" => ["Fantasy"]}
            }
          )
        end

        test "an audience verdict links the audience category" do
          ya = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
          records = [record(1, genre: "Young adult fiction"), record(2, genre: "Young adult fiction")]

          result = ApplyCategories.call(book: @book, records: records, map: audience_map)

          assert_equal ["Young Adult"], result.data[:audiences_linked]
          assert CategoryItem.exists?(category: ya, item: @book)
        end

        test "a weak Juvenile term alone adds nothing" do
          childrens = ::Books::Category.create!(name: "Children's", category_type: :audience)
          records = [record(1, genre: "Juvenile fiction"), record(2, genre: "Juvenile fiction")]

          result = ApplyCategories.call(book: @book, records: records, map: audience_map)

          refute CategoryItem.exists?(category: childrens, item: @book)
          assert_equal 1, result.data[:weak_skipped]
        end

        test "a weak term counts when a record also supports Children's strongly" do
          childrens = ::Books::Category.create!(name: "Children's", category_type: :audience)
          records = [record(1, genre: "Juvenile fiction"), record(2, genre: "Children's stories")]

          ApplyCategories.call(book: @book, records: records, map: audience_map)

          assert CategoryItem.exists?(category: childrens, item: @book)
        end

        test "a weak term counts on a book that is already Children's" do
          childrens = ::Books::Category.create!(name: "Children's", category_type: :audience)
          CategoryItem.create!(category: childrens, item: @book)
          records = [record(1, genre: "Juvenile fiction"), record(2, genre: "Juvenile fiction")]

          result = ApplyCategories.call(book: @book, records: records, map: audience_map)

          assert_equal 1, result.data[:already_linked]
          assert_equal 0, result.data[:weak_skipped]
          assert_equal 1, CategoryItem.where(category: childrens, item: @book).count
        end

        test "an also target gets support from the same term" do
          ::Books::Category.create!(name: "Science Fiction", category_type: :genre)
          ::Books::Category.create!(name: "Fantasy", category_type: :genre)
          records = [record(1, genre: "Fantasy och science fiction"), record(2, genre: "Fantasy och science fiction")]

          result = ApplyCategories.call(book: @book, records: records, map: audience_map)

          assert_equal ["Fantasy", "Science Fiction"], result.data[:genres_linked]
        end
```

`apply_aliases_test.rb`:

```ruby
        test "audience terms become alternative names on the audience; a missing audience is reported" do
          ya = ::Books::Category.create!(name: "Young Adult", category_type: :audience)
          map = ::Books::WorldCat::GenreMap.new("audiences" => ["Young Adult", "Middle Grade"], "terms" => {
            "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult"},
            "Middle grade fiction" => {"verdict" => "audience", "audience" => "Middle Grade"}
          })

          result = ApplyAliases.call(map: map)

          assert_includes ya.reload.alternative_names, "Young adult fiction"
          assert_includes result.data[:missing_genres], "Middle Grade"
        end
```

`mapping_report_test.rb`: read how it writes the report (it takes a map and an `out_path`); add:

```ruby
        test "audience verdicts are counted and shown with their audience" do
          map = ::Books::WorldCat::GenreMap.new("terms" => {
            "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult", "uses" => 5, "books" => 2}
          })
          path = Rails.root.join("tmp", "mapping_report_test_#{SecureRandom.hex(4)}.md")

          result = MappingReport.call(map: map, out_path: path)

          assert_equal 1, result.data[:counts][:audience]
          assert_includes path.read, "| Young adult fiction | 5 | 2 | audience | Young Adult |"
        ensure
          FileUtils.rm_f(path)
        end
```

(If `MappingReport.call` takes other keyword arguments such as `top:`, pass what the existing tests pass.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/books/world_cat/ test/lib/services/books/world_cat/`
Expected: FAIL.

- [ ] **Step 3: Implement `GenreMap`**

```ruby
      Target = Struct.new(:kind, :name, :weak, keyword_init: true)

      def initialize(data)
        @genres = Array(data["genres"])
        @audiences = Array(data["audiences"])
        @terms = data["terms"] || {}
      end

      attr_reader :genres, :audiences

      # Every genre or audience a term supports, primary first
      # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §7).
      def targets_for(term)
        entry = @terms[term]
        return [] unless entry

        primary = case entry["verdict"]
        when "genre" then Target.new(kind: :genre, name: entry["genre"], weak: false)
        when "audience" then Target.new(kind: :audience, name: entry["audience"], weak: entry["weak"] == true)
        end
        return [] unless primary

        [primary] + Array(entry["also"]).map { |name| Target.new(kind: @audiences.include?(name) ? :audience : :genre, name: name, weak: false) }
      end

      def terms_by_audience
        @terms.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(term, entry), out|
          out[entry["audience"]] << term if entry["verdict"] == "audience"
        end.transform_values(&:sort).sort.to_h
      end
```

(`genre_for`, `subject_for`, `terms_by_genre` stay.)

- [ ] **Step 4: Implement `ApplyCategories`**

Replace the genre half of the record loop and the genre linking loop:

```ruby
          genre_support = Hash.new(0)
          strong_support = Hash.new(0)
          ...
          @records.each do |record|
            targets = record.genre.present? ? @map.targets_for(record.genre) : []
            if targets.any?
              genre_bearing += 1
              targets.each do |target|
                key = [target.kind, target.name]
                genre_support[key] += 1
                strong_support[key] += 1 unless target.weak
              end
            end
            # subject phrases: unchanged
          end

          genres_linked = []
          audiences_linked = []
          weak_skipped = 0
          ...
          supported(genre_support, genre_bearing).sort_by { |kind, name| [-genre_support[[kind, name]], kind.to_s, name] }.each do |kind, name|
            scope = (kind == :audience) ? ::Books::Category.active.audience : ::Books::Category.active.genre
            category = scope.by_name(name).first
            next unless category

            # WorldCat's "Juvenile" spans ages 0-15 and lands on children's
            # editions of classics: on its own it is not enough for Children's.
            if strong_support[[kind, name]].zero? && !@book.categories.active.exists?(id: category.id)
              weak_skipped += 1
              next
            end

            if type_conflict?(category)
              type_conflicts += 1
              next
            end

            created = link(category)
            if !created
              already += 1
            elsif kind == :audience
              audiences_linked << category.name
            else
              genres_linked << category.name
            end
          end
```

Add `audiences_linked: audiences_linked.sort, weak_skipped: weak_skipped` to the result data. Genre targets are never weak, so `strong_support` is non-zero for them whenever they are supported.

`backfill.rb`: add `audiences_linked: 0` to `stats` and `stats[:audiences_linked] += outcome[:audiences_linked].size`; include it in the log line. `world_cat_backfill_job.rb:19`: add `#{data[:audiences_linked]} audience links, ` after the genre count.

- [ ] **Step 5: Implement `ApplyAliases` and `MappingReport`**

`ApplyAliases#call`: run the existing loop body for both maps, collecting into the same counters:

```ruby
          [[@map.terms_by_genre, ::Books::Category.active.genre], [@map.terms_by_audience, ::Books::Category.active.audience]].each do |terms_by_name, scope|
            terms_by_name.each do |name, terms|
              category = scope.by_name(name).first
              if category.nil?
                missing << name
                next
              end
              aliases = terms.reject { |t| t == category.name || category.alternative_names.any? { |a| a.casecmp?(t) } }
              next if aliases.empty?

              category.update!(alternative_names: category.alternative_names + aliases)
              updated += 1
              added += aliases.size
            end
          end
```

Update its class comment to say genre and audience verdicts.

`MappingReport`: `row` adds `audience: entry["audience"]`; `target(r)` is `r[:genre] || r[:audience] || r[:subject] || r[:reason]`; `counts` covers `%w[genre audience subject drop]`; the header line adds `#{counts[:audience]} audience`.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/books/world_cat/ test/lib/services/books/world_cat/ test/sidekiq/books/ test/lib/tasks/worldcat_rake_test.rb`
Expected: PASS. If `worldcat_rake_test.rb` asserts the report's output line, update it for the audience count.

- [ ] **Step 7: Commit**

```bash
git add -A app test
git commit -m "WorldCat: audience verdicts, also: targets, weak Juvenile evidence

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The plan file, the split answers file, reference counts, and the validator

**Files:**
- Create: `app/lib/services/books/genre_plan/plan_file.rb`
- Create: `app/lib/services/books/genre_plan/assignments.rb`
- Create: `app/lib/services/books/genre_plan/references.rb`
- Create: `app/lib/services/books/genre_plan/validator.rb`
- Test: `test/lib/services/books/genre_plan/plan_file_test.rb`, `assignments_test.rb`, `references_test.rb`, `validator_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::GenrePlan::PlanFile`
    - `DEFAULT_PATH = Rails.root.join("config", "books", "genre_plan.yml")`
    - `AUDIENCES = {"Children's" => "Written for readers up to about age 8.", "Middle Grade" => "Written for readers about 8 to 12.", "Young Adult" => "Written for readers about 12 to 18."}`
    - `.load(path = DEFAULT_PATH) -> PlanFile` (empty data when the file is missing)
    - `#exists? -> Boolean`, `#run -> String`, `#genres -> [{"name","definition"}]`, `#genre_names`, `#audiences`, `#audience_names`, `#decisions -> {Integer => Hash}` (string keys inside), `#data`
    - `#write(path = @path)`: header comment + YAML
  - `Services::Books::GenrePlan::Assignments`
    - `DEFAULT_PATH = Rails.root.join("config", "books", "genre_split_assignments.csv")`; columns `book_id,category_id,targets`; `targets` is names joined with `|`, or `unknown`
    - `.load(path = DEFAULT_PATH) -> Assignments`; `#for(category_id) -> {book_id(Integer) => [names] | :unknown}`; `#answered?(category_id, book_id)`; `#append(rows, path = @path)` with rows `[[book_id, category_id, [names] | :unknown], ...]`; `#category_ids`
  - `Services::Books::GenrePlan::References.call -> {category_id => count}`: how many saved searches plus recommendation settings include or exclude each category id.
  - `Services::Books::GenrePlan::Validator.call(plan:, assignments:) -> Result` (`errors: [String]`).
  - Split `into:` entries: a String (a genre or audience list name) or `{"subject" => name, "target_id" => id}`. `Validator.target_label(entry) -> String` (the name, used by split_check and the CSV).

- [ ] **Step 1: Write the failing tests**

`plan_file_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GenrePlan
      class PlanFileTest < ActiveSupport::TestCase
        test "a missing file loads empty" do
          plan = PlanFile.load(Rails.root.join("tmp", "no_such_plan.yml"))

          refute plan.exists?
          assert_empty plan.genres
          assert_empty plan.decisions
        end

        test "round-trips lists and integer-keyed decisions" do
          path = Rails.root.join("tmp", "genre_plan_test_#{SecureRandom.hex(4)}.yml")
          plan = PlanFile.new({"version" => 1, "run" => "genres-test",
            "genres" => [{"name" => "Fantasy", "definition" => "Magic."}],
            "audiences" => PlanFile::AUDIENCES.map { |name, definition| {"name" => name, "definition" => definition} },
            "decisions" => {12 => {"name" => "fantasy", "action" => "rename", "to" => "Fantasy"}}}, path: path)
          plan.write

          loaded = PlanFile.load(path)
          assert_equal "genres-test", loaded.run
          assert_equal ["Fantasy"], loaded.genre_names
          assert_equal PlanFile::AUDIENCES.keys, loaded.audience_names
          assert_equal "Fantasy", loaded.decisions[12]["to"]
          assert File.read(path).start_with?("# Books genre cleanup plan")
        ensure
          FileUtils.rm_f(path)
        end
      end
    end
  end
end
```

`assignments_test.rb`:

```ruby
        test "appends and reads back answers, with unknown" do
          path = Rails.root.join("tmp", "assignments_test_#{SecureRandom.hex(4)}.csv")
          Assignments.load(path).append([[1, 40, ["Fantasy"]], [2, 40, :unknown], [3, 40, ["Science Fiction", "Fantasy"]]])

          loaded = Assignments.load(path)
          assert_equal({1 => ["Fantasy"], 2 => :unknown, 3 => ["Science Fiction", "Fantasy"]}, loaded.for(40))
          assert loaded.answered?(40, 2)
          refute loaded.answered?(40, 9)
          assert_equal [40], loaded.category_ids
        ensure
          FileUtils.rm_f(path)
        end
```

`references_test.rb`:

```ruby
        test "counts saved searches and recommendation settings per category id, in either storage shape" do
          saved_searches(:books_public).update_column(:criteria, {"included_category_ids" => ["5"], "excluded_category_ids" => [7]})
          saved_searches(:books_private).update_column(:criteria, {"excluded_category_ids" => ["7", 7]})
          recommendation_configs(:regular_user_books).update_column(:criteria, {"excluded_category_ids" => [7]})

          counts = References.call

          assert_equal 1, counts[5]
          assert_equal 3, counts[7]
          assert_equal 0, counts[99]
        end
```

`validator_test.rb`: build a small world and one valid plan, then one test per check. Setup:

```ruby
        setup do
          @fiction = categories(:books_fiction_genre)
          @nonfiction = categories(:books_nonfiction_genre)
          ::Books::Category.stubs(:protected_ids).returns([@fiction.id, @nonfiction.id])
          ::Books::Category.where(category_type: :genre).where.not(id: [@fiction.id, @nonfiction.id]).update_all(deleted: true)
          @sf = ::Books::Category.create!(name: "Science fiction", category_type: :genre)
          @fantasy = ::Books::Category.create!(name: "Fantasy", category_type: :genre)
          @sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          @ya = ::Books::Category.create!(name: "Young adult", category_type: :genre)
          @ebooks = ::Books::Category.create!(name: "Ebooks", category_type: :genre)
          @childrens = ::Books::Category.create!(name: "Children's books", category_type: :genre)
          @mg = ::Books::Category.create!(name: "Middle Grade", category_type: :genre)
          @hockey = ::Books::Category.create!(name: "Hockey", category_type: :subject)
          @assignments = Assignments.new([])
        end

        def plan(decisions = {}, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy"])
          PlanFile.new({"run" => "g1",
            "genres" => genres.map { |name| {"name" => name, "definition" => "x"} },
            "audiences" => PlanFile::AUDIENCES.map { |name, d| {"name" => name, "definition" => d} },
            "decisions" => valid_decisions.merge(decisions)})
        end

        def valid_decisions
          {@fiction.id => {"name" => "Fiction", "action" => "keep"},
           @nonfiction.id => {"name" => "Nonfiction", "action" => "keep"},
           @sf.id => {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"},
           @fantasy.id => {"name" => "Fantasy", "action" => "keep"},
           @sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Science Fiction", "Fantasy"]},
           @ya.id => {"name" => "Young adult", "action" => "audience", "as" => "Young Adult"},
           @childrens.id => {"name" => "Children's books", "action" => "audience", "as" => "Children's"},
           @mg.id => {"name" => "Middle Grade", "action" => "audience", "as" => "Middle Grade"},
           @ebooks.id => {"name" => "Ebooks", "action" => "delete"}}
        end

        def errors_for(plan) = Validator.call(plan: plan, assignments: @assignments).errors
```

`update_all(deleted: true)` here runs in the test database (the destructive-command hook only blocks `rails runner` against development).

Tests:

```ruby
        test "the valid plan passes" do
          assert_empty errors_for(plan)
        end

        test "a live genre missing from the plan is named" do
          late = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre)
          assert_includes errors_for(plan).join("\n"), "#{late.id} Hockey Romance"
        end

        test "a decision whose name no longer matches the live row" do
          @fantasy.update!(name: "Fantasy!")
          assert_match(/live name is "Fantasy!"/, errors_for(plan).join("\n"))
        end

        test "a merge into a name not on the lists" do
          assert_match(/Space Opera/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "merge", "into" => "Space Opera"})).join("\n"))
        end

        test "a merge into Fiction is refused" do
          assert_match(/Fiction/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "merge", "into" => "Fiction"})).join("\n"))
        end

        test "a list genre nobody produces" do
          assert_match(/Horror.*produced by no decision/, errors_for(plan(genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "Horror"])).join("\n"))
        end

        test "a list genre produced twice" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "rename", "to" => "Fantasy"}))
          assert_match(/Fantasy.*produced by 2 decisions/, errors.join("\n"))
        end

        test "a renaming split produces its primary" do
          history = ::Books::Category.create!(name: "History and Politics", category_type: :genre)
          decisions = {history.id => {"name" => "History and Politics", "action" => "split",
                                      "into" => ["History", {"subject" => "Hockey", "target_id" => @hockey.id}]}}

          assert_empty errors_for(plan(decisions, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "History"]))
        end

        test "a protected genre must be a plain keep" do
          assert_match(/Fiction is protected/, errors_for(plan(@fiction.id => {"name" => "Fiction", "action" => "rename", "to" => "Fictions"})).join("\n"))
        end

        test "the audiences must be exactly the three" do
          bad = plan
          bad.data["audiences"] = [{"name" => "Adult", "definition" => "x"}]
          assert_match(/audiences must be/, errors_for(bad).join("\n"))
        end

        test "a split needs two distinct targets and no location" do
          one = errors_for(plan(@sff.id => {"name" => "Science Fiction Fantasy", "action" => "split", "into" => ["Fantasy"]}))
          assert_match(/at least two/, one.join("\n"))
        end

        test "a subject target_id must be a live subject with that name" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "subject", "as" => "Hockey", "target_id" => @fantasy.id}))
          assert_match(/not a live subject/, errors.join("\n"))
        end

        test "a location needs a target_id" do
          assert_match(/needs a target_id/, errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "location", "as" => "Ohio"})).join("\n"))
        end

        test "also only on keep or rename, naming other list genres" do
          errors = errors_for(plan(@fantasy.id => {"name" => "Fantasy", "action" => "keep", "also" => ["Fantasy"]}))
          assert_match(/also/, errors.join("\n"))
        end

        test "worldcat must name a list entry" do
          errors = errors_for(plan(@ebooks.id => {"name" => "Ebooks", "action" => "delete", "worldcat" => "Plays"}))
          assert_match(/worldcat/, errors.join("\n"))
        end

        test "split answers must name the split's targets" do
          @assignments = Assignments.new([[1, @sff.id, ["Horror"]]])
          assert_match(/Horror/, errors_for(plan).join("\n"))
        end

        test "split answers for a genre that is not split" do
          @assignments = Assignments.new([[1, @fantasy.id, ["Fantasy"]]])
          assert_match(/not a split/, errors_for(plan).join("\n"))
        end
```

(Simplify the renaming-split test when writing it: build its decisions hash without `@sff` directly rather than mutating the plan. The point is that `History` is produced by the split, so no "produced by no decision" error.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/genre_plan/`
Expected: FAIL (uninitialized constants).

- [ ] **Step 3: Implement `PlanFile`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # The reviewed genre cleanup plan, config/books/genre_plan.yml
      # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §4).
      # AI drafts it in development, the owner edits it, production applies it
      # unchanged.
      class PlanFile
        DEFAULT_PATH = Rails.root.join("config", "books", "genre_plan.yml")
        VERSION = 1
        AUDIENCES = {
          "Children's" => "Written for readers up to about age 8.",
          "Middle Grade" => "Written for readers about 8 to 12.",
          "Young Adult" => "Written for readers about 12 to 18."
        }.freeze
        HEADER = "# Books genre cleanup plan (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md).\n" \
                 "# Drafted by `bin/rails categories:genres:draft` and `map`; reviewed and edited by hand.\n"

        attr_reader :data, :path

        def self.load(path = DEFAULT_PATH)
          path = Pathname(path)
          new(path.exist? ? YAML.safe_load_file(path) : {}, path: path, exists: path.exist?)
        end

        def initialize(data, path: DEFAULT_PATH, exists: true)
          @data = data || {}
          @data["decisions"] = (@data["decisions"] || {}).transform_keys(&:to_i)
          @path = Pathname(path)
          @exists = exists
        end

        def exists? = @exists

        def run = data["run"].to_s

        def genres = Array(data["genres"])

        def genre_names = genres.map { |g| g["name"] }

        def audiences = Array(data["audiences"])

        def audience_names = audiences.map { |a| a["name"] }

        def decisions = data["decisions"]

        def write(path = @path)
          path = Pathname(path)
          path.dirname.mkpath
          ordered = {"version" => VERSION, "run" => run, "genres" => genres, "audiences" => audiences,
                     "decisions" => decisions.sort.to_h}
          path.write(HEADER + ordered.to_yaml)
          @exists = true
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `Assignments`**

```ruby
# frozen_string_literal: true

require "csv"

module Services
  module Books
    module GenrePlan
      # Per-book answers for split genres, config/books/genre_split_assignments.csv
      # (spec §4, "Combined genres"). One row per book per split genre; targets
      # are names joined with "|", or "unknown" when the model did not know the book.
      class Assignments
        DEFAULT_PATH = Rails.root.join("config", "books", "genre_split_assignments.csv")
        HEADERS = %w[book_id category_id targets].freeze
        UNKNOWN = "unknown"

        def self.load(path = DEFAULT_PATH)
          path = Pathname(path)
          rows = path.exist? ? CSV.read(path, headers: true).map { |r| [r["book_id"].to_i, r["category_id"].to_i, parse(r["targets"])] } : []
          new(rows, path: path)
        end

        def self.parse(value) = (value == UNKNOWN) ? :unknown : value.to_s.split("|")

        def initialize(rows, path: DEFAULT_PATH)
          @rows = rows
          @path = Pathname(path)
        end

        def for(category_id)
          @rows.each_with_object({}) { |(book_id, cat, targets), out| out[book_id] = targets if cat == category_id }
        end

        def answered?(category_id, book_id) = @rows.any? { |b, c, _| b == book_id && c == category_id }

        def category_ids = @rows.map { |_, c, _| c }.uniq

        def each(&) = @rows.each(&)

        def append(rows, path = @path)
          path = Pathname(path)
          path.dirname.mkpath
          new_file = !path.exist?
          CSV.open(path, "a") do |csv|
            csv << HEADERS if new_file
            rows.each { |book_id, category_id, targets| csv << [book_id, category_id, (targets == :unknown) ? UNKNOWN : targets.join("|")] }
          end
          @rows.concat(rows)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement `References`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # How many saved searches and recommendation settings name each category
      # id (included or excluded). Ids are stored as integers or strings.
      class References
        KEYS = %w[included_category_ids excluded_category_ids].freeze

        def self.call
          counts = Hash.new(0)
          [::Books::SavedSearch, ::Books::RecommendationConfig].each do |model|
            model.find_each do |record|
              criteria = record.criteria || {}
              KEYS.flat_map { |key| Array(criteria[key]) }.filter_map { |v| Integer(v.to_s, exception: false) }.uniq
                .each { |id| counts[id] += 1 }
            end
          end
          counts
        end
      end
    end
  end
end
```

(Check the criteria column name on both models: `criteria` per their annotations.)

- [ ] **Step 6: Implement `Validator`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # The pre-apply checks of spec §4. Any error stops the apply.
      class Validator
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        ACTIONS = %w[keep rename merge audience subject location delete split].freeze
        BOOK_TYPE_NAMES = ::Books::Book::BOOK_TYPE_CATEGORY_NAMES

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def self.target_label(entry) = entry.is_a?(Hash) ? entry["subject"].to_s : entry.to_s

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          errors = []
          live = ::Books::Category.active.genre.pluck(:id, :name).to_h
          decisions = @plan.decisions

          missing = live.keys - decisions.keys
          errors << "live genres missing from the plan: #{missing.map { |id| "#{id} #{live[id]}" }.join(", ")}" if missing.any?
          if @plan.audience_names != PlanFile::AUDIENCES.keys
            errors << "audiences must be exactly #{PlanFile::AUDIENCES.keys.join(", ")}"
          end

          decisions.each do |id, decision|
            label = "#{id} #{decision["name"].inspect}"
            unless live.key?(id)
              errors << "#{label}: not a live genre"
              next
            end
            errors << "#{label}: the live name is #{live[id].inspect}" if live[id] != decision["name"]
            errors.concat(check(decision, label))
          end
          errors.concat(check_protected(decisions))
          errors.concat(check_producers(decisions))
          errors.concat(check_assignments(decisions))
          Result.new(success?: errors.empty?, data: nil, errors: errors)
        end

        private

        def list_names = @list_names ||= @plan.genre_names + @plan.audience_names

        def check(decision, label)
          errors = []
          action = decision["action"]
          return ["#{label}: unknown action #{action.inspect}"] unless ACTIONS.include?(action)

          case action
          when "keep"
            errors << "#{label}: keep, but #{decision["name"].inspect} is not on the genre list" unless @plan.genre_names.include?(decision["name"])
          when "rename"
            errors << "#{label}: rename to #{decision["to"].inspect}, which is not on the genre list" unless @plan.genre_names.include?(decision["to"])
          when "merge"
            errors.concat(check_target(decision["into"], label))
          when "audience"
            errors << "#{label}: #{decision["as"].inspect} is not an audience" unless @plan.audience_names.include?(decision["as"])
          when "subject"
            errors.concat(check_live(decision["target_id"], :subject, decision["as"], label)) if decision["target_id"]
          when "location"
            if decision["target_id"]
              errors.concat(check_live(decision["target_id"], :location, decision["as"], label))
            else
              errors << "#{label}: a location needs a target_id"
            end
          when "split"
            errors.concat(check_split(decision, label))
          end

          also = Array(decision["also"])
          if also.any?
            own = (action == "rename") ? decision["to"] : decision["name"]
            if !%w[keep rename].include?(action)
              errors << "#{label}: also is only for keep and rename"
            elsif also.any? { |name| !@plan.genre_names.include?(name) || name == own }
              errors << "#{label}: also must name other genres on the list"
            end
          end
          if decision["worldcat"] && !list_names.include?(decision["worldcat"])
            errors << "#{label}: worldcat #{decision["worldcat"].inspect} is not on a list"
          end
          errors
        end

        def check_target(name, label)
          return ["#{label}: #{name.inspect} is not on a list"] unless list_names.include?(name)
          return ["#{label}: nothing merges into #{name}"] if BOOK_TYPE_NAMES.include?(name)

          []
        end

        def check_live(id, type, name, label)
          category = ::Books::Category.active.where(category_type: type).find_by(id: id)
          return ["#{label}: target_id #{id} is not a live #{type}"] if category.nil?
          return ["#{label}: target_id #{id} is #{category.name.inspect}, not #{name.inspect}"] if name.present? && !category.name.casecmp?(name)

          []
        end

        def check_split(decision, label)
          into = Array(decision["into"])
          labels = into.map { |entry| self.class.target_label(entry) }
          errors = []
          errors << "#{label}: a split needs at least two targets" if into.size < 2
          errors << "#{label}: a split names a target twice" if labels.uniq.size != labels.size
          into.each do |entry|
            if entry.is_a?(Hash)
              errors.concat(check_live(entry["target_id"], :subject, entry["subject"], label))
            else
              errors.concat(check_target(entry, label))
            end
          end
          list_targets = into.grep(String)
          (decision["worldcat_terms"] || {}).each do |term, names|
            bad = Array(names) - list_targets
            errors << "#{label}: worldcat_terms #{term.inspect} names #{bad.join(", ")}, not this split's genres" if bad.any? || Array(names).empty?
          end
          errors
        end

        def check_protected(decisions)
          ::Books::Category.protected_ids.filter_map do |id|
            decision = decisions[id]
            next if decision.nil?

            "#{decision["name"]} is protected: it must be a plain keep" unless decision["action"] == "keep" && Array(decision["also"]).empty?
          end
        end

        # The first split (by category id) whose primary nothing else produces
        # renames to it; later splits with the same primary merge into it.
        # DecisionBuilder makes the same choice in the same order.
        def check_producers(decisions)
          producers = Hash.new(0)
          decisions.sort.each do |_id, d|
            case d["action"]
            when "keep" then producers[d["name"]] += 1
            when "rename" then producers[d["to"]] += 1
            when "audience" then producers[d["as"]] += 1
            end
          end
          decisions.sort.each do |_id, d|
            next unless d["action"] == "split"

            primary = Array(d["into"]).first
            producers[primary] += 1 if primary.is_a?(String) && producers[primary].zero?
          end
          ::Books::Category.active.audience.where(name: @plan.audience_names).pluck(:name).each { |name| producers[name] += 1 }

          list_names.filter_map do |name|
            count = producers[name]
            next if count == 1

            count.zero? ? "#{name} is produced by no decision" : "#{name} is produced by #{count} decisions"
          end
        end

        def check_assignments(decisions)
          errors = []
          @assignments.each do |book_id, category_id, targets|
            decision = decisions[category_id]
            if decision.nil? || decision["action"] != "split"
              errors << "split answers for #{category_id}, which is not a split"
              next
            end
            next if targets == :unknown

            allowed = Array(decision["into"]).map { |entry| self.class.target_label(entry) }
            bad = targets - allowed
            errors << "book #{book_id} on #{decision["name"]}: #{bad.join(", ")} is not one of its targets" if bad.any?
          end
          errors.uniq
        end
      end
    end
  end
end
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/lib/services/books/genre_plan/`
Expected: PASS. Then `CI=1 bin/rails zeitwerk:check` (new `app/lib` directory). Expected: "All is good!".

- [ ] **Step 8: Commit**

```bash
git add -A app test
git commit -m "Genre cleanup: plan file, split answers, reference counts and the validator

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Building decisions, cleaning criteria, and `apply`

**Files:**
- Create: `app/lib/services/books/genre_plan/decision_builder.rb`
- Create: `app/lib/services/books/genre_plan/criteria_cleaner.rb`
- Create: `app/lib/services/books/genre_plan/apply.rb`
- Test: `test/lib/services/books/genre_plan/decision_builder_test.rb`, `criteria_cleaner_test.rb`, `apply_test.rb`

**Interfaces:**
- Consumes: `PlanFile`, `Assignments`, `Validator` (Task 9); `CategoryCleanupDecision` `split`, `extra_target_ids`, `split_assignments` and `Applier` (Task 6).
- Produces:
  - `DecisionBuilder.call(plan:, assignments:) -> Result` with `data: {created: Integer, unassigned_split_books: Integer}`; writes stage-`genres` decisions for `plan.run`; does nothing (created 0) when the run already has stage-`genres` decisions.
  - `CriteriaCleaner.call(deleted_ids:) -> Result` with `data: {saved_searches: [ids], recommendation_configs: [ids]}`.
  - `Apply.call(plan:, assignments:) -> Result` with `data: {applier: Hash, cleaned: Hash, unassigned_split_books: Integer}`; failure with the validator's errors, or `["no plan file at ..."]`.

- [ ] **Step 1: Write the failing tests**

`decision_builder_test.rb` (copy `setup`, `plan`, `valid_decisions` and the `@assignments` setup verbatim from `validator_test.rb`, Task 9 Step 1). Tests:

```ruby
        test "each action becomes the decisions of spec §4" do
          result = DecisionBuilder.call(plan: plan, assignments: @assignments)
          by = CategoryCleanupDecision.for_run("g1").where(stage: "genres").group_by(&:category_id)

          assert_equal %w[keep], by[@fantasy.id].map(&:action)
          assert_equal [["rename", "Science Fiction"]], by[@sf.id].map { |d| [d.action, d.new_name] }
          assert_equal %w[delete], by[@ebooks.id].map(&:action)
          ya = by[@ya.id].index_by(&:action)
          assert_equal Category.category_types["audience"], ya["retype"].new_category_type
          assert_equal "Young Adult", ya["rename"].new_name
          split = by[@sff.id].sole
          assert_equal "split", split.action
          assert_equal @sf.id, split.target_category_id          # merging mode: Science Fiction is produced by the rename
          assert_equal [@fantasy.id], split.extra_target_ids
          assert result.success?
        end

        test "a subject with a target_id merges into it; without, it retypes and renames" do
          decisions = {@ebooks.id => {"name" => "Ebooks", "action" => "subject", "as" => "Hockey", "target_id" => @hockey.id}}
          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)
          merge = CategoryCleanupDecision.find_by!(category: @ebooks, run: "g1")
          assert_equal [@hockey.id, "merge"], [merge.target_category_id, merge.action]
        end

        test "split answers become ids; unknown answers are left out" do
          book = books_books(:war_and_peace)
          other = books_books(:crime_and_punishment)
          @assignments = Assignments.new([[book.id, @sff.id, ["Fantasy"]], [other.id, @sff.id, :unknown]])

          DecisionBuilder.call(plan: plan, assignments: @assignments)

          split = CategoryCleanupDecision.find_by!(category: @sff, run: "g1")
          assert_equal({book.id.to_s => [@fantasy.id]}, split.split_assignments)
        end

        test "a renaming split names its primary" do
          history = ::Books::Category.create!(name: "History and Politics", category_type: :genre)
          decisions = {history.id => {"name" => "History and Politics", "action" => "split",
                                      "into" => ["History", {"subject" => "Hockey", "target_id" => @hockey.id}]}}

          DecisionBuilder.call(plan: plan(decisions, genres: ["Fiction", "Nonfiction", "Science Fiction", "Fantasy", "History"]), assignments: @assignments)

          split = CategoryCleanupDecision.find_by!(category: history, run: "g1")
          assert_nil split.target_category_id
          assert_equal "History", split.new_name
          assert_equal [@hockey.id], split.extra_target_ids
        end

        test "keep with also stores the extra targets" do
          decisions = {@fantasy.id => {"name" => "Fantasy", "action" => "keep", "also" => ["Science Fiction"]}}
          DecisionBuilder.call(plan: plan(decisions), assignments: @assignments)
          assert_equal [@sf.id], CategoryCleanupDecision.find_by!(category: @fantasy, run: "g1").extra_target_ids
        end

        test "a second build writes nothing" do
          DecisionBuilder.call(plan: plan, assignments: @assignments)
          assert_no_difference -> { CategoryCleanupDecision.count } do
            assert_equal 0, DecisionBuilder.call(plan: plan, assignments: @assignments).data[:created]
          end
        end

        test "books on a split genre with no answer are counted" do
          CategoryItem.create!(category: @sff, item: books_books(:war_and_peace))
          assert_equal 1, DecisionBuilder.call(plan: plan, assignments: @assignments).data[:unassigned_split_books]
        end
```

`criteria_cleaner_test.rb`:

```ruby
        test "removes deleted ids from included and excluded lists, in either storage shape" do
          touched = saved_searches(:books_public)
          untouched = saved_searches(:books_private)
          config = recommendation_configs(:regular_user_books)
          touched.update_column(:criteria, {"genre_match_mode" => "any", "included_category_ids" => [5, "9"], "excluded_category_ids" => ["5"]})
          untouched.update_column(:criteria, {"included_category_ids" => [9]})
          config.update_column(:criteria, {"excluded_category_ids" => [5], "max_ranked_position" => 500})

          result = CriteriaCleaner.call(deleted_ids: [5])

          assert_equal ["9"], touched.reload.criteria["included_category_ids"].map(&:to_s)
          assert_empty touched.criteria["excluded_category_ids"]
          assert_equal "any", touched.criteria["genre_match_mode"]
          assert_equal [9], untouched.reload.criteria["included_category_ids"]
          assert_empty config.reload.criteria["excluded_category_ids"]
          assert_equal 500, config.criteria["max_ranked_position"]
          assert_equal [touched.id], result.data[:saved_searches]
          assert_equal [config.id], result.data[:recommendation_configs]
        end
```

`apply_test.rb` (copy `setup`, `plan`, `valid_decisions` and the `@assignments` setup verbatim from `validator_test.rb`, Task 9 Step 1):

```ruby
        test "with no plan file it says so and changes nothing" do
          result = Apply.call(plan: PlanFile.load(Rails.root.join("tmp", "missing.yml")), assignments: Assignments.new([]))
          refute result.success?
          assert_match(/no plan file/, result.errors.first)
        end

        test "an invalid plan writes nothing" do
          late = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre)
          assert_no_difference -> { CategoryCleanupDecision.count } do
            result = Apply.call(plan: plan, assignments: @assignments)
            refute result.success?
            assert_match(/#{late.id} Hockey Romance/, result.errors.join)
          end
        end

        test "applies end to end, cleans saved searches of deleted genres, and is idempotent" do
          book = books_books(:war_and_peace)
          CategoryItem.create!(category: @sff, item: book)
          search = saved_searches(:books_public)
          search.update_column(:criteria, {"included_category_ids" => [@ebooks.id, @fantasy.id]})

          first = Apply.call(plan: plan, assignments: @assignments)
          assert first.success?, first.errors.inspect
          assert @ebooks.reload.deleted?
          assert_equal "Science Fiction", @sf.reload.name
          assert @ya.reload.audience?
          assert_equal "Young Adult", @ya.name
          assert_equal @sf, @sff.reload.merged_into
          assert CategoryItem.exists?(category: @fantasy, item: book)
          assert_equal [@fantasy.id], search.reload.criteria["included_category_ids"].map(&:to_i)
          assert_equal [search.id], first.data[:cleaned][:saved_searches]

          assert_no_difference -> { [CategoryCleanupDecision.count, CategoryItem.count] } do
            second = Apply.call(plan: plan, assignments: @assignments)
            assert second.success?, second.errors.inspect
          end
        end
```

The second `Apply` must succeed: after the first apply the live genres differ (Ebooks deleted, Young adult retyped, SFF merged, Science fiction renamed), so the validator would report decision names that no longer match. Handle this in `Apply`: when the run already has stage-`genres` decisions, skip the validator and the builder and only run the Applier and the cleaner (both idempotent). Test that path explicitly as above.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/genre_plan/`
Expected: FAIL (uninitialized constants).

- [ ] **Step 3: Implement `DecisionBuilder`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # Turns the reviewed plan into stage-`genres` CategoryCleanupDecision rows
      # for the run (spec §4 table). Writes nothing when the run already has them.
      class DecisionBuilder
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        STAGE = "genres"

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          scope = ::CategoryCleanupDecision.for_run(@plan.run).where(stage: STAGE)
          return Result.new(success?: true, data: {created: 0, unassigned_split_books: 0}, errors: []) if scope.exists?

          created = 0
          unassigned = 0
          categories = ::Books::Category.where(id: @plan.decisions.keys).index_by(&:id)
          ::CategoryCleanupDecision.transaction do
            @plan.decisions.sort.each do |id, decision|
              category = categories.fetch(id)
              rows_for(category, decision).each do |attrs|
                ::CategoryCleanupDecision.create!(base(category, decision).merge(attrs))
                created += 1
              end
              unassigned += unassigned_books(category) if decision["action"] == "split"
            end
          end
          Result.new(success?: true, data: {created: created, unassigned_split_books: unassigned}, errors: [])
        end

        private

        def base(category, decision)
          {category: category, run: @plan.run, stage: STAGE, decided_by: :ai, reason: decision["reason"],
           category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)}
        end

        def rows_for(category, decision)
          case decision["action"]
          when "keep" then [{action: :keep, extra_target_ids: ids_for(decision["also"])}]
          when "rename" then [{action: :rename, new_name: decision["to"], extra_target_ids: ids_for(decision["also"])}]
          when "merge" then [{action: :merge, target_category_id: producer_id(decision["into"])}]
          when "audience" then retype_rows(category, "audience", decision["as"])
          when "subject"
            decision["target_id"] ? [{action: :merge, target_category_id: decision["target_id"]}] : retype_rows(category, "subject", decision["as"])
          when "location" then [{action: :merge, target_category_id: decision["target_id"]}]
          when "delete" then [{action: :delete}]
          when "split" then [split_row(category, decision)]
          end
        end

        def retype_rows(category, type, new_name)
          rows = [{action: :retype, new_category_type: ::Category.category_types.fetch(type)}]
          rows << {action: :rename, new_name: new_name} if new_name.present? && new_name != category.name
          rows
        end

        def split_row(category, decision)
          into = Array(decision["into"])
          primary = into.first
          renaming = renaming_split_ids.include?(category.id)
          extras = into.drop(1).map { |entry| target_id(entry) }
          primary_id = renaming ? category.id : producer_id(primary)
          ids_by_label = into.each_with_index.to_h { |entry, i| [Validator.target_label(entry), i.zero? ? primary_id : extras[i - 1]] }
          answers = @assignments.for(category.id).each_with_object({}) do |(book_id, labels), out|
            out[book_id.to_s] = labels.map { |label| ids_by_label.fetch(label) } unless labels == :unknown
          end
          row = {action: :split, extra_target_ids: extras, split_assignments: answers}
          renaming ? row.merge(new_name: primary) : row.merge(target_category_id: primary_id)
        end

        def target_id(entry) = entry.is_a?(Hash) ? entry["target_id"].to_i : producer_id(entry)

        def ids_for(names) = Array(names).map { |name| producer_id(name) }

        # List name -> the id of the category that ends as that entry.
        def producer_id(name)
          producers.fetch(name) { raise ArgumentError, "#{name.inspect} is produced by no decision" }
        end

        def producers = build_producers.first

        def renaming_split_ids = build_producers.last

        # [list name -> producing category id, Set of renaming split ids]. The
        # first split (by id) whose primary nothing else produces renames to it;
        # Validator#check_producers makes the same choice in the same order.
        def build_producers
          @build_producers ||= begin
            map = {}
            renaming = Set.new
            @plan.decisions.sort.each do |id, d|
              case d["action"]
              when "keep" then map[d["name"]] = id
              when "rename" then map[d["to"]] = id
              when "audience" then map[d["as"]] = id
              end
            end
            @plan.decisions.sort.each do |id, d|
              next unless d["action"] == "split"

              primary = Array(d["into"]).first
              next unless primary.is_a?(String) && !map.key?(primary)

              map[primary] = id
              renaming << id
            end
            ::Books::Category.active.audience.where(name: @plan.audience_names).pluck(:name, :id).each { |name, id| map[name] ||= id }
            [map, renaming]
          end
        end

        def unassigned_books(category)
          answered = @assignments.for(category.id).keys.to_set
          category.category_items.where(item_type: "Books::Book").pluck(:item_id).count { |book_id| !answered.include?(book_id) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `CriteriaCleaner`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # A soft-deleted category in a saved search silently breaks it: included,
      # the search returns nothing; excluded, it does nothing. Removes the ids of
      # genres the plan deleted (spec §6). Merged and retyped ids keep working
      # and are left alone.
      class CriteriaCleaner
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KEYS = References::KEYS

        def self.call(deleted_ids:)
          new(deleted_ids).call
        end

        def initialize(deleted_ids)
          @deleted = deleted_ids.map(&:to_i).to_set
        end

        def call
          changed = {saved_searches: [], recommendation_configs: []}
          return Result.new(success?: true, data: changed, errors: []) if @deleted.empty?

          {saved_searches: ::Books::SavedSearch, recommendation_configs: ::Books::RecommendationConfig}.each do |key, model|
            model.find_each do |record|
              criteria = (record.criteria || {}).dup
              touched = false
              KEYS.each do |field|
                values = Array(criteria[field])
                kept = values.reject { |v| @deleted.include?(Integer(v.to_s, exception: false)) }
                next if kept.size == values.size

                criteria[field] = kept
                touched = true
              end
              next unless touched

              # update_column: criteria is the owner's data, not a form submission,
              # and nothing else about the record changes.
              record.update_column(:criteria, criteria)
              changed[key] << record.id
            end
          end
          Result.new(success?: true, data: changed, errors: [])
        end
      end
    end
  end
end
```

- [ ] **Step 5: Implement `Apply`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:apply` (spec §5 step 7): validate, write the
      # decisions, apply them, then strip deleted genres from saved criteria.
      # Re-running after a complete or partial apply only re-runs the applier
      # and the cleaner, both idempotent; the plan's names no longer match the
      # live rows by then, so the validator and builder are skipped.
      class Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          return failure(["no plan file at #{@plan.path}"]) unless @plan.exists?

          unassigned = 0
          unless decisions.exists?
            validation = Validator.call(plan: @plan, assignments: @assignments)
            return failure(validation.errors) unless validation.success?

            unassigned = DecisionBuilder.call(plan: @plan, assignments: @assignments).data[:unassigned_split_books]
          end

          applier = ::Services::CategoryCleanup::Applier.call(run: @plan.run)
          deleted = decisions.applied.action_delete.pluck(:category_id)
          cleaned = CriteriaCleaner.call(deleted_ids: deleted).data
          Result.new(success?: true, data: {applier: applier.data, cleaned: cleaned, unassigned_split_books: unassigned}, errors: [])
        end

        private

        def decisions = ::CategoryCleanupDecision.for_run(@plan.run).where(stage: DecisionBuilder::STAGE)

        def failure(errors) = Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/genre_plan/ test/lib/services/category_cleanup/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A app test
git commit -m "Genre cleanup: build decisions from the plan, apply, clean saved criteria

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The three AI tasks

**Files:**
- Create: `app/lib/services/ai/tasks/books/genre_draft_task.rb`
- Create: `app/lib/services/ai/tasks/books/genre_map_task.rb`
- Create: `app/lib/services/ai/tasks/books/genre_split_check_task.rb`
- Test: `test/lib/services/ai/tasks/books/genre_draft_task_test.rb`, `genre_map_task_test.rb`, `genre_split_check_task_test.rb`

**Interfaces:**
- Produces:
  - `GenreDraftTask.new(entries:)`; `Entry = Struct.new(:name, :books, :samples, :references, keyword_init: true)`; success data `{genres: [{name:, definition:}], notes: [String]}`. `:premium` role.
  - `GenreMapTask.new(entries:, genres:, audiences:)`; `Entry = Struct.new(:key, :name, :books, :samples, :references, :worldcat_terms, keyword_init: true)`; `genres`/`audiences` are `[{"name","definition"}]`; success data `{results: {key => {action:, to:, into:, into_subjects:, as:, also:, worldcat:, worldcat_terms: {term => [names]}, reason:}}}`. Fails the whole batch on a missing key, unknown action, or a list name not on the lists. `:premium` role.
  - `GenreSplitCheckTask.new(genre:, targets:, books:)`; `Book = Struct.new(:key, :title, :authors, :year, :description, :genres, keyword_init: true)`; success data `{results: {key => [names] | :unknown}}`. Fails the batch on a missing key or a name not in `targets`. `:standard` role.

The three share the parentless plumbing of `WorldCatGenreMappingTask` (`validate_parent!` empty, `task_provider = :openai`, `chat_type = :analysis`, `response_format = {type: "json_object"}`, a `failure(message)` helper). Follow that file's structure exactly.

- [ ] **Step 1: Write the failing tests**

`genre_draft_task_test.rb`:

```ruby
require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        class GenreDraftTaskTest < ActiveSupport::TestCase
          Entry = GenreDraftTask::Entry

          setup do
            @task = GenreDraftTask.new(entries: [
              Entry.new(name: "Science fiction", books: 7181, samples: ["Dune by Frank Herbert"], references: 100),
              Entry.new(name: "Ebooks", books: 52, samples: [], references: 0)
            ])
          end

          def genres(*names) = names.map { |n| {name: n, definition: "x"} }

          test "runs on the premium role" do
            assert_equal :premium, @task.send(:task_role)
          end

          test "the prompt carries the rules and every genre with its counts" do
            system = @task.send(:system_message)
            assert_includes system, "what the book is about"
            assert_includes system, "40 to 60"
            assert_includes system, "Romantasy"
            assert_includes system, "Fiction, Nonfiction, Religion & Spirituality and Poetry"
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Science fiction (7181 books, used by 100 saved searches)"
            assert_includes prompt, "Dune by Frank Herbert"
          end

          test "accepts a list that keeps the protected genres" do
            outcome = @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Nonfiction", "Religion & Spirituality", "Poetry", "Science Fiction"), notes: ["Ebooks is a format."]}})
            assert outcome.success?
            assert_equal 5, outcome.data[:genres].size
            assert_equal ["Ebooks is a format."], outcome.data[:notes]
          end

          test "fails when a protected genre is missing or a name repeats" do
            refute @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Science Fiction"), notes: []}}).success?
            refute @task.send(:process_and_persist, {parsed: {genres: genres("Fiction", "Nonfiction", "Religion & Spirituality", "Poetry", "Poetry"), notes: []}}).success?
          end
        end
      end
    end
  end
end
```

`genre_map_task_test.rb`:

```ruby
          Entry = GenreMapTask::Entry

          setup do
            @genres = [{"name" => "Science Fiction", "definition" => "x"}, {"name" => "Fantasy", "definition" => "y"}]
            @audiences = [{"name" => "Children's", "definition" => "z"}]
            @task = GenreMapTask.new(genres: @genres, audiences: @audiences, entries: [
              Entry.new(key: "1", name: "Science Fiction Fantasy", books: 252, samples: [], references: 0, worldcat_terms: ["Fantasy och science fiction"]),
              Entry.new(key: "2", name: "Ebooks", books: 52, samples: [], references: 3, worldcat_terms: [])
            ])
          end

          def result(overrides = {})
            {key: "2", action: "delete", to: nil, into: [], into_subjects: [], as: nil, also: [], worldcat: nil, worldcat_terms: [], reason: "A format."}.merge(overrides)
          end

          test "the prompt lists the genres, audiences, each genre's WorldCat terms and the split rule" do
            assert_includes @task.send(:system_message), "split"
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "Science Fiction: x"
            assert_includes prompt, "Children's: z"
            assert_includes prompt, "[1] \"Science Fiction Fantasy\" (252 books"
            assert_includes prompt, "WorldCat terms: Fantasy och science fiction"
          end

          test "accepts a split with worldcat_terms and a delete" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [
              result(key: "1", action: "split", into: ["Science Fiction", "Fantasy"],
                worldcat_terms: [{term: "Fantasy och science fiction", targets: ["Science Fiction", "Fantasy"]}]),
              result
            ]}})
            assert outcome.success?, outcome.error
            assert_equal ["Science Fiction", "Fantasy"], outcome.data[:results]["1"][:into]
            assert_equal({"Fantasy och science fiction" => ["Science Fiction", "Fantasy"]}, outcome.data[:results]["1"][:worldcat_terms])
          end

          test "fails the batch on an off-list name, an unknown action, or a missing key" do
            refute @task.send(:process_and_persist, {parsed: {results: [result(key: "1", action: "merge", into: ["Space Opera"]), result]}}).success?
            refute @task.send(:process_and_persist, {parsed: {results: [result(key: "1", action: "explode"), result]}}).success?
            refute @task.send(:process_and_persist, {parsed: {results: [result]}}).success?
          end

          test "reads OpenAI::BaseModel results" do
            model = GenreMapTask::MapResult.new(result(key: "1", action: "merge", into: ["Fantasy"]))
            outcome = @task.send(:process_and_persist, {parsed: {results: [model, result]}})
            assert_equal ["Fantasy"], outcome.data[:results]["1"][:into]
          end
```

`genre_split_check_task_test.rb`:

```ruby
          Book = GenreSplitCheckTask::Book

          setup do
            @task = GenreSplitCheckTask.new(genre: "Science Fiction Fantasy", targets: ["Science Fiction", "Fantasy"], books: [
              Book.new(key: "1", title: "The Lord of the Rings", authors: ["J. R. R. Tolkien"], year: 1954, description: nil, genres: ["Fantasy"]),
              Book.new(key: "2", title: "Obscure Pamphlet", authors: [], year: nil, description: nil, genres: [])
            ])
          end

          test "runs on the standard role and shows each book's facts" do
            assert_equal :standard, @task.send(:task_role)
            prompt = @task.send(:user_prompt)
            assert_includes prompt, "[1] The Lord of the Rings by J. R. R. Tolkien (1954)"
            assert_includes prompt, "Other genres: Fantasy"
          end

          test "accepts a subset, an empty answer and unknown" do
            outcome = @task.send(:process_and_persist, {parsed: {results: [
              {key: "1", targets: ["Fantasy"], unknown: false, reason: "High fantasy."},
              {key: "2", targets: [], unknown: true, reason: "Not known."}
            ]}})
            assert outcome.success?
            assert_equal({"1" => ["Fantasy"], "2" => :unknown}, outcome.data[:results])
          end

          test "fails the batch on a target that is not offered" do
            refute @task.send(:process_and_persist, {parsed: {results: [
              {key: "1", targets: ["Horror"], unknown: false, reason: ""}, {key: "2", targets: [], unknown: true, reason: ""}
            ]}}).success?
          end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/`
Expected: FAIL (uninitialized constants).

- [ ] **Step 3: Implement `GenreDraftTask`**

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Drafts the tight genre list from every live genre
        # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §3, §5).
        # Parentless: the result is a data file the owner edits.
        class GenreDraftTask < BaseTask
          Entry = Struct.new(:name, :books, :samples, :references, keyword_init: true)
          PROTECTED = ["Fiction", "Nonfiction", "Religion & Spirituality", "Poetry"].freeze

          attr_reader :entries

          def initialize(entries:, parent: nil, provider: nil, model: nil)
            @entries = entries
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :premium

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM
              You are designing the genre list of a book website that ranks the greatest books. The current genres came from Goodreads shelves and mix many kinds of label. Propose a short, deliberate list.

              A genre names what kind of book it is, never what the book is about. It is either a form (short stories, plays, graphic novels, letters and diaries, picture books) or a convention readers shelve by (mystery, fantasy, memoir, true crime, cookbooks).

              Not genres, so leave them off the list:
              - Topics and time periods (Vegetarian, Trucks, Victorian, Ancient): these become subjects.
              - Places (South Dakota): these become locations.
              - Audience (Children's, Middle Grade, Young Adult, Adult, teen): audience is a separate list the site already has.
              - Moods, romance tropes and reception labels (Dark, Cozy, Slow Burn, Banned Books, Summer Reads).
              - Formats (Ebooks).
              - Creator identity (Latino, Latinx, Hispanic, AAPI).
              - LGBTQ+: it is a subject.
              - Drama: on this site it is a shelf for "dramatic" books; plays are the genre Plays.

              Fold a subgenre into its parent unless readers widely shelve by it AND it holds enough books to stand alone. "Widely shelved" means in today's book market, not only in this catalog, which leans to the canon: keep Romantasy, one of today's best-selling genres. Aim for 40 to 60 genres.

              A name that combines two genres readers look for separately (Science Fiction Fantasy, Rom Com) is not itself on the list: its halves are. A compound that names one convention (Thriller & Suspense, Comics & Graphic Novels, Folklore & Fairy Tales) can be.

              Always include Fiction, Nonfiction, Religion & Spirituality and Poetry, with exactly those names: they are the site's book types.

              Names are consistent Title Case ("Science Fiction", "Historical Fiction"). Give each genre a one-line definition.

              In "notes", say what should happen to each current genre with more than 1,000 books that is not on your list, one short line each.
            SYSTEM
          end

          def user_prompt
            lines = ["Current genres (books carrying it; saved searches using it):"]
            entries.each do |entry|
              lines << "- #{entry.name} (#{entry.books} books, used by #{entry.references} saved searches)"
              lines << "  e.g. #{entry.samples.join("; ")}" if entry.samples.any?
            end
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            parsed = provider_response[:parsed]
            genres = Array(value(parsed, :genres)).map { |g| {name: value(g, :name).to_s.strip, definition: value(g, :definition).to_s.strip} }
            notes = Array(value(parsed, :notes)).map { |n| n.to_s.strip }.reject(&:blank?)
            names = genres.map { |g| g[:name] }

            return failure("The draft has no genres") if names.empty?
            return failure("The draft repeats #{names.tally.select { |_, n| n > 1 }.keys.join(", ")}") if names.uniq.size != names.size
            missing = PROTECTED - names
            return failure("The draft is missing #{missing.join(", ")}") if missing.any?

            Services::Ai::Result.new(success: true, data: {genres: genres, notes: notes}, ai_chat: chat)
          end

          def value(raw, key)
            return raw[key] || raw[key.to_s] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class DraftGenre < OpenAI::BaseModel
            required :name, String, doc: "The genre's name, Title Case"
            required :definition, String, doc: "One line"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :genres, OpenAI::ArrayOf[DraftGenre], doc: "The proposed list"
            required :notes, OpenAI::ArrayOf[String], doc: "What happens to each large genre not kept"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Implement `GenreMapTask`**

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Gives each current genre exactly one fate against the owner's edited
        # lists (spec §3, §4, §5 step 3). Fails the whole batch on any answer
        # naming something off the lists; the batch is retried on the next run.
        class GenreMapTask < BaseTask
          Entry = Struct.new(:key, :name, :books, :samples, :references, :worldcat_terms, keyword_init: true)
          ACTIONS = %w[keep rename merge audience subject location delete split].freeze

          attr_reader :entries, :genres, :audiences

          def initialize(entries:, genres:, audiences:, parent: nil, provider: nil, model: nil)
            @entries = entries
            @genres = genres
            @audiences = audiences
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :premium

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def genre_names = genres.map { |g| g["name"] }

          def audience_names = audiences.map { |a| a["name"] }

          def list_names = genre_names + audience_names

          def system_message
            <<~SYSTEM
              You are mapping a book website's current genres onto its new, curated genre and audience lists. Give every current genre exactly one action:

              - "keep": it is on the genre list under exactly this name.
              - "rename": it is on the genre list under a different spelling; put the list name in "to".
              - "merge": its books belong under one list genre or audience; put that name as the only entry of "into". Use it for subgenres (Space Opera into Science Fiction), twins, and compounds whose second half adds nothing (Cozy Fantasy into Fantasy).
              - "audience": it is one of the audiences; put the audience name in "as".
              - "subject": it is a topic, a time period, LGBTQ+, or a real mood, trope or reception label (Banned Books); "as" may give a cleaner subject name. Gay fiction and Lesbian Fantasy go to the subject "LGBTQ+".
              - "location": it is a place; put the place's name in "as".
              - "delete": formats (Ebooks), noise (Own, Apple), labels with no meaning as a subject (Summer Reads, Slow Burn), creator identity (Latino, Latinx, Hispanic, AAPI), and Drama (a shelf for "dramatic" books, not plays; set "worldcat" to "Plays").
              - "split": it combines two things readers look for separately (Science Fiction Fantasy, Rom Com, History and Politics, Hockey Romance). Put its genre or audience halves in "into", primary first, and subject halves in "into_subjects". For each of its WorldCat terms, list in "worldcat_terms" which of its genre or audience halves that term supports ("History" supports only History).

              A kept or renamed genre that by definition is always also other list genres names them in "also" (Romantasy: also Romance and Fantasy). Use it only when every book of the genre is necessarily the others.

              Never rename, merge, split or delete Fiction, Nonfiction, Religion & Spirituality or Poetry: keep them. Never merge into Fiction or Nonfiction.
              When saved searches use a genre, prefer "subject" over "delete": a subject keeps those searches working.
              Every name you put in "to", "into", "also", "worldcat" or "worldcat_terms" must be copied exactly from the lists. Give a one-sentence reason.
            SYSTEM
          end

          def user_prompt
            lines = ["Genre list:"]
            genres.each { |g| lines << "- #{g["name"]}: #{g["definition"]}" }
            lines << "" << "Audience list:"
            audiences.each { |a| lines << "- #{a["name"]}: #{a["definition"]}" }
            lines << "" << "Current genres to map:"
            entries.each do |entry|
              lines << "[#{entry.key}] #{entry.name.inspect} (#{entry.books} books, used by #{entry.references} saved searches)"
              lines << "  e.g. #{entry.samples.join("; ")}" if entry.samples.any?
              lines << "  WorldCat terms: #{entry.worldcat_terms.join("; ")}" if entry.worldcat_terms.any?
            end
            lines << "" << "Return exactly one result per genre, with its number in \"key\"."
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            keys = entries.map(&:key)
            results = {}
            Array(value(provider_response[:parsed], :results)).each do |raw|
              parsed = normalize(raw)
              next if !keys.include?(parsed[:key]) || results.key?(parsed[:key])

              results[parsed[:key]] = parsed
            end
            missing = keys - results.keys
            return failure("No result for #{missing.join(", ")}") if missing.any?

            results.each_value do |r|
              return failure("Unknown action #{r[:action].inspect} for #{r[:key]}") unless ACTIONS.include?(r[:action])
              named = [r[:to], r[:worldcat], *r[:into], *r[:also], *r[:worldcat_terms].values.flatten].compact
              named << r[:as] if r[:action] == "audience"
              off = named - list_names
              return failure("#{off.first.inspect} is not on the lists (genre #{r[:key]})") if off.any?
            end
            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def normalize(raw)
            strings = ->(key) { Array(value(raw, key)).map { |v| v.to_s.strip }.reject(&:blank?) }
            terms = Array(value(raw, :worldcat_terms)).to_h { |t| [value(t, :term).to_s, Array(value(t, :targets)).map(&:to_s)] }
            {key: value(raw, :key).to_s, action: value(raw, :action).to_s, to: value(raw, :to).presence, into: strings.call(:into),
             into_subjects: strings.call(:into_subjects), as: value(raw, :as).presence, also: strings.call(:also),
             worldcat: value(raw, :worldcat).presence, worldcat_terms: terms, reason: value(raw, :reason).to_s}
          end

          def value(raw, key)
            return raw[key] || raw[key.to_s] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class WorldcatTerm < OpenAI::BaseModel
            required :term, String
            required :targets, OpenAI::ArrayOf[String]
          end

          class MapResult < OpenAI::BaseModel
            required :key, String, doc: "The genre's number"
            required :action, String, doc: "keep, rename, merge, audience, subject, location, delete or split"
            required :to, String, nil?: true, doc: "For rename: the list name"
            required :into, OpenAI::ArrayOf[String], doc: "For merge: one list name. For split: its genre or audience halves, primary first"
            required :into_subjects, OpenAI::ArrayOf[String], doc: "For split: its subject halves"
            required :as, String, nil?: true, doc: "For audience: the audience. For subject or location: the name"
            required :also, OpenAI::ArrayOf[String], doc: "For keep or rename: list genres it always also is"
            required :worldcat, String, nil?: true, doc: "Where this genre's WorldCat terms should point instead, or null"
            required :worldcat_terms, OpenAI::ArrayOf[WorldcatTerm], doc: "For split: which halves each WorldCat term supports"
            required :reason, String, doc: "One sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[MapResult], doc: "One per genre"
          end
        end
      end
    end
  end
end
```

Note: `value(raw, :as)` on an `OpenAI::BaseModel` calls `raw.public_send(:as)`; `as` is a valid attribute name. If `OpenAI::BaseModel` rejects `as` as a field name, rename it to `as_name` in the schema and in `normalize`, and keep the hash key `:as`.

- [ ] **Step 5: Implement `GenreSplitCheckTask`**

```ruby
# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # For each book on a combined genre, which of its halves fit
        # (spec §4, "Combined genres"; §5 step 4).
        class GenreSplitCheckTask < BaseTask
          Book = Struct.new(:key, :title, :authors, :year, :description, :genres, keyword_init: true)

          attr_reader :genre, :targets, :books

          def initialize(genre:, targets:, books:, parent: nil, provider: nil, model: nil)
            @genre = genre
            @targets = targets
            @books = books
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM
              A book website is splitting the combined genre "#{genre}" into: #{targets.join(", ")}.
              For each book below, list in "targets" every one of those that truly describes the book, using the names exactly. A book can fit one, several, or none (a physics book wrongly tagged "Science Fiction Fantasy" fits none).
              Use what you know about the book. If you do not recognise it and its details do not settle it, set "unknown" to true and leave "targets" empty.
            SYSTEM
          end

          def user_prompt
            lines = ["Books:"]
            books.each do |book|
              by = book.authors.any? ? " by #{book.authors.join(", ")}" : ""
              year = book.year ? " (#{book.year})" : ""
              lines << "[#{book.key}] #{book.title}#{by}#{year}"
              lines << "  Other genres: #{book.genres.join(", ")}" if book.genres.any?
              lines << "  Description: #{book.description.to_s.truncate(400)}" if book.description.present?
            end
            lines << "" << "Return exactly one result per book, with its number in \"key\"."
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            keys = books.map(&:key)
            results = {}
            Array(value(provider_response[:parsed], :results)).each do |raw|
              key = value(raw, :key).to_s
              next if !keys.include?(key) || results.key?(key)

              names = Array(value(raw, :targets)).map(&:to_s)
              off = names - targets
              return failure("#{off.first.inspect} is not one of #{targets.join(", ")}") if off.any?

              results[key] = (value(raw, :unknown) == true) ? :unknown : names
            end
            missing = keys - results.keys
            return failure("No result for #{missing.join(", ")}") if missing.any?

            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def value(raw, key)
            return raw[key].nil? ? raw[key.to_s] : raw[key] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class CheckResult < OpenAI::BaseModel
            required :key, String, doc: "The book's number"
            required :targets, OpenAI::ArrayOf[String], doc: "The halves that describe it, names exactly as given"
            required :unknown, OpenAI::Boolean, doc: "True when you do not know the book"
            required :reason, String, doc: "A few words"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[CheckResult], doc: "One per book"
          end
        end
      end
    end
  end
end
```

Check how other schemas in `app/lib/services/ai/tasks/` declare a boolean field (`grep -rn "Boolean" app/lib/services/ai/tasks | head`) and use the same form.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/ai/tasks/books/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A app test
git commit -m "Genre cleanup: draft, map and split-check AI tasks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `draft`, `map` and `split_check` services

**Files:**
- Create: `app/lib/services/books/genre_plan/draft.rb`, `map.rb`, `split_check.rb`
- Test: `test/lib/services/books/genre_plan/draft_test.rb`, `map_test.rb`, `split_check_test.rb`

**Interfaces:**
- Consumes: Tasks 9 and 11; `Services::CategoryCleanup::SampleTitles.for(category)`; `Books::WorldCat::GenreMap.load`; `Services::CategoryCleanup::CostGuard.check!(calls:, force:)`.
- Produces:
  - `Draft.call(path: PlanFile::DEFAULT_PATH, force: false) -> Result` (`data: {genres: Integer, notes: [String]}`); refuses with an error when the file already has decisions and `force` is false.
  - `Map.call(path: PlanFile::DEFAULT_PATH, batch_size: 30, map: Books::WorldCat::GenreMap.load) -> Result` (`data: {mapped:, batches:, failed_batches:, remaining:}`); writes the file after each successful batch.
  - `SplitCheck.call(plan:, assignments:, batch_size: 10, force: false) -> Result` (`data: {checked:, calls:, failed_calls:}`); `SplitCheck.calls_needed(plan:, assignments:, batch_size: 10) -> Integer`.

- [ ] **Step 1: Write the failing tests**

`draft_test.rb`:

```ruby
        test "writes the drafted lists, the fixed audiences and an empty decisions map" do
          path = Rails.root.join("tmp", "draft_test_#{SecureRandom.hex(4)}.yml")
          response = Services::Ai::Result.new(success: true, data: {genres: [{name: "Fiction", definition: "x"}], notes: ["n"]})
          Services::Ai::Tasks::Books::GenreDraftTask.any_instance.stubs(:call).returns(response)

          result = Draft.call(path: path)

          plan = PlanFile.load(path)
          assert result.success?
          assert_equal ["Fiction"], plan.genre_names
          assert_equal PlanFile::AUDIENCES.keys, plan.audience_names
          assert_empty plan.decisions
          assert_match(/\Agenres-\d{4}-\d{2}\z/, plan.run)
        ensure
          FileUtils.rm_f(path)
        end

        test "refuses to overwrite a plan with decisions unless forced" do
          path = Rails.root.join("tmp", "draft_test_#{SecureRandom.hex(4)}.yml")
          PlanFile.new({"run" => "g", "decisions" => {1 => {"name" => "x", "action" => "keep"}}}, path: path).write
          Services::Ai::Tasks::Books::GenreDraftTask.any_instance.expects(:call).never

          refute Draft.call(path: path).success?
        ensure
          FileUtils.rm_f(path)
        end
```

`map_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GenrePlan
      class MapTest < ActiveSupport::TestCase
        setup do
          ::Books::Category.where(category_type: :genre).update_all(deleted: true)
          @vegetarian = ::Books::Category.create!(name: "Vegetarian", category_type: :genre, item_count: 2)
          @hockey_romance = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre, item_count: 1)
          @dakota = ::Books::Category.create!(name: "Dakotas", category_type: :genre)
          @hockey = ::Books::Category.create!(name: "Hockey", category_type: :subject)
          @path = Rails.root.join("tmp", "map_test_#{SecureRandom.hex(4)}.yml")
          PlanFile.new({"run" => "g", "genres" => [{"name" => "Romance", "definition" => "x"}],
            "audiences" => PlanFile::AUDIENCES.map { |n, d| {"name" => n, "definition" => d} }, "decisions" => {}}, path: @path).write
          @worldcat = ::Books::WorldCat::GenreMap.new("terms" => {"Hockey stories" => {"verdict" => "genre", "genre" => "Hockey Romance"}})
        end

        teardown { FileUtils.rm_f(@path) }

        def answer(key, overrides)
          {key: key, action: "delete", to: nil, into: [], into_subjects: [], as: nil, also: [], worldcat: nil, worldcat_terms: {}, reason: "r"}.merge(overrides)
        end

        def respond(results)
          Services::Ai::Result.new(success: true, data: {results: results})
        end

        test "writes one decision per genre, resolving subjects and dropping unknown places" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", action: "subject", as: "Vegetarianism"),
            "2" => answer("2", action: "split", into: ["Romance"], into_subjects: ["Hockey"], worldcat_terms: {"Hockey stories" => ["Romance"]}),
            "3" => answer("3", action: "location", as: "Dakotas")
          ))

          result = Map.call(path: @path, map: @worldcat)

          decisions = PlanFile.load(@path).decisions
          assert_equal 3, result.data[:mapped]
          assert_equal({"name" => "Vegetarian", "action" => "subject", "reason" => "r", "books" => 2, "saved_searches" => 0, "as" => "Vegetarianism"}, decisions[@vegetarian.id])
          assert_equal ["Romance", {"subject" => "Hockey", "target_id" => @hockey.id}], decisions[@hockey_romance.id]["into"]
          assert_equal({"Hockey stories" => ["Romance"]}, decisions[@hockey_romance.id]["worldcat_terms"])
          assert_equal "delete", decisions[@dakota.id]["action"]
          assert_equal "no such location: Dakotas", decisions[@dakota.id]["reason"]
        end

        test "a subject answer naming an existing subject gets its target_id" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", action: "subject", as: "hockey"), "2" => answer("2", {}), "3" => answer("3", {})
          ))

          Map.call(path: @path, map: @worldcat)

          assert_equal [@hockey.id, "Hockey"], PlanFile.load(@path).decisions[@vegetarian.id].values_at("target_id", "as")
        end

        test "a second run maps nothing; a failed batch writes nothing" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "bad name"))
          failed = Map.call(path: @path, map: @worldcat)
          assert_equal [0, 1, 3], failed.data.values_at(:mapped, :failed_batches, :remaining)
          assert_empty PlanFile.load(@path).decisions

          Services::Ai::Tasks::Books::GenreMapTask.any_instance.unstub(:call)
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", {}), "2" => answer("2", {}), "3" => answer("3", {})
          ))
          Map.call(path: @path, map: @worldcat)
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.expects(:call).never
          assert_equal 0, Map.call(path: @path, map: @worldcat).data[:mapped]
        end
      end
    end
  end
end
```

The genres are mapped in `item_count desc, id asc` order, so keys 1, 2, 3 are Vegetarian (2), Hockey Romance (1), Dakotas (0). Check `Services::Ai::Result.new`'s keyword names (`success:`, `data:`, `error:`) in `app/lib/services/ai/result.rb` and adjust.

`split_check_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GenrePlan
      class SplitCheckTest < ActiveSupport::TestCase
        setup do
          @sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          @lotr = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          [@lotr, @other].each { |book| CategoryItem.create!(category: @sff, item: book) }
          @plan = PlanFile.new({"run" => "g", "decisions" => {@sff.id => {"name" => @sff.name, "action" => "split", "into" => ["Science Fiction", "Fantasy"]}}})
          @path = Rails.root.join("tmp", "split_check_test_#{SecureRandom.hex(4)}.csv")
          @assignments = Assignments.load(@path)
        end

        teardown { FileUtils.rm_f(@path) }

        test "asks once per batch, writes every answer, and resumes" do
          ids = [@lotr.id, @other.id].sort
          answers = {"1" => ["Fantasy"], "2" => :unknown}
          Services::Ai::Tasks::Books::GenreSplitCheckTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {results: answers}))
          Services::CategoryCleanup::CostGuard.expects(:check!).with(calls: 1, force: false).returns(0.0)

          assert_equal 1, SplitCheck.calls_needed(plan: @plan, assignments: @assignments)
          result = SplitCheck.call(plan: @plan, assignments: @assignments)

          assert_equal 2, result.data[:checked]
          loaded = Assignments.load(@path)
          assert_equal({ids[0] => ["Fantasy"], ids[1] => :unknown}, loaded.for(@sff.id))
          assert_equal 0, SplitCheck.calls_needed(plan: @plan, assignments: loaded)
        end
      end
    end
  end
end
```

(Books are asked in `item_id` order, so key 1 is the lower id.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/genre_plan/draft_test.rb test/lib/services/books/genre_plan/map_test.rb test/lib/services/books/genre_plan/split_check_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement `Draft`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:draft` (spec §5 step 1).
      class Draft
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(path: PlanFile::DEFAULT_PATH, force: false)
          new(path, force).call
        end

        def initialize(path, force)
          @path = path
          @force = force
        end

        def call
          existing = PlanFile.load(@path)
          if existing.decisions.any? && !@force
            return Result.new(success?: false, data: nil, errors: ["#{@path} already has decisions; rerun with FORCE=1 to replace it"])
          end

          references = References.call
          entries = ::Books::Category.active.genre.order(item_count: :desc, name: :asc).map do |category|
            ::Services::Ai::Tasks::Books::GenreDraftTask::Entry.new(name: category.name, books: category.item_count.to_i,
              samples: ::Services::CategoryCleanup::SampleTitles.for(category), references: references[category.id])
          end
          response = ::Services::Ai::Tasks::Books::GenreDraftTask.new(entries: entries).call
          return Result.new(success?: false, data: nil, errors: [response.error]) unless response.success?

          plan = PlanFile.new({
            "run" => "genres-#{Date.current.strftime("%Y-%m")}",
            "genres" => response.data[:genres].map { |g| {"name" => g[:name], "definition" => g[:definition]} },
            "audiences" => PlanFile::AUDIENCES.map { |name, definition| {"name" => name, "definition" => definition} },
            "decisions" => {}
          }, path: @path)
          plan.write
          Result.new(success?: true, data: {genres: plan.genres.size, notes: response.data[:notes]}, errors: [])
        end
      end
    end
  end
end
```

(Check `Services::Ai::Result`'s reader for the error message: the tasks build it with `error:`; use whatever reader it defines, e.g. `#error`.)

- [ ] **Step 4: Implement `Map`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:map` (spec §5 step 3). Resumable: genres already in
      # the file are skipped, which also covers genres added later.
      class Map
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(path: PlanFile::DEFAULT_PATH, batch_size: 30, map: ::Books::WorldCat::GenreMap.load)
          new(path, batch_size, map).call
        end

        def initialize(path, batch_size, map)
          @plan = PlanFile.load(path)
          @batch_size = batch_size
          @worldcat_terms = map.terms_by_genre
        end

        def call
          return Result.new(success?: false, data: nil, errors: ["#{@plan.path} has no genre list; run draft first"]) if @plan.genres.empty?

          references = References.call
          pending = ::Books::Category.active.genre.where.not(id: @plan.decisions.keys).order(item_count: :desc, id: :asc).to_a
          mapped = 0
          failed = 0
          batches = 0
          pending.each_slice(@batch_size) do |slice|
            batches += 1
            entries = slice.each_with_index.map do |category, index|
              ::Services::Ai::Tasks::Books::GenreMapTask::Entry.new(key: (index + 1).to_s, name: category.name,
                books: category.item_count.to_i, samples: ::Services::CategoryCleanup::SampleTitles.for(category),
                references: references[category.id], worldcat_terms: @worldcat_terms.fetch(category.name, []))
            end
            response = ::Services::Ai::Tasks::Books::GenreMapTask.new(entries: entries, genres: @plan.genres, audiences: @plan.audiences).call
            unless response.success?
              failed += 1
              Rails.logger.warn("[genre map] batch failed: #{response.error}")
              next
            end

            slice.each_with_index do |category, index|
              @plan.decisions[category.id] = decision_for(category, response.data[:results].fetch((index + 1).to_s), references)
              mapped += 1
            end
            @plan.write
          end
          remaining = ::Books::Category.active.genre.where.not(id: @plan.decisions.keys).count
          Result.new(success?: true, data: {mapped: mapped, batches: batches, failed_batches: failed, remaining: remaining}, errors: [])
        end

        private

        def decision_for(category, r, references)
          d = {"name" => category.name, "action" => r[:action], "reason" => r[:reason],
               "books" => category.item_count.to_i, "saved_searches" => references[category.id]}
          case r[:action]
          when "rename" then d["to"] = r[:to]
          when "merge" then d["into"] = r[:into].first
          when "audience" then d["as"] = r[:as]
          when "subject"
            d["as"] = r[:as] if r[:as]
            target = find(:subject, r[:as] || category.name)
            d["target_id"] = target.id if target
            d["as"] = target.name if target
          when "location"
            target = find(:location, r[:as] || category.name)
            if target
              d.merge!("as" => target.name, "target_id" => target.id)
            else
              d.merge!("action" => "delete", "reason" => "no such location: #{r[:as] || category.name}")
            end
          when "split"
            subjects = r[:into_subjects].map do |name|
              target = find(:subject, name)
              target ? {"subject" => target.name, "target_id" => target.id} : nil
            end
            d["into"] = r[:into] + subjects.compact
            d["worldcat_terms"] = r[:worldcat_terms] if r[:worldcat_terms].any?
          end
          d["also"] = r[:also] if r[:also].any? && %w[keep rename].include?(d["action"])
          d["worldcat"] = r[:worldcat] if r[:worldcat]
          d
        end

        def find(type, name)
          scope = ::Books::Category.active.where(category_type: type)
          scope.by_name(name).first || scope.by_alternative_name(name).first
        end
      end
    end
  end
end
```

A split subject half with no matching live subject is dropped from `into` (the validator then flags a split left with fewer than two targets for the reviewer). Note that in the decision's `reason` by appending ` (no subject named X)` when it happens.

- [ ] **Step 5: Implement `SplitCheck`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:split_check` (spec §5 step 4). Resumable by book.
      class SplitCheck
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(plan:, assignments:, batch_size: 10, force: false)
          new(plan, assignments, batch_size).call(force: force)
        end

        def self.calls_needed(plan:, assignments:, batch_size: 10)
          new(plan, assignments, batch_size).work.sum { |_, _, books| (books.size / batch_size.to_f).ceil }
        end

        def initialize(plan, assignments, batch_size)
          @plan = plan
          @assignments = assignments
          @batch_size = batch_size
        end

        # [[category, targets, [book ids not yet answered]], ...]
        def work
          @plan.decisions.sort.filter_map do |id, d|
            next unless d["action"] == "split"

            category = ::Books::Category.find_by(id: id)
            next if category.nil?

            book_ids = category.category_items.where(item_type: "Books::Book").order(:item_id).pluck(:item_id)
              .reject { |book_id| @assignments.answered?(id, book_id) }
            [category, Array(d["into"]).map { |entry| Validator.target_label(entry) }, book_ids]
          end
        end

        def call(force:)
          jobs = work
          calls = jobs.sum { |_, _, books| (books.size / @batch_size.to_f).ceil }
          ::Services::CategoryCleanup::CostGuard.check!(calls: calls, force: force)
          checked = 0
          made = 0
          failed = 0
          jobs.each do |category, targets, book_ids|
            book_ids.each_slice(@batch_size) do |slice|
              books = ::Books::Book.where(id: slice).includes(:authors, :categories).index_by(&:id)
              entries = slice.each_with_index.map { |book_id, index| entry(books.fetch(book_id), (index + 1).to_s, category) }
              response = ::Services::Ai::Tasks::Books::GenreSplitCheckTask.new(genre: category.name, targets: targets, books: entries).call
              made += 1
              unless response.success?
                failed += 1
                next
              end

              rows = slice.each_with_index.map { |book_id, index| [book_id, category.id, response.data[:results].fetch((index + 1).to_s)] }
              @assignments.append(rows)
              checked += rows.size
            end
          end
          Result.new(success?: true, data: {checked: checked, calls: made, failed_calls: failed}, errors: [])
        end

        private

        def entry(book, key, category)
          ::Services::Ai::Tasks::Books::GenreSplitCheckTask::Book.new(
            key: key, title: book.title, authors: book.authors.map(&:name), year: book.first_published_year,
            description: book.primary_description&.content,
            genres: book.categories.select { |c| !c.deleted && c.genre? && c.id != category.id }.map(&:name)
          )
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/lib/services/books/genre_plan/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A app test
git commit -m "Genre cleanup: draft, map and split-check services

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `report` and `retarget_worldcat`

**Files:**
- Create: `app/lib/services/books/genre_plan/report.rb`, `retarget_world_cat.rb`
- Test: `test/lib/services/books/genre_plan/report_test.rb`, `retarget_world_cat_test.rb`

**Interfaces:**
- Produces:
  - `Report.call(plan:, assignments:) -> Result` with `data: {lines: [String]}`: decisions grouped by action, each line `id name -> target (books N, saved searches M) reason`, deletes always show saved searches; then one block per split genre: counts of books per target, with several targets, with none, `unknown`, unanswered, and up to 20 sample titles per outcome.
  - `RetargetWorldCat.call(plan:, path: Books::WorldCat::GenreMap::DEFAULT_PATH) -> Result` with `data: {retargeted: Integer}`; failure listing terms that target a split genre but are missing from its `worldcat_terms`, or target a genre the plan does not know.

- [ ] **Step 1: Write the failing tests**

`retarget_world_cat_test.rb`: write a temp map file and a plan (decisions keyed by made-up ids; the service reads only the plan, never the DB):

```ruby
        setup do
          @path = Rails.root.join("tmp", "genre_map_test_#{SecureRandom.hex(4)}.yml")
          @path.write({"version" => 1, "genres" => ["Science fiction", "Space Opera", "Children's books", "Drama", "Ebooks", "History and Politics", "Vegetarian", "Gay fiction"],
            "terms" => {
              "Science fiction" => {"verdict" => "genre", "genre" => "Science fiction", "uses" => 9, "books" => 3, "language" => "en"},
              "Space operas" => {"verdict" => "genre", "genre" => "Space Opera"},
              "Juvenile fiction" => {"verdict" => "genre", "genre" => "Children's books"},
              "Children's stories" => {"verdict" => "genre", "genre" => "Children's books"},
              "Drama" => {"verdict" => "genre", "genre" => "Drama"},
              "Electronic books" => {"verdict" => "drop", "reason" => "format"},
              "History" => {"verdict" => "genre", "genre" => "History and Politics"},
              "Vegetarian cooking" => {"verdict" => "genre", "genre" => "Vegetarian"},
              "Gay fiction" => {"verdict" => "genre", "genre" => "Gay fiction"},
              "Ebook" => {"verdict" => "genre", "genre" => "Ebooks"}
            }}.to_yaml)
          @plan = PlanFile.new({"run" => "g", "genres" => [{"name" => "Science Fiction"}, {"name" => "Plays"}, {"name" => "History"}],
            "audiences" => PlanFile::AUDIENCES.map { |n, d| {"name" => n, "definition" => d} },
            "decisions" => {
              1 => {"name" => "Science fiction", "action" => "rename", "to" => "Science Fiction"},
              2 => {"name" => "Space Opera", "action" => "merge", "into" => "Science Fiction"},
              3 => {"name" => "Children's books", "action" => "audience", "as" => "Children's"},
              4 => {"name" => "Drama", "action" => "delete", "worldcat" => "Plays"},
              5 => {"name" => "Ebooks", "action" => "delete"},
              6 => {"name" => "History and Politics", "action" => "split", "into" => ["History", {"subject" => "Politics", "target_id" => 9}],
                    "worldcat_terms" => {"History" => ["History"]}},
              7 => {"name" => "Vegetarian", "action" => "subject"},
              8 => {"name" => "Gay fiction", "action" => "subject", "as" => "LGBTQ+", "target_id" => 10}
            }})
        end

        teardown { FileUtils.rm_f(@path) }

        def terms = YAML.safe_load_file(@path)["terms"]

        test "rewrites every term from the plan" do
          result = RetargetWorldCat.call(plan: @plan, path: @path)

          assert result.success?, result.errors.inspect
          assert_equal({"verdict" => "genre", "genre" => "Science Fiction", "uses" => 9, "books" => 3, "language" => "en"}, terms["Science fiction"])
          assert_equal "Science Fiction", terms["Space operas"]["genre"]
          assert_equal({"verdict" => "audience", "audience" => "Children's", "weak" => true}, terms["Juvenile fiction"])
          assert_equal({"verdict" => "audience", "audience" => "Children's"}, terms["Children's stories"])
          assert_equal({"verdict" => "genre", "genre" => "Plays"}, terms["Drama"])
          assert_equal({"verdict" => "drop", "reason" => "not_a_genre"}, terms["Ebook"])
          assert_equal({"verdict" => "genre", "genre" => "History"}, terms["History"])
          assert_equal({"verdict" => "subject", "subject" => "Vegetarian"}, terms["Vegetarian cooking"])
          assert_equal({"verdict" => "subject", "subject" => "LGBTQ+"}, terms["Gay fiction"])
          assert_equal({"verdict" => "drop", "reason" => "format"}, terms["Electronic books"])
          map = YAML.safe_load_file(@path)
          assert_equal ["Science Fiction", "Plays", "History"], map["genres"]
          assert_equal PlanFile::AUDIENCES.keys, map["audiences"]
        end

        test "a split's second genre goes in also" do
          @plan.decisions[6]["into"] = ["History", "Politics"]
          @plan.data["genres"] << {"name" => "Politics"}
          @plan.decisions[6]["worldcat_terms"] = {"History" => ["History", "Politics"]}

          RetargetWorldCat.call(plan: @plan, path: @path)

          assert_equal({"verdict" => "genre", "genre" => "History", "also" => ["Politics"]}, terms["History"])
        end

        test "running it twice gives the same file" do
          RetargetWorldCat.call(plan: @plan, path: @path)
          first = @path.read
          RetargetWorldCat.call(plan: @plan, path: @path)
          assert_equal first, @path.read
        end

        test "a term on a split genre missing from worldcat_terms stops it" do
          @plan.decisions[6]["worldcat_terms"] = {}
          result = RetargetWorldCat.call(plan: @plan, path: @path)
          refute result.success?
          assert_match(/History/, result.errors.join)
        end
```

`report_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GenrePlan
      class ReportTest < ActiveSupport::TestCase
        test "lists decisions by action and summarises each split" do
          sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          books = %i[war_and_peace crime_and_punishment got of_mice_and_men clash].map { |name| books_books(name) }
          books.each { |book| CategoryItem.create!(category: sff, item: book) }
          plan = PlanFile.new({"run" => "g", "decisions" => {
            1 => {"name" => "Ebooks", "action" => "delete", "books" => 52, "saved_searches" => 3, "reason" => "A format."},
            2 => {"name" => "Space Opera", "action" => "merge", "into" => "Science Fiction", "books" => 9},
            sff.id => {"name" => sff.name, "action" => "split", "into" => ["Science Fiction", "Fantasy"], "books" => 5}
          }})
          assignments = Assignments.new([
            [books[0].id, sff.id, ["Fantasy"]], [books[1].id, sff.id, ["Science Fiction", "Fantasy"]],
            [books[2].id, sff.id, []], [books[3].id, sff.id, :unknown]
          ])

          lines = Report.call(plan: plan, assignments: assignments).data[:lines]
          text = lines.join("\n")

          assert_includes text, "1 Ebooks (books 52, saved searches 3) A format."
          assert_includes text, "2 Space Opera -> Science Fiction (books 9)"
          assert_includes text, "== split Science Fiction Fantasy (5 books)"
          assert_includes lines, "Fantasy: 1"
          assert_includes lines, "several: 1"
          assert_includes lines, "none: 1"
          assert_includes lines, "unknown: 1"
          assert_includes lines, "unanswered: 1"
          assert_includes lines, "Fantasy (any): 2"
          assert_includes text, books[0].title
        end
      end
    end
  end
end
```

(If any of those fixture book names do not exist, pick others from `test/fixtures/books/books.yml`.)

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/genre_plan/report_test.rb test/lib/services/books/genre_plan/retarget_world_cat_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement `RetargetWorldCat`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:retarget_worldcat` (spec §7): rewrites the WorldCat
      # genre map's targets from the plan, in development, for the same PR as
      # the plan. Reads only the plan and the map file.
      class RetargetWorldCat
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        KEPT_KEYS = %w[language uses books].freeze
        HEADER = "# WorldCat genre terms -> our curated genres and audiences. Generated by `bin/rails worldcat:map`\n" \
                 "# on 2026-10-12, edited by hand, and retargeted by `categories:genres:retarget_worldcat`.\n"

        def self.call(plan:, path: ::Books::WorldCat::GenreMap::DEFAULT_PATH)
          new(plan, Pathname(path)).call
        end

        def initialize(plan, path)
          @plan = plan
          @path = path
          @by_name = plan.decisions.values.index_by { |d| d["name"] }
        end

        def call
          data = YAML.safe_load_file(@path)
          errors = []
          retargeted = 0
          terms = data["terms"].to_h do |term, entry|
            next [term, entry] unless %w[genre audience].include?(entry["verdict"])

            target = entry["genre"] || entry["audience"]
            decision = @by_name[target]
            if decision.nil?
              errors << "#{term.inspect} targets #{target.inspect}, which the plan does not know" unless list_name?(target)
              next [term, entry]
            end

            fresh = rewrite(term, decision, errors)
            next [term, entry] if fresh.nil?

            retargeted += 1 unless fresh.except(*KEPT_KEYS) == entry.except(*KEPT_KEYS)
            [term, fresh.merge(entry.slice(*KEPT_KEYS))]
          end
          return Result.new(success?: false, data: nil, errors: errors) if errors.any?

          out = {"version" => data["version"], "genres" => @plan.genre_names, "audiences" => @plan.audience_names, "terms" => terms}
          @path.write(HEADER + out.to_yaml)
          Result.new(success?: true, data: {retargeted: retargeted}, errors: [])
        end

        private

        def list_name?(name) = @plan.genre_names.include?(name) || @plan.audience_names.include?(name)

        def rewrite(term, d, errors)
          return verdict(term, [d["worldcat"]]) if d["worldcat"]

          case d["action"]
          when "keep" then verdict(term, [d["name"]])
          when "rename" then verdict(term, [d["to"]])
          when "merge" then verdict(term, [d["into"]])
          when "audience" then verdict(term, [d["as"]])
          when "subject" then {"verdict" => "subject", "subject" => d["as"] || d["name"]}
          when "location", "delete" then {"verdict" => "drop", "reason" => "not_a_genre"}
          when "split"
            names = (d["worldcat_terms"] || {})[term]
            if names.blank?
              errors << "#{term.inspect} targets the split genre #{d["name"].inspect} but is not in its worldcat_terms"
              return nil
            end
            verdict(term, names)
          end
        end

        # names: primary first; the rest go in `also`.
        def verdict(term, names)
          primary = names.first
          out = if @plan.audience_names.include?(primary)
            {"verdict" => "audience", "audience" => primary}.merge(weak?(term, primary) ? {"weak" => true} : {})
          else
            {"verdict" => "genre", "genre" => primary}
          end
          names.drop(1).any? ? out.merge("also" => names.drop(1)) : out
        end

        # WorldCat's "Juvenile" spans ages 0-15 (spec §7).
        def weak?(term, audience) = audience == "Children's" && term.match?(/\bjuvenile\b/i)
      end
    end
  end
end
```

On a second run, terms already point at list names, so `@by_name[target]` finds the decision only when a list name equals an old genre name; for keep (`"Fantasy"` kept as `"Fantasy"`) the rewrite is the same, which keeps the second run identical. Verify with the "twice" test.

- [ ] **Step 4: Implement `Report`**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:report` (spec §5 step 5): what the owner reviews.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        SAMPLES = 20

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          lines = []
          @plan.decisions.sort.group_by { |_, d| d["action"] }.sort.each do |action, rows|
            lines << "" << "== #{action} (#{rows.size})"
            rows.each do |id, d|
              refs = (action == "delete" || d["saved_searches"].to_i.positive?) ? ", saved searches #{d["saved_searches"].to_i}" : ""
              lines << "#{id} #{d["name"]}#{target(d)} (books #{d["books"].to_i}#{refs}) #{d["reason"]}"
            end
          end
          @plan.decisions.sort.each { |id, d| lines.concat(split_block(id, d)) if d["action"] == "split" }
          Result.new(success?: true, data: {lines: lines}, errors: [])
        end

        private

        def target(d)
          to = d["to"] || d["as"] || (d["action"] == "split" ? Array(d["into"]).map { |e| Validator.target_label(e) }.join(" + ") : d["into"])
          extra = Array(d["also"]).any? ? " also #{d["also"].join(", ")}" : ""
          to ? " -> #{to}#{extra}" : extra
        end

        def split_block(id, d)
          answers = @assignments.for(id)
          on_genre = ::CategoryItem.where(category_id: id, item_type: "Books::Book").pluck(:item_id)
          outcomes = Hash.new { |h, k| h[k] = [] }
          on_genre.each do |book_id|
            answer = answers[book_id]
            key = if answer.nil? then "unanswered"
            elsif answer == :unknown then "unknown"
            elsif answer.empty? then "none"
            elsif answer.size > 1 then "several"
            else answer.first
            end
            outcomes[key] << book_id
          end
          titles = ::Books::Book.where(id: outcomes.values.flat_map { |ids| ids.first(SAMPLES) }).pluck(:id, :title).to_h
          lines = ["", "== split #{d["name"]} (#{on_genre.size} books)"]
          outcomes.sort.each do |key, ids|
            lines << "#{key}: #{ids.size}"
            lines << "  #{ids.first(SAMPLES).map { |book_id| titles[book_id] }.join(" | ")}"
          end
          lines
        end
      end
    end
  end
end
```

Then, at the end of `split_block` before returning `lines`, add per-target totals so the reviewer sees both views:

```ruby
          Array(d["into"]).map { |entry| Validator.target_label(entry) }.each do |label|
            count = on_genre.count { |book_id| answers[book_id].is_a?(Array) && answers[book_id].include?(label) }
            lines << "#{label} (any): #{count}"
          end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/lib/services/books/genre_plan/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A app test
git commit -m "Genre cleanup: review report and WorldCat map retarget

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Rake tasks and the subject prompt

**Files:**
- Create: `lib/tasks/genre_cleanup.rake`
- Modify: `app/lib/services/ai/tasks/category_cleanup/subject_task.rb:25`
- Test: `test/lib/tasks/genre_cleanup_rake_test.rb`, `test/lib/services/ai/tasks/category_cleanup/subject_task_test.rb`

**Interfaces:**
- Consumes: Tasks 9-13.
- Produces: `categories:genres:draft`, `map`, `split_check`, `report`, `retarget_worldcat`, `apply`. `FORCE=1` on `draft` and `split_check`. `PLAN=path` and `ASSIGNMENTS=path` override the default files (used by tests and rehearsals).

- [ ] **Step 1: Write the failing tests**

`test/lib/tasks/genre_cleanup_rake_test.rb`, loading the one rake file as `category_cleanup_rake_test.rb` does:

```ruby
require "test_helper"
require "rake"

class GenreCleanupRakeTest < ActiveSupport::TestCase
  TASKS = %w[draft map split_check report retarget_worldcat apply].freeze

  setup do
    unless Rake::Task.task_defined?("categories:genres:apply")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/genre_cleanup.rake").to_s }
    end
    TASKS.each { |name| Rake::Task["categories:genres:#{name}"].reenable }
    @missing = Rails.root.join("tmp", "missing_genre_plan_#{SecureRandom.hex(4)}.yml").to_s
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "apply with no plan file aborts and says so" do
    with_env("PLAN" => @missing) do
      assert_raises(SystemExit) do
        assert_output(nil, /no plan file/) { Rake::Task["categories:genres:apply"].invoke }
      end
    end
  end

  test "report prints the report lines and the validation result" do
    Services::Books::GenrePlan::Report.stubs(:call).returns(Services::Books::GenrePlan::Report::Result.new(success?: true, data: {lines: ["== keep (1)"]}, errors: []))
    Services::Books::GenrePlan::Validator.stubs(:call).returns(Services::Books::GenrePlan::Validator::Result.new(success?: true, data: nil, errors: []))

    with_env("PLAN" => @missing) do
      assert_output(/== keep \(1\).*The plan passes every check\./m) { Rake::Task["categories:genres:report"].invoke }
    end
  end

  test "split_check prints the estimate before calling" do
    Services::Books::GenrePlan::SplitCheck.stubs(:calls_needed).returns(3)
    Services::Books::GenrePlan::SplitCheck.stubs(:call).returns(
      Services::Books::GenrePlan::SplitCheck::Result.new(success?: true, data: {checked: 30, calls: 3, failed_calls: 0}, errors: [])
    )

    with_env("PLAN" => @missing, "ASSIGNMENTS" => @missing.sub(".yml", ".csv")) do
      assert_output(/split_check: 3 calls.*Checked 30 books in 3 calls/m) { Rake::Task["categories:genres:split_check"].invoke }
    end
  end
end
```

(`abort` writes its message to stderr and raises `SystemExit`; if `assert_output` inside `assert_raises` does not capture it, check how `category_cleanup_rake_test.rb` asserts an abort message and follow it.)

`subject_task_test.rb`:

```ruby
          test "the prompt says audience is its own category type" do
            assert_includes task(:head).send(:system_message), "an audience (\"Young Adult\"), which is its own category type"
          end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/tasks/genre_cleanup_rake_test.rb test/lib/services/ai/tasks/category_cleanup/subject_task_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement the rake file**

```ruby
# Genre cleanup (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §5).
# draft, map, split_check, report and retarget_worldcat run in development;
# apply runs in production on the reviewed files.
namespace :categories do
  namespace :genres do
    plan_path = -> { ENV["PLAN"].presence || Services::Books::GenrePlan::PlanFile::DEFAULT_PATH }
    assignments_path = -> { ENV["ASSIGNMENTS"].presence || Services::Books::GenrePlan::Assignments::DEFAULT_PATH }

    desc "Draft the genre list into config/books/genre_plan.yml (FORCE=1 replaces a plan with decisions)"
    task draft: :environment do
      result = Services::Books::GenrePlan::Draft.call(path: plan_path.call, force: ENV["FORCE"] == "1")
      abort result.errors.join("\n") unless result.success?
      puts "Drafted #{result.data[:genres]} genres into #{plan_path.call}. Edit the list, then run categories:genres:map."
      result.data[:notes].each { |note| puts "  #{note}" }
    end

    desc "Map every current genre onto the edited lists (resumable)"
    task map: :environment do
      result = Services::Books::GenrePlan::Map.call(path: plan_path.call)
      abort result.errors.join("\n") unless result.success?
      d = result.data
      puts "Mapped #{d[:mapped]} genres in #{d[:batches]} batches (#{d[:failed_batches]} failed); #{d[:remaining]} still unmapped."
      puts "Run it again to retry the failed batches." if d[:remaining].positive?
    end

    desc "Ask, book by book, which halves of each split genre fit (resumable; FORCE=1 past the cost guard)"
    task split_check: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      calls = Services::Books::GenrePlan::SplitCheck.calls_needed(plan: plan, assignments: assignments)
      puts "split_check: #{calls} calls"
      begin
        result = Services::Books::GenrePlan::SplitCheck.call(plan: plan, assignments: assignments, force: ENV["FORCE"] == "1")
      rescue Services::CategoryCleanup::CostGuard::TooExpensive => e
        abort e.message
      end
      d = result.data
      puts "Checked #{d[:checked]} books in #{d[:calls]} calls (#{d[:failed_calls]} failed)."
    end

    desc "Print the plan for review"
    task report: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      validation = Services::Books::GenrePlan::Validator.call(plan: plan, assignments: assignments)
      puts Services::Books::GenrePlan::Report.call(plan: plan, assignments: assignments).data[:lines]
      puts "", (validation.success? ? "The plan passes every check." : "Problems:\n#{validation.errors.join("\n")}")
    end

    desc "Rewrite config/worldcat/genre_map.yml's targets from the plan"
    task retarget_worldcat: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      result = Services::Books::GenrePlan::RetargetWorldCat.call(plan: plan)
      abort result.errors.join("\n") unless result.success?
      puts "Retargeted #{result.data[:retargeted]} WorldCat terms."
    end

    desc "Apply the reviewed plan (production)"
    task apply: :environment do
      plan = Services::Books::GenrePlan::PlanFile.load(plan_path.call)
      assignments = Services::Books::GenrePlan::Assignments.load(assignments_path.call)
      result = Services::Books::GenrePlan::Apply.call(plan: plan, assignments: assignments)
      abort result.errors.join("\n") unless result.success?
      d = result.data
      puts "Applied: #{d[:applier].inspect}"
      puts "Saved searches cleaned: #{d[:cleaned][:saved_searches].inspect}"
      puts "Recommendation settings cleaned: #{d[:cleaned][:recommendation_configs].inspect}"
      puts "Books on split genres with no answer (given every target): #{d[:unassigned_split_books]}"
    end
  end
end
```

`subject_task.rb:25`, change the delete line's audience clause:

```
              - "delete": junk or not a subject: a truncated fragment, a placeholder ("Book titles", "Packages"), a genre ("Science Fiction"), a format ("Anthology") or an audience ("Young Adult"), which is its own category type.
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/tasks/genre_cleanup_rake_test.rb test/lib/services/ai/tasks/category_cleanup/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A lib app test
git commit -m "Genre cleanup: categories:genres rake tasks; subject prompt names the audience type

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Docs, spec rulings, and the full suite

**Files:**
- Modify: `docs/features/books-categories.md` (new section "Genre cleanup and audiences", and audience wherever category types are listed)
- Modify: `docs/launch-todo.md` (§9: the old-site Goodreads change and `categories:genres:apply` before step 12)
- Modify: `docs/features/worldcat-data-service.md` (map entry shapes: `audience`, `also`, `weak`)
- Modify: `docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md` (record this plan's rulings)

- [ ] **Step 1: Write the feature doc section**

In `docs/features/books-categories.md`, add a section covering, in prose a reader can follow: the four types and the audience values (spec §2 table); that audience scores as a genre; the plan file and the split-answers file and what each holds; the six commands in order with where each runs; the checks `apply` makes; the `split` action and `also:`; what happens to saved searches when a genre is deleted; and the legacy sync behaviour. Use the voice of the existing doc. Link the spec.

- [ ] **Step 2: Update the launch todo**

In `docs/launch-todo.md` §9, before step 12 (aliases), insert numbered steps (renumber what follows):
- "Old site: stop the Goodreads import creating genres (`the-greatest-books/admin/app/models/book.rb`, the `Category.create!` in the Goodreads genre loop becomes `next if category.nil?`). Deploy before the genre apply."
- "Genre cleanup, in production. Shane runs with `!`. Dump the four tables (category cleanup runbook), then `bin/rails categories:genres:apply`. Needs PR 2 (the plan files) merged."

- [ ] **Step 3: Record the rulings in the spec**

In the spec: §6 table, Search index row: no `audience_category_ids` field (reason); Similar books/recommendations row: the taste panel shows audiences under Genres; §5 step 3: off-list names fail the batch rather than schema enums; §4 checks: drop the "no merge or split target is itself merged, split, retyped or deleted" bullet (reason); §6 subject prompt row: keeps deleting audience-named subjects, now naming the type; §6 filter modal row: placeholders unchanged, the axis hint changes. Add the `PLAN`/`ASSIGNMENTS` overrides to §5.

- [ ] **Step 4: Update the WorldCat doc**

In `docs/features/worldcat-data-service.md`, "The mapping file": add the `audience` verdict, `also:` and `weak: true`, the `audiences:` header, and what `ApplyCategories` does with each (link spec §7).

- [ ] **Step 5: Run the whole suite and lint**

Run: `bin/rails test`
Expected: PASS with no new warning lines (AGENTS.md: a clean run emits only the two known upstream warnings).

Run: `bundle exec standardrb`
Expected: no offenses (use `--fix` for autocorrectable ones, then re-run the tests).

Run: `CI=1 bin/rails zeitwerk:check`
Expected: "All is good!".

Run the touched Playwright specs under the port-3000 check: `yarn test:e2e e2e/tests/books/browse.spec.ts e2e/tests/books/filters.spec.ts e2e/tests/books/global-canon.spec.ts`.

- [ ] **Step 6: Commit**

```bash
git add -A docs
git commit -m "Docs: genre cleanup, audiences, WorldCat map shapes, launch steps; spec rulings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: The old site's Goodreads change (separate repository, prepared not pushed)

**Files:**
- Modify: `/home/shane/dev/the-greatest-books/admin/app/models/book.rb` (the Goodreads genre loop, around line 1627)

This is the owner's live legacy app. Prepare the change on a branch; do not push or deploy without asking.

- [ ] **Step 1: Branch**

```bash
git -C /home/shane/dev/the-greatest-books status --short
git -C /home/shane/dev/the-greatest-books switch -c stop-goodreads-genre-creation
```

If `status` shows uncommitted changes, stop and report them instead of branching.

- [ ] **Step 2: Edit**

Replace:

```ruby
      category = Category.find_existing(genre)
      next if category&.deleted?

      if category.nil?
        category = Category.create!(name: genre, import_source: :goodreads, category_type: :genre)
      end
      category.deleted = false
      category.save!
```

with:

```ruby
      category = Category.find_existing(genre)
      # Genres are curated on the new site now: link existing ones, never invent new ones.
      next if category.nil? || category.deleted?
```

(`category.deleted = false; category.save!` was a no-op once deleted genres are skipped, so it goes too.)

- [ ] **Step 3: Check it parses, and run that model's tests if the repo has them**

```bash
ruby -c /home/shane/dev/the-greatest-books/admin/app/models/book.rb
```

Expected: `Syntax OK`. If `admin/test` or `admin/spec` covers the Goodreads import, run that file the way that repo's README says; if running it needs services that are not available, say so in the report instead.

- [ ] **Step 4: Commit on the branch (no push)**

```bash
git -C /home/shane/dev/the-greatest-books add admin/app/models/book.rb
git -C /home/shane/dev/the-greatest-books commit -m "Goodreads import: link existing genres only, never create new ones

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Report the branch name; the owner decides when to push and deploy.

---

## Self-review notes

- Spec coverage: §2 audience values (Tasks 1, 9 `AUDIENCES`), §3 rules (Task 11 prompts), §4 plan file and checks (Task 9), split and also (Tasks 6, 10), §5 commands (Tasks 12-14), §6 every changed row (Tasks 1-5, 10 criteria, 14 subject prompt), §7 WorldCat (Tasks 8, 13), §8 old site (Task 16), §9 rollout and launch todo (Task 15), §10 testing (each task), §11 out of scope (nothing built).
- Names used across tasks: `PlanFile`, `Assignments`, `References`, `Validator.target_label`, `DecisionBuilder::STAGE`, `CriteriaCleaner`, `Apply`, `Draft`, `Map`, `SplitCheck.calls_needed`, `Report`, `RetargetWorldCat`, `GenreMap::Target`, `GenreMap#targets_for`, `#terms_by_audience`, `Books::Book.scoring_type`, `SCORED_CATEGORY_TYPES`, `GENRE_SCORED_TYPES`, decision columns `extra_target_ids`, `split_assignments`.
