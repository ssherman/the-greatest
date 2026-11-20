require "test_helper"

module Services
  module Books
    module Profiles
      class LibraryTest < ActiveSupport::TestCase
        setup do
          @user = users(:profile_reader)
          @today = Date.new(2026, 6, 15)
        end

        test "stats count read books, dated reads in the trailing 12 months, and ratings" do
          read = list(:read)
          add(read, books_books(:war_and_peace), completed_on: @today)
          add(read, books_books(:crime_and_punishment), completed_on: @today - 13.months)
          add(read, books_books(:got))
          review(books_books(:war_and_peace), rating: 4, body: "Great")
          review(books_books(:crime_and_punishment), rating: 5)

          assert_equal [3, 1, 4.5, 2, 1], library.stats.to_a
        end

        test "stats are nil, not zero, when there is nothing to count" do
          stats = Library.new(user: users(:profile_empty_reader), catalog_only: false).stats

          assert_equal [nil, nil, nil, nil, nil], stats.to_a
        end

        test "a dated read exactly 12 months ago today is outside the window; one day later is inside" do
          read = list(:read)
          add(read, books_books(:war_and_peace), completed_on: @today - 12.months)
          assert_nil library.stats.read_last_12_months

          add(read, books_books(:crime_and_punishment), completed_on: @today - 12.months + 1.day)
          assert_equal 1, library.stats.read_last_12_months
        end

        test "favorites follow list position and stop at 8" do
          favorites = list(:favorites)
          books = extra_books(9)
          books.each_with_index { |book, i| add(favorites, book, position: 9 - i) }

          shelf = library.favorites

          assert_equal books.last(8).reverse.map(&:id), shelf.books.map(&:id)
          assert_equal [9, favorites], [shelf.total, shelf.list]
        end

        test "reading_now stops at 4" do
          reading = list(:reading)
          extra_books(5).each { |book| add(reading, book) }

          shelf = library.reading_now

          assert_equal [4, 5], [shelf.books.size, shelf.total]
        end

        test "recently_read puts dated reads newest first, then undated by newest added" do
          read = list(:read)
          old = add(read, books_books(:war_and_peace), completed_on: @today - 30.days)
          recent = add(read, books_books(:crime_and_punishment), completed_on: @today - 1.day)
          undated_old = add(read, books_books(:got))
          undated_new = add(read, books_books(:clash))
          undated_old.update_column(:created_at, 2.days.ago)
          undated_new.update_column(:created_at, 1.day.ago)

          assert_equal [recent, old, undated_new, undated_old].map(&:listable_id),
            library.recently_read.books.map(&:id)
        end

        test "top_rated orders by rating then most recently rated and stops at 8" do
          books = extra_books(9)
          books.each_with_index do |book, i|
            review(book, rating: 3).update_columns(created_at: i.days.ago)
          end
          review(books_books(:war_and_peace), rating: 5).update_columns(created_at: 10.days.ago)

          rated = library.top_rated

          assert_equal 8, rated.size
          assert_equal [books_books(:war_and_peace).id, books[0].id, books[1].id],
            rated.first(3).map { |r| r.book.id }
          assert_equal [5, 3], rated.first(2).map { |r| r.rating.to_i }
        end

        test "recent_reviews returns only reviews with a body, newest first, at most 3" do
          books = extra_books(5)
          books.each_with_index do |book, i|
            review(book, rating: 4, body: "Body #{i}").update_columns(created_at: (10 - i).days.ago)
          end
          review(books_books(:war_and_peace), rating: 5)

          assert_equal ["Body 4", "Body 3", "Body 2"], library.recent_reviews.map(&:body)
        end

        test "goals returns only goals active today with count and days_left" do
          goal = ::Books::ReadingGoal.create!(
            user: @user, name: "Now", target_count: 4, starts_on: @today - 10.days, ends_on: @today + 5.days
          )
          ::Books::ReadingGoal.create!(
            user: @user, name: "Past", target_count: 4, starts_on: @today - 40.days, ends_on: @today - 20.days
          )
          add(list(:read), books_books(:war_and_peace), completed_on: @today - 1.day)

          progress = library.goals

          assert_equal [goal.id], progress.map { |p| p.goal.id }
          assert_equal [1, 5, 25.0], [progress.first.count, progress.first.days_left, progress.first.bar_percentage]
        end

        test "a user with no lists at all gets empty shelves and no error" do
          empty = Library.new(user: users(:profile_empty_reader), catalog_only: false)

          [empty.favorites, empty.reading_now, empty.recently_read].each do |shelf|
            assert_equal [[], 0, nil], [shelf.books, shelf.total, shelf.list]
          end
          assert_equal [[], [], []], [empty.top_rated, empty.recent_reviews, empty.goals]
        end

        test "a rating on a book that is on no list still counts in ratings and top_rated" do
          review(books_books(:war_and_peace), rating: 4)

          assert_equal 1, library.stats.ratings_count
          assert_equal [books_books(:war_and_peace).id], library.top_rated.map { |r| r.book.id }
        end

        test "catalog_only hides a provisional book from shelves, counts, ratings and reviews" do
          hidden = books_books(:war_and_peace)
          shown = books_books(:crime_and_punishment)
          [:read, :favorites, :reading].each do |type|
            add(list(type), hidden, completed_on: @today)
            add(list(type), shown, completed_on: @today)
          end
          review(hidden, rating: 5, body: "Hidden")
          review(shown, rating: 3, body: "Shown")
          hidden.update_column(:provisional, true)

          lib = library(catalog_only: true)

          assert_equal [1, 1, 3.0, 1, 1], lib.stats.to_a
          assert_equal [shown.id], lib.favorites.books.map(&:id)
          assert_equal 1, lib.favorites.total
          assert_equal [shown.id], lib.reading_now.books.map(&:id)
          assert_equal [shown.id], lib.recently_read.books.map(&:id)
          assert_equal [shown.id], lib.top_rated.map { |r| r.book.id }
          assert_equal ["Shown"], lib.recent_reviews.map(&:body)
        end

        test "catalog_only false keeps the provisional book" do
          hidden = books_books(:war_and_peace)
          add(list(:read), hidden, completed_on: @today)
          review(hidden, rating: 5, body: "Hidden")
          hidden.update_column(:provisional, true)

          lib = library(catalog_only: false)

          assert_equal [1, 1, 5.0, 1, 1], lib.stats.to_a
          assert_equal [hidden.id], lib.recently_read.books.map(&:id)
          assert_equal [hidden.id], lib.top_rated.map { |r| r.book.id }
          assert_equal 1, lib.recent_reviews.size
        end

        test "a list item whose book no longer exists is skipped" do
          favorites = list(:favorites)
          add(favorites, books_books(:war_and_peace))
          orphan_book = extra_books(1).first
          add(favorites, orphan_book)
          ::Books::Book.where(id: orphan_book.id).delete_all

          shelf = library.favorites

          assert_equal [books_books(:war_and_peace).id], shelf.books.map(&:id)
          assert_equal 1, shelf.total
        end

        test "query count does not grow with shelf size" do
          small = favorites_with(2)
          @user = users(:profile_empty_reader)
          large = favorites_with(8)

          small_count = count_queries { small.favorites.books.each { |b| touch_display_data(b) } }
          large_count = count_queries { large.favorites.books.each { |b| touch_display_data(b) } }

          assert_equal small_count, large_count
        end

        private

        def library(catalog_only: false)
          Library.new(user: @user, catalog_only: catalog_only, today: @today)
        end

        def list(type)
          ::Books::UserList.find_by(user: @user, list_type: type) ||
            ::Books::UserList.create!(
              user: @user, list_type: type, name: ::Books::UserList.default_list_name_for(type)
            )
        end

        def add(list, book, position: nil, completed_on: nil)
          list.user_list_items.create!(listable: book, position: position, completed_on: completed_on)
        end

        def review(book, rating:, body: nil)
          Review.create!(user: @user, reviewable: book, rating: rating, body: body)
        end

        def extra_books(count)
          Array.new(count) { ::Books::Book.create!(title: "Profile Extra #{SecureRandom.hex(4)}") }
        end

        def favorites_with(count)
          favorites = list(:favorites)
          extra_books(count).each { |book| add(favorites, book) }
          library
        end

        def touch_display_data(book)
          book.book_authors.map(&:author)
          book.categories.to_a
        end

        def count_queries
          count = 0
          counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
          count
        end
      end
    end
  end
end
