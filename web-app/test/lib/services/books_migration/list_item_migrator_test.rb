require "test_helper"

module Services
  module BooksMigration
    class ListItemMigratorTest < ActiveSupport::TestCase
      setup do
        @list = Books::List.create!(name: "Item Parent List")
        @book = Books::Book.create!(title: "Item Book")
      end

      def run_migrator(rows)
        migrator = ListItemMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 8000001,
          "list_id" => @list.id,
          "book_id" => @book.id,
          "position" => 3,
          "pending_book_data" => nil,
          "created_at" => Time.utc(2018, 5, 6, 7, 8, 9),
          "updated_at" => Time.utc(2019, 6, 7, 8, 9, 10)
        }.merge(overrides)
      end

      test "maps a legacy list_item to a Books::Book listable" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "ListItem", result[:data][:model]

        item = ListItem.find_by(list_id: @list.id, listable_type: "Books::Book", listable_id: @book.id)
        assert_not_nil item
        assert_equal @book, item.listable
        assert_equal 3, item.position
        assert_equal false, item.verified
        assert_nil item.metadata
        assert_equal Time.utc(2018, 5, 6, 7, 8, 9), item.created_at
        assert_equal Time.utc(2019, 6, 7, 8, 9, 10), item.updated_at
      end

      test "parses pending_book_data into metadata" do
        run_migrator([legacy_row("pending_book_data" => '{"title":"T","authors":"A"}')])

        item = ListItem.find_by(list_id: @list.id, listable_id: @book.id)
        assert_equal({"title" => "T", "authors" => "A"}, item.metadata)
      end

      test "null position and blank pending_book_data become nil" do
        run_migrator([legacy_row("position" => nil, "pending_book_data" => "")])

        item = ListItem.find_by(list_id: @list.id, listable_id: @book.id)
        assert_nil item.position
        assert_nil item.metadata
      end

      test "fails loud when the book is not migrated" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 8000042, "book_id" => missing)])

        refute result[:success]
        assert_match(/8000042/, result[:error])
      end

      test "is idempotent on [list, listable]" do
        run_migrator([legacy_row])

        assert_no_difference -> { ListItem.count } do
          run_migrator([legacy_row("position" => 99)])
        end
        assert_equal 99, ListItem.find_by(list_id: @list.id, listable_id: @book.id).position
      end
    end
  end
end
