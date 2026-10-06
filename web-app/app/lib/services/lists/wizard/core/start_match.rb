# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: one job per row that is replaceable or stuck pending. Every row is
        # marked pending before any job is queued, so the last job to finish
        # (inline in tests, or under Sidekiq) is the one that completes the step.
        class StartMatch
          STEP = "match"

          # run_id is the generation the job was started with. A run that is no
          # longer current marks, writes and queues nothing (nil).
          def self.call(list:, run_id: nil)
            new(list, run_id).call
          end

          def initialize(list, run_id = nil)
            @list = list
            @run_id = run_id
          end

          def call
            # Marking and the step write share the lock that checks the run.
            rows = manager.fenced(STEP, @run_id) { mark_pending }
            return if rows.nil?

            if rows.empty?
              MatchProgress.call(list: @list, run_id: @run_id)
            else
              rows.each { |item| enqueue(item) }
            end
            rows.size
          rescue => e
            manager.fenced(STEP, @run_id) { manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message) }
            raise
          end

          private

          def manager = @list.wizard_manager

          def mark_pending
            rows = RowState.matchable(@list).sort_by { |item| [item.position || 0, item.id] }
            rows.each do |item|
              RowState.new(item).merge(RowState::PENDING)
              RowState.unlink(item)
              item.save!
            end
            manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0})
            rows
          end

          def enqueue(item)
            if @run_id
              ::Lists::Wizard::MatchRowJob.perform_async(item.id, false, 1, @run_id)
            else
              ::Lists::Wizard::MatchRowJob.perform_async(item.id)
            end
          end
        end
      end
    end
  end
end
