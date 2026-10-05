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

        test "nothing found and no page yet: the edition waits for Goodreads, unflagged, and a fetch is queued" do
          edition = goodreads_edition
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).with(edition.goodreads_book_id)

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :pending, result.data[:outcome]
          assert_equal [true, @import, nil], [edition.verification_pending?, edition.pending_import, edition.book]
          assert_equal false, edition.match_decision.needs_review
        end

        test "nothing found with its page cached creates a provisional, verified book at once" do
          edition = goodreads_edition
          goodreads_page(goodreads_book_id: edition.goodreads_book_id)
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_equal [true, true], [edition.book.provisional?, edition.verification_verified?]
        end

        test "nothing found with a not-found page cached parks the edition" do
          edition = goodreads_edition
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)

          assert_no_difference("::Books::Book.count") do
            assert_equal :parked, ResolveEdition.call(edition: edition, import: @import).data[:outcome]
          end
        end

        test "a waiting edition is not resolved again" do
          edition = goodreads_edition(verification: :pending)
          finder = mock("finder")
          finder.expects(:call).never

          assert_equal :pending, ResolveEdition.call(edition: edition, import: @import, finder: finder).data[:outcome]
        end

        test "a rolled-back resolution queues no fetch" do
          edition = goodreads_edition
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          ActiveRecord::Base.transaction(requires_new: true) do
            ResolveEdition.call(edition: edition, import: @import)
            raise ActiveRecord::Rollback
          end

          assert edition.reload.verification_not_needed?
        end

        test "an edition another import sent to Goodreads while this one ran the finder keeps that import's decision" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")
          other_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          other_decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition,
            outcome: :unmatched, confidence: :high, decided_by: :rule)
          real = ::DataImporters::Books::Book::Finder.new
          racing = Object.new
          racing.define_singleton_method(:call) do |**options|
            real.call(**options).tap do
              ::Books::GoodreadsEdition.where(id: edition.id).update_all(verification: 1, match_decision_id: other_decision.id,
                pending_import_id: other_import.id)
            end
          end
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          result = ResolveEdition.call(edition: edition, import: @import, finder: racing)

          edition.reload
          assert_equal :pending, result.data[:outcome]
          assert_equal [other_decision, other_import], [edition.match_decision, edition.pending_import]
          assert_equal 0, ::MatchDecision.needing_review.where(subject: edition).count
        end

        test "an AI 'none of these' creates a book and flags it; it never takes the top search hit" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "War and Peace in the Garden",
            authors: [["Leo Tolstoy", "Author"]])

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

        test "an AI failure creates nothing: the edition waits for the next run and its decision leaves the review queue" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          task = stub("select_candidate_task")
          task.stubs(:call).raises(RuntimeError, "OpenAI 429")
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(task)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")

          assert_no_difference("::Books::Book.count") do
            assert_raises(ResolveEdition::MatchingFailed) { ResolveEdition.call(edition: edition, import: @import) }
          end

          assert_nil edition.reload.resolved_at
          assert_equal 0, ::MatchDecision.needing_review.where(subject: edition).count
          assert_equal 1, @import.reload.ai_calls_count
        end

        test "a failed creation, retried, leaves only the decision that was used in the review queue" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "War and Peace in the Garden",
            authors: [["Leo Tolstoy", "Author"]])
          failing = Object.new
          def failing.call(**)
            ::DataImporters::ImportResult.new(item: ::Books::Book.new, provider_results: [], success: false)
          end
          assert_raises(CreateBook::CreateFailed) { ResolveEdition.call(edition: edition, import: @import, importer: failing) }

          ResolveEdition.call(edition: edition.reload, import: @import)

          assert_equal [edition.reload.match_decision], ::MatchDecision.needing_review.where(subject: edition).to_a
        end

        test "an edition another import resolved while this one waited leaves this import's decision out of the review queue" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")
          other = ::Books::Book.create!(title: "War and Peace in the Garden", provisional: true)
          real = ::DataImporters::Books::Book::Finder.new
          racing = Object.new
          racing.define_singleton_method(:call) do |**options|
            real.call(**options).tap do
              ::Books::GoodreadsEdition.where(id: edition.id).update_all(book_id: other.id, resolution: 1, resolved_at: Time.current)
            end
          end

          result = ResolveEdition.call(edition: edition, import: @import, finder: racing)

          assert_equal :cached, result.data[:outcome]
          assert_equal 0, ::MatchDecision.needing_review.where(subject: edition).count
        end

        test "a flagged decision orphaned by a crashed earlier run leaves the review queue once the edition resolves" do
          edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy", original_publication_year: 1869)
          orphan = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
            confidence: :low, decided_by: :ai, needs_review: true)

          ResolveEdition.call(edition: edition, import: @import)

          assert_not orphan.reload.needs_review
          assert_equal 0, ::MatchDecision.needing_review.where(subject: edition).count
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
          goodreads_page(goodreads_book_id: edition.goodreads_book_id)
          gone.destroy!

          result = ResolveEdition.call(edition: edition.reload, import: @import)

          assert_equal :created, result.data[:outcome]
          assert edition.reload.book.present?
        end

        test "a later import finds the provisional book an earlier one created instead of making another" do
          first = goodreads_edition(goodreads_book_id: 90_000_001)
          goodreads_page(goodreads_book_id: 90_000_001)
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
