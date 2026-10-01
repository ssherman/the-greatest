# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what the AI step reported about an author (spec §9), filling
      # blanks only through the FactSheet every author step shares. A fact
      # the model gave low confidence is recorded, not applied. Nationalities
      # become countries through CountryLookup, and only when the author has
      # none. The description is written only when the author has no AI
      # description yet: the legacy ones are kept. Whether a run is applied
      # at all is EnrichAuthor's decision; this class saves the author.
      class ApplyAuthorFacts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        GENDERS = %w[male female non_binary].freeze
        # The ledger name each reported fact is recorded under.
        LEDGER_NAMES = {
          birth_year: "birth_year", death_year: "death_year", gender: "gender",
          nationalities: "countries", description: "description"
        }.freeze

        def self.call(author:, facts:, citations: [], description: nil)
          new(author: author, facts: facts, citations: citations, description: description).call
        end

        def initialize(author:, facts:, citations:, description:)
          @author = author
          @facts = facts.deep_symbolize_keys
          @citations = Array(citations)
          @description = description
          @sheet = FactSheet.new(author)
        end

        def call
          apply_year(:birth_year)
          apply_year(:death_year)
          apply_gender
          apply_countries
          apply_description
          LEDGER_NAMES.each { |name, key| sheet.facts[key]&.merge!("confidence" => fact(name)[:confidence]) }

          author.save!
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied}, errors: [])
        end

        private

        attr_reader :author, :facts, :citations, :description, :sheet

        def fact(name) = facts[name] || {}

        def low?(entry) = entry[:confidence].to_s.strip.casecmp?("low")

        def apply_year(name)
          entry = fact(name)
          value = entry[:value]
          key = LEDGER_NAMES.fetch(name)
          return sheet.record(key, nil, applied: false, reason: "null") if value.nil?
          return sheet.record(key, value, applied: false, reason: "invalid") unless valid_year?(name, value)
          return sheet.record(key, value, applied: false, reason: "low_confidence") if low?(entry)

          sheet.year(key, value)
        end

        # A Common Era year no later than this one; a death no earlier than
        # the birth we hold, or, failing that, the birth the model reported.
        def valid_year?(name, value)
          return false unless value.is_a?(Integer) && value.positive? && value <= Date.current.year
          return true unless name == :death_year

          reported = fact(:birth_year)[:value]
          birth = author.birth_year || (reported if reported.is_a?(Integer))
          birth.nil? || value >= birth
        end

        def apply_gender
          entry = fact(:gender)
          value = entry[:value].to_s.strip.downcase.tr(" -", "__").presence
          return sheet.record("gender", nil, applied: false, reason: "null") if value.nil?
          return sheet.record("gender", value, applied: false, reason: "invalid") unless GENDERS.include?(value)
          return sheet.record("gender", value, applied: false, reason: "low_confidence") if low?(entry)

          sheet.gender(value)
        end

        def apply_countries
          entry = fact(:nationalities)
          names = Array(entry[:value]).map { |name| name.to_s.squish }.reject(&:blank?).uniq(&:downcase)
          if names.any? && low?(entry)
            return sheet.record("countries", names, applied: false, reason: "low_confidence", unmatched: [])
          end

          sheet.countries(names, nationalities: names) { |values| ::Services::Books::CountryLookup.from_text(values) }
        end

        def apply_description
          return sheet.record("description", nil, applied: false, reason: "null") if description.nil?

          text = description[:text]
          review = {review: description[:review]}.compact
          if description[:reason].present?
            return sheet.record("description", text, applied: false, reason: description[:reason], **review)
          end
          return sheet.record("description", text, applied: false, reason: "low_confidence", **review) if low?(fact(:description))
          if author.descriptions.any? { |row| row.source == "ai_generated" }
            return sheet.record("description", text, applied: false, reason: "already_set", **review)
          end

          row = author.assign_description(source: :ai_generated, content: text, source_url: citations.first)
          sheet.record("description", text, applied: row.present?, reason: row ? "filled" : "null", **review)
        end
      end
    end
  end
end
