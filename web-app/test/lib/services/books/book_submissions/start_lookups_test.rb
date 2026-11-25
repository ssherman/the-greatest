# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module BookSubmissions
      class StartLookupsTest < ActiveSupport::TestCase
        setup do
          stub_workflow_dispatch
          @book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: books_authors(:tolstoy), position: 1)
          @config = Rails.application.config.x.book_submissions
        end

        def limited_run(book, created_at: Time.current, options: {"only" => ["goodreads"]})
          WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 2, enrichable: book,
            initiated_by: ::Workflows::Books::BookEnrichment::LIMITED_BY, options: options, status: :completed,
            created_at: created_at)
        end

        def other_books(count)
          Array.new(count) { |index| ::Books::Book.create!(title: "Other #{index}", provisional: true) }
        end

        test "plans a priority run that does only the Goodreads and Amazon steps, and no author run" do
          authors_before = WorkflowRun.where(workflow: "books.author_enrichment").count

          result = StartLookups.call(book: @book)

          run = WorkflowRun.find_by!(enrichable: @book)
          assert result.success?
          assert_equal [true, run], [result.data[:started], result.data[:run]]
          assert_equal %w[amazon goodreads], run.steps.reject(&:skipped?).map(&:key).sort
          assert_equal %w[goodreads_fetch_priority serial_priority], run.steps.where(key: %w[goodreads amazon]).map(&:queue).sort
          assert_equal ::Workflows::Books::BookEnrichment::LIMITED_BY, run.initiated_by
          assert_equal authors_before, WorkflowRun.where(workflow: "books.author_enrichment").count
        end

        test "plans nothing when lookups are switched off" do
          @config.stubs(:lookups_enabled).returns(false)

          result = StartLookups.call(book: @book)

          assert_equal [true, false, :disabled], [result.success?, result.data[:started], result.data[:reason]]
          assert_equal 0, WorkflowRun.where(enrichable: @book).count
        end

        test "plans nothing once the day's limited runs reach the ceiling" do
          @config.stubs(:lookup_runs_per_day).returns(2)
          other_books(2).each { |book| limited_run(book) }

          result = StartLookups.call(book: @book)

          assert_equal [false, :ceiling], [result.data[:started], result.data[:reason]]
          assert_equal 0, WorkflowRun.where(enrichable: @book).count
        end

        test "counts only limited runs from the last 24 hours that carry an only option" do
          @config.stubs(:lookup_runs_per_day).returns(1)
          old, full, other = other_books(3)
          limited_run(old, created_at: 25.hours.ago)
          limited_run(full, options: {})
          WorkflowRun.create!(workflow: "books.book_enrichment", definition_version: 2, enrichable: other, initiated_by: "goodreads_promote",
            options: {"only" => ["goodreads"]}, status: :completed)

          assert StartLookups.call(book: @book).data[:started]
        end

        test "a book whose submission run was already started is left alone" do
          first = StartLookups.call(book: @book).data[:run]
          first.update!(status: :completed)

          result = StartLookups.call(book: @book)

          assert_equal [false, :already_started], [result.data[:started], result.data[:reason]]
          assert_equal 1, WorkflowRun.where(enrichable: @book).count
        end
      end
    end
  end
end
