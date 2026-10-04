# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ResolveImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        # Not 656: the war_and_peace_edition fixture holds 656 under this
        # signature, already resolved, and would be reused without a finder run.
        WAR_AND_PEACE = {"Book Id" => "12345678", "Title" => "War and Peace", "Author" => "Leo Tolstoy",
                         "Original Publication Year" => "1869"}.freeze
        QUIET_YEAR = {"Book Id" => "90000001", "Title" => "The Quiet Year", "Author" => "Anna Brenner"}.freeze

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
        end

        def parse(*rows)
          ParseRows.call(import: @import, rows: goodreads_rows(*rows))
        end

        def counters
          @import.reload.slice(:matched_count, :created_count, :flagged_count, :parked_count, :ai_calls_count).values
        end

        test "resolves each edition once and sets the counters" do
          parse(WAR_AND_PEACE, WAR_AND_PEACE, QUIET_YEAR, {"Title" => "No Id", "Author" => "Anna Brenner"})

          ResolveImport.call(import: @import)

          assert_equal [1, 1, 0, 0, 0], counters
          assert_equal 2, ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: @import.editions.select(:id)).count
        end

        test "a flagged decision is counted" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(books_books(:war_and_peace))])
          stub_matching_ai(selected_index: 1, confidence: "medium")
          parse(WAR_AND_PEACE.merge("Title" => "War and Peace in the Garden"))

          ResolveImport.call(import: @import)

          assert_equal [1, 0, 1, 0, 1], counters
        end

        test "a failing edition records its error on its rows, the rest resolve, and a retry clears it" do
          parse(WAR_AND_PEACE, QUIET_YEAR)
          real = ::DataImporters::Books::Book::Finder.new
          flaky = Object.new
          flaky.define_singleton_method(:call) do |query:, **options|
            raise "AI timeout" if query.title == "The Quiet Year"

            real.call(query: query, **options)
          end

          ResolveImport.call(import: @import, finder: flaky)

          quiet = @import.rows.joins(:goodreads_edition).find_by!(books_goodreads_editions: {title: "The Quiet Year"})
          assert_equal "resolution failed: RuntimeError: AI timeout", quiet.error
          assert_equal [1, 0], counters.first(2)

          ResolveImport.call(import: @import)

          assert_nil quiet.reload.error
          assert_equal [1, 1], counters.first(2)
        end

        test "a created book later merged into another counts as matched, not created" do
          parse(QUIET_YEAR)
          ResolveImport.call(import: @import)
          ::Books::Book::Merger.call(source: @import.editions.sole.book, target: books_books(:war_and_peace))

          ResolveImport.call(import: @import)

          assert_equal [1, 0], counters.first(2)
        end

        test "a created book deleted and created again counts once" do
          parse(QUIET_YEAR)
          ResolveImport.call(import: @import)
          @import.editions.sole.book.destroy!

          ResolveImport.call(import: @import)

          assert_equal [0, 1], counters.first(2)
        end

        test "a Postgres error stops the import" do
          parse(QUIET_YEAR)
          broken = Object.new
          broken.define_singleton_method(:call) { |**| raise ActiveRecord::StatementInvalid, "connection lost" }

          assert_raises(ActiveRecord::StatementInvalid) { ResolveImport.call(import: @import, finder: broken) }
        end

        test "running it again asks the finder nothing and leaves the counters alone" do
          parse(WAR_AND_PEACE, QUIET_YEAR)
          ResolveImport.call(import: @import)
          before = counters
          finder = mock("finder")
          finder.expects(:call).never

          assert_no_difference(["::Books::Book.count", "::MatchDecision.count"]) { ResolveImport.call(import: @import, finder: finder) }

          assert_equal before, counters
        end
      end
    end
  end
end
