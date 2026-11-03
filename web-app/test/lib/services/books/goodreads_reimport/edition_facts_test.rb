# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class EditionFactsTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @row_number = 5_000
          @next_gr = 15_000
        end

        def edition_with(title: "Batman", row_titles: ["Batman: Year One (Batman #404-407)"], **attrs)
          @next_gr += 1
          edition = ::Books::GoodreadsEdition.create!({goodreads_book_id: @next_gr, signature: "sig-#{@next_gr}", title: title,
                                                       primary_author: "Frank Miller"}.merge(attrs))
          row_titles.each do |raw_title|
            ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {"Title" => raw_title},
              goodreads_edition: edition)
          end
          edition
        end

        test "full title comes from the CSV row, not the edition's cut title" do
          facts = EditionFacts.call(edition: edition_with)

          assert_equal "Batman: Year One (Batman #404-407)", facts.full_title
          assert_equal "Batman", facts.title
          assert_equal "Year One", facts.subtitle
        end

        test "the most common row title wins, ties go to the lowest row id" do
          facts = EditionFacts.call(edition: edition_with(row_titles: ["B Title", "A Title", "A Title", "B Title"]))

          assert_equal "B Title", facts.full_title
        end

        test "an edition with no rows falls back to its own title" do
          facts = EditionFacts.call(edition: edition_with(title: "Lonely", row_titles: []))

          assert_equal "Lonely", facts.full_title
          assert_nil facts.subtitle
        end

        test "authors are the primary author then additional authors, deduplicated" do
          edition = edition_with(primary_author: "Frank Miller", additional_authors: ["David Mazzucchelli", "Frank  Miller", ""])
          facts = EditionFacts.call(edition: edition)

          assert_equal ["Frank Miller", "David Mazzucchelli"], facts.author_names
        end

        test "to_query sends only the primary author as author, the rest as context" do
          edition = edition_with(additional_authors: ["David Mazzucchelli", "Richmond Lewis"])
          query = EditionFacts.call(edition: edition).to_query

          assert_equal ["Frank Miller"], query.author_names
          assert_equal ["David Mazzucchelli", "Richmond Lewis"], query.context_author_names
        end

        test "year is original publication year, else year published" do
          assert_equal 1987, EditionFacts.call(edition: edition_with(original_publication_year: 1987, year_published: 2005)).year
          assert_equal 2005, EditionFacts.call(edition: edition_with(year_published: 2005)).year
        end

        test "to_query builds the finder query and to_h uses string keys" do
          edition = edition_with(isbn13: "9781401207526", isbn10: "1401207529", series_name: "Batman", series_number: "404",
            original_publication_year: 1987)
          facts = EditionFacts.call(edition: edition)
          query = facts.to_query

          assert_instance_of DataImporters::Books::Book::ImportQuery, query
          assert_equal "Batman", query.title
          assert_equal ["Frank Miller"], query.author_names
          assert_equal 1987, query.year
          assert_equal ["9781401207526"], query.isbn13
          assert_equal ["1401207529"], query.isbn10
          assert_equal [edition.goodreads_book_id.to_s], query.goodreads_id
          assert_equal "Batman", query.series_name
          assert_equal "404", query.series_number
          assert_equal "Year One", query.subtitle
          assert_equal "Batman", facts.to_h["series_name"]
          assert_equal "Batman: Year One (Batman #404-407)", facts.to_h["full_title"]
        end
      end
    end
  end
end
