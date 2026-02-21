# frozen_string_literal: true

# Games parse step component.
#
class Admin::Games::Wizard::ParseStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list

  def raw_html_preview
    list.raw_html&.truncate(500) || "(No HTML provided)"
  end

  def parsed_count
    list.list_items.unverified.count
  end

  def parse_status
    list.wizard_manager.step_status("parse")
  end

  def parse_progress
    list.wizard_manager.step_progress("parse")
  end

  def parse_error
    list.wizard_manager.step_error("parse")
  end
end
