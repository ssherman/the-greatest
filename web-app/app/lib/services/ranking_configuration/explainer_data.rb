# frozen_string_literal: true

module Services
  module RankingConfiguration
    # Assembles everything the public /rankings page renders, for one domain.
    #
    # Books passes one configuration; music passes two (albums and songs). Every
    # query the page needs lives here rather than in the components, so the N+1
    # guard has a single place to point at.
    class ExplainerData
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      PenaltyGroup = Struct.new(:category, :title, :penalties, keyword_init: true)

      WorkedExample = Struct.new(
        :list, :weight, :item_count, :penalties,
        :penalty_before_bonus, :penalty_after_bonus, :quality_bonus_applied,
        keyword_init: true
      )

      ScoreCurve = Struct.new(
        :list_length, :top_score, :middle_score, :bottom_score, :ratio,
        keyword_init: true
      )

      Data = Struct.new(
        :configurations, :primary_configuration, :media_nouns,
        :active_lists_count, :ranked_items_count, :median_list_count,
        :penalty_groups, :worked_example, :score_curve,
        keyword_init: true
      )

      # The weight every list starts from before penalties. Mirrors
      # Rankings::WeightCalculator#base_weight, which is not public.
      BASE_WEIGHT = 100

      def self.call(configurations:, example_list_id: nil)
        new(configurations: configurations, example_list_id: example_list_id).call
      end

      def initialize(configurations:, example_list_id: nil)
        @configurations = Array(configurations).compact
        @example_list_id = example_list_id
      end

      def call
        return failure("No ranking configuration available") if @configurations.empty?

        Result.new(success?: true, data: build_data, errors: [])
      rescue => error
        failure(error.message)
      end

      private

      attr_reader :configurations, :example_list_id

      def primary = configurations.first

      def build_data
        Data.new(
          configurations: configurations,
          primary_configuration: primary,
          media_nouns: media_nouns,
          active_lists_count: active_lists_count,
          ranked_items_count: ranked_items_count,
          median_list_count: median_list_count,
          penalty_groups: penalty_groups,
          worked_example: worked_example,
          score_curve: score_curve
        )
      end

      def media_nouns
        configurations.map(&:media_noun_plural).uniq.to_sentence
      end

      def active_lists_count
        configurations.sum { |config| config.ranked_lists.joins(:list).where(lists: {status: :active}).count }
      end

      def ranked_items_count
        configurations.sum { |config| config.ranked_items.where.not(rank: nil).count }
      end

      def median_list_count
        ::List.median_list_count(type: list_type_for(primary))
      end

      def list_type_for(configuration)
        configuration.type.sub("RankingConfiguration", "List")
      end

      # Ordered by CATEGORY_TITLES so the page's sections are stable, with the
      # uncategorized remainder last under "Other". Empty groups are dropped --
      # a heading with nothing under it reads as a bug.
      def penalty_groups
        penalties = Penalty
          .joins(:penalty_applications)
          .where(penalty_applications: {ranking_configuration_id: configurations.map(&:id)})
          .distinct
          .order(:name)
          .to_a

        ordered = Penalty::CATEGORY_TITLES.keys.map do |category|
          PenaltyGroup.new(
            category: category,
            title: Penalty.category_title(category),
            penalties: penalties.select { |penalty| penalty.category == category }
          )
        end

        ordered << PenaltyGroup.new(
          category: nil,
          title: "Other",
          penalties: penalties.select { |penalty| penalty.category.nil? }
        )

        ordered.reject { |group| group.penalties.empty? }
      end

      # Reads the stored calculation rather than recomputing, so the page can
      # never disagree with the weight the list actually carries.
      def worked_example
        ranked_list = pinned_example || heaviest_example
        return nil if ranked_list.nil?

        details = ranked_list.calculated_weight_details
        bonus = details["quality_bonus"] || {}

        WorkedExample.new(
          list: ranked_list.list,
          weight: ranked_list.weight,
          item_count: ranked_list.list.list_items.count,
          penalties: details["penalties"].to_a.map { |p| {name: p["penalty_name"], value: p["value"]} },
          penalty_before_bonus: bonus["penalty_before"],
          penalty_after_bonus: bonus["penalty_after"],
          quality_bonus_applied: bonus["applied"]
        )
      end

      def pinned_example
        return nil if example_list_id.nil?

        example_scope.find_by(list_id: example_list_id)
      end

      def heaviest_example
        example_scope.order(weight: :desc).first
      end

      def example_scope
        primary.ranked_lists
          .includes(:list)
          .joins(:list)
          .where(lists: {status: :active})
          .where.not(calculated_weight_details: nil)
      end

      # Scores a synthetic list of median length at the base weight, using the
      # same strategy the real calculator uses, so the page states this domain's
      # actual numbers rather than a remembered constant.
      def score_curve
        length = [median_list_count.to_i, 2].max

        strategy = WeightedListRank::Strategies::Exponential.new(
          exponent: primary.exponent.to_f,
          bonus_pool_percentage: primary.bonus_pool_percentage.to_f,
          average_list_length: length
        )

        items = (1..length).map { |position| ItemRankings::Item.new(position, position, nil) }
        scores = strategy.calculate_scores(ItemRankings::List.new(0, BASE_WEIGHT.to_f, items))

        ScoreCurve.new(
          list_length: length,
          top_score: scores.first.round(1),
          middle_score: scores[(length / 2) - 1].round(1),
          bottom_score: scores.last.round(1),
          ratio: (scores.first / scores.last).round(2)
        )
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
