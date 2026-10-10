# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class PositivePairsTest < ActiveSupport::TestCase
      # Fixtures: regular_user favorites = war_and_peace, got; read = clash;
      # reviews = war_and_peace ★5, crime_and_punishment ★3. editor_user and
      # admin_user each rate war_and_peace ★4.
      def setup
        @user = users(:regular_user)
        want = ::Books::UserList.create!(user: @user, list_type: :want_to_read, name: "Want")
        want.user_list_items.create!(listable: books_books(:of_mice_and_men))
        custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Shelf")
        custom.user_list_items.create!(listable: books_books(:combo_steinbeck))
        Review.create!(user: @user, reviewable: books_books(:cannery_row), rating: 2)
        # Ruling 1: a read-list book rated 2 stays a positive (clash is on the read list).
        Review.create!(user: @user, reviewable: books_books(:clash), rating: 2)
      end

      def pairs(min_rating: 3, batch_size: 50_000)
        out = []
        PositivePairs.new(min_rating: min_rating).each_batch(batch_size: batch_size) { |rows| out.concat(rows) }
        out
      end

      test "yields favorites, read and rated-at-floor books once each, never want-to-read, custom or low ratings" do
        mine = pairs.select { |u, _| u == @user.id }.map(&:last)
        expected = %i[war_and_peace got clash crime_and_punishment].map { |b| books_books(b).id }.sort
        assert_equal expected, mine.sort
        assert_equal mine.uniq, mine, "a favorite that is also rated appears once"
      end

      test "the floor is a knob" do
        mine = pairs(min_rating: 4).select { |u, _| u == @user.id }.map(&:last)
        assert_not_includes mine, books_books(:crime_and_punishment).id
        assert_includes mine, books_books(:war_and_peace).id
      end

      test "rows are sorted by user then item across batches and include other users' ratings" do
        all = pairs(batch_size: 2)
        assert_equal all.sort, all
        assert_includes all, [users(:editor_user).id, books_books(:war_and_peace).id]
      end

      test "agrees with Interaction#trainable? on the adapter's view of the same user" do
        adapter = Adapter.new(config: Config.resolve)
        from_ruby = adapter.interactions(@user).select { |i| i.trainable?(min_rating: 3) }.map(&:item_id).sort
        from_sql = pairs.select { |u, _| u == @user.id }.map(&:last).sort
        assert_equal from_ruby, from_sql
      end
    end
  end
end
