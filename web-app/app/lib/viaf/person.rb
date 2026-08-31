# frozen_string_literal: true

module Viaf
  # A distilled VIAF cluster. Always constructed from the persisted payload so
  # a cache hit and a fresh fetch produce an identical object.
  #
  # Every field is optional. The heavily catalogued authors used to design this
  # have 44-48 contributing agencies; a mid-list contemporary novelist may have
  # two, with no gender, no birth date and no ISNI.
  class Person
    GENDER_CODES = {"a" => :female, "b" => :male, "u" => :unspecified}.freeze
    NAME_TYPE_KINDS = {"Personal" => :person, "Corporate" => :organization}.freeze

    attr_reader :viaf_id, :name_type, :birth_date, :death_date, :gender_code,
      :source_ids, :main_headings, :names, :nationality, :language,
      :occupation, :field_of_activity

    def self.from_payload(payload)
      new(payload)
    end

    def initialize(payload)
      @viaf_id = payload["viaf_id"]
      @name_type = payload["name_type"]
      @birth_date = payload["birth_date"]
      @death_date = payload["death_date"]
      @gender_code = payload["gender"]
      @source_ids = payload["source_ids"] || {}
      @main_headings = payload["main_headings"] || []
      @names = payload["names"] || []
      @nationality = payload["nationality"] || []
      @language = payload["language"] || []
      @occupation = payload["occupation"] || []
      @field_of_activity = payload["field_of_activity"] || []
    end

    def birth_year = year_from(birth_date)

    def death_year = year_from(death_date)

    def gender = GENDER_CODES[gender_code]

    def kind = NAME_TYPE_KINDS[name_type]

    def lcnaf = source_ids["LC"]

    def isni = source_ids["ISNI"]

    def wikidata_qid = source_ids["WKP"]

    def preferred_name
      main_headings.first&.fetch("name", nil) || names.first
    end

    private

    # Dates are strings at day precision ("1828-09-09") and integers at year
    # precision (1473). Negative years occur.
    def year_from(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      match = value.to_s.match(/\A(-?\d+)/)
      match && match[1].to_i
    end
  end
end
