# frozen_string_literal: true

module Books
  # Typed readers over a RecommendationConfig's criteria hash. The stored keys are
  # a strict subset of SavedSearchCriteria's, with the same names, so the readers
  # and the OpenSearch clause builders are reused rather than copied: this class
  # composes a SavedSearchCriteria over the permitted keys and pins `ranked` to
  # "true" (the candidate pool is ranked books only, spec §7) and hide_read off
  # (the engine excludes every shelved book itself, spec §5).
  class RecommendationCriteria
    KEYS = %w[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position
    ].freeze

    READERS = %i[
      included_category_ids excluded_category_ids genre_match_mode book_length
      first_year_published_gt first_year_published_lt max_ranked_position
    ].freeze

    def initialize(raw)
      stored = (raw || {}).to_h.stringify_keys.slice(*KEYS)
      @search = ::Books::SavedSearchCriteria.new(stored.merge("ranked" => "true"))
    end

    READERS.each do |reader|
      define_method(reader) { @search.public_send(reader) }
    end

    def unparseable?(key)
      @search.unparseable?(key)
    end

    # The object the clause builders (Search::Books::Search::CriteriaClauses) take.
    def to_search_criteria
      @search
    end
  end
end
