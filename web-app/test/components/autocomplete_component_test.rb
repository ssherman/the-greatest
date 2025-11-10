# frozen_string_literal: true

require "test_helper"

class AutocompleteComponentTest < ViewComponent::TestCase
  test "renders autocomplete input with correct attributes" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search"
    ))

    assert_selector "input[type='search'][data-autocomplete-target='input']"
    assert_selector "input[type='hidden'][data-autocomplete-target='hiddenField']", visible: false
    assert_selector "[data-controller='autocomplete']"
  end

  test "renders hidden field for value storage" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search",
      value: "123"
    ))

    assert_selector "input[type='hidden'][value='123']", visible: false
  end

  test "renders with disabled state" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search",
      disabled: true
    ))

    assert_selector "input[disabled]"
    assert_selector "input.input-disabled"
  end

  test "renders with custom placeholder" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search",
      placeholder: "Custom placeholder..."
    ))

    assert_selector "input[placeholder='Custom placeholder...']"
  end

  test "renders with required attribute" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search",
      required: true
    ))

    assert_selector "input[type='hidden'][required]", visible: false
  end

  test "sets correct stimulus data attributes" do
    render_inline(AutocompleteComponent.new(
      name: "test[field]",
      url: "/search",
      min_length: 3,
      debounce: 500,
      display_key: "name",
      value_key: "id"
    ))

    assert_selector "[data-autocomplete-url-value='/search']"
    assert_selector "[data-autocomplete-min-length-value='3']"
    assert_selector "[data-autocomplete-debounce-value='500']"
    assert_selector "[data-autocomplete-display-key-value='name']"
    assert_selector "[data-autocomplete-value-key-value='id']"
  end
end
