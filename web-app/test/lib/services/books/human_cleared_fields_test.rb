require "test_helper"

module Services
  module Books
    class HumanClearedFieldsTest < ActiveSupport::TestCase
      setup { @book = books_books(:war_and_peace) }

      def correct!(field_name, new_value, status: :applied)
        correction = ::Correction.create!(correctable: @book, status: :resolved, notes: "Cleared #{field_name}.")
        correction.correction_fields.create!(field_name: field_name, status: status, new_value: new_value, applied_at: Time.current)
      end

      test "returns the fields a human blanked, as a set of strings" do
        correct!("subtitle", "")
        correct!("page_range", nil)

        assert_equal Set["subtitle", "page_range"], HumanClearedFields.for(@book)
      end

      test "ignores corrections that set a value" do
        correct!("subtitle", "A New Subtitle")

        assert_empty HumanClearedFields.for(@book)
      end

      test "ignores corrections that were not applied" do
        correct!("subtitle", "", status: :pending)

        assert_empty HumanClearedFields.for(@book)
      end

      test "ignores another book's corrections" do
        other = books_books(:crime_and_punishment)
        correction = ::Correction.create!(correctable: other, status: :resolved, notes: "x")
        correction.correction_fields.create!(field_name: "subtitle", status: :applied, new_value: "", applied_at: Time.current)

        assert_empty HumanClearedFields.for(@book)
      end
    end
  end
end
