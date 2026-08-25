# Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy site's `changesets` feature with a domain-agnostic corrections subsystem — a public correction form on each record's page, an admin review/apply queue, an owner email per submission, and a migration of the 448 legacy changesets.

**Architecture:** One shared polymorphic `Correction` with child `CorrectionField` rows, on the same contract pattern as `Reviewable` and `Describable`. Each correctable model declares its own field allowlist via `correctable_field`. Type strings from requests resolve through `Admin::DomainRouting::ENTITIES`, never `constantize`. Books is wired first; music and games are a config change at the end.

**Tech Stack:** Rails 8.1, Postgres, Minitest + fixtures + Mocha, Pagy, Pundit-adjacent domain-role auth, Stimulus + Turbo, DaisyUI 5 on Tailwind 4, Sidekiq, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-25-corrections-design.md`

## Global Constraints

- **Working directory is `web-app/`** for every Rails and yarn command. Docs live in `docs/` at the project root, not `web-app/docs/`.
- **Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/corrections`, branch `corrections`.
- **Root-anchor `::Books::Book` inside every `Services::Corrections::*` file.** `Services::Books` exists (`app/lib/services/books/`), so a bare `Books::Book` written inside `Services::Corrections::Applier` resolves to `Services::Books::Book` and raises `NameError`. This exact shadowing broke 95 tests once already. Same rule for `::Description`, `::Correction`, `::User`.
- **Use Rails generators** — never hand-create models, controllers, or migrations. Generators create the matching test file.
- **Rails 8 enum syntax:** `enum :status, {pending: 0}` — colon prefix, never `enum status: {...}`.
- **Services use the Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. `keyword_init` is deliberate; a Standard cop is disabled for it.
- **Linter is `bundle exec standardrb`**, not `bin/rubocop`. Do not run brakeman.
- **DaisyUI 5:** `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed` were removed in v5 and fail silently. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`/`textarea`/`checkbox`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is to remove the class, never to add an allowlist entry.
- **Minitest 6:** `assert_equal nil, x` is a hard failure — use `assert_nil`. No `assert_send`, no `minitest/mock`, no `MiniTest` namespace.
- **Fixture names are semantic** (`regular_user`, `war_and_peace`). Check `test/fixtures/` before referencing. Never run `create_fixtures` — it TRUNCATES.
- **Never run a destructive command against the development database.** Books data exists only in dev and takes hours to rebuild.
- **Every new user-facing page/flow needs a Playwright E2E test** in `web-app/e2e/tests/`.
- **A clean `bin/rails test` emits no warnings** beyond `weighted_list_rank`'s position `puts` and npm/yarn during `test:prepare`. A new warning line is a regression.
- **After adding `app/lib/services/corrections/`, run `CI=1 bin/rails zeitwerk:check`** — `eager_load` is off in test, so a green suite does not prove Zeitwerk can boot.
- **Before trusting any new test, delete the line under test and watch it go red.** `assert_empty` on an empty result passes against deleted code; this has cost this repo 7 false-green tests before.
- **Commit after every task.** Do not push or open a PR without asking.

---

## File Structure

**New — contract and value layer** (`app/lib/services/corrections/`, all one namespace to avoid sibling shadowing):
- `type_registry.rb` — resolves a request's type string through `Admin::DomainRouting::ENTITIES`
- `value_caster.rb` — casts a submitted value to a declared type
- `targets/column.rb` — read/write a plain column
- `targets/primary_description.rb` — read/write the record's preferred `Description`
- `targets.rb` — maps a target symbol to its class
- `submission.rb` — builds a `Correction` from submitted params
- `applier.rb` — writes accepted fields to the record

**New — models:**
- `app/models/correction.rb`, `app/models/correction_field.rb`
- `app/models/concerns/correctable.rb`

**New — controllers:**
- `app/controllers/corrections_controller.rb` (public, shared across domains)
- `app/controllers/correction_token_controller.rb` (uncached CSRF token)
- `app/controllers/admin/corrections_controller.rb` (admin, shared across domains)
- `app/controllers/concerns/visitor_ip.rb` (extracted from `MembershipController`)

**New — views, JS, mailer, migration:**
- `app/views/corrections/new.html.erb`
- `app/views/admin/corrections/{index,show}.html.erb` + partials
- `app/javascript/controllers/corrections/form_controller.js`
- `app/views/admin_mailer/new_correction.{html,text}.erb`
- `app/models/legacy_books/changeset.rb`
- `app/lib/services/books_migration/correction_migrator.rb`

**Modified:**
- `app/models/books/book.rb` — `include Correctable` + seven field declarations + `correction_applied` hook
- `app/lib/admin/domain_nav.rb` — sidebar entry
- `config/routes.rb` — public route, token route, admin routes
- `public/robots.txt` — disallow the correction path
- `app/views/books/books/show.html.erb` — the "Suggest a correction" link
- `app/mailers/admin_mailer.rb` — `new_correction`
- `app/controllers/membership_controller.rb` — use the extracted `VisitorIp`
- `app/javascript/manifests/books_web.js` — register the Stimulus controller
- `lib/tasks/data_migration.rake` — `corrections` task, wired into `:all`

---

## Task 1: Schema and the two models

**Files:**
- Create: `db/migrate/<ts>_create_corrections.rb`, `db/migrate/<ts>_create_correction_fields.rb`
- Create: `app/models/correction.rb`, `app/models/correction_field.rb`
- Create: `test/fixtures/corrections.yml`, `test/fixtures/correction_fields.yml`
- Test: `test/models/correction_test.rb`, `test/models/correction_field_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Correction` with `status` enum `{pending: 0, resolved: 1, rejected: 2}`, associations `correctable` (polymorphic), `user`, `resolved_by`, `correction_fields`, constant `Correction::MAX_NOTES_LENGTH = 10_000`. `CorrectionField` with `status` enum `{pending: 0, applied: 1, rejected: 2}`, association `correction`, columns `field_name`, `old_value`, `new_value`, `applied_at`.

- [ ] **Step 1: Generate the models**

```bash
cd web-app
bin/rails generate model Correction correctable:references{polymorphic} user:references notes:text status:integer resolved_by:references resolved_at:datetime resolution_notes:text submitter_ip:string
bin/rails generate model CorrectionField correction:references field_name:string old_value:jsonb new_value:jsonb status:integer applied_at:datetime
```

- [ ] **Step 2: Edit the migrations to their final shape**

`create_corrections`:

```ruby
class CreateCorrections < ActiveRecord::Migration[8.1]
  def change
    create_table :corrections do |t|
      t.references :correctable, polymorphic: true, null: false
      t.references :user, null: true, foreign_key: true
      t.references :resolved_by, null: true, foreign_key: {to_table: :users}
      t.text :notes
      t.integer :status, null: false, default: 0
      t.datetime :resolved_at
      t.text :resolution_notes
      t.string :submitter_ip

      t.timestamps
    end

    # Backs the admin queue: "pending corrections for this domain's types,
    # newest first" is every index page load.
    add_index :corrections, [:status, :created_at]
  end
end
```

`create_correction_fields`:

```ruby
class CreateCorrectionFields < ActiveRecord::Migration[8.1]
  def change
    create_table :correction_fields do |t|
      t.references :correction, null: false, foreign_key: true
      t.string :field_name, null: false
      t.jsonb :old_value
      t.jsonb :new_value
      t.integer :status, null: false, default: 0
      t.datetime :applied_at

      t.timestamps
    end

    # One proposal per field per correction. The submission service already
    # dedupes, but a unique index is what makes that true rather than hoped.
    add_index :correction_fields, [:correction_id, :field_name], unique: true
  end
end
```

- [ ] **Step 3: Run the migrations**

```bash
cd web-app
bin/rails db:migrate
```

Expected: two `create_table` lines, schema version advances.

- [ ] **Step 4: Write the failing model tests**

`test/models/correction_test.rb`:

```ruby
require "test_helper"

class CorrectionTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @user = users(:regular_user)
  end

  test "is valid with notes and no fields" do
    correction = Correction.new(correctable: @book, user: @user, notes: "The year is wrong")
    assert_predicate correction, :valid?
  end

  test "is valid anonymously" do
    correction = Correction.new(correctable: @book, user: nil, notes: "The year is wrong")
    assert_predicate correction, :valid?
  end

  test "is invalid with neither notes nor fields" do
    correction = Correction.new(correctable: @book, notes: nil)
    assert_not correction.valid?
    assert_includes correction.errors[:base].join, "Tell us what's wrong"
  end

  test "is valid with a field and no notes" do
    correction = Correction.new(correctable: @book, notes: nil)
    correction.correction_fields.build(field_name: "title", old_value: "War and Peace", new_value: "War & Peace")
    assert_predicate correction, :valid?
  end

  test "rejects notes longer than the cap" do
    correction = Correction.new(correctable: @book, notes: "x" * (Correction::MAX_NOTES_LENGTH + 1))
    assert_not correction.valid?
    assert_includes correction.errors[:notes].join, "too long"
  end

  test "normalizes blank notes to nil" do
    correction = Correction.new(correctable: @book, notes: "   ")
    correction.correction_fields.build(field_name: "title", old_value: "a", new_value: "b")
    correction.validate
    assert_nil correction.notes
  end

  test "defaults to pending" do
    assert_predicate Correction.new, :pending?
  end
end
```

`test/models/correction_field_test.rb`:

```ruby
require "test_helper"

class CorrectionFieldTest < ActiveSupport::TestCase
  setup do
    @correction = corrections(:war_and_peace_pending)
  end

  test "defaults to pending" do
    assert_predicate CorrectionField.new, :pending?
  end

  test "requires a field name" do
    field = CorrectionField.new(correction: @correction, field_name: nil)
    assert_not field.valid?
    assert_includes field.errors[:field_name].join, "can't be blank"
  end

  test "rejects a second row for the same field on one correction" do
    existing = @correction.correction_fields.first
    duplicate = CorrectionField.new(correction: @correction, field_name: existing.field_name,
      old_value: "x", new_value: "y")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:field_name].join, "has already been taken"
  end

  test "round-trips an array through new_value" do
    field = CorrectionField.create!(correction: @correction, field_name: "alternate_titles",
      old_value: [], new_value: ["Voyna i mir", "War & Peace"])
    assert_equal ["Voyna i mir", "War & Peace"], field.reload.new_value
  end

  test "round-trips an integer through new_value" do
    field = CorrectionField.create!(correction: @correction, field_name: "first_published_year",
      old_value: 1869, new_value: 1867)
    assert_equal 1867, field.reload.new_value
  end
end
```

- [ ] **Step 5: Write the fixtures**

`test/fixtures/corrections.yml`:

```yaml
war_and_peace_pending:
  correctable: war_and_peace (Books::Book)
  user: regular_user
  notes: The first published year looks wrong to me.
  status: 0

war_and_peace_notes_only:
  correctable: war_and_peace (Books::Book)
  user:
  notes: The author is listed incorrectly.
  status: 0
  submitter_ip: 203.0.113.7

crime_resolved:
  correctable: crime_and_punishment (Books::Book)
  user: regular_user
  notes: Fixed the subtitle.
  status: 1
  resolved_by: admin_user
  resolved_at: <%= 2.days.ago.to_fs(:db) %>

crime_rejected:
  correctable: crime_and_punishment (Books::Book)
  user:
  notes: buy cheap watches
  status: 2
  resolved_by: admin_user
  resolved_at: <%= 1.day.ago.to_fs(:db) %>
  resolution_notes: Spam.
```

`test/fixtures/correction_fields.yml`:

```yaml
war_and_peace_year:
  correction: war_and_peace_pending
  field_name: first_published_year
  old_value: 1869
  new_value: 1867
  status: 0

war_and_peace_title:
  correction: war_and_peace_pending
  field_name: title
  old_value: War and Peace
  new_value: War & Peace
  status: 0

crime_subtitle_applied:
  correction: crime_resolved
  field_name: subtitle
  old_value:
  new_value: A Novel in Six Parts
  status: 1
  applied_at: <%= 2.days.ago.to_fs(:db) %>
```

Note the polymorphic fixture syntax — `correctable: war_and_peace (Books::Book)`. Never set `correctable_type` by hand.

- [ ] **Step 6: Run the tests to verify they fail**

```bash
cd web-app
bin/rails test test/models/correction_test.rb test/models/correction_field_test.rb
```

Expected: FAIL — `MAX_NOTES_LENGTH` undefined, no `pending?` predicate, no uniqueness validation.

- [ ] **Step 7: Write the models**

`app/models/correction.rb`:

```ruby
class Correction < ApplicationRecord
  # Generous enough that no real submission is affected -- the longest legacy note
  # is well under a thousand characters -- while bounding an anonymous public write
  # endpoint that anyone can post to.
  MAX_NOTES_LENGTH = 10_000

  belongs_to :correctable, polymorphic: true
  belongs_to :user, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true
  has_many :correction_fields, dependent: :destroy

  # No `approved` state. Legacy declared one alongside `rejected` and set neither
  # for two years; nothing sits between approving a field and writing it. `resolved`
  # means the admin acted -- by applying fields, or by fixing something the notes
  # described by hand. The field rows record which.
  enum :status, {pending: 0, resolved: 1, rejected: 2}

  normalizes :notes, with: ->(value) { value.presence }

  validates :notes, length: {maximum: MAX_NOTES_LENGTH}
  validate :notes_or_fields_present

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  private

  # `correction_fields.any?` reads the loaded association target on an unsaved
  # record and queries on a persisted one -- both are the answer we want.
  def notes_or_fields_present
    return if notes.present? || correction_fields.any?

    errors.add(:base, "Tell us what's wrong, or propose a change to at least one field")
  end
end
```

`app/models/correction_field.rb`:

```ruby
class CorrectionField < ApplicationRecord
  belongs_to :correction

  # `applied` rather than `accepted`: accepting a field and writing it are the same
  # act, so a separate accepted state would exist for zero seconds.
  enum :status, {pending: 0, applied: 1, rejected: 2}

  validates :field_name, presence: true, uniqueness: {scope: :correction_id}
end
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/models/correction_test.rb test/models/correction_field_test.rb
```

Expected: PASS.

- [ ] **Step 9: Prove the tests are not vacuous**

Comment out `validate :notes_or_fields_present` in `correction.rb`, re-run, confirm the "invalid with neither" test goes RED, then restore it. Do the same for the `uniqueness:` option on `CorrectionField#field_name`.

- [ ] **Step 10: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/models/correction.rb app/models/correction_field.rb
bin/rails test test/models/
git add -A
git commit -m "Add Correction and CorrectionField models"
```

---

## Task 2: The Correctable contract

**Files:**
- Create: `app/models/concerns/correctable.rb`
- Test: `test/models/concerns/correctable_test.rb`

**Interfaces:**
- Consumes: `Correction` from Task 1.
- Produces:
  - `Correctable::FieldDefinition = Struct.new(:name, :type, :target, :label, :hint, keyword_init: true)`
  - `Correctable::TYPES = %i[string text integer string_array]`, `Correctable::TARGETS = %i[column description]`
  - Class method `correctable_field(name, type:, target: :column, label: nil, hint: nil)`
  - Class method `correctable_fields` → `Hash<String, FieldDefinition>`, insertion-ordered
  - Class method `correctable_field_names` → `Array<String>`
  - Instance method `correction_applied(field_names)` — no-op hook, overridable
  - Association `has_many :corrections, as: :correctable, dependent: :destroy`

- [ ] **Step 1: Write the failing test**

`test/models/concerns/correctable_test.rb`:

```ruby
require "test_helper"

class CorrectableTest < ActiveSupport::TestCase
  # A throwaway class, so this tests the concern rather than Books::Book's
  # particular declarations -- which are free to change without breaking this.
  class Dummy
    include ActiveModel::Model
    extend ActiveModel::Callbacks
    def self.has_many(*, **) = nil
    include Correctable

    correctable_field :name, type: :string
    correctable_field :year, type: :integer, label: "Year of release", hint: "A four-digit year"
    correctable_field :blurb, type: :text, target: :description
  end

  class OtherDummy
    include ActiveModel::Model
    def self.has_many(*, **) = nil
    include Correctable

    correctable_field :headline, type: :string
  end

  test "records declarations in declaration order" do
    assert_equal %w[name year blurb], Dummy.correctable_field_names
  end

  test "defaults target to column" do
    assert_equal :column, Dummy.correctable_fields["name"].target
  end

  test "carries an explicit target" do
    assert_equal :description, Dummy.correctable_fields["blurb"].target
  end

  test "defaults label to a humanized name" do
    assert_equal "Name", Dummy.correctable_fields["name"].label
  end

  test "carries an explicit label and hint" do
    definition = Dummy.correctable_fields["year"]
    assert_equal ["Year of release", "A four-digit year"], [definition.label, definition.hint]
  end

  test "rejects an unknown type" do
    assert_raises(ArgumentError) do
      Class.new { include Correctable }.correctable_field(:x, type: :nonsense)
    end
  end

  test "rejects an unknown target" do
    assert_raises(ArgumentError) do
      Class.new { include Correctable }.correctable_field(:x, type: :string, target: :nonsense)
    end
  end

  # class_attribute's default object is shared by every including class. If
  # correctable_field mutated it in place, declaring a field on one model would
  # add it to every other correctable model in the app.
  test "one class's declarations do not leak into another" do
    assert_equal %w[headline], OtherDummy.correctable_field_names
    assert_not_includes Dummy.correctable_field_names, "headline"
  end

  test "correction_applied is a no-op by default" do
    assert_nil Dummy.new.correction_applied(%w[name])
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app
bin/rails test test/models/concerns/correctable_test.rb
```

Expected: FAIL — `uninitialized constant Correctable`.

- [ ] **Step 3: Write the concern**

`app/models/concerns/correctable.rb`:

```ruby
# The contract shared correction code depends on. Corrections are polymorphic
# through `correctable` and there is no per-domain Correction subclass to hang
# behaviour on, so each correctable class declares what the shared code needs.
#
# Same shape as Reviewable and Describable. Unlike Reviewable, nothing here
# raises NotImplementedError: a model that includes this and declares no fields
# is a legitimate state (it accepts free-text notes and nothing else).
module Correctable
  extend ActiveSupport::Concern

  # The declared `type` does three jobs at once: it is the allowlist entry, the
  # cast rule, and the choice of form input. Legacy derived all three by
  # pattern-matching `columns_hash[field].sql_type_metadata.sql_type` at runtime,
  # logged an error on anything it did not recognise, and silently dropped the
  # field. Declaring it is shorter and cannot drift from the column.
  FieldDefinition = Struct.new(:name, :type, :target, :label, :hint, keyword_init: true)

  TYPES = %i[string text integer string_array].freeze
  TARGETS = %i[column description].freeze

  included do
    has_many :corrections, as: :correctable, dependent: :destroy
    class_attribute :correctable_fields, default: {}.freeze
  end

  class_methods do
    def correctable_field(name, type:, target: :column, label: nil, hint: nil)
      unless Correctable::TYPES.include?(type)
        raise ArgumentError, "unknown correctable type #{type.inspect} (one of #{Correctable::TYPES.join(", ")})"
      end
      unless Correctable::TARGETS.include?(target)
        raise ArgumentError, "unknown correctable target #{target.inspect} (one of #{Correctable::TARGETS.join(", ")})"
      end

      definition = Correctable::FieldDefinition.new(
        name: name.to_s,
        type: type,
        target: target,
        label: label || name.to_s.humanize,
        hint: hint
      )

      # merge, never mutate: class_attribute's default hash is one object shared
      # by every including class, so `correctable_fields[k] = v` would add this
      # field to every other correctable model in the app.
      self.correctable_fields = correctable_fields.merge(definition.name => definition).freeze
    end

    def correctable_field_names
      correctable_fields.keys
    end
  end

  # Called by the applier after accepted fields are written and before the record
  # is saved, with the applied field names. Override to clear a derived column
  # that a corrected input feeds. No-op by default.
  def correction_applied(field_names)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web-app
bin/rails test test/models/concerns/correctable_test.rb
```

Expected: PASS.

- [ ] **Step 5: Prove the leak test is not vacuous**

Change `self.correctable_fields = correctable_fields.merge(...)` to `correctable_fields[definition.name] = definition` (dropping `.freeze` from the default so it runs). Re-run — "one class's declarations do not leak into another" must go RED. Restore.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/models/concerns/correctable.rb
git add -A
git commit -m "Add Correctable contract"
```

---

## Task 3: Value casting and target strategies

**Files:**
- Create: `app/lib/services/corrections/value_caster.rb`
- Create: `app/lib/services/corrections/targets.rb`
- Create: `app/lib/services/corrections/targets/column.rb`
- Create: `app/lib/services/corrections/targets/primary_description.rb`
- Test: `test/lib/services/corrections/value_caster_test.rb`, `test/lib/services/corrections/targets_test.rb`

**Interfaces:**
- Consumes: `Correctable` from Task 2.
- Produces:
  - `Services::Corrections::ValueCaster.call(value, type:)` → `String | Integer | Array<String> | nil`
  - `Services::Corrections::Targets.for(target_symbol)` → a class responding to `.read(record, field_name)` and `.write(record, field_name, value)`
  - `Services::Corrections::Targets::Column`, `Services::Corrections::Targets::PrimaryDescription`

**Naming note:** the description target is `PrimaryDescription`, not `Description`. A class named `Description` nested here would shadow the top-level `::Description` model for every constant lookup inside this namespace — the failure mode that has bitten this codebase repeatedly.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/corrections/value_caster_test.rb`:

```ruby
require "test_helper"

module Services
  module Corrections
    class ValueCasterTest < ActiveSupport::TestCase
      test "strips and returns a string" do
        assert_equal "War and Peace", ValueCaster.call("  War and Peace  ", type: :string)
      end

      test "returns nil for a blank string" do
        assert_nil ValueCaster.call("   ", type: :string)
      end

      test "treats text like string" do
        assert_equal "A summary.", ValueCaster.call(" A summary. ", type: :text)
      end

      test "casts a numeric string to an integer" do
        assert_equal 1869, ValueCaster.call(" 1869 ", type: :integer)
      end

      # Legacy used value.to_i, which turns "not a year" into 0 and would have
      # silently set first_published_year to 0 on apply.
      test "returns nil rather than zero for a non-numeric integer" do
        assert_nil ValueCaster.call("not a year", type: :integer)
      end

      test "returns nil for a blank integer" do
        assert_nil ValueCaster.call("", type: :integer)
      end

      test "passes an integer through" do
        assert_equal 1869, ValueCaster.call(1869, type: :integer)
      end

      test "compacts, strips and dedupes a string array" do
        assert_equal ["Voyna i mir", "War & Peace"],
          ValueCaster.call([" Voyna i mir ", "", "War & Peace", "Voyna i mir"], type: :string_array)
      end

      test "returns an empty array for a nil string array" do
        assert_equal [], ValueCaster.call(nil, type: :string_array)
      end

      test "raises on an unknown type" do
        assert_raises(ArgumentError) { ValueCaster.call("x", type: :nonsense) }
      end
    end
  end
end
```

`test/lib/services/corrections/targets_test.rb`:

```ruby
require "test_helper"

module Services
  module Corrections
    class TargetsTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
      end

      test "resolves the column target" do
        assert_equal Targets::Column, Targets.for(:column)
      end

      test "resolves the description target" do
        assert_equal Targets::PrimaryDescription, Targets.for(:description)
      end

      test "raises on an unknown target" do
        assert_raises(ArgumentError) { Targets.for(:nonsense) }
      end

      test "column reads the current value" do
        assert_equal "War and Peace", Targets::Column.read(@book, "title")
      end

      test "column writes without saving" do
        Targets::Column.write(@book, "title", "War & Peace")
        assert_equal ["War & Peace", "War and Peace"], [@book.title, @book.reload.title]
      end

      test "description reads the resolved primary description" do
        assert_equal @book.primary_description.content,
          Targets::PrimaryDescription.read(@book, "description")
      end

      test "description writes a manual row that the resolver then prefers" do
        Targets::PrimaryDescription.write(@book, "description", "A corrected summary.")
        @book.save!

        row = @book.descriptions.reload.find { |d| d.source == "manual" }
        assert_equal "A corrected summary.", row.content
        # manual is first in Descriptions::SourcePriority::ORDER, so it wins
        # without anyone setting rank.
        assert_equal "A corrected summary.", @book.reload.primary_description.content
      end

      test "description updates the existing manual row rather than adding a second" do
        Targets::PrimaryDescription.write(@book, "description", "First.")
        @book.save!
        Targets::PrimaryDescription.write(@book.reload, "description", "Second.")
        @book.save!

        manual = @book.descriptions.reload.select { |d| d.source == "manual" }
        assert_equal ["Second."], manual.map(&:content)
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web-app
bin/rails test test/lib/services/corrections/
```

Expected: FAIL — `uninitialized constant Services::Corrections`.

- [ ] **Step 3: Write the caster**

`app/lib/services/corrections/value_caster.rb`:

```ruby
module Services
  module Corrections
    # Casts a submitted form value to the type its field declared. The submission
    # service uses this on the way in (so a proposal is compared against the
    # current value in the same representation), and the applier uses it again on
    # the way out (the admin may have edited the value in the review form).
    class ValueCaster
      def self.call(value, type:)
        case type
        when :string, :text
          value.to_s.strip.presence
        when :integer
          cast_integer(value)
        when :string_array
          Array(value).map { |element| element.to_s.strip }.reject(&:blank?).uniq
        else
          raise ArgumentError, "unknown correction field type: #{type.inspect}"
        end
      end

      # Integer(..., exception: false), never to_i. to_i turns "not a year" into 0
      # -- which legacy then wrote to first_published_year on apply, silently. nil
      # is the honest answer for garbage, and it is distinguishable from a real 0.
      def self.cast_integer(value)
        return nil if value.blank?

        Integer(value.to_s.strip, exception: false)
      end
      private_class_method :cast_integer
    end
  end
end
```

- [ ] **Step 4: Write the targets**

`app/lib/services/corrections/targets.rb`:

```ruby
module Services
  module Corrections
    module Targets
      # A case rather than a constant hash: a hash literal would reference both
      # classes at module-load time, which Zeitwerk resolves in whatever order it
      # loads these files. This resolves each lazily, at call time.
      def self.for(target)
        case target
        when :column then Column
        when :description then PrimaryDescription
        else raise ArgumentError, "unknown correction target: #{target.inspect}"
        end
      end
    end
  end
end
```

`app/lib/services/corrections/targets/column.rb`:

```ruby
module Services
  module Corrections
    module Targets
      # A plain column on the record itself.
      class Column
        def self.read(record, field_name)
          record.public_send(field_name)
        end

        # Assigns without saving. The applier writes every accepted column and then
        # issues one save!, so a validation failure rolls back the whole correction
        # rather than leaving half of it applied.
        def self.write(record, field_name, value)
          record.public_send(:"#{field_name}=", value)
        end
      end
    end
  end
end
```

`app/lib/services/corrections/targets/primary_description.rb`:

```ruby
module Services
  module Corrections
    module Targets
      # The record's displayed description.
      #
      # NOT a column. books_books.description is read by nothing and is scheduled
      # for deletion as the last step of the descriptions subsystem; the displayed
      # text comes from the polymorphic `descriptions` table, resolved by source
      # priority. This target earns its special case: 68 of the 448 legacy
      # changesets propose a description, the second-largest category.
      #
      # Named PrimaryDescription, not Description: a class named Description nested
      # inside this module would shadow the top-level ::Description model for every
      # constant lookup in this namespace.
      class PrimaryDescription
        def self.read(record, _field_name)
          record.primary_description&.content
        end

        # assign_description assigns onto the association without saving (the
        # association is autosave: true), and reuses the existing manual row rather
        # than adding a second -- the descriptions natural-key unique index would
        # reject one anyway.
        #
        # source: :manual is first in Descriptions::SourcePriority::ORDER, so an
        # applied correction outranks the Wikipedia or OpenLibrary text with no
        # rank change and no demote-then-promote dance.
        def self.write(record, _field_name, value)
          record.assign_description(source: :manual, content: value)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/lib/services/corrections/
CI=1 bin/rails zeitwerk:check
```

Expected: PASS, and zeitwerk:check reports no errors. `zeitwerk:check` is not optional here — `eager_load` is off in test, so the suite passing does not prove these files can be autoloaded in production.

- [ ] **Step 6: Prove the description tests are not vacuous**

Change `source: :manual` to `source: :other` in `PrimaryDescription.write`. Re-run — "the resolver then prefers" must go RED (an `other` source sorts last). Restore.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/services/corrections/
git add -A
git commit -m "Add correction value casting and target strategies"
```

---

## Task 4: Type registry and Books::Book wiring

**Files:**
- Create: `app/lib/services/corrections/type_registry.rb`
- Modify: `app/models/books/book.rb`
- Test: `test/lib/services/corrections/type_registry_test.rb`, `test/models/books/book_test.rb`

**Interfaces:**
- Consumes: `Correctable`, `Services::Corrections::Targets`.
- Produces:
  - `Services::Corrections::TypeRegistry.resolve(type_name)` → `Class | nil`
  - `Services::Corrections::TypeRegistry.domain_for(type_name)` → `Symbol | nil`
  - `Services::Corrections::TypeRegistry.types_for_domain(domain)` → `Array<String>`
  - `::Books::Book.correctable_field_names` → `%w[title subtitle first_published_year page_range word_count alternate_titles description]`
  - `::Books::Book#correction_applied(field_names)` clears `book_length` when `page_range` or `word_count` was applied

- [ ] **Step 1: Write the failing tests**

`test/lib/services/corrections/type_registry_test.rb`:

```ruby
require "test_helper"

module Services
  module Corrections
    class TypeRegistryTest < ActiveSupport::TestCase
      test "resolves a registered correctable type" do
        assert_equal ::Books::Book, TypeRegistry.resolve("Books::Book")
      end

      test "returns nil for a type that is not in the registry" do
        assert_nil TypeRegistry.resolve("User")
      end

      # The whole point: legacy called constantize on this param directly.
      test "returns nil rather than constantizing an arbitrary class name" do
        assert_nil TypeRegistry.resolve("Kernel")
        assert_nil TypeRegistry.resolve("ActiveRecord::Base")
      end

      test "returns nil for a registered type that is not correctable" do
        # Books::Edition is in Admin::DomainRouting::ENTITIES but does not
        # include Correctable.
        assert_nil TypeRegistry.resolve("Books::Edition")
      end

      test "returns nil for blank input" do
        assert_nil TypeRegistry.resolve(nil)
        assert_nil TypeRegistry.resolve("")
      end

      test "reports the domain for a type" do
        assert_equal :books, TypeRegistry.domain_for("Books::Book")
      end

      test "lists the correctable types for a domain" do
        assert_equal ["Books::Book"], TypeRegistry.types_for_domain(:books)
      end

      test "lists nothing for a domain with no correctable types yet" do
        assert_empty TypeRegistry.types_for_domain(:music)
      end
    end
  end
end
```

Add to `test/models/books/book_test.rb`:

```ruby
test "declares its correctable fields in display order" do
  assert_equal %w[title subtitle first_published_year page_range word_count alternate_titles description],
    ::Books::Book.correctable_field_names
end

test "does not expose the doomed description column as a column target" do
  assert_equal :description, ::Books::Book.correctable_fields["description"].target
end

test "clears book_length when page_range is corrected so it re-derives" do
  book = books_books(:war_and_peace)
  book.update!(page_range: "1200", book_length: :very_long)

  book.correction_applied(%w[page_range])
  assert_nil book.book_length
end

test "clears book_length when word_count is corrected" do
  book = books_books(:war_and_peace)
  book.update!(word_count: 500_000, book_length: :very_long)

  book.correction_applied(%w[word_count])
  assert_nil book.book_length
end

test "leaves book_length alone when an unrelated field is corrected" do
  book = books_books(:war_and_peace)
  book.update!(page_range: "1200", book_length: :very_long)

  book.correction_applied(%w[title])
  assert_equal "very_long", book.book_length
end
```

And to `test/models/correction_field_test.rb` — the spec's "an undeclared field cannot be stored" invariant, which only becomes testable now that a real model is correctable:

```ruby
test "accepts a field name the record declares" do
  field = CorrectionField.new(correction: corrections(:war_and_peace_pending),
    field_name: "subtitle", old_value: nil, new_value: "A Novel")

  assert_predicate field, :valid?
end

test "rejects a field name the record does not declare" do
  field = CorrectionField.new(correction: corrections(:war_and_peace_pending),
    field_name: "slug", old_value: "war-and-peace", new_value: "hacked")

  assert_not field.valid?
  assert_includes field.errors[:field_name].join, "not correctable"
end

test "does not blow up validating a blank field name" do
  field = CorrectionField.new(correction: corrections(:war_and_peace_pending), field_name: nil)

  assert_not field.valid?
  assert_includes field.errors[:field_name].join, "can't be blank"
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web-app
bin/rails test test/lib/services/corrections/type_registry_test.rb test/models/books/book_test.rb
```

Expected: FAIL — `TypeRegistry` undefined, `correctable_field_names` undefined on `Books::Book`.

- [ ] **Step 3: Write the registry**

`app/lib/services/corrections/type_registry.rb`:

```ruby
module Services
  module Corrections
    # Resolves a correctable_type string that arrived in a request.
    #
    # Legacy called params[:changeable_type].constantize directly, which resolves
    # any constant name an attacker cares to send. This resolves ONLY names that
    # are already keys of Admin::DomainRouting::ENTITIES -- the registry that
    # already drives descriptions, category items and admin paths -- and then only
    # if the resulting class actually includes Correctable. Anything else is nil,
    # which callers turn into a 400.
    #
    # ::Admin and ::Books are root-anchored: Services::Books exists, so a bare
    # Books::Book written inside Services::Corrections resolves to
    # Services::Books::Book and raises NameError.
    module TypeRegistry
      def self.resolve(type_name)
        name = type_name.to_s
        return nil if name.blank?
        return nil unless ::Admin::DomainRouting::ENTITIES.key?(name)

        klass = name.safe_constantize
        return nil unless klass.respond_to?(:correctable_fields)

        klass
      end

      def self.domain_for(type_name)
        ::Admin::DomainRouting::ENTITIES.dig(type_name.to_s, :domain)
      end

      def self.types_for_domain(domain)
        ::Admin::DomainRouting::ENTITIES.filter_map do |name, config|
          name if config[:domain] == domain&.to_sym && resolve(name)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire Books::Book**

In `app/models/books/book.rb`, add `Correctable` to the includes and the declarations directly below the `enum` block:

```ruby
class Books::Book < ApplicationRecord
  include Describable
  include SearchIndexable
  include Reviewable
  include Correctable
```

Then, after the `enum :book_length, ...` line:

```ruby
  # What a reader may propose a correction to. Ordered as the public form renders
  # them.
  #
  # Deliberately absent: sort_title, book_kind and book_length are not visible to a
  # reader, so a reader cannot know they are wrong; book_length is derived anyway.
  #
  # description is target: :description, not a column. books_books.description is
  # read by no book page and is scheduled for deletion; the displayed text lives in
  # the descriptions table.
  correctable_field :title, type: :string
  correctable_field :subtitle, type: :string
  correctable_field :first_published_year, type: :integer
  correctable_field :page_range, type: :string, hint: "A number or a range, e.g. 300 or 250-350"
  correctable_field :word_count, type: :integer
  correctable_field :alternate_titles, type: :string_array
  correctable_field :description, type: :text, target: :description
```

And the hook, as a public method beside `release_year`:

```ruby
  # Correctable hook. derive_book_length only fires when book_length is blank, so
  # correcting page_range or word_count on a book that already has a length would
  # leave the "Length" and "Pages" rows of the public details card contradicting
  # each other. Clearing it lets the existing before_validation re-derive on save.
  def correction_applied(field_names)
    return unless field_names.intersect?(%w[page_range word_count])

    self.book_length = nil
  end
```

- [ ] **Step 4b: Add the declared-field validation to CorrectionField**

The spec requires that an undeclared field cannot be stored. It lands here rather than in Task 1 because Task 1 runs before any model is correctable, so there would have been nothing to validate against and the test would have been vacuous.

In `app/models/correction_field.rb`:

```ruby
  validate :field_name_is_declared

  private

  # Defence in depth. Submission only ever builds declared fields, so nothing in
  # the request path can violate this today -- but the admin apply path rewrites
  # new_value, and the whole point of this subsystem is that an agent will write
  # corrections through it later. This is the invariant that lets the applier trust
  # a stored field_name.
  #
  # Resolves through the registry rather than constantizing correctable_type, for
  # the same reason the controllers do.
  def field_name_is_declared
    return if field_name.blank?  # presence validation already reported it

    klass = Services::Corrections::TypeRegistry.resolve(correction&.correctable_type)
    return if klass.nil?         # unknown type is not this validation's job

    return if klass.correctable_fields.key?(field_name)

    errors.add(:field_name, "is not correctable on #{correction.correctable_type}")
  end
```

Note this is bypassed by `insert_all`, which is exactly how the legacy migrator (Task 15) writes — deliberate, and why the applier in Task 7 tolerates an undeclared row rather than raising.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/lib/services/corrections/ test/models/books/book_test.rb
```

Expected: PASS.

- [ ] **Step 6: Prove the registry test is not vacuous**

Replace the body of `TypeRegistry.resolve` with `type_name.to_s.safe_constantize`. Re-run — "returns nil rather than constantizing an arbitrary class name" and "returns nil for a registered type that is not correctable" must both go RED. Restore.

- [ ] **Step 7: Full suite, lint, commit**

```bash
cd web-app
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
git add -A
git commit -m "Add correction type registry and wire Books::Book"
```

The full suite matters here: adding an association and a `class_attribute` to `Books::Book` touches a model that ~1,500 tests load.

---

## Task 5: Extract the visitor IP helper

**Files:**
- Create: `app/controllers/concerns/visitor_ip.rb`
- Modify: `app/controllers/membership_controller.rb:200-206`
- Test: `test/controllers/concerns/visitor_ip_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `VisitorIp#visitor_ip` → `String`, a controller concern.

- [ ] **Step 1: Read the current implementation**

```bash
cd web-app
sed -n '195,210p' app/controllers/membership_controller.rb
```

- [ ] **Step 2: Write the failing test**

`test/controllers/concerns/visitor_ip_test.rb`:

```ruby
require "test_helper"

class VisitorIpTest < ActiveSupport::TestCase
  class Host
    include VisitorIp
    attr_accessor :request

    def initialize(request) = @request = request

    public :visitor_ip
  end

  FakeRequest = Struct.new(:headers, :remote_ip)

  test "prefers the Cloudflare connecting IP" do
    host = Host.new(FakeRequest.new({"CF-Connecting-IP" => "198.51.100.4"}, "172.16.0.1"))
    assert_equal "198.51.100.4", host.visitor_ip
  end

  test "falls back to remote_ip when the header is absent" do
    host = Host.new(FakeRequest.new({}, "172.16.0.1"))
    assert_equal "172.16.0.1", host.visitor_ip
  end

  test "falls back to remote_ip when the header is blank" do
    host = Host.new(FakeRequest.new({"CF-Connecting-IP" => ""}, "172.16.0.1"))
    assert_equal "172.16.0.1", host.visitor_ip
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd web-app
bin/rails test test/controllers/concerns/visitor_ip_test.rb
```

Expected: FAIL — `uninitialized constant VisitorIp`.

- [ ] **Step 4: Write the concern**

`app/controllers/concerns/visitor_ip.rb`:

```ruby
# The caller's real IP, for rate-limit bucketing.
#
# request.remote_ip in production is the CLOUDFLARE EDGE IP, not the visitor's.
# Keying a rate limit on it puts every visitor on the planet into one bucket, so
# the limit fires for everyone the moment any one person trips it. Every
# IP-keyed limit in this app must go through here.
#
# remote_ip is the fallback only, for requests that did not come through
# Cloudflare -- local development, and health checks hitting the origin directly.
module VisitorIp
  extend ActiveSupport::Concern

  private

  def visitor_ip
    request.headers["CF-Connecting-IP"].presence || request.remote_ip
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd web-app
bin/rails test test/controllers/concerns/visitor_ip_test.rb
```

Expected: PASS.

- [ ] **Step 6: Switch MembershipController to the concern**

Delete its private `visitor_ip` method and its comment block, and add `include VisitorIp` beside the controller's other includes. Keep a one-line pointer where the method was:

```ruby
  # visitor_ip comes from the VisitorIp concern -- see it for why remote_ip alone
  # is wrong behind Cloudflare.
```

- [ ] **Step 7: Verify the membership tests still pass**

```bash
cd web-app
bin/rails test test/controllers/membership_controller_test.rb
```

Expected: PASS, same count as before the change.

- [ ] **Step 8: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/controllers/concerns/visitor_ip.rb app/controllers/membership_controller.rb
git add -A
git commit -m "Extract VisitorIp concern from MembershipController"
```

---

## Task 6: The submission service

**Files:**
- Create: `app/lib/services/corrections/submission.rb`
- Test: `test/lib/services/corrections/submission_test.rb`

**Interfaces:**
- Consumes: `Correctable`, `ValueCaster`, `Targets` from Tasks 2–3.
- Produces: `Services::Corrections::Submission.call(record:, field_params:, notes:, user: nil, submitter_ip: nil)` → `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` where `data` is the persisted `Correction`.

`field_params` is a `Hash<String, Object>` of raw submitted values keyed by field name — typically `params[:correction][:fields].to_unsafe_h`. Undeclared keys are ignored, not an error.

- [ ] **Step 1: Write the failing test**

`test/lib/services/corrections/submission_test.rb`:

```ruby
require "test_helper"

module Services
  module Corrections
    class SubmissionTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @user = users(:regular_user)
      end

      test "creates a field row only for a value that actually moved" do
        result = Submission.call(
          record: @book,
          field_params: {"title" => "War and Peace", "first_published_year" => "1867"},
          notes: nil,
          user: @user
        )

        assert_predicate result, :success?
        assert_equal %w[first_published_year], result.data.correction_fields.map(&:field_name)
      end

      test "records the old value from the record, not from the submission" do
        result = Submission.call(
          record: @book,
          field_params: {"first_published_year" => "1867"},
          notes: nil,
          user: @user
        )

        field = result.data.correction_fields.sole
        assert_equal [1869, 1867], [field.old_value, field.new_value]
      end

      test "casts before comparing, so whitespace alone is not a change" do
        result = Submission.call(
          record: @book,
          field_params: {"title" => "  War and Peace  "},
          notes: "just notes",
          user: nil
        )

        assert_empty result.data.correction_fields
      end

      test "ignores undeclared field names" do
        result = Submission.call(
          record: @book,
          field_params: {"slug" => "hacked", "id" => "9999"},
          notes: "just notes",
          user: nil
        )

        assert_predicate result, :success?
        assert_empty result.data.correction_fields
      end

      test "detects an array change" do
        result = Submission.call(
          record: @book,
          field_params: {"alternate_titles" => ["Voyna i mir", "War & Peace"]},
          notes: nil,
          user: @user
        )

        field = result.data.correction_fields.sole
        assert_equal [["Voyna i mir"], ["Voyna i mir", "War & Peace"]],
          [field.old_value, field.new_value]
      end

      test "reads the description target rather than the column" do
        result = Submission.call(
          record: @book,
          field_params: {"description" => "A corrected summary."},
          notes: nil,
          user: @user
        )

        field = result.data.correction_fields.sole
        assert_equal @book.primary_description.content, field.old_value
      end

      test "stores the submitter and their ip" do
        result = Submission.call(
          record: @book, field_params: {}, notes: "wrong", user: @user, submitter_ip: "198.51.100.4"
        )

        assert_equal [@user, "198.51.100.4"], [result.data.user, result.data.submitter_ip]
      end

      test "succeeds anonymously" do
        result = Submission.call(record: @book, field_params: {}, notes: "wrong", user: nil)

        assert_predicate result, :success?
        assert_nil result.data.user
      end

      test "fails with neither notes nor a moved field" do
        result = Submission.call(
          record: @book, field_params: {"title" => "War and Peace"}, notes: "  ", user: nil
        )

        assert_not result.success?
        assert_includes result.errors.join, "Tell us what's wrong"
      end

      test "persists nothing when it fails" do
        assert_no_difference -> { Correction.count } do
          Submission.call(record: @book, field_params: {}, notes: nil, user: nil)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app
bin/rails test test/lib/services/corrections/submission_test.rb
```

Expected: FAIL — `uninitialized constant Services::Corrections::Submission`.

- [ ] **Step 3: Write the service**

`app/lib/services/corrections/submission.rb`:

```ruby
module Services
  module Corrections
    # Turns a submitted form into a Correction plus one CorrectionField per value
    # that actually moved.
    #
    # The submitter's browser sends what it believes the current values to be, but
    # `old_value` is read from the RECORD here, never from the submission. A cached
    # form page can be up to 24 hours stale, and trusting its idea of "from" is how
    # a correction ends up claiming a change that never happened.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(record:, field_params:, notes:, user: nil, submitter_ip: nil)
        new(record: record, field_params: field_params, notes: notes,
          user: user, submitter_ip: submitter_ip).call
      end

      def initialize(record:, field_params:, notes:, user:, submitter_ip:)
        @record = record
        @field_params = field_params || {}
        @notes = notes
        @user = user
        @submitter_ip = submitter_ip
      end

      def call
        correction = ::Correction.new(
          correctable: @record, user: @user, notes: @notes, submitter_ip: @submitter_ip
        )
        moved_fields.each { |attrs| correction.correction_fields.build(**attrs) }

        if correction.save
          Result.new(success?: true, data: correction, errors: [])
        else
          Result.new(success?: false, data: nil, errors: correction.errors.full_messages)
        end
      end

      private

      # Undeclared keys are dropped silently rather than rejected: the form only
      # renders declared fields, so anything else is either a stale cached page from
      # before a field was removed, or someone poking at the endpoint. Neither is
      # worth an error the submitter cannot act on.
      def moved_fields
        @record.class.correctable_fields.filter_map do |name, definition|
          next unless @field_params.key?(name)

          target = Targets.for(definition.target)
          current = ValueCaster.call(target.read(@record, name), type: definition.type)
          proposed = ValueCaster.call(@field_params[name], type: definition.type)
          next if current == proposed

          {field_name: name, old_value: current, new_value: proposed}
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web-app
bin/rails test test/lib/services/corrections/submission_test.rb
```

Expected: PASS.

- [ ] **Step 5: Prove the old-value test is not vacuous**

Change `old_value: current` to `old_value: @field_params["_from_#{name}"]`. Re-run — "records the old value from the record, not from the submission" must go RED. Restore.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/services/corrections/submission.rb
bin/rails test test/lib/services/corrections/
git add -A
git commit -m "Add correction submission service"
```

---

## Task 7: The apply service

**Files:**
- Create: `app/lib/services/corrections/applier.rb`
- Test: `test/lib/services/corrections/applier_test.rb`

**Interfaces:**
- Consumes: `Correction`, `CorrectionField`, `Targets`, `ValueCaster`, `Correctable#correction_applied`.
- Produces: `Services::Corrections::Applier.call(correction:, accepted:, admin:)` → `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`, `data` is the reloaded `Correction`.

`accepted` is a `Hash<String, Object>` mapping field name → the value to write (the admin may have edited it in the review form). A declared field absent from `accepted` is rejected, not skipped.

- [ ] **Step 1: Write the failing test**

`test/lib/services/corrections/applier_test.rb`:

```ruby
require "test_helper"

module Services
  module Corrections
    class ApplierTest < ActiveSupport::TestCase
      setup do
        @correction = corrections(:war_and_peace_pending)
        @book = @correction.correctable
        @admin = users(:admin_user)
      end

      test "writes an accepted column field" do
        result = Applier.call(correction: @correction, accepted: {"first_published_year" => "1867"}, admin: @admin)

        assert_predicate result, :success?
        assert_equal 1867, @book.reload.first_published_year
      end

      test "rejects the fields the admin did not accept" do
        Applier.call(correction: @correction, accepted: {"first_published_year" => "1867"}, admin: @admin)

        statuses = @correction.reload.correction_fields.order(:field_name).pluck(:field_name, :status)
        assert_equal [["first_published_year", "applied"], ["title", "rejected"]], statuses
        assert_equal "War and Peace", @book.reload.title
      end

      test "writes the admin's edited value, not the submitted one" do
        Applier.call(correction: @correction, accepted: {"first_published_year" => "1868"}, admin: @admin)

        assert_equal 1868, @book.reload.first_published_year
        assert_equal 1868, @correction.reload.correction_fields.find_by(field_name: "first_published_year").new_value
      end

      test "resolves the correction and stamps who did it" do
        freeze_time do
          Applier.call(correction: @correction, accepted: {"title" => "War & Peace"}, admin: @admin)

          @correction.reload
          assert_predicate @correction, :resolved?
          assert_equal [@admin, Time.current], [@correction.resolved_by, @correction.resolved_at]
        end
      end

      test "stamps applied_at on the applied field rows only" do
        Applier.call(correction: @correction, accepted: {"title" => "War & Peace"}, admin: @admin)

        applied = @correction.reload.correction_fields.find_by(field_name: "title")
        rejected = @correction.correction_fields.find_by(field_name: "first_published_year")
        assert_not_nil applied.applied_at
        assert_nil rejected.applied_at
      end

      test "writes a description field through its target" do
        correction = ::Correction.create!(correctable: @book, notes: nil,
          correction_fields_attributes: [{field_name: "description", old_value: "old", new_value: "A corrected summary."}])

        Applier.call(correction: correction, accepted: {"description" => "A corrected summary."}, admin: @admin)

        assert_equal "A corrected summary.", @book.reload.primary_description.content
      end

      test "clears book_length so a page_range correction re-derives it" do
        @book.update!(page_range: "1200", book_length: :very_long)
        correction = ::Correction.create!(correctable: @book, notes: nil,
          correction_fields_attributes: [{field_name: "page_range", old_value: "1200", new_value: "300"}])

        Applier.call(correction: correction, accepted: {"page_range" => "300"}, admin: @admin)

        assert_equal ["300", "medium"], [@book.reload.page_range, @book.book_length]
      end

      test "rolls everything back when the record is invalid" do
        correction = ::Correction.create!(correctable: @book, notes: nil,
          correction_fields_attributes: [{field_name: "title", old_value: "War and Peace", new_value: ""}])

        result = Applier.call(correction: correction, accepted: {"title" => ""}, admin: @admin)

        assert_not result.success?
        assert_includes result.errors.join, "Title can't be blank"
        assert_equal "War and Peace", @book.reload.title
        assert_predicate correction.reload, :pending?
        assert_predicate correction.correction_fields.first, :pending?
      end

      test "accepting nothing rejects every field and still resolves" do
        result = Applier.call(correction: @correction, accepted: {}, admin: @admin)

        assert_predicate result, :success?
        assert_predicate @correction.reload, :resolved?
        assert @correction.correction_fields.all?(&:rejected?)
      end

      test "refuses a correction that is not pending" do
        result = Applier.call(correction: corrections(:crime_resolved), accepted: {}, admin: @admin)

        assert_not result.success?
        assert_includes result.errors.join, "already been resolved"
      end

      # Reachable two ways: the legacy migrator writes with insert_all, which
      # bypasses the declared-field validation, and a field removed from a model's
      # declaration strands corrections already submitted against it. Neither may
      # 500 the admin.
      test "rejects a field whose name is no longer declared instead of raising" do
        correction = ::Correction.create!(correctable: @book, notes: "legacy")
        ::CorrectionField.insert_all([{
          correction_id: correction.id, field_name: "series_name",
          old_value: nil, new_value: "Discworld", status: 0,
          created_at: Time.current, updated_at: Time.current
        }])

        result = Applier.call(correction: correction, accepted: {"series_name" => "Discworld"}, admin: @admin)

        assert_predicate result, :success?
        assert_predicate correction.reload.correction_fields.sole, :rejected?
      end
    end
  end
end
```

`Correction` needs `accepts_nested_attributes_for :correction_fields` for those `create!` calls. Add it in Step 3.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web-app
bin/rails test test/lib/services/corrections/applier_test.rb
```

Expected: FAIL — `uninitialized constant Services::Corrections::Applier`.

- [ ] **Step 3: Add nested attributes to Correction**

In `app/models/correction.rb`, below `has_many :correction_fields`:

```ruby
  # For the admin review form, which submits per-field decisions, and for tests
  # that build a correction and its fields in one call.
  accepts_nested_attributes_for :correction_fields
```

- [ ] **Step 4: Write the service**

`app/lib/services/corrections/applier.rb`:

```ruby
module Services
  module Corrections
    # Writes an admin's accepted fields onto the record and closes the correction.
    #
    # `accepted` maps field name to the value to WRITE, which is not necessarily the
    # value that was submitted -- the review form lets an admin correct a near-miss
    # in place. A declared field absent from `accepted` is rejected. There is no
    # third outcome: leaving a field pending on a resolved correction would make the
    # queue lie about what is left to do.
    #
    # ::Correction and ::Books are root-anchored -- Services::Books exists, so a bare
    # Books::Book here resolves to Services::Books::Book and raises NameError.
    class Applier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(correction:, accepted:, admin:)
        new(correction: correction, accepted: accepted || {}, admin: admin).call
      end

      def initialize(correction:, accepted:, admin:)
        @correction = correction
        @accepted = accepted
        @admin = admin
      end

      def call
        unless @correction.pending?
          return failure(["This correction has already been resolved"])
        end

        ::Correction.transaction do
          apply_fields
          @record.save!
          resolve_correction
        end

        Result.new(success?: true, data: @correction.reload, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        # The record's real validation errors, not legacy's single generic
        # "Failed to apply changes" -- an admin cannot fix what they cannot see.
        failure(e.record.errors.full_messages)
      end

      private

      def apply_fields
        @record = @correction.correctable
        applied_names = []

        @correction.correction_fields.each do |field|
          unless @accepted.key?(field.field_name)
            field.update!(status: :rejected)
            next
          end

          # [] with a nil guard, NOT fetch. insert_all in the legacy migrator
          # bypasses validations, and a declaration removed later (say, dropping
          # word_count) strands already-submitted rows -- fetch would turn both
          # into a KeyError 500 in the admin, on data the admin cannot fix.
          definition = @record.class.correctable_fields[field.field_name]
          if definition.nil?
            field.update!(status: :rejected)
            next
          end

          value = ValueCaster.call(@accepted[field.field_name], type: definition.type)
          Targets.for(definition.target).write(@record, field.field_name, value)

          field.update!(status: :applied, new_value: value, applied_at: Time.current)
          applied_names << field.field_name
        end

        # Before save!, so a cleared derived column re-derives in the same write.
        @record.correction_applied(applied_names)
      end

      def resolve_correction
        @correction.update!(status: :resolved, resolved_by: @admin, resolved_at: Time.current)
      end

      def failure(errors)
        Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd web-app
bin/rails test test/lib/services/corrections/applier_test.rb
```

Expected: PASS.

- [ ] **Step 6: Prove the rollback test is not vacuous**

Remove the `::Correction.transaction do ... end` wrapper (leaving the body). Re-run — "rolls everything back when the record is invalid" must go RED, because the field rows will already have been updated before `save!` raises. Restore.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/services/corrections/applier.rb app/models/correction.rb
bin/rails test test/lib/services/corrections/ test/models/
git add -A
git commit -m "Add correction apply service"
```

---

## Task 8: Public routes, the token endpoint, and the form page

**Files:**
- Create: `app/controllers/corrections_controller.rb`
- Create: `app/controllers/correction_token_controller.rb`
- Create: `app/views/corrections/new.html.erb`
- Modify: `config/routes.rb`, `public/robots.txt`
- Test: `test/controllers/correction_token_controller_test.rb`, `test/controllers/corrections_controller_test.rb`

**Interfaces:**
- Consumes: `TypeRegistry`, `Correctable`.
- Produces: routes `books_book_correction_path(slug:)` (GET), `corrections_path` (POST), `correction_token_path` (GET). `CorrectionsController#new` assigns `@record`, `@correctable_type`, `@fields` (an `Array<Correctable::FieldDefinition>`).

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the books domain constraint, beside the existing `get "book/:slug"` line:

```ruby
    # correctable_type comes from route defaults, never from a param: #new then has
    # no user input to validate at all. Music and games each add one analogous line
    # pointing at this same shared controller.
    get "book/:slug/suggest-correction", to: "corrections#new",
      defaults: {correctable_type: "Books::Book"}, as: :books_book_correction
```

And at the top level, beside `get "review_state"`:

```ruby
  # Uncached, no database query. Exists so the edge-cached correction form can get
  # a token that belongs to the caller's session rather than to whoever populated
  # the cache.
  get "correction_token", to: "correction_token#show", as: :correction_token
  resources :corrections, only: [:create]
```

- [ ] **Step 2: Write the failing token test**

`test/controllers/correction_token_controller_test.rb`:

```ruby
require "test_helper"

class CorrectionTokenControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a csrf token anonymously" do
    get correction_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "is never cached" do
    get correction_token_path, as: :json

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "issues no database query" do
    assert_queries_count(0) do
      get correction_token_path, as: :json
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/controllers/correction_token_controller_test.rb
```

Expected: FAIL — uninitialized constant / no route.

- [ ] **Step 4: Write the token controller**

`app/controllers/correction_token_controller.rb`:

```ruby
# The correction form page is edge-cached, so the <meta name="csrf-token"> it
# ships belongs to whoever populated the cache, or to nobody. This hands the
# caller a token for their own session.
#
# Deliberately does no database work: the form page it serves is a public,
# anonymous surface that has been used to flood the origin before, and this is
# the one uncached endpoint that surface still touches. Keeping it query-free
# makes a flood of it about as cheap as Rails gets. The Stimulus controller
# fetches it on first interaction with the form, not on page load, so a crawler
# or a flood that never touches the form never reaches it at all.
class CorrectionTokenController < ApplicationController
  include Cacheable

  before_action :prevent_caching

  def show
    render json: {csrf_token: form_authenticity_token}
  end
end
```

- [ ] **Step 5: Run it to verify it passes**

```bash
cd web-app
bin/rails test test/controllers/correction_token_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Write the failing `#new` test**

`test/controllers/corrections_controller_test.rb`:

```ruby
require "test_helper"

class CorrectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @book = books_books(:war_and_peace)
  end

  test "renders the form for a book" do
    get books_book_correction_path(slug: @book.slug)

    assert_response :success
  end

  test "404s for an unknown slug" do
    get books_book_correction_path(slug: "no-such-book")

    assert_response :not_found
  end

  # The whole point of caching this page: it is the surface that took the live
  # site down when it was uncached.
  test "is publicly cacheable" do
    get books_book_correction_path(slug: @book.slug)

    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  test "sets no session cookie, so Cloudflare does not bypass the cache" do
    get books_book_correction_path(slug: @book.slug)

    assert_nil response.headers["Set-Cookie"]
  end

  test "is not indexable" do
    get books_book_correction_path(slug: @book.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/controllers/corrections_controller_test.rb
```

Expected: FAIL — no `CorrectionsController`.

- [ ] **Step 8: Write the controller's `#new`**

`app/controllers/corrections_controller.rb`:

```ruby
class CorrectionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  before_action :set_record, only: [:new]
  before_action :cache_for_show_page, only: [:new]

  def new
    # The books layout emits "noindex, follow" unless @indexable is truthy, so nil
    # would already do it. Explicit, because "not indexed" here is a decision, not
    # an accident of a default.
    @indexable = false
    @fields = @record.class.correctable_fields.values
  end

  private

  # correctable_type is a ROUTE DEFAULT here, not a param -- see config/routes.rb.
  # It still goes through the registry rather than constantize, so the two callers
  # (#new and #create) share one resolution path and neither can drift.
  def set_record
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    @record = klass.find_by!(slug: params[:slug])
  end

  def domain_layout
    "#{Current.domain}/application"
  end
end
```

- [ ] **Step 9: Write the form view**

`app/views/corrections/new.html.erb`. daisyUI 5 only — `fieldset`/`fieldset-legend`/`label` and bare `input`/`textarea`, never `form-control`, `label-text` or `input-bordered`.

```erb
<%
  content_for :page_title, "Suggest a correction to #{@record.title} | The Greatest Books"
%>

<div class="max-w-2xl mx-auto space-y-6" data-controller="corrections--form"
     data-corrections--form-token-url-value="<%= correction_token_path %>">
  <div>
    <h1 class="text-2xl sm:text-3xl font-bold">Suggest a correction</h1>
    <p class="text-base-content/70 mt-2">
      <%= link_to @record.title, book_path(slug: @record.slug), class: "link" %>
    </p>
  </div>

  <%= form_with url: corrections_path, method: :post, class: "space-y-6",
        data: {corrections__form_target: "form"} do |f| %>
    <%= hidden_field_tag :correctable_type, @correctable_type %>
    <%= hidden_field_tag :correctable_id, @record.id %>

    <%# Honeypot. Bots fill every input they find; a human never sees this one.
        Positioned off-screen rather than display:none -- some bots skip hidden
        inputs. Named plausibly for the same reason. %>
    <div class="absolute left-[-9999px]" aria-hidden="true">
      <label for="correction_website">Website</label>
      <%= text_field_tag :website, nil, id: "correction_website", tabindex: -1, autocomplete: "off" %>
    </div>

    <fieldset class="fieldset">
      <legend class="fieldset-legend text-base">Tell us what's wrong</legend>
      <p class="text-sm text-base-content/70 mb-2">
        If the author, country, genre or series is wrong, describe it here — those aren't
        fields you can edit below.
      </p>
      <%= text_area_tag "correction[notes]", nil, rows: 5, class: "textarea w-full",
            maxlength: Correction::MAX_NOTES_LENGTH %>
    </fieldset>

    <fieldset class="fieldset">
      <legend class="fieldset-legend text-base">Or correct these details</legend>

      <% @fields.each do |definition| %>
        <% current = Services::Corrections::Targets.for(definition.target).read(@record, definition.name) %>

        <% if definition.type == :string_array %>
          <label class="label" for="correction_fields_<%= definition.name %>"><%= definition.label %></label>
          <div data-corrections--form-target="list" data-field="<%= definition.name %>" class="space-y-2">
            <% Array(current).each do |value| %>
              <div class="join w-full">
                <%= text_field_tag "correction[fields][#{definition.name}][]", value,
                      class: "input join-item w-full" %>
                <button type="button" class="btn join-item"
                        data-action="corrections--form#removeListItem">Remove</button>
              </div>
            <% end %>
          </div>
          <button type="button" class="btn btn-sm mt-2" data-field="<%= definition.name %>"
                  data-action="corrections--form#addListItem">
            Add <%= definition.label.singularize.downcase %>
          </button>

        <% elsif definition.type == :text %>
          <label class="label" for="correction_fields_<%= definition.name %>"><%= definition.label %></label>
          <%= text_area_tag "correction[fields][#{definition.name}]", current, rows: 6,
                id: "correction_fields_#{definition.name}", class: "textarea w-full" %>

        <% else %>
          <label class="label" for="correction_fields_<%= definition.name %>"><%= definition.label %></label>
          <%= text_field_tag "correction[fields][#{definition.name}]", current,
                id: "correction_fields_#{definition.name}", class: "input w-full",
                inputmode: (definition.type == :integer ? "numeric" : nil) %>
        <% end %>

        <% if definition.hint.present? %>
          <p class="text-sm text-base-content/70 mt-1"><%= definition.hint %></p>
        <% end %>
      <% end %>
    </fieldset>

    <div class="flex gap-2">
      <%= f.submit "Submit correction", class: "btn btn-primary",
            data: {testid: "correction-submit"} %>
      <%= link_to "Cancel", book_path(slug: @record.slug), class: "btn btn-ghost" %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 10: Add the robots.txt rule**

Append to `public/robots.txt`, below the existing `Disallow` lines:

```
# The correction form. Nothing here is content, and it is the surface that has
# been used to flood the origin.
Disallow: /book/*/suggest-correction
```

- [ ] **Step 11: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/controllers/corrections_controller_test.rb test/controllers/correction_token_controller_test.rb
bin/rails test test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS, including the daisyUI lint.

- [ ] **Step 12: Prove the cache test is not vacuous**

Remove `before_action :cache_for_show_page, only: [:new]`. Re-run — "is publicly cacheable" and "sets no session cookie" must both go RED. Restore.

- [ ] **Step 13: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/controllers/corrections_controller.rb app/controllers/correction_token_controller.rb
git add -A
git commit -m "Add cached public correction form and token endpoint"
```

---

## Task 9: Create, rate limiting, honeypot, and null_session

**Files:**
- Modify: `app/controllers/corrections_controller.rb`
- Test: `test/controllers/corrections_controller_test.rb`

**Interfaces:**
- Consumes: `Services::Corrections::Submission`, `VisitorIp`, `TypeRegistry`.
- Produces: `POST /corrections` accepting `correctable_type`, `correctable_id`, `website` (honeypot), `correction[notes]`, `correction[fields][<name>]`.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/corrections_controller_test.rb`:

```ruby
  def submit(params = {})
    post corrections_path, params: {
      correctable_type: "Books::Book",
      correctable_id: @book.id,
      correction: {notes: "The year is wrong"}
    }.deep_merge(params)
  end

  test "creates a correction anonymously and redirects to the book" do
    assert_difference -> { Correction.count }, 1 do
      submit
    end

    assert_redirected_to book_path(slug: @book.slug)
    assert_nil Correction.last.user
  end

  test "attaches the signed-in user" do
    sign_in_as(users(:regular_user), stub_auth: true)
    submit

    assert_equal users(:regular_user), Correction.last.user
  end

  test "records the Cloudflare connecting ip, not the edge ip" do
    post corrections_path,
      params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
      headers: {"CF-Connecting-IP" => "198.51.100.4"}

    assert_equal "198.51.100.4", Correction.last.submitter_ip
  end

  test "creates field rows for moved values" do
    submit(correction: {fields: {first_published_year: "1867"}})

    assert_equal %w[first_published_year], Correction.last.correction_fields.map(&:field_name)
  end

  test "rejects an unknown correctable type without constantizing it" do
    post corrections_path, params: {
      correctable_type: "Kernel", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  test "rejects a correctable type that is not correctable" do
    post corrections_path, params: {
      correctable_type: "Books::Edition", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  # Accept-and-discard: a bot that gets a 200 stops retrying, and one that gets a
  # 422 comes back.
  test "silently discards a submission with the honeypot filled" do
    assert_no_difference -> { Correction.count } do
      submit(website: "http://spam.example")
    end

    assert_redirected_to book_path(slug: @book.slug)
  end

  test "re-renders with an error when nothing was submitted" do
    post corrections_path, params: {
      correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: ""}
    }

    assert_response :unprocessable_entity
  end

  test "never caches the create response" do
    submit

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "rate limits by ip and redirects rather than raising" do
    Rails.application.config.x.rate_limit_store.clear

    6.times do
      post corrections_path,
        params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end

    assert_redirected_to book_path(slug: @book.slug)
    assert_equal "Thanks — you've sent us several corrections just now. Please try again shortly.", flash[:alert]
  end

  # The cached page ships no usable token. null_session must accept the write as
  # anonymous rather than 422 the submitter, who can do nothing about it.
  test "accepts a submission with no csrf token instead of raising" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_difference -> { Correction.count }, 1 do
      post corrections_path, params: {
        correctable_type: "Books::Book", correctable_id: @book.id,
        correction: {notes: "wrong"}, authenticity_token: "stale"
      }
    end

    assert_redirected_to book_path(slug: @book.slug)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd web-app
bin/rails test test/controllers/corrections_controller_test.rb
```

Expected: FAIL — no `create` action.

- [ ] **Step 3: Implement create**

Replace `app/controllers/corrections_controller.rb`'s body with:

```ruby
class CorrectionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  # The form page is edge-cached, so its <meta name="csrf-token"> belongs to
  # whoever populated the cache. The Stimulus controller fetches a real token from
  # /correction_token on first interaction -- but if that fetch never happened (JS
  # off, blocked, slow), null_session accepts the write as ANONYMOUS rather than
  # raising and showing the submitter a 422 they cannot act on.
  #
  # This is sound, not a compromise. CSRF exists to stop a forged request riding a
  # victim's ambient session authority; null_session removes exactly that
  # authority, so what lands is an anonymous correction the attacker could have
  # posted directly -- and it is moderated before it touches a record. The only
  # thing lost is attribution for a signed-in user whose token fetch failed.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :set_record, only: [:new]
  before_action :cache_for_show_page, only: [:new]
  before_action :prevent_caching, only: [:create]
  before_action :set_record_from_params, only: [:create]

  # Five an hour is far above any human correcting books they are reading, and it
  # caps a script at 120/day per address rather than unbounded.
  #
  # by: goes through visitor_ip, NOT request.remote_ip -- see the VisitorIp
  # concern. remote_ip in production is the Cloudflare edge IP, so keying on it
  # would put every visitor in one bucket and lock out the whole site at the fifth
  # submission of the hour.
  #
  # with: is not optional. Rails' default raises TooManyRequests, which renders an
  # HTML error body.
  #
  # Declared AFTER set_record_from_params, and that ordering is load-bearing:
  # filters run in declaration order and rate_limit installs its own before_action,
  # so @record is already set when the with: lambda calls correctable_path. Move
  # this above that filter and a throttled request redirects to nil.
  rate_limit to: 5, within: 1.hour,
    by: -> { current_user&.id || visitor_ip },
    with: -> {
      redirect_to correctable_path,
        alert: "Thanks — you've sent us several corrections just now. Please try again shortly."
    },
    store: Rails.application.config.x.rate_limit_store,
    name: "corrections-create",
    only: [:create]

  def new
    @indexable = false
    @fields = @record.class.correctable_fields.values
  end

  def create
    return redirect_to(correctable_path, notice: submitted_message) if honeypot_filled?

    result = Services::Corrections::Submission.call(
      record: @record,
      field_params: field_params,
      notes: params.dig(:correction, :notes),
      user: current_user,
      submitter_ip: visitor_ip
    )

    if result.success?
      redirect_to correctable_path, notice: submitted_message
    else
      @indexable = false
      @fields = @record.class.correctable_fields.values
      flash.now[:alert] = result.errors.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_record
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    @record = klass.find_by!(slug: params[:slug])
  end

  def set_record_from_params
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    # find_by!(id:), NEVER find. Books::Book is friendly_id with :finders, so
    # find("123") resolves the SLUG "123" before the primary key -- and this corpus
    # has 137 purely-numeric slugs, so `find` would file corrections against the
    # wrong book. Same trap the Amazon work hit.
    @record = klass.find_by!(id: params[:correctable_id])
  end

  # A bot fills every input it finds. A filled honeypot is discarded, and the
  # caller still gets the ordinary success redirect -- a 200 stops a bot retrying,
  # where a 422 brings it back.
  def honeypot_filled?
    params[:website].present?
  end

  def field_params
    submitted = params.dig(:correction, :fields)
    return {} if submitted.blank?

    # permit! then to_h, not permit(a list): the field set is per-model and comes
    # from the declaration, and Submission already drops every key that is not
    # declared. Permitting a computed list here would be the same allowlist,
    # written twice.
    submitted.permit!.to_h
  end

  # Hardcoded to books until there is a second correctable domain. Task 16 replaces
  # this with a lookup; generalising it before there is a second case would be
  # guessing at the shape.
  def correctable_path
    book_path(slug: @record.slug)
  end

  def submitted_message
    "Thanks — we've got your correction and we'll review it."
  end

  def domain_layout
    "#{Current.domain}/application"
  end
end
```

Note `correctable_path` hardcodes `book_path` for now. Task 18 replaces it with a registry lookup when a second domain is wired; leaving it concrete until there is a second case is deliberate.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/controllers/corrections_controller_test.rb
```

Expected: PASS.

- [ ] **Step 5: Prove three tests are not vacuous**

- Change `by:` to `-> { request.remote_ip }` — "records the Cloudflare connecting ip" still passes (it tests the model column), so instead delete `submitter_ip: visitor_ip` from the `Submission.call` and confirm that test goes RED. Restore.
- Delete the `honeypot_filled?` guard — "silently discards" must go RED. Restore.
- Change `protect_from_forgery with: :null_session` to `with: :exception` — "accepts a submission with no csrf token" must go RED. Restore.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/controllers/corrections_controller.rb
bin/rails test test/controllers/
git add -A
git commit -m "Add correction create with rate limiting and honeypot"
```

---

## Task 10: Stimulus controller and the book page link

**Files:**
- Create: `app/javascript/controllers/corrections/form_controller.js`
- Modify: `app/javascript/manifests/books_web.js`
- Modify: `app/views/books/books/show.html.erb`
- Create: `e2e/tests/books/corrections.spec.ts`

**Interfaces:**
- Consumes: `correction_token_path` from Task 8.
- Produces: Stimulus controller registered as `corrections--form`, with value `tokenUrl`, targets `form` and `list`, actions `addListItem` and `removeListItem`.

- [ ] **Step 1: Write the Stimulus controller**

`app/javascript/controllers/corrections/form_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// The correction form page is edge-cached, so the authenticity_token rendered
// into it belongs to whoever populated the cache, or to nobody. This fetches a
// real one for this visitor's session and writes it into the form.
//
// Fetched on FIRST INTERACTION, not on connect: this page is public and has been
// used to flood the origin, and /correction_token is the only uncached endpoint
// it still touches. A crawler or a flood that never focuses an input never
// reaches it.
//
// If the fetch fails there is deliberately no error shown and no submit blocked:
// the server's protect_from_forgery :null_session accepts the write as anonymous.
// Losing attribution is a better outcome than a 422 the submitter cannot act on.
export default class extends Controller {
  static targets = ["form", "list"]
  static values = { tokenUrl: String }

  connect() {
    this.tokenFetched = false
    this._inflight = null
  }

  // Wired from the form element's focusin, so any input reaching focus arms it.
  ensureToken() {
    if (this.tokenFetched) return this._inflight
    if (this._inflight) return this._inflight

    this._inflight = this._fetchToken().finally(() => {
      this._inflight = null
    })
    return this._inflight
  }

  async _fetchToken() {
    let response
    try {
      response = await fetch(this.tokenUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("corrections--form: token fetch failed", err)
      return
    }

    if (!response.ok) return

    const data = await response.json()
    if (!data.csrf_token) return

    this.tokenFetched = true
    this._applyToken(data.csrf_token)
  }

  _applyToken(token) {
    const field = this.formTarget.querySelector('input[name="authenticity_token"]')
    if (field) field.value = token

    // Also patch the page meta tag: the cached page's token is stale for any
    // other Turbo request on this page too. Same as reviews/widget_controller.
    const meta = document.querySelector('meta[name="csrf-token"]')
    if (meta) meta.setAttribute("content", token)
  }

  addListItem(event) {
    const field = event.currentTarget.dataset.field
    const list = this.listTargets.find((el) => el.dataset.field === field)
    if (!list) return

    const row = document.createElement("div")
    row.className = "join w-full"

    const input = document.createElement("input")
    input.type = "text"
    input.name = `correction[fields][${field}][]`
    input.className = "input join-item w-full"

    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn join-item"
    button.dataset.action = "corrections--form#removeListItem"
    button.textContent = "Remove"

    // createElement + textContent throughout rather than innerHTML: `field` comes
    // from a data attribute, and building markup by string concatenation is how a
    // template ends up interpolating something it should not.
    row.append(input, button)
    list.append(row)
    input.focus()
  }

  removeListItem(event) {
    event.currentTarget.closest(".join")?.remove()
  }
}
```

- [ ] **Step 2: Register it**

Append to `app/javascript/manifests/books_web.js`:

```javascript
import Corrections__FormController from "../controllers/corrections/form_controller"
application.register("corrections--form", Corrections__FormController)
```

- [ ] **Step 3: Arm the token fetch from the form**

In `app/views/corrections/new.html.erb`, add `focusin` to the wrapper div's controller declaration:

```erb
<div class="max-w-2xl mx-auto space-y-6" data-controller="corrections--form"
     data-corrections--form-token-url-value="<%= correction_token_path %>"
     data-action="focusin->corrections--form#ensureToken">
```

- [ ] **Step 4: Add the link to the book page**

In `app/views/books/books/show.html.erb`, immediately after the `render "books/books/details"` line:

```erb
    <%# A plain link, not a form: this page is edge-cached with the session
        skipped, so a form here would carry no usable CSRF token. %>
    <p class="text-sm">
      <%= link_to "Suggest a correction",
            books_book_correction_path(slug: @book.slug),
            class: "link", data: {testid: "suggest-correction-link"} %>
    </p>
```

- [ ] **Step 5: Build and check the bundle**

```bash
cd web-app
yarn build:all
```

Expected: no build errors.

- [ ] **Step 6: Write the E2E test**

`e2e/tests/books/corrections.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Suggest a correction', () => {
  test('the book page links to the correction form', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    await page.getByTestId('suggest-correction-link').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace\/suggest-correction$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Suggest a correction' })).toBeVisible();
  });

  test('the form is not indexable', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    const robots = page.locator('meta[name="robots"]');
    await expect(robots).toHaveAttribute('content', 'noindex, follow');
  });

  test('an anonymous visitor can submit notes', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    await page.getByRole('textbox').first().fill('The first published year looks wrong.');
    await page.getByTestId('correction-submit').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace$/);
    await expect(page.getByText(/we've got your correction/i)).toBeVisible();
  });

  test('an anonymous visitor can propose a field change', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    // Wait for the token fetch armed by focusin before submitting.
    const yearInput = page.locator('#correction_fields_first_published_year');
    await yearInput.click();
    await yearInput.fill('1867');
    await page.getByTestId('correction-submit').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace$/);
    await expect(page.getByText(/we've got your correction/i)).toBeVisible();
  });

  test('an alternate title row can be added and removed', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    const list = page.locator('[data-corrections--form-target="list"][data-field="alternate_titles"]');
    const before = await list.locator('input').count();

    await page.getByRole('button', { name: /^Add alternate title$/ }).click();
    await expect(list.locator('input')).toHaveCount(before + 1);

    await list.locator('button', { hasText: 'Remove' }).last().click();
    await expect(list.locator('input')).toHaveCount(before);
  });
});
```

- [ ] **Step 7: Run the E2E test**

Start the dev server in one shell, then:

```bash
cd web-app
yarn test:e2e e2e/tests/books/corrections.spec.ts
```

Expected: PASS. E2E needs a running local server and `e2e/.env`; CI does not run it.

- [ ] **Step 8: Prove the link test is not vacuous**

Delete the `books_book_correction_path` link from `show.html.erb`, re-run the first E2E test, confirm RED. Restore.

- [ ] **Step 9: Run the Rails suite, lint, commit**

```bash
cd web-app
bin/rails test
bundle exec standardrb
git add -A
git commit -m "Add correction form Stimulus controller and book page link"
```

---

## Task 11: Admin index

**Files:**
- Create: `app/controllers/admin/corrections_controller.rb`
- Create: `app/views/admin/corrections/index.html.erb`, `app/views/admin/corrections/_row.html.erb`
- Modify: `config/routes.rb`, `app/lib/admin/domain_nav.rb`
- Test: `test/controllers/admin/corrections_controller_test.rb`

**Interfaces:**
- Consumes: `TypeRegistry.types_for_domain`, `Correction`.
- Produces: routes `admin_books_corrections_path`, `admin_books_correction_path(id)`. `#index` assigns `@corrections`, `@pagy`, `@status`, `@counts` (a `Hash<String, Integer>` keyed by status name).

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside `namespace :admin, module: "admin/books", as: "admin_books"`, beside `resources :reviews`:

```ruby
      # Shared controller, routed per domain -- same shape as descriptions and
      # category items. The domain comes from the route, so the index can scope to
      # this domain's correctable types.
      resources :corrections, only: [:index, :show], controller: "/admin/corrections" do
        member do
          post :apply
          post :reject
          post :resolve
        end
        collection do
          post :bulk_reject
        end
      end
```

- [ ] **Step 2: Add the sidebar entry**

In `app/lib/admin/domain_nav.rb`, add to `CONFIGS[:books][:items]`, after the Reviews line:

```ruby
          {label: "Corrections", icon: :chat, path: -> { URL_HELPERS.admin_books_corrections_path }},
```

- [ ] **Step 3: Write the failing test**

`test/controllers/admin/corrections_controller_test.rb`.

**`rails-controller-testing` is NOT in this app's Gemfile**, so `assigns(...)` is unavailable. These assert against the rendered rows via `css_select` on stable `data-` hooks, which `rails-dom-testing` provides out of the box. That is also the better test: it proves the page actually renders what the scope returned, not just that an ivar was set.

```ruby
require "test_helper"

module Admin
  class CorrectionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @admin = users(:admin_user)
      sign_in_as(@admin, stub_auth: true)
    end

    # Reads an attribute off every rendered correction row.
    def row_values(attribute)
      css_select("[data-testid=correction-row]").map { |row| row[attribute] }
    end

    def row_ids
      row_values("data-correction-id").map(&:to_i)
    end

    test "index defaults to pending" do
      get admin_books_corrections_path

      assert_response :success
      assert_not_empty row_values("data-status")
      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index filters by status" do
      get admin_books_corrections_path(status: "rejected")

      assert_not_empty row_values("data-status")
      assert_equal %w[rejected], row_values("data-status").uniq
    end

    test "index ignores an unknown status and falls back to pending" do
      get admin_books_corrections_path(status: "nonsense")

      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index reports counts for every status" do
      get admin_books_corrections_path

      assert_select "[data-testid=status-count-pending]",
        text: Correction.where(status: :pending).count.to_s
      assert_select "[data-testid=status-count-rejected]",
        text: Correction.where(status: :rejected).count.to_s
    end

    test "index scopes to this domain's correctable types" do
      get admin_books_corrections_path

      assert_not_empty row_values("data-correctable-type")
      assert_equal ["Books::Book"], row_values("data-correctable-type").uniq
    end

    test "index searches notes" do
      get admin_books_corrections_path(status: "rejected", q: "watches")

      assert_includes row_ids, corrections(:crime_rejected).id
    end

    test "index excludes corrections whose notes do not match the search" do
      get admin_books_corrections_path(status: "pending", q: "zzzznomatch")

      assert_empty row_ids
    end

    test "show renders" do
      get admin_books_correction_path(corrections(:war_and_peace_pending))

      assert_response :success
    end

    test "turns away a user with no books access" do
      sign_in_as(users(:games_editor_user), stub_auth: true)
      get admin_books_corrections_path

      assert_response :redirect
    end
  end
end
```

The two `assert_not_empty` guards are load-bearing. `assert_equal %w[pending], [].uniq` would fail, but `assert_empty`-shaped assertions on an empty collection are exactly how this repo has shipped tests that passed against deleted code — an empty page must never read as a pass here.

- [ ] **Step 4: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/controllers/admin/corrections_controller_test.rb
```

Expected: FAIL — no controller.

- [ ] **Step 5: Write the controller's index and show**

`app/controllers/admin/corrections_controller.rb`:

```ruby
class Admin::CorrectionsController < Admin::BaseController
  include Admin::DomainScopedAuth
  include Pagy::Method

  before_action :set_correction, only: [:show, :apply, :reject, :resolve]

  STATUSES = %w[pending resolved rejected].freeze

  def index
    # Defaults to pending. Legacy's index was every changeset ever, newest first,
    # which is a log rather than a queue.
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @corrections = pagy(filtered_scope)
  end

  def show
    @fields = @correction.correction_fields.order(:field_name)
    @record = @correction.correctable
  end

  private

  def domain_scope
    ::Correction.where(correctable_type: Services::Corrections::TypeRegistry.types_for_domain(current_domain))
  end

  def filtered_scope
    scope = domain_scope.where(status: @status).includes(:user, :correction_fields, :correctable).recent
    return scope if params[:q].blank?

    scope.where("corrections.notes ILIKE ?", "%#{::ActiveRecord::Base.sanitize_sql_like(params[:q])}%")
  end

  def set_correction
    @correction = domain_scope.find(params[:id])
  end

  # Authorize against the corrected RECORD's domain, not the request host --
  # same rule as Admin::DescriptionsController.
  def domain_auth_parent
    return nil if params[:id].blank?

    ::Correction.find_by(id: params[:id])&.correctable
  end
end
```

- [ ] **Step 6: Write the index view**

`app/views/admin/corrections/index.html.erb`:

```erb
<div class="space-y-4">
  <h1 class="text-2xl font-bold">Corrections</h1>

  <div role="tablist" class="tabs tabs-border">
    <% Admin::CorrectionsController::STATUSES.each do |status| %>
      <%= link_to admin_books_corrections_path(status: status, q: params[:q]),
            role: "tab",
            class: "tab #{"tab-active" if @status == status}",
            data: {testid: "status-tab-#{status}"} do %>
        <%= status.titleize %>
        <span class="badge badge-sm ml-2"
              data-testid="status-count-<%= status %>"><%= @counts[status].to_i %></span>
      <% end %>
    <% end %>
  </div>

  <%= form_with url: admin_books_corrections_path, method: :get, class: "flex gap-2" do %>
    <%= hidden_field_tag :status, @status %>
    <%= text_field_tag :q, params[:q], placeholder: "Search notes", class: "input w-full max-w-xs" %>
    <%= submit_tag "Search", class: "btn" %>
  <% end %>

  <%= form_with url: bulk_reject_admin_books_corrections_path, method: :post do %>
    <%= hidden_field_tag :status, @status %>
    <div class="overflow-x-auto">
      <table class="table bg-base-100">
        <thead>
          <tr>
            <th></th>
            <th>Record</th>
            <th>Proposed</th>
            <th>From</th>
            <th>Submitted</th>
          </tr>
        </thead>
        <tbody>
          <%= render partial: "admin/corrections/row", collection: @corrections, as: :correction %>
        </tbody>
      </table>
    </div>

    <% if @status == "pending" && @corrections.any? %>
      <%= submit_tag "Reject selected", class: "btn btn-warning mt-3",
            data: {turbo_confirm: "Reject the selected corrections?", testid: "bulk-reject"} %>
    <% end %>
  <% end %>

  <%== @pagy.series_nav %>
</div>
```

`app/views/admin/corrections/_row.html.erb`:

```erb
<%# The data- attributes are stable test hooks: the tests assert on these rather
    than on any visible text, which a designer must stay free to change. %>
<tr data-testid="correction-row"
    data-correction-id="<%= correction.id %>"
    data-status="<%= correction.status %>"
    data-correctable-type="<%= correction.correctable_type %>">
  <td>
    <% if correction.pending? %>
      <%= check_box_tag "correction_ids[]", correction.id, false, class: "checkbox checkbox-sm" %>
    <% end %>
  </td>
  <td>
    <%= link_to correction.correctable&.title || "(deleted)",
          admin_books_correction_path(correction), class: "link" %>
  </td>
  <td class="text-sm">
    <%= correction.correction_fields.map(&:field_name).map(&:humanize).to_sentence.presence || "—" %>
    <% if correction.notes.present? %>
      <span class="badge badge-ghost badge-sm">notes</span>
    <% end %>
  </td>
  <td class="text-sm"><%= correction.user&.email || "Anonymous" %></td>
  <td class="text-sm"><%= time_ago_in_words(correction.created_at) %> ago</td>
</tr>
```

The table is inside a `form_with`, not a Turbo Frame, so the trapped-links rule does not apply — but run the guard anyway in Step 7.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/controllers/admin/corrections_controller_test.rb test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS.

- [ ] **Step 8: Prove the status filter is not vacuous**

Domain scoping cannot be tested non-vacuously while books is the only correctable domain — Task 16 Step 7 is where that assertion gets real teeth, and wiring a second model here just to revert it buys no coverage. Verify the filter instead: change `filtered_scope`'s `.where(status: @status)` to `.all`, re-run, and confirm both "index defaults to pending" and "index filters by status" go RED. Restore.

- [ ] **Step 9: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/controllers/admin/corrections_controller.rb app/lib/admin/domain_nav.rb
git add -A
git commit -m "Add admin corrections index"
```

---

## Task 12: Admin show, apply, reject, resolve, bulk reject

**Files:**
- Modify: `app/controllers/admin/corrections_controller.rb`
- Create: `app/views/admin/corrections/show.html.erb`
- Test: `test/controllers/admin/corrections_controller_test.rb`

**Interfaces:**
- Consumes: `Services::Corrections::Applier` from Task 7.
- Produces: `POST apply` (params `accepted[<field_name>]`), `POST reject` (param `resolution_notes`), `POST resolve`, `POST bulk_reject` (param `correction_ids[]`).

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/corrections_controller_test.rb`.

The review form submits two things per row: a checkbox in `accepted_fields[]` naming the accepted field, and an input in `accepted[<name>]` carrying the value. Both are needed — every row's input submits a value whether or not its box is ticked, so the checkbox list is what makes unticking mean anything.

```ruby
    test "apply writes the accepted fields and resolves" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["first_published_year"], accepted: {first_published_year: "1867"}}

      assert_redirected_to admin_books_correction_path(correction)
      assert_equal 1867, books_books(:war_and_peace).reload.first_published_year
      assert_predicate correction.reload, :resolved?
    end

    # The unticked row still submits its value. Without the checkbox list, this
    # would silently apply the title too.
    test "apply rejects a field whose box was not ticked, even though its input was submitted" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {
          accepted_fields: ["first_published_year"],
          accepted: {first_published_year: "1867", title: "War & Peace"}
        }

      assert_predicate correction.reload.correction_fields.find_by(field_name: "title"), :rejected?
      assert_equal "War and Peace", books_books(:war_and_peace).reload.title
    end

    test "apply writes the admin's edited value" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["title"], accepted: {title: "War & Peace, Revised"}}

      assert_equal "War & Peace, Revised", books_books(:war_and_peace).reload.title
    end

    test "apply splits a comma-joined array field" do
      correction = ::Correction.create!(correctable: books_books(:war_and_peace),
        correction_fields_attributes: [{field_name: "alternate_titles",
                                        old_value: ["Voyna i mir"],
                                        new_value: ["Voyna i mir", "War & Peace"]}])

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["alternate_titles"],
                 accepted: {alternate_titles: ["Voyna i mir, War & Peace"]}}

      assert_equal ["Voyna i mir", "War & Peace"], books_books(:war_and_peace).reload.alternate_titles
    end

    test "apply reports validation errors without changing anything" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["title"], accepted: {title: ""}}

      assert_predicate correction.reload, :pending?
      assert_match(/can't be blank/, flash[:alert])
    end

    test "reject stores the reason and does not touch the record" do
      correction = corrections(:war_and_peace_pending)

      post reject_admin_books_correction_path(correction), params: {resolution_notes: "Not supported by any source"}

      correction.reload
      assert_predicate correction, :rejected?
      assert_equal "Not supported by any source", correction.resolution_notes
      assert_equal 1869, books_books(:war_and_peace).reload.first_published_year
      assert correction.correction_fields.all?(&:rejected?)
    end

    test "resolve closes a notes-only correction fixed by hand" do
      correction = corrections(:war_and_peace_notes_only)

      post resolve_admin_books_correction_path(correction)

      assert_predicate correction.reload, :resolved?
      assert_equal @admin, correction.resolved_by
    end

    test "bulk reject closes several at once" do
      ids = [corrections(:war_and_peace_pending).id, corrections(:war_and_peace_notes_only).id]

      post bulk_reject_admin_books_corrections_path, params: {correction_ids: ids}

      assert_equal %w[rejected rejected], Correction.where(id: ids).map(&:status)
    end

    test "bulk reject ignores ids outside this domain" do
      other = Correction.create!(correctable: books_books(:got), notes: "x")
      post bulk_reject_admin_books_corrections_path, params: {correction_ids: [other.id, 999_999]}

      assert_predicate other.reload, :rejected?
    end

    test "a domain user without write access cannot apply" do
      sign_in_as(users(:games_editor_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction), params: {accepted: {}}

      assert_response :redirect
      assert_predicate correction.reload, :pending?
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd web-app
bin/rails test test/controllers/admin/corrections_controller_test.rb
```

Expected: FAIL — no `apply` action.

- [ ] **Step 3: Add the actions**

In `app/controllers/admin/corrections_controller.rb`, add the write guard and the four actions:

```ruby
  before_action :require_domain_write!, only: [:apply, :reject, :resolve, :bulk_reject]
```

```ruby
  def apply
    result = Services::Corrections::Applier.call(
      correction: @correction, accepted: accepted_params, admin: current_user
    )

    if result.success?
      redirect_to admin_books_correction_path(@correction), notice: "Correction applied."
    else
      redirect_to admin_books_correction_path(@correction),
        alert: "Could not apply: #{result.errors.to_sentence}"
    end
  end

  def reject
    ::Correction.transaction do
      @correction.correction_fields.update_all(status: ::CorrectionField.statuses[:rejected])
      @correction.update!(
        status: :rejected, resolved_by: current_user, resolved_at: Time.current,
        resolution_notes: params[:resolution_notes].presence
      )
    end

    redirect_to admin_books_corrections_path, notice: "Correction rejected."
  end

  # For a notes-only correction the admin acted on by hand -- there is nothing for
  # the applier to write, but the queue must stop showing it.
  def resolve
    @correction.update!(
      status: :resolved, resolved_by: current_user, resolved_at: Time.current,
      resolution_notes: params[:resolution_notes].presence
    )

    redirect_to admin_books_corrections_path, notice: "Correction marked resolved."
  end

  def bulk_reject
    scope = domain_scope.where(id: params[:correction_ids], status: :pending)
    count = scope.count

    ::Correction.transaction do
      ::CorrectionField.where(correction_id: scope.select(:id))
        .update_all(status: ::CorrectionField.statuses[:rejected])
      scope.update_all(
        status: ::Correction.statuses[:rejected], resolved_by_id: current_user.id,
        resolved_at: Time.current, updated_at: Time.current
      )
    end

    redirect_to admin_books_corrections_path(status: params[:status]),
      notice: "Rejected #{count} #{"correction".pluralize(count)}."
  end
```

and in `private`:

```ruby
  # The review form submits a checkbox per accepted field in accepted_fields[],
  # and every row's value in accepted[<name>] whether ticked or not. Slicing by the
  # checkbox list is what makes UNTICKING a box mean anything -- without it, an
  # unticked row's still-submitted input would be applied anyway.
  #
  # permit! is safe: the applier checks every field name against the record's own
  # declaration, so restating an allowlist here would be the same list written twice.
  def accepted_params
    names = Array(params[:accepted_fields])
    return {} if names.empty?

    submitted = params[:accepted].present? ? params[:accepted].permit!.to_h : {}
    submitted.slice(*names).transform_values { |value| normalize_accepted(value) }
  end

  # An array field is edited as ONE comma-separated input, so it arrives as
  # ["a, b"] -- which ValueCaster would faithfully turn into a single-element
  # array containing a comma. Splitting here keeps the review form to one input
  # per field instead of a repeatable list the admin has to manage.
  def normalize_accepted(value)
    return value unless value.is_a?(Array) && value.size == 1

    value.first.to_s.split(",")
  end
```

`update_all` here is deliberate and safe — it is scoped to specific ids in the admin, not a bulk wipe. The dev-database hook blocks `update_all` inside `rails runner`, not inside application code.

- [ ] **Step 4: Write the show view**

`app/views/admin/corrections/show.html.erb`:

```erb
<div class="space-y-6 max-w-4xl">
  <div class="flex items-start justify-between gap-4">
    <div>
      <h1 class="text-2xl font-bold">Correction #<%= @correction.id %></h1>
      <p class="text-sm text-base-content/70 mt-1">
        <%= @correction.user&.email || "Anonymous" %>
        · <%= @correction.created_at.strftime("%B %-d, %Y at %H:%M") %>
        <% if @correction.submitter_ip.present? %>· <%= @correction.submitter_ip %><% end %>
      </p>
    </div>
    <span class="badge"><%= @correction.status.titleize %></span>
  </div>

  <% if @record %>
    <div class="flex gap-2">
      <%= link_to "Open in admin", Admin::DomainRouting.path_for(@record), class: "btn btn-sm" %>
      <%= link_to "View public page", book_path(slug: @record.slug), class: "btn btn-sm btn-ghost" %>
    </div>
  <% else %>
    <div class="alert alert-warning">The corrected record no longer exists.</div>
  <% end %>

  <%# Notes first and full width: 111 of the 236 pending legacy corrections are
      notes-only, so this is the primary content, not a footnote under a table. %>
  <div class="card bg-base-100 shadow-md">
    <div class="card-body">
      <h2 class="card-title text-lg">Notes</h2>
      <% if @correction.notes.present? %>
        <p class="[overflow-wrap:anywhere] whitespace-pre-line"><%= @correction.notes %></p>
      <% else %>
        <p class="text-base-content/70">No notes.</p>
      <% end %>
    </div>
  </div>

  <% if @fields.any? && @record %>
    <%= form_with url: apply_admin_books_correction_path(@correction), method: :post do %>
      <div class="card bg-base-100 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-lg">Proposed changes</h2>
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Accept</th>
                  <th>Field</th>
                  <th>Was</th>
                  <th>Is now</th>
                  <th>Proposed</th>
                </tr>
              </thead>
              <tbody>
                <% @fields.each do |field| %>
                  <% definition = @record.class.correctable_fields[field.field_name] %>
                  <% next if definition.nil? %>
                  <% current = Services::Corrections::Targets.for(definition.target).read(@record, field.field_name) %>
                  <% stale = current.to_s != field.old_value.to_s %>
                  <tr data-testid="correction-field-row" data-field="<%= field.field_name %>">
                    <td>
                      <%= check_box_tag "accepted_fields[]", field.field_name, @correction.pending?,
                            class: "checkbox", disabled: !@correction.pending? %>
                    </td>
                    <td><%= definition.label %></td>
                    <td class="text-sm text-base-content/70 [overflow-wrap:anywhere]"><%= field.old_value.inspect %></td>
                    <td class="text-sm [overflow-wrap:anywhere] <%= "text-warning font-semibold" if stale %>">
                      <%= current.inspect %>
                      <%# Flagged, not blocked. With a backlog reaching back to Oct
                          2024 over books that have since been through the
                          description migration and Amazon enrichment, a stale
                          "Was" is the normal case -- the admin's judgement is the
                          point. %>
                      <% if stale %>
                        <span class="badge badge-warning badge-sm" data-testid="stale-flag">changed since</span>
                      <% end %>
                    </td>
                    <td>
                      <% if definition.type == :string_array %>
                        <%= text_field_tag "accepted[#{field.field_name}][]", Array(field.new_value).join(", "),
                              class: "input input-sm w-full", disabled: !@correction.pending? %>
                      <% elsif definition.type == :text %>
                        <%= text_area_tag "accepted[#{field.field_name}]", field.new_value, rows: 4,
                              class: "textarea w-full", disabled: !@correction.pending? %>
                      <% else %>
                        <%= text_field_tag "accepted[#{field.field_name}]", field.new_value,
                              class: "input input-sm w-full", disabled: !@correction.pending? %>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <% if @correction.pending? %>
            <div class="card-actions mt-4">
              <%= submit_tag "Apply checked fields", class: "btn btn-primary",
                    data: {testid: "apply-correction"} %>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
  <% end %>

  <% if @correction.pending? %>
    <div class="flex flex-wrap gap-2">
      <%= form_with url: resolve_admin_books_correction_path(@correction), method: :post do %>
        <%= submit_tag "Mark resolved", class: "btn", data: {testid: "resolve-correction"} %>
      <% end %>

      <%= form_with url: reject_admin_books_correction_path(@correction), method: :post, class: "flex gap-2" do %>
        <%= text_field_tag :resolution_notes, nil, placeholder: "Reason (optional)", class: "input" %>
        <%= submit_tag "Reject", class: "btn btn-warning", data: {testid: "reject-correction"} %>
      <% end %>
    </div>
  <% elsif @correction.resolution_notes.present? %>
    <div class="alert"><%= @correction.resolution_notes %></div>
  <% end %>
</div>
```

The checkbox name is `accepted_fields[]` and the value input is `accepted[<name>]` — `accepted_params` in Step 3 reconciles the two.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/controllers/admin/corrections_controller_test.rb test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS.

- [ ] **Step 6: Prove the accept-checkbox logic is not vacuous**

Delete the `.slice(*names)` from `accepted_params`. Re-run — "apply rejects the fields that were not accepted" must go RED. Restore.

- [ ] **Step 7: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/controllers/admin/corrections_controller.rb
bin/rails test
git add -A
git commit -m "Add admin correction apply, reject, resolve and bulk reject"
```

---

## Task 13: Admin E2E test

**Files:**
- Create: `e2e/tests/books/admin/corrections.spec.ts`

- [ ] **Step 1: Check the admin E2E conventions**

```bash
cd web-app
ls e2e/tests/books/admin/
head -30 e2e/tests/books/admin/$(ls e2e/tests/books/admin/ | head -1)
```

Follow whatever auth setup those use. If the admin user is missing, run `bin/rails e2e:admin`.

- [ ] **Step 2: Write the test**

`e2e/tests/books/admin/corrections.spec.ts`, matching the auth pattern found in Step 1:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Admin corrections', () => {
  test('a submitted correction appears in the pending queue and can be applied', async ({ page }) => {
    // Submit one from the public form so the test drives the real flow end to end.
    await page.goto('/book/crime-and-punishment/suggest-correction');
    const subtitle = page.locator('#correction_fields_subtitle');
    await subtitle.click();
    await subtitle.fill('A Novel in Six Parts');
    await page.getByTestId('correction-submit').click();
    await expect(page.getByText(/we've got your correction/i)).toBeVisible();

    await page.goto('/admin/corrections');
    await expect(page.getByTestId('status-tab-pending')).toBeVisible();

    await page.getByTestId('correction-row').first().getByRole('link').click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Correction #/);

    await page.getByTestId('apply-correction').click();
    await expect(page.getByText('Correction applied.')).toBeVisible();

    await page.goto('/book/crime-and-punishment');
    await expect(page.getByText('A Novel in Six Parts')).toBeVisible();
  });

  test('a correction can be rejected with a reason', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');
    await page.getByRole('textbox').first().fill('E2E reject case');
    await page.getByTestId('correction-submit').click();

    await page.goto('/admin/corrections');
    await page.getByTestId('correction-row').first().getByRole('link').click();
    await page.getByTestId('reject-correction').click();

    await expect(page.getByText('Correction rejected.')).toBeVisible();
  });
});
```

- [ ] **Step 3: Run it**

```bash
cd web-app
yarn test:e2e e2e/tests/books/admin/corrections.spec.ts
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add admin corrections E2E test"
```

---

## Task 14: Email notification

**Files:**
- Modify: `app/mailers/admin_mailer.rb`, `app/controllers/corrections_controller.rb`
- Create: `app/views/admin_mailer/new_correction.html.erb`, `app/views/admin_mailer/new_correction.text.erb`
- Test: `test/mailers/admin_mailer_test.rb`, `test/controllers/corrections_controller_test.rb`

**Interfaces:**
- Consumes: `Correction`, `TypeRegistry.domain_for`, `MailBranding`.
- Produces: `AdminMailer.new_correction(correction)`.

- [ ] **Step 1: Write the failing mailer tests**

Append to `test/mailers/admin_mailer_test.rb` (its setup already sets `ADMIN_NOTIFICATION_EMAIL`):

```ruby
  test "new_correction goes to the admin address" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_equal ["owner@example.org"], mail.to
    assert_match(/Correction/, mail.subject)
  end

  test "new_correction is branded for the record's domain" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_match(/The Greatest Books/, mail[:from].to_s)
  end

  test "new_correction replies to a signed-in submitter" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))

    assert_equal [users(:regular_user).email], mail.reply_to
  end

  test "new_correction sets no reply_to for an anonymous submitter" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_notes_only))

    assert_nil mail.reply_to
  end

  test "new_correction includes the notes and the proposed fields" do
    mail = AdminMailer.new_correction(corrections(:war_and_peace_pending))
    body = mail.text_part.body.to_s

    assert_match(/first published year/i, body)
    assert_match(/1867/, body)
    assert_match(/The first published year looks wrong/, body)
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd web-app
bin/rails test test/mailers/admin_mailer_test.rb
```

Expected: FAIL — no `new_correction`.

- [ ] **Step 3: Add the mailer action**

In `app/mailers/admin_mailer.rb`, beside the other actions:

```ruby
  def new_correction(correction)
    @correction = correction
    @record = correction.correctable
    @fields = correction.correction_fields.order(:field_name)
    domain = Services::Corrections::TypeRegistry.domain_for(correction.correctable_type)
    @site_name = MailBranding.for(domain).site_name

    branded_mail(
      domain: domain,
      to: admin_address,
      subject: "New correction on #{@site_name}",
      # Only when a real account submitted it. An anonymous correction has no
      # address, and an unverified one would not be a reply channel anyway.
      reply_to: correction.user&.email
    )
  end
```

`branded_mail` passes options straight to `mail`, and Rails drops a nil `reply_to`, so no branch is needed.

- [ ] **Step 4: Write the templates**

`app/views/admin_mailer/new_correction.text.erb`:

```erb
A new correction was submitted on <%= @site_name %>.

Record:    <%= @record&.title || "(deleted)" %>
Submitted: <%= @correction.created_at.strftime("%B %-d, %Y at %H:%M") %>
By:        <%= @correction.user&.email || "Anonymous" %>

Notes:
<%= @correction.notes.presence || "(none)" %>

<% if @fields.any? -%>
Proposed changes:
<% @fields.each do |field| -%>
  <%= field.field_name.humanize %>: <%= field.old_value.inspect %> -> <%= field.new_value.inspect %>
<% end -%>
<% else -%>
Proposed changes: (none — notes only)
<% end -%>

Review it: <%= admin_books_correction_url(@correction) %>
```

`app/views/admin_mailer/new_correction.html.erb`. The `mailer` layout supplies all the wrapper markup and branding, so the neighbouring `new_donation.html.erb` is a bare `<p>` plus a `<ul>` — match that, no inline styles:

```erb
<p>A new correction was submitted on <%= @site_name %>.</p>

<ul>
  <li>Record: <%= @record&.title || "(deleted)" %></li>
  <li>Submitted: <%= @correction.created_at.strftime("%B %-d, %Y at %H:%M") %></li>
  <li>By: <%= @correction.user&.email || "Anonymous" %></li>
</ul>

<p><strong>Notes</strong><br>
<%= simple_format(@correction.notes.presence || "(none)") %></p>

<% if @fields.any? %>
  <p><strong>Proposed changes</strong></p>
  <ul>
    <% @fields.each do |field| %>
      <li><%= field.field_name.humanize %>: <%= field.old_value.inspect %> &rarr; <%= field.new_value.inspect %></li>
    <% end %>
  </ul>
<% else %>
  <p><strong>Proposed changes:</strong> none — notes only.</p>
<% end %>

<p><%= link_to "Review this correction", admin_books_correction_url(@correction) %></p>
```

`admin_books_correction_url` (not `_path`) — a mailer link must be absolute. `branded_mail` sets `default_url_options` from the domain's branding, so the host is right for whichever site the correction came from.

- [ ] **Step 5: Enqueue it from create**

In `CorrectionsController#create`, inside the `if result.success?` branch, before the redirect:

```ruby
      # deliver_later, not deliver_now: legacy built and sent this inline in the
      # request, which blocked the submitter on SendGrid and had no retry.
      AdminMailer.new_correction(result.data).deliver_later
```

- [ ] **Step 6: Add the controller test**

Append to `test/controllers/corrections_controller_test.rb`:

```ruby
  test "emails the owner on a successful submission" do
    with_env("ADMIN_NOTIFICATION_EMAIL" => "owner@example.org") do
      assert_emails 1 do
        submit
      end
    end
  end

  test "sends nothing when the submission fails" do
    assert_emails 0 do
      post corrections_path, params: {
        correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: ""}
      }
    end
  end

  test "sends nothing for a honeypot submission" do
    assert_emails 0 do
      submit(website: "http://spam.example")
    end
  end
```

Sidekiq runs inline in tests (`Sidekiq.testing!(:inline)`), so `deliver_later` delivers within `assert_emails`.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/mailers/admin_mailer_test.rb test/controllers/corrections_controller_test.rb
```

Expected: PASS.

- [ ] **Step 8: Prove the reply_to test is not vacuous**

Delete the `reply_to:` line from `new_correction`. Re-run — "replies to a signed-in submitter" must go RED. Restore.

- [ ] **Step 9: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/mailers/admin_mailer.rb app/controllers/corrections_controller.rb
git add -A
git commit -m "Email the owner on each new correction"
```

**Before this ships:** confirm `ADMIN_NOTIFICATION_EMAIL` resolves to `contact@thegreatestbooks.org` in production. If corrections need a different recipient, that is a second env var read in `new_correction`, not a design change.

---

## Task 15: Legacy changeset migration

**Files:**
- Create: `app/models/legacy_books/changeset.rb`
- Create: `app/lib/services/books_migration/correction_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/correction_migrator_test.rb`

**Interfaces:**
- Consumes: `Correction`, `CorrectionField`, `::Books::Book`.
- Produces: `Services::BooksMigration::CorrectionMigrator.call` → the standard migrator Result hash `{success: true, data: {model:, count:}}`.

**Legacy shape:** `changesets(id, changeable_type, changeable_id, user_id, change_data jsonb, notes text, status integer, applied_at, rejected_at, created_at, updated_at)`. 448 rows, ids 1–647, status 0 (pending, 236) or 3 (applied, 212), all `changeable_type = "Book"`.

**Field mapping:** `sub_title` → `subtitle`, `first_year_published` → `first_published_year`. `title`, `page_range`, `word_count`, `alternate_titles`, `description` carry over unchanged. `series_name`, `series_number`, `series`, `original_language` have no target and fold into notes.

- [ ] **Step 1: Read an existing legacy model for the pattern**

```bash
cd web-app
cat app/models/legacy_books/review.rb
cat app/models/legacy_books/record.rb
```

- [ ] **Step 2: Write the legacy model**

`app/models/legacy_books/changeset.rb`, following whatever base class `review.rb` uses:

```ruby
module LegacyBooks
  class Changeset < Record
    self.table_name = "changesets"
  end
end
```

- [ ] **Step 3: Write the failing test**

`test/lib/services/books_migration/correction_migrator_test.rb`. Every migrator test stubs `legacy_each` so the legacy connection is never opened.

```ruby
require "test_helper"

module Services
  module BooksMigration
    class CorrectionMigratorTest < ActiveSupport::TestCase
      def legacy_row(overrides = {})
        {
          "id" => 9001,
          "changeable_type" => "Book",
          "changeable_id" => ::Books::Book.first.id,
          "user_id" => nil,
          "change_data" => {},
          "notes" => "Something is wrong",
          "status" => 0,
          "applied_at" => nil,
          "created_at" => Time.zone.parse("2025-01-02 03:04:05"),
          "updated_at" => Time.zone.parse("2025-01-02 03:04:05")
        }.merge(overrides)
      end

      def migrate(rows)
        CorrectionMigrator.any_instance.stubs(:legacy_each).multiple_yields(*rows.map { |r| [r] })
        CorrectionMigrator.call
      end

      test "migrates a notes-only pending changeset" do
        result = migrate([legacy_row])

        assert result[:success]
        correction = ::Correction.find(9001)
        assert_predicate correction, :pending?
        assert_equal "Something is wrong", correction.notes
      end

      test "preserves the legacy id and timestamps" do
        migrate([legacy_row])

        correction = ::Correction.find(9001)
        assert_equal Time.zone.parse("2025-01-02 03:04:05"), correction.created_at
      end

      test "maps Book to Books::Book" do
        migrate([legacy_row])

        assert_equal "Books::Book", ::Correction.find(9001).correctable_type
      end

      test "maps an applied changeset to resolved with applied fields" do
        row = legacy_row(
          "status" => 3,
          "applied_at" => Time.zone.parse("2025-02-01 00:00:00"),
          "change_data" => {"title" => {"from" => "Old", "to" => "New"}}
        )
        migrate([row])

        correction = ::Correction.find(9001)
        assert_predicate correction, :resolved?
        field = correction.correction_fields.sole
        assert_predicate field, :applied?
        assert_equal Time.zone.parse("2025-02-01 00:00:00"), field.applied_at
      end

      test "renames sub_title and first_year_published" do
        row = legacy_row("change_data" => {
          "sub_title" => {"from" => nil, "to" => "A Novel"},
          "first_year_published" => {"from" => 1869, "to" => 1867}
        })
        migrate([row])

        assert_equal %w[first_published_year subtitle],
          ::Correction.find(9001).correction_fields.map(&:field_name).sort
      end

      test "keeps description as a real field proposal" do
        row = legacy_row("change_data" => {"description" => {"from" => "a", "to" => "b"}})
        migrate([row])

        assert_equal %w[description], ::Correction.find(9001).correction_fields.map(&:field_name)
      end

      test "folds an unmappable field into the notes rather than dropping it" do
        row = legacy_row("change_data" => {"series_name" => {"from" => nil, "to" => "Discworld"}})
        migrate([row])

        correction = ::Correction.find(9001)
        assert_empty correction.correction_fields
        assert_match(/From the old site/, correction.notes)
        assert_match(/Series name/, correction.notes)
        assert_match(/Discworld/, correction.notes)
      end

      test "keeps mappable fields while folding unmappable ones" do
        row = legacy_row("change_data" => {
          "title" => {"from" => "Old", "to" => "New"},
          "original_language" => {"from" => "en", "to" => "ru"}
        })
        migrate([row])

        correction = ::Correction.find(9001)
        assert_equal %w[title], correction.correction_fields.map(&:field_name)
        assert_match(/Original language/, correction.notes)
      end

      test "folds unmappable fields even when the changeset had no notes" do
        row = legacy_row("notes" => nil, "change_data" => {"series" => {"from" => nil, "to" => "X"}})
        migrate([row])

        assert_match(/From the old site/, ::Correction.find(9001).notes)
      end

      test "skips a changeset whose book no longer exists" do
        result = migrate([legacy_row("changeable_id" => 99_999_999)])

        assert result[:success]
        assert_nil ::Correction.find_by(id: 9001)
      end

      test "skips a changeset whose user no longer exists" do
        migrate([legacy_row("user_id" => 99_999_999)])

        assert_nil ::Correction.find(9001).user_id
      end

      test "is idempotent" do
        migrate([legacy_row])
        migrate([legacy_row])

        assert_equal 1, ::Correction.where(id: 9001).count
      end

      # insert_all bypasses callbacks, so the 448-row run must not fire 448 emails.
      test "sends no email" do
        assert_emails 0 do
          migrate([legacy_row])
        end
      end

      test "resets the primary key sequence so a new correction does not collide" do
        migrate([legacy_row])

        fresh = ::Correction.create!(correctable: ::Books::Book.first, notes: "new one")
        assert_operator fresh.id, :>, 9001
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/lib/services/books_migration/correction_migrator_test.rb
```

Expected: FAIL — no `CorrectionMigrator`.

- [ ] **Step 5: Write the migrator**

`app/lib/services/books_migration/correction_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `changesets` -> `corrections` + `correction_fields`.
    #
    # Legacy ids are PRESERVED (1-647 into a brand-new table, so it is free). That
    # buys idempotency -- a re-run collides on the pkey and ON CONFLICT DO NOTHING
    # absorbs it -- and traceability back to the legacy row. Book ids and user ids
    # are already preserved by BookMigrator and UserMigrator, so both map 1:1.
    #
    # NOT an InsertOnlyMigrator subclass: this writes two tables per legacy row and
    # needs the parent's id in hand to write the children, which the batching base
    # does not model. It uses insert_all directly for the same
    # callbacks-and-validations-bypassed reason -- notably, no correction email.
    #
    # ::Books, ::Correction and ::CorrectionField are root-anchored: Services::Books
    # exists, so a bare Books::Book here resolves to Services::Books::Book.
    class CorrectionMigrator < Migrator
      # Legacy column name => this app's declared field name. Absent from this map
      # and not a declared field => folded into the notes.
      FIELD_RENAMES = {
        "sub_title" => "subtitle",
        "first_year_published" => "first_published_year"
      }.freeze

      LEGACY_STATUS_PENDING = 0
      LEGACY_STATUS_APPLIED = 3

      # PUBLIC, deliberately. Migrator.call is `new.call`, so a private #call here
      # raises NoMethodError before a single row is read. Migrator (unlike
      # BulkUpsertMigrator) has no preload_context hook -- it goes straight from
      # legacy_each to upsert_row -- so this override is what runs it.
      def call
        preload_context
        super
      end

      private

      def legacy_model
        LegacyBooks::Changeset
      end

      def model_key
        "Correction"
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @user_ids = ::User.pluck(:id).to_set
        @declared = ::Books::Book.correctable_field_names.to_set
      end

      # insert_all with explicit ids never advances the sequence, so without this the
      # first correction a real visitor submits gets id 1 and collides.
      def finalize
        ::Correction.connection.reset_pk_sequence!("corrections")
      end

      def upsert_row(attrs)
        book_id = attrs["changeable_id"]
        # Skipped, not raised -- a departure from ReviewMigrator's fail-loud rule.
        # Two legacy changesets point at books that no longer exist, and a
        # correction for a deleted book has nothing to correct.
        unless @book_ids.include?(book_id)
          Rails.logger.warn("CorrectionMigrator: skipped legacy changeset id=#{attrs["id"]}, no Books::Book #{book_id}")
          return
        end

        mappable, unmappable = partition_change_data(attrs["change_data"])
        applied = attrs["status"] == LEGACY_STATUS_APPLIED

        inserted = ::Correction.insert_all(
          [correction_row(attrs, unmappable, applied)],
          unique_by: nil, record_timestamps: false
        )
        # Empty means ON CONFLICT DO NOTHING skipped it -- already migrated, so its
        # children are too.
        return if inserted.length.zero?

        return if mappable.empty?

        ::CorrectionField.insert_all(
          mappable.map { |name, change| field_row(attrs, name, change, applied) },
          unique_by: nil, record_timestamps: false
        )
      end

      def correction_row(attrs, unmappable, applied)
        {
          id: attrs["id"],
          correctable_type: "Books::Book",
          correctable_id: attrs["changeable_id"],
          user_id: @user_ids.include?(attrs["user_id"]) ? attrs["user_id"] : nil,
          notes: notes_with_unmappable(attrs["notes"], unmappable),
          status: applied ? ::Correction.statuses[:resolved] : ::Correction.statuses[:pending],
          resolved_at: applied ? attrs["applied_at"] : nil,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      def field_row(attrs, name, change, applied)
        {
          correction_id: attrs["id"],
          field_name: name,
          old_value: change["from"],
          new_value: change["to"],
          status: applied ? ::CorrectionField.statuses[:applied] : ::CorrectionField.statuses[:pending],
          applied_at: applied ? attrs["applied_at"] : nil,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      # series_name, series_number, series and original_language are associations in
      # this app, not columns, so there is nothing for the applier to write. Folding
      # them into the notes keeps the proposal visible and actionable by hand rather
      # than silently discarding 103 field proposals.
      def partition_change_data(change_data)
        renamed = (change_data || {}).to_h do |legacy_name, change|
          [FIELD_RENAMES.fetch(legacy_name, legacy_name), change]
        end

        renamed.partition { |name, _| @declared.include?(name) }.map(&:to_h)
      end

      def notes_with_unmappable(notes, unmappable)
        return notes.presence if unmappable.empty?

        lines = unmappable.map do |name, change|
          "  #{name.humanize}: #{change["from"].inspect} -> #{change["to"].inspect}"
        end

        [notes.presence, "From the old site — these could not be applied automatically:", *lines]
          .compact.join("\n")
      end
    end
  end
end
```

Two things about this class that will look wrong and are not:

- It subclasses `Migrator`, not `InsertOnlyMigrator`. It writes two tables per legacy row and needs the parent's id in hand before writing the children, which the batching base does not model.
- Its `#call` is public. `Migrator.call` is `new.call`; a private override raises `NoMethodError` before a row is read.

- [ ] **Step 6: Add the rake task**

In `lib/tasks/data_migration.rake`, beside the `reviews` task:

```ruby
  desc "Migrate legacy changesets into corrections + correction_fields (preserves ids)"
  task corrections: :environment do
    pp Services::BooksMigration::CorrectionMigrator.call
  end
```

Then add `corrections` to the `:all` task's dependency list, after `reviews`.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd web-app
bin/rails test test/lib/services/books_migration/correction_migrator_test.rb
```

Expected: PASS.

- [ ] **Step 8: Prove the folding test is not vacuous**

Change `partition_change_data` to return `[renamed, {}]`. Re-run — "folds an unmappable field into the notes" must go RED. Restore.

- [ ] **Step 9: Snapshot dev, then run it for real**

```bash
cd web-app
bin/snapshot-dev-db.sh --label pre-corrections-migration
bin/rails data_migration:corrections
```

Expected: `{success: true, data: {model: "Correction", count: 446}}` — 448 legacy rows minus the 2 orphans. Two warning lines in the log naming the skipped ids.

Verify with a read-only check:

```bash
cd web-app
bin/rails runner 'puts Correction.group(:status).count; puts CorrectionField.group(:field_name).count.sort_by { |_, v| -v }.inspect'
```

Expected: 236 pending, 212 resolved (minus whichever of the 2 orphans fell in each), and a field histogram matching the spec's table with `first_published_year` largest.

- [ ] **Step 10: Lint and commit**

```bash
cd web-app
bundle exec standardrb --fix app/lib/services/books_migration/correction_migrator.rb app/models/legacy_books/changeset.rb
bin/rails test
git add -A
git commit -m "Migrate legacy changesets into corrections"
```

---

## Task 16: Wire music and games

**Files:**
- Modify: `app/models/music/album.rb`, `app/models/games/game.rb`
- Modify: `config/routes.rb`, `app/lib/admin/domain_nav.rb`
- Modify: `app/controllers/corrections_controller.rb`
- Modify: `app/views/music/albums/show.html.erb`, `app/views/games/games/show.html.erb`
- Modify: `public/robots.txt`
- Test: `test/models/music/album_test.rb`, `test/controllers/corrections_controller_test.rb`

This is the increment that proves the abstraction held. If any of it needs a change outside these files, that is a finding worth reporting before proceeding.

Both models are already `include Describable` + `include SearchIndexable` with `friendly_id :title, use: [:slugged, :finders]`, and both carry `title:string`, `release_year:integer`, `description:text` (the same doomed column books has — descriptions live in the `descriptions` table for all three). Their public show routes are `get "album/:slug", as: :album` and `get "game/:slug", as: :game`, so the helpers are `album_path(slug:)` and `game_path(slug:)`.

- [ ] **Step 1: Declare the fields**

In `app/models/music/album.rb`, add `include Correctable` after `include SearchIndexable`, then below the `friendly_id` line:

```ruby
  correctable_field :title, type: :string
  correctable_field :release_year, type: :integer
  # target: :description, not the music_albums.description column -- the displayed
  # text comes from the descriptions table, same as books.
  correctable_field :description, type: :text, target: :description
```

In `app/models/games/game.rb`, the same three. `game_type` is deliberately excluded: it is an internal enum a reader never sees.

- [ ] **Step 2: Add the routes**

One line per domain, inside that domain's constraint, mirroring books:

```ruby
      get "album/:slug/suggest-correction", to: "corrections#new",
        defaults: {correctable_type: "Music::Album"}, as: :music_album_correction
```

```ruby
    get "game/:slug/suggest-correction", to: "corrections#new",
      defaults: {correctable_type: "Games::Game"}, as: :games_game_correction
```

Match the surrounding indentation — the music album route sits inside a nested `scope`, the games one does not.

- [ ] **Step 3: Generalise correctable_path**

`CorrectionsController#correctable_path` currently hardcodes `book_path`. Replace it:

```ruby
  # Where to send the submitter back to. There is no single root-relative show
  # helper in this app -- four sites share one route file, so each domain names its
  # own -- which is why this is a lookup rather than polymorphic_path.
  PUBLIC_PATHS = {
    "Books::Book" => :book_path,
    "Music::Album" => :album_path,
    "Games::Game" => :game_path
  }.freeze

  def correctable_path
    public_send(PUBLIC_PATHS.fetch(@correctable_type), slug: @record.slug)
  end
  helper_method :correctable_path
```

`fetch`, not `[]`: a correctable type with no public path is a wiring mistake, and it should raise in that domain's own tests rather than produce a `nil` redirect in production.

Then replace both `book_path(slug: @record.slug)` calls in `app/views/corrections/new.html.erb` with `correctable_path`.

- [ ] **Step 4: Generalise the admin path helpers**

`Admin::CorrectionsController` and `AdminMailer#new_correction` both hardcode `admin_books_correction_path` / `_url`, and the admin show view hardcodes `book_path`. All three break the moment a music correction exists. Add a matching lookup on the admin controller:

```ruby
  ADMIN_PATHS = {
    books: :admin_books_corrections_path,
    music: :admin_corrections_path,
    games: :admin_games_corrections_path
  }.freeze

  def corrections_index_path(**options)
    public_send(ADMIN_PATHS.fetch(current_domain.to_sym), **options)
  end
  helper_method :corrections_index_path

  def correction_path_for(correction)
    domain = Services::Corrections::TypeRegistry.domain_for(correction.correctable_type)
    public_send(ADMIN_PATHS.fetch(domain).to_s.sub("corrections_path", "correction_path"), correction)
  end
  helper_method :correction_path_for
```

Use the real route helper names the music and games `resources :corrections` blocks generate — derive them from `bin/rails routes -g corrections` rather than assuming. Replace every hardcoded `admin_books_correction*_path` in the controller, both views, and the mailer (`_url` there), and replace the admin show view's `book_path(slug: @record.slug)` with `Admin::DomainRouting`-driven public path lookup or the same `PUBLIC_PATHS` map from Step 3, exposed as a helper.

This step is the one most likely to reveal that the abstraction did not fully hold. If it turns into more than mechanical substitution, stop and report it before continuing.

- [ ] **Step 5: Add sidebar entries and robots rules**

One `{label: "Corrections", icon: :chat, ...}` item in `CONFIGS[:music][:items]` and `CONFIGS[:games][:items]`, and a `resources :corrections, only: [:index, :show], controller: "/admin/corrections"` block (with the same `member`/`collection` routes as books) inside each domain's admin namespace. Two more `Disallow:` lines in `robots.txt`:

```
Disallow: /album/*/suggest-correction
Disallow: /game/*/suggest-correction
```

- [ ] **Step 6: Add the "Suggest a correction" links**

One link on `app/views/music/albums/show.html.erb` and `app/views/games/games/show.html.erb`, matching the books wording, the `link` class, and the `data-testid="suggest-correction-link"` hook.

- [ ] **Step 7: Add tests**

For each domain, mirror the books tests: the model declares its fields, `#new` renders and is cacheable and noindex, `#create` works, and the admin index scopes to that domain's types only.

The last one is the real check, and it is the reason this task exists. Add a music correction fixture (`correctable: <some album> (Music::Album)`) and confirm `test/controllers/admin/corrections_controller_test.rb`'s "scopes to this domain's correctable types" now goes RED when `domain_scope` is replaced with `::Correction.all` — it could not, before this task, because books was the only correctable domain. Then restore.

- [ ] **Step 8: Run everything**

```bash
cd web-app
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
bin/rails test test/lint/daisyui_v4_classes_test.rb
yarn build:all
```

Expected: all green.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Wire corrections for music and games"
```

---

## Final verification

- [ ] **Full suite and lint**

```bash
cd web-app
bin/rails db:test:prepare test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: green, and **no new warning lines** beyond `weighted_list_rank`'s position `puts` and npm/yarn output. A new warning is a regression — fix the cause, don't filter it.

- [ ] **E2E**

```bash
cd web-app
yarn test:e2e e2e/tests/books/corrections.spec.ts e2e/tests/books/admin/corrections.spec.ts
```

- [ ] **Ops steps that must happen before this is live** (these are Shane's, not the implementer's):
  - A Cloudflare Cache Rule ignoring query strings on `/book/*/suggest-correction` and the music/games equivalents. **Without it the caching does nothing** — `?x=1`, `?x=2` are distinct cache keys and every request goes through to Rails, which is the exact shape of the flood that took the legacy site down.
  - Confirm `ADMIN_NOTIFICATION_EMAIL` resolves to `contact@thegreatestbooks.org` in production.

- [ ] **Do not push or open a PR without asking.**
