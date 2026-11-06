# frozen_string_literal: true

module Api
  # What an endpoint backed by the OpenSearch index shares: how `q` is read and
  # bounded, and what an outage of the index answers.
  #
  # Every model and search reference in an including controller is root-anchored
  # (::Books::…, ::Search::…): inside Api::V1 a bare Books:: resolves to
  # Api::V1::Books:: and raises NameError.
  module SearchBacked
    extend ActiveSupport::Concern

    # The most hits a query pages through. Search is a lookup, not an export:
    # a query that matches more than this should be refined.
    SEARCH_LIMIT = 100

    # A query this long is a pasted paragraph, not a search. Left uncapped it
    # exceeds OpenSearch's max_clause_count, and the 400 that comes back is a
    # failure of ours that the client could do nothing about.
    MAX_QUERY_LENGTH = 200

    included do
      # OpenSearch being down is not our bug, so it is a documented 503 and not
      # the generic 500 an unexpected exception gets.
      rescue_from(*::Search::Shared::Client::UNAVAILABLE_ERRORS) do |error|
        Rails.logger.warn("API #{controller_name} unavailable: #{error.class}")
        render_problem(::Api::Problem.new(:search_unavailable, detail: "Search is temporarily unavailable. Retry shortly."))
      end
    end

    private

    # The stripped `q`, or ::Api::Page::InvalidParameter (a 400).
    def search_text!
      raw = params[:q]
      # `q[]=war` arrives as an Array and `q[a]=war` as Parameters: neither is
      # a search string, and to_s would turn it into one.
      raise ::Api::Page::InvalidParameter, "q must be a single value" unless raw.nil? || raw.is_a?(String)

      query = raw.to_s.strip
      raise ::Api::Page::InvalidParameter, "q is required" if query.blank?
      raise ::Api::Page::InvalidParameter, "q must be at most #{MAX_QUERY_LENGTH} characters" if query.length > MAX_QUERY_LENGTH

      query
    end
  end
end
