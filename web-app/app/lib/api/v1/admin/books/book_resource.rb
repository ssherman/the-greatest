# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # The book as an admin search result: what an operator needs to pick the
        # right row to merge. Key order is the order in config/api/v1/admin_openapi.yaml.
        # Root-anchor every ::Books:: reference in this namespace.
        class BookResource
          include Alba::Resource

          attributes :id, :slug, :title, :subtitle, :book_kind, :provisional, :first_published_year

          attribute :rank do |book|
            book.primary_ranked_item&.rank
          end

          attribute :authors do |book|
            book.authors.map { |author| ::Api::V1::Books::AuthorSummaryResource.new(author).to_h }
          end
        end
      end
    end
  end
end
