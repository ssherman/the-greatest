require "test_helper"

module Services
  module BooksMigration
    class UserListMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = UserListMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 300001,
          "user_id" => @user.id,
          "name" => "Books I've Read",
          "description" => "desc",
          "list_type" => 0,
          "view_mode" => nil,
          "public" => nil,
          "position" => nil,
          "greatest_books_list" => true,
          "best_ranked" => true,
          "date_read" => Date.new(2020, 1, 1),
          "created_at" => Time.utc(2015, 1, 2, 3, 4, 5),
          "updated_at" => Time.utc(2016, 2, 3, 4, 5, 6)
        }.merge(overrides)
      end

      test "maps a legacy user_list to Books::UserList, preserving id" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::UserList", result[:data][:model]

        list = ::UserList.find(300001)
        assert_instance_of Books::UserList, list
        assert_equal @user, list.user
        assert_equal "Books I've Read", list.name
        assert_equal "desc", list.description
        assert list.read?
        assert list.default_view?
        assert_not list.public?
        assert_nil list.position
        assert_equal Time.utc(2015, 1, 2, 3, 4, 5), list.created_at
        assert_equal Time.utc(2016, 2, 3, 4, 5, 6), list.updated_at
      end

      test "remaps every legacy list_type to the new-app enum" do
        result = run_migrator([
          legacy_row("id" => 300010, "list_type" => 0),
          legacy_row("id" => 300011, "list_type" => 1),
          legacy_row("id" => 300012, "list_type" => 2),
          legacy_row("id" => 300013, "list_type" => 3),
          legacy_row("id" => 300014, "list_type" => 4)
        ])

        assert result[:success], result[:error]
        assert_equal "read", ::UserList.find(300010).list_type
        assert_equal "reading", ::UserList.find(300011).list_type
        assert_equal "want_to_read", ::UserList.find(300012).list_type
        assert_equal "favorites", ::UserList.find(300013).list_type
        assert_equal "custom", ::UserList.find(300014).list_type
      end

      test "fails loud on an unmapped list_type" do
        result = run_migrator([legacy_row("id" => 300099, "list_type" => 7)])

        refute result[:success]
        assert_match(/300099/, result[:error])
        assert_match(/list_type/, result[:error])
      end

      test "remaps view_mode, treating NULL as the default member" do
        result = run_migrator([
          legacy_row("id" => 300020, "list_type" => 0, "view_mode" => nil),
          legacy_row("id" => 300021, "list_type" => 1, "view_mode" => 1),
          legacy_row("id" => 300022, "list_type" => 2, "view_mode" => 2)
        ])

        assert result[:success], result[:error]
        assert_equal "default_view", ::UserList.find(300020).view_mode
        assert_equal "table_view", ::UserList.find(300021).view_mode
        assert_equal "grid_view", ::UserList.find(300022).view_mode
      end

      test "fails loud on an unmapped view_mode" do
        result = run_migrator([legacy_row("id" => 300098, "view_mode" => 9)])

        refute result[:success]
        assert_match(/300098/, result[:error])
        assert_match(/view_mode/, result[:error])
      end

      test "a null public becomes false and a true public is preserved" do
        result = run_migrator([
          legacy_row("id" => 300030, "list_type" => 0, "public" => nil),
          legacy_row("id" => 300031, "list_type" => 1, "public" => true)
        ])

        assert result[:success], result[:error]
        assert_not ::UserList.find(300030).public?
        assert ::UserList.find(300031).public?
      end

      test "drops greatest_books_list, best_ranked and date_read" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        list = ::UserList.find(300001)
        assert_not list.respond_to?(:greatest_books_list)
        assert_not list.respond_to?(:best_ranked)
        assert_not list.respond_to?(:date_read)
      end

      test "is idempotent on id" do
        run_migrator([legacy_row])

        assert_no_difference -> { ::UserList.count } do
          run_migrator([legacy_row("name" => "Renamed")])
        end
        assert_equal "Renamed", ::UserList.find(300001).name
      end
    end
  end
end
