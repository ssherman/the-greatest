# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST   /api/v1/admin/books/:id/categories               -- tag a book
        # DELETE /api/v1/admin/books/:id/categories/:category_id  -- untag it
        class BookCategoriesController < BaseController
          include CategoryTaggable

          private

          def model_class = ::Books::Book

          def policy_class = ::Books::BookPolicy
        end
      end
    end
  end
end
