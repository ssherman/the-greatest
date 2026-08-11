# frozen_string_literal: true

require "test_helper"

module Reviews
  class ModalComponentTest < ViewComponent::TestCase
    test "renders a dialog the widget can open by id" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "dialog#review_modal[data-controller='reviews--modal']"
    end

    test "renders five star buttons that announce their pressed state" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-testid='review-star-button']", count: 5
      assert_selector "[data-testid='review-star-button'][aria-pressed='false']", count: 5
      assert_selector "[data-testid='review-star-button'][data-rating='3']"
    end

    test "carries a hidden rating field for the form to submit" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "input[type='hidden'][name='review[rating]']", visible: :all
    end

    test "carries optional title and body fields" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "input[name='review[title]']"
      assert_selector "textarea[name='review[body]']"
    end

    test "carries an empty authenticity token the controller replaces" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "input[name='authenticity_token']", visible: :all
    end

    test "carries a method override field so the same form can update" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "input[name='_method']", visible: :all
    end

    test "ships with the remove button hidden" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-testid='review-remove'].hidden"
    end

    test "carries no user data" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "input[name='review[title]'][value='']"
    end
  end
end
