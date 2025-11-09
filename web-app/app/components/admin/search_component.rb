# frozen_string_literal: true

class Admin::SearchComponent < ViewComponent::Base
  def initialize(url:, placeholder: "Search...", param: "q", value: nil, turbo_frame: nil)
    @url = url
    @placeholder = placeholder
    @param = param
    @value = value
    @turbo_frame = turbo_frame
  end

  private

  attr_reader :url, :placeholder, :param, :value, :turbo_frame
end
