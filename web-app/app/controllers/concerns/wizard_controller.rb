# frozen_string_literal: true

module WizardController
  extend ActiveSupport::Concern

  included do
    before_action :set_wizard_entity
    before_action :validate_step, only: [:show_step, :step_status, :advance_step, :back_step]
  end

  def show
    redirect_to action: :show_step, step: wizard_steps[wizard_entity.wizard_current_step]
  end

  def show_step
    @step_name = params[:step]
    @step_index = wizard_steps.index(@step_name)
    @wizard_steps = wizard_steps
    load_step_data(@step_name)
  end

  def step_status
    # Use step parameter if provided, otherwise fall back to current step
    step_name = params[:step] || wizard_entity.current_step_name

    render json: {
      status: wizard_entity.wizard_step_status(step_name),
      progress: wizard_entity.wizard_step_progress(step_name),
      error: wizard_entity.wizard_step_error(step_name),
      metadata: wizard_entity.wizard_step_metadata(step_name)
    }
  end

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

  def back_step
    current_step_index = wizard_steps.index(params[:step])
    previous_step_index = [current_step_index - 1, 0].max

    wizard_entity.update!(wizard_state: (wizard_entity.wizard_state || {}).merge("current_step" => previous_step_index))
    redirect_to action: :show_step, step: wizard_steps[previous_step_index]
  end

  def restart
    wizard_entity.reset_wizard!
    redirect_to action: :show
  end

  protected

  def wizard_steps
    raise NotImplementedError, "Subclass must implement wizard_steps - returns array of step names"
  end

  def wizard_entity
    raise NotImplementedError, "Subclass must implement wizard_entity - returns the model instance"
  end

  def load_step_data(step_name)
  end

  def enqueue_step_job(step_name)
  end

  def should_enqueue_job?(step_name)
    false
  end

  private

  def validate_step
    step_name = params[:step]
    unless wizard_steps.include?(step_name)
      redirect_to action: :show, alert: "Invalid step"
    end
  end
end
