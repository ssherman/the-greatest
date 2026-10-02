# frozen_string_literal: true

module Wikidata
  # Read-only view of a distilled entity (Distiller's payload), built the
  # same way from a stored external_records row and from a fresh fetch.
  class Entity
    # human, pseudonym, collective pseudonym, human whose existence is
    # disputed (Homer, Q6691, is typed only as that)
    PERSON_TYPES = %w[Q5 Q61002 Q16017119 Q21070568].freeze
    MIN_YEAR_PRECISION = 9 # year; 8 is decade, 7 century

    YearFact = Struct.new(:year, :reason, keyword_init: true)

    attr_reader :payload

    def self.from_payload(payload) = new(payload)

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def id = payload["id"]

    def label = payload["label"]

    def description = payload["description"]

    def aliases = Array(payload["aliases"])

    def instance_of = Array(payload["instance_of"])

    def gender_ids = Array(payload["gender"])

    def citizenship_ids = Array(payload["citizenships"])

    def occupation_ids = Array(payload["occupations"])

    def native_names = Array(payload["native_names"])

    def pseudonyms = Array(payload["pseudonyms"])

    def enwiki_title = payload["enwiki_title"]

    def sitelink_count = payload["sitelink_count"].to_i

    def identifiers(kind) = Array(payload.dig("identifiers", kind.to_s))

    def person? = instance_of.intersect?(PERSON_TYPES)

    # The label and the aliases (English, then all-languages): the names this item answers to.
    def names = ([label] + aliases).compact_blank.uniq

    def birth = year_fact(payload["birth"])

    def death = year_fact(payload["death"])

    def birth_year = birth.year

    def death_year = death.year

    private

    # A year is usable only at year precision or finer, when those values
    # agree, and when it is CE. Otherwise the reason says why: null (no
    # value), unknown (somevalue), imprecise (decade or century only),
    # disagreeing, or bce.
    def year_fact(values)
      values = Array(values)
      known = values.reject { |value| value["unknown"] }
      return YearFact.new(year: nil, reason: values.any? ? "unknown" : "null") if known.empty?

      precise = known.select { |value| value["precision"].to_i >= MIN_YEAR_PRECISION }
      return YearFact.new(year: nil, reason: "imprecise") if precise.empty?

      years = precise.map { |value| value["year"].to_i }.uniq
      return YearFact.new(year: nil, reason: "disagreeing") if years.size > 1
      return YearFact.new(year: nil, reason: "bce") unless years.first.positive?

      YearFact.new(year: years.first, reason: nil)
    end
  end
end
