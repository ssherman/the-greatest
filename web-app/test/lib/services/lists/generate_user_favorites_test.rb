# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class GenerateUserFavoritesTest < ActiveSupport::TestCase
      setup do
        ::UserListItem.where(user_list_id: ::Books::UserList.select(:id)).delete_all
        @next_user = 0
      end

      # User has after_create :create_default_user_lists, so the favorites list
      # already exists -- find it rather than creating a second one, which
      # one_default_per_type_per_user would reject.
      def build_ballot(books)
        @next_user += 1
        user = ::User.create!(email: "voter#{@next_user}@example.com")
        list = ::Books::UserList.find_by!(user: user, list_type: :favorites)
        books.each_with_index do |book, index|
          ::UserListItem.create!(user_list: list, listable: book, position: index + 1)
        end
        list
      end

      def generate(**options)
        GenerateUserFavorites.call(user_list_class: ::Books::UserList, min_voters: 1, **options)
      end

      test "creates the list unapproved on first run" do
        build_ballot([books_books(:war_and_peace)])

        result = generate

        assert result.success?, result.errors.inspect
        list = result.data[:list]
        assert_equal "Our Users' Favorite Books of All Time", list.name
        assert_equal "unapproved", list.status
        assert list.generated_user_favorites?
        assert_instance_of ::Books::List, list
      end

      test "writes items in tally order with sequential positions" do
        loved = books_books(:war_and_peace)
        liked = books_books(:got)
        3.times { build_ballot([loved]) }
        build_ballot([liked])

        list = generate.data[:list]
        items = list.list_items.order(:position)

        assert_equal [loved.id, liked.id], items.map(&:listable_id)
        assert_equal [1, 2], items.map(&:position)
        assert_equal ["Books::Book", "Books::Book"], items.map(&:listable_type)
        assert items.all?(&:verified?)
      end

      test "records the real ballot count as number_of_voters" do
        2.times { build_ballot([books_books(:war_and_peace)]) }

        assert_equal 2, generate.data[:list].number_of_voters
      end

      test "replaces items on a second run rather than accumulating" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        build_ballot([books_books(:got)])
        build_ballot([books_books(:got)])
        generate

        items = list.reload.list_items.order(:position)
        assert_equal 2, items.count
        assert_equal [books_books(:got).id, books_books(:war_and_peace).id], items.map(&:listable_id)
      end

      test "reuses the same list across runs" do
        build_ballot([books_books(:war_and_peace)])

        first = generate.data[:list]
        second = generate.data[:list]

        assert_equal first.id, second.id
        assert_equal 1, ::Books::List.where(auto_generated_kind: :user_favorites).count
      end

      test "does not change the status of an existing active list" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.update!(status: :active)

        generate

        assert_equal "active", list.reload.status
      end

      test "empties the list when every ballot disappears" do
        ballot = build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        ballot.user_list_items.delete_all
        result = generate

        assert result.success?, result.errors.inspect
        assert_equal 0, list.reload.list_items.count
        assert_equal 0, result.data[:ballot_count]
      end

      test "returns a failure Result rather than raising" do
        UserFavoritesTally.stubs(:call).raises(ActiveRecord::StatementInvalid, "boom")

        result = generate

        refute result.success?
        assert_includes result.errors.first, "boom"
      end

      test "leaves the list untouched when the write fails partway" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]

        ::ListItem.stubs(:insert_all).raises(ActiveRecord::StatementInvalid, "boom")
        result = generate

        refute result.success?
        assert_equal 1, list.reload.list_items.count
      end

      # The Result carries only the message, and the nightly job re-raises a
      # RuntimeError of its own -- so Sidekiq records that backtrace and the real
      # one is gone unless it is written down here.
      test "logs the original exception, class and backtrace included" do
        UserFavoritesTally.stubs(:call).raises(ArgumentError, "boom")

        io = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)

        begin
          result = generate
        ensure
          Rails.logger = original_logger
        end

        refute result.success?
        assert_includes io.string, "ArgumentError"
        assert_includes io.string, "boom"
        # full_message, not just message: the backtrace has to survive.
        assert_includes io.string, "generate_user_favorites.rb"
      end
    end
  end
end
