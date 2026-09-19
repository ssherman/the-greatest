# frozen_string_literal: true

require "test_helper"

module CsvExports
  class WriterTest < ActiveSupport::TestCase
    test "writes a BOM, the header and each row, counting rows" do
      io = StringIO.new
      writer = Writer.new(io, headers: ["Rank", "Title"])
      writer.row([1, "War and Peace"])
      writer.row([2, "Crime, and Punishment"])

      assert_equal 2, writer.rows
      assert_equal "\uFEFFRank,Title\n1,War and Peace\n2,\"Crime, and Punishment\"\n", io.string
    end

    test "a header-only export is still a valid file" do
      io = StringIO.new
      writer = Writer.new(io, headers: ["Rank"])

      assert_equal 0, writer.rows
      assert_equal "\uFEFFRank\n", io.string
    end
  end
end
