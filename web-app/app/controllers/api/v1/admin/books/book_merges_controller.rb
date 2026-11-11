# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # POST /api/v1/admin/books/:id/merge -- folds source_id into :id, deleting the source
        class BookMergesController < BaseController
          include Mergeable

          private

          def model_class = ::Books::Book

          def policy_class = ::Books::BookPolicy

          def resource_for(book) = book_merge_resource(book)
        end
      end
    end
  end
end
