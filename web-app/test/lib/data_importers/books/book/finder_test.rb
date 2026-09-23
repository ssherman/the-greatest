# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class FinderTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"
        SEARCH = ::Search::Books::Search::BookByTitleAndAuthors

        def setup
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:finder:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @finder = Finder.new(open_library_client: client)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @task = stub("select_candidate_task")
          SEARCH.stubs(:call).returns([])
          stub_resolve(resolve_response(verdict: "abstain"))
        end

        # ---- helpers ----------------------------------------------------------

        def hit(book, score = 9.0)
          {id: book.id.to_s, score: score, source: {}}
        end

        def stub_ai(data)
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: data, ai_chat: ai_chats(:general_chat)))
        end

        def expect_no_ai
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).never
        end

        def work_record(key:, title:, authors: [], declared_year: nil, redirected_from: [])
          {
            "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => nil, "description" => nil,
            "authors" => authors.each_with_index.map { |name, i| {"key" => {"source" => "openlibrary", "key" => "OL#{i}A"}, "name" => name} },
            "subjects" => [], "year_evidence" => {"declared_year" => declared_year}, "popularity" => nil,
            "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} }
          }
        end

        def ol_candidate(key:, verdict:, score:, record:)
          {"key" => {"source" => "openlibrary", "key" => key}, "score" => score, "rules" => ["title_author"], "margin" => 0.2,
           "verdict" => verdict, "evidence" => {}, "conflicts" => [], "diff" => [], "record" => record}
        end

        def resolve_response(verdict:, key: nil, candidates: [], reason: "test")
          {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "decision" => {"verdict" => verdict, "key" => key && {"source" => "openlibrary", "key" => key}, "score" => 0.9, "margin" => 0.3, "reason" => reason},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }
          }
        end

        def stub_resolve(body)
          WebMock.reset!
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: body.to_json)
        end

        # ---- identifiers (rule 1) ----------------------------------------------

        test "a corroborated Open Library key hit is a certain identifier match and stops gathering" do
          SEARCH.expects(:call).never
          expect_no_ai
          query = ImportQuery.new(title: "Crime and Punishment", open_library_work_key: identifiers(:crime_and_punishment_openlibrary).value)

          match = @finder.call(query: query)

          assert_equal [@crime, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_equal({type: "books_work_openlibrary_id", value: "OL262758W"}, match.candidates.first.evidence[:matched_identifier])
          assert_not_requested(:post, "#{BASE_URL}/resolve")
        end

        test "an identifier-only query is corroborated by definition: ISBN-13 and Goodreads hits are certain" do
          assert_equal @war_and_peace, @finder.call(query: ImportQuery.new(title: nil, isbn13: [identifiers(:war_and_peace_isbn13).value])).record
          assert_equal books_books(:of_mice_and_men), @finder.call(query: ImportQuery.new(title: nil, goodreads_id: [identifiers(:of_mice_and_men_goodreads).value])).record
        end

        test "an identifier hit whose record disagrees on title and creators is not decisive: gathering continues and the AI decides" do
          query = ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"], open_library_work_key: identifiers(:crime_and_punishment_openlibrary).value)
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new).with { |args| args[:candidate_lines].size == 2 }.returns(@task)
          @task.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {selected_index: 1, confidence: "medium", reasoning: "The key is authoritative.", same_entity_groups: []}, ai_chat: ai_chats(:general_chat)))

          match = @finder.call(query: query)

          assert_equal [@crime, :medium, :ai], [match.record, match.confidence, match.decided_by]
          assert match.needs_review?
          assert_equal [@crime, @war_and_peace], match.candidates.map(&:record)
          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "two books holding the same ISBN are an identifier collision: one is chosen and the pair is flagged" do
          value = identifiers(:war_and_peace_isbn13).value
          @crime.identifiers.create!(identifier_type: :books_work_isbn13, value: value)

          match = @finder.call(query: ImportQuery.new(title: nil, isbn13: [value]))

          assert_includes [@war_and_peace, @crime], match.record
          assert match.decision.certain?
          pair = DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@war_and_peace.id, @crime.id].min, item_b_id: [@war_and_peace.id, @crime.id].max)
          assert pair.raised_by_identifier_collision?
          assert_equal match.decision, pair.match_decision
        end

        # ---- exact (rule 4) ----------------------------------------------------

        test "an exact title and author match, case-insensitively, is a high-confidence rule match" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "war and peace", author_names: ["LEO TOLSTOY"]))

          assert_equal [@war_and_peace, :high, :rule], [match.record, match.confidence, match.decided_by]
          assert_includes match.candidates.first.sources, :exact
          assert_not match.needs_review?
        end

        test "an author's alternate name satisfies the exact source and the creator agreement" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Lev Tolstoy"]))

          assert_equal [@war_and_peace, :rule], [match.record, match.decided_by]
        end

        test "the query is normalized the way the models store titles and names" do
          author = ::Books::Author.create!(name: "Kathleen Alcott")
          book = ::Books::Book.create!(title: "The Secret Lives")
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)

          # U+202F NARROW NO-BREAK SPACE between the names, as real external
          # data carries it (NameNormalizer's whole reason to exist -- see
          # its comment). The stored author name is plain ASCII (the model
          # normalizes on save regardless), so this only passes if the
          # finder normalizes the QUERY the same way before comparing.
          match = @finder.call(query: ImportQuery.new(title: "The Secret Lives", author_names: ["Kathleen Alcott"]))

          assert_equal book, match.record
        end

        test "a title with no author names is never an exact match: the candidate goes to the AI" do
          stub_ai({selected_index: 0, confidence: "low", reasoning: "Ambiguous.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace"))

          assert match.unmatched?
          assert_equal [@war_and_peace], match.candidates.map(&:record)
          assert_equal :ai, match.decided_by
        end

        test "the exact source's local candidate carries book_kind and alternate_titles as evidence" do
          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          candidate = match.candidates.first
          assert_equal ["standalone", ["Voyna i mir"]], candidate.evidence.values_at(:book_kind, :alternate_titles)
        end

        test "describe_candidate marks a collection" do
          combo = books_books(:combo_steinbeck)
          candidate = Candidate.new(record: combo, sources: [:exact], evidence: {title: combo.title, book_kind: "collection"})

          assert_match(/\| collection\z/, @finder.describe_candidate(candidate))
        end

        # ---- the negative class -----------------------------------------------

        test "same title, different author: not exact, the AI decides, and 'none' is unmatched" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          stub_ai({selected_index: 0, confidence: "high", reasoning: "Different author.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Someone Else"]))

          assert match.unmatched?
          assert_equal [@war_and_peace], match.candidates.map(&:record)
          assert_equal [[:opensearch]], match.candidates.map(&:sources), "the exact source must not match a different author"
          assert_equal :ai, match.decided_by
        end

        test "same author, different title: no candidates from any source is a high-confidence unmatched" do
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Anna Karenina", author_names: ["Leo Tolstoy"]))

          assert_equal [:unmatched, :high, :rule], [match.outcome, match.confidence, match.decided_by]
          assert_equal [], match.candidates
          assert_match(/4 sources/, match.reason)
        end

        test "a near spelling reaches the AI through OpenSearch and a confident selection is a match" do
          SEARCH.expects(:call).with(title: "War & Peace", authors: ["Leo Tolstoy"], year: nil, size: 5).returns([hit(@war_and_peace, 11.2)])
          stub_ai({selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War & Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :high, :ai], [match.record, match.confidence, match.decided_by]
          assert_equal({opensearch: 11.2}, match.candidates.first.scores)
          assert_not match.needs_review?
        end

        test "a translated alternate title found by OpenSearch is an exact match by rule" do
          SEARCH.stubs(:call).returns([hit(@war_and_peace)])
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Voyna i mir", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :high, :rule], [match.record, match.confidence, match.decided_by]
        end

        test "a year more than two apart blocks the exact rule" do
          stub_ai({selected_index: 0, confidence: "medium", reasoning: "Different year.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"], year: 1990))

          assert match.unmatched?
          assert_equal :ai, match.decided_by
        end

        # ---- Open Library (rules 2 and 5) ---------------------------------------

        test "an Open Library accept on a key a local book holds, corroborated by the title, is a certain match with the resolution kept" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          stub_resolve(resolve_response(verdict: "accept", key: key, candidates: [ol_candidate(key: key, verdict: "accept", score: 0.95, record: work_record(key: key, title: "Crime and Punishment"))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", author_names: ["Fyodor Dostoevsky"]))

          assert_equal [@crime, :certain, :identifier], [match.record, match.confidence, match.decided_by]
          assert_equal key, match.external.external_key
          assert match.external_resolution.accept?
          assert_match(/open_library accepted #{key}/, match.reason)
        end

        test "an Open Library accept on a key nobody holds, with no local candidates, is a high-confidence unmatched with the external set" do
          stub_resolve(resolve_response(verdict: "accept", key: "OL999W", candidates: [ol_candidate(key: "OL999W", verdict: "accept", score: 0.95, record: work_record(key: "OL999W", title: "The Brothers Karamazov", authors: ["Fyodor Dostoevsky"], declared_year: 1880))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "The Brothers Karamazov", author_names: ["Fyodor Dostoevsky"]))

          assert_equal [:unmatched, :high, :rule], [match.outcome, match.confidence, match.decided_by]
          assert_equal "OL999W", match.external.external_key
          assert_equal ["The Brothers Karamazov", ["Fyodor Dostoevsky"], 1880], match.external.evidence.values_at(:title, :creators, :year)
          assert match.external_resolution.accept?
          assert_equal "OL999W", match.decision.candidates.first["external_key"]
        end

        test "an Open Library abstain with candidates alongside a local exact match: the exact rule still decides and the externals are recorded" do
          stub_resolve(resolve_response(verdict: "abstain", candidates: [ol_candidate(key: "OL5W", verdict: "abstain", score: 0.4, record: work_record(key: "OL5W", title: "War and Peace"))]))
          expect_no_ai

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :rule], [match.record, match.decided_by]
          assert_equal [@war_and_peace, nil], match.candidates.map(&:record)
          assert_equal "OL5W", match.candidates.last.external_key
        end

        test "the service failing is a failed source: the exact match stands but a high confidence is capped at medium" do
          WebMock.reset!
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "down")

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_equal [@war_and_peace, :medium, :rule], [match.record, match.confidence, match.decided_by]
          assert_equal ["open_library"], match.sources_failed
          assert match.needs_review?
        end

        test "only one HTTP request is made, the resolve" do
          @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]))

          assert_requested(:post, "#{BASE_URL}/resolve", times: 1)
        end

        # ---- verify, exclude, subject ----------------------------------------

        test "verify: true disables the identifier early exit, runs every source and records verify on the decision" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          SEARCH.expects(:call).once.returns([])
          stub_ai({selected_index: 1, confidence: "high", reasoning: "Same key.", same_entity_groups: []})

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", open_library_work_key: key), verify: true)

          assert_equal [@crime, :ai], [match.record, match.decided_by]
          assert match.decision.verify
          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "exclude: drops that record from every source" do
          key = identifiers(:crime_and_punishment_openlibrary).value
          stub_resolve(resolve_response(verdict: "accept", key: key, candidates: [ol_candidate(key: key, verdict: "accept", score: 0.95, record: work_record(key: key, title: "Crime and Punishment"))]))

          match = @finder.call(query: ImportQuery.new(title: "Crime and Punishment", open_library_work_key: key), verify: true, exclude: @crime)

          assert match.unmatched?
          assert_equal [], match.candidates.map(&:record).compact
        end

        test "the subject is recorded on the decision" do
          subject = list_items(:music_albums_item)

          match = @finder.call(query: ImportQuery.new(title: "War and Peace", author_names: ["Leo Tolstoy"]), subject: subject)

          assert_equal subject, match.decision.subject
        end
      end
    end
  end
end
