# frozen_string_literal: true

class Wizard::Core::JobStepComponent < ViewComponent::Base
  TITLES = {"parse" => "Parse", "match" => "Match", "import" => "Import"}.freeze
  DESCRIPTIONS = {
    "parse" => "The parser turns the pasted list into rows.",
    "match" => "Every row is looked up. Confident answers pass through; the rest are flagged for review.",
    "import" => "Rows marked to create become books, one at a time."
  }.freeze
  RERUN = {"parse" => [:reparse, "Re-parse"], "match" => [:rematch, "Re-match unsettled rows"]}.freeze

  def initialize(list:, adapter:, step:)
    @list = list
    @adapter = adapter
    @step = step
  end

  def title = TITLES.fetch(@step)

  def description = DESCRIPTIONS.fetch(@step)

  def status = manager.step_status(@step)

  def progress = manager.step_progress(@step)

  def error = manager.step_error(@step)

  def metadata = manager.step_metadata(@step)

  def start_label = error.present? ? "Try again" : "Start"

  def start_path = @adapter.wizard_path(:advance_step, @list, step: @step)

  def status_path = @adapter.wizard_path(:step_status, @list, step: @step)

  def step_path = @adapter.wizard_path(:step, @list, step: @step)

  def rerun_path = RERUN[@step] && @adapter.wizard_path(RERUN[@step].first, @list)

  def rerun_label = RERUN[@step]&.last

  def parsed_rows
    @list.list_items.ordered.to_a
      .reject { |item| ::Services::Lists::Wizard::Core::RowState.new(item).removed? }
      .map { |item| [item, @adapter.row_display(item)] }
  end

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).review_counts

  private

  attr_reader :step

  def manager = @list.wizard_manager
end
