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
        assert_no_difference -> { ::Correction.count } do
          Submission.call(record: @book, field_params: {}, notes: nil, user: nil)
        end
      end
    end
  end
end
