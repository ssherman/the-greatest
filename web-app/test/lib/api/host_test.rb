require "test_helper"

module Api
  class HostTest < ActiveSupport::TestCase
    test "base_url is https on the configured host for the current domain" do
      Current.domain = :books
      assert_equal "https://dev-new.thegreatestbooks.org", Host.base_url

      Current.domain = :music
      assert_equal "https://dev.thegreatestmusic.org", Host.base_url
    end

    test "an explicit domain wins over Current" do
      Current.domain = :books
      assert_equal "https://dev.thegreatest.games", Host.base_url(:games)
    end

    test "a comma-separated domain setting uses its first host" do
      Rails.application.config.stubs(:domains).returns(books: "a.example.org,b.example.org")

      assert_equal "https://a.example.org", Host.base_url(:books)
    end

    test "no current domain falls back to books, the same default the site uses" do
      Current.domain = nil
      assert_equal "https://dev-new.thegreatestbooks.org", Host.base_url
    end
  end
end
