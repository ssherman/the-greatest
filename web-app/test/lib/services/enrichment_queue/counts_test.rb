require "test_helper"

module Services
  module EnrichmentQueue
    class CountsTest < ActiveSupport::TestCase
      test "counts every status, with zeros, and done rows by outcome" do
        kind = "books.test_type"
        ::EnrichmentRequest.create!(enrichable: books_books(:war_and_peace), kind: kind, reason: "missing")
        ::EnrichmentRequest.create!(enrichable: books_books(:crime_and_punishment), kind: kind, reason: "missing", status: :done, outcome: "applied")
        ::EnrichmentRequest.create!(enrichable: books_books(:got), kind: kind, reason: "missing", status: :done, outcome: "nothing_to_apply")
        ::EnrichmentRequest.create!(enrichable: books_books(:got), kind: "books.other", reason: "missing")

        counts = Counts.call(kind: kind)

        assert_equal %w[pending claimed submitted done skipped failed], counts[:statuses].keys
        assert_equal [1, 0, 0, 2, 0, 0], counts[:statuses].values
        assert_equal({"applied" => 1, "nothing_to_apply" => 1}, counts[:outcomes])
      end
    end
  end
end
