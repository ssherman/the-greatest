require "test_helper"

module Services
  module BooksMigration
    class UserListItemMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @list = Books::UserList.create!(user: @user, name: "Books I've Read", list_type: :read)
        @book = Books::Book.create!(title: "Item Book")
      end

      def run_migrator(rows)
        migrator = UserListItemMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 5000001,
          "user_list_id" => @list.id,
          "book_id" => @book.id,
          "position" => 3,
          "read_date" => Date.new(2021, 7, 4),
          "created_at" => Time.utc(2018, 5, 6, 7, 8, 9),
          "updated_at" => Time.utc(2019, 6, 7, 8, 9, 10)
        }.merge(overrides)
      end

      test "maps a legacy user_list_book to a Books::Book listable" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "UserListItem", result[:data][:model]

        item = UserListItem.find_by(user_list_id: @list.id, listable_type: "Books::Book", listable_id: @book.id)
        assert_not_nil item
        assert_equal @book, item.listable
        assert_equal Date.new(2021, 7, 4), item.completed_on
        assert_equal Time.utc(2018, 5, 6, 7, 8, 9), item.created_at
        assert_equal Time.utc(2019, 6, 7, 8, 9, 10), item.updated_at
        assert_equal 1, item.position
      end

      test "a null read_date becomes a null completed_on" do
        run_migrator([legacy_row("read_date" => nil)])

        item = UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id)
        assert_nil item.completed_on
      end

      test "renumbers positions to a contiguous 1..N, nulls last and ties broken by legacy id" do
        second = Books::Book.create!(title: "Second")
        third = Books::Book.create!(title: "Third")
        fourth = Books::Book.create!(title: "Fourth")

        result = run_migrator([
          legacy_row("id" => 5000001, "book_id" => fourth.id, "position" => nil),
          legacy_row("id" => 5000002, "book_id" => second.id, "position" => 7),
          legacy_row("id" => 5000003, "book_id" => third.id, "position" => 7),
          legacy_row("id" => 5000004, "book_id" => @book.id, "position" => 2)
        ])

        assert result[:success], result[:error]
        assert_equal [[@book.id, 1], [second.id, 2], [third.id, 3], [fourth.id, 4]],
          UserListItem.where(user_list_id: @list.id).order(:position).pluck(:listable_id, :position)
      end

      test "no sentinel position survives the renumber" do
        run_migrator([legacy_row("position" => nil)])

        assert_equal 0, UserListItem.where(position: UserListItemMigrator::NULL_POSITION_SENTINEL).count
      end

      test "the renumber leaves non-Books user_list_items untouched" do
        music_list = ::Music::Albums::UserList.create!(user: @user, name: "Renumber Guard", list_type: :custom)
        music_item = UserListItem.create!(user_list: music_list,
          listable: music_albums(:dark_side_of_the_moon), position: 5)

        run_migrator([legacy_row])

        assert_equal 5, music_item.reload.position
      end

      test "fails loud when the book is not migrated" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 5000042, "book_id" => missing)])

        refute result[:success]
        assert_match(/5000042/, result[:error])
      end

      test "is idempotent on [user_list, listable]" do
        run_migrator([legacy_row])

        assert_no_difference -> { UserListItem.count } do
          run_migrator([legacy_row("read_date" => Date.new(2022, 1, 1))])
        end

        item = UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id)
        assert_equal Date.new(2022, 1, 1), item.completed_on
        assert_equal 1, item.position
      end
    end
  end
end
