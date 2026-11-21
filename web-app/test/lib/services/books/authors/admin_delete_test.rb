# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class AdminDeleteTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Stranded Record")
        end

        test "deletes an author with no books and no credits" do
          result = AdminDelete.call(author: @author)

          assert result.success?
          assert_not ::Books::Author.exists?(@author.id)
        end

        test "a dry run checks and changes nothing" do
          result = AdminDelete.call(author: @author, dry_run: true)

          assert result.success?
          assert ::Books::Author.exists?(@author.id)
        end

        test "refuses an author a book credits, naming merge_author" do
          ::Books::BookAuthor.create!(book: books_books(:war_and_peace), author: @author)

          result = AdminDelete.call(author: @author)

          assert_equal [false, :unprocessable], [result.success?, result.code]
          assert_match(/credited on 1 book\b.*merge_author/, result.errors.first)
          assert ::Books::Author.exists?(@author.id)
        end

        test "refuses an author holding a translator or editor credit" do
          ::Books::Credit.create!(author: @author, creditable: books_books(:war_and_peace), role: :editor)

          result = AdminDelete.call(author: @author, dry_run: true)

          assert_not result.success?
          assert_match(/holds 1 credit\b/, result.errors.first)
        end
      end
    end
  end
end
