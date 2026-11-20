require "test_helper"

module Services
  module Books
    module Profiles
      class CachedUrlsTest < ActiveSupport::TestCase
        test "cached_urls returns the profile URL on every books host" do
          profile = books_profiles(:public_profile)
          original = Rails.application.config.domains[:books]
          Rails.application.config.domains[:books] = "books.test,, books-alt.test,books.test"

          assert_equal [
            "https://books.test/profiles/#{profile.id}",
            "https:// books-alt.test/profiles/#{profile.id}"
          ], CachedUrls.call(profile: profile)
        ensure
          Rails.application.config.domains[:books] = original
        end
      end
    end
  end
end
