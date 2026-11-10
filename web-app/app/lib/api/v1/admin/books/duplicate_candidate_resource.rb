# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A suspected duplicate pair as an admin API client sees it. `records` and
        # `summaries` come from Services::DuplicateCandidates::PairRecords for the
        # whole page, keyed by [item_type, id]; a record a merge or delete removed
        # is {id:, missing: true}. `detail` adds the fields that cost a query per
        # record, so only the single-pair endpoint asks for them. Key order here
        # IS the order in config/api/v1/admin_openapi.yaml. Root-anchor every
        # ::Books:: reference.
        class DuplicateCandidateResource
          DESCRIPTION_LIMIT = 500
          DETAIL_LIMIT = 25

          def initialize(pair, records:, summaries:, detail: false)
            @pair = pair
            @records = records
            @summaries = summaries
            @detail = detail
          end

          def to_h
            {
              id: @pair.id,
              item_type: @pair.item_type.demodulize.underscore,
              raised_by: @pair.source,
              status: @pair.status,
              occurrences: @pair.occurrences,
              evidence: @pair.evidence,
              created_at: @pair.created_at,
              resolution: resolution,
              records: [@pair.item_a_id, @pair.item_b_id].map { |id| record_hash(id) }
            }.tap { |hash| hash[:match_decision] = match_decision if @detail }
          end

          private

          def resolution
            return nil if @pair.pending?

            {
              resolved_at: @pair.resolved_at,
              resolved_by: @pair.resolved_by&.email,
              resolved_via: @pair.resolved_via,
              note: @pair.resolution_note
            }
          end

          def match_decision
            decision = @pair.match_decision
            return nil unless decision

            {id: decision.id, finder: decision.finder, outcome: decision.outcome,
             confidence: decision.confidence, reason: decision.reason}
          end

          def record_hash(id)
            record = @records[[@pair.item_type, id]]
            return {id: id, missing: true} unless record

            hash = {id: id, missing: false}.merge(@summaries[[@pair.item_type, id]] || {})
            hash.merge!(detail_for(record)) if @detail
            hash
          end

          def detail_for(record)
            if record.is_a?(::Books::Book)
              {
                subtitle: record.subtitle,
                alternate_titles: Array(record.alternate_titles),
                description: record.description&.slice(0, DESCRIPTION_LIMIT),
                lists: record.lists.order(:id).limit(DETAIL_LIMIT).map { |list| {id: list.id, name: list.name} }
              }
            else
              {
                alternate_names: Array(record.alternate_names),
                description: record.description&.slice(0, DESCRIPTION_LIMIT),
                books: record.books.includes(:primary_ranked_item).order(:id).limit(DETAIL_LIMIT).map do |book|
                  {id: book.id, title: book.title, rank: book.primary_ranked_item&.rank}
                end
              }
            end
          end
        end
      end
    end
  end
end
