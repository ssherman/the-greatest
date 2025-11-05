# frozen_string_literal: true

module Rankings
  class WeightCalculatorV1 < WeightCalculator
    private

    def calculate_weight
      details = {
        "calculation_version" => 1,
        "timestamp" => Time.current.iso8601,
        "base_values" => build_base_values,
        "penalties" => [],
        "penalty_summary" => {}
      }

      starting_weight = base_weight.to_f

      static_penalties = calculate_static_penalties_with_details(details)
      voter_penalties = calculate_voter_count_penalty_with_details(details)
      attribute_penalties = calculate_attribute_penalties_with_details(details)

      total_penalty_percentage = static_penalties + voter_penalties + attribute_penalties

      details["penalty_summary"] = {
        "total_static_penalties" => static_penalties,
        "total_voter_count_penalties" => voter_penalties,
        "total_attribute_penalties" => attribute_penalties,
        "total_before_quality_bonus" => total_penalty_percentage
      }

      details["quality_bonus"] = apply_quality_bonus_with_details(total_penalty_percentage)
      total_penalty_percentage = details["quality_bonus"]["penalty_after"]

      details["final_calculation"] = build_final_calculation(starting_weight, total_penalty_percentage)

      ranked_list.calculated_weight_details = details

      details["final_calculation"]["final_weight"]
    end

    def build_base_values
      {
        "base_weight" => base_weight,
        "minimum_weight" => minimum_weight,
        "high_quality_source" => list.high_quality_source?
      }
    end

    def calculate_static_penalties_with_details(details)
      total_penalty = 0

      list.list_penalties.includes(:penalty).each do |list_penalty|
        penalty = list_penalty.penalty
        next unless penalty.static?

        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        next unless penalty_application

        penalty_value = penalty_application.value || 0
        total_penalty += penalty_value

        details["penalties"] << {
          "source" => "static",
          "penalty_id" => penalty.id,
          "penalty_name" => penalty.name,
          "penalty_class" => penalty.class.name,
          "list_penalty_id" => list_penalty.id,
          "penalty_application_id" => penalty_application.id,
          "value" => penalty_value
        }
      end

      total_penalty
    end

    def calculate_voter_count_penalty_with_details(details)
      voter_count_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(:number_of_voters)
        .distinct

      return 0 if voter_count_penalties.empty?

      total_voter_penalty = 0

      voter_count_penalties.each do |penalty|
        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        next unless penalty_application

        penalty_value, calculation_details = calculate_voter_count_penalty_with_calculation_details(penalty, penalty_application)
        next unless penalty_value > 0

        total_voter_penalty += penalty_value

        details["penalties"] << {
          "source" => "dynamic_voter_count",
          "penalty_id" => penalty.id,
          "penalty_name" => penalty.name,
          "penalty_class" => penalty.class.name,
          "penalty_application_id" => penalty_application.id,
          "max_value" => penalty_application.value,
          "calculation" => calculation_details,
          "value" => penalty_value
        }
      end

      total_voter_penalty
    end

    def calculate_voter_count_penalty_with_calculation_details(penalty, penalty_application, exponent: 2.0)
      voter_count = list.number_of_voters
      return [0, {}] unless voter_count.present?

      max_penalty = penalty_application.value
      median_voter_count = ranking_configuration.median_voter_count || 50

      if voter_count <= 1
        return [max_penalty, {
          "voter_count" => voter_count,
          "median_voter_count" => median_voter_count,
          "formula" => "max_value (voter_count <= 1)"
        }]
      end

      if voter_count > median_voter_count
        return [0, {
          "voter_count" => voter_count,
          "median_voter_count" => median_voter_count,
          "formula" => "0 (voter_count > median)"
        }]
      end

      ratio = voter_count.to_f / median_voter_count.to_f
      penalty_value = max_penalty * ((1.0 - ratio)**exponent)
      penalty_value = penalty_value.clamp(0, max_penalty)

      calculation_details = {
        "voter_count" => voter_count,
        "median_voter_count" => median_voter_count,
        "ratio" => ratio,
        "exponent" => exponent,
        "formula" => "max_value * ((1.0 - ratio) ** exponent)"
      }

      [penalty_value, calculation_details]
    end

    def calculate_attribute_penalties_with_details(details)
      total_penalty = 0

      total_penalty += calculate_unknown_data_penalties_with_details(details)
      total_penalty += calculate_bias_penalties_with_details(details)
      total_penalty += calculate_temporal_coverage_penalty_with_details(details)

      total_penalty
    end

    def calculate_unknown_data_penalties_with_details(details)
      penalty = 0

      if list.voter_names_unknown?
        penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:voter_names_unknown)
        if penalty_value > 0
          penalty += penalty_value
          details["penalties"] << penalty_info.merge(
            "source" => "dynamic_attribute",
            "dynamic_type" => "voter_names_unknown",
            "attribute_value" => true,
            "value" => penalty_value
          )
        end
      end

      if list.voter_count_unknown?
        penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:voter_count_unknown)
        if penalty_value > 0
          penalty += penalty_value
          details["penalties"] << penalty_info.merge(
            "source" => "dynamic_attribute",
            "dynamic_type" => "voter_count_unknown",
            "attribute_value" => true,
            "value" => penalty_value
          )
        end
      end

      if list.voter_count_estimated?
        penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:voter_count_estimated)
        if penalty_value > 0
          penalty += penalty_value
          details["penalties"] << penalty_info.merge(
            "source" => "dynamic_attribute",
            "dynamic_type" => "voter_count_estimated",
            "attribute_value" => true,
            "value" => penalty_value
          )
        end
      end

      penalty
    end

    def calculate_bias_penalties_with_details(details)
      penalty = 0

      if list.category_specific?
        penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:category_specific)
        if penalty_value > 0
          penalty += penalty_value
          details["penalties"] << penalty_info.merge(
            "source" => "dynamic_attribute",
            "dynamic_type" => "category_specific",
            "attribute_value" => true,
            "value" => penalty_value
          )
        end
      end

      if list.location_specific?
        penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:location_specific)
        if penalty_value > 0
          penalty += penalty_value
          details["penalties"] << penalty_info.merge(
            "source" => "dynamic_attribute",
            "dynamic_type" => "location_specific",
            "attribute_value" => true,
            "value" => penalty_value
          )
        end
      end

      penalty
    end

    def calculate_temporal_coverage_penalty_with_details(details)
      return 0 unless list.num_years_covered.present?

      temporal_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(:num_years_covered)
        .distinct

      return 0 if temporal_penalties.empty?

      total_temporal_penalty = 0

      temporal_penalties.each do |penalty|
        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        next unless penalty_application

        penalty_value, calculation_details = calculate_temporal_coverage_penalty_with_calculation_details(penalty, penalty_application)
        next unless penalty_value > 0

        total_temporal_penalty += penalty_value

        details["penalties"] << {
          "source" => "dynamic_temporal",
          "penalty_id" => penalty.id,
          "penalty_name" => penalty.name,
          "penalty_class" => penalty.class.name,
          "penalty_application_id" => penalty_application.id,
          "max_value" => penalty_application.value,
          "calculation" => calculation_details,
          "value" => penalty_value
        }
      end

      total_temporal_penalty
    end

    def calculate_temporal_coverage_penalty_with_calculation_details(penalty, penalty_application, exponent: 2.0)
      years_covered = list.num_years_covered
      return [0, {}] unless years_covered.present?

      max_penalty = penalty_application.value
      max_year_range = calculate_media_year_range

      if years_covered >= max_year_range
        return [0, {
          "years_covered" => years_covered,
          "max_year_range" => max_year_range,
          "media_type" => list.class.name,
          "formula" => "0 (full coverage)"
        }]
      end

      ratio = years_covered.to_f / max_year_range.to_f
      penalty_value = max_penalty * ((1.0 - ratio)**exponent)
      penalty_value = penalty_value.clamp(0, max_penalty)

      calculation_details = {
        "years_covered" => years_covered,
        "max_year_range" => max_year_range,
        "media_type" => list.class.name,
        "ratio" => ratio,
        "exponent" => exponent,
        "formula" => "max_value * ((1.0 - ratio) ** exponent)"
      }

      [penalty_value, calculation_details]
    end

    def find_penalty_details_by_dynamic_type(dynamic_type)
      matching_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(dynamic_type)
        .distinct

      return [0, {}] if matching_penalties.empty?

      total_value = 0
      penalty_info = {}

      matching_penalties.each do |penalty|
        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        next unless penalty_application

        value = penalty_application.value || 0
        total_value += value

        penalty_info = {
          "penalty_id" => penalty.id,
          "penalty_name" => penalty.name,
          "penalty_class" => penalty.class.name,
          "penalty_application_id" => penalty_application.id
        }
      end

      [total_value, penalty_info]
    end

    def apply_quality_bonus_with_details(total_penalty_percentage)
      penalty_before = total_penalty_percentage
      reduction_factor = 2.0 / 3.0
      applied = list.high_quality_source?

      penalty_after = applied ? (total_penalty_percentage * reduction_factor) : total_penalty_percentage

      {
        "applied" => applied,
        "reduction_factor" => reduction_factor,
        "penalty_before" => penalty_before,
        "penalty_after" => penalty_after
      }
    end

    def build_final_calculation(starting_weight, total_penalty_percentage)
      capped_penalty_percentage = [total_penalty_percentage, 100].min
      weight_after_penalty = starting_weight - (starting_weight * (capped_penalty_percentage / 100.0))
      weight_after_floor = [weight_after_penalty, minimum_weight].max
      final_weight = weight_after_floor.round

      {
        "total_penalty_percentage" => total_penalty_percentage,
        "capped_penalty_percentage" => capped_penalty_percentage,
        "weight_after_penalty" => weight_after_penalty,
        "weight_after_floor" => weight_after_floor,
        "final_weight" => final_weight
      }
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
        .distinct

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
      total_penalty += calculate_temporal_coverage_penalty

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

      # Penalty for estimated voter count
      if list.voter_count_estimated?
        penalty += find_penalty_value_by_dynamic_type(:voter_count_estimated)
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

    def calculate_temporal_coverage_penalty
      return 0 unless list.num_years_covered.present?

      # Check if there are any temporal coverage penalties configured
      temporal_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(:num_years_covered)
        .distinct

      return 0 if temporal_penalties.empty?

      total_temporal_penalty = 0

      temporal_penalties.each do |penalty|
        penalty_value = calculate_temporal_coverage_penalty_for_penalty(penalty)
        total_temporal_penalty += penalty_value if penalty_value > 0
      end

      total_temporal_penalty
    end

    def calculate_temporal_coverage_penalty_for_penalty(penalty, exponent: 2.0)
      years_covered = list.num_years_covered
      return 0 unless years_covered.present?

      # Get the penalty application value for this configuration
      penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
      return 0 unless penalty_application

      max_penalty = penalty_application.value

      # Calculate the maximum year range for this media type
      max_year_range = calculate_media_year_range

      return 0 if years_covered >= max_year_range  # No penalty for full coverage

      # Power curve penalty calculation - lists with limited coverage get penalty
      ratio = years_covered.to_f / max_year_range.to_f
      penalty_value = max_penalty * ((1.0 - ratio)**exponent)

      penalty_value.clamp(0, max_penalty)
    end

    def calculate_media_year_range
      # Determine media type from list class and calculate year range
      case list.class.name
      when /^Music::/
        calculate_music_year_range
      when /^Books::/
        calculate_books_year_range
      when /^Movies::/
        calculate_movies_year_range
      when /^Games::/
        calculate_games_year_range
      else
        # Fallback for generic lists
        100  # Default 100 year range
      end
    end

    def calculate_music_year_range
      # Use actual data from music albums and songs
      album_years = Music::Album.where.not(release_year: nil).pluck(:release_year)
      song_years = Music::Song.where.not(release_year: nil).pluck(:release_year)

      all_years = (album_years + song_years).compact

      return 100 if all_years.empty?  # Fallback

      min_year = all_years.min
      max_year = all_years.max
      current_year = Date.current.year

      # Use current year if max_year is in the future or current year is more recent
      max_year = [max_year, current_year].max

      max_year - min_year + 1
    end

    def calculate_books_year_range
      # Books have a much longer historical range
      # For now, use a reasonable estimate until we have book models with data
      current_year = Date.current.year
      estimated_oldest_book_year = -3000  # ~3000 BCE

      current_year - estimated_oldest_book_year + 1
    end

    def calculate_movies_year_range
      # Movies are relatively recent
      # For now, use a reasonable estimate until we have movie models with data
      current_year = Date.current.year
      estimated_first_movie_year = 1888  # First known motion picture

      current_year - estimated_first_movie_year + 1
    end

    def calculate_games_year_range
      # Video games are very recent
      # For now, use a reasonable estimate until we have game models with data
      current_year = Date.current.year
      estimated_first_game_year = 1958  # Tennis for Two or similar early games

      current_year - estimated_first_game_year + 1
    end

    def find_penalty_value_by_dynamic_type(dynamic_type)
      # Find penalties for this ranking configuration that match the dynamic type
      matching_penalties = ranking_configuration.penalties.joins(:penalty_applications)
        .by_dynamic_type(dynamic_type)
        .distinct

      return 0 if matching_penalties.empty?

      # Sum all matching penalty values
      matching_penalties.sum do |penalty|
        penalty_application = penalty.penalty_applications.find_by(ranking_configuration: ranking_configuration)
        penalty_application&.value || 0
      end
    end
  end
end
