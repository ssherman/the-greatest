# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Authors
      class UnknownAuthorTest < ActiveSupport::TestCase
        setup do
          @unknown = books_authors(:excluded_placeholder)
        end

        test "placeholder names match whatever their case, spacing or trailing period" do
          ["Unknown", "unknown", " UNKNOWN ", "Unknown Author", "unknown  author", "Anonymous", "anonymous.", "Anon", "Anon."].each do |name|
            assert UnknownAuthor.placeholder?(name), name.inspect
          end
        end

        test "real names, Various and place names are not placeholders" do
          ["Various", "Various Authors", "China", "Leo Tolstoy", "Unknown Pleasures", "", nil].each do |name|
            assert_not UnknownAuthor.placeholder?(name), name.inspect
          end
        end

        test "the canonical author is the Unknown with the most books, lowest id on a tie" do
          small = ::Books::Author.create!(name: "Unknown")
          assert_equal @unknown, UnknownAuthor.canonical

          2.times { |i| ::Books::BookAuthor.create!(book: ::Books::Book.create!(title: "Untitled #{i}"), author: small, position: 1) }
          assert_equal small, UnknownAuthor.canonical
        end

        test "no canonical author when nothing is named exactly Unknown" do
          @unknown.update_columns(name: "Unknown Author")
          assert_nil UnknownAuthor.canonical
        end

        test "the merge's selection and the finder's check agree on every edge-case name" do
          names = ["Anon..", "Anonymous .", "\tUnknown", "Unknown Author", "unknown\nauthor", "ANON.", "Anonymous!", "Unknown Pleasures", "Anonymous Lover"]
          authors = names.map { |name| ::Books::Author.create!(name: name) }
          selected = UnknownAuthor.placeholders.pluck(:id)

          authors.each do |author|
            assert_equal UnknownAuthor.placeholder?(author.name), selected.include?(author.id), author.name.inspect
          end
          assert UnknownAuthor.placeholder?("Anonymous ."), "a space before the period still counts"
          assert_not UnknownAuthor.placeholder?("Anon.."), "only one trailing period is dropped"
        end

        test "placeholders lists every author with a placeholder name and nothing else" do
          anonymous = ::Books::Author.create!(name: "Anonymous")
          unknown_author = ::Books::Author.create!(name: "unknown author")
          ::Books::Author.create!(name: "Various")

          assert_equal [@unknown, anonymous, unknown_author].map(&:id).sort, UnknownAuthor.placeholders.pluck(:id).sort
        end
      end
    end
  end
end
