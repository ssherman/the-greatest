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
      @io = io
      @rows = 0
      @io.write(BOM)
      @io.write(CSV.generate_line(headers))
    end

    def row(values)
      @io.write(CSV.generate_line(values))
      @rows += 1
    end
  end
end
