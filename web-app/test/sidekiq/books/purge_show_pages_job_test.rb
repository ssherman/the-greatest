require "test_helper"

class Books::PurgeShowPagesJobTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @author = books_authors(:tolstoy)
  end

  def with_token(value)
    original = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
    ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = value
    yield
  ensure
    ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = original
  end

  test "purges the canonical book and author pages in one request" do
    host = Rails.application.config.domains[:books]
    service = mock("purge_service")
    service.expects(:purge_urls).with(:books, ["https://#{host}/book/#{@book.slug}", "https://#{host}/author/#{@author.slug}"])
      .returns({success: true})
    Cloudflare::PurgeService.expects(:new).returns(service)

    with_token("test-token") { Books::PurgeShowPagesJob.new.perform([@book.id], [@author.id]) }
  end

  test "does nothing without a Cloudflare token, or with nothing left to purge" do
    Cloudflare::PurgeService.expects(:new).never

    with_token(nil) { Books::PurgeShowPagesJob.new.perform([@book.id], [@author.id]) }
    with_token("test-token") { Books::PurgeShowPagesJob.new.perform([-1], []) }
  end
end
