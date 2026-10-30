# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class ExportFactsTest < ActiveSupport::TestCase
        FakeSurvey = Struct.new(:groups)

        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @row_number = 2_000
        end

        def edition(gr, title: "Tenth of December", author: "George Saunders", rows: 1, **attrs)
          created = ::Books::GoodreadsEdition.create!(goodreads_book_id: gr, signature: "sig-#{gr}", title: title, primary_author: author,
            original_publication_year: 2013, **attrs)
          rows.times do
            ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {}, goodreads_edition: created)
          end
          created
        end

        def evidence(edition, world_cat: :no_record, ol_work_keys: [])
          ::Books::RebuildEditionEvidence.create!(goodreads_book_id: edition.goodreads_book_id, signature: edition.signature,
            world_cat: world_cat, ol_work_keys: ol_work_keys, checked_at: Time.current)
        end

        def group(*editions, year: 2013, volume: nil)
          {"edition_ids" => editions.map(&:id), "goodreads_book_ids" => editions.map(&:goodreads_book_id), "titles" => [],
           "authors" => [], "year" => year, "volume" => volume, "row_count" => 1}
        end

        def facts(*groups) = ExportFacts.call(survey: FakeSurvey.new(groups))

        test "full title comes from the main group's most-rowed edition, split at the first colon" do
          full = "How to Work with (Almost) Anyone: Five Questions for Building the Best Possible Relationships"
          few = edition(1, title: "Short Edition", rows: 1)
          many = edition(2, title: full, rows: 3)

          result = facts(group(few, many))

          assert_equal "How to Work with (Almost) Anyone", result.title
          assert_equal "Five Questions for Building the Best Possible Relationships", result.subtitle
          assert_equal full, result.full_title
        end

        test "a trailing Goodreads series suffix is dropped from the title" do
          one = edition(1, title: "The Crossroads of Time (Crosstime (aka) Blake Walker #1)", series_name: "Crosstime (aka) Blake Walker")

          result = facts(group(one, volume: "1"))

          assert_equal "The Crossroads of Time", result.title
          assert_nil result.subtitle
          assert_equal "Crosstime (aka) Blake Walker", result.series_name
          assert_equal "1", result.volume
        end

        test "a parenthetical without a number stays in the title" do
          one = edition(1, title: "How to Work with (Almost) Anyone")

          assert_equal "How to Work with (Almost) Anyone", facts(group(one)).title
        end

        test "ties on row count go to the lowest goodreads book id" do
          later = edition(9, title: "Later", rows: 2)
          earlier = edition(3, title: "Earlier", rows: 2)

          assert_equal "Earlier", facts(group(later, earlier)).title
        end

        test "author_names are the distinct primary authors, most rows first, never additional authors" do
          a = edition(1, author: "Minor Author", rows: 1, additional_authors: ["Translator Person"])
          b = edition(2, author: "Major Author", rows: 3)
          c = edition(3, author: "Major Author", rows: 1)

          assert_equal ["Major Author", "Minor Author"], facts(group(a, b, c)).author_names
        end

        test "isbn and goodreads ids cover every edition in the main group only" do
          a = edition(1, isbn13: "9780812993803", isbn10: "0812993802", rows: 2)
          b = edition(2, isbn13: "9780679731726")
          other = edition(3, isbn13: "9781111111111")

          result = facts(group(a, b), group(other))

          assert_equal ["9780812993803", "9780679731726"].sort, result.isbn13.sort
          assert_equal ["0812993802"], result.isbn10
          assert_equal %w[1 2], result.goodreads_ids.sort
          assert_equal [a.id, b.id].sort, result.edition_ids.sort
        end

        test "world_cat_agrees is true when any main-group edition's evidence agrees" do
          a = edition(1)
          b = edition(2)
          evidence(a, world_cat: :disagrees)
          evidence(b, world_cat: :agrees)

          assert facts(group(a, b)).world_cat_agrees
        end

        test "world_cat_agrees is false when none agree or there is no evidence" do
          a = edition(1)
          b = edition(2)
          evidence(a, world_cat: :disagrees)

          refute facts(group(a, b)).world_cat_agrees
          refute facts(group(b)).world_cat_agrees
        end

        test "ol_work_keys are ordered by how many main-group editions name them" do
          a = edition(1)
          b = edition(2)
          c = edition(3, rows: 3)
          evidence(a, ol_work_keys: ["OL1W", "OL2W"])
          evidence(b, ol_work_keys: ["OL2W"])
          evidence(c, ol_work_keys: ["OL2W", "OL3W"])

          # OL1W and OL3W tie on one edition each; the most-rowed edition's key wins, though its evidence was saved last.
          assert_equal %w[OL2W OL3W OL1W], facts(group(a, b, c)).ol_work_keys
        end

        test "query_attributes round-trips to_payload" do
          a = edition(1, title: "Tenth of December: Stories", isbn13: "9780812993803", isbn10: "0812993802")
          evidence(a, ol_work_keys: ["OL1W"])
          result = facts(group(a, volume: "2"))

          payload = JSON.parse(result.to_payload.to_json)
          attributes = ExportFacts.query_attributes(payload)

          assert_equal({title: "Tenth of December", subtitle: "Stories", author_names: ["George Saunders"], year: 2013,
                        isbn13: ["9780812993803"], isbn10: ["0812993802"], goodreads_id: ["1"], open_library_work_key: "OL1W",
                        series_name: nil, series_number: "2"}, attributes)
          assert result.to_query.valid?
          assert_equal result.to_payload, payload
        end
      end
    end
  end
end
