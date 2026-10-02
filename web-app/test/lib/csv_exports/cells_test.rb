# frozen_string_literal: true

require "test_helper"

module CsvExports
  class CellsTest < ActiveSupport::TestCase
    test "scores carry two decimals" do
      assert_equal "99.50", Cells.score(BigDecimal("99.5"))
      assert_equal "12.00", Cells.score(12)
      assert_equal "87.13", Cells.score(BigDecimal("87.13"))
    end

    test "a missing score is an empty cell" do
      assert_nil Cells.score(nil)
    end
  end
end
