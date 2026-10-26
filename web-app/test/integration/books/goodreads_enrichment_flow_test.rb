# frozen_string_literal: true

require "test_helper"

module Books
  # Spec acceptance scenario 1: a new book through the real engine with the
  # goodreads step live. Only the boundaries are stubbed: the page fetcher
  # (fixture HTML per URL), the FetchGate turn, the cheap-model pick, the book
  # AI tasks, and the author and Amazon steps.
  class GoodreadsEnrichmentFlowTest < ActiveSupport::TestCase
    BASE_URL = "http://open-library.test:8080"
    FETCH = ::Books::Goodreads::GateTurn::Decision.new(action: :fetch, wait: nil, refusal: nil)
    DESCRIPTION = "Captain Yossarian flies bombing missions from a Mediterranean island and slowly realizes that the " \
      "army's own rules make escape impossible. A bureaucratic trap closes around every airman, and the " \
      "laughter this novel provokes turns darker with each chapter. It remains a landmark of postwar satire, " \
      "loved for its looping structure and its fury at institutional madness."

    setup do
      ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([])
      ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
      client = ::Books::OpenLibrary::Client.new(
        config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
        breaker: ::Books::OpenLibrary::CircuitBreaker.new(key: "test:gr_flow:open_library", failure_threshold: 5, cooldown: 60,
          redis: ::Books::OpenLibrary::FakeRedis.new)
      )
      ::Books::OpenLibrary::Client.stubs(:new).returns(client)
      stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
      Workflows::Coordinator.cancel(workflow_runs(:tolstoy_author_run), outcome: "test")

      stub_authors_and_amazon
      stub_goodreads
      stub_book_ai
    end

    def ok(klass, data = {}) = klass::Result.new(success?: true, data: data, errors: [])

    def stub_authors_and_amazon
      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(ok(::Services::Books::Authors::EnrichFromWikidata, {outcome: :matched}))
      ::Services::Books::Authors::EnrichFromViaf.stubs(:call)
        .returns(ok(::Services::Books::Authors::EnrichFromViaf, {outcome: :unmatched, wikidata_qid: nil, decision: nil}))
      ::Services::Books::Authors::EnrichAuthor.stubs(:call).returns(ok(::Services::Books::Authors::EnrichAuthor))
      ::Services::Books::AmazonProductService.stubs(:call).returns({success: true, data: {}, errors: []})
    end

    def fixture_html(name) = Zlib.gunzip(file_fixture("goodreads/#{name}").binread).force_encoding(Encoding::UTF_8)

    def fetched(html)
      ::PageFetcher::Page.new(url: "u", final_url: "u", status: 200, title: "t", html: html, selector_found: true,
        elapsed_ms: 1_000, fetched_at: Time.current)
    end

    # The search page answers the /search URL and the constructed v2 page
    # answers 168668; any other URL fails the test by raising.
    def stub_goodreads
      @gate_turns = 0
      ::Books::Goodreads::GateTurn.stubs(:call).with { |**|
        @gate_turns += 1
        true
      }.returns(FETCH)
      ::Books::Goodreads::GateTurn.stubs(:after_fetch)

      pages = {
        "search" => fetched(fixture_html("searches/catch_22_title_only.html.gz")),
        "168668" => fetched(fixture_html("pages/catch_22_main_168668.html.gz"))
      }
      fetcher = Object.new
      fetcher.define_singleton_method(:fetch) do |url, **|
        pages.find { |key, _| url.include?(key) }&.last or raise "unexpected fetch: #{url}"
      end
      ::PageFetcher::Client.stubs(:new).returns(fetcher)

      pick = ::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "high"})
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(stub(call: pick))
    end

    def stub_book_ai
      facts = {
        recognized: true, confidence: "high",
        first_published_year: {value: 1961, confidence: "high"}, first_published_year_estimated: false,
        original_language: {value: "en", confidence: "high"}, word_count: {value: nil, confidence: "low"},
        page_range: {value: nil, confidence: "low"}, subtitle: {value: nil, confidence: "low"},
        alternate_titles: {value: [], confidence: "low"}, origin_countries: {value: [], confidence: "low"},
        book_type: {value: "fiction", confidence: "high"}, series_name: {value: nil, confidence: "low"},
        series_number: {value: nil, confidence: "low"}, description: {value: DESCRIPTION, confidence: "high"}
      }
      @modes = []
      ::Services::Ai::Tasks::Books::BookFactsTask.stubs(:new).with { |args|
        @modes << args[:mode]
        true
      }.returns(stub(call: ::Services::Ai::Result.new(success: true, data: {facts: facts, citations: []})))
      review = {spoilers: false, spoiler_notes: nil, style_violations: [], rewritten: nil}
      ::Services::Ai::Tasks::Books::DescriptionReviewTask.stubs(:new)
        .returns(stub(call: ::Services::Ai::Result.new(success: true, data: review)))
    end

    test "a new book is matched on Goodreads, filled from the page, and written by sourced book AI" do
      book = DataImporters::Books::Book::Importer.call(title: "Catch-22", author_names: ["Joseph Heller"]).item.reload

      assert_equal [1961, "453", "168668"],
        [book.first_published_year, book.page_range, book.identifiers.find_by(identifier_type: "books_work_goodreads_id")&.value]
      assert book.category_items.exists?(source: :goodreads)

      assert_equal [:sourced], @modes
      assert_equal %w[sourced], book.enrichments.where(kind: "books.book_facts").map(&:mode)
      assert_equal 0, book.enrichments.research.count
      assert book.descriptions.exists?(source: :ai_generated)

      run = WorkflowRun.where(enrichable: book).order(:id).first
      goodreads, amazon = run.step(:goodreads), run.step(:amazon)
      assert_equal ["completed", "succeeded", "succeeded"], [run.status, goodreads.state, amazon.state]
      assert_operator amazon.started_at, :>=, goodreads.finished_at
      assert_equal 2, @gate_turns, "one search and one page fetch, a turn each"
    end
  end
end
