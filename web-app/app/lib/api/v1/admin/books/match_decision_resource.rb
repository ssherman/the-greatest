# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A match decision as an admin API client sees it: one row of the review
        # queue. `detail` adds the stored query snapshot and the candidates, each
        # with `current`, the live summary of the record it names (from
        # FinderBase#summarize_all, keyed [record_type, record_id] in `summaries`)
        # or nil when it names no record of ours or the record is gone. Key order
        # here IS the order in config/api/v1/admin_openapi.yaml.
        class MatchDecisionResource
          def initialize(decision, summaries: {}, detail: false)
            @decision = decision
            @summaries = summaries
            @detail = detail
          end

          # The summaries a decision's candidates need, one finder call per
          # record type: {[record_type, record_id] => summary}.
          def self.summaries_for(decisions)
            snapshots = decisions.flat_map(&:candidates)
            snapshots.group_by { |candidate| candidate["record_type"] }.each_with_object({}) do |(type, rows), summaries|
              entry = ::DataImporters::FinderRegistry.entry_for_model(type)
              next unless entry

              ids = rows.filter_map { |row| row["record_id"] }.uniq
              found = entry.model_class.where(id: ids).includes(:identifiers, *entry.preloads).to_a
              entry.finder_class.new.summarize_all(found).each { |id, summary| summaries[[type, id]] = summary }
            end
          end

          def to_h
            {
              id: @decision.id,
              entity: entity,
              finder: @decision.finder,
              outcome: @decision.outcome,
              confidence: @decision.confidence,
              decided_by: @decision.decided_by,
              reason: @decision.reason,
              created_at: @decision.created_at,
              subject: reference(@decision.subject),
              record: reference(@decision.record),
              review: review
            }.tap do |hash|
              next unless @detail

              hash[:query] = @decision.query
              hash[:selected_index] = @decision.selected_index
              hash[:candidates] = @decision.candidates.map { |candidate| candidate.merge("current" => @summaries[[candidate["record_type"], candidate["record_id"]]]) }
            end
          end

          private

          def entity = ::DataImporters::FinderRegistry.entry(@decision.finder)&.label&.parameterize

          def reference(record)
            return nil unless record

            {id: record.id, type: record.class.name, label: record.try(:title) || record.try(:name)}
          end

          def review
            return nil unless @decision.reviewed_at

            {
              reviewed_at: @decision.reviewed_at,
              reviewed_by: @decision.reviewed_by&.email,
              reviewed_via: @decision.reviewed_via,
              note: @decision.review_note,
              verdict: @decision.verdict
            }
          end
        end
      end
    end
  end
end
