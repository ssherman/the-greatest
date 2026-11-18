require "test_helper"

module Services
  module EnrichmentQueue
    class CarryOverTest < ActiveSupport::TestCase
      setup do
        @source = books_books(:war_and_peace)
        @target = books_books(:crime_and_punishment)
      end

      test "moves the source's rows and drops one the target already has" do
        moved = ::EnrichmentRequest.create!(enrichable: @source, kind: "books.origin", reason: "missing")
        ::EnrichmentRequest.create!(enrichable: @source, kind: "books.categories", reason: "missing")
        kept = ::EnrichmentRequest.create!(enrichable: @target, kind: "books.categories", reason: "missing", status: :done)
        result = CarryOver.call(source: @source, target: @target)
        assert result.success?
        assert_equal 1, result.data[:moved]
        assert_empty result.errors
        assert_equal @target, moved.reload.enrichable
        assert_equal [kept.id], ::EnrichmentRequest.where(enrichable: @target, kind: "books.categories").pluck(:id)
        assert_empty ::EnrichmentRequest.where(enrichable: @source).to_a
      end

      test "moves nothing and deletes nothing when the source has no rows" do
        kept = ::EnrichmentRequest.create!(enrichable: @target, kind: "books.origin", reason: "missing")
        result = CarryOver.call(source: @source, target: @target)
        assert result.success?
        assert_equal 0, result.data[:moved]
        assert_equal [kept.id], ::EnrichmentRequest.where(enrichable: @target).pluck(:id)
      end
    end
  end
end
