require "test_helper"

module Books
  class SearchesControllerTest < ActionDispatch::IntegrationTest
    def stub_search(*books)
      hits = books.each_with_index.map do |book, i|
        {id: book.id.to_s, score: 10.0 - i, source: {"title" => book.title}}
      end
      ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits)
    end

    setup do
      host! "dev-new.thegreatestbooks.org"
      @book_a = books_books(:war_and_peace)
      @book_b = books_books(:crime_and_punishment)
    end

    test "renders the prompt without querying OpenSearch when q is missing" do
      ::Search::Books::Search::BookGeneral.expects(:call).never

      get "/search"

      assert_response :success
      assert_equal [], @controller.view_assigns["books"]
    end

    test "renders the prompt without querying OpenSearch when q is blank" do
      ::Search::Books::Search::BookGeneral.expects(:call).never

      get "/search?q=+"

      assert_response :success
      assert_equal [], @controller.view_assigns["books"]
    end

    test "renders the matches in the order OpenSearch returned" do
      stub_search(@book_b, @book_a)

      get "/search?q=russian"

      assert_response :success
      assert_equal [@book_b.id, @book_a.id], @controller.view_assigns["books"].map(&:id)
      assert_select "h1", /russian/
    end

    test "asks OpenSearch for fifty results" do
      ::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 50).returns([])

      get "/search?q=war"

      assert_response :success
    end

    test "renders an empty state when nothing matched" do
      ::Search::Books::Search::BookGeneral.stubs(:call).returns([])

      get "/search?q=zzzznope"

      assert_response :success
      assert_equal [], @controller.view_assigns["books"]
    end

    # A results page must never be indexed or edge cached: the query string is
    # visitor-supplied, so an indexable variant is unbounded and a cacheable
    # one would serve one visitor's results to the next.
    test "suppresses indexing and edge caching" do
      stub_search(@book_a)

      get "/search?q=war"

      assert_not @controller.view_assigns["indexable"]
      assert_match(/no-store/, response.headers["Cache-Control"])
    end

    test "escapes the query when echoing it back" do
      ::Search::Books::Search::BookGeneral.stubs(:call).returns([])

      get "/search", params: {q: "<script>alert(1)</script>"}

      assert_response :success
      assert_no_match(/<script>alert/, response.body)
    end

    test "survives a query of only special characters" do
      ::Search::Books::Search::BookGeneral.stubs(:call).returns([])

      get "/search", params: {q: "AC/DC & More!"}

      assert_response :success
    end

    test "renders the grid without an author or cover query per book" do
      stub_search(@book_a, @book_b)

      get "/search?q=x"

      assert_response :success
      assert_queries_count(0) do
        @controller.view_assigns["books"].each do |book|
          book.book_authors.map { |book_author| book_author.author.name }
          book.primary_image&.file&.attached?
        end
      end
    end
  end
end
