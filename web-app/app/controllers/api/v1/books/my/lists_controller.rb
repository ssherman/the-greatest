# frozen_string_literal: true

module Api
  module V1
    module Books
      module My
        # GET /api/v1/my/lists -- the token holder's own books lists, in the
        # site's /my/lists order: the four defaults, then custom lists by name.
        #
        # Every model reference is root-anchored (::Books::…): inside this module
        # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
        class ListsController < BaseController
          include ::Api::Library

          require_scope "books:library:read"

          def index
            # A member from before a default existed (or a new one) has no
            # reading/want_to_read list yet; creating them here is what the site does.
            relation = library_user.user_lists.where(type: "Books::UserList")
            ::Services::UserLists::EnsureDefaults.call(user: library_user, domain: :books, existing: relation.to_a)

            render_page(relation.order(Arel.sql(::Api::Library::LISTS_ORDER)), path: "/api/v1/my/lists") do |lists|
              counts = book_count_for(lists)
              lists.map { |list| UserListResource.new(list, params: {book_count: counts.fetch(list.id, 0)}).to_h }
            end
          end
        end
      end
    end
  end
end
