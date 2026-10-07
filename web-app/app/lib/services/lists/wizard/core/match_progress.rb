# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Called by every row job after it saves its row. Under the list's row
        # lock: write progress, or, once no row is pending and the step is not
        # yet completed, run the on-list-twice pass and complete the step. The
        # status check is inside the lock, so the pass runs once per bulk run.
        class MatchProgress
          STEP = "match"

          # run_id is the match generation of a full-match row job; progress
          # from a superseded run is dropped. Single-row re-matches pass none.
          def self.call(list:, single_row: false, run_id: nil)
            new(list, single_row, run_id).call
          end

          def initialize(list, single_row, run_id = nil)
            @list = list
            @single_row = single_row
            @run_id = run_id
          end

          def call
            @list.wizard_manager.fenced(STEP, @run_id) do
              # Counted in SQL: no row is instantiated while the list is locked.
              # Rows with no wizard key (from before the wizard) are not counted.
              scope = @list.list_items
                .where("list_items.metadata->'wizard' IS NOT NULL")
                .where("COALESCE(list_items.metadata->'wizard'->>'bucket', '') <> 'removed'")
              total = scope.count
              pending = scope.where("list_items.metadata->'wizard'->>'bucket' = 'pending'").count
              manager = @list.wizard_manager

              if pending.zero?
                if manager.step_status(STEP) != "completed"
                  OnListTwice.call(list: @list)
                  manager.update_step_status!(step: STEP, status: "completed", progress: 100,
                    metadata: {"total_items" => total, "processed_items" => total, "completed_at" => Time.current.iso8601})
                elsif @single_row
                  OnListTwice.call(list: @list)
                end
              elsif !@single_row
                decided = total - pending
                manager.update_step_status!(step: STEP, status: "running", progress: decided * 100 / total,
                  metadata: {"total_items" => total, "processed_items" => decided})
              end
            end
          end
        end
      end
    end
  end
end
