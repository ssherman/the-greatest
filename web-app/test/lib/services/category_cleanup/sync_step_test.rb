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

      test "never deletes a new category that has no links yet" do
        mark_decided(place("Georgia"))
        empty = place("Brand New Place", links: 0)

        SyncStep.call

        refute empty.reload.deleted?
        assert CategoryCleanupDecision.where(category: empty).none?
      end

      test "retries categories whose only decisions failed or went stale" do
        mark_decided(place("Georgia"))
        failed = place("secrets", links: 1)
        CategoryCleanupDecision.create!(category: failed, run: "old", stage: "rules", action: :rename, new_name: "Secrets",
          decided_by: :rule, status: :failed, category_snapshot: CategoryCleanupDecision.snapshot_of(failed))

        result = SyncStep.call

        assert_operator result.data[:new_categories], :>=, 1
        assert_equal "Secrets", failed.reload.name
      end

      test "ignores categories with a proposed, applied or rejected decision" do
        mark_decided(place("Georgia"))
        pending = place("Pending Place")
        CategoryCleanupDecision.create!(category: pending, run: "old", stage: "rules", action: :keep,
          decided_by: :ai, status: :proposed, category_snapshot: CategoryCleanupDecision.snapshot_of(pending))

        SyncStep.call

        assert_equal ["old"], CategoryCleanupDecision.where(category: pending).pluck(:run)
      end

      test "applies a rename and reports the result shape" do
        mark_decided(place("Georgia"))
        lower = ::Books::Category.create!(name: "secrets", category_type: :subject)
        ::Books::Book.order(:id).limit(1).each { |book| CategoryItem.create!(category: lower, item: book) }

        result = SyncStep.call

        assert_equal "Secrets", lower.reload.name
        assert_equal [:applied, :decisions, :new_categories], result.data.keys.sort
        assert_operator result.data[:new_categories], :>=, 1
        assert_operator result.data[:decisions], :>=, 1
      end
    end
  end
end
