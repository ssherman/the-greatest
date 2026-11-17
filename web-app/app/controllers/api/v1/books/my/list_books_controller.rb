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
        # Every model reference is root-anchored (::Books::…): inside this module
        # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
        class ListBooksController < BaseController
          include ::Api::Library

          require_scope "books:library:read"

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
        end
      end
    end
  end
end
