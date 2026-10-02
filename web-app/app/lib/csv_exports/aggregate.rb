# frozen_string_literal: true

# One grouped query per many-to-many column per batch (spec §10). Preloading
# authors, countries and categories for 21k books instantiates ~150k join
# records and took ~10 s; asking Postgres for `string_agg` per owner returns one
# short string per row instead.
#
# Returns {owner_id => "A, B"}; an owner with no rows is absent, so callers
# read with [] and get nil for an empty cell.
#
# group_by, name and order are SQL fragments: code constants only, never
# request input.
module CsvExports
  module Aggregate
    def self.names(relation, group_by:, name:, order: nil)
      order_sql = order ? " ORDER BY #{order}" : ""
      relation
        .group(Arel.sql(group_by))
        .pluck(Arel.sql(group_by), Arel.sql("string_agg(#{name}, ', '#{order_sql})"))
        .to_h
    end
  end
end
