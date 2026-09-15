# frozen_string_literal: true

# Resolves which site a request is for from its host and publishes it as
# Current.domain. Shared by ApplicationController (HTML) and Api::V1::BaseController
# (JSON), which is why it does not assume ActionController::Base: helper_method
# only exists on the HTML side.
#
# Unrecognised hosts fall back to :books. In production config.hosts is unset,
# so request.host is client-supplied -- nothing here should ever be used to
# build a URL (see Api::Host and the routes file for the canonical source).
module CurrentDomain
  extend ActiveSupport::Concern

  included do
    before_action :set_current_domain
    helper_method :current_domain, :domain_settings if respond_to?(:helper_method)
  end

  private

  attr_reader :current_domain, :domain_settings

  def set_current_domain
    @current_domain = detect_current_domain
    @domain_settings = Rails.application.config.domain_settings[@current_domain]
    Current.domain = @current_domain

    # Debug logging
    Rails.logger.info "Host: #{request.host}"
    Rails.logger.info "Detected domain: #{@current_domain}"
    Rails.logger.info "Domain settings: #{@domain_settings}"
  end

  def detect_current_domain
    host = request.host

    Rails.application.config.domains.each do |domain, configured|
      return domain if configured.split(",").include?(host)
    end

    :books # default for unrecognized hosts
  end
end
