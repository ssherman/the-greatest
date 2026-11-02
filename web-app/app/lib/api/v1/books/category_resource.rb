# frozen_string_literal: true

module Api
  module V1
    module Books
      # The category as the API presents it. Key order here IS the order in
      # config/api/v1/openapi.yaml.
      #
      # `params[:book_count]` is the number of RANKED books (primary ranking)
      # that carry the category -- the list passes the row's ranked_count, show
      # passes one COUNT. The catalog counter cache (categories.item_count)
      # covers unranked books too and is not what the site shows.
      class CategoryResource
        include Alba::Resource

        attributes :id, :slug, :name, :category_type, :description

        attribute :parent do |category|
          # Only a followable parent: a deleted one is null, a merged one is
          # its live target, so the slug always resolves on the public endpoints.
          parent = category.parent&.canonical
          parent && {id: parent.id, slug: parent.slug, name: parent.name}
        end

        attribute :book_count do |_category|
          params[:book_count] || 0
        end
      end
    end
  end
end
