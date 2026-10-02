# frozen_string_literal: true

require "csv"

# Writes one CSV onto any IO: a UTF-8 BOM (so Excel opens accented titles
# correctly), the header line, then rows. Shared by every export path so the
# pre-built file and an on-demand response are byte-for-byte the same shape.
module CsvExports
  class Writer
    BOM = "\uFEFF"

    attr_reader :rows

    def initialize(io, headers:)
      io.write(BOM)
      @csv = CSV.new(io)
      @csv << headers
      @rows = 0
    end

    def row(values)
      @csv << values
      @rows += 1
    end
  end
end
