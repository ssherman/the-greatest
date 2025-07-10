module Games
  class RankingConfiguration < ::RankingConfiguration
    # Games-specific defaults
    after_initialize :set_games_defaults, if: :new_record?

    private

    def set_games_defaults
      self.max_list_dates_penalty_percentage ||= 60
      self.max_list_dates_penalty_age ||= 20
    end
  end
end
