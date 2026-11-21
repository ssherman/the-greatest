# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/lists/:id/items -- a list's rows in position order
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class ListItemsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read"

          def index
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list

            items = list.list_items.reorder(Arel.sql("list_items.position ASC NULLS LAST"), :id)
              .preload(listable: [:authors, :countries])
            render_page(items, path: "/api/v1/admin/lists/#{list.id}/items") do |rows|
              rows.map { |item| ListItemResource.new(item).to_h }
            end
          end
        end
      end
    end
  end
end
