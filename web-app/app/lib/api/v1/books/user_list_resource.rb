# frozen_string_literal: true

module Api
  module V1
    module Books
      # A member's own books list. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `params[:book_count]` is the catalogue books on the list, settled per
      # page by the controller; `url` is the list's page on the site.
      class UserListResource
        include Alba::Resource

        attributes :id, :name, :list_type

        attribute :default do |list|
          list.default?
        end

        attributes :description, :public

        attribute :book_count do |_list|
          params[:book_count] || 0
        end

        attribute :created_at do |list|
          list.created_at.utc.iso8601
        end

        attribute :updated_at do |list|
          list.updated_at.utc.iso8601
        end

        attribute :url do |list|
          "#{::Api::Host.base_url}/my/lists/#{list.id}"
        end

        attribute :api_url do |list|
          "#{::Api::Host.base_url}/api/v1/my/lists/#{list.id}"
        end

        attribute :books_api_url do |list|
          "#{::Api::Host.base_url}/api/v1/my/lists/#{list.id}/books"
        end
      end
    end
  end
end
