# CSV Exports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Download CSV" button on every rankings page (books, music albums, music songs, games), saved-search page and user-list page; members get everything, signed-in non-members get the top 500; the unfiltered member export of a ranking configuration is a pre-built file that is regenerated after every ranking calculation and nightly.

**Architecture:** One `CsvExport` row per `RankingConfiguration` holds a pre-built ActiveStorage file, claimed/generated through `Services::CsvExports::RequestGenerate` + `Generate` and `CsvExports::GenerateJob`. Everything else is generated on demand by `CsvExports::RankedItems` / `SavedSearch` / `UserList` through per-domain row classes, served from dedicated `export` actions (never the edge-cached `index`) via the `CsvExportable` concern. A static DaisyUI modal plus a small Stimulus controller explains the 500-row cap to non-members; the server enforces it.

**Tech Stack:** Rails 8.1, Ruby 4.0.6 (mise), Postgres, Sidekiq 8 + sidekiq-cron, ActiveStorage (R2 in dev/prod, Disk in test), Minitest 6 + Mocha, ViewComponent, Stimulus, DaisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-18-csv-exports-design.md` — read it first. Section numbers below (§) refer to it.

---

## Before you start

- Work in a worktree on branch `csv-exports` (the spec commit is already on it). Use the `EnterWorktree` tool, never `git worktree add` (see `CLAUDE.md`).
- Run every Rails command from `web-app/`. If `ruby -v` prints anything but 4.0.6, prefix commands with `mise exec --`.
- `bin/rails g model` runs annotaterb's post-migrate hook, which tries to connect to the legacy books database. If that database is not on this machine, export `ANNOTATERB_SKIP_ON_DB_TASKS=1` for the generator and migration commands.
- `benchmark` is not a default gem in Ruby 4 — the timing step uses `Process.clock_gettime`.
- Every commit ends with the trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`. The commit commands below include it.
- Run `bundle exec standardrb <changed files>` before each commit; `--fix` autocorrects formatting.
- Constant lookup landmine, twice over: inside `module Services; module CsvExports`, a bare `CsvExports::Registry` resolves to `Services::CsvExports::Registry` (NameError) and a bare `CsvExport` still resolves to the model only because nothing shadows it — root-anchor everything (`::CsvExports::Registry`, `::CsvExport`, `::RankingConfiguration`) in service code, exactly as `Services::RankingConfigurations::RequestRefresh` does. Inside `module CsvExports; module Books`, a bare `Books::Book` resolves to `CsvExports::Books::Book` — root-anchor model constants there too (`::Books::Book`).

## File structure

```
web-app/
  db/migrate/<ts>_create_csv_exports.rb
  app/models/csv_export.rb                              # row per configuration: status, stamps, file
  app/models/ranking_configuration.rb                   # + has_one :csv_export
  app/lib/membership_gate.rb                            # + :csv_export_full
  app/lib/csv_exports/registry.rb                       # exportable config types -> row class, relation, slug, noun
  app/lib/csv_exports/limits.rb                         # 500 for non-members, nil for members
  app/lib/csv_exports/writer.rb                         # BOM + header + rows -> IO
  app/lib/csv_exports/aggregate.rb                      # one grouped string_agg query per many-to-many column
  app/lib/csv_exports/books/ranked_book_row.rb          # HEADERS / preloads / context / row
  app/lib/csv_exports/music/ranked_album_row.rb
  app/lib/csv_exports/music/ranked_song_row.rb
  app/lib/csv_exports/games/ranked_game_row.rb
  app/lib/csv_exports/ranked_items.rb                   # relation + row class + limit -> rows on an IO
  app/lib/csv_exports/saved_search.rb                   # pages Books::SavedSearchQuery up to the cap
  app/lib/csv_exports/user_list.rb                      # moved verbatim from MyListsController
  app/lib/services/csv_exports/request_generate.rb      # find_or_create + atomic claim + enqueue
  app/lib/services/csv_exports/generate.rb              # build file, attach, stamp
  app/sidekiq/csv_exports/generate_job.rb               # queue low, retry false
  app/sidekiq/csv_exports/refresh_global_job.rb         # nightly fan-out
  app/sidekiq/calculate_rankings_job.rb                 # + RequestGenerate on success
  app/sidekiq/ranking_configurations/refresh_job.rb     # + RequestGenerate on success
  config/schedule.yml                                   # + csv_exports_refresh_global
  app/controllers/concerns/csv_exportable.rb            # shared export-action skeleton
  app/views/csv_exports/preparing.html.erb              # 202 page while the file is built
  app/controllers/books/ranked_items_controller.rb      # + export, + @csv_export_path
  app/controllers/music/albums/ranked_items_controller.rb
  app/controllers/music/songs/ranked_items_controller.rb
  app/controllers/games/ranked_items_controller.rb
  app/controllers/saved_searches_controller.rb          # + export
  app/controllers/my_lists_controller.rb                # csv branch delegates to CsvExports::UserList
  app/lib/books/saved_search_query.rb                   # + ranked_score in the hydrate select
  app/components/csv_exports/download_button_component.rb (+ .html.erb)
  app/javascript/controllers/csv_export_controller.js
  app/javascript/manifests/web_shared.js                # + register "csv-export"
  app/views/{books,music/albums,music/songs,games}/ranked_items/index.html.erb   # + button
  app/views/saved_searches/show.html.erb                # + button
  app/views/my_lists/show.html.erb                      # button component replaces the link
  app/lib/actions/admin/regenerate_csv_export.rb
  app/controllers/admin/ranking_configurations_controller.rb   # + allowed action name
  app/views/admin/ranking_configurations/show.html.erb  # + CSV Export card
  config/routes.rb                                      # export routes
  e2e/tests/books/rankings-csv-export.spec.ts
  e2e/tests/books/account/rankings-csv-export.spec.ts
  e2e/tests/books/account/saved-search-csv-export.spec.ts
  e2e/tests/books/member/rankings-csv-export.spec.ts
  e2e/tests/music/csv-export.spec.ts
  e2e/tests/games/csv-export.spec.ts
docs/features/csv-exports.md
docs/features/user-lists.md                             # CSV section points at the new doc
```

---

### Task 1: `CsvExport` model

**Files:**
- Create: `web-app/db/migrate/<timestamp>_create_csv_exports.rb` (generated)
- Create: `web-app/app/models/csv_export.rb` (generated, then replaced)
- Create: `web-app/test/models/csv_export_test.rb` (generated, then replaced)
- Modify: `web-app/test/fixtures/csv_exports.yml` (generated — must be emptied)
- Modify: `web-app/app/models/ranking_configuration.rb`

- [ ] **Step 1: Generate the model**

```bash
cd web-app
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails g model CsvExport ranking_configuration:references status:integer requested_at:datetime generated_at:datetime row_count:integer byte_size:bigint error_message:text
```

- [ ] **Step 2: Fix the migration — status default, unique index**

Replace the generated migration body with:

```ruby
class CreateCsvExports < ActiveRecord::Migration[8.1]
  def change
    create_table :csv_exports do |t|
      # One export per configuration (spec §6): the unique index is the invariant.
      t.references :ranking_configuration, null: false, foreign_key: true, index: {unique: true}
      t.integer :status, null: false, default: 0
      t.datetime :requested_at
      t.datetime :generated_at
      t.integer :row_count
      t.bigint :byte_size
      t.text :error_message

      t.timestamps
    end
  end
end
```

- [ ] **Step 3: Empty the generated fixture file**

The generator writes `one:`/`two:` rows pointing at a `ranking_configuration: one` that does not exist, which breaks every fixture load. Replace `test/fixtures/csv_exports.yml` with:

```yaml
# Deliberately empty. Tests create the export rows they need so the claim,
# stale-claim and download paths start from a known state.
```

- [ ] **Step 4: Migrate**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
bin/rails db:test:prepare
```

Expected: `create_table(:csv_exports)` in the output, `db/schema.rb` gains the table with `index_csv_exports_on_ranking_configuration_id` **unique**.

- [ ] **Step 5: Write the failing model tests**

Replace `test/models/csv_export_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class CsvExportTest < ActiveSupport::TestCase
  setup do
    @config = ranking_configurations(:games_secondary)
  end

  test "starts pending with no file" do
    export = CsvExport.create!(ranking_configuration: @config)

    assert export.pending?
    refute export.file.attached?
    refute export.downloadable?
  end

  test "one export per configuration" do
    CsvExport.create!(ranking_configuration: @config)

    duplicate = CsvExport.new(ranking_configuration: @config)
    refute duplicate.valid?
    assert_includes duplicate.errors[:ranking_configuration_id], "has already been taken"

    # insert_all (no bang) would skip the duplicate silently; the bang form raises.
    assert_raises(ActiveRecord::RecordNotUnique) do
      CsvExport.insert_all!([{ranking_configuration_id: @config.id, status: 0, created_at: Time.current, updated_at: Time.current}])
    end
  end

  test "pending, ready and failed exports are claimable" do
    export = CsvExport.create!(ranking_configuration: @config)
    assert export.claimable?

    export.update!(status: :ready)
    assert export.claimable?

    export.update!(status: :failed)
    assert export.claimable?
  end

  test "a fresh generation claim is not claimable" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: 5.minutes.ago)

    refute export.claimable?
  end

  test "a generation claim older than the stale window is claimable again" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating,
      requested_at: (CsvExport::GENERATION_STALE_AFTER + 1.minute).ago)

    assert export.claimable?
  end

  test "a generating claim with no requested_at is treated as abandoned" do
    export = CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: nil)

    assert export.claimable?
  end

  test "downloadable only when ready with a file attached" do
    export = CsvExport.create!(ranking_configuration: @config, status: :ready)
    refute export.downloadable?

    export.file.attach(io: StringIO.new("\uFEFFRank\n"), filename: "x.csv", content_type: "text/csv")
    assert export.downloadable?

    export.update!(status: :failed)
    refute export.downloadable?
  end

  test "is destroyed with its configuration" do
    export = CsvExport.create!(ranking_configuration: @config)

    @config.destroy!

    assert_nil CsvExport.find_by(id: export.id)
  end
end
```

- [ ] **Step 6: Run the tests to see them fail**

```bash
bin/rails test test/models/csv_export_test.rb
```

Expected: failures/errors — `claimable?`, `downloadable?`, and `has_one :csv_export` do not exist yet.

- [ ] **Step 7: Write the model**

Replace `app/models/csv_export.rb`:

```ruby
# frozen_string_literal: true

# The pre-built CSV of one ranking configuration's full, unfiltered ranking
# (spec §6). One row per configuration -- the unique index is the invariant --
# regenerated after every successful ranking calculation and nightly for the
# global configurations, never on a TTL.
#
# The claim/stale-claim rules mirror RankingConfiguration#refresh_claimable?:
# a `generating` row whose claim is older than GENERATION_STALE_AFTER was left
# behind by a worker killed before its rescue could run, and may be re-claimed.
class CsvExport < ApplicationRecord
  GENERATION_STALE_AFTER = 15.minutes

  belongs_to :ranking_configuration
  has_one_attached :file

  enum :status, {pending: 0, generating: 1, ready: 2, failed: 3}

  # No uniqueness validation: it would run a SELECT inside create! and turn a
  # race on a configuration's first row into RecordInvalid, which
  # find_or_create_by! does not rescue. The unique index is the invariant.

  # The rows a caller may claim for generation, as SQL, kept beside claimable?
  # so the two cannot drift.
  scope :claimable, -> {
    where("status <> :generating OR requested_at IS NULL OR requested_at < :stale",
      generating: statuses[:generating], stale: GENERATION_STALE_AFTER.ago)
  }

  def claimable?
    !generating? || requested_at.nil? || requested_at < GENERATION_STALE_AFTER.ago
  end

  # Whatever `status` says about the latest attempt, an attached file is a good
  # file: Generate only attaches on success. So a member keeps downloading the
  # last good file while a regeneration runs or after one fails (spec §8, §13).
  def downloadable?
    file.attached?
  end
end
```

- [ ] **Step 8: Add the association on the configuration**

In `app/models/ranking_configuration.rb`, after `has_many :penalties, through: :penalty_applications, inverse_of: :ranking_configurations`, add:

```ruby
  has_one :csv_export, dependent: :destroy
```

- [ ] **Step 9: Run the tests to see them pass**

```bash
bin/rails test test/models/csv_export_test.rb test/models/ranking_configuration_test.rb
```

Expected: all pass, 0 failures.

- [ ] **Step 10: Commit**

```bash
bundle exec standardrb app/models/csv_export.rb app/models/ranking_configuration.rb test/models/csv_export_test.rb db/migrate/*_create_csv_exports.rb
git add db/migrate db/schema.rb app/models/csv_export.rb app/models/ranking_configuration.rb test/models/csv_export_test.rb test/fixtures/csv_exports.yml
git commit -m "Add CsvExport: one pre-built export row per ranking configuration" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Registry, limits, and the paywall key

**Files:**
- Create: `web-app/app/lib/csv_exports/registry.rb`
- Create: `web-app/app/lib/csv_exports/limits.rb`
- Modify: `web-app/app/lib/membership_gate.rb`
- Test: `web-app/test/lib/csv_exports/registry_test.rb`, `web-app/test/lib/csv_exports/limits_test.rb`, `web-app/test/lib/membership_gate_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/csv_exports/registry_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RegistryTest < ActiveSupport::TestCase
    test "the four ranking domains are exportable" do
      %i[books_global music_albums_global music_songs_global games_global].each do |name|
        assert Registry.exportable?(ranking_configurations(name)), "#{name} should be exportable"
      end
    end

    test "creator rankings and movies are not exportable" do
      %i[books_authors_global music_artists_global movies_global].each do |name|
        refute Registry.exportable?(ranking_configurations(name)), "#{name} should not be exportable"
        assert_nil Registry.for_config(ranking_configurations(name))
      end
    end

    test "an entry names its row class, slug and noun" do
      entry = Registry.for_config(ranking_configurations(:books_global))

      assert_equal "CsvExports::Books::RankedBookRow", entry.row_class_name
      assert_equal "books", entry.slug
      assert_equal "books", entry.noun
    end

    test "the unfiltered relation is the configuration's ranked items in rank order, unranked excluded" do
      config = ranking_configurations(:games_global)

      ids = Registry.for_config(config).relation.call(config).pluck(:item_id)

      assert_equal [
        games_games(:breath_of_the_wild).id,
        games_games(:resident_evil_4).id,
        games_games(:half_life_2).id,
        games_games(:tears_of_the_kingdom).id
      ], ids
    end

    test "the music relation excludes unranked items" do
      config = ranking_configurations(:music_songs_global)

      ids = Registry.for_config(config).relation.call(config).pluck(:item_id)

      assert_equal [music_songs(:time).id], ids
    end

    test "filenames carry the slug and the date" do
      assert_equal "the-greatest-books-rankings-2026-09-18.csv",
        Registry.filename_for(ranking_configurations(:books_global), date: Date.new(2026, 9, 18))
      assert_equal "user-books-ranking-books-2026-09-18.csv",
        Registry.filename_for(ranking_configurations(:books_user), date: Date.new(2026, 9, 18))
    end
  end
end
```

`test/lib/csv_exports/limits_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class LimitsTest < ActiveSupport::TestCase
    test "a member has no limit" do
      assert_nil Limits.limit_for(users(:regular_user))
    end

    test "a signed-in non-member gets the preview rows" do
      assert_equal 500, Limits.limit_for(users(:user_with_expired_membership))
    end

    test "no user gets the preview rows" do
      assert_equal 500, Limits.limit_for(nil)
    end
  end
end
```

Append to `test/lib/membership_gate_test.rb`, inside the class:

```ruby
  test "the full CSV export is registered as a paid feature" do
    assert MembershipGate.members_only?(:csv_export_full)
  end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/lib/csv_exports test/lib/membership_gate_test.rb
```

Expected: `NameError: uninitialized constant CsvExports::Registry` etc., and the gate assertion fails.

- [ ] **Step 3: Write the registry**

`app/lib/csv_exports/registry.rb`:

```ruby
# frozen_string_literal: true

# Everything the CSV export feature needs to know about a ranking domain, in
# one place (spec §7). A configuration type with no entry is not exportable:
# RequestGenerate returns :not_exportable, the nightly job skips it, the admin
# card does not render. That is what keeps the creator rankings (authors,
# artists) and movies out without a conditional anywhere else.
#
# Row classes are named as strings and constantized on use so this file loads
# before the row classes without a dependency cycle.
module CsvExports
  module Registry
    Entry = Struct.new(
      :ranking_configuration_class, # "Books::RankingConfiguration"
      :row_class_name,              # "CsvExports::Books::RankedBookRow"
      :slug,                        # filename token
      :noun,                        # "top 500 <noun>" in the modal
      :relation,                    # ->(config) { the full, unfiltered ranked relation in rank order }
      keyword_init: true
    ) do
      def row_class
        row_class_name.constantize
      end
    end

    # Music and games mirror their index actions' joins so the year filter
    # service (which addresses the media table by name) can be applied on top.
    # Unranked rows (rank NULL) are excluded everywhere: a rankings CSV with an
    # empty Rank cell is noise, and the books query already excludes them.
    ENTRIES = [
      Entry.new(
        ranking_configuration_class: "Books::RankingConfiguration",
        row_class_name: "CsvExports::Books::RankedBookRow",
        slug: "books",
        noun: "books",
        relation: ->(config) { ::Books::RankedBooksQuery.call(ranking_configuration: config) }
      ),
      Entry.new(
        ranking_configuration_class: "Music::Albums::RankingConfiguration",
        row_class_name: "CsvExports::Music::RankedAlbumRow",
        slug: "albums",
        noun: "albums",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN music_albums ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
            .where(item_type: "Music::Album").where.not(rank: nil).order(:rank)
        }
      ),
      Entry.new(
        ranking_configuration_class: "Music::Songs::RankingConfiguration",
        row_class_name: "CsvExports::Music::RankedSongRow",
        slug: "songs",
        noun: "songs",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN music_songs ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
            .where(item_type: "Music::Song").where.not(rank: nil).order(:rank)
        }
      ),
      Entry.new(
        ranking_configuration_class: "Games::RankingConfiguration",
        row_class_name: "CsvExports::Games::RankedGameRow",
        slug: "games",
        noun: "games",
        relation: ->(config) {
          config.ranked_items
            .joins("JOIN games_games ON ranked_items.item_id = games_games.id AND ranked_items.item_type = 'Games::Game'")
            .where(item_type: "Games::Game").where.not(rank: nil).order(:rank)
        }
      )
    ].freeze

    def self.for_config(config)
      ENTRIES.find { |entry| entry.ranking_configuration_class == config.type }
    end

    def self.exportable?(config)
      for_config(config).present?
    end

    # "the-greatest-books-rankings-2026-09-18.csv" for a global configuration;
    # a user-owned one is named after itself so two downloads are told apart.
    def self.filename_for(config, date: Date.current)
      entry = for_config(config)
      base = if config.global?
        "the-greatest-#{entry.slug}-rankings"
      else
        "#{config.name.parameterize.presence || "rankings"}-#{entry.slug}"
      end
      "#{base}-#{date.iso8601}.csv"
    end
  end
end
```

- [ ] **Step 4: Write the limits**

`app/lib/csv_exports/limits.rb`:

```ruby
# frozen_string_literal: true

# The membership gate is a cap, not a redirect (spec D7): a non-member gets a
# file, just a shorter one. nil means "no limit".
module CsvExports
  module Limits
    PREVIEW_ROWS = 500

    def self.limit_for(user)
      user&.member? ? nil : PREVIEW_ROWS
    end
  end
end
```

- [ ] **Step 5: Register the paywall key**

In `app/lib/membership_gate.rb`, extend `FEATURES`:

```ruby
  FEATURES = {
    members_area: "The members' area at /members",
    api: "The public API at /api/v1 (tokens managed at /developers/tokens)",
    csv_export_full: "Full CSV downloads of rankings and saved searches (non-members get the top 500 rows)"
  }.freeze
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
bin/rails test test/lib/csv_exports test/lib/membership_gate_test.rb
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb app/lib/csv_exports app/lib/membership_gate.rb test/lib/csv_exports test/lib/membership_gate_test.rb
git add app/lib/csv_exports app/lib/membership_gate.rb test/lib/csv_exports test/lib/membership_gate_test.rb
git commit -m "CsvExports: registry of exportable ranking types, row limits, paywall key" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `Writer` and `Aggregate`

**Files:**
- Create: `web-app/app/lib/csv_exports/writer.rb`, `web-app/app/lib/csv_exports/aggregate.rb`
- Test: `web-app/test/lib/csv_exports/writer_test.rb`, `web-app/test/lib/csv_exports/aggregate_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/csv_exports/writer_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class WriterTest < ActiveSupport::TestCase
    test "writes a BOM, the header and each row, counting rows" do
      io = StringIO.new
      writer = Writer.new(io, headers: ["Rank", "Title"])
      writer.row([1, "War and Peace"])
      writer.row([2, "Crime, and Punishment"])

      assert_equal 2, writer.rows
      assert_equal "\uFEFFRank,Title\n1,War and Peace\n2,\"Crime, and Punishment\"\n", io.string
    end

    test "a header-only export is still a valid file" do
      io = StringIO.new
      writer = Writer.new(io, headers: ["Rank"])

      assert_equal 0, writer.rows
      assert_equal "\uFEFFRank\n", io.string
    end
  end
end
```

`test/lib/csv_exports/aggregate_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class AggregateTest < ActiveSupport::TestCase
    test "joins names per owner in the requested order" do
      book = books_books(:war_and_peace)
      names = Aggregate.names(
        ::Books::BookCountry.joins(:country).where(book_id: [book.id]),
        group_by: "books_book_countries.book_id",
        name: "books_countries.name",
        order: "books_countries.name"
      )

      assert_equal({book.id => "French"}, names)
    end

    test "an owner with nothing to aggregate is simply absent" do
      names = Aggregate.names(
        ::Books::BookCountry.joins(:country).where(book_id: [-1]),
        group_by: "books_book_countries.book_id",
        name: "books_countries.name"
      )

      assert_equal({}, names)
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/lib/csv_exports/writer_test.rb test/lib/csv_exports/aggregate_test.rb
```

Expected: `NameError` for `Writer` and `Aggregate`.

- [ ] **Step 3: Write the writer**

`app/lib/csv_exports/writer.rb`:

```ruby
# frozen_string_literal: true

require "csv"

# Writes one CSV onto any IO: a UTF-8 BOM (so Excel opens accented titles
# correctly), the header line, then rows. Shared by every export path so the
# pre-built file and an on-demand response are byte-for-byte the same shape.
module CsvExports
  class Writer
    BOM = "\uFEFF"

    attr_reader :rows

    def initialize(io, headers:)
      @io = io
      @rows = 0
      @io.write(BOM)
      @io.write(CSV.generate_line(headers))
    end

    def row(values)
      @io.write(CSV.generate_line(values))
      @rows += 1
    end
  end
end
```

- [ ] **Step 4: Write the aggregate helper**

`app/lib/csv_exports/aggregate.rb`:

```ruby
# frozen_string_literal: true

# One grouped query per many-to-many column per batch (spec §10). Preloading
# authors, countries and categories for 21k books instantiates ~150k join
# records and took ~10 s; asking Postgres for `string_agg` per owner returns one
# short string per row instead.
#
# Returns {owner_id => "A, B"}; an owner with no rows is absent, so callers
# read with [] and get nil for an empty cell.
module CsvExports
  module Aggregate
    def self.names(relation, group_by:, name:, order: nil)
      order_sql = order ? " ORDER BY #{order}" : ""
      relation
        .group(Arel.sql(group_by))
        .pluck(Arel.sql(group_by), Arel.sql("string_agg(#{name}, ', '#{order_sql})"))
        .to_h
    end
  end
end
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
bin/rails test test/lib/csv_exports/writer_test.rb test/lib/csv_exports/aggregate_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/lib/csv_exports test/lib/csv_exports
git add app/lib/csv_exports test/lib/csv_exports
git commit -m "CsvExports: Writer (BOM + rows on an IO) and Aggregate (string_agg per owner)" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Books row class

**Files:**
- Create: `web-app/app/lib/csv_exports/books/ranked_book_row.rb`
- Test: `web-app/test/lib/csv_exports/books/ranked_book_row_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Books
    class RankedBookRowTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
        @book = books_books(:war_and_peace)
        @ranked = RankedItem.create!(item: @book, ranking_configuration: @config, rank: 1, score: 99.5)
      end

      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Authors", "Year", "Original Language", "Countries",
          "Genres", "Subjects", "Locations", "Page Range", "Word Count", "URL"], RankedBookRow::HEADERS
      end

      test "a row from a ranked item" do
        ctx = RankedBookRow.context([@book.id])

        assert_equal [
          1, "99.50", @book.id, "War and Peace", "Leo Tolstoy", 1869, "Russian", "French",
          "Classics, Novels", nil, nil, nil, nil,
          "#{Api::Host.base_url(:books)}/book/war-and-peace"
        ], RankedBookRow.row(@ranked, ctx)
      end

      test "a row for a hydrated book carries the rank and score it is given" do
        ctx = RankedBookRow.context([@book.id])

        row = RankedBookRow.row_for_book(@book, rank: 7, score: 12, ctx: ctx)

        assert_equal 7, row[0]
        assert_equal "12.00", row[1]
      end

      test "a soft-deleted category is left out" do
        # update_columns: Category's save callbacks enqueue search reindexing,
        # which is not what this test is about.
        categories(:books_classics_genre).update_columns(deleted: true)

        ctx = RankedBookRow.context([@book.id])

        assert_equal "Novels", RankedBookRow.row(@ranked, ctx)[8]
      end

      test "unranked scores and missing authors are blank cells" do
        # insert_all, as the controller tests seed books: no model callbacks.
        id = ::Books::Book.insert_all([{title: "Nobody Wrote This", slug: "nobody-wrote-this",
          created_at: Time.current, updated_at: Time.current}], returning: :id).rows.flatten.first
        book = ::Books::Book.find(id)
        ranked = RankedItem.create!(item: book, ranking_configuration: @config, rank: 2, score: nil)
        ctx = RankedBookRow.context([book.id])

        row = RankedBookRow.row(ranked, ctx)

        assert_nil row[1]
        assert_nil row[4]
      end

      test "preloads only the belongs_to columns the row reads" do
        assert_equal [:original_language], RankedBookRow.preloads
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/lib/csv_exports/books/ranked_book_row_test.rb
```

Expected: `NameError: uninitialized constant CsvExports::Books::RankedBookRow`.

- [ ] **Step 3: Write the row class**

`app/lib/csv_exports/books/ranked_book_row.rb`:

```ruby
# frozen_string_literal: true

# The books columns (spec §12). `context` runs once per batch of book ids and
# answers every many-to-many column from grouped queries; `row` is pure.
# `row_for_book` exists because the saved-search export hydrates books rather
# than ranked items and carries the rank on the book itself.
module CsvExports
  module Books
    class RankedBookRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Authors", "Year", "Original Language", "Countries",
        "Genres", "Subjects", "Locations", "Page Range", "Word Count", "URL"].freeze

      def self.preloads
        [:original_language]
      end

      def self.context(book_ids)
        categories = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: book_ids, categories: {deleted: false})
        types = ::Category.category_types

        {
          authors: Aggregate.names(::Books::BookAuthor.joins(:author).where(book_id: book_ids),
            group_by: "books_book_authors.book_id", name: "books_authors.name", order: "books_book_authors.position"),
          countries: Aggregate.names(::Books::BookCountry.joins(:country).where(book_id: book_ids),
            group_by: "books_book_countries.book_id", name: "books_countries.name", order: "books_countries.name"),
          genres: category_names(categories, types[:genre]),
          subjects: category_names(categories, types[:subject]),
          locations: category_names(categories, types[:location])
        }
      end

      def self.row(ranked_item, ctx)
        row_for_book(ranked_item.item, rank: ranked_item.rank, score: ranked_item.score, ctx: ctx)
      end

      def self.row_for_book(book, rank:, score:, ctx:)
        [
          rank,
          format_score(score),
          book.id,
          book.title,
          ctx[:authors][book.id],
          book.first_published_year,
          book.original_language&.name,
          ctx[:countries][book.id],
          ctx[:genres][book.id],
          ctx[:subjects][book.id],
          ctx[:locations][book.id],
          book.page_range,
          book.word_count,
          "#{Api::Host.base_url(:books)}#{URL_HELPERS.book_path(book)}"
        ]
      end

      def self.format_score(score)
        score.nil? ? nil : format("%.2f", score)
      end

      def self.category_names(scope, category_type)
        Aggregate.names(scope.where(categories: {category_type: category_type}),
          group_by: "category_items.item_id", name: "categories.name", order: "categories.name")
      end
      private_class_method :category_names
    end
  end
end
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bin/rails test test/lib/csv_exports/books/ranked_book_row_test.rb
```

Expected: all pass. If `book_path` raises `NoMethodError`, the route is named `book` inside the books host constraint (`get "book/:slug", as: :book` in `config/routes.rb`); confirm with `bin/rails routes -g "book/:slug"`.

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb app/lib/csv_exports/books test/lib/csv_exports/books
git add app/lib/csv_exports/books test/lib/csv_exports/books
git commit -m "CsvExports: books row class with grouped many-to-many columns" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Music and games row classes

**Files:**
- Create: `web-app/app/lib/csv_exports/music/ranked_album_row.rb`, `ranked_song_row.rb`, `web-app/app/lib/csv_exports/games/ranked_game_row.rb`
- Test: `web-app/test/lib/csv_exports/music/ranked_album_row_test.rb`, `ranked_song_row_test.rb`, `web-app/test/lib/csv_exports/games/ranked_game_row_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/csv_exports/music/ranked_album_row_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Music
    class RankedAlbumRowTest < ActiveSupport::TestCase
      setup do
        @album = music_albums(:dark_side_of_the_moon)
        @ranked = RankedItem.create!(item: @album, ranking_configuration: ranking_configurations(:music_albums_global),
          rank: 1, score: 100)
      end

      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Artists", "Year", "Genres", "URL"], RankedAlbumRow::HEADERS
      end

      test "a row" do
        ctx = RankedAlbumRow.context([@album.id])

        assert_equal [
          1, "100.00", @album.id, "The Dark Side of the Moon", "Pink Floyd", 1973, "Progressive Rock, Rock",
          "#{Api::Host.base_url(:music)}/album/the-dark-side-of-the-moon"
        ], RankedAlbumRow.row(@ranked, ctx)
      end

      test "no preloads beyond the item" do
        assert_equal [], RankedAlbumRow.preloads
      end
    end
  end
end
```

`test/lib/csv_exports/music/ranked_song_row_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Music
    class RankedSongRowTest < ActiveSupport::TestCase
      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Artists", "Year", "URL"], RankedSongRow::HEADERS
      end

      test "a row" do
        ranked = ranked_items(:music_songs_ranked_item)
        song = music_songs(:time)
        ctx = RankedSongRow.context([song.id])

        assert_equal [
          42, "95.50", song.id, "Time", "Pink Floyd", 1973,
          "#{Api::Host.base_url(:music)}/song/time"
        ], RankedSongRow.row(ranked, ctx)
      end
    end
  end
end
```

`test/lib/csv_exports/games/ranked_game_row_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  module Games
    class RankedGameRowTest < ActiveSupport::TestCase
      test "headers" do
        assert_equal ["Rank", "Score", "ID", "Title", "Year", "Platforms", "Companies", "Genres", "URL"],
          RankedGameRow::HEADERS
      end

      test "a row" do
        ranked = ranked_items(:games_ranked_botw)
        game = games_games(:breath_of_the_wild)
        ctx = RankedGameRow.context([game.id])

        row = RankedGameRow.row(ranked, ctx)

        assert_equal [1, "98.50", game.id, "The Legend of Zelda: Breath of the Wild", 2017], row[0..4]
        assert_equal "Nintendo Switch", row[5]
        assert_equal "Nintendo", row[6]
        assert_equal "#{Api::Host.base_url(:games)}/game/the-legend-of-zelda-breath-of-the-wild", row[8]
      end
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/lib/csv_exports/music test/lib/csv_exports/games
```

Expected: `NameError` for each row class.

- [ ] **Step 3: Write the album row**

`app/lib/csv_exports/music/ranked_album_row.rb`:

```ruby
# frozen_string_literal: true

module CsvExports
  module Music
    class RankedAlbumRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Artists", "Year", "Genres", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(album_ids)
        {
          artists: Aggregate.names(::Music::AlbumArtist.joins(:artist).where(album_id: album_ids),
            group_by: "music_album_artists.album_id", name: "music_artists.name", order: "music_album_artists.position"),
          genres: Aggregate.names(
            ::CategoryItem.joins(:category).where(item_type: "Music::Album", item_id: album_ids,
              categories: {deleted: false, category_type: ::Category.category_types[:genre]}),
            group_by: "category_items.item_id", name: "categories.name", order: "categories.name"
          )
        }
      end

      def self.row(ranked_item, ctx)
        album = ranked_item.item
        [
          ranked_item.rank,
          ranked_item.score.nil? ? nil : format("%.2f", ranked_item.score),
          album.id,
          album.title,
          ctx[:artists][album.id],
          album.release_year,
          ctx[:genres][album.id],
          "#{Api::Host.base_url(:music)}#{URL_HELPERS.album_path(album)}"
        ]
      end
    end
  end
end
```

- [ ] **Step 4: Write the song row**

`app/lib/csv_exports/music/ranked_song_row.rb`:

```ruby
# frozen_string_literal: true

module CsvExports
  module Music
    class RankedSongRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Artists", "Year", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(song_ids)
        {
          artists: Aggregate.names(::Music::SongArtist.joins(:artist).where(song_id: song_ids),
            group_by: "music_song_artists.song_id", name: "music_artists.name", order: "music_song_artists.position")
        }
      end

      def self.row(ranked_item, ctx)
        song = ranked_item.item
        [
          ranked_item.rank,
          ranked_item.score.nil? ? nil : format("%.2f", ranked_item.score),
          song.id,
          song.title,
          ctx[:artists][song.id],
          song.release_year,
          "#{Api::Host.base_url(:music)}#{URL_HELPERS.song_path(song)}"
        ]
      end
    end
  end
end
```

- [ ] **Step 5: Write the game row**

`app/lib/csv_exports/games/ranked_game_row.rb`:

```ruby
# frozen_string_literal: true

module CsvExports
  module Games
    class RankedGameRow
      URL_HELPERS = Rails.application.routes.url_helpers

      HEADERS = ["Rank", "Score", "ID", "Title", "Year", "Platforms", "Companies", "Genres", "URL"].freeze

      def self.preloads
        []
      end

      def self.context(game_ids)
        {
          platforms: Aggregate.names(::Games::GamePlatform.joins(:platform).where(game_id: game_ids),
            group_by: "games_game_platforms.game_id", name: "games_platforms.name", order: "games_platforms.name"),
          companies: Aggregate.names(::Games::GameCompany.joins(:company).where(game_id: game_ids),
            group_by: "games_game_companies.game_id", name: "games_companies.name", order: "games_companies.name"),
          genres: Aggregate.names(
            ::CategoryItem.joins(:category).where(item_type: "Games::Game", item_id: game_ids,
              categories: {deleted: false, category_type: ::Category.category_types[:genre]}),
            group_by: "category_items.item_id", name: "categories.name", order: "categories.name"
          )
        }
      end

      def self.row(ranked_item, ctx)
        game = ranked_item.item
        [
          ranked_item.rank,
          ranked_item.score.nil? ? nil : format("%.2f", ranked_item.score),
          game.id,
          game.title,
          game.release_year,
          ctx[:platforms][game.id],
          ctx[:companies][game.id],
          ctx[:genres][game.id],
          "#{Api::Host.base_url(:games)}#{URL_HELPERS.game_path(game)}"
        ]
      end
    end
  end
end
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
bin/rails test test/lib/csv_exports/music test/lib/csv_exports/games
```

Expected: all pass. If a `Games::GameCompany` join name differs, check `bin/rails runner 'puts Games::GameCompany.table_name'`.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb app/lib/csv_exports test/lib/csv_exports
git add app/lib/csv_exports/music app/lib/csv_exports/games test/lib/csv_exports/music test/lib/csv_exports/games
git commit -m "CsvExports: album, song and game row classes" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `CsvExports::RankedItems` and the timing check

**Files:**
- Create: `web-app/app/lib/csv_exports/ranked_items.rb`
- Test: `web-app/test/lib/csv_exports/ranked_items_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RankedItemsTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:games_global)
      @relation = Registry.for_config(@config).relation.call(@config)
      @row_class = Games::RankedGameRow
    end

    def export(limit:)
      io = StringIO.new
      rows = RankedItems.call(relation: @relation, row_class: @row_class, limit: limit, io: io)
      [rows, CSV.parse(io.string.delete_prefix(Writer::BOM))]
    end

    test "writes every ranked item in rank order with the header" do
      rows, parsed = export(limit: nil)

      assert_equal 4, rows
      assert_equal Games::RankedGameRow::HEADERS, parsed.first
      assert_equal %w[1 2 3 4], parsed.drop(1).map(&:first)
      assert_equal "The Legend of Zelda: Breath of the Wild", parsed[1][3]
    end

    test "the limit caps the rows written" do
      rows, parsed = export(limit: 2)

      assert_equal 2, rows
      assert_equal 3, parsed.size
    end

    test "rank order survives batching" do
      stub_const_batch(2) do
        _rows, parsed = export(limit: nil)
        assert_equal %w[1 2 3 4], parsed.drop(1).map(&:first)
      end
    end

    test "a ranked item whose item is gone is skipped, not raised" do
      RankedItem.where(item: games_games(:half_life_2)).delete_all
      RankedItem.insert_all([{item_type: "Games::Game", item_id: -1, ranking_configuration_id: @config.id,
                              rank: 3, score: 1, created_at: Time.current, updated_at: Time.current}])

      rows, parsed = export(limit: nil)

      assert_equal 3, rows
      assert_equal %w[1 2 4], parsed.drop(1).map(&:first)
    end

    test "the relation's own includes do not break the id pluck" do
      config = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: config, rank: 1, score: 1)
      io = StringIO.new

      rows = RankedItems.call(relation: Registry.for_config(config).relation.call(config),
        row_class: Books::RankedBookRow, limit: nil, io: io)

      assert_equal 1, rows
    end

    private

    def stub_const_batch(size)
      original = RankedItems::BATCH
      RankedItems.send(:remove_const, :BATCH)
      RankedItems.const_set(:BATCH, size)
      yield
    ensure
      RankedItems.send(:remove_const, :BATCH)
      RankedItems.const_set(:BATCH, original)
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/lib/csv_exports/ranked_items_test.rb
```

Expected: `NameError: uninitialized constant CsvExports::RankedItems`.

- [ ] **Step 3: Write it**

`app/lib/csv_exports/ranked_items.rb`:

```ruby
# frozen_string_literal: true

# Turns a ranked relation into CSV rows on an IO (spec §10). One path for the
# pre-built file (io is a Tempfile) and every on-demand export (io is a
# StringIO), so both are the same bytes for the same rows.
#
# Not `in_batches`: that walks by primary key and ignores the relation's rank
# order, so batches would come out in id order. Instead the ids are plucked
# once in rank order (a few tens of thousands of integers at most), then each
# slice is loaded and re-ordered to match the slice. Memory stays flat at one
# batch of records.
module CsvExports
  class RankedItems
    BATCH = 1000

    def self.call(relation:, row_class:, limit:, io:)
      writer = Writer.new(io, headers: row_class::HEADERS)

      ids = relation.unscope(:includes, :preload, :eager_load).limit(limit).pluck(:id)
      ids.each_slice(BATCH) do |slice|
        scope = ::RankedItem.where(id: slice)
        scope = row_class.preloads.empty? ? scope.preload(:item) : scope.preload(item: row_class.preloads)
        by_id = scope.index_by(&:id)

        items = slice.filter_map { |id| by_id[id] }.select(&:item)
        ctx = row_class.context(items.map(&:item_id))
        items.each { |ranked_item| writer.row(row_class.row(ranked_item, ctx)) }
      end

      writer.rows
    end
  end
end
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bin/rails test test/lib/csv_exports/ranked_items_test.rb
```

Expected: all pass.

- [ ] **Step 5: Time the full books export on the dev database**

```bash
bin/rails runner '
config = Books::RankingConfiguration.default_primary
entry = CsvExports::Registry.for_config(config)
io = StringIO.new
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
rows = CsvExports::RankedItems.call(relation: entry.relation.call(config), row_class: entry.row_class, limit: nil, io: io)
puts "rows=#{rows} seconds=#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)} mb=#{(io.string.bytesize / 1024.0 / 1024).round(2)}"
'
```

Expected: ~21,400 rows in **under 3 seconds** (the preload version measured 9.95 s; this is the spec §10 target). Record the number in the commit message. If it is over 3 s, look at the query log for the batch (`ActiveRecord::Base.logger = Logger.new($stdout)`) — the five queries per batch should each be a single grouped SELECT; a per-row query means a preload leaked in.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/lib/csv_exports/ranked_items.rb test/lib/csv_exports/ranked_items_test.rb
git add app/lib/csv_exports/ranked_items.rb test/lib/csv_exports/ranked_items_test.rb
# Put the row count and seconds measured in Step 5 in place of 21392 and 2.1 below.
git commit -m "CsvExports::RankedItems: rank-ordered batches onto an IO (full books export: 21392 rows in 2.1s)" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `Services::CsvExports::RequestGenerate`

**Files:**
- Create: `web-app/app/lib/services/csv_exports/request_generate.rb`
- Test: `web-app/test/lib/services/csv_exports/request_generate_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module CsvExports
    class RequestGenerateTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
      end

      test "creates the row, claims it and enqueues the job" do
        ::CsvExports::GenerateJob.expects(:perform_async).with { |id| id == ::CsvExport.last.id }.once

        result = RequestGenerate.call(ranking_configuration: @config)

        assert result.success?, result.errors.inspect
        export = @config.reload.csv_export
        assert export.generating?
        assert_in_delta Time.current, export.requested_at, 5.seconds
        assert_equal export, result.data[:csv_export]
      end

      test "reuses the existing row" do
        existing = ::CsvExport.create!(ranking_configuration: @config, status: :ready)
        ::CsvExports::GenerateJob.expects(:perform_async).with(existing.id).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
        assert_equal 1, ::CsvExport.where(ranking_configuration: @config).count
        assert existing.reload.generating?
      end

      test "a failed row is claimable" do
        ::CsvExport.create!(ranking_configuration: @config, status: :failed, error_message: "boom")
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
      end

      test "refuses while a fresh generation is running and enqueues nothing" do
        ::CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: 2.minutes.ago)
        ::CsvExports::GenerateJob.expects(:perform_async).never

        result = RequestGenerate.call(ranking_configuration: @config)

        refute result.success?
        assert_equal :already_generating, result.data[:reason]
      end

      test "reclaims a generation abandoned longer than the stale window" do
        ::CsvExport.create!(ranking_configuration: @config, status: :generating,
          requested_at: (::CsvExport::GENERATION_STALE_AFTER + 1.minute).ago)
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
      end

      test "only one of two back-to-back calls wins" do
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
        refute RequestGenerate.call(ranking_configuration: @config).success?
      end

      test "a non-exportable configuration is refused without creating a row" do
        ::CsvExports::GenerateJob.expects(:perform_async).never

        result = RequestGenerate.call(ranking_configuration: ranking_configurations(:books_authors_global))

        refute result.success?
        assert_equal :not_exportable, result.data[:reason]
        assert_equal 0, ::CsvExport.count
      end

      test "an enqueue failure releases the claim into failed with the reason" do
        ::CsvExports::GenerateJob.expects(:perform_async).raises(RedisClient::CannotConnectError, "redis is down")

        result = RequestGenerate.call(ranking_configuration: @config)

        refute result.success?
        assert_equal :enqueue_failed, result.data[:reason]
        export = @config.reload.csv_export
        assert export.failed?
        assert_includes export.error_message, "redis is down"
        assert export.claimable?
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/lib/services/csv_exports/request_generate_test.rb
```

Expected: `NameError: uninitialized constant Services::CsvExports`.

- [ ] **Step 3: Write the service**

`app/lib/services/csv_exports/request_generate.rb`:

```ruby
# frozen_string_literal: true

# Claims a configuration's CSV export row and enqueues the generate job
# (spec §8). Same shape as Services::RankingConfigurations::RequestRefresh:
# one conditional UPDATE is the claim, so two simultaneous callers -- three
# members clicking at once, or the nightly job racing a calculation -- produce
# one job. The stale clause reclaims a row wedged by a killed worker.
#
# The claim commits before the enqueue, so an unreachable Redis would leave
# the row `generating` for the whole stale window; an enqueue failure
# therefore releases it into `failed` with the reason.
#
# Model constants are root-anchored: inside Services::CsvExports a bare
# CsvExports resolves to this module.
module Services
  module CsvExports
    class RequestGenerate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      NOT_EXPORTABLE = "This ranking has no CSV export."
      ALREADY_GENERATING = "The export is already being generated."
      ENQUEUE_FAILED = "The export could not be queued. Try again in a moment."

      def self.call(ranking_configuration:)
        new(ranking_configuration: ranking_configuration).call
      end

      def initialize(ranking_configuration:)
        @config = ranking_configuration
      end

      def call
        return failure(nil, :not_exportable, NOT_EXPORTABLE) unless ::CsvExports::Registry.exportable?(config)

        export = find_or_create
        return failure(export, :already_generating, ALREADY_GENERATING) unless claim(export)

        begin
          ::CsvExports::GenerateJob.perform_async(export.id)
        rescue => error
          release(export, error)
          return failure(export, :enqueue_failed, ENQUEUE_FAILED)
        end

        Result.new(success?: true, data: {csv_export: export, reason: nil}, errors: [])
      end

      private

      attr_reader :config

      def statuses
        ::CsvExport.statuses
      end

      # Two callers can both miss the find; Rails' find_or_create_by! falls
      # through to create_or_find_by!, which rescues the unique-index violation
      # and returns the winner's row. That only holds because CsvExport has no
      # uniqueness validation (a validation would raise RecordInvalid instead).
      def find_or_create
        ::CsvExport.find_or_create_by!(ranking_configuration_id: config.id)
      end

      # CsvExport.claimable is the SQL twin of CsvExport#claimable?.
      def claim(export)
        claimed = ::CsvExport.claimable.where(id: export.id)
          .update_all(status: statuses[:generating], requested_at: Time.current)
        return false unless claimed == 1

        export.reload
        true
      end

      def release(export, error)
        Rails.logger.error "[Services::CsvExports::RequestGenerate] export #{export.id}: #{error.class}: #{error.message}"
        ::CsvExport.where(id: export.id).update_all(
          status: statuses[:failed],
          error_message: "Could not queue the export: #{error.message}".truncate(500)
        )
        export.reload
      end

      def failure(export, reason, message)
        Result.new(success?: false, data: {csv_export: export, reason: reason}, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bin/rails test test/lib/services/csv_exports/request_generate_test.rb
```

Expected: all pass. (`::CsvExports::GenerateJob` does not exist yet; Mocha's `expects` on an undefined constant raises `NameError` — if it does, add a temporary stub file `app/sidekiq/csv_exports/generate_job.rb` containing only `module CsvExports; class GenerateJob; include Sidekiq::Job; def perform(_id); end; end; end` and note that Task 9 replaces it.)

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb app/lib/services/csv_exports test/lib/services/csv_exports app/sidekiq/csv_exports
git add app/lib/services/csv_exports test/lib/services/csv_exports app/sidekiq/csv_exports
git commit -m "Services::CsvExports::RequestGenerate: atomic claim + enqueue" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `Services::CsvExports::Generate`

**Files:**
- Create: `web-app/app/lib/services/csv_exports/generate.rb`
- Test: `web-app/test/lib/services/csv_exports/generate_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module CsvExports
    class GenerateTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:games_global)
        @export = ::CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: Time.current,
          error_message: "old failure")
      end

      test "attaches the full unfiltered ranking and stamps the row ready" do
        result = Generate.call(csv_export: @export)

        assert result.success?, result.errors.inspect
        @export.reload
        assert @export.ready?
        assert @export.file.attached?
        assert_equal 4, @export.row_count
        assert_nil @export.error_message
        assert_in_delta Time.current, @export.generated_at, 5.seconds

        body = @export.file.download
        assert body.start_with?(::CsvExports::Writer::BOM)
        assert_equal @export.byte_size, body.bytesize
        parsed = CSV.parse(body.delete_prefix(::CsvExports::Writer::BOM))
        assert_equal ::CsvExports::Games::RankedGameRow::HEADERS, parsed.first
        assert_equal 5, parsed.size
        assert_equal "the-greatest-games-rankings-#{Date.current.iso8601}.csv", @export.file.filename.to_s
      end

      test "a failure marks the row failed with the message and keeps the previous file" do
        @export.file.attach(io: StringIO.new("\uFEFFold\n"), filename: "old.csv", content_type: "text/csv")
        ::CsvExports::RankedItems.stubs(:call).raises(StandardError, "opensearch exploded")

        result = Generate.call(csv_export: @export)

        refute result.success?
        assert_equal ["opensearch exploded"], result.errors
        @export.reload
        assert @export.failed?
        assert_equal "opensearch exploded", @export.error_message
        assert_equal "\uFEFFold\n", @export.file.download
      end

      test "a configuration that stopped being exportable fails cleanly" do
        @export.update_columns(ranking_configuration_id: ranking_configurations(:books_authors_global).id)

        # A fresh load: @export still holds games_global as its cached association target.
        result = Generate.call(csv_export: ::CsvExport.find(@export.id))

        refute result.success?
        assert @export.reload.failed?
      end
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/lib/services/csv_exports/generate_test.rb
```

Expected: `NameError: uninitialized constant Services::CsvExports::Generate`.

- [ ] **Step 3: Write the service**

`app/lib/services/csv_exports/generate.rb`:

```ruby
# frozen_string_literal: true

require "tempfile"

# Builds one configuration's full, unfiltered CSV and attaches it (spec §8).
# Runs under a `generating` claim taken by RequestGenerate. The previous
# attachment is only replaced by a successful attach, so a download during a
# failed regeneration still serves the last good file; on failure the row
# carries the message and stays claimable for the next trigger.
#
# Returns a Result rather than raising so the job decides what to raise;
# the job re-raises a failure so it lands in the Sidekiq log.
module Services
  module CsvExports
    class Generate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(csv_export:)
        new(csv_export: csv_export).call
      end

      def initialize(csv_export:)
        @export = csv_export
      end

      def call
        config = export.ranking_configuration
        entry = ::CsvExports::Registry.for_config(config)
        raise "#{config.type} is not exportable" if entry.nil?

        rows = nil
        Tempfile.create(["csv-export-#{export.id}-", ".csv"]) do |file|
          rows = ::CsvExports::RankedItems.call(relation: entry.relation.call(config), row_class: entry.row_class,
            limit: nil, io: file)
          file.flush
          file.rewind

          export.file.attach(io: file, filename: ::CsvExports::Registry.filename_for(config), content_type: "text/csv")
          export.update!(status: :ready, generated_at: Time.current, row_count: rows, byte_size: file.size,
            error_message: nil)
        end

        Result.new(success?: true, data: {csv_export: export, rows: rows}, errors: [])
      rescue => error
        Rails.logger.error "[Services::CsvExports::Generate] export #{export.id}: #{error.class}: #{error.message}"
        ::CsvExport.where(id: export.id).update_all(
          status: ::CsvExport.statuses[:failed],
          error_message: error.message.truncate(500)
        )
        export.reload
        Result.new(success?: false, data: {csv_export: export}, errors: [error.message])
      end

      private

      attr_reader :export
    end
  end
end
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bin/rails test test/lib/services/csv_exports/generate_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb app/lib/services/csv_exports/generate.rb test/lib/services/csv_exports/generate_test.rb
git add app/lib/services/csv_exports/generate.rb test/lib/services/csv_exports/generate_test.rb
git commit -m "Services::CsvExports::Generate: build the file, attach, stamp" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: The jobs and the nightly schedule

**Files:**
- Create: `web-app/app/sidekiq/csv_exports/generate_job.rb`, `web-app/app/sidekiq/csv_exports/refresh_global_job.rb` (generated)
- Modify: `web-app/config/schedule.yml`
- Test: `web-app/test/sidekiq/csv_exports/generate_job_test.rb`, `web-app/test/sidekiq/csv_exports/refresh_global_job_test.rb`

- [ ] **Step 1: Generate the jobs**

```bash
bin/rails generate sidekiq:job csv_exports/generate
bin/rails generate sidekiq:job csv_exports/refresh_global
```

(If Task 7 left a stub `generate_job.rb`, the generator asks to overwrite — answer yes.)

- [ ] **Step 2: Write the failing tests**

`test/sidekiq/csv_exports/generate_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class GenerateJobTest < ActiveSupport::TestCase
    setup do
      @export = ::CsvExport.create!(ranking_configuration: ranking_configurations(:games_global),
        status: :generating, requested_at: Time.current)
    end

    test "runs on the low queue and never retries" do
      assert_equal "low", GenerateJob.get_sidekiq_options["queue"].to_s
      assert_equal false, GenerateJob.get_sidekiq_options["retry"]
    end

    test "generates the export" do
      GenerateJob.new.perform(@export.id)

      assert @export.reload.ready?
      assert @export.file.attached?
    end

    test "raises when generation fails so the failure reaches the Sidekiq log" do
      Services::CsvExports::Generate.expects(:call).returns(
        Services::CsvExports::Generate::Result.new(success?: false, data: {}, errors: ["boom"])
      )

      error = assert_raises(RuntimeError) { GenerateJob.new.perform(@export.id) }

      assert_includes error.message, "boom"
    end

    test "is quiet about a row deleted while queued" do
      Services::CsvExports::Generate.expects(:call).never

      assert_nothing_raised { GenerateJob.new.perform(-1) }
    end
  end
end
```

`test/sidekiq/csv_exports/refresh_global_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RefreshGlobalJobTest < ActiveSupport::TestCase
    test "runs on the low queue" do
      assert_equal "low", RefreshGlobalJob.get_sidekiq_options["queue"].to_s
    end

    # The real RequestGenerate runs (it creates one CsvExport row per
    # configuration it claims), and only the job enqueue is stubbed -- so the
    # set of rows afterwards IS the set of configurations that were requested.
    test "requests a generate for every active global exportable configuration and nothing else" do
      ranking_configurations(:games_secondary).update_columns(archived: true)
      GenerateJob.stubs(:perform_async)

      RefreshGlobalJob.new.perform

      requested = ::CsvExport.pluck(:ranking_configuration_id)
      expected = RankingConfiguration.global.active.select { |config| Registry.exportable?(config) }.map(&:id)
      assert_equal expected.sort, requested.sort
      refute_includes requested, ranking_configurations(:books_user).id, "user-owned configurations are skipped"
      refute_includes requested, ranking_configurations(:games_secondary).id, "archived configurations are skipped"
      refute_includes requested, ranking_configurations(:books_authors_global).id, "non-exportable types are skipped"
    end

    test "is scheduled nightly" do
      schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))

      assert_equal "CsvExports::RefreshGlobalJob", schedule.dig("csv_exports_refresh_global", "class")
      assert_equal "30 4 * * *", schedule.dig("csv_exports_refresh_global", "cron")
    end
  end
end
```

- [ ] **Step 3: Run them to see them fail**

```bash
bin/rails test test/sidekiq/csv_exports
```

Expected: queue/retry assertions fail (generated jobs have no options), `perform` does nothing, the schedule key is missing.

- [ ] **Step 4: Write the generate job**

`app/sidekiq/csv_exports/generate_job.rb`:

```ruby
# frozen_string_literal: true

# Generates one configuration's pre-built CSV. `retry: false` because the row
# carries the outcome (spec §8): a silent Sidekiq retry would run while the
# admin card still said "failed", and every trigger (calculation, nightly,
# download, admin button) re-claims a failed row anyway.
module CsvExports
  class GenerateJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(csv_export_id)
      export = ::CsvExport.find_by(id: csv_export_id)
      return if export.nil? # deleted while queued -- not a failure

      result = Services::CsvExports::Generate.call(csv_export: export)
      raise "CSV export #{csv_export_id} failed: #{result.errors.join(", ")}" unless result.success?
    end
  end
end
```

- [ ] **Step 5: Write the nightly job**

`app/sidekiq/csv_exports/refresh_global_job.rb`:

```ruby
# frozen_string_literal: true

# Nightly reconciliation (spec D5): title fixes, author merges and category
# edits change a file's contents without any ranking calculation, and nothing
# cheap detects that at download time. Global configurations only -- a
# user-owned one regenerates on its owner's refresh.
module CsvExports
  class RefreshGlobalJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform
      ::RankingConfiguration.global.active.find_each do |config|
        next unless Registry.exportable?(config)

        Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
      end
    end
  end
end
```

- [ ] **Step 6: Schedule it**

Append to `config/schedule.yml`:

```yaml

csv_exports_refresh_global:
  class: CsvExports::RefreshGlobalJob
  cron: "30 4 * * *"
  description: "Regenerate the pre-built CSV export of every global ranking configuration"
```

- [ ] **Step 7: Run the tests to see them pass**

```bash
bin/rails test test/sidekiq/csv_exports
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
bundle exec standardrb app/sidekiq/csv_exports test/sidekiq/csv_exports
git add app/sidekiq/csv_exports test/sidekiq/csv_exports config/schedule.yml
git commit -m "CsvExports jobs: GenerateJob (low, no retry) and nightly RefreshGlobalJob" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Regenerate after every successful calculation

**Files:**
- Modify: `web-app/app/sidekiq/calculate_rankings_job.rb`
- Modify: `web-app/app/sidekiq/ranking_configurations/refresh_job.rb`
- Test: `web-app/test/sidekiq/calculate_rankings_job_test.rb`, `web-app/test/sidekiq/ranking_configurations/refresh_job_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/sidekiq/calculate_rankings_job_test.rb`, inside the class:

```ruby
  test "requests a CSV export regenerate after a successful calculation" do
    RankingConfiguration.any_instance.stubs(:calculate_rankings).returns(
      ItemRankings::Calculator::Result.new(success?: true, data: [], errors: [])
    )
    Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @ranking_configuration).once

    CalculateRankingsJob.new.perform(@ranking_configuration.id)
  end

  test "does not request a CSV export regenerate after a failed calculation" do
    RankingConfiguration.any_instance.stubs(:calculate_rankings).returns(
      ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["nope"])
    )
    Services::CsvExports::RequestGenerate.expects(:call).never

    assert_raises(StandardError) { CalculateRankingsJob.new.perform(@ranking_configuration.id) }
  end
```

Append to `test/sidekiq/ranking_configurations/refresh_job_test.rb`, inside the class:

```ruby
    test "requests a CSV export regenerate after a successful run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(@success)
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @config).once

      RefreshJob.new.perform(@config.id)
    end

    test "does not request a CSV export regenerate after a failed run" do
      Rankings::BulkWeightCalculator.any_instance.expects(:call).returns(@clean_weights)
      RankingConfiguration.any_instance.expects(:calculate_rankings).returns(
        ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["nope"])
      )
      Services::CsvExports::RequestGenerate.expects(:call).never

      RefreshJob.new.perform(@config.id)
    end
```

Existing tests in both files stub `calculate_rankings` on success paths without expecting `RequestGenerate`; with Sidekiq inline, the real `RequestGenerate` would now enqueue and run `Generate` inside those tests. Add this line inside each file's existing setup (`def setup` in the CalculateRankingsJob test, `setup do` in the RefreshJob test):

```ruby
    Services::CsvExports::RequestGenerate.stubs(:call).returns(
      Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: [])
    )
```

(Mocha lets a later `expects` in a test override the setup stub.)

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/sidekiq/calculate_rankings_job_test.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
```

Expected: the two `.once` expectations fail (never invoked).

- [ ] **Step 3: Hook `CalculateRankingsJob`**

In `app/sidekiq/calculate_rankings_job.rb`, inside `if result.success?`, after the `Books::ReindexRankedFieldsJob` block (still inside the success branch):

```ruby
      # The pre-built CSV must never be behind the ranks it describes (spec D4).
      # RequestGenerate is a no-op for a type with no export.
      Services::CsvExports::RequestGenerate.call(ranking_configuration: ranking_configuration)
```

- [ ] **Step 4: Hook `RankingConfigurations::RefreshJob`**

In `app/sidekiq/ranking_configurations/refresh_job.rb`, after the final `config.update_columns(refresh_status: ... idle ...)` and before `rescue`:

```ruby
      Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
bin/rails test test/sidekiq/calculate_rankings_job_test.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/sidekiq/calculate_rankings_job.rb app/sidekiq/ranking_configurations/refresh_job.rb test/sidekiq/calculate_rankings_job_test.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
git add app/sidekiq/calculate_rankings_job.rb app/sidekiq/ranking_configurations/refresh_job.rb test/sidekiq/calculate_rankings_job_test.rb test/sidekiq/ranking_configurations/refresh_job_test.rb
git commit -m "Regenerate the CSV export after every successful ranking calculation" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: `CsvExportable` concern and the preparing page

**Files:**
- Create: `web-app/app/controllers/concerns/csv_exportable.rb`
- Create: `web-app/app/views/csv_exports/preparing.html.erb`

No test of its own — the concern is exercised by every export action's controller tests (Tasks 12–15).

- [ ] **Step 1: Write the concern**

`app/controllers/concerns/csv_exportable.rb`:

```ruby
# frozen_string_literal: true

# The shared skeleton of every CSV export action (spec §9). Included by a
# controller that defines `export`; never by an action that is edge-cached.
#
#   include CsvExportable
#   def export ... send_on_demand_ranked_items(...) / serve_prebuilt_or_prepare(...)
#
# Filters run in declaration order: prevent_caching and require_signed_in!
# come from this concern's `included` block, so they run before the
# controller's own before_actions (which load and gate the configuration).
# rate_limit is declared after require_signed_in! so an anonymous caller is
# turned away before `by:` runs, otherwise every anonymous request would share
# one nil bucket.
module CsvExportable
  extend ActiveSupport::Concern

  REFRESH_SECONDS = 15

  included do
    before_action :prevent_caching, only: [:export]
    before_action :require_signed_in!, only: [:export]
    rate_limit to: 20, within: 1.hour,
      by: -> { current_user&.id },
      with: -> { head :too_many_requests },
      store: Rails.application.config.x.rate_limit_store,
      only: [:export]
  end

  private

  def export_limit
    ::CsvExports::Limits.limit_for(current_user)
  end

  def send_csv(data, filename:)
    response.headers["X-Robots-Tag"] = "noindex"
    send_data data, type: "text/csv; charset=utf-8", filename: filename, disposition: "attachment"
  end

  # The member + unfiltered case: serve the pre-built file (any attached file
  # is a good one -- Generate attaches only on success -- so this holds during
  # a regeneration and after a failed one), or claim a generate and show the
  # preparing page. The HTTP Refresh header re-requests
  # this URL; once the file exists the response is an attachment and the
  # browser downloads it without leaving the page. Not a flash: the cached
  # rankings page skips the session, so a flash set here would never render.
  def serve_prebuilt_or_prepare(ranking_configuration)
    export = ranking_configuration.csv_export
    if export&.downloadable?
      send_csv export.file.download, filename: export.file.filename.to_s
    else
      Services::CsvExports::RequestGenerate.call(ranking_configuration: ranking_configuration)
      response.headers["Refresh"] = REFRESH_SECONDS.to_s
      render "csv_exports/preparing", status: :accepted, formats: [:html], content_type: "text/html"
    end
  end

  def send_on_demand_ranked_items(relation, row_class:, filename:)
    io = StringIO.new
    ::CsvExports::RankedItems.call(relation: relation, row_class: row_class, limit: export_limit, io: io)
    send_csv io.string, filename: filename
  end
end
```

- [ ] **Step 2: Write the preparing view**

`app/views/csv_exports/preparing.html.erb`:

```erb
<% content_for :page_title, "Preparing your export" %>

<div class="max-w-xl mx-auto py-16 space-y-6 text-center" data-testid="csv-export-preparing">
  <h1 class="text-2xl font-bold">Preparing your export</h1>

  <div role="alert" class="alert alert-info alert-soft alert-vertical sm:alert-horizontal">
    <span class="loading loading-spinner loading-md" aria-hidden="true"></span>
    <span>
      The full ranking is being generated. This page checks again every
      <%= CsvExportable::REFRESH_SECONDS %> seconds and the download starts as soon as the file is ready.
    </span>
  </div>

  <p class="text-sm text-base-content/70">
    <%= link_to "Back to the rankings", :back, class: "link" %>
  </p>
</div>
```

- [ ] **Step 3: Boot check**

```bash
bin/rails runner 'puts CsvExportable::REFRESH_SECONDS'
```

Expected: `15`.

- [ ] **Step 4: Commit**

```bash
bundle exec standardrb app/controllers/concerns/csv_exportable.rb
git add app/controllers/concerns/csv_exportable.rb app/views/csv_exports/preparing.html.erb
git commit -m "CsvExportable: shared export-action skeleton and the preparing page" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Books export action

**Files:**
- Modify: `web-app/config/routes.rb` (books root region, around line 868)
- Modify: `web-app/app/controllers/books/ranked_items_controller.rb`
- Test: `web-app/test/controllers/books/ranked_items_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `Books::RankedItemsControllerTest` (before the `private` helpers):

```ruby
    # --- CSV export (spec §9) ---

    BOM = "\uFEFF"

    def parsed_csv
      CSV.parse(response.body.delete_prefix(BOM))
    end

    def generate_ok
      Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: [])
    end

    test "export requires sign-in" do
      get "/export.csv"

      assert_redirected_to "/"
    end

    test "export without the csv format is not routable" do
      get "/export"

      assert_response :not_found
    end

    test "a non-member gets the top 500 rows on demand, uncached" do
      seed_ranked_books(600)
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      get "/export.csv"

      assert_response :success
      assert_includes response.media_type, "text/csv"
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_equal "noindex", response.headers["X-Robots-Tag"]
      assert_includes response.headers["Content-Disposition"], "the-greatest-books-rankings-#{Date.current.iso8601}.csv"
      assert response.body.start_with?(BOM)
      rows = parsed_csv
      assert_equal CsvExports::Books::RankedBookRow::HEADERS, rows.first
      assert_equal 500, rows.size - 1
      assert_equal "War and Peace", rows[1][3]
    end

    test "a member's unfiltered export is served from the pre-built file" do
      export = CsvExport.create!(ranking_configuration: @rc, status: :ready, generated_at: Time.current)
      export.file.attach(io: StringIO.new("\uFEFFRank,Title\n1,Prebuilt\n"),
        filename: "the-greatest-books-rankings-2026-09-18.csv", content_type: "text/csv")
      Services::CsvExports::RequestGenerate.expects(:call).never
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv"

      assert_response :success
      assert_equal "\uFEFFRank,Title\n1,Prebuilt\n", response.body
      assert_includes response.headers["Content-Disposition"], "the-greatest-books-rankings-2026-09-18.csv"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "a member's unfiltered export with no file requests one and shows the preparing page" do
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @rc).once.returns(generate_ok)
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv"

      assert_response :accepted
      assert_equal "text/html", response.media_type
      assert_equal "15", response.headers["Refresh"]
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_select "[data-testid=csv-export-preparing]"
    end

    # Both fixture books carry the novels category; the 600 filler books carry
    # none, so the filter is what keeps them out of a member's uncapped export.
    test "a member's filtered export is generated on demand without a cap" do
      seed_ranked_books(600)
      Services::CsvExports::RequestGenerate.expects(:call).never
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?category_id=novels"

      assert_response :success
      rows = parsed_csv
      assert_equal ["War and Peace", "Crime and Punishment"], rows.drop(1).map { |row| row[3] }
    end

    test "every filter the page accepts applies to the export" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?country_id=french&published_start=1800&published_end=1900"

      assert_response :success
      assert_equal ["War and Peace"], parsed_csv.drop(1).map { |row| row[3] }
    end

    test "a collection filter applies to the export" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?collection=#{Collections::Registry.slugs(:books).first}"

      assert_response :success
      assert_includes response.media_type, "text/csv"
    end

    test "an unknown collection 404s" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?collection=nope"

      assert_response :not_found
    end

    test "an explicit ranking configuration exports its own ranks" do
      other = ranking_configurations(:books_inherited)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: other, rank: 1, score: 1)
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      get "/rc/#{other.id}/export.csv"

      assert_response :success
      assert_equal ["Crime and Punishment"], parsed_csv.drop(1).map { |row| row[3] }
    end

    test "a private user-owned configuration's export 404s for a non-owner" do
      sign_in_as users(:editor_user), stub_auth: true

      get "/rc/#{ranking_configurations(:books_user).id}/export.csv"

      assert_response :not_found
    end

    test "the export is rate limited per user" do
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      20.times { get "/export.csv" }
      assert_response :success

      get "/export.csv"
      assert_response :too_many_requests
    end

    # Rails appends an optional (.:format) to every route, so /.csv does reach
    # the cached index action -- and must come back as an error (406, no
    # template for csv), never as a CSV body carrying public cache headers.
    test "the cached index never answers with a csv body" do
      get "/.csv"
      refute_equal 200, response.status
      refute_equal "text/csv", response.media_type

      get "/index.csv"
      assert_response :not_found
    end

    test "the index carries the export link with the current filters" do
      get "/the-greatest/novels/books"

      assert_response :success
      assert_equal "/export.csv?category_id=novels", @controller.view_assigns["csv_export_path"]
    end

    test "the index on a configuration carries an rc export link" do
      get "/rc/#{@rc.id}"

      assert_equal "/rc/#{@rc.id}/export.csv", @controller.view_assigns["csv_export_path"]
    end
```

Add `require "csv"` at the top of the test file if it is not already there.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/controllers/books/ranked_items_controller_test.rb
```

Expected: the new tests fail (404s, nil `csv_export_path`).

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, directly after `root to: "books/ranked_items#index", as: :books_root` (books section):

```ruby
    # CSV export (spec §9). Its own action, never a format of the cached
    # index; `.csv` is required by the format constraint so /export alone 404s.
    get "export", to: "books/ranked_items#export", as: :books_export, constraints: {format: /csv/}
    get "rc/:ranking_configuration_id/export", to: "books/ranked_items#export", as: :books_rc_export,
      constraints: {format: /csv/}
```

- [ ] **Step 4: Add the action**

In `app/controllers/books/ranked_items_controller.rb`:

Add `include CsvExportable` after `include PathBasedPagination`.

At the end of `index`, after `@indexable = ...`:

```ruby
    @csv_export_path = csv_export_path
```

Add the action and helpers (before `private`, and inside `private` respectively):

```ruby
  # GET (/rc/:ranking_configuration_id)/export.csv
  #
  # Filters arrive as query params and are parsed by the same FilterParams the
  # page uses, so the relation is identical by construction. `collection` is a
  # query param here, unlike index (see find_collection): this endpoint is
  # uncached, nofollow and sign-in only, so the soft-duplicate-URL concern
  # that keeps ?collection= off the index does not apply.
  def export
    filters = Books::FilterParams.call(params)
    collection = export_collection
    unfiltered = filters.categories.empty? && filters.countries.empty? &&
      filters.year_start.blank? && filters.year_end.blank? && collection.nil?

    return serve_prebuilt_or_prepare(@ranking_configuration) if unfiltered && current_user.member?

    relation = Books::RankedBooksQuery.call(
      ranking_configuration: @ranking_configuration,
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end,
      collection: collection
    )
    send_on_demand_ranked_items(relation, row_class: CsvExports::Books::RankedBookRow,
      filename: CsvExports::Registry.filename_for(@ranking_configuration))
  end
```

```ruby
  def export_collection
    slug = params[:collection]
    return nil if slug.blank?

    Collections::Registry.find(:books, slug) || raise(ActiveRecord::RecordNotFound)
  end

  # The export link for the page being rendered: the same filters, as query
  # params, on the export route that matches the configuration in the URL.
  def csv_export_path
    filter_params = {
      category_id: @categories.map(&:slug).join(",").presence,
      country_id: @countries.map(&:slug).join(",").presence,
      published_start: @year_start.presence,
      published_end: @year_end.presence,
      collection: @collection&.slug
    }.compact

    if params[:ranking_configuration_id].present?
      books_rc_export_path(ranking_configuration_id: @ranking_configuration.id, format: :csv, **filter_params)
    else
      books_export_path(format: :csv, **filter_params)
    end
  end
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
bin/rails test test/controllers/books/ranked_items_controller_test.rb
```

Expected: all pass, including the pre-existing ones. If "the index carries the export link" fails on param order, compare `@controller.view_assigns["csv_export_path"]` to `books_export_path(format: :csv, category_id: "novels")` instead of a literal.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/controllers/books/ranked_items_controller.rb test/controllers/books/ranked_items_controller_test.rb config/routes.rb
git add config/routes.rb app/controllers/books/ranked_items_controller.rb test/controllers/books/ranked_items_controller_test.rb
git commit -m "Books rankings: /export.csv with filters, cap, pre-built member file" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Music albums and songs export actions

**Files:**
- Modify: `web-app/config/routes.rb` (music rc scope, after `albums/page/:page` and `songs/page/:page`)
- Modify: `web-app/app/controllers/music/albums/ranked_items_controller.rb`, `web-app/app/controllers/music/songs/ranked_items_controller.rb`
- Test: `web-app/test/controllers/music/albums/ranked_items_controller_test.rb`, `web-app/test/controllers/music/songs/ranked_items_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside the albums test class:

```ruby
      # --- CSV export (spec §9) ---

      test "export requires sign-in" do
        get "/albums/export.csv"

        assert_redirected_to "/"
      end

      test "a non-member exports the ranked albums on demand" do
        RankedItem.create!(item: music_albums(:dark_side_of_the_moon),
          ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 100)
        sign_in_as users(:user_with_expired_membership), stub_auth: true

        get "/albums/export.csv"

        assert_response :success
        assert_includes response.media_type, "text/csv"
        assert_match "no-store", response.headers["Cache-Control"].to_s
        rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
        assert_equal CsvExports::Music::RankedAlbumRow::HEADERS, rows.first
        assert_equal ["The Dark Side of the Moon"], rows.drop(1).map { |row| row[3] }
      end

      test "a year filter applies to the export" do
        RankedItem.create!(item: music_albums(:dark_side_of_the_moon),
          ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 100)
        sign_in_as users(:regular_user), stub_auth: true

        get "/albums/export.csv?year=1990&year_mode=since"

        assert_response :success
        assert_equal 1, CSV.parse(response.body.delete_prefix("\uFEFF")).size
      end

      test "a member's unfiltered export with no file shows the preparing page" do
        Services::CsvExports::RequestGenerate.expects(:call)
          .with(ranking_configuration: ranking_configurations(:music_albums_global)).once
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))
        sign_in_as users(:regular_user), stub_auth: true

        get "/albums/export.csv"

        assert_response :accepted
        assert_equal "15", response.headers["Refresh"]
      end

      test "the index carries the export link" do
        get "/albums/since/1980"

        assert_equal "/albums/export.csv?year=1980&year_mode=since", @controller.view_assigns["csv_export_path"]
      end
```

Append inside the songs test class:

```ruby
      # --- CSV export (spec §9) ---

      test "a non-member exports the ranked songs on demand" do
        sign_in_as users(:user_with_expired_membership), stub_auth: true

        get "/songs/export.csv"

        assert_response :success
        assert_includes response.media_type, "text/csv"
        rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
        assert_equal CsvExports::Music::RankedSongRow::HEADERS, rows.first
        assert_equal ["Time"], rows.drop(1).map { |row| row[3] }
      end

      test "a member's filtered export is on demand" do
        Services::CsvExports::RequestGenerate.expects(:call).never
        sign_in_as users(:regular_user), stub_auth: true

        get "/songs/export.csv?year=1973"

        assert_response :success
        assert_equal ["Time"], CSV.parse(response.body.delete_prefix("\uFEFF")).drop(1).map { |row| row[3] }
      end

      test "the index carries the export link" do
        get "/songs"

        assert_equal "/songs/export.csv", @controller.view_assigns["csv_export_path"]
      end
```

Add `require "csv"` at the top of both test files.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/controllers/music/albums/ranked_items_controller_test.rb test/controllers/music/songs/ranked_items_controller_test.rb
```

Expected: new tests fail (404 / nil ivar).

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, in the music `scope "(/rc/:ranking_configuration_id)"` block, directly after `get "albums/page/:page", ...`:

```ruby
      get "albums/export", to: "music/albums/ranked_items#export", as: :albums_export, constraints: {format: /csv/}
```

and directly after `get "songs/page/:page", ...`:

```ruby
      get "songs/export", to: "music/songs/ranked_items#export", as: :songs_export, constraints: {format: /csv/}
```

(Both sit before the `albums/:year` / `songs/:year` routes, whose `\d{4}` constraint would not capture "export" anyway.)

- [ ] **Step 4: Add the albums action**

In `app/controllers/music/albums/ranked_items_controller.rb`: add `include CsvExportable` after `include PathBasedPagination`; at the end of `index` add `@csv_export_path = csv_export_path`; add:

```ruby
  # GET (/rc/:ranking_configuration_id)/albums/export.csv?year=&year_mode=
  def export
    return serve_prebuilt_or_prepare(@ranking_configuration) if @year_filter.nil? && current_user.member?

    entry = CsvExports::Registry.for_config(@ranking_configuration)
    relation = entry.relation.call(@ranking_configuration)
    if @year_filter
      relation = Services::RankedItemsFilterService.new(relation, table_name: "music_albums").apply_year_filter(@year_filter)
    end
    send_on_demand_ranked_items(relation, row_class: entry.row_class,
      filename: CsvExports::Registry.filename_for(@ranking_configuration))
  end

  private

  def csv_export_path
    albums_export_path(
      **{ranking_configuration_id: params[:ranking_configuration_id].presence,
         year: params[:year].presence, year_mode: params[:year_mode].presence}.compact,
      format: :csv
    )
  end
```

- [ ] **Step 5: Add the songs action**

Same shape in `app/controllers/music/songs/ranked_items_controller.rb`, with `table_name: "music_songs"` and `songs_export_path`:

```ruby
  # GET (/rc/:ranking_configuration_id)/songs/export.csv?year=&year_mode=
  def export
    return serve_prebuilt_or_prepare(@ranking_configuration) if @year_filter.nil? && current_user.member?

    entry = CsvExports::Registry.for_config(@ranking_configuration)
    relation = entry.relation.call(@ranking_configuration)
    if @year_filter
      relation = Services::RankedItemsFilterService.new(relation, table_name: "music_songs").apply_year_filter(@year_filter)
    end
    send_on_demand_ranked_items(relation, row_class: entry.row_class,
      filename: CsvExports::Registry.filename_for(@ranking_configuration))
  end

  private

  def csv_export_path
    songs_export_path(
      **{ranking_configuration_id: params[:ranking_configuration_id].presence,
         year: params[:year].presence, year_mode: params[:year_mode].presence}.compact,
      format: :csv
    )
  end
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
bin/rails test test/controllers/music/albums/ranked_items_controller_test.rb test/controllers/music/songs/ranked_items_controller_test.rb
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb app/controllers/music test/controllers/music config/routes.rb
git add config/routes.rb app/controllers/music/albums/ranked_items_controller.rb app/controllers/music/songs/ranked_items_controller.rb test/controllers/music/albums/ranked_items_controller_test.rb test/controllers/music/songs/ranked_items_controller_test.rb
git commit -m "Music rankings: albums and songs /export.csv" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Games export action

**Files:**
- Modify: `web-app/config/routes.rb` (games rc scope, after `video-games/page/:page`)
- Modify: `web-app/app/controllers/games/ranked_items_controller.rb`
- Test: `web-app/test/controllers/games/ranked_items_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside the games test class (add `require "csv"` at the top of the file):

```ruby
      # --- CSV export (spec §9) ---

      test "export requires sign-in" do
        get "/video-games/export.csv"

        assert_redirected_to "/"
      end

      test "a non-member exports the ranked games on demand in rank order" do
        sign_in_as users(:user_with_expired_membership), stub_auth: true

        get "/video-games/export.csv"

        assert_response :success
        assert_includes response.media_type, "text/csv"
        rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
        assert_equal CsvExports::Games::RankedGameRow::HEADERS, rows.first
        assert_equal %w[1 2 3 4], rows.drop(1).map(&:first)
      end

      test "a since-year filter applies to the export" do
        sign_in_as users(:regular_user), stub_auth: true

        get "/video-games/export.csv?year=2017&year_mode=since"

        assert_response :success
        titles = CSV.parse(response.body.delete_prefix("\uFEFF")).drop(1).map { |row| row[3] }
        assert_includes titles, "The Legend of Zelda: Breath of the Wild"
        refute_includes titles, "Half-Life 2"
      end

      test "a member's unfiltered export with a ready file downloads it" do
        export = CsvExport.create!(ranking_configuration: ranking_configurations(:games_global), status: :ready,
          generated_at: Time.current)
        export.file.attach(io: StringIO.new("\uFEFFRank\n1\n"), filename: "the-greatest-games-rankings-2026-09-18.csv",
          content_type: "text/csv")
        sign_in_as users(:regular_user), stub_auth: true

        get "/video-games/export.csv"

        assert_response :success
        assert_equal "\uFEFFRank\n1\n", response.body
      end

      test "the index carries the export link" do
        get "/video-games/since/2017"

        assert_equal "/video-games/export.csv?year=2017&year_mode=since", @controller.view_assigns["csv_export_path"]
      end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/controllers/games/ranked_items_controller_test.rb
```

Expected: the new tests fail.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, in the games `scope "(/rc/:ranking_configuration_id)"` block, directly after `get "video-games/page/:page", ...`:

```ruby
      get "video-games/export", to: "games/ranked_items#export", as: :video_games_export, constraints: {format: /csv/}
```

- [ ] **Step 4: Add the action**

In `app/controllers/games/ranked_items_controller.rb`: add `include CsvExportable` after `include PathBasedPagination`; in `index`, after `@pagy, @games = ...`, add `@csv_export_path = csv_export_path`; add the action before `private` and the helper inside `private`:

```ruby
  # GET (/rc/:ranking_configuration_id)/video-games/export.csv?year=&year_mode=
  def export
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil? # no primary yet: index shows "coming soon"
    return serve_prebuilt_or_prepare(@ranking_configuration) if @year_filter.nil? && current_user.member?

    entry = CsvExports::Registry.for_config(@ranking_configuration)
    relation = entry.relation.call(@ranking_configuration)
    if @year_filter
      relation = Services::RankedItemsFilterService.new(relation, table_name: "games_games").apply_year_filter(@year_filter)
    end
    send_on_demand_ranked_items(relation, row_class: entry.row_class,
      filename: CsvExports::Registry.filename_for(@ranking_configuration))
  end
```

```ruby
  def csv_export_path
    video_games_export_path(
      **{ranking_configuration_id: params[:ranking_configuration_id].presence,
         year: params[:year].presence, year_mode: params[:year_mode].presence}.compact,
      format: :csv
    )
  end
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
bin/rails test test/controllers/games/ranked_items_controller_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/controllers/games/ranked_items_controller.rb test/controllers/games/ranked_items_controller_test.rb config/routes.rb
git add config/routes.rb app/controllers/games/ranked_items_controller.rb test/controllers/games/ranked_items_controller_test.rb
git commit -m "Games rankings: /video-games/export.csv" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Saved-search export

**Files:**
- Modify: `web-app/app/lib/books/saved_search_query.rb` (hydrate select)
- Create: `web-app/app/lib/csv_exports/saved_search.rb`
- Modify: `web-app/config/routes.rb` (searches block), `web-app/app/controllers/saved_searches_controller.rb`
- Test: `web-app/test/lib/books/saved_search_query_test.rb`, `web-app/test/lib/csv_exports/saved_search_test.rb`, `web-app/test/controllers/saved_searches_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/books/saved_search_query_test.rb`, next to the "carries ranked_position" test (same setup — copy that test's stubbing of `BookAdvanced` and its ranked-item creation):

```ruby
    test "carries ranked_score alongside ranked_position" do
      book = books_books(:war_and_peace)
      RankedItem.where(item: book).delete_all
      RankedItem.create!(item: book, ranking_configuration: ::Books::RankingConfiguration.default_primary, rank: 7, score: 42.5)
      ::Search::Books::Search::BookAdvanced.stubs(:call).returns({ids: [book.id], total: 1, total_relation: "eq"})

      result = SavedSearchQuery.call(criteria: saved_searches(:books_public).criteria_object, owner: users(:regular_user))

      assert_equal 42.5, result.books.first.ranked_score.to_f
    end
```

`test/lib/csv_exports/saved_search_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class SavedSearchTest < ActiveSupport::TestCase
    setup do
      @search = saved_searches(:books_public)
      @books = [books_books(:war_and_peace), books_books(:crime_and_punishment)]
    end

    def stub_pages(pages)
      calls = 0
      ::Search::Books::Search::BookAdvanced.stubs(:call).with { |*| calls += 1; true }.returns(
        *pages.map { |ids| {ids: ids, total: pages.flatten.size, total_relation: "eq"} }
      )
    end

    def export(limit:)
      io = StringIO.new
      rows = SavedSearch.call(search: @search, limit: limit, io: io)
      [rows, CSV.parse(io.string.delete_prefix(Writer::BOM))]
    end

    test "writes the books columns for every result, in search order" do
      stub_pages([@books.map(&:id).reverse])

      rows, parsed = export(limit: nil)

      assert_equal 2, rows
      assert_equal Books::RankedBookRow::HEADERS, parsed.first
      assert_equal ["Crime and Punishment", "War and Peace"], parsed.drop(1).map { |row| row[3] }
    end

    # `opts` rather than keyword block params: Mocha hands the call's keyword
    # arguments to a matching block in a version-dependent shape, and a plain
    # second positional swallows either one.
    test "the limit caps rows and sizes the page to the limit" do
      ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, opts|
        opts[:page] == 1 && opts[:per_page] == 1
      }.returns({ids: [@books.first.id], total: 2, total_relation: "eq"}).once

      rows, _parsed = export(limit: 1)

      assert_equal 1, rows
    end

    test "a member's export asks for full pages" do
      ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, opts|
        opts[:per_page] == SavedSearch::PER_PAGE
      }.returns({ids: [], total: 0, total_relation: "eq"}).once

      export(limit: nil)
    end

    test "stops after a short page without asking for another" do
      ::Search::Books::Search::BookAdvanced.expects(:call).once
        .returns({ids: [@books.first.id], total: 1, total_relation: "eq"})

      rows = SavedSearch.call(search: @search, limit: nil, io: StringIO.new)

      assert_equal 1, rows
    end

    test "never asks past the OpenSearch window" do
      assert_equal 10, SavedSearch.max_page(per_page: 1000)
    end

    test "rank and score come from the hydrated book" do
      RankedItem.where(item: @books.first).delete_all
      RankedItem.create!(item: @books.first, ranking_configuration: ::Books::RankingConfiguration.default_primary,
        rank: 3, score: 12.25)
      stub_pages([[@books.first.id]])

      _rows, parsed = export(limit: nil)

      assert_equal ["3", "12.25"], parsed[1][0..1]
    end
  end
end
```

Append to `test/controllers/saved_searches_controller_test.rb`:

```ruby
  # --- export (spec §9) ---

  test "export requires sign-in even for a public search" do
    get export_saved_search_path(@public_search, format: :csv)

    assert_redirected_to "/"
  end

  test "a non-member exports the top 500 results of a visible search" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    sign_in_as(users(:user_with_expired_membership), stub_auth: true)

    get export_saved_search_path(@public_search, format: :csv)

    assert_response :success
    assert_includes response.media_type, "text/csv"
    assert_match "no-store", response.headers["Cache-Control"].to_s
    assert_includes response.headers["Content-Disposition"], "great-russian-novels-#{Date.current.iso8601}.csv"
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
    assert_equal CsvExports::Books::RankedBookRow::HEADERS, rows.first
    assert_equal ["War and Peace"], rows.drop(1).map { |row| row[3] }
  end

  test "a private search's export 404s for a stranger" do
    sign_in_as(@other, stub_auth: true)

    get export_saved_search_path(@private_search, format: :csv)

    assert_response :not_found
  end

  test "the export does not count as an execution" do
    stub_advanced(ids: [], total: 0)
    sign_in_as(@user, stub_auth: true)
    before = @public_search.last_executed_at

    get export_saved_search_path(@public_search, format: :csv)

    assert_equal before, @public_search.reload.last_executed_at
  end
```

Add `require "csv"` at the top of the controller test if absent.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/lib/books/saved_search_query_test.rb test/lib/csv_exports/saved_search_test.rb test/controllers/saved_searches_controller_test.rb
```

Expected: `ranked_score` NoMethodError, `NameError` for `CsvExports::SavedSearch`, undefined `export_saved_search_path`.

- [ ] **Step 3: Add `ranked_score` to the hydrate select**

In `app/lib/books/saved_search_query.rb`, change the `select` line in `hydrate` to:

```ruby
        .select("books_books.*, ranked_items.rank AS ranked_position, ranked_items.score AS ranked_score")
```

- [ ] **Step 4: Write the exporter**

`app/lib/csv_exports/saved_search.rb`:

```ruby
# frozen_string_literal: true

# Exports a saved search by paging its query (spec §9): OpenSearch picks the
# ids, SavedSearchQuery hydrates a page, and the books row class writes it.
# Stops at the limit, at a short page, or at the last page inside OpenSearch's
# 10,000-result window, whichever comes first. hide_read stays about the
# search's owner, exactly as on the page.
#
# Books-only in effect: saved searches exist on no other domain, and the
# controller 404s a host without them before this is reached.
module CsvExports
  class SavedSearch
    PER_PAGE = 1000

    def self.max_page(per_page:)
      ::Books::SavedSearchQuery.max_page(per_page: per_page)
    end

    def self.call(search:, limit:, io:)
      row_class = Books::RankedBookRow
      writer = Writer.new(io, headers: row_class::HEADERS)
      per_page = limit ? [limit, PER_PAGE].min : PER_PAGE
      last_page = max_page(per_page: per_page)
      query_class = search.class.query_class

      page = 1
      loop do
        books = query_class.call(criteria: search.criteria_object, owner: search.user, page: page, per_page: per_page).books
        break if books.empty?

        ActiveRecord::Associations::Preloader.new(records: books, associations: row_class.preloads).call
        ctx = row_class.context(books.map(&:id))
        books.each do |book|
          break if limit && writer.rows >= limit

          writer.row(row_class.row_for_book(book, rank: book.ranked_position, score: book.ranked_score, ctx: ctx))
        end

        break if (limit && writer.rows >= limit) || books.size < per_page || page >= last_page

        page += 1
      end

      writer.rows
    end
  end
end
```

- [ ] **Step 5: Add the route and action**

In `config/routes.rb`, in the saved searches block, before `get "searches/:id"`:

```ruby
  get "searches/:id/export", to: "saved_searches#export", as: :export_saved_search,
    constraints: {id: /\d+/, format: /csv/}
```

In `app/controllers/saved_searches_controller.rb`: add `include CsvExportable` after `include SavedSearchDomainScoped`, and add the action after `show`:

```ruby
  # GET /searches/:id/export.csv
  #
  # Same visibility as show (owner, or anyone for a public search -- but
  # signed in, per CsvExportable), and deliberately not an execution: it does
  # not write last_executed_at.
  def export
    @search = domain_class.visible_to(current_user).find(params[:id])
    authorize @search, :show?, policy_class: SavedSearchPolicy

    io = StringIO.new
    CsvExports::SavedSearch.call(search: @search, limit: export_limit, io: io)
    send_csv io.string, filename: "#{@search.display_name.parameterize.presence || "search"}-#{Date.current.iso8601}.csv"
  end
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
bin/rails test test/lib/books/saved_search_query_test.rb test/lib/csv_exports/saved_search_test.rb test/controllers/saved_searches_controller_test.rb
```

Expected: all pass. If the controller's `assert_queries_count(9)` on `show` fails, the `select` change did not add a query — re-check the diff; the count must not move.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb app/lib/books/saved_search_query.rb app/lib/csv_exports/saved_search.rb app/controllers/saved_searches_controller.rb config/routes.rb test/lib/books/saved_search_query_test.rb test/lib/csv_exports/saved_search_test.rb test/controllers/saved_searches_controller_test.rb
git add app/lib/books/saved_search_query.rb app/lib/csv_exports/saved_search.rb app/controllers/saved_searches_controller.rb config/routes.rb test/lib/books/saved_search_query_test.rb test/lib/csv_exports/saved_search_test.rb test/controllers/saved_searches_controller_test.rb
git commit -m "Saved searches: /searches/:id/export.csv, paged through OpenSearch up to the cap" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: Move the user-list CSV into `CsvExports::UserList`

**Files:**
- Create: `web-app/app/lib/csv_exports/user_list.rb`
- Modify: `web-app/app/controllers/my_lists_controller.rb`
- Test: `web-app/test/lib/csv_exports/user_list_test.rb`; `web-app/test/controllers/my_lists_controller_test.rb` must stay green unchanged

- [ ] **Step 1: Write the failing test (against the current controller output)**

`test/lib/csv_exports/user_list_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class UserListTest < ActiveSupport::TestCase
    test "albums with a completion date" do
      list = user_lists(:regular_user_music_albums_listened)
      items = list.user_list_items.ordered.to_a

      body = UserList.call(list: list, items: items).string

      assert body.start_with?(Writer::BOM)
      rows = CSV.parse(body.delete_prefix(Writer::BOM))
      assert_equal ["Position", "Title", "Artists", "Year", "Completed On"], rows.first
      assert_equal items.size, rows.size - 1
      assert_equal items.first.listable.title, rows[1][1]
      assert_equal "2026-02-01", rows[1][4]
    end

    test "songs omit the completion column" do
      list = user_lists(:regular_user_music_songs_favorites)

      rows = CSV.parse(UserList.call(list: list, items: list.user_list_items.ordered.to_a).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Artists", "Year"], rows.first
    end

    test "books use an Authors column and first_published_year" do
      list = user_lists(:regular_user_books_favorites)
      items = list.user_list_items.ordered.to_a

      rows = CSV.parse(UserList.call(list: list, items: items).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Authors", "Year"], rows.first
      assert_equal items.first.listable.first_published_year.to_s, rows[1][3]
    end

    test "games and movies have no creator column" do
      list = user_lists(:regular_user_games_favorites)

      rows = CSV.parse(UserList.call(list: list, items: list.user_list_items.ordered.to_a).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Year"], rows.first
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/lib/csv_exports/user_list_test.rb
```

Expected: `NameError: uninitialized constant CsvExports::UserList`.

- [ ] **Step 3: Write the exporter (moved verbatim)**

`app/lib/csv_exports/user_list.rb`:

```ruby
# frozen_string_literal: true

# The user-list CSV, moved from MyListsController without changing its output
# (spec §9): test/controllers/my_lists_controller_test.rb pins the bytes.
# Columns vary per listable; the Completed On column appears only on lists
# whose list_type supports a completion date. Uncapped -- a list is the
# viewer's own data, or data someone chose to make public.
module CsvExports
  class UserList
    def self.call(list:, items:, io: StringIO.new)
      new(list, items).write(io)
    end

    def initialize(list, items)
      @list = list
      @items = items
      @listable_name = list.class.listable_class.name
      @show_completed = list.completed_on_enabled?
    end

    def write(io)
      writer = Writer.new(io, headers: headers)
      @items.each { |item| writer.row(row(item)) }
      io
    end

    private

    def headers
      headers =
        case @listable_name
        when "Music::Album", "Music::Song" then ["Position", "Title", "Artists", "Year"]
        when "Books::Book" then ["Position", "Title", "Authors", "Year"]
        else ["Position", "Title", "Year"]
        end
      @show_completed ? headers + ["Completed On"] : headers
    end

    def row(item)
      listable = item.listable
      row =
        case @listable_name
        when "Music::Album", "Music::Song"
          [item.position, listable.title, artist_names(listable), listable.release_year]
        when "Books::Book"
          [item.position, listable.title, author_names(listable), listable.first_published_year]
        else
          [item.position, listable.title, listable.release_year]
        end
      @show_completed ? row + [item.completed_on&.iso8601] : row
    end

    def artist_names(listable)
      listable.artists.map(&:name).join(", ")
    end

    def author_names(listable)
      listable.book_authors.map { |book_author| book_author.author.name }.join(", ")
    end
  end
end
```

- [ ] **Step 4: Switch the controller over**

In `app/controllers/my_lists_controller.rb`:

- Delete `require "csv"` at the top.
- Replace the `format.csv` block in `show` with:

```ruby
      format.csv do
        items = collection.is_a?(Array) ? collection : collection.to_a
        send_data CsvExports::UserList.call(list: @list, items: items).string,
          type: "text/csv; charset=utf-8",
          filename: csv_filename,
          disposition: "attachment"
      end
```

- Delete the private methods `build_csv`, `csv_headers`, `csv_row`, `artist_names`, `author_names` and the comment above `build_csv`. Keep `csv_filename`.

- [ ] **Step 5: Run the tests to see them pass — including the untouched controller tests**

```bash
bin/rails test test/lib/csv_exports/user_list_test.rb test/controllers/my_lists_controller_test.rb
```

Expected: all pass with no change to `my_lists_controller_test.rb`.

- [ ] **Step 6: Commit**

```bash
bundle exec standardrb app/lib/csv_exports/user_list.rb app/controllers/my_lists_controller.rb test/lib/csv_exports/user_list_test.rb
git add app/lib/csv_exports/user_list.rb app/controllers/my_lists_controller.rb test/lib/csv_exports/user_list_test.rb
git commit -m "Move the user-list CSV into CsvExports::UserList (output unchanged)" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 17: The download button component and its Stimulus controller

**Files:**
- Create: `web-app/app/components/csv_exports/download_button_component.rb` + `.html.erb` (generated)
- Create: `web-app/app/javascript/controllers/csv_export_controller.js`
- Modify: `web-app/app/javascript/manifests/web_shared.js`
- Test: `web-app/test/components/csv_exports/download_button_component_test.rb` (generated, then replaced)

- [ ] **Step 1: Generate the component**

```bash
bin/rails g component CsvExports::DownloadButton export_path noun capped
```

- [ ] **Step 2: Write the failing component test**

Replace `test/components/csv_exports/download_button_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module CsvExports
  class DownloadButtonComponentTest < ViewComponent::TestCase
    test "a capped button carries the controller, the link and the explanation dialog" do
      render_inline(DownloadButtonComponent.new(export_path: "/export.csv?category_id=novels", noun: "books"))

      assert_selector "[data-controller='csv-export'][data-csv-export-modal-value='csv_export_modal']"
      assert_selector "a[href='/export.csv?category_id=novels'][rel='nofollow'][data-action='csv-export#download'][data-turbo='false'][data-testid='download-csv']",
        text: "Download CSV"
      assert_selector "dialog#csv_export_modal.modal" do
        assert_selector "h3", text: "This download includes the top 500 books"
        assert_selector "a.btn-primary[href='/export.csv?category_id=novels'][data-turbo='false']", text: "Download top 500"
        assert_selector "a[href='/membership']", text: "Become a member"
        assert_selector "form[method='dialog'] button", text: "Cancel"
      end
    end

    test "an uncapped button is a plain link with no controller and no dialog" do
      render_inline(DownloadButtonComponent.new(export_path: "/my/lists/1.csv", noun: "books", capped: false))

      assert_selector "a[href='/my/lists/1.csv'][data-turbo='false'][data-testid='download-csv']", text: "Download CSV"
      assert_no_selector "[data-controller='csv-export']"
      assert_no_selector "dialog"
    end

    test "the noun and testid are configurable" do
      render_inline(DownloadButtonComponent.new(export_path: "/searches/1/export.csv", noun: "results", testid: "export-search"))

      assert_selector "h3", text: "This download includes the top 500 results"
      assert_selector "a[data-testid='export-search']"
    end
  end
end
```

- [ ] **Step 3: Run it to see it fail**

```bash
bin/rails test test/components/csv_exports/download_button_component_test.rb
```

Expected: failures — the generated template is empty.

- [ ] **Step 4: Write the component**

`app/components/csv_exports/download_button_component.rb`:

```ruby
# frozen_string_literal: true

# "Download CSV" (spec §11). On an edge-cached page the HTML is the same for
# everyone, so the top-500 explanation is a static dialog that
# csv_export_controller.js opens for a signed-in non-member. The <a href> is
# real: with JS off the link still works and the server applies the cap. The
# dialog explains; it never enforces.
#
# capped: false (user lists) renders a bare link -- no controller, no dialog.
# The component renders its own dialog, so it is rendered once per page.
module CsvExports
  class DownloadButtonComponent < ViewComponent::Base
    MODAL_ID = "csv_export_modal"

    def initialize(export_path:, noun:, capped: true, testid: "download-csv")
      @export_path = export_path
      @noun = noun
      @capped = capped
      @testid = testid
    end

    private

    attr_reader :export_path, :noun, :testid

    def capped?
      @capped
    end

    def modal_id
      MODAL_ID
    end

    def preview_rows
      ::CsvExports::Limits::PREVIEW_ROWS
    end
  end
end
```

`app/components/csv_exports/download_button_component.html.erb`:

```erb
<% if capped? %>
  <div data-controller="csv-export" data-csv-export-modal-value="<%= modal_id %>" class="inline-block">
    <a href="<%= export_path %>" rel="nofollow" class="btn btn-sm btn-outline"
       data-action="csv-export#download" data-turbo="false" data-testid="<%= testid %>">Download CSV</a>
  </div>

  <dialog id="<%= modal_id %>" class="modal">
    <div class="modal-box">
      <h3 class="text-lg font-bold">This download includes the top <%= preview_rows %> <%= noun %></h3>
      <p class="py-4">Members can download the whole ranking and the full results of any filter or saved search.</p>
      <div class="modal-action">
        <a href="<%= export_path %>" class="btn btn-primary" data-turbo="false">Download top <%= preview_rows %></a>
        <%= link_to "Become a member", helpers.membership_path, class: "btn btn-outline" %>
        <form method="dialog"><button class="btn btn-ghost">Cancel</button></form>
      </div>
    </div>
    <form method="dialog" class="modal-backdrop"><button>close</button></form>
  </dialog>
<% else %>
  <a href="<%= export_path %>" class="btn btn-sm btn-outline" data-turbo="false" data-testid="<%= testid %>">Download CSV</a>
<% end %>
```

- [ ] **Step 5: Run the component test to see it pass**

```bash
bin/rails test test/components/csv_exports/download_button_component_test.rb
```

Expected: all pass.

- [ ] **Step 6: Write the Stimulus controller**

`app/javascript/controllers/csv_export_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The Download CSV button on edge-cached pages (spec §11).
//
// The page cannot know who is looking at it, so the decision is made on click:
//   - no tg_uid cookie      -> open the sign-in modal (same check as
//                              user_list_widget_controller.js)
//   - /membership_state ok  -> member: follow the link; the server sends the
//                              file
//   - anything else         -> show the top-500 dialog. Safe in the direction
//                              that matters: a member who hits this fallback
//                              sees one unnecessary dialog, and "Download top
//                              500" points at the same URL, so the server
//                              still gives them the full file.
export default class extends Controller {
  static values = {
    modal: String,
    stateUrl: { type: String, default: "/membership_state" }
  }

  async download(event) {
    event.preventDefault()
    const href = event.currentTarget.href

    if (!this.cookieUid()) {
      document.getElementById("login_modal")?.showModal?.()
      return
    }

    if (await this.member()) {
      window.location.assign(href)
      return
    }

    document.getElementById(this.modalValue)?.showModal?.()
  }

  async member() {
    try {
      const response = await fetch(this.stateUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) return false
      const state = await response.json()
      return !!state.member
    } catch (_e) {
      return false
    }
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }
}
```

- [ ] **Step 7: Register it**

In `app/javascript/manifests/web_shared.js`, after the `contact--form` registration:

```js
import CsvExportController from "../controllers/csv_export_controller"
application.register("csv-export", CsvExportController)
```

- [ ] **Step 8: Build and run the manifest lint**

```bash
yarn build:all
bin/rails test test/lint/stimulus_manifest_test.rb test/lint/daisyui_v4_classes_test.rb
```

Expected: the build succeeds; the manifest test **fails** with "registered but referenced nowhere" until Task 18 renders the component in a view — that is expected here; it passes after Task 18. The DaisyUI lint passes.

- [ ] **Step 9: Commit**

```bash
bundle exec standardrb app/components/csv_exports test/components/csv_exports
git add app/components/csv_exports test/components/csv_exports app/javascript/controllers/csv_export_controller.js app/javascript/manifests/web_shared.js
git commit -m "CsvExports::DownloadButtonComponent and csv-export Stimulus controller" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 18: Render the button on every page

**Files:**
- Modify: `web-app/app/views/books/ranked_items/index.html.erb`
- Modify: `web-app/app/views/music/albums/ranked_items/index.html.erb`, `web-app/app/views/music/songs/ranked_items/index.html.erb`
- Modify: `web-app/app/views/games/ranked_items/index.html.erb`
- Modify: `web-app/app/views/saved_searches/show.html.erb`
- Modify: `web-app/app/views/my_lists/show.html.erb`
- Test: `web-app/test/controllers/books/ranked_items_controller_test.rb`, `.../music/albums/...`, `.../games/...`, `.../saved_searches_controller_test.rb`, `.../my_lists_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `Books::RankedItemsControllerTest`:

```ruby
    test "the rankings page renders the download button and its dialog" do
      get "/"

      assert_select "a[data-testid=download-csv][href='/export.csv']"
      assert_select "dialog#csv_export_modal"
    end
```

Append to the music albums test class:

```ruby
      test "the albums page renders the download button" do
        get "/albums"

        assert_select "a[data-testid=download-csv][href='/albums/export.csv']"
      end
```

Append to the games test class:

```ruby
      test "the games page renders the download button" do
        get "/video-games"

        assert_select "a[data-testid=download-csv][href='/video-games/export.csv']"
      end
```

Append to `SavedSearchesControllerTest`:

```ruby
  test "show renders the download button" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_select "a[data-testid=download-csv][href='#{export_saved_search_path(@public_search, format: :csv)}']"
    assert_select "dialog#csv_export_modal h3", text: /top 500 results/
  end
```

Append to `MyListsControllerTest` (find the existing show test's setup for a list the user owns — `@albums_listened` — and reuse it):

```ruby
  test "show renders the download button as a plain link" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_listened)

    assert_select "a[data-testid=download-csv][href*='.csv']", text: "Download CSV"
    assert_select "dialog#csv_export_modal", count: 0
  end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/controllers/books/ranked_items_controller_test.rb test/controllers/music/albums/ranked_items_controller_test.rb test/controllers/games/ranked_items_controller_test.rb test/controllers/saved_searches_controller_test.rb test/controllers/my_lists_controller_test.rb
```

Expected: the new `assert_select`s fail.

- [ ] **Step 3: Books rankings**

In `app/views/books/ranked_items/index.html.erb`, directly after the `Books::FilterBarComponent` render block:

```erb
  <div class="flex justify-center">
    <%= render CsvExports::DownloadButtonComponent.new(export_path: @csv_export_path, noun: "books") %>
  </div>
```

- [ ] **Step 4: Music albums and songs**

In `app/views/music/albums/ranked_items/index.html.erb`, directly after the `Music::FilterTabsComponent` render block:

```erb
  <div class="flex justify-end mb-4">
    <%= render CsvExports::DownloadButtonComponent.new(export_path: @csv_export_path, noun: "albums") %>
  </div>
```

Same in `app/views/music/songs/ranked_items/index.html.erb` with `noun: "songs"`.

- [ ] **Step 5: Games**

In `app/views/games/ranked_items/index.html.erb`, directly after the `<div class="flex justify-center">…Games::FilterTabsComponent…</div>` block:

```erb
  <div class="flex justify-center mb-4">
    <%= render CsvExports::DownloadButtonComponent.new(export_path: @csv_export_path, noun: "games") %>
  </div>
```

- [ ] **Step 6: Saved search**

In `app/views/saved_searches/show.html.erb`, replace the `<% if @owner %>` block that holds the Edit/Delete buttons with:

```erb
  <div class="flex flex-wrap gap-2">
    <%= render CsvExports::DownloadButtonComponent.new(
          export_path: export_saved_search_path(@search, format: :csv),
          noun: "results"
        ) %>
    <% if @owner %>
      <%= link_to "Edit", edit_saved_search_path(@search), class: "btn btn-sm btn-outline" %>
      <%= button_to "Delete", saved_search_path(@search), method: :delete,
            class: "btn btn-sm btn-error btn-outline",
            form: {data: {turbo_confirm: "Delete this saved search?"}} %>
    <% end %>
  </div>
```

- [ ] **Step 7: User list**

In `app/views/my_lists/show.html.erb`, replace the `link_to "Download", ...` with:

```erb
      <%= render CsvExports::DownloadButtonComponent.new(
            export_path: my_list_path(@list, format: :csv, view_mode: @view_mode, sort: ranking_sort),
            noun: "items",
            capped: false
          ) %>
```

- [ ] **Step 8: Run the tests, the lint, and the frame-trap guard**

```bash
yarn build:all
bin/rails test test/controllers/books/ranked_items_controller_test.rb test/controllers/music/albums/ranked_items_controller_test.rb test/controllers/music/songs/ranked_items_controller_test.rb test/controllers/games/ranked_items_controller_test.rb test/controllers/saved_searches_controller_test.rb test/controllers/my_lists_controller_test.rb test/lint
```

Expected: all pass, including `stimulus_manifest_test.rb` now that the controller is referenced by markup. The existing my-lists E2E test looks for `getByTestId('download-csv')` — the testid is unchanged.

- [ ] **Step 9: Commit**

```bash
git add app/views test/controllers
git commit -m "Render the CSV download button on rankings, saved-search and list pages" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 19: Admin — CSV export card and Regenerate action

**Files:**
- Create: `web-app/app/lib/actions/admin/regenerate_csv_export.rb`
- Modify: `web-app/app/controllers/admin/ranking_configurations_controller.rb` (`allowed_action_names`)
- Modify: `web-app/app/views/admin/ranking_configurations/show.html.erb`
- Test: `web-app/test/lib/actions/admin/regenerate_csv_export_test.rb`, `web-app/test/controllers/admin/books/ranking_configurations_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/actions/admin/regenerate_csv_export_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class RegenerateCsvExportTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @config = ranking_configurations(:books_global)
      end

      test "name and message" do
        assert_equal "Regenerate CSV Export", RegenerateCsvExport.name
        assert_not_empty RegenerateCsvExport.message
      end

      test "visible only on the show view" do
        assert RegenerateCsvExport.visible?(view: :show)
        assert_not RegenerateCsvExport.visible?(view: :index)
      end

      test "errors unless exactly one configuration is given" do
        assert RegenerateCsvExport.call(user: @user, models: []).error?
      end

      test "requests a generate and reports success" do
        Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @config)
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))

        result = RegenerateCsvExport.call(user: @user, models: [@config])

        assert result.success?
        assert_includes result.message, @config.name
      end

      test "surfaces a refused request as an error" do
        result = RegenerateCsvExport.call(user: @user, models: [ranking_configurations(:books_authors_global)])

        assert result.error?
        assert_equal Services::CsvExports::RequestGenerate::NOT_EXPORTABLE, result.message
      end
    end
  end
end
```

Append to `test/controllers/admin/books/ranking_configurations_controller_test.rb`, inside the class (its setup defines `@admin_user` and `@rc = ranking_configurations(:books_global)`):

```ruby
      test "show renders the CSV export card" do
        sign_in_as(@admin_user, stub_auth: true)
        CsvExport.create!(ranking_configuration: @rc, status: :failed, error_message: "disk full")

        get admin_books_ranking_configuration_path(@rc)

        assert_response :success
        assert_select "[data-testid=csv-export-card]" do
          assert_select "*", text: /Failed/
          assert_select "*", text: /disk full/
          assert_select "form[action=?]", execute_action_admin_books_ranking_configuration_path(@rc, action_name: "RegenerateCsvExport")
        end
      end

      test "RegenerateCsvExport is an allowed action" do
        sign_in_as(@admin_user, stub_auth: true)
        Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @rc)
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))

        post execute_action_admin_books_ranking_configuration_path(@rc, action_name: "RegenerateCsvExport")

        assert_redirected_to admin_books_ranking_configuration_path(@rc)
      end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/lib/actions/admin/regenerate_csv_export_test.rb test/controllers/admin/books/ranking_configurations_controller_test.rb
```

Expected: `NameError` for the action; the card is missing; the action name is rejected (400).

- [ ] **Step 3: Write the action**

`app/lib/actions/admin/regenerate_csv_export.rb`:

```ruby
module Actions
  module Admin
    class RegenerateCsvExport < Actions::Admin::BaseAction
      def self.name
        "Regenerate CSV Export"
      end

      def self.message
        "Rebuild the pre-built CSV download for this configuration."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        result = Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
        return error(result.errors.join(", ")) unless result.success?

        succeed "CSV export regeneration queued for #{config.name}."
      end
    end
  end
end
```

- [ ] **Step 4: Allow it**

In `app/controllers/admin/ranking_configurations_controller.rb`, `allowed_action_names` becomes:

```ruby
    %w[RefreshRankings BulkCalculateWeights GenerateDynamicLists CreateNextYearConfiguration RegenerateCsvExport]
```

- [ ] **Step 5: Add the card**

In `app/views/admin/ranking_configurations/show.html.erb`, in the right-hand `<div class="space-y-6">` column, directly after the Statistics card's closing `</div></div>` (before the Metadata card):

```erb
      <% if CsvExports::Registry.exportable?(@ranking_configuration) %>
        <% export = @ranking_configuration.csv_export %>
        <div class="card bg-base-100 shadow-xl" data-testid="csv-export-card">
          <div class="card-body">
            <h2 class="card-title">CSV Export</h2>
            <% if export %>
              <dl class="text-sm space-y-1">
                <div><dt class="inline font-semibold">Status:</dt> <dd class="inline"><%= export.status.humanize %></dd></div>
                <div>
                  <dt class="inline font-semibold">Generated:</dt>
                  <dd class="inline"><%= export.generated_at ? "#{time_ago_in_words(export.generated_at)} ago" : "never" %></dd>
                </div>
                <% if export.row_count %>
                  <div><dt class="inline font-semibold">Rows:</dt> <dd class="inline"><%= number_with_delimiter(export.row_count) %></dd></div>
                <% end %>
                <% if export.byte_size %>
                  <div><dt class="inline font-semibold">Size:</dt> <dd class="inline"><%= number_to_human_size(export.byte_size) %></dd></div>
                <% end %>
                <% if export.error_message.present? %>
                  <div class="text-error"><%= export.error_message %></div>
                <% end %>
              </dl>
            <% else %>
              <p class="text-sm text-base-content/70">No export has been generated yet.</p>
            <% end %>
            <% if ranking_configuration_policy.execute_action? %>
              <div class="card-actions mt-2">
                <%= button_to "Regenerate CSV",
                    execute_action_ranking_configuration_path(@ranking_configuration, action_name: "RegenerateCsvExport"),
                    method: :post,
                    class: "btn btn-sm btn-outline" %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
bin/rails test test/lib/actions/admin/regenerate_csv_export_test.rb test/controllers/admin
```

Expected: all pass (the whole admin directory, to catch a view regression on the other domains' show pages).

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb app/lib/actions/admin/regenerate_csv_export.rb app/controllers/admin/ranking_configurations_controller.rb test/lib/actions/admin/regenerate_csv_export_test.rb test/controllers/admin/books/ranking_configurations_controller_test.rb
git add app/lib/actions/admin/regenerate_csv_export.rb app/controllers/admin/ranking_configurations_controller.rb app/views/admin/ranking_configurations/show.html.erb test/lib/actions/admin/regenerate_csv_export_test.rb test/controllers/admin/books/ranking_configurations_controller_test.rb
git commit -m "Admin: CSV export card and Regenerate action on ranking configurations" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 20: Playwright E2E

**Files:**
- Create: `web-app/e2e/tests/books/rankings-csv-export.spec.ts`
- Create: `web-app/e2e/tests/books/account/rankings-csv-export.spec.ts`
- Create: `web-app/e2e/tests/books/account/saved-search-csv-export.spec.ts`
- Create: `web-app/e2e/tests/books/member/rankings-csv-export.spec.ts`
- Create: `web-app/e2e/tests/music/csv-export.spec.ts`
- Create: `web-app/e2e/tests/games/csv-export.spec.ts`

Prerequisites (see `docs/features/e2e-testing.md`): `web-app/e2e/.env` exists (copy from the main machine if this one only has `.env.example`), `yarn build:all`, `bin/rails server` in this worktree, and port 3000 is yours — check before running:

```bash
pid=$(lsof -tiTCP:3000 -sTCP:LISTEN | head -1); [ -n "$pid" ] && lsof -p "$pid" | awk '$4=="cwd"{print $NF}' || echo "port 3000 is free"
```

- [ ] **Step 1: Anonymous books spec**

`e2e/tests/books/rankings-csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Books rankings CSV export (anonymous)', () => {
  test('the download button opens the login modal for a visitor', async ({ page }) => {
    await page.goto('/');

    await page.getByTestId('download-csv').click();

    await expect(page.locator('#login_modal')).toBeVisible();
    await expect(page.locator('#csv_export_modal')).not.toBeVisible();
  });

  test('the export endpoint turns an anonymous request away', async ({ page }) => {
    const response = await page.request.get('/export.csv', { maxRedirects: 0 });

    expect(response.status()).toBe(302);
  });
});
```

- [ ] **Step 2: Signed-in non-member books spec**

`e2e/tests/books/account/rankings-csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// books-account is the ordinary (non-member) E2E account. If it is ever
// comped, the modal never opens; the guard below skips rather than fails.
test.describe('Books rankings CSV export (non-member)', () => {
  test.beforeEach(async ({ page }) => {
    const state = await page.request.get('/membership_state', { headers: { Accept: 'application/json' } });
    test.skip(state.ok() && (await state.json()).member === true, 'account is a member');
  });

  test('explains the top-500 cap and downloads the preview', async ({ page }) => {
    await page.goto('/');
    await page.getByTestId('download-csv').click();

    const dialog = page.locator('#csv_export_modal');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: /top 500 books/ })).toBeVisible();
    await expect(dialog.getByRole('link', { name: 'Become a member' })).toHaveAttribute('href', '/membership');

    const [download] = await Promise.all([
      page.waitForEvent('download'),
      dialog.getByRole('link', { name: 'Download top 500' }).click(),
    ]);
    expect(download.suggestedFilename()).toMatch(/^the-greatest-books-rankings-\d{4}-\d{2}-\d{2}\.csv$/);
  });

  test('the preview is capped at 500 rows and carries the current filters', async ({ page }) => {
    const response = await page.request.get('/export.csv?category_id=novels');

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
    expect(response.headers()['cache-control']).toContain('no-store');
    const lines = (await response.text()).trim().split('\n');
    expect(lines[0]).toMatch(/^\uFEFFRank,Score,ID,Title/);
    expect(lines.length).toBeLessThanOrEqual(501);
  });
});
```

- [ ] **Step 3: Member books spec**

`e2e/tests/books/member/rankings-csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// books-member: PLAYWRIGHT_MEMBER_EMAIL, comped by `bin/rails e2e:member`.
test.describe('Books rankings CSV export (member)', () => {
  test('a member is taken straight to the file on a filtered page', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByTestId('download-csv').click(),
    ]);

    expect(download.suggestedFilename()).toMatch(/\.csv$/);
    await expect(page.locator('#csv_export_modal')).not.toBeVisible();
  });

  test('the unfiltered export is the pre-built file or the preparing page', async ({ page }) => {
    const response = await page.request.get('/export.csv');

    expect([200, 202]).toContain(response.status());
    if (response.status() === 200) {
      expect(response.headers()['content-type']).toContain('text/csv');
    } else {
      expect(response.headers()['refresh']).toBe('15');
      expect(await response.text()).toContain('Preparing your export');
    }
  });
});
```

- [ ] **Step 4: Saved-search spec**

`e2e/tests/books/account/saved-search-csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Saved search CSV export', () => {
  test('a saved search page offers a CSV download that serves CSV', async ({ page }) => {
    await page.goto('/searches');
    await page.getByRole('link', { name: 'New Saved Search' }).click();

    const name = `E2E csv ${Date.now()}`;
    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Type').selectOption({ label: 'Fiction' });
    await page.getByRole('button', { name: 'Create search' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText(name);

    const link = page.getByTestId('download-csv');
    await expect(link).toBeVisible();
    const href = (await link.getAttribute('href'))!;
    expect(href).toMatch(/^\/searches\/\d+\/export\.csv$/);

    const response = await page.request.get(href);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');

    // Clean up so the account does not accumulate searches across runs.
    page.on('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL('/searches');
  });
});
```

- [ ] **Step 5: Music and games specs**

`e2e/tests/music/csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Music CSV export', () => {
  for (const [path, exportPath] of [
    ['/albums', '/albums/export.csv?year=1990s'],
    ['/songs', '/songs/export.csv?year=1990s'],
  ] as const) {
    test(`${path} offers a download and a filtered export serves CSV`, async ({ page }) => {
      await page.goto(path);
      await expect(page.getByTestId('download-csv')).toBeVisible();

      const response = await page.request.get(exportPath);
      expect(response.status()).toBe(200);
      expect(response.headers()['content-type']).toContain('text/csv');
      expect(await response.text()).toMatch(/^\uFEFFRank,Score,ID,Title,Artists/);
    });
  }
});
```

`e2e/tests/games/csv-export.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

test.describe('Games CSV export', () => {
  test('the games page offers a download and a filtered export serves CSV', async ({ page }) => {
    await page.goto('/video-games');
    await expect(page.getByTestId('download-csv')).toBeVisible();

    const response = await page.request.get('/video-games/export.csv?year=2017&year_mode=since');
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
    expect(await response.text()).toMatch(/^\uFEFFRank,Score,ID,Title,Year,Platforms/);
  });
});
```

- [ ] **Step 6: Run them**

```bash
yarn test:e2e -- e2e/tests/books/rankings-csv-export.spec.ts e2e/tests/books/account/rankings-csv-export.spec.ts e2e/tests/books/account/saved-search-csv-export.spec.ts e2e/tests/books/member/rankings-csv-export.spec.ts e2e/tests/music/csv-export.spec.ts e2e/tests/games/csv-export.spec.ts e2e/tests/books/account/my-lists.spec.ts
```

Expected: all pass. If the member project is not configured on this machine (`PLAYWRIGHT_MEMBER_EMAIL` unset), Playwright reports the member spec as skipped/failed at setup — say so in the commit and hand-off rather than deleting the spec.

- [ ] **Step 7: Commit**

```bash
git add e2e/tests
git commit -m "E2E: CSV export flows on rankings, saved searches and lists" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 21: Documentation

**Files:**
- Create: `docs/features/csv-exports.md`
- Modify: `docs/features/user-lists.md` (the "CSV export" subsection)

- [ ] **Step 1: Write the feature doc**

`docs/features/csv-exports.md`:

```markdown
# CSV exports

Design: `docs/superpowers/specs/2026-09-18-csv-exports-design.md`.

## What a user gets

A "Download CSV" button on every rankings page (books, music albums, music songs, games), on every
saved-search page and on every user-list page. It exports what is on screen, filters included.

| Viewer is looking at | Member | Signed-in non-member | Anonymous |
|---|---|---|---|
| Unfiltered ranking | pre-built file, full | on demand, top 500 | sign-in modal |
| Filtered ranking | on demand, full | on demand, top 500 | sign-in modal |
| Saved search | on demand, up to 10,000 (OpenSearch's window) | on demand, top 500 | sign-in modal |
| User list | on demand, full | same | unchanged: public lists download for anyone |

`MembershipGate::FEATURES[:csv_export_full]` is the paywall entry; the gate is a cap
(`CsvExports::Limits.limit_for`), never a redirect.

## Why the pre-built file exists, and why nothing else is cached

The legacy books site generated the ~20,000-row member export inline and it timed out constantly;
it then cached files on a 24-hour TTL behind nginx and served them stale. Here:

- The **unfiltered** export of a ranking configuration is a `CsvExport` row (one per configuration,
  unique index) with an ActiveStorage file on R2. It is regenerated by the events that change it:
  after every successful `CalculateRankingsJob` / `RankingConfigurations::RefreshJob`, and nightly
  (`CsvExports::RefreshGlobalJob`, 04:30) for the global configurations to pick up title, author,
  category and country edits that no calculation would notice. There is no TTL.
- **Everything else** is generated on demand by the same code and never stored.
- No CSV is ever a format of an edge-cached `index` action. Every export is its own `export` action
  with `prevent_caching` + `require_signed_in!` + a per-user rate limit (`CsvExportable`).
- The file is proxied through Rails (`send_data blob.download`). The R2 bucket is public, so a blob
  URL would be a permanent unauthenticated link to the paid artifact; `rails_blob_path` is out for
  the same reason (its signed ids do not expire).

## Where the code is

- `app/models/csv_export.rb` — status (`pending/generating/ready/failed`), `requested_at` claim,
  `generated_at`, `row_count`, `byte_size`, `error_message`, `has_one_attached :file`.
  `claimable?` treats a `generating` claim older than 15 minutes as abandoned.
- `app/lib/csv_exports/registry.rb` — the exportable configuration types and, per type, the row
  class, the unfiltered relation, the filename slug and the modal noun. A type with no entry
  (authors, artists, movies) is a no-op everywhere.
- `app/lib/csv_exports/{writer,aggregate,ranked_items,saved_search,user_list,limits}.rb` and the
  row classes under `csv_exports/{books,music,games}/`. Rows are built per batch of 1000 with one
  grouped `string_agg` query per many-to-many column (authors, countries, categories, artists,
  platforms, companies) — preloading those for 21k books took ~10 s; this takes a couple of seconds.
- `app/lib/services/csv_exports/request_generate.rb` — find-or-create + one atomic claim
  `UPDATE … WHERE status <> generating OR requested_at < now() - 15 min` + enqueue; an enqueue
  failure releases the claim into `failed`. Mirrors `Services::RankingConfigurations::RequestRefresh`.
- `app/lib/services/csv_exports/generate.rb` — builds into a Tempfile, attaches, stamps `ready`. On
  failure: `failed` + message, previous file left in place.
- `app/sidekiq/csv_exports/generate_job.rb` (`low`, `retry: false` — the row carries the outcome),
  `refresh_global_job.rb` (nightly, `config/schedule.yml`).
- `app/controllers/concerns/csv_exportable.rb` — the export-action skeleton. `export` actions live
  on `Books::RankedItemsController`, `Music::Albums::…`, `Music::Songs::…`, `Games::…`, and
  `SavedSearchesController`; `MyListsController#show.csv` is the pre-existing list export, now
  delegating to `CsvExports::UserList`.
- `app/components/csv_exports/download_button_component.rb` + `csv_export_controller.js` — the
  button and the top-500 dialog. Rankings pages are edge-cached and identical for everyone, so the
  dialog is static and the Stimulus controller decides on click: no `tg_uid` cookie → login modal;
  `/membership_state` says member → follow the link; otherwise → dialog. The `<a href>` is real and
  the server enforces the cap; the dialog only explains.
- `app/lib/actions/admin/regenerate_csv_export.rb` + the "CSV Export" card on the admin ranking
  configuration show page: status, generated at, rows, size, last error, Regenerate.

## Routes

| Route | Filters (query string) |
|---|---|
| `GET (/rc/:id)/export.csv` (books) | `category_id`, `country_id`, `year`, `published_start`, `published_end`, `collection` |
| `GET (/rc/:id)/albums/export.csv`, `/songs/export.csv` (music) | `year`, `year_mode` |
| `GET (/rc/:id)/video-games/export.csv` (games) | `year`, `year_mode` |
| `GET /searches/:id/export.csv` | none — the search's criteria |
| `GET /my/lists/:id.csv` | `sort` |

The `.csv` format is required by a route constraint; each `export` action parses its filters with
the same code its `index` uses, so the relation is identical by construction. `?collection=` is
accepted here although `index` rejects it (the soft-duplicate-URL concern does not apply to an
uncached, `nofollow`, sign-in-only endpoint).

## Failure modes worth knowing

- A member's unfiltered download with no `ready` file gets a 202 "Preparing your export" page with an
  HTTP `Refresh: 15` header; the refresh re-requests the URL and the browser downloads once the file
  exists. Not a flash — the cached rankings page skips the session. Each refresh calls
  `RequestGenerate`, which dedupes on the claim; if generation keeps failing the rate limit
  (20/hour/user) ends the loop.
- `Generate` failure: row `failed`, message on the admin card, previous file still served, next
  trigger retries.
- Ranks in the file lag the site by the seconds the job takes. Metadata edits lag by up to 24 h for
  global configurations, and until the owner's next refresh for user-owned ones. The filename carries
  `generated_at`.
- Backfill after first deploy: `CsvExports::RefreshGlobalJob.perform_async` once from a console.

## Testing

Model, registry, row, service, job, component and controller tests under `test/`; E2E under
`e2e/tests/{books,music,games}/…csv-export.spec.ts` (books has anonymous, account and member
variants). `test/lint/stimulus_manifest_test.rb` guards the controller registration.
```

- [ ] **Step 2: Point the user-lists doc at it**

In `docs/features/user-lists.md`, replace the paragraph under `### CSV export` with:

```markdown
`show.csv` streams the list through `CsvExports::UserList` (see `docs/features/csv-exports.md`):
a UTF-8 CSV with a BOM prefix, filename `"#{list.name.parameterize}-#{Date.current.iso8601}.csv"`.
Columns vary per listable (albums/songs: Position, Title, Artists, Year; books: Position, Title,
Authors, Year; games/movies: Position, Title, Year), plus `Completed On` only when
`completed_on_enabled?`. Unpaginated, follows the current sort, and — unlike the rankings and
saved-search exports — never capped: a list is the viewer's own data or data someone made public.
The Download button is `CsvExports::DownloadButtonComponent` with `capped: false` (a plain link).
```

- [ ] **Step 3: Commit**

```bash
git add docs/features/csv-exports.md docs/features/user-lists.md
git commit -m "docs: CSV exports feature doc; user-lists CSV section points at it" -m "Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 22: Full verification

- [ ] **Step 1: Whole suite, lint, no new warnings**

```bash
cd web-app
bin/rails test 2>&1 | tee /tmp/csv-exports-test.log | tail -20
bundle exec standardrb
grep -c "warning" /tmp/csv-exports-test.log
```

Expected: `0 failures, 0 errors`; standardrb clean; the warning count matches a run on `main` (the two known upstream sources only — `weighted_list_rank`'s position `puts` and npm/yarn during `test:prepare`).

- [ ] **Step 2: Manual smoke in the browser (dev server, this worktree on port 3000)**

1. Signed out on `dev-new.thegreatestbooks.org`: click Download CSV → login modal.
2. Signed in as a non-member: click → dialog; "Download top 500" → a 501-line file.
3. Signed in as a member (comp yourself via `Membership.create!(user: User.find_by(email: …), source: :comped, status: :active)` in a console, or `bin/rails e2e:member`): click on `/` → either the file or the preparing page; wait for the `low` queue (Sidekiq must be running: `bundle exec sidekiq`) and refresh → the file, with `generated_at` in its name.
4. Admin → Books → Ranking Configurations → the primary: the CSV Export card shows Ready / rows / size; Regenerate re-queues.
5. `/albums`, `/songs`, `/video-games`, a saved search, and `/my/lists/:id`: button present, download works.

- [ ] **Step 3: Hand off**

Use `superpowers:finishing-a-development-branch`. The PR description should include the timing measured in Task 6 and the one deploy-time step: run `CsvExports::RefreshGlobalJob.perform_async` once after the deploy.
