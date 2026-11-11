require "test_helper"

module Services
  module DuplicateCandidates
    class AgentPromptTest < ActiveSupport::TestCase
      test "renders the admin MCP url and the pending counts for books" do
        prompt = AgentPrompt.call(domain: :books)

        pending = DuplicateCandidate.pending.group(:item_type).count
        assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
        assert_includes prompt, "#{pending["Books::Book"].to_i} pending book pairs"
        assert_includes prompt, "#{pending["Books::Author"].to_i} pending author pairs"
      end

      test "counts pending pairs only" do
        before = AgentPrompt.call(domain: "books")
        a, b = [books_authors(:king).id, books_authors(:bachman).id].minmax
        DuplicateCandidate.create!(item_type: "Books::Author", item_a_id: a, item_b_id: b, source: :human, status: :merged)

        assert_equal before, AgentPrompt.call(domain: "books")
      end

      test "is nil for a domain with no prompt file" do
        assert_nil AgentPrompt.call(domain: :games)
      end
    end
  end
end
