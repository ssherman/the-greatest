require "test_helper"

module Services
  module CategoryCleanup
    class SyncStepTest < ActiveSupport::TestCase
      def place(name, links: 1)
        record = ::Books::Category.create!(name: name, category_type: :location)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def mark_decided(category)
        CategoryCleanupDecision.create!(category: category, run: "main", stage: "locations_head", action: :keep,
          decided_by: :ai, status: :applied, category_snapshot: CategoryCleanupDecision.snapshot_of(category))
      end

      test "does nothing before any cleanup has been applied" do
        place("georgia")
        assert SyncStep.call.data[:skipped]
        assert CategoryCleanupDecision.none?
      end

      test "merges an incoming twin into the existing category and applies it" do
        existing = place("Georgia", links: 1)
        mark_decided(existing)
        incoming = place("georgia", links: 2)

        result = SyncStep.call

        assert result.success?
        assert_equal existing, incoming.reload.merged_into
      end

      test "leaves an incoming category the rules can't improve undecided" do
        mark_decided(place("Georgia"))
        fresh = place("Brand New Place")

        SyncStep.call

        assert CategoryCleanupDecision.where(category: fresh).none?
        refute fresh.reload.deleted?
      end
    end
  end
end
