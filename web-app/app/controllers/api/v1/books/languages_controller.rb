# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/languages -- the original languages of catalogue books, for
      # the slugs `language` and `exclude_language` take on discover_books.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class LanguagesController < BaseController
        def index
          sort = enum_param!(:sort, ::Books::BrowseQuery::SORTS)
          relation = ::Books::BrowseQuery.languages(sort: sort)

          # The sort rides along on the paging links, or `next` would fall back
          # to the default and silently switch lists.
          render_ranked_page(relation, path: "/api/v1/languages", query: {sort: sort}.compact) do |row|
            LanguageResource.new(row, params: {book_count: row.book_count}).to_h
          end
        end
      end
    end
  end
end
