# frozen_string_literal: true

# BaseListWizardController provides shared functionality for media list import wizards.
# Used by Music::Songs and Music::Albums ListWizardControllers.
#
# == Wizard Steps
#
# 1. *source* - Select import source (custom_html or musicbrainz_series)
# 2. *parse* - Parse HTML to extract items (custom_html only)
# 3. *enrich* - Enrich items with MusicBrainz data
# 4. *validate* - AI validation of matches
# 5. *review* - Manual review and verification
# 6. *import* - Import verified items into the list
# 7. *complete* - Wizard completion summary
#
# == Subclass Requirements
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - enrichment_id_key: Metadata key for MusicBrainz ID (e.g., "mb_recording_id")
#   - job_step_config: Hash of step configurations with job classes
#
class Admin::Music::BaseListWizardController < Admin::Music::BaseController
  include WizardController

  # Ordered list of wizard step names
  STEPS = %w[source parse enrich validate review import complete].freeze

  # Valid import source types
  VALID_IMPORT_SOURCES = %w[custom_html musicbrainz_series].freeze

  # Saves raw HTML content for parsing.
  # Called from the source step when user provides custom HTML.
  def save_html
    wizard_entity.update!(raw_html: params[:raw_html])
    redirect_to action: :show_step, step: "parse", notice: "HTML saved successfully"
  end

  # Resets the parse step to allow re-parsing.
  # Destroys all unverified list items and resets step status.
  def reparse
    wizard_entity.wizard_manager.reset_step!("parse")
    wizard_entity.list_items.unverified.destroy_all
    redirect_to action: :show_step, step: "parse", notice: "Ready to re-parse. Click 'Start Parsing' to begin."
  end

  # Advances the wizard based on the current step.
  # Dispatches to step-specific handlers for custom logic.
  def advance_step
    case params[:step]
    when "source"
      advance_from_source_step
    when "parse"
      advance_from_parse_step
    when "enrich"
      advance_from_enrich_step
    when "validate"
      advance_from_validate_step
    when "review"
      advance_from_review_step
    when "import"
      advance_from_import_step
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
    job_class = job_step_config.dig(step_name, :job_class)&.constantize
    job_class&.perform_async(wizard_entity.id)
  end

  private

  def set_wizard_entity
    @list = list_class.find(params[:list_id])
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
    @unverified_items = @list.list_items.unverified.ordered
    @enriched_items = @unverified_items.select do |item|
      item.listable_id.present? ||
        item.metadata[entity_id_key].present? ||
        item.metadata[enrichment_id_key].present?
    end
    @total_items = @unverified_items.count
    @items_to_validate = @enriched_items.count
  end

  def load_review_step_data
    @items = @list.list_items.ordered.includes(listable: :artists)
    @total_count = @items.count
    @valid_count = @items.count(&:verified?)
    @invalid_count = @items.count { |i| i.metadata["ai_match_invalid"] }
    @missing_count = @total_count - @valid_count - @invalid_count
  end

  def load_import_step_data
    import_source = @list.wizard_state&.dig("import_source") || "custom_html"

    if import_source == "custom_html"
      @all_items = @list.list_items.ordered
      @linked_items = @all_items.where.not(listable_id: nil)
      @items_to_import = @all_items.where(listable_id: nil)
        .where("metadata->>'#{enrichment_id_key}' IS NOT NULL")
      @items_without_match = @all_items.where(listable_id: nil)
        .where("metadata->>'#{enrichment_id_key}' IS NULL")
    end
  end

  def load_complete_step_data
  end

  # Handles advancement for job-based wizard steps.
  # Manages the three states: idle/failed, running, and completed.
  #
  # @param step_name [String] the current step name
  # @param config [Hash] step configuration from job_step_config
  # @return [void] redirects to appropriate page
  def advance_from_job_step(step_name, config)
    status = wizard_entity.wizard_manager.step_status(step_name)
    job_class = config[:job_class].constantize
    action_name = config[:action_name]
    re_run_param = config[:re_run_param]

    # Handle re-execution if param is set and step supports it
    if re_run_param && params[re_run_param] == "true"
      start_job(step_name, job_class)
      redirect_to action: :show_step, step: step_name, notice: "Re-#{action_name.downcase} started"
      return
    end

    if status == "idle" || status == "failed"
      start_job(step_name, job_class)
      redirect_to action: :show_step, step: step_name, notice: "#{action_name} started"
    elsif status == "completed"
      navigate_to_next_step(set_completed: config[:set_completed_on_advance])
    else
      redirect_to action: :show_step, step: step_name, alert: "#{action_name} in progress, please wait"
    end
  end

  # Sets step status to running and enqueues the background job.
  #
  # @param step_name [String] the step to start
  # @param job_class [Class] the Sidekiq job class to enqueue
  def start_job(step_name, job_class)
    wizard_entity.wizard_manager.update_step_status!(step: step_name, status: "running", progress: 0, error: nil, metadata: {})
    job_class.perform_async(wizard_entity.id)
  end

  # Navigates to the next wizard step or marks wizard as complete.
  #
  # @param set_completed [Boolean] whether to set completed_at timestamp
  def navigate_to_next_step(set_completed: false)
    current_step_index = wizard_steps.index(params[:step])
    next_step_index = current_step_index + 1

    if next_step_index < wizard_steps.length
      state_updates = {"current_step" => next_step_index}
      state_updates["completed_at"] = Time.current.iso8601 if set_completed
      wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge(state_updates))
      redirect_to action: :show_step, step: wizard_steps[next_step_index]
    else
      wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("completed_at" => Time.current.iso8601))
      redirect_to action: :show_step, step: wizard_steps.last
    end
  end

  # Handles the source step which selects the import method.
  # Routes to parse step for custom_html, or review step for musicbrainz_series.
  def advance_from_source_step
    import_source = params[:import_source].presence ||
      wizard_entity.wizard_state&.[]("import_source")

    unless import_source.present? && VALID_IMPORT_SOURCES.include?(import_source)
      redirect_to action: :show_step, step: "source", alert: "Please select an import source"
      return
    end

    # Extract batch_mode parameter (checkbox returns "1" when checked, nil when unchecked)
    batch_mode = params[:batch_mode] == "1"

    next_step_index = (import_source == "musicbrainz_series") ? 5 : 1

    wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge(
      "current_step" => next_step_index,
      "import_source" => import_source,
      "batch_mode" => batch_mode
    ))

    redirect_to action: :show_step, step: wizard_steps[next_step_index]
  end

  def advance_from_parse_step
    advance_from_job_step("parse", job_step_config["parse"])
  end

  def advance_from_enrich_step
    advance_from_job_step("enrich", job_step_config["enrich"])
  end

  def advance_from_validate_step
    advance_from_job_step("validate", job_step_config["validate"])
  end

  # Validates that there are items to import before proceeding.
  def advance_from_review_step
    items = wizard_entity.list_items
    valid_count = items.count(&:verified?)

    if valid_count.zero?
      redirect_to action: :show_step, step: "review", alert: "No valid items to import. Please fix invalid or missing items first."
      return
    end

    navigate_to_next_step
  end

  def advance_from_import_step
    advance_from_job_step("import", job_step_config["import"])
  end

  # Abstract methods - subclasses must implement

  def list_class
    raise NotImplementedError, "Subclass must implement #list_class"
  end

  def entity_id_key
    raise NotImplementedError, "Subclass must implement #entity_id_key"
  end

  def enrichment_id_key
    raise NotImplementedError, "Subclass must implement #enrichment_id_key"
  end

  def job_step_config
    raise NotImplementedError, "Subclass must implement #job_step_config"
  end
end
