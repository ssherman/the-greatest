# frozen_string_literal: true

class Authentication::WidgetComponent < ViewComponent::Base
  def initialize(reload_after_auth: false, css_class: nil)
    @reload_after_auth = reload_after_auth
    @css_class = css_class
  end

  private

  attr_reader :reload_after_auth, :css_class

  def container_classes
    classes = ["authentication-widget"]
    classes << css_class if css_class.present?
    classes.join(" ")
  end

  def reload_after_auth_data
    reload_after_auth ? "true" : "false"
  end

  def oauth_providers
    @oauth_providers ||= Services::AuthProviderRegistry.enabled_for_view
  end

  # The client needs firebase_id and scopes to construct the provider; the id
  # is what the action param carries back. Serialised whole rather than
  # per-button so the controller can resolve an unknown id to a real error
  # instead of an unhandled rejection.
  def oauth_providers_json
    oauth_providers.to_json
  end
end
