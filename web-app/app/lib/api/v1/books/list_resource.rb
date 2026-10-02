# frozen_string_literal: true

module Api
  module V1
    module Books
      # A list as the API presents it. Compact by default (every collection
      # row), with a :full trait for show. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `weight` and `item_count` are params the controller settles per page:
      # weight is a property of the (list, configuration) pair, not of the
      # list (spec D1), so the resource never looks it up itself; item_count is
      # batched. Both use `fetch` -- a caller that forgets one fails loudly
      # instead of rendering null, and a list that is off the configuration
      # passes weight: nil on purpose.
      #
      # `url` is the list's page on the site; the lists.url column (the
      # original list on the web) is `source_url`, in the full shape only. The
      # editorial flags and the weight breakdown are deliberately absent (D10).
      class ListResource
        include Alba::Resource

        attributes :id, :name, :source, :year_published, :yearly_award, :number_of_voters

        attribute :item_count do
          params.fetch(:item_count)
        end

        attribute :weight do
          params.fetch(:weight)
        end

        attribute :activated_at do |list|
          list.activated_at&.utc&.iso8601
        end

        attribute :url do |list|
          "#{::Api::Host.base_url}/lists/#{list.id}"
        end

        attribute :api_url do |list|
          "#{::Api::Host.base_url}/api/v1/lists/#{list.id}"
        end

        attribute :items_api_url do |list|
          "#{::Api::Host.base_url}/api/v1/lists/#{list.id}/items"
        end

        trait :full do
          attributes :description

          attribute :source_url do |list|
            list.url
          end
        end
      end
    end
  end
end
