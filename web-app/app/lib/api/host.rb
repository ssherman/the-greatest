# frozen_string_literal: true

# The canonical absolute origin for the current site. Every URL the API emits
# is built from here, never from request.host: in production config.hosts is
# unset and nginx forwards the raw Host header, so request.host is whatever the
# client sent. config.domains is the same source config/routes.rb constrains on.
module Api
  module Host
    def self.base_url(domain = Current.domain)
      # :books is also ApplicationController#detect_current_domain's fallback.
      host = Rails.application.config.domains.fetch(domain || :books).split(",").first
      "https://#{host}"
    end
  end
end
