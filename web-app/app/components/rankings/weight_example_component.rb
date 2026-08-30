# frozen_string_literal: true

# One real list walked from 100 down to the weight it actually carries.
#
# Every number comes from the stored calculated_weight_details rather than being
# recomputed here, so this can never contradict the weight the list is ranked
# with.
class Rankings::WeightExampleComponent < ViewComponent::Base
  BASE_WEIGHT = 100

  def initialize(example:)
    @example = example
  end

  def render? = @example.present?

  private

  attr_reader :example

  def base_weight = BASE_WEIGHT

  def total_before_bonus
    example.penalty_before_bonus.to_f.round(1)
  end

  def total_after_bonus
    example.penalty_after_bonus.to_f.round(1)
  end

  def quality_bonus_applied? = example.quality_bonus_applied
end
