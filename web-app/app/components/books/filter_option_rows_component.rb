module Books
  class FilterOptionRowsComponent < ViewComponent::Base
    # Every category type is badged, so a search result always says what it is
    # -- the Category axis spans genres, subjects and settings, and an unbadged
    # row is indistinguishable from the badged ones around it. Only the wording
    # is overridden: "Setting" reads better than "Location" for a place a book
    # is set in. Every other type is its own titleized name.
    BADGE_LABELS = {"location" => "Setting"}.freeze

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

    # Countries have no category_type at all, and the column is nullable, so
    # both guards are reachable rather than defensive.
    def badge_for(record)
      return nil unless axis == "category"
      return nil if record.category_type.blank?

      BADGE_LABELS.fetch(record.category_type.to_s) { record.category_type.to_s.titleize }
    end

    def count_for(row)
      return nil unless show_counts

      row[:count]
    end
  end
end
