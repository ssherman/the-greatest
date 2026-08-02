require "test_helper"

module Books
  module Authors
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      EXPECTED_INDEX_QUERIES = 11

      setup do
        host! "dev-new.thegreatestbooks.org"
        @config = ranking_configurations(:books_authors_global)
        @config.ranked_items.destroy_all
        RankedItem.create!(item: books_authors(:tolstoy), ranking_configuration: @config, rank: 1, score: 100)
        RankedItem.create!(item: books_authors(:king), ranking_configuration: @config, rank: 2, score: 90)
      end

      test "renders the ranked author index" do
        get "/authors"

        assert_response :success
      end

      test "page one redirects to the canonical index" do
        get "/authors/page/1"

        assert_redirected_to "/authors"
        assert_response :moved_permanently
      end

      test "path-based pagination resolves the page" do
        seed_ranked_authors(120)

        get "/authors/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "404s past the last page" do
        get "/authors/page/99"

        assert_response :not_found
      end

      test "handles a missing ranking configuration gracefully" do
        Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

        get "/authors"

        assert_response :success
      end

      test "high page number 404s when no ranking configuration exists" do
        Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

        get "/authors/page/2"

        assert_response :not_found
      end

      test "sets a public cache-control header" do
        get "/authors"

        assert_match(/max-age=21600/, response.headers["Cache-Control"])
        assert_match(/public/, response.headers["Cache-Control"])
      end

      test "index issues a fixed number of queries" do
        seed_ranked_authors(10)

        assert_queries_count(EXPECTED_INDEX_QUERIES) { get "/authors" }
      end

      test "query count does not grow with the number of authors" do
        seed_ranked_authors(10)
        small = count_queries { get "/authors" }

        seed_ranked_authors(60)
        large = count_queries { get "/authors" }

        assert_equal small, large,
          "query count grew from #{small} to #{large} as authors were added -- N+1 in the index"
      end

      private

      def seed_ranked_authors(count)
        start = @config.ranked_items.maximum(:rank).to_i
        books_rc = Books::RankingConfiguration.default_primary
        book_start = books_rc.ranked_items.maximum(:rank).to_i

        count.times do |i|
          author = Books::Author.create!(name: "Seeded Author #{start + i}")
          RankedItem.create!(
            item: author,
            ranking_configuration: @config,
            rank: start + i + 1,
            score: 10
          )

          book = Books::Book.create!(title: "Seeded Book #{start + i}")
          Books::BookAuthor.create!(book: book, author: author, role: :author)
          RankedItem.create!(
            item: book,
            ranking_configuration: books_rc,
            rank: book_start + i + 1,
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
    end
  end
end
