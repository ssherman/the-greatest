# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class ApplyTest < ActiveSupport::TestCase
        include GoodreadsReimportApplyHelper

        setup do
          setup_reader
          @n = 0
          @tolstoy = books_authors(:tolstoy)
          @garnett = books_authors(:garnett)
          @from.book_authors.destroy_all
          ::Books::BookAuthor.create!(book: @from, author: @tolstoy, position: 1)
          GoodreadsRebuild::Cohort.stubs(:trusted?).returns(false)
          ::Services::RankingConfigurations::RequestRefresh.stubs(:call_for_ids)
        end

        def strip_verdict(book: @to, **attributes)
          @n += 1
          Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "978000000#{@n.to_s.rjust(4, "0")}", source: :legacy)
          ::Books::RepairVerdict.create!(kind: :reimport_strip, subject_key: "reimport:strip:#{book.id}:#{@n}", decided_by: :rule, status: :approved,
            **attributes, payload: {"book_id" => book.id, "identifier_type" => "books_work_isbn13", "value" => "978000000#{@n.to_s.rjust(4, "0")}"})
        end

        def author_verdict(**attributes)
          ::Books::RepairVerdict.create!(kind: :reimport_author, subject_key: "reimport:author:#{@from.id}", decided_by: :rule, status: :approved,
            **attributes, payload: {"book_id" => @from.id, "row_author_names" => ["Constance Garnett"], "after" => {"Constance Garnett" => @garnett.id}})
        end

        def mixed_verdict
          lump = ::Books::Book.create!(title: "Lump #{@n += 1}", book_kind: :standalone)
          UserListItem.create!(user_list: list(:read), listable: lump)
          [lump, ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{lump.id}", decided_by: :rule, status: :approved,
            payload: {"book_id" => lump.id, "archive" => {}})]
        end

        test "applies the first kind that has work and leaves later kinds for later calls" do
          strip = strip_verdict
          author = author_verdict
          Apply::Strip.stubs(:call).returns(Apply::Entries.noop("held back"))

          result = Apply.call

          assert_equal [1, 1, 0], result.data.values_at(:applied, :noop, :failed)
          assert_nil strip.reload.applied_at
          # every strip answered noop, so the call moves on rather than stall on them
          assert_not_nil author.reload.applied_at
        end

        test "stops at a kind the limit cut short, and the next call continues there" do
          first = strip_verdict
          second = strip_verdict
          author = author_verdict

          result = Apply.call(limit: 1)

          assert_equal [1, {"kind" => "reimport_strip", "id" => first.id}], result.data.values_at(:applied, :cursor)
          assert_not_nil first.reload.applied_at
          assert_nil second.reload.applied_at
          assert_nil author.reload.applied_at

          result = Apply.call(limit: 5, after: result.data[:cursor])

          assert_equal [2, nil], result.data.values_at(:applied, :cursor)
          assert_not_nil second.reload.applied_at
          assert_not_nil author.reload.applied_at
        end

        test "a mixed book that is not empty stays unapplied and does not hold the authors back" do
          lump, mixed = mixed_verdict
          author = author_verdict

          result = Apply.call

          assert_equal [1, 1, nil], result.data.values_at(:applied, :noop, :cursor)
          assert_nil mixed.reload.applied_at
          assert ::Books::Book.exists?(lump.id)
          assert_not_nil author.reload.applied_at
          assert_equal({"not empty: list items remain" => 1}, result.data[:noop_reasons])
        end

        test "an emptied mixed book is deleted and its verdict closed" do
          lump, mixed = mixed_verdict
          UserListItem.where(listable: lump).delete_all

          Apply.call

          assert_not ::Books::Book.exists?(lump.id)
          assert_not_nil mixed.reload.applied_at
        end

        test "skips unapproved, superseded and already applied verdicts" do
          proposed = strip_verdict(status: :proposed)
          superseded = strip_verdict(superseded_at: Time.current)
          done = strip_verdict(applied_at: 1.day.ago)

          result = Apply.call

          assert_equal [0, 0, nil], result.data.values_at(:applied, :noop, :cursor)
          assert_nil proposed.reload.applied_at
          assert_nil superseded.reload.applied_at
          assert_in_delta 1.day.ago, done.reload.applied_at, 5
        end

        test "a handler that raises records the error and the run carries on" do
          failing = strip_verdict
          author = author_verdict
          Apply::Strip.stubs(:call).raises(RuntimeError, "boom")

          result = Apply.call

          assert_equal [1, 1], result.data.values_at(:applied, :failed)
          assert_equal "RuntimeError: boom", failing.reload.error
          assert_nil failing.applied_at
          assert_not_nil author.reload.applied_at
        end

        test "another database error is recorded on its verdict and the walk continues" do
          failing = strip_verdict
          author = author_verdict
          Apply::Strip.stubs(:call).raises(ActiveRecord::RecordNotUnique, "dup")

          result = Apply.call

          assert_equal [1, 1], result.data.values_at(:applied, :failed)
          assert_match(/RecordNotUnique/, failing.reload.error)
          assert_not_nil author.reload.applied_at
        end

        test "a deadlock that outlasts its retries still raises, after queueing the follow-ups collected" do
          strip_verdict
          strip_verdict
          Apply::Strip.stubs(:call).returns(Apply::Entries.applied(follow_ups: [:user_favorites], reweigh_configuration_ids: [7])).then.raises(ActiveRecord::Deadlocked)
          Apply::Run.any_instance.stubs(:sleep)
          ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).once.with([7], delay: 5.minutes)
          ::GenerateUserFavoritesListsJob.expects(:perform_async).once

          assert_raises(ActiveRecord::Deadlocked) { Apply.call }
        end

        test "an unknown cursor kind restarts from the first kind" do
          strip = strip_verdict

          Apply.call(after: {"kind" => "bogus", "id" => 10**9})

          assert_not_nil strip.reload.applied_at
        end

        test "retries a deadlocked handler" do
          verdict = strip_verdict
          calls = 0
          Apply::Strip.stubs(:call).with { calls += 1 }.raises(ActiveRecord::Deadlocked).then.returns(Apply::Entries.applied)
          Apply::Run.any_instance.stubs(:sleep)

          result = Apply.call

          assert_equal 1, result.data[:applied]
          assert_equal 2, calls
          assert_not_nil verdict.reload.applied_at
        end

        test "more non-final noops than the limit do not starve a later verdict, and the chain ends" do
          lumps = Array.new(3) { mixed_verdict.last }
          author = author_verdict
          cursor = nil
          calls = 0
          loop do
            calls += 1
            cursor = Apply.call(limit: 2, after: cursor).data[:cursor]
            break if cursor.nil? || calls > 10
          end

          assert_operator calls, :<=, 3
          assert_nil cursor
          assert_not_nil author.reload.applied_at
          assert lumps.all? { |lump| lump.reload.applied_at.nil? }
        end

        test "a final noop closes the verdict with its reason" do
          verdict = strip_verdict
          Identifier.where(identifiable: @to).update_all(source: Identifier.sources[:open_library])

          Apply.call

          assert_not_nil verdict.reload.applied_at
          assert_equal "identifier is not a legacy one", verdict.payload["closed_reason"]
        end

        test "follow-ups from every verdict are queued once" do
          strip_verdict
          strip_verdict
          Apply::Strip.stubs(:call).returns(Apply::Entries.applied(follow_ups: [:user_favorites], reweigh_configuration_ids: [7]))
          ::Services::RankingConfigurations::RequestRefresh.expects(:call_for_ids).once.with([7], delay: 5.minutes)
          ::GenerateUserFavoritesListsJob.expects(:perform_async).once.with("Books::UserList")

          Apply.call
        end

        test "an approved match whose edition already caches the book is applied, so DecideRow can use it" do
          edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 98_001, signature: "cached-sig", title: "War and Peace",
            primary_author: "Leo Tolstoy", book: @from, resolution: :matched, resolved_at: 1.day.ago)
          match = ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:#{edition.id}", decided_by: :ai,
            status: :approved, payload: {"outcome" => "matched", "book_id" => @from.id, "goodreads_edition_id" => edition.id})
          row = @import.rows.create!(row_number: 1, raw: {"Title" => "War and Peace"}, goodreads_edition: edition, legacy_book_id: @from.id)

          Apply.call

          assert_not_nil match.reload.applied_at
          assert_equal :recorded, DecideRow.call(row: row).data[:outcome]
        end
      end
    end
  end
end
