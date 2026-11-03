# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class QueueEnrichmentTest < ActiveSupport::TestCase
        setup do
          stub_workflow_dispatch
          ::Books::Goodreads::FetchGate.any_instance.stubs(:blocked?).returns(false)
          @author = ::Books::Author.create!(name: "Someone Else")
          @count = 0
        end

        def fixed_book(applied: true, applied_at: 1.hour.ago, payload: {})
          book = ::Books::Book.create!(title: "Fixed #{@count += 1}")
          book.book_authors.create!(author: @author, position: 1)
          ::Books::RepairVerdict.create!(kind: :fix_identity, subject_key: "rebuild:#{book.id}", status: :approved, confidence: :high,
            decided_by: :rule, applied_at: applied ? applied_at : nil,
            payload: {"book_id" => book.id, "author_names" => ["Real Author"]}.merge(payload))
          book
        end

        def list(book, times)
          lists = [user_lists(:regular_user_books_read), user_lists(:regular_user_books_favorites)]
          lists.first(times).each { |l| UserListItem.create!(user_list: l, listable: book) }
        end

        def old_run(book, created_at)
          WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 2, enrichable: book, status: :completed,
            initiated_by: "test", options: {}, created_at: created_at)
        end

        def runs = WorkflowRun.where(workflow: "books.book_enrichment", initiated_by: "goodreads_rebuild")

        test "a title-only fix keeps its data and is not queued; a full one and one without a recorded scope are" do
          title_only = fixed_book(payload: {"fix_scope" => "title_only"})
          full = fixed_book(payload: {"fix_scope" => "full"})
          older = fixed_book

          result = QueueEnrichment.call(in_flight: 10)

          assert_equal({started: 2, in_flight: 2, waiting: 0}, result.data)
          assert_equal [full.id, older.id].sort, runs.pluck(:enrichable_id).sort
          refute_includes runs.pluck(:enrichable_id), title_only.id
        end

        test "tops up to in_flight, most-listed applied fix first" do
          none = fixed_book
          one = fixed_book
          two = fixed_book
          list(one, 1)
          list(two, 2)

          result = QueueEnrichment.call(in_flight: 2)

          assert result.success?
          assert_equal({started: 2, in_flight: 2, waiting: 1}, result.data)
          assert_equal [one.id, two.id].sort, runs.pluck(:enrichable_id).sort
          refute_includes runs.pluck(:enrichable_id), none.id
          assert_equal ["Real Author"], runs.find_by(enrichable_id: two.id).options["author_names"]
        end

        test "starts nothing when already at in_flight" do
          fixed_book
          fixed_book
          QueueEnrichment.call(in_flight: 1)

          result = QueueEnrichment.call(in_flight: 1)

          assert_equal({started: 0, in_flight: 1, waiting: 1}, result.data)
          assert_equal 1, runs.count
        end

        test "a run whose Goodreads step has finished no longer counts as in flight" do
          fixed_book
          fixed_book
          QueueEnrichment.call(in_flight: 1)
          runs.first.step(:goodreads).update!(state: :succeeded, released_at: Time.current)

          result = QueueEnrichment.call(in_flight: 1)

          assert_equal 1, result.data[:started]
          assert_equal 2, runs.count
        end

        test "skips a book already enriched since its fix, and an unapplied fix" do
          old_run(fixed_book, 10.minutes.ago)
          earlier = fixed_book
          old_run(earlier, 2.hours.ago)
          fixed_book(applied: false)

          result = QueueEnrichment.call(in_flight: 10)

          assert_equal [earlier.id], runs.pluck(:enrichable_id)
          assert_equal({started: 1, in_flight: 1, waiting: 0}, result.data)
        end

        test "skips a book whose older enrichment run is still running" do
          book = fixed_book
          WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 2, enrichable: book, status: :running,
            initiated_by: "test", options: {}, created_at: 2.hours.ago)
          ::Workflows::Books::BookEnrichment.expects(:start).never

          result = QueueEnrichment.call(in_flight: 5)

          assert_equal({started: 0, in_flight: 0, waiting: 0}, result.data)
        end

        test "passes the fix's created author ids" do
          book = fixed_book(payload: {"created_author_ids" => [@author.id]})
          other = fixed_book
          ::Workflows::Books::BookEnrichment.expects(:start)
            .with(book, initiated_by: "goodreads_rebuild", new_author_ids: [@author.id], author_names: ["Real Author"])
            .returns(WorkflowRun.new)
          ::Workflows::Books::BookEnrichment.expects(:start)
            .with(other, initiated_by: "goodreads_rebuild", new_author_ids: [], author_names: ["Real Author"])
            .returns(WorkflowRun.new)

          QueueEnrichment.call(in_flight: 5)
        end

        def reimport_book(kind, payload)
          book = ::Books::Book.create!(title: "Reimported #{@count += 1}")
          ::Books::RepairVerdict.create!(kind: kind, subject_key: "reimport:#{kind}:#{book.id}", status: :approved, confidence: :high,
            decided_by: :rule, applied_at: 1.hour.ago, payload: payload.call(book))
          book
        end

        def created_book
          reimport_book(:reimport_match, ->(b) { {"created_book_id" => b.id, "facts" => {"author_names" => ["Facts Author"]}} })
        end

        def checked_book
          reimport_book(:reimport_author, ->(b) { {"book_id" => b.id, "row_author_names" => ["Row Author"], "created_author_ids" => [@author.id]} })
        end

        def with_enrichment(value)
          config = Rails.configuration.x.goodreads_reimport
          was = config.enrichment
          config.enrichment = value
          yield
        ensure
          config.enrichment = was
        end

        test "re-import created books wait while enrichment is off" do
          created_book
          checked_book

          result = QueueEnrichment.call(in_flight: 10)

          assert_equal({started: 0, in_flight: 0, waiting: 0}, result.data)
          assert_equal 0, runs.count
        end

        test "they start once it is on, after the rebuild's books" do
          created = created_book
          checked = checked_book
          fixed = fixed_book
          started = []
          ::Workflows::Books::BookEnrichment.stubs(:start).with { |book, **kw| started << [book, kw] }.returns(WorkflowRun.new)

          with_enrichment(true) { QueueEnrichment.call(in_flight: 10) }

          assert_equal [fixed, created, checked], started.map(&:first)
          assert_equal ["Facts Author"], started[1].last[:author_names]
          assert_equal [@author.id], started[2].last[:new_author_ids]
          assert_equal ["Row Author"], started[2].last[:author_names]
        end

        test "a re-import author check that created no authors, and unapplied, proposed or superseded re-import verdicts, are not started" do
          reimport_book(:reimport_author, ->(b) { {"book_id" => b.id, "created_author_ids" => []} })
          unapplied = created_book
          ::Books::RepairVerdict.reimport_match.find_by("payload->>'created_book_id' = ?", unapplied.id.to_s).update_columns(applied_at: nil)
          proposed = created_book
          ::Books::RepairVerdict.reimport_match.find_by("payload->>'created_book_id' = ?", proposed.id.to_s)
            .update_columns(status: ::Books::RepairVerdict.statuses.fetch("proposed"))
          old = checked_book
          ::Books::RepairVerdict.reimport_author.find_by("payload->>'book_id' = ?", old.id.to_s).update_columns(superseded_at: Time.current)
          ::Workflows::Books::BookEnrichment.expects(:start).never

          result = with_enrichment(true) { QueueEnrichment.call(in_flight: 10) }

          assert_equal({started: 0, in_flight: 0, waiting: 0}, result.data)
        end

        test "a book named by a fix and a re-import verdict starts once with the created authors unioned" do
          book = fixed_book(payload: {"created_author_ids" => [@author.id]})
          other = ::Books::Author.create!(name: "Another")
          ::Books::RepairVerdict.create!(kind: :reimport_author, subject_key: "reimport:author:#{book.id}", status: :approved, confidence: :high,
            decided_by: :rule, applied_at: 1.hour.ago, payload: {"book_id" => book.id, "created_author_ids" => [other.id]})
          ::Workflows::Books::BookEnrichment.expects(:start)
            .with(book, initiated_by: "goodreads_rebuild", new_author_ids: [@author.id, other.id], author_names: ["Real Author"])
            .once.returns(WorkflowRun.new)

          with_enrichment(true) { QueueEnrichment.call(in_flight: 10) }
        end

        test "re-import books count against the same cap as the rebuild's" do
          fixed_book
          created_book

          result = with_enrichment(true) { QueueEnrichment.call(in_flight: 1) }

          assert_equal({started: 1, in_flight: 1, waiting: 1}, result.data)
        end

        test "starts nothing while the fetch gate is blocked" do
          fixed_book
          ::Books::Goodreads::FetchGate.any_instance.stubs(:blocked?).returns(true)

          result = QueueEnrichment.call(in_flight: 5)

          assert result.success?
          assert_equal({started: 0, in_flight: 0, waiting: 1}, result.data)
          assert_equal 0, runs.count
        end
      end
    end
  end
end
