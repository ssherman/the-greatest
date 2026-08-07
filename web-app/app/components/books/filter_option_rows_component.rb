module Books
  class FilterOptionRowsComponent < ViewComponent::Base
    BADGES = {"location" => "Setting", "subject" => "Subject"}.freeze

    def initialize(axis:, rows:, checked: false, show_counts: true)
      @axis = axis.to_s
      @rows = Array(rows)
      @checked = checked
      @show_counts = show_counts
    end

    private

    attr_reader :axis, :rows, :checked, :show_counts

    def input_name
      "#{axis}_slugs[]"
    end

    def normalized_rows
      rows.map do |row|
        row.is_a?(Hash) ? row : {record: row, count: nil}
      end
    end

    def badge_for(record)
      return nil unless axis == "category"

      BADGES[record.category_type.to_s]
    end

    def count_for(row)
      return nil unless show_counts

      row[:count]
    end
  end
end
