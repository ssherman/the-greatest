# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class EnrichmentTest < ActiveSupport::TestCase
          def setup
            stub_workflow_dispatch
            @provider = Enrichment.new
            @book = books_books(:war_and_peace)
            # Deliberately NOT the fixture's author name: this pins that
            # book.authors wins over the query when the book already has
            # authors (see the first test below).
            @query = ImportQuery.new(title: "War and Peace", author_names: ["Someone Else"])
          end

          def book_run(book)
            WorkflowRun.find_by!(enrichable: book, workflow: "books.book_enrichment")
          end

          test "plans one book run with the book's own authors and reports success" do
            result = @provider.populate(@book, query: @query)

            assert result.success?
            assert_equal [:enrichment_planned], result.data_populated
            run = book_run(@book)
            assert_equal ["importer", ["Leo Tolstoy"]], [run.initiated_by, run.options["author_names"]]
          end

          test "falls back to the query's author names when the book has none" do
            book = ::Books::Book.create!(title: "Brand New")
            query = ImportQuery.new(title: "Brand New", author_names: ["Someone New"])

            assert @provider.populate(book, query: query).success?
            assert_equal ["Someone New"], book_run(book).options["author_names"]
          end

          test "fails without a title" do
            @book.title = ""

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book title required for AI enrichment"
            assert_equal 0, WorkflowRun.where(enrichable: @book).count
          end

          test "fails when neither the book nor the query has authors" do
            book = ::Books::Book.create!(title: "Nobody's Book")

            result = @provider.populate(book, query: ImportQuery.new(title: "Nobody's Book"))

            refute result.success?
            assert_includes result.errors, "Book must have an author for AI enrichment"
            assert_equal 0, WorkflowRun.where(enrichable: book).count
          end

          test "fails when the query's author names are blank" do
            book = ::Books::Book.create!(title: "Blank Author Book")

            result = @provider.populate(book, query: ImportQuery.new(title: "Blank Author Book", author_names: [""]))

            refute result.success?
            assert_includes result.errors, "Book must have an author for AI enrichment"
          end

          test "fails when the book is not persisted" do
            book = ::Books::Book.new(title: "Unsaved")

            result = @provider.populate(book, query: @query)

            refute result.success?
            assert_includes result.errors, "Book must be persisted before queuing AI enrichment"
          end

          test "works with a nil query for item-based imports" do
            assert @provider.populate(@book, query: nil).success?
            assert_equal ["Leo Tolstoy"], book_run(@book).options["author_names"]
          end

          test "turns a planning error into a failure result" do
            ::Workflows::Books::BookEnrichment.stubs(:start).raises(ArgumentError, "bad plan")

            result = @provider.populate(@book, query: @query)

            refute result.success?
            assert_match(/Enrichment provider error: bad plan/, result.errors.first)
          end

          test "a created author linked to the book gets a run that book_facts waits on" do
            author = ::Books::Author.create!(name: "Fresh Author")
            ::Books::BookAuthor.create!(book: @book, author: author, position: 2, role: :author)

            assert Enrichment.new(new_author_ids: [author.id]).populate(@book, query: @query).success?

            author_run = WorkflowRun.find_by!(enrichable: author, workflow: "books.author_enrichment")
            assert_equal [author_run.step(:author_facts)], book_run(@book).step(:book_facts).dependencies.map(&:prerequisite_step)
          end

          test "a created author not linked to the book is enriched but not waited on" do
            author = books_authors(:king)

            Enrichment.new(new_author_ids: [author.id]).populate(@book, query: @query)

            assert WorkflowRun.exists?(enrichable: author, workflow: "books.author_enrichment")
            assert_equal 0, book_run(@book).step(:book_facts).dependencies.count
          end

          test "the plan joins the caller's transaction: a rollback leaves no run and dispatches nothing" do
            Workflows::Dispatcher.expects(:dispatch).never

            ::ActiveRecord::Base.transaction(requires_new: true) do
              @provider.populate(@book, query: @query)
              assert_equal 1, WorkflowRun.where(enrichable: @book).count, "the provider planned nothing, so the rollback proves nothing"
              raise ::ActiveRecord::Rollback
            end

            assert_equal 0, WorkflowRun.where(enrichable: @book).count
          end

          test "a failure after the author runs were written rolls the whole plan back" do
            author = ::Books::Author.create!(name: "Fresh Author")
            ::Books::BookAuthor.create!(book: @book, author: author, position: 2, role: :author)
            Workflows::Dispatcher.stubs(:after_commit).raises("boom")

            result = ::ActiveRecord::Base.transaction do
              Enrichment.new(new_author_ids: [author.id]).populate(@book, query: @query)
            end

            refute result.success?
            assert_equal 0, WorkflowRun.where(enrichable: [@book, author]).count
          end
        end
      end
    end
  end
end
