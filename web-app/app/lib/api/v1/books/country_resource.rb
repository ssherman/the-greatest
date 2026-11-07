# frozen_string_literal: true

module Api
  module V1
    module Books
      # The country as the API presents it. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `params[:book_count]` is the number of RANKED books (primary ranking)
      # from the country -- the list passes the row's ranked_count. The catalog
      # counter (books_countries.book_count) covers unranked books too and is
      # not what the site shows.
      #
      # `slug` is what `country_id` accepts on the book endpoints; `url` is the
      # site's own ranked page for the country, built by the one class that
      # owns the URL grammar.
      class CountryResource
        include Alba::Resource

        attributes :slug, :name

        attribute :book_count do |_country|
          params[:book_count] || 0
        end

        attribute :url do |country|
          "#{::Api::Host.base_url}#{::Books::FilterPath.call(countries: [country])}"
        end
      end
    end
  end
end
