# frozen_string_literal: true

module DataImporters
  module Games
    module Company
      module Providers
        # IGDB provider for Games::Company data
        # Fetches company information from IGDB API and populates the company record
        class Igdb < DataImporters::ProviderBase
          # Populates a company with IGDB data
          #
          # @param company [Games::Company] the company to enrich
          # @param query [ImportQuery] contains igdb_id
          # @return [ProviderResult] success or failure result
          def populate(company, query:)
            api_result = search_service.find_with_details(query.igdb_id)

            return failure_result(errors: api_result[:errors]) unless api_result[:success]

            companies_data = api_result[:data]
            return failure_result(errors: ["Company not found in IGDB"]) if companies_data.empty?

            company_data = companies_data.first

            populate_company_data(company, company_data)
            create_identifier(company, query.igdb_id)

            success_result(data_populated: data_fields_populated(company_data))
          rescue => e
            failure_result(errors: ["IGDB error: #{e.message}"])
          end

          private

          def search_service
            @search_service ||= ::Games::Igdb::Search::CompanySearch.new
          end

          # Maps IGDB company data to model attributes
          def populate_company_data(company, company_data)
            company.name = company_data["name"] if company_data["name"].present?
            company.description = company_data["description"] if company_data["description"].present?

            # Convert IGDB numeric country code to ISO 2-letter
            if company_data["country"].present?
              iso_code = Services::Games::CountryCodeConverter.igdb_to_iso(company_data["country"])
              company.country = iso_code if iso_code.present?
            end

            # Extract year from IGDB start_date (Unix timestamp)
            if company_data["start_date"].present?
              company.year_founded = Time.at(company_data["start_date"]).year
            end
          end

          def create_identifier(company, igdb_id)
            company.identifiers.find_or_initialize_by(
              identifier_type: :games_igdb_company_id,
              value: igdb_id.to_s
            )
          end

          def data_fields_populated(company_data)
            fields = [:name, :igdb_id]
            fields << :description if company_data["description"].present?
            fields << :country if company_data["country"].present?
            fields << :year_founded if company_data["start_date"].present?
            fields
          end
        end
      end
    end
  end
end
