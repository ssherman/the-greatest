require "test_helper"

module DataImporters
  class FinderBaseTest < ActiveSupport::TestCase
    class FakeSource
      attr_reader :name

      def initialize(name, candidates: [], error: nil, resolution: nil)
        @name = name
        @candidates = candidates
        @error = error
        @resolution = resolution
        @calls = 0
      end

      attr_reader :calls, :resolution

      def call
        @calls += 1
        raise @error if @error

        @candidates
      end
    end

    # A books finder whose query is a Hash and whose sources are injected.
    class TestFinder < DataImporters::FinderBase
      attr_accessor :sources

      protected

      def model_class = ::Books::Book

      def ranking_configuration_class = ::Books::RankingConfiguration

      def candidate_sources(_query) = sources

      def creators_required? = true

      def query_title(query) = query[:title]

      def query_creators(query) = Array(query[:creators])

      def query_year(query) = query[:year]

      def record_creators(record) = record.authors.map(&:name)

      def record_creator_alternate_names(record) = record.authors.flat_map { |a| Array(a.alternate_names) }

      def record_year(record) = record.first_published_year
    end

    def setup
      @book = books_books(:war_and_peace)      # Leo Tolstoy, 1869, alternate title "Voyna i mir"
      @other = books_books(:crime_and_punishment)
      @finder = TestFinder.new
      @query = {title: "War and Peace", creators: ["Leo Tolstoy"], year: 1869}
      @task = mock("select_candidate_task")
    end

    def stub_ai(data, success: true, error: nil)
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: success, data: data, error: error, ai_chat: ai_chats(:general_chat)))
    end

    # ---- agreement judgements ------------------------------------------

    test "titles_agree? compares normalized titles and alternate titles" do
      assert @finder.titles_agree?({title: "war and peace"}, @book)
      assert @finder.titles_agree?({title: "Voyna i mir"}, @book)
      assert_not @finder.titles_agree?({title: "War"}, @book)
      assert_not @finder.titles_agree?({title: nil}, @book)
    end

    test "creators_agree? needs one query creator to match a record creator or alternate name" do
      assert @finder.creators_agree?({creators: ["leo tolstoy"]}, @book)
      assert_not @finder.creators_agree?({creators: ["Fyodor Dostoevsky"]}, @book)
      assert_not @finder.creators_agree?({creators: []}, @book)
    end

    test "corroborated? is true when nothing can be compared, else when titles or creators agree" do
      candidate = Candidate.new(record: @book)

      assert @finder.corroborated?({}, candidate)
      assert @finder.corroborated?({title: "Nothing like it", creators: ["Leo Tolstoy"]}, candidate)
      assert @finder.corroborated?({title: "War and Peace", creators: ["Nobody"]}, candidate)
      assert_not @finder.corroborated?({title: "Nothing like it", creators: ["Nobody"]}, candidate)
    end

    test "exact_match? needs title, creators (when required) and no year conflict" do
      candidate = Candidate.new(record: @book)

      assert @finder.exact_match?(@query, candidate)
      assert @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"]}, candidate), "missing year is not a conflict"
      assert @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"], year: 1871}, candidate), "two years apart is not a conflict"
      assert_not @finder.exact_match?({title: "War and Peace", creators: ["Leo Tolstoy"], year: 1900}, candidate)
      assert_not @finder.exact_match?({title: "War and Peace", creators: []}, candidate), "creators are required in this domain"
      assert_not @finder.exact_match?({title: "War", creators: ["Leo Tolstoy"]}, candidate)
    end

    test "ranked_position reads the primary configuration and ranked? follows it" do
      assert_nil @finder.ranked_position(@book)
      RankedItem.create!(item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1.0)

      assert_equal 7, @finder.ranked_position(@book)
      assert @finder.ranked?(@book)
    end

    test "never_merge? consults the duplicate_candidates verdict" do
      assert_not @finder.never_merge?(@book, @other)
      ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@book.id, @other.id], source: :ai).data.update!(status: :not_duplicate)

      assert @finder.never_merge?(@other, @book)
    end

    test "describe_candidate lays out title, creators, year, rank, where it lives and shared identifiers" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library,
        evidence: {title: "War and Peace", creators: ["Leo Tolstoy"], year: 1869, ranked_position: 3,
                   matched_identifier: {type: "books_work_isbn13", value: "978"}, external_verdict: "accept"})

      line = @finder.describe_candidate(candidate)

      assert_equal "War and Peace | by Leo Tolstoy | (1869) | ranked #3 | in catalog | open_library OL1W | shares books_work_isbn13 | open_library verdict accept", line
    end

    # ---- the pipeline -----------------------------------------------------

    test "a legacy hit is a certain rule match and is recorded" do
      @finder.sources = [FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])]

      match = @finder.call(query: @query)

      assert match.matched?
      assert_equal @book, match.record
      assert_equal [:certain, :rule], [match.confidence, match.decided_by]
      assert_not match.needs_review?
      decision = match.decision
      assert_equal "DataImporters::FinderBaseTest::TestFinder", decision.finder
      assert_equal @book, decision.record
      assert decision.matched?
      assert decision.certain?
      assert decision.decided_by_rule?
      assert_equal 1, decision.selected_index
      assert_equal "War and Peace", decision.query["title"]
      assert_equal ["Leo Tolstoy"], decision.query["creators"]
      assert_equal "Books::Book", decision.candidates.first["record_type"]
      assert_equal @book.id, decision.candidates.first["record_id"]
      assert_equal ["Leo Tolstoy"], decision.candidates.first["evidence"]["creators"]
      assert_not decision.needs_review
    end

    test "no candidates is a high-confidence unmatched, recorded with no record" do
      @finder.sources = [FakeSource.new(:exact), FakeSource.new(:opensearch)]

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_nil match.record
      assert_equal [:high, :rule], [match.confidence, match.decided_by]
      assert_match(/2 sources/, match.reason)
      assert_nil match.decision.record
      assert match.decision.unmatched?
    end

    test "a decisive candidate stops gathering; verify runs every source" do
      first = FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])
      second = FakeSource.new(:opensearch, candidates: [Candidate.new(record: @other, sources: [:opensearch])])
      @finder.sources = [first, second]

      @finder.call(query: @query)
      assert_equal 0, second.calls

      stub_ai({selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: []})
      match = @finder.call(query: @query, verify: true)

      assert_equal 1, second.calls
      assert match.decision.verify
      assert_equal 2, match.candidates.size
    end

    test "exclude drops that record from every source" do
      @finder.sources = [FakeSource.new(:exact, candidates: [Candidate.new(record: @book, sources: [:exact]), Candidate.new(record: @other, sources: [:exact])])]
      stub_ai({selected_index: 0, confidence: "high", reasoning: "", same_entity_groups: []})

      match = @finder.call(query: @query, exclude: @book)

      assert_equal [@other], match.candidates.map(&:record)
    end

    test "a failing source contributes nothing, is recorded, and caps a high confidence at medium" do
      @finder.sources = [FakeSource.new(:opensearch, error: StandardError.new("opensearch down"))]

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_equal ["opensearch"], match.sources_failed
      assert_equal :medium, match.confidence
      assert match.needs_review?
      assert_equal ["opensearch"], match.decision.sources_failed
      assert match.decision.needs_review
    end

    test "an ActiveRecord error inside a source propagates and records no decision" do
      @finder.sources = [FakeSource.new(:exact, error: ActiveRecord::StatementInvalid.new("PG::ConnectionBad: server closed the connection"))]

      assert_no_difference("MatchDecision.count") do
        assert_raises(ActiveRecord::StatementInvalid) { @finder.call(query: @query) }
      end
    end

    test "a source that returns nil contributes nothing" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: nil)]

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_equal [], match.sources_failed
    end

    test "a failing source does not downgrade a certain decision" do
      @finder.sources = [
        FakeSource.new(:opensearch, error: StandardError.new("down")),
        FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)])
      ]

      match = @finder.call(query: @query)

      assert_equal :certain, match.confidence
      assert_not match.needs_review?
    end

    test "candidates that the rules cannot settle go to the AI, and the selection is recorded" do
      candidates = [@book, @other, books_books(:combo_steinbeck), books_books(:got)].map { |b| Candidate.new(record: b, sources: [:opensearch], scores: {opensearch: 5.0}) }
      @finder.sources = [FakeSource.new(:opensearch, candidates: candidates)]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with do |args|
        args[:entity_noun] == "book" && args[:candidate_lines].size == 4 && args[:query_line].include?("War and Peace") && args[:parent].nil?
      end.returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 2, confidence: "medium", reasoning: "Closest.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

      match = @finder.call(query: @query)

      assert match.matched?
      assert_equal @other, match.record
      assert_equal [:medium, :ai, "Closest."], [match.confidence, match.decided_by, match.reason]
      assert match.needs_review?
      assert_equal ai_chats(:general_chat), match.decision.ai_chat
      assert_equal 2, match.decision.selected_index
      assert match.decision.decided_by_ai?
      assert match.decision.needs_review
    end

    test "at most six candidates reach the AI, and the match still carries every candidate" do
      externals = (1..7).map do |i|
        Candidate.new(external_key: "OL#{i}W", external_source: :open_library, sources: [:open_library], scores: {open_library: 1.0 - (i * 0.1)})
      end
      @finder.sources = [FakeSource.new(:open_library, candidates: externals)]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with do |args|
        args[:candidate_lines].size == 6 && args[:candidate_lines].none? { |line| line.include?("OL7W") }
      end.returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: []}))

      match = @finder.call(query: @query)

      assert_equal 7, match.candidates.size
      assert_equal 7, match.decision.candidates.size
    end

    test "candidates are ordered local first, then by number of sources, then by best score, keeping insertion order on ties" do
      external_low = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], scores: {open_library: 0.2})
      external_high = Candidate.new(external_key: "OL2W", external_source: :open_library, sources: [:open_library], scores: {open_library: 0.9})
      tie_a = Candidate.new(external_key: "OL3W", external_source: :open_library, sources: [:open_library], scores: {open_library: 0.5})
      tie_b = Candidate.new(external_key: "OL4W", external_source: :open_library, sources: [:open_library], scores: {open_library: 0.5})
      local_single = Candidate.new(record: @book, sources: [:opensearch], scores: {opensearch: 3.0})
      local_multi = Candidate.new(record: @other, sources: [:exact, :opensearch], scores: {opensearch: 1.0})
      @finder.sources = [FakeSource.new(:mixed, candidates: [external_low, tie_a, external_high, local_single, tie_b, local_multi])]
      stub_ai({selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: []})

      match = @finder.call(query: @query)

      assert_equal [@other, @book], match.candidates.first(2).map(&:record), "locals first, the multi-source one ahead of the single-source one"
      assert_equal ["OL2W", "OL3W", "OL4W", "OL1W"], match.candidates.drop(2).map(&:external_key), "externals by best score, insertion order on the tie"
    end

    test "the subject is passed to the AI task as its parent and recorded on the decision" do
      subject = list_items(:music_albums_item)
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with { |args| args[:parent] == subject }.returns(@task)
      @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 0, confidence: "low", reasoning: "", same_entity_groups: []}))

      match = @finder.call(query: @query, subject: subject)

      assert_equal subject, match.decision.subject
    end

    test "an AI same-entity group of two local records is flagged as a duplicate pair tied to the decision" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai({selected_index: 1, confidence: "high", reasoning: "Both the same.", same_entity_groups: [[1, 2]]})

      match = @finder.call(query: @query)

      pair = DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
      assert pair.pending?
      assert pair.raised_by_ai?
      assert_equal match.decision, pair.match_decision
      assert_equal "Both the same.", pair.evidence["reason"]
    end

    test "the ranked candidate wins a same-entity group over the AI's unranked pick" do
      RankedItem.create!(item: @other, ranking_configuration: ranking_configurations(:books_global), rank: 2, score: 1.0)
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai({selected_index: 1, confidence: "high", reasoning: "Picked one.", same_entity_groups: [[1, 2]]})

      match = @finder.call(query: @query)

      assert_equal @other, match.record
      assert_match(/Preferred ranked #2/, match.reason)
    end

    test "an AI failure falls back to unmatched, low, decided_by fallback, and never raises" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      stub_ai(nil, success: false, error: "boom")

      match = @finder.call(query: @query)

      assert match.unmatched?
      assert_equal [:low, :fallback], [match.confidence, match.decided_by]
      assert_includes match.reason, "boom"
      assert match.needs_review?
      assert match.decision.decided_by_fallback?
    end

    test "an exception building the AI task is also a fallback" do
      @finder.sources = [FakeSource.new(:opensearch, candidates: [Candidate.new(record: @book, sources: [:opensearch]), Candidate.new(record: @other, sources: [:opensearch])])]
      ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).raises(ArgumentError, "Unknown provider")

      match = @finder.call(query: @query)

      assert match.decision.decided_by_fallback?
      assert_includes match.reason, "Unknown provider"
    end

    test "a source's resolution is carried onto the match" do
      resolution = Object.new
      @finder.sources = [FakeSource.new(:legacy, candidates: [Candidate.new(record: @book, sources: [:legacy], decisive: true)], resolution: resolution)]

      match = @finder.call(query: @query)

      assert_same resolution, match.external_resolution
    end

    test "evidence for a local candidate is filled from the record and keeps what the source supplied" do
      @finder.sources = [FakeSource.new(:identifier, candidates: [Candidate.new(record: @book, sources: [:identifier], evidence: {matched_identifier: {type: "books_work_isbn13", value: "9780140447934"}})])]

      match = @finder.call(query: @query)

      evidence = match.candidates.first.evidence
      assert_equal "War and Peace", evidence[:title]
      assert_equal ["Leo Tolstoy"], evidence[:creators]
      assert_equal 1869, evidence[:year]
      assert_equal({type: "books_work_isbn13", value: "9780140447934"}, evidence[:matched_identifier])
      assert_includes evidence[:identifiers], {type: "books_work_isbn13", value: "9780140447934"}
    end

    test "two local candidates sharing an external key are flagged as an external key collision whatever the rules decide" do
      first = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:opensearch, :open_library])
      second = Candidate.new(record: @other, external_key: "OL1W", external_source: :open_library, sources: [:opensearch, :open_library])
      @finder.sources = [FakeSource.new(:opensearch, candidates: [first, second])]
      stub_ai({selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: []})

      match = @finder.call(query: @query)

      assert_equal 2, match.candidates.size
      pair = DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
      assert pair.raised_by_external_key_collision?
      assert_equal match.decision, pair.match_decision
    end
  end
end
