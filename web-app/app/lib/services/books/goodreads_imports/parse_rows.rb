# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Writes one import row per export row and links each parseable row to
      # its edition, creating the edition the first time any import names
      # that Goodreads id under that signature (Goodreads import spec §3, §5).
      # An edition another import created is reused as it is; its fields are
      # never rewritten. A row that cannot be parsed, or cannot be stored, is
      # kept, failed, with the reason; one bad row never stops the rest
      # (spec §13). Postgres errors re-raise. Safe to run again: rows already
      # written are skipped.
      class ParseRows
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

        def self.call(import:, rows:)
          new(import: import, rows: rows).call
        end

        def initialize(import:, rows:)
          @import = import
          @rows = rows
        end

        def call
          written = @import.rows.pluck(:row_number).to_set
          @rows.each do |row|
            next if written.include?(row.row_number)

            write(row)
          end
          @import.update!(
            rows_count: @import.rows.count,
            editions_count: @import.rows.where.not(goodreads_edition_id: nil).distinct.count(:goodreads_edition_id)
          )
          Result.new(success?: true, data: {import: @import}, errors: [])
        end

        private

        def write(row)
          if row.valid?
            @import.rows.create!(row.row_attributes.merge(goodreads_edition: edition_for(row)))
          else
            @import.rows.create!(row.row_attributes.merge(outcome: :failed, error: row.errors.join("; ")))
          end
        rescue *POSTGRES_ERRORS
          raise
        rescue => e
          @import.rows.create!(row_number: row.row_number, outcome: :failed,
            error: "row could not be stored: #{e.class}: #{e.message}")
        end

        def edition_for(row)
          key = {goodreads_book_id: row.goodreads_book_id, signature: row.signature}
          ::Books::GoodreadsEdition.find_by(key) ||
            ::Books::GoodreadsEdition.create_or_find_by!(key) { |edition| edition.assign_attributes(row.edition_attributes) }
        end
      end
    end
  end
end
