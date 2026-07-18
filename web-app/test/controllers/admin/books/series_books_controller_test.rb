require "test_helper"

module Admin
  module Books
    class SeriesBooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = books_series(:asoiaf)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a series book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        book = books_books(:war_and_peace)
        assert_difference("@series.series_books.count", 1) do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: book.id, position: "3", numbered: "1", position_label: "Book 3"}}
        end
        assert_redirected_to admin_books_series_path(@series)
        assert_equal book.id, @series.series_books.order(:created_at).last.book_id
      end

      test "create rejects a duplicate book in the series" do
        sign_in_as(@admin_user, stub_auth: true)
        existing = @series.series_books.first.book
        assert_no_difference("::Books::SeriesBook.count") do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: existing.id, position: "9"}}
        end
        assert_redirected_to admin_books_series_path(@series)
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        book = books_books(:war_and_peace)
        assert_no_difference("::Books::SeriesBook.count") do
          post admin_books_series_series_books_path(@series), params: {books_series_book: {book_id: book.id, position: "3"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the position" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = books_series_books(:asoiaf_got)
        patch admin_books_series_book_path(sb), params: {books_series_book: {position: "5", numbered: "0", position_label: "Prequel"}}
        assert_redirected_to admin_books_series_path(@series)
        assert_equal 5.0, sb.reload.position
        assert_equal false, sb.numbered
      end

      test "destroy removes the series book" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = @series.series_books.create!(book: books_books(:war_and_peace), position: 4)
        assert_difference("::Books::SeriesBook.count", -1) do
          delete admin_books_series_book_path(sb)
        end
        assert_redirected_to admin_books_series_path(@series)
      end

      test "make_representative sets the series representative_book" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = books_series_books(:asoiaf_clash)
        post make_representative_admin_books_series_book_path(sb)
        assert_redirected_to admin_books_series_path(@series)
        assert_equal sb.book_id, @series.reload.representative_book_id
      end

      test "make_representative is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        sb = books_series_books(:asoiaf_clash)
        post make_representative_admin_books_series_book_path(sb)
        assert_redirected_to books_root_path
        assert_nil @series.reload.representative_book_id
      end

      test "destroy clears the representative when removing the representative book" do
        sign_in_as(@admin_user, stub_auth: true)
        sb = books_series_books(:asoiaf_got)
        @series.update!(representative_book_id: sb.book_id)
        delete admin_books_series_book_path(sb)
        assert_nil @series.reload.representative_book_id
      end

      test "destroy keeps the representative when removing a different book" do
        sign_in_as(@admin_user, stub_auth: true)
        rep = books_series_books(:asoiaf_got)
        other = books_series_books(:asoiaf_clash)
        @series.update!(representative_book_id: rep.book_id)
        delete admin_books_series_book_path(other)
        assert_equal rep.book_id, @series.reload.representative_book_id
      end
    end
  end
end
