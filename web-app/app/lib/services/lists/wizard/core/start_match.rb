# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: every row that is replaceable or stuck
        # pending is marked pending, then matched one at a time in this job, in
        # list order. Open Library answers one /resolve at a time and turns the
        # rest away busy, so rows matched side by side by several jobs crowd each
        # other out and fail; one after another, a row fails only when Open
        # Library itself does not answer.
        class StartMatch
          STEP = "match"
          # How long a row whose source failed waits before it is matched again
          # (Open Library busy with another caller, or briefly down). After the
          # last wait the Match pauses: the step fails, this row and the rest
          # stay pending, and the admin's "Try again" carries on. About 13
          # minutes in all, inside the 30-minute stall rule.
          SOURCE_RETRY_DELAYS = [15, 30, 60, 120, 240, 300].freeze

          # run_id is the generation the job was started with. A run that is no
          # longer current marks, writes and matches nothing (nil).
          def self.call(list:, run_id: nil, sleeper: nil)
            new(list, run_id, sleeper).call
          end

          def initialize(list, run_id = nil, sleeper = nil)
            @list = list
            @run_id = run_id
            @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          end

          def call
            # Marking and the step write share the lock that checks the run.
            rows = manager.fenced(STEP, @run_id) { resumed? ? pending_rows : mark_pending }
            return if rows.nil?

            if rows.empty?
              MatchProgress.call(list: @list, run_id: @run_id)
            else
              adapter = Adapters.for(@list)
              rows.each do |item|
                break unless manager.run_current?(STEP, @run_id)
                break unless match(item, adapter)
              end
            end
            rows.size
          rescue => e
            manager.fenced(STEP, @run_id) { manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message) }
            raise
          end

          private

          def manager = @list.wizard_manager

          # false when the Match paused on this row.
          def match(item, adapter)
            attempt = 1
            loop do
              row = MatchRow.new(item, adapter, false, attempt, @run_id, serial: true)
              return true unless row.call == :retry

              delay = SOURCE_RETRY_DELAYS[attempt - 1]
              return pause(item, row.failed_sources) if delay.nil?

              @sleeper.call(delay)
              attempt += 1
            end
          end

          def pause(item, sources)
            title = item.metadata&.dig("title")
            manager.fenced(STEP, @run_id) do
              manager.write_step!(step: STEP, status: "failed",
                error: "#{sources.join(", ")} did not answer for \"#{title}\", so matching paused. " \
                  "Rows already matched are kept; Try again to carry on.")
            end
            false
          end

          # The same run started again (Sidekiq pushes a running job back to
          # the queue when it shuts down for a deploy): it has already marked
          # its rows, and the ones it decided are not matched twice.
          def resumed?
            @run_id.present? && manager.step_metadata(STEP)["marked_run_id"] == @run_id
          end

          def pending_rows
            @list.list_items.reload
              .select { |item| RowState.new(item).present? && RowState.new(item).pending? }
              .sort_by { |item| [item.position || 0, item.id] }
          end

          def mark_pending
            rows = RowState.matchable(@list).sort_by { |item| [item.position || 0, item.id] }
            rows.each do |item|
              RowState.new(item).merge(RowState::PENDING)
              RowState.unlink(item)
              item.save!
            end
            manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0, "marked_run_id" => @run_id})
            rows
          end
        end
      end
    end
  end
end
