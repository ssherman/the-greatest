# Rankings Explainer Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one shared `/rankings` explainer page serving books, music and games, replacing the two near-duplicate hand-written pages and giving books its first.

**Architecture:** A single query service assembles page data from one or more `RankingConfiguration` records; five ViewComponents render it; three thin controllers pick their configurations. A new `category` enum on `penalties` groups the 49 penalties into five readable sections, and all 49 descriptions are rewritten via an idempotent rake task.

**Tech Stack:** Rails 8.1, Minitest + Mocha + fixtures, ViewComponent, Tailwind 4 + daisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-29-rankings-explainer-page-design.md`

## Global Constraints

- Run all Rails/yarn commands from `web-app/`. Docs are at the project root.
- Worktree: `/home/shane/dev/the-greatest/.claude/worktrees/books-rankings-page`, branch `worktree-books-rankings-page`.
- Linter is `bundle exec standardrb` — **never** `bin/rubocop`.
- Use Rails generators for models/controllers/components; never hand-create them.
- Rails 8 enum syntax: `enum :category, {...}` with a colon prefix.
- Minitest 6: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Services use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Display strings belong on models. There is no `app/presenters`.
- daisyUI 5: these classes are removed and fail silently — `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`.
- daisyUI `.stats` and `.table` have no background of their own — fix in the domain stylesheet, never in a view.
- Controller tests assert behavior (status, assigns), never HTML/CSS/copy.
- Never run destructive commands against the development database.
- **Never commit to `main`.** Work stays on `worktree-books-rankings-page`.

---

### Task 1: `penalties.category` enum

**Files:**
- Create: `db/migrate/<timestamp>_add_category_to_penalties.rb`
- Modify: `app/models/penalty.rb`
- Modify: `app/views/admin/penalties/_form.html.erb`
- Modify: `app/controllers/admin/penalties_controller.rb:68-70`
- Modify: `test/fixtures/penalties.yml`
- Test: `test/models/penalty_test.rb`

**Interfaces:**
- Produces: `Penalty#category` (string or nil), `Penalty.categories` hash, scope `Penalty.by_category(cat)`, `Penalty.category_title(cat) -> String`, `Penalty::CATEGORY_TITLES`.

- [ ] **Step 1: Write the failing test**

Append to `test/models/penalty_test.rb`, inside the existing `PenaltyTest` class:

```ruby
test "category enum accepts the five groups" do
  penalty = penalties(:global_penalty)
  Penalty.categories.each_key do |category|
    penalty.category = category
    assert penalty.valid?, "#{category} should be a valid category"
  end
end

test "category is optional" do
  penalty = penalties(:global_penalty)
  penalty.category = nil
  assert penalty.valid?
  assert_nil penalty.category
end

test "by_category scope filters to one group" do
  penalties(:global_penalty).update!(category: :list_time_scope)
  penalties(:cross_media_penalty).update!(category: :voter_expertise)

  results = Penalty.by_category(:list_time_scope)

  assert_includes results, penalties(:global_penalty)
  assert_not_includes results, penalties(:cross_media_penalty)
end

test "category_title returns a human heading for each group" do
  assert_equal "Who voted", Penalty.category_title("voter_expertise")
  assert_equal "How many voted", Penalty.category_title("voter_participation")
  assert_equal "How much time the list covers", Penalty.category_title("list_time_scope")
  assert_equal "How narrow the list's subject is", Penalty.category_title("list_subject_scope")
  assert_equal "How the list was made", Penalty.category_title("list_integrity")
end

test "category_title falls back to Other for an unknown or nil category" do
  assert_equal "Other", Penalty.category_title(nil)
  assert_equal "Other", Penalty.category_title("something_else")
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/penalty_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'categories'` / unknown attribute `category`.

- [ ] **Step 3: Generate and write the migration**

Run: `bin/rails generate migration AddCategoryToPenalties`

Then replace the generated file's body with:

```ruby
class AddCategoryToPenalties < ActiveRecord::Migration[8.1]
  def change
    # Nullable on purpose. A penalty created in admin without a category still
    # renders on the public rankings page under an "Other" heading rather than
    # silently disappearing from it -- the failure mode has to be visible.
    add_column :penalties, :category, :integer

    add_index :penalties, :category
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bin/rails db:migrate`
Expected: migration runs; `db/schema.rb` gains `t.integer "category"` on `penalties`.

- [ ] **Step 5: Add the enum, scope and titles to the model**

In `app/models/penalty.rb`, add after the existing `dynamic_type` enum block:

```ruby
  # How this penalty is grouped on the public /rankings page. Nullable: an
  # uncategorized penalty renders under "Other" rather than vanishing.
  enum :category, {
    voter_expertise: 0,
    voter_participation: 1,
    list_time_scope: 2,
    list_subject_scope: 3,
    list_integrity: 4
  }, allow_nil: true

  # Section headings for the public page. These are reader-facing questions
  # rather than schema names -- "Who voted" lands where "voter_expertise" does
  # not. Ordered as the page renders them.
  CATEGORY_TITLES = {
    "voter_expertise" => "Who voted",
    "voter_participation" => "How many voted",
    "list_time_scope" => "How much time the list covers",
    "list_subject_scope" => "How narrow the list's subject is",
    "list_integrity" => "How the list was made"
  }.freeze

  def self.category_title(category)
    CATEGORY_TITLES.fetch(category.to_s, "Other")
  end
```

Add alongside the existing scopes:

```ruby
  scope :by_category, ->(category) { where(category: category) }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/models/penalty_test.rb`
Expected: PASS.

- [ ] **Step 7: Add the field to the admin form**

In `app/views/admin/penalties/_form.html.erb`, inside the `Type Configuration` card's
`grid` div, after the `dynamic_type` block, add:

```erb
        <div>
          <%= f.label :category, class: "label" do %>
            <span class="font-semibold">Category</span>
          <% end %>
          <%= f.select :category,
              options_for_select(
                [["Uncategorized", nil]] + Penalty.categories.keys.map { |k| [Penalty.category_title(k), k] },
                @penalty.category
              ),
              {},
              class: "select w-full #{@penalty.errors[:category].any? ? 'select-error' : ''}" %>
          <label class="label">
            <span>Groups this penalty on the public rankings page. Uncategorized penalties appear under "Other".</span>
          </label>
          <% if @penalty.errors[:category].any? %>
            <label class="label">
              <span class="text-error"><%= @penalty.errors[:category].first %></span>
            </label>
          <% end %>
        </div>
```

- [ ] **Step 8: Permit the parameter**

In `app/controllers/admin/penalties_controller.rb`, change `penalty_params`:

```ruby
  def penalty_params
    params.require(:penalty).permit(:name, :description, :dynamic_type, :category)
  end
```

- [ ] **Step 9: Give fixtures a category**

In `test/fixtures/penalties.yml`, add a `category:` line to these five fixtures so
grouping has coverage in tests:

```yaml
global_penalty:
  type: Global::Penalty
  name: "Limited Time Coverage"
  description: "List only covers a limited time period"
  category: 2 # list_time_scope

cross_media_penalty:
  type: Global::Penalty
  name: "Non-Expert Voters"
  description: "Voters are not critics, authors, or experts"
  category: 0 # voter_expertise

dynamic_penalty:
  type: Global::Penalty
  name: "Dynamic Test Penalty"
  description: "A dynamic penalty for testing"
  dynamic_type: 0 # number_of_voters
  category: 1 # voter_participation

static_penalty:
  type: Global::Penalty
  name: "Static Test Penalty"
  description: "A static penalty for testing"
  category: 4 # list_integrity

books_penalty:
  type: Books::Penalty
  name: "Western Canon Bias"
  description: "List focuses heavily on Western Canon books"
  dynamic_type: 1 # percentage_western
  category: 3 # list_subject_scope
```

Leave `movies_penalty`, `games_penalty`, `music_penalty`, `user_penalty` and
`user_books_penalty` without a category — they are the "Other" coverage.

- [ ] **Step 10: Run the full model and admin tests**

Run: `bin/rails test test/models/penalty_test.rb test/controllers/admin/penalties_controller_test.rb`
Expected: PASS.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb --fix app/models/penalty.rb app/controllers/admin/penalties_controller.rb
git add db/migrate db/schema.rb app/models/penalty.rb app/views/admin/penalties/_form.html.erb app/controllers/admin/penalties_controller.rb test/fixtures/penalties.yml test/models/penalty_test.rb
git commit -m "Add category enum to penalties for public rankings grouping"
```

---

### Task 2: Backfill categories and rewrite all 49 descriptions

**Files:**
- Create: `lib/tasks/penalties.rake`
- Test: `test/lib/tasks/penalties_rake_test.rb`

**Interfaces:**
- Consumes: `Penalty#category` from Task 1.
- Produces: rake task `penalties:backfill`. No Ruby interface other tasks depend on.

The mapping below is validated against the live database: all 49 penalty ids are covered
exactly once, and the books primary configuration's 41 penalties land 7 / 3 / 7 / 16 / 8
across the five categories, matching the spec.

- [ ] **Step 1: Write the failing test**

Create `test/lib/tasks/penalties_rake_test.rb`:

```ruby
require "test_helper"
require "rake"

class PenaltiesRakeTest < ActiveSupport::TestCase
  setup do
    Rake::Task.clear
    Rails.application.load_tasks
    @task = Rake::Task["penalties:backfill"]
  end

  teardown do
    Rake::Task.clear
  end

  test "assigns a category and description to a penalty it knows" do
    penalty = Penalty.create!(id: 990_001, type: "Global::Penalty", name: "Placeholder")
    Penalties::Backfill::ENTRIES[990_001] = {
      category: :list_integrity,
      description: "A test description."
    }

    Penalties::Backfill.call

    penalty.reload
    assert_equal "list_integrity", penalty.category
    assert_equal "A test description.", penalty.description
  ensure
    Penalties::Backfill::ENTRIES.delete(990_001)
  end

  test "is idempotent - a second run changes nothing" do
    penalty = Penalty.create!(id: 990_002, type: "Global::Penalty", name: "Placeholder Two")
    Penalties::Backfill::ENTRIES[990_002] = {
      category: :voter_expertise,
      description: "Another test description."
    }

    Penalties::Backfill.call
    first = penalty.reload.updated_at

    Penalties::Backfill.call

    assert_equal first, penalty.reload.updated_at
  ensure
    Penalties::Backfill::ENTRIES.delete(990_002)
  end

  test "skips ids that are not present without raising" do
    Penalties::Backfill::ENTRIES[990_003] = {category: :list_integrity, description: "Absent."}

    assert_nothing_raised { Penalties::Backfill.call }
  ensure
    Penalties::Backfill::ENTRIES.delete(990_003)
  end

  test "every entry names a real category" do
    valid = Penalty.categories.keys.map(&:to_sym)
    Penalties::Backfill::ENTRIES.each do |id, entry|
      assert_includes valid, entry[:category], "penalty #{id} has an unknown category"
      assert entry[:description].present?, "penalty #{id} has a blank description"
    end
  end

  test "the task runs" do
    @task.invoke
    assert true
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/tasks/penalties_rake_test.rb`
Expected: FAIL — `NameError: uninitialized constant Penalties`.

- [ ] **Step 3: Write the backfill task**

Create `lib/tasks/penalties.rake`. `ENTRIES` is keyed by penalty id because names are
long and editable in admin; ids are stable and the books migration preserved them.

```ruby
# frozen_string_literal: true

module Penalties
  # Canonical category and public description for every penalty.
  #
  # Keyed by id, not name: names are long, editable in admin, and several differ
  # only in a trailing clause. Descriptions are written for a site visitor AND
  # for whoever is tagging a list in admin -- one text serves both, which is why
  # there is no separate public_description column.
  module Backfill
    ENTRIES = {
      # --- Who voted -------------------------------------------------------
      8 => {category: :voter_expertise,
            description: "Most of the people who voted live in one country, so the list reflects one nation's taste rather than a broad readership."},
      9 => {category: :voter_expertise,
            description: "The voting panel was narrow -- similar backgrounds, similar training, or similar taste -- so the result reflects a small slice of readers."},
      10 => {category: :voter_expertise,
             description: "Voted on by the general public rather than critics, authors, or scholars. Popular opinion is worth something, but it is not expert judgement."},
      11 => {category: :voter_expertise,
             description: "Voting was limited to a specific group of people, so the list describes that group's preferences rather than a general consensus."},
      22 => {category: :voter_expertise,
             description: "The voters appear to be promoting a viewpoint rather than judging quality, so their picks say more about the agenda than the books."},
      32 => {category: :voter_expertise,
             description: "Roughly half the panel were experts and half were general readers, so the list blends expert and popular opinion."},
      44 => {category: :voter_expertise,
             description: "The public voted, but critics or experts chose and vetted the candidates, so expert judgement shaped the field even though the public ranked it."},

      # --- How many voted --------------------------------------------------
      12 => {category: :voter_participation,
             description: "We could not find out who voted. Named voters can be held to their choices; anonymous ones cannot."},
      13 => {category: :voter_participation,
             description: "Applied automatically when fewer people voted than on a typical list. The fewer the voters, the larger the reduction -- a poll of five is far easier to skew than a poll of five hundred."},
      14 => {category: :voter_participation,
             description: "The list does not say how many people voted, so we cannot tell whether it reflects a crowd or one person's opinion."},
      18 => {category: :voter_participation,
             description: "The number of voters was estimated rather than published, so the figure we hold is approximate."},
      21 => {category: :voter_participation,
             description: "The list names its voters but tells us little else about them, so we cannot judge how qualified the panel was."},

      # --- How much time the list covers -----------------------------------
      17 => {category: :list_time_scope,
             description: "Applied automatically based on how much of history a list covers. A list spanning a few years can only find the best of those years; one spanning centuries competes against everything ever published."},
      28 => {category: :list_time_scope,
             description: "Covers a single year. Yearly awards and best-of-the-year lists cannot tell you what will still be read in fifty years."},
      29 => {category: :list_time_scope,
             description: "Confined to roughly a fifty-year window, so anything published outside it was never eligible."},
      30 => {category: :list_time_scope,
             description: "Confined to roughly a century, so anything published outside it was never eligible."},
      33 => {category: :list_time_scope,
             description: "Confined to roughly five years of publishing -- a very narrow slice of what exists."},
      35 => {category: :list_time_scope,
             description: "Confined to roughly a seventy-five-year window, so anything published outside it was never eligible."},
      40 => {category: :list_time_scope,
             description: "Confined to roughly twenty-five years of publishing, so anything outside that window was never eligible."},
      41 => {category: :list_time_scope,
             description: "Confined to roughly a decade of publishing, so anything outside that window was never eligible."},

      # --- How narrow the list's subject is ---------------------------------
      5 => {category: :list_subject_scope,
            description: "Restricted to authors of one gender, so it surveys part of the field rather than all of it."},
      6 => {category: :list_subject_scope,
            description: "Restricted to books written in one language, so everything written elsewhere was never eligible."},
      7 => {category: :list_subject_scope,
            description: "Built around an unusual angle rather than quality -- entries were chosen to fit a concept, not because they are the best."},
      15 => {category: :list_subject_scope,
             description: "Applied automatically to lists that declare a regional focus. Their scope is narrow, but it is stated honestly up front -- which is also why they are exempt from the western-canon adjustment."},
      16 => {category: :list_subject_scope,
             description: "Applied automatically to single-genre lists. The best fantasy novel is competing in a far smaller field than the best novel."},
      19 => {category: :list_subject_scope,
             description: "Mostly compilations and greatest-hits collections rather than albums as their artists released them."},
      20 => {category: :list_subject_scope,
             description: "Restricted to one console or platform, so games released elsewhere were never eligible."},
      23 => {category: :list_subject_scope,
             description: "Applied automatically when a list that presents itself as general turns out to be 90% or more western. Lists that declare a regional focus up front are exempt."},
      26 => {category: :list_subject_scope,
             description: "Organised around a theme such as religion or politics, so books were picked for fitting the subject rather than for being the best."},
      27 => {category: :list_subject_scope,
             description: "Limited to genre fiction, so literary fiction and non-fiction were never eligible."},
      31 => {category: :list_subject_scope,
             description: "About half the entries were required to come from one country, so the field was partly reserved rather than open."},
      36 => {category: :list_subject_scope,
             description: "Restricted to one continent, so books from everywhere else were never eligible."},
      37 => {category: :list_subject_scope,
             description: "Restricted to authors or books from a single country."},
      38 => {category: :list_subject_scope,
             description: "Restricted to one large region, such as Asia or Latin America."},
      39 => {category: :list_subject_scope,
             description: "Restricted to a single state or province -- a very small pool to pick from."},
      42 => {category: :list_subject_scope,
             description: "Restricted to a single city, the smallest geographic pool we track."},
      43 => {category: :list_subject_scope,
             description: "Restricted to translated or foreign-language books relative to where the voters live."},
      46 => {category: :list_subject_scope,
             description: "Restricted to a small region, such as the American South."},
      47 => {category: :list_subject_scope,
             description: "Restricted to books that are part of a series, so standalone works were never eligible."},
      48 => {category: :list_subject_scope,
             description: "Built around an unusual premise rather than quality -- entries were chosen to fit the concept."},

      # --- How the list was made -------------------------------------------
      1 => {category: :list_integrity,
            description: "Whoever made the list also sells the books on it, so the selection has a commercial interest behind it."},
      2 => {category: :list_integrity,
            description: "Very long. Past a few hundred entries a list stops being a judgement and starts being an inventory."},
      3 => {category: :list_integrity,
            description: "Ranked by something other than quality -- most influential, most surprising, best beach read. Useful, but not a verdict on how good the books are."},
      4 => {category: :list_integrity,
            description: "A sequel or overflow list. Its entries are the ones that did not make the original."},
      24 => {category: :list_integrity,
             description: "The runners-up from another list rather than a selection in its own right."},
      25 => {category: :list_integrity,
             description: "One book chosen per year, so a book competed against whatever else came out that year rather than against everything ever written."},
      34 => {category: :list_integrity,
             description: "We could not find reliable information about how this list was made or who made it."},
      45 => {category: :list_integrity,
             description: "Itself an aggregation of other lists, several of which we may already count -- so it risks counting the same opinions twice."},
      49 => {category: :list_integrity,
             description: "A podcast or column featuring one book at a time. The picks are discussion topics, not a ranking."}
    }

    # Assigns only what actually differs, so a re-run is a no-op and updated_at
    # stays put. Missing ids are skipped rather than raising: this task runs
    # against dev and production, and the two may not hold identical rows.
    def self.call
      updated = 0
      skipped = 0

      ENTRIES.each do |id, entry|
        penalty = Penalty.find_by(id: id)
        if penalty.nil?
          skipped += 1
          next
        end

        penalty.category = entry[:category]
        penalty.description = entry[:description]
        updated += 1 if penalty.changed?
        penalty.save! if penalty.changed?
      end

      {updated: updated, skipped: skipped, total: ENTRIES.size}
    end
  end
end

namespace :penalties do
  desc "Backfill penalty categories and rewrite public descriptions (idempotent)"
  task backfill: :environment do
    result = Penalties::Backfill.call

    puts "Entries:   #{result[:total]}"
    puts "Updated:   #{result[:updated]}"
    puts "Not found: #{result[:skipped]}"

    uncategorized = Penalty.where(category: nil).count
    puts "Penalties still uncategorized: #{uncategorized}"
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/tasks/penalties_rake_test.rb`
Expected: PASS.

- [ ] **Step 5: Run the backfill against development**

Run: `bin/rails penalties:backfill`
Expected output: `Entries: 49`, `Updated: 49`, `Not found: 0`, `Penalties still uncategorized: 0`.

- [ ] **Step 6: Verify the books grouping matches the spec**

Run:

```bash
bin/rails runner 'rc = Books::RankingConfiguration.default_primary; ids = rc.penalty_applications.pluck(:penalty_id); Penalty.categories.each_key { |c| puts format("%-22s %s", c, Penalty.where(id: ids, category: c).count) }'
```

Expected: `voter_expertise 7`, `voter_participation 3`, `list_time_scope 7`, `list_subject_scope 16`, `list_integrity 8`.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix lib/tasks/penalties.rake test/lib/tasks/penalties_rake_test.rb
git add lib/tasks/penalties.rake test/lib/tasks/penalties_rake_test.rb
git commit -m "Backfill penalty categories and rewrite all 49 descriptions"
```

---

### Task 3: Media nouns and the `ExplainerData` service

**Files:**
- Modify: `app/models/books/ranking_configuration.rb`
- Modify: `app/models/music/albums/ranking_configuration.rb`
- Modify: `app/models/music/songs/ranking_configuration.rb`
- Modify: `app/models/games/ranking_configuration.rb`
- Modify: `app/models/ranking_configuration.rb`
- Create: `app/lib/services/ranking_configuration/explainer_data.rb`
- Test: `test/lib/services/ranking_configuration/explainer_data_test.rb`

**Interfaces:**
- Consumes: `Penalty#category`, `Penalty.category_title` from Task 1.
- Produces:
  - `RankingConfiguration#media_noun_plural -> String` ("books", "albums", "songs", "games"); base class raises `NotImplementedError`.
  - `Services::RankingConfiguration::ExplainerData.call(configurations:, example_list_id: nil) -> Result`
  - `Result#data` is an `ExplainerData::Data` with readers: `configurations`, `media_nouns`, `active_lists_count`, `ranked_items_count`, `median_list_count`, `penalty_groups`, `worked_example`, `score_curve`, `primary_configuration`.
  - `ExplainerData::PenaltyGroup` — `category`, `title`, `penalties` (Array<Penalty>).
  - `ExplainerData::WorkedExample` — `list`, `weight`, `item_count`, `penalties` (Array of `{name:, value:}`), `penalty_before_bonus`, `penalty_after_bonus`, `quality_bonus_applied`.
  - `ExplainerData::ScoreCurve` — `list_length`, `top_score`, `middle_score`, `bottom_score`, `ratio`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/ranking_configuration/explainer_data_test.rb`:

```ruby
require "test_helper"

module Services
  module RankingConfiguration
    class ExplainerDataTest < ActiveSupport::TestCase
      setup do
        @configuration = ranking_configurations(:books_global)
      end

      test "fails when given no configurations" do
        result = ExplainerData.call(configurations: [])

        assert_not result.success?
        assert_includes result.errors, "No ranking configuration available"
      end

      test "succeeds and reports the media noun" do
        result = ExplainerData.call(configurations: [@configuration])

        assert result.success?
        assert_equal "books", result.data.media_nouns
      end

      test "joins media nouns for a multi-configuration domain" do
        result = ExplainerData.call(configurations: [
          ranking_configurations(:music_albums_global),
          ranking_configurations(:music_songs_global)
        ])

        assert_equal "albums and songs", result.data.media_nouns
      end

      test "groups penalties by category in the order the page renders them" do
        result = ExplainerData.call(configurations: [@configuration])

        titles = result.data.penalty_groups.map(&:title)
        assert_equal titles, titles.uniq
        assert_operator result.data.penalty_groups.size, :>, 0
        result.data.penalty_groups.each do |group|
          assert group.penalties.any?, "#{group.title} should not be an empty group"
        end
      end

      test "puts uncategorized penalties in an Other group rather than dropping them" do
        penalty = penalties(:movies_penalty)
        penalty.update!(category: nil)
        PenaltyApplication.create!(penalty: penalty, ranking_configuration: @configuration, value: 10)

        result = ExplainerData.call(configurations: [@configuration])

        other = result.data.penalty_groups.find { |g| g.title == "Other" }
        assert_not_nil other, "expected an Other group"
        assert_includes other.penalties, penalty
      end

      test "score curve shows position is worth far less than presence" do
        result = ExplainerData.call(configurations: [@configuration])
        curve = result.data.score_curve

        assert_operator curve.top_score, :>, curve.bottom_score
        assert_operator curve.ratio, :<, 2.0
        assert_operator curve.ratio, :>, 1.0
      end

      test "worked example falls back to the heaviest list when the pinned id is absent" do
        result = ExplainerData.call(configurations: [@configuration], example_list_id: 999_999_999)

        assert result.success?
        assert_not_nil result.data.worked_example
      end

      test "worked example is nil when no list carries stored calculation details" do
        @configuration.ranked_lists.update_all(calculated_weight_details: nil)

        result = ExplainerData.call(configurations: [@configuration])

        assert result.success?
        assert_nil result.data.worked_example
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/ranking_configuration/explainer_data_test.rb`
Expected: FAIL — `NameError: uninitialized constant ExplainerData`.

- [ ] **Step 3: Add media nouns to the models**

In `app/models/ranking_configuration.rb`, add under `# Instance methods`:

```ruby
  # The plural noun this configuration ranks, for page copy. Defined per
  # subclass rather than derived from the class name because "Music::Albums"
  # would produce "albumses" and because the string is display text, which
  # belongs on the model.
  def media_noun_plural
    raise NotImplementedError, "#{self.class.name} must define #media_noun_plural"
  end
```

In `app/models/books/ranking_configuration.rb`, replace the placeholder comment:

```ruby
module Books
  class RankingConfiguration < ::RankingConfiguration
    def media_noun_plural = "books"
  end
end
```

In `app/models/music/albums/ranking_configuration.rb`:

```ruby
module Music
  module Albums
    class RankingConfiguration < ::RankingConfiguration
      def media_noun_plural = "albums"
    end
  end
end
```

In `app/models/music/songs/ranking_configuration.rb`:

```ruby
module Music
  module Songs
    class RankingConfiguration < ::RankingConfiguration
      def media_noun_plural = "songs"
    end
  end
end
```

In `app/models/games/ranking_configuration.rb`:

```ruby
module Games
  class RankingConfiguration < ::RankingConfiguration
    def media_noun_plural = "games"
  end
end
```

Leave the schema annotation comment blocks at the top of each file untouched.

- [ ] **Step 4: Write the service**

Create `app/lib/services/ranking_configuration/explainer_data.rb`:

```ruby
# frozen_string_literal: true

module Services
  module RankingConfiguration
    # Assembles everything the public /rankings page renders, for one domain.
    #
    # Books passes one configuration; music passes two (albums and songs). Every
    # query the page needs lives here rather than in the components, so the N+1
    # guard has a single place to point at.
    class ExplainerData
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      PenaltyGroup = Struct.new(:category, :title, :penalties, keyword_init: true)

      WorkedExample = Struct.new(
        :list, :weight, :item_count, :penalties,
        :penalty_before_bonus, :penalty_after_bonus, :quality_bonus_applied,
        keyword_init: true
      )

      ScoreCurve = Struct.new(
        :list_length, :top_score, :middle_score, :bottom_score, :ratio,
        keyword_init: true
      )

      Data = Struct.new(
        :configurations, :primary_configuration, :media_nouns,
        :active_lists_count, :ranked_items_count, :median_list_count,
        :penalty_groups, :worked_example, :score_curve,
        keyword_init: true
      )

      # The weight every list starts from before penalties. Mirrors
      # Rankings::WeightCalculator#base_weight, which is not public.
      BASE_WEIGHT = 100

      def self.call(configurations:, example_list_id: nil)
        new(configurations: configurations, example_list_id: example_list_id).call
      end

      def initialize(configurations:, example_list_id: nil)
        @configurations = Array(configurations).compact
        @example_list_id = example_list_id
      end

      def call
        return failure("No ranking configuration available") if @configurations.empty?

        Result.new(success?: true, data: build_data, errors: [])
      rescue => error
        failure(error.message)
      end

      private

      attr_reader :configurations, :example_list_id

      def primary = configurations.first

      def build_data
        Data.new(
          configurations: configurations,
          primary_configuration: primary,
          media_nouns: media_nouns,
          active_lists_count: active_lists_count,
          ranked_items_count: ranked_items_count,
          median_list_count: median_list_count,
          penalty_groups: penalty_groups,
          worked_example: worked_example,
          score_curve: score_curve
        )
      end

      def media_nouns
        configurations.map(&:media_noun_plural).uniq.to_sentence
      end

      def active_lists_count
        configurations.sum { |config| config.ranked_lists.joins(:list).where(lists: {status: :active}).count }
      end

      def ranked_items_count
        configurations.sum { |config| config.ranked_items.where.not(rank: nil).count }
      end

      def median_list_count
        ::List.median_list_count(type: list_type_for(primary))
      end

      def list_type_for(configuration)
        configuration.type.sub("RankingConfiguration", "List")
      end

      # Ordered by CATEGORY_TITLES so the page's sections are stable, with the
      # uncategorized remainder last under "Other". Empty groups are dropped --
      # a heading with nothing under it reads as a bug.
      def penalty_groups
        penalties = Penalty
          .joins(:penalty_applications)
          .where(penalty_applications: {ranking_configuration_id: configurations.map(&:id)})
          .distinct
          .order(:name)
          .to_a

        ordered = Penalty::CATEGORY_TITLES.keys.map do |category|
          PenaltyGroup.new(
            category: category,
            title: Penalty.category_title(category),
            penalties: penalties.select { |penalty| penalty.category == category }
          )
        end

        ordered << PenaltyGroup.new(
          category: nil,
          title: "Other",
          penalties: penalties.select { |penalty| penalty.category.nil? }
        )

        ordered.reject { |group| group.penalties.empty? }
      end

      # Reads the stored calculation rather than recomputing, so the page can
      # never disagree with the weight the list actually carries.
      def worked_example
        ranked_list = pinned_example || heaviest_example
        return nil if ranked_list.nil?

        details = ranked_list.calculated_weight_details
        bonus = details["quality_bonus"] || {}

        WorkedExample.new(
          list: ranked_list.list,
          weight: ranked_list.weight,
          item_count: ranked_list.list.list_items.count,
          penalties: details["penalties"].to_a.map { |p| {name: p["penalty_name"], value: p["value"]} },
          penalty_before_bonus: bonus["penalty_before"],
          penalty_after_bonus: bonus["penalty_after"],
          quality_bonus_applied: bonus["applied"]
        )
      end

      def pinned_example
        return nil if example_list_id.nil?

        example_scope.find_by(list_id: example_list_id)
      end

      def heaviest_example
        example_scope.order(weight: :desc).first
      end

      def example_scope
        primary.ranked_lists
          .includes(:list)
          .joins(:list)
          .where(lists: {status: :active})
          .where.not(calculated_weight_details: nil)
      end

      # Scores a synthetic list of median length at the base weight, using the
      # same strategy the real calculator uses, so the page states this domain's
      # actual numbers rather than a remembered constant.
      def score_curve
        length = [median_list_count.to_i, 2].max

        strategy = WeightedListRank::Strategies::Exponential.new(
          exponent: primary.exponent.to_f,
          bonus_pool_percentage: primary.bonus_pool_percentage.to_f,
          average_list_length: length
        )

        items = (1..length).map { |position| ItemRankings::Item.new(position, position, nil) }
        scores = strategy.calculate_scores(ItemRankings::List.new(0, BASE_WEIGHT.to_f, items))

        ScoreCurve.new(
          list_length: length,
          top_score: scores.first.round(1),
          middle_score: scores[(length / 2) - 1].round(1),
          bottom_score: scores.last.round(1),
          ratio: (scores.first / scores.last).round(2)
        )
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/ranking_configuration/explainer_data_test.rb`
Expected: PASS. If a fixture name in the test does not exist, check the real names first with `sed -n '/^[a-z_]*:/p' test/fixtures/ranking_configurations.yml` and use those — fixture names are semantic, never `one`/`two`.

- [ ] **Step 6: Check autoloading**

Run: `CI=1 bin/rails zeitwerk:check`
Expected: `All is good!`

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/ranking_configuration/explainer_data.rb app/models
git add app/lib/services/ranking_configuration/explainer_data.rb app/models test/lib/services/ranking_configuration/explainer_data_test.rb
git commit -m "Add ExplainerData service and per-domain media nouns"
```

---

### Task 4: `Rankings::PenaltyTableComponent`

**Files:**
- Create: `app/components/rankings/penalty_table_component.rb`
- Create: `app/components/rankings/penalty_table_component.html.erb`
- Test: `test/components/rankings/penalty_table_component_test.rb`

**Interfaces:**
- Consumes: `ExplainerData::PenaltyGroup` from Task 3.
- Produces: `Rankings::PenaltyTableComponent.new(groups:)`.

- [ ] **Step 1: Write the failing test**

Create `test/components/rankings/penalty_table_component_test.rb`:

```ruby
require "test_helper"

module Rankings
  class PenaltyTableComponentTest < ViewComponent::TestCase
    setup do
      @group = Services::RankingConfiguration::ExplainerData::PenaltyGroup.new(
        category: "voter_expertise",
        title: "Who voted",
        penalties: [penalties(:cross_media_penalty)]
      )
    end

    test "renders the group heading" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "h3", text: "Who voted"
    end

    test "renders each penalty name and description" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_text penalties(:cross_media_penalty).name
      assert_text penalties(:cross_media_penalty).description
    end

    test "renders nothing when there are no groups" do
      render_inline(PenaltyTableComponent.new(groups: []))

      assert_no_selector "h3"
    end

    test "renders a details element per group so the tables start collapsed" do
      render_inline(PenaltyTableComponent.new(groups: [@group]))

      assert_selector "details"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/rankings/penalty_table_component_test.rb`
Expected: FAIL — `NameError: uninitialized constant Rankings::PenaltyTableComponent`.

- [ ] **Step 3: Generate the component**

Run: `bin/rails generate component Rankings::PenaltyTable groups`

- [ ] **Step 4: Write the component class**

Replace `app/components/rankings/penalty_table_component.rb`:

```ruby
# frozen_string_literal: true

# The full penalty reference, grouped into the five reader-facing categories.
#
# Each group's table sits inside a <details> because the complete set runs to
# roughly fifty rows and would otherwise dominate the page. The prose above each
# group is what most readers need; the table is for the ones who want all of it.
class Rankings::PenaltyTableComponent < ViewComponent::Base
  def initialize(groups:)
    @groups = groups
  end

  def render? = @groups.any?

  private

  attr_reader :groups
end
```

- [ ] **Step 5: Write the template**

Replace `app/components/rankings/penalty_table_component.html.erb`:

```erb
<div class="space-y-6">
  <% groups.each do |group| %>
    <div>
      <h3 class="text-lg font-semibold mb-2"><%= group.title %></h3>

      <details class="rounded-box bg-base-200 p-4">
        <summary class="cursor-pointer font-medium">
          <%= pluralize(group.penalties.size, "adjustment") %>
        </summary>

        <div class="overflow-x-auto mt-4">
          <table class="table w-full">
            <thead>
              <tr>
                <th scope="col">Adjustment</th>
                <th scope="col">What it means</th>
              </tr>
            </thead>
            <tbody>
              <% group.penalties.each do |penalty| %>
                <tr>
                  <th scope="row" class="align-top font-medium whitespace-normal">
                    <%= penalty.name %>
                  </th>
                  <td class="align-top [overflow-wrap:anywhere]">
                    <%= penalty.description %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </details>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/components/rankings/penalty_table_component_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/rankings test/components/rankings
git add app/components/rankings test/components/rankings
git commit -m "Add penalty table component for the rankings page"
```

---

### Task 5: `Rankings::WeightExampleComponent`

**Files:**
- Create: `app/components/rankings/weight_example_component.rb`
- Create: `app/components/rankings/weight_example_component.html.erb`
- Test: `test/components/rankings/weight_example_component_test.rb`

**Interfaces:**
- Consumes: `ExplainerData::WorkedExample` from Task 3.
- Produces: `Rankings::WeightExampleComponent.new(example:)`.

- [ ] **Step 1: Write the failing test**

Create `test/components/rankings/weight_example_component_test.rb`:

```ruby
require "test_helper"

module Rankings
  class WeightExampleComponentTest < ViewComponent::TestCase
    setup do
      @example = Services::RankingConfiguration::ExplainerData::WorkedExample.new(
        list: lists(:books_list),
        weight: 70,
        item_count: 26,
        penalties: [
          {name: "List: only covers 1 specific country", value: 20},
          {name: "Voters: Unknown Names", value: 5}
        ],
        penalty_before_bonus: 45.0,
        penalty_after_bonus: 30.0,
        quality_bonus_applied: true
      )
    end

    test "renders the list name and its final weight" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text lists(:books_list).name
      assert_text "70"
    end

    test "renders each penalty with its value" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text "List: only covers 1 specific country"
      assert_text "20"
      assert_text "Voters: Unknown Names"
    end

    test "mentions the quality bonus when it was applied" do
      render_inline(WeightExampleComponent.new(example: @example))

      assert_text(/high-quality source/i)
    end

    test "omits the quality bonus line when it was not applied" do
      @example.quality_bonus_applied = false
      @example.penalty_after_bonus = 45.0

      render_inline(WeightExampleComponent.new(example: @example))

      assert_no_text(/high-quality source/i)
    end

    test "renders nothing when there is no example" do
      render_inline(WeightExampleComponent.new(example: nil))

      assert_no_selector "table"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/rankings/weight_example_component_test.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Generate the component**

Run: `bin/rails generate component Rankings::WeightExample example`

- [ ] **Step 4: Write the component class**

Replace `app/components/rankings/weight_example_component.rb`:

```ruby
# frozen_string_literal: true

# One real list walked from 100 down to the weight it actually carries.
#
# Every number comes from the stored calculated_weight_details rather than being
# recomputed here, so this can never contradict the weight the list is ranked
# with.
class Rankings::WeightExampleComponent < ViewComponent::Base
  BASE_WEIGHT = 100

  def initialize(example:)
    @example = example
  end

  def render? = @example.present?

  private

  attr_reader :example

  def base_weight = BASE_WEIGHT

  def total_before_bonus
    example.penalty_before_bonus.to_f.round(1)
  end

  def total_after_bonus
    example.penalty_after_bonus.to_f.round(1)
  end

  def quality_bonus_applied? = example.quality_bonus_applied
end
```

- [ ] **Step 5: Write the template**

Replace `app/components/rankings/weight_example_component.html.erb`:

```erb
<div class="rounded-box bg-base-200 p-4 md:p-6">
  <p class="mb-4">
    Take <strong><%= example.list.name %></strong>, a list of
    <%= number_with_delimiter(example.item_count) %> entries. Every list starts at
    <strong><%= base_weight %></strong>. These adjustments applied:
  </p>

  <div class="overflow-x-auto">
    <table class="table w-full">
      <tbody>
        <% example.penalties.each do |penalty| %>
          <tr>
            <th scope="row" class="font-medium whitespace-normal [overflow-wrap:anywhere]">
              <%= penalty[:name] %>
            </th>
            <td class="text-right whitespace-nowrap">
              &minus;<%= penalty[:value].to_f.round(1) %>%
            </td>
          </tr>
        <% end %>
        <tr>
          <th scope="row" class="font-semibold">Total</th>
          <td class="text-right font-semibold whitespace-nowrap">
            &minus;<%= total_before_bonus %>%
          </td>
        </tr>
      </tbody>
    </table>
  </div>

  <% if quality_bonus_applied? %>
    <p class="mt-4">
      This is a high-quality source, so its total is cut by a third &mdash; from
      <strong><%= total_before_bonus %>%</strong> to
      <strong><%= total_after_bonus %>%</strong>.
    </p>
  <% end %>

  <p class="mt-4">
    That leaves it a weight of <strong><%= example.weight %></strong> out of
    <%= base_weight %>. Every entry on the list is worth that much to the
    <%= example.list.list_items.any? ? "items" : "entries" %> on it.
  </p>
</div>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/components/rankings/weight_example_component_test.rb`
Expected: PASS. If `lists(:books_list)` is not a real fixture name, check with `sed -n '/^[a-z_]*:/p' test/fixtures/lists.yml` and substitute.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/rankings test/components/rankings
git add app/components/rankings test/components/rankings
git commit -m "Add worked weight example component for the rankings page"
```

---

### Task 6: Score curve and configuration facts components

**Files:**
- Create: `app/components/rankings/score_curve_component.rb`
- Create: `app/components/rankings/score_curve_component.html.erb`
- Create: `app/components/rankings/configuration_facts_component.rb`
- Create: `app/components/rankings/configuration_facts_component.html.erb`
- Test: `test/components/rankings/score_curve_component_test.rb`
- Test: `test/components/rankings/configuration_facts_component_test.rb`

**Interfaces:**
- Consumes: `ExplainerData::ScoreCurve` and `RankingConfiguration` from Task 3.
- Produces: `Rankings::ScoreCurveComponent.new(curve:, media_nouns:)`, `Rankings::ConfigurationFactsComponent.new(configurations:)`.

- [ ] **Step 1: Write the failing tests**

Create `test/components/rankings/score_curve_component_test.rb`:

```ruby
require "test_helper"

module Rankings
  class ScoreCurveComponentTest < ViewComponent::TestCase
    setup do
      @curve = Services::RankingConfiguration::ExplainerData::ScoreCurve.new(
        list_length: 50,
        top_score: 123.1,
        middle_score: 103.2,
        bottom_score: 100.0,
        ratio: 1.23
      )
    end

    test "renders the top and bottom scores" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "books"))

      assert_text "123.1"
      assert_text "100.0"
    end

    test "states the ratio" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "books"))

      assert_text "1.23"
    end

    test "uses the media noun in the copy" do
      render_inline(ScoreCurveComponent.new(curve: @curve, media_nouns: "albums and songs"))

      assert_text(/albums and songs/)
    end
  end
end
```

Create `test/components/rankings/configuration_facts_component_test.rb`:

```ruby
require "test_helper"

module Rankings
  class ConfigurationFactsComponentTest < ViewComponent::TestCase
    setup do
      @configuration = ranking_configurations(:books_global)
    end

    test "renders the configuration name" do
      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_text @configuration.name
    end

    test "renders the exponent and bonus pool" do
      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_text @configuration.exponent.to_f.to_s
    end

    test "reports the weight floor as zero rather than the stored minimum" do
      @configuration.update!(min_list_weight: -50)

      render_inline(ConfigurationFactsComponent.new(configurations: [@configuration]))

      assert_no_text "-50"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/components/rankings/score_curve_component_test.rb test/components/rankings/configuration_facts_component_test.rb`
Expected: FAIL — uninitialized constants.

- [ ] **Step 3: Generate both components**

```bash
bin/rails generate component Rankings::ScoreCurve curve media_nouns
bin/rails generate component Rankings::ConfigurationFacts configurations
```

- [ ] **Step 4: Write the score curve component**

Replace `app/components/rankings/score_curve_component.rb`:

```ruby
# frozen_string_literal: true

# Shows how little rank *within* a list matters compared to being on it at all.
#
# The numbers are computed from the live configuration rather than hardcoded,
# because exponent and bonus pool differ per domain.
class Rankings::ScoreCurveComponent < ViewComponent::Base
  def initialize(curve:, media_nouns:)
    @curve = curve
    @media_nouns = media_nouns
  end

  private

  attr_reader :curve, :media_nouns
end
```

Replace `app/components/rankings/score_curve_component.html.erb`:

```erb
<p class="mb-4">
  Being named on a list is worth that list's full weight. Where something places
  <em>on</em> that list adds a bonus on top &mdash; but a much smaller one than
  most people expect.
</p>

<div class="overflow-x-auto mb-4">
  <table class="table w-full">
    <thead>
      <tr>
        <th scope="col">Position on a <%= curve.list_length %>-entry list</th>
        <th scope="col" class="text-right">Score</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <th scope="row">#1</th>
        <td class="text-right"><%= curve.top_score %></td>
      </tr>
      <tr>
        <th scope="row">#<%= curve.list_length / 2 %></th>
        <td class="text-right"><%= curve.middle_score %></td>
      </tr>
      <tr>
        <th scope="row">#<%= curve.list_length %></th>
        <td class="text-right"><%= curve.bottom_score %></td>
      </tr>
    </tbody>
  </table>
</div>

<p>
  Topping a list is worth <strong><%= curve.ratio %>&times;</strong> what placing
  last on it is &mdash; and that ratio barely moves whether the list holds ten
  entries or five hundred. This is deliberate. Agreement between many lists is a
  stronger signal than one editor's ordering, so <%= media_nouns %> that many
  good lists name will outrank <%= media_nouns %> that top a single list.
</p>
```

- [ ] **Step 5: Write the configuration facts component**

Replace `app/components/rankings/configuration_facts_component.rb`:

```ruby
# frozen_string_literal: true

# The live numbers behind the current rankings.
#
# The weight floor is reported as 0, not min_list_weight. Total penalty is capped
# at 100%, so weight can never fall below 0 and a negative stored minimum (books
# carries -50) is unreachable. Printing it would be accurate about the column and
# wrong about the system.
class Rankings::ConfigurationFactsComponent < ViewComponent::Base
  WEIGHT_FLOOR = 0

  def initialize(configurations:)
    @configurations = configurations
  end

  private

  attr_reader :configurations

  def weight_floor = WEIGHT_FLOOR
end
```

Replace `app/components/rankings/configuration_facts_component.html.erb`:

```erb
<div class="overflow-x-auto">
  <table class="table w-full">
    <thead>
      <tr>
        <th scope="col">Setting</th>
        <% configurations.each do |configuration| %>
          <th scope="col"><%= configuration.media_noun_plural.capitalize %></th>
        <% end %>
      </tr>
    </thead>
    <tbody>
      <tr>
        <th scope="row">Configuration</th>
        <% configurations.each do |configuration| %>
          <td><%= configuration.name %></td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Starting weight</th>
        <% configurations.each do %>
          <td>100</td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Lowest possible weight</th>
        <% configurations.each do %>
          <td><%= weight_floor %></td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Position bonus curve</th>
        <% configurations.each do |configuration| %>
          <td><%= configuration.exponent.to_f %></td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Bonus pool</th>
        <% configurations.each do |configuration| %>
          <td><%= configuration.bonus_pool_percentage.to_f %></td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Typical voters per list</th>
        <% configurations.each do |configuration| %>
          <td><%= configuration.median_voter_count || "not recorded" %></td>
        <% end %>
      </tr>
      <tr>
        <th scope="row">Recency adjustment</th>
        <% configurations.each do |configuration| %>
          <td>
            <% if configuration.apply_list_dates_penalty? %>
              up to <%= configuration.max_list_dates_penalty_percentage %>%,
              fading out over <%= configuration.max_list_dates_penalty_age %> years
            <% else %>
              off
            <% end %>
          </td>
        <% end %>
      </tr>
    </tbody>
  </table>
</div>
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/components/rankings/`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/rankings test/components/rankings
git add app/components/rankings test/components/rankings
git commit -m "Add score curve and configuration facts components"
```

---

### Task 7: `Rankings::PageComponent` — the shell and all prose

**Files:**
- Create: `app/components/rankings/page_component.rb`
- Create: `app/components/rankings/page_component.html.erb`
- Test: `test/components/rankings/page_component_test.rb`

**Interfaces:**
- Consumes: `ExplainerData::Data` from Task 3; all four components from Tasks 4-6.
- Produces: `Rankings::PageComponent.new(data:, domain:)` where `domain` is `:books`, `:music` or `:games`.

The western-tilt section is books-only: it is the only domain with
`percentage_western` implemented and the only one with a Global Canon page.

- [ ] **Step 1: Write the failing test**

Create `test/components/rankings/page_component_test.rb`:

```ruby
require "test_helper"

module Rankings
  class PageComponentTest < ViewComponent::TestCase
    setup do
      @data = Services::RankingConfiguration::ExplainerData.call(
        configurations: [ranking_configurations(:books_global)]
      ).data
    end

    test "renders the main heading" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_selector "h1", text: "How Our Rankings Work"
    end

    test "links to both open source repositories" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_selector "a[href='https://github.com/ssherman/weighted_list_rank']"
      assert_selector "a[href='https://github.com/ssherman/the-greatest/']"
    end

    test "describes the recency adjustment as hitting recent items, not old ones" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_text(/same year/i)
      assert_no_text(/classic .{0,40}unfairly penalized/i)
    end

    test "books renders the western tilt section" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_text(/western/i)
      assert_selector "a[href='/global-canon']"
    end

    test "music does not render the western tilt section" do
      music = Services::RankingConfiguration::ExplainerData.call(
        configurations: [ranking_configurations(:music_albums_global)]
      ).data

      render_inline(PageComponent.new(data: music, domain: :music))

      assert_no_selector "a[href='/global-canon']"
    end

    test "renders the live stat counts" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_text number_with_delimiter(@data.active_lists_count)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/rankings/page_component_test.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Generate the component**

Run: `bin/rails generate component Rankings::Page data domain`

- [ ] **Step 4: Write the component class**

Replace `app/components/rankings/page_component.rb`:

```ruby
# frozen_string_literal: true

# The whole /rankings page for one domain.
#
# Sections run flat down the page rather than behind expanders: this is a
# transparency page, and hiding its substance undercuts the point. Only the full
# penalty tables collapse, because there are roughly fifty rows of them.
class Rankings::PageComponent < ViewComponent::Base
  ALGORITHM_REPO = "https://github.com/ssherman/weighted_list_rank"
  SITE_REPO = "https://github.com/ssherman/the-greatest/"
  DISCORD_URL = "https://discord.com/invite/8JE9fpMtZp"

  def initialize(data:, domain:)
    @data = data
    @domain = domain.to_sym
  end

  private

  attr_reader :data, :domain

  # Books only: percentage_western is implemented for books lists alone, and
  # Global Canon is a books page. Rendering this anywhere else would promise a
  # correction that does not exist.
  def western_section? = domain == :books

  def configuration = data.primary_configuration

  def date_penalty_age = configuration.max_list_dates_penalty_age

  def date_penalty_percentage = configuration.max_list_dates_penalty_percentage

  def date_penalty? = configuration.apply_list_dates_penalty?
end
```

- [ ] **Step 5: Write the template**

Replace `app/components/rankings/page_component.html.erb`:

```erb
<div class="max-w-3xl">
  <h1 class="text-3xl md:text-4xl font-bold mb-6">How Our Rankings Work</h1>

  <p class="text-lg leading-relaxed mb-4">
    We do not pick the greatest <%= data.media_nouns %> ourselves. We collect
    published lists &mdash; critics' rankings, reader polls, prize long-lists,
    library surveys &mdash; and combine them.
  </p>

  <p class="leading-relaxed mb-8">
    The part that matters is that we do not count them equally. A carefully
    judged ranking by <%= data.media_nouns %> critics and an anonymous listicle
    are not the same evidence, so we weigh each list by how much we can trust it.
    The result is that <strong><%= data.media_nouns %> many good lists agree on
    beat <%= data.media_nouns %> that top a single list</strong>.
  </p>

  <div class="stats stats-vertical md:stats-horizontal bg-base-200 w-full mb-10">
    <div class="stat">
      <div class="stat-title">Lists we count</div>
      <div class="stat-value"><%= number_with_delimiter(data.active_lists_count) %></div>
    </div>
    <div class="stat">
      <div class="stat-title">Ranked <%= data.media_nouns %></div>
      <div class="stat-value"><%= number_with_delimiter(data.ranked_items_count) %></div>
    </div>
    <div class="stat">
      <div class="stat-title">Typical list length</div>
      <div class="stat-value"><%= number_with_delimiter(data.median_list_count) %></div>
    </div>
  </div>

  <h2 class="text-2xl font-bold mb-4">Why we think this is accurate</h2>
  <ul class="list-disc list-outside ps-5 space-y-2 mb-10">
    <li>
      <strong>It is a consensus, not an opinion.</strong> No single list can
      outvote <%= number_with_delimiter(data.active_lists_count) %> of them.
    </li>
    <li>
      <strong>Every list's weight is public.</strong> Nothing about the scoring is
      hidden &mdash; you can see what each list was worth and why.
    </li>
    <li>
      <strong>The code is open source.</strong> Both the ranking algorithm and this
      entire site can be read, checked, and argued with.
    </li>
    <li>
      <strong>We correct for known biases</strong> rather than pretending they are
      not there, and we say plainly where the corrections fall short.
    </li>
  </ul>

  <% if western_section? %>
    <h2 class="text-2xl font-bold mb-4">Why the list still skews western</h2>
    <p class="leading-relaxed mb-4">
      This is the most common complaint we get, and it is a fair one. Our top 100
      is roughly <strong>94% western</strong>. Here is exactly why, and what we do
      about it.
    </p>
    <p class="leading-relaxed mb-4">
      The lists we ingest are themselves overwhelmingly western &mdash; the median
      source list is about <strong>92% western</strong>. Weighting redistributes
      influence <em>among</em> those lists, so when almost all of them lean the
      same way, weighting cannot pull the result somewhere they never went.
    </p>
    <p class="leading-relaxed mb-2">Three structural forces keep it that way:</p>
    <ol class="list-decimal list-outside ps-5 space-y-2 mb-4">
      <li>
        <strong>Translation flows one way.</strong> English-language books are
        translated into other languages far more than the reverse, so they appear
        on more lists worldwide.
      </li>
      <li>
        <strong>Anglophone markets under-translate.</strong> Only a sliver of books
        published each year in the US or UK are translations, which limits what
        most voters have ever had the chance to read.
      </li>
      <li>
        <strong>The canon has inertia.</strong> Big "best of" lists, prize juries
        and school syllabi inherited a western core decades ago and tend to
        reinforce it.
      </li>
    </ol>
    <p class="leading-relaxed mb-4">
      What we do: a list that presents itself as general but turns out to be 90% or
      more western has its weight reduced automatically. That currently applies to
      <strong>303 of our <%= number_with_delimiter(data.active_lists_count) %>
      lists</strong>. Lists that declare a regional focus up front are exempt
      &mdash; being a list of great Japanese novels is honest, not a bias.
    </p>
    <p class="leading-relaxed mb-4">
      <strong>And that is not enough.</strong> Trimming the worst offenders by a
      few points cannot fix a field where nearly every source leans the same
      direction. So we built a different tool instead.
    </p>
    <div class="rounded-box bg-base-200 p-4 md:p-6 mb-4">
      <h3 class="text-lg font-semibold mb-2">The Global Canon</h3>
      <p class="mb-4">
        Rather than reweighting the lists, the
        <%= link_to "Global Canon", "/global-canon", class: "link link-primary" %>
        rebuilds the selection with a cap on how many books any one country may
        contribute. It comes out around <strong>45% western</strong> instead of
        94%. If the main list's tilt is what bothers you, that page is the answer,
        not a footnote.
      </p>
      <div class="flex flex-wrap gap-2">
        <%= link_to "The Global Canon", "/global-canon", class: "btn btn-primary btn-sm" %>
        <%= link_to "Non-Western Canon", "/non-western", class: "btn btn-outline btn-sm" %>
        <%= link_to "African Books", "/africa", class: "btn btn-outline btn-sm" %>
        <%= link_to "Asian Books", "/asia", class: "btn btn-outline btn-sm" %>
        <%= link_to "Latin American Books", "/latin-america", class: "btn btn-outline btn-sm" %>
      </div>
    </div>
    <p class="leading-relaxed mb-10">
      The thing that would genuinely move this is better source material. If you
      know a high-participation reading poll, library survey or prize long-list
      from outside the usual western circuits,
      <%= link_to "send it to us", SiteContact::MAILTO, class: "link link-primary" %>.
      More than any adjustment we can make to the maths, that is what changes the
      answer.
    </p>
  <% end %>

  <h2 class="text-2xl font-bold mb-4">How a list earns its weight</h2>
  <p class="leading-relaxed mb-4">
    Every list starts at 100 and loses ground for anything that makes it less
    representative &mdash; a tiny voting panel, an undocumented process, a narrow
    remit. Sources we have judged high quality get their total reduction cut by a
    third. Weight never falls below 0.
  </p>
  <div class="mb-10">
    <%= render Rankings::WeightExampleComponent.new(example: data.worked_example) %>
  </div>

  <h2 class="text-2xl font-bold mb-4">What we adjust for</h2>
  <p class="leading-relaxed mb-6">
    These are the things that reduce a list's weight, grouped by what they are
    really measuring. Some are applied by hand when a list is catalogued; others
    are computed automatically from the list itself.
  </p>
  <div class="mb-10">
    <%= render Rankings::PenaltyTableComponent.new(groups: data.penalty_groups) %>
  </div>

  <h2 class="text-2xl font-bold mb-4">How something earns its score</h2>
  <div class="mb-10">
    <%= render Rankings::ScoreCurveComponent.new(curve: data.score_curve, media_nouns: data.media_nouns) %>
  </div>

  <% if date_penalty? %>
    <h2 class="text-2xl font-bold mb-4">Correcting for recency</h2>
    <p class="leading-relaxed mb-10">
      A list published this year cannot tell you what will still matter in fifty
      years &mdash; it has not had the chance to find out. So when a list names
      something released in the same year the list came out, that placement counts
      for up to <strong><%= date_penalty_percentage %>%</strong> less. The
      reduction shrinks the older the work was when the list named it, and
      disappears entirely once the gap reaches
      <strong><%= date_penalty_age %> years</strong>. Classics are not penalized by
      this &mdash; they are what it protects. Yearly awards always take the full
      reduction, because "best of 2019" is a statement about one year, not about
      all time.
    </p>
  <% end %>

  <h2 class="text-2xl font-bold mb-4">The current settings</h2>
  <div class="mb-10">
    <%= render Rankings::ConfigurationFactsComponent.new(configurations: data.configurations) %>
  </div>

  <h2 class="text-2xl font-bold mb-4">Read the code</h2>
  <p class="leading-relaxed mb-4">
    Both the ranking algorithm and this entire site are open source. If you think
    the maths is wrong, you can go and check.
  </p>
  <ul class="list-disc list-outside ps-5 space-y-1 mb-6">
    <li>
      <%= link_to "The ranking algorithm (weighted_list_rank)", Rankings::PageComponent::ALGORITHM_REPO,
          target: "_blank", rel: "noopener", class: "link link-primary" %>
    </li>
    <li>
      <%= link_to "The Greatest (this site's full source)", Rankings::PageComponent::SITE_REPO,
          target: "_blank", rel: "noopener", class: "link link-primary" %>
    </li>
  </ul>
  <p class="leading-relaxed">
    Suggestions, corrections and new lists are all welcome &mdash;
    <%= link_to "join us on Discord", Rankings::PageComponent::DISCORD_URL,
        target: "_blank", rel: "noopener", class: "link link-primary" %>
    or <%= link_to "get in touch", SiteContact::MAILTO, class: "link link-primary" %>.
  </p>
</div>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/components/rankings/page_component_test.rb`
Expected: PASS.

- [ ] **Step 7: Confirm no removed daisyUI classes crept in**

Run: `bin/rails test test/lint/daisyui_v4_classes_test.rb`
Expected: PASS.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/components/rankings test/components/rankings
git add app/components/rankings test/components/rankings
git commit -m "Add rankings page component with full explainer copy"
```

---

### Task 8: Controllers, routes and footer

**Files:**
- Create: `app/controllers/books/default_controller.rb`
- Create: `app/views/books/default/rankings.html.erb`
- Modify: `app/controllers/music/default_controller.rb:29-43`
- Modify: `app/controllers/games/default_controller.rb:11-22`
- Modify: `app/views/music/default/rankings.html.erb`
- Modify: `app/views/games/default/rankings.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/components/footer_component.rb`
- Test: `test/controllers/books/default_controller_test.rb`
- Test: `test/components/footer_component_test.rb`

**Interfaces:**
- Consumes: `ExplainerData` (Task 3), `Rankings::PageComponent` (Task 7).
- Produces: route helper `books_rankings_path`.

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/books/default_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class DefaultControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestbooks.org"
    end

    test "should get rankings page" do
      get books_rankings_url
      assert_response :success
    end

    test "rankings page has a title" do
      get books_rankings_url
      assert_select "title"
    end

    test "rankings page has a meta description" do
      get books_rankings_url
      assert_select "meta[name='description']"
    end

    test "rankings page assigns explainer data" do
      get books_rankings_url
      assert_not_nil assigns(:data)
    end

    test "rankings page does not trap links in a turbo frame" do
      get books_rankings_url
      assert_no_frame_trapped_links
    end
  end
end
```

Append to `test/components/footer_component_test.rb`:

```ruby
  test "books footer links to its rankings page" do
    render_inline(FooterComponent.new(domain: :books))

    assert_selector "a[href='/rankings']"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/books/default_controller_test.rb test/components/footer_component_test.rb`
Expected: FAIL — `undefined local variable or method 'books_rankings_url'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the books `DomainConstraint` block, next to the other
top-level books pages (near `get "search", to: "books/searches#index", as: :books_search`), add:

```ruby
    get "rankings", to: "books/default#rankings", as: :books_rankings
```

- [ ] **Step 4: Create the books controller**

Run: `bin/rails generate controller Books::Default rankings --skip-routes --no-helper`

Then replace `app/controllers/books/default_controller.rb`:

```ruby
class Books::DefaultController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :cache_for_index_page, only: [:rankings]

  # A real list, pinned so the worked example's surrounding copy can name its
  # numbers. ExplainerData falls back to the heaviest active list if this one is
  # ever archived, so the page cannot break on a data change.
  EXAMPLE_LIST_ID = 43

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [Books::RankingConfiguration.default_primary],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
end
```

- [ ] **Step 5: Create the books view**

Create `app/views/books/default/rankings.html.erb`:

```erb
<%
  content_for :page_title, "How Our Rankings Work | The Greatest Books"
  content_for :meta_description, "How we rank the greatest books: hundreds of weighted lists, what lowers a list's weight, and why the result still skews western."
%>

<%= render Rankings::PageComponent.new(data: @data, domain: :books) %>
```

- [ ] **Step 6: Run the books controller test**

Run: `bin/rails test test/controllers/books/default_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Rewire music**

Replace the `rankings` action in `app/controllers/music/default_controller.rb`:

```ruby
  EXAMPLE_LIST_ID = 10_015

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [
        Music::Albums::RankingConfiguration.default_primary,
        Music::Songs::RankingConfiguration.default_primary
      ],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
```

Replace the whole of `app/views/music/default/rankings.html.erb`:

```erb
<%
  content_for :page_title, "How Our Rankings Work | The Greatest Music"
  content_for :meta_description, "How we rank the greatest albums and songs: hundreds of weighted lists, what lowers a list's weight, and how scoring works."
%>

<%= render Rankings::PageComponent.new(data: @data, domain: :music) %>
```

- [ ] **Step 8: Rewire games**

Replace the `rankings` action in `app/controllers/games/default_controller.rb`:

```ruby
  EXAMPLE_LIST_ID = 11_376

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [Games::RankingConfiguration.default_primary],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
```

Replace the whole of `app/views/games/default/rankings.html.erb`:

```erb
<%
  content_for :page_title, "How Our Rankings Work | The Greatest Games"
  content_for :meta_description, "How we rank the greatest games: dozens of weighted lists, what lowers a list's weight, and how scoring works."
%>

<%= render Rankings::PageComponent.new(data: @data, domain: :games) %>
```

- [ ] **Step 9: Add books to the footer**

In `app/components/footer_component.rb`, delete the three-line comment above
`site_links` that explains the books absence, and change `rankings_path`:

```ruby
  def rankings_path
    case domain
    when :books then helpers.books_rankings_path
    when :music then helpers.music_rankings_path
    when :games then helpers.games_rankings_path
    end
  end
```

- [ ] **Step 10: Run all affected tests**

Run: `bin/rails test test/controllers/books/default_controller_test.rb test/controllers/music/default_controller_test.rb test/controllers/games/default_controller_test.rb test/components/footer_component_test.rb`
Expected: PASS.

- [ ] **Step 11: Add the N+1 guard**

Append to `test/controllers/books/default_controller_test.rb`:

```ruby
    test "rankings page query count does not grow with the number of penalties" do
      get books_rankings_url # warm any per-process memoization

      baseline = count_queries { get books_rankings_url }

      extra = Penalty.create!(type: "Books::Penalty", name: "Extra", category: :list_integrity,
        description: "Added to prove the page does not query per penalty.")
      PenaltyApplication.create!(penalty: extra, ranking_configuration: ranking_configurations(:books_global), value: 5)

      assert_equal baseline, count_queries { get books_rankings_url }
    end

    private

    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) {
        count += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION])
      }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
```

- [ ] **Step 12: Run the guard**

Run: `bin/rails test test/controllers/books/default_controller_test.rb`
Expected: PASS. If it fails because the count grew, add the missing `includes` to
`ExplainerData#penalty_groups` rather than relaxing the assertion.

- [ ] **Step 13: Run the whole suite**

Run: `bin/rails db:test:prepare test`
Expected: all green, and no new warning lines beyond the two known upstream sources.

- [ ] **Step 14: Lint and commit**

```bash
bundle exec standardrb --fix app config test
git add app config test
git commit -m "Serve the shared rankings page from books, music and games"
```

---

### Task 9: Playwright E2E for the books page

**Files:**
- Create: `web-app/e2e/tests/books/rankings.spec.ts`

**Interfaces:**
- Consumes: the `/rankings` route from Task 8.

- [ ] **Step 1: Confirm port 3000 is yours**

Run:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

Expected: either "port 3000 is free" or this worktree's path. **If it prints another
checkout, stop and tell the user** — do not kill their server and do not use another
port, because routes are host-constrained.

- [ ] **Step 2: Write the test**

Create `web-app/e2e/tests/books/rankings.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books rankings explainer', () => {
  test('the page loads and renders its heading', async ({ page }) => {
    const response = await page.goto('/rankings');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'How Our Rankings Work', level: 1 })).toBeVisible();
  });

  test('the footer links to it from another page', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'Ranking Details' }).click();

    await expect(page).toHaveURL(/\/rankings$/);
  });

  test('the western tilt section is present and links to the Global Canon', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: /why the list still skews western/i })).toBeVisible();

    await page.getByRole('link', { name: 'The Global Canon', exact: true }).click();
    await expect(page).toHaveURL(/\/global-canon$/);
  });

  test('a penalty group expands to reveal its table', async ({ page }) => {
    await page.goto('/rankings');

    const firstGroup = page.locator('details').first();
    await expect(firstGroup.locator('table')).toBeHidden();

    await firstGroup.locator('summary').click();

    await expect(firstGroup.locator('table')).toBeVisible();
  });

  test('both open source repositories are linked', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.locator('a[href="https://github.com/ssherman/weighted_list_rank"]').first()).toBeVisible();
    await expect(page.locator('a[href="https://github.com/ssherman/the-greatest/"]').first()).toBeVisible();
  });
});
```

- [ ] **Step 3: Build assets and start the server**

```bash
yarn build:all
bin/rails server
```

(Run the server in a separate shell; `bin/dev` needs a TTY and is not used here.)

- [ ] **Step 4: Run the E2E test**

Run: `yarn test:e2e e2e/tests/books/rankings.spec.ts`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add web-app/e2e/tests/books/rankings.spec.ts
git commit -m "Add E2E coverage for the books rankings page"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Shared engine, three thin callers | 3, 8 |
| `Services::RankingConfiguration::ExplainerData` | 3 |
| Five components under `app/components/rankings/` | 4, 5, 6, 7 |
| `Books::DefaultController#rankings`, cached | 8 |
| Route `books_rankings` | 8 |
| Footer exception removed | 8 |
| `category` enum, nullable, admin-editable | 1 |
| Five categories, books split 7/3/7/16/8 | 1, 2 |
| Uncategorized renders under "Other" | 3 (service), 4 (render) |
| All 49 descriptions rewritten, idempotent rake task | 2 |
| Live worked example with fallback | 3, 5 |
| Content sections 1-10 | 7 |
| Western tilt as a first-class section | 7 |
| Date penalty stated correctly | 7 |
| Position worth ~1.24x | 3 (computed), 6 (rendered) |
| Weight floor stated as 0, not -50 | 6 |
| Controller test per domain | 8 |
| Component test per component | 4, 5, 6, 7 |
| Service test incl. fallbacks | 3 |
| Query-count guard | 8 |
| Model test for the enum | 1 |
| Rake task idempotency test | 2 |
| Playwright E2E | 9 |

No gaps.

**Placeholder scan:** none. Every code step carries real code; the 49 descriptions are written out in full in Task 2.

**Type consistency:** `ExplainerData::Data` readers used in Tasks 5-8 (`media_nouns`, `active_lists_count`, `ranked_items_count`, `median_list_count`, `penalty_groups`, `worked_example`, `score_curve`, `configurations`, `primary_configuration`) all match the `Data` struct defined in Task 3. `PenaltyGroup#title`/`#penalties`, `WorkedExample#weight`/`#penalties`/`#quality_bonus_applied`, and `ScoreCurve#top_score`/`#bottom_score`/`#ratio` match their definitions. `Penalty.category_title` is defined in Task 1 and consumed in Task 3.

## Known risks

- **Fixture names are verified against `test/fixtures/`, not assumed:** `ranking_configurations(:books_global)`, `:music_albums_global`, `:music_songs_global` and `lists(:books_list)` all exist. If a test still fails on a fixture, read the YAML with `grep -n "^[a-z_]*:" test/fixtures/<file>.yml` — never call `create_fixtures` to check, it truncates every table it names.
- **`SiteContact::MAILTO` is verified** — defined at `app/lib/site_contact.rb:24` and already used by `FooterComponent`.
- **The pinned example list ids (books 43, music 10015, games 11376) exist in development.** If any is absent in another environment the service falls back to the heaviest active list, which is why that fallback is tested rather than assumed.
- **The 303-lists figure in the western section is hardcoded copy.** Accurate as of 2026-08-30 but it will drift as lists are added. If it should track the data, add a `western_penalty_list_count` to `ExplainerData` and interpolate it; the spec did not call for that, so it stays prose for now.
- **Fixture-backed component tests render very few penalties**, so the query-count guard in Task 8 is the only thing standing between this page and an N+1 against 49 penalties in production. Do not weaken it.
- **Books' `ranked_lists.weight` had drifted to ~2x** the computed value before this work (legacy migration scale, never recalculated). It is now consistent in development — 0 of 623 rows disagree with their stored details. See the spec's Rollout section: production is unverified, and a weight run there must be checked for persistence rather than trusted on its success message.
