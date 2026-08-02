# frozen_string_literal: true

module ItemRankings
  module Books
    module Authors
      class ScoreFormula
        SATURATION_COUNT = 6

        def self.call(book_count:, total_score:)
          count = book_count.to_i
          return BigDecimal(0) if count < 1

          BigDecimal(total_score.to_s) * count_multiplier(count)
        end

        def self.count_multiplier(book_count)
          capped = [book_count.to_i, SATURATION_COUNT].min
          shortfall = 1.0 - (capped.to_f / SATURATION_COUNT)

          BigDecimal((1.0 - (shortfall**2)).to_s)
        end
      end
    end
  end
end
