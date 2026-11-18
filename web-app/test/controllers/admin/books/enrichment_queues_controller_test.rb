require "test_helper"

module Admin
  module Books
    class EnrichmentQueuesControllerTest < ActionDispatch::IntegrationTest
      include SqlCapture

      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @book = books_books(:got)
        ::EnrichmentQueue::FillJob.jobs.clear
      end

      # Fake-mode jobs live in a process-wide array: leave it empty for whichever test runs next.
      teardown { ::EnrichmentQueue::FillJob.jobs.clear }

      def make_request(book, status:, kind: "books.origin", **attrs)
        ::EnrichmentRequest.create!({enrichable: book, kind: kind, reason: "missing", status: status}.merge(attrs))
      end

      test "index is 200 for an admin with no rows" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queues_path
        assert_response :success
      end

      test "index is 200 with rows in several statuses" do
        make_request(@book, status: :pending)
        make_request(books_books(:clash), status: :done, resolved_at: Time.current, outcome: "applied")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queues_path
        assert_response :success
      end

      test "index redirects unauthenticated users" do
        get admin_books_enrichment_queues_path
        assert_redirected_to books_root_path
      end

      test "show origin is 200" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queue_path("origin")
        assert_response :success
      end

      test "show of an unknown type is 404" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queue_path("nope")
        assert_response :not_found
      end

      test "show with status and via filters is 200" do
        make_request(@book, status: :done, resolved_at: Time.current, resolved_via: :api, resolved_by: @admin, outcome: "applied")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queue_path("origin", status: "done", via: "api")
        assert_response :success
      end

      test "show falls back to pending for an unknown status" do
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queue_path("origin", status: "bogus")
        assert_response :success
      end

      test "show lists only the rows of its own type and status" do
        pending = make_request(@book, status: :pending)
        make_request(books_books(:clash), status: :done, resolved_at: Time.current)
        make_request(books_books(:war_and_peace), status: :pending, kind: "books.categories")
        sign_in_as(@admin, stub_auth: true)
        get admin_books_enrichment_queue_path("origin")
        assert_response :success
        assert_equal [pending.id.to_s], css_select("[data-testid=request-row]").map { |row| row["data-request-id"] }
      end

      test "show runs no more queries for 3 done rows than for 1" do
        sign_in_as(@admin, stub_auth: true)
        books = [@book, books_books(:clash), books_books(:war_and_peace)]
        make_request(books[0], status: :done, resolved_at: 1.hour.ago, resolved_by: @admin, resolved_via: :api, outcome: "applied")
        get admin_books_enrichment_queue_path("origin", status: "done") # warm caches
        one = capture_sql { get admin_books_enrichment_queue_path("origin", status: "done") }.size

        make_request(books[1], status: :done, resolved_at: 2.hours.ago, resolved_by: @admin, resolved_via: :api, outcome: "applied")
        make_request(books[2], status: :done, resolved_at: 3.hours.ago, resolved_by: users(:regular_user), resolved_via: :api, outcome: "applied")
        three = capture_sql { get admin_books_enrichment_queue_path("origin", status: "done") }.size

        assert_operator three, :<=, one
      end

      test "fill queues the fill job and redirects to the index" do
        sign_in_as(@admin, stub_auth: true)
        Sidekiq::Testing.fake! do
          assert_difference -> { ::EnrichmentQueue::FillJob.jobs.size }, 1 do
            post fill_admin_books_enrichment_queue_path("origin"), params: {scope: "ranked", limit: "50"}
          end
          assert_equal ["books.origin", "ranked", 50], ::EnrichmentQueue::FillJob.jobs.last["args"]
        end
        assert_redirected_to admin_books_enrichment_queues_path
        assert flash[:notice].present?
      end

      test "fill with a blank limit queues nil" do
        sign_in_as(@admin, stub_auth: true)
        Sidekiq::Testing.fake! do
          post fill_admin_books_enrichment_queue_path("categories"), params: {scope: "all", limit: ""}
          assert_equal ["books.categories", "all", nil], ::EnrichmentQueue::FillJob.jobs.last["args"]
        end
      end

      test "fill with an unknown scope or a bad limit queues nothing" do
        sign_in_as(@admin, stub_auth: true)
        Sidekiq::Testing.fake! do
          assert_no_difference -> { ::EnrichmentQueue::FillJob.jobs.size } do
            post fill_admin_books_enrichment_queue_path("origin"), params: {scope: "everything", limit: "5"}
            assert_redirected_to admin_books_enrichment_queues_path
            assert flash[:alert].present?

            ["0", "-3", "abc", "2.5"].each do |limit|
              post fill_admin_books_enrichment_queue_path("origin"), params: {scope: "ranked", limit: limit}
              assert_redirected_to admin_books_enrichment_queues_path
              assert flash[:alert].present?, "limit #{limit.inspect} should be refused"
            end
          end
        end
      end

      test "fill of an unknown type is 404" do
        sign_in_as(@admin, stub_auth: true)
        post fill_admin_books_enrichment_queue_path("nope"), params: {scope: "ranked"}
        assert_response :not_found
      end

      test "requeue makes a done row pending and goes back to the type's page" do
        row = make_request(@book, status: :done, resolved_at: Time.current, outcome: "applied", note: "x")
        sign_in_as(@admin, stub_auth: true)
        post admin_books_requeue_enrichment_request_path(row)
        assert_redirected_to admin_books_enrichment_queue_path("origin")
        assert flash[:notice].present?
        assert row.reload.pending?
        assert_nil row.outcome
      end

      test "requeue of a claimed row refuses and changes nothing" do
        row = make_request(@book, status: :claimed, lease_token: "t", lease_expires_at: 10.minutes.from_now)
        sign_in_as(@admin, stub_auth: true)
        post admin_books_requeue_enrichment_request_path(row)
        assert_redirected_to admin_books_enrichment_queue_path("origin")
        assert flash[:alert].present?
        assert row.reload.claimed?
      end

      test "requeue of a row of another domain is 404" do
        row = make_request(@book, status: :done, kind: "music.other", resolved_at: Time.current)
        sign_in_as(@admin, stub_auth: true)
        post admin_books_requeue_enrichment_request_path(row)
        assert_response :not_found
        assert row.reload.done?
      end

      test "a viewer cannot fill or requeue" do
        row = make_request(@book, status: :done, resolved_at: Time.current)
        sign_in_as(@viewer, stub_auth: true)
        Sidekiq::Testing.fake! do
          assert_no_difference -> { ::EnrichmentQueue::FillJob.jobs.size } do
            post fill_admin_books_enrichment_queue_path("origin"), params: {scope: "ranked"}
          end
        end
        assert_redirected_to books_root_path

        post admin_books_requeue_enrichment_request_path(row)
        assert_redirected_to books_root_path
        assert row.reload.done?
      end

      test "index has no links trapped in a frame" do
        assert_no_frame_trapped_links_for admin_books_enrichment_queues_path
      end

      test "show has no links trapped in a frame" do
        make_request(@book, status: :pending)
        assert_no_frame_trapped_links_for admin_books_enrichment_queue_path("origin")
      end

      private

      def assert_no_frame_trapped_links_for(path)
        sign_in_as(@admin, stub_auth: true)
        assert_no_frame_trapped_links(path)
      end
    end
  end
end
