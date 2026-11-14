require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class RepairVerdictsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @war = books_books(:war_and_peace)
            @crime = books_books(:crime_and_punishment)
            @merge = verdict("t:merge", kind: :merge_books, payload: {"source_id" => @crime.id, "target_id" => @war.id},
              decided_by: :ai, confidence: :high)
            @guess = verdict("t:guess", kind: :reimport_guess, payload: {"guess" => true, "from_book_id" => @war.id, "to_book_id" => @crime.id})
            @approved = verdict("t:approved", status: :approved, kind: :relink)
            @superseded = verdict("t:superseded", superseded_at: Time.current)
          end

          def verdict(key, kind: :relink, decided_by: :rule, confidence: :certain, payload: {}, **attrs)
            ::Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: decided_by, confidence: confidence,
              payload: payload, reason: "test", **attrs)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def list(params = {}, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/repair_verdicts", params: params, headers: bearer(token)
          end

          def fetch(id, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/repair_verdicts/#{id}", headers: bearer(token)
          end

          def ids = json[:data].map { |row| row[:id] }

          test "lists proposed current verdicts by default, newest first, and conforms" do
            @merge.update_columns(updated_at: 2.days.ago)
            @guess.update_columns(updated_at: 1.day.ago)
            list
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [@guess.id, @merge.id], ids
            assert_equal %i[id kind status decided_by confidence summary reason guess reviewed_at applied_at created_at], json[:data].first.keys
            assert json[:data].first[:guess]
            assert_not json[:data].last[:guess]
          end

          test "status, kind, decided_by, confidence and guess filters" do
            list({status: "approved"})
            assert_equal [@approved.id], ids
            list({kind: "merge_books"})
            assert_equal [@merge.id], ids
            list({decided_by: "ai"})
            assert_equal [@merge.id], ids
            list({confidence: "high"})
            assert_equal [@merge.id], ids
            list({guess: "true"})
            assert_equal [@guess.id], ids
          end

          test "a superseded verdict never appears" do
            list({status: "proposed"})
            assert_not_includes ids, @superseded.id
          end

          test "an unknown enum value is a 400" do
            %w[kind status decided_by confidence].each do |name|
              list({name => "bogus"})
              assert_response :bad_request, name
            end
          end

          test "a member token is a 403 and no token a 401" do
            list({}, token: ApiTokenSecrets::MEMBER)
            assert_response :forbidden
            get "/api/v1/admin/repair_verdicts"
            assert_response :unauthorized
          end

          test "get a merge_books verdict returns books with authors and no candidates" do
            fetch(@merge.id)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal [@crime.id, @war.id].sort, data[:books].map { |book| book[:id] }.sort
            assert_equal %i[id slug title first_published_year authors], data[:books].first.keys
            assert_equal [], data[:candidate_books]
            assert_equal [], data[:source_rows]
            assert_equal 0, data[:source_row_count]
            assert_nil data[:match_decision]
            assert_nil data[:reviewed_by]
            assert_nil data[:reviewed_via]
            assert_nil data[:superseded_at]
            assert_equal({"source_id" => @crime.id, "target_id" => @war.id}, data[:payload].deep_stringify_keys)
          end

          test "get a reimport_match verdict returns candidates, the match decision and the reviewer" do
            decision = match_decisions(:low_confidence_book_match)
            reviewer = users(:admin_user)
            match = verdict("t:match", kind: :reimport_match, decided_by: :ai,
              payload: {"outcome" => "matched", "book_id" => @war.id, "candidate_book_ids" => [@war.id, @crime.id, 999_999_999],
                        "match_decision_id" => decision.id},
              status: :approved, reviewed_at: Time.current, decided_by_user_id: reviewer.id, reviewed_via: :api)
            fetch(match.id)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal [@war.id, @crime.id].sort, data[:candidate_books].map { |book| book[:id] }.sort
            assert_equal [@war.id], data[:books].map { |book| book[:id] }
            assert_equal({id: decision.id, outcome: decision.outcome}, data[:match_decision])
            assert_equal({id: reviewer.id, name: reviewer.name}, data[:reviewed_by])
            assert_equal "api", data[:reviewed_via]
          end

          test "source rows come from the payload pairs, capped at 20 with the full count" do
            import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 4242)
            (1..25).each do |number|
              import.rows.create!(row_number: number, raw: {"Title" => "Title #{number}", "Author" => "Author #{number}"})
            end
            edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 777, signature: "sig-777", title: "T", primary_author: "A",
              isbn13: "9780140447934")
            import.rows.find_by(row_number: 1).update!(goodreads_edition: edition)
            pairs = (1..25).map { |number| [4242, number] } + [[999_999, 1]]
            carrier = verdict("t:rows", kind: :fix_identity, payload: {"book_id" => @war.id, "rows" => pairs})

            fetch(carrier.id)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal 20, data[:source_rows].size
            assert_equal 26, data[:source_row_count]
            assert_equal({import_id: 4242, row_number: 1, title: "Title 1", author: "Author 1", isbn13: "9780140447934", goodreads_book_id: 777},
              data[:source_rows].first)
            assert_equal [nil, nil], [data[:source_rows].last[:isbn13], data[:source_rows].last[:goodreads_book_id]]
          end

          def write(path, params = {}, token: ApiTokenSecrets::ADMIN)
            post "/api/v1/admin/repair_verdicts/#{path}", params: params, as: :json, headers: bearer(token)
          end

          def match_verdict(**attrs)
            verdict("t:match:#{SecureRandom.hex(3)}", kind: :reimport_match, decided_by: :ai,
              payload: {"outcome" => "matched", "book_id" => @war.id}, **attrs)
          end

          test "approve stamps the reviewer and api, returns the detail and conforms" do
            write("#{@merge.id}/approve")
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "approved", json[:data][:status]
            assert_equal "api", json[:data][:reviewed_via]
            assert_equal users(:admin_user).id, json[:data][:reviewed_by][:id]
            assert_equal "ai", @merge.reload.decided_by
            assert_nil @merge.applied_at
          end

          test "approve of an already reviewed verdict is a 422" do
            write("#{@approved.id}/approve")
            assert_response :unprocessable_entity
          end

          test "approve and reject of a superseded verdict are 422 and change nothing" do
            write("#{@superseded.id}/approve")
            assert_response :unprocessable_entity
            write("#{@superseded.id}/reject")
            assert_response :unprocessable_entity
            assert_predicate @superseded.reload, :proposed?
          end

          test "approve and reject of an unknown verdict are 404" do
            write("999999999/approve")
            assert_response :not_found
            write("999999999/reject")
            assert_response :not_found
            write("abc/approve")
            assert_response :not_found
          end

          test "reject stamps api, and rejecting twice is a 422" do
            write("#{@merge.id}/reject")
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["rejected", "api"], [json[:data][:status], json[:data][:reviewed_via]]

            write("#{@merge.id}/reject")
            assert_response :unprocessable_entity
          end

          test "rejecting an applied mark_provisional reverts the book" do
            @war.update!(provisional: true)
            applied = verdict("t:prov", kind: :mark_provisional, status: :approved, applied_at: Time.current,
              payload: {"book_id" => @war.id})
            ::Services::RankingConfigurations::RequestRefresh.stubs(:call_for_ids)

            write("#{applied.id}/reject")

            assert_response :success
            assert_not @war.reload.provisional
            assert_nil applied.reload.applied_at
          end

          test "approve needs the merge scope and reject the write scope" do
            write("#{@merge.id}/approve", token: ApiTokenSecrets::ADMIN_READ)
            assert_response :forbidden
            write("#{@merge.id}/reject", token: ApiTokenSecrets::ADMIN_READ)
            assert_response :forbidden
            write("#{@merge.id}/correct", {create: true}, token: ApiTokenSecrets::ADMIN_READ)
            assert_response :forbidden
            write("bulk_approve", {ids: [@merge.id]}, token: ApiTokenSecrets::ADMIN_READ)
            assert_response :forbidden
            assert_predicate @merge.reload, :proposed?
          end

          test "correct with create answers a match, stamps api and conforms" do
            match = match_verdict

            write("#{match.id}/correct", {create: true})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ["approved", "api"], [json[:data][:status], json[:data][:reviewed_via]]
            assert_equal "create", match.reload.payload["outcome"]
          end

          test "correct with a book id points the match at that book" do
            match = match_verdict

            write("#{match.id}/correct", {book_id: @crime.id})

            assert_response :success
            assert_equal @crime.id, match.reload.payload["book_id"]
          end

          test "correct with both or neither of book_id and create is a 422" do
            match = match_verdict
            write("#{match.id}/correct", {book_id: @crime.id, create: true})
            assert_response :unprocessable_entity
            write("#{match.id}/correct", {})
            assert_response :unprocessable_entity
            assert_predicate match.reload, :proposed?
          end

          test "correct with wrong JSON types is a 400" do
            match = match_verdict
            write("#{match.id}/correct", {book_id: "12"})
            assert_response :bad_request
            write("#{match.id}/correct", {create: "yes"})
            assert_response :bad_request
            write("#{match.id}/correct", {book_id: [1]})
            assert_response :bad_request
          end

          test "correct refuses a superseded match, a non-match and an unknown book" do
            write("#{match_verdict(superseded_at: Time.current).id}/correct", {create: true})
            assert_response :unprocessable_entity
            write("#{@merge.id}/correct", {create: true})
            assert_response :unprocessable_entity
            write("#{match_verdict.id}/correct", {book_id: 999_999_999})
            assert_response :unprocessable_entity
            write("999999999/correct", {create: true})
            assert_response :not_found
          end

          test "bulk approve approves the proposed and skips the rest" do
            write("bulk_approve", {ids: [@merge.id, @guess.id, @approved.id, @superseded.id, 999_999_999]})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [@merge.id, @guess.id].sort, json[:data][:approved_ids].sort
            assert_equal [@approved.id, @superseded.id, 999_999_999].sort, json[:data][:skipped_ids].sort
            assert_equal "api", @merge.reload.reviewed_via
            assert_predicate @superseded.reload, :proposed?
          end

          test "bulk approve refuses a bad ids list with a 400" do
            [[], (1..101).to_a, ["1"], [0], [1.5], "1", nil].each do |ids|
              write("bulk_approve", {ids: ids})
              assert_response :bad_request, ids.inspect
            end
            write("bulk_approve", {ids: (1..100).to_a})
            assert_response :success
          end

          test "an unknown or non-numeric id is a 404" do
            fetch(999_999_999)
            assert_response :not_found
            fetch("abc")
            assert_response :not_found
          end

          test "get with a member token is a 403" do
            fetch(@merge.id, token: ApiTokenSecrets::MEMBER)
            assert_response :forbidden
          end
        end
      end
    end
  end
end
