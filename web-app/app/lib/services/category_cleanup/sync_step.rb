# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.5: until cutover the weekly sync keeps bringing new legacy
    # categories. Once a cleanup has been applied, each sync runs the rules
    # pass for categories no run has decided yet (failed or stale decisions don't count: those retry next week) (case/punctuation twins merge
    # into the existing vocabulary; renames and deletes follow the same rules)
    # and applies those rule decisions straight away. AI decisions are never
    # auto-applied; what the rules can't settle waits for the owner's next
    # propose. Every normal path returns a success Result: a failing step
    # blocks the whole weekly sync, and genuine exceptions propagate so the
    # sync loop reports them.
    class SyncStep
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        return result(skipped: true) unless ::CategoryCleanupDecision.applied.exists?

        new_ids = ::Books::Category.active
          .where(category_type: RulePass::TYPES)
          .where.not(id: ::CategoryCleanupDecision.where(status: %i[proposed applied rejected]).select(:category_id))
          .pluck(:id)
        return result(new_categories: 0) if new_ids.empty?

        # Random suffix: two syncs (or a retry) inside one second must not share a run.
        run = "sync-#{Time.current.utc.strftime("%Y%m%d%H%M%S")}-#{SecureRandom.hex(3)}"
        rules = RulePass.call(run: run, only_ids: new_ids, stage: "sync")
        applied = Applier.call(run: run, only_rules: true)
        result(new_categories: new_ids.size, decisions: rules.data[:decisions], applied: applied.data)
      end

      private

      def result(**data)
        Result.new(success?: true, data: data, errors: [])
      end
    end
  end
end
