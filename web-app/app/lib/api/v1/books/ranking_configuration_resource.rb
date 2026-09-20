# frozen_string_literal: true

module Api
  module V1
    module Books
      # A ranking configuration as the API presents it: one shape for index
      # and show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # `kind` is always "books" on this host today; it is in the payload so
      # that author configurations (and, on music, albums vs songs) can join
      # additively. The algorithm parameters are deliberately absent (spec D10).
      #
      # Both counts are params the controller batches per page -- `fetch`, so a
      # caller that forgets one fails loudly instead of rendering null.
      class RankingConfigurationResource
        include Alba::Resource

        attributes :id, :name

        attribute :kind do
          "books"
        end

        attributes :primary, :year, :description

        attribute :published_at do |configuration|
          configuration.published_at&.utc&.iso8601
        end

        attribute :last_refreshed_at do |configuration|
          configuration.last_refreshed_at&.utc&.iso8601
        end

        attribute :item_count do
          params.fetch(:item_count)
        end

        attribute :list_count do
          params.fetch(:list_count)
        end

        attribute :url do |configuration|
          "#{::Api::Host.base_url}/rc/#{configuration.id}"
        end

        attribute :api_url do |configuration|
          "#{::Api::Host.base_url}/api/v1/ranking_configurations/#{configuration.id}"
        end

        attribute :books_api_url do |configuration|
          "#{::Api::Host.base_url}/api/v1/ranking_configurations/#{configuration.id}/books"
        end
      end
    end
  end
end
