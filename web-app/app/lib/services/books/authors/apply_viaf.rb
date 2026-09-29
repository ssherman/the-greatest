# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Writes what a matched VIAF cluster says onto the author, filling
      # blanks only (spec §8). Identifiers (VIAF, ISNI, LC, and the Wikidata
      # id in the cluster's sources), life years, gender, countries from the
      # nationality codes, and alternate names from the libraries' main
      # headings. Never writes name or kind. An author holding a different
      # VIAF id gets nothing. Returns the ledger facts, and the Wikidata id
      # when this run newly stamped it (the job runs Wikidata once more).
      class ApplyViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ALTERNATE_NAME_CAP = 10
        VIAF = "books_author_viaf"
        QID = "books_author_wikidata_qid"
        GENDERS = {"a" => "female", "b" => "male"}.freeze
        # A heading built from Wikidata ("Stacy Willingham American writer")
        # is a label and a description, not a library's name form.
        SKIPPED_HEADING_SOURCES = %w[WKP].freeze

        def self.call(author:, person:, decision: nil, country_lookup: nil)
          new(author: author, person: person, decision: decision, country_lookup: country_lookup).call
        end

        def initialize(author:, person:, decision:, country_lookup:)
          @author = author
          @person = person
          @decision = decision
          @country_lookup = country_lookup || ::Services::Books::CountryLookup.new
          @sheet = FactSheet.new(author)
        end

        def call
          other = sheet.identifier_values(VIAF) - [person.viaf_id]
          if other.any?
            sheet.record("viaf", person.viaf_id, applied: false, reason: "held_viaf_conflict", held: other)
            return result(conflict: true)
          end

          sheet.single_identifier("viaf", VIAF, person.viaf_id)
          sheet.single_identifier("isni", "books_author_isni", person.isni)
          sheet.single_identifier("lcnaf", "books_author_lcnaf", person.lcnaf)
          sheet.single_identifier("wikidata_qid", QID, person.wikidata_qid.to_s[/\AQ\d+\z/])
          apply_year("birth_year", person.birth_year)
          apply_year("death_year", person.death_year)
          apply_gender
          sheet.alternate_names(heading_names, cap: ALTERNATE_NAME_CAP)
          codes = person.country_codes
          sheet.countries(codes, viaf: codes) { |values| @country_lookup.from_iso(values) }
          author.save!
          sheet.flag_collisions(reason: "VIAF #{person.viaf_id} lists identifiers another author already holds", decision: decision)
          result(conflict: false)
        end

        private

        attr_reader :author, :person, :decision, :sheet

        def result(conflict:)
          new_qid = sheet.facts.dig("wikidata_qid", "applied") ? sheet.facts["wikidata_qid"]["value"] : nil
          Result.new(success?: true, data: {facts: sheet.facts, applied: sheet.applied, conflict: conflict, wikidata_qid: new_qid},
            errors: [])
        end

        def apply_year(name, year)
          if year.nil?
            sheet.record(name, nil, applied: false, reason: "null")
          elsif !person.lived?
            sheet.record(name, year, applied: false, reason: "not_life_dates", date_type: person.date_type)
          elsif year.negative?
            sheet.record(name, year, applied: false, reason: "bce")
          else
            sheet.year(name, year)
          end
        end

        def apply_gender
          code = person.gender_code
          value = GENDERS[code]
          return sheet.record("gender", code, applied: false, reason: "null") if value.nil?

          sheet.gender(value, viaf: code)
        end

        # Main headings only, in natural order, Latin script, entered under a
        # surname. A heading entered under a forename ("Marcus Aurelius,
        # Emperor of Rome") or of unknown entry (Distiller's surname_first is
        # false or nil) has no inversion to undo, so ViafNames.natural is
        # never called on it — inverting it would write garbage. A heading
        # whose words only reorder a name the author already has is skipped:
        # "Mo, Yan" is Mo Yan, not "Yan Mo", and the comma cannot tell the two apart.
        def heading_names
          existing = [author.name] + Array(author.alternate_names)
          person.main_headings.filter_map do |heading|
            next if SKIPPED_HEADING_SOURCES.include?(heading["source"])
            next unless heading["surname_first"] == true

            name = ViafNames.natural(heading["name"])
            next if name.nil? || !ViafNames.latin?(name)
            next if existing.any? { |ours| ViafNames.reordering?(name, of: ours) }

            name
          end.uniq
        end
      end
    end
  end
end
