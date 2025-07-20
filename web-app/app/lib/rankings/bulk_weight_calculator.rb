# frozen_string_literal: true

module Rankings
  class BulkWeightCalculator
    attr_reader :ranking_configuration, :results

    def initialize(ranking_configuration)
      @ranking_configuration = ranking_configuration
      @results = {
        processed: 0,
        updated: 0,
        errors: [],
        weights_calculated: []
      }
    end

    # Main entry point - calculates weights for all ranked lists
    def call
      ActiveRecord::Base.transaction do
        ranking_configuration.ranked_lists.includes(:list).find_each do |ranked_list|
          process_ranked_list(ranked_list)
        end
      end

      log_results
      results
    end

    # Process specific ranked list IDs only
    def call_for_ids(ranked_list_ids)
      ActiveRecord::Base.transaction do
        ranking_configuration.ranked_lists.where(id: ranked_list_ids).includes(:list).find_each do |ranked_list|
          process_ranked_list(ranked_list)
        end
      end

      log_results
      results
    end

    private

    def process_ranked_list(ranked_list)
      @results[:processed] += 1

      begin
        calculator = WeightCalculator.for_ranked_list(ranked_list)
        old_weight = ranked_list.weight
        new_weight = calculator.call

        if old_weight != new_weight
          @results[:updated] += 1
          @results[:weights_calculated] << {
            ranked_list_id: ranked_list.id,
            list_name: ranked_list.list.name,
            old_weight: old_weight,
            new_weight: new_weight,
            change: new_weight - (old_weight || 0)
          }
        end
      rescue => e
        @results[:errors] << {
          ranked_list_id: ranked_list.id,
          list_name: ranked_list.list.name,
          error: e.message
        }
        Rails.logger.error "Error calculating weight for RankedList #{ranked_list.id}: #{e.message}"
      end
    end

    def log_results
      Rails.logger.info "BulkWeightCalculator completed for RankingConfiguration #{ranking_configuration.id}"
      Rails.logger.info "Processed: #{@results[:processed]}, Updated: #{@results[:updated]}, Errors: #{@results[:errors].count}"

      if @results[:errors].any?
        Rails.logger.error "Errors encountered: #{@results[:errors].map { |e| e[:error] }.join(", ")}"
      end
    end
  end
end
