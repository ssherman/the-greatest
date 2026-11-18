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

    test "duplicates prompt carries the author pair rules and their tools" do
      prompt = AgentPrompts.call(domain: :books, queue: :duplicates)

      ["create_admin_author", "update_book_author", "reject_match_decision_link", "shared pseudonym", "409"].each do |text|
        assert_includes prompt, text
      end
    end

    test "duplicates counts pending pairs only" do
      before = AgentPrompts.call(domain: "books", queue: :duplicates)
      a, b = [books_authors(:king).id, books_authors(:bachman).id].minmax
      DuplicateCandidate.create!(item_type: "Books::Author", item_a_id: a, item_b_id: b, source: :human, status: :merged)

      assert_equal before, AgentPrompts.call(domain: "books", queue: :duplicates)
    end

    test "duplicates prompt tells the agent to fix the data that caused a false pair" do
      prompt = AgentPrompts.call(domain: "books", queue: :duplicates)

      assert_includes prompt, "update_book"
      assert_match(/own data caused a false pair/, prompt)
    end

    test "duplicates counts leave out pairs naming a book the re-import is emptying" do
      before = AgentPrompts.call(domain: "books", queue: :duplicates)
      pair = duplicate_candidates(:books_pending_pair)
      ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:mixed:#{pair.item_a_id}",
        payload: {"book_id" => pair.item_a_id}, decided_by: :rule, status: :approved)

      after = AgentPrompts.call(domain: "books", queue: :duplicates)
      pending = DuplicateCandidate.pending.where(item_type: "Books::Book").count
      assert_includes before, "#{pending} pending book pairs"
      assert_includes after, "#{pending - 1} pending book pairs"
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

    test "repair verdicts renders the admin MCP url and the proposed reimport match counts by confidence" do
      prompt = AgentPrompts.call(domain: :books, queue: :repair_verdicts)

      pending = ::Books::RepairVerdict.reimport_match.proposed.current.group(:confidence).count
      assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
      assert_includes prompt, "#{pending["high"].to_i} high confidence"
      assert_includes prompt, "#{pending["medium"].to_i} medium confidence"
      assert_includes prompt, "#{pending["low"].to_i} low confidence"
      assert_includes prompt, "correct_repair_verdict"
    end

    test "repair verdicts counts only proposed reimport matches" do
      count = -> { AgentPrompts.call(domain: :books, queue: :repair_verdicts)[/(\d+) high confidence/, 1].to_i }
      before = count.call
      attrs = {kind: :reimport_match, decided_by: :ai, confidence: :high, payload: {}, reason: "t"}

      ::Books::RepairVerdict.create!(**attrs, subject_key: "t:approved", status: :approved)
      ::Books::RepairVerdict.create!(**attrs, subject_key: "t:rejected", status: :rejected)
      ::Books::RepairVerdict.create!(**attrs, subject_key: "t:other", status: :proposed, kind: :relink)
      ::Books::RepairVerdict.create!(**attrs, subject_key: "t:superseded", status: :proposed, superseded_at: Time.current)
      assert_equal before, count.call

      ::Books::RepairVerdict.create!(**attrs, subject_key: "t:proposed", status: :proposed)
      assert_equal before + 1, count.call
    end

    test "series prompt renders the counts and names the tools" do
      prompt = AgentPrompts.call(domain: :books, queue: :series)

      live = ::Books::Series.active
      single = live.joins(:series_books).group("books_series.id").having("COUNT(*) = 1").count.size
      several = ::Books::SeriesBook.where(series_id: live.select(:id)).group(:book_id).having("COUNT(*) > 1").count.size
      assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
      assert_includes prompt, "#{live.count} live series"
      assert_includes prompt, "#{single} hold a single book"
      assert_includes prompt, "#{several} books are in more than one series"
      %w[list_admin_series get_admin_series create_admin_series update_admin_series delete_admin_series
        merge_admin_series add_series_book update_series_book remove_series_book].each do |tool|
        assert_includes prompt, tool
      end
    end

    test "series counts ignore deleted series" do
      count = -> { AgentPrompts.call(domain: :books, queue: :series)[/(\d+) live series/, 1].to_i }
      before = count.call
      ::Books::Series.create!(title: "Gone", deleted: true)
      assert_equal before, count.call
      ::Books::Series.create!(title: "Alive")
      assert_equal before + 1, count.call
    end

    test "the origin enrichment prompt carries the url, the pending count, the loop and the task's rules" do
      book = ::Books::Book.create!(title: "Pending Origin")
      ::EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
      prompt = AgentPrompts.for_enrichment(Services::Books::QueueTypes::Origin)

      assert_includes prompt, "#{::Api::Host.base_url}/api/mcp/admin"
      assert_includes prompt, "holds 1 pending"
      %w[get_enrichment_queue claim_enrichment_items submit_enrichment_item skip_enrichment_item].each { assert_includes prompt, it }
      assert_includes prompt, Services::Ai::Tasks::Books::BookOriginTask::RULES
    end

    test "the categories enrichment prompt carries the task's rules" do
      prompt = AgentPrompts.for_enrichment(Services::Books::QueueTypes::Categories)

      assert_includes prompt, Services::Ai::Tasks::Books::BookCategoriesTask::RULES
      assert_includes prompt, "claim_enrichment_items"
    end

    test "each enrichment prompt tells the agent when the queue is done and what a 409 means" do
      [Services::Books::QueueTypes::Origin, Services::Books::QueueTypes::Categories].each do |type|
        prompt = AgentPrompts.for_enrichment(type)

        assert_includes prompt, "`meta.remaining` is 0", type.kind
        assert_includes prompt, "no longer yours", type.kind
        assert_includes prompt, "Set `recognized` to true only when you are sure which book the item is", type.kind
        assert_includes prompt, "do not raise your confidence to get an answer through", type.kind
        assert_match(/medium/i, prompt, type.kind)
        refute_includes prompt, "anything lower is recorded and held", type.kind
        assert_includes prompt, "The lease lasts 30 minutes", type.kind
        assert_includes prompt, "fix the answer and submit again", type.kind
        assert_includes prompt, "If either call answers 404, the item is gone", type.kind
      end
    end

    test "the categories prompt says submitting only adds and never creates a category" do
      prompt = AgentPrompts.for_enrichment(Services::Books::QueueTypes::Categories)

      assert_includes prompt, "It only adds."
      assert_includes prompt, "recorded and not created"
    end

    test "the enrichment prompt's pending count is the pending rows of that kind only" do
      books = Array.new(3) { |i| ::Books::Book.create!(title: "Counted #{i}") }
      ::EnrichmentRequest.create!(enrichable: books[0], kind: "books.origin", reason: "missing")
      ::EnrichmentRequest.create!(enrichable: books[1], kind: "books.origin", reason: "missing", status: :done)
      ::EnrichmentRequest.create!(enrichable: books[2], kind: "books.categories", reason: "missing")

      assert_includes AgentPrompts.for_enrichment(Services::Books::QueueTypes::Origin), "holds 1 pending"
      assert_includes AgentPrompts.for_enrichment(Services::Books::QueueTypes::Categories), "holds 1 pending"
    end

    test "a type with no prompt file has no prompt" do
      assert_nil AgentPrompts.for_enrichment(EnrichmentQueueTestType)
    end

    test "is nil for a domain with no prompt file" do
      assert_nil AgentPrompts.call(domain: :games, queue: :repair_verdicts)
      assert_nil AgentPrompts.call(domain: :games, queue: :series)
      assert_nil AgentPrompts.call(domain: :games, queue: :duplicates)
      assert_nil AgentPrompts.call(domain: :games, queue: :match_decisions)
    end

    test "rejects an unknown queue" do
      assert_raises(ArgumentError) { AgentPrompts.call(domain: :books, queue: :other) }
    end
  end
end
