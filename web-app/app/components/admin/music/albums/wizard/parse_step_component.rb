# frozen_string_literal: true

class Admin::Music::Albums::Wizard::ParseStepComponent < ViewComponent::Base
  def initialize(list:, errors: [], raw_html_preview: nil, parsed_count: nil)
    @list = list
    @errors = errors
    @raw_html_preview = raw_html_preview || list.raw_html&.truncate(500) || "(No HTML provided)"
    @parsed_count = parsed_count || list.list_items.unverified.count
  end

  private

  attr_reader :list, :errors, :raw_html_preview, :parsed_count
end
