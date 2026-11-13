require "test_helper"

module Sitemaps
  class StaticPagesTest < ActiveSupport::TestCase
    setup { @source = Sitemaps::StaticPages.new(paths: %w[/ /a /b]) }

    test "key is pages" do
      assert_equal "pages", @source.key
    end

    test "count is the number of paths" do
      assert_equal 3, @source.count
    end

    test "entries honours offset and limit" do
      entries = @source.entries(offset: 1, limit: 1)
      assert_equal ["/a"], entries.map(&:path)
      assert_nil entries.first.lastmod
    end

    test "lastmod is nil" do
      assert_nil @source.lastmod
    end
  end
end
