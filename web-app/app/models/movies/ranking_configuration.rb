module Movies
  class RankingConfiguration < ::RankingConfiguration
    # Movies-specific defaults
    after_initialize :set_movies_defaults, if: :new_record?

    private

    def set_movies_defaults
      self.max_list_dates_penalty_percentage ||= 70
      self.max_list_dates_penalty_age ||= 30
    end
  end
end
