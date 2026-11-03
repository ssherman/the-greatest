# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      # The whole pipeline, step by step as the rake tasks run it, on one small world: a coherent book legacy got
      # right (its edition already cached by legacy), a mixed book holding two works, a reader of both (copy), a reader
      # of one (move), a hand-added entry (guess), and a legacy identifier on another book that a matched edition
      # contradicts. Only the finder, the AI and the redirect write are stubbed.
      class EndToEndTest < ActiveSupport::TestCase
        Fake = Struct.new(:response) do
          def call(**) = response
        end

        setup do
          GoodreadsRebuild::Cohort.stubs(:trusted?).returns(false)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call_for_ids)

          @writer = ::Books::Author.create!(name: "Ada Writer")
          @coherent = book("Coherent Book")
          @first = book("First Work")
          @second = book("Second Work")
          @mixed = book("First Work and Second Work")
          @other = book("Some Other Book")
          @readers = Array.new(3) { |i| User.create!(email: "e2e-#{i}-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false) }
          @both, @one, @stray = @readers

          @ed_coherent = edition(1, "Coherent Book", isbn13: nil).tap { |e| e.update!(book: @coherent, resolution: :matched, resolved_at: 1.day.ago) }
          @ed_first = edition(2, "First Work", isbn13: "9780000000101")
          @ed_second = edition(3, "Second Work", isbn13: "9780000000102")
          Identifier.create!(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000101", source: :legacy)

          @imports = @readers.first(2).to_h { |user| [user.id, import_for(user)] }
          [@both, @one].each do |user|
            UserListItem.create!(user_list: list(user, :read), listable: @coherent)
            @imports[user.id].rows.create!(row_number: 1, goodreads_edition: @ed_coherent, legacy_book_id: @coherent.id, exclusive_shelf: "read",
              raw: {"Title" => "Coherent Book"})
          end
          UserListItem.create!(user_list: list(@both, :read), listable: @mixed)
          Review.create!(user: @both, reviewable: @mixed, rating: 4, body: "legacy review")
          @imports[@both.id].rows.create!(row_number: 2, goodreads_edition: @ed_first, legacy_book_id: @mixed.id, exclusive_shelf: "read",
            rating: 5, review_body: "csv first", raw: {"Title" => "First Work"})
          @imports[@both.id].rows.create!(row_number: 3, goodreads_edition: @ed_second, legacy_book_id: @mixed.id, exclusive_shelf: "read",
            rating: 3, review_body: "csv second", raw: {"Title" => "Second Work"})
          UserListItem.create!(user_list: list(@one, :read), listable: @mixed)
          @imports[@one.id].rows.create!(row_number: 2, goodreads_edition: @ed_first, legacy_book_id: @mixed.id, exclusive_shelf: "read",
            raw: {"Title" => "First Work"})
          @stray_item = UserListItem.create!(user_list: list(@stray, :read), listable: @mixed)
          @before = item_counts
        end

        def book(title)
          ::Books::Book.create!(title: title, book_kind: :standalone).tap { |b| ::Books::BookAuthor.create!(book: b, author: @writer, position: 1) }
        end

        def edition(number, title, isbn13:)
          ::Books::GoodreadsEdition.create!(goodreads_book_id: 93_000 + number, signature: "e2e-#{number}", title: title,
            primary_author: "Ada Writer", isbn13: isbn13)
        end

        def import_for(user)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, status: :complete, finished_at: Time.current)
        end

        def list(user, type) = ::Books::UserList.find_by!(user: user, list_type: type)

        def item_counts = @readers.to_h { |user| [user.id, UserListItem.joins(:user_list).where(user_lists: {user_id: user.id}).count] }

        def books_of(user) = UserListItem.joins(:user_list).where(user_lists: {user_id: user.id}).pluck(:listable_id).sort

        def review_bodies(user) = Review.where(user: user).order(:id).map { |r| [r.reviewable_id, r.body] }

        def run_match(edition, book)
          found = DataImporters::Match.new(outcome: :matched, record: book, confidence: :high, decided_by: :rule, candidates: [], sources_failed: [])
          answer = Services::Ai::Result.new(success: true, data: {book_id: book.id, confidence: "high", reason: "same work"})
          task = stub(call: answer)
          klass = stub
          klass.stubs(:new).returns(task)
          MatchEdition.call(edition: edition, finder: Fake.new(found), task_class: klass)
        end

        # One chain of apply calls, as the rake task walks it: small pages, so the cursor does real work.
        def apply_all
          after = nil
          loop do
            after = Apply.call(limit: 2, after: after).data[:cursor]
            break unless after
          end
        end

        test "every row ends on its exact book and nothing is lost" do
          mixed_verdict = MixedBooks.archive(@mixed, legacy_map: GoodreadsRebuild::LegacyBookMap.new(@mixed.id => [@mixed.id]))
          [[@ed_coherent, @coherent], [@ed_first, @first], [@ed_second, @second]].each do |edition, target|
            assert_predicate run_match(edition, target).data[:verdict], :approved?
          end

          apply_all
          # The mixed book is still full and has no redirect target yet: it waits, whole.
          assert ::Books::Book.exists?(@mixed.id)
          assert_predicate mixed_verdict.reload, :approved?
          assert_nil mixed_verdict.applied_at
          assert ::Books::RepairVerdict.reimport_match.all?(&:applied_at)
          assert_not Identifier.exists?(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000101")

          @readers.first(2).each { |user| DecideRow.decide_user(user_id: user.id) }
          assert_equal :decided, DecideGuesses.call(mixed_verdict: mixed_verdict).data[:outcome]
          ::Services::BooksMigration::RedirectRecorder.expects(:merged).with(item_type: "Books::Book", from_id: @mixed.id, to_id: @first.id)
          apply_all

          [@coherent, @first, @second].each { |target| CheckAuthor.call(book: target, task_class: stub) }
          apply_all

          # Entries sit on their exact books, the mixed book is gone, and the stray went to its most-read book.
          assert_equal [@coherent.id, @first.id, @second.id].sort, books_of(@both)
          assert_equal [@coherent.id, @first.id].sort, books_of(@one)
          assert_equal [@first.id], books_of(@stray)
          assert_not ::Books::Book.exists?(@mixed.id)
          assert_equal @first.id, @stray_item.reload.listable_id
          guess = ::Books::RepairVerdict.reimport_guess.sole
          assert_equal [true, @first.id], [guess.payload["guess"], guess.payload["to_book_id"]]

          # The legacy review follows the row that carries it; the other row writes its own from the CSV.
          assert_equal [[@first.id, "legacy review"], [@second.id, "csv second"]], review_bodies(@both)
          assert_empty Review.where(reviewable: @mixed)

          # Nothing lost, and nothing left half-done.
          @before.each { |user_id, count| assert_operator item_counts.fetch(user_id), :>=, count, "user #{user_id} lost entries" }
          assert_equal [], ::Books::RepairVerdict.approved.current.unapplied.reimport_row.to_a
          assert_equal [], ::Books::RepairVerdict.approved.current.unapplied.where(kind: %i[reimport_match reimport_guess reimport_strip reimport_mixed]).to_a
          %i[reimport_match reimport_row reimport_guess reimport_strip reimport_mixed].each do |kind|
            assert ::Books::RepairVerdict.where(kind: kind).exists?, "no #{kind} verdict was recorded"
          end
        end
      end
    end
  end
end
