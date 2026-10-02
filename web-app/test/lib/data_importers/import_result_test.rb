# frozen_string_literal: true

require "test_helper"

module DataImporters
  class ImportResultTest < ActiveSupport::TestCase
    test "created defaults to false and is reported in the summary" do
      result = ImportResult.new(item: nil, provider_results: [], success: true)
      created = ImportResult.new(item: nil, provider_results: [], success: true, created: true)

      assert_not result.created?
      assert created.created?
      assert_equal [false, true], [result.summary[:item_created], created.summary[:item_created]]
    end
  end
end
