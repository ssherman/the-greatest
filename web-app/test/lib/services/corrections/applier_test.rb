require "test_helper"

module Services
  module Corrections
    class ApplierTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

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

      # Codex P2: an admin can edit the proposed value to blank in the review form,
      # which Submission's own guard never sees. assign_description no-ops on blank,
      # so without this the field would be marked applied and the correction
      # resolved while the description on the page never changed.
      test "refuses a blank description at apply instead of reporting a false success" do
        correction = ::Correction.create!(correctable: @book, notes: nil,
          correction_fields_attributes: [{field_name: "description",
                                          old_value: "old text", new_value: "new text"}])

        result = Applier.call(correction: correction, accepted: {"description" => "  "}, admin: @admin)

        assert_not result.success?
        assert_includes result.errors.join, "cannot be cleared"
        assert_predicate correction.reload, :pending?
        assert_predicate correction.correction_fields.sole, :pending?
      end

      # Codex P2: the pending check used to run OUTSIDE the transaction, so two
      # concurrent applies both passed it and both wrote -- the second silently
      # overwriting the first admin's edited values and audit fields. lock! now
      # serialises them. Simulated by resolving the row underneath an in-flight
      # apply, which is the state the loser observes after waiting on the lock.
      test "refuses to apply a correction another admin resolved first" do
        correction = corrections(:war_and_peace_pending)
        ::Correction.where(id: correction.id).update_all(status: ::Correction.statuses[:resolved])

        result = Applier.call(correction: correction, accepted: {"title" => "War & Peace"}, admin: @admin)

        assert_not result.success?
        assert_includes result.errors.join, "already been resolved"
        assert_equal "War and Peace", @book.reload.title
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

      # Pins the branch order in apply_fields: undeclared must be checked before
      # @accepted, or a field that is BOTH undeclared and absent from accepted
      # falls into the ordinary update! branch, which re-runs
      # field_name_is_declared against the very field_name that fails it, and
      # raises instead of rejecting.
      test "rejects an undeclared field that is also absent from accepted, instead of raising" do
        correction = ::Correction.create!(correctable: @book, notes: "legacy")
        ::CorrectionField.insert_all([{
          correction_id: correction.id, field_name: "series_name",
          old_value: nil, new_value: "Discworld", status: 0,
          created_at: Time.current, updated_at: Time.current
        }])

        result = Applier.call(correction: correction, accepted: {}, admin: @admin)

        assert_predicate result, :success?
        assert_predicate correction.reload.correction_fields.sole, :rejected?
      end
    end
  end
end
