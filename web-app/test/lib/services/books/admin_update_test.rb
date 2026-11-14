require "test_helper"

module Services
  module Books
    class AdminUpdateTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @user = users(:admin_user)
      end

      def call(attrs, **opts)
        AdminUpdate.call(book: @book, attrs: attrs, user: @user, via: "api", **opts)
      end

      test "present to blank writes a row stamped with the user and via" do
        result = call({"first_published_year" => nil})

        assert result.success?
        assert_includes result.data[:changed], "first_published_year"
        row = @book.cleared_fields.find_by!(field_name: "first_published_year")
        assert_equal [@user, "api"], [row.cleared_by, row.cleared_via]
      end

      test "a blank string counts as blank" do
        @book.update!(subtitle: "Sub")
        call({"subtitle" => "  "})

        assert @book.cleared_fields.exists?(field_name: "subtitle")
      end

      test "blank to value deletes the row" do
        @book.cleared_fields.create!(field_name: "subtitle", cleared_via: :api)
        @book.update!(subtitle: nil)

        call({"subtitle" => "Back"})

        refute @book.cleared_fields.exists?(field_name: "subtitle")
      end

      test "blank to blank writes no row without explicit_nulls and one with it" do
        @book.update!(subtitle: nil)

        call({"subtitle" => nil})
        refute @book.cleared_fields.exists?(field_name: "subtitle")

        call({"subtitle" => nil}, explicit_nulls: ["subtitle"])
        assert @book.cleared_fields.exists?(field_name: "subtitle")
      end

      test "clearing again leaves the existing row as it was" do
        @book.update!(subtitle: nil)
        row = @book.cleared_fields.create!(field_name: "subtitle", cleared_via: :admin_ui)

        call({"subtitle" => nil}, explicit_nulls: ["subtitle"])

        assert_equal ["admin_ui", 1], [row.reload.cleared_via, @book.cleared_fields.count]
      end

      test "a non-clearable field blanked writes no row" do
        call({"sort_title" => nil})

        assert_equal 0, @book.cleared_fields.count
      end

      test "a partial attrs leaves other fields and alternate titles alone" do
        @book.update!(original_language: nil)
        @book.cleared_fields.create!(field_name: "original_language_id", cleared_via: :api)
        title = @book.title

        call({"subtitle" => "Sub"})

        @book.reload
        assert_equal [title, 1869, ["Voyna i mir"]], [@book.title, @book.first_published_year, @book.alternate_titles]
        assert_equal ["original_language_id"], @book.cleared_fields.pluck(:field_name)
      end

      test "a validation failure writes nothing" do
        result = call({"title" => "", "first_published_year" => nil, "alternate_titles" => ["X"]})

        refute result.success?
        assert_equal :invalid, result.data[:code]
        assert_not_empty result.errors
        @book.reload
        assert_equal [1869, ["Voyna i mir"], 0], [@book.first_published_year, @book.alternate_titles, @book.cleared_fields.count]
      end

      test "alternate titles replace through the Writer with source admin" do
        Services::AlternateTitles::Writer.expects(:replace).with(record: @book, titles: ["Guerre"], source: :admin, user: @user).returns(nil)

        assert call({"alternate_titles" => ["Guerre"]}).success?
      end
    end
  end
end
