# frozen_string_literal: true

module Services
  module Books
    module Categorize
      # Everything we hold about a book that bears on where it comes from: our
      # record, the latest books.evidence row and the latest books.book_facts
      # row. Read-only. The instance methods work from the stored fields alone.
      class Dossier < Data.define(:book, :evidence_id, :record, :book_facts, :wikidata, :wikipedia, :worldcat)
        LEAD_LIMIT = 1_000
        LEDGER_LEAD_LIMIT = 500
        WIKIDATA_LISTS = %w[countries country_ids country_matches languages publication_years].freeze
        WIKIDATA_KEYS = %w[qid label description].freeze

        def self.build(book:)
          evidence = book.enrichments.where(kind: Evidence::Gather::KIND).order(:id).last
          facts = evidence&.facts || {}
          new(book: book, evidence_id: evidence&.id, record: record_for(book),
            book_facts: book_facts_for(book), wikidata: wikidata_section(facts["wikidata"]),
            wikipedia: wikipedia_section(facts["wikipedia"]), worldcat: worldcat_section(facts["worldcat"]))
        end

        def self.record_for(book)
          names = book.countries.order(:id).pluck(:name)
          {
            "title" => book.title, "subtitle" => book.subtitle,
            "first_published_year" => book.first_published_year,
            "original_language" => book.original_language&.name,
            "countries" => names,
            "real_countries" => names.reject { |name| CountryLookup::PLACEHOLDERS.include?(name.downcase) },
            "authors" => book.book_authors.includes(author: :countries).order(:position, :id).map { |ba| author_entry(ba) }
          }
        end

        def self.author_entry(book_author)
          author = book_author.author
          kind = Authors::AuthorKind.kind(author)
          {
            "name" => author.name, "role" => book_author.role, "kind" => kind.to_s,
            "countries" => author.countries.map(&:name),
            "birth_year" => author.birth_year, "death_year" => author.death_year,
            "place_country" => (kind == :place) ? Authors::AuthorKind.place_country(author)&.name : nil
          }
        end

        def self.book_facts_for(book)
          row = book.enrichments.where(kind: EnrichBook::KIND, outcome: %i[applied nothing_to_apply unrecognized]).order(:id).last
          return nil unless row

          facts = row.facts || {}
          value = ->(key) { facts[key].is_a?(Hash) ? facts[key]["value"] : nil }
          {
            "recognized" => row.recognized, "mode" => row.mode,
            "original_language" => value.call("original_language"),
            "origin_countries" => value.call("origin_countries"),
            "book_type" => value.call("book_type")
          }
        end

        def self.wikidata_section(section)
          return nil unless section.is_a?(Hash)

          WIKIDATA_KEYS.to_h { |key| [key, section[key]] }
            .merge(WIKIDATA_LISTS.to_h { |key| [key, Array(section[key])] })
        end

        def self.wikipedia_section(section)
          return nil unless section.is_a?(Hash)

          infobox = section["infobox"].is_a?(Hash) ? section["infobox"] : {}
          {
            "title" => section["title"], "url" => section["url"],
            "lead" => section["lead"]&.slice(0, LEAD_LIMIT),
            "infobox_country" => infobox["country"], "infobox_language" => infobox["language"]
          }
        end

        def self.worldcat_section(section)
          return nil unless section.is_a?(Hash)

          section.slice("publication_places", "earliest_year", "cataloging_languages")
        end

        private_class_method :record_for, :author_entry, :book_facts_for, :wikidata_section,
          :wikipedia_section, :worldcat_section

        def external?
          [wikidata, wikipedia, worldcat].any?(&:present?)
        end

        # The held countries that are real, in the order the record lists them.
        def real_countries
          names = record["real_countries"]
          by_name = ::Books::Country.where(name: names).index_by(&:name)
          names.filter_map { |name| by_name[name] }
        end

        # Person authors' countries and place authors' own nationality; editors
        # and placeholders add nothing.
        def author_countries
          record["authors"].select { |a| a["role"] == "author" }.flat_map do |a|
            case a["kind"]
            when "person" then a["countries"]
            when "place" then [a["place_country"]]
            else []
            end
          end.compact.uniq
        end

        def to_ledger
          {
            "evidence_id" => evidence_id, "record" => record, "book_facts" => book_facts,
            "wikidata" => wikidata, "worldcat" => worldcat,
            "wikipedia" => wikipedia&.merge("lead" => wikipedia["lead"]&.slice(0, LEDGER_LEAD_LIMIT))
          }
        end
      end
    end
  end
end
