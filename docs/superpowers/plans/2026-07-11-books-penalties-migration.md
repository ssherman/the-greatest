# Penalties Migration (Phase 2c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate legacy `list_cons` → `penalties` + `penalty_applications` (active RCs only) and `list_con_lists` → `list_penalties` (static only), reusing the seeded `Global::Penalty` taxonomy where it matches and creating `Books::Penalty` records for the rest.

**Architecture:** A pure `PenaltyResolver` decides reuse-global-vs-create-Books per legacy row. Three migrators follow the established `Migrator`/`BulkUpsertMigrator` base classes: `PenaltyMigrator` (per-row, records `LegacyIdMap "Penalty"`), `PenaltyApplicationMigrator` (per-row, find-or-init MAX-points), `ListPenaltyMigrator` (bulk upsert, static targets only). Two new read-only `LegacyBooks::*` models. Wired into `data_migration:all` after `:ranked_lists`.

**Tech Stack:** Rails 8, Minitest + Mocha, Postgres, multi-db read-only replica (`LegacyBooks`).

**Spec:** `docs/superpowers/specs/2026-07-11-books-penalties-migration-design.md` (read it first — it holds the full mapping tables and edge rulings).

## Global Constraints

- Run all commands from `web-app/`.
- Namespaced services live in `app/lib/services/books_migration/`; tests mirror at `test/lib/services/books_migration/`.
- Unit tests **stub `legacy_each`** (via `m.stubs(:legacy_each).multiple_yields(*rows.zip)`) — the legacy DB is never opened in tests. Attribute hashes use **String keys**.
- Migrators return `{success: true, data: {...}}` / `{success: false, error: ...}` — never raise to the caller.
- Legacy dynamic_type integers → new enum labels: `0 number_of_voters`, `1 percentage_western`, `2 voter_names_unknown`, `3 voter_count_unknown`, `4 category_specific`.
- `GLOBAL_ALIASES` (exactly 3): `"List: contains over 500 books(Quantity over Quality)" → "…items…"`, `"List: Creator of the list, sells the books on the list" → "…items…"`, `%q{List: criteria is not just "best/favorite"} → "List: criteria is not just best/favorite"`.
- Lint: `bundle exec standardrb` (NOT rubocop). Security: `bin/brakeman --no-pager`.
- `keyword_init` Result pattern not used here (migrators return plain hashes, matching 2a/2b).

---

### Task 1: Read-only legacy models

**Files:**
- Create: `app/models/legacy_books/list_con.rb`
- Create: `app/models/legacy_books/list_con_list.rb`
- Test: `test/models/legacy_books/record_test.rb` (modify)

**Interfaces:**
- Produces: `LegacyBooks::ListCon` (`table_name = "list_cons"`), `LegacyBooks::ListConList` (`table_name = "list_con_lists"`) — both `< LegacyBooks::Record` (read-only replica).

- [ ] **Step 1: Add failing assertions** to `test/models/legacy_books/record_test.rb`, inside the existing `"legacy models point at the legacy tables"` test:

```ruby
    test "legacy models point at the legacy tables" do
      assert_equal "authors", LegacyBooks::Author.table_name
      assert_equal "languages", LegacyBooks::Language.table_name
      assert_equal "list_cons", LegacyBooks::ListCon.table_name
      assert_equal "list_con_lists", LegacyBooks::ListConList.table_name
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/legacy_books/record_test.rb`
Expected: FAIL with `NameError: uninitialized constant LegacyBooks::ListCon`

- [ ] **Step 3: Create the two models**

`app/models/legacy_books/list_con.rb`:

```ruby
module LegacyBooks
  class ListCon < Record
    self.table_name = "list_cons"
  end
end
```

`app/models/legacy_books/list_con_list.rb`:

```ruby
module LegacyBooks
  class ListConList < Record
    self.table_name = "list_con_lists"
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/legacy_books/record_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/legacy_books/list_con.rb app/models/legacy_books/list_con_list.rb test/models/legacy_books/record_test.rb
git commit -m "Add LegacyBooks::ListCon and ListConList read-only models"
```

---

### Task 2: PenaltyResolver (pure reuse-or-create decision)

**Files:**
- Create: `app/lib/services/books_migration/penalty_resolver.rb`
- Test: `test/lib/services/books_migration/penalty_resolver_test.rb`

**Interfaces:**
- Consumes: `Penalty` records (any STI subclass) supplied as lookup hashes.
- Produces: `PenaltyResolver.new(globals_by_name:, globals_by_dynamic_type:)` with `#call(attrs)` returning `[:reuse, <Penalty>]` or `[:create_books, {name: String, dynamic_type: String|nil}]`. `attrs` has String keys `"name"`, `"dynamic_type"` (Integer|nil). Raises `KeyError` if a legacy `dynamic_type` has no seeded global (except `percentage_western`, which always creates). `globals_by_dynamic_type` is keyed by the enum **label string** (`"number_of_voters"` etc.).
- Constants: `PenaltyResolver::LEGACY_DYNAMIC_TYPE` (Integer→label), `PenaltyResolver::GLOBAL_ALIASES` (legacy name→global name).

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/penalty_resolver_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::PenaltyResolverTest < ActiveSupport::TestCase
  R = Services::BooksMigration::PenaltyResolver

  def globals
    [
      Global::Penalty.new(name: "Voters: Voter Count", dynamic_type: :number_of_voters),
      Global::Penalty.new(name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown),
      Global::Penalty.new(name: "List: only covers 1 specific genre", dynamic_type: :category_specific),
      Global::Penalty.new(name: "Voters: not critics, authors, or experts", dynamic_type: nil),
      Global::Penalty.new(name: "List: contains over 500 items(Quantity over Quality)", dynamic_type: nil)
    ]
  end

  def resolver
    R.new(
      globals_by_name: globals.index_by(&:name),
      globals_by_dynamic_type: globals.select(&:dynamic_type).index_by(&:dynamic_type)
    )
  end

  def lc(overrides = {})
    {"name" => "x", "dynamic_type" => nil}.merge(overrides)
  end

  test "dynamic type maps to the seeded global by dynamic_type, ignoring the legacy name" do
    strategy, penalty = resolver.call(lc("name" => "Voters: Voter names unknown", "dynamic_type" => 3))
    assert_equal :reuse, strategy
    assert_equal "Voters: Unknown Count", penalty.name
  end

  test "dynamic type 0 maps to number_of_voters global" do
    _, penalty = resolver.call(lc("name" => "Voters: Voter Count", "dynamic_type" => 0))
    assert_equal "Voters: Voter Count", penalty.name
  end

  test "percentage_western (type 1) always creates a Books penalty" do
    strategy, payload = resolver.call(lc("name" => %q{List: only covers mostly "Western Canon" books}, "dynamic_type" => 1))
    assert_equal :create_books, strategy
    assert_equal %q{List: only covers mostly "Western Canon" books}, payload[:name]
    assert_equal "percentage_western", payload[:dynamic_type]
  end

  test "static exact name match reuses the global" do
    strategy, penalty = resolver.call(lc("name" => "Voters: not critics, authors, or experts", "dynamic_type" => nil))
    assert_equal :reuse, strategy
    assert_equal "Voters: not critics, authors, or experts", penalty.name
  end

  test "static alias (books to items) reuses the normalized global" do
    strategy, penalty = resolver.call(lc("name" => "List: contains over 500 books(Quantity over Quality)", "dynamic_type" => nil))
    assert_equal :reuse, strategy
    assert_equal "List: contains over 500 items(Quantity over Quality)", penalty.name
  end

  test "unmatched static creates a Books penalty with nil dynamic_type" do
    strategy, payload = resolver.call(lc("name" => "List: only covers 75 years", "dynamic_type" => nil))
    assert_equal :create_books, strategy
    assert_equal "List: only covers 75 years", payload[:name]
    assert_nil payload[:dynamic_type]
  end

  test "raises when a dynamic type has no seeded global" do
    bare = R.new(globals_by_name: {}, globals_by_dynamic_type: {})
    assert_raises(KeyError) { bare.call(lc("dynamic_type" => 0)) }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/penalty_resolver_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::PenaltyResolver`

- [ ] **Step 3: Write the implementation**

`app/lib/services/books_migration/penalty_resolver.rb`:

```ruby
module Services
  module BooksMigration
    # Pure decision: legacy list_con attrs -> reuse an existing Global::Penalty or
    # create a Books::Penalty. Dynamic list_cons resolve by dynamic_type (the legacy
    # name is ignored — it can be mistyped); percentage_western has no seeded global
    # (owner: book-specific) so it always creates. Static list_cons reuse a Global by
    # exact name or via GLOBAL_ALIASES (books->items / quote-only rewrites), else create.
    class PenaltyResolver
      LEGACY_DYNAMIC_TYPE = {
        0 => "number_of_voters",
        1 => "percentage_western",
        2 => "voter_names_unknown",
        3 => "voter_count_unknown",
        4 => "category_specific"
      }.freeze

      GLOBAL_ALIASES = {
        "List: contains over 500 books(Quantity over Quality)" => "List: contains over 500 items(Quantity over Quality)",
        "List: Creator of the list, sells the books on the list" => "List: Creator of the list, sells the items on the list",
        %q{List: criteria is not just "best/favorite"} => "List: criteria is not just best/favorite"
      }.freeze

      def initialize(globals_by_name:, globals_by_dynamic_type:)
        @globals_by_name = globals_by_name
        @globals_by_dynamic_type = globals_by_dynamic_type
      end

      def call(attrs)
        dynamic_type = attrs["dynamic_type"]
        name = attrs["name"]

        if dynamic_type
          label = LEGACY_DYNAMIC_TYPE.fetch(dynamic_type)
          return [:create_books, {name: name, dynamic_type: "percentage_western"}] if label == "percentage_western"
          [:reuse, @globals_by_dynamic_type.fetch(label)]
        else
          global = @globals_by_name[GLOBAL_ALIASES.fetch(name, name)]
          global ? [:reuse, global] : [:create_books, {name: name, dynamic_type: nil}]
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/penalty_resolver_test.rb`
Expected: PASS (7 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/penalty_resolver.rb test/lib/services/books_migration/penalty_resolver_test.rb
git commit -m "Add PenaltyResolver (reuse-global-or-create-Books decision)"
```

---

### Task 3: PenaltyMigrator (list_cons → penalties + LegacyIdMap "Penalty")

**Files:**
- Create: `app/lib/services/books_migration/penalty_migrator.rb`
- Test: `test/lib/services/books_migration/penalty_migrator_test.rb`

**Interfaces:**
- Consumes: `PenaltyResolver`; `LegacyIdMap` model `"Books::RankingConfiguration"` (to scope active RCs); seeded `Global::Penalty` rows.
- Produces: `Penalty` rows (reused globals untouched; new `Books::Penalty` created) and `LegacyIdMap` model `"Penalty"` (`list_con.id → penalty.id`, many-to-one). Class method `Services::BooksMigration::PenaltyMigrator.call`.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/penalty_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::PenaltyMigratorTest < ActiveSupport::TestCase
  MODEL_KEY = "Penalty"

  setup do
    @voter_count = Global::Penalty.create!(name: "Voters: Voter Count", dynamic_type: :number_of_voters)
    @not_critics = Global::Penalty.create!(name: "Voters: not critics, authors, or experts")
    LegacyIdMap.record(model: "Books::RankingConfiguration", legacy_id: 48, new_id: 999_048)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::PenaltyMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "name" => "List: only covers 75 years",
      "points" => 20,
      "description" => "legacy desc #{id}",
      "ranking_configuration_id" => 48,
      "dynamic" => false,
      "dynamic_type" => nil,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  def mapped(legacy_id)
    Penalty.find(LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: legacy_id))
  end

  test "creates a Books::Penalty for an unmatched static list_con, verbatim name + preserved fields" do
    assert_difference -> { Books::Penalty.count }, 1 do
      result = run_migrator([legacy(8001)])
      assert result[:success], result[:error]
    end
    penalty = mapped(8001)
    assert_equal "Books::Penalty", penalty.type
    assert_equal "List: only covers 75 years", penalty.name
    assert_nil penalty.dynamic_type
    assert_nil penalty.user_id
    assert_equal "legacy desc 8001", penalty.description
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), penalty.created_at
  end

  test "reuses an existing Global::Penalty by exact static name without creating or mutating it" do
    assert_no_difference -> { Penalty.count } do
      run_migrator([legacy(8002, "name" => "Voters: not critics, authors, or experts")])
    end
    assert_equal @not_critics.id, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8002)
  end

  test "reuses the number_of_voters global for a dynamic_type 0 list_con" do
    run_migrator([legacy(8003, "name" => "Voters: Voter Count", "dynamic_type" => 0)])
    assert_equal @voter_count.id, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8003)
  end

  test "creates the percentage_western Books::Penalty for dynamic_type 1" do
    run_migrator([legacy(8004, "name" => %q{List: only covers mostly "Western Canon" books}, "dynamic_type" => 1)])
    penalty = mapped(8004)
    assert_equal "Books::Penalty", penalty.type
    assert_equal "percentage_western", penalty.dynamic_type
  end

  test "records the map for every active-RC list_con" do
    run_migrator([legacy(8005), legacy(8006, "name" => "List: honorable mention")])
    assert_not_nil LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8005)
    assert_not_nil LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8006)
  end

  test "is idempotent: re-running reuses the same Books::Penalty and keeps the map" do
    run_migrator([legacy(8007)])
    first = LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8007)
    assert_no_difference -> { Penalty.count } do
      run_migrator([legacy(8007)])
    end
    assert_equal first, LegacyIdMap.lookup(model: MODEL_KEY, legacy_id: 8007)
  end

  test "suppresses search indexing during the load" do
    assert_no_difference -> { SearchIndexRequest.count } do
      run_migrator([legacy(8008)])
    end
  end

  test "fails loud when no ranking configuration has been migrated" do
    LegacyIdMap.where(model: "Books::RankingConfiguration").delete_all
    result = Services::BooksMigration::PenaltyMigrator.new.call
    refute result[:success]
    assert_match(/ranking_configuration/, result[:error])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/penalty_migrator_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::PenaltyMigrator`

- [ ] **Step 3: Write the implementation**

`app/lib/services/books_migration/penalty_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `list_cons` (active RCs only) -> penalties, recording LegacyIdMap "Penalty"
    # (list_con.id -> penalty.id, many-to-one). PenaltyResolver decides reuse-global vs
    # create-Books; created Books::Penalty rows keep the legacy name/description/timestamps
    # (first-writer-wins via find_or_create_by across RCs). Scoped to whatever RCs 2b
    # migrated (the "Books::RankingConfiguration" map) — raises if that map is empty.
    class PenaltyMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListCon
      end

      def model_key
        "Penalty"
      end

      def legacy_each(&block)
        ids = active_rc_legacy_ids
        legacy_model.where(ranking_configuration_id: ids).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def upsert_row(attrs)
        strategy, payload = resolver.call(attrs)
        penalty =
          case strategy
          when :reuse
            payload
          when :create_books
            Books::Penalty.find_or_create_by!(name: payload[:name], user_id: nil) do |p|
              p.dynamic_type = payload[:dynamic_type]
              p.description = attrs["description"]
              p.created_at = attrs["created_at"]
              p.updated_at = attrs["updated_at"]
            end
          end
        LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: penalty.id)
      end

      def active_rc_legacy_ids
        @active_rc_legacy_ids ||= begin
          ids = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id)
          raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if ids.empty?
          ids
        end
      end

      def resolver
        @resolver ||= begin
          globals = Penalty.where(type: "Global::Penalty").to_a
          PenaltyResolver.new(
            globals_by_name: globals.index_by(&:name),
            globals_by_dynamic_type: globals.select(&:dynamic_type).index_by(&:dynamic_type)
          )
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/penalty_migrator_test.rb`
Expected: PASS (8 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/penalty_migrator.rb test/lib/services/books_migration/penalty_migrator_test.rb
git commit -m "Add PenaltyMigrator (list_cons -> penalties + Penalty id map)"
```

---

### Task 4: PenaltyApplicationMigrator (list_cons → penalty_applications, MAX-points)

**Files:**
- Create: `app/lib/services/books_migration/penalty_application_migrator.rb`
- Test: `test/lib/services/books_migration/penalty_application_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyIdMap` models `"Penalty"` (list_con→penalty) and `"Books::RankingConfiguration"` (legacy rc→new rc).
- Produces: `penalty_application` rows keyed `[penalty_id, ranking_configuration_id]`, `value = MAX(points)` on collision. Class method `.call`. Records no id map.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/penalty_application_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::PenaltyApplicationMigratorTest < ActiveSupport::TestCase
  setup do
    @rc = Books::RankingConfiguration.create!(name: "PA Config")
    @penalty = Global::Penalty.create!(name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown)
    LegacyIdMap.record(model: "Books::RankingConfiguration", legacy_id: 52, new_id: @rc.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 700, new_id: @penalty.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 701, new_id: @penalty.id)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::PenaltyApplicationMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy(id, overrides = {})
    {
      "id" => id,
      "points" => 30,
      "ranking_configuration_id" => 52,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  test "creates a penalty_application mapping penalty + rc, value from points" do
    result = run_migrator([legacy(700)])
    assert result[:success], result[:error]
    pa = PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id)
    assert_equal 30, pa.value
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), pa.created_at
  end

  test "keeps the MAX points on a [penalty, rc] collision" do
    assert_difference -> { PenaltyApplication.count }, 1 do
      run_migrator([legacy(700, "points" => 5), legacy(701, "points" => 85)])
    end
    pa = PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id)
    assert_equal 85, pa.value
  end

  test "MAX is order-independent" do
    run_migrator([legacy(700, "points" => 85), legacy(701, "points" => 5)])
    assert_equal 85, PenaltyApplication.find_by(penalty_id: @penalty.id, ranking_configuration_id: @rc.id).value
  end

  test "is idempotent on [penalty_id, ranking_configuration_id]" do
    run_migrator([legacy(700, "points" => 40)])
    assert_no_difference -> { PenaltyApplication.count } do
      run_migrator([legacy(700, "points" => 40)])
    end
  end

  test "fails loud when the penalty map is empty" do
    LegacyIdMap.where(model: "Penalty").delete_all
    result = run_migrator([legacy(700)])
    refute result[:success]
    assert_match(/penalt/i, result[:error])
  end

  test "fails loud when the ranking configuration map is empty" do
    LegacyIdMap.where(model: "Books::RankingConfiguration").delete_all
    result = run_migrator([legacy(700)])
    refute result[:success]
    assert_match(/ranking_configuration/, result[:error])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/penalty_application_migrator_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::PenaltyApplicationMigrator`

- [ ] **Step 3: Write the implementation**

`app/lib/services/books_migration/penalty_application_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `list_cons` (active RCs) -> penalty_applications. penalty_id via the
    # "Penalty" map, ranking_configuration_id via the "Books::RankingConfiguration" map,
    # value = list_con.points. Per-row find_or_initialize + value = MAX(existing, points)
    # gives both the [penalty, rc] collision rule (one legacy pair: RC52) and idempotency
    # without an upsert_all "affect row twice" hazard. Records no id map (join table).
    class PenaltyApplicationMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListCon
      end

      def model_key
        "PenaltyApplication"
      end

      def legacy_each(&block)
        legacy_model.where(ranking_configuration_id: rc_map.keys).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def upsert_row(attrs)
        penalty_id = penalty_map.fetch(attrs["id"])
        rc_id = rc_map.fetch(attrs["ranking_configuration_id"])
        pa = PenaltyApplication.find_or_initialize_by(penalty_id: penalty_id, ranking_configuration_id: rc_id)
        pa.value = [pa.value || 0, attrs["points"]].max
        pa.created_at = attrs["created_at"] if pa.new_record?
        pa.updated_at = attrs["updated_at"]
        pa.save!
      end

      def penalty_map
        @penalty_map ||= begin
          map = LegacyIdMap.where(model: "Penalty").pluck(:legacy_id, :new_id).to_h
          raise "no migrated penalties; run data_migration:penalties first" if map.empty?
          map
        end
      end

      def rc_map
        @rc_map ||= begin
          map = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id, :new_id).to_h
          raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if map.empty?
          map
        end
      end
    end
  end
end
```

Note: the penalty-map-empty test stubs `legacy_each` (so `rc_map` is not touched there) and `upsert_row` hits `penalty_map.fetch` first; the rc-map-empty test's stubbed `legacy_each` skips `rc_map.keys`, so `rc_map` raises inside `upsert_row` (penalty map present).

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/penalty_application_migrator_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/penalty_application_migrator.rb test/lib/services/books_migration/penalty_application_migrator_test.rb
git commit -m "Add PenaltyApplicationMigrator (list_cons -> penalty_applications, MAX points)"
```

---

### Task 5: ListPenaltyMigrator (list_con_lists → list_penalties, static only)

**Files:**
- Create: `app/lib/services/books_migration/list_penalty_migrator.rb`
- Test: `test/lib/services/books_migration/list_penalty_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyIdMap` model `"Penalty"`; `Penalty.static`; `Books::List` id set. In the real run, `legacy_each` joins `list_con_lists → ranked_lists` for `list_id`; tests stub `legacy_each` and yield the already-joined hash (`"id"`, `"list_con_id"`, `"list_id"`, timestamps).
- Produces: `list_penalty` rows keyed `[list_id, penalty_id]`, static-target only, deduped in-memory. Class method `.call`.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books_migration/list_penalty_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::ListPenaltyMigratorTest < ActiveSupport::TestCase
  setup do
    @list = Books::List.create!(name: "LP List")
    @static_penalty = Global::Penalty.create!(name: "Voters: not critics, authors, or experts")
    @dynamic_penalty = Global::Penalty.create!(name: "Voters: Voter Count", dynamic_type: :number_of_voters)
    LegacyIdMap.record(model: "Penalty", legacy_id: 500, new_id: @static_penalty.id)
    LegacyIdMap.record(model: "Penalty", legacy_id: 501, new_id: @dynamic_penalty.id)
  end

  def run_migrator(rows)
    m = Services::BooksMigration::ListPenaltyMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def lcl(id, overrides = {})
    {
      "id" => id,
      "list_con_id" => 500,
      "list_id" => @list.id,
      "created_at" => Time.utc(2020, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2021, 2, 3, 4, 5, 6)
    }.merge(overrides)
  end

  test "creates a list_penalty for a static-target list_con_list" do
    result = run_migrator([lcl(1)])
    assert result[:success], result[:error]
    lp = ListPenalty.find_by(list_id: @list.id, penalty_id: @static_penalty.id)
    assert_not_nil lp
    assert_equal Time.utc(2020, 1, 2, 3, 4, 5), lp.created_at
  end

  test "skips a dynamic-target list_con_list" do
    assert_no_difference -> { ListPenalty.count } do
      run_migrator([lcl(2, "list_con_id" => 501)])
    end
  end

  test "dedups repeated [list_id, penalty_id] pairs" do
    assert_difference -> { ListPenalty.count }, 1 do
      run_migrator([lcl(3), lcl(4)])
    end
  end

  test "fails loud when the list is not a migrated Books::List" do
    missing = List.maximum(:id).to_i + 999_999
    result = run_migrator([lcl(5, "list_id" => missing)])
    refute result[:success]
    assert_match(/5/, result[:error])
  end

  test "is idempotent on [list_id, penalty_id]" do
    run_migrator([lcl(6)])
    assert_no_difference -> { ListPenalty.count } do
      run_migrator([lcl(6)])
    end
  end

  test "fails loud when no penalties have been migrated" do
    LegacyIdMap.where(model: "Penalty").delete_all
    result = run_migrator([lcl(7)])
    refute result[:success]
    assert_match(/penalt/i, result[:error])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/list_penalty_migrator_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::BooksMigration::ListPenaltyMigrator`

- [ ] **Step 3: Write the implementation**

`app/lib/services/books_migration/list_penalty_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `list_con_lists` -> list_penalties, STATIC-target list_cons only (ListPenalty
    # forbids dynamic penalties; dynamic-side + genre-static->dynamic-global rows drop).
    # list_id comes from ranked_lists (joined in legacy_each; lists preserve their id, so
    # it is the Books::List id directly) -> fail-loud if not a migrated Books::List.
    # penalty_id via the "Penalty" map. Deduped in-memory on [list_id, penalty_id] because
    # two ranked_lists can map the same penalty onto the same list and upsert_all cannot
    # touch a conflict key twice in one statement. Idempotent on the target unique index.
    class ListPenaltyMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::ListConList
      end

      def model_key
        "ListPenalty"
      end

      def target_model
        ListPenalty
      end

      def unique_by
        :index_list_penalties_on_list_and_penalty
      end

      def record_timestamps?
        false
      end

      def preload_context
        @penalty_map = LegacyIdMap.where(model: "Penalty").pluck(:legacy_id, :new_id).to_h
        raise "no migrated penalties; run data_migration:penalties first" if @penalty_map.empty?
        static_penalty_ids = Penalty.static.pluck(:id).to_set
        @static_list_con_ids = @penalty_map.select { |_legacy_id, new_id| static_penalty_ids.include?(new_id) }.keys
        @list_ids = Books::List.pluck(:id).to_set
        @seen = Set.new
      end

      def legacy_each(&block)
        LegacyBooks::ListConList
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .where(list_con_id: @static_list_con_ids)
          .select("list_con_lists.id, list_con_lists.list_con_id, list_con_lists.created_at, list_con_lists.updated_at, ranked_lists.list_id AS list_id")
          .find_each(batch_size: BATCH_SIZE) do |record|
            block.call(
              "id" => record.id,
              "list_con_id" => record.list_con_id,
              "list_id" => record.list_id,
              "created_at" => record.created_at,
              "updated_at" => record.updated_at
            )
          end
      end

      def build_rows(attrs)
        penalty_id = @penalty_map.fetch(attrs["list_con_id"])
        list_id = attrs["list_id"]
        unless @list_ids.include?(list_id)
          raise "no migrated Books::List for legacy list_con_lists.list_id=#{list_id.inspect} (list_con_list id=#{attrs["id"]})"
        end

        key = [list_id, penalty_id]
        return [] if @seen.include?(key)
        @seen << key

        [{
          list_id: list_id,
          penalty_id: penalty_id,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/list_penalty_migrator_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books_migration/list_penalty_migrator.rb test/lib/services/books_migration/list_penalty_migrator_test.rb
git commit -m "Add ListPenaltyMigrator (list_con_lists -> list_penalties, static only)"
```

---

### Task 6: Rake orchestration

**Files:**
- Modify: `lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: all four migrators from Tasks 3–5.
- Produces: `data_migration:penalties`, `data_migration:list_penalties`, appended to `data_migration:all` after `:ranked_lists`.

- [ ] **Step 1: Add the two tasks** before the `all` task in `lib/tasks/data_migration.rake`:

```ruby
  desc "Migrate legacy list_cons into penalties + penalty_applications (active RCs; reuse Global seeds)"
  task penalties: :environment do
    pp Services::BooksMigration::PenaltyMigrator.call
    pp Services::BooksMigration::PenaltyApplicationMigrator.call
  end

  desc "Migrate legacy list_con_lists into list_penalties (static penalties only)"
  task list_penalties: :environment do
    pp Services::BooksMigration::ListPenaltyMigrator.call
  end
```

- [ ] **Step 2: Extend the `all` task** dependency list (append `:penalties, :list_penalties` after `:ranked_lists`):

```ruby
  desc "Run all Phase-1 migrators in dependency order"
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links, :lists, :list_items, :ranking_configurations, :ranked_lists, :penalties, :list_penalties]
```

- [ ] **Step 3: Verify the tasks load** (no legacy DB call — just confirms wiring parses)

Run: `bin/rails -T data_migration`
Expected: output includes `data_migration:penalties` and `data_migration:list_penalties`.

- [ ] **Step 4: Commit**

```bash
git add lib/tasks/data_migration.rake
git commit -m "Wire penalties + list_penalties into data_migration orchestrator"
```

---

### Task 7: Full-suite gate, lint, and e2e verification against the real legacy DB

**Files:** none (verification only; the design doc is the record).

**Interfaces:** Consumes the merged 2b baseline dev DB (lists, ranked_lists, ranking_configurations migrated) + the real legacy `the_greatest_books` connection.

- [ ] **Step 1: Run the full migration test suite**

Run: `bin/rails test test/lib/services/books_migration/ test/models/legacy_books/`
Expected: all green (0 failures, 0 errors).

- [ ] **Step 2: Run the whole suite**

Run: `bin/rails test`
Expected: green (no regressions vs the ~4,473 baseline).

- [ ] **Step 3: Lint + security**

Run: `bundle exec standardrb && bin/brakeman --no-pager`
Expected: standardrb clean; brakeman 0 new warnings.

- [ ] **Step 4: E2e run against the real legacy DB** (dev DB already at the 2b baseline). Run each task twice to prove idempotency, capturing counts before/after:

Run:
```bash
bin/rails runner '
  pp Services::BooksMigration::PenaltyMigrator.call
  pp Services::BooksMigration::PenaltyApplicationMigrator.call
  pp Services::BooksMigration::ListPenaltyMigrator.call
'
bin/rails runner '
  pp Services::BooksMigration::PenaltyMigrator.call
  pp Services::BooksMigration::PenaltyApplicationMigrator.call
  pp Services::BooksMigration::ListPenaltyMigrator.call
'
```
Expected: every call `{success: true, ...}`; second run reports the same/no-growth counts.

- [ ] **Step 5: Assert the exact target state** (values from the spec's E2e section):

Run:
```bash
bin/rails runner '
  puts "penalties total: #{Penalty.count} (expect 49)"
  puts "new Books::Penalty: #{Books::Penalty.count} (expect 29: 28 static + 1 percentage_western)"
  puts "  static Books: #{Books::Penalty.static.count} (expect 28)"
  puts "  percentage_western Books: #{Books::Penalty.where(dynamic_type: :percentage_western).count} (expect 1)"
  puts "new Global::Penalty: #{Global::Penalty.count} (expect 19 — unchanged, none created)"
  puts "Penalty id map rows: #{LegacyIdMap.where(model: %q{Penalty}).count} (expect 78)"
  puts "penalty_applications: #{PenaltyApplication.count} (expect 126 = 49 pre + 77)"
  rc52 = RankingConfiguration.find(LegacyIdMap.lookup(model: %q{Books::RankingConfiguration}, legacy_id: 52))
  vcu = Global::Penalty.find_by(name: %q{Voters: Unknown Count})
  puts "RC52 x Unknown Count value: #{PenaltyApplication.find_by(ranking_configuration_id: rc52.id, penalty_id: vcu.id)&.value} (expect 85 — MAX)"
  puts "list_penalties: #{ListPenalty.count} (expect 1192 = 82 pre + 1110)"
  puts "list_penalties on dynamic penalties: #{ListPenalty.joins(:penalty).where.not(penalties: {dynamic_type: nil}).count} (expect 0)"
'
```
Expected: every line matches its `(expect …)`.

- [ ] **Step 6: Final commit** (if any lint autofixes were applied in Step 3; otherwise skip)

```bash
git commit -am "standardrb autofixes for penalties migration"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** dynamic→global-by-type (Task 2/3), percentage_western→Books (Task 2/3), static exact+alias reuse (Task 2), unmatched static→Books verbatim (Task 3), points→value with MAX collision (Task 4), list_con_lists→list_penalties static-only with drop (Task 5), Penalty id map (Task 3), fail-loud dependency guards (Tasks 3–5), orchestration order (Task 6), exact e2e counts 49/77/1110 + idempotency (Task 7). All covered.

**Placeholder scan:** none — every step has runnable code/commands.

**Type consistency:** `PenaltyResolver#call → [:reuse, Penalty] | [:create_books, {name:, dynamic_type:}]` consumed identically in `PenaltyMigrator#upsert_row`. `LegacyIdMap` model keys `"Penalty"` / `"Books::RankingConfiguration"` consistent across Tasks 3–5. `unique_by` names match schema (`index_list_penalties_on_list_and_penalty`). Migrator return-hash shape matches base classes.
