# frozen_string_literal: true

# Cell formatting shared by every row class.
module CsvExports
  module Cells
    # ranked_items.score is decimal(10,2); "%.2f" pads an integer-valued score
    # so every score cell has two decimals. nil stays an empty cell.
    def self.score(value)
      value.nil? ? nil : format("%.2f", value)
    end
  end
end
