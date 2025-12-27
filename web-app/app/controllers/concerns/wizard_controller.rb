# frozen_string_literal: true

# WizardController is a reusable concern for implementing multi-step wizard flows
# in admin controllers. It provides a consistent interface for step navigation,
# progress tracking, and background job integration.
#
# == Usage
#
# Include this concern in your wizard controller:
#
#   class Admin::Music::Songs::ListWizardController < Admin::Music::BaseController
#     include WizardController
#
#     STEPS = %w[source parse enrich validate review import complete].freeze
#
#     protected
#
#     def wizard_steps
#       STEPS
#     end
#
#     def wizard_entity
#       @list
#     end
#   end
#
# == Required Implementations
#
# Subclasses must implement:
# - +wizard_steps+ - Returns array of step name strings
# - +wizard_entity+ - Returns the model instance being wizarded
# - +set_wizard_entity+ - Before action to load the entity
#
# == Optional Overrides
#
# - +load_step_data(step_name)+ - Load data needed for a specific step
# - +should_enqueue_job?(step_name)+ - Return true if step needs background job
# - +enqueue_step_job(step_name)+ - Enqueue the background job for a step
# - +advance_step+ - Override to customize step advancement logic
#
# == Routes
#
# Define routes for your wizard controller:
#
#   resource :wizard, only: [:show], controller: "list_wizard" do
#     get "step/:step", action: :show_step, as: :step
#     post "step/:step/advance", action: :advance_step, as: :advance
#     post "step/:step/back", action: :back_step, as: :back
#     get "step/:step/status", action: :step_status, as: :step_status
#     post "restart", action: :restart
#   end
#
# == Wizard State
#
# The wizard state is stored as JSON on the entity model. Expected format:
#
#   {
#     "current_step" => 0,
#     "started_at" => "2025-01-19T10:00:00Z",
#     "completed_at" => nil,
#     "import_source" => "custom_html",
#     "steps" => {
#       "parse" => { "status" => "completed", "progress" => 100 }
#     }
#   }
#
module WizardController
  extend ActiveSupport::Concern

  included do
    before_action :set_wizard_entity
    before_action :validate_step, only: [:show_step, :step_status, :advance_step, :back_step]
  end

  # Redirects to the current step in the wizard.
  # This is the entry point when accessing the wizard without a specific step.
  def show
    redirect_to action: :show_step, step: wizard_steps[wizard_entity.wizard_manager.current_step]
  end

  # Renders the view for a specific wizard step.
  # Sets up @step_name, @step_index, and @wizard_steps instance variables.
  # Calls +load_step_data+ to allow subclasses to load step-specific data.
  def show_step
    @step_name = params[:step]
    @step_index = wizard_steps.index(@step_name)
    @wizard_steps = wizard_steps
    load_step_data(@step_name)
  end

  # Returns JSON status of the current step for AJAX polling.
  # Used by the wizard_step Stimulus controller to poll for job completion.
  #
  # @return [JSON] status, progress, error, and metadata for the step
  def step_status
    # Use step parameter if provided, otherwise fall back to current step
    manager = wizard_entity.wizard_manager
    step_name = params[:step] || manager.current_step_name

    render json: {
      status: manager.step_status(step_name),
      progress: manager.step_progress(step_name),
      error: manager.step_error(step_name),
      metadata: manager.step_metadata(step_name)
    }
  end

  # Advances the wizard to the next step.
  # Updates current_step in wizard_state and optionally enqueues a background job.
  # Override this method in subclasses to implement custom step advancement logic.
  def advance_step
    current_step_index = wizard_steps.index(params[:step])
    next_step_index = current_step_index + 1

    if next_step_index < wizard_steps.length
      wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("current_step" => next_step_index))
      enqueue_step_job(wizard_steps[next_step_index]) if should_enqueue_job?(wizard_steps[next_step_index])
      redirect_to action: :show_step, step: wizard_steps[next_step_index]
    else
      wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("completed_at" => Time.current.iso8601))
      redirect_to action: :show_step, step: wizard_steps.last
    end
  end

  # Moves the wizard back to the previous step.
  # Respects step 0 as the minimum (cannot go before first step).
  def back_step
    current_step_index = wizard_steps.index(params[:step])
    previous_step_index = [current_step_index - 1, 0].max

    wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("current_step" => previous_step_index))
    redirect_to action: :show_step, step: wizard_steps[previous_step_index]
  end

  # Resets the wizard to its initial state and redirects to the first step.
  # Calls +reset!+ on the wizard manager to clear all wizard state.
  def restart
    wizard_entity.wizard_manager.reset!
    redirect_to action: :show
  end

  protected

  # Returns the ordered array of step names for this wizard.
  # Must be implemented by subclasses.
  #
  # @return [Array<String>] step names in order
  # @raise [NotImplementedError] if not implemented
  def wizard_steps
    raise NotImplementedError, "Subclass must implement wizard_steps - returns array of step names"
  end

  # Returns the model instance being wizarded (e.g., the List being imported).
  # Must be implemented by subclasses.
  #
  # @return [ApplicationRecord] the entity with wizard_state
  # @raise [NotImplementedError] if not implemented
  def wizard_entity
    raise NotImplementedError, "Subclass must implement wizard_entity - returns the model instance"
  end

  # Hook for loading step-specific data before rendering.
  # Override in subclass to set instance variables needed by step components.
  #
  # @param step_name [String] the current step being displayed
  def load_step_data(step_name)
  end

  # Hook for enqueuing a background job when entering a step.
  # Override in subclass to start async processing.
  #
  # @param step_name [String] the step to enqueue a job for
  def enqueue_step_job(step_name)
  end

  # Determines whether a step requires a background job.
  # Override in subclass to return true for job-based steps.
  #
  # @param step_name [String] the step to check
  # @return [Boolean] true if step needs a job
  def should_enqueue_job?(step_name)
    false
  end

  private

  # Validates that the step parameter matches a valid step name.
  # Redirects to show action if step is invalid.
  def validate_step
    step_name = params[:step]
    unless wizard_steps.include?(step_name)
      redirect_to action: :show, alert: "Invalid step"
    end
  end
end
