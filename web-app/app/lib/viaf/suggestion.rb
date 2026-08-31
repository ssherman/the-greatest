# frozen_string_literal: true

module Viaf
  # One AutoSuggest candidate.
  #
  # AutoSuggest is ~250x cheaper than a cluster fetch (3 KB for ten candidates
  # versus 361-782 KB for one author), so resolution happens here and only the
  # chosen VIAF ID gets an expensive cluster fetch.
  class Suggestion
    # Everything else in the response is a contributing agency code.
    STRUCTURAL_KEYS = %w[term displayForm nametype viafid score recordID].freeze

    NAME_TYPE_KINDS = {"personal" => :person, "corporate" => :organization}.freeze

    attr_reader :viaf_id, :term, :display_form, :name_type, :score, :source_ids

    def self.from_result(result)
      new(result)
    end

    def initialize(result)
      @viaf_id = result["viafid"].to_s
      @term = result["term"]
      @display_form = result["displayForm"]
      @name_type = result["nametype"]
      @score = result["score"]&.to_i
      @source_ids = result.except(*STRUCTURAL_KEYS)
    end

    def kind = NAME_TYPE_KINDS[name_type]

    def birth_year = date_range[0]

    def death_year = date_range[1]

    private

    # Dates are embedded in the heading, e.g. "Tolstoy, Leo, graf, 1828-1910".
    def date_range
      @date_range ||= begin
        match = term.to_s.match(/(\d{3,4})\s*-\s*(\d{3,4})?/)
        match ? [match[1].to_i, match[2]&.to_i] : [nil, nil]
      end
    end
  end
end
