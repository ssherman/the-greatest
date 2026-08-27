require "test_helper"

module Services
  module Books
    module ReadingGoals
      class ProgressQueryTest < ActiveSupport::TestCase
        test "projects only the owner's dated Read items inside inclusive boundaries" do
          goal = reading_goal
          starts_item = add_read_item(goal.user, books_books(:war_and_peace), goal.starts_on)
          ends_item = add_read_item(goal.user, books_books(:cannery_row), goal.ends_on)
          add_read_item(goal.user, books_books(:of_mice_and_men), nil)
          add_read_item(users(:editor_user), books_books(:crime_and_punishment), goal.starts_on)
          add_read_item(goal.user, books_books(:crime_and_punishment), goal.starts_on - 1.day)
          add_read_item(goal.user, books_books(:got), goal.ends_on + 1.day)

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_equal [ends_item.id, starts_item.id], result.items.map(&:id)
          assert_equal 2, result.count
        end

        test "excludes books on Favorites and Reading lists and non-books on another domain's list" do
          goal = reading_goal
          included = add_read_item(goal.user, books_books(:war_and_peace), goal.starts_on)
          user_lists(:regular_user_books_favorites).user_list_items.create!(
            listable: books_books(:cannery_row), completed_on: goal.starts_on
          )
          reading_list = ::Books::UserList.create!(
            user: goal.user,
            name: ::Books::UserList.default_list_name_for(:reading),
            list_type: :reading
          )
          reading_list.user_list_items.create!(
            listable: books_books(:of_mice_and_men), completed_on: goal.starts_on
          )
          listened_list = user_lists(:regular_user_music_albums_listened)
          listened_list.user_list_items.create!(listable: music_albums(:nevermind), completed_on: goal.starts_on)

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_equal [included.id], result.items.map(&:id)
          assert_equal 1, result.count
        end

        test "includes a shared Read item in overlapping goals" do
          goal = reading_goal(starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31))
          overlapping_goal = reading_goal(
            name: "Overlapping goal", starts_on: Date.new(2027, 6, 1), ends_on: Date.new(2027, 12, 31)
          )
          item = add_read_item(goal.user, books_books(:war_and_peace), Date.new(2027, 6, 1))

          assert_equal [item.id], ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal).items.map(&:id)
          assert_equal [item.id], ::Services::Books::ReadingGoals::ProgressQuery.call(goal: overlapping_goal).items.map(&:id)
        end

        test "reports truthful over-target progress and caps only the bar" do
          goal = reading_goal(target_count: 1)
          add_read_item(goal.user, books_books(:crime_and_punishment), goal.starts_on)
          add_read_item(goal.user, books_books(:cannery_row), goal.ends_on)

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_equal 200.0, result.percentage
          assert result.complete
          assert_equal 100.0, result.bar_percentage
        end

        test "orders equal dates by item id descending and pages by 24" do
          goal = reading_goal
          items = 25.times.map do |index|
            book = ::Books::Book.create!(title: "Goal book #{index}", slug: "goal-book-#{index}")
            add_read_item(goal.user, book, goal.starts_on)
          end

          page_one = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: 1)
          page_two = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: 2)

          assert_equal items.map(&:id).sort.last(24).reverse, page_one.items.map(&:id)
          assert_equal [items.map(&:id).min], page_two.items.map(&:id)
          assert_equal 25, page_two.count
        end

        test "normalizes invalid page values and accepts numeric strings" do
          goal = reading_goal
          items = 25.times.map do |index|
            book = ::Books::Book.create!(title: "Page book #{index}", slug: "page-book-#{index}")
            add_read_item(goal.user, book, goal.starts_on)
          end

          first_page_ids = items.map(&:id).sort.last(24).reverse
          [nil, 0, -1, "invalid"].each do |page|
            result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: page)

            assert_equal first_page_ids, result.items.map(&:id), "page=#{page.inspect} should use page one"
          end

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: "2")

          assert_equal [items.map(&:id).min], result.items.map(&:id)
        end

        test "returns an empty projection when the owner has no Read list" do
          user = User.create!(email: "reading-goal-empty@example.com", role: :user, email_verified: true)
          ::Books::UserList.find_by!(user: user, list_type: :read).destroy!
          goal = ::Books::ReadingGoal.create!(
            user: user, name: "Empty", target_count: 12,
            starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31)
          )

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_empty result.items
          assert_equal 0, result.count
          assert_equal 0.0, result.percentage
          assert_not result.complete
          assert_equal 0.0, result.bar_percentage
        end

        test "preloads card associations for a full page" do
          goal = reading_goal
          author = books_authors(:tolstoy)
          24.times do |index|
            book = ::Books::Book.create!(title: "Preloaded book #{index}", slug: "preloaded-book-#{index}")
            ::Books::BookAuthor.create!(book: book, author: author, position: 1)
            image = Image.new(parent: book, primary: true)
            image.file.attach(io: StringIO.new("fake image data"), filename: "cover-#{index}.jpg", content_type: "image/jpeg")
            image.save!
            add_read_item(goal.user, book, goal.starts_on)
          end

          result = ::Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

          assert_queries_count(0) do
            result.items.each do |item|
              item.listable.book_authors.map { |book_author| book_author.author.name }
              item.listable.primary_image.file_attachment.blob.filename
              ::Books::CardComponent.new(book: item.listable).send(:cover)
            end
          end
        end

        private

        def reading_goal(**attributes)
          ::Books::ReadingGoal.create!({
            user: users(:regular_user), name: "Reading goal", target_count: 12,
            starts_on: Date.new(2027, 1, 1), ends_on: Date.new(2027, 12, 31)
          }.merge(attributes))
        end

        def add_read_item(user, book, completed_on)
          list = ::Books::UserList.find_or_create_by!(user: user, list_type: :read) do |new_list|
            new_list.name = ::Books::UserList.default_list_name_for(:read)
          end
          list.user_list_items.create!(listable: book, completed_on: completed_on)
        end
      end
    end
  end
end
