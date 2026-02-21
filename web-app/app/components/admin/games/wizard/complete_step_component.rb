# frozen_string_literal: true

# ViewComponent for the Complete step of the Games List Wizard.
# Shows a summary of the completed import with statistics.
#
class Admin::Games::Wizard::CompleteStepComponent < ViewComponent::Base
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
