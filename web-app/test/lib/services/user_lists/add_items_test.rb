require "test_helper"

module Services
  module UserLists
    class AddItemsTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @read = user_lists(:regular_user_books_read)
        @favorites = user_lists(:regular_user_books_favorites)
        @reading = ::Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
          list.name = ::Books::UserList.default_list_name_for(:reading)
        end
        @war = books_books(:war_and_peace)
        @crime = books_books(:crime_and_punishment)
        @row = books_books(:cannery_row)
      end

      test "adds new books in order" do
        result = AddItems.call(user_list: @reading, listables: [@war, @crime, @row])

        assert result.success?
        assert_equal %w[added added added], result.data[:outcomes].map { |o| o[:outcome] }
        assert_equal [@war, @crime, @row], result.data[:outcomes].map { |o| o[:listable] }
        assert_equal [@war.id, @crime.id, @row.id], @reading.user_list_items.reload.map(&:listable_id)
        assert_equal [1, 2, 3], @reading.user_list_items.map(&:position)
      end

      test "re-adding a book is already_present and creates no row" do
        AddItems.call(user_list: @reading, listables: [@war])

        assert_no_difference -> { UserListItem.count } do
          result = AddItems.call(user_list: @reading, listables: [@war])
          assert_equal ["already_present"], result.data[:outcomes].map { |o| o[:outcome] }
        end
      end

      test "adding to read moves a reading book and enqueues one purge" do
        @reading.user_list_items.create!(listable: @crime)
        Services::Books::ReadingGoals::CompletionChangeInvalidator.stubs(:call).returns(["/x"])
        ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["/x"]).once

        result = AddItems.call(user_list: @read, listables: [@war, @crime], today: Date.new(2026, 8, 26))

        assert_equal %w[added moved], result.data[:outcomes].map { |o| o[:outcome] }
        assert_empty @reading.user_list_items.reload
        assert_equal Date.new(2026, 8, 26), @read.user_list_items.find_by(listable: @crime).completed_on
      end

      test "completed_on dates new and existing items and reports updated" do
        @read.user_list_items.create!(listable: @war)
        date = Date.new(2024, 3, 1)

        result = AddItems.call(user_list: @read, listables: [@war, @row], completed_on: date)

        assert_equal %w[updated added], result.data[:outcomes].map { |o| o[:outcome] }
        assert_equal [date, date], [@war, @row].map { |b| @read.user_list_items.find_by(listable: b).completed_on }
      end

      test "completed_on on a list without completion dates fails and writes nothing" do
        assert_no_difference -> { UserListItem.count } do
          result = AddItems.call(user_list: @favorites, listables: [@war], completed_on: Date.new(2024, 3, 1))

          refute result.success?
          assert_equal ["Completion dates are not enabled for this list"], result.errors
        end
      end

      test "a failure on the third listable rolls back the batch and enqueues nothing" do
        Services::Books::ReadingGoals::CompletionChangeInvalidator.stubs(:call).returns(["/x"])
        ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never
        ok = ->(book) { MutationResult.new(success?: true, data: {item: nil, listable: book, transitioned: false}, errors: []) }
        calls = 0
        AddItem.stubs(:call).with do |**kwargs|
          calls += 1
          UserListItem.create!(user_list: @reading, listable: kwargs[:listable]) if calls < 3
          true
        end.returns(ok.call(@war), ok.call(@crime), MutationResult.failure(["boom"]))

        result = AddItems.call(user_list: @reading, listables: [@war, @crime, @row])

        refute result.success?
        assert_equal ["boom"], result.errors
        assert_equal 0, @reading.user_list_items.reload.count
      end

      test "a failing batch inside an outer transaction rolls back only itself" do
        album = music_albums(:dark_side_of_the_moon)

        ActiveRecord::Base.transaction do
          marker = @reading.user_list_items.create!(listable: @row)
          result = AddItems.call(user_list: @reading, listables: [@war, @crime, album])

          refute result.success?
          assert_equal [marker.id], @reading.user_list_items.reload.map(&:id)
        end

        assert_equal [@row.id], @reading.user_list_items.reload.map(&:listable_id)
      end
    end
  end
end
