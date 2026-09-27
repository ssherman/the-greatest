# frozen_string_literal: true

require "faraday"
require "json"

module Wikimedia
  # The one HTTP path to every Wikimedia host. Adds the policy User-Agent,
  # takes a slot from the shared pace before each request, and turns the
  # hosts' back-off signals (a 429, a maxlag error) into RateLimited.
  #
  # The pace is an :immediate DistributedRateLimiter, but a request waits
  # inline for a slot up to max_inline_wait seconds: one author costs about
  # eight requests at one a second, so failing on the first busy slot would
  # reschedule every job forever. Only a longer wait (several workers
  # competing) becomes RateLimited, so no thread sleeps for long.
  class Http
    Response = Struct.new(:data, :body, keyword_init: true)

    USER_AGENT = "TheGreatest/1.0 (%s)"
    LIMITER_KEY = "wikimedia:api"
    TIMEOUT = 30
    OPEN_TIMEOUT = 10
    DEFAULT_RETRY_AFTER = 60
    MIN_SLEEP = 0.05

    attr_reader :settings

    def initialize(settings: Rails.application.config.x.wikimedia, limiter: nil, sleeper: nil)
      @settings = settings
      @limiter = limiter || ::DistributedRateLimiter.new(
        key: LIMITER_KEY, limit: settings.requests_per_window, window: settings.window_seconds, mode: :immediate
      )
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def user_agent = format(USER_AGENT, settings.contact)

    # GET against an Action API endpoint (www.wikidata.org or a Wikipedia).
    def action_api(url, params)
      response = perform(:get, url, params.merge(format: "json", formatversion: 2, maxlag: settings.maxlag))
      data = parse(response)
      error = data.is_a?(Hash) ? data["error"] : nil
      raise Exceptions::ApiError.new("Wikimedia API error #{error["code"]}: #{error["info"]}", error["code"].to_s) if error

      Response.new(data: data, body: response.body)
    end

    # POST to the Wikidata Query Service, so a long VALUES list fits.
    def sparql(url, query)
      response = perform(:post, url, {query: query}, accept: "application/sparql-results+json")
      Response.new(data: parse(response), body: response.body)
    end

    private

    def perform(verb, url, params, accept: "application/json")
      acquire_slot!
      headers = {"User-Agent" => user_agent, "Accept" => accept}
      response = if verb == :get
        connection.get(url, params, headers)
      else
        connection.post(url, URI.encode_www_form(params), headers.merge("Content-Type" => "application/x-www-form-urlencoded"))
      end
      check_status!(response)
      response
    rescue Faraday::TimeoutError => e
      raise Exceptions::TimeoutError.new("Wikimedia request timed out", e)
    rescue Faraday::ConnectionFailed => e
      raise Exceptions::NetworkError.new("Wikimedia connection failed: #{e.message}", e)
    rescue Faraday::Error => e
      raise Exceptions::NetworkError.new("Wikimedia network error: #{e.message}", e)
    end

    def check_status!(response)
      if response.status == 429 || maxlag?(response)
        raise Exceptions::RateLimited.new("Wikimedia asked us to wait (HTTP #{response.status})", retry_after: retry_after(response))
      end
      return if response.status == 200

      message = if response.status == 403
        "Wikimedia refused the request (403). Check the User-Agent policy before retrying."
      else
        "Wikimedia returned HTTP #{response.status}"
      end
      raise Exceptions::HttpError.new(message, response.status, response.body)
    end

    def maxlag?(response)
      return false unless response.body.to_s.include?("maxlag")

      JSON.parse(response.body).dig("error", "code") == "maxlag"
    rescue JSON::ParserError, TypeError
      false
    end

    def retry_after(response)
      value = Integer(response.headers["retry-after"].to_s, exception: false)
      value&.positive? ? value : DEFAULT_RETRY_AFTER
    end

    def parse(response)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Exceptions::ParseError, "Wikimedia returned invalid JSON: #{e.message}"
    end

    def acquire_slot!
      waited = 0.0
      begin
        @limiter.acquire!
      rescue ::DistributedRateLimiter::RateLimitExceeded => e
        wait = [e.retry_after.to_f, MIN_SLEEP].max
        if waited + wait > settings.max_inline_wait
          raise Exceptions::RateLimited.new("Wikimedia pace still busy after #{waited.round(2)}s", retry_after: wait.ceil)
        end

        @sleeper.call(wait)
        waited += wait
        retry
      end
    end

    def connection
      @connection ||= Faraday.new do |conn|
        conn.options.timeout = TIMEOUT
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.adapter Faraday.default_adapter
      end
    end
  end
end
