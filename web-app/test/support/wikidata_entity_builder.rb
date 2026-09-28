# frozen_string_literal: true

# Builds wbgetentities entity hashes (formatversion 2) with only the shapes
# Wikidata::Distiller reads. Years: an Integer is year precision (9);
# {year:, precision:} sets the precision; :unknown is a somevalue snak.
module WikidataEntityBuilder
  def wikidata_entity(id, label: nil, aliases: [], description: nil, types: ["Q5"], born: nil, died: nil,
    gender: [], citizenships: [], occupations: [], native_names: [], pseudonyms: [], identifiers: {},
    enwiki: nil, sitelinks: 0, claims: {})
    all_claims = {
      "P31" => types.map { |type| wikidata_item_statement(type) },
      "P21" => gender.map { |item| wikidata_item_statement(item) },
      "P27" => citizenships.map { |item| wikidata_item_statement(item) },
      "P106" => occupations.map { |item| wikidata_item_statement(item) },
      "P1559" => native_names.map { |text| wikidata_statement({"text" => text, "language" => "mul"}) },
      "P742" => pseudonyms.map { |name| wikidata_statement(name) },
      "P569" => wikidata_dates(born).map { |value| wikidata_time_statement(value) },
      "P570" => wikidata_dates(died).map { |value| wikidata_time_statement(value) }
    }
    Wikidata::Distiller::IDENTIFIER_PROPERTIES.each do |kind, property|
      all_claims[property] = Array(identifiers[kind.to_sym] || identifiers[kind]).map { |value| wikidata_statement(value) }
    end

    links = {}
    links["enwiki"] = {"site" => "enwiki", "title" => enwiki} if enwiki
    (sitelinks - links.size).times { |i| links["x#{i}wiki"] = {"site" => "x#{i}wiki", "title" => label.to_s} }

    {
      "type" => "item",
      "id" => id,
      "labels" => label ? {"en" => {"language" => "en", "value" => label}} : {},
      "descriptions" => description ? {"en" => {"language" => "en", "value" => description}} : {},
      "aliases" => aliases.any? ? {"en" => aliases.map { |name| {"language" => "en", "value" => name} }} : {},
      "claims" => all_claims.reject { |_property, statements| statements.empty? }.merge(claims),
      "sitelinks" => links
    }
  end

  # nil → none; one value (an Integer, a {year:, precision:} Hash, :unknown) → one; an Array → each.
  # Not Array(value): Array({year: 1900}) would turn the Hash into pairs.
  def wikidata_dates(value)
    return [] if value.nil?

    value.is_a?(Array) ? value : [value]
  end

  def wikidata_time_statement(value, rank: "normal")
    return {"mainsnak" => {"snaktype" => "somevalue"}, "rank" => rank} if value == :unknown

    year, precision = value.is_a?(Hash) ? [value[:year], value[:precision]] : [value, 9]
    time = format("%s%04d-00-00T00:00:00Z", year.negative? ? "-" : "+", year.abs)
    wikidata_statement({"time" => time, "precision" => precision}, rank: rank)
  end

  def wikidata_item_statement(item_id, rank: "normal")
    wikidata_statement({"entity-type" => "item", "id" => item_id}, rank: rank)
  end

  def wikidata_statement(value, rank: "normal")
    {"mainsnak" => {"snaktype" => "value", "datavalue" => {"value" => value}}, "rank" => rank}
  end
end

ActiveSupport::TestCase.include(WikidataEntityBuilder)
