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

      test "includes fields recorded in cleared_fields" do
        ClearedField.create!(clearable: @book, field_name: "first_published_year", cleared_via: :api)

        assert_equal Set["first_published_year"], HumanClearedFields.for(@book)
      end

      test "unions cleared_fields rows with correction clears" do
        correct!("subtitle", "")
        ClearedField.create!(clearable: @book, field_name: "original_language_id", cleared_via: :admin_ui)

        assert_equal Set["subtitle", "original_language_id"], HumanClearedFields.for(@book)
      end

      test "ignores another book's cleared_fields rows" do
        ClearedField.create!(clearable: books_books(:crime_and_punishment), field_name: "subtitle", cleared_via: :api)

        assert_empty HumanClearedFields.for(@book)
      end

      test "not_cleared_sql agrees with for across every way a field is or is not cleared" do
        cleared = books_books(:war_and_peace)
        blank_corrected = books_books(:crime_and_punishment)
        sql_null = ::Books::Book.create!(title: "Sql Null")
        json_null = ::Books::Book.create!(title: "Json Null")
        spaces = ::Books::Book.create!(title: "Spaces")
        value_corrected = ::Books::Book.create!(title: "Value Corrected")
        pending_corrected = ::Books::Book.create!(title: "Pending Corrected")
        untouched = ::Books::Book.create!(title: "Untouched")
        ClearedField.create!(clearable: cleared, field_name: "first_published_year", cleared_via: :api)

        {blank_corrected => ["", :applied], sql_null => [nil, :applied], json_null => [1, :applied], spaces => ["  ", :applied],
         value_corrected => [1869, :applied], pending_corrected => ["", :pending]}.each do |book, (value, status)|
          ::Correction.create!(correctable: book, status: :resolved, notes: "x")
            .correction_fields.create!(field_name: "first_published_year", status: status, new_value: value, applied_at: Time.current)
        end
        # A JSON null, as opposed to the SQL NULL that new_value: nil stores.
        CorrectionField.joins(:correction).where(corrections: {correctable_id: json_null.id, correctable_type: "Books::Book"})
          .update_all("new_value = 'null'::jsonb")

        books = [cleared, blank_corrected, sql_null, json_null, spaces, value_corrected, pending_corrected, untouched]
        in_sql = ::Books::Book.where(id: books.map(&:id)).where(HumanClearedFields.not_cleared_sql("first_published_year")).pluck(:id)
        expected = books.reject { |book| HumanClearedFields.for(book).include?("first_published_year") }.map(&:id)

        assert_equal expected.sort, in_sql.sort
        assert_equal [value_corrected, pending_corrected, untouched].map(&:id).sort, in_sql.sort
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
