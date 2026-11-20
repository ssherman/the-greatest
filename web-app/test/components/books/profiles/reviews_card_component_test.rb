# frozen_string_literal: true

require "test_helper"

class Books::Profiles::ReviewsCardComponentTest < ViewComponent::TestCase
  def review
    Review.create!(user: users(:profile_reader), reviewable: books_books(:war_and_peace),
      rating: BigDecimal("4.0"), body: "A long and rewarding read.")
  end

  test "renders reviews for both audiences, with the see-all link for the owner only" do
    reviews = [review]

    render_inline Books::Profiles::ReviewsCardComponent.new(reviews: reviews, audience: :owner)
    assert_selector "[data-testid='profile-review']", count: 1
    assert_selector "a[href='/my/reviews']"
    assert_no_text "4.0"

    render_inline Books::Profiles::ReviewsCardComponent.new(reviews: reviews, audience: :public)
    assert_selector "[data-testid='profile-review']", count: 1
    assert_no_selector "a[href='/my/reviews']"
  end

  test "owner with none gets the prompt card; public gets nothing" do
    render_inline Books::Profiles::ReviewsCardComponent.new(reviews: [], audience: :owner)
    assert_selector "[data-testid='profile-reviews-prompt'].card-dash a", count: 1

    refute Books::Profiles::ReviewsCardComponent.new(reviews: [], audience: :public).render?
    refute Books::Profiles::ReviewsCardComponent.new(reviews: nil, audience: :public).render?
  end
end
