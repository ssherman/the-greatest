module Services
  module BooksMigration
    # Backfills book_length, page_range, and word_count onto already-migrated
    # books. Unlike every other migrator in this suite it UPDATEs rather than
    # inserts, so it cannot use BulkUpsertMigrator: upsert_all's INSERT arm would
    # have to satisfy books_books' NOT NULL title and slug, which a three-column
    # attribute row does not carry. A batched UPDATE ... FROM (VALUES ...) keyed
    # on the preserved ids does the same job in one statement per batch.
    #
    # book_length is copied verbatim, never re-derived: legacy's stored value is
    # what its saved searches were built against, including the 1,136 books whose
    # page_range never parsed and the 3 whose length came from neither source.
    class BookAttributesMigrator < Migrator
      UPDATE_BATCH = 1000

      def call
        @count = 0
        buffer = []
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            buffer << row_for(attrs)
            if buffer.size >= update_batch
              flush(buffer)
              buffer = []
            end
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows updated): #{e.message}"
          end
          flush(buffer) if buffer.any?
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      def update_batch
        UPDATE_BATCH
      end

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book"
      end

      def legacy_each(&block)
        legacy_model.select(:id, :book_length, :page_range, :word_count)
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def row_for(attrs)
        [attrs["id"], attrs["book_length"], attrs["page_range"], attrs["word_count"]]
      end

      def flush(rows)
        connection = ::Books::Book.connection
        values = rows.map do |id, book_length, page_range, word_count|
          "(#{connection.quote(id)}::bigint, " \
            "#{connection.quote(book_length)}::integer, " \
            "#{connection.quote(page_range)}::varchar, " \
            "#{connection.quote(word_count)}::integer)"
        end.join(", ")

        connection.execute(<<~SQL)
          UPDATE books_books
             SET book_length = v.book_length,
                 page_range  = v.page_range,
                 word_count  = v.word_count
            FROM (VALUES #{values}) AS v(id, book_length, page_range, word_count)
           WHERE books_books.id = v.id
        SQL

        @count += rows.size
      end
    end
  end
end
