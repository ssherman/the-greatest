# frozen_string_literal: true

module Api
  module V1
    module Books
      module My
        # GET /api/v1/my/books/:slug/lists -- which of the caller's own lists a
        # book is on ("is this on my read list?"), in the /my/lists order.
        #
        # Rows are {list, position, added_at, completed_on}.
        #
        # Every model reference is root-anchored (::Books::…): inside this module
        # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
        class BookListsController < BaseController
          include ::Api::Library

          require_scope "books:library:read"

          def index
            # find_by!(slug:), never friendly.find: purely numeric slugs exist.
            book = ::Books::Book.catalog.find_by!(slug: params[:slug])

            relation = ::UserListItem.where(listable: book)
              .joins(:user_list)
              .where(user_lists: {user_id: library_user.id, type: "Books::UserList"})
              .includes(:user_list)
              .order(Arel.sql(::Api::Library::LISTS_ORDER))

            render_page(relation, path: "/api/v1/my/books/#{book.slug}/lists") do |items|
              counts = book_count_for(items.map(&:user_list))
              items.map do |item|
                {
                  list: UserListResource.new(item.user_list, params: {book_count: counts.fetch(item.user_list_id, 0)}).to_h,
                  position: item.position,
                  added_at: item.created_at.utc.iso8601,
                  completed_on: iso_date(item.completed_on)
                }
              end
            end
          end
        end
      end
    end
  end
end
