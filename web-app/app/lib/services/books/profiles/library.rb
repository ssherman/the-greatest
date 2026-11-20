module Services
  module Books
    module Profiles
      # Everything a reader's profile page shows about their library, in SQL.
      # Every method is one or two queries regardless of shelf size; books are
      # preloaded with the same includes the list pages use.
      class Library
        FAVORITES_LIMIT = 8
        READING_NOW_LIMIT = 4
        RECENTLY_READ_LIMIT = 8
        TOP_RATED_LIMIT = 8
        RECENT_REVIEWS_LIMIT = 3

        Shelf = Struct.new(:books, :total, :list, keyword_init: true)
        Stats = Struct.new(:books_read, :read_last_12_months, :average_rating,
          :ratings_count, :reviews_count, keyword_init: true)
        RatedBook = Struct.new(:book, :rating, keyword_init: true)
        GoalProgress = Struct.new(:goal, :count, :bar_percentage, :days_left, keyword_init: true)

        def initialize(user:, catalog_only:, today: Date.current)
          @user = user
          @catalog_only = catalog_only
          @today = today
        end

        def stats
          read_items = shelf_items(list_for(:read))
          window = (today - 12.months + 1.day)..today
          ratings = reviews.where.not(rating: nil)
          average = ratings.average(:rating)

          Stats.new(
            books_read: nil_if_zero(read_items&.count),
            read_last_12_months: nil_if_zero(read_items&.where(completed_on: window)&.count),
            average_rating: average&.to_f&.round(1),
            ratings_count: nil_if_zero(ratings.count),
            reviews_count: nil_if_zero(reviews.with_body.count)
          )
        end

        def favorites
          shelf(:favorites, FAVORITES_LIMIT) { |items| items.reorder(:position, :id) }
        end

        def reading_now
          shelf(:reading, READING_NOW_LIMIT) { |items| items.reorder(:position, :id) }
        end

        def recently_read
          shelf(:read, RECENTLY_READ_LIMIT) do |items|
            items.reorder(
              Arel.sql("user_list_items.completed_on DESC NULLS LAST"),
              created_at: :desc, id: :desc
            )
          end
        end

        def top_rated
          rows = reviews.where.not(rating: nil).reorder(
            Arel.sql("reviews.rating DESC"), created_at: :desc, id: :desc
          ).limit(TOP_RATED_LIMIT).preload(reviewable: display_includes).to_a

          rows.map { |review| RatedBook.new(book: review.reviewable, rating: review.rating) }
        end

        def recent_reviews
          reviews.with_body.recent.limit(RECENT_REVIEWS_LIMIT)
            .preload(reviewable: display_includes).to_a
        end

        def goals
          ::Books::ReadingGoal.owned_by(user).active_on(today).map do |goal|
            progress = ReadingGoals::ProgressQuery.call(goal: goal, catalog_only: catalog_only)
            GoalProgress.new(
              goal: goal,
              count: progress.count,
              bar_percentage: progress.bar_percentage,
              days_left: (goal.ends_on - today).to_i
            )
          end
        end

        private

        attr_reader :user, :catalog_only, :today

        def nil_if_zero(count)
          count unless count.to_i.zero?
        end

        def shelf(list_type, limit)
          list = list_for(list_type)
          return Shelf.new(books: [], total: 0, list: nil) if list.nil?

          items = shelf_items(list)
          ordered = yield(items).limit(limit).preload(listable: display_includes).to_a
          Shelf.new(books: ordered.filter_map(&:listable), total: items.count, list: list)
        end

        # Items whose book still exists (and, when asked, is in the catalog).
        def shelf_items(list)
          return nil if list.nil?

          list.user_list_items.where(listable_type: "Books::Book", listable_id: visible_book_ids)
        end

        def reviews
          Review.where(user: user, reviewable_type: "Books::Book", reviewable_id: visible_book_ids)
        end

        def visible_book_ids
          (catalog_only ? ::Books::Book.catalog : ::Books::Book).select(:id)
        end

        def list_for(list_type)
          lists[list_type]
        end

        def lists
          @lists ||= ::Books::UserList.where(user: user, list_type: %i[favorites reading read])
            .index_by { |list| list.list_type.to_sym }
        end

        def display_includes
          ::Books::UserList.listable_display_includes
        end
      end
    end
  end
end
