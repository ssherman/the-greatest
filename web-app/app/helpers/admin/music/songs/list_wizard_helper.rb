# frozen_string_literal: true

module Admin::Music::Songs::ListWizardHelper
  def step_icon(step_name)
    case step_name
    when "source" then "📁"
    when "parse" then "📝"
    when "enrich" then "✨"
    when "validate" then "✓"
    when "review" then "👁"
    when "import" then "📥"
    when "complete" then "✓"
    else "●"
    end
  end

  def render_step_component(step_name, list)
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
        items: @items || []
      ))
    when "import"
      render(Admin::Music::Songs::Wizard::ImportStepComponent.new(list: list))
    when "complete"
      render(Admin::Music::Songs::Wizard::CompleteStepComponent.new(list: list))
    end
  end

  def step_ready_to_advance?(step_name, list)
    case step_name
    when "source"
      list.wizard_state&.[]("import_source").present?
    when "complete"
      false
    else
      list.wizard_job_status != "running"
    end
  end

  def next_button_label(step_name)
    case step_name
    when "review" then "Import →"
    when "import" then "Complete →"
    else "Next →"
    end
  end

  def job_status_text(list)
    case list.wizard_job_status
    when "idle" then "Ready to parse"
    when "running" then "Parsing HTML..."
    when "completed" then "Complete! Parsed #{list.wizard_job_metadata["total_items"] || 0} items"
    when "failed" then "Parsing failed"
    else "Unknown status"
    end
  end
end
