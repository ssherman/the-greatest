# frozen_string_literal: true

# Shows how little rank *within* a list matters compared to being on it at all.
#
# The numbers are computed from the live configuration rather than hardcoded,
# because exponent and bonus pool differ per domain.
class Rankings::ScoreCurveComponent < ViewComponent::Base
  def initialize(curve:, media_nouns:)
    @curve = curve
    @media_nouns = media_nouns
  end

  private

  attr_reader :curve, :media_nouns
end
