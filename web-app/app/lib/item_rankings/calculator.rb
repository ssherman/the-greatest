# frozen_string_literal: true

module ItemRankings
  class Calculator
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    attr_reader :ranking_configuration

    def initialize(ranking_configuration)
      @ranking_configuration = ranking_configuration
    end

    def call
      # Get the median list count for this ranking configuration's type
      average_list_length = median_list_count

      # Prepare the lists and items
      lists = prepare_lists

      # Use the exponential strategy from weighted_list_rank gem
      exponential_strategy = WeightedListRank::Strategies::Exponential.new(
        exponent: ranking_configuration.exponent.to_f,
        bonus_pool_percentage: ranking_configuration.bonus_pool_percentage.to_f,
        average_list_length: average_list_length
      )

      # Calculate rankings
      ranking_context = WeightedListRank::RankingContext.new(exponential_strategy)
      ranking_data = ranking_context.rank(lists)

      # Update RankedItems in database
      update_ranked_items(ranking_data)

      Result.new(success?: true, data: ranking_data, errors: [])
    rescue => error
      Result.new(success?: false, data: nil, errors: [error.message])
    end

    protected

    # Subclasses should override these methods
    def list_type
      raise NotImplementedError, "Subclasses must implement list_type"
    end

    def item_type
      raise NotImplementedError, "Subclasses must implement item_type"
    end

    def median_list_count
      ::List.median_list_count(type: list_type)
    end

    private

    def prepare_lists
      # Get ranked lists with proper eager loading for performance
      ranked_lists = ranking_configuration.ranked_lists
        .joins(:list)
        .includes(:list)
        .includes(list: :list_items)
        .where(lists: {status: :active})
        .order(weight: :desc)

      lists = []
      ranked_lists.each do |ranked_list|
        items = prepare_items(ranked_list)
        list = ItemRankings::List.new(ranked_list.list_id, ranked_list.weight, items)
        lists << list
      end

      lists
    end

    def prepare_items(ranked_list)
      ranked_list.list.list_items.filter_map do |list_item|
        # Skip unverified items that don't have an actual listable
        next if list_item.listable_id.nil?

        score_penalty = calculate_score_penalty(ranked_list.list, list_item) if ranking_configuration.apply_list_dates_penalty?

        ItemRankings::Item.new(
          list_item.listable_id, # The actual item ID (book_id, album_id, etc)
          list_item.position,
          score_penalty
        )
      end
    end

    def calculate_score_penalty(list, list_item)
      return nil unless list.year_published.present?

      # Get the item to check its release year
      item = list_item.listable
      return nil unless item&.respond_to?(:release_year) && item.release_year.present?

      max_age = ranking_configuration.max_list_dates_penalty_age
      max_penalty_percentage = ranking_configuration.max_list_dates_penalty_percentage

      return nil if max_age.nil? || max_penalty_percentage.nil?

      year_difference = list.year_published - item.release_year

      penalty = if year_difference <= 0
        max_penalty_percentage / 100.0
      elsif year_difference > max_age
        nil
      else
        # Apply graduated penalty based on age difference
        p = ((max_age - year_difference).to_f / max_age) * max_penalty_percentage
        p / 100.0
      end

      (penalty == 0) ? nil : penalty
    end

    def update_ranked_items(ranking_data)
      # Wrap the entire operation in a transaction for atomicity
      ActiveRecord::Base.transaction do
        # Prepare ranked items data for upsert
        ranked_items_data = []

        ranking_data.each_with_index do |ranking, index|
          ranked_items_data << {
            ranking_configuration_id: ranking_configuration.id,
            item_id: ranking[:id],
            item_type: item_type,
            rank: index + 1,
            score: ranking[:total_score],
            created_at: Time.current
          }
        end

        if ranked_items_data.any?
          # Use upsert_all with the unique constraint (item_id, item_type, ranking_configuration_id)
          # Rails automatically handles updated_at
          RankedItem.upsert_all(
            ranked_items_data,
            unique_by: [:item_id, :item_type, :ranking_configuration_id],
            update_only: [:rank, :score]
          )
        end

        # Remove any ranked items that are no longer in the ranking
        current_item_ids = ranking_data.map { |r| r[:id] }
        ranking_configuration.ranked_items
          .where(item_type: item_type)
          .where.not(item_id: current_item_ids)
          .delete_all
      end
    end
  end
end
