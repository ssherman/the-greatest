# frozen_string_literal: true

module Wikidata
  # Reduces one wbgetentities entity to the fields the author steps read.
  # Only best-rank statements count: the preferred ones when any exist,
  # otherwise the normal ones, never deprecated ones. The full entity is kept
  # separately, gzipped (ExternalRecord#raw_text).
  #
  # Names read English first, then "mul", the label Wikidata keeps for all
  # languages: many people's items now carry their name only there (Victor
  # Hugo's has no English label at all). SCHEMA_VERSION 2 added that
  # fallback, so an item stored under 1 is fetched and distilled again.
  module Distiller
    SCHEMA_VERSION = 2
    NAME_LANGUAGES = %w[en mul].freeze

    IDENTIFIER_PROPERTIES = {
      "viaf" => "P214", "isni" => "P213", "lcnaf" => "P244",
      "openlibrary" => "P648", "goodreads" => "P2963", "librarything" => "P7400"
    }.freeze

    TIME = /\A([+-])(\d+)-/

    module_function

    def call(entity)
      unless entity.is_a?(Hash) && entity["id"].present? && !entity.key?("missing")
        raise ::Wikimedia::Exceptions::ParseError, "Not a Wikidata entity: #{entity.to_s[0, 200]}"
      end

      claims = entity["claims"].is_a?(Hash) ? entity["claims"] : {}
      {
        "id" => entity["id"],
        "label" => name(entity["labels"]),
        "aliases" => name_list(entity["aliases"]),
        "description" => english(entity["descriptions"]),
        "instance_of" => item_ids(claims, "P31"),
        "birth" => times(claims, "P569"),
        "death" => times(claims, "P570"),
        "gender" => item_ids(claims, "P21"),
        "citizenships" => item_ids(claims, "P27"),
        "occupations" => item_ids(claims, "P106"),
        "native_names" => values(claims, "P1559").filter_map { |value| value["text"] if value.is_a?(Hash) },
        "pseudonyms" => values(claims, "P742").grep(String),
        "identifiers" => IDENTIFIER_PROPERTIES.transform_values { |property| values(claims, property).grep(String) },
        "enwiki_title" => entity["sitelinks"].is_a?(Hash) ? entity["sitelinks"].dig("enwiki", "title") : nil,
        "sitelink_count" => entity["sitelinks"].is_a?(Hash) ? entity["sitelinks"].size : 0
      }
    end

    def english(terms)
      terms.is_a?(Hash) ? terms.dig("en", "value") : nil
    end

    # The English label, else the all-languages one.
    def name(terms)
      return nil unless terms.is_a?(Hash)

      NAME_LANGUAGES.lazy.filter_map { |language| terms.dig(language, "value") }.first
    end

    # English aliases, then the all-languages ones.
    def name_list(terms)
      return [] unless terms.is_a?(Hash)

      NAME_LANGUAGES.flat_map { |language| Array(terms[language]).filter_map { |term| term["value"] if term.is_a?(Hash) } }.uniq
    end

    def best(claims, property)
      statements = Array(claims[property]).select { |statement| statement.is_a?(Hash) && statement["rank"] != "deprecated" }
      preferred = statements.select { |statement| statement["rank"] == "preferred" }
      preferred.any? ? preferred : statements
    end

    def values(claims, property)
      best(claims, property).filter_map do |statement|
        snak = statement["mainsnak"]
        snak.dig("datavalue", "value") if snak.is_a?(Hash) && snak["snaktype"] == "value"
      end
    end

    def item_ids(claims, property)
      values(claims, property).filter_map { |value| value["id"] if value.is_a?(Hash) }.uniq
    end

    def times(claims, property)
      best(claims, property).filter_map do |statement|
        snak = statement["mainsnak"]
        next unless snak.is_a?(Hash)
        next {"unknown" => true} if snak["snaktype"] == "somevalue"

        value = snak.dig("datavalue", "value")
        match = value.is_a?(Hash) && value["time"].to_s.match(TIME)
        next unless match

        {"year" => match[2].to_i * ((match[1] == "-") ? -1 : 1), "precision" => value["precision"].to_i}
      end
    end

    private_class_method :english, :name, :name_list, :best, :values, :item_ids, :times
  end
end
