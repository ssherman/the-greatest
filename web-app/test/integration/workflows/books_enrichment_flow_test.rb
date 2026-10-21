# frozen_string_literal: true

require "test_helper"

# Whole book and author runs through the real engine: planner, coordinator,
# WorkflowStepJob and the recovery sweep. Sidekiq runs inline and the dispatch is
# NOT stubbed, so a finished step really dispatches what it readied. Only the
# service boundary is stubbed (Wikidata, VIAF, the two AI steps, Amazon, and
# Open Library, which is down so the importer falls back to the query's names).
module Workflows
  class BooksEnrichmentFlowTest < ActiveSupport::TestCase
    BASE_URL = "http://open-library.test:8080"

    setup do
      ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([])
      ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
      stub_open_library_down
      @calls = []
      stub_services
    end

    def stub_open_library_down
      client = ::Books::OpenLibrary::Client.new(
        config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
        breaker: ::Books::OpenLibrary::CircuitBreaker.new(key: "test:flow:open_library", failure_threshold: 5, cooldown: 60,
          redis: ::Books::OpenLibrary::FakeRedis.new)
      )
      ::Books::OpenLibrary::Client.stubs(:new).returns(client)
      stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
    end

    def success(klass, data = {})
      klass::Result.new(success?: true, data: data, errors: [])
    end

    # Records every service call, in order, so a test can assert on the sequence.
    def stub_services
      calls = @calls
      wikidata_result = success(::Services::Books::Authors::EnrichFromWikidata, {outcome: :matched})
      viaf_result = success(::Services::Books::Authors::EnrichFromViaf, {outcome: :unmatched, wikidata_qid: nil, decision: nil})
      author_result = success(::Services::Books::Authors::EnrichAuthor)
      book_result = success(::Services::Books::EnrichBook)

      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).with { |**kwargs|
        calls << [:wikidata, kwargs[:author].name]
        true
      }.returns(wikidata_result)
      ::Services::Books::Authors::EnrichFromViaf.stubs(:call).with { |**kwargs|
        calls << [:viaf, kwargs[:author].name]
        true
      }.returns(viaf_result)
      ::Services::Books::Authors::EnrichAuthor.stubs(:call).with { |**kwargs|
        calls << [:author_facts, kwargs[:author].name]
        true
      }.returns(author_result)
      ::Services::Books::EnrichBook.stubs(:call).with { |**kwargs|
        calls << [:book_facts, kwargs[:book].title]
        true
      }.returns(book_result)
      ::Services::Books::AmazonProductService.stubs(:call).with { |**kwargs|
        calls << [:amazon, kwargs[:book].title]
        true
      }.returns({success: true, data: {}, errors: []})
    end

    def import(title, *author_names)
      DataImporters::Books::Book::Importer.call(title: title, author_names: author_names).item.reload
    end

    def runs_of(record)
      WorkflowRun.where(enrichable: record).order(:id)
    end

    def called(kind)
      @calls.select { |name, _| name == kind }.map(&:last)
    end

    test "an imported book with two new authors runs book AI once, after both authors' AI steps" do
      book = import("Two Hands", "Nora Quillfeather", "Basil Tern")

      assert_equal ["Basil Tern", "Nora Quillfeather"], book.authors.map(&:name).sort
      assert_equal [["Two Hands"], 2], [called(:book_facts), called(:author_facts).size]
      assert_operator @calls.index([:book_facts, "Two Hands"]), :>, @calls.rindex { |kind, _| kind == :author_facts }

      assert_equal %w[completed completed], runs_of(book.authors).map(&:status)
      assert_equal %w[completed], runs_of(book).map(&:status)
      assert_equal %w[succeeded succeeded], runs_of(book).first.steps.order(:id).map(&:state)
    end

    test "importing the same book again plans and runs nothing" do
      import("Two Hands", "Nora Quillfeather", "Basil Tern")
      @calls.clear

      import("Two Hands", "Nora Quillfeather", "Basil Tern")

      assert_empty @calls
    end

    test "an author on a far VIAF turn does not hold the book's AI step, and VIAF finishes later" do
      ::Services::Books::Authors::EnrichFromWikidata.stubs(:call).returns(
        success(::Services::Books::Authors::EnrichFromWikidata, {outcome: :unmatched})
      )
      # A busy line whose next turn is two hours off: the VIAF step releases itself.
      ::Viaf::Schedule.stubs(:new).returns(stub(horizon: 1, reserve: 7200))

      book = import("Slow Line", "Orla Fenwick", "Jory Pell")

      authors = book.authors.order(:name).to_a
      assert_equal [2, ["Slow Line"], []], [called(:author_facts).size, called(:book_facts), called(:viaf)]
      viaf_steps = authors.map { |author| runs_of(author).first.step(:viaf) }
      assert_equal %w[waiting waiting], viaf_steps.map(&:state)
      assert_equal %w[running running], runs_of(authors).map(&:status)
      assert_equal %w[completed], runs_of(book).map(&:status)

      travel_to 3.hours.from_now do
        Workflows::Recovery.call
      end

      assert_equal authors.map(&:name).sort, called(:viaf).sort
      assert_equal %w[completed completed], runs_of(authors).map(&:status)
      assert_equal [1, 2], [called(:book_facts).size, called(:author_facts).size],
        "an unmatched VIAF has no QID to send back, so neither AI step runs again"
    end

    test "a worker crash mid-step is recovered by the sweep" do
      run = Sidekiq::Testing.fake! { Workflows::Books::BookEnrichment.start(books_books(:got), initiated_by: "test") }
      step = run.step(:book_facts)
      assert_predicate step, :ready?
      Workflows::Coordinator.claim(step.id, token: "dead-worker")
      step.update_columns(lease_expires_at: 1.minute.ago)

      # The amazon message was only queued in the fake; its dispatch window stays open ten minutes.
      travel_to 11.minutes.from_now do
        Workflows::Recovery.call
      end

      assert_equal ["completed", "succeeded", 1], [run.reload.status, run.step(:book_facts).state, run.step(:book_facts).attempts]
      assert_equal "succeeded", run.step(:amazon).state
      assert_equal 1, called(:book_facts).size
    end

    test "a committed advance whose dispatch failed is recovered by the sweep" do
      chain = WorkflowStepJob.set(queue: "author_chain")
      serial = WorkflowStepJob.set(queue: "serial")
      WorkflowStepJob.stubs(:set).with(queue: "author_chain").returns(chain)
      WorkflowStepJob.stubs(:set).with(queue: "serial").returns(serial)
      WorkflowStepJob.stubs(:set).with(queue: "low").raises(RedisClient::CannotConnectError.new("redis is down"))

      book = import("Lost Message", "Edda Marlow")

      book_run = runs_of(book).first
      step = book_run.step(:book_facts)
      assert_equal ["running", "ready", nil, []], [book_run.status, step.state, step.dispatched_at, called(:book_facts)]

      WorkflowStepJob.unstub(:set)
      Workflows::Recovery.call

      assert_equal ["completed", "succeeded", ["Lost Message"]], [book_run.reload.status, step.reload.state, called(:book_facts)]
    end
  end
end
