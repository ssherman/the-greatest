require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class MatchDecisionsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @low = match_decisions(:low_confidence_book_match)
            @sweep = match_decisions(:war_and_peace_sweep)
            @created = match_decisions(:new_book_created)
            @reviewed = match_decisions(:reviewed_book_match)
            @music = match_decisions(:dark_side_album_match)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def list(params = {}, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/match_decisions", params: params, headers: bearer(token)
          end

          def fetch(id, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/match_decisions/#{id}", headers: bearer(token)
          end

          def ids = json[:data].map { |row| row[:id] }

          test "lists pending decisions by default, hides verify runs and conforms to the admin document" do
            list
            assert_api_response_conform(status: 200, api: :admin)

            assert_includes ids, @low.id
            assert_includes ids, @created.id
            assert_not_includes ids, @sweep.id
            assert_not_includes ids, @reviewed.id
            assert_not_includes ids, @music.id
          end

          test "newest first with id as the tiebreaker" do
            @low.update_columns(created_at: 3.days.ago)
            @created.update_columns(created_at: 1.day.ago)
            list
            assert_equal [@created.id, @low.id], ids & [@created.id, @low.id]
          end

          test "reviewed and verify filters" do
            list({reviewed: "reviewed"})
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [@reviewed.id], ids

            list({reviewed: "all", verify: "include"})
            assert_includes ids, @sweep.id
            assert_includes ids, @reviewed.id
            assert_includes ids, @low.id
            assert_not_includes ids, @music.id
          end

          test "entity, outcome, confidence and decided_by narrow the list" do
            author_decision = MatchDecision.create!(finder: "DataImporters::Books::Author::Finder", outcome: :unmatched,
              confidence: :low, decided_by: :fallback, needs_review: true, query: {}, candidates: [])

            list({entity: "author"})
            assert_equal [author_decision.id], ids

            list({entity: "book", outcome: "unmatched"})
            assert_equal [@created.id], ids

            list({confidence: "low", entity: "book"})
            assert_equal [@low.id, @created.id].sort, ids.sort

            list({decided_by: "fallback"})
            assert_equal [author_decision.id], ids
          end

          test "wikidata-link and viaf-link are entities" do
            link = MatchDecision.create!(finder: "Services::Books::Authors::ResolveWikidata", outcome: :matched,
              confidence: :low, decided_by: :rule, needs_review: true, query: {}, candidates: [])

            list({entity: "wikidata-link"})
            assert_equal [link.id], ids

            list({entity: "viaf-link"})
            assert_empty ids
          end

          test "a bad filter value is a 400" do
            {entity: "album", outcome: "maybe", confidence: "huge", decided_by: "magic", reviewed: "some", verify: "yes"}.each do |key, value|
              list({key => value})
              assert_api_response_conform(status: 400, api: :admin)
            end
          end

          test "a row has subject and record labels and the review block" do
            @sweep.update_columns(needs_review: true)
            @reviewed.update_columns(reviewed_via: MatchDecision.reviewed_via.fetch("api"), verdict: MatchDecision.verdicts.fetch("confirmed"))
            list({reviewed: "all", verify: "include"})

            low = json[:data].find { |row| row[:id] == @low.id }
            assert_equal "book", low[:entity]
            assert_equal @low.finder, low[:finder]
            assert_equal "matched", low[:outcome]
            assert_equal "low", low[:confidence]
            assert_equal "ai", low[:decided_by]
            assert_equal books_books(:war_and_peace).title, low[:record][:label]
            assert_equal [books_books(:war_and_peace).id, "Books::Book"], [low[:record][:id], low[:record][:type]]
            assert_nil low[:subject]
            assert_nil low[:review]

            sweep = json[:data].find { |row| row[:id] == @sweep.id }
            assert_equal books_books(:war_and_peace).id, sweep[:subject][:id]
            assert_nil sweep[:record]

            reviewed = json[:data].find { |row| row[:id] == @reviewed.id }
            assert_equal [users(:admin_user).email, "api", "Looks right.", "confirmed"],
              reviewed[:review].values_at(:reviewed_by, :reviewed_via, :note, :verdict)
            assert reviewed[:review][:reviewed_at].present?
          end

          test "get returns the query, candidates and a current summary for an existing record" do
            fetch(@low.id)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal @low.id, data[:id]
            assert_equal "War & Peace", data[:query][:title]
            assert_equal 1, data[:selected_index]
            candidate = data[:candidates].first
            assert_equal "Books::Book", candidate[:record_type]
            assert_equal ["opensearch"], candidate[:sources]
            assert_equal books_books(:war_and_peace).title, candidate[:current][:title]
          end

          test "a candidate whose record is gone has a null current" do
            @low.update!(candidates: @low.candidates.map { |c| c.merge("record_id" => 999_999_999) })
            fetch(@low.id)
            assert_api_response_conform(status: 200, api: :admin)
            assert_nil json[:data][:candidates].first[:current]
          end

          test "a candidate that is not one of our record types has a null current" do
            @low.update!(candidates: [{"record_type" => nil, "external_key" => "Q1", "external_source" => "wikidata", "sources" => [], "scores" => {}, "evidence" => {}}])
            fetch(@low.id)
            assert_api_response_conform(status: 200, api: :admin)
            assert_nil json[:data][:candidates].first[:current]
          end

          test "an unknown id and another domain's decision are 404" do
            fetch(999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "No match decision 999999999 in the books queue."

            fetch(@music.id)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "a read token works and a non-admin token is 403" do
            list(token: ApiTokenSecrets::ADMIN_READ)
            assert_response :success

            list(token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end
        end
      end
    end
  end
end
