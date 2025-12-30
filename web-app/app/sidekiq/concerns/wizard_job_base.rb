# frozen_string_literal: true

# Shared functionality for wizard background jobs.
# Provides common progress tracking, error handling, and status updates.
#
# Subclasses must implement:
#   - list_class: Model class for list (e.g., Music::Songs::List)
#   - step_name: The wizard step name (e.g., "enrich")
#
module WizardJobBase
  extend ActiveSupport::Concern

  PROGRESS_UPDATE_INTERVAL = 10

  included do
    # Tracks the last time we updated progress
    attr_accessor :last_progress_update
  end

  # Determines if we should update progress based on interval
  def should_update_progress?(index, total)
    return true if (index + 1) == total
    return true if (index + 1) % PROGRESS_UPDATE_INTERVAL == 0
    return true if Time.current - @last_progress_update >= 5.seconds
    false
  end

  # Updates the step status with progress information
  def update_step_progress(list, progress:, metadata: {})
    list.wizard_manager.update_step_status!(
      step: step_name,
      status: "running",
      progress: progress,
      metadata: metadata
    )
    @last_progress_update = Time.current
  end

  # Marks the step as completed
  def complete_step(list, metadata: {})
    list.wizard_manager.update_step_status!(
      step: step_name,
      status: "completed",
      progress: 100,
      metadata: metadata.merge("completed_at" => Time.current.iso8601)
    )
  end

  # Handles step errors
  def handle_step_error(list, error_message)
    list.wizard_manager.update_step_status!(
      step: step_name,
      status: "failed",
      progress: 0,
      error: error_message
    )
  end

  # Finds the list by ID using the subclass's list_class
  def find_list(list_id)
    list_class.find(list_id)
  end

  protected

  # Abstract methods - subclasses must implement

  def list_class
    raise NotImplementedError, "Subclass must implement #list_class"
  end

  def step_name
    raise NotImplementedError, "Subclass must implement #step_name"
  end
end
