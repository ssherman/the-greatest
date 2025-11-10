# frozen_string_literal: true

class AutocompleteComponent < ViewComponent::Base
  def initialize(
    name:,
    url:,
    placeholder: "Search...",
    value: nil,
    selected_text: nil,
    display_key: "text",
    value_key: "value",
    min_length: 2,
    debounce: 300,
    required: false,
    disabled: false
  )
    @name = name
    @url = url
    @placeholder = placeholder
    @value = value
    @selected_text = selected_text
    @display_key = display_key
    @value_key = value_key
    @min_length = min_length
    @debounce = debounce
    @required = required
    @disabled = disabled
  end

  def input_id
    @name.to_s.gsub(/[\[\]]/, "_").squeeze("_").sub(/_$/, "")
  end

  def autocomplete_id
    "#{input_id}_autocomplete"
  end

  private

  attr_reader :name, :url, :placeholder, :value, :selected_text,
    :display_key, :value_key, :min_length, :debounce,
    :required, :disabled
end
