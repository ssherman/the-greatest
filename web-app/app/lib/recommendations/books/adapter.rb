# frozen_string_literal: true

module Recommendations
  module Books
    # Everything the engine needs to know about books: the user's interactions
    # and shelf, category and item facts, and (Task 7) the two OpenSearch
    # candidate queries. The only place in the engine that names a books model.
    # Root-anchored constants throughout: inside Recommendations::Books a bare
    # `Books::Book` resolves to Recommendations::Books::Book.
    class Adapter
      SCORING_TYPES = ::Books::Book::SIMILARITY_CATEGORY_TYPES
      LIST_KINDS = {"favorites" => :favorite, "read" => :read, "reading" => :reading, "want_to_read" => :want_to_read}.freeze

      attr_reader :config

      def initialize(config:)
        @config = config
      end

      def interactions(user)
        list_weights, kinds = list_weights_for(user)
        reviews = user.reviews.where(reviewable_type: "Books::Book").pluck(:reviewable_id, :rating).to_h

        (list_weights.keys | reviews.keys).map do |item_id|
          rating = reviews[item_id]
          base = list_weights[item_id]
          # A review on a book that is on no list implies it was read.
          base = config[:read_weight] if base.nil? && reviews.key?(item_id)
          weight = (base || 0.0) + (rating ? config[:rating_slope] * (rating - 3) : 0.0)
          Interaction.new(item_id: item_id, weight: weight.to_f, kind: kinds[item_id] || :review, rating: rating)
        end
      end

      def shelved_item_ids(user)
        list_ids = ::UserListItem.joins(:user_list)
          .where(user_lists: {user_id: user.id, type: "Books::UserList"}, listable_type: "Books::Book")
          .distinct.pluck(:listable_id)
        review_ids = user.reviews.where(reviewable_type: "Books::Book").pluck(:reviewable_id)
        list_ids | review_ids
      end

      def categories_for(item_ids)
        return {} if item_ids.empty?

        rows = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: item_ids)
          .where(categories: {deleted: false, category_type: SCORING_TYPES})
          .pluck(:item_id, "categories.id", "categories.category_type", "categories.item_count")
        ranked_counts = ranked_population? ? ranked_counts_for(rows.map { |r| r[1] }.uniq) : nil

        rows.group_by(&:first).transform_values do |group|
          group.map do |_, id, type, count|
            CategoryFact.new(id: id, category_type: type_name(type),
              item_count: ranked_counts ? ranked_counts.fetch(id, 0) : count.to_i)
          end
        end
      end

      # The population the lift's p_c is measured over: every non-provisional
      # book, or (lift_population "ranked") the ranked pool the query draws from.
      # categories_for counts each category over the same population.
      def catalog_size
        @catalog_size ||= ranked_population? ? ranked_pool.count : ::Books::Book.catalog.count
      end

      def type_category_ids
        @type_category_ids ||= ::Books::Category
          .where(name: ::Books::Book::BOOK_TYPE_CATEGORY_NAMES, category_type: :genre)
          .pluck(:name, :id).to_h
      end

      def criteria_for(user)
        ::Books::RecommendationConfig.for_user(user).criteria_object
      end

      def item_facts(item_ids)
        return {} if item_ids.empty?

        authors = ::Books::BookAuthor.where(book_id: item_ids).pluck(:book_id, :author_id).group_by(&:first)
        genres = ::CategoryItem.joins(:category)
          .where(item_type: "Books::Book", item_id: item_ids)
          .where(categories: {deleted: false, category_type: :genre})
          .pluck(:item_id, :category_id).group_by(&:first)
        predecessors = series_predecessors(item_ids)
        ranks = ::RankedItem.where(item_type: "Books::Book", item_id: item_ids,
          ranking_configuration_id: ::Books::RankingConfiguration.default_primary&.id).pluck(:item_id, :rank).to_h

        item_ids.index_with do |id|
          ItemFact.new(
            author_ids: authors.fetch(id, []).map(&:last),
            genre_ids: genres.fetch(id, []).map(&:last),
            series_predecessor_id: predecessors[id],
            rank_position: ranks[id]
          )
        end
      end

      # The cards' preload chain (Books::CardComponent needs authors + cover).
      def load_items(item_ids)
        ::Books::Book.where(id: item_ids)
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: :blob})
          .index_by(&:id)
      end

      def search_candidates(profile:, criteria:, excluded_ids:, size:)
        ::Search::Books::Search::BookRecommendations.call(
          profile: profile, criteria: criteria, excluded_ids: excluded_ids, type_category_ids: type_category_ids,
          options: config.merge(candidate_size: size)
        ).map { |hit| Candidate.new(item_id: hit[:id], score: hit[:score], rank_position: hit[:rank_position], evidence: {taste: true}) }
      end

      def rank_ordered_candidates(criteria:, excluded_ids:, size:)
        ::Search::Books::Search::BookRecommendations.ranked_only(
          criteria: criteria, excluded_ids: excluded_ids, options: config.merge(candidate_size: size)
        ).map { |hit| Candidate.new(item_id: hit[:id], score: hit[:score], rank_position: hit[:rank_position], evidence: {}) }
      end

      private

      def ranked_population?
        config[:lift_population].to_s == "ranked"
      end

      # The same pool Evaluation.candidate_ids measures: the default primary
      # configuration's ranked items with a rank.
      def ranked_pool
        ::RankedItem.where(item_type: "Books::Book", ranking_configuration_id: ::Books::RankingConfiguration.default_primary&.id)
          .where.not(rank: nil)
      end

      def ranked_counts_for(category_ids)
        return {} if category_ids.empty?

        ::CategoryItem.where(item_type: "Books::Book", category_id: category_ids)
          .where(item_id: ranked_pool.select(:item_id))
          .group(:category_id).count
      end

      def list_weights_for(user)
        rows = ::UserListItem.joins(:user_list)
          .where(user_lists: {user_id: user.id, type: "Books::UserList"}, listable_type: "Books::Book")
          .where.not(user_lists: {list_type: ::Books::UserList.list_types["custom"]})
          .pluck(:listable_id, "user_lists.list_type", "user_lists.manually_ordered", :position)

        weights = {}
        kinds = {}
        rows.each do |item_id, list_type, manual, position|
          name = ::Books::UserList.list_types.key(list_type) || list_type.to_s
          weight = list_weight(name, manual, position)
          next if weights[item_id] && weights[item_id] >= weight

          weights[item_id] = weight
          kinds[item_id] = LIST_KINDS.fetch(name)
        end
        [weights, kinds]
      end

      def list_weight(name, manual, position)
        case name
        when "favorites"
          bonus = (manual && position.to_i <= config[:top_favorite_count]) ? config[:top_favorite_bonus] : 0.0
          config[:favorite_weight] + bonus
        when "read", "reading" then config[:read_weight]
        when "want_to_read" then config[:want_to_read_weight]
        else 0.0
        end
      end

      # pluck through a join returns the enum's integer on some adapters and its
      # name on others; normalise to the name.
      def type_name(value)
        value.is_a?(Integer) ? ::Category.category_types.key(value) : value.to_s
      end

      # The nearest NUMBERED entry with a lower position in each of the item's
      # series. Unnumbered entries (novellas at 1.5) never count as predecessors.
      def series_predecessors(item_ids)
        own = ::Books::SeriesBook.where(book_id: item_ids, numbered: true).where.not(position: nil)
          .pluck(:book_id, :series_id, :position)
        return {} if own.empty?

        all = ::Books::SeriesBook.where(series_id: own.map { |_, s, _| s }.uniq, numbered: true)
          .where.not(position: nil).pluck(:series_id, :book_id, :position).group_by(&:first)

        own.each_with_object({}) do |(book_id, series_id, position), out|
          earlier = all.fetch(series_id, []).select { |_, _, p| p < position }.max_by { |_, _, p| p }
          out[book_id] = earlier&.at(1) if out[book_id].nil?
        end
      end
    end
  end
end
