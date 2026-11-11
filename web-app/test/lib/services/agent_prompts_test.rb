require "test_helper"

module Services
  class AgentPromptsTest < ActiveSupport::TestCase
    test "duplicates renders the admin MCP url and the pending counts for books" do
      prompt = AgentPrompts.call(domain: :books, queue: :duplicates)

      pending = DuplicateCandidate.pending.group(:item_type).count
      assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
      assert_includes prompt, "#{pending["Books::Book"].to_i} pending book pairs"
      assert_includes prompt, "#{pending["Books::Author"].to_i} pending author pairs"
      assert_includes prompt, "list_duplicate_candidates"
    end

    test "duplicates counts pending pairs only" do
      before = AgentPrompts.call(domain: "books", queue: :duplicates)
      a, b = [books_authors(:king).id, books_authors(:bachman).id].minmax
      DuplicateCandidate.create!(item_type: "Books::Author", item_a_id: a, item_b_id: b, source: :human, status: :merged)

      assert_equal before, AgentPrompts.call(domain: "books", queue: :duplicates)
    end

    test "match decisions renders the admin MCP url and the pending counts per finder" do
      pending = MatchDecision.needing_review.where(verify: false).group(:finder).count
      prompt = AgentPrompts.call(domain: :books, queue: :match_decisions)

      assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
      assert_includes prompt, "#{pending["Services::Books::Authors::ResolveWikidata"].to_i} pending Wikidata link decisions"
      assert_includes prompt, "#{pending["Services::Books::Authors::ResolveViaf"].to_i} pending VIAF link decisions"
      assert_includes prompt, "#{pending["DataImporters::Books::Author::Finder"].to_i} pending author match decisions"
      assert_includes prompt, "review_match_decision"
    end

    test "match decisions counts only decisions needing review with verify hidden" do
      finder = "DataImporters::Books::Author::Finder"
      count = -> { AgentPrompts.call(domain: :books, queue: :match_decisions)[/(\d+) pending author match decisions/, 1].to_i }
      before = count.call
      attrs = {finder: finder, outcome: :unmatched, confidence: :low, decided_by: :rule}

      MatchDecision.create!(**attrs, needs_review: true, reviewed_at: Time.current, verify: false)
      MatchDecision.create!(**attrs, needs_review: true, verify: true)
      MatchDecision.create!(**attrs, needs_review: false, verify: false)
      assert_equal before, count.call

      MatchDecision.create!(**attrs, needs_review: true, verify: false)
      assert_equal before + 1, count.call
    end

    test "is nil for a domain with no prompt file" do
      assert_nil AgentPrompts.call(domain: :games, queue: :duplicates)
      assert_nil AgentPrompts.call(domain: :games, queue: :match_decisions)
    end

    test "rejects an unknown queue" do
      assert_raises(ArgumentError) { AgentPrompts.call(domain: :books, queue: :other) }
    end
  end
end
