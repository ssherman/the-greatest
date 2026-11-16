# frozen_string_literal: true

module Api
  module V1
    module Books
      # The language as the API presents it. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `params[:book_count]` is the number of catalogue books originally written
      # in the language. `slug` is what `language` and `exclude_language` accept
      # on discover_books.
      class LanguageResource
        include Alba::Resource

        attributes :slug, :name

        attribute :book_count do |_language|
          params[:book_count] || 0
        end
      end
    end
  end
end
