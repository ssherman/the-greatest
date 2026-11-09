# frozen_string_literal: true

require "faraday"
require "json"

module Wikidata
  # HTTP transport for the local Wikidata service: Faraday and JSON in, parsed
  # JSON out, typed Wikidata::Exceptions on failure. A copy of the shape of
  # Books::WorldCat::BaseClient, behind the same source-agnostic circuit
  # breaker. Only "the service is unhealthy" (network, timeout, 5xx, an open
  # circuit) counts against the breaker and raises Unavailable; a 4xx or a
  # non-JSON body is a ServiceError, raised after the breaker has seen a
  # healthy reply.
  #
  # The log filters exist because the service sits behind Cloudflare Access:
  # the token secret is a request header and Access answers with a signed
  # CF_Authorization cookie. Neither may reach a log line.
  class Service
    attr_reader :config, :breaker

    def initialize(config = nil, breaker: nil)
      @config = config || Configuration.new
      @breaker = breaker || Books::OpenLibrary::CircuitBreaker.new(key: "wikidata:service", failure_threshold: 5, cooldown: 60)
      @connection = build_connection
    end

    # @return [Hash] the parsed JSON body
    def post(path, body)
      perform(path) do
        @connection.post(path) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = body.to_json
        end
      end
    end

    def get(path, params = {})
      perform(path) { @connection.get(path) { |req| req.params = params } }
    end

    private

    def build_connection
      Faraday.new(url: config.base_url) do |conn|
        conn.options.timeout = config.timeout
        conn.options.open_timeout = config.open_timeout
        conn.headers["User-Agent"] = config.user_agent
        conn.headers["Accept"] = "application/json"
        config.access.headers.each { |name, value| conn.headers[name] = value }

        if config.logger
          conn.response :logger, config.logger, bodies: false do |logger|
            logger.filter(/(CF-Access-Client-Secret: )"[^"]*"/, '\1"[FILTERED]"')
            logger.filter(/(CF_Authorization=)[^;"]+/, '\1[FILTERED]')
          end
        end

        conn.adapter Faraday.default_adapter
      end
    end

    def perform(path)
      response = nil
      breaker.call do
        response = yield
        raise Exceptions::Unavailable, "Wikidata service answered #{response.status} for #{path}" if response.status >= 500
      end

      unless (200..299).cover?(response.status)
        raise Exceptions::ServiceError.new("Wikidata service answered #{response.status} for #{path}", response.status)
      end
      parse_json(response.body, path)
    rescue Books::OpenLibrary::Exceptions::CircuitOpenError => e
      raise Exceptions::Unavailable, e.message
    rescue Faraday::Error => e
      raise Exceptions::Unavailable, "Wikidata service unreachable (#{e.class}): #{e.message}"
    end

    def parse_json(body, path)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Exceptions::ServiceError, "Wikidata service sent unparseable JSON for #{path}: #{e.message}"
    end
  end
end
