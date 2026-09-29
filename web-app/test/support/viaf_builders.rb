# frozen_string_literal: true

# Builds Viaf::Person and Viaf::Suggestion objects in the shapes the importer
# reads (live shapes observed 2026-09-28). A person's default sources are
# libraries the appliers never stamp, so only an explicit wikidata:, isni: or
# lc: produces an identifier.
module ViafBuilders
  def viaf_person(id, headings: [], born: nil, died: nil, date_type: "lived", gender: nil, wikidata: nil, isni: nil,
    lc: nil, nationality: [], occupations: [], titles: [], names: [], name_type: "Personal", agencies: %w[DNB BNF])
    source_ids = agencies.index_with { |code| "#{code.downcase}-#{id}" }
    source_ids["WKP"] = wikidata if wikidata
    source_ids["ISNI"] = isni if isni
    source_ids["LC"] = lc if lc
    Viaf::Person.from_payload(
      "viaf_id" => id.to_s, "name_type" => name_type, "birth_date" => born, "death_date" => died,
      "date_type" => date_type, "gender" => gender, "source_ids" => source_ids,
      "main_headings" => headings.map { |heading| heading.is_a?(Hash) ? heading : {"source" => "LC", "name" => heading, "surname_first" => true} },
      "names" => names, "nationality" => nationality, "language" => [], "occupation" => occupations,
      "field_of_activity" => [], "titles" => titles
    )
  end

  def viaf_suggestion(id, term, name_type: "personal", agencies: {"lc" => "n1"})
    Viaf::Suggestion.from_result(
      {"term" => term, "displayForm" => term, "nametype" => name_type, "viafid" => id.to_s, "score" => "100"}.merge(agencies)
    )
  end
end

ActiveSupport::TestCase.include(ViafBuilders)
