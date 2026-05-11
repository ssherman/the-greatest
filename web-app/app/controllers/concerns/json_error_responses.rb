module JsonErrorResponses
  extend ActiveSupport::Concern

  included do
    rescue_from Pundit::NotAuthorizedError do |_e|
      render_forbidden
    end

    rescue_from ActiveRecord::RecordNotFound do |_e|
      render_not_found
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      render_validation_failed(e.record)
    end

    # CDN-cached pages can't carry a fresh CSRF token via <meta>, so the modal
    # awaits one from /user_list_state. If a mutation fires before that token
    # is in memory, Rails raises this — keep the JSON shape consistent.
    rescue_from ActionController::InvalidAuthenticityToken do
      render json: error_body(:forbidden, "Invalid or missing CSRF token"), status: :forbidden
    end
  end

  private

  def render_unauthenticated
    render json: error_body(:unauthenticated, "Sign in required"), status: :unauthorized
  end

  def render_forbidden
    render json: error_body(:forbidden, "Not authorized"), status: :forbidden
  end

  def render_not_found
    render json: error_body(:not_found, "Not found"), status: :not_found
  end

  def render_conflict(message = "Already exists")
    render json: error_body(:conflict, message), status: :conflict
  end

  def render_validation_failed(record)
    message = record.errors.full_messages.first || "Validation failed"
    body = error_body(:validation_failed, message)
    body[:error][:details] = record.errors.messages
    render json: body, status: :unprocessable_entity
  end

  def error_body(code, message)
    {error: {code: code.to_s, message: message}}
  end
end
