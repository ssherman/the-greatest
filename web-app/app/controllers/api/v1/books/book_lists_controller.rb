# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books/:slug/lists -- every active list the book is on
      # GET /api/v1/ranking_configurations/:id/books/:slug/lists -- only the lists that configuration feeds
      #
      # Rows are {position, list}: the book's position on that list and the
      # compact list, whose weight is the primary configuration's or null when
      # the list does not feed it (spec D7). Weighted lists come first; a
      # null-weight row is self-describing, so "100 Notable Books of 2024" is
      # visible from the book's side while /lists/{id} serves it.
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class BookListsController < BaseController
        def index
          # Resolved first, so a bad configuration is a 404 before the book.
          configuration = ranking_configuration if nested_configuration_id
          # find_by!(slug:), never friendly.find: 137 books have purely numeric
          # slugs and friendly_id resolves slugs before primary keys.
          book = ::Books::Book.catalog.find_by!(slug: params[:slug])

          render_page(listings_for(book, configuration), path: collection_path("books/#{book.slug}/lists")) do |items|
            counts = item_counts_for(items.map(&:list_id))
            items.map do |item|
              {position: item.position, list: ListResource.new(item.list, params: {weight: item.weight, item_count: counts.fetch(item.list_id, 0)}).to_h}
            end
          end
        end

        private

        # The book's rows on active books lists, each carrying the list's
        # weight on the primary configuration (NULL off it) so the database
        # orders weighted lists first and pagination stays consistent. With
        # no primary yet every weight is NULL and the order is by list id.
        #
        # preload, not includes: where(lists: …) references the lists table
        # and joins(:list) is already there — either one would promote
        # includes to an eager-load JOIN, which clashes with the custom
        # select.
        #
        # Under a named configuration (`configuration` given) the join is an
        # INNER one: only the lists that configuration feeds appear, with its
        # weights, and a fed list with no weight yet comes last (D-d).
        def listings_for(book, configuration = nil)
          relation = ::ListItem.where(listable: book).joins(:list)
            .where(::Books::ListsQuery.active_list_conditions)
            .preload(:list)

          if configuration
            return relation
                .joins("INNER JOIN ranked_lists ON ranked_lists.list_id = lists.id AND ranked_lists.ranking_configuration_id = #{configuration.id.to_i}")
                .select("list_items.*, ranked_lists.weight AS weight")
                .order(Arel.sql("ranked_lists.weight DESC NULLS LAST, lists.id ASC"))
          end

          primary = ::Books::RankingConfiguration.default_primary

          if primary.nil?
            return relation
                .select("list_items.*, NULL::integer AS weight")
                .order(Arel.sql("lists.id ASC"))
          end

          relation
            .joins(
              "LEFT OUTER JOIN ranked_lists ON ranked_lists.list_id = lists.id " \
              "AND ranked_lists.ranking_configuration_id = #{primary.id.to_i}"
            )
            .select("list_items.*, ranked_lists.weight AS weight")
            .order(Arel.sql("ranked_lists.weight DESC NULLS LAST, lists.id ASC"))
        end
      end
    end
  end
end
