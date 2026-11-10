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
