# frozen_string_literal: true

module CloudflareAccess
  # The service token Rails presents to the Cloudflare Access applications in
  # front of the home server's tunnels (docs/features/home-server.md). Both
  # halves or neither: a client sending one gets Access's login page back.
  class Credentials
    attr_reader :client_id, :client_secret

    def self.from_env
      new(client_id: ENV["CLOUDFLARE_ACCESS_CLIENT_ID"], client_secret: ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"])
    end

    def initialize(client_id:, client_secret:)
      @client_id = client_id.presence
      @client_secret = client_secret.presence
    end

    def configured?
      !client_id.nil? && !client_secret.nil?
    end

    def partial?
      client_id.nil? != client_secret.nil?
    end

    def headers
      return {} unless configured?

      {"CF-Access-Client-Id" => client_id, "CF-Access-Client-Secret" => client_secret}
    end

    # The secret must never reach a log line or an exception message.
    def inspect
      "#<#{self.class.name} configured=#{configured?}>"
    end
    alias_method :to_s, :inspect
  end
end
