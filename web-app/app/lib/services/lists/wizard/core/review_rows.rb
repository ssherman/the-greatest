# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The Review table's rows (spec §4): the filtered rows in list order, each
        # with its current decision and the top candidates the finder weighed.
        class ReviewRows
          FILTERS = %w[flagged all create ai].freeze
          MAX_CANDIDATES = 6

          Row = Struct.new(:item, :state, :decision, :candidates, keyword_init: true)
          CandidateView = Struct.new(:record_id, :record_type, :external_key, :title, :creators, :year, :list_count, keyword_init: true) do
            def local? = !record_id.nil?
          end

          attr_reader :filter

          def initialize(list:, filter: "flagged", listable_includes: [])
            @list = list
            @filter = FILTERS.include?(filter) ? filter : FILTERS.first
            @listable_includes = listable_includes
          end

          def rows
            items = @list.list_items.includes(listable: @listable_includes).order(:position, :id).to_a
            pairs = items.map { |item| [item, RowState.new(item)] }.select { |_item, state| keep?(state) }
            decisions = ::MatchDecision.where(id: pairs.filter_map { |_item, state| state.match_decision_id }).index_by(&:id)
            pairs.map do |item, state|
              decision = decisions[state.match_decision_id]
              Row.new(item: item, state: state, decision: decision, candidates: candidates_for(decision))
            end
          end

          private

          def keep?(state)
            return false if state.removed?

            case filter
            when "all" then true
            when "create" then state.bucket == "create"
            when "ai" then state.decided_by == "ai"
            else state.flagged?
            end
          end

          def candidates_for(decision)
            Array(decision&.candidates).first(MAX_CANDIDATES).map do |snapshot|
              evidence = snapshot["evidence"] || {}
              CandidateView.new(
                record_id: snapshot["record_id"], record_type: snapshot["record_type"], external_key: snapshot["external_key"],
                title: evidence["title"], creators: Array(evidence["creators"]),
                year: evidence["year"], list_count: evidence["list_count"]
              )
            end
          end
        end
      end
    end
  end
end
