# frozen_string_literal: true

# The full penalty reference, grouped into the five reader-facing categories.
#
# Each group's table sits inside a <details> because the complete set runs to
# roughly fifty rows and would otherwise dominate the page. The prose above each
# group is what most readers need; the table is for the ones who want all of it.
class Rankings::PenaltyTableComponent < ViewComponent::Base
  def initialize(groups:)
    @groups = groups
  end

  def render? = @groups.any?

  private

  attr_reader :groups
end
