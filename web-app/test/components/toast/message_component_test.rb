# frozen_string_literal: true

require "test_helper"

class Toast::MessageComponentTest < ViewComponent::TestCase
  test "renders a status alert that the toast-item controller dismisses" do
    render_inline(Toast::MessageComponent.new(message: "Saved", ttl: 2500))

    assert_selector "div.alert.alert-success[role='status'][data-controller='toast-item'][data-toast-item-ttl-value='2500']", text: "Saved"
    assert_no_selector "button"
  end

  test "escapes the message" do
    render_inline(Toast::MessageComponent.new(message: "<b>Dune</b>"))

    assert_no_selector "b"
    assert_text "<b>Dune</b>"
  end

  test "renders an action button when given" do
    render_inline(Toast::MessageComponent.new(
      message: "Removed",
      type: :info,
      action: {label: "Undo", url: "/undo", method: :post, params: {id: 1}}
    ))

    assert_selector "div.alert-info form[action='/undo'] button.btn", text: "Undo"
  end
end
