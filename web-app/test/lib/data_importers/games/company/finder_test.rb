# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Company
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
          @nintendo = games_companies(:nintendo)
        end

        test "call finds existing company by IGDB identifier" do
          # Create IGDB identifier for Nintendo
          @nintendo.identifiers.create!(
            identifier_type: :games_igdb_company_id,
            value: "70"
          )

          query = ImportQuery.new(igdb_id: 70)
          result = @finder.call(query: query)

          assert_equal @nintendo, result
        end

        test "call returns nil when no identifier matches" do
          query = ImportQuery.new(igdb_id: 99999)
          result = @finder.call(query: query)

          assert_nil result
        end

        test "call returns nil when igdb_id is blank" do
          query = ImportQuery.new(igdb_id: nil)

          # Bypass validation for this test
          query.stubs(:valid?).returns(true)

          result = @finder.call(query: query)

          assert_nil result
        end
      end
    end
  end
end
