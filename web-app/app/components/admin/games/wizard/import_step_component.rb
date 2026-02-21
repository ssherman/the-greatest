# frozen_string_literal: true

# Games import step component.
# Only supports custom_html path (no series import for games).
#
class Admin::Games::Wizard::ImportStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
    @all_items = list.list_items.ordered
    @linked_items = @all_items.where.not(listable_id: nil)
    @items_to_import = @all_items.where(listable_id: nil)
      .where("metadata->>'igdb_id' IS NOT NULL")
    @items_without_match = @all_items.where(listable_id: nil)
      .where("metadata->>'igdb_id' IS NULL")
  end

  private

  attr_reader :list, :all_items, :linked_items, :items_to_import, :items_without_match

  def import_status
    list.wizard_manager.step_status("import")
  end

  def import_progress
    list.wizard_manager.step_progress("import")
  end

  def import_error
    list.wizard_manager.step_error("import")
  end

  def job_metadata
    list.wizard_manager.step_metadata("import")
  end

  def imported_count
    job_metadata["imported_count"] || 0
  end

  def failed_count
    job_metadata["failed_count"] || 0
  end

  def skipped_count
    job_metadata["skipped_count"] || 0
  end

  def processed_items
    job_metadata["processed_items"] || 0
  end

  def total_from_metadata
    job_metadata["total_items"] || 0
  end

  def errors
    job_metadata["errors"] || []
  end

  def idle_or_failed?
    %w[idle failed].include?(import_status)
  end

  def running?
    import_status == "running"
  end

  def completed?
    import_status == "completed"
  end

  def failed?
    import_status == "failed"
  end

  def can_start_import?
    items_to_import.any?
  end

  def items_to_import_count
    items_to_import.count
  end

  def linked_items_count
    linked_items.count
  end

  def items_without_match_count
    items_without_match.count
  end

  def total_items_count
    all_items.count
  end
end
