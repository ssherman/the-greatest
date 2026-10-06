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

          def self.call(list:)
            new(list).call
          end

          def initialize(list)
            @list = list
          end

          def call
            rows = RowState.matchable(@list).sort_by { |item| [item.position || 0, item.id] }
            rows.each do |item|
              RowState.new(item).merge(RowState::PENDING)
              RowState.unlink(item)
              item.save!
            end
            @list.wizard_manager.write_step!(step: STEP, status: "running", progress: 0, error: nil,
              metadata: {"total_items" => rows.size, "processed_items" => 0})

            if rows.empty?
              MatchProgress.call(list: @list)
            else
              rows.each { |item| ::Lists::Wizard::MatchRowJob.perform_async(item.id) }
            end
            rows.size
          rescue => e
            @list.wizard_manager.write_step!(step: STEP, status: "failed", progress: 0, error: e.message)
            raise
          end
        end
      end
    end
  end
end
