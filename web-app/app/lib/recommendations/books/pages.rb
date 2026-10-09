# frozen_string_literal: true

module Recommendations
  module Books
    # Everything the recommendation pages need that is books-specific and not
    # the engine's business: the user's shelves for the wizard steps, the
    # search box, and the names behind the ids the engine returns. The
    # controller is domain-generic and reaches this through
    # Registry.pages_class_for. Root-anchored constants throughout: inside
    # Recommendations::Books a bare `Books::Book` resolves to the wrong module.
    class Pages
      READ_LIMIT = 500
      RATED_LIMIT = 50
      SEARCH_SIZE = 12
      DEPTH_LABELS = {"safe" => "Safer bets", "balanced" => "Balanced", "deep" => "Deep cuts"}.freeze
      DROPPED_GROUP_LABELS = ["Ranking status"].freeze

      StepBooks = Struct.new(:books, :total, keyword_init: true)

      def initialize(user:)
        @user = user
      end

      def history?
        [list(:favorites), list(:read)].compact.any? do |l|
          ::UserListItem.where(user_list: l, listable_type: "Books::Book").exists?
        end
      end

      def favorites
        list_books(:favorites, order: {position: :asc, created_at: :desc}, limit: nil)
      end

      def read_books(limit: READ_LIMIT)
        list_books(:read, order: {created_at: :desc}, limit: limit)
      end

      def unrated_read
        rated_ids = rated_reviews.pluck(:reviewable_id).to_set
        read_books.books.reject { |book| rated_ids.include?(book.id) }
      end

      def rated(limit: RATED_LIMIT)
        reviews = rated_reviews.order(updated_at: :desc, id: :desc).limit(limit).to_a
        books = load_books(reviews.map(&:reviewable_id))
        reviews.filter_map { |review| (book = books[review.reviewable_id]) && [book, review] }
      end

      def list(list_type)
        ::Books::UserList.find_by(user: @user, list_type: list_type)
      end

      def search(query)
        ::Books::BookSearchQuery.call(query, size: SEARCH_SIZE)
      end

      def category_names(ids)
        return {} if ids.empty?

        ::Books::Category.where(id: ids).pluck(:id, :name).to_h
      end

      def item_names(ids)
        return {} if ids.empty?

        ::Books::Book.where(id: ids).pluck(:id, :title).to_h
      end

      # The side panel's settings summary. The saved-search labels already
      # name categories and format years; the recommendation criteria pin
      # `ranked` to true, so that group is noise here and is dropped.
      def criteria_groups(criteria)
        groups = ::Books::SavedSearchFilterLabels.call(criteria.to_search_criteria)
          .reject { |group| DROPPED_GROUP_LABELS.include?(group.label) }
        if criteria.depth != ::Books::RecommendationCriteria::DEFAULT_DEPTH
          groups << ::Books::SavedSearchFilterLabels::Group.new(label: "Depth", values: [DEPTH_LABELS.fetch(criteria.depth)])
        end
        groups
      end

      private

      def rated_reviews
        @user.reviews.where(reviewable_type: "Books::Book").where.not(rating: nil)
      end

      def list_books(list_type, order:, limit:)
        l = list(list_type)
        return StepBooks.new(books: [], total: 0) if l.nil?

        scope = ::UserListItem.where(user_list: l, listable_type: "Books::Book")
        total = scope.count
        ids = scope.order(order).then { |s| limit ? s.limit(limit) : s }.pluck(:listable_id)
        books = load_books(ids)
        StepBooks.new(books: ids.filter_map { |id| books[id] }, total: total)
      end

      def load_books(ids)
        return {} if ids.empty?

        ::Books::Book.where(id: ids)
          .includes(book_authors: :author)
          .includes(primary_image: {file_attachment: :blob})
          .index_by(&:id)
      end
    end
  end
end
