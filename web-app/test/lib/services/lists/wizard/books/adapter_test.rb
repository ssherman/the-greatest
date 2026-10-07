# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Books
        class AdapterTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @adapter = Adapter.new
            @list = wizard_list
          end

          def resolution(accept_key:, duplicates: [], duplicate_redirects: [], redirect_sources: [])
            key = ->(value) { {"source" => "openlibrary", "key" => value} }
            ::Books::OpenLibrary::Resolution.from_response({
              "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                                   "pipeline_version" => 1, "matcher_version" => 2},
              "data" => {
                "decision" => {"verdict" => "accept", "key" => key.call(accept_key), "score" => 0.9, "margin" => 0.3, "reason" => "test",
                               "duplicates" => duplicates.map(&key), "duplicate_redirect_sources" => duplicate_redirects.map(&key)},
                "guards_tripped" => [], "volume_guards_tripped" => [],
                "candidates" => [{"key" => key.call(accept_key), "score" => 0.9, "rules" => [], "margin" => 0.3, "verdict" => "accept",
                                  "evidence" => {}, "conflicts" => [], "diff" => [], "record" => nil,
                                  "redirect_sources" => redirect_sources.map(&key)}]
              }
            })
          end

          test "parse maps the parser's books to wizard rows, subtitle and year included, and drops untitled ones" do
            data = {books: [
              {rank: 1, title: " Sapiens ", subtitle: "A Brief History of Humankind", authors: ["Yuval Noah Harari", " "], publication_year: 2011},
              {rank: nil, title: "", subtitle: nil, authors: [], publication_year: nil}
            ]}
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.any_instance.stubs(:call)
              .returns(::Services::Ai::Result.new(success: true, data: data))

            result = @adapter.parse(@list)

            assert result.success?
            assert_equal [{"rank" => 1, "title" => "Sapiens", "subtitle" => "A Brief History of Humankind",
                           "authors" => ["Yuval Noah Harari"], "year" => 2011}], result.data
          end

          test "parse hands a batch's content to the parser" do
            task = stub(call: ::Services::Ai::Result.new(success: true, data: {books: []}))
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.expects(:new).with(parent: @list, content: "1. Emma by Jane Austen").returns(task)

            assert @adapter.parse(@list, content: "1. Emma by Jane Austen").success?
          end

          test "parse reports the parser's error" do
            ::Services::Ai::Tasks::Lists::Books::RawParserTask.any_instance.stubs(:call)
              .returns(::Services::Ai::Result.new(success: false, error: "rate limited"))

            result = @adapter.parse(@list)

            assert_not result.success?
            assert_equal ["rate limited"], result.errors
          end

          test "row_signature uses the row's text, and falls back to the linked book's for a row without it" do
            text_row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
            bare_row = @list.list_items.create!(listable: books_books(:war_and_peace), position: 2)

            expected = @adapter.signature("war and peace", ["LEO TOLSTOY"])
            assert_equal expected, @adapter.row_signature(text_row)
            assert_equal expected, @adapter.row_signature(bare_row)
          end

          test "query_for builds the finder query from the row, subtitle and year included" do
            row = wizard_row(@list, position: 1, title: "Sapiens", subtitle: "A Brief History of Humankind",
              authors: ["Yuval Noah Harari"], year: "2011")

            query = @adapter.query_for(row)

            assert_instance_of ::DataImporters::Books::Book::ImportQuery, query
            assert_equal ["Sapiens", "A Brief History of Humankind", ["Yuval Noah Harari"], 2011],
              [query.title, query.subtitle, query.author_names, query.year]
          end

          test "query_for drops a year that is not a year" do
            row = wizard_row(@list, position: 1, title: "Sapiens", year: "circa 2011")

            assert_nil @adapter.query_for(row).year
          end

          test "finder is a fresh books finder" do
            assert_instance_of ::DataImporters::Books::Book::Finder, @adapter.finder
            assert_not_same @adapter.finder, @adapter.finder
          end

          test "recheck_keys saves the chosen work, the accepted key, its duplicates and both redirect-source lists" do
            row = wizard_row(@list, position: 1, title: "Dune")
            match = wizard_match(subject: row, outcome: :unmatched, external: ol_candidate("OL0W"),
              external_resolution: resolution(accept_key: "OL1W", duplicates: ["OL2W"], duplicate_redirects: ["OL3W"], redirect_sources: ["OL4W"]))

            assert_equal %w[OL0W OL1W OL2W OL3W OL4W], @adapter.recheck_keys(match).sort
          end

          test "recheck_keys without a resolution keeps only an Open Library external key" do
            row = wizard_row(@list, position: 1, title: "Dune")
            ol = wizard_match(subject: row, outcome: :unmatched, external: ol_candidate("OL1W"))
            other = wizard_match(subject: row, outcome: :unmatched,
              external: ::DataImporters::Candidate.new(external_key: "X1", external_source: :igdb))

            assert_equal ["OL1W"], @adapter.recheck_keys(ol)
            assert_equal [], @adapter.recheck_keys(other)
          end

          test "find_record finds a book by id and answers nil for an unknown one" do
            assert_equal books_books(:got), @adapter.find_record(books_books(:got).id.to_s)
            assert_nil @adapter.find_record("0")
          end

          test "row_display and record_display give title, authors and year" do
            row = wizard_row(@list, position: 1, title: "Sapiens", subtitle: "A Brief History", authors: ["Yuval Noah Harari"], year: 2011)

            assert_equal({title: "Sapiens", subtitle: "A Brief History", authors: ["Yuval Noah Harari"], year: 2011}, @adapter.row_display(row))
            assert_equal({title: "War and Peace", authors: ["Leo Tolstoy"], year: 1869}, @adapter.record_display(books_books(:war_and_peace)))
          end

          test "recheck finds a book holding the chosen work or any key saved at Match" do
            held = books_books(:crime_and_punishment) # holds OL262758W (fixture)
            chosen = wizard_row(@list, position: 1, title: "Crime and Punishment", wizard: {bucket: "create", ol_work_key: "OL262758W"})
            saved = wizard_row(@list, position: 2, title: "Crime and Punishment", wizard: {bucket: "create", ol_work_key: "OL1W", ol_keys: ["OL1W", "OL262758W"]})
            missing = wizard_row(@list, position: 3, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL2W", ol_keys: ["OL2W"]})

            assert_equal held, @adapter.recheck(chosen)
            assert_equal held, @adapter.recheck(saved)
            assert_nil @adapter.recheck(missing)
          end

          test "recheck for a text row finds a book with the same title and an agreeing author created after its match" do
            row = wizard_row(@list, position: 1, title: "A Winter of Crows", authors: ["Wren Halloway"],
              wizard: {bucket: "create", matched_at: 1.hour.ago.iso8601})
            author = ::Books::Author.create!(name: "Wren Halloway")
            book = ::Books::Book.create!(title: "A Winter of Crows")
            book.book_authors.create!(author: author, position: 1)

            assert_equal book, @adapter.recheck(row)
          end

          test "recheck for a text row ignores a book made before its match, or by someone else" do
            row = wizard_row(@list, position: 1, title: "A Winter of Crows", authors: ["Wren Halloway"],
              wizard: {bucket: "create", matched_at: 1.hour.from_now.iso8601})
            author = ::Books::Author.create!(name: "Wren Halloway")
            ::Books::Book.create!(title: "A Winter of Crows").book_authors.create!(author: author, position: 1)
            later = wizard_row(@list, position: 2, title: "A Winter of Crows", authors: ["Somebody Else"],
              wizard: {bucket: "create", matched_at: 1.hour.ago.iso8601})

            assert_nil @adapter.recheck(row)
            assert_nil @adapter.recheck(later)
          end

          test "create sends a chosen work, trusted, as a normal enriched book with the rebuilt match" do
            book = books_books(:war_and_peace)
            row = wizard_row(@list, position: 1, title: "War and Peace", subtitle: "A Novel", authors: ["Leo Tolstoy"], year: 1869)
            decision = wizard_match(subject: row, outcome: :unmatched, candidates: [local_candidate(books_books(:got))]).decision
            row.update!(metadata: row.metadata.deep_merge("wizard" => {"bucket" => "create", "ol_work_key" => "OL5W", "match_decision_id" => decision.id}))
            importer = mock("importer")
            importer.expects(:call).with { |**kw|
              kw.values_at(:title, :subtitle, :author_names, :year, :open_library_work_key, :trust_work_key, :provisional, :enrich, :subject) ==
                ["War and Peace", "A Novel", ["Leo Tolstoy"], 1869, "OL5W", true, false, true, row] &&
                kw[:match].decision == decision && kw[:match].candidates.map(&:record) == [books_books(:got)] && !kw.key?(:providers)
            }.returns(::DataImporters::ImportResult.new(item: book, provider_results: [], success: true, created: true))

            assert_equal book, @adapter.create(row, importer: importer)
          end

          test "create for a text row skips the Open Library provider" do
            row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"], wizard: {bucket: "create"})
            importer = mock("importer")
            importer.expects(:call).with { |**kw| kw[:providers] == Adapter::TEXT_PROVIDERS && !kw.key?(:open_library_work_key) }
              .returns(::DataImporters::ImportResult.new(item: books_books(:war_and_peace), provider_results: [], success: true, created: true))

            @adapter.create(row, importer: importer)
          end

          test "create raises when nothing was created, and rolls back a book left with no author" do
            row = wizard_row(@list, position: 1, title: "Nobody's Book", wizard: {bucket: "create"})
            failed = mock("importer")
            failed.stubs(:call).returns(::DataImporters::ImportResult.new(item: ::Books::Book.new(title: "x"), provider_results: [], success: false))
            authorless = Object.new
            def authorless.call(**)
              ::DataImporters::ImportResult.new(item: ::Books::Book.create!(title: "Nobody's Book"), provider_results: [], success: true, created: true)
            end

            assert_raises(Adapter::CreateFailed) { @adapter.create(row, importer: failed) }
            assert_raises(Adapter::CreateFailed) { @adapter.create(row, importer: authorless) }
            assert_not ::Books::Book.exists?(title: "Nobody's Book")
          end

          test "paths point at the books admin wizard, the book search and the list pages" do
            assert_equal "/admin/lists/#{@list.id}/wizard", @adapter.wizard_path(nil, @list)
            assert_equal "/admin/lists/#{@list.id}/wizard/step/review?filter=ai", @adapter.wizard_path(:step, @list, step: "review", filter: "ai")
            assert_equal "/admin/lists/#{@list.id}/wizard/rows/7/link", @adapter.wizard_path(:link_row, @list, row_id: 7)
            assert_equal "/admin/books/search", @adapter.search_path
            assert_equal ["/admin/lists", "/admin/lists/#{@list.id}"], [@adapter.lists_path, @adapter.list_path(@list)]
          end
        end
      end
    end
  end
end
