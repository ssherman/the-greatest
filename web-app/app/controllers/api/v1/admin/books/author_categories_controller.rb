# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST   /api/v1/admin/authors/:id/categories               -- tag an author
        # DELETE /api/v1/admin/authors/:id/categories/:category_id  -- untag them
        class AuthorCategoriesController < BaseController
          include CategoryTaggable

          private

          def model_class = ::Books::Author

          def policy_class = ::Books::AuthorPolicy
        end
      end
    end
  end
end
