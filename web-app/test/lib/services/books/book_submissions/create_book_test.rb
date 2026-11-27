# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module BookSubmissions
      class CreateBookTest < ActiveSupport::TestCase
        include GoodreadsImportHelper
        include BookSubmissionHelper

        setup do
          stub_resolution_services
          @submission = book_submission(status: :looking_up)
        end

        def create(resolved: resolved_facts, match: nil, submission: @submission, **options)
          CreateBook.call(submission: submission, resolved: resolved, match: match || finder_match(subject: submission), **options)
        end

        def other_submission
          list = ::Books::UserList.create!(user: users(:editor_user), name: "Books I've Read", list_type: :read)
          book_submission(user: users(:editor_user), list: list, status: :looking_up)
        end

        test "a reader or list that is gone means no book is created, even for a match" do
          before = ::Books::Book.count
          [nil, books_books(:war_and_peace)].each do |record|
            submission = book_submission(status: :looking_up)
            ::Books::BookSubmission.where(id: submission.id).update_all(user_list_id: nil)

            result = create(submission: submission, match: finder_match(subject: submission, record: record))

            assert_not result.success?
            assert_equal :no_owner, result.data[:outcome]
            assert_nil submission.reload.book_id
          end
          assert_equal before, ::Books::Book.count
        end

        def admin_row(**attributes)
          ::Books::BookSubmission.create!({user: users(:admin_user), user_list: nil, origin: :admin, list: lists(:books_list),
                                           list_position: 3, input_method: :title_authors, typed_title: "The Quiet Year",
                                           typed_author_names: ["Anna Brenner"], status: :looking_up}.merge(attributes))
        end

        test "an admin row creates a catalog book with full enrichment" do
          submission = admin_row
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: false)
          ::Books::BookAuthor.create!(book: book, author: ::Books::Author.create!(name: "Anna Brenner"), position: 1)
          importer = mock("importer")
          importer.expects(:call).with(has_entries(provisional: false, enrich: true, stamp_identifiers: true, query_identifier_source: :admin))
            .returns(stub(item: book, created?: true))

          result = create(submission: submission, importer: importer)

          assert result.success?
          submission.reload
          assert_equal ["not_needed", true, book], [submission.review_status, submission.created_book, submission.book]
        end

        test "an admin row with no list is not no_owner" do
          submission = admin_row
          ::Books::BookSubmission.where(id: submission.id).update_all(list_id: nil)

          result = create(submission: submission.reload, match: finder_match(subject: submission, record: books_books(:war_and_peace)))

          assert result.success?
          assert_equal :matched, result.data[:outcome]
        end

        test "an admin row whose user is gone is no_owner" do
          submission = admin_row
          ::Books::BookSubmission.where(id: submission.id).update_all(user_id: nil)

          result = create(submission: submission.reload)

          assert_not result.success?
          assert_equal :no_owner, result.data[:outcome]
        end

        test "a submission that already has its book resumes even when its list is gone" do
          first = create.data[:book]
          ::Books::BookSubmission.where(id: @submission.id).update_all(user_list_id: nil)

          result = create

          assert_equal [first, :resumed], [result.data[:book], result.data[:outcome]]
        end

        test "creates a provisional book and author and records what it made on the submission, leaving it looking up" do
          result = create(resolved: resolved_facts(year: 1977))

          @submission.reload
          book = result.data[:book]
          assert result.success?
          assert_equal [true, :created], [result.data[:created], result.data[:outcome]]
          assert_equal ["The Quiet Year", 1977, true], [book.title, book.first_published_year, book.provisional?]
          assert_equal [["Anna Brenner", true]], book.authors.map { |author| [author.name, author.provisional?] }
          assert_equal [book.id, true, "pending", "looking_up"], [@submission.book_id, @submission.created_book, @submission.review_status, @submission.status]
          assert_equal ["The Quiet Year", ["Anna Brenner"]], [@submission.resolved_title, @submission.resolved_author_names]
          assert_equal ::Books::Goodreads::ExportRow.signature("The Quiet Year", "Anna Brenner"), @submission.signature
          assert_equal book, @submission.match_decision.record
          assert_nil @submission.user_list_item
        end

        test "stamps the submission's own identifiers as user_submission, and nothing for typed title and authors" do
          create(resolved: resolved_facts(identifiers: {isbn13: ["9780441013593"], goodreads_id: ["90000001"]}))
          stamped = ::Books::Book.find_by(title: "The Quiet Year").identifiers.map { |row| [row.identifier_type, row.value, row.source] }.sort
          assert_equal [["books_work_goodreads_id", "90000001", "user_submission"], ["books_work_isbn13", "9780441013593", "user_submission"]], stamped

          other = book_submission(typed_title: "Another Year", status: :looking_up)
          result = create(resolved: resolved_facts(title: "Another Year"), submission: other)
          assert_empty result.data[:book].identifiers
        end

        test "plans no enrichment: lookups are StartLookups' to start" do
          result = create

          assert_equal 0, WorkflowRun.where(enrichable: result.data[:book]).count
        end

        test "a matched book is recorded without creating anything and needs no review" do
          book = books_books(:war_and_peace)
          before = ::Books::Book.count

          result = create(match: finder_match(subject: @submission, record: book))

          @submission.reload
          assert_equal [book, false, :matched], [result.data[:book], result.data[:created], result.data[:outcome]]
          assert_equal [book.id, false, "not_needed"], [@submission.book_id, @submission.created_book, @submission.review_status]
          assert_equal before, ::Books::Book.count
        end

        test "adopts the book a submission with the same signature created since the finder looked" do
          first = other_submission
          created = create(submission: first).data[:book]

          result = create

          @submission.reload
          assert_equal [created, false, :adopted], [result.data[:book], result.data[:created], result.data[:outcome]]
          assert_equal [created.id, false, "not_needed"], [@submission.book_id, @submission.created_book, @submission.review_status]
          assert_equal 1, ::Books::Book.where(title: "The Quiet Year").count
          assert_equal created, @submission.match_decision.reload.record
        end

        test "adopts a book a Goodreads import created with the same signature" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)

          result = create

          assert_equal [book, false], [result.data[:book], result.data[:created]]
        end

        test "a book the finder already considered and turned down is not adopted" do
          first = other_submission
          turned_down = create(submission: first).data[:book]
          considered = ::DataImporters::Candidate.new(record: turned_down, sources: [:exact])

          result = create(match: finder_match(subject: @submission, candidates: [considered]))

          assert_equal [true, :created], [result.data[:created], result.data[:outcome]]
          assert_not_equal turned_down, result.data[:book]
        end

        test "takes the advisory lock a Goodreads import takes, keyed by the same signature" do
          signature = ::Books::Goodreads::ExportRow.signature("The Quiet Year", "Anna Brenner")
          CreateBook.expects(:lock).with(signature)

          create
        end

        test "the lock is the Goodreads import's own SQL under its own key" do
          assert_equal ::Services::Books::GoodreadsImports::CreateBook::LOCK_SQL, CreateBook::LOCK_SQL
          ActiveRecord::Base.connection.expects(:exec_query).with(CreateBook::LOCK_SQL, anything, ["goodreads-edition:abc"])

          CreateBook.lock("abc")
        end

        test "a book a Goodreads import created, that the finder considered and turned down, is not adopted" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)
          considered = ::DataImporters::Candidate.new(record: book, sources: [:exact])

          result = create(match: finder_match(subject: @submission, candidates: [considered]))

          assert_equal [:created, true], [result.data[:outcome], result.data[:book] != book]
        end

        test "a same-signature submission that matched a book rather than creating one is not adopted" do
          other = other_submission
          create(submission: other, match: finder_match(subject: other, record: books_books(:war_and_peace)))

          result = create

          assert_equal [:created, true], [result.data[:outcome], result.data[:book] != books_books(:war_and_peace)]
        end

        test "a submission cancelled while the book was being found creates nothing" do
          ::Books::BookSubmission.where(id: @submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
          before = [::Books::Book.count, ::Books::Author.count]

          result = create

          assert_not result.success?
          assert_equal :aborted, result.data[:outcome]
          assert_equal before, [::Books::Book.count, ::Books::Author.count]
          assert_nil @submission.reload.book_id
        end

        test "a submission that already has a book keeps it and creates no second" do
          first = create.data[:book]

          result = create

          assert_equal [first, :resumed], [result.data[:book], result.data[:outcome]]
          assert_equal 1, ::Books::Book.where(title: "The Quiet Year").count
        end

        test "an importer that leaves the book with no author rolls everything back" do
          importer = Class.new do
            def self.call(title:, **)
              book = ::Books::Book.create!(title: title, provisional: true)
              Struct.new(:item, :created_author_ids) { def created? = true }.new(book, [])
            end
          end
          before = ::Books::Book.count

          result = create(importer: importer)

          assert_not result.success?
          assert_equal :no_author, result.data[:outcome]
          assert_equal before, ::Books::Book.count
          assert_nil @submission.reload.book_id
        end

        test "an unexpected importer error propagates and leaves no book" do
          importer = Class.new do
            def self.call(**) = raise("boom")
          end
          before = ::Books::Book.count

          assert_raises(RuntimeError) { create(importer: importer) }

          assert_equal before, ::Books::Book.count
          assert_nil @submission.reload.book_id
        end
      end
    end
  end
end
