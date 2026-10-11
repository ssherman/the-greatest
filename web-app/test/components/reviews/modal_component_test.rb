# frozen_string_literal: true

require "test_helper"

module Reviews
  class ModalComponentTest < ViewComponent::TestCase
    test "renders a dialog the widget can open by id" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "dialog#review_modal[data-controller='reviews--modal']"
    end

    # /my/reviews' reload guard (event.target.closest("#review_modal")) depends
    # on the form living inside this specific id -- if the dialog's id ever
    # moved, that guard would silently stop matching and the reload it exists
    # for would stop firing.
    test "the form lives inside the review_modal dialog" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "#review_modal form[data-reviews--modal-target='form']"
    end

    test "renders a quarter-step slider of five stars with a readout" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-controller='reviews--star-input'] [role='slider'][data-testid='review-star-input']" \
        "[aria-valuemin='0.25'][aria-valuemax='5'][aria-valuetext='Not rated'][tabindex='0']"
      assert_selector "[data-testid='review-star-input'] [data-reviews--star-input-target='star']", count: 5
      assert_selector "[data-testid='review-rating-readout']", text: "Not rated"
    end

    test "the hidden rating field lives inside the star input so it can write it" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "[data-controller='reviews--star-input'] input[type='hidden'][name='review[rating]']" \
        "[data-reviews--star-input-target='input'][data-reviews--modal-target='rating']", visible: :all
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

    test "tells the writer how to hide a spoiler" do
      render_inline(Reviews::ModalComponent.new)

      assert_text "||"
    end

    test "ships a clear-rating control, hidden until a rating is picked" do
      render_inline(Reviews::ModalComponent.new)

      assert_selector "button[data-testid='review-clear-rating'][data-action='click->reviews--modal#clearRating'].hidden", visible: :all
    end
  end
end
