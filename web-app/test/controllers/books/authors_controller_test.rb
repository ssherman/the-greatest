require "test_helper"

module Books
  class AuthorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @author = books_authors(:tolstoy)
      @author_config = ranking_configurations(:books_authors_global)
      @books_config = ranking_configurations(:books_global)
      @author_config.ranked_items.destroy_all
      RankedItem.create!(item: @author, ranking_configuration: @author_config, rank: 1, score: 100)
    end

    test "renders the author show page" do
      get "/author/#{@author.slug}"

      assert_response :success
    end

    test "renders an author with no ranked item" do
      @author_config.ranked_items.destroy_all

      get "/author/#{@author.slug}"

      assert_response :success
    end

    test "404s for an unknown slug" do
      get "/author/not-a-real-author"

      assert_response :not_found
    end

    test "sets a public cache-control header on show" do
      get "/author/#{@author.slug}"

      assert_match(/max-age=86400/, response.headers["Cache-Control"])
      assert_match(/public/, response.headers["Cache-Control"])
    end

    test "renders the all-books page" do
      get "/author/#{@author.slug}/all-books"

      assert_response :success
    end

    test "sets a public cache-control header on all-books" do
      get "/author/#{@author.slug}/all-books"

      assert_match(/max-age=86400/, response.headers["Cache-Control"])
    end

    test "404s past the last all-books page" do
      get "/author/#{@author.slug}/all-books/page/99"

      assert_response :not_found
    end

    test "renders show scoped to an explicit ranking configuration" do
      get "/rc/#{@books_config.id}/author/#{@author.slug}"

      assert_response :success
    end

    # Brief's fixtures only rank the author, never one of their books, so the
    # ranked-books join/preload/alias branch would otherwise go untested (the
    # same gap Task 5 shipped). This test ranks the author's book directly.
    test "carries the book's rank through the ranked_items join as ranked_position" do
      book = books_books(:war_and_peace)
      RankedItem.create!(item: book, ranking_configuration: @books_config, rank: 7, score: 50)

      get "/author/#{@author.slug}"

      assert_response :success
      ranked_books = @controller.view_assigns["ranked_books"]
      assert_equal [book.id], ranked_books.map(&:id)
      assert_equal 7, ranked_books.first.ranked_position
    end
  end
end
