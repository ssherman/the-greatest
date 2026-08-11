require "test_helper"

module Reviews
  class PurgeCachedPageJobTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
    end

    test "purges the canonical book url" do
      expected = "https://#{Rails.application.config.domains[:books]}/book/#{@book.slug}"
      service = mock("purge_service")
      service.expects(:purge_urls).with(:books, [expected]).returns({success: true})
      Cloudflare::PurgeService.expects(:new).returns(service)

      with_purge_token { PurgeCachedPageJob.new.perform("Books::Book", @book.id) }
    end

    # Without this guard every review write on a developer machine raises,
    # because Cloudflare::Configuration#initialize demands the token.
    #
    # Explicitly clears the token rather than assuming it's already absent --
    # this machine's own .env carries a real CLOUDFLARE_CACHE_PURGE_TOKEN for
    # manual purge testing, so relying on ambient state made this test flaky.
    test "does nothing when no cloudflare token is configured" do
      Cloudflare::PurgeService.expects(:new).never

      assert_nothing_raised do
        without_purge_token { PurgeCachedPageJob.new.perform("Books::Book", @book.id) }
      end
    end

    test "does nothing for a reviewable type with no public page" do
      Cloudflare::PurgeService.expects(:new).never

      with_purge_token { PurgeCachedPageJob.new.perform("Music::Album", 1) }
    end

    test "does nothing when the record no longer exists" do
      Cloudflare::PurgeService.expects(:new).never

      with_purge_token { PurgeCachedPageJob.new.perform("Books::Book", 0) }
    end

    test "does nothing when the book has no slug" do
      # slug is NOT NULL at the DB level (see db/schema.rb), so update_columns
      # can't set it to nil -- an empty string exercises the job's
      # slug.blank? guard the same way without violating that constraint.
      book = Books::Book.create!(title: "Slugless")
      book.update_columns(slug: "")
      Cloudflare::PurgeService.expects(:new).never

      with_purge_token { PurgeCachedPageJob.new.perform("Books::Book", book.id) }
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
