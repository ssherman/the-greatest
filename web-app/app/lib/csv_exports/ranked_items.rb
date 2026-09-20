# frozen_string_literal: true

# Turns a ranked relation into CSV rows on an IO (spec §10). One path for the
# pre-built file (io is a Tempfile) and every on-demand export (io is a
# StringIO), so both are the same bytes for the same rows.
#
# Not `in_batches`: that walks by primary key and ignores the relation's rank
# order, so batches would come out in id order. Instead the ids are plucked
# once in rank order (a few tens of thousands of integers at most), then each
# slice is loaded and re-ordered to match the slice. Memory stays flat at one
# batch of records.
module CsvExports
  class RankedItems
    BATCH = 1000

    # limit: nil means no cap; it replaces any limit the relation carried.
    def self.call(relation:, row_class:, limit:, io:, batch: BATCH)
      writer = Writer.new(io, headers: row_class::HEADERS)

      # rank then id: nothing enforces unique ranks, and an unstable sort on a tie would make the pre-built file and an on-demand export differ.
      ids = relation.unscope(:includes, :preload, :eager_load).order(:id).limit(limit).pluck(:id)
      ids.each_slice(batch) do |slice|
        by_id = ::RankedItem.where(id: slice).preload(item: row_class.preloads).index_by(&:id)

        items = slice.filter_map { |id| by_id[id] }.select(&:item)
        dropped = slice.size - items.size
        Rails.logger.warn("[CsvExports::RankedItems] skipped #{dropped} ranked item(s) with no item in batch") if dropped.positive?

        ctx = row_class.context(items.map(&:item_id))
        items.each { |ranked_item| writer.row(row_class.row(ranked_item, ctx)) }
      end

      writer.rows
    end
  end
end
