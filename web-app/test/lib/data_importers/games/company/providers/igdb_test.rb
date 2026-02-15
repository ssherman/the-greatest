# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Company
      module Providers
        class IgdbTest < ActiveSupport::TestCase
          def setup
            @provider = Igdb.new
            @company = ::Games::Company.new
          end

          test "populate sets company attributes from IGDB data" do
            search_service = mock
            search_service.expects(:find_with_details).with(70).returns(
              success: true,
              data: [
                {
                  "name" => "Nintendo",
                  "description" => "Japanese video game company",
                  "country" => 392, # Japan
                  "start_date" => -2524608000 # 1889 Unix timestamp
                }
              ]
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 70)
            result = @provider.populate(@company, query: query)

            assert result.success?
            assert_equal "Nintendo", @company.name
            assert_equal "Japanese video game company", @company.description
            assert_equal "JP", @company.country
            assert_equal 1889, @company.year_founded
          end

          test "populate creates IGDB identifier" do
            search_service = mock
            search_service.expects(:find_with_details).with(70).returns(
              success: true,
              data: [{"name" => "Nintendo"}]
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 70)
            @provider.populate(@company, query: query)

            identifier = @company.identifiers.find { |i| i.identifier_type == "games_igdb_company_id" }
            assert_not_nil identifier
            assert_equal "70", identifier.value
          end

          test "populate returns failure when IGDB API fails" do
            search_service = mock
            search_service.expects(:find_with_details).with(70).returns(
              success: false,
              errors: ["API rate limit exceeded"]
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 70)
            result = @provider.populate(@company, query: query)

            refute result.success?
            assert_includes result.errors, "API rate limit exceeded"
          end

          test "populate returns failure when company not found" do
            search_service = mock
            search_service.expects(:find_with_details).with(99999).returns(
              success: true,
              data: []
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 99999)
            result = @provider.populate(@company, query: query)

            refute result.success?
            assert_includes result.errors, "Company not found in IGDB"
          end

          test "populate handles missing optional fields gracefully" do
            search_service = mock
            search_service.expects(:find_with_details).with(70).returns(
              success: true,
              data: [{"name" => "Unknown Company"}]
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 70)
            result = @provider.populate(@company, query: query)

            assert result.success?
            assert_equal "Unknown Company", @company.name
            assert_nil @company.description
            assert_nil @company.country
            assert_nil @company.year_founded
          end

          test "populate skips unknown country codes" do
            search_service = mock
            search_service.expects(:find_with_details).with(70).returns(
              success: true,
              data: [
                {
                  "name" => "Test Company",
                  "country" => 999 # Unknown country code
                }
              ]
            )

            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 70)
            @provider.populate(@company, query: query)

            assert_nil @company.country
          end
        end
      end
    end
  end
end
