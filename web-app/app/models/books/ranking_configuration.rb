module Books
  class RankingConfiguration < ::RankingConfiguration
    # Books-specific defaults
    after_initialize :set_books_defaults, if: :new_record?

    private

    def set_books_defaults
      self.max_list_dates_penalty_percentage ||= 80
      self.max_list_dates_penalty_age ||= 50
    end
  end
end
