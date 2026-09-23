require "test_helper"

module DataImporters
  class CandidateTest < ActiveSupport::TestCase
    def setup
      @book = books_books(:war_and_peace)
    end

    test "local? and external? describe which halves are present" do
      local = Candidate.new(record: @book, sources: [:exact])
      external = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library])
      both = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library)

      assert local.local?
      assert_not local.external?
      assert_not external.local?
      assert external.external?
      assert both.local?
      assert both.external?
    end

    test "defaults sources, scores and evidence, and decisive is false" do
      candidate = Candidate.new(record: @book)

      assert_equal [], candidate.sources
      assert_equal({}, candidate.scores)
      assert_equal({}, candidate.evidence)
      assert_not candidate.decisive?
    end

    test "ranked? reads the ranked_position evidence" do
      assert Candidate.new(record: @book, evidence: {ranked_position: 12}).ranked?
      assert_not Candidate.new(record: @book, evidence: {ranked_position: nil}).ranked?
    end

    test "external_accepted? reads the external_verdict evidence" do
      assert Candidate.new(external_key: "OL1W", evidence: {external_verdict: "accept"}).external_accepted?
      assert_not Candidate.new(external_key: "OL1W", evidence: {external_verdict: "abstain"}).external_accepted?
    end

    test "absorb unions sources, merges scores and evidence, fills missing halves and keeps decisive if either is" do
      local = Candidate.new(record: @book, sources: [:exact], scores: {}, evidence: {title: "War and Peace", year: 1869})
      external = Candidate.new(
        record: @book, external_key: "OL1W", external_source: :open_library,
        sources: [:open_library], scores: {open_library: 0.9}, evidence: {external_verdict: "accept", year: nil}, decisive: true
      )

      local.absorb(external)

      assert_equal [:exact, :open_library], local.sources
      assert_equal({open_library: 0.9}, local.scores)
      assert_equal "OL1W", local.external_key
      assert_equal :open_library, local.external_source
      assert_equal 1869, local.evidence[:year], "an absorbed nil never overwrites a value"
      assert_equal "accept", local.evidence[:external_verdict]
      assert local.decisive?
    end

    test "snapshot is JSON-safe and carries no record object" do
      candidate = Candidate.new(
        record: @book, external_key: "OL1W", external_source: :open_library,
        sources: [:exact, :open_library], scores: {opensearch: 7.5}, evidence: {title: "War and Peace", creators: ["Leo Tolstoy"]}
      )

      snapshot = candidate.snapshot

      assert_equal "Books::Book", snapshot[:record_type]
      assert_equal @book.id, snapshot[:record_id]
      assert_equal "open_library", snapshot[:external_source]
      assert_equal "OL1W", snapshot[:external_key]
      assert_equal %w[exact open_library], snapshot[:sources]
      assert_equal({"opensearch" => 7.5}, snapshot[:scores])
      assert_equal({"title" => "War and Peace", "creators" => ["Leo Tolstoy"]}, snapshot[:evidence])
      assert_nothing_raised { JSON.generate(snapshot) }
    end
  end
end
