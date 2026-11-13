module Sitemaps
  # Active lists that have a ranked_lists row in the primary ranking
  # configuration of one RC class. Ordered by id; empty when there is no primary RC.
  class RankedLists
    def initialize(key:, list_class:, ranking_configuration_class:, path_prefix:)
      @key = key
      @list_class = list_class
      @ranking_configuration_class = ranking_configuration_class
      @path_prefix = path_prefix
    end

    attr_reader :key

    def count = relation.count

    def entries(offset:, limit:)
      relation.offset(offset).limit(limit).pluck(:id, :updated_at).map do |id, updated_at|
        Entry.new(path: "#{@path_prefix}#{id}", lastmod: updated_at)
      end
    end

    def lastmod = relation.maximum("#{@list_class.table_name}.updated_at")

    private

    def relation
      rc = @ranking_configuration_class.default_primary
      return @list_class.none unless rc

      @list_class
        .where(status: :active)
        .where(id: rc.ranked_lists.select(:list_id))
        .reorder("#{@list_class.table_name}.id")
    end
  end
end
