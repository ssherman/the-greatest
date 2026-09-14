# frozen_string_literal: true

module Api
  # Renders ::Api::Problem bodies and maps the exceptions the API expects onto
  # them. Anything not listed here is a bug and reaches Rails' own handler
  # (a generic JSON 500) -- deliberately not rescued, so tests fail loudly
  # instead of passing against a friendly body.
  module ErrorRendering
    extend ActiveSupport::Concern

    included do
      rescue_from ActiveRecord::RecordNotFound do
        render_problem(::Api::Problem.new(:not_found, detail: "No #{controller_name.singularize} with that slug"))
      end

      rescue_from ::Api::Page::InvalidParameter do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end

      rescue_from ActionController::ParameterMissing do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end
    end

    private

    def render_problem(problem, www_authenticate: nil)
      response.headers["WWW-Authenticate"] = www_authenticate if www_authenticate
      render json: problem.to_h, status: problem.status, content_type: ::Api::Problem::CONTENT_TYPE
    end
  end
end
