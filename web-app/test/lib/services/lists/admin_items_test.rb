require "test_helper"

module Services
  module Lists
    class AdminItemsTest < ActiveSupport::TestCase
      include BookSubmissionReviewHelper

      setup do
        stub_review_side_effects
        @admin = users(:admin_user)
        @list = ::Books::List.create!(name: "Admin Items List", status: :approved)
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
      end

      teardown { Current.reset }

      def conflict_failure
        ::Services::Books::BookSubmissions::Lease::Result.new(success?: false, data: {conflict: true}, errors: ["the book no longer exists"])
      end

      test "create adds a verified row at the given position and moves no other row" do
        one = ListItem.create!(list: @list, listable: @other, position: 1)
        two = ListItem.create!(list: @list, metadata: {"title" => "Loose"}, position: 2)

        result = AdminItems.create(list: @list, book: @book, position: 2, user: @admin)

        assert result.success?
        item = result.data[:item]
        assert_equal [2, true, false], [item.position, item.verified, result.data[:promoted]]
        assert_equal [1, 2], [one.reload.position, two.reload.position]
      end

      test "create with no position leaves it null" do
        result = AdminItems.create(list: @list, book: @book, position: nil, user: @admin)

        assert result.success?
        assert_nil result.data[:item].position
      end

      test "a book already on the list is refused" do
        ListItem.create!(list: @list, listable: @book)

        result = AdminItems.create(list: @list, book: @book, position: nil, user: @admin)

        assert_not result.success?
        assert_includes result.errors, "Listable is already in this list"
        assert_nil result.data[:conflict]
      end

      test "a provisional book is promoted before the row is written" do
        book = ::Books::Book.create!(title: "Provisional One", provisional: true)

        result = AdminItems.create(list: @list, book: book, position: 1, user: @admin)

        assert result.success?
        assert_equal true, result.data[:promoted]
        assert_not book.reload.provisional?
      end

      test "a failed promotion writes no row" do
        ::Services::Books::PromoteProvisionalBook.stubs(:call).returns(conflict_failure)

        assert_no_difference "ListItem.count" do
          result = AdminItems.create(list: @list, book: @book, position: 1, user: @admin)

          assert_not result.success?
          assert_equal true, result.data[:conflict]
        end
      end

      test "update relinks to another book and marks it verified" do
        item = ListItem.create!(list: @list, listable: @other, position: 4, verified: false)

        result = AdminItems.update(item: item, user: @admin, book: @book)

        assert result.success?
        item.reload
        assert_equal [@book, 4, true], [item.listable, item.position, item.verified]
      end

      test "update with position nil clears it" do
        item = ListItem.create!(list: @list, listable: @book, position: 4)

        result = AdminItems.update(item: item, user: @admin, position: nil)

        assert result.success?
        assert_nil item.reload.position
        assert_equal @book, item.listable
      end

      test "update relinking to a provisional book promotes it" do
        item = ListItem.create!(list: @list, listable: @other, position: 1)
        book = ::Books::Book.create!(title: "Provisional Three", provisional: true)

        result = AdminItems.update(item: item, user: @admin, book: book)

        assert result.success?
        assert_equal true, result.data[:promoted]
        assert_not book.reload.provisional?
      end

      test "an auto-generated list refuses create, update and destroy" do
        list = ::Books::List.create!(name: "Generated", status: :approved, auto_generated_kind: :year_top, auto_generated_year: 1999)
        item = ListItem.new(list: list, listable: @other)
        item.save!(validate: false)

        created = AdminItems.create(list: list, book: @book, position: 1, user: @admin)
        updated = AdminItems.update(item: item, user: @admin, position: 2)
        destroyed = AdminItems.destroy(item: item)

        [created, updated, destroyed].each do |result|
          assert_not result.success?
          assert_match(/managed by the generator/, result.errors.join)
        end
        assert ListItem.exists?(item.id)
      end

      test "destroy removes the row and keeps the book" do
        item = ListItem.create!(list: @list, listable: @book, position: 1)

        result = AdminItems.destroy(item: item)

        assert result.success?
        assert_equal item, result.data[:item]
        assert_not ListItem.exists?(item.id)
        assert ::Books::Book.exists?(@book.id)
      end
    end
  end
end
