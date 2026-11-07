# frozen_string_literal: true

module Oauth
  # What counts as a loopback redirect URI, in one place.
  #
  # RFC 8252 section 7.3 lets a native client (Claude Code, Codex) register
  # `http://localhost/callback` and then listen on whatever port it gets, so
  # the port is ignored when a loopback redirect URI is compared. Doorkeeper's
  # own loopback test goes through IPAddr, which never treats the name
  # `localhost` as loopback, so the matching rule is patched to use this module
  # (config/initializers/doorkeeper.rb). Registration (DCR) and the
  # `force_ssl_in_redirect_uri` rule use it too, so all three agree.
  module RedirectUris
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

    # Only these three literal hosts. Not "127.0.0.2", not "localhost.evil.test".
    def self.loopback_host?(host)
      LOOPBACK_HOSTS.include?(host.to_s.downcase)
    end

    # http (never https) and a loopback host. Takes a String or a URI.
    def self.loopback?(uri)
      parsed = parse(uri)
      !parsed.nil? && parsed.scheme == "http" && loopback_host?(parsed.host)
    end

    # The dynamic client registration rule (D6): https with a host, or http on
    # a loopback host; never a fragment, never userinfo.
    def self.valid_registration?(string)
      return false unless string.is_a?(String) && string.present?

      parsed = parse(string)
      return false if parsed.nil?
      return false if parsed.fragment.present? || parsed.userinfo.present? || string.include?("#")

      case parsed.scheme
      when "https" then parsed.host.present?
      when "http" then loopback_host?(parsed.host)
      else false
      end
    end

    def self.parse(uri)
      uri.is_a?(URI::Generic) ? uri : URI.parse(uri.to_s)
    rescue URI::InvalidURIError
      nil
    end
    private_class_method :parse
  end
end
