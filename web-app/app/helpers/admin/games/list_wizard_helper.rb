# frozen_string_literal: true

# View helpers for the Games List Wizard.
# Used in the wizard step views to render components and determine UI state.
module Admin::Games::ListWizardHelper
  # Renders the appropriate step component based on the current step name.
  def render_games_step_component(step_name, list)
    case step_name
    when "source"
      render(Admin::Games::Wizard::SourceStepComponent.new(list: list))
    when "parse"
      render(Admin::Games::Wizard::ParseStepComponent.new(list: list))
    when "enrich"
      render(Admin::Games::Wizard::EnrichStepComponent.new(list: list))
    when "validate"
      render(Admin::Games::Wizard::ValidateStepComponent.new(list: list))
    when "review"
      items = list.list_items.ordered.includes(listable: {game_companies: :company})
      total_count = items.count
      valid_count = items.count(&:verified?)
      invalid_count = items.count { |i| i.metadata["ai_match_invalid"] }
      missing_count = total_count - valid_count - invalid_count

      render(Admin::Games::Wizard::ReviewStepComponent.new(
        list: list,
        items: items,
        total_count: total_count,
        valid_count: valid_count,
        invalid_count: invalid_count,
        missing_count: missing_count
      ))
    when "import"
      render(Admin::Games::Wizard::ImportStepComponent.new(list: list))
    when "complete"
      render(Admin::Games::Wizard::CompleteStepComponent.new(list: list))
    else
      content_tag(:div, "Step component for '#{step_name}' not yet implemented", class: "alert alert-warning")
    end
  end

  # Determines whether the Next button should be enabled for the current step.
  def games_step_ready_to_advance?(step_name, list)
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
  def games_next_button_label(step_name)
    case step_name
    when "review" then "Import ->"
    when "import" then "Complete ->"
    else "Next ->"
    end
  end
end
