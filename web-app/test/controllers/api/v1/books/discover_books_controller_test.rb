require "test_helper"

module Api
  module V1
    module Books
      class DiscoverBooksControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @mice = books_books(:of_mice_and_men)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def engine(*books, total: books.size)
          {ids: books.map(&:id), total: total, total_relation: "eq"}
        end

        def discover(params = {}) = get("/api/v1/discover/books", params: params, headers: bearer(ApiTokenSecrets::MEMBER))

        test "returns the books in the engine's order with the primary rank, and asks for exact totals" do
          RankedItem.create!(item: @war, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1)
          RankedItem.create!(item: @crime, ranking_configuration: ranking_configurations(:books_user), rank: 3, score: 1)
          ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, **opts| opts[:track_total_hits] == true && opts[:order] == :rank && opts[:seed].nil? }
            .returns(engine(@mice, @war, @crime))

          discover
          assert_api_conform(status: 200)

          assert_equal [@mice.id, @war.id, @crime.id], json[:data].map { |b| b[:id] }
          assert_equal [nil, 7, nil], json[:data].map { |b| b[:rank] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1, order: "rank"}, json[:meta])
        end

        test "meta.filters echoes the applied filters" do
          ::Search::Books::Search::BookAdvanced.stubs(:call).returns(engine(@war))

          discover(language: "english", length: "long,short", ranked: "all")
          assert_api_conform(status: 200)

          assert_equal({language: "english", length: "short,long", ranked: "all"}, json[:meta][:filters])
          assert_includes json[:links][:self], "language=english"
        end

        test "order=random with a seed passes both to the engine and carries them in meta and links" do
          ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, **opts| opts[:order] == :random && opts[:seed] == 5 }
            .returns(engine(@war, total: 120))

          discover(order: "random", seed: 5, per_page: 10)
          assert_api_conform(status: 200)

          assert_equal [5, "random"], [json[:meta][:seed], json[:meta][:order]]
          assert_includes json[:links][:next], "seed=5"
          assert_includes json[:links][:next], "order=random"
        end

        test "order=random without a seed generates one and puts it in the links" do
          ::Search::Books::Search::BookAdvanced.stubs(:call).returns(engine(@war))

          discover(order: "random")

          seed = json[:meta][:seed]
          assert_kind_of Integer, seed
          assert_includes json[:links][:self], "seed=#{seed}"
        end

        test "the last reachable page of the window is 334 at per_page=30, and the one after is a 400" do
          ::Search::Books::Search::BookAdvanced.stubs(:call).returns(engine(@war, total: 100_000))

          discover(per_page: 30, page: 334)
          assert_api_conform(status: 200)
          assert_equal [334, 100_000], [json[:meta][:total_pages], json[:meta][:total_count]]
          assert_nil json[:links][:next]

          ::Search::Books::Search::BookAdvanced.unstub(:call)
          ::Search::Books::Search::BookAdvanced.expects(:call).never
          discover(per_page: 30, page: 335)
          assert_api_conform(status: 400)
        end

        test "hide_read passes the read list's books as exclusions" do
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @crime)
          ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, **opts| opts[:excluded_book_ids].include?(@crime.id) }
            .returns(engine(@war))

          discover(hide_read: "true")
          assert_api_conform(status: 200)

          assert_equal({hide_read: true}, json[:meta][:filters])
        end

        test "hide_read for a user with no read list excludes nothing" do
          user_lists(:regular_user_books_read).destroy!
          ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, **opts| opts[:excluded_book_ids] == [] }
            .returns(engine(@war))

          discover(hide_read: "true")

          assert_response :success
        end

        test "with no primary ranking the page is empty and the engine is never asked" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
          ::Search::Books::Search::BookAdvanced.expects(:call).never

          discover
          assert_api_conform(status: 200)

          assert_equal [[], 0], [json[:data], json[:meta][:total_count]]
        end

        test "an unknown language slug is a 404" do
          ::Search::Books::Search::BookAdvanced.expects(:call).never

          discover(language: "klingon")

          assert_api_conform(status: 404)
        end

        test "rank_min above rank_max is a 400" do
          discover(rank_min: 10, rank_max: 5)

          assert_api_conform(status: 400)
        end

        test "an unavailable search service is a 503" do
          ::Search::Books::Search::BookAdvanced.stubs(:call).raises(::Search::Shared::Client::UNAVAILABLE_ERRORS.first)

          discover

          assert_api_conform(status: 503)
        end
      end
    end
  end
end
