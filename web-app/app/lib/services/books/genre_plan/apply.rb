# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # `categories:genres:apply` (spec §5 step 7): validate, write the
      # decisions, apply them, then strip deleted genres from saved criteria.
      # Re-running after a complete or partial apply only re-runs the applier
      # and the cleaner, both idempotent; the plan's names no longer match the
      # live rows by then, so the validator and builder are skipped.
      class Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(plan:, assignments:)
          new(plan, assignments).call
        end

        def initialize(plan, assignments)
          @plan = plan
          @assignments = assignments
        end

        def call
          return failure(["no plan file at #{@plan.path}"]) unless @plan.exists?

          return failure(["the plan has no run name"]) if @plan.run.blank?

          other = ::CategoryCleanupDecision.for_run(@plan.run).where.not(stage: DecisionBuilder::STAGE).distinct.pluck(:stage)
          return failure(["run #{@plan.run.inspect} already has decisions from stage #{other.join(", ")}; use a new run name"]) if other.any?

          unassigned = 0
          rerun = decisions.exists?
          unless rerun
            validation = Validator.call(plan: @plan, assignments: @assignments)
            return failure(validation.errors) unless validation.success?

            unassigned = DecisionBuilder.call(plan: @plan, assignments: @assignments).data[:unassigned_split_books]
          end

          applier = ::Services::CategoryCleanup::Applier.call(run: @plan.run)
          deleted = decisions.applied.action_delete.pluck(:category_id)
          cleaned = CriteriaCleaner.call(deleted_ids: deleted).data
          Result.new(success?: true, data: {applier: applier.data, cleaned: cleaned, unassigned_split_books: unassigned, rerun: rerun}, errors: [])
        end

        private

        def decisions = ::CategoryCleanupDecision.for_run(@plan.run).where(stage: DecisionBuilder::STAGE)

        def failure(errors) = Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end
