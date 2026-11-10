require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class DuplicateCandidatesControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @pending = duplicate_candidates(:books_pending_pair)
            @dismissed = duplicate_candidates(:books_dismissed_pair)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def list(params = {}, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/duplicate_candidates", params: params, headers: bearer(token)
          end

          def fetch(id, token: ApiTokenSecrets::ADMIN_READ)
            get "/api/v1/admin/duplicate_candidates/#{id}", headers: bearer(token)
          end

          def pair_of(type, a, b, **attrs)
            ids = [a.id, b.id].minmax
            DuplicateCandidate.create!({item_type: type, item_a_id: ids[0], item_b_id: ids[1], source: :human}.merge(attrs))
          end

          def author_pair
            pair_of("Books::Author", books_authors(:king), books_authors(:bachman))
          end

          test "lists pending pairs of both types by default and conforms to the admin document" do
            author = author_pair
            list
            assert_api_response_conform(status: 200, api: :admin)

            ids = json[:data].map { |row| row[:id] }
            assert_includes ids, @pending.id
            assert_includes ids, author.id
            assert_not_includes ids, @dismissed.id
            assert_not_includes ids, duplicate_candidates(:resident_evil_4_pair).id
            assert(json[:data].all? { |row| row[:status] == "pending" })
          end

          test "status and item_type filter" do
            author = author_pair

            list({status: "not_duplicate"})
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [@dismissed.id], json[:data].map { |row| row[:id] }

            list({item_type: "author"})
            assert_equal [author.id], json[:data].map { |row| row[:id] }
            assert_equal "author", json[:data].first[:item_type]
          end

          test "a bad status or item_type is a 400" do
            list({status: "open"})
            assert_api_response_conform(status: 400, api: :admin)

            list({item_type: "game"})
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "each pair carries both records, lower id first" do
            list
            row = json[:data].find { |pair| pair[:id] == @pending.id }

            assert_equal [@pending.item_a_id, @pending.item_b_id], row[:records].map { |record| record[:id] }
            assert(row[:records].all? { |record| record[:missing] == false && record[:title].present? })
            assert_equal "pending", row[:status]
            assert_equal "bulk_verify", row[:raised_by]
            assert_equal 2, row[:occurrences]
            assert_nil row[:resolution]
          end

          test "a resolved pair reports who resolved it and how" do
            @dismissed.update!(resolved_via: :api)
            list({status: "not_duplicate"})

            resolution = json[:data].first[:resolution]
            assert_equal [users(:admin_user).email, "api", "Different books."],
              [resolution[:resolved_by], resolution[:resolved_via], resolution[:note]]
          end

          test "a record deleted since the pair was raised shows as missing" do
            book = books_books(:war_and_peace)
            pair = DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: book.id, item_b_id: book.id + 1_000_000, source: :human)
            list
            row = json[:data].find { |entry| entry[:id] == pair.id }

            assert_equal false, row[:records][0][:missing]
            assert_equal({id: pair.item_b_id, missing: true}, row[:records][1])
          end

          test "summaries are loaded once per item type for a page of pairs" do
            pair_of("Books::Book", books_books(:war_and_peace), books_books(:crime_and_punishment))
            pair_of("Books::Book", books_books(:cannery_row), books_books(:war_and_peace))
            assert_equal 3, DuplicateCandidate.pending.where(item_type: "Books::Book").count

            ::DataImporters::Books::Book::Finder.any_instance.expects(:summarize_all).once.returns({})
            list
            assert_response :success
            assert_equal 3, json[:data].size
          end

          test "get returns the book detail fields and the match decision" do
            fetch(@pending.id)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal @pending.id, data[:id]
            assert_equal @pending.match_decision_id, data[:match_decision][:id]
            assert_equal "low", data[:match_decision][:confidence]
            record = data[:records].first
            assert record.key?(:subtitle)
            assert_kind_of Array, record[:alternate_titles]
            assert_kind_of Array, record[:lists]
          end

          test "get returns the author detail fields, and a null match decision when unlinked" do
            author = author_pair
            fetch(author.id)
            assert_api_response_conform(status: 200, api: :admin)

            record = json[:data][:records].first
            assert_kind_of Array, record[:alternate_names]
            assert_kind_of Array, record[:books]
            assert_nil json[:data][:match_decision]
          end

          test "get answers for a resolved pair" do
            fetch(@dismissed.id)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal "not_duplicate", json[:data][:status]
          end

          test "get on an unknown id is a 404 that says to list again" do
            fetch(0)
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "List the queue again"
          end

          test "get on another domain's pair is a 404" do
            fetch(duplicate_candidates(:resident_evil_4_pair).id)
            assert_api_response_conform(status: 404, api: :admin)
          end

          # --- merge and dismiss -------------------------------------------------

          def merge_pair(pair, body, token: ApiTokenSecrets::ADMIN, id: pair&.id)
            post "/api/v1/admin/duplicate_candidates/#{id}/merge", params: body, as: :json, headers: bearer(token)
          end

          # record_ids default to the pair's own, as get_duplicate_candidate returns them.
          def dismiss_pair(pair, body = {}, token: ApiTokenSecrets::ADMIN, id: pair&.id)
            body = {record_ids: [pair.item_a_id, pair.item_b_id]}.merge(body) if pair
            post "/api/v1/admin/duplicate_candidates/#{id}/dismiss", params: body, as: :json, headers: bearer(token)
          end

          def book_pair
            @war = books_books(:war_and_peace)
            @crime = books_books(:crime_and_punishment)
            pair_of("Books::Book", @war, @crime)
          end

          def pair_with_missing_side
            war = books_books(:war_and_peace)
            @gone_id = war.id + 1_000_000
            DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: war.id, item_b_id: @gone_id, source: :human)
          end

          test "merge deletes the other record and resolves the pair with who, how and the note" do
            pair = book_pair
            merge_pair(pair, {target_id: @war.id, source_id: @crime.id, note: "Same novel."})
            assert_api_response_conform(status: 200, api: :admin)

            assert_not ::Books::Book.exists?(@crime.id)
            assert ::Books::Book.exists?(@war.id)
            pair.reload
            assert pair.merged?
            assert pair.resolved_via_api?
            assert_equal users(:admin_user), pair.resolved_by
            assert_equal "Same novel.", pair.resolution_note
            assert_not_nil pair.resolved_at
            assert_equal [@war.id, @crime.id], [json[:data][:survivor][:id], json[:data][:deleted][:id]]
            assert_equal false, json[:meta][:dry_run]
            assert_equal "merged", json[:data][:pair][:status]
            assert_equal "Same novel.", json[:data][:pair][:resolution][:note]
          end

          test "the target is the survivor whichever side it is" do
            pair = book_pair
            merge_pair(pair, {target_id: @crime.id, source_id: @war.id})
            assert_response :success

            assert_not ::Books::Book.exists?(@war.id)
            assert ::Books::Book.exists?(@crime.id)
          end

          test "merge without a note leaves the note nil" do
            pair = book_pair
            merge_pair(pair, {target_id: @war.id, source_id: @crime.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_nil pair.reload.resolution_note
            assert pair.merged?
          end

          test "a string target_id of plain digits is accepted" do
            pair = book_pair
            merge_pair(pair, {target_id: @war.id, source_id: @crime.id.to_s})
            assert_response :success
            assert_not ::Books::Book.exists?(@crime.id)
          end

          test "merge dry_run changes nothing" do
            pair = book_pair
            ::Books::Book::Merger.expects(:new).never

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id, note: "ignored", dry_run: true})
            assert_api_response_conform(status: 200, api: :admin)

            assert ::Books::Book.exists?(@crime.id)
            pair.reload
            assert pair.pending?
            assert_nil pair.resolution_note
            assert_equal true, json[:meta][:dry_run]
            assert_equal @crime.id, json[:data][:deleted][:id]
            assert_equal "pending", json[:data][:pair][:status]
          end

          test "merge of an author pair uses the author merger and returns author resources" do
            pair = author_pair
            keep = books_authors(:king)
            gone = books_authors(:bachman)

            merge_pair(pair, {target_id: keep.id, source_id: gone.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_not ::Books::Author.exists?(gone.id)
            assert_equal [keep.id, gone.id], [json[:data][:survivor][:id], json[:data][:deleted][:id]]
            assert json[:data][:survivor].key?(:name)
            assert pair.reload.merged?
            assert pair.resolved_via_api?
          end

          test "merge warnings are returned" do
            pair = book_pair
            merger = stub(call: ::Books::Book::Merger::Result.new(success?: true, data: @war, errors: []),
              stats: {post_commit_error: "Redis down"})
            ::Books::Book::Merger.expects(:new).returns(merger)

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id})
            assert_equal ["post_commit_error"], json[:warnings].map { |w| w[:code] }
          end

          test "merge of a pair that is not pending is a 422 and deletes nothing" do
            pair = book_pair
            pair.update!(status: :not_duplicate)

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert ::Books::Book.exists?(@crime.id)
            assert ::Books::Book.exists?(@war.id)
          end

          test "a target_id outside the pair is a 422 and deletes nothing" do
            pair = book_pair
            outsider = books_books(:cannery_row)

            merge_pair(pair, {target_id: outsider.id, source_id: @war.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "not this pair's"
            [@war, @crime, outsider].each { |book| assert ::Books::Book.exists?(book.id) }
            assert pair.reload.pending?
          end

          test "a pair with a side already gone is a 422 and nothing is deleted" do
            pair = pair_with_missing_side

            merge_pair(pair, {target_id: books_books(:war_and_peace).id, source_id: @gone_id})
            assert_api_response_conform(status: 422, api: :admin)

            assert ::Books::Book.exists?(books_books(:war_and_peace).id)
            assert pair.reload.pending?
          end

          test "merge naming the missing side as the survivor is a 422" do
            pair = pair_with_missing_side

            merge_pair(pair, {target_id: @gone_id, source_id: books_books(:war_and_peace).id})
            assert_api_response_conform(status: 422, api: :admin)
            assert ::Books::Book.exists?(books_books(:war_and_peace).id)
          end

          test "a missing, non-integer or non-positive target_id is a 400" do
            pair = book_pair

            post "/api/v1/admin/duplicate_candidates/#{pair.id}/merge", params: {note: "x"}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_response :bad_request

            ["abc", "0x1A", 5.5, 0, -1, true].each do |bad|
              merge_pair(pair, {target_id: bad, source_id: @crime.id})
              assert_response :bad_request, bad.inspect
              assert_equal "invalid_parameter", json[:code]
            end
            assert ::Books::Book.exists?(@crime.id)
            assert pair.reload.pending?
          end

          test "a note that is not a string or is too long is a 400" do
            pair = book_pair

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id, note: ["a"]})
            assert_response :bad_request
            merge_pair(pair, {target_id: @war.id, source_id: @crime.id, note: "a" * 1001})
            assert_response :bad_request
            assert ::Books::Book.exists?(@crime.id)
          end

          test "merging an unknown pair is a 404 that says to list again" do
            merge_pair(nil, {target_id: books_books(:war_and_peace).id, source_id: 1}, id: 999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "List the queue again"
          end

          test "merging another domain's pair is a 404" do
            merge_pair(nil, {target_id: 1, source_id: 2}, id: duplicate_candidates(:resident_evil_4_pair).id)
            assert_response :not_found
          end

          test "merge needs the merge scope" do
            pair = book_pair
            merge_pair(pair, {target_id: @war.id, source_id: @crime.id}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "insufficient_scope", json[:code]
            assert ::Books::Book.exists?(@crime.id)
            assert pair.reload.pending?
          end

          test "an owner whose policy refuses destroy is a 403 and deletes nothing" do
            pair = book_pair
            # The token's merge scope is itself decided by a destroy? check on the
            # class, so only the one record is refused.
            refused = @crime
            ::Books::BookPolicy.stubs(:new).with { |_user, record| record != refused }
              .returns(stub_everything(index?: true, destroy?: true))
            ::Books::BookPolicy.stubs(:new).with { |_user, record| record == refused }
              .returns(stub_everything(destroy?: false))

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id})
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert ::Books::Book.exists?(@crime.id)
            assert pair.reload.pending?
          end

          test "a failing merger is a 422 and leaves the pair pending" do
            pair = book_pair
            merger = stub(call: ::Books::Book::Merger::Result.new(success?: false, data: nil, errors: ["boom"]), stats: {})
            ::Books::Book::Merger.expects(:new).returns(merger)

            merge_pair(pair, {target_id: @war.id, source_id: @crime.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "boom"
            assert pair.reload.pending?
          end

          test "merging with the old ids after a merge re-keyed the pair is a 422 and deletes nothing" do
            a = books_books(:war_and_peace)
            b = books_books(:crime_and_punishment)
            c = books_books(:cannery_row)
            p1 = pair_of("Books::Book", a, b)
            p2 = pair_of("Books::Book", b, c)
            ids = [a, b, c].map(&:id)
            # The agent listed p1 and p2 with (a, b) and (b, c). Merging p2 keeping c re-keys p1 to (a, c).
            merge_pair(p2, {target_id: c.id, source_id: b.id})
            assert_response :success
            assert_equal [a.id, c.id].minmax, [p1.reload.item_a_id, p1.item_b_id]

            merge_pair(p1, {target_id: a.id, source_id: b.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "not this pair's"
            assert ::Books::Book.exists?(a.id)
            assert ::Books::Book.exists?(c.id)
            assert_not ::Books::Book.exists?(b.id)
            assert p1.reload.pending?
            assert_equal 2, ids.count { |id| ::Books::Book.exists?(id) }
          end

          test "merge with source_id equal to target_id is a 422" do
            pair = book_pair
            merge_pair(pair, {target_id: @war.id, source_id: @war.id})
            assert_response :unprocessable_entity
            assert ::Books::Book.exists?(@crime.id)
            assert pair.reload.pending?
          end

          test "a missing or malformed source_id is a 400" do
            pair = book_pair
            post "/api/v1/admin/duplicate_candidates/#{pair.id}/merge", params: {target_id: @war.id}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_response :bad_request

            ["abc", 0, -1, 5.5, true].each do |bad|
              merge_pair(pair, {target_id: @war.id, source_id: bad})
              assert_response :bad_request, bad.inspect
            end
            assert ::Books::Book.exists?(@crime.id)
            assert pair.reload.pending?
          end

          test "dismissing with the old record_ids after a merge re-keyed the pair is a 422 and leaves it pending" do
            a = books_books(:war_and_peace)
            b = books_books(:crime_and_punishment)
            c = books_books(:cannery_row)
            p1 = pair_of("Books::Book", a, b)
            p2 = pair_of("Books::Book", b, c)
            merge_pair(p2, {target_id: c.id, source_id: b.id})
            assert_response :success

            post "/api/v1/admin/duplicate_candidates/#{p1.id}/dismiss", params: {record_ids: [a.id, b.id]}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_api_response_conform(status: 422, api: :admin)
            assert p1.reload.pending?
          end

          test "dismiss with missing or malformed record_ids is a 400" do
            post "/api/v1/admin/duplicate_candidates/#{@pending.id}/dismiss", params: {note: "x"}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_response :bad_request

            [[1], [1, 2, 3], ["a", "b"], [0, 1], "1,2", [1, nil], [1.5, 2]].each do |bad|
              post "/api/v1/admin/duplicate_candidates/#{@pending.id}/dismiss", params: {record_ids: bad}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
              assert_response :bad_request, bad.inspect
            end
            assert @pending.reload.pending?
          end

          test "dismiss accepts the record ids in either order" do
            dismiss_pair(@pending, {record_ids: [@pending.item_b_id, @pending.item_a_id]})
            assert_response :success
            assert @pending.reload.not_duplicate?
          end

          test "dismiss marks the pair not a duplicate with who, how and the note" do
            dismiss_pair(@pending, {note: "Different editions of different works."})
            assert_api_response_conform(status: 200, api: :admin)

            @pending.reload
            assert @pending.not_duplicate?
            assert_not_nil @pending.resolved_at
            assert_equal users(:admin_user), @pending.resolved_by
            assert @pending.resolved_via_api?
            assert_equal "Different editions of different works.", @pending.resolution_note
            assert_equal "not_duplicate", json[:data][:pair][:status]
            assert_equal "Different editions of different works.", json[:data][:pair][:resolution][:note]
          end

          test "dismiss works without a note and when a side is missing" do
            pair = pair_with_missing_side

            dismiss_pair(pair)
            assert_api_response_conform(status: 200, api: :admin)

            assert pair.reload.not_duplicate?
            assert_nil pair.resolution_note
            assert ::Books::Book.exists?(books_books(:war_and_peace).id)
          end

          test "dismiss of an author pair works" do
            pair = author_pair
            dismiss_pair(pair)
            assert_response :success
            assert pair.reload.not_duplicate?
          end

          test "dismiss of a pair that is not pending is a 422 and changes nothing" do
            dismiss_pair(@dismissed, {note: "again"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "Different books.", @dismissed.reload.resolution_note
          end

          test "dismiss needs the write scope" do
            dismiss_pair(@pending, {}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "insufficient_scope", json[:code]
            assert @pending.reload.pending?
          end

          test "dismiss by a user without a books write role is a 403" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            dismiss_pair(@pending)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert @pending.reload.pending?
          end

          test "dismiss on an unknown pair is a 404" do
            dismiss_pair(nil, {record_ids: [1, 2]}, id: 999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "dismiss with a bad note is a 400" do
            dismiss_pair(@pending, {note: {a: 1}})
            assert_api_response_conform(status: 400, api: :admin)
            assert @pending.reload.pending?
          end

          test "the list breaks created_at ties newest id first" do
            stamp = Time.current
            first = pair_of("Books::Book", books_books(:war_and_peace), books_books(:crime_and_punishment), created_at: stamp)
            second = pair_of("Books::Book", books_books(:cannery_row), books_books(:war_and_peace), created_at: stamp)

            list
            ids = json[:data].map { |row| row[:id] }
            assert_operator ids.index(second.id), :<, ids.index(first.id)
          end

          test "an author's detail books list ranked books first by rank, then unranked" do
            author = author_pair
            king = books_authors(:king)
            config = ranking_configurations(:books_global)
            newest = ::Books::Book.create!(title: "Newest King")
            ::Books::BookAuthor.create!(book: newest, author: king)
            RankedItem.create!(item: newest, ranking_configuration: config, rank: 2, score: 1)
            RankedItem.create!(item: books_books(:clash), ranking_configuration: config, rank: 9, score: 1)

            fetch(author.id)
            books = json[:data][:records].find { |record| record[:id] == king.id }[:books]

            # The newest book has the highest id, so ordering by id would put it last.
            assert_equal [newest.id, books_books(:clash).id, books_books(:got).id], books.map { |book| book[:id] }
            assert_equal [2, 9, nil], books.map { |book| book[:rank] }
          end

          test "a read-scope token can list and get" do
            list(token: ApiTokenSecrets::ADMIN_READ)
            assert_response :success
            fetch(@pending.id, token: ApiTokenSecrets::ADMIN_READ)
            assert_response :success
          end

          test "a token without admin scopes is a 403" do
            list(token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
            fetch(@pending.id, token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end
        end
      end
    end
  end
end
