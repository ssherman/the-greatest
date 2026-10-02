# frozen_string_literal: true

module DataImporters
  module Sources
    # The domain's title-plus-creators dedup query. `params` is the keyword
    # hash the search class takes (nil when the query has nothing to
    # search on). Hits are loaded as records; a hit whose record is gone is
    # dropped. A search error propagates so the finder records the source
    # as failed.
    class OpenSearch
      def initialize(model_class:, search_class:, params:, size: 5, min_score: nil, includes: [])
        @model_class = model_class
        @search_class = search_class
        @params = params
        @size = size
        @min_score = min_score
        @includes = includes
      end

      def name
        :opensearch
      end

      def call
        return [] if @params.nil?

        options = {size: @size}
        options[:min_score] = @min_score if @min_score
        hits = @search_class.call(**@params, **options)
        return [] if hits.empty?

        records = @model_class.where(id: hits.map { |hit| hit[:id].to_i })
        records = records.includes(*@includes) if @includes.any?
        by_id = records.index_by(&:id)

        hits.filter_map do |hit|
          record = by_id[hit[:id].to_i]
          next unless record

          Candidate.new(record: record, sources: [:opensearch], scores: {opensearch: hit[:score]})
        end
      end
    end
  end
end
