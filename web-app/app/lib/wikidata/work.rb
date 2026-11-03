# frozen_string_literal: true

module Wikidata
  # Read-only view of a WorkDistiller payload, built the same way from a
  # stored external_records row and from a fresh fetch.
  class Work
    WRITTEN_WORK_TYPES = %w[
      Q7725634 Q47461344 Q571 Q8261 Q5185279 Q25379 Q35760 Q49084 Q1279564 Q12106333 Q725377 Q8274 Q1004 Q7725310
    ].freeze
    EDITION_TYPE = "Q3331189"

    attr_reader :payload

    def self.from_payload(payload) = new(payload)

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def id = payload["id"]

    def label = payload["label"]

    def description = payload["description"]

    def enwiki_title = payload["enwiki_title"]

    def identifiers = payload["identifiers"].is_a?(Hash) ? payload["identifiers"] : {}

    def publication_years = Array(payload["publication_years"]).map(&:to_i)

    %w[instance_of authors edition_of countries languages genres main_subjects narrative_locations
      set_in_periods forms].each do |key|
      define_method(key) { Array(payload[key]) }
    end

    def written_work? = (instance_of + forms).intersect?(WRITTEN_WORK_TYPES)

    def edition? = instance_of.include?(EDITION_TYPE)
  end
end
