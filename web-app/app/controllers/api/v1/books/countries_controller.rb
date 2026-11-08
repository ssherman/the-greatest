# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/countries -- countries with ranked books, for the slugs the
      # `country_id` filter takes. The "unknown" country is never listed
      # (Books::Country.filterable).
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class CountriesController < BaseController
        def index
          sort = enum_param!(:sort, ::Books::BrowseQuery::SORTS)

          configuration = ::Books::RankingConfiguration.default_primary
          relation = configuration && ::Books::BrowseQuery.countries(ranking_configuration: configuration, sort: sort)

          # The sort rides along on the paging links, or `next` would fall back
          # to the default and silently switch lists.
          render_ranked_page(relation, path: "/api/v1/countries", query: {sort: sort}.compact) do |row|
            CountryResource.new(row, params: {book_count: row.ranked_count}).to_h
          end
        end
      end
    end
  end
end
