# frozen_string_literal: true

require "test_helper"

module Books
  # Fixture facts this file leans on, verified 2026-08-23:
  #   * `books_global` is the default primary Books::RankingConfiguration.
  #   * ranked_items.yml carries NO Books::Book rows (only movies/music/games),
  #     so a RankedItem created here cannot collide with
  #     index_ranked_items_on_item_and_ranking_config_unique.
  #   * war_and_peace has an author (tolstoy); crime_and_punishment has none.
  class BookSearchQueryTest < ActiveSupport::TestCase
    # The shape Search::Base::Search#extract_hits_with_scores returns: `id` is
    # a String because OpenSearch's _id is.
    def stub_search(*books, scores: nil)
      hits = books.each_with_index.map do |book, i|
        {id: book.id.to_s, score: scores ? scores[i] : (10.0 - i), source: {"title" => book.title}}
      end
      ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits)
    end

    setup do
      @rc = ::Books::RankingConfiguration.default_primary
      @book_a = books_books(:war_and_peace)
      @book_b = books_books(:crime_and_punishment)
    end

    test "returns nothing for a blank query without touching OpenSearch" do
      ::Search::Books::Search::BookGeneral.expects(:call).never

      assert_equal [], ::Books::BookSearchQuery.call("")
      assert_equal [], ::Books::BookSearchQuery.call("   ")
      assert_equal [], ::Books::BookSearchQuery.call(nil)
    end

    test "hydrates the ids the search returned" do
      stub_search(@book_a)

      assert_equal [@book_a.id], ::Books::BookSearchQuery.call("war").map(&:id)
    end

    # Asserted in both directions on purpose: fixture ids are hashed, so a
    # single ordering can coincide with the database's and pass against a
    # query that never reapplies the search order at all.
    test "preserves the relevance order rather than the database's" do
      stub_search(@book_b, @book_a)
      assert_equal [@book_b.id, @book_a.id], ::Books::BookSearchQuery.call("x").map(&:id)

      stub_search(@book_a, @book_b)
      assert_equal [@book_a.id, @book_b.id], ::Books::BookSearchQuery.call("x").map(&:id)
    end

    test "drops an id the index still has but the database does not" do
      hits = [
        {id: @book_a.id.to_s, score: 10.0, source: {}},
        {id: "999999999", score: 9.0, source: {}}
      ]
      ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits)

      assert_equal [@book_a.id], ::Books::BookSearchQuery.call("x").map(&:id)
    end

    test "collapses an id the index returned twice" do
      stub_search(@book_a, @book_a)

      assert_equal [@book_a.id], ::Books::BookSearchQuery.call("x").map(&:id)
    end

    test "carries ranked_position from the default primary configuration" do
      RankedItem.create!(item: @book_a, ranking_configuration: @rc, rank: 7, score: 99.0)
      stub_search(@book_a)

      assert_equal 7, ::Books::BookSearchQuery.call("war").first.ranked_position.to_i
    end

    test "leaves ranked_position nil for an unranked book" do
      stub_search(@book_b)

      assert_nil ::Books::BookSearchQuery.call("crime").first.ranked_position
    end

    # A rank from a non-primary configuration must not leak onto the card: the
    # badge means "position in the global ranking" everywhere else on the site.
    test "ignores a rank belonging to another ranking configuration" do
      RankedItem.create!(
        item: @book_a, ranking_configuration: ranking_configurations(:books_user),
        rank: 3, score: 99.0
      )
      stub_search(@book_a)

      assert_nil ::Books::BookSearchQuery.call("war").first.ranked_position
    end

    test "asks OpenSearch for the requested number of results" do
      ::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 50).returns([])
      ::Books::BookSearchQuery.call("war")

      ::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 5).returns([])
      ::Books::BookSearchQuery.call("war", size: 5)
    end

    test "preloads authors and covers so a caller rendering a grid does not N+1" do
      stub_search(@book_a, @book_b)

      books = ::Books::BookSearchQuery.call("x")

      assert_queries_count(0) do
        books.each do |book|
          book.book_authors.map { |book_author| book_author.author.name }
          book.primary_image&.file&.attached?
        end
      end
    end
  end
end
