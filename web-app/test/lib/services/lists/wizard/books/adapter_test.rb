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
            match = wizard_match(subject: row, outcome: :unmatched, external: ol_candidate("OL1W"),
              external_resolution: resolution(accept_key: "OL1W", duplicates: ["OL2W"], duplicate_redirects: ["OL3W"], redirect_sources: ["OL4W"]))

            assert_equal %w[OL1W OL2W OL3W OL4W], @adapter.recheck_keys(match).sort
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
        end
      end
    end
  end
end
