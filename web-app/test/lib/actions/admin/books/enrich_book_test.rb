require "test_helper"

module Actions
  module Admin
    module Books
      class EnrichBookTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @book = books_books(:war_and_peace)
        end

        test "is a non-destructive show-page action" do
          refute EnrichBook.destructive?
          assert EnrichBook.visible?(view: :show)
          refute EnrichBook.visible?(view: :index)
          assert_equal "Enrich With AI", EnrichBook.name
        end

        test "queues a knowledge run by default" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

          result = EnrichBook.call(user: @admin_user, models: [@book])

          assert result.success?
          assert_equal "Enrichment queued for War and Peace.", result.message
        end

        test "a checked force_research box queues a web search run" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, true)

          result = EnrichBook.call(user: @admin_user, models: [@book], fields: {"force_research" => "1"})

          assert result.success?
          assert_equal "Enrichment with web search queued for War and Peace.", result.message
        end

        test "an unchecked box is a knowledge run" do
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id, false)

          EnrichBook.call(user: @admin_user, models: [@book], fields: {force_research: "0"})
        end

        test "refuses more than one book" do
          ::Books::EnrichBookJob.expects(:perform_async).never

          result = EnrichBook.call(user: @admin_user, models: [@book, books_books(:crime_and_punishment)])

          assert result.error?
        end
      end
    end
  end
end
