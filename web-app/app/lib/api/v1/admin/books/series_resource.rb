# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A series as an admin sees it. `params` may carry the page's grouped
        # lookups, :counts ({series_id => book links}) and :goodreads
        # ({series_id => id string}); without them each value is read from the
        # record, so a single series needs no setup. Key order is the order of
        # AdminSeries in config/api/v1/admin_openapi.yaml. Root-anchor every
        # ::Books:: reference.
        class SeriesResource
          include Alba::Resource

          attributes :id, :slug, :title

          attribute :book_count do |series|
            counts = params[:counts]
            counts ? counts.fetch(series.id, 0) : series.series_books.size
          end

          attribute :goodreads_series_id do |series|
            ids = params[:goodreads]
            ids ? ids[series.id] : series.identifiers.find { |row| row.identifier_type == "books_series_goodreads_id" }&.value
          end

          attributes :deleted, :merged_into_id
        end
      end
    end
  end
end
