# frozen_string_literal: true

# The penalty section of the new/edit form: every catalogue penalty for the
# entry, grouped under the same headings the public rankings explainer uses,
# each row carrying whether it is on and at what value.
#
# `values` is {penalty_id => value} for the enabled penalties only -- the
# official configuration's applications for a new form, the configuration's
# own for edit, or the submitted params on a re-render.
module RankingConfigurations
  class PenaltyRows
    Row = Struct.new(:penalty, :enabled, :value, keyword_init: true)
    Group = Struct.new(:title, :rows, keyword_init: true)

    def self.call(entry:, values:)
      penalties = Registry.penalties_for(entry).order(:name).to_a
      by_category = penalties.group_by(&:category)
      categories = ::Penalty::CATEGORY_TITLES.keys + [nil]

      categories.filter_map do |category|
        rows = (by_category[category] || []).map do |penalty|
          Row.new(penalty: penalty, enabled: values.key?(penalty.id), value: values[penalty.id] || 0)
        end
        next if rows.empty?

        Group.new(title: ::Penalty.category_title(category), rows: rows)
      end
    end
  end
end
