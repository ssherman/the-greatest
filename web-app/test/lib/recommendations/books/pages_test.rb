# frozen_string_literal: true

require "test_helper"

module Recommendations
  module Books
    class PagesTest < ActiveSupport::TestCase
      # Fixtures: regular_user owns a favorites and a read list, which ship with
      # items (favorites: war_and_peace, got; read: clash); setup empties them so
      # each test builds exactly the shelf it asserts on.
      # Reviews: war_and_peace ★5 and crime_and_punishment ★3 by regular_user.
      def setup
        @user = users(:regular_user)
        @favorites = user_lists(:regular_user_books_favorites)
        @read = user_lists(:regular_user_books_read)
        ::UserListItem.where(user_list: [@favorites, @read]).delete_all
        @pages = Pages.new(user: @user)
      end

      def add(list, book, position: nil)
        ::UserListItem.create!(user_list: list, listable: book, position: position)
      end

      test "history? is false with empty lists and true once a favorite or read book exists" do
        assert_not @pages.history?
        add(@read, books_books(:got))
        assert Pages.new(user: @user).history?
      end

      test "favorites come back in list order with their total" do
        add(@favorites, books_books(:clash), position: 2)
        add(@favorites, books_books(:got), position: 1)
        result = @pages.favorites
        assert_equal [books_books(:got), books_books(:clash)], result.books
        assert_equal 2, result.total
        assert result.books.first.association(:book_authors).loaded?
      end

      test "read books are newest first and capped at the read limit" do
        old = add(@read, books_books(:got))
        old.update_columns(created_at: 2.days.ago)
        add(@read, books_books(:clash))
        result = @pages.read_books(limit: 1)
        assert_equal [books_books(:clash)], result.books
        assert_equal 2, result.total, "the total counts beyond the cap"
      end

      test "unrated_read drops read books the user has rated, and rated lists them with the review" do
        add(@read, books_books(:war_and_peace))
        add(@read, books_books(:got))
        assert_equal [books_books(:got)], @pages.unrated_read
        rated = @pages.rated
        assert_includes rated.map(&:first), books_books(:war_and_peace)
        assert_equal 5, rated.find { |book, _| book == books_books(:war_and_peace) }.last.rating
      end

      test "a text-only review does not count as rated" do
        add(@read, books_books(:got))
        ::Review.create!(user: @user, reviewable: books_books(:got), body: "Fine.")
        assert_includes @pages.unrated_read, books_books(:got)
      end

      test "a user with no lists has no history and empty steps" do
        pages = Pages.new(user: users(:books_viewer_user))
        assert_not pages.history?
        assert_equal 0, pages.favorites.total
        assert_equal [], pages.unrated_read
      end

      test "search delegates to the site search with the page size" do
        ::Books::BookSearchQuery.expects(:call).with("hall", size: Pages::SEARCH_SIZE).returns([books_books(:got)])
        assert_equal [books_books(:got)], @pages.search("hall")
      end

      test "names look up categories and books by id" do
        genre = categories(:books_classics_genre)
        assert_equal({genre.id => genre.name}, @pages.category_names([genre.id, 0]))
        assert_equal({books_books(:got).id => books_books(:got).title}, @pages.item_names([books_books(:got).id]))
      end

      test "criteria_groups drops the ranked group and adds a depth group when it is not balanced" do
        criteria = ::Books::RecommendationCriteria.new("max_ranked_position" => 100, "depth" => "deep")
        groups = @pages.criteria_groups(criteria)
        labels = groups.map(&:label)
        assert_includes labels, "Ranking limit"
        assert_not_includes labels, "Ranking status"
        assert_equal ["Deep cuts"], groups.find { |g| g.label == "Depth" }.values

        balanced = @pages.criteria_groups(::Books::RecommendationCriteria.new({}))
        assert_equal [], balanced.map(&:label)
      end
    end
  end
end
