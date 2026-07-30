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
            row = @company.descriptions.detect { |d| d.source == "igdb" }
            assert_not_nil row, "expected an igdb description to be built"
            assert_equal "Japanese video game company", row.content
            assert_equal "summary", row.kind
            assert_equal "normal", row.rank
            assert_nil @company.description
            assert_equal "JP", @company.country
            assert_equal 1889, @company.year_founded
          end

          test "re-import persists a changed description on an already-saved company" do
            company = games_companies(:capcom)
            company.descriptions.create!(
              kind: :summary, locale: "en", source: :igdb, content: "Stale description."
            )
            company.reload

            search_service = mock
            search_service.expects(:find_with_details).with(8).returns(
              success: true,
              data: [{"name" => "Capcom", "description" => "Fresh description from IGDB."}]
            )
            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            result = @provider.populate(company, query: ImportQuery.new(igdb_id: 8))
            assert result.success?
            company.save!

            assert_equal "Fresh description from IGDB.",
              company.descriptions.reload.find_by(source: :igdb).content
          end

          test "populate leaves the company saveable with a description attached" do
            search_service = mock
            search_service.stubs(:find_with_details).with(70).returns(
              {success: true, data: [{"name" => "Nintendo", "description" => "A description."}]},
              {success: true, data: [{"name" => "Nintendo", "description" => "An updated description."}]}
            )
            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

            @provider.populate(@company, query: ImportQuery.new(igdb_id: 70))

            assert @company.valid?, @company.errors.full_messages.join(", ")
            assert_difference "Description.count", 1 do
              @company.save!
            end

            assert_no_difference "Description.count" do
              @provider.populate(@company, query: ImportQuery.new(igdb_id: 70))
              @company.save!
            end

            assert_equal "An updated description.",
              @company.descriptions.reload.find_by(source: :igdb).content
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
