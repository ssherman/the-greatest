# frozen_string_literal: true

module Wikidata
  # Reduces one wbgetentities entity for a work (or an edition of one) to the
  # fields the category/origin evidence reads. Best-rank statements only, via
  # Distiller's helpers.
  module WorkDistiller
    ITEM_PROPERTIES = {
      "instance_of" => "P31", "authors" => "P50", "edition_of" => "P629", "countries" => "P495",
      "languages" => "P407", "genres" => "P136", "main_subjects" => "P921", "narrative_locations" => "P840",
      "set_in_periods" => "P2408", "forms" => "P7937"
    }.freeze
    IDENTIFIER_PROPERTIES = {"goodreads_book" => "P2969", "openlibrary" => "P648", "oclc" => "P243"}.freeze
    MIN_YEAR_PRECISION = 9 # year; 8 is decade

    module_function

    def call(entity)
      unless entity.is_a?(Hash) && entity["id"].present? && !entity.key?("missing")
        raise ::Wikimedia::Exceptions::ParseError, "Not a Wikidata entity: #{entity.to_s[0, 200]}"
      end

      claims = entity["claims"].is_a?(Hash) ? entity["claims"] : {}
      sitelinks = entity["sitelinks"].is_a?(Hash) ? entity["sitelinks"] : {}
      {
        "id" => entity["id"],
        "label" => Distiller.name(entity["labels"]),
        "description" => Distiller.english(entity["descriptions"])
      }.merge(ITEM_PROPERTIES.transform_values { |property| Distiller.item_ids(claims, property) }).merge(
        "publication_years" => publication_years(claims),
        "identifiers" => IDENTIFIER_PROPERTIES.transform_values { |property| Distiller.values(claims, property).grep(String).first }.compact,
        "enwiki_title" => sitelinks.dig("enwiki", "title")
      )
    end

    def publication_years(claims)
      Distiller.times(claims, "P577").filter_map { |time|
        time["year"] if time["year"] && time["precision"].to_i >= MIN_YEAR_PRECISION
      }.uniq
    end
  end
end
