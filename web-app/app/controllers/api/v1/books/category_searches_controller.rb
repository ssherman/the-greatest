# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/search/categories?q= -- categories matched by name or alias,
      # the same Postgres query as the site's category search
      # (Books::BrowseQuery.search), so a hit never disagrees with the site.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class CategorySearchesController < BaseController
        def index
          query = text_param!(
            :q,
            required: true,
            min_length: ::Books::BrowseQuery::SEARCH_MIN_LENGTH,
            max_length: ::Books::BrowseQuery::SEARCH_MAX_LENGTH
          )
          type = enum_param!(:type, ::Books::BrowseQuery::TYPES)

          # BrowseQuery.search carries its own .limit(SEARCH_LIMIT), which
          # render_page's .offset().limit() would replace. Loading its (at most
          # 60) rows first and paging a plain relation over their ids keeps the
          # cap in total_count; the order and each ranked_count come from the load.
          configuration = ::Books::RankingConfiguration.default_primary
          rows = configuration ? ::Books::BrowseQuery.search(ranking_configuration: configuration, query: query, type: type).to_a : []
          ids = rows.map(&:id)
          counts = rows.to_h { |row| [row.id, row.ranked_count] }

          relation = if ids.any?
            ::Books::Category.where(id: ids).in_order_of(:id, ids).includes(parent: :merged_into)
          end

          render_page(relation, path: "/api/v1/search/categories", query: {q: query, type: params[:type].presence && type}.compact) do |page_rows|
            page_rows.map { |row| CategoryResource.new(row, params: {book_count: counts.fetch(row.id)}).to_h }
          end
        end
      end
    end
  end
end
