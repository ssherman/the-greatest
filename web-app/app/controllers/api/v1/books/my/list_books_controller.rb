# frozen_string_literal: true

module Api
  module V1
    module Books
      module My
        # GET /api/v1/my/lists/:list/books -- the books on one of the caller's own
        # lists. `:list` is a list id or a default name (favorites, read, reading,
        # want_to_read).
        #
        # Rows are {position, added_at, completed_on, book}. Only catalogue books
        # are served (provisional imports are hidden, as on the site), so positions
        # can skip numbers.
        #
        # POST, PATCH and DELETE change the list, each book change counted against the
        # daily library budget (Api::Library#with_budget). Order of refusals: body or
        # query (400), list (404), rules (422), books (404), budget (429), service (422).
        #
        # Every model reference is root-anchored (::Books::…): inside this module
        # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
        class ListBooksController < BaseController
          include ::Api::Library

          require_scopes index: "books:library:read", create: "books:library:write",
            update: "books:library:write", destroy: "books:library:write"

          ADD_FIELDS = %w[books completed_on].freeze
          UPDATE_FIELDS = %w[completed_on position].freeze

          SORTS = {
            "position" => "user_list_items.position ASC, user_list_items.id ASC",
            "added" => "user_list_items.created_at DESC, user_list_items.id DESC",
            "completed_on" => "user_list_items.completed_on DESC NULLS LAST, user_list_items.position ASC, user_list_items.id ASC"
          }.freeze

          def index
            sort = enum_param!(:sort, SORTS.keys) || "position"
            list = find_my_list!(params[:list])
            return if list.nil?

            if sort == "completed_on" && !list.completed_on_enabled?
              raise ::Api::Page::InvalidParameter, "sort=completed_on needs a list with completion dates, like the read list"
            end

            relation = ::Books::UserList.catalog_items(::UserListItem.where(user_list_id: list.id))
              .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
              .order(Arel.sql(SORTS.fetch(sort)))

            render_page(relation, path: "/api/v1/my/lists/#{list.id}/books", query: {sort: sort}) do |items|
              ranks = ranks_for(items.map(&:listable_id))
              items.map do |item|
                {
                  position: item.position,
                  added_at: item.created_at.utc.iso8601,
                  completed_on: iso_date(item.completed_on),
                  book: BookResource.new(item.listable, params: {rank: ranks[item.listable_id]}).to_h
                }
              end
            end
          end

          # POST /api/v1/my/lists/:list/books  {books: [slug], completed_on?}
          def create
            body = json_body
            return bad_body("The body must be a JSON object with books.") if body.nil?

            return bad_body("books must be an array of book slugs") unless body["books"].is_a?(Array)

            slugs = book_slugs!(body["books"]) or return
            completed_on = completed_on!(body["completed_on"].nil? ? :absent : body["completed_on"], allow_nil: false)
            return if performed?

            list = find_my_list!(params[:list]) or return
            unknown = body.keys - ADD_FIELDS
            return unknown_fields(unknown, ADD_FIELDS) if unknown.any?
            return completed_on_refused unless completed_on == :absent || list.completed_on_enabled?

            books = catalog_books!(slugs) or return
            with_budget(books.size) do
              result = ::Services::UserLists::AddItems.call(
                user_list: list, listables: books, completed_on: (completed_on unless completed_on == :absent)
              )
              render_write(list, result)
            end
          end

          # PATCH /api/v1/my/lists/:list/books/:slug  {completed_on?: date|null, position?: integer}
          def update
            body = json_body
            return bad_body("The body must be a JSON object with completed_on and/or position.") if body.nil?

            completed_on = completed_on!(body.fetch("completed_on", :absent), allow_nil: true)
            return if performed?

            position = body.fetch("position", :absent)
            valid_position = position.is_a?(Integer) && position >= 1
            return bad_body("position must be an integer of 1 or more") unless position == :absent || valid_position
            return bad_body("Send completed_on, position, or both.") if completed_on == :absent && position == :absent

            list = find_my_list!(params[:list]) or return
            unknown = body.keys - UPDATE_FIELDS
            return unknown_fields(unknown, UPDATE_FIELDS) if unknown.any?
            # null clears a date, which only means something on a list that has
            # dates; elsewhere it is the same as leaving the field out.
            completed_on = :absent if completed_on.nil? && !list.completed_on_enabled?
            return bad_body("Send completed_on, position, or both.") if completed_on == :absent && position == :absent
            return completed_on_refused unless completed_on == :absent || list.completed_on_enabled?

            book = (catalog_books!([params[:slug].to_s]) or return).first
            item = list.user_list_items.find_by(listable: book)
            return refuse("That book is not on this list") if item.nil?

            count = list.user_list_items.count
            return refuse("position must be between 1 and #{count}") if position != :absent && position > count

            with_budget(1) do
              result = ::Services::UserLists::UpdateItem.call(
                item: item,
                completed_on: (completed_on == :absent) ? :unchanged : completed_on,
                position: (position == :absent) ? :unchanged : position
              )
              render_write(list, result)
            end
          end

          # DELETE /api/v1/my/lists/:list/books?books=slug,slug
          def destroy
            slugs = book_slugs!(params[:books]) or return
            list = find_my_list!(params[:list]) or return
            books = catalog_books!(slugs) or return

            with_budget(books.size) do
              render_write(list, ::Services::UserLists::RemoveItems.call(user_list: list, listables: books))
            end
          end

          private

          def refuse(detail)
            render_problem(::Api::Problem.new(:unprocessable, detail: detail))
          end

          def completed_on_refused
            refuse("completed_on only applies to a list with completion dates, like the read list")
          end

          # A service failure rolled everything back: a 422, and with_budget
          # sees the non-2xx status and releases the reservation.
          def render_write(list, result)
            return refuse(result.errors.join(", ")) unless result.success?

            write_result(list, result.data.fetch(:outcomes))
          end
        end
      end
    end
  end
end
