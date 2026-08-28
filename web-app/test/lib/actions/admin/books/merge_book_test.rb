require "test_helper"

module Actions
  module Admin
    module Books
      class MergeBookTest < ActiveSupport::TestCase
        def setup
          @target = books_books(:war_and_peace)
          @source = books_books(:crime_and_punishment)
          @user = users(:admin_user)
          GenerateUserFavoritesListsJob.stubs(:perform_async)
        end

        def call_with(fields)
          Actions::Admin::Books::MergeBook.call(
            user: @user, models: [@target], fields: fields
          )
        end

        test "declares itself destructive so the controller's delete gate runs" do
          assert Actions::Admin::Books::MergeBook.destructive?
        end

        test "merges and reports success" do
          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert result.success?
          assert_not ::Books::Book.exists?(@source.id)
          assert_match(/Crime and Punishment/, result.message)
        end

        test "refuses when no source is selected" do
          result = call_with(confirm_merge: "1")

          assert_not result.success?
          assert_match(/select a book/i, result.message)
          assert ::Books::Book.exists?(@source.id)
        end

        test "refuses when the confirmation checkbox is not ticked" do
          result = call_with(source_book_id: @source.id.to_s)

          assert_not result.success?
          assert_match(/confirm/i, result.message)
          assert ::Books::Book.exists?(@source.id)
        end

        test "refuses a source id that does not exist" do
          result = call_with(source_book_id: "0", confirm_merge: "1")

          assert_not result.success?
          assert_match(/not found/i, result.message)
        end

        test "refuses a self-merge" do
          result = call_with(source_book_id: @target.id.to_s, confirm_merge: "1")

          assert_not result.success?
          assert_match(/itself/i, result.message)
          assert ::Books::Book.exists?(@target.id)
        end

        test "refuses when given more than one model" do
          result = Actions::Admin::Books::MergeBook.call(
            user: @user,
            models: [@target, @source],
            fields: {source_book_id: @source.id.to_s, confirm_merge: "1"}
          )

          assert_not result.success?
          assert_match(/single book/i, result.message)
        end

        test "names what the authors gate left behind" do
          # war_and_peace already has tolstoy, so the source's author stays put.
          ::Books::BookAuthor.create!(
            book: @source, author: books_authors(:king), position: 1
          )

          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert result.success?
          assert_match(/author/i, result.message)
        end

        test "warns rather than failing when a post-commit step fails" do
          GenerateUserFavoritesListsJob.stubs(:perform_async)
            .raises(StandardError.new("redis is down"))

          result = call_with(source_book_id: @source.id.to_s, confirm_merge: "1")

          assert_not ::Books::Book.exists?(@source.id), "the merge did commit"
          assert_match(/redis is down/, result.message)
        end
      end
    end
  end
end
