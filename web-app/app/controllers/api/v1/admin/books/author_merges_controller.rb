# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/authors/:id/merge -- folds source_id into :id, deleting the source
        class AuthorMergesController < BaseController
          include Mergeable

          private

          def model_class = ::Books::Author

          def policy_class = ::Books::AuthorPolicy

          def resource_for(author)
            author = ::Books::Author.includes(:primary_ranked_item).find(author.id)
            counts = ::Books::BookAuthor.where(author_id: author.id).group(:author_id).count
            AuthorResource.new(author, params: {book_counts: counts}).to_h
          end
        end
      end
    end
  end
end
