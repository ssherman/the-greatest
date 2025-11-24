# frozen_string_literal: true

class Admin::Music::Songs::ListWizardController < Admin::Music::BaseController
  include WizardController

  STEPS = %w[source parse enrich validate review import complete].freeze

  def advance_step
    if params[:step] == "source"
      advance_from_source_step
    else
      super
    end
  end

  protected

  def wizard_steps
    STEPS
  end

  def wizard_entity
    @list
  end

  def load_step_data(step_name)
    case step_name
    when "source"
      load_source_step_data
    when "parse"
      load_parse_step_data
    when "enrich"
      load_enrich_step_data
    when "validate"
      load_validate_step_data
    when "review"
      load_review_step_data
    when "import"
      load_import_step_data
    when "complete"
      load_complete_step_data
    end
  end

  def should_enqueue_job?(step_name)
    %w[parse enrich validate import].include?(step_name)
  end

  def enqueue_step_job(step_name)
    case step_name
    when "parse"
      enqueue_parse_job
    when "enrich"
      enqueue_enrich_job
    when "validate"
      enqueue_validate_job
    when "import"
      enqueue_import_job
    end
  end

  private

  def set_wizard_entity
    @list = Music::Songs::List.find(params[:list_id])
  end

  def load_source_step_data
  end

  def load_parse_step_data
  end

  def load_enrich_step_data
  end

  def load_validate_step_data
  end

  def load_review_step_data
    @items = @list.list_items.includes(listable: [:artists])
  end

  def load_import_step_data
  end

  def load_complete_step_data
  end

  def enqueue_parse_job
  end

  def enqueue_enrich_job
  end

  def enqueue_validate_job
  end

  def enqueue_import_job
  end

  def advance_from_source_step
    import_source = params[:import_source]

    unless %w[custom_html musicbrainz_series].include?(import_source)
      flash[:alert] = "Please select an import source"
      redirect_to action: :show_step, step: "source"
      return
    end

    next_step_index = if import_source == "musicbrainz_series"
      5
    else
      1
    end

    wizard_entity.update!(wizard_state: wizard_entity.wizard_state.merge(
      "current_step" => next_step_index,
      "import_source" => import_source
    ))

    redirect_to action: :show_step, step: wizard_steps[next_step_index]
  end
end
