# frozen_string_literal: true

module Services
  module Books
    # A year as a prompt shows it: "1828", or "480 BCE" for a year before
    # the Common Era, which the books data stores as a negative number
    # (Euripides is -480). A bare "-480" reads as a typo, and "born -480"
    # invites the model to report it back as a Common Era year.
    class YearLabel
      def self.call(year)
        return nil if year.nil?

        year.to_i.negative? ? "#{-year.to_i} BCE" : year.to_s
      end
    end
  end
end
