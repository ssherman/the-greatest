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
      assert @controller.view_assigns["indexable"]
    end

    test "renders an author with no ranked item" do
      # Not @author_config.ranked_items.destroy_all: setup's earlier destroy_all
      # already loaded (and cached) that association as empty, and the RankedItem
      # created right after it was created directly on the class, bypassing the
      # association -- so a second call through the stale cached association
      # would silently destroy nothing.
      RankedItem.where(ranking_configuration: @author_config).destroy_all

      get "/author/#{@author.slug}"

      assert_response :success
      assert_not @controller.view_assigns["indexable"]
    end

    test "404s for an unknown slug" do
      get "/author/not-a-real-author"

      assert_response :not_found
    end

    test "does not fall back to a primary key lookup" do
      get "/author/#{@author.id}"

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
      assert_not @controller.view_assigns["indexable"]
    end

    test "sets a public cache-control header on all-books" do
      get "/author/#{@author.slug}/all-books"

      assert_match(/max-age=86400/, response.headers["Cache-Control"])
    end

    test "404s past the last all-books page" do
      get "/author/#{@author.slug}/all-books/page/99"

      assert_response :not_found
    end

    test "renders the all-books page for an author with no books" do
      author = books_authors(:king)

      get "/author/#{author.slug}/all-books"

      assert_response :success
      assert_empty @controller.view_assigns["books"]
    end

    test "renders show scoped to an explicit ranking configuration" do
      get "/rc/#{@books_config.id}/author/#{@author.slug}"

      assert_response :success
    end

    # The show page renders a Books::CardComponent per ranked book, and each card
    # reads primary_image and book_authors. Without the preloads on the ranked_books
    # relation that is 2-3 queries per book, up to 71 for one author.
    test "show query count does not grow with the number of ranked books" do
      seed_ranked_books_for_author(3)
      small = count_queries { get "/author/#{@author.slug}" }

      seed_ranked_books_for_author(12)
      large = count_queries { get "/author/#{@author.slug}" }

      assert_equal small, large,
        "query count grew from #{small} to #{large} as ranked books were added -- N+1 on the author show page"
    end

    test "all-books keeps unranked books and carries rank only for ranked ones" do
      ranked = books_books(:war_and_peace)
      RankedItem.create!(item: ranked, ranking_configuration: @books_config, rank: 7, score: 50)
      unranked = Books::Book.create!(title: "An Unranked Title")
      Books::BookAuthor.create!(book: unranked, author: @author, role: :author)

      get "/author/#{@author.slug}/all-books"

      assert_response :success
      books = @controller.view_assigns["books"]
      by_id = books.index_by(&:id)

      assert_includes by_id.keys, unranked.id, "the LEFT JOIN dropped an unranked book"
      assert_equal 7, by_id[ranked.id].ranked_position
      assert_nil by_id[unranked.id].ranked_position
      assert_equal ranked.id, books.first.id, "ranked books should sort ahead of unranked ones"
    end

    test "all-books query count does not grow with the number of books" do
      seed_ranked_books_for_author(3)
      small = count_queries { get "/author/#{@author.slug}/all-books" }

      seed_ranked_books_for_author(12)
      large = count_queries { get "/author/#{@author.slug}/all-books" }

      assert_equal small, large,
        "query count grew from #{small} to #{large} as books were added -- N+1 on the all-books page"
    end

    private

    def seed_ranked_books_for_author(count)
      start = @books_config.ranked_items.where(item_type: "Books::Book").count

      count.times do |i|
        book = Books::Book.create!(title: "Seeded Book #{start + i}")
        Books::BookAuthor.create!(book: book, author: @author, role: :author)
        RankedItem.create!(
          item: book,
          ranking_configuration: @books_config,
          rank: start + i + 1,
          score: 10
        )
        next unless i.zero?

        image = Image.new(parent: book, primary: true)
        image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
        image.save!
      end
    end

    def count_queries(&block)
      count = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        count += 1 unless %w[CACHE SCHEMA TRANSACTION].include?(payload[:name])
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
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
