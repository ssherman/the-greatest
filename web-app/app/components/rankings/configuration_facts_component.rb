# frozen_string_literal: true

# The live numbers behind the current rankings.
#
# The weight floor is reported as 0, not min_list_weight. Total penalty is capped
# at 100%, so weight can never fall below 0 and a negative stored minimum (books
# carries -50) is unreachable. Printing it would be accurate about the column and
# wrong about the system.
class Rankings::ConfigurationFactsComponent < ViewComponent::Base
  WEIGHT_FLOOR = 0

  def initialize(configurations:)
    @configurations = configurations
  end

  private

  attr_reader :configurations

  def weight_floor = WEIGHT_FLOOR
end
