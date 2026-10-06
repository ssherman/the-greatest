# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class SettleEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :verifying)
        end

        # An edition the finder left unmatched, waiting for its page, with
        # one row in the given import.
        def waiting_edition(import: @import, needs_review: false, candidates: [], **attributes)
          edition = goodreads_edition(**attributes)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
            confidence: :high, decided_by: :rule, needs_review: needs_review, candidates: candidates)
          edition.update!(verification: :pending, match_decision: decision, pending_import: import)
          add_row(import, edition)
          edition
        end

        def add_row(import, edition)
          import.rows.create!(row_number: import.rows.count + 1, goodreads_edition: edition)
        end

        test "a page that backs the edition creates a provisional book from the page's facts, verified" do
          edition = waiting_edition(goodreads_book_id: 90_000_001)
          page = goodreads_page(goodreads_book_id: 90_000_001, title: "The Quiet Year: A Novel",
            authors: [["Anna Brenner", "Author"], ["Kit Ober", "Translator"], ["Jo Ray", "Author"]])

          result = SettleEdition.call(edition: edition, page: page)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_equal ["The Quiet Year: A Novel", true], [edition.book.title, edition.book.provisional?]
          assert_equal ["Anna Brenner", "Jo Ray"], edition.book.authors.map(&:name).sort
          assert_equal [true, nil], [edition.verification_verified?, edition.pending_import_id]
          assert_includes @import.records.map(&:record), edition.book
        end

        test "a page that says the id does not exist parks the edition and its waiting rows; nothing is created" do
          edition = waiting_edition(needs_review: true)
          page = goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)

          assert_no_difference("::Books::Book.count") do
            assert_equal :parked, SettleEdition.call(edition: edition, page: page).data[:outcome]
          end

          edition.reload
          row = edition.import_rows.sole
          assert_equal [true, true, nil], [edition.parked?, edition.verification_not_found?, edition.pending_import_id]
          assert edition.resolved_at.present?
          assert_equal ["parked", "not found on Goodreads"], [row.outcome, row.outcome_detail]
          assert_not edition.match_decision.needs_review
        end

        test "a page about another book parks it as a mismatch" do
          edition = waiting_edition
          page = goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "Something Else Entirely")

          SettleEdition.call(edition: edition, page: page)

          assert_equal [true, "does not match its Goodreads page"],
            [edition.reload.verification_mismatch?, edition.import_rows.sole.outcome_detail]
        end

        test "with no page the book is created unverified, for the sweep" do
          edition = waiting_edition

          assert_equal :created, SettleEdition.call(edition: edition, page: nil).data[:outcome]

          assert_equal [true, true], [edition.reload.created?, edition.verification_unverified?]
        end

        test "the finder never runs again, and a book it turned down is still not adopted" do
          turned_down = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: turned_down, resolution: :created, resolved_at: Time.current)
          edition = waiting_edition(candidates: [{"record_type" => "Books::Book", "record_id" => turned_down.id}])
          ::DataImporters::Books::Book::Finder.any_instance.expects(:call).never

          assert_equal :created, SettleEdition.call(edition: edition, page: nil).data[:outcome]

          edition.reload
          assert_not_equal turned_down, edition.book
          assert_equal edition.book, edition.match_decision.record
        end

        test "the import that waited owns what is created, not a later one" do
          edition = waiting_edition
          later = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          add_row(later, edition)

          SettleEdition.call(edition: edition, page: nil)

          assert_includes @import.records.map(&:record), edition.reload.book
          assert_empty later.records
        end

        test "with the waiting import gone, the latest import with rows on the edition owns it" do
          edition = waiting_edition
          later = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          add_row(later, edition)
          edition.update!(pending_import: nil)

          SettleEdition.call(edition: edition, page: nil)

          assert_includes later.records.map(&:record), edition.reload.book
        end

        test "a rejected import never owns what a settle creates; with no live import the edition is released" do
          edition = waiting_edition(goodreads_book_id: 90_000_005)
          @import.update!(status: :failed, review_status: :rejected)

          assert_no_difference -> { ::Books::Book.count } do
            assert_equal :released, SettleEdition.call(edition: edition, page: nil).data[:outcome]
          end
        end

        test "with no import left the edition is released, and nothing is created" do
          edition = goodreads_edition(verification: :pending)

          assert_no_difference("::Books::Book.count") do
            assert_equal :released, SettleEdition.call(edition: edition, page: nil).data[:outcome]
          end
          assert edition.reload.verification_not_needed?
        end

        test "a released edition's flagged decision leaves the review queue" do
          edition = goodreads_edition
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
            confidence: :high, decided_by: :ai, needs_review: true)
          edition.update!(verification: :pending, match_decision: decision)

          assert_equal :released, SettleEdition.call(edition: edition, page: nil).data[:outcome]

          assert_not decision.reload.needs_review
        end

        test "settling twice makes one book, and parking twice parks once" do
          created = waiting_edition(goodreads_book_id: 90_000_001)
          parked = waiting_edition(goodreads_book_id: 90_000_002)
          missing = goodreads_page(goodreads_book_id: 90_000_002, outcome: :not_found)

          assert_difference("::Books::Book.count", 1) do
            2.times { SettleEdition.call(edition: ::Books::GoodreadsEdition.find(created.id), page: nil) }
          end
          outcomes = 2.times.map { SettleEdition.call(edition: ::Books::GoodreadsEdition.find(parked.id), page: missing).data[:outcome] }

          assert_equal [:parked, :cached], outcomes
        end

        test "an edition created unverified is checked later, and its book is left alone" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          edition = goodreads_edition(book: book, resolution: :created, verification: :unverified, resolved_at: 1.day.ago)

          assert_equal :unchanged, SettleEdition.call(edition: edition, page: nil).data[:outcome]
          assert_equal :rechecked,
            SettleEdition.call(edition: edition, page: goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)).data[:outcome]

          edition.reload
          assert_equal [true, book, true], [edition.verification_not_found?, edition.book, book.reload.provisional?]
        end
      end
    end
  end
end
