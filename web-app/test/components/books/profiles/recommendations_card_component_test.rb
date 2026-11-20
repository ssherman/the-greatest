# frozen_string_literal: true

require "test_helper"

class Books::Profiles::RecommendationsCardComponentTest < ViewComponent::TestCase
  Data = Services::Books::Profiles::Recommended::Data

  test "unavailable does not render" do
    refute Books::Profiles::RecommendationsCardComponent.new(
      recommendations: Data.new(state: :unavailable, books: []), audience: :owner
    ).render?
  end

  test "no_history renders the wizard prompt" do
    render_inline Books::Profiles::RecommendationsCardComponent.new(
      recommendations: Data.new(state: :no_history, books: []), audience: :owner
    )

    assert_selector "[data-testid='profile-recommendations-prompt'].card-dash a[href='#{Rails.application.routes.url_helpers.recommendations_wizard_path(step: 1)}']"
  end

  test "ok renders the books with a see-all link" do
    render_inline Books::Profiles::RecommendationsCardComponent.new(
      recommendations: Data.new(state: :ok, books: [books_books(:war_and_peace)]), audience: :owner
    )

    assert_selector "[data-testid='profile-book']", count: 1
    assert_selector "a[href='#{Rails.application.routes.url_helpers.recommendations_path}']"
  end

  test "never renders for the public, nil or not" do
    [Data.new(state: :ok, books: [books_books(:war_and_peace)]), Data.new(state: :no_history, books: []), nil].each do |data|
      refute Books::Profiles::RecommendationsCardComponent.new(recommendations: data, audience: :public).render?
    end
  end
end
