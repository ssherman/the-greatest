module Books
  class FilterOptionRowsComponent < ViewComponent::Base
    # axis is "category" or "country"; type is the category type or "country".
    def initialize(axis:, type:, rows:, show_counts: true)
      @axis = axis.to_s
      @type = type.to_s
      @rows = Array(rows)
      @show_counts = show_counts
    end

    private

    attr_reader :axis, :type, :rows, :show_counts

    def normalized_rows
      rows.map do |row|
        row.is_a?(Hash) ? row : {record: row, count: nil}
      end
    end

    def count_for(row)
      return nil unless show_counts

      row[:count]
    end
  end
end
