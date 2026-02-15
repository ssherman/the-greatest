# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Company
      class ImporterTest < ActiveSupport::TestCase
        test "call creates and imports new company" do
          search_service = mock
          search_service.expects(:find_with_details).with(70).returns(
            success: true,
            data: [
              {
                "name" => "Nintendo",
                "description" => "Japanese video game company",
                "country" => 392,
                "start_date" => -2524608000
              }
            ]
          )

          ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 70)

          assert result.success?
          assert_instance_of ::Games::Company, result.item
          assert_equal "Nintendo", result.item.name
          assert result.item.persisted?
          assert_equal "JP", result.item.country
          assert_equal 1889, result.item.year_founded
        end

        test "call returns existing company when found by identifier" do
          existing_company = games_companies(:nintendo)
          existing_company.identifiers.create!(
            identifier_type: :games_igdb_company_id,
            value: "70"
          )

          # Should not call IGDB API when company already exists
          ::Games::Igdb::Search::CompanySearch.expects(:new).never

          result = Importer.call(igdb_id: 70)

          assert result.success?
          assert_equal existing_company, result.item
        end

        test "call re-runs providers with force_providers true" do
          existing_company = games_companies(:nintendo)
          existing_company.identifiers.create!(
            identifier_type: :games_igdb_company_id,
            value: "70"
          )

          search_service = mock
          search_service.expects(:find_with_details).with(70).returns(
            success: true,
            data: [
              {
                "name" => "Nintendo",
                "description" => "Updated description"
              }
            ]
          )

          ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 70, force_providers: true)

          assert result.success?
          assert_equal existing_company, result.item
          assert_equal "Updated description", result.item.reload.description
        end

        test "call fails when igdb_id is invalid" do
          error = assert_raises(ArgumentError) do
            Importer.call(igdb_id: "not-an-integer")
          end

          assert_includes error.message, "Invalid query object"
        end

        test "call creates IGDB identifier for new company" do
          search_service = mock
          search_service.expects(:find_with_details).with(70).returns(
            success: true,
            data: [{"name" => "Nintendo"}]
          )

          ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 70)

          assert result.success?
          identifier = result.item.identifiers.find_by(identifier_type: :games_igdb_company_id)
          assert_not_nil identifier
          assert_equal "70", identifier.value
        end

        test "call handles IGDB API failure" do
          search_service = mock
          search_service.expects(:find_with_details).with(70).returns(
            success: false,
            errors: ["Network error"]
          )

          ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 70)

          refute result.success?
          refute result.item.persisted?
        end
      end
    end
  end
end
