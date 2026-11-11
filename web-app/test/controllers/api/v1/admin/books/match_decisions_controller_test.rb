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

          test "a list item subject has a null label and does not break list or get" do
            item = list_items(:basic_item)
            @low.update_columns(subject_type: "ListItem", subject_id: item.id)

            list
            assert_api_response_conform(status: 200, api: :admin)
            subject = json[:data].find { |row| row[:id] == @low.id }[:subject]
            assert_equal [item.id, "ListItem"], [subject[:id], subject[:type]]
            assert_nil subject[:label]

            fetch(@low.id)
            assert_api_response_conform(status: 200, api: :admin)
            assert_nil json[:data][:subject][:label]
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

          # ---- review and reject_link ------------------------------------------

          def review(id, body = {}, token: ApiTokenSecrets::ADMIN)
            post "/api/v1/admin/match_decisions/#{id}/review", params: body, as: :json, headers: bearer(token)
          end

          def reject_link(id, body = {}, token: ApiTokenSecrets::ADMIN)
            post "/api/v1/admin/match_decisions/#{id}/reject_link", params: body, as: :json, headers: bearer(token)
          end

          def link_decision(finder: "Services::Books::Authors::ResolveWikidata", outcome: :matched, key: "Q7243")
            MatchDecision.create!(
              finder: finder, subject: books_authors(:tolstoy), record: nil, outcome: outcome, confidence: :medium,
              decided_by: :ai, needs_review: true, query: {"name" => "Leo Tolstoy"},
              candidates: [{"record_type" => nil, "record_id" => nil, "external_source" => "wikidata", "external_key" => key,
                            "sources" => ["name_search"], "scores" => {}, "evidence" => {"external_title" => "Leo Tolstoy"}}],
              selected_index: (outcome == :matched) ? 1 : nil, reason: "Works match."
            )
          end

          test "review stamps who, when, how, the verdict and the note, and returns the detail row" do
            review(@low.id, {verdict: "confirmed", note: "Same book."})
            assert_api_response_conform(status: 200, api: :admin)

            @low.reload
            assert @low.reviewed_at.present?
            assert_equal users(:admin_user), @low.reviewed_by
            assert @low.verdict_confirmed?
            assert_equal "Same book.", @low.review_note
            assert @low.reviewed_via_api?
            assert_equal [@low.id, "confirmed", "api"], json[:data].then { |d| [d[:id], d[:review][:verdict], d[:review][:reviewed_via]] }
            assert json[:data].key?(:candidates)
          end

          test "review without a verdict or note is fine" do
            review(@low.id)
            assert_api_response_conform(status: 200, api: :admin)

            assert @low.reload.reviewed_at.present?
            assert_nil @low.verdict
          end

          test "reviewing an already reviewed decision is a 422 and changes nothing" do
            before = @reviewed.reload.attributes
            review(@reviewed.id, {note: "again"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal before, @reviewed.reload.attributes
          end

          test "a bad verdict or an overlong note is a 400" do
            review(@low.id, {verdict: "maybe"})
            assert_api_response_conform(status: 400, api: :admin)

            review(@low.id, {note: "x" * 1001})
            assert_api_response_conform(status: 400, api: :admin)
            assert_nil @low.reload.reviewed_at
          end

          test "rejecting a matched Wikidata decision by review points at reject_match_decision_link and changes nothing" do
            decision = link_decision
            review(decision.id, {verdict: "rejected"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "reject_match_decision_link"
            assert_nil decision.reload.reviewed_at
            assert_nil decision.verdict
          end

          test "rejecting an unmatched link decision, or an author finder decision, by review is allowed" do
            unmatched = link_decision(outcome: :unmatched)
            review(unmatched.id, {verdict: "rejected"})
            assert_api_response_conform(status: 200, api: :admin)
            assert unmatched.reload.verdict_rejected?

            author_decision = MatchDecision.create!(finder: "DataImporters::Books::Author::Finder", outcome: :matched,
              confidence: :low, decided_by: :ai, needs_review: true, record: books_authors(:tolstoy), query: {"name" => "x"},
              candidates: [{"record_type" => "Books::Author", "record_id" => books_authors(:tolstoy).id, "sources" => [], "scores" => {}, "evidence" => {}}],
              selected_index: 1)
            review(author_decision.id, {verdict: "rejected"})
            assert_api_response_conform(status: 200, api: :admin)
            assert author_decision.reload.verdict_rejected?
          end

          test "review of an unknown id is 404, of another domain's decision is 404, and needs the write scope" do
            review(999_999_999)
            assert_api_response_conform(status: 404, api: :admin)

            review(@music.id)
            assert_api_response_conform(status: 404, api: :admin)

            review(@low.id, {}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert_nil @low.reload.reviewed_at
          end

          test "review by a user without a books write role is a 403" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            review(@low.id)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
            assert_nil @low.reload.reviewed_at
          end

          test "reject_link removes the identifier, rejects the decision with the note, and stamps the cascade via the API" do
            stub_workflow_dispatch
            author = books_authors(:tolstoy)
            author.identifiers.create!(identifier_type: "books_author_wikidata_qid", value: "Q7243")
            decision = link_decision
            sibling = link_decision

            reject_link(decision.id, {note: "Wrong Tolstoy."})
            assert_api_response_conform(status: 200, api: :admin)

            assert_not author.identifiers.exists?(identifier_type: "books_author_wikidata_qid", value: "Q7243")
            decision.reload
            assert decision.verdict_rejected?
            assert_equal "Link rejected. \u2014 Wrong Tolstoy.", decision.review_note
            assert_equal [decision.id, sibling.id].sort, json[:data][:rejected].sort
            assert_equal decision.id, json[:data][:decision][:id]
            assert_includes json[:data][:reverted], "wikidata_qid"
            assert_equal 0, json[:data][:descriptions_deprecated]

            sibling.reload
            assert sibling.verdict_rejected?
            assert sibling.reviewed_via_api?
            assert_equal users(:admin_user), sibling.reviewed_by
            assert_equal "Link rejected.", sibling.review_note
          end

          test "reject_link without a note leaves the service's note" do
            stub_workflow_dispatch
            decision = link_decision
            reject_link(decision.id)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "Link rejected.", decision.reload.review_note
            assert decision.reviewed_via_api?
          end

          test "reject_link refuses what the service refuses, with its message" do
            stub_workflow_dispatch
            unmatched = link_decision(outcome: :unmatched)
            reject_link(unmatched.id)
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], "Only a decision that matched a record can be rejected."

            reject_link(@low.id)
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], "Only a Wikidata or VIAF link decision can be rejected."

            done = link_decision
            done.update!(verdict: :rejected)
            reject_link(done.id)
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], "already rejected"
          end

          test "reject_link needs the merge scope and a books delete role, and a bad note is a 400" do
            decision = link_decision
            reject_link(decision.id, {}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)

            ::Books::AuthorPolicy.any_instance.stubs(:destroy?).returns(false)
            reject_link(decision.id)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
            assert_nil decision.reload.verdict

            ::Books::AuthorPolicy.any_instance.unstub(:destroy?)
            reject_link(decision.id, {note: "x" * 1001})
            assert_api_response_conform(status: 400, api: :admin)
            assert_nil decision.reload.verdict
          end

          test "reject_link on a decision whose author is gone is a 422 with the service's message" do
            stub_workflow_dispatch
            decision = link_decision
            decision.update_columns(subject_id: 999_999_999)
            reject_link(decision.id)
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "The author is gone."
            assert_nil decision.reload.verdict
          end

          test "rejecting a matched VIAF decision by review is a 422 pointing at reject_match_decision_link" do
            decision = link_decision(finder: "Services::Books::Authors::ResolveViaf", key: "96987389")
            review(decision.id, {verdict: "rejected"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "reject_match_decision_link"
            assert_nil decision.reload.reviewed_at
          end

          test "reject_link of an unknown id is 404" do
            reject_link(999_999_999)
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
