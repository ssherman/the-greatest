# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/lists/:list_id/items -- the list's books in list order
      #
      # Rows are {position, book}: position ASC with the unpositioned rows
      # last, then by row id -- the site's order (spec D6). Only rows whose
      # listable is a set Books::Book are counted or served (book_items), so
      # total_count matches the rows. rank on the embedded book is the
      # primary's, batched per page.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class ListItemsController < BaseController
        def index
          list = ::Books::List.active.find(params[:list_id])
          relation = book_items(list.list_items)
            .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
            .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC"))

          render_page(relation, path: "/api/v1/lists/#{list.id}/items") do |items|
            ranks = ranks_for(items.map(&:listable_id))
            items.map do |item|
              {position: item.position, book: BookResource.new(item.listable, params: {rank: ranks[item.listable_id]}).to_h}
            end
          end
        end

        private

        # {book_id => rank} on the primary configuration in one query; {} when
        # there is no primary or the page is empty. The key is always passed to
        # BookResource (nil for an unranked book) so it never falls back to the
        # per-row primary_ranked_item lookup.
        def ranks_for(book_ids)
          primary = ::Books::RankingConfiguration.default_primary
          return {} if primary.nil? || book_ids.empty?

          ::RankedItem.where(ranking_configuration_id: primary.id, item_type: "Books::Book", item_id: book_ids)
            .pluck(:item_id, :rank).to_h
        end
      end
    end
  end
end
