# frozen_string_literal: true

# View helpers for the Song List Wizard.
# Used in the wizard step views to render components and determine UI state.
module Admin::Music::Songs::ListWizardHelper
  # Renders the appropriate step component based on the current step name.
  #
  # @param step_name [String] the current step (source, parse, enrich, etc.)
  # @param list [Music::Songs::List] the list being imported
  # @return [String] rendered HTML for the step component
  def render_songs_step_component(step_name, list)
    case step_name
    when "source"
      render(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: list))
    when "parse"
      render(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: list))
    when "enrich"
      render(Admin::Music::Songs::Wizard::EnrichStepComponent.new(list: list))
    when "validate"
      render(Admin::Music::Songs::Wizard::ValidateStepComponent.new(list: list))
    when "review"
      render(Admin::Music::Songs::Wizard::ReviewStepComponent.new(
        list: list,
        items: @items || [],
        total_count: @total_count || 0,
        valid_count: @valid_count || 0,
        invalid_count: @invalid_count || 0,
        missing_count: @missing_count || 0
      ))
    when "import"
      render(Admin::Music::Songs::Wizard::ImportStepComponent.new(list: list))
    when "complete"
      render(Admin::Music::Songs::Wizard::CompleteStepComponent.new(list: list))
    end
  end

  # Determines whether the Next button should be enabled for the current step.
  #
  # @param step_name [String] the current step name
  # @param list [Music::Songs::List] the list being imported
  # @return [Boolean] true if advancement is allowed
  def step_ready_to_advance?(step_name, list)
    case step_name
    when "source"
      list.wizard_state&.[]("import_source").present?
    when "complete"
      false
    else
      list.wizard_manager.step_status(step_name) != "running"
    end
  end

  # Returns the label for the Next button based on the current step.
  #
  # @param step_name [String] the current step name
  # @return [String] button label with arrow
  def next_button_label(step_name)
    case step_name
    when "review" then "Import →"
    when "import" then "Complete →"
    else "Next →"
    end
  end

  # Returns human-readable status text for a wizard step.
  #
  # @param list [Music::Songs::List] the list with wizard state
  # @param step_name [String] the step to get status for (defaults to current step)
  # @return [String] status description
  def job_status_text(list, step_name = nil)
    manager = list.wizard_manager
    step_name ||= manager.current_step_name
    status = manager.step_status(step_name)
    metadata = manager.step_metadata(step_name)

    case status
    when "idle" then "Ready to parse"
    when "running" then "Parsing HTML..."
    when "completed" then "Complete! Parsed #{metadata["total_items"] || 0} items"
    when "failed" then "Parsing failed"
    else "Unknown status"
    end
  end
end
