# frozen_string_literal: true

module Services
  module Books
    # The only class that writes Books::Book columns from AI output. Policy:
    # fill a blank, union an array, never overwrite. Every fact gets a ledger
    # entry saying what happened and why, applied or not.
    #
    # Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §4-5.
    class ApplyBookFacts
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      PAGE_RANGE = /\A\d+(-\d+)?\z/
      RECORDED_ONLY = %w[book_type series_name series_number].freeze

      def self.call(book:, facts:, citations: [], description: nil)
        new(book: book, facts: facts, citations: citations, description: description).call
      end

      def initialize(book:, facts:, citations:, description:)
        @book = book
        @facts = facts.deep_symbolize_keys
        @citations = Array(citations)
        @description = description
        @ledger = {}
        @applied = []
      end

      def call
        apply_first_published_year
        apply_original_language
        apply_word_count
        apply_page_range
        apply_subtitle
        apply_alternate_titles
        apply_origin_countries
        record_only_facts
        apply_description

        book.save!
        Result.new(success?: true, data: {facts: ledger, applied: applied}, errors: [])
      end

      private

      attr_reader :book, :facts, :citations, :description, :ledger, :applied

      def fact(name) = facts.fetch(name, {}) || {}

      def record(name, fact, applied:, reason:, value: fact[:value], **extra)
        ledger[name.to_s] = {"value" => value, "confidence" => fact[:confidence], "applied" => applied, "reason" => reason}.merge(extra.stringify_keys)
        self.applied << name.to_s if applied
      end

      def fill_scalar(name, column:, present: -> { book.public_send(column).present? }, valid: ->(_) { true }, cast: ->(v) { v })
        f = fact(name)
        value = f[:value]
        if value.nil? || (value.respond_to?(:empty?) && value.empty?)
          record(name, f, applied: false, reason: "null")
        elsif !valid.call(value)
          record(name, f, applied: false, reason: "invalid")
        elsif present.call
          record(name, f, applied: false, reason: "already_set")
        else
          book.public_send(:"#{column}=", cast.call(value))
          record(name, f, applied: true, reason: "filled")
        end
      end

      def apply_first_published_year
        fill_scalar(:first_published_year, column: :first_published_year, valid: ->(v) { v.is_a?(Integer) }, cast: ->(v) { v })
        ledger["first_published_year_estimated"] = {
          "value" => facts[:first_published_year_estimated],
          "confidence" => fact(:first_published_year)[:confidence],
          "applied" => false,
          "reason" => "not_applied_yet"
        }
      end

      def apply_original_language
        f = fact(:original_language)
        value = f[:value].to_s.strip
        return record(:original_language, f, applied: false, reason: "null") if value.blank?
        return record(:original_language, f, applied: false, reason: "already_set") if book.original_language_id.present?

        language = find_language(value)
        return record(:original_language, f, applied: false, reason: "no_match") if language.nil?

        book.original_language = language
        record(:original_language, f, applied: true, reason: "filled")
      end

      def find_language(value)
        downcased = value.downcase
        (Language.find_by(iso_639_1: downcased) if downcased.length == 2) ||
          Language.where("lower(name) = ?", downcased).first
      end

      def apply_word_count
        fill_scalar(:word_count, column: :word_count, valid: ->(v) { v.is_a?(Integer) && v.positive? })
      end

      def apply_page_range
        fill_scalar(:page_range, column: :page_range, valid: ->(v) { v.to_s.match?(PAGE_RANGE) }, cast: ->(v) { v.to_s })
      end

      def apply_subtitle
        fill_scalar(:subtitle, column: :subtitle, cast: ->(v) { v.to_s.strip })
      end

      def apply_alternate_titles
        f = fact(:alternate_titles)
        incoming = Array(f[:value]).map { |t| t.to_s.strip }.reject(&:blank?)
        return record(:alternate_titles, f, applied: false, reason: "null", value: []) if incoming.empty?

        existing = Array(book.alternate_titles)
        taken = (existing + [book.title]).map(&:downcase)
        new_titles = incoming.reject { |t| taken.include?(t.downcase) }.uniq(&:downcase)
        return record(:alternate_titles, f, applied: false, reason: "already_set", value: []) if new_titles.empty?

        book.alternate_titles = existing + new_titles
        record(:alternate_titles, f, applied: true, reason: "filled", value: new_titles)
      end

      def apply_origin_countries
        f = fact(:origin_countries)
        names = Array(f[:value]).map { |n| n.to_s.strip }.reject(&:blank?)
        return record(:origin_countries, f, applied: false, reason: "null", value: [], unmatched: []) if names.empty?
        return record(:origin_countries, f, applied: false, reason: "already_set", unmatched: []) if book.book_countries.exists?

        matched, unmatched = names.partition { |name| find_country(name) }
        matched.each { |name| book.book_countries.build(country: find_country(name)) }

        if matched.any?
          record(:origin_countries, f, applied: true, reason: "filled", value: matched, unmatched: unmatched)
        else
          record(:origin_countries, f, applied: false, reason: "no_match", unmatched: unmatched)
        end
      end

      def find_country(name)
        @countries ||= {}
        @countries[name.downcase] ||= ::Books::Country.where("lower(name) = ?", name.downcase).first
      end

      def record_only_facts
        RECORDED_ONLY.each do |name|
          f = fact(name.to_sym)
          record(name, f, applied: false, reason: f[:value].nil? ? "null" : "not_applied_yet")
        end
      end

      def apply_description
        f = fact(:description)
        if description.nil?
          return record(:description, f, applied: false, reason: "null")
        end

        review = description[:review]
        if description[:reason].present?
          return record(:description, f, applied: false, reason: description[:reason], value: description[:text], review: review)
        end
        if book.descriptions.any? { |d| d.source == "ai_generated" }
          return record(:description, f, applied: false, reason: "already_set", value: description[:text], review: review)
        end

        book.assign_description(source: :ai_generated, content: description[:text], source_url: citations.first)
        record(:description, f, applied: true, reason: "filled", value: description[:text], review: review)
      end
    end
  end
end
