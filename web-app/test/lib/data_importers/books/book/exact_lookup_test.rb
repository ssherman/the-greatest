# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class ExactLookupTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Hans Trefousse")
        end

        def book(title, subtitle = nil)
          record = ::Books::Book.create!(title: title, subtitle: subtitle)
          ::Books::BookAuthor.create!(book: record, author: @author, position: 1)
          record
        end

        def lookup(title, subtitle: nil, loose: false, limit: 5)
          ExactLookup.call(title: title, subtitle: subtitle, author_names: ["Hans Trefousse"], limit: limit, loose: loose).to_a
        end

        test "a whole title finds the book that holds it split, and a split one the book that holds it whole" do
          split = book("Andrew Johnson", "A Biography")
          whole = book("Thaddeus Stevens: Nineteenth-Century Egalitarian")

          assert_equal [split], lookup("Andrew Johnson: A Biography")
          assert_equal [whole], lookup("Thaddeus Stevens", subtitle: "Nineteenth-Century Egalitarian")
        end

        test "a closing series note does not hide the book" do
          split = book("Andrew Johnson", "A Biography")

          assert_equal [split], lookup("Andrew Johnson: A Biography (American Presidents Book 17)")
        end

        test "the part before the colon alone counts only when loose" do
          other = book("Andrew Johnson", "Seventeenth President")

          assert_equal [], lookup("Andrew Johnson: A Biography")
          assert_equal [other], lookup("Andrew Johnson: A Biography", loose: true)
        end

        test "whole-title matches come first, so a long series cannot push one out of the limit" do
          4.times { |i| book("Andrew Johnson", "Part #{i}") }
          wanted = book("Andrew Johnson", "A Biography")

          assert_includes lookup("Andrew Johnson: A Biography", loose: true, limit: 2), wanted
        end

        test "with no author, only the title itself is looked up" do
          book("Andrew Johnson", "A Biography")

          assert_equal [], ExactLookup.call(title: "Andrew Johnson: A Biography", author_names: []).to_a
        end
      end
    end
  end
end
