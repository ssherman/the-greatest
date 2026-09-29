# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class ResolveViafTest < ActiveSupport::TestCase
        def setup
          @author = ::Books::Author.create!(name: "Stacy Willingham", birth_year: 1991)
          book = ::Books::Book.create!(title: "A Flicker in the Dark")
          @author.book_authors.create!(book: book, position: 1)
        end

        def resolve(client, author: @author, refresh: false) = ResolveViaf.call(author: author, refresh: refresh, client: client)

        # Options override the defaults (merged, not double-splatted beside
        # them, which would warn about a duplicated key).
        def willingham(id = "5391", **options)
          defaults = {headings: ["Willingham, Stacy"], born: "1991-01-30", died: 0, gender: "a",
                      titles: ["A Flicker in the Dark", "All the Dangerous Things"], nationality: ["US"]}
          viaf_person(id, **defaults.merge(options))
        end

        def ai_selects(index, confidence: "high")
          result = Services::Ai::Result.new(success: true, data: {selected_index: index, confidence: confidence, reasoning: "Because.", same_entity_groups: []})
          task = mock("task")
          task.stubs(:call).returns(result)
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).with { |options| @ai_options = options }.returns(task)
        end

        test "a corroborated held id matches by identifier, certain, without searching" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          client = FakeViafClient.new(people: {"5391" => willingham})

          result = resolve(client)

          assert_equal [:matched, "5391"], [result.data[:outcome], result.data[:person].viaf_id]
          decision = result.data[:decision]
          assert_equal ["identifier", "certain", false], [decision.decided_by, decision.confidence, decision.needs_review]
          assert_not client.called?(:suggest)
        end

        test "a held id whose person disagrees on years is not decided by identifier" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "5391")
          client = FakeViafClient.new(people: {"5391" => willingham(born: "1950")})
          ai_selects(0)

          result = resolve(client)

          assert_equal ["unmatched", "ai"], [result.data[:decision].outcome, result.data[:decision].decided_by]
          assert client.called?(:suggest)
        end

        test "a held id VIAF no longer serves is dropped, and the search decides" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "404")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham}
          )

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "medium"], [decision.outcome, decision.decided_by, decision.confidence]
          assert_equal ["viaf_cluster"], decision.sources_failed
          held = decision.candidates.find { |candidate| candidate["external_key"] == "404" }
          assert_equal "NotFoundError", held["evidence"]["unavailable"]
        end

        test "no person among the suggestions is unmatched by rule, and fetches nothing" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [
            viaf_suggestion("2750", "Stacy. Willingham, No salgas de noche", name_type: "uniformtitleexpression")
          ]})

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["unmatched", "rule", "high"], [decision.outcome, decision.decided_by, decision.confidence]
          assert_equal "not a person", decision.candidates.first["evidence"]["dropped"]
          assert_empty client.clusters
        end

        test "rows for one cluster are one candidate; the only one named and born as ours matches by rule" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [
              viaf_suggestion("5391", "Stacy Willingham"),
              viaf_suggestion("5391", "Stacy Willingham 1991–"),
              viaf_suggestion("5391", "Stacy Willingham American writer")
            ]},
            people: {"5391" => willingham}
          )
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["matched", "rule", "high", 1], [decision.outcome, decision.decided_by, decision.confidence, decision.candidates.size]
          assert_equal ["5391"], client.clusters
        end

        test "the rule needs our birth year" do
          author = ::Books::Author.create!(name: "Stacy Willingham Unborn")
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham Unborn" => [viaf_suggestion("9", "Stacy Willingham Unborn, 1991-")]},
            people: {"9" => viaf_person("9", headings: ["Willingham Unborn, Stacy"], born: "1991")}
          )
          ai_selects(1)

          result = resolve(client, author: author)

          assert_equal ["matched", "ai"], [result.data[:decision].outcome, result.data[:decision].decided_by]
        end

        test "the rule's cluster is unavailable, and so no read cluster is a person" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]})
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.expects(:new).never

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["unmatched", "rule", "medium"], [decision.outcome, decision.decided_by, decision.confidence]
          assert_equal ["viaf_cluster"], decision.sources_failed
        end

        test "the rule's cluster disagrees on years after the fetch, so the AI decides" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham(born: "1950")}
          )
          ai_selects(0)

          result = resolve(client)

          assert_equal "ai", result.data[:decision].decided_by
        end

        test "two clusters named as ours (a VIAF duplicate) go to the AI, which sees both and is told about duplicates" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [
              viaf_suggestion("5391", "Stacy Willingham 1991–"),
              viaf_suggestion("1375", "Stacy Willingham, 1991-", agencies: {})
            ]},
            people: {"5391" => willingham, "1375" => viaf_person("1375", headings: ["Willingham, Stacy"], born: "1991", agencies: [])}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal ["5391", "matched", "ai"], [result.data[:person].viaf_id, result.data[:decision].outcome, result.data[:decision].decided_by]
          assert_equal 2, @ai_options[:candidate_lines].size
          assert_match(/2 contributing libraries/, @ai_options[:candidate_lines].first)
          assert_match(/two records/, @ai_options[:guidance])
          assert_equal "VIAF", @ai_options[:source_name]
        end

        test "the AI is shown at most three clusters, named-as-ours first, with titles matched on the main title" do
          people = %w[1 2 3 4].to_h { |id| [id, viaf_person(id, headings: ["Other#{id}, Person"])] }
          people["5"] = willingham("5", titles: ["A flicker in the dark : a novel", "Another Book"])
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => %w[1 2 3 4].map { |id| viaf_suggestion(id, "Person Other#{id}") } +
              [viaf_suggestion("5", "Stacy Willingham")]},
            people: people
          )
          ai_selects(0)

          resolve(client)

          assert_equal 3, client.clusters.size
          assert_equal "5", client.clusters.first
          assert_match(/works matching ours: A flicker in the dark : a novel/, @ai_options[:candidate_lines].first)
          assert_match(/other works: Another Book/, @ai_options[:candidate_lines].first)
        end

        test "a suggested cluster VIAF no longer serves is never shown to the AI" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("404", "Stacy Willingham"), viaf_suggestion("5391", "S. Willingham")]},
            people: {"5391" => willingham}
          )
          ai_selects(1)

          result = resolve(client)

          assert_equal 1, @ai_options[:candidate_lines].size
          assert_equal "5391", result.data[:person].viaf_id
        end

        test "an AI choice of none is unmatched, and a medium one needs review" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => willingham})

          ai_selects(0)
          assert_equal "unmatched", resolve(client).data[:decision].outcome

          ai_selects(1, confidence: "medium")
          assert resolve(client).data[:decision].needs_review
        end

        test "a failed AI call records a failed run for review" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "S. Willingham")]}, people: {"5391" => willingham})
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "timeout"))
          Services::Ai::Tasks::Matching::SelectExternalRecordTask.stubs(:new).returns(task)

          result = resolve(client)

          assert_equal :failed, result.data[:outcome]
          assert_equal ["fallback", true], [result.data[:decision].decided_by, result.data[:decision].needs_review]
        end

        test "a rate limit propagates and records no decision" do
          client = FakeViafClient.new(suggestions: {"Stacy Willingham" => ::Viaf::Exceptions::RateLimited.new("wait", retry_after: 60)})

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Viaf::Exceptions::RateLimited) { resolve(client) }
          end
        end

        test "a VIAF error other than a rate limit propagates and records nothing" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => ::Viaf::Exceptions::ServerError.new("Server error: 500", 500)}
          )

          assert_no_difference -> { ::MatchDecision.count } do
            assert_raises(::Viaf::Exceptions::ServerError) { resolve(client) }
          end
        end

        test "records one decision about the author, with VIAF candidates and the selected one" do
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [viaf_suggestion("5391", "Stacy Willingham 1991–")]},
            people: {"5391" => willingham}
          )

          decision = resolve(client).data[:decision]

          assert_equal ["Services::Books::Authors::ResolveViaf", @author, nil], [decision.finder, decision.subject, decision.record]
          selected = decision.candidates[decision.selected_index - 1]
          assert_equal ["viaf", "5391", "Stacy Willingham", 1991], [selected["external_source"], selected["external_key"],
            selected["evidence"]["external_title"], selected["evidence"]["birth_year"]]
          assert_equal "Stacy Willingham", decision.query["name"]
        end

        test "stored candidates start in the order the AI was shown, even when the post-fetch sort disagrees" do
          # A has more agency keys in its AutoSuggest rows (3) than B (1), so
          # the AI is shown [A, B]. Once fetched, A's cluster turns out to
          # have no agencies while B's has five, so a plain post-fetch sort
          # would give [B, A]. The stored candidates must still start A, B.
          client = FakeViafClient.new(
            suggestions: {"Stacy Willingham" => [
              viaf_suggestion("111", "Candidate A", agencies: {"lc" => "n1", "bnf" => "n2", "dnb" => "n3"}),
              viaf_suggestion("222", "Candidate B", agencies: {"lc" => "n4"})
            ]},
            people: {
              "111" => viaf_person("111", headings: ["A, Candidate"], agencies: []),
              "222" => viaf_person("222", headings: ["B, Candidate"], agencies: %w[DNB BNF DLC NUKAT SUDOC])
            }
          )
          ai_selects(1)

          result = resolve(client)

          decision = result.data[:decision]
          assert_equal ["111", "222"], decision.candidates.first(2).map { |candidate| candidate["external_key"] }
          assert_equal "111", decision.candidates[decision.selected_index - 1]["external_key"]
        end

        test "a forename heading is shown as written, never inverted" do
          author = ::Books::Author.create!(name: "Marcus Aurelius")
          person = viaf_person("7", headings: [{"source" => "LC", "name" => "Marcus Aurelius, Emperor of Rome", "surname_first" => false}])
          client = FakeViafClient.new(suggestions: {"Marcus Aurelius" => [viaf_suggestion("7", "Marcus Aurelius")]}, people: {"7" => person})
          ai_selects(0)

          decision = resolve(client, author: author).data[:decision]

          assert_equal "Marcus Aurelius, Emperor of Rome", decision.candidates.first["evidence"]["external_title"]
          assert_match(/\AMarcus Aurelius, Emperor of Rome \|/, @ai_options[:candidate_lines].first)
        end
      end
    end
  end
end
