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

      # /suggest-correction is an anonymous POST with no Rack or nginx body limit
      # in front of it, and the rate limit keys on an ip header the origin will
      # believe if a request ever reaches it off-edge. Correction::MAX_NOTES_LENGTH
      # bounded the notes and nothing bounded the field values, which are what
      # actually reach a jsonb column. The caps and the reasoning behind each
      # number are on Correction.
      test "rejects a string field value longer than the cap" do
        result = Submission.call(
          record: @book,
          field_params: {"title" => "x" * (::Correction::MAX_FIELD_VALUE_LENGTH + 1)},
          notes: nil, user: nil
        )

        assert_not result.success?
        assert_includes result.errors.join, "Title is too long"
      end

      test "rejects a description longer than the text cap" do
        result = Submission.call(
          record: @book,
          field_params: {"description" => "x" * (::Correction::MAX_TEXT_VALUE_LENGTH + 1)},
          notes: nil, user: nil
        )

        assert_not result.success?
        assert_includes result.errors.join, "Description is too long"
      end

      test "rejects an array with more entries than the cap" do
        result = Submission.call(
          record: @book,
          field_params: {"alternate_titles" => Array.new(::Correction::MAX_ARRAY_ELEMENTS + 1) { |i| "Title #{i}" }},
          notes: nil, user: nil
        )

        assert_not result.success?
        assert_includes result.errors.join, "Alternate titles has too many entries"
      end

      test "rejects an array entry longer than the cap" do
        result = Submission.call(
          record: @book,
          field_params: {"alternate_titles" => ["Voyna i mir", "x" * (::Correction::MAX_FIELD_VALUE_LENGTH + 1)]},
          notes: nil, user: nil
        )

        assert_not result.success?
        assert_includes result.errors.join, "Alternate titles has an entry that is too long"
      end

      test "persists nothing when a field value is over the cap" do
        assert_no_difference -> { ::Correction.count } do
          Submission.call(
            record: @book,
            field_params: {"title" => "y" * (::Correction::MAX_FIELD_VALUE_LENGTH + 1)},
            notes: "and some notes too", user: nil
          )
        end
      end

      # The other half of the cap: it has to be loose enough that nothing real is
      # refused. Exactly at the limit, and a description far longer than any book
      # in the corpus actually has (the longest is 64,664), both go through.
      test "accepts a value exactly at the cap" do
        result = Submission.call(
          record: @book,
          field_params: {"title" => "z" * ::Correction::MAX_FIELD_VALUE_LENGTH},
          notes: nil, user: nil
        )

        assert_predicate result, :success?
        assert_equal "z" * ::Correction::MAX_FIELD_VALUE_LENGTH, result.data.correction_fields.sole.new_value
      end

      test "accepts a description longer than any book in the corpus has" do
        result = Submission.call(
          record: @book, field_params: {"description" => "w" * 70_000}, notes: nil, user: nil
        )

        assert_predicate result, :success?
        assert_equal "description", result.data.correction_fields.sole.field_name
      end

      # 66 is the longest alternate_titles list on a real book, and the form
      # prefills every entry -- so a submitter correcting the YEAR on that book
      # posts all 66 back untouched. The cap must not turn that into an error the
      # submitter cannot act on.
      test "accepts the longest alternate title list a real book has" do
        result = Submission.call(
          record: @book,
          field_params: {"alternate_titles" => Array.new(66) { |i| "Title #{i}" }},
          notes: nil, user: nil
        )

        assert_predicate result, :success?
        assert_equal 66, result.data.correction_fields.sole.new_value.size
      end
    end
  end
end
