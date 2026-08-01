# frozen_string_literal: true

class Lists::WeightBreakdownComponent < ViewComponent::Base
  def initialize(ranked_list:)
    @ranked_list = ranked_list
  end

  private

  attr_reader :ranked_list

  def details
    @details ||= ranked_list&.calculated_weight_details
  end

  def penalties
    (details["penalties"] || []).sort_by { |p| -p["value"].to_f }
  end

  def base_weight
    pct(details.dig("base_values", "base_weight"))
  end

  def final_weight
    pct(details.dig("final_calculation", "final_weight"))
  end

  def total_penalty
    pct(details.dig("penalty_summary", "total_before_quality_bonus"))
  end

  def quality_bonus
    return nil unless details.dig("quality_bonus", "applied")

    before = details.dig("quality_bonus", "penalty_before")
    after = details.dig("quality_bonus", "penalty_after")
    return nil if before.nil? || after.nil?

    pct(before - after)
  end

  def pct(value)
    return nil if value.nil?
    number_with_precision(value, precision: 1, strip_insignificant_zeros: true)
  end
end
