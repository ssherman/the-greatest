module Music
  class RankingConfiguration < ::RankingConfiguration
    # Music-specific defaults
    after_initialize :set_music_defaults, if: :new_record?

    private

    def set_music_defaults
      self.max_list_dates_penalty_percentage ||= 75
      self.max_list_dates_penalty_age ||= 40
    end
  end
end
