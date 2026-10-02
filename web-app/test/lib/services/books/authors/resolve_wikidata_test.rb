# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ResolveWikidataTest < ActiveSupport::TestCase
        TOLSTOY = {label: "Leo Tolstoy", aliases: ["Lev Tolstoy"], born: 1828, died: 1910, enwiki: "Leo Tolstoy", sitelinks: 150}.freeze

        def setup
          @author = books_authors(:tolstoy) # alternate names Lev Tolstoy, Lev Nikolayevich Tolstoy; wrote War and Peace
        end

        def resolve(client, refresh: false) = ResolveWikidata.call(author: @author, refresh: refresh, client: client)

        def hold(type, value) = @author.identifiers.create!(identifier_type: type, value: value)

        def ai_selects(index, confidence: "high")
          result = Services::Ai::Result.new(success: true, data: {selected_index: index, confidence: confidence, reasoning: "Because.", same_entity_groups: []})
          task = mock("task")
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).with { |options| @ai_options = options }.returns(task)
        end

        test "a corroborated held id matches by identifier, certain, without searching" do
          hold(:books_author_wikidata_qid, "Q7243")
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal :matched, result.data[:outcome]
          assert_equal "Q7243", result.data[:entity].id
          decision = result.data[:decision]
          assert_equal ["identifier", "certain", false], [decision.decided_by, decision.confidence, decision.needs_review]
          assert_not client.called?(:search)
        end

        test "names are compared with case and diacritics folded" do
          author = ::Books::Author.create!(name: "Gabriel Garcia Marquez")
          author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q5878")
          client = FakeWikidataClient.new(entities: {"Q5878" => wikidata_entity("Q5878", label: "Gabriel García Márquez")})

          result = ResolveWikidata.call(author: author, client: client)

          assert_equal ["matched", "identifier"], [result.data[:decision].outcome, result.data[:decision].decided_by]
        end

        test "a held id that Wikidata has merged resolves to the surviving item" do
          hold(:books_author_wikidata_qid, "Q999")
          client = FakeWikidataClient.new(entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal "Q7243", result.data[:entity].id
          assert_equal "Q7243", result.data[:decision].candidates.first["external_key"]
          assert_equal ["Q999"], result.data[:redirected_ids]
        end

        test "a held id whose person disagrees on years goes to the AI, not identifier" do
          hold(:books_author_wikidata_qid, "Q7243")
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", label: "Leo Tolstoy", born: 1650)})
          ai_selects(0)

          result = resolve(client)

          assert_equal "ai", result.data[:decision].decided_by
          assert @ai_options[:candidate_lines].first.include?("year conflict")
        end

        test "one person reached through the author's other ids matches by identifier" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q7243"],
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, identifiers: {openlibrary: ["OL26783A"]})}
          )

          result = resolve(client)

          assert_equal [:matched, "identifier"], [result.data[:outcome], result.data[:decision].decided_by]
          assert_includes client.calls, [:by_statements, [["P648", "OL26783A"]]]
          assert_not client.called?(:search)
          evidence = result.data[:decision].candidates.first["evidence"]
          assert_equal({"type" => "books_author_openlibrary_id", "value" => "OL26783A"}, evidence["matched_identifier"])
        end

        test "a single bridge hit whose label disagrees goes to the AI" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q7243"],
            entities: {"Q7243" => wikidata_entity("Q7243", label: "Someone Else", born: 1828, died: 1910, identifiers: {openlibrary: ["OL26783A"]})}
          )
          ai_selects(0)

          result = resolve(client)

          assert_equal "ai", result.data[:decision].decided_by
        end

        test "two persons reached through the ids go to the AI" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q7243", "Q1"],
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY), "Q1" => wikidata_entity("Q1", label: "Leo Tolstoy")}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal "ai", result.data[:decision].decided_by
          assert_equal "Q7243", result.data[:entity].id
          assert_equal 1, result.data[:decision].selected_index
          assert_includes @ai_options[:guidance], "writing these books"
        end

        test "the only same-name person with agreeing years and a shared title matches by rule" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243", "Q4256164"]},
            entities: {
              "Q7243" => wikidata_entity("Q7243", **TOLSTOY),
              "Q4256164" => wikidata_entity("Q4256164", label: "Lev Tolstoy", types: ["Q11424"], description: "1984 film")
            },
            works: {"Q7243" => ["War and Peace", "Anna Karenina"]}
          )

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "high"], [decision.outcome, decision.decided_by, decision.confidence]
          film = decision.candidates.find { |candidate| candidate["external_key"] == "Q4256164" }
          assert_equal "not a person", film["evidence"]["dropped"]
          assert_equal ["War and Peace"], decision.candidates.first["evidence"]["matching_titles"]
        end

        test "rule 3 does not fire while another person carries the author's identifier" do
          hold(:books_author_openlibrary_id, "OL26783A")
          client = FakeWikidataClient.new(
            statements: ["Q999"],
            searches: {"Leo Tolstoy" => ["Q999", "Q7243"]},
            entities: {
              "Q999" => wikidata_entity("Q999", label: "Leo Tolstoy", born: 1650, identifiers: {openlibrary: ["OL26783A"]}),
              "Q7243" => wikidata_entity("Q7243", **TOLSTOY)
            },
            works: {"Q7243" => ["War and Peace"]}
          )
          ai_selects(2)

          result = resolve(client)

          assert_equal ["ai", "Q7243"], [result.data[:decision].decided_by, result.data[:entity].id]
        end

        test "a same-name person with no shared title goes to the AI" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          ai_selects(1, confidence: "medium")

          result = resolve(client)

          assert_equal ["ai", "medium", true], [result.data[:decision].decided_by, result.data[:decision].confidence, result.data[:decision].needs_review]
        end

        test "no person among the candidates: unmatched by rule, with no AI call" do
          non_persons = {
            "Q10" => ["Q7725634", "War and Peace (novel)"], "Q11" => ["Q277759", "Tolstoy series"],
            "Q12" => ["Q13406463", "list of works by Leo Tolstoy"], "Q13" => ["Q2198855", "Tolstoyan movement"],
            "Q14" => ["Q95074", "Leo Tolstoy (character)"]
          }
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => non_persons.keys},
            entities: non_persons.to_h { |id, (type, label)| [id, wikidata_entity(id, label: label, types: [type])] }
          )
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal [:unmatched, "unmatched", "rule"], [result.data[:outcome], decision.outcome, decision.decided_by]
          assert_equal 5, decision.candidates.size
          assert decision.candidates.all? { |candidate| candidate["evidence"]["dropped"] == "not a person" }
          assert_nil result.data[:record]
        end

        test "a same-name person from another century is never matched by rule and is shown to the AI with a year conflict" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q1"]},
            entities: {"Q1" => wikidata_entity("Q1", label: "Leo Tolstoy", born: 1650)},
            works: {"Q1" => ["War and Peace"]}
          )
          ai_selects(0)

          result = resolve(client)

          assert_equal [:unmatched, "ai"], [result.data[:outcome], result.data[:decision].decided_by]
          assert @ai_options[:candidate_lines].first.include?("year conflict")
          assert_equal true, result.data[:decision].candidates.first["evidence"]["year_conflict"]
        end

        test "a TV chef whose name differs by one letter is left to the AI, which may reject him" do
          author = ::Books::Author.create!(name: "Michael Harriot")
          book = ::Books::Book.create!(title: "Harriott's Kitchen")
          author.book_authors.create!(book: book, position: 1)
          client = FakeWikidataClient.new(
            searches: {"Michael Harriot" => ["Q2"]},
            entities: {"Q2" => wikidata_entity("Q2", label: "Ainsley Harriott", description: "British celebrity chef", born: 1957)},
            works: {"Q2" => ["Harriott's Kitchen"]}
          )
          ai_selects(0)

          result = ResolveWikidata.call(author: author, client: client)

          assert_equal [:unmatched, "ai"], [result.data[:outcome], result.data[:decision].decided_by]
        end

        test "an AI failure records a fallback decision for review and reports failed" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal :failed, result.data[:outcome]
          assert_equal ["unmatched", "fallback", true], [decision.outcome, decision.decided_by, decision.needs_review]
          assert_match(/timeout/, decision.reason)
        end

        test "a failed works query is recorded and the AI decides" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)},
            works_error: ::Wikimedia::Exceptions::HttpError.new("boom", 500)
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal ["wikidata_works"], result.data[:decision].sources_failed
          assert_equal "ai", result.data[:decision].decided_by
        end

        test "a rate limit propagates and records nothing" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          client.stubs(:works).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Wikimedia::Exceptions::RateLimited) { resolve(client) }
          end
        end

        test "a rate limit raised by the AI task itself propagates and records nothing" do
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})
          task = mock("task")
          task.stubs(:call).raises(::Wikimedia::Exceptions::RateLimited.new("wait", retry_after: 30))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Wikimedia::Exceptions::RateLimited) { resolve(client) }
          end
        end

        test "stores only the chosen item, with its complete entity gzipped" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243", "Q4256164"]},
            entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY), "Q4256164" => wikidata_entity("Q4256164", label: "Lev Tolstoy", types: ["Q11424"])},
            works: {"Q7243" => ["War and Peace"]}
          )

          result = resolve(client)

          assert_equal ["Q7243"], ::ExternalRecord.where(source: :wikidata).pluck(:source_id)
          assert_equal result.data[:record], ::ExternalRecord.find_by!(source: :wikidata, source_id: "Q7243")
          assert_equal "Leo Tolstoy", JSON.parse(result.data[:record].raw_text).dig("labels", "en", "value")
        end

        test "reads a stored item instead of fetching it, and fetches again on refresh" do
          hold(:books_author_wikidata_qid, "Q7243")
          ::Services::ExternalRecords::Store.write(source: :wikidata, source_id: "Q7243",
            payload: ::Wikidata::Distiller.call(wikidata_entity("Q7243", **TOLSTOY)), raw: "{}", schema_version: ::Wikidata::Distiller::SCHEMA_VERSION)
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          resolve(client)
          assert_not client.calls.any? { |call| call.first == :entities && call.last.include?("Q7243") }

          resolve(client, refresh: true)
          assert_includes client.calls, [:entities, ["Q7243"]]
        end

        test "records one decision for the audit pages" do
          client = FakeWikidataClient.new(
            searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY, occupations: ["Q36180"])},
            works: {"Q7243" => ["War and Peace"]}, labels: {"Q36180" => "writer"}
          )

          assert_difference(-> { ::MatchDecision.count }, 1) { resolve(client) }
          decision = ::MatchDecision.order(:id).last

          assert_equal ["Services::Books::Authors::ResolveWikidata", @author, nil], [decision.finder, decision.subject, decision.record]
          assert_equal "Leo Tolstoy", decision.query["name"]
          candidate = decision.candidates.first
          assert_equal ["wikidata", "Q7243", ["name_search"]], [candidate["external_source"], candidate["external_key"], candidate["sources"]]
          assert_equal ["Leo Tolstoy", 1828, ["writer"]], candidate["evidence"].values_at("external_title", "external_year", "occupations")
        end

        def reject_for(author, key)
          ::MatchDecision.create!(finder: ResolveWikidata.name, subject: author, outcome: :matched, confidence: :high,
            decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => key}], selected_index: 1)
        end

        test "a record rejected for this author is never fetched, and the run decides without it" do
          reject_for(@author, "Q7243")
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q7243"]}, entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal [:unmatched, "rule"], [result.data[:outcome], result.data[:decision].decided_by]
          assert_equal [], result.data[:decision].candidates
          assert_equal ["Q7243"], result.data[:decision].query["rejected"]
          assert_not client.calls.any? { |call| call.first == :entities && call.last.include?("Q7243") }
        end

        test "an old id Wikidata merged into a rejected item is dropped too" do
          reject_for(@author, "Q7243")
          client = FakeWikidataClient.new(searches: {"Leo Tolstoy" => ["Q999"]}, entities: {"Q999" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal :unmatched, result.data[:outcome]
          assert_equal [], result.data[:decision].candidates
        end

        test "a record rejected for another author is still a candidate here" do
          reject_for(::Books::Author.create!(name: "Someone Else"), "Q7243")
          hold(:books_author_wikidata_qid, "Q7243")
          client = FakeWikidataClient.new(entities: {"Q7243" => wikidata_entity("Q7243", **TOLSTOY)})

          result = resolve(client)

          assert_equal [:matched, "Q7243"], [result.data[:outcome], result.data[:entity].id]
          assert_nil result.data[:decision].query["rejected"]
        end
      end
    end
  end
end
