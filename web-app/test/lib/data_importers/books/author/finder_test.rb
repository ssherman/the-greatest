# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class FinderTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"
        SEARCH = ::Search::Books::Search::AuthorByName
        TASK = ::Services::Ai::Tasks::Matching::SelectCandidateTask

        def setup
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_finder:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @finder = Finder.new(open_library_client: client)
          @tolstoy = books_authors(:tolstoy)
          @task = stub("select_candidate_task")
          SEARCH.stubs(:call).returns([])
        end

        # ---- helpers ----------------------------------------------------------

        def hit(author, score = 9.0)
          {id: author.id.to_s, score: score, source: {}}
        end

        def stub_ai(data)
          TASK.stubs(:new).returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: data, ai_chat: ai_chats(:general_chat)))
        end

        def expect_no_ai
          TASK.expects(:new).never
        end

        def stub_author(key, record_key: key, redirected_from: [], name: "Leo Tolstoy", status: 200)
          body = {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "key" => {"source" => "openlibrary", "key" => record_key},
              "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
              "name" => name, "alternate_names" => [], "birth_year" => 1828, "death_year" => 1910
            }
          }
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        # ---- identifiers (rule 1) ---------------------------------------------

        test "a held Open Library key whose name agrees is a certain identifier match and stops gathering" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          SEARCH.expects(:call).never
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"))

          assert_equal [@tolstoy, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_not_requested(:get, %r{#{BASE_URL}/authors/}o)
        end

        test "a key-only query is corroborated by definition" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")

          assert_equal @tolstoy, @finder.call(query: ImportQuery.new(open_library_author_key: "OL26783A")).record
        end

        test "a held key on an author with a different name is not decisive: the AI decides" do
          king = books_authors(:king)
          king.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          stub_author("OL26783A")
          TASK.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 2, confidence: "medium", reasoning: "Name and dates fit Tolstoy.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL26783A"))

          assert_equal [:ai, :medium], [match.decided_by, match.confidence]
          assert match.needs_review?
        end

        # ---- exact (rule 4) ---------------------------------------------------

        test "an exact name match, case-insensitively, is a high-confidence rule match" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "LEO TOLSTOY"))

          assert_equal [@tolstoy, :high, :rule], [match.record, match.confidence, match.decided_by]
          assert_includes match.candidates.first.sources, :exact
        end

        test "a query name equal to a stored alternate name is an exact match" do
          expect_no_ai

          assert_equal [@tolstoy, :rule], @finder.call(query: ImportQuery.new(name: "Lev Tolstoy")).then { |m| [m.record, m.decided_by] }
        end

        test "the query's alternate name matching a stored primary name reaches the exact source, but is not itself a rule match" do
          stub_ai(selected_index: 0, confidence: "medium", reasoning: "A different transliteration is not decisive.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Graf Lev Tolstoi", alternate_names: ["Leo Tolstoy"]))

          candidate = match.candidates.find { |c| c.local? && c.record == @tolstoy }
          assert candidate, "expected @tolstoy among the candidates"
          assert_includes candidate.sources, :exact
          assert_equal :ai, match.decided_by
        end

        test "a stored alternate name with a curly apostrophe still matches a straight-apostrophe query by rule" do
          # Books::Author normalizes alternate_names on save (the same
          # NameNormalizer/QuoteNormalizer pair the finder applies to the
          # query), so the column holds the straight form the finder's SQL
          # compares against.
          author = ::Books::Author.create!(name: "Brian O'Nolan", alternate_names: ["Flann O\u2019Brien"])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Flann O'Brien"))

          assert_equal [author, :rule], [match.record, match.decided_by]
        end

        test "curly quotes, exotic spaces and case are normalized the way the model stores names" do
          author = ::Books::Author.create!(name: "Flann O'Brien")
          expect_no_ai

          # U+202F NARROW NO-BREAK SPACE between the names and U+2019 RIGHT
          # SINGLE QUOTATION MARK in the apostrophe, written as explicit Ruby
          # escapes so the bytes are unambiguous (NameNormalizer.rb's own
          # reason to exist -- see its comment).
          match = @finder.call(query: ImportQuery.new(name: "FLANN\u202FO\u2019BRIEN"))

          assert_equal [author, :rule], [match.record, match.decided_by]
        end

        test "a birth-year conflict blocks the exact rule: the AI decides" do
          stub_ai(selected_index: 0, confidence: "high", reasoning: "Different century.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", birth_year: 1950))

          assert_equal [nil, :unmatched, :ai], [match.record, match.outcome, match.decided_by]
        end

        test "a death-year conflict blocks the exact rule too" do
          stub_ai(selected_index: 0, confidence: "high", reasoning: "Different person.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", death_year: 1990))

          assert_equal [:unmatched, :ai], [match.outcome, match.decided_by]
        end

        test "two authors with the same exact name go to the AI" do
          twin = ::Books::Author.create!(name: "Leo Tolstoy")
          TASK.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "medium", reasoning: "Same person twice.", same_entity_groups: [[1, 2]]}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy"))

          assert_includes [@tolstoy, twin], match.record
          assert DuplicateCandidate.exists?(item_type: "Books::Author", item_a_id: [@tolstoy.id, twin.id].min, item_b_id: [@tolstoy.id, twin.id].max)
        end

        test "the OpenSearch source is called with the query's name and alternate names as keywords" do
          SEARCH.expects(:call).with(name: "Leo Tolstoy", alternate_names: [], size: 5).returns([])
          expect_no_ai

          @finder.call(query: ImportQuery.new(name: "Leo Tolstoy"))
        end

        test "a surname-only OpenSearch neighbour never matches by rule" do
          SEARCH.stubs(:call).returns([hit(@tolstoy)])
          stub_ai(selected_index: 0, confidence: "high", reasoning: "A different Tolstoy.", same_entity_groups: [])

          match = @finder.call(query: ImportQuery.new(name: "Aleksey Tolstoy"))

          assert_equal [nil, :ai], [match.record, match.decided_by]
        end

        # ---- no candidates (rule 3) -------------------------------------------

        test "no candidates is unmatched by rule without the AI" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Nobody Anybody"))

          assert_equal [nil, :unmatched, :high, :rule], [match.record, match.outcome, match.confidence, match.decided_by]
        end

        # ---- Open Library -----------------------------------------------------

        test "an unheld key is unmatched with the Open Library record on match.external (rule 5)" do
          stub_author("OL99A", name: "Nobody Anybody")
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Nobody Anybody", open_library_author_key: "OL99A"))

          assert_equal [:unmatched, :rule], [match.outcome, match.decided_by]
          assert_equal "OL99A", match.external.external_key
          assert_instance_of ::Books::OpenLibrary::Author, match.external.external_record
        end

        test "a local author holding a key the service redirects from matches (rule 2)" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          stub_author("OL2A", redirected_from: ["OL1A"])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL2A"))

          assert_equal [@tolstoy, :certain, :identifier], [match.record, match.confidence, match.decided_by]
        end

        test "two local authors holding keys the service redirects from: rule 2 picks one, flags the pair and needs review" do
          twin = ::Books::Author.create!(name: "Leo Tolstoy")
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          twin.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          stub_author("OL2A", redirected_from: ["OL1A"])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL2A"))

          assert_equal [:matched, :medium, :identifier], [match.outcome, match.confidence, match.decided_by]
          assert match.needs_review?
          assert ::DuplicateCandidate.raised_by_external_key_collision.exists?(item_type: "Books::Author", item_a_id: [@tolstoy.id, twin.id].min, item_b_id: [@tolstoy.id, twin.id].max)
        end

        test "an Open Library 404 is not a failed source" do
          stub_author("OL404A", status: 404)

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL404A"))

          assert_equal [@tolstoy, :high], [match.record, match.confidence]
          assert_empty match.sources_failed
        end

        test "an Open Library outage is a failed source and demotes a high rule match to medium" do
          stub_author("OL500A", status: 500)

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: "OL500A"))

          assert_equal [@tolstoy, :medium], [match.record, match.confidence]
          assert_equal ["open_library"], match.sources_failed
        end

        test "an OpenSearch outage is a failed source; the exact source still decides" do
          SEARCH.stubs(:call).raises(Faraday::ConnectionFailed.new("down"))

          match = @finder.call(query: ImportQuery.new(name: "Leo Tolstoy"))

          assert_equal [@tolstoy, :rule], [match.record, match.decided_by]
          assert_equal ["opensearch"], match.sources_failed
        end

        # ---- the AI prompt and the audit summary ------------------------------

        test "the AI sees life spans, other names and book titles on both sides" do
          ::Books::Author.create!(name: "Leo Tolstoy")
          TASK.expects(:new).with { |args|
            args[:entity_noun] == "author" &&
              args[:query_line].include?("1828-1910") && args[:query_line].include?("wrote War and Peace") &&
              args[:candidate_lines].any? { |line| line.include?("wrote War and Peace") && line.include?("also known as Lev Tolstoy") }
          }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "high", reasoning: "Same dates.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          @finder.call(query: ImportQuery.new(name: "Leo Tolstoy", birth_year: 1828, death_year: 1910, work_titles: ["War and Peace"]))
        end

        test "summarize includes the author's book titles and years" do
          summary = @finder.summarize(@tolstoy)

          assert_includes summary[:book_titles], books_books(:war_and_peace).title
          assert_equal [1828, 1910, "Leo Tolstoy"], summary.values_at(:birth_year, :death_year, :title)
        end
      end
    end
  end
end
