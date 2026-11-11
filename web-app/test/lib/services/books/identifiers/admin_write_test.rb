# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Identifiers
      class AdminWriteTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @author = books_authors(:tolstoy)
          ::Workflows::Books::AuthorEnrichment.stubs(:start)
        end

        def add(record, type, value) = AdminWrite.add(record: record, identifier_type: type, value: value)

        def assert_added(result, value)
          assert result.success?, result.errors.inspect
          assert_equal value, result.data[:identifier].value
          assert result.data[:identifier].source_admin?
          assert result.data[:created]
        end

        def assert_refused(result, code, detail)
          assert_not result.success?
          assert_equal code, result.data[:code]
          assert_match detail, result.errors.join(" ")
        end

        test "a Wikidata QID is upcased" do
          assert_added add(@author, "books_author_wikidata_qid", " q7243 "), "Q7243"
          assert_added add(@book, "books_work_wikidata_qid", "q161531"), "Q161531"
        end

        test "a Wikidata QID that is not Q and digits is refused, naming the form" do
          assert_refused add(@author, "books_author_wikidata_qid", "7243"), :invalid, /Q followed by digits/
          assert_refused add(@book, "books_work_wikidata_qid", "Q72a"), :invalid, /Q followed by digits/
        end

        test "a VIAF id must be digits" do
          assert_added add(@author, "books_author_viaf", "96987389"), "96987389"
          assert_refused add(@author, "books_author_viaf", "VIAF96987389"), :invalid, /digits/
        end

        test "an ISBN-13 is stripped of hyphens and spaces and its checksum checked" do
          assert_added add(@book, "books_work_isbn13", "978-0-306-40615-7"), "9780306406157"
          assert_refused add(@book, "books_work_isbn13", "9780306406158"), :invalid, /ISBN-13/
          assert_refused add(@book, "books_work_isbn13", "0306406152"), :invalid, /ISBN-13/
        end

        test "an ISBN-10 is stripped, upcased, and its checksum checked" do
          assert_added add(@book, "books_work_isbn10", "0-306-40615-2"), "0306406152"
          assert_added add(@book, "books_work_isbn10", "080442957x"), "080442957X"
          assert_refused add(@book, "books_work_isbn10", "0306406153"), :invalid, /ISBN-10/
          assert_refused add(@book, "books_work_isbn10", "9780306406157"), :invalid, /ISBN-10/
        end

        test "an ISNI is 16 characters of digits or X, spaces stripped" do
          assert_added add(@author, "books_author_isni", "0000 0001 2096 0218"), "0000000120960218"
          assert_added add(@author, "books_author_isni", "000000012281955x"), "000000012281955X"
          assert_refused add(@author, "books_author_isni", "0000 0001 2096"), :invalid, /16/
        end

        test "any other type is stripped, non-blank and at most 255 characters" do
          assert_added add(@book, "books_work_goodreads_id", "  12345  "), "12345"
          assert_refused add(@book, "books_work_goodreads_id", "   "), :invalid, /blank/
          assert_refused add(@book, "books_work_goodreads_id", "1" * 256), :invalid, /255/
        end

        test "a type the record kind cannot hold is refused" do
          assert_refused add(@book, "books_author_viaf", "123"), :invalid, /books_work_/
          assert_refused add(@author, "books_work_isbn13", "9780306406157"), :invalid, /books_author_/
          assert_refused add(@book, "books_edition_isbn13", "9780306406157"), :invalid, /books_work_/
          assert_refused add(@book, "music_isrc", "x"), :invalid, /books_work_/
        end

        test "adding a value the record already holds returns the existing row unchanged" do
          existing = identifiers(:war_and_peace_isbn13)

          result = add(@book, "books_work_isbn13", "978-0140447934")

          assert result.success?
          assert_equal existing, result.data[:identifier]
          assert_not result.data[:created]
          assert_nil existing.reload.source
        end

        test "an author already holding a different QID is refused until it is removed" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q1", source: :wikidata)

          assert_refused add(@author, "books_author_wikidata_qid", "Q7243"), :conflict, /remove Q1 first/
        end

        test "an author already holding a different VIAF id is refused until it is removed" do
          @author.identifiers.create!(identifier_type: :books_author_viaf, value: "111", source: :viaf)

          assert_refused add(@author, "books_author_viaf", "222"), :conflict, /remove 111 first/
        end

        test "a value rejected for this author is refused" do
          ::MatchDecision.create!(finder: ::Services::Books::Authors::ResolveWikidata.name, subject: @author, outcome: :matched,
            confidence: :high, decided_by: :rule, verdict: :rejected, candidates: [{"external_key" => "Q42"}], selected_index: 1)

          assert_refused add(@author, "books_author_wikidata_qid", "Q42"), :conflict, /rejected/
          assert_not @author.identifiers.exists?(value: "Q42")
        end

        test "adding an author QID or VIAF id starts a refresh enrichment run" do
          ::Workflows::Books::AuthorEnrichment.expects(:start)
            .with(@author, initiated_by: "admin_identifier", options: {refresh: true}, supersede: true).twice

          add(@author, "books_author_wikidata_qid", "Q7243")
          add(@author, "books_author_viaf", "96987389")
        end

        test "other author identifiers, book identifiers and an unchanged add start nothing" do
          @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243")
          ::Workflows::Books::AuthorEnrichment.expects(:start).never

          add(@author, "books_author_isni", "0000000120960218")
          add(@author, "books_author_wikidata_qid", "Q7243")
          add(@book, "books_work_wikidata_qid", "Q161531")
        end

        test "removing an author QID deletes it and starts a refresh enrichment run" do
          row = @author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q7243", source: :wikidata)
          ::Workflows::Books::AuthorEnrichment.expects(:start)
            .with(@author, initiated_by: "admin_identifier", options: {refresh: true}, supersede: true).once

          result = AdminWrite.remove(record: @author, identifier: row)

          assert result.success?
          assert_equal row.id, result.data[:identifier].id
          assert_not ::Identifier.exists?(row.id)
        end

        test "removing a book identifier starts nothing" do
          row = identifiers(:war_and_peace_asin)
          ::Workflows::Books::AuthorEnrichment.expects(:start).never

          assert AdminWrite.remove(record: @book, identifier: row).success?
          assert_not ::Identifier.exists?(row.id)
        end

        test "the type lists are the books types, by level" do
          assert_equal ::Identifier.identifier_types.keys.grep(/\Abooks_/), AdminWrite::IDENTIFIER_TYPES
          assert_includes AdminWrite::BOOK_TYPES, "books_work_isbn13"
          assert(AdminWrite::BOOK_TYPES.all? { |type| type.start_with?("books_work_") })
          assert_includes AdminWrite::AUTHOR_TYPES, "books_author_viaf"
          assert(AdminWrite::AUTHOR_TYPES.all? { |type| type.start_with?("books_author_") })
        end
      end
    end
  end
end
