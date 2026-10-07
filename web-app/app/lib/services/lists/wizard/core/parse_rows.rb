# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §2 and §8: pasted content becomes pending rows.
        # A re-parse replaces rows that are neither settled nor linked to a book and never re-adds a row whose
        # normalized title and creators equal a kept row's. Nothing is deleted
        # until the parser has succeeded.
        class ParseRows
          STEP = "parse"
          BATCH_SIZE = 100

          def self.call(list:, adapter:, run_id: nil)
            new(list: list, adapter: adapter, run_id: run_id).call
          end

          # run_id is the generation the job was started with: every write and
          # the row replacement happen only while the step still carries it.
          def initialize(list:, adapter:, run_id: nil)
            @list = list
            @adapter = adapter
            @run_id = run_id
          end

          def call
            return unless write(status: "running", progress: 0, error: nil)
            return fail!("Paste the list before parsing.") if @list.raw_content.blank?

            rows = batch_mode? ? parse_in_batches : parse_once
            return if rows.nil?
            return fail!("The parser found no books") if rows.empty?

            replace_rows(rows)
          rescue => e
            fail!(e.message)
            raise
          end

          private

          def manager = @list.wizard_manager

          def batch_mode? = @list.wizard_state&.dig("batch_mode") == true

          def parse_once
            result = @adapter.parse(@list)
            return fail!(Array(result.errors).join(", ").presence || "Parsing failed") unless result.success?

            result.data
          end

          # As BaseWizardParseListJob#perform_batched_parse: batches of 100
          # non-blank lines, one parser call each, positions strictly in order.
          # A failed batch fails the whole parse before anything is deleted.
          def parse_in_batches
            lines = @list.simplified_content.to_s.split("\n").reject { |line| line.strip.empty? }
            batches = lines.each_slice(BATCH_SIZE).map { |slice| slice.join("\n") }
            rows = []
            batches.each_with_index do |content, index|
              result = @adapter.parse(@list, content: content)
              unless result.success?
                return fail!("Parsing failed on batch #{index + 1}: #{Array(result.errors).join(", ")}")
              end

              rows.concat(result.data)
              return nil unless write(status: "running", progress: (index + 1) * 100 / batches.size,
                metadata: {"batches_completed" => index + 1, "total_batches" => batches.size, "processed_items" => rows.size})
            end
            @sequential = true
            rows
          end

          def fail!(message)
            write(status: "failed", progress: 0, error: message)
            nil
          end

          # One step write, only while this run is current. nil when it is not.
          def write(**attributes)
            manager.fenced(STEP, @run_id) do
              manager.write_step!(step: STEP, **attributes)
              true
            end
          end

          # The check, the replacement and the completed status share one lock:
          # a run superseded during the slow parse changes nothing. nil then.
          def replace_rows(rows)
            ::ActiveRecord::Base.transaction do
              manager.fenced(STEP, @run_id) { replace_rows_locked(rows) }
            end
          end

          def replace_rows_locked(rows)
            ::ListItem.where(id: RowState.replaceable(@list).map(&:id)).destroy_all
            kept = @list.list_items.includes(listable: @adapter.listable_includes).map { |item| @adapter.row_signature(item) }.to_set

            now = Time.current
            inserts = []
            rows.each_with_index do |row, index|
              next if kept.include?(@adapter.signature(row["title"], row["authors"]))

              inserts << {
                list_id: @list.id, listable_type: @adapter.listable_type, listable_id: nil, verified: false,
                position: position_for(row, index), metadata: clean(row).merge(RowState::KEY => RowState::INITIAL),
                created_at: now, updated_at: now
              }
            end
            ::ListItem.insert_all(inserts) if inserts.any?
            @list.touch
            added = inserts.size
            manager.write_step!(step: STEP, status: "completed", progress: 100,
              metadata: {"total_items" => added, "processed_items" => added, "parsed_at" => Time.current.iso8601})
            added
          end

          def position_for(row, index)
            return index + 1 if @sequential

            rank = row["rank"]
            (rank.is_a?(Integer) && rank.positive?) ? rank : index + 1
          end

          # jsonb cannot store a NUL byte.
          def clean(row)
            row.transform_values do |value|
              case value
              when String then value.delete("\u0000")
              when Array then value.map { |entry| entry.is_a?(String) ? entry.delete("\u0000") : entry }
              else value
              end
            end
          end
        end
      end
    end
  end
end
