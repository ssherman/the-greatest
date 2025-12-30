# frozen_string_literal: true

# Base component for wizard parse step.
# Displays HTML input form and parsing progress.
#
# Subclasses must implement:
#   - save_html_path: Path helper for saving HTML
#   - step_status_path: Path helper for polling step status
#   - advance_step_path: Path helper for advancing to next step
#   - entity_name: "song" or "album" for display text
#   - entity_name_plural: "songs" or "albums" for display text
#
class Admin::Music::Wizard::BaseParseStepComponent < ViewComponent::Base
  def initialize(list:, errors: [], raw_html_preview: nil, parsed_count: nil)
    @list = list
    @errors = errors
    @raw_html_preview = raw_html_preview || list.raw_html&.truncate(500) || "(No HTML provided)"
    @parsed_count = parsed_count || list.list_items.unverified.count
  end

  private

  attr_reader :list, :errors, :raw_html_preview, :parsed_count

  # Abstract methods - subclasses must implement
  def save_html_path
    raise NotImplementedError, "Subclass must implement #save_html_path"
  end

  def step_status_path
    raise NotImplementedError, "Subclass must implement #step_status_path"
  end

  def advance_step_path
    raise NotImplementedError, "Subclass must implement #advance_step_path"
  end

  def entity_name
    raise NotImplementedError, "Subclass must implement #entity_name"
  end

  def entity_name_plural
    raise NotImplementedError, "Subclass must implement #entity_name_plural"
  end

  # Shared methods
  def parse_status
    list.wizard_manager.step_status("parse")
  end

  def parse_progress
    list.wizard_manager.step_progress("parse")
  end

  def parse_error
    list.wizard_manager.step_error("parse")
  end

  def parse_metadata
    list.wizard_manager.step_metadata("parse")
  end

  def idle_or_failed?
    %w[idle failed].include?(parse_status)
  end

  def running?
    parse_status == "running"
  end

  def completed?
    parse_status == "completed"
  end

  def failed?
    parse_status == "failed"
  end

  def total_items_from_metadata
    parse_metadata["total_items"] || parsed_count
  end
end
