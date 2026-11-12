# frozen_string_literal: true

# Exports a frozen ranking archive with the same columns as the live ranking.
# Walks the archive by offset in batch-sized steps; Entries resolves merged and
# deleted books, so a batch can come back short or empty without the archive
# being over. The walk therefore ends only when `limit` rows have been written
# or the offset passes the archive's item count. `limit` counts rows written,
# not archive slots.
#
# Named ArchivedRanking, not RankingArchive, so it does not shadow the model
# inside CsvExports.
module CsvExports
  class ArchivedRanking
    BATCH = 1000

    def self.call(archive:, row_class:, limit:, io:, batch: BATCH)
      writer = Writer.new(io, headers: row_class::HEADERS)
      offset = 0

      while offset < archive.items_count && (limit.nil? || writer.rows < limit)
        entries = ::Services::RankingArchives::Entries.call(
          archive: archive, offset: offset, limit: batch, preload: row_class.preloads
        )
        ctx = row_class.context(entries.map { |entry| entry.item.id })
        entries.each do |entry|
          break if limit && writer.rows >= limit

          writer.row(row_class.row_for_book(entry.item, rank: entry.rank, score: entry.score, ctx: ctx))
        end
        offset += batch
      end

      writer.rows
    end
  end
end
