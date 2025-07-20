# frozen_string_literal: true

module Rankings
  class WeightCalculatorV1 < WeightCalculator
    private

    def calculate_weight
      starting_weight = base_weight.to_f
      total_penalty_percentage = calculate_total_penalty_percentage

      # Apply quality source bonus (reduce penalties by 1/3 if high quality)
      if list.high_quality_source?
        total_penalty_percentage *= (2.0 / 3.0)
      end

      # Ensure penalty percentage doesn't exceed 100%
      total_penalty_percentage = [total_penalty_percentage, 100].min

      # Apply penalty to starting weight
      starting_weight -= (starting_weight * (total_penalty_percentage / 100.0))

      # Apply minimum weight floor
      final_weight = [starting_weight, minimum_weight].max

      # Return as integer
      final_weight.round
    end

    def calculate_total_penalty_percentage
      # Get all penalty values applied to this list for this ranking configuration
      penalty_percentage = calculate_static_penalties.to_f

      # Add any additional penalties based on list attributes
      penalty_percentage += calculate_voter_count_penalty
      penalty_percentage += calculate_attribute_penalties

      penalty_percentage
    end

    def calculate_static_penalties
      total_penalty = 0

      # Calculate penalties from list penalty associations (list-specific penalties)
      list.list_penalties.includes(:penalty).each do |list_penalty|
        penalty = list_penalty.penalty
        if penalty.static?
          # For static penalties, get value from penalty applications for this configuration
          penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
          total_penalty += penalty_application&.value || 0
        end
      end

      total_penalty
    end

    def calculate_voter_count_penalty
      # Check if there are any voter count penalties configured for this ranking configuration
      voter_count_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(:number_of_voters)

      return 0 if voter_count_penalties.empty?

      total_voter_penalty = 0

      voter_count_penalties.each do |penalty|
        penalty_value = calculate_voter_count_penalty_for_penalty(penalty)
        total_voter_penalty += penalty_value if penalty_value > 0
      end

      total_voter_penalty
    end

    def calculate_voter_count_penalty_for_penalty(penalty, exponent: 2.0)
      voter_count = list.number_of_voters
      return 0 unless voter_count.present?

      # Get the penalty application value for this configuration
      penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
      return 0 unless penalty_application

      max_penalty = penalty_application.value

      # Calculate the median voter count from all lists in this ranking configuration
      median_voter_count = ranking_configuration.median_voter_count

      # If we can't calculate median (no data), fall back to reasonable default
      median_voter_count ||= 50

      return max_penalty if voter_count <= 1
      return 0 if voter_count > median_voter_count

      # Power curve penalty calculation - lists at or below median get penalty
      ratio = voter_count.to_f / median_voter_count.to_f
      penalty_value = max_penalty * ((1.0 - ratio)**exponent)

      penalty_value.clamp(0, max_penalty)
    end

    def calculate_attribute_penalties
      total_penalty = 0

      # Apply penalties based on list attributes
      total_penalty += calculate_unknown_data_penalties
      total_penalty += calculate_bias_penalties

      total_penalty
    end

    def calculate_unknown_data_penalties
      penalty = 0

      # Penalty for unknown voter names
      if list.voter_names_unknown?
        penalty += find_penalty_value_by_dynamic_type(:voter_names_unknown)
      end

      # Penalty for unknown voter count
      if list.voter_count_unknown?
        penalty += find_penalty_value_by_dynamic_type(:voter_count_unknown)
      end

      penalty
    end

    def calculate_bias_penalties
      penalty = 0

      # Penalty for category-specific lists
      if list.category_specific?
        penalty += find_penalty_value_by_dynamic_type(:category_specific)
      end

      # Penalty for location-specific lists
      if list.location_specific?
        penalty += find_penalty_value_by_dynamic_type(:location_specific)
      end

      penalty
    end

    def find_penalty_value_by_dynamic_type(dynamic_type)
      # Find penalties for this ranking configuration that match the dynamic type
      matching_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(dynamic_type)

      return 0 if matching_penalties.empty?

      # Sum all matching penalty values
      matching_penalties.sum do |penalty|
        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        penalty_application&.value || 0
      end
    end
  end
end
