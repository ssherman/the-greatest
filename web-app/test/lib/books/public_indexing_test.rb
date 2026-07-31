require "test_helper"

module Books
  class PublicIndexingTest < ActiveSupport::TestCase
    test "is disabled by default" do
      ENV.delete("BOOKS_PUBLIC_INDEXING")
      refute Books::PublicIndexing.enabled?
    end

    test "is enabled only for the exact string true" do
      ENV["BOOKS_PUBLIC_INDEXING"] = "true"
      assert Books::PublicIndexing.enabled?
    ensure
      ENV.delete("BOOKS_PUBLIC_INDEXING")
    end

    test "is disabled for any other value" do
      ENV["BOOKS_PUBLIC_INDEXING"] = "1"
      refute Books::PublicIndexing.enabled?
    ensure
      ENV.delete("BOOKS_PUBLIC_INDEXING")
    end
  end
end
