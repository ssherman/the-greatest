# frozen_string_literal: true

module Categories
  # Queues every item carrying a category for search reindexing after a change to the
  # category row itself that as_indexed_json reads -- see Category#search_relevant_change?
  # for what qualifies.
  #
  # Inserts the SearchIndexRequest rows synchronously rather than through a background
  # job. Measured against Books "Fiction", the largest category in the app at 68,333
  # items: 31ms to pluck the ids, 3.2s to insert every row in 1000-row slices. The only
  # caller is an after_update_commit callback, so those inserts sit outside the
  # category's own transaction -- a slower admin response, not a held lock. A job would
  # buy nothing and add a commit/enqueue race.
  class ItemReindexer
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    BATCH_SIZE = 1000

    # Indirection so tests can shrink the batch size without stubbing a constant.
    def self.batch_size
      BATCH_SIZE
    end

    def self.call(category:)
      new(category: category).call
    end

    def initialize(category:)
      @category = category
    end

    def call
      return suppressed_result if ::Services::BooksMigration.search_indexing_suppressed?

      # One timestamp for the whole flood, so all of a large category's rows sort as a
      # single group under Search::IndexerJob's oldest_first scope instead of
      # interleaving with requests that arrive mid-insert.
      now = Time.current
      queued = 0

      @category.category_items
        .where(item_type: ::Search::IndexerJob::INDEXED_MODEL_TYPES)
        .in_batches(of: self.class.batch_size) do |batch|
          rows = batch.pluck(:item_type, :item_id).map do |item_type, item_id|
            {
              parent_type: item_type,
              parent_id: item_id,
              action: ::SearchIndexRequest.actions[:index_item],
              created_at: now,
              updated_at: now
            }
          end
          next if rows.empty?

          ::SearchIndexRequest.insert_all(rows)
          queued += rows.size
        end

      Result.new(success?: true, data: {queued: queued}, errors: [])
    end

    private

    # Bulk migrations run inside Services::BooksMigration.without_search_indexing and
    # reindex explicitly at the end. SearchIndexable honours the same flag; so does this.
    def suppressed_result
      Result.new(success?: true, data: {queued: 0, suppressed: true}, errors: [])
    end
  end
end
