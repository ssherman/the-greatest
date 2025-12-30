# frozen_string_literal: true

# ViewComponent for the Complete step of the Albums List Wizard.
# Shows a summary of the completed import with statistics.
#
# Displays:
# - Total items in the list
# - Items linked to albums
# - Verified items
# - Links to view the list and return to lists index
class Admin::Music::Albums::Wizard::CompleteStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list

  def total_items
    @total_items ||= list.list_items.count
  end

  def linked_items
    @linked_items ||= list.list_items.where.not(listable_id: nil).count
  end

  def verified_items
    @verified_items ||= list.list_items.verified.count
  end

  def unlinked_items
    total_items - linked_items
  end

  def import_metadata
    list.wizard_manager.step_metadata("import")
  end

  def imported_count
    import_metadata["imported_count"] || 0
  end

  def failed_count
    import_metadata["failed_count"] || 0
  end
end
