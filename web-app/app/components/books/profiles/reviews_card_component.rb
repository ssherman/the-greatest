# frozen_string_literal: true

class Books::Profiles::ReviewsCardComponent < ViewComponent::Base
  def initialize(reviews:, audience:)
    @reviews = reviews || []
    @audience = audience
  end

  def render?
    reviews.any? || owner?
  end

  private

  attr_reader :reviews, :audience

  def owner? = audience == :owner

  # Rendered, not stored: what is stored stays exactly what the author typed.
  # Never call BodySanitizer.call here.
  def snippet(review)
    Services::Reviews::BodySanitizer.render(review.body)
  end
end
