module Sitemaps
  # Items of one model that hold a rank in the primary ranking configuration of
  # one RC class. scope is a relation of the item model (e.g. Books::Book.catalog),
  # so exclusions such as provisional records are the caller's choice. Ordered by
  # id so URLs keep their file from day to day. Empty when there is no primary RC.
  class RankedItems
    def initialize(key:, scope:, ranking_configuration_class:, path_prefix:)
      @key = key
      @scope = scope
      @ranking_configuration_class = ranking_configuration_class
      @path_prefix = path_prefix
    end

    attr_reader :key

    def count = relation.count

    def entries(offset:, limit:)
      relation.offset(offset).limit(limit).pluck(:slug, :updated_at).map do |slug, updated_at|
        Entry.new(path: "#{@path_prefix}#{slug}", lastmod: updated_at)
      end
    end

    def lastmod = relation.maximum("#{table}.updated_at")

    private

    def table = @scope.model.table_name

    def relation
      rc = @ranking_configuration_class.default_primary
      return @scope.none unless rc

      @scope
        .where(id: ::RankedItem.where(
          item_type: @scope.model.name,
          ranking_configuration_id: rc.id
        ).where.not(rank: nil).select(:item_id))
        .reorder("#{table}.id")
    end
  end
end
