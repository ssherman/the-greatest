require "test_helper"

module Services
  module BooksMigration
    class CorrectionMigratorTest < ActiveSupport::TestCase
      # Only ActionDispatch::IntegrationTest gets this for free in this app (see
      # test_helper.rb) -- ActiveSupport::TestCase does not. Needed for
      # "sends no email" below.
      include ActionMailer::TestHelper

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
        CorrectionMigrator.any_instance.stubs(:legacy_each).multiple_yields(*rows.zip)
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
