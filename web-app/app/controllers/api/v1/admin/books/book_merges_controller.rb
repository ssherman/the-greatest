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

          # Re-read with the associations the resource renders, so the survivor
          # reflects the merge and the deleted record is captured whole.
          def resource_for(book)
            BookResource.new(::Books::Book.includes(:authors, :primary_ranked_item).find(book.id)).to_h
          end
        end
      end
    end
  end
end
