# frozen_string_literal: true

module Reviews
  # A single written review: stars, when it was written, an optional title, the body.
  #
  # No author. The legacy book page shows none either, only 56 of 364 reviewers ever
  # set a display name, and publishing names against 141,869 already-migrated rows was
  # never something their authors agreed to. It also keeps the row free of any
  # association, so a page of these loads no extra rows.
  class ReviewComponent < ViewComponent::Base
    def initialize(review:)
      @review = review
    end

    private

    attr_reader :review

    def body_html
      @body_html ||= Services::Reviews::BodySanitizer.render(review.body)
    end

    def written_at
      "#{time_ago_in_words(review.created_at)} ago"
    end

    def stars_label
      "Rated #{review.rating} out of 5 stars"
    end
  end
end
