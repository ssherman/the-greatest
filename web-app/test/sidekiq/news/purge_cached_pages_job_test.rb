require "test_helper"

module News
  class PurgeCachedPagesJobTest < ActiveSupport::TestCase
    setup do
      @urls = ["https://example.com/news", "https://example.com/news/a-post"]
    end

    test "purges the given urls against the given domain's zone" do
      service = mock("purge_service")
      service.expects(:purge_urls).with(:books, @urls).returns({success: true})
      Cloudflare::PurgeService.expects(:new).returns(service)

      with_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
    end

    # Sidekiq round-trips arguments through JSON, so the domain arrives as a
    # String. Cloudflare::Configuration#zone_id raises ZoneNotFoundError unless
    # it is one of its four symbols.
    test "accepts the domain as a string and converts it for the zone lookup" do
      service = mock("purge_service")
      service.expects(:purge_urls).with(:music, @urls).returns({success: true})
      Cloudflare::PurgeService.expects(:new).returns(service)

      with_purge_token { PurgeCachedPagesJob.new.perform("music", @urls) }
    end

    # Without this guard every news write on a developer machine raises, because
    # Cloudflare::Configuration#initialize demands the token. Clears it
    # explicitly rather than assuming it is absent -- this machine's .env
    # carries a real one for manual purge testing.
    test "does nothing when no cloudflare token is configured" do
      Cloudflare::PurgeService.expects(:new).never

      assert_nothing_raised do
        without_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
      end
    end

    test "does nothing when given no urls" do
      Cloudflare::PurgeService.expects(:new).never

      with_purge_token { PurgeCachedPagesJob.new.perform("books", []) }
    end

    test "does nothing when given a blank domain" do
      Cloudflare::PurgeService.expects(:new).never

      with_purge_token { PurgeCachedPagesJob.new.perform("", @urls) }
    end

    # Cloudflare rejects a single-file purge carrying more than 100 URLs on this
    # plan, and PurgeService#purge_urls issues ONE request -- so an unchunked
    # batch of 101 fails as a whole and purges nothing, logged but never raised.
    test "splits a batch larger than cloudflare's per-request limit" do
      urls = Array.new(101) { |i| "https://example.com/news/post-#{i}" }
      service = mock("purge_service")
      service.expects(:purge_urls).with(:books, urls.first(100)).returns({success: true})
      service.expects(:purge_urls).with(:books, urls.last(1)).returns({success: true})
      Cloudflare::PurgeService.expects(:new).returns(service)

      with_purge_token { PurgeCachedPagesJob.new.perform("books", urls) }
    end

    test "sends a batch of exactly the limit as a single request" do
      urls = Array.new(100) { |i| "https://example.com/news/post-#{i}" }
      service = mock("purge_service")
      service.expects(:purge_urls).with(:books, urls).once.returns({success: true})
      Cloudflare::PurgeService.expects(:new).returns(service)

      with_purge_token { PurgeCachedPagesJob.new.perform("books", urls) }
    end

    # A purge that fails is not worth retrying forever: the page simply stays
    # cached until it expires, which is the pre-existing behaviour, and Sidekiq
    # retrying a raise here would re-purge every URL on each attempt.
    test "does not raise when a batch fails" do
      service = mock("purge_service")
      service.expects(:purge_urls).returns({success: false, error: "boom"})
      Cloudflare::PurgeService.expects(:new).returns(service)

      assert_nothing_raised do
        with_purge_token { PurgeCachedPagesJob.new.perform("books", @urls) }
      end
    end

    private

    def with_purge_token
      original = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test-token"
      yield
    ensure
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = original
    end

    def without_purge_token
      original = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
      ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      yield
    ensure
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = original
    end
  end
end
