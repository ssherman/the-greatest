# frozen_string_literal: true

require "faraday"
require "json"

module Services
  # Reads an account's provider records from Identity Toolkit.
  #
  # Firebase keeps a provider-supplied email on the PROVIDER record and, under
  # this project's "allow multiple accounts with the same email address"
  # setting, does not promote it to the ACCOUNT record -- which is what mints
  # ID tokens. So the address exists, and the token does not carry it. Google's
  # own guidance for that setting is to retrieve it from the identity provider
  # yourself; this is that.
  #
  # Unlike the copy the browser sends, what comes back here is server-to-server
  # from Google and is not attacker-controlled.
  class FirebaseAccountLookup
    BASE_URL = "https://identitytoolkit.googleapis.com"
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    class Error < StandardError; end

    def self.call(uid, project_id:)
      new(uid, project_id).call
    end

    def initialize(uid, project_id)
      @uid = uid
      @project_id = project_id
    end

    def call
      raise Error, "uid is required" if @uid.blank?
      raise Error, "project_id is required" if @project_id.blank?

      response = post_lookup

      unless response.status == 200
        raise Error, "accounts:lookup failed (#{response.status})"
      end

      account = Array(JSON.parse(response.body)["users"]).first
      Array(account && account["providerUserInfo"])
    rescue JSON::ParserError => e
      raise Error, "accounts:lookup returned an unparseable body: #{e.message}"
    rescue Faraday::Error => e
      raise Error, "accounts:lookup request failed: #{e.class}"
    end

    private

    def post_lookup
      connection = Faraday.new(url: BASE_URL) do |conn|
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.options.timeout = READ_TIMEOUT
        conn.adapter Faraday.default_adapter
      end

      connection.post("/v1/projects/#{@project_id}/accounts:lookup") do |req|
        req.headers["Authorization"] = "Bearer #{GoogleServiceAccountToken.access_token}"
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(localId: [@uid])
      end
    end
  end
end
