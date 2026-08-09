# frozen_string_literal: true

require "test_helper"

module Books
  class SavedSearchQueryTest < ActiveSupport::TestCase
    def criteria(hash = {})
      ::Books::SavedSearchCriteria.new(hash)
    end

    def stub_search(ids:, total: nil)
      ::Search::Books::Search::BookAdvanced
        .stubs(:call)
        .returns({ids: ids, total: total || ids.size})
    end

    # Verified 2026-08-09: these are real fixture labels, `books_global` is the
    # default primary (global: true, primary: true), and ranked_items.yml
    # contains NO books rows -- only movies/music/games -- so creating one here
    # cannot collide with index_ranked_items_on_item_and_ranking_config_unique.
    setup do
      @owner = users(:regular_user)
      @rc = ::Books::RankingConfiguration.default_primary
      @book_a = books_books(:war_and_peace)
      @book_b = books_books(:crime_and_punishment)
    end

    test "hydrates the ids the search returned" do
      stub_search(ids: [@book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_a.id], result.books.map(&:id)
      assert_equal 1, result.total
    end

    test "preserves the order OpenSearch returned rather than the database's" do
      stub_search(ids: [@book_b.id, @book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_b.id, @book_a.id], result.books.map(&:id)
    end

    test "returns the total even when it exceeds the page" do
      stub_search(ids: [@book_a.id], total: 4391)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 4391, result.total
    end

    test "returns no books when the search matched nothing" do
      stub_search(ids: [], total: 0)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [], result.books
      assert_equal 0, result.total
    end

    test "drops an id with no matching book rather than raising" do
      stub_search(ids: [@book_a.id, 999_999_999], total: 2)

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal [@book_a.id], result.books.map(&:id)
    end

    test "carries ranked_position from the ranking configuration" do
      RankedItem.create!(
        item: @book_a, ranking_configuration: @rc, rank: 7, score: 99.0
      )
      stub_search(ids: [@book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 7, result.books.first.ranked_position.to_i
    end

    test "leaves ranked_position nil for an unranked book" do
      stub_search(ids: [@book_b.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_nil result.books.first.ranked_position
    end

    test "passes the owner's read books to the search when hide_read is set" do
      # The regular_user fixture set already gives @owner a :read list
      # (regular_user_books_read); one_default_per_type_per_user allows only
      # one per user, so it must go before this test can create its own.
      ::Books::UserList.where(user: @owner, list_type: :read).destroy_all
      list = ::Books::UserList.create!(user: @owner, name: "Read", list_type: :read)
      list.user_list_items.create!(listable: @book_a, position: 1)

      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [@book_a.id] }
        .returns({ids: [@book_b.id], total: 1})

      ::Books::SavedSearchQuery.call(criteria: criteria({"hide_read" => true}), owner: @owner)
    end

    test "passes no exclusions when hide_read is not set" do
      # Same fixture collision as above: @owner's fixture :read list must be
      # cleared before this test can create its own.
      ::Books::UserList.where(user: @owner, list_type: :read).destroy_all
      list = ::Books::UserList.create!(user: @owner, name: "Read", list_type: :read)
      list.user_list_items.create!(listable: @book_a, position: 1)

      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [] }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)
    end

    test "passes no exclusions when hide_read is set but there is no owner" do
      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:excluded_book_ids] == [] }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria({"hide_read" => true}), owner: nil)
    end

    test "forwards paging to the search" do
      ::Search::Books::Search::BookAdvanced
        .expects(:call)
        .with { |_c, options| options[:page] == 3 && options[:per_page] == 25 }
        .returns({ids: [], total: 0})

      ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner, page: 3, per_page: 25)
    end

    test "defaults to the default primary ranking configuration" do
      RankedItem.create!(item: @book_a, ranking_configuration: @rc, rank: 42, score: 99.0)
      stub_search(ids: [@book_a.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_equal 42, result.books.first.ranked_position.to_i
    end

    test "raises for a ranking configuration other than the default primary" do
      other = ranking_configurations(:books_user)
      stub_search(ids: [])

      error = assert_raises(ArgumentError) do
        ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner, ranking_configuration: other)
      end

      assert_match(/default primary/i, error.message)
    end

    test "preloads authors so a caller rendering a grid does not N+1" do
      stub_search(ids: [@book_a.id, @book_b.id])

      result = ::Books::SavedSearchQuery.call(criteria: criteria, owner: @owner)

      assert_queries_count(0) do
        result.books.each { |book| book.book_authors.map(&:author) }
      end
    end
  end
end
