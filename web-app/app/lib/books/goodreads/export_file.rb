# frozen_string_literal: true

require "csv"

module Books
  module Goodreads
    # The bytes of a Goodreads library export, turned into ExportRows
    # (Goodreads import spec §4). Refuses a file that is not CSV or lacks the
    # export's headers; never refuses a row (a bad row is the row's problem).
    #
    # Encoding: a BOM is stripped; a file that is UTF-8 apart from stray
    # bytes stays UTF-8, with the stray bytes scrubbed; anything else is read
    # as Windows-1252, its undefined bytes dropped. NUL bytes are removed
    # (Postgres refuses them). Liberal parsing keeps a field with a stray
    # quote, the likely cause of the 23 legacy imports that died on
    # CSV::MalformedCSVError. Where a stray quote has split a field, the
    # row's columns no longer line up with the header; that row is passed on
    # misaligned, so nothing in it is read under the wrong header.
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
        # Plain arrays, not CSV::Table: a table pads a short row out to the
        # header and takes its header count from the first row, so neither a
        # short nor a long row would show.
        records = CSV.parse(decode, liberal_parsing: true, skip_blanks: true)
        headers = Array(records.shift).map { |header| header.to_s.strip }
        missing = REQUIRED_HEADERS - headers
        return failure("missing Goodreads export headers: #{missing.join(", ")}") if missing.any?

        rows = records.each_with_index.map do |fields, index|
          ExportRow.new(row_number: index + 1, fields: headers.zip(fields).to_h, misaligned: fields.size != headers.size)
        end
        Result.new(success?: true, data: {rows: rows}, errors: [])
      rescue CSV::MalformedCSVError => e
        failure("not a readable CSV file: #{e.message}")
      end

      private

      def decode
        bytes = @bytes.start_with?(BOM) ? @bytes.byteslice(BOM.bytesize..) : @bytes
        text_for(bytes).delete("\u0000")
      end

      # A UTF-8 file with a stray byte still holds real multibyte characters
      # once the stray byte is scrubbed. A Windows-1252 file's accented bytes
      # are each invalid UTF-8 on their own, so scrubbing leaves it plain
      # ASCII: that is the sign to read it as Windows-1252 instead.
      def text_for(bytes)
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        scrubbed = utf8.scrub("")
        return scrubbed unless scrubbed.ascii_only?

        bytes.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace, replace: "")
      end

      def failure(message)
        Result.new(success?: false, data: {rows: []}, errors: [message])
      end
    end
  end
end
