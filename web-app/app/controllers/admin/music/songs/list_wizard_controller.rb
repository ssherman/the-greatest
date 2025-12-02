# frozen_string_literal: true

class Admin::Music::Songs::ListWizardController < Admin::Music::BaseController
  include WizardController

  STEPS = %w[source parse enrich validate review import complete].freeze

  def save_html
    wizard_entity.update!(raw_html: params[:raw_html])
    redirect_to action: :show_step, step: "parse", notice: "HTML saved successfully"
  end

  def reparse
    wizard_entity.reset_wizard_step!("parse")
    wizard_entity.list_items.unverified.destroy_all
    redirect_to action: :show_step, step: "parse", notice: "Ready to re-parse. Click 'Start Parsing' to begin."
  end

  def advance_step
    if params[:step] == "source"
      advance_from_source_step
    elsif params[:step] == "parse"
      advance_from_parse_step
    elsif params[:step] == "enrich"
      advance_from_enrich_step
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
    @raw_html_preview = @list.raw_html&.truncate(500) || "(No HTML provided)"
    @parsed_count = @list.list_items.unverified.count
  end

  def load_enrich_step_data
    @unverified_items = @list.list_items.unverified.ordered
    @total_items = @unverified_items.count
    @enriched_items = @unverified_items.where.not(listable_id: nil)
    @enriched_count = @enriched_items.count
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
    Music::Songs::WizardParseListJob.perform_async(wizard_entity.id)
  end

  def enqueue_enrich_job
    Music::Songs::WizardEnrichListItemsJob.perform_async(wizard_entity.id)
  end

  def enqueue_validate_job
  end

  def enqueue_import_job
  end

  def advance_from_source_step
    # Use provided import_source, or fall back to existing selection, or default to custom_html
    import_source = params[:import_source].presence ||
      wizard_entity.wizard_state&.[]("import_source") ||
      "custom_html"

    next_step_index = if import_source == "musicbrainz_series"
      5
    else
      1
    end

    wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge(
      "current_step" => next_step_index,
      "import_source" => import_source
    ))

    redirect_to action: :show_step, step: wizard_steps[next_step_index]
  end

  def advance_from_parse_step
    parse_status = wizard_entity.wizard_step_status("parse")

    if parse_status == "idle" || parse_status == "failed"
      # Set status to running BEFORE enqueuing so the redirect renders with polling enabled
      wizard_entity.update_wizard_step_status(step: "parse", status: "running", progress: 0)
      Music::Songs::WizardParseListJob.perform_async(wizard_entity.id)
      redirect_to action: :show_step, step: "parse", notice: "Parsing started"
    elsif parse_status == "completed"
      current_step_index = wizard_steps.index(params[:step])
      next_step_index = current_step_index + 1

      if next_step_index < wizard_steps.length
        # Only update current_step - preserve parse status for back navigation
        wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("current_step" => next_step_index))
        redirect_to action: :show_step, step: wizard_steps[next_step_index]
      else
        wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("completed_at" => Time.current.iso8601))
        redirect_to action: :show_step, step: wizard_steps.last
      end
    else
      redirect_to action: :show_step, step: "parse", alert: "Parsing in progress, please wait"
    end
  end

  def advance_from_enrich_step
    enrich_status = wizard_entity.wizard_step_status("enrich")

    if params[:reenrich] == "true"
      # Re-enrich: reset step and start again
      wizard_entity.update_wizard_step_status(step: "enrich", status: "running", progress: 0, error: nil, metadata: {})
      Music::Songs::WizardEnrichListItemsJob.perform_async(wizard_entity.id)
      redirect_to action: :show_step, step: "enrich", notice: "Re-enrichment started"
    elsif enrich_status == "idle" || enrich_status == "failed"
      wizard_entity.update_wizard_step_status(step: "enrich", status: "running", progress: 0, error: nil, metadata: {})
      Music::Songs::WizardEnrichListItemsJob.perform_async(wizard_entity.id)
      redirect_to action: :show_step, step: "enrich", notice: "Enrichment started"
    elsif enrich_status == "completed"
      current_step_index = wizard_steps.index(params[:step])
      next_step_index = current_step_index + 1

      if next_step_index < wizard_steps.length
        # Only update current_step - preserve enrich status for back navigation
        wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("current_step" => next_step_index))
        redirect_to action: :show_step, step: wizard_steps[next_step_index]
      else
        wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("completed_at" => Time.current.iso8601))
        redirect_to action: :show_step, step: wizard_steps.last
      end
    else
      redirect_to action: :show_step, step: "enrich", alert: "Enrichment in progress, please wait"
    end
  end
end
