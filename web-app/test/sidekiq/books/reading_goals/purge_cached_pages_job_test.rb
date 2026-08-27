require "test_helper"

module Books
  module ReadingGoals
    class PurgeCachedPagesJobTest < ActiveSupport::TestCase
      setup do
        @urls = ["https://books.test/reading_goals/1"]
      end

      test "purges the given URLs in the Books zone" do
        service = mock("purge_service")
        service.expects(:purge_urls).with(:books, @urls).returns(success: true)
        Cloudflare::PurgeService.expects(:new).returns(service)

        with_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
      end

      test "does nothing without a token before constructing Configuration" do
        Cloudflare::Configuration.expects(:new).never
        Cloudflare::PurgeService.expects(:new).never

        assert_nothing_raised do
          without_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
        end
      end

      test "does nothing with a blank domain or URL list" do
        Cloudflare::PurgeService.expects(:new).never

        with_purge_token do
          PurgeCachedPagesJob.new.perform("", @urls)
          PurgeCachedPagesJob.new.perform("books", [])
        end
      end

      test "chunks URL purges at 100 URLs" do
        urls = Array.new(201) { |index| "https://books.test/reading_goals/#{index}" }
        service = mock("purge_service")
        service.expects(:purge_urls).with(:books, urls.first(100)).returns(success: true)
        service.expects(:purge_urls).with(:books, urls.slice(100, 100)).returns(success: true)
        service.expects(:purge_urls).with(:books, urls.last(1)).returns(success: true)
        Cloudflare::PurgeService.expects(:new).returns(service)

        with_purge_token { PurgeCachedPagesJob.new.perform("books", urls) }
      end

      test "raises when a purge fails so Sidekiq retries it" do
        service = mock("purge_service")
        service.expects(:purge_urls).with(:books, @urls)
          .returns(success: false, error: "Cloudflare unavailable")
        Cloudflare::PurgeService.expects(:new).returns(service)

        error = assert_raises(PurgeCachedPagesJob::PurgeError) do
          with_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
        end

        assert_equal "Cloudflare unavailable", error.message
      end

      test "perform_async stores only JSON-native arguments" do
        Sidekiq::Testing.fake! do
          PurgeCachedPagesJob.perform_async("books", @urls)

          assert_equal ["books", @urls], PurgeCachedPagesJob.jobs.last.fetch("args")
        end
      end

      private

      def with_purge_token
        with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") { yield }
      end

      def without_purge_token
        with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => nil) { yield }
      end
    end
  end
end
