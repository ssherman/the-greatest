require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ApplyVerdictsTest < ActiveSupport::TestCase
        def verdict(kind, key, payload = {}, status: :approved)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: :rule, status: status, payload: payload)
        end

        def answer(outcome, **data)
          Struct.new(:success?, :data, :errors, keyword_init: true).new(success?: true, data: {outcome: outcome, **data}, errors: [])
        end

        test "refuses to change anything while auto_apply is off" do
          verdict(:strip_identifier, "book:1:x")
          Apply::StripIdentifier.expects(:call).never

          result = ApplyVerdicts.call(auto_apply: false)

          refute result.success?
          assert_match(/auto_apply is off/, result.errors.first)
        end

        test "applies approved verdicts kind by kind: author merges, book merges, relinks, strips, provisional" do
          order = sequence("spec order")
          provisional = verdict(:mark_provisional, "book:9")
          strip = verdict(:strip_identifier, "book:8:x")
          relink = verdict(:relink, "user:1:book:2:goodreads:3")
          books = verdict(:merge_books, "books:4:5")
          authors = verdict(:merge_authors, "authors:6:7")
          verdict(:merge_books, "books:10:11", status: :proposed)
          Apply::MergeAuthors.expects(:call).with(verdict: authors).in_sequence(order).returns(answer(:applied))
          Apply::MergeBooks.expects(:call).with(verdict: books).in_sequence(order).returns(answer(:applied))
          Apply::Relink.expects(:call).with(verdict: relink).in_sequence(order).returns(answer(:noop, reason: "already applied"))
          Apply::StripIdentifier.expects(:call).with(verdict: strip).in_sequence(order).returns(answer(:applied))
          Apply::MarkProvisional.expects(:call).with(verdict: provisional).in_sequence(order)
            .returns(answer(:applied, ranking_configuration_ids: [42]))
          ::CalculateRankingsJob.expects(:perform_async).with(42).once

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal({"merge_authors applied" => 1, "merge_books applied" => 1, "relink noop" => 1,
                        "strip_identifier applied" => 1, "mark_provisional applied" => 1}, result.data[:tally])
          refute_nil authors.reload.applied_at
          assert_nil relink.reload.applied_at
        end

        test "queues each follow-up once per run, however many merges asked for it" do
          first = verdict(:merge_books, "books:1:2")
          second = verdict(:merge_books, "books:3:4")
          authors = verdict(:merge_authors, "authors:5:6")
          more_authors = verdict(:merge_authors, "authors:7:8")
          flagged = verdict(:mark_provisional, "book:9")
          Apply::MergeBooks.stubs(:call).with(verdict: first).returns(answer(:applied, reweigh_configuration_ids: [1, 2], follow_ups: [:user_favorites]))
          Apply::MergeBooks.stubs(:call).with(verdict: second).returns(answer(:applied, reweigh_configuration_ids: [2], follow_ups: [:user_favorites]))
          Apply::MergeAuthors.stubs(:call).with(verdict: authors).returns(answer(:applied, follow_ups: [:author_rankings]))
          Apply::MergeAuthors.stubs(:call).with(verdict: more_authors).returns(answer(:applied, follow_ups: [:author_rankings]))
          Apply::MarkProvisional.stubs(:call).with(verdict: flagged).returns(answer(:applied, ranking_configuration_ids: [2, 3]))
          ::BulkCalculateWeightsJob.expects(:perform_async).with(1).once
          ::BulkCalculateWeightsJob.expects(:perform_async).with(2).once
          ::CalculateRankingsJob.expects(:perform_in).with(5.minutes, 1).once
          ::CalculateRankingsJob.expects(:perform_in).with(5.minutes, 2).once
          ::CalculateRankingsJob.expects(:perform_async).with(3).once
          ::GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList").once
          ::Books::CalculateAuthorRankingsJob.expects(:perform_async).once

          ApplyVerdicts.call(auto_apply: true)
        end

        test "a failing verdict records its error and the rest still apply; a later success clears it" do
          broken = verdict(:merge_books, "books:1:2")
          fine = verdict(:merge_books, "books:3:4")
          Apply::MergeBooks.stubs(:call).with(verdict: broken).raises(Apply::Failed, "locked")
          Apply::MergeBooks.stubs(:call).with(verdict: fine).returns(answer(:applied))

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal "Services::Books::GoodreadsReplay::Apply::Failed: locked", broken.reload.error
          assert_equal 1, result.data[:tally]["merge_books failed"]
          refute_nil fine.reload.applied_at

          Apply::MergeBooks.stubs(:call).with(verdict: broken).returns(answer(:applied))
          ApplyVerdicts.call(auto_apply: true)
          assert_nil broken.reload.error
        end

        test "a Postgres error stops the run" do
          verdict(:merge_books, "books:1:2")
          Apply::MergeBooks.stubs(:call).raises(ActiveRecord::StatementInvalid, "PG::ConnectionBad")

          assert_raises(ActiveRecord::StatementInvalid) { ApplyVerdicts.call(auto_apply: true) }
        end

        test "an author merge chain applies in id order, and a link whose author is gone is a harmless no-op" do
          ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
          a = ::Books::Author.create!(name: "Chain Author")
          b = ::Books::Author.create!(name: "Chain  Author")
          c = ::Books::Author.create!(name: "Chain Author.")
          verdict(:merge_authors, "authors:#{b.id}:#{c.id}", {"source_id" => b.id, "target_id" => c.id})
          verdict(:merge_authors, "authors:#{a.id}:#{b.id}", {"source_id" => a.id, "target_id" => b.id})

          result = ApplyVerdicts.call(auto_apply: true)

          assert_equal({"merge_authors applied" => 1, "merge_authors noop" => 1}, result.data[:tally])
          refute ::Books::Author.exists?(b.id)
          assert ::Books::Author.exists?(a.id), "A's target was merged away first; the next pass re-derives A with C"
        end

        test "a slug fix-up and a relink on the same book end with the bare id on the right book only" do
          wrong = books_books(:war_and_peace)
          right = books_books(:of_mice_and_men)
          user = users(:regular_user)
          ::Identifier.create!(identifiable: wrong, identifier_type: :books_work_goodreads_id, value: "777-some-slug")
          verdict(:strip_identifier, "book:#{wrong.id}:books_work_goodreads_id:777-some-slug",
            {"book_id" => wrong.id, "remove" => [["books_work_goodreads_id", "777-some-slug"]], "add" => [["books_work_goodreads_id", "777"]]})
          verdict(:relink, "user:#{user.id}:book:#{wrong.id}:goodreads:777",
            {"user_id" => user.id, "from_book_id" => wrong.id, "to_book_id" => right.id, "goodreads_book_id" => 777,
             "strip_identifiers" => [["books_work_goodreads_id", "777"], ["books_work_goodreads_id", "777-some-slug"]],
             "stamp_identifiers" => [["books_work_goodreads_id", "777"]]})
          goodreads = ->(book) { book.identifiers.where(identifier_type: :books_work_goodreads_id).where("value LIKE '777%'").pluck(:value) }

          ApplyVerdicts.call(auto_apply: true)

          assert_empty goodreads.call(wrong)
          assert_equal ["777"], goodreads.call(right)
        end

        test "applying the same verdicts twice leaves the same state" do
          book = books_books(:war_and_peace)
          ::Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
          verdict(:strip_identifier, "book:#{book.id}:books_work_goodreads_id:656-war-and-peace",
            {"book_id" => book.id, "remove" => [["books_work_goodreads_id", "656-war-and-peace"]], "add" => [["books_work_goodreads_id", "656"]]})

          ApplyVerdicts.call(auto_apply: true)
          first = book.identifiers.order(:id).pluck(:identifier_type, :value)
          second = ApplyVerdicts.call(auto_apply: true)

          assert_equal first, book.identifiers.order(:id).pluck(:identifier_type, :value)
          assert_equal({"strip_identifier noop" => 1}, second.data[:tally])
        end
      end
    end
  end
end
