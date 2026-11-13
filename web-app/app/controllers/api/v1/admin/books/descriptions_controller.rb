# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/books/:id/descriptions    -- every description of a book
        # GET /api/v1/admin/authors/:id/descriptions  -- every description of an author
        #
        # Descriptions are polymorphic; the record is looked up through ::Books::Book
        # or ::Books::Author first, so another domain's descriptions are never
        # reachable here. Root-anchor every ::Books:: reference in this namespace.
        class DescriptionsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes book_index: "books:admin:read", author_index: "books:admin:read"

          def book_index = list_for(::Books::Book, "book")

          def author_index = list_for(::Books::Author, "author")

          private

          # Every kind and locale, in the order the admin page shows them. The shown
          # description is the public page's summary, picked by the same resolver
          # (preferred wins, else source priority; deprecated is never shown).
          def list_for(model, name)
            record = model.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No #{name} #{params[:id]}.")) unless record

            rows = record.descriptions.reorder(rank: :desc, source: :asc).to_a
            render json: {
              data: rows.map { |description| DescriptionResource.new(description).to_h },
              shown_description_id: ::Descriptions::Resolver.call(rows, kind: :summary)&.id
            }
          end
        end
      end
    end
  end
end
