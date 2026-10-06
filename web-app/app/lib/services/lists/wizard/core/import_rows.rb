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

          # nil when this run does not own the step: another run holds it, or a
          # newer run has replaced it (even a completed one), or a restart wiped
          # it. A run that is superseded midway stops before its next row.
          def call
            return nil unless claim

            rows = @list.list_items.ordered.to_a.select { |item| creatable?(item) }
            return nil unless write(status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0, "failed_count" => 0})

            rows.each_with_index do |item, index|
              return nil unless manager.run_current?(STEP, @run_id)

              import_row(item)
              return nil unless write(status: "running", progress: (index + 1) * 100 / rows.size,
                metadata: {"processed_items" => index + 1, "failed_count" => @failed})
            end

            manager.fenced(STEP, @run_id) do
              delete_removed_rows
              manager.write_step!(step: STEP, status: "completed", progress: 100,
                metadata: {"total_items" => rows.size, "processed_items" => rows.size, "failed_count" => @failed,
                           "imported_at" => Time.current.iso8601})
              rows.size
            end
          rescue => e
            write(status: "failed", progress: 0, error: e.message)
            raise
          end

          private

          def manager = @list.wizard_manager

          # One step write, only while this run is current. nil when it is not.
          def write(**attributes)
            manager.fenced(STEP, @run_id) do
              manager.write_step!(step: STEP, **attributes)
              true
            end
          end

          # Under the list's row lock. A run that carries an id must find that id
          # on the step, whatever the step's status: the controller wrote it when
          # it started this run, and anything else means a newer run or a restart.
          # A run with no id (a direct call) takes the step unless another run
          # is running it, and gives itself one so the checks above can follow it.
          def claim
            @list.with_lock do
              owner = manager.step_metadata(STEP)["run_id"]
              if @run_id
                unless owner == @run_id
                  Rails.logger.info("List wizard import run #{@run_id} for list #{@list.id} is superseded; skipping")
                  next false
                end
              elsif manager.step_status(STEP) == "running" && owner.present?
                next false
              else
                @run_id = SecureRandom.uuid
              end

              manager.update_step_status!(step: STEP, status: "running", progress: 0, error: nil,
                metadata: {"run_id" => @run_id})
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
