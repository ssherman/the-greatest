# frozen_string_literal: true

require "test_helper"

module Recommendations
  class PathsTest < ActiveSupport::TestCase
    test "keys follow the spec's five shapes" do
      assert_equal "recommendations/books/interactions/2026-10-09.csv.gz", Paths.interactions(:books, "2026-10-09")
      assert_equal "recommendations/books/interactions/latest", Paths.interactions_latest("books")
      assert_equal "recommendations/books/model/2026-10-09.csv.gz", Paths.model(:books, "2026-10-09")
      assert_equal "recommendations/books/model/2026-10-09.json", Paths.model_manifest(:books, "2026-10-09")
      assert_equal "recommendations/books/model/latest", Paths.model_latest(:books)
    end

    test "names with a path separator are refused" do
      assert_raises(ArgumentError) { Paths.interactions(:books, "../x") }
      assert_raises(ArgumentError) { Paths.model(:books, "a/b") }
    end
  end
end
