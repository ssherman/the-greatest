# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET    /api/v1/admin/lists/:id/items -- a list's rows in position order
        # POST   /api/v1/admin/lists/:id/items -- add a book as a verified row; body {book_id, position?}
        # PATCH  /api/v1/admin/list_items/:id  -- relink and/or reposition a row; body {book_id?, position?}
        # DELETE /api/v1/admin/list_items/:id  -- remove a row (the book stays)
        #
        # The write rules live in Services::Lists::AdminItems. A service failure flagged
        # `conflict` is a 409; any other failure is a 422.
        #
        # Root-anchor every ::Books:: reference in this namespace.
        class ListItemsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include ::Api::JsonBody

          require_scopes index: "books:admin:read", create: "books:admin:write", update: "books:admin:write", destroy: "books:admin:write"

          def index
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            return render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list

            items = list.list_items.reorder(Arel.sql("list_items.position ASC NULLS LAST"), :id)
              .preload(listable: [:authors, :countries])
            render_page(items, path: "/api/v1/admin/lists/#{list.id}/items") do |rows|
              rows.map { |item| ListItemResource.new(item).to_h }
            end
          end

          def create
            list = find_list or return
            return forbidden_update(list) unless allowed?(list)

            body = body_for(%w[book_id position]) or return
            return bad_body("book_id is required and must be an integer") unless body["book_id"].is_a?(Integer)
            return bad_body("position must be an integer or null") unless position_ok?(body)

            book = ::Books::Book.find_by(id: body["book_id"])
            return unprocessable("No book #{body["book_id"]}.") unless book

            result = ::Services::Lists::AdminItems.create(list: list, book: book, position: body["position"], user: current_principal.user)
            respond(result, "create", list)
          end

          def update
            item = find_item or return
            return forbidden_update(item.list) unless allowed?(item.list)

            body = body_for(%w[book_id position]) or return
            if body.key?("book_id") && !body["book_id"].is_a?(Integer)
              return bad_body("book_id must be an integer")
            end
            return bad_body("position must be an integer or null") unless position_ok?(body)
            return unprocessable("Nothing to change: send book_id and/or position.") if body.empty?

            attrs = {}
            if body.key?("book_id")
              book = ::Books::Book.find_by(id: body["book_id"])
              return unprocessable("No book #{body["book_id"]}.") unless book

              attrs[:book] = book
            end
            attrs[:position] = body["position"] if body.key?("position")

            result = ::Services::Lists::AdminItems.update(item: item, user: current_principal.user, **attrs)
            respond(result, "update", item.list)
          end

          def destroy
            item = find_item or return
            return forbidden_update(item.list) unless allowed?(item.list)

            respond(::Services::Lists::AdminItems.destroy(item: item), "delete", item.list)
          end

          private

          def find_list
            list = ::Books::List.find_by(id: parse_id(params[:id]))
            render_problem(::Api::Problem.new(:not_found, detail: "No books list #{params[:id]}.")) unless list
            list
          end

          def find_item
            item = ::ListItem.joins(:list).where(lists: {type: "Books::List"}).find_by(id: parse_id(params[:id]))
            render_problem(::Api::Problem.new(:not_found, detail: "No books list item #{params[:id]}.")) unless item
            item
          end

          def allowed?(list) = ::Books::ListPolicy.new(current_principal.user, list).update?

          def forbidden_update(list)
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not edit list #{list.id}."))
          end

          def position_ok?(body) = !body.key?("position") || body["position"].nil? || (body["position"].is_a?(Integer) && body["position"].abs <= 2_147_483_647)

          def unprocessable(detail)
            render_problem(::Api::Problem.new(:unprocessable, detail: detail))
          end

          # The JSON object; nil after rendering the 400 or 422 for a body that is not an
          # object or carries a key outside `allowed`.
          def body_for(allowed)
            body = json_body
            if body.nil?
              bad_body("The body must be a JSON object.")
              return
            end

            unknown = body.keys - allowed
            if unknown.any?
              unprocessable("Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Accepted: #{allowed.join(", ")}.")
              return
            end

            body
          end

          def respond(result, action, list)
            unless result.success?
              kind = result.data[:conflict] ? :conflict : :unprocessable
              return render_problem(::Api::Problem.new(kind, detail: result.errors.join(", ")))
            end

            item = result.data[:item]
            log(action, list, item)
            ActiveRecord::Associations::Preloader.new(records: [item], associations: {listable: [:authors, :countries]}).call
            payload = {data: ListItemResource.new(item).to_h}
            payload[:promoted] = result.data[:promoted] unless action == "delete"
            render json: payload
          end

          def log(action, list, item)
            Rails.logger.info("event=api_admin_list_item_#{action} token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} list_id=#{list.id} item_id=#{item.id}")
          end
        end
      end
    end
  end
end
