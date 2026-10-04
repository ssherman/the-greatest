# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ResolveEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
          @war_and_peace = books_books(:war_and_peace)
        end

        test "an exact title and author match links the existing book, unflagged" do
          edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", original_publication_year: 1869)

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          decision = edition.match_decision
          assert_equal [:matched, @war_and_peace], [result.data[:outcome], edition.book]
          assert_equal [true, true], [edition.matched?, edition.verification_not_needed?]
          assert_equal ["high", false, edition], [decision.confidence, decision.needs_review, decision.subject]
        end

        test "an ISBN the catalog holds links its book with certainty" do
          edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", isbn13: "9780140447934")

          ResolveEdition.call(edition: edition, import: @import)

          assert_equal [@war_and_peace, "certain"], [edition.reload.book, edition.match_decision.confidence]
        end

        test "nothing found creates a provisional book, unflagged" do
          edition = goodreads_edition

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert edition.book.provisional?
          assert_equal false, edition.match_decision.needs_review
        end

        test "an AI 'none of these' creates a book and flags it; it never takes the top search hit" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_not_equal @war_and_peace, edition.book
          assert edition.book.provisional?
          assert edition.match_decision.needs_review
        end

        test "a medium-confidence AI match links the book and flags it" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")

          assert_no_difference("::Books::Book.count") { ResolveEdition.call(edition: edition, import: @import) }

          assert_equal [@war_and_peace, true], [edition.reload.book, edition.match_decision.needs_review]
        end

        test "AI calls are counted on the import; rule decisions are not" do
          ResolveEdition.call(edition: goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy",
            original_publication_year: 1869), import: @import)
          assert_equal 0, @import.reload.ai_calls_count

          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          ResolveEdition.call(edition: goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy"),
            import: @import)

          assert_equal 1, @import.reload.ai_calls_count
        end

        test "an edition already resolved is reused without asking the finder" do
          edition = goodreads_edition(book: @war_and_peace, resolution: :matched, resolved_at: Time.current)
          finder = mock("finder")
          finder.expects(:call).never

          result = ResolveEdition.call(edition: edition, import: @import, finder: finder)

          assert_equal :cached, result.data[:outcome]
        end

        test "an edition whose book was deleted is resolved again" do
          gone = ::Books::Book.create!(title: "The Quiet Year")
          edition = goodreads_edition(book: gone, resolution: :matched, resolved_at: 1.day.ago)
          gone.destroy!

          result = ResolveEdition.call(edition: edition.reload, import: @import)

          assert_equal :created, result.data[:outcome]
          assert edition.reload.book.present?
        end

        test "a later import finds the provisional book an earlier one created instead of making another" do
          first = goodreads_edition(goodreads_book_id: 90_000_001)
          ResolveEdition.call(edition: first, import: @import)
          later_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          second = goodreads_edition(goodreads_book_id: 90_000_002)

          assert_no_difference("::Books::Book.count") { ResolveEdition.call(edition: second, import: later_import) }

          assert_equal first.reload.book, second.reload.book
          assert_equal "matched", second.match_decision.outcome
        end
      end
    end
  end
end
