# frozen_string_literal: true

module Services
  module Books
    # Recomputes books_authors.name_keys (Services::Text::PersonNameKey over
    # the name and alternate names) for every author whose stored keys
    # differ, and writes them in batches with one UPDATE ... FROM (VALUES)
    # per batch. Books::Author keeps the column current on every save; this
    # fills it once (the migration that adds the column calls it) and again
    # only if the key rule changes (bin/rails books:refresh_author_name_keys).
    #
    # It must never raise on odd stored data: the migration runs it during a
    # deploy, and a failing migration is an outage.
    class RefreshAuthorNameKeys
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      BATCH_SIZE = 2000

      def self.call(batch_size: BATCH_SIZE)
        new(batch_size: batch_size).call
      end

      def initialize(batch_size:)
        @batch_size = batch_size
      end

      def call
        scanned = 0
        updated = 0
        ::Books::Author.in_batches(of: @batch_size) do |batch|
          rows = batch.pluck(:id, :name, :alternate_names, :name_keys)
          scanned += rows.size
          changed = rows.filter_map do |id, name, alternate_names, stored|
            keys = ::Services::Text::PersonNameKey.all([name, *Array(alternate_names)])
            [id, keys] unless keys == stored
          end
          next if changed.empty?

          write(changed)
          updated += changed.size
        end
        Result.new(success?: true, data: {scanned: scanned, updated: updated}, errors: [])
      end

      private

      def write(rows)
        connection = ::Books::Author.connection
        type = ::Books::Author.type_for_attribute(:name_keys)
        values = rows.map { |id, keys| "(#{connection.quote(id)}, #{connection.quote(type.serialize(keys))}::varchar[])" }
        # update, not exec_update: only update clears the query cache, and a
        # cached pluck would show the next run the keys from before this write.
        connection.update(<<~SQL.squish, "RefreshAuthorNameKeys")
          UPDATE books_authors SET name_keys = v.keys
          FROM (VALUES #{values.join(", ")}) AS v(id, keys)
          WHERE books_authors.id = v.id
        SQL
      end
    end
  end
end
