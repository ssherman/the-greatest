# frozen_string_literal: true

require "csv"

module Books
  module Goodreads
    # The bytes of a Goodreads library export, turned into ExportRows
    # (Goodreads import spec §4). Refuses a file that is not CSV or lacks the
    # export's headers; never refuses a row (a bad row is the row's problem).
    #
    # Encoding: a BOM is stripped; bytes that are not valid UTF-8 are read as
    # Windows-1252; bytes that are neither are scrubbed. Liberal parsing
    # keeps a field with a stray quote, the likely cause of the 23 legacy
    # imports that died on CSV::MalformedCSVError.
    class ExportFile
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      REQUIRED_HEADERS = ["Book Id", "Title", "Author", "Exclusive Shelf"].freeze
      BOM = "\xEF\xBB\xBF".b

      def self.parse(bytes)
        new(bytes).parse
      end

      def initialize(bytes)
        @bytes = bytes.to_s.b
      end

      def parse
        table = CSV.parse(decode, headers: true, liberal_parsing: true, skip_blanks: true,
          header_converters: ->(header) { header.to_s.strip })
        missing = REQUIRED_HEADERS - table.headers.compact
        return failure("missing Goodreads export headers: #{missing.join(", ")}") if missing.any?

        rows = table.each_with_index.map { |row, index| ExportRow.new(row_number: index + 1, fields: row.to_h) }
        Result.new(success?: true, data: {rows: rows}, errors: [])
      rescue CSV::MalformedCSVError => e
        failure("not a readable CSV file: #{e.message}")
      end

      private

      def decode
        bytes = @bytes.start_with?(BOM) ? @bytes.byteslice(BOM.bytesize..) : @bytes
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        begin
          bytes.encode(Encoding::UTF_8, Encoding::Windows_1252)
        rescue EncodingError
          utf8.scrub("")
        end
      end

      def failure(message)
        Result.new(success?: false, data: {rows: []}, errors: [message])
      end
    end
  end
end
