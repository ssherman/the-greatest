# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §6: one run per list, creating rows one after
        # another so a second book by a new author finds the author the first
        # one made. A failing row is flagged and the run goes on. Removed rows
        # are deleted at the end.
        class ImportRows
          STEP = "import"

          def self.call(list:, adapter:, run_id: nil)
            new(list, adapter, run_id).call
          end

          def initialize(list, adapter, run_id)
            @list = list
            @adapter = adapter
            @run_id = run_id
            @failed = 0
          end

          # nil when another run owns the step (it is running under a different
          # run_id): two Import runs never overlap.
          def call
            return nil unless claim

            rows = @list.list_items.ordered.to_a.select { |item| creatable?(item) }
            manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0, "failed_count" => 0})

            rows.each_with_index do |item, index|
              import_row(item)
              manager.write_step!(step: STEP, status: "running", progress: (index + 1) * 100 / rows.size,
                metadata: {"processed_items" => index + 1, "failed_count" => @failed})
            end

            delete_removed_rows
            manager.write_step!(step: STEP, status: "completed", progress: 100,
              metadata: {"total_items" => rows.size, "processed_items" => rows.size, "failed_count" => @failed,
                         "imported_at" => Time.current.iso8601})
            rows.size
          rescue => e
            manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message)
            raise
          end

          private

          def manager = @list.wizard_manager

          # Under the list's row lock: a step already running under another run
          # id belongs to that run. Otherwise this run takes it.
          def claim
            @list.with_lock do
              owner = manager.step_metadata(STEP)["run_id"]
              next false if manager.step_status(STEP) == "running" && owner.present? && owner != @run_id

              manager.update_step_status!(step: STEP, status: "running", progress: 0, error: nil,
                metadata: {"run_id" => @run_id || SecureRandom.uuid})
              true
            end
          end

          def creatable?(item)
            RowState.new(item).bucket == "create" && item.listable_id.nil?
          end

          def import_row(item)
            return unless ::ListItem.exists?(item.id)

            # Re-read: another run (a Sidekiq retry, a double start) may have
            # handled the row since this run listed it.
            item.reload
            return unless creatable?(item)

            found = @adapter.recheck(item)
            return link(item, found, "linked_existing", ["changed_since_match"]) if found

            link(item, @adapter.create(item), "created", [])
          rescue => e
            @failed += 1
            RowState.new(item).merge("import_error" => e.message.to_s.truncate(500)).flag!("import_failed")
          end

          def link(item, record, result, reasons)
            state = RowState.new(item)
            if RowState.holder_of(@list, record, except: item)
              state.merge("target_record_id" => record.id).flag!("on_list_twice")
              return
            end

            state.merge(
              "bucket" => "matched", "import_result" => result, "target_record_id" => record.id, "import_error" => nil,
              "reasons" => ((state.reasons - ["import_failed"]) + reasons).uniq,
              "settled" => true, "settled_at" => state.data["settled_at"] || Time.current.iso8601
            ).link!(record)
          end

          def delete_removed_rows
            ids = @list.list_items.reload.select { |item| RowState.new(item).removed? }.map(&:id)
            ::ListItem.where(id: ids).destroy_all
          end
        end
      end
    end
  end
end
