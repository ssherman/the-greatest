# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module BookSubmissions
      class ProcessSubmissionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper
        include BookSubmissionHelper

        Boom = Class.new(StandardError)

        # Runs a block between the book being settled (CreateBook's commit, or the
        # match) and the list step, so a merge or a delete lands in that gap.
        module AfterBookHook
          class << self
            attr_accessor :hook
          end

          private

          def finish(book)
            AfterBookHook.hook&.call(book)
            super
          end
        end
        ProcessSubmission.prepend(AfterBookHook)

        teardown { AfterBookHook.hook = nil }

        setup do
          stub_resolution_services
          freeze_time
          @user = users(:regular_user)
          @list = user_lists(:regular_user_books_read)
          @window = Rails.application.config.x.book_submissions.retry_window
        end

        def process(submission, **options)
          ProcessSubmission.call(submission: submission, **options)
        end

        def items_for(book) = UserListItem.where(listable: book)

        def books_called(title) = ::Books::Book.where(title: title)

        def provisional_book(title: "The Quiet Year", author: "Anna Brenner")
          ::Books::Book.create!(title: title, provisional: true).tap do |book|
            ::Books::BookAuthor.create!(book: book, author: ::Books::Author.create!(name: author), position: 1)
          end
        end

        def assert_settled(submission, items: 1, title: "The Quiet Year")
          submission.reload
          assert_equal 1, books_called(title).count
          assert_equal items, items_for(submission.book).where(user_list_id: submission.user_list_id).count
          assert_equal "added", submission.status
          assert_equal items_for(submission.book).find_by(user_list_id: submission.user_list_id), submission.user_list_item
        end

        # ---- admin rows ----------------------------------------------------

        def admin_submission(**attributes)
          ::Books::BookSubmission.create!({user: users(:admin_user), user_list: nil, origin: :admin, list: lists(:books_list),
                                           list_position: 7, input_method: :title_authors, typed_title: "War and Peace",
                                           typed_author_names: ["Leo Tolstoy"]}.merge(attributes))
        end

        test "an admin row lands its book on the books list at its position" do
          submission = admin_submission
          war_and_peace = books_books(:war_and_peace)
          stub_finder(finder_match(subject: submission, record: war_and_peace))

          result = process(submission)

          submission.reload
          assert_equal :done, result.data[:outcome]
          assert_equal "added", submission.status
          item = submission.list_item
          assert_equal [lists(:books_list), war_and_peace, 7, true], [item.list, item.listable, item.position, item.verified]
          assert_nil submission.user_list_item_id
        end

        test "an admin row whose book is already on the list records that row" do
          submission = admin_submission
          war_and_peace = books_books(:war_and_peace)
          existing = ListItem.create!(list: lists(:books_list), listable: war_and_peace, position: 40, verified: true)
          stub_finder(finder_match(subject: submission, record: war_and_peace))

          assert_no_difference "ListItem.count" do
            process(submission)
          end

          submission.reload
          assert_equal ["added", existing], [submission.status, submission.list_item]
        end

        test "an admin row matched to a provisional book promotes it before adding" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          book = provisional_book
          reader = book_submission(book: book, created_book: true, status: :added, review_status: :pending)
          submission = admin_submission(typed_title: "The Quiet Year", typed_author_names: ["Anna Brenner"])
          stub_finder(finder_match(subject: submission, record: book))

          process(submission)

          assert_not book.reload.provisional?
          assert_equal "approved", reader.reload.review_status
          assert_equal book, submission.reload.list_item.listable
          assert_equal "added", submission.status
        end

        test "an admin row with a deleted list ends added with no item" do
          submission = admin_submission
          stub_finder(finder_match(subject: submission, record: books_books(:war_and_peace)))
          ::Books::BookSubmission.where(id: submission.id).update_all(list_id: nil)

          assert_no_difference "ListItem.count" do
            process(submission.reload)
          end

          submission.reload
          assert_equal "added", submission.status
          assert_nil submission.list_item_id
        end

        test "an admin row whose list refuses the row raises" do
          submission = admin_submission(list_position: 7)
          war_and_peace = books_books(:war_and_peace)
          stub_finder(finder_match(subject: submission, record: war_and_peace))
          ::Services::Lists::AdminItems.stubs(:create).returns(
            ::Services::Lists::AdminItems::Result.new(success?: false, data: {}, errors: ["Position is invalid"])
          )

          assert_raises(ProcessSubmission::ListAddFailed) { process(submission) }
        end

        test "StartLookups never runs for an admin row" do
          submission = admin_submission
          stub_finder(finder_match(subject: submission))
          StartLookups.expects(:call).never

          process(submission)

          assert_equal "added", submission.reload.status
        end

        test "an admin row whose user is gone is cancelled" do
          submission = admin_submission
          ::Books::BookSubmission.where(id: submission.id).update_all(user_id: nil)

          process(submission.reload)

          assert_equal "cancelled", submission.reload.status
        end

        # ---- matches -------------------------------------------------------

        test "a catalog book the finder matches goes on the list and needs no review" do
          submission = book_submission(typed_title: "War and Peace", typed_author_names: ["Leo Tolstoy"])
          war_and_peace = books_books(:war_and_peace)
          before = ::Books::Book.count

          result = process(submission)

          submission.reload
          assert_equal :done, result.data[:outcome]
          assert_equal [war_and_peace, "added", false, "not_needed"],
            [submission.book, submission.status, submission.created_book, submission.review_status]
          assert_includes @list.reload.items, war_and_peace
          assert_equal items_for(war_and_peace).find_by(user_list_id: @list.id), submission.user_list_item
          assert_equal before, ::Books::Book.count
          assert_equal submission, submission.match_decision.subject
          assert_equal 0, WorkflowRun.where(enrichable: war_and_peace).count
        end

        test "a provisional book the finder matches is used, and no second book is made" do
          book = provisional_book
          submission = book_submission

          process(submission)

          assert_equal [book, false, "not_needed"], [submission.reload.book, submission.created_book, submission.review_status]
          assert_equal 1, books_called("The Quiet Year").count
          assert_includes @list.reload.items, book
        end

        test "a finder match is used whatever its confidence, and its own review flag stays to audit it" do
          submission = book_submission
          match = finder_match(subject: submission, record: books_books(:war_and_peace), confidence: :low, needs_review: true)
          stub_finder(match)

          process(submission)

          assert_equal books_books(:war_and_peace), submission.reload.book
          assert match.decision.reload.needs_review?
        end

        # ---- creating ------------------------------------------------------

        test "an unmatched submission creates a provisional book and author, pending review, on the list, with lookups planned" do
          submission = book_submission(input_method: :isbn, isbn13: "9780441013593", typed_title: nil, typed_author_names: nil,
            supplied: {"title" => "The Quiet Year", "author_names" => ["Anna Brenner"], "identifiers" => {"isbn13" => ["9780441013593"]}})

          process(submission)

          submission.reload
          book = submission.book
          assert_equal ["added", true, "pending"], [submission.status, submission.created_book, submission.review_status]
          assert_equal [true, "Anna Brenner"], [book.provisional?, book.authors.sole.name]
          assert_equal [["books_work_isbn13", "9780441013593", "user_submission"]],
            book.identifiers.map { |row| [row.identifier_type, row.value, row.source] }
          assert_includes @list.reload.items, book
          assert_equal [::Workflows::Books::BookEnrichment::LIMITED_BY], WorkflowRun.where(enrichable: book).map(&:initiated_by)
          assert_equal [submission], ::MatchDecision.where(record: book).map(&:subject)
        end

        test "title and authors stamps no identifier" do
          submission = book_submission

          process(submission)

          assert_empty submission.reload.book.identifiers
        end

        test "a Goodreads submission with its page cached creates the book with its own Goodreads id" do
          goodreads_page(goodreads_book_id: 5107, title: "The Quiet Year")
          submission = book_submission(input_method: :goodreads, raw_input: "https://www.goodreads.com/book/show/5107",
            goodreads_book_id: 5107, typed_title: nil, typed_author_names: nil)

          process(submission)

          assert_equal [["books_work_goodreads_id", "5107", "user_submission"]],
            submission.reload.book.identifiers.map { |row| [row.identifier_type, row.value, row.source] }
        end

        test "a Goodreads submission with no page waits for the fetch and creates nothing" do
          submission = book_submission(input_method: :goodreads, raw_input: "https://www.goodreads.com/book/show/5107",
            goodreads_book_id: 5107, typed_title: nil, typed_author_names: nil)

          result = process(submission)

          submission.reload
          assert_equal :waiting_for_goodreads, result.data[:outcome]
          assert_equal ["looking_up", nil, Time.current], [submission.status, submission.book_id, submission.processing_started_at]
        end

        test "an AI that found none of the candidates is flagged for review, as a Goodreads import flags it" do
          submission = book_submission
          match = finder_match(subject: submission, decided_by: :ai, needs_review: false)
          stub_finder(match)

          process(submission)

          assert match.decision.reload.needs_review?
          assert submission.reload.created_book
        end

        test "an earlier run's flagged decision leaves the review queue once this run settles, and this run's own stays" do
          submission = book_submission
          earlier = finder_match(subject: submission, needs_review: true).decision
          match = finder_match(subject: submission, needs_review: true, confidence: :medium)
          stub_finder(match)

          process(submission)

          assert_not earlier.reload.needs_review?
          assert match.decision.reload.needs_review?
        end

        # ---- the list ------------------------------------------------------

        test "a book already on the target list is success, and its item is stored" do
          existing = UserListItem.create!(user_list: @list, listable: books_books(:war_and_peace))
          submission = book_submission(typed_title: "War and Peace", typed_author_names: ["Leo Tolstoy"])

          process(submission)

          assert_equal [existing, "added"], [submission.reload.user_list_item, submission.status]
          assert_equal 1, items_for(books_books(:war_and_peace)).where(user_list_id: @list.id).count
        end

        test "the list add runs under the owner's lock and tracks the completion change for the reading goal" do
          submission = book_submission(typed_title: "War and Peace", typed_author_names: ["Leo Tolstoy"])
          ::Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).with(has_entry(user: @user)).returns([])

          process(submission)
        end

        test "the finder is told to ignore legacy identifiers" do
          submission = book_submission
          finder = stub(call: finder_match(subject: submission))
          ::DataImporters::Books::Book::Finder.expects(:new).with(identifier_sources: ::Identifier::NON_LEGACY_SOURCES).returns(finder)

          process(submission)
        end

        test "adding to Read a book that is on Reading moves it" do
          reading = ::Books::UserList.create!(user: @user, name: "Books I'm Reading", list_type: :reading)
          UserListItem.create!(user_list: reading, listable: books_books(:war_and_peace))
          submission = book_submission(typed_title: "War and Peace", typed_author_names: ["Leo Tolstoy"])

          process(submission)

          assert_equal [@list.id], items_for(books_books(:war_and_peace)).where(user_list_id: [@list.id, reading.id]).map(&:user_list_id)
          assert_equal "added", submission.reload.status
        end

        test "a submission with no user or no list is cancelled before anything is looked up" do
          orphan = book_submission(user: nil)
          listless = book_submission(list: nil)
          ::DataImporters::Books::Book::Finder.any_instance.expects(:call).never

          [orphan, listless].each { |submission| process(submission) }

          assert_equal %w[cancelled cancelled], [orphan, listless].map { |submission| submission.reload.status }
          assert_equal 0, books_called("The Quiet Year").count
        end

        # ---- failures and retries ------------------------------------------

        test "a fallback answer retries with backoff, and fails the submission once the window has passed" do
          submission = book_submission
          first = finder_match(subject: submission, decided_by: :fallback)
          last = finder_match(subject: submission, decided_by: :fallback)
          ::DataImporters::Books::Book::Finder.any_instance.stubs(:call).returns(first).then.returns(last)

          result = process(submission)

          submission.reload
          assert_equal :retry, result.data[:outcome]
          assert_equal [30.seconds.from_now, 1, "looking_up", nil], [result.data[:retry_at], submission.attempts, submission.status, submission.book_id]
          assert_equal submission.next_attempt_at, result.data[:retry_at]
          assert_not first.decision.reload.needs_review?, "a retried run's decision is superseded"
          assert_equal 0, books_called("The Quiet Year").count

          travel @window + 1.second
          result = process(submission)

          submission.reload
          assert_equal [:done, "failed", nil], [result.data[:outcome], submission.status, submission.book_id]
          assert_predicate submission.error, :present?
          assert_not last.decision.reload.needs_review?, "a row that ends with no book leaves nothing in the review queue"
        end

        test "the backoff doubles from 30 seconds and stops at 10 minutes" do
          submission = book_submission
          stub_finder(finder_match(subject: submission, decided_by: :fallback))

          delays = [0, 1, 2, 3, 4, 5, 6, 9].map do |attempts|
            submission.update!(attempts: attempts, processing_started_at: Time.current, status: :queued)
            process(submission).data[:retry_at] - Time.current
          end

          assert_equal [30, 60, 120, 240, 480, 600, 600, 600], delays
        end

        test "a failed local source retries too, even when the finder found nothing, then fails" do
          submission = book_submission
          stub_finder(finder_match(subject: submission, sources_failed: ["opensearch"]))

          assert_equal :retry, process(submission).data[:outcome]
          travel @window + 1.second
          process(submission)

          assert_equal ["failed", nil], [submission.reload.status, submission.book_id]
        end

        test "Open Library failing alone, with no match, retries within the window and then creates" do
          submission = book_submission
          stub_finder(finder_match(subject: submission, sources_failed: ["open_library"]))

          assert_equal :retry, process(submission).data[:outcome]
          assert_nil submission.reload.book_id

          travel @window + 1.second
          result = process(submission)

          assert_equal :done, result.data[:outcome]
          assert_equal ["added", true], [submission.reload.status, submission.created_book]
        end

        test "Open Library failing alone, with a match, uses the match at once" do
          submission = book_submission
          stub_finder(finder_match(subject: submission, record: books_books(:war_and_peace), sources_failed: ["open_library"],
            confidence: :medium, needs_review: true))

          assert_equal :done, process(submission).data[:outcome]
          assert_equal [books_books(:war_and_peace), "added"], [submission.reload.book, submission.status]
        end

        test "inputs that are unavailable retry, then become needs_details once the window has passed" do
          submission = book_submission
          ResolveInput.stubs(:call).returns(ResolveInput::Result.new(success?: false, data: {outcome: :unavailable}, errors: ["down"]))

          assert_equal :retry, process(submission).data[:outcome]
          travel @window + 1.second
          process(submission)

          assert_equal ["needs_details", nil], [submission.reload.status, submission.book_id]
        end

        test "an input with no record is needs_details" do
          submission = book_submission
          ResolveInput.stubs(:call).returns(ResolveInput::Result.new(success?: true, data: {outcome: :no_record}, errors: []))

          process(submission)

          assert_equal "needs_details", submission.reload.status
        end

        test "an importer that leaves no author makes no book and the submission needs_details" do
          submission = book_submission
          match = finder_match(subject: submission, needs_review: true)
          stub_finder(match)
          importer = Class.new do
            def self.call(title:, match:, **)
              book = ::Books::Book.create!(title: title, provisional: true)
              match.decision.update!(record: book)
              Struct.new(:item, :created_author_ids) { def created? = true }.new(book, [])
            end
          end

          process(submission, importer: importer)

          assert_equal ["needs_details", nil], [submission.reload.status, submission.book_id]
          assert_equal 0, books_called("The Quiet Year").count
          assert_not match.decision.reload.needs_review?, "the unused decision leaves the review queue"
          assert_nil match.decision.record_id, "and does not name the book that was rolled back"
          assert_nil match.decision.record_type
        end

        test "cancelled, failed, needs_details and added submissions are left alone" do
          %i[cancelled failed needs_details added].each do |status|
            submission = book_submission(status: status)
            ::DataImporters::Books::Book::Finder.any_instance.expects(:call).never

            result = process(submission)

            assert_equal [:done, status.to_s], [result.data[:outcome], submission.reload.status]
          end
        end

        test "a cancel that lands while the book is being found creates nothing and stays cancelled" do
          submission = book_submission
          match = finder_match(subject: submission, needs_review: true)
          ::DataImporters::Books::Book::Finder.any_instance.stubs(:call).with { |**|
            ::Books::BookSubmission.where(id: submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
            true
          }.returns(match)

          result = process(submission)

          assert_equal :done, result.data[:outcome]
          assert_equal ["cancelled", nil], [submission.reload.status, submission.book_id]
          assert_equal 0, books_called("The Quiet Year").count
          assert_not match.decision.reload.needs_review?
        end

        # ---- a match wins over a failed source ------------------------------

        test "a matched book is used at once even when a local source failed" do
          submission = book_submission
          stub_finder(finder_match(subject: submission, record: books_books(:war_and_peace), sources_failed: ["opensearch"],
            confidence: :medium, needs_review: true))

          assert_equal :done, process(submission).data[:outcome]
          assert_equal [books_books(:war_and_peace), "added"], [submission.reload.book, submission.status]
        end

        # ---- concurrency: a second run or a cancel commits inside a step ----

        # A finder whose nth call runs the nth step, which returns the match.
        def finder_that(*steps)
          calls = 0
          fake = Object.new
          fake.define_singleton_method(:call) do |**|
            step = steps.fetch(calls)
            calls += 1
            step.call
          end
          ::DataImporters::Books::Book::Finder.stubs(:new).returns(fake)
        end

        def cancel_row(submission)
          ::Books::BookSubmission.where(id: submission.id).update_all(status: ::Books::BookSubmission.statuses[:cancelled])
        end

        def no_record = ResolveInput::Result.new(success?: true, data: {outcome: :no_record}, errors: [])

        test "a second job that commits first leaves this run's flagged decision, whatever its id, out of the queue" do
          submission = book_submission
          twin = ::Books::BookSubmission.find(submission.id)
          twins = nil
          mine = nil
          finder_that(
            -> {
              process(twin)
              mine = finder_match(subject: submission, needs_review: true, confidence: :medium)
            },
            -> { twins = finder_match(subject: twin, needs_review: true, confidence: :medium) }
          )

          process(submission)

          assert_equal twins.decision, submission.reload.match_decision
          assert_equal [false, true], [mine.decision.reload.needs_review?, twins.decision.reload.needs_review?]
          assert_equal 1, books_called("The Quiet Year").count
          assert_equal "added", submission.status
        end

        test "a flag a second job's clear wiped while this run was creating the book is put back on the decision it holds" do
          submission = book_submission
          match = finder_match(subject: submission, needs_review: true, confidence: :medium)
          stub_finder(match)
          importer = Object.new
          importer.define_singleton_method(:call) do |title:, match:, **|
            ProcessSubmission.clear_flags(match.decision.subject_id)
            book = ::Books::Book.create!(title: title, provisional: true)
            ::Books::BookAuthor.create!(book: book, author: ::Books::Author.create!(name: "Anna Brenner"), position: 1)
            match.decision.update!(record: book)
            Struct.new(:item, :created_author_ids) { def created? = true }.new(book, [])
          end

          process(submission, importer: importer)

          assert match.decision.reload.needs_review?
          assert_equal match.decision, submission.reload.match_decision
        end

        test "an error raised after the finder leaves no flagged decision behind" do
          submission = book_submission
          match = finder_match(subject: submission, needs_review: true, confidence: :medium)
          stub_finder(match)
          importer = Class.new do
            def self.call(**) = raise("boom")
          end

          assert_raises(RuntimeError) { process(submission, importer: importer) }

          assert_not match.decision.reload.needs_review?
        end

        test "a Postgres error is raised without touching the decision" do
          submission = book_submission
          match = finder_match(subject: submission, needs_review: true, confidence: :medium)
          stub_finder(match)
          importer = Class.new do
            def self.call(**) = raise(ActiveRecord::StatementInvalid, "connection gone")
          end

          assert_raises(ActiveRecord::StatementInvalid) { process(submission, importer: importer) }

          assert match.decision.reload.needs_review?
        end

        test "flagged decisions a crashed run left behind are cleared when the row turns out to be cancelled" do
          submission = book_submission(status: :cancelled)
          left = finder_match(subject: submission, needs_review: true).decision

          process(submission)

          assert_not left.reload.needs_review?
        end

        test "a list deleted while the finder ran cancels the submission and creates no book" do
          list = ::Books::UserList.create!(user: @user, name: "Mine", list_type: :custom)
          submission = book_submission(list: list)
          match = finder_match(subject: submission, needs_review: true)
          finder_that(-> {
            list.destroy!
            match
          })

          process(submission)

          assert_equal ["cancelled", nil], [submission.reload.status, submission.book_id]
          assert_equal 0, books_called("The Quiet Year").count
          assert_not match.decision.reload.needs_review?
        end

        test "a matched book is not recorded when the list went before it was" do
          list = ::Books::UserList.create!(user: @user, name: "Mine", list_type: :custom)
          submission = book_submission(list: list)
          match = finder_match(subject: submission, record: books_books(:war_and_peace))
          finder_that(-> {
            list.destroy!
            match
          })

          process(submission)

          assert_equal ["cancelled", nil], [submission.reload.status, submission.book_id]
        end

        test "a cancel during the resolve step is not overwritten by needs_details" do
          submission = book_submission
          ResolveInput.stubs(:call).with { |**|
            cancel_row(submission)
            true
          }.returns(no_record)

          process(submission)

          assert_equal "cancelled", submission.reload.status
        end

        test "a cancel during the finder is not overwritten by a retry" do
          submission = book_submission
          finder_that(-> {
            cancel_row(submission)
            finder_match(subject: submission, decided_by: :fallback)
          })

          result = process(submission)

          submission.reload
          assert_equal [:done, "cancelled", 0, nil], [result.data[:outcome], submission.status, submission.attempts, submission.next_attempt_at]
        end

        test "a cancel during the finder is not overwritten by a failure" do
          submission = book_submission(processing_started_at: 2.hours.ago)
          finder_that(-> {
            cancel_row(submission)
            finder_match(subject: submission, decided_by: :fallback)
          })

          process(submission)

          assert_equal ["cancelled", nil], [submission.reload.status, submission.error]
        end

        test "a run that finds no record cannot turn a row another run finished into needs_details" do
          submission = book_submission
          book = books_books(:war_and_peace)
          ResolveInput.stubs(:call).with { |**|
            ::Books::BookSubmission.where(id: submission.id).update_all(book_id: book.id, status: ::Books::BookSubmission.statuses[:added])
            true
          }.returns(no_record)

          process(submission)

          assert_equal ["added", book.id], [submission.reload.status, submission.book_id]
        end

        test "a run that finds no record cannot turn an open row another run already gave a book into needs_details" do
          submission = book_submission
          book = books_books(:war_and_peace)
          ResolveInput.stubs(:call).with { |**|
            ::Books::BookSubmission.where(id: submission.id).update_all(book_id: book.id)
            true
          }.returns(no_record)

          process(submission)

          assert_equal ["looking_up", book.id], [submission.reload.status, submission.book_id]
        end

        test "a no-owner answer cannot cancel a row that got its book in the meantime" do
          submission = book_submission
          book = books_books(:war_and_peace)
          stub_finder(finder_match(subject: submission))
          CreateBook.stubs(:call).with { |**|
            ::Books::BookSubmission.where(id: submission.id).update_all(book_id: book.id)
            true
          }.returns(CreateBook::Result.new(success?: false, data: {outcome: :no_owner}, errors: []))

          process(submission)

          assert_equal ["looking_up", book.id], [submission.reload.status, submission.book_id]
        end

        # ---- resumable order -----------------------------------------------

        test "running a finished submission again changes nothing" do
          submission = book_submission
          process(submission)
          before = [::Books::Book.count, UserListItem.count, WorkflowRun.count, submission.reload.attributes]

          process(submission)

          assert_equal before, [::Books::Book.count, UserListItem.count, WorkflowRun.count, submission.reload.attributes]
        end

        test "a crash between creating the book and adding it to the list resumes to one book, one item, added" do
          submission = book_submission
          ::Services::UserLists::AddItem.stubs(:call).raises(Boom)

          assert_raises(Boom) { process(submission) }

          assert_equal ["looking_up", true], [submission.reload.status, submission.book_id.present?]
          assert_equal 0, items_for(submission.book).count
          ::Services::UserLists::AddItem.unstub(:call)
          process(submission)

          assert_settled(submission)
        end

        test "a crash between the list and the lookups resumes to one book, one item, added" do
          submission = book_submission
          StartLookups.stubs(:call).raises(Boom)

          assert_raises(Boom) { process(submission) }

          assert_equal ["looking_up", 1], [submission.reload.status, items_for(submission.book).count]
          StartLookups.unstub(:call)
          process(submission)

          assert_settled(submission)
          assert_equal 1, WorkflowRun.where(enrichable: submission.book).count
        end

        test "a crash between the lookups and the added status resumes to one book, one item, one run, added" do
          submission = book_submission
          real = StartLookups.method(:call)
          StartLookups.stubs(:call).with { |*args, **kwargs|
            real.call(*args, **kwargs)
            raise Boom
          }

          assert_raises(Boom) { process(submission) }

          assert_equal "looking_up", submission.reload.status
          StartLookups.unstub(:call)
          process(submission)

          assert_settled(submission)
          assert_equal 1, WorkflowRun.where(enrichable: submission.book).count
        end

        test "a list deleted after the book exists means no item, and the submission is still added" do
          list = ::Books::UserList.create!(user: @user, name: "Mine", list_type: :custom)
          submission = book_submission(list: list)
          ::Services::UserLists::AddItem.stubs(:call).raises(Boom)
          assert_raises(Boom) { process(submission) }
          ::Services::UserLists::AddItem.unstub(:call)
          list.destroy!

          process(submission)

          submission.reload
          assert_equal ["added", nil, true], [submission.status, submission.user_list_item, submission.book_id.present?]
          assert_equal 1, books_called("The Quiet Year").count
        end

        test "two submissions with the same signature share one book, each on its own list" do
          editor = users(:editor_user)
          editors_list = ::Books::UserList.create!(user: editor, name: "Books I've Read", list_type: :read)
          first = book_submission
          second = book_submission(user: editor, list: editors_list)
          ::DataImporters::Books::Book::Finder.any_instance.stubs(:call)
            .returns(finder_match(subject: first)).then.returns(finder_match(subject: second))

          process(first)
          process(second)

          first.reload
          second.reload
          assert_equal first.book, second.book
          assert_equal 1, books_called("The Quiet Year").count
          assert_equal [true, false, "pending", "not_needed"], [first.created_book, second.created_book, first.review_status, second.review_status]
          assert_equal [@list.id, editors_list.id].sort, items_for(first.book).map(&:user_list_id).sort
          assert_equal %w[added added], [first.status, second.status]
          assert_equal 1, WorkflowRun.where(enrichable: first.book).count
        end

        # ---- a merge or delete between the book and the list ---------------

        test "a book merged away after it was made puts the survivor on the list, and no item points at the old book" do
          GenerateUserFavoritesListsJob.stubs(:perform_async)
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          survivor = books_books(:war_and_peace)
          made = nil
          AfterBookHook.hook = ->(book) {
            made = book
            assert ::Books::Book::Merger.call(source: book, target: survivor).success?
          }
          submission = book_submission

          process(submission)

          submission.reload
          assert_equal [survivor, "added", "merged"], [submission.book, submission.status, submission.review_status]
          assert_equal 0, UserListItem.where(listable_type: "Books::Book", listable_id: made.id).count
          assert_equal 1, items_for(survivor).where(user_list_id: @list.id).count
          assert_equal items_for(survivor).find_by(user_list_id: @list.id), submission.user_list_item
          assert_equal 0, ::Books::Book.where(id: made.id).count
        end

        test "a book deleted after it was made leaves no item and the row stays rejected and cancelled" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          made = nil
          AfterBookHook.hook = ->(book) {
            made = book
            ::Books::Book.find(book.id).destroy!
          }
          submission = book_submission
          items_before = UserListItem.count

          result = process(submission)

          submission.reload
          assert_equal :done, result.data[:outcome]
          assert_equal ["cancelled", "rejected", nil], [submission.status, submission.review_status, submission.book_id]
          assert_equal items_before, UserListItem.count
          assert_equal 0, books_called("The Quiet Year").count
          assert_equal 0, WorkflowRun.where(enrichable_type: "Books::Book", enrichable_id: made.id).count
        end

        test "a matched provisional book deleted before the list step leaves a second reader's row rejected, with no item" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          book = provisional_book
          AfterBookHook.hook = ->(matched) { ::Books::Book.find(matched.id).destroy! }
          submission = book_submission
          stub_finder(finder_match(subject: submission, record: book))
          items_before = UserListItem.count

          process(submission)

          submission.reload
          assert_equal ["cancelled", "rejected", nil], [submission.status, submission.review_status, submission.book_id]
          assert_equal items_before, UserListItem.count
        end

        test "a delete that lands after the list step is not overwritten by added" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          StartLookups.stubs(:call).with { |book:|
            ::Books::Book.find(book.id).destroy!
            true
          }
          submission = book_submission

          process(submission)

          submission.reload
          assert_equal ["cancelled", "rejected", nil, nil], [submission.status, submission.review_status, submission.book_id, submission.user_list_item_id]
        end

        test "a resumed run whose book is now in the catalog plans no lookups on it" do
          catalog = books_books(:war_and_peace)
          submission = book_submission(book: catalog, created_book: true, review_status: :merged, status: :looking_up)
          StartLookups.expects(:call).never

          process(submission)

          assert_equal "added", submission.reload.status
          assert_includes @list.reload.items, catalog
        end

        test "a resumed run whose book is still provisional and was made by it plans the lookups" do
          book = provisional_book
          submission = book_submission(book: book, created_book: true, review_status: :pending, status: :looking_up)
          StartLookups.expects(:call).with(book: book).once

          process(submission)
        end
      end
    end
  end
end
